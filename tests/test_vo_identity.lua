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

test("the Outs track marks a take as out -- an explicit rejection", function()
  -- Out is a DECISION, unlike Review: the user parked the take there.
  assert(vo.MarkFromTrack("Outs", {}) == "out")
  local cfg = { track_outs = "REJECTS" }
  assert(vo.MarkFromTrack("REJECTS", cfg) == "out")
  assert(vo.MarkFromTrack("Outs", cfg) == nil, "default name still matched")
end)

test("effective marks on the Outs track read as unticked, not re-ticked", function()
  local m = vo.EffectiveMarks(nil, "Outs", {})
  assert(m.select == false and m.keep == false,
    "an out take must not inherit any mark from its track")
end)

test("an unrelated or missing track sets no mark", function()
  assert(vo.MarkFromTrack("Grumbar REC", {}) == nil)
  assert(vo.MarkFromTrack("", {}) == nil)
  assert(vo.MarkFromTrack(nil, {}) == nil)
end)

--------------------------------
print("TrackForMarks:")

test("Sel goes to Selects and Keep alone goes to Alts", function()
  assert(vo.TrackForMarks({ select = true, keep = true }) == "selects")
  assert(vo.TrackForMarks({ select = true, keep = false }) == "selects",
         "Sel must win over Keep, as in PlanPull")
  assert(vo.TrackForMarks({ select = false, keep = true }) == "alts")
end)

test("no marks is no destination -- the caller hands it back to the parent", function()
  assert(vo.TrackForMarks({ select = false, keep = false }) == nil)
  assert(vo.TrackForMarks({}) == nil)
  assert(vo.TrackForMarks(nil) == nil)
end)


test("an explicit no to Keep is Outs, not nowhere", function()
  -- AJ: unticking Keep is a DECISION now that Outs exists -- the take is
  -- rejected, not merely un-filed. A STORED false is what says so; a stored
  -- nil is a take nobody has ruled on and still goes back to its parent.
  assert(vo.TrackForMarks({ select = false, keep = false },
                          { keep = false }) == "outs")
  assert(vo.TrackForMarks({ select = false, keep = false },
                          { keep = nil }) == nil,
         "never-decided must not be filed as rejected")
  assert(vo.TrackForMarks({ select = false, keep = false }) == nil,
         "no stored marks at all is still no decision")
end)

test("a live tick always beats a stored rejection", function()
  -- Ticking Keep again while a stale false is still stored must read as
  -- Alts, or the box and the track would say different things.
  assert(vo.TrackForMarks({ select = false, keep = true },
                          { keep = false }) == "alts")
  assert(vo.TrackForMarks({ select = true, keep = false },
                          { keep = false }) == "selects")
end)

test("Outs round-trips with MarkFromTrack", function()
  -- The two directions have to agree or an item sorted onto Outs would read
  -- back as something else on the next rebuild.
  local cat = vo.TrackForMarks({ select = false, keep = false }, { keep = false })
  assert(cat == "outs")
  assert(vo.MarkFromTrack("Outs", {}) == "out")
end)

test("it round-trips with MarkFromTrack", function()
  -- The two directions have to agree, or an auto-sorted item would read back
  -- off its new track as a different mark on the very next rebuild.
  local names = { selects = "Selects", alts = "Alts" }
  for _, marks in ipairs({ { select = true, keep = true },
                           { select = false, keep = true } }) do
    local cat = assert(vo.TrackForMarks(marks))
    local back = vo.MarkFromTrack(names[cat], {})
    assert(back == (marks.select and "select" or "keep"),
           "round trip broke at " .. cat .. ": " .. tostring(back))
  end
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

-- A take exists where a marker says it does, so the one take here is a marker
-- and its marks are keyed by the marker id.
local ID_KEY = "tkm|k1"

local function one_take_overview(entries)
  return vo.BuildOverview({
    lines = ID_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 1.0, stop = 2.0, line_idx = 1 },
    } } },
    takes_by_asset = { grum_01 = {
      { id = "k1", start = 1.0, stop = 2.0, source_path = "sess.wav" },
    } },
    entries = entries,
  })
end

test("an explicit no survives as mark_select false, not nil", function()
  local rows = one_take_overview({
    { key = ID_KEY, asset = "grum_01", select = false },
  })
  local row = assert(row_for_key(rows, ID_KEY))
  assert(row.mark_select == false, "mark_select: " .. tostring(row.mark_select))
  assert(row.user_select == false, "user_select: " .. tostring(row.user_select))
end)

