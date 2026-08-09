# VO Take Identity and Repair — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a take's link to its REAPER item survive hand-editing, read Sel/Keep decisions back off the Selects/Alts tracks so scrambled marks self-heal, and add a reconciliation pass for damage already done.

**Architecture:** A take row gains an *anchor* — the GUID of the item it owns, plus the source-time edges Cut gave that item. Anchored rows resolve directly to their item instead of guessing by occupancy, and an item whose edges have drifted from its anchor is a hand-edit that Cut must not overwrite. Separately, Sel/Keep become tri-state (yes / no / no-opinion), so a blank can defer to where the item actually sits on the timeline.

**Tech Stack:** Lua 5.4, REAPER API, ReaImGui 0.9.3. Pure logic in `VO/lib/ajsfx_vo.lua`, tested against `tests/mock_reaper.lua` with no REAPER.

Design spec: [`docs/superpowers/specs/2026-08-09-vo-take-identity-and-repair-design.md`](../specs/2026-08-09-vo-take-identity-and-repair-design.md)

## Global Constraints

- **Pure/coupled split is mandatory.** Anything decidable without REAPER goes in the pure layer of `VO/lib/ajsfx_vo.lua` and gets unit tests. Only code that calls `r.*` lives in the coupled layer.
- **`vo.PROJECT_VERSION` stays at `1`.** New columns are appended, never inserted; `vo.ParseProjectFile` reads entry fields by index and a short row yields `nil`.
- **Times are seconds, serialized `"%.3f"`** — matching every other time in these files.
- **Edited-anchor tolerance is `0.010` seconds** at either edge.
- **Track names come from config**, never hardcoded: `cfg.track_selects or "Selects"`, `cfg.track_alts or "Alts"`, `cfg.track_review or "Review"`.
- **Run the whole suite** with `./run_tests.sh` before each commit; every test file must end `0 failed`.
- **Do not bump `@version` until Task 12.** Intermediate commits ship nothing (see `.agents/standards.md` — only a changed `@version` publishes).
- **Never write `e.select or nil`.** With tri-state marks that silently converts an explicit "no" into "no opinion". Use `~= nil` tests and explicit if/else throughout.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `VO/lib/ajsfx_vo.lua` | Pure: file format, mark precedence, edit detection, reconcile planning. Coupled: `ApplyPlan` returning anchors. | Modify |
| `VO/ajsfx_VO_Overview.lua` | Rebuild wiring, Cut protection, row menu, repair panel | Modify |
| `tests/test_vo_identity.lua` | All pure-layer tests for this feature | Create |
| `VO/MANUAL_TEST.md` | REAPER-only paths the mock cannot reach | Modify |
| `VO/SPEC-overview.md` | Document anchors, track marks, repair panel | Modify |

**Phase boundaries.** Tasks 1–9 deliver working software on their own: anchors exist, hand-edits are protected, marks self-heal from tracks. Tasks 10–11 add the repair panel. Task 12 ships. Stopping after Task 9 leaves a coherent, releasable tool.

---

### Task 1: Project file format — anchors and tri-state marks

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (`vo.PROJECT_HEADER` ~line 3413, `vo.SerializeProjectFile` entry loop ~line 3548, `vo.ParseProjectFile` entry loop ~line 3658)
- Test: `tests/test_vo_identity.lua` (create)

**Interfaces:**
- Consumes: nothing (first task)
- Produces: entry fields `anchor` (string GUID or nil), `anchor_start` / `anchor_stop` (number or nil); `select` and `keep` become tri-state `true` / `false` / `nil`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_vo_identity.lua`:

```lua
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
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/test_vo_identity.lua`
Expected: FAIL — anchors come back nil, `select == false` comes back as `nil` or the entry is dropped entirely.

- [ ] **Step 3: Widen the header**

In `VO/lib/ajsfx_vo.lua`, replace `vo.PROJECT_HEADER`:

```lua
vo.PROJECT_HEADER = {
  "Key", "Filename", "Source", "Source start", "Select", "Status",
  "Name override", "Notes", "Keep", "Anchor", "Anchor start", "Anchor stop",
}
```

- [ ] **Step 4: Add the tri-state helpers**

Immediately above `vo.SerializeProjectFile`, add:

```lua
-- Marks are TRI-STATE in the file: "yes", "no", or empty.
--
-- Empty means "no opinion", which is what lets an item's TRACK speak for it
-- (vo.EffectiveMarks). That makes an explicit "no" load-bearing: without a way
-- to say it, un-ticking a take whose item sits on Selects would be re-ticked by
-- the track on the very next rebuild and the un-tick would spring back.
local function mark_to_field(v)
  if v == true  then return "yes" end
  if v == false then return "no"  end
  return ""
end

local function field_to_mark(v)
  v = fold(v or "")
  if v == "yes" then return true  end
  if v == "no"  then return false end
  return nil
end
```

- [ ] **Step 5: Write the new columns and count them as work**

In `vo.SerializeProjectFile`, replace the entry loop body:

```lua
  for _, e in ipairs(entries or {}) do
    -- Only rows carrying actual user work are written. Without this the file
    -- would grow a line per script line per session and the signal would drown.
    -- An explicit "no" IS work -- see mark_to_field -- so these test against
    -- nil rather than truthiness, or the no would be dropped and reappear as a
    -- tick from the track.
    local has_work = e.select ~= nil or e.keep ~= nil
                  or (e.status and e.status ~= "")
                  or (e.name_override and e.name_override ~= "")
                  or (e.notes and e.notes ~= "")
                  -- An anchor is the whole of what binds a take to its item;
                  -- dropping it would unbind every cut take on the next save.
                  or (e.anchor and e.anchor ~= "")
                  -- A planned take's existence IS the work: it derives from
                  -- nothing else, so dropping a bare one would delete the row.
                  or vo.IsPlannedKey(e.key)
    if has_work then
      out[#out + 1] = vo.FormatCSVRow({
        e.key or "",
        e.asset or "",
        e.source or "",
        e.source_start and string.format("%.3f", e.source_start) or "",
        mark_to_field(e.select),
        e.status or "",
        e.name_override or "",
        e.notes or "",
        mark_to_field(e.keep),
        e.anchor or "",
        e.anchor_start and string.format("%.3f", e.anchor_start) or "",
        e.anchor_stop  and string.format("%.3f", e.anchor_stop)  or "",
      })
    end
  end
