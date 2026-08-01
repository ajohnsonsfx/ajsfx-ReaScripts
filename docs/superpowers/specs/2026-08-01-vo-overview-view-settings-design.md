# VO Overview — view settings, column reorder, per-column presentation

Date: 2026-08-01
Scope: `VO/ajsfx_VO_Overview.lua` only. No changes to `VO/lib/ajsfx_vo.lua`,
ScriptMatch, or the Settings script.

## Problem

The Overview table is fixed. Columns sit where `COLUMNS` puts them, every cell
renders in one size, and long line text is clipped to a single line. A user
working a long session cannot make the table fit the way they read it, and any
width they do drag out is remembered only by accident.

Three things follow from that:

1. Columns cannot be reordered.
2. There is no place to put a preference, so there is no settings window.
3. Long text is unreadable, and the fix for it (word wrap) creates tall rows,
   which in turn creates a question ImGui does not answer: where in a tall row
   does a short cell sit?

## Decisions taken

Recorded here because each closes an ambiguity in the original request.

| Question | Decision |
| --- | --- |
| "Horizontal cell context alignment — top/middle/bottom" | Vertical alignment. Top/middle/bottom only; no left/center/right. |
| Where per-column settings live | `ExtState`, global across projects. A column's look is a personal preference, not a property of the session. |
| Font size outside the table | Fixed. Only table cells vary; the toolbar keeps its hand-tuned widths. |
| What "Restore view settings" covers | Column widths, column order, **and** per-column align/wrap/font. |

## Storage

All keys go in `ExtState(vo.EXT_SECTION, ...)` with `persist = true`, alongside
the existing `layout_*` keys. Deliberately **not** part of `vo.CONFIG_SCHEMA`:
that schema drives the ScriptMatch Settings dialog and describes matching, not
this window's presentation.

| Key | Values | Default |
| --- | --- | --- |
| `view_restore` | `"1"` / `"0"` | `"1"` |
| `view_font_small` | point size | `11` |
| `view_font_medium` | point size | `13` |
| `view_font_large` | point size | `16` |
| `view_col_<key>_align` | `top` / `middle` / `bottom` | `middle` |
| `view_col_<key>_wrap` | `"1"` / `"0"` | `0`, except `line_text` = `1` |
| `view_col_<key>_font` | `small` / `medium` / `large` | `medium` |

`<key>` is the column's `key` field from `COLUMNS` (`line_text`, `asset`, …),
never its index. Reordering columns therefore cannot scramble which setting
belongs to which column, and inserting a new column in a later version does not
shift every stored preference by one.

Medium defaults to 13 because that is the size the table draws at today; a user
who never opens Settings sees no change.

## Components

Five units, each with one job.

### `viewcfg` — the settings table and its persistence

Owns the defaults, reads them from `ExtState` at startup, writes on change.
Exposes:

- `viewcfg.restore` — boolean
- `viewcfg.sizes` — `{ small = n, medium = n, large = n }`
- `viewcfg.Column(key)` — `{ align =, wrap =, font = }`, defaults applied
- `viewcfg.SetColumn(key, field, value)` — writes through to `ExtState` and
  bumps the layout generation (below)
- `viewcfg.Clear()` — deletes every `view_col_*` key

Nothing else in the file reads `ExtState` for these.

### `fonts` — three attached fonts

ReaImGui fonts are created at a fixed size and must be attached to the context
before the frame that uses them. The script pins `require('imgui')('0.9.3')`, so
the 0.9.3 signatures apply regardless of the installed ReaImGui build:
`im.CreateFont(family, size)` → `im.Attach(ctx, font)` → `im.PushFont(ctx, font)`.

- Three fonts are created and attached at startup, one per preset.
- Changing a preset size in Settings detaches the old font, creates and attaches
  the replacement. The new size takes effect on the next frame; this is
  invisible at frame rate.
- `fonts.Push(size_key)` / `fonts.Pop()` wrap a cell. `medium` still pushes its
  font explicitly rather than relying on the default, so the medium preset is
  editable like the other two.
- The context is recreated if `ValidatePtr` fails (the existing loop already does
  this). Fonts must be re-attached on that path, so attachment lives in one
  function called from both startup and the recreate branch.

### `rowmetrics` — row heights for wrapped columns

The mechanism that makes wrap and vertical align possible. ImGui offers neither,
and the two are the same problem: both need the row's final height *before* the
row is drawn.

ImGui has no `TableGetColumnWidth`. A cell's usable width is only knowable from
inside that cell, via `GetContentRegionAvail`. That is a frame too late to size
the row it belongs to, so:

1. While drawing, every cell records its available width into
   `rowmetrics.width[column_index]`.
2. On the next frame, before `im.TableNextRow`, each wrapping column's height is
   measured with `im.CalcTextSize(ctx, text, nil, width[i])` under that column's
   font, and the row height is the maximum across the row (floored at
   `GetFrameHeight()`, so a row holding an `InputText` is never shorter than the
   widget in it).
3. That height is passed as `im.TableNextRow(ctx, 0, row_h)`.

**Accepted consequence — one frame of lag.** While a column edge is being
dragged, row heights are computed from the previous frame's width. Heights
settle on the following frame. At frame rate this is not perceptible, and the
alternative (a hidden measuring pass) costs a full extra table per frame.

**Cost and its containment.** `DrawTableBody` emits every row every frame; there
is no `ListClipper` (ReaImGui rejects it here, per the existing comment). A naive
implementation would call `CalcTextSize` once per wrapping cell per row per
frame. Heights are therefore cached on the row (`row._h`, `row._h_gen`) against a
generation counter, `rowmetrics.gen`, bumped when — and only when — one of these
happens:

