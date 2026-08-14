-- Unit tests for the parity engine: diff, attribution, assembly.
-- Run with: lua tests/test_vo_parity.lua (from the repository root)

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

print("\n=== ajsfx_vo.lua Parity Engine Unit Tests ===\n")

-- One agreeing take, with fields to override per case.
local function take(over)
  local base = {
    key = "k1",
    marker = { asset = "IWinBig_02", start = 1.25, stop = 3.50 },
    marker_count = 1,
    item = { name = "IWinBig_02", from = 1.25, to = 3.50 },
    sheet = { asset = "IWinBig_02" },
  }
  for k, v in pairs(over or {}) do base[k] = v end
  return base
end

--------------------------------
print("ParityDiff:")

test("agreement diffs to nothing", function()
  assert(#vo.ParityDiff({ take() }) == 0, "clean take reported divergent")
end)

test("a renamed item is a name divergence", function()
  local d = vo.ParityDiff({ take({
    item = { name = "IWinLittle_01", from = 1.25, to = 3.50 } }) })
  assert(#d == 1, "expected one divergence, got " .. #d)
  assert(d[1].key == "k1", "key not echoed")
  assert(d[1].fields[1] == "name", "expected a name divergence")
end)

test("a conventional alt name is not a divergence", function()
  local d = vo.ParityDiff(
    { take({ item = { name = "IWinBig_02_alt01", from = 1.25, to = 3.50 } }) },
    { alt_pattern = "_alt{n}" })
  assert(#d == 0, "an alt name read as a wrong name")
end)

test("edges past eps diverge, inside eps do not", function()
  assert(#vo.ParityDiff({ take({
    item = { name = "IWinBig_02", from = 1.30, to = 3.50 } }) }) == 1,
    "a 50ms edge gap was not seen")
  assert(#vo.ParityDiff({ take({
    item = { name = "IWinBig_02", from = 1.2501, to = 3.50 } }) }) == 0,
    "float noise read as an edit")
end)

test("a recording is never compared", function()
  assert(#vo.ParityDiff({ take({ marker_count = 3,
    item = { name = "whatever", from = 0, to = 99 } }) }) == 0,
    "an uncut recording was diffed")
end)

test("no marker, no divergence -- that is Match's business", function()
  assert(#vo.ParityDiff({ take({ marker = nil, marker_count = 0 }) }) == 0,
    "an unmarked item was diffed")
end)

test("sheet disagreeing with marker is a name divergence", function()
  local d = vo.ParityDiff({ take({ sheet = { asset = "IWinLittle_01" } }) })
  assert(#d == 1 and d[1].fields[1] == "name",
    "sheet/marker disagreement missed")
end)

test("name and edges both wrong is one divergence with two fields", function()
  local d = vo.ParityDiff({ take({
    item = { name = "IWinLittle_01", from = 1.40, to = 3.50 } }) })
  assert(#d == 1, "two divergences for one take")
  assert(#d[1].fields == 2, "expected name and edges, got " .. #d[1].fields)
end)

test("nil takes is empty, not an error", function()
  assert(#vo.ParityDiff(nil) == 0, "nil input errored or reported")
end)

--------------------------------
print("ParityAttribute:")

test("one element moved names the authority", function()
  assert(vo.ParityAttribute({ edge = true })   == "item",   "edge -> item")
  assert(vo.ParityAttribute({ name = true })   == "name",   "name -> name")
  assert(vo.ParityAttribute({ marker = true }) == "marker", "marker -> marker")
  assert(vo.ParityAttribute({ track = true })  == "sheet",  "track -> sheet")
end)

test("two elements moved is nobody's authority", function()
  assert(vo.ParityAttribute({ edge = true, marker = true }) == nil,
    "edge+marker attributed")
  assert(vo.ParityAttribute({ name = true, track = true }) == nil,
    "name+track attributed")
end)

test("nothing moved, nil, and nil input is not an error", function()
  assert(vo.ParityAttribute({})  == nil, "empty set attributed")
  assert(vo.ParityAttribute(nil) == nil, "nil errored or attributed")
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
