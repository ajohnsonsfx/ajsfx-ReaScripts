# VO ScriptMatch — spreadsheet-first run dialog

**Date:** 2026-07-25
**Scope:** `VO/ajsfx_VO_ScriptMatch.lua` run dialog. Presentation plus one behavioural
simplification (single-character filter).

## Problem

The run dialog is a stack of form controls. Column mapping, the character filter and
the filename options each live in a different section, so a setting is separated from
the column it acts on. Nothing shows what the CSV actually contains, so a wrong column
choice is invisible until after a transcription run, and the effect of the skip tokens
and character filter is never shown at all.

## Goal

Make the script table the interface. Columns are mapped *in the table header*, and the
table body is the list of lines that will actually run — the real CSV content, with the
filters already applied. Everything else collapses out of the way.

## Layout

```
[N item(s) selected, M skipped]
Script CSV  [_______________________________________] [Browse]

▸ Layout & presets
▸ Session options

┌ Character ─────────────────┬ Filename ────────┬ Line Text ──────────────┐
│ [Column ▾] [Character ▾]   │ [Column ▾]       │ [Column ▾]              │
├────────────────────────────┼──────────────────┼─────────────────────────┤
│ RIVA                       │ vo_riva_intro_01 │ We should not have c…   │
│ RIVA                       │ vo_riva_intro_02 │ Quiet. Something is …   │
│ RIVA                       │ vo_riva_deck_01  │ Seal it. Nobody goes…   │
│ …                                                                       │
└─────────────────────────────────────────────────────────────────────────┘
                                       (table fills remaining window height)

128 of 214 rows will run.
[Transcribe and cut]   Nothing changes until transcription finishes.
```

Expanded, the two collapsing headers contain:

```
▾ Layout & presets
  Preset [(unsaved) ▾]   [Save] [Save As...] [Delete]
  Skip tokens — one per line. A row whose Filename cell matches is not
  yet recorded and is excluded.
  [_________________________________]

▾ Session options
  ☐ Suffix non-primary takes (_tk01, _tk02…)
  ☐ Send non-primary takes to the Alts track
  ☑ The last take of a line is the primary
  Uncheck the last box if the first read is usually the keeper.
```

## Requirements

### R1 — Column descriptor model

The table is driven by an ordered descriptor list, not hardcoded columns:

```lua
local COLUMNS = {
  { key = "speaker", label = "Character",
    kind = "mapped", role = "speaker", optional = true, filter = "character" },
  { key = "asset",   label = "Filename",
    kind = "mapped", role = "asset",   required = true },
  { key = "text",    label = "Line Text",
    kind = "mapped", role = "text",    required = true },
}
```

`kind = "mapped"` columns render a column-selector combo in the selector row and take
their body values from the CSV. The model reserves `kind = "computed"` for columns
whose header is a static label and whose body is produced by a render function — the
extension point for the future Result and Take columns (see Future work). Nothing in
the drawing code may assume all columns are mapped.

### R2 — Table header

Two frozen rows (`im.TableSetupScrollFreeze(ctx, 0, 2)`):

**Row 1 — static labels.** `Character`, `Filename`, `Line Text`, from
`descriptor.label`. Required columns whose role is unmapped show the label in the
warning colour, so what is blocking the run is visible in the header itself.

**Row 2 — selectors.** Each mapped column gets a combo listing the CSV header names,
sized to the table column via `im.SetNextItemWidth`. The Character column's cell holds
**two combos side by side** on the same line: the column selector, then the character
selector (R3). No extra row, no taller header.

Combo labels are hidden (`##<key>_col`). The optional Character column's selector leads
with `(none)`. Changing a selector calls `MarkDirty` and, for the speaker role,
`RebuildDistinct`, exactly as today.

Table flags: `Borders | Resizable | ScrollY | RowBg`. The Character column is given a
wider initial width to fit its two combos.

### R3 — Single-character filter

