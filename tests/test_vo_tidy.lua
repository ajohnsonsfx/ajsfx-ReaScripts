-- Unit tests for vo.LineKey and vo.SelectConflicts -- the pure layer behind
-- the Sheet tab's "Match transcript to script" (SPEC-toolbar.md).

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

print("\n=== ajsfx_vo.lua Tidy Unit Tests ===\n")

print("SelectConflicts:")

test("two selects on one line is one conflict carrying the count", function()
  local rows = {
    { script_row = "s1", asset = "line_a", deliver = "line_a", user_select = true },
    { script_row = "s1", asset = "line_a", deliver = "line_a", user_select = true },
    { script_row = "s2", asset = "line_b", deliver = "line_b", user_select = true },
  }
  local c = vo.SelectConflicts(rows)
  assert(#c == 1, "expected 1 conflict, got " .. #c)
  assert(c[1].count == 2, "count: " .. tostring(c[1].count))
  assert(c[1].key == "s1", "key: " .. tostring(c[1].key))
  assert(c[1].label == "line_a", "label: " .. tostring(c[1].label))
end)

test("one select per line is no conflict", function()
  local rows = {
    { script_row = "s1", asset = "line_a", user_select = true },
    { script_row = "s1", asset = "line_a", user_select = false },
  }
  assert(#vo.SelectConflicts(rows) == 0)
end)

test("orphan rows never conflict, even sharing a key", function()
  local rows = {
    { asset = "line_a", status = "orphan", user_select = true },
    { asset = "line_a", status = "orphan", user_select = true },
  }
  assert(#vo.SelectConflicts(rows) == 0)
end)

test("rows with no script_row group by asset", function()
  local rows = {
    { asset = "line_a", user_select = true },
    { asset = "line_a", user_select = true },
  }
  local c = vo.SelectConflicts(rows)
  assert(#c == 1 and c[1].key == "asset:line_a", "key: " .. tostring(c[1] and c[1].key))
end)

print("\nResolveScope:")

-- Three takes of one recording, before Cut: every row's item is the SAME
-- recording item, because no take has an item of its own yet.
local REC = "recording_item"
local function uncut()
  return {
    { uid = "u1", item = REC, asset = "a" },
    { uid = "u2", item = REC, asset = "b" },
    { uid = "u3", item = REC, asset = "c" },
  }
end

-- After Cut: one take, one item.
local function cut()
  return {
    { uid = "u1", item = "i1", asset = "a" },
    { uid = "u2", item = "i2", asset = "b" },
    { uid = "u3", item = "i3", asset = "c" },
  }
end

test("nothing selected acts on everything in view", function()
  local rows, narrowed = vo.ResolveScope(cut(), {}, {})
  assert(#rows == 3, "expected 3, got " .. #rows)
  assert(narrowed == false, "reported as narrowed with no selection")
end)

test("a selected row narrows to that take", function()
  local rows, narrowed = vo.ResolveScope(cut(), { u2 = true }, {})
  assert(#rows == 1 and rows[1].asset == "b", "wrong row")
  assert(narrowed == true, "not reported as narrowed")
end)

test("after Cut, selecting an item is selecting its take", function()
  local rows = vo.ResolveScope(cut(), {}, { i3 = true })
  assert(#rows == 1 and rows[1].asset == "c", "wrong row")
end)

test("before Cut, selecting the recording selects every take in it", function()
  -- The asymmetry the whole rule exists for: one item, many takes. Selecting
  -- the recording and pressing Cut has to mean "cut all of these".
  local rows = vo.ResolveScope(uncut(), {}, { [REC] = true })
  assert(#rows == 3, "expected all 3 takes of the recording, got " .. #rows)
end)

test("the two selections union rather than one winning", function()
  local rows = vo.ResolveScope(cut(), { u1 = true }, { i3 = true })
  assert(#rows == 2, "expected 2, got " .. #rows)
  assert(rows[1].asset == "a" and rows[2].asset == "c", "wrong pair")
end)

test("a row selected both ways is counted once", function()
  local rows = vo.ResolveScope(cut(), { u2 = true }, { i2 = true })
  assert(#rows == 1, "duplicated a row selected both ways: " .. #rows)
end)

test("a selection matching nothing in view never widens to everything", function()
  -- The row picked is filtered out of `rows`. Acting on all three because the
  -- one you chose is hidden is the worst available answer.
  local rows, narrowed = vo.ResolveScope(cut(), { u_hidden = true }, {})
  assert(#rows == 0, "silently widened to " .. #rows .. " rows")
  assert(narrowed == true, "an empty scope must still read as narrowed")
end)

test("a row with no item is reachable only by its own selection", function()
  local rows = { { uid = "u1", asset = "a" } }   -- a line with no audio yet
  assert(#vo.ResolveScope(rows, {}, { i1 = true }) == 0, "matched with no item")
  assert(#vo.ResolveScope(rows, { u1 = true }, {}) == 1, "unreachable by uid")
end)

test("nil selections are the same as empty ones", function()
  local rows, narrowed = vo.ResolveScope(cut(), nil, nil)
  assert(#rows == 3 and narrowed == false, "nil selections narrowed the scope")
end)

print("\nPlanItemIdentity:")

local function span(start, stop, asset, marked)
  return { start = start, stop = stop, asset = asset,
           deliver = asset, marked = marked or nil }
end

local function plan_of(items, opts)
  local plans, counts = vo.PlanItemIdentity(items, opts)
  return plans[1], counts
end

test("a clip holding one take is that take, marked at its own edges", function()
  -- The user's hand-trimmed edges are the truth, so the marker spans the ITEM,
  -- not the span the matcher found inside it.
  local p = plan_of({ { key = "i1", from = 10, to = 20,
                        spans = { span(11, 19, "line_a") } } })
  assert(p.kind == "one", "kind: " .. tostring(p.kind))
  assert(p.name == "line_a", "not named for its line")
  assert(#p.markers == 1, "markers: " .. #p.markers)
  assert(p.markers[1].start == 10 and p.markers[1].stop == 20,
    "marker did not span the item: " .. p.markers[1].start .. ".." .. p.markers[1].stop)
end)

test("a recording holding several takes gets one marker per take", function()
  local p = plan_of({ { key = "rec", from = 0, to = 100,
                        spans = { span(1, 5, "a"), span(10, 14, "b"),
                                  span(20, 24, "c") } } })
  assert(p.kind == "many", "kind: " .. tostring(p.kind))
  assert(#p.markers == 3, "markers: " .. #p.markers)
  assert(p.markers[1].start == 1 and p.markers[1].stop == 5,
    "marker did not use the span's own bounds")
end)

test("an item holding several takes is never renamed", function()
  -- It cannot be: an item holding four lines has no one line to be named for.
  local p = plan_of({ { key = "rec", from = 0, to = 100,
                        spans = { span(1, 5, "a"), span(10, 14, "b") } } })
  assert(p.name == nil, "named a multi-take item " .. tostring(p.name))
end)

test("a take barely clipped by the item does not make it multi-take", function()
  -- A clip holding one take plus the tail of the previous one is ONE take.
  -- 20% of the neighbour is under the 35% floor, so it does not count.
  local p = plan_of({ { key = "i1", from = 10, to = 20,
                        spans = { span(8, 10.4, "prev"), span(11, 19, "mine") } } })
  assert(p.kind == "one", "kind: " .. tostring(p.kind))
  assert(p.name == "mine", "named after the neighbour: " .. tostring(p.name))
end)

test("two whole takes in one item is many, not one", function()
  local p = plan_of({ { key = "i1", from = 0, to = 20,
                        spans = { span(1, 5, "a"), span(10, 15, "b") } } })
  assert(p.kind == "many", "kind: " .. tostring(p.kind))
end)

test("an item nothing matched is reported, not guessed at", function()
  local p, counts = plan_of({ { key = "i1", from = 0, to = 5, spans = {} } })
  assert(p.kind == "none" and #p.markers == 0, "invented a marker")
  assert(counts.none == 1, "not counted")
end)

test("an already-marked take is still named, but not re-marked", function()
  -- This is what "adopt an existing session" was a separate button for:
  -- re-running has to be able to name without writing markers again.
  local p = plan_of({ { key = "i1", from = 10, to = 20,
                        spans = { span(11, 19, "line_a", true) } } })
  assert(p.kind == "one", "kind: " .. tostring(p.kind))
  assert(p.name == "line_a", "an already-marked take lost its name")
  assert(#p.markers == 0, "re-marked an already-marked take")
end)

test("marked spans do not change one-vs-many", function()
  -- 399 of 400 takes already marked must NOT read as a single-take item and
  -- rename the whole recording after one line.
  local spans = {}
  for i = 1, 10 do spans[i] = span(i * 10, i * 10 + 5, "a" .. i, i > 1) end
  local p = plan_of({ { key = "rec", from = 0, to = 200, spans = spans } })
  assert(p.kind == "many", "kind: " .. tostring(p.kind))
  assert(p.name == nil, "renamed a recording after one of its takes")
  assert(#p.markers == 1, "re-marked takes that already had markers: " .. #p.markers)
end)

test("a zero-length item matches nothing", function()
  local p = plan_of({ { key = "i1", from = 5, to = 5,
                        spans = { span(1, 9, "a") } } })
  assert(p.kind == "none", "kind: " .. tostring(p.kind))
end)

test("counts total the items, and no items is not an error", function()
  local _, counts = vo.PlanItemIdentity({
    { key = "a", from = 0, to = 10, spans = { span(1, 9, "x") } },
    { key = "b", from = 0, to = 10, spans = { span(1, 3, "y"), span(5, 9, "z") } },
    { key = "c", from = 0, to = 10, spans = {} },
  })
  assert(counts.one == 1 and counts.many == 1 and counts.none == 1,
    string.format("one=%d many=%d none=%d", counts.one, counts.many, counts.none))
  local plans, empty = vo.PlanItemIdentity(nil)
  assert(#plans == 0 and empty.one == 0, "nil items errored")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
