# VO Overview: nested line/take rows — design

Date: 2026-08-08
Target: `VO/ajsfx_VO_Overview.lua` (+ `VO/lib/ajsfx_vo_view.lua`, pure grouping in `VO/lib/ajsfx_vo.lua`)

## Problem

The Overview table has 18 fixed-width columns (~1800px declared). On a laptop
screen with the window narrowed, ImGui squeezes the columns to fit; word wrap
then makes rows very tall, and the table is unusable. The narrow-window tasks
are exactly the wide ones: comparing line text against transcript, marking
Sel/Keep/Lock, editing item names.

The root inefficiency is redundancy: every take row repeats its line's
script-side facts (line text, character, script, CSV filename, Append), and
line text + transcript sit side by side (480px) when they are only ever read
as a comparison.

## Decisions (agreed in brainstorming)

1. The table becomes a **tree**: one parent row per script line, its takes
   nested beneath. No flat mode.
2. The table is **always in script order**. Header-click display sorting is
   removed entirely (sort accessors, tristate logic, sort-spec plumbing).
   The Sort *panel* — which rearranges items on the timeline — is a different
   feature and is untouched.
3. Columns collapse 18 → 6 groups. **Every column asks one question; the
   parent answers it for the line, the child answers it for the take.**
4. Marks are plain per-take **checkboxes** (binary, one click), labelled once
   per expanded line by a slim **sub-header row**, never per take row.
5. Character becomes a **group header row** (script order makes characters
   contiguous). Orphans group under one **"Not on the script"** section at
   the bottom.

## Row model

- **Parent row = script line.** One per merged script line, in script order.
  Rows that today synthesize per-line facts (status, Got) roll up here.
- **Child row = take.** Everything that produces a row today — matched spans,
  name-adopted items, hand-comped extras — in take order under its line.
- **Missing lines** have no children: the parent row alone, red dot, is the
  whole story. No expand arrow.
- **Orphans** (recorded audio matching no line) cannot nest under a line;
  they render as child-shaped rows under a single "Not on the script"
  section header at the bottom of the table.
- **Character group headers:** a full-width header row whenever the character
  changes ("— GRUMBAR —"). Replaces the Character column.
- **Expand state:** default expanded (working state). Collapse is for
  skimming coverage. Collapsed-line set persists in the project file's view
  section, keyed the same way rows are (line key), so a reopened project
  looks the way it was left. Global expand/collapse-all in the header bar.

## Columns

Frozen top header carries the questions; parent and child answer:

