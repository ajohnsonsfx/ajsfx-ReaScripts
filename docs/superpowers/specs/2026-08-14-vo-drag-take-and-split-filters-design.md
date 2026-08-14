# VO Overview: drag a take to another line, and split the text filter

Date: 2026-08-14
Status: approved, ready for an implementation plan
Scope: `VO/ajsfx_VO_Overview.lua`, `VO/lib/ajsfx_vo.lua`, `tests/`

Two independent features, specified together because they land in the same
file and the same release.

---

## Feature 1 — Drag a take onto another line

### The problem

A take sits under the wrong line. Today the only ways out are to retype the
item name by hand in the Name cell, or to select the item in REAPER and press
`+ Add Take` on the right line — and neither removes the take from the line it
is on now, because neither touches the take marker that put it there.

### What decides which line a take belongs to

`vo.BuildOverview` groups takes with `takes_by_asset[line.asset]`, where the
asset comes from the take **marker's** name. The marker is the assignment; the
item name is the delivery. Moving a take between lines therefore means
rewriting the marker, and anything that renames without rewriting the marker
leaves the take exactly where it was and adds a name/marker mismatch for
Check to flag.

### The operation

Dropping take *T* onto line *L* changes three facts, in one
`core.Transaction("VO Overview: move take to line")`:

1. **The marker names the target line.** How depends on whether `T` has one:

   - **`T.marker_id` is set** (a take row) — the marker keeps its id and its
     span; only its name is rewritten, with `vo.FormatMarkerName(L.asset, id)`.
     The id is deliberately preserved: the stored marks are keyed `tkm|<id>`,
     so notes ride along with the take rather than being stranded.
   - **`T.marker_id` is nil** (an orphan — an unmatched transcript span, which
     is a span row and has never had a marker) — a marker is minted with
     `vo.MintMarkerId(TakenMarkerIds())` and added with `vo.AddMarkerToItem`,
     spanning the item's source coverage via `vo.SourceCoverageRanges`. The
     row's stored entry is re-keyed from `row.key` to `tkm|<id>`, so its marks
     and notes are not stranded on a key nothing builds any more. This is the
     marker half of `AssignSelectedItems`, which already does exactly this.
2. **The item is renamed** to the next free *alt* name in `L`'s family —
   `L.deliver` plus `vo.FormatAltAppend(...)` at the lowest unused number,
   computed the same way `MakeSelect` computes it. Never the plain delivered
   name: the plain name means "this take is the delivery", and a take that has
   just arrived is undecided.
3. **The item moves to the Review track** (`cfg.track_review`, default
   `Review`). `vo.MarkFromTrack` maps that track to no mark at all — it means
   "undecided, look at this" — which is exactly the state a just-moved take is
   in. If no track by that name exists, one is created at the end of the track
   list.

Stored `select` and `keep` on the take's entry are cleared: they were
decisions about the line it came from. `notes` and `status` are left alone.

Afterwards the sheet reloads once for the whole drop, not once per take.

### Refusals, reported not silent

- A take with **Lock** ticked (`user_status == "verified"`) does not move.
- A take with **no live item** does not move.
- A line with **no asset** is not a drop target and does not highlight.
- Dropping onto the line a take is already on is a no-op.

A drop that moved some takes and skipped others says so in one message:
`Moved 2 takes to line_042. 1 skipped (locked).`

### What can be dragged, and where

| From | To | Effect |
|---|---|---|
| a take row | another line's card | the operation above |
| an orphan row | a line's card | the same operation, minting the marker rather than retargeting it |
| a take row | the "Not on the script" card | un-assign (below) |

**Un-assigning** deletes the take's marker from the item and clears the item's
take name to empty, so REAPER falls back to showing the source filename. The
audio is untouched. With no marker the span reverts to an ordinary unmatched
transcript span, which is what the orphan list is built from. The name is
cleared rather than left: a name for a line the take no longer belongs to is
the mismatch this feature exists to remove.

The stored entry keyed `tkm|<id>` is deleted with the marker rather than
re-keyed to a span key. Every mark it held — Sel, Keep, Lock, notes — was a
judgement about a line this take no longer belongs to, and the project file
holds only live judgements.

**Multi-drag.** If the take under the cursor is part of the current row
selection (`state.selection`), the whole selection is dragged. Otherwise just
that one take. Rows in the selection that fail a refusal check are skipped
individually, not taken as a reason to abandon the drop.

### The gesture

ReaImGui's drag-drop API, reached through the existing `Api(name)` helper so a
binding that lacks it degrades rather than errors:

- **Source:** the `##take` Selectable in `DrawCardTakeRow` — shared by take
  rows and orphan rows, so one source covers both. The drag payload is the
  constant string `"vo_take"`; the actual rows travel in `DND.rows`, set when
  the drag begins.
- **Line target:** the `##band` Selectable in `DrawCardBand`, which already
  spans the card's full inner width folded or open.