```

- [ ] **Step 6: Parse the new columns and the tri-state**

In `vo.ParseProjectFile`, replace the entry-building block:

```lua
  for j = header_at + 1, #rows do
    local row = rows[j]
    local key = row[1] or ""
    if key ~= "" then
      local status = fold(row[6] or "")
      -- Two independent marks. 0.13 briefly wrote "alt" in the Select field
      -- before Keep had a column of its own; it reads as a keep, so a file
      -- written by that version keeps the work rather than losing it.
      --
      -- Written as statements, NOT `field_to_mark(row[9]) or legacy`: an
      -- explicit "no" is `false`, and `false or legacy` would evaluate the
      -- legacy branch and turn the user's no into a yes.
      local keep = field_to_mark(row[9])
      if keep == nil and fold(row[5] or "") == "alt" then keep = true end

      parsed.entries[#parsed.entries + 1] = {
        key           = key,
        asset         = row[2] ~= "" and row[2] or nil,
        source        = row[3] ~= "" and row[3] or nil,
        source_start  = tonumber(row[4] or ""),
        select        = field_to_mark(row[5]),
        keep          = keep,
        -- An unrecognised status is dropped rather than carried: it would
        -- otherwise render as an unknown badge with no way to clear it.
        status        = vo.TRACKER_STATUSES[status] and status or nil,
        name_override = row[7] ~= "" and row[7] or nil,
        notes         = row[8] ~= "" and row[8] or nil,
        -- Absent in files written before anchors existed; nil is correct there
        -- and means "this take is not bound to an item".
        anchor        = (row[10] and row[10] ~= "") and row[10] or nil,
        anchor_start  = tonumber(row[11] or ""),
        anchor_stop   = tonumber(row[12] or ""),
      }
    end
  end
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `lua tests/test_vo_identity.lua`
Expected: PASS, `0 failed`.

Then run the whole suite: `./run_tests.sh`
Expected: every file `0 failed`. `tests/test_vo.lua` exercises the project file heavily; if anything there fails it is a real regression in this task, not a stale test.

- [ ] **Step 8: Commit**

```bash
git add tests/test_vo_identity.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: anchor columns and tri-state marks in the project file"
```

---

### Task 2: `vo.IsEditedAnchor`

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (new pure section after `vo.SourceCoverageRanges`)
- Test: `tests/test_vo_identity.lua`

**Interfaces:**
- Consumes: entry fields `anchor_start` / `anchor_stop` from Task 1
- Produces: `vo.IsEditedAnchor(anchor, range, tolerance) -> boolean`, where `anchor` is `{ anchor_start, anchor_stop }` and `range` is `{ from, to }` as `vo.SourceCoverageRanges` returns; `vo.ANCHOR_EDIT_TOLERANCE = 0.010`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo_identity.lua`, before the results line:

```lua
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/test_vo_identity.lua`
Expected: FAIL with `attempt to call a nil value (field 'IsEditedAnchor')`.

- [ ] **Step 3: Implement it**

In `VO/lib/ajsfx_vo.lua`, directly below `vo.SourceCoverageRanges`, add:

```lua
--------------------------------
-- Pure layer: anchors
--------------------------------

-- An ANCHOR binds a take row to one specific REAPER item by the item's GUID,
-- plus the source-time edges Cut gave that item.
--
-- The GUID is the durable half: dragging an edge, moving an item between
-- tracks, and saving and reloading all preserve it, while the source-time key
-- every other part of this tool uses (vo.OverviewKey) changes the moment an
-- edge moves. The EDGES are what make "has the user touched this?" answerable.
--
-- They are the edges the cut PLAN wrote, never the row's own source_start --
-- boundary snapping moves the edges away from the raw match, so comparing
-- against the match would report every untouched item as edited.
vo.ANCHOR_EDIT_TOLERANCE = 0.010  -- seconds at either edge

-- Has the user moved this item's edges since Cut made it?
--
-- `range` is the item's CURRENT source coverage, from vo.SourceCoverageRanges.
-- Returns false when there is nothing to compare -- an anchor with no recorded
-- edges, or an item that is gone. Neither is evidence of an edit: a missing
-- item is a repair-pass finding (see vo.PlanReconcile), and treating it as an
-- edit would make Cut skip takes it should be free to re-cut.
function vo.IsEditedAnchor(anchor, range, tolerance)
  if not anchor or not range then return false end
  local from, to = anchor.anchor_start, anchor.anchor_stop
  if not from or not to then return false end
  local tol = tolerance or vo.ANCHOR_EDIT_TOLERANCE
  return math.abs((range.from or 0) - from) > tol
      or math.abs((range.to   or 0) - to)   > tol
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/test_vo_identity.lua`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add tests/test_vo_identity.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: IsEditedAnchor -- has the user moved this item since Cut"
```

---

### Task 3: `vo.MarkFromTrack` and `vo.EffectiveMarks`

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (pure anchors section from Task 2)
- Test: `tests/test_vo_identity.lua`

**Interfaces:**
- Consumes: tri-state entry marks from Task 1
- Produces: `vo.MarkFromTrack(track_name, cfg) -> "select" | "keep" | nil`; `vo.EffectiveMarks(entry, track_name, cfg) -> { select = boolean, keep = boolean }`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo_identity.lua`, before the results line:

```lua
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/test_vo_identity.lua`
Expected: FAIL with `attempt to call a nil value (field 'MarkFromTrack')`.

- [ ] **Step 3: Implement both functions**

Append to the pure anchors section in `VO/lib/ajsfx_vo.lua`:

```lua
-- THE TRACK IS THE DECISION, alongside the governing idea that the name is the
-- assignment: an item on the Selects track IS the select, one on Alts IS a
-- keep. Pull already writes this direction; this reads it back.
--
-- Track placement is the most damage-resistant signal in the system. Marks live
-- in a source-time key that a re-match can invalidate and item names can be
-- edited by anything, but "this item sits on Selects" survives all of it -- so
-- it is what lets scrambled marks heal themselves.
--
-- The Review track deliberately maps to nothing: it means "undecided, look at
-- this", which is the absence of a decision rather than a mark.
function vo.MarkFromTrack(track_name, cfg)
  if not track_name or track_name == "" then return nil end
  cfg = cfg or {}
  local name = fold(track_name)
  if name == fold(cfg.track_selects or "Selects") then return "select" end
  if name == fold(cfg.track_alts    or "Alts")    then return "keep"   end
  return nil
end

-- What a take's Sel and Keep actually are, given what the user stored and where
-- the item sits. ONE function, so the rule cannot drift between the sheet, Pull
-- and the repair pass.
--
--   1. an explicit decision -- including an explicit NO -- always wins
--   2. otherwise the item's track decides
--   3. otherwise unticked
--
-- Each mark is decided independently: saying "no" to Sel must not stop Keep
-- following an Alts track.
function vo.EffectiveMarks(entry, track_name, cfg)
  local from_track = vo.MarkFromTrack(track_name, cfg)
  local sel, keep
  if entry and entry.select ~= nil then sel  = entry.select
  else                                  sel  = (from_track == "select") end
  if entry and entry.keep   ~= nil then keep = entry.keep
  else                                  keep = (from_track == "keep")   end
  return { select = sel, keep = keep }
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/test_vo_identity.lua`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add tests/test_vo_identity.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: the track is the decision -- MarkFromTrack and EffectiveMarks"
```

---

### Task 4: Carry anchors and stored marks through the row model

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (`vo.BuildOverview` `make_row` ~line 3856, its missing-line branch ~line 3927, `planned_row` from the planned-takes work, `vo.ProjectEntriesFromRows` ~line 3968)
- Test: `tests/test_vo_identity.lua`

**Interfaces:**
- Consumes: `vo.EffectiveMarks` (Task 3), entry fields (Task 1)
- Produces: rows carry `mark_select` / `mark_keep` (tri-state, what gets persisted) and `anchor` / `anchor_start` / `anchor_stop`. `user_select` / `user_keep` stay booleans and become the EFFECTIVE values, which the coupled layer overwrites in Task 6.