Multi-character selection is removed. Recording sessions put one character per media
file; a session with two characters is handled by running the script twice.

- `state.excluded` (a set of folded keys) is replaced by `state.character` — a single
  folded key, or `nil` for "(all)".
- The character selector combo lists `(all characters)` followed by the display names
  from `state.distinct`. It is disabled when no character column is mapped.
- `RebuildDistinct` keeps `state.character` if that character still exists in the new
  column, and resets it to `nil` if not.
- In `Run()`, the include-set passed to `BuildScriptLines` is
  `{ [state.character] = true }` when a character is selected, and `nil` otherwise —
  a set of one. `vo.BuildScriptLines` is unchanged; so is the rule that the filter is
  inert when no character column is mapped.
- The "No characters selected." error path disappears — it is now unreachable.

Character selection stays per-run: it is not saved into layout presets and does not
mark the layout dirty.

### R4 — Table body

The body shows **only the rows that will be processed**. Excluded rows are hidden, not
dimmed. Cell text is clipped, not wrapped, so a long line of dialogue cannot change row
height.

The rows are the return value of the same call `Run()` makes:

```lua
local lines = vo.BuildScriptLines(state.rows, cols, { skip_values = …, speakers = …, canonicalize = … })
```

which returns `{ text, asset, speaker, row }` per surviving line — exactly the three
column values the table needs. The preview is not a reimplementation of the filter
rules and cannot drift from them. Character names shown are the canonicalized forms,
matching the output.

Rows therefore disappear from the table when excluded by a skip token, by the character
filter, or by an empty Filename or Line Text cell.

**The header and selector rows are always drawn**, including when the body is empty —
they are the controls the user needs in order to fill the body. Empty-body states show
a dimmed message in place of rows:

| State | Message |
|---|---|
| A required column is unmapped | `Choose the Filename and Line Text columns above.` |
| All mapped, nothing survives | `No script lines survive the current filters.` |

Below the table: `N of M rows will run.` — `N` = `#lines`, `M` = `#state.rows`. This is
the only signal that rows were excluded, since they are no longer visible.

**Sizing.** The table fills the remaining window height (`im.GetContentRegionAvail`
minus the reserved height of the count line and the run button row below it).

**Performance.** `BuildScriptLines` is not called per frame. It is recomputed only when
an input changes — CSV load, mapping change, skip-text edit, character selection —
each of which sets `state.preview_dirty`. Row drawing uses `im.CreateListClipper` so
only visible rows issue draw calls.

### R5 — Collapsed sections

Two `im.CollapsingHeader` sections above the table, both closed by default:

| Section | Contents |
|---|---|
| Layout & presets | Preset combo; Save / Save As… / Delete; skip-tokens hint and multiline input |
| Session options | `Suffix non-primary takes`; `Send non-primary takes to the Alts track`; `The last take of a line is the primary`; existing hint line |

Skip tokens sit with the presets because they are saved *into* a layout preset; the
Session options are per-run `cfg` values. Both headers stay visible (not hidden) so a
non-default setting is one click from view.

The `Layout`, `Character filter` and `This session` `SeparatorText` sections are
removed.

### R6 — Run gating

Unchanged in substance: the run is blocked until the CSV is valid and both required
roles are mapped, with today's messages. Presentation changes only — the required
column's header label also turns warning-coloured while unmapped.

The `Transcribe and cut` button, its hint, the run-blocked message and
`state.message` sit below the table, remaining the last elements in the window.

### R7 — Behaviour preserved

No change to:

- `state.mapping` and `state.skip_text` semantics
- layout preset save/load/delete, `MarkDirty` on mapping or skip edits
- `PersistProjectMemory` and SPEC §5.3 restore precedence
- `cfg` assignment on Run; matching, transcription and routing behaviour
- any function in `VO/lib/ajsfx_vo.lua`

## Accepted consequences

