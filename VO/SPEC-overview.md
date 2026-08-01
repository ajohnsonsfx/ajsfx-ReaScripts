# ajsfx VO Overview — Design Spec

**Status:** Implemented · **Version:** 0.1 · **Date:** 2026-07-25

A project-wide picture of the dialogue in a session: every line the script says
should be there, every line that actually is, and the user's own marks over the
top. One table, all recordings, whether or not anything has been cut yet.

---

## 1. Why this is a separate script

`ajsfx_VO_ScriptMatch.lua` was built to **cut and pull takes**. A spreadsheet UI
was later grown onto the front of it, and the two purposes pull against each
other at every turn:

| | ScriptMatch | Overview |
|---|---|---|
| Scope | the current item selection, on one track | every item in the project |
| Lifetime | one run | the whole job, across sessions |
| Owns | derived data (transcripts, spans) | the user's judgements |
| Verb | *do something to this audio* | *tell me where I am* |

Trying to serve both from one dialog is what produced a selection-following
window that had to defend a live plan against every reselect. Splitting them
lets each be simple. Overview is the front door; small focused actions can hang
off it later.

### Non-goals

Overview does **not** transcribe, cut, split, move items between tracks, or pull
selects. Those belong to ScriptMatch and must not migrate here — that is exactly
the drift this split exists to prevent. The only thing Overview writes to the
project is a take name, and only when the user types one.

---

## 2. The three data layers

| Layer | File | Owner | Regenerable |
|---|---|---|---|
| **Expected** | the script CSV | the production | n/a |
| **Actual** | `<audio>_vo_report.csv`, one per source | ScriptMatch | yes — disposable |
| **The user's work** | `<project>_vo_tracker.csv`, one per project | Overview | **no** |

The separation is the point of the whole design. Re-transcribing a recording
rewrites its sidecar wholesale; it must not cost the user a single checkmark.
Verified flags, notes, name overrides and select choices are *judgements about*
audio, not facts *derived from* it, so they get their own file that transcription
never touches.

The script CSV path and its column mapping live in `SetProjExtState` under
`ajsfx_vo`, **shared with ScriptMatch**. Map the columns once; both windows know
them.

### Tracker format

```csv
ajsfx VO Overview,1

Key,Source,Source start,Filename,Status,Name override,Notes,Primary
RIVA.wav|1230,D:\Session\RIVA.wav,1.230,vo_guard_halt_01,verified,,great read,yes
```

Only rows carrying actual user work are written — otherwise the file would grow
a line per script line per session and the signal would drown. Clearing a row's
marks removes it from the file.

`vo.ParseTracker` never raises. A tracker mangled by a spreadsheet round-trip
returns `nil, reason`, and Overview then **refuses to save** rather than
overwriting whatever the user still has in there, and says so in the window.

---

## 3. Row identity

A verified flag has to survive a re-transcription that nudges a boundary by a few
tens of milliseconds. Identity is therefore tolerant, in four passes, each run
over every row before the next begins:

1. exact key, same full path — the row has not moved
2. exact key, same basename — the project moved to another drive
3. within ±0.5 s, same filename, same full path — a boundary shifted
4. within ±0.5 s, same filename, same basename — both at once

Keys are `<basename>|<source start in ms>` for audio rows and `|<filename>` for
script lines with no audio. Basename rather than full path so a project that
moves drives keeps its tracker; the full-path pass runs first so two recordings
that happen to share a filename never share a checkmark.

Within a pass, proximity matches are taken **globally nearest-first**, and each
tracker entry can be claimed by at most one row. Resolving per-row instead would
let one row claim, through the loose basename bucket, an entry that a later row
matches on its full path.

### Known limits

- A take moved more than 0.5 s by re-transcription loses its mark. This is
  deliberate: past that distance it is more likely a different piece of audio,
  and silently migrating a "verified" onto the wrong take is worse than dropping
  it.
- Two different lines recorded within 0.5 s of each other cannot swap marks —
  the rematch requires the same filename — but a *deleted* take can cause the
  remaining takes of that line to shift by one.
- Take numbering across several source files orders by source path, then by
  time within the file. With one recording per session and dated filenames this
  is recording order; it is not guaranteed to be for arbitrary filenames.

