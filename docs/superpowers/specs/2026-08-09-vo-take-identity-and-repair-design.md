# VO: take identity and repair — Design

**Status:** Approved, not yet implemented · **Date:** 2026-08-09

Hand-editing a cut in REAPER currently costs you your marks. This makes a take's
link to its item durable, teaches the sheet to read decisions back off the
timeline, and adds a reconciliation pass for damage already done.

---

## 1. The problem

Two failures, reported after a real session on 2026-08-08.

**Marks detach when audio moves.** A take row's identity is a *source-time
coordinate*: `vo.OverviewKey` returns `<basename>|<start-in-ms>`, and every mark
the user makes (Sel, Keep, Lock, note, name override) is stored in the project
file under that key. `resolve_tracker` reattaches marks across rebuilds with a
`vo.TRACKER_REMATCH_TOLERANCE` of 0.5s. Anything that moves a boundary further
than that — a re-match, a re-transcription, or the user dragging an item edge —
leaves the mark unable to find its take. It either vanishes or lands on a
neighbour.

**Rows resolve to items by guesswork.** `vo.ResolveSourceSpan` picks the item
that is most fully occupied by the take's source-time span. That rule was chosen
carefully and fixed real bugs, but it is still inference: after a hand-edit the
same take can resolve to a different item, to nothing, or two rows can land on
one item.

Underneath both: **the tool treats the transcript match as truth and items as
derived from it.** Hand-editing inverts that, and nothing in the model says so.

### Scope

This spec covers identity and repair only. Improving Cut's *boundary placement*
is a separate project, deliberately deferred: it needs experiments against real
audio with REAPER open, and it is safer to attempt once a bad result can no
longer scramble a session's marks.

## 2. Goals

1. A take hand-edited in REAPER keeps its marks, permanently.
2. Cut never silently destroys a hand-edit.
3. Decisions already expressed on the timeline (which track an item sits on) are
   read back into the sheet, so scrambled marks self-heal.
4. Damage already done is findable and fixable without hand-editing a CSV.

**Non-goals.** Boundary accuracy. Re-cutting a single line in isolation (the
user explicitly did not want this). Automatic detection of *which* hand-edit was
intended — the tool records that an edit happened, never guesses why.

---

## 3. Anchors

An **anchor** is a durable binding from a take row to one specific REAPER item,
keyed by the item's GUID rather than by a source-time coordinate.

GUIDs are the right currency: dragging an edge, moving an item between tracks,
saving and reloading the project all preserve an item's GUID. Only splitting an
item (the right-hand piece) or re-recording produces a new one — which are
exactly the cases where the binding *should* break.

An anchored row:

- resolves directly to its item, with `vo.ResolveSourceSpan` used only as the
  fallback for unanchored rows — so it cannot lose to a leftover or a neighbour;
- keeps its marks under a key no edge-drag can move;
- is *spoken for*, so Cut knows to leave it alone (§5).

An anchor records three things: the item GUID, and the source-time edges Cut
gave that item (`anchor_start`, `anchor_stop`). The edges are what make "has
this been hand-edited?" answerable — see §5. They are the edges the **plan**
wrote, not the row's `source_start`/`source_stop`: boundary snapping moves the
edges away from the raw match, so comparing against the match would report every
untouched item as edited.

### 3.1 Where anchors come from

**Automatically, at Cut.** `vo.ApplyPlan` already holds `piece`, the exact item
it just created for each span ([`ajsfx_vo.lua:6059`](../../../VO/lib/ajsfx_vo.lua)) —
it names it and discards the reference. It will instead return a map of
`row key -> { guid, start, stop }`, and the caller writes those onto the
entries. Every cut take is anchored from birth, with nothing inferred.

**The row key must be stamped onto each span before padding runs.**
`vo.ApplyPadding` mutates `span.start` and `span.stop` in place — that is what
boundary snapping *is* — so by the time `ApplyPlan` sees a span, its `start` is
no longer the value `vo.OverviewKey` was built from. The Cut path therefore
records `span.row_key = vo.OverviewKey(span.source_path, span.start)` in
`CutCandidates`, before `ApplyPadding` is called, and `ApplyPlan` keys its
returned map by that field. Deriving the key inside `ApplyPlan` instead would
bind every anchor to a row that does not exist, silently.

