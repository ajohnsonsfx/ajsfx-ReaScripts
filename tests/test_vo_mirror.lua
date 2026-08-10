-- Unit tests for vo.BestSpanForItem and vo.PlanMarkerMirror.
-- Run with: lua tests/test_vo_mirror.lua (from the repository root)
--
-- Two ideas under test. Mark selected item: "which line is this item?" is
-- answered by the match span the item's window covers most, with a floor
-- under the guess. Marker mirroring: the take map travels with the audio --
-- every item of a source carries the neighbouring takes' markers within
-- reach of its window, refreshed from the canonical (counting) copies, so
-- widening an item shows labelled takes instead of bare waveform.

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

print("\n=== ajsfx_vo.lua Mark-selected / Marker-mirror Unit Tests ===\n")

--------------------------------
-- BestSpanForItem
--------------------------------
print("BestSpanForItem:")

local SPANS = {
  { kind = "match",  start = 10.0, stop = 13.0, asset = "line_a" },
  { kind = "review", start = 14.0, stop = 16.0, asset = "line_b" },
  { kind = "chatter", start = 20.0, stop = 22.0, asset = "" },
}

test("an item holding one whole take answers that take at 1.0", function()
  local span, frac = vo.BestSpanForItem({ from = 9.8, to = 13.2 }, SPANS)
  assert(span and span.asset == "line_a", "wrong span")
  assert(math.abs(frac - 1.0) < 1e-9, "frac: " .. frac)
end)

test("an item over two takes answers the one it covers more of", function()
  -- covers 1.5s of line_a's 3s (0.5) and all 2s of line_b (1.0)
  local span, frac = vo.BestSpanForItem({ from = 11.5, to = 16.5 }, SPANS)
  assert(span and span.asset == "line_b", "wrong span: " .. tostring(span and span.asset))
  assert(frac > 0.99)
end)

test("half a take answers at 0.5 so a floor can refuse it", function()
  local span, frac = vo.BestSpanForItem({ from = 10.0, to = 11.5 }, SPANS)
  assert(span and span.asset == "line_a")
  assert(math.abs(frac - 0.5) < 1e-9, "frac: " .. frac)
end)

test("chatter is never an answer", function()
  local span = vo.BestSpanForItem({ from = 20.0, to = 22.0 }, SPANS)
  assert(span == nil, "matched chatter")
end)

test("an item touching no span answers nothing", function()
  local span, frac = vo.BestSpanForItem({ from = 30.0, to = 35.0 }, SPANS)
  assert(span == nil and frac == 0)
end)

--------------------------------
-- PlanMarkerMirror
--------------------------------
print("PlanMarkerMirror:")

-- Three cut items of one source; each holds only its own take's marker.
--   item 1: window 0..10,   take t1 at 2..5
--   item 2: window 10..20,  take t2 at 12..15
--   item 3: window 20..30,  take t3 at 22..25
local function tkm(pos, asset, id, length)
  return { pos = pos, name = vo.FormatMarkerName(asset, id), length = length }
end

local function three_items()
  return {
    { coverage = { from = 0,  to = 10 },
      markers = { tkm(2,  "line_a", "aa1", 3) }, info = { item = "i1" } },
    { coverage = { from = 10, to = 20 },
      markers = { tkm(12, "line_b", "bb2", 3) }, info = { item = "i2" } },
    { coverage = { from = 20, to = 30 },
      markers = { tkm(22, "line_c", "cc3", 3) }, info = { item = "i3" } },
  }
end

