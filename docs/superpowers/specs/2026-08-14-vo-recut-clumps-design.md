# ajsfx VO — Re-cut selected takes

**Status:** Designed, not implemented · **Date:** 2026-08-14

One verb for the case where a single spoken line has been split into several
abutting items carrying contradictory take markers. It returns the clump to
*being a recording*, then hands it back to the existing match-and-cut path so
the good cut can run again. It invents no matcher and no cutter.

Companion to `VO/SPEC-duplicate-markers.md`, which resolves two lines claiming
one range. This spec resolves the opposite failure: one line scattered across
several items.

---

## 1. The shape of the problem

Observed live on the Grumbar session, 2026-08-14. Two selected items on track
3, both from `Grumbar full read-CMKB_Cleaned.wav`:

```
ITEM A  pos 1254.510  len 0.595  srcoff 1254.510  srcend 1255.105  name "DBP_Grumbar_Grumbar_IBreakOar"
  TKM 1254.51  "DBP_Grumbar_Grumbar_MyLeash ~adp"   len 0.595
ITEM B  pos 1255.105  len 1.125  srcoff 1255.105  srcend 1256.230  name "DBP_Grumbar_Grumbar_IBreakOar"
  TKM 1254.51  "! 2026-08-13 13:23  PARTIAL: ..."   len 0      <- stale note, points outside B
  TKM 1255.105 "DBP_Grumbar_Grumbar_IBreakOar ~adw" len 1.125
  TKM 1255.49  "DBP_Grumbar_Grumbar_IBreakOar ~87u" len 1.79   <- ends 1257.28, past B's end
```

Four facts fall out of that dump:

1. **The items abut exactly, in project time *and* source time.**
   `A.pos + A.len == B.pos` and `A.srcoff + A.len × A.rate == B.srcoff`.
   Nothing was removed between them. This is a pure split, not an edit.
2. **Both items are named `IBreakOar`,** while A's marker claims `MyLeash`.
   Name and marker disagree — the audible drift.
3. **The `~87u` marker overhangs B's end by 1.05s,** reaching into source that
   no item covers.
4. **A stale `!` note marker** from the previous day is still complaining about
   the very condition this verb exists to fix.

The user hears *"my leash"* and nothing else across the whole 1.72s.

### 1.1 Why the transcript cannot place the boundary

The transcript over the region reads:

```
1252.330..1253.790  honor,
1253.790..1254.200  my
1254.200..1255.740  leash,
1255.740..1255.920  I
1255.920..1257.030  break
1257.030..1258.280  ore,
1258.280..1258.360  I
1258.360..1259.240  sink
```

By those stamps the selection straddles the end of *leash* and the start of
*I break*. By ear it is *my leash* entire — the stamps run roughly half a
second early. This is the known displacement recorded in
`vo-word-stamps-are-displaced-not-imprecise`: a window can end before its word
begins, and no anchor or overlap rule fixes it.

**So the transcript decides WHAT is in the clump; only the envelope can decide
WHERE the edges go.** This spec never uses word stamps to place a cut. It uses
them to identify lines, and delegates edge placement to the existing cut path
(`vo.ApplyPadding` / `vo.SnapBoundary`), which already asks the envelope.

### 1.2 Why the clump cannot be re-cut in place

Item 374 ends at 1251.70 and item 377 begins at 1258.28. The clump
(1254.51–1256.23) is an island with **2.05s of uncovered source to its right**,
and most of *"I break ore"* lives in that gap. A re-cut confined to the clump's
own coverage can only re-derive half a line, and would re-earn the PARTIAL note
on the next pass. The verb must be allowed to reclaim adjacent uncovered
source — see §2, step 2.

---

## 2. The verb

**Name:** *Re-cut selected takes*. It sits on the Overview button row beside
*Match takes to script* and *Cut recording into takes*, whose vocabulary it
shares. "Repair" is deliberately not used — that name belongs to the
transcript-gap Repair panel.

**Scope:** the REAPER item selection, and nothing else. No fallback to the
track or the project.

Everything below runs inside a single `core.Transaction("VO: Re-cut selected
takes", ...)`, so one Ctrl+Z undoes the whole thing.

### Step 1 — Cluster the selection into clumps

Group selected items by track and source path, sort by position, and join two
adjacent items into the same clump when **both** hold within a 1ms tolerance:

```
project:  a.pos    + a.len              == b.pos
source:   a.srcoff + a.len × a.rate     == b.srcoff
```

Clustering is transitive along the sorted run. A single selected item forms a
clump of one, which is legal and still re-cuttable — a lone item with a
misplaced marker is the degenerate case of the same problem.

Requiring source-time abutment as well as project-time is what keeps this safe.
Two items that merely touch on the timeline but come from different parts of the
recording are a deliberate assembly, not a clump, and are never joined.

### Step 2 — Compute the reclaim window

Start from the clump's own source-coverage window, `vo.SourceCoverageRanges`.
This is the same question `vo.ResolveSourceSpanForCut` asks when resolving a
span to its item, so scope and resolution cannot disagree — the rule from
`vo-rows-are-not-spans`.

Then, for every match span that **intersects the window but is not wholly
inside it**, extend the window to that span's bounds. "Match span" means a span
from the Overview's current match for this source — the same set the cut reads,
refreshed by step 5's `MatchTakes`, never a separately computed one. If no match
is loaded, that is the "no transcript" refusal in §3.

Finally clamp the window to the nearest **unselected** item's edge on each
side, converted to source time. Heal can grow into audio that no item covers;
it can never eat a neighbour.

For the observed clump: `1254.51–1256.23` → `1254.51–1258.28` (stopped by item
377), which is the full stretch holding *my leash* and *I break ore*.