**Explicitly, from the take row.** A right-click menu item, *Anchor to selected
item*, binds the row to whatever is selected in REAPER. This is the escape hatch
for hand-comped, rendered, or re-recorded audio, and the manual fix offered by
the repair pass.

Anchors are never created by inference from geometry. If the tool did not make
the item and the user did not point at it, it stays unanchored.

### 3.2 What anchors do not change

`vo.TRACKER_REMATCH_TOLERANCE` stays exactly as it is. Unanchored rows — a line
matched but never cut — still need proximity reattachment, and 0.5s remains the
right window for them. Anchors do not widen it; they make it irrelevant for the
rows that have one.

---

## 4. Track-derived marks

Alongside the governing idea that *the name is the assignment*: **the track is
the decision.** An item on the `Selects` track is the select; one on `Alts` is a
keep. Pull already writes this direction (marks → tracks, via
`cfg.track_selects` / `track_alts` / `track_review`); this reads it back.

Track placement is the most damage-resistant signal in the system. Marks live in
a fragile key and item names can be edited, but "this item sits on Selects"
survives every re-match, re-transcription and edge-drag.

### 4.1 Precedence

For each take, Sel and Keep resolve as:

1. **An explicit decision stored in the project file** — including an explicit
   *no*. Always wins.
2. **Otherwise, the item's track:** `track_selects` → Sel ticked;
   `track_alts` → Keep ticked.
3. **Otherwise** — no item, or a track matching neither name — unticked.

The `track_review` track sets nothing. It means "undecided, look at this", which
is the absence of a decision, not a mark.

This yields self-healing: when a re-match scrambles the marks, the items are
still on Selects, so rows re-tick themselves on the next rebuild with no user
action.

### 4.2 The explicit "no"

Today, un-ticking Sel writes `nil` and `vo.SerializeProjectFile` drops entries
carrying no work. Under rule 2 that blank would let the track re-tick the row,
and the un-tick would spring back a frame later.

So `Select` and `Keep` become tri-state in the file: `yes`, `no`, or empty
meaning *no opinion*. Un-ticking a take whose item sits on the matching track
writes `no`; un-ticking one whose item does not writes empty, as now, so files
do not grow rows that say nothing. An entry holding only a `no` counts as work
and is written.

**Backward compatibility.** A file written before this change has empty Select
fields meaning "not selected", which now read as "no opinion". On first open,
rows whose items already sit on Selects will therefore tick themselves. This is
a real behaviour change, and it is the desired one: those items *are* the
selects — Pull is what put them there. It is called out in the changelog.

---

## 5. Cut and hand-edited takes

**Edited** needs no separate detection: a take is edited when it is anchored and
its item's current source coverage differs from the anchor's recorded
`anchor_start` / `anchor_stop` by more than 10ms at either edge. The comparison
uses `vo.SourceCoverageRanges`, the same arithmetic the rest of the tool uses to
put an item in source time.

Cut skips edited takes and says so:

> Cut 37 clips. 3 takes skipped — you had edited them. **[Re-cut anyway]**

*Re-cut anyway* clears the anchors for exactly those takes and re-runs. Nothing
else about Cut changes; unedited and unanchored spans cut as they do today.

This protection applies where it can: Cut acts on the recording track, so a take
already pulled to Selects is out of its reach regardless. The case that matters —
cut, hand-fix an edge, re-run Cut — is precisely the one covered.

---

## 6. The repair pass

A panel, in the same style as Cut / Pull / Sort, framed as a **reconciliation**
between two sources of truth: the sheet's marks and the timeline's placement.
It reports only non-empty categories, acts only on a press, and each finding
scrolls the sheet to the take in question.

| Finding | Fix offered |
|---|---|
| Sheet and timeline disagree — ticked Sel but the item is not on Selects, or the reverse | **Adopt timeline** (write the marks the tracks imply) or **Adopt sheet** (re-run Pull) |
| An anchor's item no longer exists | **Clear anchor**, or **Relink** to the REAPER selection |
| Two rows anchored to the same item | Show both; **Keep this one** clears the other |
| Marks with no item and no anchor — damage already done | **Clear**, or **Relink** |
| An item named for a line that no row claims | **Adopt as take** (the existing planned-take/adoption path) |

