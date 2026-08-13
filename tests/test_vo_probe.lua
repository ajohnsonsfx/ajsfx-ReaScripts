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

-- The reaper table ajsfx_vo BOUND TO at require time. mock.reset() REPLACES the
-- global, so every later fresh_project() installs its API onto a table the
-- module never sees -- the module keeps working only because the first install's
-- closures read mock.tracks, which reset does refresh. A test that wants to
-- observe a call the module makes has to wrap this table, not the global.
local VOR = reaper

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
-- MakeTakeProfile: the batched form of probing window by window
--
-- The point of these is EQUIVALENCE. The profile replaced a loop that called
-- MakeTakeProbe once per 10ms window, which cost one buffer allocation and one
-- GetAudioAccessorSamples per window and stalled REAPER on a large selection.
-- Faster is only worth having if it decides the same edges, so the first test
-- compares the two directly rather than asserting the new one looks plausible.
--------------------------------
print("\nMakeTakeProfile (batched profiling):")

-- A source whose speech does NOT begin or end on a window boundary.
--
-- The shared fixture steps at exactly 2.0s and 29.0s, which are exact multiples
-- of the 10ms window: at such an instant the last sample of a window belongs to
-- neither side by any principled rule, and which side it lands on is decided by
-- the last bits of the float path that reached it. That makes it the wrong
-- fixture for asking "do these two ways of reading agree?" -- it asks "do two
-- float paths round the same way?", which is not a property worth having.
-- Off-grid edges are also what real speech has.
local function make_offgrid_source(path)
  return { path = path, length = SRC_LEN, rate = 1000, chans = 1,
           amp = function(t)
             if t >= 2.0034 and t <= 28.9967 then return 0.5 end
             return 0.0
           end }
end

-- The per-window loop TightenItems used to run, kept here as the reference.
local function profile_by_window(take, pos, len, step)
  local probe, destroy = vo.MakeTakeProbe(take)
  if not probe then return nil end
  local out = {}
  for k = 0, math.floor(len / step) - 1 do
    out[#out + 1] = probe(pos + k * step,
                          math.min(pos + (k + 1) * step, pos + len)) or -150.0
  end
  destroy()
  return out
end

