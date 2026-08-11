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
print("CountingMarkers:")

local function pi(from, to, markers)
  return { coverage = { from = from, to = to }, markers = markers }
end
local function mk(pos, asset, id, len)
  return { pos = pos, name = vo.FormatMarkerName(asset, id), color = 0, length = len }
end

test("a marker counts where its range intersects the item window", function()
  local out = vo.CountingMarkers({ pi(0, 10, { mk(2, "A", "k1", 3) }) })
  assert(#out == 1, "count: " .. #out)
  assert(out[1].id == "k1" and out[1].start == 2 and out[1].stop == 5)
end)

test("split residue is ignored: off-window copies do not count", function()
  local out = vo.CountingMarkers({
    pi(0, 6,  { mk(2, "A", "k1", 3) }),   -- covers the span: counts
    pi(6, 10, { mk(2, "A", "k1", 3) }),   -- residue: range 2-5 misses 6-10
  })
  assert(#out == 1, "residue counted: " .. #out)
  assert(out[1].item_index == 1)
end)

test("two items covering one marker: the better-covering one wins", function()
  local out = vo.CountingMarkers({
    pi(0, 4,  { mk(2, "A", "k1", 4) }),   -- covers 2-4 of 2-6
    pi(0, 10, { mk(2, "A", "k1", 4) }),   -- covers all of it
  })
  assert(#out == 1 and out[1].item_index == 2, "wrong winner")
end)

test("one take wearing two markers counts once", function()
  -- The shape of a real bug: Cut minted a fresh marker for a take that already
  -- had one, so the same performance carried two ids at the same bounds.
  local out = vo.CountingMarkers({ pi(0, 10, {
    mk(2, "A", "k9", 3), mk(2, "A", "k1", 3) }) })
  assert(#out == 1, "counted a doubled marker twice: " .. #out)
  assert(out[1].id == "k1", "unstable survivor: " .. tostring(out[1].id))
end)

test("the survivor is the same one every run", function()
  -- Marks are keyed `tkm|<id>`, so a survivor that changed run to run would
  -- move the user's Sel and Keep around under them.
  local a = vo.CountingMarkers({ pi(0, 10, { mk(2, "A", "k9", 3), mk(2, "A", "k1", 3) }) })
  local b = vo.CountingMarkers({ pi(0, 10, { mk(2, "A", "k1", 3), mk(2, "A", "k9", 3) }) })
  assert(a[1].id == b[1].id, "survivor depends on chunk order")
end)

test("two takes of one line are two takes, not a duplicate", function()
  -- Same asset, different audio: the whole point of the tool. Only OVERLAP
  -- makes two markers one take.
  local out = vo.CountingMarkers({ pi(0, 20, {
    mk(2, "A", "k1", 3), mk(10, "A", "k2", 3) }) })
  assert(#out == 2, "merged two genuine takes of one line: " .. #out)
end)

test("two different lines overlapping stay separate", function()
  local out = vo.CountingMarkers({ pi(0, 10, {
    mk(2, "A", "k1", 3), mk(2, "B", "k2", 3) }) })
  assert(#out == 2, "merged two different lines: " .. #out)
end)

test("markers without our id suffix are not ours and are ignored", function()
  local out = vo.CountingMarkers({ pi(0, 10, {
    { pos = 1, name = "user note", color = 0, length = 0 } }) })
  assert(#out == 0, "claimed a foreign marker")
end)

--------------------------------
print("BuildOverview with markers:")

local MK_LINES = {
  { asset = "grum_01", text = "Hello.", speaker = "Grumbar", index = 1 },
}

test("a line with markers builds its takes from them, not the match", function()
  local rows = vo.BuildOverview({
    lines = MK_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 90.0, stop = 92.0, line_idx = 1 },
    } } },
    entries = {},
    takes_by_asset = { grum_01 = {
      { id = "k1", start = 10.0, stop = 12.5, item_index = 3 },
      { id = "k2", start = 20.0, stop = 22.0, item_index = 7 },
    } },
  })
  local takes = {}
  for _, row in ipairs(rows) do
    if row.take_index and row.asset == "grum_01" then takes[#takes + 1] = row end
  end
  assert(#takes == 2, "takes: " .. #takes)
  assert(takes[1].key == "tkm|k1", "key: " .. tostring(takes[1].key))
  assert(takes[1].source_start == 10.0, "marker start lost")
  assert(takes[2].take_index == 2, "ordering broken")
  for _, row in ipairs(rows) do
    assert(row.source_start ~= 90.0, "a match row leaked through")
  end
end)

test("marker takes attach their stored marks by tkm key", function()
  local rows = vo.BuildOverview({
    lines = MK_LINES, matches = {},
    entries = { { key = "tkm|k1", asset = "grum_01", notes = "the good one" } },
    takes_by_asset = { grum_01 = { { id = "k1", start = 10.0, stop = 12.5 } } },
  })
  local found
  for _, row in ipairs(rows) do
    if row.key == "tkm|k1" then found = row end
  end
  assert(found, "marker row missing")
  assert(found.notes == "the good one", "marks did not attach")
end)

test("a line with no markers still builds from the match", function()
  local rows = vo.BuildOverview({
    lines = MK_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 90.0, stop = 92.0, line_idx = 1 },
    } } },
    entries = {}, takes_by_asset = {},
  })
  local found
  for _, row in ipairs(rows) do
    if row.source_start == 90.0 then found = row end
  end
  assert(found, "match fallback lost")
end)

test("planned takes still append after marker takes", function()
  local rows = vo.BuildOverview({
    lines = MK_LINES, matches = {},
    entries = { { key = vo.PlannedKey("grum_01", "p1"), asset = "grum_01" } },
    takes_by_asset = { grum_01 = { { id = "k1", start = 10.0, stop = 12.5 } } },
  })
  local planned
  for _, row in ipairs(rows) do
    if row.planned then planned = row end
  end
  assert(planned, "planned take vanished")
  assert(planned.take_index == 2, "planned numbering: " .. tostring(planned.take_index))
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