The first category is the one that answers the reported session: it makes the
disagreement visible instead of leaving the user to discover it take by take.

---

## 7. Data format

`vo.PROJECT_VERSION` stays at 1. Three columns are appended to
`vo.PROJECT_HEADER`, which is backward compatible because `vo.ParseProjectFile`
reads entry fields by index and a shorter row simply yields `nil`:

```
Key, Filename, Source, Source start, Select, Status, Name override, Notes, Keep,
Anchor, Anchor start, Anchor stop
```

- **Anchor** — the item GUID as REAPER reports it, or empty.
- **Anchor start**, **Anchor stop** — source-time seconds, `%.3f`, matching the
  precision of every other time in these files.

`Select` and `Keep` gain the value `no` as described in §4.2. A reader that
predates this change sees `no` as a non-`yes` value and treats it as unticked,
which is the correct fallback.

---

## 8. Architecture

The existing pure/coupled discipline holds: everything decidable without REAPER
is decided in the pure layer and unit-tested against the mock.

**Pure layer** (`VO/lib/ajsfx_vo.lua`):

- `vo.MarkFromTrack(track_name, cfg)` → `"select"`, `"keep"`, or `nil`.
- `vo.EffectiveMarks(entry, track_name, cfg)` → `{ select, keep }`, implementing
  the §4.1 precedence. One function, so the rule cannot drift between the sheet,
  Pull and the repair pass.
- `vo.IsEditedAnchor(anchor, coverage, tolerance)` → boolean, the §5 comparison.
- `vo.PlanReconcile(rows, opts)` → the §6 findings, categorised, each naming its
  row and its available fixes. Pure: it takes rows already carrying their
  resolved item GUID and track name.
- `vo.SerializeProjectFile` / `vo.ParseProjectFile` — the §7 columns and the
  tri-state marks.

**Coupled layer:**

- `vo.ApplyPlan` returns its `row key -> { guid, start, stop }` map, keyed by the
  `span.row_key` stamped before padding (§3.1).
- `Rebuild` reads each resolved item's GUID and track name onto the row, which
  is what lets `PlanReconcile` and `EffectiveMarks` stay pure.
- Anchored resolution: check the anchor's GUID against the project's items
  before falling back to `vo.ResolveSourceSpan`.
- The repair panel and its fix actions, in `ajsfx_VO_Overview.lua`.

---

## 9. Testing

Pure-layer tests in `tests/`, following the existing files' shape, in a new
`tests/test_vo_identity.lua`:

- `MarkFromTrack`: each configured track name; a track matching none; a nil
  track; custom names from config rather than the defaults.
- `EffectiveMarks`: explicit yes beats the track; explicit **no** beats the
  track (the §4.2 regression); blank defers to the track; no item and no entry
  is unticked; `track_review` sets nothing.
- `IsEditedAnchor`: unmoved item is not edited; head moved past tolerance is;
  tail moved past tolerance is; a sub-tolerance nudge is not.
- Round-trip: an anchor survives serialize → parse; a `no` survives; a file
  written without the new columns parses with `nil` anchor and no error; an
  entry holding only a `no` is not dropped as workless.
- Anchor keying: a span carrying a `row_key` stamped before padding still maps
  to that key after its `start` and `stop` have been moved, which is the §3.1
  hazard stated as a test.
- `PlanReconcile`: each of the five categories produced from hand-built rows,
  and an all-clean input producing nothing.

Manual REAPER coverage is added to `VO/MANUAL_TEST.md` for the paths the mock
cannot reach: anchoring at Cut, GUID survival across an edge-drag and a Pull,
the skip-and-re-cut-anyway flow, and each repair fix.

---

## 10. Delivery

One `@version` bump on `VO/ajsfx_VO_Overview.lua` with a changelog that calls
out the §4.2 first-open behaviour change explicitly, and one on
`VO/lib/ajsfx_vo.lua`. Pre-release (`0.15beta3`) so it reaches opt-in testers
before the stable 0.15, per `.agents/standards.md`.
