-- Unit tests for the transcript gap-repair pure layer in VO/lib/ajsfx_vo.lua.
-- Run with: lua tests/test_vo_gap_repair.lua (from the repository root)
--
-- The failure mode under test: a slate ("Actor reading Character.") followed
-- by a pause at the head of a recording makes whisper emit a gap token that
-- swallows the rest of its first 30s window -- speech from ~1.4s to 30s is
-- never decoded although levels are normal. The repair re-runs whisper on the
-- suspect span with an offset and merges the recovered words back in.

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

local function near(a, b, tol)
  return math.abs(a - b) <= (tol or 0.1)
end

package.path = package.path .. ";VO/lib/?.lua;tests/?.lua"
local mock = require("mock_reaper")
mock.reset()
local vo = require("ajsfx_vo")

print("\n=== ajsfx_vo.lua Gap Repair Unit Tests ===\n")

--------------------------------
-- BuildWhisperArgv with a span
--------------------------------
print("BuildWhisperArgv span:")

local function has_flag(argv, flag)
  for i, v in ipairs(argv) do
    if v == flag then return i end
  end
  return nil
end

test("no span emits no -ot or -d", function()
  local argv = vo.BuildWhisperArgv({}, "in.wav", "out")
  assert(not has_flag(argv, "-ot"), "-ot present without a span")
  assert(not has_flag(argv, "-d"), "-d present without a span")
end)

test("a span becomes -ot and -d in whole milliseconds", function()
  local argv = vo.BuildWhisperArgv({}, "in.wav", "out", { from = 1.42, to = 29.5 })
  local ot = has_flag(argv, "-ot")
  local d  = has_flag(argv, "-d")
  assert(ot, "-ot missing")
  assert(d, "-d missing")
  assert(argv[ot + 1] == "1420", "offset ms: " .. tostring(argv[ot + 1]))
  assert(argv[d + 1] == "28080", "duration ms: " .. tostring(argv[d + 1]))
end)

test("a span never emits fractional milliseconds", function()
  local argv = vo.BuildWhisperArgv({}, "in.wav", "out", { from = 1.0 / 3.0, to = 2.0 / 3.0 })
  local ot = has_flag(argv, "-ot")
  local d  = has_flag(argv, "-d")
  assert(argv[ot + 1]:match("^%d+$"), "offset not integral: " .. argv[ot + 1])
  assert(argv[d + 1]:match("^%d+$"), "duration not integral: " .. argv[d + 1])
end)

--------------------------------
-- TranscriptGapSpans
--------------------------------
print("TranscriptGapSpans:")

test("contiguous words yield no gaps", function()
  local words = {
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 1.0, t1 = 2.0, text = "b" },
    { t0 = 2.0, t1 = 3.0, text = "c" },
  }
  local gaps = vo.TranscriptGapSpans(words, 3.0, {})
  assert(#gaps == 0, "expected 0 gaps, got " .. #gaps)
end)