### Step 3 — Heal

Run REAPER's native **Item: Heal splits in items** (command 40548) on the
clump. This rejoins abutting same-source items with no render — the requirement
the user set, and its precondition is exactly the step 1 test.

Then set the survivor's `D_POSITION`, `D_LENGTH` and `D_STARTOFFS` to the
reclaim window. Also no render: the take already points at the whole file, so
this only reveals source it was already addressing.

### Step 4 — Strip the clump's markers

Delete every counting marker on the healed item, plus any `!` note marker whose
complaint this re-cut is about to answer (identified with `vo.IsNoteMarker`).
Written through `vo.PlanMarkerRemove` / `vo.WriteTakeMarkers`.

This is the step that makes the item read as *a recording, not a take* again —
the distinction `SPEC-duplicate-markers.md` §1 identifies as the reason
multi-marker items get skipped by **Trim items to their markers** and **Snap
markers to items**.

### Step 5 — Re-match and re-cut

The item is now a recording, which is precisely what the existing path expects.
Run `MatchTakes({ mark = true })` scoped to it, then the cut.
`vo.ResolveSourceSpanForCut` already guarantees that only spans landing inside
this item apply, so no extra scoping machinery is needed.

The result is items with proper cuts and one ranged marker each, derived fresh
rather than inherited from the bad split.

### Step 6 — Flag the ambiguous

A re-cut can produce a take whose *role* is unclear even when its *line* is
certain: the line may already have another item claiming select, so the new one
is a select, an alt, or a replacement, and the verb cannot tell which.

Where that happens, stamp a `! REVIEW:` note marker with `vo.WriteNoteMarker`
naming the ambiguity and the competing item. **Nothing moves and no track
changes** — the note is the flag, Overview surfaces it, and the user clears it.

This is the whole of "review if drastically changed": the review condition is
role ambiguity, not audio drift.

---

## 3. Refusals

Each of these means *do nothing to the clump and report why*. A refusal is
per-clump: other clumps in the same selection still run.

| Condition | Reason |
|---|---|
| Items in the clump differ in playrate or pitch | Healing would lie about the audio. **Overridable** — see §3.1 |
| No transcript for the source | Identity has no authority; the verb would be guessing |
| No span in the reclaim window clears the match threshold | Leave it alone rather than invent a line |
| Any item in the clump is locked | The user has said not to touch it |

### 3.1 `recut_ignore_rate`

A new config field, declared alongside the existing bool options:

```lua
{ key = "recut_ignore_rate", kind = "bool", default = false },
```

Shown in VO Settings as **"Ignore item pitch/playrate when re-cutting."**

With it on, a mixed-rate clump heals anyway. The survivor takes the **longest
item's** playrate and pitch, and a `! REVIEW:` note records what was discarded:

```
! 2026-08-14 ...  RATE: dropped playrate 0.97 / pitch -1 from 1 item(s) when re-cutting.
```

So the override can change how audio sounds, but never silently.

Note that step 1's source-abutment test already uses each item's own rate, so
mixed-rate clumps cluster correctly whatever this setting says. The option
governs only whether heal may collapse them.

---

## 4. The `Match takes to script` hook

*Match takes to script* gains a pre-check and nothing more. Before matching, it
runs step 1 over the selection and, if any clump has more than one item,
appends to its report:

```
2 clump(s) of split items found — press "Re-cut selected takes".
```

**It reports; it does not act.** The catch-all must not silently re-cut audio,
and a clump that the user split deliberately is not a bug the sheet gets to
overrule.

---

## 5. Code placement

The Overview chunk sits at Lua's 200-local ceiling
(`vo-overview-local-limit`), so:

- **Planners go in `lib/ajsfx_vo.lua`**, pure and testable against
  `tests/mock_reaper.lua`:
  - `vo.ClusterClumps(items, tol)` → list of clumps, each an ordered item list.
  - `vo.PlanReCut(clump, spans, neighbours, opts)` → `{ window, heal, remove_markers, refuse, review }`.
    Decides everything; writes nothing.
- **Overview gains exactly one new top-level local**, `ReCutTakes(opts)`, which
  applies the plan. Every variant goes through `opts`, not through a second
  function — the same reason `MatchTakes` and `IdentifyItems` take opts.
- Run `luac -p` on the Overview before trusting a green test run. A local-limit
  break compiles nowhere but shows up as a passing suite, because the tests
  never load the Overview chunk.

---

## 6. Verification

**Unit** — planner tests in `tests/`:

- abutting in both times → one clump; abutting in project only → two clumps.
- a lone item → a clump of one.
- reclaim window stops at an unselected neighbour's edge.
- reclaim window extends for a span that overflows the coverage.
- mixed rates refuse by default, proceed with `recut_ignore_rate`, and record
  the dropped values.
- locked / no-transcript / below-threshold each refuse without side effects.

**Live** — on this exact Grumbar clump, through the headless bridge
(`vo-mcp-test-harness`). Expected after one press:

- one item spanning source `1254.51–1258.28` becomes two;
- named `DBP_Grumbar_Grumbar_MyLeash` and `DBP_Grumbar_Grumbar_IBreakOar`;
- one ranged counting marker on each, no overhang;
- the 2026-08-13 PARTIAL note gone;
- one Ctrl+Z restores the two-item, four-marker state exactly.

---

## 7. Out of scope

- Choosing between two lines that both claim one range — that is
  `SPEC-duplicate-markers.md`.
- Repairing transcript gaps — that is the existing Repair panel.
- Any automatic pass over the track or project. This verb runs on the
  selection, on a press, and reports what it did.
