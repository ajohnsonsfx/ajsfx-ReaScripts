-- Unit tests for ranged take markers: the TKM chunk layer, the coverage rule,
-- and marker-built take rows.
-- Run with: lua tests/test_vo_markers.lua (from the repository root)
--
-- The substrate is the undocumented fourth field of the TKM chunk line --
-- `TKM <srcpos> <name> <color> <length>` -- verified in live REAPER v7.78 on
-- 2026-08-09 (SoundDesignDocs Workflow/reaper-session-automation.md §4).

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

print("\n=== ajsfx_vo.lua Take Marker Unit Tests ===\n")

--------------------------------
print("ParseTKMChunk:")

local CHUNK = table.concat({
  "<ITEM", "POSITION 1", "LENGTH 10", "NAME plain",
  "<SOURCE WAVE", 'FILE "a.wav"', ">", ">",
}, "\n")

local function with_tkm(lines)
  return (CHUNK:gsub("<SOURCE", table.concat(lines, "\n") .. "\n<SOURCE", 1))
end

test("a bare-name ranged line parses", function()
  local m = vo.ParseTKMChunk(with_tkm({ "TKM 2 RTEST 0 4" }))
  assert(#m == 1, "count: " .. #m)
  assert(m[1].pos == 2 and m[1].length == 4 and m[1].name == "RTEST")
end)

test("a quoted name with spaces parses, any delimiter", function()
  for _, q in ipairs({ '"', "'", "`" }) do
    local m = vo.ParseTKMChunk(with_tkm({
      "TKM 1.5 " .. q .. "DBP_Book ~k7" .. q .. " 0 3.25" }))
    assert(#m == 1, q .. " count: " .. #m)
    assert(m[1].name == "DBP_Book ~k7", q .. " name: " .. tostring(m[1].name))
    assert(math.abs(m[1].length - 3.25) < 1e-9, q .. " length lost")
  end
end)

test("a point marker parses with length 0", function()
  local m = vo.ParseTKMChunk(with_tkm({ "TKM 7 POINT 0 0" }))
  assert(m[1].length == 0)
end)

test("a legacy line with no fourth field parses with length 0", function()
  local m = vo.ParseTKMChunk(with_tkm({ "TKM 7 OLD 0" }))
  assert(#m == 1 and m[1].length == 0)
end)

--------------------------------
print("FormatTKMLine:")

test("a name with spaces is quoted and round-trips", function()
  local line = vo.FormatTKMLine({ pos = 2, name = "DBP_Book ~k7", color = 0, length = 4 })
  local m = vo.ParseTKMChunk(with_tkm({ line }))
  assert(m[1].name == "DBP_Book ~k7", "round trip: " .. tostring(m[1].name))
  assert(m[1].length == 4)
end)

test("a name containing a double quote picks another delimiter", function()
  local line = vo.FormatTKMLine({ pos = 1, name = 'say "no" ~a1', color = 0, length = 2 })
  assert(not line:find('^TKM 1 "say'), "used a delimiter the name contains")
  local m = vo.ParseTKMChunk(with_tkm({ line }))
  assert(m[1].name == 'say "no" ~a1', "round trip: " .. tostring(m[1].name))
end)

--------------------------------
print("PatchTKMChunk:")

test("patching replaces existing TKM lines wholesale", function()
  local c1 = with_tkm({ "TKM 2 OLD 0 4", "TKM 5 OLD2 0 1" })
  local c2, ok = vo.PatchTKMChunk(c1, { { pos = 3, name = "NEW ~x1", color = 0, length = 2 } })
  assert(ok, "patch refused")
  local m = vo.ParseTKMChunk(c2)
  assert(#m == 1 and m[1].name == "NEW ~x1", "old lines survived or new missing")
end)

test("patching a chunk with no TKM lines inserts before SOURCE", function()
  local c2, ok = vo.PatchTKMChunk(CHUNK, { { pos = 1, name = "A ~b2", color = 0, length = 3 } })
  assert(ok)
  local m = vo.ParseTKMChunk(c2)
  assert(#m == 1, "insert failed")
  assert(c2:find("TKM") < c2:find("<SOURCE"), "TKM landed after the SOURCE block")
end)

test("an empty marker list strips all TKM lines", function()
  local c2 = vo.PatchTKMChunk(with_tkm({ "TKM 2 OLD 0 4" }), {})
  assert(#vo.ParseTKMChunk(c2) == 0, "TKM lines survived a clear")
end)

test("a multi-take chunk is refused unchanged", function()
  local multi = CHUNK:gsub(">%s*$", 'TAKE\nNAME "second"\n>')
  local c2, ok = vo.PatchTKMChunk(multi, { { pos = 1, name = "A ~c3", color = 0, length = 1 } })
  assert(ok == false, "multi-take chunk was patched")
  assert(c2 == multi, "chunk changed despite refusal")
end)

--------------------------------
print("Marker names:")

test("FormatMarkerName and ParseMarkerName round-trip", function()
  local asset, id = vo.ParseMarkerName(vo.FormatMarkerName("DBP_Grumbar_Book", "k7"))
  assert(asset == "DBP_Grumbar_Book" and id == "k7")
end)

test("a name with no id parses as asset only", function()
  local asset, id = vo.ParseMarkerName("DBP_Grumbar_Book")
  assert(asset == "DBP_Grumbar_Book" and id == nil)
end)

test("a tilde inside the asset does not fake an id", function()
  local asset, id = vo.ParseMarkerName("weird~name here")
  assert(id == nil, "invented id: " .. tostring(id))
  assert(asset == "weird~name here")
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