1. **Multi-character runs are no longer possible in one pass.** Deliberate, per R3.
   A mixed-character session requires two runs. `vo.BuildScriptLines` still accepts an
   arbitrary include-set, so restoring multi-select later is a UI change only.

2. **Session options are one click away rather than always visible.** Both headers are
   collapsed by default. Their settings persist in `cfg` as they do today, so a
   forgotten checkbox stays in effect unseen. Mitigated by keeping the headers
   themselves always visible.

3. **Wider default window.** Default size grows from 520×560 to roughly 760×720 to fit
   three table columns and the Character column's two combos. Still user-resizable, and
   `Cond_FirstUseEver` means a remembered size wins.

4. **The table is empty until both required columns are mapped.** `BuildScriptLines`
   drops rows with an empty Filename or Line Text, so it returns nothing until both are
   chosen. Accepted deliberately: the selectors and the CSV-derived dropdown contents
   are the feedback during mapping, and the run is blocked in that state anyway. The
   empty body carries an instructive message rather than nothing (R4).

5. **Excluded rows are invisible.** Hiding rather than dimming means a skip token that
   matches more than intended removes rows silently. The `N of M rows will run.` count
   is the only indication. Accepted: an accurate list of what will run is the more
   useful default, and the count makes an over-broad filter noticeable.

## Future work

These are not in scope, but the design above is shaped so they are additive:

1. **Result column** — a `kind = "computed"` column showing per-line match / review /
   unmatched status after a run.
2. **Take column** — a computed column whose cell is clickable and moves the edit
   cursor to that line's primary take without changing play state.
Items 1 and 2 both require the dialog to stay open after the run rather than closing to
a summary message box. That reshape of `Run` / `Finish` is deliberately deferred.

## Decided: the toolkit stays ReaImGui

There is no scriptable native REAPER widget toolkit — Project Bay's controls are C++
and not exposed — so matching REAPER's look was never on the table. The choice was
between ReaImGui and a `gfx`-based Lua toolkit (rtk, Lokasenna GUI v2).

**ReaImGui, on usability and liveness grounds:**

- The two primitives this design depends on, `TableSetupScrollFreeze` (two-row frozen
  header) and `ListClipper` (draw only visible rows), have no equivalent in the
  `gfx` toolkits, which redraw every widget in Lua each frame. A thousand-row table is
  the difference between free and unusable.
- ReaImGui tracks upstream Dear ImGui and is actively maintained; Lokasenna GUI v2 is
  dormant. "Not dead" was an explicit requirement.

Theme integration via `reaper.GetThemeColor` is explicitly **not** pursued. Function
over appearance; the default ImGui style is acceptable. Revisit only if it becomes a
usability problem rather than an aesthetic one.

## Testing

Existing tests in `tests/` cover `vo.lua` logic, not dialog drawing, and must continue
to pass unchanged — this change touches no library function.

No new unit tests are warranted: the will-run set is `BuildScriptLines`'s output, which
is already covered in `tests/test_vo.lua`. Verification is manual, in REAPER:

1. Load a CSV with no layout remembered; confirm the header and selector rows draw, the
   body shows `Choose the Filename and Line Text columns above.`, and required column
   headers are warning-coloured until mapped.
2. Map Filename and Line Text; confirm the body populates on the second selection.
3. Pick a character; confirm every other character's rows disappear and the count drops.
4. Set it back to `(all characters)`; confirm all rows return.
5. Type a skip token matching a real Filename cell; confirm those rows disappear and the
   count drops by the right amount.
6. Change the Character column to a different CSV column; confirm the character
   selector repopulates and the selection resets when the old value is absent.
7. Unmap Line Text; confirm Run is blocked with its existing message.
8. Load a 1000+ row CSV; confirm scrolling stays responsive.
9. Save a preset, close and reopen; confirm mapping, skip tokens and preset name
   restore and the table repopulates.
10. Resize the window taller; confirm the table grows and the run button stays visible.