**Why two pairs of fields:** `user_select` is what the checkbox and Pull read; `mark_select` is what gets written back to the file. Keeping them separate is what stops an *inferred* tick (from a track) being persisted as an *explicit* one, which would freeze the inference and make it unclearable.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo_identity.lua`, before the results line:

```lua
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

test("a take row carries its anchor out of the entry", function()
  local rows = vo.BuildOverview({
    lines = ID_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 1.0, stop = 2.0, line_idx = 1 },
    } } },
    entries = { { key = "sess.wav|1000", asset = "grum_01",
                  anchor = "{G1}", anchor_start = 0.9, anchor_stop = 2.1 } },
  })
  local row = assert(row_for_key(rows, "sess.wav|1000"), "row missing")
  assert(row.anchor == "{G1}", "anchor: " .. tostring(row.anchor))
  assert(math.abs(row.anchor_start - 0.9) < 1e-6, "anchor_start lost")
  assert(math.abs(row.anchor_stop - 2.1) < 1e-6, "anchor_stop lost")
end)

test("an explicit no survives as mark_select false, not nil", function()
  local rows = vo.BuildOverview({
    lines = ID_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 1.0, stop = 2.0, line_idx = 1 },
    } } },
    entries = { { key = "sess.wav|1000", asset = "grum_01", select = false } },
  })
  local row = assert(row_for_key(rows, "sess.wav|1000"))
  assert(row.mark_select == false, "mark_select: " .. tostring(row.mark_select))
  assert(row.user_select == false, "user_select: " .. tostring(row.user_select))
end)

test("an absent mark is nil on the row, not false", function()
  local rows = vo.BuildOverview({
    lines = ID_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 1.0, stop = 2.0, line_idx = 1 },
    } } },
    entries = {},
  })
  local row = assert(row_for_key(rows, "sess.wav|1000"))
  assert(row.mark_select == nil, "mark_select: " .. tostring(row.mark_select))
  assert(row.user_select == false, "user_select should be a boolean for the UI")
end)

