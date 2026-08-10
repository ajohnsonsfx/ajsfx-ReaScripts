-- Unit tests for vo.LineKey, vo.SelectConflicts and vo.PlanSelectNames --
-- the pure layer behind the Overview toolbar's Tidy pass (SPEC-toolbar.md).

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

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
