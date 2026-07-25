# VO ScriptMatch Spreadsheet-First Dialog Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the `ajsfx_VO_ScriptMatch` run dialog around a live preview table whose header *is* the column-mapping UI, with the other options collapsed out of the way.

**Architecture:** All changes are confined to `VO/ajsfx_VO_ScriptMatch.lua`. No function in `VO/lib/ajsfx_vo.lua` is touched. The table body is the return value of the same `vo.BuildScriptLines` call `Run()` makes, cached in `state.preview` and recomputed only when `state.preview_dirty` is set — so the preview cannot drift from actual run behaviour. An ordered `COLUMNS` descriptor list drives the table so the future Result/Take columns are additive.

**Tech Stack:** Lua 5.3 (REAPER), ReaImGui `0.9.3` (`require('imgui')('0.9.3')`), `vo` library at `VO/lib/ajsfx_vo.lua`, test harness `./run_tests.sh` with the mock REAPER environment in `tests/`.

**Design spec:** `docs/superpowers/specs/2026-07-25-vo-scriptmatch-ui-regroup-design.md`

## Global Constraints

- ReaImGui version stays pinned at `0.9.3`. Do not use an API added after that version.
- No function in `VO/lib/ajsfx_vo.lua` may be modified, added, or removed.
- `im.Begin` must always be matched by `im.End`; `im.BeginDisabled` by `im.EndDisabled`; `im.BeginTable` by `im.EndTable` **only when it returned true**; `im.BeginCombo` by `im.EndCombo` **only when it returned true**.
- Capture any disabled-state boolean into a local *before* the widget that can change it, and gate `EndDisabled` on that local (existing convention, see `dis_del` at line 589).
- `state.mapping`, `state.skip_text`, preset save/load/delete, `MarkDirty`, `PersistProjectMemory` and SPEC §5.3 restore precedence keep their current semantics.
- `reaper.GetThemeColor` is explicitly out of scope. Keep the existing literal colours (`0xDD6666FF` error, `0xDDAA33FF` warning).
- Existing tests in `tests/` must pass unchanged after every task.
- Do not bump `-- @version` until Task 6.

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `VO/ajsfx_VO_ScriptMatch.lua` | Modify | The entire change. Dialog state, column descriptors, table drawing, run gating. |
| `docs/superpowers/specs/2026-07-25-...-design.md` | Read only | Source of truth for requirements. |
| `VO/lib/ajsfx_vo.lua` | Untouched | — |
| `tests/test_vo.lua` | Untouched | Already covers `BuildScriptLines`, which owns the will-run correctness. |

The script is ~700 lines and organised into commented banner sections. Keep that structure: new helpers go in the `Layout / CSV dialog helpers` section, new drawing code in the `Run dialog` section.

## Testing Note

The dialog is drawn by ReaImGui inside REAPER's `defer` loop and is not reachable from the headless mock harness — `tests/` covers `vo.lua` logic only. So the per-task cycle here is:

