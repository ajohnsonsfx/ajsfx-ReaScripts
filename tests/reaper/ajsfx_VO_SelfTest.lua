-- @noindex
--
-- ajsfx VO — REAPER self-test.
--
-- tests/test_vo.lua covers the pure layer against a mock REAPER. This covers
-- what that mock cannot: real audio samples through REAPER's audio accessor,
-- real media items, real splits, and real undo. It is not a substitute for
-- looking at the windows -- nothing here draws a frame or clicks a button --
-- but every claim it makes about the coupled layer is one nobody has to take
-- on trust.
--
-- HOW TO RUN
--   Actions → Show action list → ReaScript: Load → pick this file → Run.
--   It opens a NEW project tab and works only in there; your own project is
--   never touched. Close that tab WITHOUT saving when it finishes.
--   Results go to the ReaScript console and to
--   <scratch>/ajsfx_vo_selftest.log, which is the file to send back.
--
-- The fixture audio is generated here rather than committed: the test needs to
-- know the exact amplitude of every sample to assert what the probe reads, and
-- a wav in the repo would be a binary nobody can review.

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
-- tests/reaper/ -> repo root -> VO/
package.path = script_path .. "../../VO/?.lua;" ..
               script_path .. "../../?.lua;" .. package.path

local core = require("lib.ajsfx_core")
local vo   = require("lib.ajsfx_vo")

--------------------------------
-- Harness
--------------------------------

local passed, failed, lines = 0, 0, {}

