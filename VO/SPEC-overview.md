# ajsfx VO Overview — Design Spec

**Status:** Implemented · **Version:** 0.1 · **Date:** 2026-07-25

A project-wide picture of the dialogue in a session: every line the script says
should be there, every line that actually is, and the user's own marks over the
top. One sheet, all recordings, whether or not anything has been cut yet.

---

## 1. Why this is a separate script

The tool used to be one script that transcribed, matched and cut in a single
run. That run-and-forget shape and a project-wide picture of the dialogue pull
against each other at every turn:

| | Sources / Cut | Overview |
|---|---|---|
| Scope | one batch of files, or the takes marked Select | every item in the project |
| Lifetime | one run | the whole job, across sessions |
| Owns | derived data (transcripts, the live match) | the user's judgements |
| Verb | *do something to this audio* | *tell me where I am* |

Splitting the three verbs apart — transcribe, judge, cut — lets each stay
simple. Overview is the front door: it opens Sources and Cut for you
(`VO/SPEC.md` §5), but does neither job itself.

### Non-goals

Overview does **not** transcribe, cut, split, move items between tracks, or pull
selects. Those belong to Sources and Cut and must not migrate here — that is
exactly the drift this split exists to prevent. The only thing Overview writes
to the project is a take name, and only when the user types one; everything
else it writes goes to the project file (§2).

---

## 2. The two data layers

| Layer | File | Owner | Regenerable |
|---|---|---|---|
| **Words** | `<audio>_vo_transcript.csv`, one per source wav | Sources | yes — costs a whisper run |
| **The user's work** | `<project>_vo.csv`, one per project | Overview | **no** |

The match between them — which words correspond to which script line — is
computed live by `vo.BuildMatch` every time Overview needs it (`VO/SPEC.md` §6)
and is never written to either file. That is the separation the whole design
rests on: re-transcribing a recording rewrites its sidecar wholesale, and
swapping the loaded script CSV re-derives every status instantly; neither can
cost the user a single checkmark. Verified flags, notes, name overrides and
select choices are *judgements about* audio, not facts *derived from* it, so
they get their own file that neither transcription nor matching ever touches.

The script CSV path and its column mapping live **in the project file itself**
(§2.1), not in `ProjExtState`. Overview is the only window that reads or writes
either.

### 2.1 Project file format

```csv
ajsfx VO Project,1
Script CSV,D:\Session\script.csv
Mapping,speaker=Character;asset=Filename;text=Line Text

Key,Filename,Source,Source start,Select,Status,Name override,Notes
RIVA.wav|1230,vo_guard_halt_01,D:\Session\RIVA.wav,1.230,yes,verified,,great read
```

`Select` is the take Cut acts on; `Status` keeps the pre-existing `verified` /
`flagged` vocabulary and is a separate column because a take can carry both at
once. Only rows carrying actual user work are written — otherwise the file
would grow a line per script line per session and the signal would drown.
Clearing a row's marks removes it from the file. See `VO/SPEC.md` §4.2 for the
full format, which this window owns.