1. `./run_tests.sh` — must stay green (it proves you did not break the library or the module's load-time behaviour).
2. `luac -p VO/ajsfx_VO_ScriptMatch.lua` (or `luac5.3 -p`) — syntax check, catches an unbalanced `end` before REAPER does.
3. The task's **Manual verification** block, run in REAPER.
4. Commit.

Do not skip the manual block. An ImGui stack imbalance is silent in a syntax check and fatal at runtime.

---

### Task 1: Single-character filter replaces multi-select

Removes `state.excluded` and every reader of it in one atomic change, so the file is runnable at the end of the task. The old checkbox list is deleted here; the new character combo arrives in Task 3, so between the two the dialog has no character filter UI — that is expected and temporary.

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua:127` (state field), `:194-207` (`RebuildDistinct`), `:426-448` (`Run` filter block), `:614-626` (checkbox list)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `state.character` — a folded character key (string) matching a `d.key` from `vo.DistinctCharacters`, or `nil` meaning "all characters".
  - `local function CharacterFilter()` returning `speakers, canon` — the two values `Run()` passes to `vo.BuildScriptLines`. `speakers` is `{ [state.character] = true }` or `nil`; `canon` is `vo.CanonicalizeMap(state.distinct)` or `nil`.

- [ ] **Step 1: Replace the state field**

At line 127, replace:

```lua
  excluded         = {},         -- folded character key -> true when unchecked
```

with:

```lua
  character        = nil,        -- folded character key to keep, nil = all (R3)
```

- [ ] **Step 2: Make `RebuildDistinct` reconcile the selection**

Replace the body of `RebuildDistinct` (lines 194-207) with:

```lua
-- (Re)build the character list from the mapped speaker column. A selection that
-- still exists in the new column survives; one that does not resets to "all".
local function RebuildDistinct()
  local spk = state.mapping.speaker
  local idx
  if spk then
    for i, h in ipairs(state.header or {}) do if h == spk then idx = i; break end end
  end
  if not idx then
    state.distinct  = nil
    state.character = nil
    return
  end
  state.distinct = vo.DistinctCharacters(state.rows or {}, idx)
  if state.character then
    local still_there = false
    for _, d in ipairs(state.distinct) do
      if d.key == state.character then still_there = true; break end
    end
    if not still_there then state.character = nil end
  end
end
```

- [ ] **Step 3: Add `CharacterFilter` and use it in `Run`**

Insert this helper immediately after `RebuildDistinct`:

```lua
-- The character filter as BuildScriptLines arguments. Canonicalization applies
-- whenever a character column carries values; the include-set is nil (inert ->
-- keep every row, blank-character rows included) until a character is chosen,
-- at which point it is a set of exactly one (R3).
local function CharacterFilter()
  if not (state.distinct and #state.distinct > 0) then return nil, nil end
  local canon = vo.CanonicalizeMap(state.distinct)
  if not state.character then return nil, canon end
  return { [state.character] = true }, canon
end
```

Then in `Run()` replace the whole comment-and-code block at lines 426-448 with:

```lua
  local speakers, canon = CharacterFilter()
```

The `"No characters selected."` early-return is deleted — with a single-select it is unreachable.

- [ ] **Step 4: Delete the checkbox list**

Remove lines 614-626 entirely (the `-- Character filter ---` comment, the `if state.distinct and #state.distinct > 0 then` block, its `SeparatorText`, hint and checkbox loop).

- [ ] **Step 5: Verify no `excluded` references remain**

Run:

```bash
grep -n "excluded" VO/ajsfx_VO_ScriptMatch.lua
```

Expected: no output. Any hit is an unmigrated reader — fix it before continuing.

- [ ] **Step 6: Run the checks**

```bash
./run_tests.sh
```

Expected: PASS, same count as before the task.

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```

Expected: no output.

- [ ] **Step 7: Manual verification in REAPER**

1. Select a session item, run the script, load a CSV with a character column.
2. Confirm the dialog opens with no character checkbox list and no error.
3. Confirm `Transcribe and cut` still runs and processes every row (the filter is inert with `state.character == nil`).

- [ ] **Step 8: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua
git commit -m "refactor(VO): single-character filter replaces multi-select"
```

---

### Task 2: Combo helper that puts the label inside the control

`im.Combo` derives its closed-state text from the selected item and cannot show a composed preview. `im.BeginCombo` takes an arbitrary preview string, which is what lets the label live inside the box. This task swaps the mechanism with no visual reorganisation yet, so a regression here is easy to spot.

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua:336-364` (`RoleCombo`)

**Interfaces:**
- Consumes: `state.header`, `state.mapping`, `MarkDirty`, `RebuildDistinct` from Task 1.
- Produces: `local function RoleCombo(role, optional, width)` — draws the column selector for `role`. `width` is a number of pixels, or `nil` to fill the available content region. Returns nothing. Assigns `state.mapping[role]` (a header column name string, or `nil` for `(none)`).

- [ ] **Step 1: Rewrite `RoleCombo`**

Replace lines 336-364 in full with:

```lua
-- One column selector. The label lives inside the control as the preview text,
-- so the table header does not need a separate label column. Options are the
-- header columns; optional roles lead with (none). Editing marks the layout
-- unsaved and rebuilds the character list when the speaker column moves.
local function RoleCombo(role, optional, width)
  local mapped  = state.mapping[role]
  local preview = mapped or (optional and "(none)" or "Column…")

  im.SetNextItemWidth(ctx, width or im.GetContentRegionAvail(ctx))
  if im.BeginCombo(ctx, "##" .. role .. "_col", preview) then
    if optional then
      if im.Selectable(ctx, "(none)", mapped == nil) and mapped ~= nil then
        state.mapping[role] = nil
        MarkDirty()
        if role == "speaker" then RebuildDistinct() end
      end
    end
    for _, h in ipairs(state.header or {}) do
      if im.Selectable(ctx, h, h == mapped) and h ~= mapped then
        state.mapping[role] = h
        MarkDirty()
        if role == "speaker" then RebuildDistinct() end
      end
    end
    im.EndCombo(ctx)
  end
end
```

Note the two guards that matter: `EndCombo` is called **only inside** the `if BeginCombo` branch, and each `Selectable` result is `and`-ed with an actual change so `MarkDirty` does not fire on a no-op reselect.

- [ ] **Step 2: Update the three call sites**

At lines 603-605 the calls become:

```lua
      RoleCombo("speaker", true)   -- Character (optional)
      RoleCombo("asset",   false)  -- Filename (required, and the line's identity)
      RoleCombo("text",    false)  -- Line Text (required)
```

(unchanged text — the new third parameter is optional and `nil` here). Leave them in place; Task 4 moves them into the table.

- [ ] **Step 3: Run the checks**

```bash
./run_tests.sh
```

Expected: PASS.

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```

Expected: no output.

- [ ] **Step 4: Manual verification in REAPER**

1. Open the dialog with a CSV loaded. The three dropdowns now show the column name (or `(none)` / `Column…`) with no external label.
2. Change the Filename column; confirm the preset combo flips to `(unsaved)` (that is `MarkDirty` firing).
3. Reselect the *same* Filename column; confirm the preset name does **not** flip to unsaved a second time if you first re-save it.
4. Set Character to `(none)`; confirm no error.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua
git commit -m "refactor(VO): BeginCombo role selector with label inside the control"
```

---

### Task 3: Character selector combo

The second dropdown in the Character cell. Built now, drawn beside `RoleCombo("speaker")` in Task 4.

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua` — insert after `RoleCombo`

**Interfaces:**
- Consumes: `state.distinct`, `state.character` (Task 1), `RoleCombo`'s conventions.
- Produces: `local function CharacterCombo(width)` — draws the character selector. Assigns `state.character`. Sets `state.preview_dirty = true` on change (the field is introduced in Task 4; assigning it before then is harmless).

- [ ] **Step 1: Add the helper**

Insert immediately after `RoleCombo`:

```lua
-- The "which character" selector, drawn beside the character column selector.
-- Per-run only: it is not saved into a layout preset and does not mark dirty.
local function CharacterCombo(width)
  local has = state.distinct and #state.distinct > 0
  local preview = "(all characters)"
  if has and state.character then
    for _, d in ipairs(state.distinct) do
      if d.key == state.character then preview = d.display; break end
    end
  end

  if not has then im.BeginDisabled(ctx) end
  im.SetNextItemWidth(ctx, width or im.GetContentRegionAvail(ctx))
  if im.BeginCombo(ctx, "##character", preview) then
    if im.Selectable(ctx, "(all characters)", state.character == nil)
       and state.character ~= nil then
      state.character = nil
      state.preview_dirty = true
    end
    for _, d in ipairs(state.distinct or {}) do
      if im.Selectable(ctx, d.display, d.key == state.character)
         and d.key ~= state.character then
        state.character = d.key
        state.preview_dirty = true
      end
    end
    im.EndCombo(ctx)
  end
  if not has then im.EndDisabled(ctx) end
end
```

`has` is captured before the widget and reused for `EndDisabled`, per the global constraint.

- [ ] **Step 2: Run the checks**

```bash
./run_tests.sh
```

Expected: PASS.

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```

Expected: no output.

- [ ] **Step 3: Commit**

Nothing calls it yet, so there is nothing to verify in REAPER beyond the script still opening.

```bash
git add VO/ajsfx_VO_ScriptMatch.lua
git commit -m "feat(VO): character selector combo"
```

---

### Task 4: The preview table

The centrepiece. Column descriptors, the two frozen header rows, the cached `BuildScriptLines` body, the count line.

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua` — add `COLUMNS` and preview helpers in the helpers section; replace lines 602-633 (the three `RoleCombo` calls, skip-tokens block and the `elseif/else` header-state branches) in the draw loop

**Interfaces:**
- Consumes: `RoleCombo` (Task 2), `CharacterCombo` (Task 3), `CharacterFilter` (Task 1), `ParseSkipLines`, `vo.MapColumns`, `vo.BuildScriptLines`.
- Produces:
  - `COLUMNS` — the ordered descriptor list.
  - `state.preview` — array of `{ text, asset, speaker, row }`, or `nil` when not computable.
  - `state.preview_dirty` — boolean, set by any input change, cleared by `RefreshPreview`.
  - `local function RefreshPreview()` — recomputes `state.preview` from current state.
  - `local function DrawTable()` — draws the whole table including both header rows.

- [ ] **Step 1: Add the column descriptors**

Insert after `ROLE_LABEL` (after line 166):

```lua
-- The preview table is driven by this ordered list, not hardcoded columns.
-- kind = "mapped" -> a column selector in the header, body values from the CSV.
-- kind = "computed" is reserved for future columns whose header is a static
-- label and whose body comes from a render function (Result, Take). Nothing in
-- the drawing code may assume every column is mapped.
local COLUMNS = {
  { key = "speaker", label = "Character", kind = "mapped", role = "speaker",
    optional = true, filter = "character", init_width = 200 },
  { key = "asset",   label = "Filename",  kind = "mapped", role = "asset",
    required = true, init_width = 180 },
  { key = "text",    label = "Line Text", kind = "mapped", role = "text",
    required = true, init_width = 280 },
}
```

- [ ] **Step 2: Add the two new state fields**

In the `state` table, after `distinct` (line 128), add:

```lua
  preview          = nil,        -- cached BuildScriptLines result (R4)
  preview_dirty    = true,       -- recompute the preview on the next frame
```

- [ ] **Step 3: Add `RefreshPreview`**

Insert after `CharacterCombo`:

```lua
-- Recompute the will-run set. This is the same call Run() makes with the same
-- arguments, so the table cannot drift from actual run behaviour (R4). Returns
-- nil (not an empty list) when the mapping is incomplete, which the table
-- distinguishes from "mapped but nothing survives".
local function RefreshPreview()
  state.preview_dirty = false
  state.preview = nil
  if not state.header or state.header_error ~= "" or not state.rows then return end

  local cols = vo.MapColumns(state.header, state.mapping)
  if not cols then return end

  local speakers, canon = CharacterFilter()
  state.preview = vo.BuildScriptLines(state.rows, cols, {
    skip_values  = ParseSkipLines(state.skip_text),
    speakers     = speakers,
    canonicalize = canon,
  })
end
```

- [ ] **Step 4: Mark the preview dirty wherever an input changes**

Four places. In `RoleCombo`, add `state.preview_dirty = true` next to each `MarkDirty()` call (both branches). In `LoadCSV`, add `state.preview_dirty = true` as the last line of the function. `CharacterCombo` already sets it (Task 3). The skip-tokens input gets it in Step 6 below.

- [ ] **Step 5: Add `DrawTable`**

Insert after `RefreshPreview`:

```lua
-- The table is the interface: columns are mapped in its header, and the body is
-- the list of lines that will actually run. Rows excluded by a skip token, the
-- character filter, or an empty required cell are hidden, not dimmed (R4).
local function DrawTable(height)
  local flags = im.TableFlags_Borders | im.TableFlags_Resizable
              | im.TableFlags_ScrollY | im.TableFlags_RowBg
  if not im.BeginTable(ctx, "script_preview", #COLUMNS, flags, 0, height) then
    return
  end

  for _, c in ipairs(COLUMNS) do
    im.TableSetupColumn(ctx, c.label, im.TableColumnFlags_WidthFixed, c.init_width)
  end
  im.TableSetupScrollFreeze(ctx, 0, 2)

  -- Header row 1: static labels. A required column that is unmapped shows its
  -- label in the warning colour, so what blocks the run is visible in place.
  im.TableNextRow(ctx, im.TableRowFlags_Headers)
  for i, c in ipairs(COLUMNS) do
    im.TableSetColumnIndex(ctx, i - 1)
    if c.required and not state.mapping[c.role] then
      im.TextColored(ctx, 0xDDAA33FF, c.label)
    else
      im.Text(ctx, c.label)
    end
  end

  -- Header row 2: the selectors. The Character cell holds two combos side by
  -- side so its header is no taller than the others.
  im.TableNextRow(ctx)
  for i, c in ipairs(COLUMNS) do
    im.TableSetColumnIndex(ctx, i - 1)
    if c.kind == "mapped" then
      if c.filter == "character" then
        local half = math.max(60, (im.GetContentRegionAvail(ctx) - 8) / 2)
        RoleCombo(c.role, c.optional, half)
        im.SameLine(ctx)
        CharacterCombo(half)
      else
        RoleCombo(c.role, c.optional)
      end
    end
  end

  local lines = state.preview
  if lines and #lines > 0 then
    local clipper = im.CreateListClipper(ctx)
    im.ListClipper_Begin(clipper, #lines)
    while im.ListClipper_Step(clipper) do
      local first, last = im.ListClipper_GetDisplayRange(clipper)
      for n = first, last - 1 do
        local line = lines[n + 1]
        im.TableNextRow(ctx)
        for i, c in ipairs(COLUMNS) do
          im.TableSetColumnIndex(ctx, i - 1)
          if c.kind == "mapped" then
            im.Text(ctx, line[c.key] or "")
          end
        end
      end
    end
  else
    local msg
    if not lines then
      msg = "Choose the Filename and Line Text columns above."
    else
      msg = "No script lines survive the current filters."
    end
    im.TableNextRow(ctx)
    im.TableSetColumnIndex(ctx, 0)
    im.TextDisabled(ctx, msg)
  end

  im.EndTable(ctx)
end
```

`EndTable` is inside the `BeginTable` success path only — the early `return` above handles the false case.

- [ ] **Step 6: Wire it into the draw loop**

In `loop()`, the `if state.header then` branch currently runs from line 546 to 633. Leave the Layout preset block (lines 547-600) alone for now — Task 5 collapses it. Replace lines 602-612 (the `im.Spacing`, three `RoleCombo` calls, the skip-tokens hint and input) with just the skip-tokens block, keeping it where it is until Task 5 moves it:

```lua
      im.Spacing(ctx)
      im.TextDisabled(ctx, "Skip tokens — one per line. A row whose Filename cell\n" ..
                           "matches is not yet recorded and is excluded.")
      local skchanged
      skchanged, state.skip_text = im.InputTextMultiline(ctx, "##skip", state.skip_text, 380, 54)
      if skchanged then
        MarkDirty()
        state.preview_dirty = true
      end
```

Then immediately before the `-- Run is blocked until…` comment (line 648), insert the refresh, the table and the count line:

```lua
    if state.preview_dirty then RefreshPreview() end

    if state.header and state.header_error == "" then
      -- Reserve room for the count line, the run button row and the separator
      -- above them; the table takes whatever is left.
      local reserve = im.GetFrameHeightWithSpacing(ctx) * 3
      DrawTable(math.max(120, im.GetContentRegionAvail(ctx) - reserve))

      local n = state.preview and #state.preview or 0
      local m = state.rows and #state.rows or 0
      im.TextDisabled(ctx, string.format("%d of %d rows will run.", n, m))
    end
```

Also widen the default window at line 524:

```lua
  im.SetNextWindowSize(ctx, 760, 720, im.Cond_FirstUseEver)
```

- [ ] **Step 7: Run the checks**

```bash
./run_tests.sh
```

Expected: PASS.

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```

Expected: no output.

- [ ] **Step 8: Manual verification in REAPER**

1. Open with a CSV whose layout is not remembered. Confirm both header rows draw, the body reads `Choose the Filename and Line Text columns above.`, and the `Filename` / `Line Text` labels are warning-coloured.
2. Map Filename. Body still shows the message (`BuildScriptLines` drops rows with an empty Line Text). Map Line Text. Body populates and the labels turn normal.
3. Map the Character column; confirm the character selector enables and lists the CSV's characters.
4. Pick one character. Confirm every other character's rows vanish and the count drops.
5. Set it back to `(all characters)`. Confirm all rows return.
6. Type a skip token matching a real Filename cell. Confirm those rows vanish and the count drops by the right amount.
7. Change the Character column to a different CSV column; confirm the selector repopulates and resets to `(all characters)` when the old value is absent.
8. Load a 1000+ row CSV; scroll the table and confirm it stays responsive and the two header rows stay frozen.
9. Resize the window taller; confirm the table grows and the run button stays visible.

- [ ] **Step 9: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua
git commit -m "feat(VO): spreadsheet preview table with in-header column mapping"
```

---

### Task 5: Collapse the options into two headers

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua` — the draw loop between the CSV path row and the table

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: no new names.

- [ ] **Step 1: Wrap the layout block**

Wrap the preset combo, the Save / Save As… / Delete row and the skip-tokens block (currently lines 547-612, minus the `SeparatorText(ctx, "Layout")` which is deleted) in:

```lua
      if im.CollapsingHeader(ctx, "Layout & presets") then
        -- … preset combo, Save / Save As… / Delete, skip-tokens hint + input …
      end
```

Delete the `im.SeparatorText(ctx, "Layout")` call. Skip tokens belong here because they are saved *into* a layout preset.

- [ ] **Step 2: Wrap the session options**

Replace the `-- This session ---` block (lines 635-642) with:

```lua
    im.Spacing(ctx)
    if im.CollapsingHeader(ctx, "Session options") then
      local sch
      sch, state.suffix_alt_names = im.Checkbox(ctx, "Suffix non-primary takes (_tk01, _tk02…)", state.suffix_alt_names)
      sch, state.use_alts_track   = im.Checkbox(ctx, "Send non-primary takes to the Alts track", state.use_alts_track)
      sch, state.primary_last     = im.Checkbox(ctx, "The last take of a line is the primary", state.primary_last)
      im.TextDisabled(ctx, "Uncheck the last box if the first read is usually the keeper.")
    end
```

Note the reordering: `Suffix` first, then `Alts track`, then `primary`, per the spec's layout sketch. The `SeparatorText(ctx, "This session")` is deleted.

Both headers are closed by default — `CollapsingHeader` with no `DefaultOpen` flag.

- [ ] **Step 3: Keep the no-CSV branches**

The `elseif state.header_error ~= "" then` / `else` branches at lines 627-633 stay as they are — with no CSV there is nothing to map, so the error text and `Choose a script CSV to map its columns.` remain the right output.

- [ ] **Step 4: Run the checks**

```bash
./run_tests.sh
```

Expected: PASS.

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```

Expected: no output.

- [ ] **Step 5: Manual verification in REAPER**

1. Open the dialog. Both headers are collapsed; the table dominates the window.
2. Expand `Layout & presets`; confirm the preset combo, three buttons and skip-tokens box are all there and the Delete button is disabled with no preset selected.
3. Save a preset, close and reopen the dialog; confirm mapping, skip tokens and preset name restore and the table repopulates.
4. Expand `Session options`; toggle each checkbox and confirm no ImGui assertion or stack error appears in the ReaScript console.
5. Collapse both again; confirm the table resizes to fill the reclaimed space.

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua
git commit -m "feat(VO): collapse layout and session options above the table"
```

---

### Task 6: Run gating below the table, and the version bump

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua:1-16` (header), and the run-gating block in the draw loop

**Interfaces:**
- Consumes: everything above.
- Produces: no new names.

- [ ] **Step 1: Confirm the run-gating block sits below the table**

The block computing `run_error`, the `Transcribe and cut` button, its hint, the warning text and `state.message` must be the last things drawn in the window, after the count line. If Task 4's insertion put the table above them, this is already true — verify by reading the draw loop top to bottom. The `run_error` logic itself is unchanged.

- [ ] **Step 2: Bump the version and changelog**

Replace lines 3-4 with:

```lua
-- @version 0.7
-- @changelog Run dialog rebuilt around a live preview table: columns are mapped in the table header, the body shows exactly the lines that will run, and layout and session options collapse out of the way; character filtering is now single-select
```

- [ ] **Step 3: Run the checks**

```bash
./run_tests.sh
```

Expected: PASS.

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```

Expected: no output.

- [ ] **Step 4: Manual verification in REAPER**

1. Unmap Line Text; confirm Run is disabled, the existing `Map the required column: Line Text` warning shows below the table, and the `Line Text` header label is warning-coloured.
2. Remap it and run a real transcription end to end; confirm the matched/review/unmatched counts and the report are as before.
3. Select a single character, run again, and confirm only that character's lines were processed.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua
git commit -m "feat(VO): move run controls below the preview table; bump to 0.7"
```

---

## Out of Scope

- `VO/ajsfx_VO_Settings.lua`
- Matching, transcription and routing behaviour
- Editing or sorting from the preview table
- The Result column, the clickable Take column, and the `Run`/`Finish` reshape (keeping the dialog open after a run) that both require — deliberately deferred, with `kind = "computed"` reserved in `COLUMNS` so they are additive
- Theme integration via `reaper.GetThemeColor`
