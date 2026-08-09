# VO: ranged take markers — Design

**Status:** Approved, not yet implemented · **Date:** 2026-08-09

Recorded-take tracking moves onto ranged take markers: one marker per
performance, visible in the arrange view, editable with native REAPER
gestures, and authoritative. This supersedes the GUID-anchor half of
`2026-08-09-vo-take-identity-and-repair-design.md` (unpushed, so nothing
published carries the superseded design); the tri-state marks, track-derived
Sel/Keep, repair panel and planned takes from that spec all stay.

---

## 1. The fundamentals this is built on

Agreed workflow, stated by the user and adopted as the design's frame:

1. The system gets things roughly in place (**kickstart**).
2. The user finalizes in the REAPER timeline.
3. The tool follows the user's work (**tracking**), staying current.
4. The user keeps an eye on the tool as an overview while they work.

The user should never expect the tool to perfectly edit a session. They should
expect it to kickstart one and then accurately track what they do.

The structural consequence: today the transcript match is a *live authority* —
re-derived forever, each re-derivation free to disagree with what the user did
yesterday. Under this design the match becomes a **one-time generator**: it
runs at kickstart, materializes into take markers, and never gets to change
its mind again. Kickstart verbs (Cut, generate) refuse to run where tracking
data already exists; tracking reads only the markers.

## 2. The substrate — verified facts

Spiked in live REAPER v7.78 on 2026-08-09 (recorded in SoundDesignDocs
`Workflow/reaper-session-automation.md` §4):

- The item state chunk stores each take marker as
  **`TKM <srcpos> <name> <color> <length>`**. The undocumented fourth field is
  a **length in seconds**; `0` is a plain point marker. REAPER renders the
  range as a line from the marker to `srcpos + length`.
- The API cannot set or read the length (`SetTakeMarker`/`GetTakeMarker` know
  nothing of it), but API edits **do not destroy it** — a rename left a
  chunk-authored length intact. All range I/O goes through
  `Get/SetItemStateChunk`.
- **Native mouse gestures already edit both edges**: dragging the marker moves
  the start with the length intact; alt-drag moves the end. User-verified, and
  the chunk reflects both edits exactly.
- **Splitting an item copies the full `TKM` line into both halves**, including
  a half whose window does not contain it. Off-window markers persist in the
  chunk and simply don't draw.
- Positions are **source time**; the bridge to item coordinates is
  `D_STARTOFFS` (long-standing rule, same doc).

## 3. The model

