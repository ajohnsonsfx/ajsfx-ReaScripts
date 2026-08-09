-- Unit tests for vo.MakeSourceProbe's cut-session fallback.
-- Run with: lua tests/test_vo_probe.lua (from the repository root)
--
-- The failure under test: take audio accessors are bounded by their item, so
-- probing a source through the first clip that references it reads silence
-- everywhere outside that clip's little window. On a session already cut into
-- clips, gap repair measured "no speech" in a 28-second hole full of takes and
-- silently repaired nothing. The fix probes through an item that shows the
-- WHOLE file -- and builds a temporary full-length one when no such item
-- exists.

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    print("  FAIL: " .. name .. " - " .. tostring(err))
  end
end

package.path = package.path .. ";VO/lib/?.lua;tests/?.lua"
local mock = require("mock_reaper")
mock.reset()

--------------------------------
-- A small audio-capable project model on top of the base mock
--------------------------------

local SRC_LEN = 36.0
-- Speech sits at 2..29s of the source; room silence everywhere else.
local function amp_at(t)
  if t >= 2.0 and t <= 29.0 then return 0.5 end
  return 0.0
end

local function make_source(path, length)
  return { path = path, length = length or SRC_LEN, rate = 1000, chans = 1,
           amp = amp_at }
end

-- item covering source [offs, offs+len) at project position pos
local function make_audio_item(track, source, pos, len, offs)
  local item = { info = { D_POSITION = pos, D_LENGTH = len }, track = track }
  item.take = { info = { D_STARTOFFS = offs or 0, D_PLAYRATE = 1.0 },
                source = source, item = item }
  track.items = track.items or {}
  track.items[#track.items + 1] = item
  return item
end

local function install_audio_api()
  local rp = reaper
  rp.TakeIsMIDI = function(take) return false end
  rp.GetMediaSourceFileName = function(source) return source and source.path or "" end
  rp.GetMediaSourceLength = function(source) return source and source.length or 0 end
  rp.GetMediaSourceSampleRate = function(source) return source and source.rate or 1000 end
  rp.GetMediaSourceNumChannels = function(source) return source and source.chans or 1 end
  rp.GetMediaItemTake_Item = function(take) return take and take.item end
  rp.CountMediaItems = function()
    local n = 0
    for _, t in ipairs(mock.tracks) do n = n + #(t.items or {}) end
    return n
  end
  rp.GetMediaItem = function(proj, i)
    local k = -1
    for _, t in ipairs(mock.tracks) do
      for _, it in ipairs(t.items or {}) do
        k = k + 1
        if k == i then return it end
      end
    end
    return nil
  end
  rp.new_array = function(n)
    local t = { n = n }
    for i = 1, n do t[i] = 0.0 end
    t.clear = function() for i = 1, n do t[i] = 0.0 end end
    return t
  end
  rp.CreateTakeAudioAccessor = function(take) return { take = take } end
  rp.DestroyAudioAccessor = function(acc) end
  rp.GetAudioAccessorSamples = function(acc, rate, chans, t0, n, buf)
    local take = acc.take
    local item = take.item
    local len  = item.info.D_LENGTH or 0
    local offs = (take.info and take.info.D_STARTOFFS) or 0
    local src  = take.source
    for i = 0, n - 1 do
      local t = t0 + i / rate            -- take-relative time
      local v = 0.0
      if t >= 0 and t <= len and src and src.amp then
        v = src.amp(offs + t)            -- playrate 1.0 in these tests
      end
      buf[i * chans + 1] = v
    end
    return 1
  end
  rp.AddMediaItemToTrack = function(track)
    local item = { info = {}, track = track }
    track.items = track.items or {}
    track.items[#track.items + 1] = item
    return item
  end
  rp.AddTakeToMediaItem = function(item)
    item.take = { info = {}, item = item }
    return item.take
  end
  rp.SetMediaItemTake_Source = function(take, source) take.source = source end
  rp.PCM_Source_CreateFromFile = function(path)
    if mock.pcm_sources and mock.pcm_sources[path] then
      return mock.pcm_sources[path]
    end
    return nil
  end
  rp.DeleteTrack = function(track)
    for i, t in ipairs(mock.tracks) do
      if t == track then table.remove(mock.tracks, i) return end
    end
  end
end

local function fresh_project()
  mock.reset()
  install_audio_api()
  mock.pcm_sources = {}
  local track = { info = {}, items = {}, name = "rec" }
  mock.tracks[1] = track
  return track
end

local vo = (function()
  fresh_project()
  return require("ajsfx_vo")
end)()

local PATH = "X:/session/read.wav"

print("\n=== ajsfx_vo.lua MakeSourceProbe Unit Tests ===\n")

test("a full-length item probes in place, with no temporary track", function()
  local track = fresh_project()
  local src = make_source(PATH)
  make_audio_item(track, src, 600.0, SRC_LEN, 0)
  local before = #mock.tracks

  local probe, destroy, duration = vo.MakeSourceProbe(PATH)
  assert(probe, "no probe")
  assert(#mock.tracks == before, "a temp track was created needlessly")
  assert(math.abs(duration - SRC_LEN) < 1e-6, "duration: " .. tostring(duration))
  assert(probe(5.0, 6.0) > -10.0, "speech reads silent through a covering item")
  assert(probe(30.0, 31.0) < -100.0, "silence reads hot")
  destroy()
  assert(#mock.tracks == before, "destroy changed the track count")
end)

test("a session cut into clips probes through a temporary full-length item", function()
  local track = fresh_project()
  local src = make_source(PATH)
  -- Clips only: one shows 10..12s, another 20..23s. No item shows 2..9s.
  make_audio_item(track, src, 600.0, 2.0, 10.0)
  make_audio_item(track, src, 650.0, 3.0, 20.0)
  mock.pcm_sources[PATH] = src
  local before = #mock.tracks

  local probe, destroy, duration = vo.MakeSourceProbe(PATH)
  assert(probe, "no probe on a cut session")
  assert(math.abs(duration - SRC_LEN) < 1e-6, "duration: " .. tostring(duration))
  -- 5..6s is inside NO clip. The old code read this as silence.
  assert(probe(5.0, 6.0) > -10.0,
         "speech outside every clip reads silent -- the bounded-accessor bug")
  assert(probe(31.0, 32.0) < -100.0, "silence reads hot")
  destroy()
  assert(#mock.tracks == before, "the temporary track leaked")
end)

test("an item trimmed at the head does not count as covering", function()
  local track = fresh_project()
  local src = make_source(PATH)
  -- Starts 5s into the source: everything before 5s is unreachable through it.
  make_audio_item(track, src, 600.0, SRC_LEN - 5.0, 5.0)
  mock.pcm_sources[PATH] = src

  local probe, destroy = vo.MakeSourceProbe(PATH)
  assert(probe, "no probe")
  assert(probe(2.5, 3.5) > -10.0, "the trimmed-off head reads silent")
  destroy()
end)

test("an unreadable file yields no probe and leaks nothing", function()
  local track = fresh_project()
  local src = make_source(PATH)
  make_audio_item(track, src, 600.0, 2.0, 10.0)
  -- No pcm_sources entry: PCM_Source_CreateFromFile returns nil.
  local before = #mock.tracks

  local probe, destroy, duration = vo.MakeSourceProbe(PATH)
  assert(probe == nil, "probe from nothing")
  assert(type(destroy) == "function")
  destroy()
  assert(#mock.tracks == before, "a track leaked on the failure path")
end)

--------------------------------
-- RepairTranscriptGaps must SAY when it could not check a hole
--------------------------------
print("RepairTranscriptGaps reporting:")

test("an uncheckable transcript hole is reported, not silently skipped", function()
  fresh_project()  -- no items reference PATH, no pcm source: no probe possible
  local words = {
    { t0 = 0.7, t1 = 1.4, text = "Character." },
    { t0 = 30.0, t1 = 30.4, text = "resumes" },
  }
  local got_words, got_report
  vo.RepairTranscriptGaps({}, PATH, "/tmp", "/tmp/x", words,
    function(w, rep) got_words, got_report = w, rep end,
    function() end)
  assert(got_words == words, "words were changed with no probe")
  assert(got_report, "no report for an uncheckable hole")
  assert(#(got_report.notes or {}) >= 1, "no note in the report")
  assert(tostring(got_report.notes[1]):find("could not be checked"),
         "note does not say why: " .. tostring(got_report.notes[1]))
end)

test("a transcript with no suspicious holes still reports nothing", function()
  fresh_project()
  local words = {
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 1.0, t1 = 2.0, text = "b" },
  }
  local got_report = "unset"
  vo.RepairTranscriptGaps({}, PATH, "/tmp", "/tmp/x", words,
    function(w, rep) got_report = rep end,
    function() end)
  assert(got_report == nil, "invented a report with nothing to say")
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