-- THE claim. Faster is only worth having if it decides the same edge, and the
-- edge is what EffectiveRoom returns -- not the individual window values.
test("batched and per-window profiling agree on the head and tail room", function()
  local track = fresh_project()
  local src = make_offgrid_source(PATH)
  local was, was_stride = vo.PROFILE_MAX_FRAMES, vo.PROFILE_STRIDE
  vo.PROFILE_MAX_FRAMES = 64          -- 6 windows per block: cross many blocks
  vo.PROFILE_STRIDE = 1               -- against the loop, measure like the loop
  local item = make_audio_item(track, src, 600.0, 30.0, 0)

  local step = 0.010
  local ref = profile_by_window(item.take, 600.0, 30.0, step)
  local got = vo.MakeTakeProfile(item.take, 600.0, 600.0 + 30.0, step)
  vo.PROFILE_MAX_FRAMES, vo.PROFILE_STRIDE = was, was_stride

  assert(ref and #ref > 0, "reference profile is empty")
  assert(got, "no batched profile")
  assert(#got == #ref,
         string.format("window count: batched %d, per-window %d", #got, #ref))

  local function reversed(t)
    local out = {}
    for i = #t, 1, -1 do out[#out + 1] = t[i] end
    return out
  end
  local opts = { floor_db = -40.0 }
  assert(vo.EffectiveRoom(got, step, opts) == vo.EffectiveRoom(ref, step, opts),
         "head room differs between batched and per-window profiling")
  assert(vo.EffectiveRoom(reversed(got), step, opts)
         == vo.EffectiveRoom(reversed(ref), step, opts),
         "tail room differs between batched and per-window profiling")

  -- Values are NOT asserted equal, because the per-window loop was subtly
  -- wrong and the next test pins down how.
end)

-- The stride is the fix that actually made Auto-adjust fast (summing squares in
-- Lua was 84% of the profiling time, measured). It is only allowed to be fast
-- if it reaches the SAME EDGE, which is what this pins.
test("striding does not move the head or tail room", function()
  local track = fresh_project()
  local src = make_offgrid_source(PATH)
  local item = make_audio_item(track, src, 600.0, 30.0, 0)
  local step = 0.010
  local was = vo.PROFILE_STRIDE

  vo.PROFILE_STRIDE = 1
  local full = vo.MakeTakeProfile(item.take, 600.0, 630.0, step)
  local function reversed(t)
    local out = {}
    for i = #t, 1, -1 do out[#out + 1] = t[i] end
    return out
  end
  local opts = { floor_db = -40.0 }
  local head_full = vo.EffectiveRoom(full, step, opts)
  local tail_full = vo.EffectiveRoom(reversed(full), step, opts)

  for _, stride in ipairs({ 2, 4, 8 }) do
    vo.PROFILE_STRIDE = stride
    local w = vo.MakeTakeProfile(item.take, 600.0, 630.0, step)
    assert(w and #w == #full, "stride " .. stride .. " changed the window count")
    assert(vo.EffectiveRoom(w, step, opts) == head_full,
           "stride " .. stride .. " moved the head room")
    assert(vo.EffectiveRoom(reversed(w), step, opts) == tail_full,
           "stride " .. stride .. " moved the tail room")
  end
  vo.PROFILE_STRIDE = was
end)

test("a stride that does not divide the window still reports the right level", function()
  local track = fresh_project()
  -- Constant full-scale tone: RMS is 0.5 regardless of how it is sampled, so
  -- any error here is the DIVISOR, which is the bug worth guarding.
  local src = { path = PATH, length = SRC_LEN, rate = 1000, chans = 1,
                amp = function() return 0.5 end }
  local item = make_audio_item(track, src, 600.0, 10.0, 0)
  local was = vo.PROFILE_STRIDE
  vo.PROFILE_STRIDE = 3            -- 10-sample windows: 3 does not divide 10
  local w = vo.MakeTakeProfile(item.take, 600.0, 610.0, 0.010)
  vo.PROFILE_STRIDE = was
  assert(w and #w > 0, "no profile")
  local want = 20.0 * math.log(0.5, 10)
  for i = 1, #w do
    assert(math.abs(w[i] - want) < 1e-9, string.format(
      "window %d reads %.6f dB, expected %.6f -- the divisor is wrong",
      i, w[i], want))
  end
end)

-- Found by the equivalence test above rather than by reading the code, and
-- worth keeping: the loop this replaced measured some windows over one fewer
-- sample than the rest.
--
-- It sized each read as floor((t1 - t0) * rate) from two accumulated floats, so
-- a window whose width came out as 0.009999999999999787 instead of 0.01 was
-- read as 9 samples rather than 10 -- and since RMS divides by the count, that
-- window's dB was computed over a different denominator than its neighbours.
-- Silent, small, and entirely dependent on where in the item the window fell.
-- The batched profile fixes it by construction: the sample count per window is
-- decided ONCE, so every window is measured the same way.
test("every window is measured over the same number of samples", function()
  local track = fresh_project()
  local src = make_offgrid_source(PATH)
  local item = make_audio_item(track, src, 600.0, 30.0, 0)

  local counts = {}
  local real = VOR.GetAudioAccessorSamples
  VOR.GetAudioAccessorSamples = function(acc, rate, chans, t0, n, buf)
    counts[#counts + 1] = n
    return real(acc, rate, chans, t0, n, buf)
  end

  local step = 0.010
  -- One window per read, so each read's n IS a window's sample count.
  local was = vo.PROFILE_MAX_FRAMES
  vo.PROFILE_MAX_FRAMES = 10
  vo.MakeTakeProfile(item.take, 600.0, 630.0, step)
  vo.PROFILE_MAX_FRAMES = was

  local batched_counts = counts
  counts = {}
  profile_by_window(item.take, 600.0, 30.0, step)
  local loop_counts = counts
  VOR.GetAudioAccessorSamples = real

  local function tally(list)
    local seen = {}
    for _, n in ipairs(list) do seen[n] = (seen[n] or 0) + 1 end
    return seen
  end

  local batched = tally(batched_counts)
  assert(batched[10] and batched[10] == #batched_counts, string.format(
    "the batched profile read uneven window sizes: %d of %d were not 10",
    #batched_counts - (batched[10] or 0), #batched_counts))

  -- The wart itself, asserted so nobody "simplifies" the fix away: the old loop
  -- really did produce short reads on this input.
  local loop = tally(loop_counts)
  assert((loop[9] or 0) > 0 and (loop[10] or 0) > 0, string.format(
    "expected the per-window loop to mix 9- and 10-sample reads (got 9x%d, " ..
    "10x%d) -- if that is genuinely fixed, this test and the note above it " ..
    "can go", loop[9] or 0, loop[10] or 0))
end)

-- The values themselves. Not asserted equal: see the note on MakeTakeProfile --
-- this fixture steps from 0.5 to 0.0 at exactly 29.0s, and the two float paths
-- to that instant disagree on the last sample, which is a property of a
-- synthetic knife-edge rather than of the batching.
test("window values match everywhere except an exact amplitude discontinuity", function()
  local track = fresh_project()
  local src = make_source(PATH)          -- steps at exactly 2.0s and 29.0s
  local item = make_audio_item(track, src, 600.0, 30.0, 0)

  local step = 0.010
  local ref = profile_by_window(item.take, 600.0, 30.0, step)
  local got = vo.MakeTakeProfile(item.take, 600.0, 630.0, step)

  local differing, worst = 0, 0.0
  for i = 1, #ref do
    if got[i] ~= ref[i] then
      differing = differing + 1
      local d = math.abs(got[i] - ref[i])
      if d > worst then worst = d end
    end
  end
  assert(differing <= 2, string.format(
    "%d windows differ (expected at most the 2 discontinuities), worst %.4f dB",
    differing, worst))
end)

test("it reads far fewer times than the per-window loop", function()
  local track = fresh_project()
  local src = make_source(PATH)
  local item = make_audio_item(track, src, 600.0, 30.0, 0)

  local reads = 0
  local real = VOR.GetAudioAccessorSamples
  VOR.GetAudioAccessorSamples = function(...)
    reads = reads + 1
    return real(...)
  end

  local step = 0.010
  vo.MakeTakeProfile(item.take, 600.0, 630.0, step)
  local batched = reads
  reads = 0
  profile_by_window(item.take, 600.0, 30.0, step)
  local per_window = reads
  VOR.GetAudioAccessorSamples = real

  assert(per_window == 3000, "expected 3000 per-window reads, got " .. per_window)
  -- 65536-frame cap over 10-frame windows: every window fits in one block.
  assert(batched == 1, "expected a single batched read, got " .. batched)
end)

test("speech and silence still land where they did", function()
  local track = fresh_project()
  local src = make_source(PATH)          -- speech at 2..29s
  local item = make_audio_item(track, src, 0.0, SRC_LEN, 0)
  local w = vo.MakeTakeProfile(item.take, 0.0, SRC_LEN, 0.010)
  assert(w, "no profile")
  -- window index for source time t is floor(t / step)
  assert(w[math.floor(5.0 / 0.010) + 1] > -10.0, "speech reads silent")
  assert(w[math.floor(31.0 / 0.010) + 1] < -100.0, "silence reads hot")
end)

test("a zero-length or backwards range yields nothing rather than erroring", function()
  local track = fresh_project()
  local src = make_source(PATH)
  local item = make_audio_item(track, src, 600.0, 30.0, 0)
  assert(vo.MakeTakeProfile(item.take, 600.0, 600.0, 0.010) == nil, "zero length")
  assert(vo.MakeTakeProfile(item.take, 630.0, 600.0, 0.010) == nil, "backwards")
  assert(vo.MakeTakeProfile(item.take, 600.0, 630.0, 0) == nil, "zero step")
end)

test("the accessor is destroyed on every path, including the refusals", function()
  local track = fresh_project()
  local src = make_source(PATH)
  local item = make_audio_item(track, src, 600.0, 30.0, 0)

  local made, killed = 0, 0
  local mk, dk = VOR.CreateTakeAudioAccessor, VOR.DestroyAudioAccessor
  VOR.CreateTakeAudioAccessor = function(t) made = made + 1 return mk(t) end
  VOR.DestroyAudioAccessor = function(a) killed = killed + 1 return dk(a) end

  vo.MakeTakeProfile(item.take, 600.0, 630.0, 0.010)   -- succeeds
  vo.MakeTakeProfile(item.take, 600.0, 600.5, 1.0)     -- refuses: total < 1
  VOR.CreateTakeAudioAccessor, VOR.DestroyAudioAccessor = mk, dk

  assert(made == 2, "expected 2 accessors, got " .. made)
  assert(killed == made,
         string.format("leaked: %d created, %d destroyed", made, killed))
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