One ranged take marker per **recorded take** (a performance of a line — not
REAPER's take object):

- **name** — the script filename (asset) plus a short id: `DBP_..._Book ~k7`.
  Never a `_altN` suffix and never review prefixes: the *item name* owns what
  the take becomes, the *track* owns what was decided, the *marker* owns what
  performance this is.
- **srcpos / length** — the take's span in source time.
- **color** — reserved; written as `0` for now (free for status tinting later).
- **the id** (`~` + 2–3 base36 chars, generated once at creation, unique
  within the project) — what the project-file entry keys on, so Sel/Keep/notes
  stay attached across any drag, trim or split. This is the only place
  item-independent identity lives; the GUID-anchor columns are retired.

**Markers are the truth.** The sheet re-reads them every rebuild; dragging a
marker IS editing the take. Deleting one deletes the take from the sheet (its
orphaned marks surface in the repair panel, which already has that category).

## 4. Kickstart

Generation writes markers, then Cut splits at marker bounds:

1. The match runs and proposes spans, exactly as today.
2. One `TKM` line per span is written into the take of the recording-track
   item covering it (chunk edit; positions converted through `D_STARTOFFS`).
3. Cut splits at marker bounds. Split propagation means each cut piece is born
   carrying its own marker; the copies left in remainders are off-window
   residue, ignored under §5 and prunable.

**Migration for an existing session** (the open Grumbar project): the same
generator sourced from the session as it stands rather than from the match —
an already-cut take gets its marker from its item's *current* source coverage,
which captures the user's hand-fixed cut points as truth, visibly. Uncut
audio gets markers from the match. One action, results reviewable at a glance
in the arrange view — this replaces the bulk-anchor idea, whose failure mode
was freezing wrong guesses invisibly.

**Cut's protection rule** replaces `IsEditedAnchor` and its tolerance
machinery: **Cut never touches audio covered by a counting marker.** The
skip report and a *Re-cut anyway* stay, but the override's action is "delete
these takes' markers, then cut" — explicit, visible, and the same gesture the
user could do by hand.

## 5. The coverage rule (reading markers back)

A marker **counts** only where its range intersects the source window of the
item holding it. That one rule absorbs split residue: after Cut, the piece
that covers the span carries the counting marker; remainders hold off-window
copies that are ignored. A housekeeping action ("Clean stray take markers")
deletes off-window copies.

Row→item resolution becomes: the item whose window covers the counting
marker — and when two items genuinely cover it (overlaps, comps), the one
covering more of the range. `vo.ResolveSourceSpan`'s occupancy logic survives
only as this tiebreaker; it no longer decides identity.

Rebuild reads `TKM` lines by walking item chunks. 456 items × a few KB of
chunk text at the existing once-per-second rebuild throttle is acceptable;
if it proves slow, chunks are cached against the project state counter.

## 6. Tracking verbs the tool adds

Native gestures already cover moving, resizing, and deleting. The tool adds:

- **Snap marker to item** — the user's rule: adjust the *earliest marker whose
  range intersects the item* to the item's current source coverage. The tool
  for "I trimmed the head past the marker start."
- **Add take here** — writes a marker (asset + fresh id) onto the selected
  item, spanning its coverage; the take-row and planned-take "link" actions
  route through this. This replaces `AnchorRowToSelection`.
- **Clean stray take markers** — the §5 pruning pass.
- **Generate / regenerate markers** — the §4 kickstart and migration action,
  refusing to overwrite counting markers unless told.

## 7. Project file

- The `Anchor` / `Anchor start` / `Anchor stop` columns (unpushed) are
  removed.
- A marker-keyed entry's `Key` is `tkm|<id>`; `Filename` (asset) is stored as
  today. Entries with legacy source-time keys still parse and still resolve
  through the existing tracker as a fallback, so a project file from before
  markers opens with nothing lost; on the first save after migration each
  mark rides its marker id.
- Tri-state Select/Keep and everything else from the identity spec: unchanged.

## 8. What is kept, what is retired

| Kept | Retired |
|---|---|
| Tri-state marks, explicit-no semantics | GUID anchors, anchor columns |
| Track-derived Sel/Keep (`vo.EffectiveMarks`) | `vo.IsEditedAnchor` + tolerance |
| Repair panel (categories rewired to markers) | `AnchorRowToSelection` (becomes Add-take-here) |
| Planned takes | Anchor-based Cut skip (becomes marker-overlap skip) |
| Whisper gap repair, card sheet, follow-scroll | — |

The retirement happens **before `main` is pushed** — `0.15beta3` ships the
marker model, and no published version ever carries the anchor columns.

## 9. Pure/coupled split and testing

Pure (unit-tested against the mock, `tests/test_vo_markers.lua`):

- `vo.ParseTKMLines(chunk)` / `vo.PatchTKMLines(chunk, markers)` — the chunk
  is a string; parsing and rewriting it is pure string work.
- `vo.CountingMarkers(markers, coverage)` — the §5 rule.
- Marker id handling: generation is coupled (needs entropy), but recognition
  and formatting of `~id` suffixes is pure.
- Marker→row assembly and the resolution tiebreaker.
- Round-trips: a `TKM` line with length survives parse→patch; a point marker
  stays a point; ids survive renames of the visible name half.

Coupled: chunk I/O per item, the §6 verbs, generation, migration. All
REAPER-side behavior lands in `VO/MANUAL_TEST.md`, including re-verifying
split propagation through the real Cut path.

## 10. Open questions deliberately deferred

- Color-coding markers by state (reserved field, no behavior yet).
- Whether the kickstart/tracking split becomes two layouts or windows — the
  verbs are separated by rule now; UI separation can follow usage.
- Boundary accuracy: unchanged, still its own future project — but note the
  migration already banks the user's hand-fixed boundaries as marker truth.