---

## 4. Behaviour

### Rows

One unified list. Every script line appears; a line with several takes appears
once per take, as sibling rows.

| Status | Means |
|---|---|
| **Recorded** | a matched span exists |
| **Review** | the span matched below the accept threshold |
| **Missing** | the script has this line, no audio matches it |
| **Orphan** | audio matching no script line, or a line the filters exclude |

Orphans are listed last and never silently dropped: unrecognised audio is
exactly what the user opened this window to find.

### Resolving a row to an item

A row carries a **source-time** coordinate. Resolution finds the project item
whose take plays that stretch of that file, and converts to project time.

This works identically **before and after a cut**, and that is not luck:
splitting an item leaves each piece pointing at the same source file with an
adjusted `D_STARTOFFS`, so a source-time coordinate still lands in exactly one
piece's coverage range. Nothing in the resolution path knows or cares whether a
cut has happened.

A row whose audio is not in the project resolves to nothing, is dimmed, and is
not navigable — a sidecar can outlive the item that produced it.

### Selection

Selection is a set, with spreadsheet rules: click replaces it, Ctrl/Cmd-click
toggles one row, Shift-click takes the range from the anchor. Ranges walk the
*visible* rows, so a Shift-click selects what the user can see between the two
rows they clicked, not what a filter is hiding between them.

Selection is keyed by a per-row **uid**, not by the row key of §3. Keys are
deliberately not unique — every script line with no audio yet keys as
`|<asset>`, so a character's un-recorded lines can collapse onto one key, and
selecting one of them would select all of them. The uid is the key plus an
ordinal among the rows sharing it, assigned on rebuild.

The project selection follows: selected rows select their media items in the
arrange view. The edit cursor follows the **focus** row only — seeking once per
gesture rather than once per row keeps a fifty-row Shift-click from thrashing
the transport.

Changing a filter drops now-hidden rows from the selection. That is deliberate,
not a side effect: it is what stops the layout tool below from moving items the
user cannot see.

### Laying out the timeline

**Sort on timeline** re-lays the affected audio along the timeline in either
script order or record order. It moves whole media items and **never cuts** —
cutting is ScriptMatch's job, and the non-goal in §1 holds here.

The unit of movement is the **cluster**, and two relations weld one. They chain
through each other, so a crossfade partner that carries no group of its own still
travels with the group it is fused to.

1. **Overlap, same track only.** A crossfade is nothing but an overlap: move one
   side and the fade is gone. Cross-track overlaps do *not* weld — ScriptMatch
   pulls selects onto per-character tracks, where two characters overlapping in
   time is normal and means nothing about editing; welding those would chain a
   multi-character session into one immovable blob. Items must overlap by more
   than `vo.OVERLAP_EPSILON` (1 ms), so a butt-join trimmed to abut is left alone.
2. **Item group, across tracks.** A nonzero `I_GROUPID` is the user saying "these
   belong together" out loud, and stranding half a group is the same damage as
   breaking a crossfade. Group id `0` means ungrouped and never welds.

Clustering runs over *every* item in the project, including the MIDI and
time-stretched items `inspect_item` skips: a crossfade partner has to travel with
its neighbour whether or not this tool understands its contents.

| | |
|---|---|
| **Scope** | items behind the selected rows; if nothing is selected, items behind every visible row |
| **Start** | the earliest current position among the affected items |
| **Tracks** | a new child track per source track, nested under it — see below |
| **Script order** | by the script CSV's row order |
| **Record order** | grouped by source recording, oldest file first, then by position within that recording |
| **Fixed gap** | the same space after every item (default 2 s) |
| **Original spacing** | replays a recording's own gaps; record order only |
| **Between recordings** | inserted between two different source files (default 60 s) |

An item holding several lines is positioned by its **first recognized line**, and
the next item is placed clear of its whole length. Orphans — audio matching no
script line — are appended after the run in script order rather than left behind
for a sorted item to land on top of. A cluster containing a locked item is
skipped and reported: moving half a cluster would destroy the crossfade the
cluster exists to protect.

#### Where it lands

A run never shuffles audio where it sits. Every source track gets a **new child
track nested under it**, named `<source track> sorted <N>`, and the sorted items
move there. Two consequences, both deliberate:

- **A sort cannot land on audio it was not asked to touch.** The layout only
  knows about the clusters in scope; laying them out in place would let a
  six-row selection drop items on top of unselected takes. A fresh track has
  nothing to collide with, so the question does not arise.
- **Per-character separation survives.** One child per source, not one for the
  lot — collapsing ALEX and JORDAN onto a single track would throw away exactly
  what ScriptMatch's select-pulling exists to create. A group welded across two
  tracks likewise stays spread across two destinations: each member keeps its own
  source-to-destination mapping, and only the *delta* is shared.

Every child of one run shares the run number `N`, so a run reads as one set and
the run before it is still sitting there untouched. Nesting is `I_FOLDERDEPTH`
arithmetic, which is a delta rather than a level: `vo.FolderDepthForChild` sets
the parent to `1` and the child to `parent - 1`, one rule that covers a plain
track, a folder's last child, and a track that is already a folder. Getting it
wrong re-indents every track *below* the parent, which is why it is pure and
tested rather than inline at the call site.

The layout arithmetic is pure (`vo.ClusterItems`, `vo.PlanTimelineLayout`,
`vo.FolderDepthForChild`) and unit-tested with no REAPER. Applying the moves
writes `D_POSITION` directly, which does not trigger REAPER's auto-crossfade,
inside one `core.Transaction` — so the track creation, the track moves and the
positions are a single undo step. Toolbar settings persist globally in
`ExtState` and are deliberately *not* part of `vo.CONFIG_SCHEMA`, which drives
the Settings dialog.

#### Known limits

- **File age comes from the filesystem.** Record order reads each source's
  modification date through `js_ReaScriptAPI` when it is installed, and through a
  single batched `stat` on macOS and Linux. On Windows without js_ReaScriptAPI no
  date can be read without flashing a console window per file, so ordering falls
  back to filename and the window says so — guessing at "oldest" would reorder a
  session wrongly and silently. A *partial* read is reported too: three of four
  files dated still leaves the fourth sorting last with nothing to say for
  itself, which is why `vo.SourceModifiedTimes` returns a count rather than a
  boolean.
- **An item holding several lines is placed by its first line only.** The rest of
  its lines go wherever that puts them.
- **A re-rendered file looks new.** Gluing or superglueing a run of edits
  produces a file whose date is now and whose internal timecode restarts at zero,
  so it sorts as the newest recording. This is not worked around.
- **Original spacing can still collide.** An item retimed since it was recorded
  can be longer than the gap it originally sat in; it slides forward to abut its
  neighbour rather than stacking on it, and the count is reported.

### Interactions

- **Click a row** — moves the edit cursor there, seeks playback, selects the item.
- **OK checkbox** — marks verified. `Space` toggles the selected row, but only
  when no text field has focus, or typing a space in Notes would fire it.
- **Sel radio** — chooses which take of a line is the select, overriding the
  configured first/last rule. Choosing one clears the rest of its group, so the
  tracker can never hold two selects for one filename.
- **Item name** — editable, and the only thing Overview writes to the project.
  It shows the take's *live* name, so a rename made anywhere else in REAPER
  appears here too. Committed on Enter or on losing focus, never per keystroke,
  so each commit is one undo point. The name is sanitized, applied to the take
  inside a `core.Transaction`, and recorded in the tracker so it survives the
  item being deleted. Take name is what REAPER's render patterns read; that is
  the whole point of editing it here.
- **CSV filename** — read-only, beside it. The script's own name for the line,
  kept on screen so a rename never leaves the user unable to find the original.
  Nothing here renames a file on disk.
- **Notes** — editable free text, saved to the tracker.

Filters: status, character, and a text search across filename, line, transcript
and notes. Sorting is an explicit droplist rather than clickable headers —
ImGui's sort-spec API is unused elsewhere in this repo and the version risk was
not worth it for v1. Script order is the default and the stable tiebreak for
every other sort.

### Refresh

A per-frame probe of `GetProjectStateChangeCount` + item count decides *whether*
to rebuild; a 1.5 s throttle bounds how often that leads to actual sidecar file
I/O, since a drag gesture moves the counter every frame. **Refresh** forces a
re-read — that is the button to press after transcribing in ScriptMatch.