test("reach 0 with a clean session rewrites nothing", function()
  local rewrites, canon = vo.PlanMarkerMirror(three_items(), 0)
  assert(#rewrites == 0, "rewrote a clean session: " .. #rewrites)
  assert(canon == 3, "canonical: " .. canon)
end)

test("with reach, every item gains its neighbours' markers", function()
  local rewrites = vo.PlanMarkerMirror(three_items(), 30)
  assert(#rewrites == 3, "rewrites: " .. #rewrites)
  for _, rw in ipairs(rewrites) do
    assert(#rw.markers == 3, "item " .. rw.item_index ..
           " mirrors " .. #rw.markers .. " markers, wanted all 3")
  end
end)

test("reach bounds the mirror: a far take stays out", function()
  local rewrites = vo.PlanMarkerMirror(three_items(), 5)
  -- item 1 (0..10, reach to 15): sees t1, t2(12..15 intersects) not t3(22..25)
  local by_index = {}
  for _, rw in ipairs(rewrites) do by_index[rw.item_index] = rw end
  assert(by_index[1], "item 1 not rewritten")
  assert(#by_index[1].markers == 2, "item 1: " .. #by_index[1].markers)
  -- item 2 (10..20, reach 5..25): gains t3 (22..25 intersects), but NOT t1 --
  -- 2..5 merely touches the 5s edge, and touching is not intersecting.
  assert(by_index[2] and #by_index[2].markers == 2,
         "item 2: " .. (by_index[2] and #by_index[2].markers or -1))
end)

test("a second sync is a no-op: mirroring converges", function()
  local group = three_items()
  local rewrites = vo.PlanMarkerMirror(group, 30)
  for _, rw in ipairs(rewrites) do
    group[rw.item_index].markers = {}
    for _, m in ipairs(rw.markers) do
      group[rw.item_index].markers[#group[rw.item_index].markers + 1] =
        tkm(m.start, m.asset, m.id, m.stop - m.start)
    end
  end
  local again = vo.PlanMarkerMirror(group, 30)
  assert(#again == 0, "second sync still rewrites " .. #again .. " item(s)")
end)

test("a dragged counting copy wins over its stale mirrors", function()
  local group = three_items()
  -- Mirror t1 into item 2 (stale position), then drag the real t1 to 3..6.
  group[2].markers[#group[2].markers + 1] = tkm(2, "line_a", "aa1", 3)
  group[1].markers[1] = tkm(3, "line_a", "aa1", 3)
  local rewrites = vo.PlanMarkerMirror(group, 30)
  for _, rw in ipairs(rewrites) do
    for _, m in ipairs(rw.markers) do
      if m.id == "aa1" then
        assert(math.abs(m.start - 3) < 1e-9,
               "a stale mirror out-voted the visible copy: " .. m.start)
      end
    end
  end
end)

test("split residue -- the same id twice in one item -- collapses", function()
  local group = three_items()
  group[1].markers[#group[1].markers + 1] = tkm(2, "line_a", "aa1", 3)
  local rewrites = vo.PlanMarkerMirror(group, 0)
  local by_index = {}
  for _, rw in ipairs(rewrites) do by_index[rw.item_index] = rw end
  assert(by_index[1], "duplicate id survived")
  assert(#by_index[1].markers == 1, "markers: " .. #by_index[1].markers)
end)

test("reach 0 removes an off-window stray -- the old clean-stray", function()
  local group = three_items()
  -- A copy of t3 stranded on item 1, far outside its window.
  group[1].markers[#group[1].markers + 1] = tkm(22, "line_c", "cc3", 3)
  local rewrites = vo.PlanMarkerMirror(group, 0)
  local by_index = {}
  for _, rw in ipairs(rewrites) do by_index[rw.item_index] = rw end
  assert(by_index[1], "the stray survived")
  assert(#by_index[1].markers == 1)
  assert(by_index[1].markers[1].id == "aa1")
end)

test("items of an untouched source are not rewritten just for reach", function()
  -- One item, one take: nothing to mirror in, nothing stray. Any reach.
  local group = {
    { coverage = { from = 0, to = 10 },
      markers = { tkm(2, "line_a", "aa1", 3) }, info = { item = "i1" } },
  }
  assert(#vo.PlanMarkerMirror(group, 0) == 0)
  assert(#vo.PlanMarkerMirror(group, 60) == 0)
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
