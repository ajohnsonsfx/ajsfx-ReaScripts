# VO ScriptMatch — CSV config UI regroup

**Date:** 2026-07-25
**Scope:** `VO/ajsfx_VO_ScriptMatch.lua` run dialog only. Presentation change.

## Problem

The run dialog stacks all three column dropdowns together under **Layout**, then puts
the character filter in a separate section far below, and the "suffix non-primary
takes" option in a third section (**This session**) with unrelated routing options.

A setting is therefore separated from the column it acts on. The user has to look in
three places to understand one decision, and there is no way to confirm a column
selection is correct — or see what the filters actually excluded — without opening
the CSV in another application.

## Goal

1. Group each column dropdown with the settings that act on it.
2. Show a live preview table of the rows that will actually be processed.

## Layout

```
[N item(s) selected, M skipped]
Script CSV  [_______________________] [Browse]

── Layout ────────────────────────────────────────────────
Preset [(unsaved) ▾]   [Save] [Save As...] [Delete]

── Character ─────────────────────────────────────────────
[Character Column:  Character            ▾]
      ┌──────────────────────────────────┐
      │ ☑ NARRATOR                       │
      │ ☑ RIVA                           │
      │ ☐ GUARD                          │
      └──────────────────────────────────┘
      Unchecked characters are excluded from this run.

── Filename ──────────────────────────────────────────────
[Filename Column:  Asset               ▾]
☐ Suffix non-primary takes (_tk01, _tk02…)
Skip tokens — one per line. A row whose Filename cell matches
is not yet recorded and is excluded.
[________________________]

── Line Text ─────────────────────────────────────────────
[Line Text Column:  Line                ▾]

── This session ──────────────────────────────────────────
☐ Send non-primary takes to the Alts track
☑ The last take of a line is the primary
Uncheck the last box if the first read is usually the keeper.

── Preview — 128 lines ───────────────────────────────────
┌ Character ─┬ Filename ──────────┬ Line Text ───────────┐
│ NARRATOR   │ vo_nar_open_01     │ The station had bee… │
│ RIVA       │ vo_riva_intro_01   │ We should not have … │
│ RIVA       │ vo_riva_intro_02   │ Quiet. Something is… │
│ …                                                      │
└────────────┴────────────────────┴──────────────────────┘
                            (fills remaining window height)

──────────────────────────────────────────────────────────
[Transcribe and cut]   Nothing changes until transcription finishes.
```

## Requirements

### R1 — Labels inside the dropdowns

Each role dropdown displays its label inside the closed control:
`Character Column:  <selected column>`, where the selected column is the header name
or `(none)`. This frees the horizontal space an external ImGui label consumes.

`RoleCombo` is rewritten from `im.Combo` to `im.BeginCombo` /
`im.Selectable` / `im.EndCombo`, since `im.Combo` derives its closed-state text from
the selected item and cannot show a composed preview string. The ImGui label becomes
`##<role>_col` (hidden). Each combo is set to full available width via
`im.SetNextItemWidth`.

Required roles (Filename, Line Text) keep a `*` marker in the preview string:
`Filename Column *:  Asset`. Selection semantics, the `(none)` entry for the optional
Character role, `MarkDirty` on change, and `RebuildDistinct` when the speaker column
moves are all unchanged.

### R2 — Section grouping

Sections in order: **Layout**, **Character**, **Filename**, **Line Text**,
**This session**, **Preview**.

| Section | Contents |
|---|---|
| Layout | Preset combo; Save / Save As… / Delete |
| Character | Character Column combo; bordered scrolling checkbox list (indented beneath the combo); dimmed hint "Unchecked characters are excluded from this run." |
| Filename | Filename Column combo; `Suffix non-primary takes (_tk01, _tk02…)` checkbox; skip-tokens hint and multiline input |
| Line Text | Line Text Column combo |
| This session | `Send non-primary takes to the Alts track`; `The last take of a line is the primary`; existing hint line |
| Preview | The preview table (R3) |

Relocations from today:

- **Character filter** moves out of its own `Character filter` section into the
  Character section; that separator is removed.
- **Suffix non-primary takes** moves out of `This session` into Filename. It is a
  filename option.
- **Skip tokens** move out of the Layout block into Filename. They match against the
  Filename cell.

The character checkbox list keeps its existing widget and `state.excluded` keying; it
gains a bordered child window with a fixed height (~4 rows) so a large cast scrolls
instead of pushing the rest of the dialog down.

### R3 — Preview table

A three-column table — **Character**, **Filename**, **Line Text** — showing the rows
that will actually be processed.

