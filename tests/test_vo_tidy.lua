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

test("one ticked + one parked on Selects = contested (the originating bug)", function()
  local rows = {
    { script_row = "s1", asset = "line_a", deliver = "line_a",
      user_select = true, track_name = "Alts" },
    { script_row = "s1", asset = "line_a", deliver = "line_a",
      track_name = "Selects" },
  }
  local c = vo.SelectConflicts(rows)
  assert(#c == 1, "expected 1 conflict, got " .. #c)
  assert(c[1].count == 2, "count: " .. tostring(c[1].count))
  assert(#c[1].claimants == 2, "claimants ride the entry")
end)

test("one ticked + one on Alts = not contested", function()
  local rows = {
    { script_row = "s1", asset = "line_a", user_select = true, track_name = "Selects" },
    { script_row = "s1", asset = "line_a", track_name = "Alts" },
  }
  assert(#vo.SelectConflicts(rows) == 0)
end)

test("custom Selects track name honoured through cfg", function()
  local rows = {
    { script_row = "s1", asset = "line_a", track_name = "MyPicks" },
    { script_row = "s1", asset = "line_a", track_name = "MyPicks" },
  }
  assert(#vo.SelectConflicts(rows) == 0, "default cfg: MyPicks is not Selects")
  local c = vo.SelectConflicts(rows, { track_selects = "MyPicks" })
  assert(#c == 1, "cfg names the track: contested")
end)

test("missing rows never claim", function()
  local rows = {
    { script_row = "s1", asset = "line_a", user_select = true, track_name = "Selects" },
    { script_row = "s1", asset = "line_a", status = "missing", track_name = "Selects" },
  }
  assert(#vo.SelectConflicts(rows) == 0)
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

test("nothing selected acts on NOTHING, never on everything", function()
  -- The old rule was "no selection means everything in view", and the
  -- difference between a three-take run and a whole-session run was whether a
  -- click had landed. A verb with an empty scope is a no-op you can see
  -- coming; one quietly acting on 169 lines is not.
  local rows, picked = vo.ResolveScope(cut(), {}, {})
  assert(#rows == 0, "widened to " .. #rows .. " rows with nothing selected")
  assert(picked == false, "reported a selection where there is none")
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
  local rows, picked = vo.ResolveScope(cut(), nil, nil)
  assert(#rows == 0 and picked == false, "nil selections acted on something")
end)

test("an empty scope and a hidden selection are told apart", function()
  -- Both give zero rows and they need different words on screen: one says
  -- "select something", the other says "the filters are hiding it".
  local _, none = vo.ResolveScope(cut(), {}, {})
  local hidden_rows, hidden = vo.ResolveScope(cut(), { u_hidden = true }, {})
  assert(none == false, "nothing selected must report picked=false")
  assert(hidden == true and #hidden_rows == 0,
         "a hidden selection must report picked=true with no rows")
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

print("\nBestOverlap:")

test("a marker pairs with its span even though neither edge matches", function()
  -- The bug this exists for: a marker is written at the CUT's edges -- speech
  -- bounds, padded, snapped -- and the span is the matcher's raw whisper
  -- bounds, so they never share a start. Identify compared starts, decided no
  -- take was marked, and minted a second marker for every take on every press
  -- while keeping the first. The item's markers doubled per run.
  local markers = { { start = 0.94, stop = 5.40 }, { start = 9.88, stop = 14.6 } }
  assert(vo.BestOverlap(markers, { start = 1.00, stop = 5.00 }) == 1,
    "a padded marker did not pair with its own span")
  assert(vo.BestOverlap(markers, { start = 10.0, stop = 14.0 }) == 2, "wrong marker")
end)

test("a take with no marker of its own claims nobody else's", function()
  local markers = { { start = 0.94, stop = 5.40 } }
  assert(vo.BestOverlap(markers, { start = 20.0, stop = 24.0 }) == nil,
    "claimed a marker nowhere near it")
  -- Touching is not overlapping: a take starting where the last marker ends
  -- is the NEXT take.
  assert(vo.BestOverlap(markers, { start = 5.40, stop = 9.0 }) == nil,
    "claimed the marker it merely abuts")
  -- A sliver of overlap is a neighbour bleeding, not the same take.
  assert(vo.BestOverlap(markers, { start = 5.20, stop = 9.0 }) == nil,
    "a 200ms clip of overlap counted as the same take")
end)

test("a recording's own marker cannot swallow a take inside it", function()
  -- Measured against the SHORTER of the two: the long marker covers the short
  -- span completely, but the short span covers almost none of the marker.
  -- Sharing "most of the shorter one" is the honest test, and here it holds --
  -- what must NOT happen is the reverse pairing being ambiguous.
  local long_marker = { { start = 0.0, stop = 100.0 } }
  assert(vo.BestOverlap(long_marker, { start = 10.0, stop = 14.0 }) == 1,
    "a take wholly inside a marker did not pair with it")
  assert(vo.BestOverlap({ { start = 10.0, stop = 14.0 } },
                        { start = 0.0, stop = 100.0 }) == 1,
    "the pairing is not symmetric")
end)

test("a degenerate range never wins a span", function()
  -- Overview zeroes a claimed marker's range so it cannot be claimed twice.
  assert(vo.BestOverlap({ { start = 0, stop = 0 } }, { start = 0.0, stop = 5.0 }) == nil,
    "a zero-width range claimed a take")
  assert(vo.BestOverlap(nil, { start = 0, stop = 1 }) == nil, "nil ranges errored")
  assert(vo.BestOverlap({ { start = 0, stop = 1 } }, nil) == nil, "nil span errored")
end)

print("\nPlanItemIdentity (replace):")

test("replace re-marks the takes an ordinary run skips", function()
  -- Without this a session identified once is frozen: every span reads as
  -- marked, every plan comes back empty, and a boundary setting can never
  -- reach the timeline however far it is dragged.
  local spans = { span(1, 5, "a", true), span(10, 14, "b", true),
                  span(20, 24, "c") }
  local item = { { key = "rec", from = 0, to = 100, spans = spans } }
  assert(#plan_of(item).markers == 1, "an ordinary run re-marked marked takes")
  local p = plan_of(item, { replace = true })
  assert(#p.markers == 3, "replace skipped marked takes: " .. #p.markers)
  assert(p.markers[1].redo == true and p.markers[3].redo == nil,
    "redo does not distinguish an existing marker from a new one")
end)

test("replace leaves a single-take item on the user's own edges", function()
  -- The item IS the take there, and its edges are the user's trim, not the
  -- tool's padding pass -- so there is nothing for a boundary setting to move.
  local p = plan_of({ { key = "i1", from = 10, to = 20,
                        spans = { span(11, 19, "line_a", true) } } },
                    { replace = true })
  assert(p.kind == "one" and #p.markers == 0,
    "re-placed a marker at edges the tool does not own")
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

print("\nPlanUpdatePass:")

-- The routing behind Update from Item / Update from Marker. `n` markers, `s`
-- spans inside the item.
local function items(list)
  local out = {}
  for _, it in ipairs(list) do
    out[#out + 1] = { key = it[1], marker_count = it[2], span_count = it[3] }
  end
  return out
end

test("one marker is the pair to act on, either direction", function()
  local one = items({ { "i1", 1, 0 } })
  for _, dir in ipairs({ "item", "marker" }) do
    local p = vo.PlanUpdatePass(one, dir)
    assert(#p.act == 1 and p.act[1] == "i1", dir .. ": act=" .. #p.act)
    assert(#p.several == 0 and #p.identify == 0, dir .. ": routed elsewhere too")
  end
end)

test("several markers is a recording, refused by both directions", function()
  -- The test that matters most: an uncut recording holds one marker per take,
  -- and neither button may touch it.
  local rec = items({ { "i1", 5, 5 } })
  for _, dir in ipairs({ "item", "marker" }) do
    local p = vo.PlanUpdatePass(rec, dir)
    assert(#p.several == 1 and p.several[1] == "i1", dir .. ": not refused")
    assert(#p.act == 0 and #p.identify == 0, dir .. ": acted on a recording")
  end
end)

test("no marker but audio the matcher knows is identified, not refused", function()
  -- The marker was never written, or was deleted. That is not a bad match and
  -- the score is not consulted.
  local p = vo.PlanUpdatePass(items({ { "i1", 0, 1 } }), "item")
  assert(#p.identify == 1 and p.identify[1] == "i1", "identify=" .. #p.identify)
  assert(#p.unmatched == 0, "reported as unmatched")
end)

test("no marker and no span reports rather than guessing", function()
  local p = vo.PlanUpdatePass(items({ { "i1", 0, 0 } }), "item")
  assert(#p.unmatched == 1 and p.unmatched[1] == "i1", "unmatched=" .. #p.unmatched)
  assert(#p.identify == 0, "identified audio matching no line")
end)

test("from Marker, a marker-less item has no authority to update from", function()
  -- The one row where the two directions differ: Update from Item would mark
  -- it, Update from Marker has nothing to read.
  local p = vo.PlanUpdatePass(items({ { "i1", 0, 3 } }), "marker")
  assert(#p.nomarker == 1 and p.nomarker[1] == "i1", "nomarker=" .. #p.nomarker)
  assert(#p.identify == 0, "Update from Marker identified an item")
end)

test("a mixed scope routes every item exactly once", function()
  local p = vo.PlanUpdatePass(items({
    { "take",   1, 1 },
    { "rec",    4, 4 },
    { "bare",   0, 1 },
    { "silent", 0, 0 },
  }), "item")
  assert(#p.act == 1 and #p.several == 1 and #p.identify == 1
         and #p.unmatched == 1 and #p.nomarker == 0,
    string.format("act=%d several=%d identify=%d unmatched=%d nomarker=%d",
      #p.act, #p.several, #p.identify, #p.unmatched, #p.nomarker))
end)

test("nil items is not an error, and dir defaults to item", function()
  local p = vo.PlanUpdatePass(nil)
  assert(#p.act == 0 and #p.identify == 0 and #p.nomarker == 0, "nil errored")
  local d = vo.PlanUpdatePass(items({ { "i1", 0, 1 } }))
  assert(#d.identify == 1, "default dir was not \"item\"")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