local function say(text)
  lines[#lines + 1] = text
  r.ShowConsoleMsg(text .. "\n")
end

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    say("  PASS: " .. name)
  else
    failed = failed + 1
    say("  FAIL: " .. name .. "\n        " .. tostring(err))
  end
end

local function section(title)
  say("\n" .. title .. ":")
end

local function near(a, b, tol, what)
  if not a then error((what or "value") .. " is nil", 2) end
  if math.abs(a - b) > tol then
    error(string.format("%s: expected %.3f +/- %.3f, got %.3f",
                        what or "value", b, tol, a), 2)
  end
end

--------------------------------
-- Fixture audio
--------------------------------

-- 16-bit mono PCM at 48k. The shape matters to every assertion below:
--
--   0.00 - 0.50  near-silence   (a real noise floor, not digital black)
--   0.50 - 0.90  tone at -12 dBFS
--   0.90 - 1.40  near-silence
--   1.40 - 1.80  tone at -12 dBFS
--   1.80 - 2.30  near-silence
--
-- The floor is dithered rather than zero because a real recording never reads
-- -inf, and code that only works against digital black would pass here and
-- fail on a session.
local RATE       = 48000
local TONE_DB    = -12.0
local FLOOR_DB   = -60.0
local BURSTS     = { { 0.50, 0.90 }, { 1.40, 1.80 } }
local TOTAL_S    = 2.30

local function le16(v)
  if v < 0 then v = v + 65536 end
  return string.char(v % 256, math.floor(v / 256) % 256)
end

local function le32(v)
  return string.char(v % 256, math.floor(v / 256) % 256,
                     math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

local function write_fixture_wav(path)
  local n     = math.floor(TOTAL_S * RATE)
  local tone  = 32767 * (10 ^ (TONE_DB / 20))
  local floor = 32767 * (10 ^ (FLOOR_DB / 20))

  local samples = {}
  for i = 0, n - 1 do
    local t = i / RATE
    local v = floor * math.sin(2 * math.pi * 3000 * t)   -- the noise floor
    for _, b in ipairs(BURSTS) do
      if t >= b[1] and t < b[2] then
        v = tone * math.sin(2 * math.pi * 440 * t)
      end
    end
    samples[#samples + 1] = le16(math.floor(v + 0.5))
  end

  local data = table.concat(samples)
  local f, err = io.open(path, "wb")
  if not f then error("Cannot write fixture wav: " .. tostring(err)) end
  f:write("RIFF", le32(36 + #data), "WAVE",
          "fmt ", le32(16), le16(1), le16(1),
          le32(RATE), le32(RATE * 2), le16(2), le16(16),
          "data", le32(#data))
  f:write(data)
  f:close()
  return path
end

--------------------------------
-- Project fixture
--------------------------------

local function new_tab()
  r.Main_OnCommand(40859, 0)   -- New project tab
end

-- Inserts the fixture at 0.0 on a fresh track and returns item, take, track.
local function insert_fixture(path)
  r.InsertTrackAtIndex(0, true)
  local track = r.GetTrack(0, 0)
  r.SetOnlyTrackSelected(track)
  r.SetEditCurPos(0, false, false)
  r.InsertMedia(path, 0)

  local item = r.GetTrackMediaItem(track, 0)
  if not item then error("InsertMedia put no item on the track") end
  return item, r.GetActiveTake(item), track
end

--------------------------------
-- The run
--------------------------------

r.ClearConsole()
say("ajsfx VO — REAPER self-test")
say(("REAPER %s, %s"):format(tostring(r.GetAppVersion()), tostring(r.GetOS())))

local scratch = vo.ResolveScratchDir(vo.LoadConfig())
r.RecursiveCreateDirectory(scratch, 0)
local wav_path = scratch .. "/ajsfx_vo_selftest.wav"
local log_path = scratch .. "/ajsfx_vo_selftest.log"

write_fixture_wav(wav_path)
say("Fixture: " .. wav_path)

new_tab()
local item, take, track = insert_fixture(wav_path)

--------------------------------
section("Fixture and project state")

test("the fixture reads back at its written length", function()
  local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  near(len, TOTAL_S, 0.02, "item length")
end)

test("CollectProjectSpans sees the inserted item", function()
  local items = vo.CollectProjectSpans()
  if #items ~= 1 then error("expected 1 item, got " .. #items) end
  if not items[1].path or items[1].path == "" then error("item carries no source path") end
end)

test("ProjectSourcePaths resolves to the fixture on disk", function()
  local paths = vo.ProjectSourcePaths(vo.CollectProjectSpans())
  if #paths ~= 1 then error("expected 1 source, got " .. #paths) end
  if not vo.FileExists(paths[1]) then error("source path does not exist: " .. paths[1]) end
end)

--------------------------------
section("MakeTakeProbe against real samples")

local probe, destroy = vo.MakeTakeProbe(take)

test("a probe is created for a real take", function()
  if not probe then error("MakeTakeProbe returned no probe") end
end)

test("the tone reads at the amplitude it was written at", function()
  -- RMS of a sine is its peak minus 3.01 dB.
  near(probe(0.60, 0.80), TONE_DB - 3.01, 1.5, "tone dBFS")
end)

test("the silence reads at the noise floor, not at zero", function()
  local db = probe(1.00, 1.30)
  near(db, FLOOR_DB - 3.01, 3.0, "floor dBFS")
end)

test("silence reads quieter than tone by the written margin", function()
  local quiet, loud = probe(1.00, 1.30), probe(0.60, 0.80)
  local margin = loud - quiet
  near(margin, TONE_DB - FLOOR_DB, 4.0, "tone-to-floor margin")
end)

test("a zero-length window is refused rather than guessed at", function()
  if probe(1.0, 1.0) ~= nil then error("expected nil for an empty window") end
end)

--------------------------------
section("Noise floor and boundary snapping")

-- The words the transcript would hold for this fixture: one per burst.
local words = {
  { t0 = BURSTS[1][1], t1 = BURSTS[1][2], text = "first" },
  { t0 = BURSTS[2][1], t1 = BURSTS[2][2], text = "second" },
}
local cfg = vo.LoadConfig()

test("MeasureNoiseFloor lands near the written floor", function()
  local gaps = vo.InterWordGaps(words)
  if #gaps ~= 1 then error("expected 1 inter-word gap, got " .. #gaps) end
  local floor = vo.MeasureNoiseFloor(gaps, probe, cfg)
  -- The measurement is the quietest window plus cfg.snap_floor_offset.
  near(floor, FLOOR_DB - 3.01 + vo.Opt(cfg, "snap_floor_offset"), 4.0, "measured floor")
end)

test("a boundary snaps into the silence rather than to the pad limit", function()
  local floor = vo.MeasureNoiseFloor(vo.InterWordGaps(words), probe, cfg)
  -- Travelling backwards from the second burst, with room to reach silence.
  local at, how = vo.SnapBoundary(BURSTS[2][1], BURSTS[2][1] - 0.30, -1, floor, probe, cfg)
  if how ~= "silence" then error("expected a silence snap, got " .. tostring(how)) end
  if at >= BURSTS[2][1] then error("boundary did not move back: " .. at) end
  if at < BURSTS[1][2] then
    error(string.format("boundary %0.3f crossed into the previous word (ends %0.3f)",
                        at, BURSTS[1][2]))
  end
end)

test("a boundary never travels past its limit", function()
  local floor = vo.MeasureNoiseFloor(vo.InterWordGaps(words), probe, cfg)
  local limit = BURSTS[2][1] - 0.10
  local at = vo.SnapBoundary(BURSTS[2][1], limit, -1, floor, probe, cfg)
  if at < limit - 1e-6 then
    error(string.format("boundary %0.3f went past the limit %0.3f", at, limit))
  end
end)

test("ApplyPadding keeps both clips clear of the neighbouring word", function()
  local floor = vo.MeasureNoiseFloor(vo.InterWordGaps(words), probe, cfg)
  local spans = {
    { start = BURSTS[1][1], stop = BURSTS[1][2], kind = "match" },
    { start = BURSTS[2][1], stop = BURSTS[2][2], kind = "match" },
  }
  vo.ApplyPadding(spans, cfg, { start = 0, stop = TOTAL_S }, probe, floor, words)

  if spans[1].stop > spans[2].start + 1e-9 then
    error(string.format("clips overlap: %.3f > %.3f", spans[1].stop, spans[2].start))
  end
  for i, s in ipairs(spans) do
    if s.stop <= s.start then
      error(string.format("span %d is degenerate: %.3f..%.3f", i, s.start, s.stop))
    end
  end
  -- Neither edge may contain a sample of the other burst.
  if spans[1].stop >= BURSTS[2][1] then error("clip 1 reaches into word 2") end
  if spans[2].start <= BURSTS[1][2] then error("clip 2 reaches back into word 1") end
end)

test("an edge stops at a word the cut did not select", function()
  -- The second burst stands in for a false start nobody ticked: it is in the
  -- word list but not in the span list, and the edge must still respect it.
  local floor = vo.MeasureNoiseFloor(vo.InterWordGaps(words), probe, cfg)
  -- The word bound belongs to the snapping path; with no floor there is nothing
  -- to assert here, and a cascade from the floor test would read as a second,
  -- separate failure.
  if not floor then error("no floor measured — see the MeasureNoiseFloor failure") end
  local greedy = vo.ShallowCopy(cfg)
  greedy.pre_pad, greedy.post_pad = 1.0, 1.0   -- enough rope to reach it
  local spans = { { start = BURSTS[1][1], stop = BURSTS[1][2], kind = "match" } }
  vo.ApplyPadding(spans, greedy, { start = 0, stop = TOTAL_S }, probe, floor, words)
  if spans[1].stop > BURSTS[2][1] + 1e-9 then
    error(string.format("edge reached %.3f, into the unselected word at %.3f",
                        spans[1].stop, BURSTS[2][1]))
  end
end)

test("with snapping off both pads apply as fixed amounts", function()
  local off = vo.ShallowCopy(cfg)
  off.snap_boundaries = false
  local spans = { { start = 1.00, stop = 1.20, kind = "match" } }
  vo.ApplyPadding(spans, off, { start = 0, stop = TOTAL_S }, probe, -50.0)
  near(spans[1].start, 1.00 - vo.Opt(off, "pre_pad"),  1e-6, "unsnapped start")
  near(spans[1].stop,  1.20 + vo.Opt(off, "post_pad"), 1e-6, "unsnapped stop")
end)

destroy()

test("the accessor is destroyed without taking the take with it", function()
  if not r.ValidatePtr2(0, take, "MediaItem_Take*") then
    error("the take did not survive DestroyAudioAccessor")
  end
end)

--------------------------------
section("Transcript files on disk")

test("a transcript round-trips beside its audio", function()
  local ok, why = vo.WriteTranscript(wav_path, words, vo.TranscriptMeta(wav_path,
    { backend = "selftest", model = "none", language = "en" }))
  if not ok then error("write failed: " .. tostring(why)) end

  local parsed, reason = vo.ReadTranscript(wav_path)
  if not parsed then error("read failed: " .. tostring(reason)) end
  if #parsed.words ~= 2 then error("expected 2 words, got " .. #parsed.words) end
  near(parsed.words[1].t0, BURSTS[1][1], 1e-3, "first word start")
end)

test("a fresh transcript reads as current", function()
  local state = vo.TranscriptState(wav_path)
  if state ~= "yes" then error("expected yes, got " .. tostring(state)) end
end)

test("rewriting the audio at the same length reads as stale", function()
  -- The case a size check alone cannot catch: same byte count, different audio.
  -- Done on a COPY, because the fixture itself is open in the project and
  -- Windows will not hand out a write handle to a file REAPER is playing.
  local copy = scratch .. "/ajsfx_vo_selftest_copy.wav"
  local src = assert(io.open(wav_path, "rb"))
  local bytes = src:read("a"); src:close()
  local dst = assert(io.open(copy, "wb")); dst:write(bytes); dst:close()

  local ok, why = vo.WriteTranscript(copy, words, vo.TranscriptMeta(copy))
  if not ok then error("write failed: " .. tostring(why)) end
  if vo.TranscriptState(copy) ~= "yes" then error("the copy did not start current") end

  local f, err = io.open(copy, "r+b")
  if not f then error("cannot reopen the copy: " .. tostring(err)) end
  f:seek("set", 44)                       -- past the header, into the samples
  f:write(string.rep("\0", 2048))
  f:close()

  local state = vo.TranscriptState(copy)
  os.remove(vo.TranscriptPath(copy))
  os.remove(copy)
  if state ~= "stale" then error("expected stale, got " .. tostring(state)) end
end)

test("an unreadable transcript reports error rather than throwing", function()
  local tpath = vo.TranscriptPath(wav_path)
  local f = io.open(tpath, "w"); f:write("this is not a transcript\n"); f:close()
  local state, _, why = vo.TranscriptState(wav_path)
  if state ~= "error" then error("expected error, got " .. tostring(state)) end
  if type(why) ~= "string" then error("no reason given") end
  os.remove(tpath)
end)

--------------------------------
section("Cutting, tracks and undo")

local function item_count()
  return r.CountMediaItems(0)
end

test("EnsureTrackBelow creates the track once and reuses it after", function()
  local before = r.CountTracks(0)
  local a = vo.EnsureTrackBelow(track, "Selftest Dest")
  local mid = r.CountTracks(0)
  local b = vo.EnsureTrackBelow(track, "Selftest Dest")
  if mid ~= before + 1 then error("expected one new track, got " .. (mid - before)) end
  if r.CountTracks(0) ~= mid then error("the second call created another track") end
  if a ~= b then error("the second call returned a different track") end
end)

local cut_plan = {
  { start = 0.45, stop = 0.95, kind = "match", dest = "selects",
    name = "SELFTEST_first",  character = "" },
  { start = 1.35, stop = 1.85, kind = "match", dest = "selects",
    name = "SELFTEST_second", character = "" },
}

local before_cut = item_count()
local applied, failures

test("ApplyPlan cuts the plan inside one transaction", function()
  core.Transaction("VO selftest cut", function()
    applied, failures = vo.ApplyPlan(cut_plan, cfg, track)
  end)
  if applied ~= 2 then
    error(("applied %s of 2; failures: %s")
      :format(tostring(applied), table.concat(failures or {}, " | ")))
  end
end)

test("the cut produced the clips it said it did", function()
  if item_count() <= before_cut then
    error("item count did not grow: " .. item_count())
  end
  local found = {}
  for i = 0, item_count() - 1 do
    local it = r.GetMediaItem(0, i)
    local tk = r.GetActiveTake(it)
    if tk then
      local _, nm = r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
      found[nm] = true
    end
  end
  if not found.SELFTEST_first  then error("SELFTEST_first was not named") end
  if not found.SELFTEST_second then error("SELFTEST_second was not named") end
end)

test("the clips landed on the Selects track", function()
  local dest = nil
  for i = 0, r.CountTracks(0) - 1 do
    local t = r.GetTrack(0, i)
    local _, nm = r.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
    if nm == (cfg.track_selects or "Selects") then dest = t end
  end
  if not dest then error("no " .. tostring(cfg.track_selects) .. " track was created") end
  if r.CountTrackMediaItems(dest) ~= 2 then
    error("expected 2 items on the destination, got " .. r.CountTrackMediaItems(dest))
  end
end)

test("one undo puts the whole cut back", function()
  -- The reason core.Transaction exists. A cut that takes two undos to reverse
  -- is a cut the user cannot trust.
  r.Undo_DoUndo2(0)
  if item_count() ~= before_cut then
    error(string.format("expected %d items after one undo, got %d",
                        before_cut, item_count()))
  end
end)

--------------------------------
section("Sibling scripts are registered, not hardcoded")

test("every sibling script resolves to a real action id", function()
  local here = script_path .. "../../VO/"
  for _, name in ipairs({ "ajsfx_VO_Overview.lua", "ajsfx_VO_Sources.lua",
                          "ajsfx_VO_Cut.lua", "ajsfx_VO_Settings.lua" }) do
    if not vo.FileExists(here .. name) then error("missing script: " .. name) end
    -- Registers without running. Idempotent: an already-registered script
    -- returns its existing id rather than a duplicate.
    local id = r.AddRemoveReaScript(true, 0, here .. name, true)
    if not id or id == 0 then error("could not register " .. name) end
    local again = r.AddRemoveReaScript(true, 0, here .. name, true)
    if again ~= id then
      error(name .. " registered twice: " .. tostring(id) .. " vs " .. tostring(again))
    end
  end
end)

--------------------------------
-- Report
--------------------------------

say(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
say("Close this project tab WITHOUT saving.")

local f = io.open(log_path, "w")
if f then
  f:write(table.concat(lines, "\n"), "\n")
  f:close()
  r.ShowConsoleMsg("\nLog written to " .. log_path .. "\n")
end
