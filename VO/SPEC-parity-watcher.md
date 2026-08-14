# ajsfx VO — The Parity Watcher

**Status:** Implemented, unverified in REAPER · **Date:** 2026-08-14

Pure layer is unit-tested (`vo.ParityDiff`, `vo.ParityAttribute`,
`vo.ParityAssemble` — `tests/test_vo_parity.lua`); every REAPER write is
checked by hand — see `VO/MANUAL_TEST.md`, "Parity watcher".

Supersedes `VO/SPEC-authority-buttons.md` (Update from Item / from Marker):
the two macros became two of the watcher's four waterfalls.

Design rationale: `docs/superpowers/specs/2026-08-14-vo-parity-watcher-design.md`.

---

## 1. The idea

The tool has an invariant: **marker name = item name = sheet assignment**,
and **marker bounds ≈ item edges** for a single-take item. Every repair verb
was one direction of one edge of that triangle, run by hand.

The watcher owns the invariant instead. Every fix answers one question —
*who has the authority?* — and there are only two kinds of answer:

- **My edit does.** The user changed exactly one element; the others catch
  up from it, automatically, the moment the drag settles.
- **The transcript does.** The external evidence; never inferred from an
  edit, always a button ("Fix from Transcript").

**The tool never guesses. It acts on knowledge or it asks.** Anything it
cannot pin on one element queues in "Out of sync" with the evidence and the
four authorities as per-row buttons.

## 2. The parts

| part | where | job |
|---|---|---|
| `vo.ParityDiff(takes, opts)` | lib, pure | what disagrees (name, edges); refuses recordings |
| `vo.ParityAttribute(changed)` | lib, pure | which ONE element moved, or nil |
| `vo.ParityAssemble(collected, rows)` | lib, pure | shape CollectTakeMarkers + sheet rows into Diff input |
| `Trim.changes_since_last_look` | Overview | snapshot track / edge (length+offs, not position) / item name / marker signature; returns attributed + queued sets |
| `Trim.marker_sigs` | Overview | marker state per item from the LAST Reload's collection — no chunk reads of its own |
| `Trim.sync_dispatch(attributed)` | Overview | authority → waterfall router; also what every queue button calls |
| `Trim.retarget_from_names(items)` | Overview | typed name → marker follows (`vo.RetargetMarkerOnItem`, same id) |
| Out of sync panel | Overview | parity queue + marks-vs-tracks, each row with Fix from … |

## 3. The waterfalls

| authority | trigger | runs |
|---|---|---|
| `item` | edge (length/offs) moved | `Trim.update("item")` then transcript re-check of the names |
| `marker` | marker moved/renamed | `Trim.update("marker")` — trim, name from marker, fades |
| `name` | item renamed | marker retargets to the line the name resolves to; unresolvable → queue |
| `sheet` | item changed track | `Trim.adopt_track_marks` then `ApplyAltNames` |
| transcript | button only | `Trim.fix_names_from_transcript` |

Refusals unchanged: several markers = a recording, geometry never touched;
duplicate clusters the words cannot decide are never resolved by guess.

## 4. What runs when

- The snapshot runs on every project-change tick, ~15 settled frames gate
  the dispatch (same settle rule the followers used).
- One element attributed → sync, own undo step, own log line.
- Two elements, a split, a paste, a fresh session → queue, no action.
- Two DIFFERENT attributions for one item inside one settle batch → queue.
- Undo guard: if the top of the REDO stack is a `VO Overview` transaction,
  the change was an undo of our own work — re-baseline, act on nothing.
- "Keep the session in sync" OFF: the snapshot still runs (the queue must
  not go blind), but attributed edits queue instead of dispatching.
- After any `pending_action`, re-baseline: the tool's own work never reads
  as a user edit.

## 5. No backwards compatibility

One session in the world uses this tool. The first diff over the existing
project surfaces every past divergence — that is the point: fix the project
through the queue, once. No migration of the three old follower ExtState
keys, no leniency in the comparators.

## 6. Testing

Pure (mock suite, `tests/test_vo_parity.lua`): agreement is silent; each
single-field divergence named; conventional alt names are agreement;
recordings and unmarked items excluded; attribution 1-of-4 / nil; assembly
excludes note markers, invents no sheet element.

By hand (`VO/MANUAL_TEST.md`): trim→snap, marker-drag→trim+name,
rename→retarget, retrack→marks+altnames, split→queue both halves,
Fix-from-… per row, one-undo-per-sync, undo does not re-trigger.