test("ProjectEntriesFromRows writes the stored mark, never the effective one", function()
  -- The row's user_select is what the TRACK inferred; persisting that would
  -- freeze an inference into an explicit decision nobody made.
  local entries = vo.ProjectEntriesFromRows({
    { key = "sess.wav|1000", mark_select = nil, user_select = true,
      mark_keep = false, user_keep = false,
      anchor = "{G1}", anchor_start = 0.9, anchor_stop = 2.1 },
  })
  assert(#entries == 1, "entry count: " .. #entries)
  assert(entries[1].select == nil, "inferred tick was persisted: " .. tostring(entries[1].select))
  assert(entries[1].keep == false, "explicit no lost: " .. tostring(entries[1].keep))
  assert(entries[1].anchor == "{G1}", "anchor lost")
  assert(math.abs(entries[1].anchor_start - 0.9) < 1e-6, "anchor_start lost")
end)

test("an anchor survives a full row round trip", function()
  local text = vo.SerializeProjectFile(vo.ProjectEntriesFromRows({
    { key = "sess.wav|1000", anchor = "{G1}", anchor_start = 0.9, anchor_stop = 2.1 },
  }), EMPTY_META)
  local e = assert(only_entry(text, "sess.wav|1000"), "entry dropped")
  assert(e.anchor == "{G1}", "anchor lost in round trip")
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/test_vo_identity.lua`
Expected: FAIL — `row.anchor` is nil and `mark_select` does not exist.

- [ ] **Step 3: Carry the fields in `make_row`**

In `vo.BuildOverview`, in `make_row`, replace the two mark lines at the end of the returned table:

```lua
      -- The STORED marks, tri-state: true / false / nil for "no opinion".
      -- Written back by vo.ProjectEntriesFromRows.
      mark_select   = t and t.select,
      mark_keep     = t and t.keep,
      -- The EFFECTIVE marks, always boolean, for the checkbox and for Pull.
      -- The coupled layer recomputes these through vo.EffectiveMarks once it
      -- knows which track the item sits on; this is the no-item answer.
      user_select   = (t and t.select) == true,
      user_keep     = (t and t.keep) == true,
      anchor        = t and t.anchor,
      anchor_start  = t and t.anchor_start,
      anchor_stop   = t and t.anchor_stop,
```

- [ ] **Step 4: Carry them in the missing-line branch too**

In the same function, in the `else` branch that builds a row for a line with no takes, replace its two mark lines:

```lua
        mark_select   = t and t.select,
        mark_keep     = t and t.keep,
        user_select   = (t and t.select) == true,
        user_keep     = (t and t.keep) == true,
        anchor        = t and t.anchor,
        anchor_start  = t and t.anchor_start,
        anchor_stop   = t and t.anchor_stop,
```

- [ ] **Step 5: Carry them in `planned_row`**

In the same function, in `planned_row`, replace its two mark lines:

```lua
      mark_select   = e.select,
      mark_keep     = e.keep,
      user_select   = e.select == true,
      user_keep     = e.keep == true,
      anchor        = e.anchor,
      anchor_start  = e.anchor_start,
      anchor_stop   = e.anchor_stop,
```

- [ ] **Step 6: Persist the stored marks, not the effective ones**

Replace the body of `vo.ProjectEntriesFromRows`:

```lua
function vo.ProjectEntriesFromRows(rows)
  local entries = {}
  for _, row in ipairs(rows or {}) do
    entries[#entries + 1] = {
      key           = row.key,
      source        = row.source_path,
      source_start  = row.source_start,
      asset         = row.asset,
      -- The STORED mark, never row.user_select: that one may have been
      -- inferred from the item's track, and writing an inference down as an
      -- explicit decision would make it permanent and unclearable.
      select        = row.mark_select,
      keep          = row.mark_keep,
      status        = row.user_status,
      name_override = row.name_override,
      notes         = row.notes,
      anchor        = row.anchor,
      anchor_start  = row.anchor_start,
      anchor_stop   = row.anchor_stop,
    }
  end
  return entries
end
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `lua tests/test_vo_identity.lua`
Expected: PASS, `0 failed`.

Then: `./run_tests.sh` — expect every file `0 failed`. `tests/test_vo.lua` and `tests/test_vo_planned.lua` both build overviews and will catch a dropped field.

- [ ] **Step 8: Commit**

```bash
git add tests/test_vo_identity.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: rows carry anchors and stored tri-state marks"
```

---

### Task 5: Anchor every take Cut creates

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (`CutCandidates` ~line 2739, `DoCut` ~line 2883)
- Modify: `VO/lib/ajsfx_vo.lua` (`vo.ApplyPlan` ~line 6031)

**Interfaces:**
- Consumes: entry anchor fields (Task 1)
- Produces: `vo.ApplyPlan(plan, source_track) -> applied, failures, anchors` where `anchors` is `{ [row_key] = { guid, start, stop } }`

**The hazard this task exists to avoid:** `vo.ApplyPadding` mutates `span.start` and `span.stop` in place — boundary snapping *is* that mutation. A row key derived inside `ApplyPlan` would be built from the post-snap value and bind every anchor to a row that does not exist, silently. The key is therefore stamped in `CutCandidates`, where the span is already joined to its row, before any padding runs.

- [ ] **Step 1: Stamp the row key onto each span before padding**

In `VO/ajsfx_VO_Overview.lua`, in `CutCandidates`, inside the `for _, s in ipairs(all_spans)` loop, extend the existing row lookup:

```lua
    local key = start_key(s.source_path, s.start)
    local row = by_start[key]
    if row then
      s.select = row.user_select == true
      -- The row this span belongs to, captured HERE and not later: ApplyPadding
      -- mutates s.start on its way to ApplyPlan, so a key derived downstream
      -- would name a row that does not exist. Taken from the row itself rather
      -- than recomputed, so it cannot disagree with the row's own identity.
      s.row_key = row.key
    end
```

- [ ] **Step 2: Return the anchors from `ApplyPlan`**

In `VO/lib/ajsfx_vo.lua`, in `vo.ApplyPlan`, add the collector and record each created item. Change the opening:

```lua
function vo.ApplyPlan(plan, source_track)
  local applied = 0
  local failures = {}
  -- Which item each span became, keyed by the row key stamped before padding.
  -- This is the ONLY moment the binding is known for certain -- afterwards it
  -- can only be inferred by occupancy, which is what anchors exist to replace.
  local anchors = {}
```

Then, immediately after the `P_NAME` write inside the `else` branch, add:

```lua
      -- Anchor the take to the item just made for it. Read after the splits, so
      -- the GUID is the piece's own and not the item it was cut from.
      if span.row_key then
        local got, guid = r.GetSetMediaItemInfo_String(piece, "GUID", "", false)
        if got and guid ~= "" then
          anchors[span.row_key] =
            { guid = guid, start = span.start, stop = span.stop }
        end
      end
```

And the return:

```lua
  r.UpdateArrange()
  return applied, failures, anchors
end
```

- [ ] **Step 3: Write the anchors onto the entries after the cut**

In `VO/ajsfx_VO_Overview.lua`, in `DoCut`, replace the transaction block:

```lua
  -- One transaction around every split and rename, so the run is one undo step.
  local applied, failures = 0, {}
  local anchors = {}
  core.Transaction("VO Overview: cut and name", function()
    for _, g in pairs(by_item) do
      local a, f, anc = vo.ApplyPlan(g.spans, g.info.track)
      applied = applied + a
      for _, msg in ipairs(f) do failures[#failures + 1] = msg end
      for key, rec in pairs(anc or {}) do anchors[key] = rec end
    end
  end)

  -- Bind each cut take to the item it became. Written straight to the entries
  -- rather than through Mutate, which rebuilds the whole match per call: forty
  -- rebuilds for one press, each invalidating the rows still to be anchored.
  local anchored = 0
  for key, rec in pairs(anchors) do
    local entry
    for _, e in ipairs(state.entries) do
      if e.key == key then entry = e break end
    end
    if not entry then
      entry = { key = key }
      state.entries[#state.entries + 1] = entry
    end
    entry.anchor       = rec.guid
    entry.anchor_start = rec.start
    entry.anchor_stop  = rec.stop
    anchored = anchored + 1
  end
  if anchored > 0 then state.dirty = true end
```

- [ ] **Step 4: Verify it parses and the suite still passes**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && lua -e "assert(loadfile('VO/lib/ajsfx_vo.lua'))"`
Expected: no output, exit 0.

Run: `./run_tests.sh`
Expected: every file `0 failed`. `vo.ApplyPlan`'s extra return value is additive, so existing callers are unaffected.

**No unit test here, deliberately.** Every line of this task calls `r.*` —
`SplitMediaItem`, `GetSetMediaItemInfo_String` — so the mock cannot reach it,
and a pure test asserting "`span.row_key` survives mutating `span.start`" would
be testing Lua's field semantics rather than this code. The invariant is
covered instead by manual test 1 in Task 12, which checks the anchor lands on
the *right row* — if the key were derived post-padding, the anchors would
attach to rows that do not exist and the sheet would show none.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: Cut anchors every take to the item it created"
```

---

### Task 6: Resolve by anchor, and apply track-derived marks

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (`Rebuild` ~line 600, after the name-adoption block ~line 713)

**Interfaces:**
- Consumes: `vo.EffectiveMarks` (Task 3), row anchor fields (Task 4)
- Produces: every row carries `item` (resolved), `track_name` (string or nil), `anchor_missing` (boolean), `edited` (boolean); `user_select` / `user_keep` become the effective marks

- [ ] **Step 1: Resolve anchored rows before anything else**

In `VO/ajsfx_VO_Overview.lua`, in `Rebuild`, immediately *before* the existing "Name-based fallback for the rows" block, insert:

```lua
  -- Anchored rows resolve by GUID, before any inference runs.
  --
  -- This is the whole point of anchors: vo.ResolveSourceSpan picks whichever
  -- item is most occupied by the take's span, which is a good guess but still a
  -- guess -- and after a hand-edit it can answer with a neighbour, a leftover,
  -- or nothing. A GUID cannot be wrong.
  local by_guid = {}
  for _, info in ipairs(state.items or {}) do
    if info.item then
      local got, guid = r.GetSetMediaItemInfo_String(info.item, "GUID", "", false)
      if got and guid ~= "" then by_guid[guid] = info end
    end
  end
  for _, row in ipairs(state.overview) do
    if row.anchor then
      local info = by_guid[row.anchor]
      if info then
        row.item      = info.item
        row.item_info = info
        -- A take whose item's edges no longer match what Cut wrote has been
        -- hand-edited. Cut must not overwrite it (Task 8), and the repair pass
        -- reports it.
        row.edited = vo.IsEditedAnchor(row,
                                       vo.SourceCoverageRanges({ info })[1])
      else
        -- The anchor names an item this project no longer has: deleted,
        -- re-recorded, or split so the GUID moved. Left unresolved for the
        -- fallbacks below and flagged for the repair pass.
        row.anchor_missing = true
      end
    end
  end
```

- [ ] **Step 2: Read each resolved item's track and apply the effective marks**

In `Rebuild`, immediately *after* the "Whatever is STILL in the pool" extra-rows block and *before* the out-of-band rename detection, insert:

```lua
  -- Where each row's item actually sits, and what that says about its marks.
  --
  -- Runs last, after every path that can give a row an item (anchor, span,
  -- name adoption, extra rows), so no row is judged on a track it has not been
  -- resolved onto yet.
  local track_name_of = {}
  for _, row in ipairs(state.overview) do
    if row.item then
      local track = r.GetMediaItem_Track(row.item)
      if track then
        local cached = track_name_of[track]
        if cached == nil then
          local _, tname = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
          cached = tname or ""
          track_name_of[track] = cached
        end
        row.track_name = cached
      end
    end
    local marks = vo.EffectiveMarks(
      { select = row.mark_select, keep = row.mark_keep }, row.track_name, cfg)
    row.user_select, row.user_keep = marks.select, marks.keep
  end
```

- [ ] **Step 3: Verify it parses and the suite passes**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))"`
Expected: no output, exit 0.

