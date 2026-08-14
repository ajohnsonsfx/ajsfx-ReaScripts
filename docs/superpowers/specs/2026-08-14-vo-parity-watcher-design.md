# ajsfx VO — The Parity Watcher

**Status:** Design approved, not implemented · **Date:** 2026-08-14

Builds on `VO/SPEC-authority-buttons.md` (Update from Item / from Marker) and
subsumes it: the two macros, the single-step repair verbs, and the three
follower checkboxes become frontends and automatic behaviours of one engine.

---

## 1. The problem

The tool has an invariant nobody owns:

> **marker name = item name = sheet assignment**, and
> **marker bounds ≈ item edges** (for a single-take item).

Eight toolbar verbs and three follower checkboxes each repair one direction of
one edge of that triangle. Every new way to edit a session needed its own
repair button, which is why the Fix row grew redundant — and why sessions
drift: the user has to know which button reverses which drift, and press it.

The user's own framing, which this design adopts: **every fix answers one
question — who has the authority?** Either the transcript does (my edits are
suspect, re-derive identity from the words), or my edit does (I just made one
element correct; everything else catches up). The tool's job is to make the
second case need **no button at all**.

## 2. The shape

Three parts, in dependency order:

1. **A parity engine** (lib) — one owner for the invariant. Detects
   disagreement, and restores parity from a named authority.
2. **A watcher** (always-on, in the Overview defer loop) — extends the
   existing follower snapshot to cover every element of the invariant. When it
   can attribute a divergence to exactly one element the user edited, it syncs
   from that element automatically. When it cannot, it refuses and queues.
3. **A queue panel** — the only new UI. One row per take the watcher refused
   to guess about, with "Fix from …" actions per row and for the batch.

The Fix row shrinks to the verbs that are *not* parity repairs.

## 3. The parity engine

Lives in `VO/lib/ajsfx_vo.lua` as planners (pure, unit-testable) plus a thin
apply layer in the Overview script. Respecting the 200-local cap: new
functions hang off a table (`vo.Parity = {}`), not new top-level locals.

### 3.1 The model

Per tracked take, four elements can carry the identity or the geometry:

| element | carries | source of truth today |
|---|---|---|
| marker | line (asset name) + bounds | item chunk (`state.take_markers`) |
| item | name + edges | media item |
| sheet | line assignment + Keep/Sel | derived from marker id + stored marks |
| transcript | the words actually spoken there | source word list inside the marker's range |

