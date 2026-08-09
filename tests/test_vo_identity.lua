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
print("MarkFromTrack:")

test("the configured Selects and Alts tracks map to their marks", function()
  assert(vo.MarkFromTrack("Selects", {}) == "select")
  assert(vo.MarkFromTrack("Alts", {}) == "keep")
end)

test("custom track names from config are honoured", function()
  local cfg = { track_selects = "PICKED", track_alts = "SPARES" }
  assert(vo.MarkFromTrack("PICKED", cfg) == "select")
  assert(vo.MarkFromTrack("SPARES", cfg) == "keep")
  assert(vo.MarkFromTrack("Selects", cfg) == nil, "default name still matched")
end)

test("the Review track sets no mark", function()
  -- Review means "undecided, look at this" -- the absence of a decision.
  assert(vo.MarkFromTrack("Review", {}) == nil)
end)

test("an unrelated or missing track sets no mark", function()
  assert(vo.MarkFromTrack("Grumbar REC", {}) == nil)
  assert(vo.MarkFromTrack("", {}) == nil)
  assert(vo.MarkFromTrack(nil, {}) == nil)
end)

--------------------------------
print("EffectiveMarks:")

test("a blank mark defers to the item's track", function()
  local m = vo.EffectiveMarks({}, "Selects", {})
  assert(m.select == true, "track did not tick Sel")
  assert(m.keep == false, "Alts tick invented")
end)

test("an explicit yes wins over a track that says nothing", function()
  local m = vo.EffectiveMarks({ select = true }, "Grumbar REC", {})
  assert(m.select == true)
end)

test("an explicit no beats the track", function()
  -- The regression that makes the tri-state worth having: without it the
  -- un-tick springs back on the next rebuild.
  local m = vo.EffectiveMarks({ select = false }, "Selects", {})
  assert(m.select == false, "the track overrode an explicit no")
end)

test("an explicit no on one mark leaves the other free to follow its track", function()
  local m = vo.EffectiveMarks({ select = false }, "Alts", {})
  assert(m.select == false, "select no was lost")
  assert(m.keep == true, "keep did not follow the Alts track")
end)

test("no entry and no track is unticked", function()
  local m = vo.EffectiveMarks(nil, nil, {})
  assert(m.select == false and m.keep == false)
end)

--------------------------------
print("Row model:")

local ID_LINES = {
  { asset = "grum_01", text = "Hello there.", speaker = "Grumbar", index = 1 },
}

local function row_for_key(rows, key)
  for _, row in ipairs(rows) do
    if row.key == key then return row end
  end
  return nil
end

local function one_take_overview(entries)
  return vo.BuildOverview({
    lines = ID_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 1.0, stop = 2.0, line_idx = 1 },
    } } },
    entries = entries,
  })
end

-- `source` and `source_start` are not optional decoration: index_tracker
-- buckets entries by source path, and resolve_tracker only ever looks in those
-- buckets -- an entry without them can never attach to a span row.
-- vo.ProjectEntriesFromRows always writes them, so real files always have them.
test("an explicit no survives as mark_select false, not nil", function()
  local rows = one_take_overview({
    { key = "sess.wav|1000", asset = "grum_01",
      source = "sess.wav", source_start = 1.0, select = false },
  })
  local row = assert(row_for_key(rows, "sess.wav|1000"))
  assert(row.mark_select == false, "mark_select: " .. tostring(row.mark_select))
  assert(row.user_select == false, "user_select: " .. tostring(row.user_select))
end)

test("an absent mark is nil on the row, not false", function()
  local rows = one_take_overview({})
  local row = assert(row_for_key(rows, "sess.wav|1000"))
  assert(row.mark_select == nil, "mark_select: " .. tostring(row.mark_select))
  assert(row.user_select == false, "user_select should be a boolean for the UI")
end)

test("ProjectEntriesFromRows writes the stored mark, never the effective one", function()
  -- The row's user_select is what the TRACK inferred; persisting that would
  -- freeze an inference into an explicit decision nobody made.
  local entries = vo.ProjectEntriesFromRows({
    { key = "sess.wav|1000", mark_select = nil, user_select = true,
      mark_keep = false, user_keep = false },
  })
  assert(#entries == 1, "entry count: " .. #entries)
  assert(entries[1].select == nil, "inferred tick was persisted: " .. tostring(entries[1].select))
  assert(entries[1].keep == false, "explicit no lost: " .. tostring(entries[1].keep))
end)

--------------------------------
print("PlanReconcile:")

test("a clean sheet produces no findings", function()
  local plan = vo.PlanReconcile({
    { key = "a|1", user_select = true, track_name = "Selects", item_guid = "{A}" },
    { key = "a|2", user_select = false, track_name = "Review", item_guid = "{B}" },
  }, {})
  assert(#plan.disagree == 0, "disagree: " .. #plan.disagree)
  assert(#plan.missing_anchor == 0 and #plan.doubled == 0 and #plan.orphan_marks == 0)
end)

test("ticked Sel with the item off the Selects track is a disagreement", function()
  local plan = vo.PlanReconcile({
    { key = "a|1", user_select = true, track_name = "Review", item_guid = "{A}" },
  }, {})
  assert(#plan.disagree == 1, "disagree: " .. #plan.disagree)
  assert(plan.disagree[1].row.key == "a|1")
end)

test("an item on Selects whose row says an explicit no is a disagreement", function()
  local plan = vo.PlanReconcile({
    { key = "a|1", mark_select = false, user_select = false,
      track_name = "Selects", item_guid = "{A}" },
  }, {})
  assert(#plan.disagree == 1, "disagree: " .. #plan.disagree)
end)

test("a row with no item is not a disagreement", function()
  -- Nothing to disagree WITH. This is the orphan_marks case at most.
  local plan = vo.PlanReconcile({
    { key = "a|1", user_select = true },
  }, {})
  assert(#plan.disagree == 0, "a row with no item was called a disagreement")
end)

test("marks with no item are reported as damage", function()
  local plan = vo.PlanReconcile({
    { key = "a|1", mark_select = true },
  }, {})
  assert(#plan.orphan_marks == 1, "orphan_marks: " .. #plan.orphan_marks)
end)

test("an unmarked row with no item is not damage", function()
  -- A script line nobody has recorded yet is the normal case, not a finding.
  local plan = vo.PlanReconcile({ { key = "a|1" } }, {})
  assert(#plan.orphan_marks == 0, "an unrecorded line was reported as damage")
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
