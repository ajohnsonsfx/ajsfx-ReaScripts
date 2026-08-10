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

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