The transcript is special: it is never *written* by a sync (words follow the
marker's range by themselves, `vo.TranscriptForRange`) but it is the one
authority that can correct *identity* — the others can only propagate it.

### 3.2 `Parity.Diff(scope) -> divergences`

For each take in scope, compare the elements and return a list of
divergences, each tagged with:

- `what` — which fields disagree (`name`, `edges`, `marks`), and how.
- `moved` — which single element changed since the last baseline, or `nil`
  when unknown (fresh session, split, paste, two elements moved in one settle
  window, or a duplicate cluster).

`Diff` **never** writes. Attribution comes from the watcher's snapshot
(§4); `Diff` called without one (e.g. from the queue panel on a fresh
session) reports every `moved` as `nil` — disagreement is still visible,
authority is just not assumed.

### 3.3 `Parity.Sync(take, authority)`

Runs the deterministic waterfall from the named authority. The steps are the
*existing* planners — nothing about what a sync does is new, only who calls
it:

| authority | waterfall |
|---|---|
| `item` | resolve duplicates (words) → snap marker to edges → fill fades. Today's Update from Item. |
| `marker` | resolve duplicates → trim item to bounds → name item from marker (`PlanAdopt`) → fill fades. Today's Update from Marker / Trim to markers. |
| `sheet` | rename item + marker from the sheet's assignment and marks. Today's Fix names from the sheet. |
| `transcript` | ask the words which line is really read there; rewrite marker + item name when they disagree (marker keeps its id, so Keep/Sel survive). Today's Fix wrong names from transcript. |

Refusals are law, unchanged: an item holding several markers is a recording
and no sync touches its geometry; a duplicate cluster the words cannot decide
is skipped and queued, never guessed. One `core.Transaction` per invocation,
whatever the caller.

## 4. The watcher

### 4.1 What exists

`Trim.changes_since_last_look()` already snapshots item edges and tracks per
tick of `GetProjectStateChangeCount`, waits ~15 settled frames, and feeds the
three followers. The re-baseline after every `pending_action` (tool's own
work never counts as a user edit) already exists and is the pattern that
stops the watcher chasing its tail.

### 4.2 What extends

The snapshot grows two fields per take: **marker (name, bounds)** and **item
name**. Both read from state the Reload already collects (`state.take_markers`,
item cache) — the watcher adds **no chunk reads of its own**; take-marker
chunk reads are already the per-rescan tax and this must not raise it.

On settle, per changed take:

- exactly one element moved → `Parity.Sync(take, that element)`,
  automatically, its own undo step, reported in the message line and log.
- more than one moved, or the change cannot be attributed (split — both
  halves wear the whole marker set; paste; item appeared this frame; fresh
  session) → no action; the take enters the queue.

**The tool never guesses. It acts on knowledge or it asks.**

### 4.3 The one switch

The three follower checkboxes (`marks_follow_tracks`,
`tracking_follows_edit`, `alt_names_follow_tracks`) retire, replaced by one:

> **[x] Keep the session in sync** — default ON.

It covers everything the three did: a drag between tracks still adopts the
marks (the sheet is the element that "moved" is *toward*: track placement is
a sheet-authority edit), a trim still snaps the marker and fixes the name,
and alt naming runs as the tail of any sync that changed marks — after the
marks settle, never before, exactly as today.

Default ON where alt-names was OFF before: the queue is what makes that safe.
The old risk was a rename nobody asked for with nothing on screen to say why;
now every automatic action is logged, and anything uncertain queues instead
of acting.

## 5. The queue

A `PanelButton` on the Fix row wearing its count — `Out of sync (3)` — in the
style of "Marks vs tracks", which it replaces (marks-vs-tracks disagreement is
just one kind of divergence).

Each row shows the take, what disagrees (marker says `IWinBig_02`, item says
`IWinLittle_01`, words score 0.91 for `IWinBig`), and the actions:

> **Fix from Transcript** · **Fix from Marker** · **Fix from Item** · **Fix from Sheet**

plus the same four as batch buttons over the selection/all. Naming rule
throughout: **"Fix from X"** — verb first, authority named. A row fixed
leaves the queue on the next diff; (0) means the session agrees with itself.

## 6. The Fix row after

```
Fix:  [ Fix from Transcript ]  [ Out of sync (0) ]
      [ Cut from markers ]  [ Re-cut selected takes ]
      ── [ Auto-adjust head and tail ]  [ Apply the cut fades ]
      ── [ Restore missing lines ]
      [x] Keep the session in sync
```

**Stays, and why:**

- **Fix from Transcript** — the macro slot. The one authority that is not
  "my edits"; absorbs "Fix wrong names from transcript" and is the button for
  "I don't trust what's on the timeline".
- **Cut from markers / Re-cut selected takes** — cutting turns recordings
  into takes; that is creation, not parity repair.
- **Auto-adjust head and tail** — measures audio and decides an edge itself;
  precisely why no authority waterfall may run it.
- **Apply the cut fades** — the manual re-enrol verb.
- **Restore missing lines** — whole-project by design; a selection cannot
  scope it.

**Retires (button gone, code becomes engine steps):** Update from Item, Trim
items to their markers, Snap markers to items, Fix names from the sheet, Fix
wrong names from transcript (absorbed), Remove Extra Take Markers (runs
inside every sync; undecidable clusters land in the queue), the three
follower checkboxes.

The hero, Match, Pick and Pull rows are untouched.

## 7. Testing

The new decisions are **diff, attribution, and routing** — all pure, all in
the lib, all unit-tested against the mock:

1. `Parity.Diff`: agreement → empty; each single-field divergence named;
   several markers → recording, geometry excluded from the diff.
2. Attribution: one element moved → that element; two moved in one window →
   `nil`; item with no snapshot (new/pasted/split) → `nil`; tool's own write
   after re-baseline → no divergence at all.
3. Routing: each authority reaches exactly its waterfall; `transcript`
   refuses when no words cover the range; duplicate cluster undecided →
   queued, not synced.
4. The four waterfalls themselves are existing tested planners and are not
   re-tested.

Writes are checked by hand in `VO/MANUAL_TEST.md`: the checks that cannot be
skipped are *one undo step per automatic sync*, *the split case queues both
halves rather than renaming either*, and *Ctrl+Z after an automatic sync does
not immediately re-trigger it* (undo bumps the change count; the re-baseline
must swallow it).

## 8. Not changing

- The waterfall steps: `Trim.extras`, `Trim.apply`, `Trim.snap_apply`,
  `PlanAdopt`, `PlanItemIdentity`, the fade rule.
- Refusal behaviour: several markers = recording; undecided duplicates are
  never resolved by guess.
- Scope rule for manual verbs: the selection, or everything.
- `luac -p` before trusting green tests (the 200-local cap).

## 9. Success criteria

- A single hand edit — trim, marker drag, rename, tick, track drag — restores
  parity with **zero presses**, one undo step, one log line.
- Nothing automatic ever acts on a divergence it cannot attribute; every such
  case is visible in one place with its evidence and a "Fix from …" choice.
- The Fix row's control count drops from 14 to 8, and every surviving
  name states its authority without the tooltip.
- `(0)` on the queue is a true statement that the session agrees with itself.