- `Rebuild()` runs (row text may have changed)
- any recorded column width differs from the previous frame (a resize or reorder)
- `viewcfg.SetColumn` or a font preset changes

A table nobody is touching costs one integer comparison per row per frame.

### Cell drawing helpers

`CellText(col, text, kind)` replaces the bare `im.Text` / `im.TextDisabled` /
`im.TextColored` calls in `DrawTableBody`. It:

1. pushes the column's font,
2. offsets `SetCursorPosY` by `(row_h - cell_h) × factor`, where factor is
   `0` / `0.5` / `1` for top / middle / bottom,
3. draws with `PushTextWrapPos` when the column wraps, plain otherwise,
4. pops.

The widget cells (Item name `InputText`, Notes `InputText`, the OK `Checkbox`,
the Sel `RadioButton`) take the same vertical offset but ignore wrap:
a single-line input cannot wrap, and forcing a multiline widget here would change
what Enter means in a field where Enter currently commits a rename.

The row-spanning `Selectable` is given an explicit size of `(0, row_h)` so a
click anywhere in a tall row still selects it, rather than only in its top
`FrameHeight` pixels.

### Settings window

A second `im.Begin('VO Overview Settings', true)`, opened by a `Settings` button
in the top bar beside `Choose…`, closed by its own title-bar X. Not modal: the
point of changing a font size is watching the table change under it.

Contents, and nothing more:

- **Restore view settings** — checkbox.
- **Font sizes** — three `InputInt` fields, Small / Medium / Large, clamped to
  6–48. A size out of range is silently clamped rather than rejected; there is no
  wrong number a user can type that should produce an error message here.

## Column reorder

`TableFlags_Reorderable` is added to the flags in `DrawTable`. Nothing else
changes. The hand-drawn header loop and every `TableSetColumnIndex(n)` in
`DrawTableBody` address columns by *logical* index; ImGui maps logical index to
display position itself, so cells follow their headers with no code change.

## Restore view settings — what each state means

**On** (default). ImGui persists column widths and order to its own per-script
ini under `REAPER/ReaImGui/<hash>.ini`, which it already does today. Per-column
align/wrap/font persist in `ExtState`. Nothing to implement.

**Off.** `TableFlags_NoSavedSettings` is added, so ImGui stops writing and stops
reading widths and order; the table opens at the `COLUMNS` defaults. At the
moment the checkbox is turned off, `viewcfg.Clear()` deletes every stored
`view_col_*` key.

Clearing on the transition, rather than merely ignoring the keys, is deliberate:
it makes "off" mean one thing. The alternative leaves a hidden layer of
preferences that reappears the moment the box is ticked again, which is a
surprise with no upside.

Note that ImGui keys table settings by `(table id, column count)`. Adding or
removing a column in a future version invalidates a saved layout by itself. That
is correct behaviour — a saved order for the current twelve columns says nothing
useful about a thirteenth — and needs no handling.

## Header context menu

Each hand-drawn `im.TableHeader` call gains a `BeginPopupContextItem`. The
existing header loop already draws headers one at a time to hang tooltips off
them, so there is a per-column item to attach the popup to.

```
Vertical align  ▸  Top · Middle · Bottom
[ ] Word wrap
Font size       ▸  Small · Medium · Large
```

Every pick routes through `viewcfg.SetColumn`, which persists and bumps the
generation counter. No pick needs deferring through `pending_action`: none of
them mutates the project or the row set, only presentation.

## Error handling

- **Font creation fails.** `CreateFont` is called under `pcall`. On failure the
  preset falls back to the default font and the window shows the existing
  `state.message` line in its error colour. The table still draws.
- **A stored setting is unrecognised** (a hand-edited `ExtState`, or a key from a
  newer version). `viewcfg.Column` validates against the known value sets and
  falls back to the default. No message; a bad key is not something the user did.
- **The table body still runs under `pcall`.** The new code adds two more things
  that must be unwound if a row throws mid-draw: the font stack and the text-wrap
  stack. Both are tracked the way `id_depth` already tracks `PushID`, and unwound
  in the same loop in `DrawTable` before `EndTable`.

## Testing

`tests/` runs against `tests/mock_reaper.lua`, which has no ImGui. Drawing is
therefore not unit-testable, and the split above is chosen so that the parts
worth testing do not touch ImGui:

- `viewcfg` defaults, validation of unrecognised values, round-trip through a
  mocked `Get/SetExtState`, and `Clear()`.
- The vertical-offset arithmetic (`row_h`, `cell_h`, align → offset), extracted
  as a pure function so it can be called without a context.
- Font-size clamping.

The rest is manual, recorded in `VO/MANUAL_TEST.md`:

1. Drag a column to a new position; close and reopen; the order is kept.
2. Turn off Restore view settings; reopen; columns are back at their defaults and
   the header menu shows defaults.
3. Turn word wrap on for Line text; a long line grows the row, and the OK
   checkbox sits where the alignment setting says it should.
4. Set a column to Large; the row grows and the toolbar does not move.
5. Drag a column edge with wrap on; heights follow without flicker.

## Out of scope

Column show/hide, per-column horizontal alignment, saved view presets, and a
global window font size. Each is a reasonable next request; none is needed for
the table to be readable, and every one of them widens the settings window that
this design deliberately keeps to two controls.