Run: `./run_tests.sh`
Expected: every file `0 failed`.

- [ ] **Step 4: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: resolve anchored rows by GUID and tick marks from the track"
```

---

### Task 7: Un-ticking writes an explicit no

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (`SetSelect` ~line 899, `SetKeep` just below it)

**Interfaces:**
- Consumes: `vo.MarkFromTrack` (Task 3), `row.track_name` (Task 6)
- Produces: nothing new; changes what `SetSelect` / `SetKeep` persist

**Why:** without this, un-ticking a take whose item sits on Selects writes `nil`, the track re-infers the tick on the next rebuild, and the un-tick springs back within a frame.

- [ ] **Step 1: Read the current implementations**

Run: `grep -n "local function SetSelect" -A 20 VO/ajsfx_VO_Overview.lua`
Note the exclusivity loop in `SetSelect` — it must be preserved exactly; only the final `Mutate` changes.

- [ ] **Step 2: Replace the final Mutate in `SetSelect`**

Replace the single line `Mutate(row, function(e) e.select = on or nil end)` with:

```lua
  -- Ticking stores yes. UN-ticking stores an explicit NO when the item's track
  -- would otherwise re-tick it (vo.EffectiveMarks rule 2), and nothing at all
  -- when it would not -- so files do not grow rows that say nothing.
  local cfg = vo.LoadConfig()
  Mutate(row, function(e)
    if on then
      e.select = true
    elseif vo.MarkFromTrack(row.track_name, cfg) == "select" then
      e.select = false
    else
      e.select = nil
    end
  end)
```

- [ ] **Step 3: Replace the equivalent line in `SetKeep`**

```lua
  local cfg = vo.LoadConfig()
  Mutate(row, function(e)
    if on then
      e.keep = true
    elseif vo.MarkFromTrack(row.track_name, cfg) == "keep" then
      e.keep = false
    else
      e.keep = nil
    end
  end)
```

- [ ] **Step 4: Verify it parses and the suite passes**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && ./run_tests.sh`
Expected: parses clean, every file `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: un-ticking a mark writes an explicit no when the track would re-tick it"
```

---

### Task 8: Cut skips hand-edited takes

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (`CutCandidates` ~line 2739, `DoCut` summary, the Cut panel button ~line 3544)

**Interfaces:**
- Consumes: `row.edited` (Task 6)
- Produces: `state.cut_skipped_edited` — array of take names skipped this run, read by the panel to offer *Re-cut anyway*; `state.force_recut` — boolean the next run consumes

- [ ] **Step 1: Skip edited rows when gathering candidates**

In `CutCandidates`, inside the `if in_range[key] then` branch, add the edited test ahead of the stale test:

```lua
      if in_range[key] then
        counts.in_range = counts.in_range + 1
        -- A take whose item the user has moved is THEIR edit, and re-cutting
        -- would silently throw it away. Skipped unless the run is a deliberate
        -- Re-cut anyway, which clears the anchors first.
        if row and row.edited and not state.force_recut then
          counts.edited = (counts.edited or 0) + 1
          edited_names[#edited_names + 1] =
            row.deliver or row.asset or "(unnamed)"
        elseif stale_paths[s.source_path] then
          counts.stale = counts.stale + 1
        else
          s.in_range = true
          candidates[#candidates + 1] = s
        end
      end
```

Declare the collector beside `candidates` and initialise the count:

```lua
  local counts = { spans = #all_spans, cuttable = 0, in_range = 0, stale = 0, edited = 0 }
  local candidates = {}
  local edited_names = {}
```

And return it:

```lua
  return candidates, all_spans, stale_names, counts, edited_names
```

- [ ] **Step 2: Report the skip and arm the override**

In `DoCut`, capture the new return value and record it:

```lua
  local candidates, all_spans, stale_names, _counts, edited_names = CutCandidates()
  state.cut_skipped_edited = edited_names or {}
  -- The override is consumed by the run it was armed for, never the next one.
  state.force_recut = false
```

After `state.cut_summary` is built, append the skip line:

```lua
  if #state.cut_skipped_edited > 0 then
    table.insert(state.cut_summary, {
      text = string.format(
        "%d take(s) skipped -- you had edited them: %s",
        #state.cut_skipped_edited,
        table.concat(state.cut_skipped_edited, ", ")),
      warn = true,
    })
  end
```

- [ ] **Step 3: Offer Re-cut anyway in the Cut panel**

Beside the existing Cut button, add:

```lua
  if #(state.cut_skipped_edited or {}) > 0 then
    im.SameLine(ctx)
    if im.Button(ctx, "Re-cut anyway") then
      pending_action = function()
        -- Clear the anchors of exactly the skipped takes, so they cut as
        -- unbound spans and are re-anchored to their new items. Rows the user
        -- did not edit keep theirs.
        local doomed = {}
        for _, name in ipairs(state.cut_skipped_edited) do doomed[name] = true end
        for _, row in ipairs(state.overview) do
          if row.edited and doomed[row.deliver or row.asset or ""] then
            for _, e in ipairs(state.entries) do
              if e.key == row.key then
                e.anchor, e.anchor_start, e.anchor_stop = nil, nil, nil
              end
            end
          end
        end
        state.dirty = true
        state.force_recut = true
        DoCut()
      end
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Re-cut the takes you had edited, discarding those edits.\n" ..
                         "Their anchors are cleared and rebound to the new clips.")
    end
  end
```

- [ ] **Step 4: Verify it parses and the suite passes**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && ./run_tests.sh`
Expected: parses clean, every file `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: Cut skips hand-edited takes and offers Re-cut anyway"
```

---

### Task 9: Anchor to selected item, from the take row

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (`DrawTakeRowMenu`)

**Interfaces:**
- Consumes: entry anchor fields (Task 1), `vo.SourceCoverageRanges`
- Produces: nothing consumed downstream; this is the manual escape hatch and the repair pass's *Relink* action

- [ ] **Step 1: Find the take row menu**

Run: `grep -n "local function DrawTakeRowMenu" -A 12 VO/ajsfx_VO_Overview.lua`

- [ ] **Step 2: Add the two menu items**

Inside `DrawTakeRowMenu`, add:

```lua
  local n_sel = r.CountSelectedMediaItems(0)
  if im.MenuItem(ctx, "Anchor to selected item", nil, nil, n_sel == 1) then
    local captured = row
    pending_action = function() AnchorRowToSelection(captured) end
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, n_sel == 1
      and ("Bind this take to the item selected in REAPER. It will then follow\n" ..
           "that item wherever you move or trim it, and Cut will leave it alone.")
      or  "Select exactly one item in REAPER first.")
  end
  if im.MenuItem(ctx, "Clear anchor", nil, nil, row.anchor ~= nil) then
    local captured = row
    pending_action = function()
      for _, e in ipairs(state.entries) do
        if e.key == captured.key then
          e.anchor, e.anchor_start, e.anchor_stop = nil, nil, nil
        end
      end
      state.dirty = true
      Reload()
      state.message, state.message_kind = "Anchor cleared.", "ok"
    end
  end
