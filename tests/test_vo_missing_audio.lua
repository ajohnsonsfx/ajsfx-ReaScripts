-- Unit tests for vo.MergeRanges and vo.MissingAudioGaps.
-- Run with: lua tests/test_vo_missing_audio.lua (from the repository root)
--
-- The failure under test, measured in a real session: 8.19 seconds of source
-- holding two complete reads was covered by no item anywhere in the project.
-- Every stage of the tool scopes by item coverage, so nothing found the reads,
-- nothing reported them missing, and the only symptom was a line reading
-- "take 0/0 missing" with no button that would fix it. These two functions are
-- how the tool asks the recording what the timeline lost.

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
local vo = require("ajsfx_vo")

local function words(...)
  local out = {}
  for _, w in ipairs({ ... }) do
    out[#out + 1] = { t0 = w[1], t1 = w[2], text = w[3] }
  end
  return out
end

--------------------------------
print("\nMergeRanges:")
--------------------------------

test("overlapping ranges collapse into one", function()
  local m = vo.MergeRanges({ { from = 0, to = 5 }, { from = 3, to = 9 } })
  assert(#m == 1, "expected 1 range, got " .. #m)
  assert(m[1].from == 0 and m[1].to == 9, "wrong bounds")
end)

test("disjoint ranges stay apart and come back in time order", function()
  local m = vo.MergeRanges({ { from = 10, to = 12 }, { from = 0, to = 5 } })
  assert(#m == 2, "expected 2 ranges, got " .. #m)
  assert(m[1].from == 0 and m[2].from == 10, "not sorted")
end)

test("touching ranges join", function()
  local m = vo.MergeRanges({ { from = 0, to = 5 }, { from = 5, to = 8 } })
  assert(#m == 1 and m[1].to == 8, "touching ranges did not join")
end)

test("a zero-length range is dropped rather than merged", function()
  local m = vo.MergeRanges({ { from = 4, to = 4 }, { from = 0, to = 1 } })
  assert(#m == 1 and m[1].to == 1, "kept an empty range")
end)

--------------------------------
print("\nMissingAudioGaps:")
--------------------------------

test("a fully covered transcript reports nothing", function()
  local g = vo.MissingAudioGaps({ { from = 0, to = 10 } },
    words({ 1, 2, "a" }, { 2, 3, "b" }))
  assert(#g == 0, "invented a gap, got " .. #g)
end)

test("the real failure: two reads in an uncovered hole are found as one range",
function()
  -- The measured session, rounded: an item ends at 235.72 and the next begins
  -- at 243.91, with two complete reads in between.
  local g = vo.MissingAudioGaps(
    { { from = 231.26, to = 235.72 }, { from = 243.91, to = 245.86 } },
    words({ 231.20, 231.46, "I" }, { 231.46, 235.41, "am" },
          { 235.41, 239.68, "not" }, { 239.68, 243.90, "doing" }))
  assert(#g == 1, "expected 1 gap, got " .. #g)
  assert(g[1].count == 2, "expected 2 missing words, got " .. g[1].count)
  assert(g[1].text == "not doing", "wrong text: " .. tostring(g[1].text))
end)

test("padding is clamped to the covered audio either side, never overlapping",
function()
  local g = vo.MissingAudioGaps(
    { { from = 0, to = 10 }, { from = 12, to = 20 } },
    words({ 10.4, 11.6, "hello" }), 0.2, 5.0)  -- pad far wider than the hole
  assert(#g == 1, "expected 1 gap")
  assert(g[1].from == 10.0, "head crossed into covered audio: " .. g[1].from)
  assert(g[1].to == 12.0, "tail crossed into covered audio: " .. g[1].to)
end)

test("a word half covered by an item is present, not missing", function()
  -- 0.5 of this word is inside the item. The rule is "at least half", so it
  -- counts as held and must not drag a sliver of a restore out beside the clip.
  local g = vo.MissingAudioGaps({ { from = 0, to = 10.5 } },
    words({ 10.0, 11.0, "edge" }))
  assert(#g == 0, "restored a sliver beside a clip")
end)

test("a word barely clipped by a neighbour still reads as missing", function()
  local g = vo.MissingAudioGaps({ { from = 0, to = 10.1 } },
    words({ 10.0, 11.0, "edge" }))
  assert(#g == 1, "lost a read because a neighbour clipped its first 100ms")
end)

test("separate holes come back as separate ranges", function()
  local g = vo.MissingAudioGaps(
    { { from = 0, to = 5 }, { from = 10, to = 15 }, { from = 20, to = 25 } },
    words({ 6, 7, "one" }, { 16, 17, "two" }))
  assert(#g == 2, "expected 2 gaps, got " .. #g)
  assert(g[1].text == "one" and g[2].text == "two", "wrong grouping")
end)

test("a hole shorter than min_gap is not worth restoring", function()
  local g = vo.MissingAudioGaps(
    { { from = 0, to = 5 }, { from = 5.05, to = 10 } },
    words({ 5.0, 5.05, "uh" }), 0.20, 0.25)
  assert(#g == 0, "restored a 50ms crumb")
end)

test("silence with no words is never restored", function()
  -- A four-minute hole with nothing said in it is not a lost take, it is the
  -- session breathing. Restoring it would put an item over every pause.
  local g = vo.MissingAudioGaps({ { from = 0, to = 5 } }, words())
  assert(#g == 0, "restored audio nobody spoke in")
end)

test("no coverage at all restores everything that was said", function()
  local g = vo.MissingAudioGaps({}, words({ 1, 2, "a" }, { 2, 3, "b" }))
  assert(#g == 1 and g[1].count == 2, "an empty project restored nothing")
end)

--------------------------------
print("\nPlanSameAssetPrune:")
--------------------------------

local function mk(a, b, asset, id)
  return { start = a, stop = b, asset = asset, id = id }
end

test("the measured clip: two same-asset markers collapse to the longer", function()
  -- 0.385s and 1.875s, ADJACENT -- zero overlap, so the 80%-of-the-shorter
  -- dedupe correctly saw two takes and left both.
  local keep, drop = vo.PlanSameAssetPrune(
    { mk(844.200, 844.585, "Trying", "jj1"), mk(844.585, 846.460, "Trying", "jj8") },
    { from = 844.264, to = 846.460 })
  assert(#keep == 1 and keep[1].id == "jj8", "kept the wrong marker")
  assert(#drop == 1 and drop[1].id == "jj1", "dropped the wrong marker")
end)

test("two markers naming DIFFERENT lines are never pruned", function()
  local keep, drop = vo.PlanSameAssetPrune(
    { mk(0, 5, "LineA", "a1"), mk(5, 10, "LineB", "b1") }, { from = 0, to = 10 })
  assert(#keep == 2 and #drop == 0, "pruned an uncut recording")
end)

test("coverage decides, not marker length", function()
  local keep = vo.PlanSameAssetPrune(
    { mk(0, 20, "L", "long"), mk(20, 24, "L", "short") }, { from = 19.5, to = 24 })
  assert(#keep == 1 and keep[1].id == "short", "length beat coverage")
end)

test("markers with no asset are left alone", function()
  local keep = vo.PlanSameAssetPrune(
    { mk(0, 1, nil, nil), mk(2, 3, nil, nil) }, { from = 0, to = 3 })
  assert(#keep == 2, "pruned markers that name nothing")
end)

test("pruning twice keeps the same id, so marks survive a second press", function()
  local input = { mk(0, 1, "L", "a"), mk(1, 5, "L", "b") }
  local once = vo.PlanSameAssetPrune(input, { from = 0, to = 5 })
  local twice = vo.PlanSameAssetPrune(once, { from = 0, to = 5 })
  assert(#twice == 1 and twice[1].id == once[1].id, "not idempotent")
end)

test("three copies of one asset collapse to one", function()
  local keep, drop = vo.PlanSameAssetPrune(
    { mk(0, 1, "L", "a"), mk(1, 2, "L", "b"), mk(2, 9, "L", "c") },
    { from = 0, to = 9 })
  assert(#keep == 1 and keep[1].id == "c", "wrong survivor")
  assert(#drop == 2, "expected 2 dropped, got " .. #drop)
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
