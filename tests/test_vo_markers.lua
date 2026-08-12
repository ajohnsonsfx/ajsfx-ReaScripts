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
print("PlanTrimToRange:")

local function near(a, b) return math.abs(a - b) < 1e-9 end

test("trimming the head moves the item right, not left", function()
  -- The audio must not shift: dropping 2s off the front means starting 2s
  -- later in the source AND 2s later in the project.
  local it = { pos = 100, length = 10, start_offs = 0, playrate = 1.0 }
  local p = vo.PlanTrimToRange(it, 2, 8)
  assert(near(p.pos, 102), "pos: " .. p.pos)
  assert(near(p.length, 6), "length: " .. p.length)
  assert(near(p.start_offs, 2), "start_offs: " .. p.start_offs)
end)

test("the same source sample stays at the same project time", function()
  local it = { pos = 100, length = 10, start_offs = 5, playrate = 1.0 }
  local before = vo.SourceTimeToProject(9, it)
  local p = vo.PlanTrimToRange(it, 8, 12)
  local after = vo.SourceTimeToProject(9,
    { pos = p.pos, start_offs = p.start_offs, playrate = 1.0 })
  assert(near(before, after), string.format("audio moved: %f -> %f", before, after))
end)

test("playrate scales the project length, not the source range", function()
  local it = { pos = 0, length = 10, start_offs = 0, playrate = 2.0 }
  local p = vo.PlanTrimToRange(it, 4, 8)
  assert(near(p.length, 2), "length: " .. p.length)      -- 4s of source at 2x
  assert(near(p.start_offs, 4), "start_offs: " .. p.start_offs)
  assert(near(p.pos, 2), "pos: " .. p.pos)               -- 4s of source at 2x
end)

test("the result round-trips through SourceCoverageRanges", function()
  local it = { pos = 3, length = 10, start_offs = 1, playrate = 1.5 }
  local p = vo.PlanTrimToRange(it, 4, 9)
  local cov = vo.SourceCoverageRanges({
    { start_offs = p.start_offs, length = p.length, playrate = 1.5 } })[1]
  assert(near(cov.from, 4) and near(cov.to, 9),
    string.format("covers %f..%f, wanted 4..9", cov.from, cov.to))
end)

test("a range with no length is nothing to trim to", function()
  local it = { pos = 0, length = 10, start_offs = 0, playrate = 1 }
  assert(vo.PlanTrimToRange(it, 5, 5) == nil, "zero length accepted")
  assert(vo.PlanTrimToRange(it, 8, 4) == nil, "reversed range accepted")
  assert(vo.PlanTrimToRange(nil, 1, 2) == nil, "no item accepted")
end)