```

- [ ] **Step 3: Implement `AnchorRowToSelection`**

**Where this goes matters.** Put it immediately after `EntryFor`
(`VO/ajsfx_VO_Overview.lua:885`) — *not* beside `DrawTakeRowMenu` at line 3740.
Lua resolves names lexically at compile time, so a function defined at 3740
would be invisible to `DrawRepairPanel` (Task 11), which sits with the other
panels around line 3318: the reference there would compile as a *global*, be
`nil`, and fail only when the button is pressed. The codebase already carries
this scar — see the note about `ctx` binding as a nil global in the cards
section. `EntryFor` at 885 is the latest dependency it has, so directly below
that is the earliest safe home.

Add:

```lua
-- Bind a take row to the item selected in REAPER.
--
-- The manual counterpart to the anchoring Cut does automatically: for audio
-- this tool did not create -- a hand-comp, a rendered file, a re-record -- and
-- the fix the repair pass offers for a row whose anchor has gone stale.
--
-- The recorded edges are the item's CURRENT ones, so a freshly anchored take
-- reads as unedited: the user has just declared this geometry correct.
local function AnchorRowToSelection(row)
  if r.CountSelectedMediaItems(0) ~= 1 then
    state.message, state.message_kind =
      "Select exactly one item in REAPER to anchor this take to.", "warn"
    return
  end
  local item = r.GetSelectedMediaItem(0, 0)
  local got, guid = r.GetSetMediaItemInfo_String(item, "GUID", "", false)
  if not got or guid == "" then
    state.message, state.message_kind = "That item has no GUID to anchor to.", "error"
    return
  end

  local take = r.GetActiveTake(item)
  local info = {
    start_offs = take and r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0,
    length     = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
    playrate   = take and r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1.0,
  }
  local range = vo.SourceCoverageRanges({ info })[1]

  local e = EntryFor(row)
  e.anchor       = guid
  e.anchor_start = range and range.from or nil
  e.anchor_stop  = range and range.to   or nil
  state.dirty = true
  Reload()
  state.message, state.message_kind = string.format(
    "Anchored %s to the selected item.", row.deliver or row.asset or "take"), "ok"
end
```

- [ ] **Step 4: Verify it parses and the suite passes**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && ./run_tests.sh`
Expected: parses clean, every file `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: Anchor to selected item and Clear anchor on the take row"
```

**Phase 1+2 complete.** Anchors exist, hand-edits are protected, marks self-heal from tracks. This is releasable on its own.

---

### Task 10: `vo.PlanReconcile`

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (pure anchors section)
- Test: `tests/test_vo_identity.lua`

**Interfaces:**
- Consumes: rows carrying `anchor`, `anchor_missing`, `item_guid`, `track_name`, `mark_select`, `user_select` (Tasks 4 and 6)
- Produces: `vo.PlanReconcile(rows, cfg) -> { disagree, missing_anchor, doubled, orphan_marks }`, each an array of `{ row, detail }`

**Note on the fifth spec category** ("an item named for a line that no row claims"): that is already surfaced by `vo.CheckCoverage` as `state.check.extra`, and the existing adoption path in `Rebuild` handles it. The panel links to it rather than recomputing it — see Task 11.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo_identity.lua`, before the results line:

```lua
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