- **Orphan target:** the orphan card's "Not on the script" heading, which
  becomes an `im.Selectable` for the purpose — a drop target needs an item
  with an ID, and `TextDisabled` has none.

The drag preview shows the take name and, when several are moving, the count.

If `Api('BeginDragDropSource')` is nil, no source and no target is registered
and every existing path (`+ Add Take`, the Name cell, the take context menu)
works exactly as it does now.

### Where the code lives

`VO/ajsfx_VO_Overview.lua` holds **196 top-level locals** against Lua's limit
of 200. This feature adds **exactly one**: `local DND = {}`, holding the drag
state and every function the feature needs (`DND.rows`, `DND.Source`,
`DND.LineTarget`, `DND.OrphanTarget`, `DND.MoveTo`, `DND.Unassign`,
`DND.NextAltName`). Nothing else in the file gains a top-level name.

`track_named(name)` is currently redefined as a closure inside `MakeSelect`,
`PlaceSelectedItems` and `TightenItems`. `DND` needs it too. Rather than a
fourth copy, it moves to `vo.TrackNamed(name)` in `VO/lib/ajsfx_vo.lua` and
the three existing callers use it — a targeted tidy inside the code this
feature already touches, and it makes the function testable.

Retargeting a marker needs a helper alongside the existing
`vo.AddMarkerToItem`:

```
vo.RetargetMarkerOnItem(item, marker_id, new_asset) -> ok, changed, why
vo.RemoveMarkerFromItem(item, marker_id)            -> ok, changed, why
```

Both parse with `vo.ParseTKMChunk`, edit the one marker whose id matches, and
write with `vo.WriteTakeMarkers`. Both are pure enough to test against the
mock REAPER.

### Tests

In `tests/`, against the mock:

1. `vo.RetargetMarkerOnItem` rewrites only the named marker and preserves its
   id and span.
2. `vo.RemoveMarkerFromItem` removes one marker and leaves siblings intact.
3. `DND.NextAltName` skips numbers already used by the target line's takes.
4. After a retarget, `vo.BuildOverview` reports the take under the new line and
   not under the old one.
5. After a retarget, the entry keyed `tkm|<id>` still carries its notes.
6. Dropping an orphan mints a marker spanning the item's source coverage, and
   the row comes back as a take of the target line.
7. Dropping an orphan re-keys its stored entry to `tkm|<id>`, so a note written
   while it was an orphan survives.
8. A locked take is refused and the message counts it.
9. Un-assigning removes the marker and the span comes back as an orphan.

---

## Feature 2 — Separate Script and Transcript filters

### The problem

The `Text` column's filter box matches `line_text .. " " .. transcript`, so
one needle answers "either what the script says or what was said". There is no
way to ask for a line whose script says one thing and whose take says another
— which is the exact shape of a flubbed read.

### The change

The single box hinted `Text` becomes two boxes side by side in the same filter
row, hinted **Script** and **Transcript**. Script matches `row.line_text`;
Transcript matches `row.transcript`. They AND with each other and with
everything else, exactly as any two column boxes do today. Typing the same
thing in both is allowed and means "the script says it and the take says it".

### How

The `text` column gains a `filters` sub-table and loses its own `text`
accessor:

```lua
{ key = "text", label = "Text", width = 260, stretch = 2.0,
  filters = {
    { key = "text.script", label = "Script",
      text = function(row) return row.line_text or "" end },
    { key = "text.said",   label = "Transcript",
      text = function(row) return row.transcript or "" end },
  },
  tip = "Line: what the script says. Take: what was actually said,\n" ..
        "directly beneath it for comparison." }
```

The column's header tip is unchanged; each box also carries its own tip naming
the one field it matches.

- The `COLUMN_BY_KEY` build loop also registers each `c.filters` entry under
  its own key. That is the only change `Matches`, the project-file load guard
  and `Clear filters` need — all three already work off that table.
- `ColumnKeys()` is **not** extended. It drives per-column *view* settings
  (widths, visibility); a sub-filter is not a column.
- `DrawFilters` draws one box per `c.filters` entry when a column has them,
  and the single box otherwise.

### Migration

A `col_filters.text` needle saved by an earlier version is dropped on load
rather than migrated: it cannot be known which of the two boxes the user
meant, and putting it in both would AND two different questions together.
The load guard already discards keys `COLUMN_BY_KEY` does not know, so this
happens with no new code. Same precedent as the restored-character filter,
which is dropped rather than shown matching nothing.

### Tests

1. A Script needle matches on `line_text` and not on `transcript`.
2. A Transcript needle matches on `transcript` and not on `line_text`.
3. Both set: only rows matching both survive.
4. A saved `text` key does not survive a load.

---

## Release

One version bump covering both features, with a `@changelog` entry naming each
— CI reads it for the ReaPack changelog. Pre-release (`0.15beta…`) as with the
rest of the 0.15 line.
