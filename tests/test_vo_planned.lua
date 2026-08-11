-- Unit tests for PLANNED take rows in VO/lib/ajsfx_vo.lua.
-- Run with: lua tests/test_vo_planned.lua (from the repository root)
--
-- A planned take is a row the user added by hand before any audio exists for
-- it ("+ Add Take" with nothing selected in REAPER): a placeholder to hang
-- notes and marks on, linked to a real item later. It lives ONLY in the
-- project file -- keyed "planned|<asset>|<id>" -- because unlike every other
-- row there is no span and no item name to derive it from.

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

print("\n=== ajsfx_vo.lua Planned Take Unit Tests ===\n")

local LINES = {
  { asset = "grum_01", text = "Hello there.", speaker = "Grumbar", index = 1 },
}

local function find_key(rows, key)
  for _, row in ipairs(rows) do
    if row.key == key then return row end
  end
  return nil
end

--------------------------------
print("Keys:")

test("PlannedKey builds and IsPlannedKey recognises it", function()
  local key = vo.PlannedKey("grum_01", "abc123")
  assert(vo.IsPlannedKey(key), "not recognised: " .. key)
  assert(not vo.IsPlannedKey("|grum_01"), "line key misread as planned")
  assert(not vo.IsPlannedKey("a.wav|1400"), "span key misread as planned")
  assert(not vo.IsPlannedKey(nil), "nil misread as planned")
end)

--------------------------------
print("BuildOverview:")

test("a planned entry becomes a take row on its line", function()
  local key = vo.PlannedKey("grum_01", "abc")
  local rows = vo.BuildOverview({
    lines = LINES, matches = {},
    entries = { { key = key, asset = "grum_01", notes = "record on Tuesday" } },
  })
  local row = assert(find_key(rows, key), "planned row missing")
  assert(row.status == "planned", "status: " .. tostring(row.status))
  assert(row.planned == true, "planned flag missing")
  assert(row.take_index == 1, "take_index: " .. tostring(row.take_index))
  assert(row.notes == "record on Tuesday", "notes lost: " .. tostring(row.notes))
  assert(row.line_text == "Hello there.", "line text not carried")
  assert(row.deliver == "grum_01", "deliver: " .. tostring(row.deliver))
end)

test("planned rows sit after real takes and continue the numbering", function()
  local key = vo.PlannedKey("grum_01", "abc")
  local rows = vo.BuildOverview({
    lines = LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 1.0, stop = 2.0, line_idx = 1 },
    } } },
    takes_by_asset = { grum_01 = {
      { id = "k1", start = 1.0, stop = 2.0, source_path = "sess.wav" },
    } },
    entries = { { key = key, asset = "grum_01" } },
  })
  local planned = assert(find_key(rows, key), "planned row missing")
  assert(planned.take_index == 2, "take_index: " .. tostring(planned.take_index))
  local real
  for _, row in ipairs(rows) do
    if row.marker_id == "k1" then real = row end
  end
  assert(real, "real take missing")
  assert(real.take_index == 1, "real take_index: " .. tostring(real.take_index))
end)

test("a planned entry does not steal the line's own marks", function()
  -- index_tracker's by_asset bucket holds the "|<asset>" entry that carries a
  -- MISSING line's notes; a planned entry shares the asset and must not
  -- shadow it.
  local rows = vo.BuildOverview({
    lines = LINES, matches = {},
    entries = {
      { key = vo.PlannedKey("grum_01", "abc"), asset = "grum_01", notes = "planned note" },
      { key = "|grum_01", asset = "grum_01", notes = "line note" },
    },
  })
  local rep
  for _, row in ipairs(rows) do
    if row.status == "missing" and row.asset == "grum_01" then rep = row end
  end
  assert(rep, "line rep missing")
  assert(rep.notes == "line note", "line marks lost: " .. tostring(rep.notes))
end)

test("a planned entry whose asset matches no line surfaces as an orphan", function()
  local key = vo.PlannedKey("gone_99", "abc")
  local rows = vo.BuildOverview({
    lines = LINES, matches = {},
    entries = { { key = key, asset = "gone_99" } },
  })
  local row = assert(find_key(rows, key), "planned orphan dropped")
  assert(row.status == "orphan", "status: " .. tostring(row.status))
  assert(row.planned == true, "planned flag missing")
end)

--------------------------------
print("GroupOverview:")

test("a planned take counts in the rollup but does not read as recorded", function()
  local key = vo.PlannedKey("grum_01", "abc")
  local rows = vo.BuildOverview({
    lines = LINES, matches = {},
    entries = { { key = key, asset = "grum_01" } },
  })
  local nodes = vo.GroupOverview(rows)
  local line
  for _, node in ipairs(nodes) do
    if node.kind == "line" then line = node end
  end
  assert(line, "line node missing")
  assert(#line.takes == 1, "takes: " .. #line.takes)
  assert(line.rollup.take_count == 1, "take_count: " .. line.rollup.take_count)
  assert(line.rollup.status == "missing",
         "a line with only a planned take must still read missing, got: "
         .. tostring(line.rollup.status))
end)

--------------------------------
print("Persistence:")

test("a planned entry with no other work survives serialization", function()
  local text = vo.SerializeProjectFile(
    { { key = vo.PlannedKey("grum_01", "abc"), asset = "grum_01" } },
    { scripts = {}, appends = {}, pins = {}, view = {} })
  local parsed = assert(vo.ParseProjectFile(text))
  local found
  for _, e in ipairs(parsed.entries) do
    if e.key == vo.PlannedKey("grum_01", "abc") then found = e end
  end
  assert(found, "planned entry dropped as workless")
  assert(found.asset == "grum_01", "asset lost")
end)

test("a planned row round-trips through ProjectEntriesFromRows", function()
  local key = vo.PlannedKey("grum_01", "abc")
  local rows = vo.BuildOverview({
    lines = LINES, matches = {},
    entries = { { key = key, asset = "grum_01", notes = "hold for retake" } },
  })
  local entries = vo.ProjectEntriesFromRows(rows)
  local found
  for _, e in ipairs(entries) do
    if e.key == key then found = e end
  end
  assert(found, "planned entry lost in the round trip")
  assert(found.notes == "hold for retake", "notes lost: " .. tostring(found.notes))
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