Tracker writes are throttled to 2 s while typing and flushed on window close.

---

## 5. Architecture

Pure layer in `lib/ajsfx_vo.lua`, unit-tested with no REAPER:

- `vo.TrackerPath`, `vo.OverviewKey`
- `vo.SerializeTracker`, `vo.ParseTracker`
- `vo.BuildOverview`, `vo.TrackerEntriesFromRows`, `vo.SummarizeOverview`
- `vo.ClusterItems`, `vo.PlanTimelineLayout`, `vo.FolderDepthForChild`

Coupled layer:

- `vo.CollectItemGeometry` — position, length, track, lock state and group id of
  every item, with no take access. Deliberately not built on `inspect_item`: see
  "Laying out the timeline" above.
- `vo.EnsureSortChildTracks` — the destination child track per source track,
  built on the same `vo.EnsureTrackBelow` ScriptMatch uses for character tracks,
  plus the folder-depth rule.
- `vo.SourceModifiedTimes`
- `vo.CollectProjectSpans` — project-wide sibling of `vo.CollectSourceSpans`.
  Both call one shared `inspect_item`, so the MIDI / no-source / playrate skip
  rules cannot drift apart between the two windows.
- `vo.ProjectSourcePaths`, `vo.ResolveSourceTime`

`ajsfx_VO_Overview.lua` is ReaImGui only: no matching, no file format knowledge,
no REAPER mutation beyond `P_NAME` and the transport.

Optional ReaImGui entry points are fetched with `rawget`, never guarded with
`im.Maybe and ...`: the binding's shim installs an `__index` that *raises* on an
unknown field instead of returning `nil`, so the guard is itself the crash. The
per-row `PushID` is likewise unwound by hand around the table body's `pcall` —
`EndTable` raises on an unbalanced ID stack, which would replace the real error
with a misleading one.

`ListClipper` is deliberately not used in the table — ReaImGui rejects it as
excessive creation of short-lived resources, which is why ScriptMatch dropped it
from its preview table too. ImGui's own table clipping keeps off-screen rows out
of the draw list.

Packaging: Overview ships inside the **existing** ScriptMatch package as a third
`[main]` entry. It must not declare its own `@provides` for `lib/ajsfx_vo.lua` —
only one package may provide a given file, and the loser is dropped from
`index.xml` silently.

## Presentation settings

How the table LOOKS belongs to the user, not to the session, so none of it
touches the project or the tracker. Column widths and column order are persisted
by ImGui itself, into `REAPER/ReaImGui/<hash>.ini`. Everything else lives in
`ExtState` under section `ajsfx_vo` with a `view_` prefix:

- `view_restore` — whether any of it is remembered at all. Turning it off clears
  the stored per-column keys rather than merely ignoring them, so "off" means
  one thing rather than hiding a layer that reappears when it is turned back on.
- `view_font_small` / `view_font_medium` / `view_font_large` — the point sizes
  behind the three presets. Medium is 13, the size the table has always drawn at.
- `view_col_<key>_align` / `_wrap` / `_font` — per column.

Per-column keys use the column's `key` field, never its index, so dragging
columns into a new order cannot scramble which setting belongs to which column,
and inserting a column in a later version does not shift every stored preference
by one.

The defaults, the validation and the alignment arithmetic live in
`VO/lib/ajsfx_vo_view.lua` rather than in the script, because the script calls
`im.CreateContext` at load time and so cannot be required by a test. That module
is pure but for `ExtState`, and is covered by `tests/test_vo_view.lua`.

Row heights are measured from the PREVIOUS frame's column widths: ImGui has no
`TableGetColumnWidth`, and a cell's usable width is only knowable from inside
that cell, which is a frame too late to size the row it belongs to. Dragging a
column edge therefore leaves heights one frame stale; they settle on the next
frame. Heights are cached against a generation counter bumped by a rebuild, a
width change or a settings edit, so a table nobody is touching costs one
comparison per row per frame — this table emits every row every frame, with no
ListClipper.

The full design is in
`docs/superpowers/specs/2026-08-01-vo-overview-view-settings-design.md`.
