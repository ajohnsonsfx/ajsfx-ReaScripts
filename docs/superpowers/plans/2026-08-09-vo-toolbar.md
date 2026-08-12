# VO Overview Toolbar Reorg Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reorganize the Overview toolbar into Sheet/Items/View zones and add a one-click safe "Tidy" pass, per `VO/SPEC-toolbar.md`.

**Architecture:** Two new pure functions in `VO/lib/ajsfx_vo.lua` (conflict detection, select-name planning) carry all testable logic; the UI file gains a `TidyPass()` orchestrator that reuses existing machinery (`Reload`, `vo.PlanReconcile`, `ApplyAltNames`, `Pull`) and a rearranged toolbar. No panel internals change.

**Tech Stack:** Lua 5.x, REAPER API via `tests/mock_reaper.lua` for tests, ReaImGui (`im.*`) for UI.

## Global Constraints

- Tests run headless: `./run_tests.sh` from repo root (Git Bash on Windows). Every pure function must be testable with plain tables, no live REAPER.
- All item-mutating work runs inside `core.Transaction("...", fn)` — one undo step per user action.
- Sheet-zone controls must never call any `r.*` function that writes to items, tracks, or the timeline. Writing project ExtState / the `_vo.csv` sheet is allowed.
- Config persists via `vo.LoadConfig()` / `vo.SaveConfig(cfg)`.
- The UI file is `VO/ajsfx_VO_Overview.lua` (~6300 lines). Line numbers below were valid at commit `51fa457`; re-locate by searching the quoted code, not by trusting the number.
- Comment style: full-sentence comments explaining *why*, matching the file's existing voice. No "added by task N" noise.
- Do NOT bump `@version` until the final task.

---

### Task 1: `vo.SelectConflicts` (pure) + tests

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (add near `vo.EffectiveMarks`, ~line 1325)
- Create: `tests/test_vo_tidy.lua`
- Modify: `VO/ajsfx_VO_Overview.lua:1444` (`LineKeyOf` — replace body with lib call)

**Interfaces:**
- Produces: `vo.LineKey(row) -> string` and `vo.SelectConflicts(rows) -> array of { key, label, count }`, where `rows` are overview rows carrying `user_select`, `status`, `script_row`, `asset`, `deliver`.
- Consumed by: Task 3 (TidyPass report), Task 6 (summary segment).

Background for the implementer: an overview row is one *take*; several rows share one *line*. The UI file already keys lines with `LineKeyOf` (`row.script_row or ("asset:" .. tostring(row.asset))`). Two rows of one line can both carry Sel — the sheet derives marks from track placement (`vo.EffectiveMarks` rule 2), so a user dragging two items onto Selects creates exactly this state. We are making it visible, not preventing it.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_vo_tidy.lua` (harness copied from `tests/test_vo_mirror.lua`):

```lua
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash run_tests.sh` (or `lua tests/test_vo_tidy.lua` from repo root)
Expected: FAIL — `attempt to call a nil value (field 'SelectConflicts')`

- [ ] **Step 3: Implement in `VO/lib/ajsfx_vo.lua`**

Insert directly after `vo.EffectiveMarks` (after its closing `end`, ~line 1324):

```lua
-- One take of a line is the Select; the line key is what "one line" means.
-- By SCRIPT ROW, never by filename: two CSV rows may share a filename (the
-- Append column separates them), and keying by name would fuse them. This
-- is the same rule the sheet's SetSelect exclusivity uses -- one function,
-- so the two cannot drift.
function vo.LineKey(row)
  return row.script_row or ("asset:" .. tostring(row.asset))
end