test("a missing anchor is reported", function()
  local plan = vo.PlanReconcile({
    { key = "a|1", anchor = "{GONE}", anchor_missing = true },
  }, {})
  assert(#plan.missing_anchor == 1, "missing: " .. #plan.missing_anchor)
end)

test("two rows anchored to one item are reported together", function()
  local plan = vo.PlanReconcile({
    { key = "a|1", anchor = "{A}", item_guid = "{A}" },
    { key = "a|2", anchor = "{A}", item_guid = "{A}" },
  }, {})
  assert(#plan.doubled == 1, "doubled groups: " .. #plan.doubled)
  assert(#plan.doubled[1].rows == 2, "rows in group: " .. #plan.doubled[1].rows)
end)

test("marks with no item and no anchor are reported as damage", function()
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `lua tests/test_vo_identity.lua`
Expected: FAIL with `attempt to call a nil value (field 'PlanReconcile')`.

- [ ] **Step 3: Implement it**

Append to the pure anchors section in `VO/lib/ajsfx_vo.lua`:

```lua
-- What the sheet and the timeline disagree about, and what is simply broken.
--
-- Pure: it reads rows that already carry their resolved item's GUID and track
-- name (the coupled layer puts those there), so the whole reconciliation is
-- testable without REAPER.
--
-- Returns four independent lists rather than one flat one, because each has a
-- different fix and the panel shows only the non-empty ones:
--
--   disagree       -- the sheet says one thing, the item's track says another
--   missing_anchor -- the anchor names an item this project no longer has
--   doubled        -- two rows claim the same item
--   orphan_marks   -- marks on a row with no item and no anchor: damage done
--                     before anchors existed, or by a re-match that moved a
--                     boundary past the rematch tolerance
function vo.PlanReconcile(rows, cfg)
  local plan = { disagree = {}, missing_anchor = {}, doubled = {}, orphan_marks = {} }
  local by_anchor = {}

  for _, row in ipairs(rows or {}) do
    if row.anchor_missing then
      plan.missing_anchor[#plan.missing_anchor + 1] =
        { row = row, detail = "anchored item is gone" }
    end

    if row.anchor then
      by_anchor[row.anchor] = by_anchor[row.anchor] or {}
      table.insert(by_anchor[row.anchor], row)
    end

    -- Only rows that HAVE an item can disagree with where it sits.
    if row.item_guid then
      local from_track = vo.MarkFromTrack(row.track_name, cfg)
      local wants_sel  = (from_track == "select")
      local wants_keep = (from_track == "keep")
      if (row.user_select == true) ~= wants_sel then
        plan.disagree[#plan.disagree + 1] = { row = row, detail = wants_sel
          and "on the Selects track but not ticked Sel"
          or  "ticked Sel but the item is not on the Selects track" }
      elseif (row.user_keep == true) ~= wants_keep then
        plan.disagree[#plan.disagree + 1] = { row = row, detail = wants_keep
          and "on the Alts track but not ticked Keep"
          or  "ticked Keep but the item is not on the Alts track" }
      end
    elseif row.mark_select ~= nil or row.mark_keep ~= nil
           or (row.notes and row.notes ~= "") or row.user_status then
      -- Marks with nothing to attach to. An UNMARKED row with no item is just
      -- a line nobody has recorded yet, which is not a finding.
      if not row.anchor then
        plan.orphan_marks[#plan.orphan_marks + 1] =
          { row = row, detail = "marks with no item" }
      end
    end
  end

  for guid, list in pairs(by_anchor) do
    if #list > 1 then
      plan.doubled[#plan.doubled + 1] = { guid = guid, rows = list }
    end
  end

  return plan
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `lua tests/test_vo_identity.lua`
Expected: PASS, `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add tests/test_vo_identity.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: PlanReconcile -- what the sheet and the timeline disagree about"
```

---

### Task 11: The repair panel

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (`Rebuild` — stamp `item_guid`; the panel list ~line 178; a new `DrawRepairPanel`; the toolbar)

**Interfaces:**
- Consumes: `vo.PlanReconcile` (Task 10), `AnchorRowToSelection` (Task 9)
- Produces: `state.panel == "repair"`

- [ ] **Step 1: Stamp `item_guid` onto rows**

In `Rebuild`, in the track-reading loop added in Task 6, record the GUID as well so `PlanReconcile` can stay pure:

```lua
  for _, row in ipairs(state.overview) do
    if row.item then
      local gok, gguid = r.GetSetMediaItemInfo_String(row.item, "GUID", "", false)
      if gok and gguid ~= "" then row.item_guid = gguid end
      local track = r.GetMediaItem_Track(row.item)
```

(the rest of that loop is unchanged)

- [ ] **Step 2: Add "repair" to the panel comment and the toolbar**

Update the `panel` field comment in `state` to `-- "script" | "cut" | "pull" | "sort" | "repair"`.

Beside the other panel buttons in the toolbar, add:

```lua
  im.SameLine(ctx)
  if im.Button(ctx, "Repair") then
    state.panel = (state.panel == "repair") and nil or "repair"
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Where the sheet and the timeline disagree, and what is broken.")
  end
```

- [ ] **Step 3: Write the panel**

Place it directly after `DrawPullPanel` (`VO/ajsfx_VO_Overview.lua:3318`) — with
the other panels and comfortably above the dispatch at line 5286. It depends on
`Mutate`, `Reload`, `pending_action` and `AnchorRowToSelection`, all of which
live at or below line 885, so they are in scope from here. Add:

```lua
-- Reconciliation, not repair-by-magic: two sources of truth for what a take is
-- and where it belongs, and a button for each direction. Nothing here acts
-- without a press, and every finding can be clicked to go and look at it.
local function DrawRepairPanel()
  local cfg  = vo.LoadConfig()
  local plan = vo.PlanReconcile(state.overview, cfg)
  local total = #plan.disagree + #plan.missing_anchor
              + #plan.doubled + #plan.orphan_marks

  if total == 0 then
    im.TextColored(ctx, 0x66BB66FF,
      "Nothing to repair: every take agrees with the timeline.")
    return
  end

  local function GoTo(row)
    state.selection     = { [row.uid] = true }
    state.focus_key     = row.uid
    state.scroll_to_uid = row.uid
    state.scroll_to_frames = 2
  end

  -- 1. The sheet and the timeline disagree.
  if #plan.disagree > 0 then
    im.TextColored(ctx, 0xDDAA33FF, string.format(
      "%d take(s) disagree with where their item sits:", #plan.disagree))
    for i, f in ipairs(plan.disagree) do
      if i > 12 then
        im.TextDisabled(ctx, string.format("   ...and %d more", #plan.disagree - 12))
        break
      end
      im.Bullet(ctx)
      im.SameLine(ctx)
      if im.SmallButton(ctx, string.format("%s -- %s##dis%d",
          f.row.deliver or f.row.asset or "(unnamed)", f.detail, i)) then
        local captured = f.row
        pending_action = function() GoTo(captured) end
      end
    end
    if im.Button(ctx, "Adopt timeline") then
      pending_action = function()
        -- The tracks win: write the mark each item's placement implies as an
        -- EXPLICIT decision, so the result is stable and not re-inferred.
        local n = 0
        for _, f in ipairs(plan.disagree) do
          local want = vo.MarkFromTrack(f.row.track_name, cfg)
          local captured = f.row
          Mutate(captured, function(e)
            e.select = (want == "select") or nil
            e.keep   = (want == "keep")   or nil
          end)
          n = n + 1
        end
        state.message, state.message_kind = string.format(
          "Adopted the timeline for %d take(s).", n), "ok"
      end
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Set each take's Sel/Keep to match the track its item is on.")
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Adopt sheet") then
      state.panel = "pull"
      state.message, state.message_kind =
        "Run Pull to move the items to match the sheet.", "info"
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "The marks are right; the items are in the wrong place.\n" ..
                         "Opens the Pull panel, which is what moves them.")
    end
    im.Separator(ctx)
  end

  -- 2. Anchors pointing at items that are gone.
  if #plan.missing_anchor > 0 then
    im.TextColored(ctx, 0xDD6666FF, string.format(
      "%d take(s) anchored to an item this project no longer has:",
      #plan.missing_anchor))
    for i, f in ipairs(plan.missing_anchor) do
      if i > 12 then
        im.TextDisabled(ctx, string.format("   ...and %d more", #plan.missing_anchor - 12))
        break
      end
      im.Bullet(ctx)
      im.SameLine(ctx)
      im.TextDisabled(ctx, f.row.deliver or f.row.asset or "(unnamed)")
      im.SameLine(ctx)
      if im.SmallButton(ctx, "Relink##rel" .. i) then
        local captured = f.row
        pending_action = function() AnchorRowToSelection(captured) end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, "Bind it to the item selected in REAPER.")
      end
    end
    if im.Button(ctx, "Clear all dead anchors") then
      pending_action = function()
        local n = 0
        for _, f in ipairs(plan.missing_anchor) do
          for _, e in ipairs(state.entries) do
            if e.key == f.row.key then
              e.anchor, e.anchor_start, e.anchor_stop = nil, nil, nil
              n = n + 1
            end
          end
        end
        state.dirty = true
        Reload()
        state.message, state.message_kind = string.format(
          "Cleared %d dead anchor(s). Those takes resolve by match again.", n), "ok"
      end
    end
    im.Separator(ctx)
  end

  -- 3. Two rows claiming one item.
  if #plan.doubled > 0 then
    im.TextColored(ctx, 0xDDAA33FF, string.format(
      "%d item(s) claimed by more than one take:", #plan.doubled))
    for gi, g in ipairs(plan.doubled) do
      for ri, row in ipairs(g.rows) do
        im.Bullet(ctx)
        im.SameLine(ctx)
        im.TextDisabled(ctx, row.deliver or row.asset or "(unnamed)")
        im.SameLine(ctx)
        if im.SmallButton(ctx, string.format("Keep this one##keep%d_%d", gi, ri)) then
          local keeper, group = row, g.rows
          pending_action = function()
            for _, other in ipairs(group) do
              if other.key ~= keeper.key then
                for _, e in ipairs(state.entries) do
                  if e.key == other.key then
                    e.anchor, e.anchor_start, e.anchor_stop = nil, nil, nil
                  end
                end
              end
            end
            state.dirty = true
            Reload()
            state.message, state.message_kind =
              "Anchor kept on one take; the others were cleared.", "ok"
          end
        end
      end
    end
    im.Separator(ctx)
  end

  -- 4. Marks with nothing to attach to.
  if #plan.orphan_marks > 0 then
    im.TextColored(ctx, 0xDDAA33FF, string.format(
      "%d take(s) carry marks but have no audio in this project:",
      #plan.orphan_marks))
    for i, f in ipairs(plan.orphan_marks) do
      if i > 12 then
        im.TextDisabled(ctx, string.format("   ...and %d more", #plan.orphan_marks - 12))
        break
      end
      im.Bullet(ctx)
      im.SameLine(ctx)
      im.TextDisabled(ctx, f.row.deliver or f.row.asset or "(unnamed)")
      im.SameLine(ctx)
      if im.SmallButton(ctx, "Relink##orph" .. i) then
        local captured = f.row
        pending_action = function() AnchorRowToSelection(captured) end
      end
    end
    im.TextDisabled(ctx,
      "These are usually a re-match that moved a boundary further than the\n" ..
      "half-second rematch window. Relink one to the item it belongs to, or\n" ..
      "clear its marks on the row itself.")
  end

  -- The fifth thing worth knowing about is computed elsewhere: items named for
  -- a line that no row claims are already counted by vo.CheckCoverage and
  -- adopted by Rebuild, so this points at that rather than recomputing it.
  if #(state.check.extra or {}) > 0 then
    im.Separator(ctx)
    im.TextDisabled(ctx, string.format(
      "%d item name(s) are not on the script -- see the summary line above.",
      #state.check.extra))
  end
end
```

- [ ] **Step 4: Draw it where the other panels draw**

Find the `if state.panel == "cut" then` chain and add:

```lua
  elseif state.panel == "repair" then
    DrawRepairPanel()
```

- [ ] **Step 5: Verify it parses and the suite passes**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && ./run_tests.sh`
Expected: parses clean, every file `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: repair panel -- reconcile the sheet against the timeline"
```

---

### Task 12: Documentation, manual tests, and release

**Files:**
- Modify: `VO/SPEC-overview.md`, `VO/MANUAL_TEST.md`, `VO/ajsfx_VO_Overview.lua` (header), `VO/lib/ajsfx_vo.lua` (header)

- [ ] **Step 1: Document the model in `VO/SPEC-overview.md`**

Add a section after the card-sheet description:

```markdown
## Take identity

A take row's link to its item is an **anchor**: the item's GUID plus the
source-time edges Cut gave it. Anchored rows resolve by GUID before any
inference runs, so an edge dragged in REAPER cannot detach a take's marks —
which the source-time row key (`vo.OverviewKey`) could not survive, since it
*is* a start time.

Anchors are written automatically by Cut (`vo.ApplyPlan` returns the item it
made for each span) and manually from a take row's right-click menu. An
anchored take whose item edges have moved more than 10ms is **edited**: Cut
skips it and offers *Re-cut anyway*, which clears those anchors first.

**The track is the decision.** Sel and Keep are tri-state in the project file —
`yes`, `no`, or blank meaning no opinion. A blank defers to where the item
sits: on `Selects` it reads as Sel, on `Alts` as Keep (`vo.EffectiveMarks`).
Track placement survives re-matching and re-transcription, so scrambled marks
heal themselves. Un-ticking a mark whose item sits on the matching track writes
an explicit `no`, without which the track would re-tick it on the next frame.

The **Repair** panel reconciles the two: disagreements between sheet and
timeline (with *Adopt timeline* / *Adopt sheet*), anchors whose item is gone,
items claimed by two takes, and marks with no audio left to attach to.
```

- [ ] **Step 2: Add the REAPER-only manual tests to `VO/MANUAL_TEST.md`**

```markdown
## Take identity and repair (2026-08-09)

1. Cut a session. Open the project's `_vo.csv`: every cut take has an `Anchor`
   GUID with `Anchor start` / `Anchor stop`, and each one sits on the row whose
   `Key` names that take — not on a row that no longer exists, and not absent.
   This is what proves the row key was stamped before padding (Task 5): derived
   afterwards it would be built from the snapped start and match nothing.
2. Tick Sel on a take, drag that item's left edge 1s later in REAPER. The row
   still points at the item and Sel is still ticked. (Before anchors, the mark
   detached: the row key is a start time.)
3. Press Cut again: the report says "1 take skipped -- you had edited them".
   Press *Re-cut anyway*: it re-cuts and the anchor is rebound to the new clip.
4. Run Pull. Drag an item from `Alts` to `Selects` by hand, then Refresh: the
   row's Sel ticks itself and Keep clears.
5. Un-tick that Sel. It stays un-ticked across a Refresh (the file holds `no`).
6. Delete an anchored item. Open Repair: it appears under "anchored to an item
   this project no longer has". Select another item, press *Relink*.
7. With a take ticked Sel but its item still on the recording track, open
   Repair: it appears as a disagreement. *Adopt timeline* clears the tick;
   undo, then *Adopt sheet* opens Pull instead.
8. Open a project file written before this version whose items are already on
   Selects: those rows tick themselves on load. This is the intended §4.2
   behaviour change, not a bug.
```

- [ ] **Step 3: Bump versions and write the changelog**

`VO/lib/ajsfx_vo.lua` → `@version 0.7`, changelog:

```
-- @changelog Take identity: anchors bind a take row to its REAPER item by GUID so hand-edits cannot detach its marks, Sel/Keep become tri-state so a blank can defer to the track the item sits on, and PlanReconcile reports where the sheet and the timeline disagree.
```

`VO/ajsfx_VO_Overview.lua` → `@version 0.15beta3`. The changelog MUST state the first-open behaviour change:

```
-- @changelog PRE-RELEASE: hand-editing a cut no longer costs you your marks. A take is now bound to its item by that item's GUID -- written automatically when Cut creates the clip, or by hand from the take's right-click menu -- so dragging an edge, moving the item between tracks, or saving and reloading can never detach its Sel, Keep, note or lock. Before this a row's identity was a start time, and moving a boundary more than half a second left its marks unable to find it: they vanished or landed on a neighbour. Cut now also refuses to overwrite a take whose edges you have moved, reporting "3 takes skipped -- you had edited them" with a Re-cut anyway button that discards those edits deliberately rather than silently. Sel and Keep also read the timeline now: an item sitting on the Selects track ticks Sel, one on Alts ticks Keep, so marks scrambled by a re-match heal themselves from where the audio actually is. NOTE ON FIRST OPEN: a blank mark now means "no opinion" rather than "no", so lines whose items already sit on Selects will tick themselves the first time you open an existing project -- those items are the selects, Pull is what put them there. Un-ticking one writes a real "no" that sticks. Finally, a Repair panel reconciles the two sources of truth: takes whose mark disagrees with the track their item is on (Adopt timeline, or Adopt sheet to re-run Pull), anchors whose item has been deleted, items claimed by two takes at once, and marks left with no audio to attach to.
```

- [ ] **Step 4: Full verification**

```bash
./run_tests.sh
lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))"
lua -e "assert(loadfile('VO/lib/ajsfx_vo.lua'))"
```
Expected: every test file `0 failed`, both scripts parse.

- [ ] **Step 5: Commit**

```bash
git add VO/SPEC-overview.md VO/MANUAL_TEST.md VO/ajsfx_VO_Overview.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: document take identity and repair, bump to 0.15beta3"
```

- [ ] **Step 6: Confirm CI went green**

```bash
gh run list --limit 1
```
A red run publishes nothing and says nothing. Also skim the build log: `reapack-index` reports packaging mistakes as warnings, so the index can build "successfully" while omitting a package.