| | **#** | **State** | **Text** | **Name** | **Where** | **Notes** |
|---|---|---|---|---|---|---|
| **Parent (line)** | Line number in the script + expand arrow | Status dot + Got badge (`● ✓2`) + rollup text (loudest: "no Sel yet") | Line text (what the script says) | CSV filename + Append rendered inline, dimmed (delivered name) | Which script: `mainquest.csv · row 41` | Line-level note |
| **Child (take)** | Take number `1, 2, 3` (replaces the old `2/3` Take column) | Status dot + `[Sel] [Keep] [Lock]` checkboxes | Transcript (what was said) — stacked directly beneath for comparison | Item name, editable (the take's actual name); vertical diff against parent shows drift | Which recording: `rec_03 @ 4:12.3`; full paths in tooltip | Take-level note (entries are already keyed per row) |

Approximate widths: # 48, State 150, Text stretch (min ~240), Name 190,
Where 140, Notes stretch. Comfortable at ~900px.

### Full layout example

One character section with an expanded line (two takes), a collapsed line, a
missing line, and the orphan section. `▾/▸` is the expand arrow in the # cell;
`●` is the status dot (colour carries the status); the `Sel Keep Lock` row is
the per-line sub-header.

```
 #    │ State              │ Text                        │ Name                    │ Where               │ Notes
══════╪════════════════════╪═════════════════════════════╪═════════════════════════╪═════════════════════╪══════════════
── GRUMBAR ──────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ▾ 41 │ ● ✓1               │ Get off my bridge!          │ grum_bridge_01 _v2      │ mainquest.csv · 41  │ redo w/ growl
      │    Sel  Keep  Lock │                             │                         │                     │
   1  │ ●  [x]  [ ]   [x]  │ get off my bridge           │ grum_bridge_01          │ rec_03 @ 4:12.3     │
   2  │ ●  [ ]  [x]   [ ]  │ get OFF my bridge           │ grum_bridge_01_alt1     │ rec_03 @ 4:18.9     │ angrier
 ▸ 42 │ ● ✓1               │ You shall not pass the toll │ grum_toll_01            │ mainquest.csv · 42  │
   43 │ ●  (no takes)      │ A troll has standards, you… │ grum_standards_01       │ mainquest.csv · 43  │
── VERA ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ▾ 44 │ ●    (no Sel yet)  │ Pay him. We don't have time │ vera_pay_01             │ mainquest.csv · 44  │
      │    Sel  Keep  Lock │                             │                         │                     │
   1  │ ●  [ ]  [ ]   [ ]  │ pay him we don't have time  │ vera_pay_01             │ rec_04 @ 0:22.1     │
── NOT ON THE SCRIPT ────────────────────────────────────────────────────────────────────────────────────────────────────
   —  │ ●                  │ uh line's good, moving on   │                         │ rec_04 @ 1:03.7     │
```

Reading it:

- **Row 41, expanded:** parent carries the script's answer in every column —
  line text, delivered name (`grum_bridge_01` + Append ` _v2` dimmed), script
  origin, line note. The sub-header labels the checkbox columns once; take
  rows 1–2 carry only take facts, each cell correlated with the parent cell
  above it (transcript under line text, item name under delivered name,
  recording position under script position).
- **Row 42, collapsed:** one row summarises the line — green dot, one
  delivered. Expand to work on it.
- **Row 43, missing:** no arrow, no children; red dot and "(no takes)".
- **Row 44:** the rollup warning — recorded but no Sel ticked yet.
- **Orphan section:** child-shaped rows (transcript, recording position),
  no parent to answer the line-side questions.

### The State group

Physically four narrow columns (dot, Sel, Keep, Lock) treated as one visual
unit under a single "State" header:

```
                 State
parent → ● ✓2   (no Sel yet)        ← rollup spans the group
           Sel   Keep   Lock         ← sub-header row, once per expanded line
take 1 → ● [x]   [ ]    [ ]
take 2 → ● [ ]   [x]    [x]
```

- Status **dots** replace status words: green recorded / amber review /
  red missing / grey orphan (reuse `STATUS_STYLE` colours); word + detail in
  the tooltip. Take dots carry take-level facts (review, partial coverage,
  adopted-by-name) that today hide inside the shared Status column.
- **Sub-header row:** a slim dimmed row drawn under each expanded parent,
  labelling the checkbox columns. Costs ~16px per expanded line. Fallback if
  that proves heavy in use: move `Sel Keep Lock` into a two-tier frozen
  header (zero per-line cost); build the per-line version first — labels
  near the inputs win.
- Checkbox semantics unchanged: Sel is exclusive per line (ticking one
  clears siblings via the existing `SetSelect` path), Keep and Lock are
  independent. Lock = the existing `user_status == "verified"`.

## Interactions

- **Append:** edited via double-click or right-click on the parent's Name
  cell (inline InputText swap, same pattern as the current editable cells).
  It moves from always-visible edit box to edit-on-demand — accepted in
  brainstorming as fitting its rarity.
- **Rename / reset name / make select / copy:** the existing right-click
  menu moves to the child's Name cell unchanged. Parent Name right-click
  offers copy CSV filename + edit Append.
- **Navigation** (click-to-jump, audition): unchanged, from child rows.
  Expand/collapse toggles on the parent's arrow (# cell) only; clicking
  elsewhere on a parent row selects, like any row.
- **Selection model:** spreadsheet-style row selection (click, shift-range,
  ctrl-toggle) continues to operate on take rows; selecting a parent selects
  its takes. `selection_only` scoping for Cut/Pull/Sort keeps working on the
  take rows it resolves to.
- **Search & filters:** the search box and character filter operate on
  *lines*; a match on any take-side field keeps the whole line visible with
  all its takes. The per-column filter row survives with the new columns
  (Text filter matches line text OR transcript; Name matches either name;
  Where matches script or source). Stored filters for removed columns are
  dropped on load — the existing `COLUMN_BY_KEY` guard already does this.
- **Rollup signal:** a line whose status is recorded but has no Sel ticked
  shows "no Sel yet" in the parent State cell — previously discoverable only
  by scanning every take row.

## Removed / relocated

| Old column | Fate |
|---|---|
| `#` | Parent #; child take number |
| Lock, Sel, Keep | State group checkboxes |
| Status | State dots + tooltip |
| Got | Badge in parent State cell |
| Character | Group header rows |
| Script | Parent Where cell |
| Item name | Child Name cell |
| CSV filename | Parent Name cell |
| Append | Inline in parent Name cell, edit on demand |
| Take | Child # cell / implied by nesting |
| Line text | Parent Text cell |
| Transcript | Child Text cell |
| Source, Time | Child Where cell |
| Notes | Notes column, both levels |

Also removed: header-click sorting and everything only it used
(`SORT_SPECS`/`NEED_SORT`/`SORT_DESC`, `sort_col`/`sort_desc`, and the
per-column `num` accessors, which existed only to sort). The Sort, Cut and
Pull panels are untouched; Sort remains the timeline-manipulation tool it is,
living in its existing on-demand panel (a separate OS window was considered
and rejected: the panel costs no width and no space when closed).

## Persistence & migration

- **View settings** (`ajsfx_vo_view.lua` per-column align/wrap/font,
  mirror): re-keyed to the new column set. The line_text/transcript mirror
  pairing becomes moot (they share the Text column; parent/child cells can
  share one view record) — mirror option removed.
- **ImGui table layout:** column count changes, which by ImGui's own keying
  invalidates saved widths — correct and automatic.
- **Project file:** no schema change to entries. The view section gains the
  collapsed-line set; stored `col_filters` under old keys are dropped by the
  existing unknown-key guard.
- **Version:** this is a visible redesign — ship as a pre-release first
  (`0.15beta1`-style letter version) so only opt-in users receive it until
  it has survived a real session.

## Testing

- The **grouping function** — flat overview rows → ordered
  {character sections → lines → takes, orphan section} — is pure Lua: add it
  to `ajsfx_vo.lua` (not the script) and cover it in `tests/` with the mock
  REAPER: take numbering, missing lines childless, orphan grouping,
  character section breaks, adopted/extra rows landing under the right line.
- **Rollup derivation** (has-Sel, lock counts, Got badge) is pure per-line:
  unit test alongside.
- Filter semantics (line-level visibility from take-level matches) already
  have pure entry points; extend existing tests.
- Rendering itself is verified in live REAPER via the existing MCP harness
  (see memory: VO MCP test harness).

## Out of scope

- Sources and Settings windows.
- Matching, cutting, pulling, timeline-sorting behaviour.
- Any change to the project-file entry schema or the name-is-the-assignment
  model.