-- Lines carrying more than one Sel. Not an error state to be prevented --
-- track placement legitimately creates it (EffectiveMarks rule 2: two items
-- of a line dragged onto Selects both read as Sel) -- but a decision the
-- user still has to make, so Tidy counts them and the card badges them.
-- Orphans are skipped: they are not lines, and their asset keys collide.
function vo.SelectConflicts(rows)
  local by_key, order = {}, {}
  for _, row in ipairs(rows or {}) do
    if row.user_select and row.status ~= "orphan" then
      local key = vo.LineKey(row)
      local got = by_key[key]
      if not got then
        got = { key = key, label = row.deliver or row.asset or "(unnamed)", count = 0 }
        by_key[key] = got
        order[#order + 1] = got
      end
      got.count = got.count + 1
    end
  end
  local out = {}
  for _, c in ipairs(order) do
    if c.count >= 2 then out[#out + 1] = c end
  end
  return out
end
```

- [ ] **Step 4: Point the UI's `LineKeyOf` at the lib**

In `VO/ajsfx_VO_Overview.lua` find `local function LineKeyOf(row)` (~line 1444) and replace only the body:

```lua
local function LineKeyOf(row)
  return vo.LineKey(row)
end
```

The long comment above it stays — it documents why the key is the script row; move it into the lib version if you prefer, but it must survive somewhere.

- [ ] **Step 5: Run the full suite**

Run: `bash run_tests.sh`
Expected: all files PASS, including the new `test_vo_tidy.lua`.

- [ ] **Step 6: Commit**

```bash
git add VO/lib/ajsfx_vo.lua VO/ajsfx_VO_Overview.lua tests/test_vo_tidy.lua
git commit -m "VO: vo.LineKey + vo.SelectConflicts -- multi-select lines become countable"
```

---

### Task 2: `vo.PlanSelectNames` (pure) + tests

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (add directly after `vo.PlanAltNames`, ~line 977)
- Modify: `tests/test_vo_tidy.lua`

**Interfaces:**
- Consumes: overview rows with `user_select`, `asset`, `deliver`, `name_override`.
- Produces: `vo.PlanSelectNames(rows) -> edits, skipped` where `edits` is `{ { index = <rows index>, name = <string> }, ... }` — the exact same shape `vo.PlanAltNames` returns, so Task 3's apply loop can reuse the `ApplyAltNames` write pattern verbatim.

This is the naming half of Tidy's "Also name matched takes" opt-in: a row ticked **Sel** should carry the line's delivered name. Rows with a `name_override` are counted `skipped` (the user already named it by hand — mirror `PlanAltNames`'s treatment exactly). Rows with no `deliver` produce nothing. Whether the live item *already* carries a resolving name is an impure question answered at apply time (Task 3), not here.

- [ ] **Step 1: Add failing tests to `tests/test_vo_tidy.lua`**

Insert before the final print/exit lines:

```lua
print("PlanSelectNames:")

test("a Sel row plans its delivered name", function()
  local rows = {
    { user_select = true, asset = "line_a", deliver = "line_a_ch2" },
    { user_select = false, asset = "line_a", deliver = "line_a_ch2" },
  }
  local edits, skipped = vo.PlanSelectNames(rows)
  assert(#edits == 1 and skipped == 0)
  assert(edits[1].index == 1 and edits[1].name == "line_a_ch2",
    "got " .. tostring(edits[1].index) .. "/" .. tostring(edits[1].name))
end)

test("a hand-named row is skipped, not renamed", function()
  local rows = {
    { user_select = true, asset = "line_a", deliver = "line_a", name_override = "custom" },
  }
  local edits, skipped = vo.PlanSelectNames(rows)
  assert(#edits == 0 and skipped == 1)
end)

test("no deliver name means nothing to plan", function()
  local rows = { { user_select = true, asset = "line_a" } }
  local edits, skipped = vo.PlanSelectNames(rows)
  assert(#edits == 0 and skipped == 0)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `lua tests/test_vo_tidy.lua`
Expected: FAIL — `attempt to call a nil value (field 'PlanSelectNames')`

- [ ] **Step 3: Implement**

After `vo.PlanAltNames`'s closing `end` in `VO/lib/ajsfx_vo.lua`:

```lua
-- The Sel half of what PlanAltNames does for Keeps: a take ticked Select
-- should carry the line's delivered name. Same return shape as PlanAltNames
-- so one apply loop serves both. Pure -- whether the live item already
-- carries a name that means a line is the APPLY side's question, answered
-- against the project at write time (never overwrite a name that already
-- resolves, the Adopt-session rule).
function vo.PlanSelectNames(rows)
  local edits, skipped = {}, 0
  for i, row in ipairs(rows or {}) do
    if row.user_select and row.asset then
      if row.name_override and trim(row.name_override) ~= "" then
        skipped = skipped + 1
      elseif row.deliver and row.deliver ~= "" then
        edits[#edits + 1] = { index = i, name = row.deliver }
      end
    end
  end
  return edits, skipped
end
```

(`trim` is a local already defined near the top of the lib — `PlanAltNames` uses it; confirm the name before assuming.)

- [ ] **Step 4: Run the full suite**

Run: `bash run_tests.sh`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo_tidy.lua
git commit -m "VO: vo.PlanSelectNames -- Sel rows plan their delivered name"
```

---

### Task 3: `TidyPass()` orchestrator + config keys

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — add `TidyPass` after `AutoSelectTakes` (~line 2524), so `Reload`, `Mutate`, `SetSelect` are in scope; `ApplyAltNames` (~3959) and `Pull` (~3751) are defined LATER in the file, so reach them via forward locals.

**Interfaces:**
- Consumes: `vo.SelectConflicts`, `vo.PlanSelectNames` (Tasks 1–2), existing `Reload()`, `vo.PlanReconcile(state.overview, cfg)`, `vo.MarkFromTrack`, `Mutate`, `vo.CollectProjectSpans`, `vo.ResolveSourceTime`, `vo.BuildNameIndex`, `vo.ResolveItemName`, `core.Transaction`.
- Produces: `TidyPass()` (no args, no return — reports via `state.message`). Config keys `cfg.tidy_name`, `cfg.tidy_pull` (booleans, default falsy). Task 4 wires the button.

The file defines UI far below the actions, so plain declaration order works for `Reload`/`Mutate`, but `ApplyAltNames` and `Pull` come after ~2524. Declare hoisted locals ONCE near the top of the action section (search for where `Pull` is defined and check whether it is already `local function Pull()`; it is, at ~3751). The clean pattern: declare `local TidyPass` as a forward local before `AutoSelectTakes`, and *define* `TidyPass` AFTER `ApplyAltNames` (~line 4030, after its closing `end`), where everything it needs already exists. That avoids all forward-reference gymnastics — do that instead of the hoisting.

- [ ] **Step 1: Implement `TidyPass` after `ApplyAltNames`**

```lua
-- The toolbar's best-effort pass (SPEC-toolbar.md section 4). Safe by
-- default: refresh the match, then make the timeline's word on marks
-- explicit -- sheet state only, no items touched. Two opt-ins reach into
-- item territory (naming, pulling) and run inside one transaction so the
-- whole pass is a single undo step. Marks are adopted LAST so they see the
-- post-pull track layout.
local function TidyPass()
  local cfg = vo.LoadConfig()
  Reload()
  local refreshed = #state.overview

  -- One OUTER transaction around every item-changing step: REAPER's undo
  -- blocks nest (an inner Undo_EndBlock folds into the outer block), so
  -- ApplyAltNames' and Pull's own transactions collapse into this one and
  -- the whole pass is a single undo step -- the SPEC-toolbar.md section 4
  -- contract.
  local named, pulled = 0, 0
  if cfg.tidy_name or cfg.tidy_pull then
    core.Transaction("VO Overview: tidy", function()
      if cfg.tidy_name then
        -- Sel rows get the line's delivered name; Keep rows get alt names.
        -- Never overwrite a name that already means a line (the Adopt-
        -- session rule): a resolving name IS an assignment, and Tidy is
        -- best-effort, not authoritative.
        local index = vo.BuildNameIndex(state.lines or {})
        local items = vo.CollectProjectSpans()
        local sel_edits = vo.PlanSelectNames(state.overview)
        for _, e in ipairs(sel_edits) do
          local row  = state.overview[e.index]
          local clean = vo.SanitizeName(e.name)
          local item = row and row.source_path and row.source_start
                       and vo.ResolveSourceTime(row.source_path, row.source_start, items)
          local take = item and r.GetActiveTake(item)
          if take and clean ~= "" then
            local _, cur = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
            if not vo.ResolveItemName(index, cur or "") then
              r.GetSetMediaItemTakeInfo_String(take, "P_NAME", clean, true)
              EntryFor(row).name_override = clean
              named = named + 1
            end
          end
        end
        -- Alts get their pattern names too. ApplyAltNames opens its own
        -- transaction; nested inside ours it folds into the one undo step.
        ApplyAltNames()
      end
      if cfg.tidy_pull then
        Pull()
        pulled = 1  -- Pull() reports its own counts in state.pull_result.
      end
    end)
    state.name_baseline = nil
    Reload()
  end

  -- The timeline's word on marks, made explicit -- the same write Repair's
  -- "Adopt timeline" does, without the panel trip.
  local plan = vo.PlanReconcile(state.overview, cfg)
  local adopted = #plan.disagree
  for _, f in ipairs(plan.disagree) do
    local want = vo.MarkFromTrack(f.row.track_name, cfg)
    Mutate(f.row, function(e)
      e.select = (want == "select") or nil
      e.keep   = (want == "keep")   or nil
    end)
  end

  local conflicts = vo.SelectConflicts(state.overview)
  local bits = { string.format("%d line%s refreshed", refreshed,
                               refreshed == 1 and "" or "s") }
  if adopted > 0 then bits[#bits + 1] = adopted .. " mark(s) adopted from the timeline" end
  if named   > 0 then bits[#bits + 1] = named .. " select(s) named" end
  if pulled  > 0 then bits[#bits + 1] = "items pulled (see the Pull report)" end
  if #conflicts > 0 then
    bits[#bits + 1] = #conflicts .. " line(s) with two selects -- pick one"
  end
  state.message = "Tidy: " .. table.concat(bits, ", ") .. "."
  state.message_kind = (#conflicts > 0) and "warn" or "ok"
  state.dirty = true
end
```

Notes for the implementer, verify each against the live file rather than trusting this plan:
- `EntryFor(row)` exists (used by `ApplyAltNames` at ~3993) and is in scope at this position.
- `Mutate` rebuilds the match per call — fine here, `plan.disagree` is usually small; do NOT wrap the Mutate loop in a transaction, marks are sheet state, not undoable project items (check how Repair's Adopt timeline does it at ~4156: bare loop, no transaction — match that).
- If `ApplyAltNames()` runs `Reload()` internally (it does), the subsequent `PlanReconcile` sees fresh rows — good; do not double-reload.
- Skipping `named`-vs-`ApplyAltNames` double counting: `ApplyAltNames` writes its own `state.message`; `TidyPass` overwrites it last, which is correct — one report, ours.
- `"warn"` as a `message_kind`: check what kinds the message-line renderer supports (search `state.message_kind`); if only `"ok"`/`"error"`/`"info"` exist, use `"info"`.

- [ ] **Step 2: Syntax check**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && echo OK` — expect `OK` (loadfile parses without executing; execution needs REAPER).
Then: `bash run_tests.sh` — all PASS (nothing new is under test, but the lib must still load).

- [ ] **Step 3: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: TidyPass -- refresh, adopt timeline marks, opt-in name and pull"
```

---

### Task 4: Row 1 — Sheet / Items zones

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — the block between `im.Text(ctx, "Script:")` (~6159) and `if state.panel == "script"` (~6219).

**Interfaces:**
- Consumes: `TidyPass` (Task 3), existing `Rematch`, `PanelButton` helper, `PlaceSelectedItems`, `TightenItems`, `AutoSelectTakes`, `AffectedRows`, `TAKE_PICKS`, `Combo`, `vo.LoadConfig`/`SaveConfig`, `vo.LaunchSibling`.
- Produces: the new row-1 layout. Task 5 removes the relocated buttons from row 2.

Replace the current sequence (Script label → PanelButtons → Settings) with the zone layout. The `Script:` filename readout (lines ~6159–6173) MOVES to sit just before the setup cluster at the right end of the row (keep the code identical, just relocate it). `PanelButton` helper stays as-is.

- [ ] **Step 1: Rewrite the block**

```lua
    -- Row 1 is the ACT row, split by the one distinction the user must
    -- never have to think about (SPEC-toolbar.md section 1): the Sheet
    -- zone only updates tracking and is always safe to press; the Items
    -- zone changes audio items, in workflow order.
    im.TextDisabled(ctx, "Sheet:")
    im.SameLine(ctx)

    if im.Button(ctx, "Refresh") then Rematch() end
    if im.IsItemHovered(ctx) then
      local locked = #state.pins
      im.SetTooltip(ctx, string.format(
        "Tracking only -- no items change.\n\n" ..
        "Re-read every transcript and identify the lines again from scratch.\n" ..
        "Locked lines keep the placement they have (%d locked).\n\n" ..
        "Do this after transcribing in ajsfx VO Sources, or after editing\n" ..
        "the script.", locked))
    end
    im.SameLine(ctx)

    local tidy_cfg = vo.LoadConfig()
    if im.Button(ctx, "Tidy") then TidyPass() end
    if im.IsItemHovered(ctx) then
      local extra = (tidy_cfg.tidy_name or tidy_cfg.tidy_pull)
        and "\n\nOpt-ins are ON, so this run ALSO changes items:" ..
            (tidy_cfg.tidy_name and "\n- names selects and alts" or "") ..
            (tidy_cfg.tidy_pull and "\n- pulls named items to their tracks" or "")
        or "\n\nTracking only -- no items change."
      im.SetTooltip(ctx,
        "Best-effort pass: refresh, adopt the marks the timeline implies,\n" ..
        "and count lines still carrying two selects." .. extra)
    end
    im.SameLine(ctx, 0, 1)
    if im.ArrowButton(ctx, "##tidyopts", im.Dir_Down) then
      im.OpenPopup(ctx, "##tidy_menu")
    end
    if im.BeginPopup(ctx, "##tidy_menu") then
      local hit, v = im.Checkbox(ctx, "Also name matched takes  (changes items)",
                                 tidy_cfg.tidy_name == true)
      if hit then
        tidy_cfg.tidy_name = v or nil
        vo.SaveConfig(tidy_cfg)
      end
      hit, v = im.Checkbox(ctx, "Also pull named items to tracks  (changes items)",
                           tidy_cfg.tidy_pull == true)
      if hit then
        tidy_cfg.tidy_pull = v or nil
        vo.SaveConfig(tidy_cfg)
      end
      im.Separator(ctx)
      if im.Button(ctx, "Select takes") then AutoSelectTakes(AffectedRows()) end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, "Tracking only -- no items change.\n\n" ..
                           "Mark one take per line as the select.")
      end
      im.SameLine(ctx)
      Combo("##autoselect", 70, TAKE_PICKS, state.auto_select_take, function(k)
        state.auto_select_take = k
        local cfg = vo.LoadConfig()
        cfg.auto_select_take = k
        vo.SaveConfig(cfg)
      end)
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, "Which take to mark as the select on a line that was\n" ..
                           "read more than once. Locked lines are left alone.")
      end
      im.EndPopup(ctx)
    end
    im.SameLine(ctx)

    im.TextDisabled(ctx, " | ")
    im.SameLine(ctx)
    im.TextDisabled(ctx, "Items:")
    im.SameLine(ctx)

    PanelButton("cut", "Cut and Name",
      "Splits every take of every decided line out of its recording\n" ..
      "and names it the script's filename. Moves nothing.")

    PanelButton("pull", "Pull",
      "Moves items onto Selects, Alts, Outs and Review tracks nested\n" ..
      "under the recording they came from, matched to the script by name.")

    PanelButton("sort", "Sort",
      "Lays the items out on the timeline in script order or record\n" ..
      "order, on fresh child tracks so nothing lands on anything.")

    if im.Button(ctx, "Place") then pending_action = PlaceSelectedItems end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx,
        "File the item(s) selected in REAPER where their NAME says they\n" ..
        "belong: a plain delivered name goes to Selects, an alt-patterned\n" ..
        "one to Alts. Rename first, press this, the sheet follows.")
    end
    im.SameLine(ctx)

    if im.Button(ctx, "Tighten") then pending_action = TightenItems end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx,
        "Finishing pass: measure where the audio really is in each delivered\n" ..
        "item and pull loose edges in to the standard head/tail room. Inward\n" ..
        "only, so speech is never lost; hand-trimmed items (custom fades)\n" ..
        "are left alone. Works on the REAPER selection, or everything on\n" ..
        "Selects + Alts when nothing is selected.")
    end
    im.SameLine(ctx)

    PanelButton("repair", "Repair",
      "Where the sheet and the timeline disagree, and what is broken:\n" ..
      "marks that contradict the track their item sits on, anchors whose\n" ..
      "item is gone, and items claimed by two takes at once.")

    im.TextDisabled(ctx, " | ")
    im.SameLine(ctx)

    -- Setup cluster, out of the workflow's way at the row's end.
    PanelButton("script", "Script",
      "The script CSVs this project reads, and which column of\n" ..
      "each holds the filename, the line and the character.")

    if im.Button(ctx, "Sources…") then
      local ok, why = vo.LaunchSibling("ajsfx_VO_Sources.lua")
      if not ok then state.message, state.message_kind = tostring(why), "error" end
    end
    im.SameLine(ctx)

    if im.Button(ctx, "Settings") then state.settings_open = true end
    im.SameLine(ctx)

    -- The loaded-script readout, relocated from the row's front.
    local n_scripts = #state.scripts
    if n_scripts == 0 then
      im.TextDisabled(ctx, "(no script chosen)")
    else
      local label = vo.Basename(state.scripts[1].path or "")
      if n_scripts > 1 then label = label .. string.format(" +%d more", n_scripts - 1) end
      im.TextDisabled(ctx, label)
      if im.IsItemHovered(ctx) then
        local all = {}
        for _, sc in ipairs(state.scripts) do all[#all + 1] = sc.path end
        im.SetTooltip(ctx, table.concat(all, "\n"))
      end
    end
```

Caveats to verify in place:
- `pending_action` must already be reset (`pending_action = nil` at ~6156) BEFORE this block — it is; keep that ordering.
- `Place`/`Tighten` previously ran via `pending_action` from the filter toolbar; that pattern is kept here. Confirm `pending_action` is executed after the table draw (search for where it is called) so assigning it from row 1 works the same as from row 2. If row-2 buttons called them directly instead, match whatever the existing call discipline is.
- `im.ArrowButton` is already used in the script panel (~3097), so the binding exists.
- `PanelButton` ends with `im.SameLine(ctx)`, plain buttons need their own — mind the trailing-SameLine bookkeeping or the row will wrap; follow the existing block's rhythm.
- The old `im.Text(ctx, "Script:")` label block at the row's front must be fully removed.

- [ ] **Step 2: Syntax check + tests**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && echo OK`, then `bash run_tests.sh`.
Expected: OK, all PASS.

- [ ] **Step 3: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: row 1 becomes Sheet / Items / setup zones with Tidy as the second hero"
```

---

### Task 5: Row 2 — view-only cleanup

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — inside `DrawFilters` (~4284–4434).

**Interfaces:** none new. Deletes relocated controls; Task 4 already re-homed them.

- [ ] **Step 1: Edit `DrawFilters`**

1. Move the Search input (`im.SetNextItemWidth(ctx, 200)` + `InputTextWithHint` block, ~4385–4387) to the TOP of the toolbar, before the character `Combo` — it becomes the row's first control.
2. Delete from `DrawFilters`: the `Rematch` button + tooltip (~4389–4400), the `Select takes` button + `##autoselect` combo + tooltip (~4402–4414), the `Place` button + tooltip (~4416–4423), the `Tighten` button + tooltip (~4425–4434).
3. The last remaining control (`Follow` popup block) must not end with a dangling `im.SameLine(ctx)` — check the block boundary after deletion.

Character combo, Filters, Clear filters, Unfold all, Fold all, Follow, and the filter-row boxes below are untouched.

- [ ] **Step 2: Syntax check + tests**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && echo OK`, then `bash run_tests.sh`.
Expected: OK, all PASS.

- [ ] **Step 3: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: row 2 is view-only -- search first, actions moved to row 1"
```

---

### Task 6: Conflict badge + summary segment

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — `DrawCardBand` (~5072) and `DrawSummary` (~5485).

**Interfaces:**
- Consumes: `vo.SelectConflicts` (Task 1); `node.takes` (the line's rows) inside `DrawCardBand`; `state.overview` inside `DrawSummary`.

- [ ] **Step 1: Badge in `DrawCardBand`**

In row 1 of the band, directly after the `CardDot(style.colour, ...)` call (~5121), insert:

```lua
  -- Two Sels on one line is a decision still pending, not an error --
  -- track placement legitimately creates it -- so it is badged where the
  -- user is already looking, and counts into the summary line.
  local sels = 0
  for _, t in ipairs(node.takes) do
    if t.user_select then sels = sels + 1 end
  end
  if sels >= 2 then
    im.SameLine(ctx)
    im.TextColored(ctx, 0xDDAA33FF, string.format("%d selects -- pick one", sels))
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "More than one take of this line is marked Sel.\n" ..
                         "Untick all but one, or drag the extra item off Selects\n" ..
                         "and press Tidy.")
    end
  end
```

Watch the cursor discipline: the band lays text with explicit `SetCursorScreenPos` calls; placing this right after `CardDot` (which ends as an inline element) with a plain `SameLine` matches how the speaker chip follows it. If the badge collides with the line-text x position (`z.marks`), move the badge to after the right-aligned badges block (~5147) instead and right-align it at `rx + inner_w - 160`.

- [ ] **Step 2: Summary segment in `DrawSummary`**

After the `flagged` segment (~5513) insert:

```lua
  local conflicts = vo.SelectConflicts(state.overview)
  if #conflicts > 0 then
    seg(0xDDAA33FF, string.format("%d line(s) need a select chosen", #conflicts),
      "Lines carrying more than one Sel. Each card says which takes;\n" ..
      "untick all but one.")
  end
```

`DrawSummary` runs every frame; `SelectConflicts` is a linear scan over the overview, same cost class as the loops already in the draw path — acceptable. If you want it cached, key it on `state.scanned_at` like `pull_count_key` does (~4086), but do not invent a new caching scheme beyond that pattern.

- [ ] **Step 3: Syntax check + tests**

Run: `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && echo OK`, then `bash run_tests.sh`.
Expected: OK, all PASS.

- [ ] **Step 4: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: badge and count lines carrying two selects"
```

---

### Task 7: Version, changelog, docs, manual test

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua:3-4` (`@version`, `@changelog`)
- Modify: `VO/SPEC-toolbar.md:3` (status line)
- Modify: `VO/MANUAL_TEST.md` (append a section)

- [ ] **Step 1: Bump the header**

`@version 0.15beta5`. Replace `@changelog` with (one line, ReaPack reads it whole):

```
PRE-RELEASE: the toolbar release. The Overview toolbar is now three zones you can trust without reading: row 1 left is SHEET (tracking only, always safe) -- Refresh (was Rematch) and the new Tidy, a one-press best-effort pass that refreshes the match, adopts the marks the timeline implies, and counts lines still carrying two selects; row 1 right is ITEMS (changes audio, in workflow order) -- Cut and Name, Pull, Sort, Place, Tighten, Repair, with Script/Sources/Settings parked at the end; row 2 is VIEW only -- search (now first), character, filters, folding, follow. Tidy's ▾ menu holds two persisted opt-ins that reach into item territory, labelled as such (also name matched takes, also pull named items), plus the relocated Select takes control. A line carrying two Sels -- which track placement can legitimately create -- now wears an amber "pick one" badge on its card and counts into the summary line. This build carries the earlier 0.15beta work: session ingest and take-map mirroring, ranged take markers, the card sheet, planned takes, and whisper gap repair in Sources.
```

- [ ] **Step 2: Spec status**

In `VO/SPEC-toolbar.md` change the status line to:
`**Status:** Implemented, unverified in REAPER · **Date:** 2026-08-09`

- [ ] **Step 3: Append to `VO/MANUAL_TEST.md`**

```markdown
## Toolbar zones + Tidy (0.15beta5)

Setup: any project with a script loaded and a few cut takes.

1. Row 1 reads `Sheet: [Refresh] [Tidy ▾] | Items: [Cut and Name] [Pull] [Sort]
   [Place] [Tighten] [Repair] | [Script] [Sources…] [Settings] <script name>`.
   Row 2 starts with the Search box; Rematch / Select takes / Place / Tighten
   are gone from it.
2. Refresh = old Rematch: message reports lines identified, locked lines skipped.
3. Tidy with both opt-ins OFF: message reports refreshed count; NOTHING moves
   or renames on the timeline (undo history gains no item edit).
4. Drag a second item of one line onto Selects. The card shows the amber
   "2 selects -- pick one" badge; the summary line counts it. Press Tidy:
   message includes "1 line(s) with two selects".
5. Tidy ▾ → tick both opt-ins (labelled "changes items"). Press Tidy on a
   project with unnamed Sel-ticked takes: takes get named, Pull runs, one
   undo step covers the naming ("VO Overview: tidy"), Pull's own report shows.
6. Tidy ▾ → Select takes + first/last combo still work as before.
7. Untick both opt-ins afterwards; confirm they persist across a window
   close/reopen (config), and Tidy's tooltip returns to "Tracking only".
```

- [ ] **Step 4: Full suite + commit**

Run: `bash run_tests.sh` — all PASS.

```bash
git add VO/ajsfx_VO_Overview.lua VO/SPEC-toolbar.md VO/MANUAL_TEST.md
git commit -m "VO: 0.15beta5 -- toolbar zones, Tidy pass, select-conflict badge"
```

Do NOT merge to main or push — REAPER verification (the MANUAL_TEST section above) comes first, per the repo's release discipline.