test("the confirmed failure shape: one large gap between slate and window 2", function()
  local words = {
    { t0 = 0.2, t1 = 0.7, text = "Actor" },
    { t0 = 0.7, t1 = 1.4, text = "Character." },
    { t0 = 30.0, t1 = 30.4, text = "resumes" },
  }
  local gaps = vo.TranscriptGapSpans(words, 34.0, {})
  assert(#gaps == 1, "expected 1 gap, got " .. #gaps)
  assert(near(gaps[1].from, 1.4), "from: " .. gaps[1].from)
  assert(near(gaps[1].to, 30.0), "to: " .. gaps[1].to)
end)

test("a swallowed head is a gap from zero to the first word", function()
  local words = { { t0 = 12.0, t1 = 12.5, text = "late" } }
  local gaps = vo.TranscriptGapSpans(words, 20.0, {})
  assert(#gaps == 2, "expected head+tail gaps, got " .. #gaps)
  assert(near(gaps[1].from, 0.0) and near(gaps[1].to, 12.0),
         "head gap: " .. gaps[1].from .. ".." .. gaps[1].to)
end)

test("a swallowed tail is a gap from the last word to the duration", function()
  local words = { { t0 = 0.0, t1 = 10.0, text = "early" } }
  local gaps = vo.TranscriptGapSpans(words, 45.0, {})
  assert(#gaps == 1, "expected 1 gap, got " .. #gaps)
  assert(near(gaps[1].from, 10.0) and near(gaps[1].to, 45.0),
         "tail gap: " .. gaps[1].from .. ".." .. gaps[1].to)
end)

test("gaps under the threshold are not suspects", function()
  local words = {
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 4.0, t1 = 5.0, text = "b" },  -- 3s pause: an ordinary session pause
  }
  local gaps = vo.TranscriptGapSpans(words, 5.0, {})
  assert(#gaps == 0, "expected 0 gaps, got " .. #gaps)
end)

test("the threshold is configurable", function()
  local words = {
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 4.0, t1 = 5.0, text = "b" },
  }
  local gaps = vo.TranscriptGapSpans(words, 5.0, { gap_repair_min_gap = 2.0 })
  assert(#gaps == 1, "expected 1 gap at min_gap=2, got " .. #gaps)
end)

test("an empty transcript with a duration is one whole-file gap", function()
  local gaps = vo.TranscriptGapSpans({}, 36.0, {})
  assert(#gaps == 1, "expected 1 gap, got " .. #gaps)
  assert(near(gaps[1].from, 0.0) and near(gaps[1].to, 36.0))
end)

test("no duration means no head or tail gap can be known", function()
  local gaps = vo.TranscriptGapSpans({}, nil, {})
  assert(#gaps == 0, "expected 0 gaps, got " .. #gaps)
end)

--------------------------------
-- PlanGapRepairs
--------------------------------
print("PlanGapRepairs:")

-- Synthetic amplitude curve: speech-level inside [sfrom, sto], room tone
-- everywhere else. Matches the probe contract of vo.FindSpeechBounds.
local function speech_probe(sfrom, sto)
  return function(t0, t1)
    local mid = (t0 + t1) / 2
    if mid >= sfrom and mid <= sto then return -20.0 end
    return -70.0
  end
end

local FLOOR = -50.0

test("a gap holding speech-level audio becomes a repair span", function()
  local words = {
    { t0 = 0.7, t1 = 1.4, text = "Character." },
    { t0 = 30.0, t1 = 30.4, text = "resumes" },
  }
  local plans = vo.PlanGapRepairs(words, 36.0, FLOOR, speech_probe(2.0, 29.0), {})
  assert(#plans == 1, "expected 1 repair, got " .. #plans)
  -- Padded out from the measured speech bounds, clamped to the gap.
  assert(plans[1].from >= 1.4 - 1e-9, "repair reaches back into the slate: " .. plans[1].from)
  assert(plans[1].to <= 30.0 + 1e-9, "repair reaches into decoded words: " .. plans[1].to)
  assert(plans[1].from < 2.0, "no head pad before the speech: " .. plans[1].from)
  assert(plans[1].to > 29.0, "no tail pad after the speech: " .. plans[1].to)
end)

test("a genuinely silent gap is left alone", function()
  local words = {
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 20.0, t1 = 21.0, text = "b" },
  }
  local plans = vo.PlanGapRepairs(words, 21.0, FLOOR, speech_probe(-1, -1), {})
  assert(#plans == 0, "silent gap planned for repair")
end)

test("no floor means no repairs, not repairs everywhere", function()
  local words = {
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 20.0, t1 = 21.0, text = "b" },
  }
  local plans = vo.PlanGapRepairs(words, 21.0, nil, speech_probe(2, 19), {})
  assert(#plans == 0, "planned repairs without a floor")
end)

test("no probe means no repairs", function()
  local words = {
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 20.0, t1 = 21.0, text = "b" },
  }
  local plans = vo.PlanGapRepairs(words, 21.0, FLOOR, nil, {})
  assert(#plans == 0, "planned repairs without a probe")
end)

test("a blip shorter than the speech minimum is not a repair", function()
  local words = {
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 20.0, t1 = 21.0, text = "b" },
  }
  -- 0.3s of sound in a 19s gap: a chair creak, not a swallowed read.
  local plans = vo.PlanGapRepairs(words, 21.0, FLOOR, speech_probe(10.0, 10.3), {})
  assert(#plans == 0, "a blip was planned for repair")
end)

test("the whole-file gap of an empty transcript can be repaired", function()
  local plans = vo.PlanGapRepairs({}, 36.0, FLOOR, speech_probe(2.0, 34.0), {})
  assert(#plans == 1, "expected 1 repair, got " .. #plans)
  assert(plans[1].from >= 0 and plans[1].to <= 36.0)
end)

--------------------------------
-- MergeRepairWords
--------------------------------
print("MergeRepairWords:")

test("recovered words land between the words that survived, in time order", function()
  local words = {
    { t0 = 0.7, t1 = 1.4, text = "Character." },
    { t0 = 30.0, t1 = 30.4, text = "resumes" },
  }
  local repairs = {
    { span = { from = 1.65, to = 29.35 },
      words = {
        { t0 = 2.0, t1 = 2.4, text = "The" },
        { t0 = 2.4, t1 = 2.9, text = "Highland" },
      } },
  }
  local merged, added = vo.MergeRepairWords(words, repairs)
  assert(added == 2, "added: " .. tostring(added))
  assert(#merged == 4, "merged count: " .. #merged)
  assert(merged[1].text == "Character.", "order lost at 1: " .. merged[1].text)
  assert(merged[2].text == "The" and merged[3].text == "Highland", "repair words misplaced")
  assert(merged[4].text == "resumes", "order lost at 4: " .. merged[4].text)
end)

test("repair words outside their span are dropped, not merged", function()
  -- The guard for a whisper build whose -ot output turned out slice-relative:
  -- words that do not land inside the span they were meant to fill are wrong
  -- by construction and must not corrupt the transcript.
  local words = { { t0 = 0.7, t1 = 1.4, text = "Character." } }
  local repairs = {
    { span = { from = 1.65, to = 29.35 },
      words = {
        { t0 = 2.0, t1 = 2.4, text = "inside" },
        { t0 = 35.0, t1 = 35.5, text = "outside" },
      } },
  }
  local merged, added = vo.MergeRepairWords(words, repairs)
  assert(added == 1, "added: " .. tostring(added))
  for _, w in ipairs(merged) do
    assert(w.text ~= "outside", "out-of-span word merged")
  end
end)

test("no repairs returns the words unchanged", function()
  local words = { { t0 = 0.0, t1 = 1.0, text = "a" } }
  local merged, added = vo.MergeRepairWords(words, {})
  assert(added == 0 and #merged == 1 and merged[1].text == "a")
end)

test("original words are never removed by a merge", function()
  local words = {
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 10.0, t1 = 11.0, text = "b" },
  }
  local repairs = {
    { span = { from = 1.0, to = 10.0 },
      words = { { t0 = 5.0, t1 = 5.5, text = "mid" } } },
  }
  local merged = vo.MergeRepairWords(words, repairs)
  assert(#merged == 3, "expected 3 words, got " .. #merged)
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