test("a zero playrate does not divide by zero", function()
  local p = vo.PlanTrimToRange({ pos = 0, length = 4, start_offs = 0, playrate = 0 }, 1, 3)
  assert(p and near(p.length, 2), "length: " .. tostring(p and p.length))
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

test("two takes cut back to back are two takes, whatever float noise says", function()
  -- Chained cuts make neighbouring takes of one line SHARE an instant by
  -- design -- the earlier take's stop IS the later take's start. Stored as
  -- pos + length, the shared edge comes back a few ulp wide of the parsed
  -- start, the strict overlap test read that as "one take wearing two
  -- markers", and the later take vanished from the sheet -- at which point
  -- its span read as unmarked and Identify minted it a fresh duplicate
  -- marker on every press. 19 takes in one real session.
  local out = vo.CountingMarkers({ pi(0, 20, {
    { pos = 2, name = vo.FormatMarkerName("A", "k1"), color = 0,
      length = 3 + 2e-15 },                                -- stop 5 + noise
    mk(5, "A", "k2", 3),
  }) })
  assert(#out == 2, "a float-thin overlap merged two back-to-back takes: " .. #out)
end)

test("adjacent takes of one line whose edges have grown into each other", function()
  -- The live case, from Grumbar 2026-08-11 (source times kept):
  --
  --   mjp  59.460 .. 64.386   take A, its marker snapped to ITS OWN item's
  --                           edges -- and that item has generous tail room,
  --                           so it reaches 0.85s past where take B starts
  --   mjw  63.540 .. 68.880   take B
  --
  -- Same asset, overlapping by more than a millisecond, so the old rule called
  -- them one take wearing two markers and dropped the later id. The take then
  -- vanished from the sheet, and -- because the prune only keeps markers that
  -- survive this function -- pressing Update from Item DELETED the marker off
  -- the user's clip.
  --
  -- 0.85s of overlap on markers 4.9s and 5.3s long is 17% of the shorter. Two
  -- markers on ONE take sit on the same audio, near enough all of it. Bleeding
  -- edges are not a double.
  local out = vo.CountingMarkers({ pi(59.46, 69.36, {
    mk(59.46, "A", "mjp", 4.926143), mk(63.54, "A", "mjw", 5.34) }) })
  assert(#out == 2,
    "merged two adjacent takes whose edges overlap: " .. #out)
end)

test("a real double still merges, at edges a hand-trim moved", function()
  -- The other side of the same threshold: two ids on ONE take, one of them
  -- trimmed slightly. 2.7 of 3.0 is 90% of the shorter -- still one take.
  local out = vo.CountingMarkers({ pi(0, 10, {
    mk(2, "A", "k9", 3), mk(2.3, "A", "k1", 2.7) }) })
  assert(#out == 1, "let a genuine double through: " .. #out)
end)

print("\nMarkerInItem:")

test("a take's own marker is in its item", function()
  -- The live shape: marker 63.54..68.88, clip showing 64.4586..69.3604.
  assert(vo.MarkerInItem({ start = 63.54, stop = 68.88 },
                         { from = 64.4586, to = 69.3604 }))
end)

test("a marker whose tail merely pokes in is NOT in the item", function()
  -- The previous take's marker ending a fifth of a second inside this clip.
  -- You cannot see it on the clip; it must not make the clip a recording.
  assert(not vo.MarkerInItem({ start = 59.46, stop = 64.66 },
                             { from = 64.46, to = 69.36 }))
end)

test("a hard-trimmed clip still holds the marker that covers it", function()
  -- Only a fifth of the marker is inside -- but the marker covers ALL of the
  -- clip, which is the case Update from Item exists for.
  assert(vo.MarkerInItem({ start = 0, stop = 5 }, { from = 2, to = 3 }))
end)

test("no overlap is never in the item", function()
  assert(not vo.MarkerInItem({ start = 0, stop = 5 }, { from = 5, to = 9 }))
  assert(not vo.MarkerInItem({ start = 6, stop = 9 }, { from = 0, to = 5 }))
end)

test("exactly half of the marker counts, a hair under does not", function()
  assert(vo.MarkerInItem({ start = 0, stop = 4 }, { from = 2, to = 100 }))
  assert(not vo.MarkerInItem({ start = 0, stop = 4 }, { from = 2.001, to = 100 }))
end)

test("a zero-length marker or item is never in anything", function()
  assert(not vo.MarkerInItem({ start = 3, stop = 3 }, { from = 0, to = 10 }))
  assert(not vo.MarkerInItem({ start = 0, stop = 5 }, { from = 3, to = 3 }))
  assert(not vo.MarkerInItem(nil, { from = 0, to = 10 }))
end)

print("")
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

test("a line with no markers is missing, however much audio matched it", function()
  local rows = vo.BuildOverview({
    lines = MK_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 90.0, stop = 92.0, line_idx = 1 },
    } } },
    entries = {}, takes_by_asset = {},
  })
  local found
  for _, row in ipairs(rows) do
    if row.asset == "grum_01" then found = row end
  end
  assert(found, "line row missing")
  assert(found.status == "missing", "status: " .. tostring(found.status))
  assert(found.heard == 1, "heard: " .. tostring(found.heard))
  for _, row in ipairs(rows) do
    assert(row.source_start ~= 90.0, "a span row survived")
  end
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
-- PlanMarkerPrune
--------------------------------
print("\nPlanMarkerPrune:")

-- The live geometry that exposed this, from a real session on 2026-08-10:
-- item 21 covers 51.64-53.98 and holds its own short marker; the NEXT take's
-- marker starts at 52.96, inside item 21's window, and runs to 59.04.
local STRADDLE = {
  pi(51.6413, 53.9771, { mk(52.27, "Storything",     "mlz", 0.69) }),
  pi(54.0186, 59.0400, { mk(52.96, "ManWalkDownAnd", "mm6", 6.08) }),
}

test("the mirror pass ADDS the straddling marker -- this is what broke", function()
  -- Not a wish, a record: PlanMarkerMirror is a mirror, and mirroring is why
  -- pressing Tidy Up Take put a second marker on a clip that had one.
  local rewrites = vo.PlanMarkerMirror(STRADDLE)
  local got
  for _, rw in ipairs(rewrites) do if rw.item_index == 1 then got = rw end end
  assert(got and #got.markers == 2,
    "PlanMarkerMirror no longer adds; this test documents why prune exists")
end)

test("prune never gives an item a marker it did not already hold", function()
  local rewrites = vo.PlanMarkerPrune(STRADDLE)
  for _, rw in ipairs(rewrites) do
    assert(rw.item_index ~= 1,
      "item 1 already holds exactly its own marker and needs no rewrite")
  end
end)

test("a straddling marker stays only on the item that covers most of it", function()
  -- Item 1 has been given a stray copy of mm6 -- what the mirror pass did.
  -- Prune must take it away again, and leave item 2's copy alone.
  local damaged = {
    pi(51.6413, 53.9771, { mk(52.27, "Storything", "mlz", 0.69),
                           mk(52.96, "ManWalkDownAnd", "mm6", 6.08) }),
    pi(54.0186, 59.0400, { mk(52.96, "ManWalkDownAnd", "mm6", 6.08) }),
  }
  local rewrites = vo.PlanMarkerPrune(damaged)
  local got
  for _, rw in ipairs(rewrites) do if rw.item_index == 1 then got = rw end end
  assert(got, "item 1 was left holding the stray")
  assert(#got.markers == 1 and got.markers[1].id == "mlz",
    "item 1 should keep only its own marker")
  for _, rw in ipairs(rewrites) do
    assert(rw.item_index ~= 2, "item 2 owns mm6 and must not be rewritten")
  end
end)

test("split residue on a non-covering item is dropped", function()
  local rewrites = vo.PlanMarkerPrune({
    pi(0, 6,  { mk(2, "A", "k1", 3) }),
    pi(20, 26, { mk(2, "A", "k1", 3) }),   -- the copy REAPER's split left
  })
  local got
  for _, rw in ipairs(rewrites) do if rw.item_index == 2 then got = rw end end
  assert(got and #got.markers == 0, "the residue copy survived")
end)

test("one id on two covering items survives only on the one covering more", function()
  -- Comps and overlaps: two items genuinely play part of the same range. The
  -- id is the take's identity, so exactly one item may hold it.
  local rewrites = vo.PlanMarkerPrune({
    pi(0, 4,  { mk(2, "A", "k1", 3) }),   -- covers 2..4 of the marker: 2s
    pi(2, 10, { mk(2, "A", "k1", 3) }),   -- covers 2..5: 3s -- this one owns it
  })
  local got
  for _, rw in ipairs(rewrites) do if rw.item_index == 1 then got = rw end end
  assert(got and #got.markers == 0, "the lesser-covering copy survived")
  for _, rw in ipairs(rewrites) do
    assert(rw.item_index ~= 2, "the owning item must not be rewritten")
  end
end)

test("one id twice INSIDE one item collapses to one", function()
  local rewrites = vo.PlanMarkerPrune({
    pi(0, 10, { mk(2, "A", "k1", 3), mk(2, "A", "k1", 3) }),
  })
  assert(#rewrites == 1, "the duplicate was left in place")
  assert(#rewrites[1].markers == 1, "collapsed to " .. #rewrites[1].markers)
end)

test("an id no item covers is dropped everywhere, not kept somewhere", function()
  local rewrites = vo.PlanMarkerPrune({
    pi(0, 4,   { mk(20, "A", "k1", 3) }),
    pi(30, 40, { mk(20, "A", "k1", 3) }),
  })
  assert(#rewrites == 2, "expected both items rewritten, got " .. #rewrites)
  for _, rw in ipairs(rewrites) do
    assert(#rw.markers == 0, "a marker with no audio under it survived")
  end
end)

test("the duplicate planner never sees one id twice", function()
  -- CountingMarkers is keyed by id, so PlanDuplicateMarkers is only ever
  -- handed one marker per id. Same-id duplication is prune's job, not the
  -- words'. This asserts the boundary rather than assuming it.
  local counted = vo.CountingMarkers({
    pi(0, 4,  { mk(2, "A", "k1", 3) }),
    pi(2, 10, { mk(2, "A", "k1", 3) }),
  })
  assert(#counted == 1, "CountingMarkers returned " .. #counted .. " for one id")
end)

test("an item already holding just its own take needs no rewrite", function()
  local rewrites = vo.PlanMarkerPrune({ pi(0, 10, { mk(2, "A", "k1", 3) }) })
  assert(#rewrites == 0, "a tidy item was rewritten anyway")
end)

test("prune reports the canonical count, like the mirror pass", function()
  local _, canon = vo.PlanMarkerPrune(STRADDLE)
  assert(canon == 2, "canonical count: " .. tostring(canon))
end)

--------------------------------
-- WordsInRange
--------------------------------
print("\nWordsInRange:")

local WR = {
  { t0 = 0.0, t1 = 0.4, text = "open" },
  { t0 = 0.5, t1 = 0.9, text = "the" },
  { t0 = 1.0, t1 = 1.9, text = "gate" },
}

test("a word belongs to the range holding its ONSET", function()
  local got = vo.WordsInRange(WR, 0, 0.95)
  assert(#got == 2, "Got " .. #got)
  assert(got[1].text == "open" and got[2].text == "the", "wrong words")
end)

test("a word followed by a long pause is judged on its start, not its middle", function()
  -- Measured on a real transcript: 94% of whisper -ml 1 words END exactly where
  -- the next one STARTS, so t1 is the next onset and a word before a pause has
  -- its midpoint sitting in silence. "guards." was stamped 85.99-90.36 for a
  -- word taking well under a second.
  local pausey = { { t0 = 85.99, t1 = 90.36, text = "guards." } }
  local got = vo.WordsInRange(pausey, 85.5, 87.0)
  assert(#got == 1, "the whole spoken word was dropped: midpoint 88.17 is silence")
  assert(got[1].text == "guards.", "wrong word")
end)

test("the range is half-open: a word starting exactly at the end belongs next", function()
  -- Otherwise two touching markers both claim the word on the seam.
  assert(#vo.WordsInRange(WR, 0, 0.5) == 1, "0.5 must belong to the NEXT range")
  assert(#vo.WordsInRange(WR, 0.5, 1.0) == 1, "0.5 must belong to THIS range")
end)

test("no words, no range, or a zero-length range is an empty list", function()
  assert(#vo.WordsInRange(nil, 0, 5) == 0, "nil words")
  assert(#vo.WordsInRange(WR, 2, 2) == 0, "zero-length range")
  assert(#vo.WordsInRange(WR, 5, 9) == 0, "silence")
end)

--------------------------------
-- ClusterMarkerRanges
--------------------------------
print("\nClusterMarkerRanges:")

local function dm(id, from, to, asset, src)
  return { id = id, start = from, stop = to, asset = asset or "A",
           source_path = src or "s.wav", item_index = 1 }
end

local function cluster_ids(clusters)
  local out = {}
  for _, c in ipairs(clusters) do
    local ids = {}
    for _, m in ipairs(c) do ids[#ids + 1] = m.id end
    table.sort(ids)
    out[#out + 1] = table.concat(ids, ",")
  end
  table.sort(out)
  return out
end

test("an uncut recording's takes never cluster", function()
  -- THE test that matters: five markers, one per take, no overlap at all.
  -- A verb that reduced this to one would destroy the session.
  local out = vo.ClusterMarkerRanges({
    dm("a", 0, 2), dm("b", 3, 5), dm("c", 6, 8), dm("d", 9, 11), dm("e", 12, 14),
  }, 0.8)
  assert(#out == 5, "Expected 5 singleton clusters, got " .. #out)
  for _, c in ipairs(out) do assert(#c == 1, "a take was clustered with another") end
end)

test("identical ranges cluster", function()
  local out = vo.ClusterMarkerRanges({
    dm("mkm", 31.87, 34.87), dm("mkt", 31.87, 34.87),
  }, 0.8)
  assert(#out == 1 and #out[1] == 2, "the live duplicate case did not cluster")
end)

test("the overlap fraction is of the SHORTER marker, at the boundary", function()
  -- 0..10 and 2..12 overlap by 8; the shorter is 10; 0.8 exactly.
  local at = vo.ClusterMarkerRanges({ dm("a", 0, 10), dm("b", 2, 12) }, 0.8)
  assert(#at == 1, "0.80 must cluster")
  -- 0..10 and 2.1..12.1 overlap by 7.9 of 10: 0.79.
  local under = vo.ClusterMarkerRanges({ dm("a", 0, 10), dm("b", 2.1, 12.1) }, 0.8)
  assert(#under == 2, "0.79 must not cluster")
end)

test("clustering is transitive", function()
  -- A-B overlap 0.8 and B-C overlap 0.8, but A-C only 0.6: all three are one
  -- argument about one stretch of audio, so all three travel together.
  local out = vo.ClusterMarkerRanges({
    dm("a", 0, 10), dm("b", 2, 12), dm("c", 4, 14),
  }, 0.8)
  assert(#out == 1 and #out[1] == 3, "transitivity lost: " ..
         table.concat(cluster_ids(out), " | "))
end)

test("markers on different sources never cluster", function()
  local out = vo.ClusterMarkerRanges({
    dm("a", 0, 10, "A", "one.wav"), dm("b", 0, 10, "B", "two.wav"),
  }, 0.8)
  assert(#out == 2, "two sources became one cluster")
end)

--------------------------------
-- PlanDuplicateMarkers
--------------------------------
print("\nPlanDuplicateMarkers:")

-- Words that spell a real line, so a real script line can win on merit.
local function words_for(text, from)
  local out, t = {}, from or 0
  for w in tostring(text):gmatch("%S+") do
    out[#out + 1] = { t0 = t, t1 = t + 0.4, text = w }
    t = t + 0.5
  end
  return out
end

test("the line the words actually spell keeps its marker", function()
  local plan = vo.PlanDuplicateMarkers({
    markers = { dm("mkm", 0, 5, "IWinLittle"), dm("mkt", 0, 5, "Book") },
    lines = { { asset = "IWinLittle", text = "I only win little." },
              { asset = "Book",       text = "Book." } },
    words = { ["s.wav"] = words_for("I only win little.") },
  })
  assert(#plan.deletes == 1, "Expected 1 delete, got " .. #plan.deletes)
  assert(plan.deletes[1].id == "mkt", "deleted the wrong one: " .. plan.deletes[1].id)
  assert(plan.deletes[1].lost_to == "IWinLittle", "loser does not name its winner")
  assert(#plan.kept == 1 and plan.kept[1].id == "mkm", "winner not kept")
  assert(#plan.skipped == 0, "a clear case was skipped")
end)

test("an uncut recording plans no deletes at all", function()
  local plan = vo.PlanDuplicateMarkers({
    markers = { dm("a", 0, 2, "L1"), dm("b", 3, 5, "L2"), dm("c", 6, 8, "L3") },
    lines = { { asset = "L1", text = "one" }, { asset = "L2", text = "two" },
              { asset = "L3", text = "three" } },
    words = { ["s.wav"] = words_for("one two three") },
  })
  assert(#plan.deletes == 0, "a recording lost markers")
  assert(#plan.skipped == 0, "singletons must not be reported as problems")
end)

test("nothing matching the audio well is left alone", function()
  -- Both lines score 0.4 against the words: below the 0.50 floor.
  local plan = vo.PlanDuplicateMarkers({
    markers = { dm("a", 0, 5, "L1"), dm("b", 0, 5, "L2") },
    lines = { { asset = "L1", text = "a b x y z" },
              { asset = "L2", text = "a b x y q" } },
    words = { ["s.wav"] = words_for("a b c d e") },
  })
  assert(#plan.deletes == 0, "deleted on a bad match")
  assert(#plan.skipped == 1 and plan.skipped[1].why == "no clear match",
         "why: " .. tostring(plan.skipped[1] and plan.skipped[1].why))
end)

test("a near-tie is a judgement call, not an automation", function()
  -- L1 scores 0.6, L2 scores 0.5: over the floor, but the gap is 0.10.
  local plan = vo.PlanDuplicateMarkers({
    markers = { dm("a", 0, 9, "L1"), dm("b", 0, 9, "L2") },
    lines = { { asset = "L1", text = "a b c d e f x y z w" },
              { asset = "L2", text = "a b c d e x y z w v" } },
    words = { ["s.wav"] = words_for("a b c d e f g h i j") },
  })
  assert(#plan.deletes == 0, "deleted on a near-tie")
  assert(#plan.skipped == 1 and plan.skipped[1].why == "too close to call",
         "why: " .. tostring(plan.skipped[1] and plan.skipped[1].why))
end)

test("no words in the range means no opinion", function()
  local plan = vo.PlanDuplicateMarkers({
    markers = { dm("a", 40, 45, "L1"), dm("b", 40, 45, "L2") },
    lines = { { asset = "L1", text = "one" }, { asset = "L2", text = "two" } },
    words = { ["s.wav"] = words_for("one two") },
  })
  assert(#plan.deletes == 0, "deleted with nothing to judge on")
  assert(#plan.skipped == 1 and plan.skipped[1].why == "no words",
         "why: " .. tostring(plan.skipped[1] and plan.skipped[1].why))
end)

test("a marker naming no script line loses to a real match", function()
  local plan = vo.PlanDuplicateMarkers({
    markers = { dm("a", 0, 5, "L1"), dm("b", 0, 5, "GHOST") },
    lines = { { asset = "L1", text = "one two three" } },
    words = { ["s.wav"] = words_for("one two three") },
  })
  assert(#plan.deletes == 1 and plan.deletes[1].id == "b",
         "the ghost survived")
end)

test("two ghosts together are reported, not guessed between", function()
  local plan = vo.PlanDuplicateMarkers({
    markers = { dm("a", 0, 5, "GHOST1"), dm("b", 0, 5, "GHOST2") },
    lines = { { asset = "L1", text = "one two three" } },
    words = { ["s.wav"] = words_for("one two three") },
  })
  assert(#plan.deletes == 0, "picked arbitrarily between two ghosts")
  assert(#plan.skipped == 1 and plan.skipped[1].why == "no clear match",
         "why: " .. tostring(plan.skipped[1] and plan.skipped[1].why))
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