`View` rows in the preamble hold how the sheet was last left: the character
filter, the search box, whether the per-field filter boxes are showing, each
field's filter needle, and which lines are UNFOLDED (`View,expanded,<line
key>`, one row each). Only what is actually set is written, so a sheet with no
filters and nothing unfolded adds nothing to the file. They live here rather than in
the global ExtState that holds the appearance settings because a character
filter names *this project's* characters. A restored filter naming a status or
column this version no longer has is dropped on load, and a restored character
that matches no row — the script changed, or its Character column is no longer
mapped — is dropped the first time there are rows to check it against, so the
sheet can never open empty with no visible reason. There is no **sort** to
store: since 0.15 the sheet is always in script order (§4).

`vo.ParseProjectFile` never raises. A file mangled by a spreadsheet round-trip
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
moves drives keeps its project file; the full-path pass runs first so two
recordings that happen to share a filename never share a checkmark.

Within a pass, proximity matches are taken **globally nearest-first**, and each
project-file entry can be claimed by at most one row. Resolving per-row instead would
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

**Not a table (0.15).** The sheet is a list of **cards**, one per script line,
drawn by hand — no ImGui table anywhere. A table forces every row through one
column grid, and this data has two kinds of row: a line and a take. Sharing
one grid is what made column labels strand in a header far from the inputs
they named, spent a whole row on each character, and left the boundary between
an unfolded parent and its neighbour ambiguous. A card's own chrome answers
"where does this line end", and take rows sit on their own colour inside it,
so the two levels can never be mistaken for one another.

Each card is a **title band**, always visible, of a header row and two
parallel columns:

| | |
|---|---|
| **who + said** | fold arrow · script position · status dot · speaker · **the line text**, quoted, right beside the speaker — the words are the main piece of information on the card, so they read in the same glance as who says them (`4 · Grumbar "Can"`) · badges right-aligned: `✓N` delivered, `!` when the line has takes but no Sel |
| **left column** | `Filename:` the delivered name (CSV filename + Append), red on a clash · `Script:` the source script |
| **right column** | the line note, editable in place, double height to sit parallel with Filename + Script, unlabelled — promoted from the old fold-only drawer, because a note you can only see by unfolding is a note you forget you wrote |

Clicking **anywhere on the band** folds or unfolds; the arrow is an indicator,
not the only target. Unfolding adds, in order: a header row naming the take
fields, the **take rows** (lettered `A, B, C … Z, AA, AB`, `vo.TakeLetter`),
and a **`+ Add Take`** button. With items selected in REAPER it names them for
this line — the only honest "add" under the name-is-the-assignment model
(§4a.1), and the answer to "I found a take that belongs here". With nothing
selected it adds a **planned take**: an empty row (`vo.PlannedKey`, stored in
the project file — the one row kind derived from nothing else) to hang notes
and marks on, whose Item zone carries a `+` that later links the REAPER
selection to it. Linking names the item and retires the planned row in the
same stroke. A planned take counts in the band's take count but never makes an
unrecorded line read as recorded, and one whose asset no longer names any
script line surfaces in the orphans card rather than vanishing.

A take row answers, at shared x-offsets so it stays correlated with its
neighbours: letter · status dot · `Sel` `Keep` `Lock` checkboxes · transcript ·
the item's own editable name · item (recording @ time) · take note. The offsets
are the alignment mechanism a table's columns used to provide; below ~720px the
Item zone drops to a tooltip and below ~540px the Note zone follows, because
at those widths they were unreadable slivers and the text is why the window is
open.

### Take identity: ranged take markers

A recorded take's identity is a **ranged take marker** — one `TKM` line in the
owning item's state chunk, `TKM <srcpos> <name> <color> <length>`. The fourth
field is undocumented but real: REAPER renders it as a range, dragging the
marker moves the start with the length intact, alt-dragging moves the end, and
API edits leave it alone (verified in v7.78, 2026-08-09; the substrate facts
live in SoundDesignDocs `Workflow/reaper-session-automation.md` §4). The name
is `<asset> ~<id>` — the visible half says which script line, the 2–3-char id
is what the project file keys marks on (`tkm|<id>`), so no drag, trim or split
can detach them. Markers without the ` ~id` suffix belong to the user and are
never touched.

**Markers are the truth.** The sheet re-reads them every rebuild
(`vo.CollectTakeMarkers` → `vo.CountingMarkers` → marker-built rows in
`vo.BuildOverview`); a line with counting markers ignores the match entirely —
the match is a one-time generator, not a live authority. The **coverage rule**
absorbs split residue: a marker counts only where its range intersects the
source window of the item holding it, and when two items genuinely cover one
marker the better-covering item wins.

Cut writes markers first, splits at their bounds, and split propagation gives
each cut piece its identity from birth. **Cut never touches audio covered by a
counting marker** — the skip is reported, and *Re-cut anyway* deletes those
takes' markers first, the same gesture the user could do by hand. The take-row
menu carries the verbs native gestures don't cover: *Add take marker from
selected item*, *Snap marker to item* (the trimmed-head fix), *Delete take
marker*. **Mark takes** migrates a pre-marker session by banking each take's
current item edges as marker truth; **Clean stray take markers** prunes
off-window split copies.

**The track is the decision.** Sel and Keep are tri-state in the project file —
`yes`, `no`, or blank meaning no opinion. A blank defers to where the item
sits: on `Selects` it reads as Sel, on `Alts` as Keep (`vo.EffectiveMarks`).
Track placement survives re-matching and re-transcription, so scrambled marks
heal themselves. Un-ticking a mark whose item sits on the matching track writes
an explicit `no`, without which the track would re-tick it on the next frame —
and the Sel exclusivity clears siblings the same way, or a sibling on the
Selects track would re-tick itself and leave two Sels on one line.

Rows carry two pairs of mark fields, deliberately: `mark_select`/`mark_keep`
are the stored tri-state and are what gets persisted, while
`user_select`/`user_keep` are the effective booleans the checkbox and Pull
read. Keeping them apart is what stops a tick *inferred* from a track being
written back as an explicit decision nobody made.

The **Repair** panel reconciles the two: disagreements between sheet and
timeline (with *Adopt timeline* / *Adopt sheet*), markers whose audio is gone,
and marks with no audio left to attach to.

**Folded is the default**, and the project file stores which lines are OPEN
(`View,expanded,<line key>` rows) rather than which are shut — a fresh project
opens as a tidy list of title bands. `Unfold all` / `Fold all` do every line at
once. The character is a chip on each band rather than a section header, so it
costs no vertical space. There is **no display sorting**: the sheet is always
in script order, and arranging the timeline is the Sort panel's job.

Internally the flat row model survives unchanged: `vo.GroupOverview` folds the
rows into typed nodes (character / line-with-takes / orphans) and
`vo.FilterGroups` decides visibility per LINE — a match on any take keeps the
whole line, takes travelling with it. The character nodes draw nothing; the
grouping function still emits them, and the renderer reads the character off
each line's own rep.

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

Folding is different from filtering, on purpose. A folded line's takes leave
the selection and the shift-range walk (`state.visible` — what the eye sees)
but stay in **tool scope** (`state.filtered` — every take the filters admit):
folding is how the sheet is tidied, and tidying must not silently shrink what
Cut and Name acts on.

### Laying out the timeline

**Sort on timeline** re-lays the affected audio along the timeline in either
script order or record order. It moves whole media items and **never cuts** —
cutting is the Cut and Name panel's job.

**Script order is resolved by NAME**, not by the match: each item's take name is
looked up in the script (`vo.BuildNameIndex` / `vo.ResolveItemName`, §7.1), and an
item whose name is not on the script is left exactly where it is and counted in
the panel's summary. Two things follow from the one rule. A folder of rendered
files with no transcripts at all sorts into script order. And an uncut recording
cannot be swept up by accident: it carries the recording's name, which is not a
script filename. **Record order is unchanged** — it asks where an item sat inside
a recording, which a name cannot answer, so it still reads the row.

The unit of movement is the **cluster**, and two relations weld one. They chain
through each other, so a crossfade partner that carries no group of its own still
travels with the group it is fused to.

1. **Overlap, same track only.** A crossfade is nothing but an overlap: move one
   side and the fade is gone. Cross-track overlaps do *not* weld — a
   multi-character session commonly ends up with each character on its own
   track, where two characters overlapping in time is normal and means nothing
   about editing; welding those would chain a multi-character session into one
   immovable blob. Items must overlap by more than `vo.OVERLAP_EPSILON` (1 ms),
   so a butt-join trimmed to abut is left alone.
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
  the separation a multi-character session's per-character tracks depend on. A
  group welded across two tracks likewise stays spread across two destinations:
  each member keeps its own source-to-destination mapping, and only the *delta*
  is shared.

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

- **Click a take row** — moves the edit cursor there, seeks playback, selects
  the item. Parents don't navigate: their arrow folds, their State cell
  selects their takes.
- **Lock checkbox** — marks verified; rematching leaves the take where it is.
- **Sel checkbox** — the user's explicit choice of which take of a line
  Cut should act on; there is no first/last default any more, only what the
  user ticks (`VO/SPEC.md` §7). Ticking one clears the rest of its group, so
  the project file can never hold two selects for one filename.
- **Name (take)** — editable, and the only thing Overview writes to the
  project. It shows the take's *live* name, so a rename made anywhere else in
  REAPER appears here too. Committed on Enter or on losing focus, never per
  keystroke, so each commit is one undo point. The name is sanitized, applied
  to the take inside a `core.Transaction`, and recorded in the project file so
  it survives the item being deleted. Take name is what REAPER's render
  patterns read; that is the whole point of editing it here.
- **Name (line)** — read-only in place: the delivered name, i.e. the script's
  own filename plus any Append, kept directly above the take names so drift
  is a visible vertical diff. The **Append** is edited on demand — double-click
  or right-click the cell — because it is rare; red marks a delivered-name
  clash until an Append separates the two lines.
- **Notes** — editable free text at both levels, saved to the project file.
  Line notes back onto `linenote|`-keyed entries no row claims, carried over
  explicitly by every save.

Filters: character, per-field boxes (their own line under the toolbar, behind
the **Filters** toggle), and a text search across filename, line, transcript
and notes — all selecting LINES, with takes travelling whole. There
is no display sorting of any kind (0.15): script order is the one order.

### Refresh

A per-frame probe of `GetProjectStateChangeCount` + item count decides *whether*
to rebuild; a 1.5 s throttle bounds how often that leads to actual transcript
file I/O, since a drag gesture moves the counter every frame. **Refresh** forces
a re-read — that is the button to press after transcribing in Sources.

Project file writes are throttled to 2 s while typing and flushed on window
close.

---

## 4a. Cut and Name, Pull, Sort

One toolbar row — `Script | Sources… | Cut and Name | Pull | Sort | Settings` —
where Sources and Settings open their own windows and the rest toggle an inline
panel, one at a time.

| | reads | writes | needs the transcript |
|---|---|---|---|
| **Cut and Name** | the match | splits the recording, names each piece | **yes** |
| **Pull** | item names, and the Select mark | renames to the delivered name, moves to child tracks | no |
| **Sort** | item names | item positions on the timeline | no |

Cut is the only tool that consults the match, and correctly so: cutting a span
out of a continuous recording is a question only the transcript can answer.

### 4a.0 Coverage: the question the job is judged on

`vo.CheckCoverage(items, lines)` answers "have I got everything?" from the
project's **item names** and the script, and from nothing else. No transcript,
no match, no stored mapping. It is recomputed on every rebuild, so there is no
copy that can drift out of step with the project: the item's name IS the
assignment, and this only reports what the names say.

It reports, per script line, how many items carry its name and which tracks
they sit on; plus the names in the project that match no line (deduplicated),
and the items whose name two lines both claim.

The sheet shows it as the `✓N` badge on each card's band and as the headline
count in the summary line. It is true however the audio got there — cut here, comped by hand, or
delivered as a rendered file by somebody else — which is exactly why it is
worth having separately from the match.

**Assigning is naming.** "This item is that line" is expressed by giving the
item the line's delivered name (right-click a row → *Assign selected item to
this line*), which is what every name-driven tool already reads. Nothing is
stored, so nothing can fall out of sync. Several items at once become the line
and its alts, numbered with the alt pattern from §5.2.

### 4a.1 Name resolution

`vo.NormalizeItemName` lowercases, trims, and drops a trailing **alphabetic**
extension of up to four characters — `line_042_v1.2` keeps its numeric tail,
because that is part of what the file is called.

`vo.BuildNameIndex` holds **two keys per line**: the script's own Filename and
the DELIVERED name (Filename + Append, or the user's override). The delivered
name is one this tool wrote, so recognising it is reading our own output back —
that is what lets a second Pull see what the first one renamed. A key two lines
claim resolves to **nothing** rather than to the first of them; that clash is
what the Append column exists to fix, and guessing would put one line's audio
under the other's name. `vo.ResolveItemName` returns the line index, or nil plus
`"unknown"` / `"ambiguous"`.

### 4a.2 Cut and Name

Splits each take out of its source item and names it the **plain CSV filename** —
no Append, no override, no uniquing. Two takes of one line SHOULD collide here;
which is the delivery is not a question cutting can answer. It moves nothing and
creates no track.

Every take of a **decided** line is cut, not only the SEL: the alts are
deliveries too, and the takes ticked neither still have to exist before they
can be listened to and ticked.

Two gates, both about acting on something undecided or no longer true: a source
whose audio has changed since it was transcribed, and a line with several takes
and no SEL.

### 4a.3 Sel and Keep

Two independent checkboxes.

**Sel** is the take being delivered — one per line, so ticking one unticks the
line's others. That exclusivity is keyed by **script row**, never by filename:
two CSV rows may ask for the same filename (that is what the Append column
separates), and keying on the name made ticking one line's Sel clear a different
line's.

**Keep** is a read worth keeping — any number per line, and independent of Sel.
Independence is the point: the single cycling mark this replaces forced you
through SEL on the way to ALT, which took the select off whichever take already
had it.

A kept take that is not the Sel is delivered as an **alt**. A take with neither
tick stays on Review.

In the project file they are two columns, `Select` and `Keep`, each `yes` or
empty. 0.13 briefly wrote `alt` in the `Select` field before Keep had a column;
that reads back as a Keep, so the work survives.

### 4a.4 Pull

Items are grouped by the line they resolve to and routed by one question — does
anything say which of these is the delivery?

| item | goes to |
|---|---|
| **Sel** ticked | **Selects**, renamed to the delivered name |
| **Keep** ticked, not Sel | **Alts**, renamed to its own name (§5.2) |
| neither | **Review**, unrenamed |
| the only item for its line, unticked | **Selects** — one take is not a decision |

Selects and Alts are **delivered**; Review is not. On a fresh session nothing is
ticked, so the first Pull puts the whole read on Review; that is the pile the
user works through. What is still there at the end is what was never wanted.

Destination tracks are **children of the recording the item came from**
(`vo.EnsureChildTrack`), so collapsing the recording folds everything cut from it
away too. Because Pull runs repeatedly, "the recording" means the first parent
that is not itself one of Pull's tracks (`vo.IsDestTrackName`) — without that, a
second Pull would nest a track inside the Review track it made on the first. An
item already on its destination is left alone rather than moved to where it
already is.

**Name alts** gives every alt that has none a delivered name of its own, from a
pattern the user defines (`{n}` marks the number, plus a start value and zero
padding), built on the line's delivered name — so an alt of a line that already
carries an Append becomes `line_042_ch2_alt1`.

The name is held against the **take**, as a `name_override`, NOT as an Append.
An Append belongs to the script line: `vo.AppendKey` has no take component and
`line.deliver` feeds every take of the line, so appending `_alt1` for an alt
would rename its select too and the two would still collide. Two takes of one
line can only be told apart by a name held against the take.

Numbering is per line. A name already chosen is never overwritten — but it still
consumes its number, or naming the second alt by hand would silently renumber
the third.

---

## 5. Architecture

Pure layer in `lib/ajsfx_vo.lua`, unit-tested with no REAPER:

- `vo.ProjectFilePath`, `vo.OverviewKey`
- `vo.SerializeProjectFile`, `vo.ParseProjectFile`, `vo.ProjectEntriesFromRows`
- `vo.BuildMatch` (`VO/SPEC.md` §6 — Overview's own call into the shared matching
  pipeline), `vo.BuildOverview`, `vo.SummarizeOverview`
- `vo.ClusterItems`, `vo.PlanTimelineLayout`, `vo.FolderDepthForChild`

Coupled layer:

- `vo.CollectItemGeometry` — position, length, track, lock state and group id of
  every item, with no take access. Deliberately not built on `inspect_item`: see
  "Laying out the timeline" above.
- `vo.EnsureSortChildTracks` — the destination child track per source track,
  built on the same `vo.EnsureTrackBelow` Cut uses for its Selects/Alts/Review
  destinations, plus the folder-depth rule.
- `vo.SourceModifiedTimes`
- `vo.CollectProjectSpans` — project-wide sibling of `vo.CollectSourceSpans`.
  Both call one shared `inspect_item`, so the MIDI / no-source / playrate skip
  rules cannot drift apart between the two windows.
- `vo.ProjectSourcePaths`, `vo.ResolveSourceTime`, `vo.LaunchSibling`

`ajsfx_VO_Overview.lua` is ReaImGui only: no matching, no file format knowledge,
no REAPER mutation beyond `P_NAME` and the transport.

Optional ReaImGui entry points are fetched with `rawget`, never guarded with
`im.Maybe and ...`: the binding's shim installs an `__index` that *raises* on an
unknown field instead of returning `nil`, so the guard is itself the crash. The
per-card `PushID` is likewise unwound by hand around the card body's `pcall`,
along with the font and text-wrap stacks — an error escaping mid-draw would
otherwise leave ImGui's stacks corrupted for every later frame.

`ListClipper` is deliberately not used — ReaImGui rejects it as excessive
creation of short-lived resources, the same reason the old single-script
tool's preview table dropped it too.

A card's footprint is submitted as a real `Dummy` item, never left as a bare
`SetCursorScreenPos`: ImGui grows a scrolling child only from submitted items,
and `EndChild` raises outright if the last thing before it was a cursor move.

Packaging: `ajsfx_VO_Overview.lua` is the ReaPack **package main file**; Sources,
Cut and Settings ship as further `[main]` entries in its own `@provides`
(`VO/SPEC.md` §5). It must not declare its own separate `@provides` for
`lib/ajsfx_vo.lua` — only one package may provide a given file, and the loser is
dropped from `index.xml` silently.

## Presentation settings

How the sheet LOOKS belongs to the user, not to the session, so none of it
touches the project or the project file. It lives in `ExtState` under section
`ajsfx_vo` with a `view_` prefix:

- `view_restore` — whether any of it is remembered at all. Turning it off clears
  the stored per-column keys rather than merely ignoring them, so "off" means
  one thing rather than hiding a layer that reappears when it is turned back on.
- `view_font_small` / `view_font_medium` / `view_font_large` — the point sizes
  behind the three presets. Medium is 13, the size the sheet has always drawn at.
- `view_col_<key>_align` / `_wrap` / `_font` — per field. Cards read only the
  **font**; alignment and wrap were table-cell concerns and no longer have an
  effect, and the header menu that was the only way to set a single field's
  values went with the table. The store and `vo_view`'s validation of all three
  are kept as they are: the module is coherent on its own and covered by
  `tests/test_vo_view.lua`, and re-cutting it would buy nothing this release.

Widths are not stored at all any more. The table persisted its column widths
and order into `REAPER/ReaImGui/<hash>.ini`; cards compute their zones from the
window width every frame, which is also what lets the Where and Note zones drop
out on a narrow window (§4).

The pre-0.15 `view_mirror_text` setting is gone with the columns it paired:
line text and transcript are no longer side by side, so there is nothing left
to mirror.

The defaults and the validation live in `VO/lib/ajsfx_vo_view.lua` rather than
in the script, because the script calls `im.CreateContext` at load time and so
cannot be required by a test. That module is pure but for `ExtState`.

Card heights are MEASURED, never predicted. Each card draws inside a
`BeginGroup`/`EndGroup` and reads its own height back with `GetItemRectSize`;
the NEXT frame paints the background rectangle at that height. The obvious
alternative — predicting with `CalcTextSize(text, wrap_width)` — is wrong and
was the first implementation of the table this replaced: the reported width
does not match what ImGui goes on to wrap to, so every height computed from it
falls short. Reading back what was drawn cannot fail that way. The cost is one
frame of lag on a card that just changed size, which is not perceptible at
frame rate.

Take-row inputs are plain single-line `InputText`s. `InputTextMultiline` would
make Enter put a newline in a filename instead of committing the rename.

The view-settings design predates the cards and describes the table's version
of this: `docs/superpowers/specs/2026-08-01-vo-overview-view-settings-design.md`.
The card design is
`docs/superpowers/specs/2026-08-08-vo-overview-nested-rows-design.md`.
