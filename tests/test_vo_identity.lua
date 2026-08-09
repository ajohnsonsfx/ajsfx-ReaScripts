-- Unit tests for take identity: anchors, track-derived marks, reconcile.
-- Run with: lua tests/test_vo_identity.lua (from the repository root)

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

print("\n=== ajsfx_vo.lua Take Identity Unit Tests ===\n")

local function only_entry(text, key)
  local parsed = assert(vo.ParseProjectFile(text))
  for _, e in ipairs(parsed.entries) do
    if e.key == key then return e end
  end
  return nil
end

local EMPTY_META = { scripts = {}, appends = {}, pins = {}, view = {} }

--------------------------------
print("Project file — anchors:")

test("an anchor round-trips through serialize and parse", function()
  local text = vo.SerializeProjectFile({
    { key = "a.wav|1400", asset = "grum_01",
      anchor = "{ABC-123}", anchor_start = 1.4, anchor_stop = 3.25 },
  }, EMPTY_META)
  local e = assert(only_entry(text, "a.wav|1400"), "entry dropped")
  assert(e.anchor == "{ABC-123}", "anchor: " .. tostring(e.anchor))
  assert(math.abs(e.anchor_start - 1.4) < 1e-6, "start: " .. tostring(e.anchor_start))
  assert(math.abs(e.anchor_stop - 3.25) < 1e-6, "stop: " .. tostring(e.anchor_stop))
end)

test("an anchor alone counts as work and is not dropped", function()
  local text = vo.SerializeProjectFile({
    { key = "a.wav|1400", anchor = "{ABC-123}", anchor_start = 1.0, anchor_stop = 2.0 },
  }, EMPTY_META)
  assert(only_entry(text, "a.wav|1400"), "anchor-only entry dropped as workless")
end)

test("a file written without the new columns parses with no anchor", function()
  local text = vo.SerializeProjectFile({
    { key = "a.wav|1400", asset = "grum_01", notes = "hi" },
  }, EMPTY_META)
  local e = assert(only_entry(text, "a.wav|1400"))
  assert(e.anchor == nil, "anchor invented: " .. tostring(e.anchor))
  assert(e.anchor_start == nil and e.anchor_stop == nil, "anchor times invented")
end)

--------------------------------
print("Project file — tri-state marks:")

test("an explicit no round-trips as false, not nil", function()
  local text = vo.SerializeProjectFile({
    { key = "a.wav|1400", select = false, keep = false },
  }, EMPTY_META)
  local e = assert(only_entry(text, "a.wav|1400"), "explicit-no entry dropped")
  assert(e.select == false, "select: " .. tostring(e.select))
  assert(e.keep == false, "keep: " .. tostring(e.keep))
end)

test("yes round-trips as true", function()
  local text = vo.SerializeProjectFile({
    { key = "a.wav|1400", select = true, keep = true },
  }, EMPTY_META)
  local e = assert(only_entry(text, "a.wav|1400"))
  assert(e.select == true and e.keep == true, "marks lost")
end)

test("an absent mark parses as nil, meaning no opinion", function()
  local text = vo.SerializeProjectFile({
    { key = "a.wav|1400", notes = "just a note" },
  }, EMPTY_META)
  local e = assert(only_entry(text, "a.wav|1400"))
  assert(e.select == nil, "select should be nil, got " .. tostring(e.select))
  assert(e.keep == nil, "keep should be nil, got " .. tostring(e.keep))
end)

test("the legacy alt value still reads as a keep", function()
  -- 0.13 wrote "alt" in the Select field before Keep had a column.
  local text = table.concat({
    vo.FormatCSVRow({ vo.PROJECT_MARKER, "1" }),
    "",
    vo.FormatCSVRow(vo.PROJECT_HEADER),
    vo.FormatCSVRow({ "a.wav|1400", "grum_01", "", "", "alt", "", "", "", "" }),
  }, "\n") .. "\n"
  local e = assert(only_entry(text, "a.wav|1400"))
  assert(e.keep == true, "legacy alt lost: " .. tostring(e.keep))
end)

test("an explicit keep=no is not overwritten by the legacy alt rule", function()
  -- The bug this guards: `tri(row[9]) or legacy` evaluates the legacy branch
  -- when tri returns false, turning an explicit no into a yes.
  local text = table.concat({
    vo.FormatCSVRow({ vo.PROJECT_MARKER, "1" }),
    "",
    vo.FormatCSVRow(vo.PROJECT_HEADER),
    vo.FormatCSVRow({ "a.wav|1400", "grum_01", "", "", "alt", "", "", "", "no" }),
  }, "\n") .. "\n"
  local e = assert(only_entry(text, "a.wav|1400"))
  assert(e.keep == false, "explicit no was overwritten: " .. tostring(e.keep))
end)

--------------------------------
print("IsEditedAnchor:")

local function anchor(from, to) return { anchor_start = from, anchor_stop = to } end
local function range(from, to)  return { from = from, to = to } end

test("an untouched item is not edited", function()
  assert(not vo.IsEditedAnchor(anchor(1.0, 3.0), range(1.0, 3.0)))
end)

test("a head dragged past the tolerance is edited", function()
  assert(vo.IsEditedAnchor(anchor(1.0, 3.0), range(1.2, 3.0)))
end)

test("a tail dragged past the tolerance is edited", function()
  assert(vo.IsEditedAnchor(anchor(1.0, 3.0), range(1.0, 2.7)))
end)

test("a sub-tolerance nudge is not edited", function()
  -- Rounding through "%.3f" and REAPER's own float noise must not read as a
  -- hand-edit, or every take would report edited after one save cycle.
  assert(not vo.IsEditedAnchor(anchor(1.0, 3.0), range(1.005, 2.996)))
end)

test("an anchor with no recorded edges is not edited", function()
  -- Nothing to compare against is not evidence of an edit.
  assert(not vo.IsEditedAnchor({}, range(1.0, 3.0)))
end)

test("a missing range is not edited", function()
  -- The item is gone, which is a repair-pass finding, not an edit.
  assert(not vo.IsEditedAnchor(anchor(1.0, 3.0), nil))
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