**Source of truth.** The rows are the return value of `vo.BuildScriptLines(state.rows,
cols, {skip_values = ParseSkipLines(state.skip_text), speakers = …, canonicalize = …})`
— the same call, with the same arguments, that `Run()` makes. The preview is not a
reimplementation of the filters; it cannot drift from what the run does. Character
names shown are therefore the canonicalized forms, matching the output.

Consequences that follow from using that function, and are intended:

- Rows whose Filename cell matches a skip token do not appear.
- Rows whose character is unchecked do not appear (only once at least one character
  has been unchecked — the filter is inert until then, per existing behaviour).
- Rows with an empty Filename or empty Line Text do not appear.

**Header.** The section separator reads `Preview — N lines`, N being the row count.
When N is 0 the table is replaced by dimmed `No script lines survive the current
filters.` — the same condition that blocks the run with that message.

**Character column.** Rendered empty when no character column is mapped. The column
is always present so the table shape does not shift.

**Sizing.** The table fills the remaining window height: height is
`im.GetContentRegionAvail` minus the reserved height of the separator, run button row
and message lines below it. It scrolls vertically (`TableFlags_ScrollY`) with a frozen
header row, and has borders and resizable columns
(`TableFlags_Borders | TableFlags_Resizable`). Cell text is clipped, not wrapped, so a
long line of dialogue cannot alter row height.

**Performance.** `BuildScriptLines` is not called per frame. The result is cached and
recomputed only when an input changes: CSV load, mapping change, skip-text edit, or a
character checkbox toggle. Each of those sets `state.preview_dirty = true`; the draw
code recomputes when dirty and clears the flag. Row drawing uses
`im.CreateListClipper` so only visible rows issue draw calls, keeping a
multi-thousand-row CSV responsive.

### R4 — Run button placement

The `Transcribe and cut` button, its hint, the run-blocked message and
`state.message` move **below** the preview table, remaining the last elements in the
window.

### R5 — Behaviour preserved

No change to any of:

- `state.mapping`, `state.excluded`, `state.distinct`, `state.skip_text` semantics
- layout preset save/load/delete, `MarkDirty` on mapping or skip edits
- `PersistProjectMemory` and SPEC §5.3 restore precedence
- the run-blocked validation, its messages, and `cfg` assignment on Run
- `RebuildDistinct` firing when the speaker column moves
- no library function in `VO/lib/ajsfx_vo.lua` is modified

Toggling a character checkbox still does not mark the layout dirty (character
exclusions are per-run, not part of a preset) — it only invalidates the preview.

## Accepted consequences

1. **Preview needs both required columns.** `BuildScriptLines` drops rows with an
   empty Filename or Line Text, so before both required columns are mapped it returns
   nothing. In that state the preview shows dimmed
   `Map the Filename and Line Text columns to see a preview.` rather than an empty
   table. Accepted: the run is blocked in the same state.

2. **Suffix checkbox hidden without a CSV.** The Filename section only renders when
   `state.header` is set, so `Suffix non-primary takes` disappears when no CSV is
   loaded, where today it is always visible. Accepted: the run is blocked and the
   setting has nothing to act on.

3. **Taller default window.** Default size grows from 520×560 to roughly 620×760 to
   give the preview usable room on first open. The window remains user-resizable and
   `Cond_FirstUseEver` still means a remembered size wins.

## Testing

Existing tests in `tests/` cover `vo.lua` logic, not dialog drawing, and must
continue to pass unchanged — this change touches no library function.

No new unit tests are warranted: the preview's correctness is `BuildScriptLines`'s
correctness, which is already covered in `tests/test_vo.lua`. Verification is manual,
in REAPER:

1. Load a CSV; confirm section order, labels inside the combos, and a populated preview.
2. Uncheck a character; confirm its rows leave the preview and the count updates.
3. Re-check every character; confirm all rows return (filter inert).
4. Type a skip token matching a real Filename cell; confirm those rows leave.
5. Change the Filename column to a wrong one; confirm the preview visibly changes.
6. Unmap Line Text; confirm the "map the required columns" preview message and that
   Run is blocked with its existing message.
7. Load a 1000+ row CSV; confirm the dialog stays responsive while scrolling.
8. Save a preset, close and reopen the dialog; confirm mapping, skip tokens and
   preset name restore, and the preview repopulates.
9. Resize the window taller; confirm the table grows and the run button stays visible.

## Out of scope

- `ajsfx_VO_Settings.lua` — its CSV panel is untouched.
- Any change to matching, transcription, or routing behaviour.
- Editing CSV values from the preview table; sorting the preview.