test("an absent mark is nil on the row, not false", function()
  local rows = one_take_overview({})
  local row = assert(row_for_key(rows, ID_KEY))
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
  assert(#plan.unbacked_markers == 0 and #plan.orphan_marks == 0)
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


test("a Sel take on Selects is not nagged about Keep", function()
  -- Sel AUTO-TICKS Keep (SetSelect: "Sel is the NARROWER of the two"), and
  -- Pull's own law reads "Selects is Keep and Sel". Judging Keep against the
  -- Alts track anyway flagged every properly-made select as "ticked Keep but
  -- the item is not on the Alts track" -- AJ, live: a finished line reading
  -- "Needs select - Conflict" while its select sat right there.
  local plan = vo.PlanReconcile({
    { item_guid = "g1", track_name = "Selects",
      user_select = true, user_keep = true },
  }, {})
  assert(#plan.disagree == 0,
         "flagged: " .. tostring((plan.disagree[1] or {}).detail))
end)

test("a Sel take on Selects with no Keep is equally fine", function()
  local plan = vo.PlanReconcile({
    { item_guid = "g1", track_name = "Selects",
      user_select = true, user_keep = false },
  }, {})
  assert(#plan.disagree == 0,
         "flagged: " .. tostring((plan.disagree[1] or {}).detail))
end)

test("Keep is still judged everywhere the track does not say Selects", function()
  local plan = vo.PlanReconcile({
    { item_guid = "g1", track_name = "Alts", user_select = false,
      user_keep = false },
  }, {})
  assert(#plan.disagree == 1, "an Alts take not ticked Keep must still speak")
end)

test("a take ticked Sel off the Selects track still speaks", function()
  local plan = vo.PlanReconcile({
    { item_guid = "g1", track_name = "Review", user_select = true },
  }, {})
  assert(#plan.disagree == 1)
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

test("a marker row with no item under it is reported as unbacked", function()
  -- The marker survived (it is in some chunk) but nothing in the project
  -- plays that audio any more -- the item was deleted or trimmed away.
  local plan = vo.PlanReconcile({
    { key = "tkm|k1", marker_id = "k1" },
  }, {})
  assert(#plan.unbacked_markers == 1, "unbacked: " .. #plan.unbacked_markers)
  assert(#plan.orphan_marks == 0, "double-reported as orphan marks too")
end)

test("a marker row WITH an item is not unbacked", function()
  local plan = vo.PlanReconcile({
    { key = "tkm|k1", marker_id = "k1", item_guid = "{A}", track_name = "Review" },
  }, {})
  assert(#plan.unbacked_markers == 0, "a backed marker was reported")
end)

test("an unmarked row with no item is not damage", function()
  -- A script line nobody has recorded yet is the normal case, not a finding.
  local plan = vo.PlanReconcile({ { key = "a|1" } }, {})
  assert(#plan.orphan_marks == 0, "an unrecorded line was reported as damage")
end)


print("\nConfirmedFingerprint:")

local BASE = { source_path = "C:/Au/a.wav", take_name = "line_a",
               start_offs = 1.0, length = 2.0, playrate = 1.0,
               mk_pos = 1.0, mk_len = 2.0, words = {} }
local function with(t)
  local c = {}
  for k, v in pairs(BASE) do c[k] = v end
  for k, v in pairs(t) do c[k] = v end
  return c
end

test("trimming a take does not withdraw its OK", function()
  -- AJ: "we shouldn't automatically uncheck OK when I change item length."
  local stamp = vo.ConfirmedFingerprint(BASE)
  assert(vo.ConfirmedMatches(stamp, with{ length = 5.0, start_offs = 0.4 }),
         "a trim cleared the mark")
  assert(vo.ConfirmedMatches(stamp, with{ mk_pos = 9.0, mk_len = 0.2 }),
         "moving the marker cleared the mark")
end)

test("renaming a take DOES withdraw it -- the name is the assignment", function()
  local stamp = vo.ConfirmedFingerprint(BASE)
  assert(not vo.ConfirmedMatches(stamp, with{ take_name = "line_b" }))
end)

test("different audio withdraws it", function()
  local stamp = vo.ConfirmedFingerprint(BASE)
  assert(not vo.ConfirmedMatches(stamp, with{ source_path = "C:/Au/b.wav" }))
end)

test("an OK stamped in the old Vet format still counts", function()
  -- Nobody's session may empty itself the day this ships.
  local old = vo.VettedFingerprint(BASE)
  assert(vo.ConfirmedMatches(old, BASE), "an untouched old stamp was dropped")
  assert(vo.ConfirmedMatches(old, with{ length = 7.0 }),
         "an old stamp should survive a trim too, now that OK means identity")
  assert(not vo.ConfirmedMatches(old, with{ take_name = "line_b" }),
         "an old stamp must still fall to a rename")
end)

test("Vet keeps the strict fingerprint -- its verdict IS about the window", function()
  local a = vo.VettedFingerprint(BASE)
  assert(a ~= vo.VettedFingerprint(with{ length = 5.0 }))
end)
--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
