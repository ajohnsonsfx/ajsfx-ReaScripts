# ajsfx VO — Update from Item / Update from Marker

**Status:** Superseded by `VO/SPEC-parity-watcher.md` (0.15beta21) — the two
macros became two of the parity watcher's four waterfalls, and their buttons
retired. · **Date:** 2026-08-11

Routing is unit-tested (`vo.PlanUpdatePass`, 7 tests in `tests/test_vo_tidy.lua`);
every REAPER write is checked by hand — see `VO/MANUAL_TEST.md`, last section.

Supersedes §6.2 of `VO/SPEC-duplicate-markers.md` (Tidy Up Take).

Two buttons, one question: **which thing is right?** Everything else is made
to agree with it.

---

## 1. The idea

Almost every fix in this tool is the same shape. One element has been made
correct by hand, and the rest of the session is now stale against it. The verb
is not "tidy" — tidy says nothing about direction. The verb is *this is the
authority, catch up*.

| I just… | The authority is | Press |
|---|---|---|
| trimmed the clip | the item's edges | **Update from Item** |
| dragged the marker to the right place | the marker's bounds | **Update from Marker** |
| edited the script | the sheet | the existing Match / Identify / Cut buttons |

The third case already has its buttons, and is not touched here.

`Tidy Up Take` is renamed to **Update from Item** — it is already that verb,
under a name that hid the direction. **Update from Marker** is new, and is the
same macro with the snap reversed and one step added.

## 2. What each press does

Both run in **one `core.Transaction`**, scope = the REAPER selection, or
everything when nothing is selected (`Trim.scope`), like every other verb here.

### 2.1 Update from Item

1. **Identify anything unmarked in scope** — new. See §3.
2. **Remove Extra Take Markers** — duplicates by the words, then leftovers
   (`Trim.extras`, unchanged).
3. **Snap** the surviving marker to the item's edges (`Trim.snap_apply`).
4. **Fill** the fades — per side, zero only, never overwritten.

### 2.2 Update from Marker

1. **Remove Extra Take Markers** — `Trim.extras`, unchanged. **First**, and
   not optional: with two contested markers on the item there is no single
   range to trim onto, and trimming onto the wrong one moves audio that a
   second press cannot walk back.
2. **Trim** the item's edges to the marker's bounds (`Trim.apply`). The audio
   does not move — `vo.PlanTrimToRange` shifts the start offset by exactly
   what the position changed.
3. **Name** the item from the marker's line, via `vo.PlanAdopt`. See §4.
4. **Fill** the fades — identical to 2.1 step 4.

No Identify step: a marker existing is the premise of the button.

### 2.3 What both refuse

An item still holding **several** markers is left alone by steps 2–3 of either
button and counted in the report. It is a recording, not a take; Cut is what
turns it into takes. This is today's `several` branch, unchanged, and it is
now also what a duplicate cluster the words refused to decide falls through to.

## 3. The missing-marker step

**Why it belongs here.** A take with no marker is not usually a bad match — it
is a marker that was never generated, or one that was deleted. Refusing on a
weak score would be answering a question nobody asked. So Update from Item
runs the identify pass on the unmarked items in its scope, and reports whatever
it could not place rather than guessing at it.

`vo.PlanItemIdentity` already gives the right answer per item, because it
detects the shape instead of asking:

| spans inside the item | it writes |
|---|---|
| **one** | one marker at the ITEM's own edges, and the line's name onto the item |
| **many** | one marker per span — this is a recording; steps 3–4 then leave it alone |
| **none** | nothing, reported as "matches no script line" |

The single-take case writing the marker at the item's edges is exactly what
this button wants: the hand-trim IS the truth, and step 3 then finds nothing to
snap.

**Seam.** `IdentifyItems` (`VO/ajsfx_VO_Overview.lua:1866`) is a whole verb —
its own `Reload`, its own transaction, its own `state.message`. It gains an
`opts` argument rather than being copied:

```lua
IdentifyItems({
  picked        = <item set or nil>,  -- skip its own SelectedItemSet()
  only_unmarked = true,               -- items whose Trim.markers_in is empty
  quiet         = true,               -- return counts, do not set state.message
})
  -> { wrote, named, none, many }
```

With no `opts` the behaviour is byte-for-byte what it is today, so the Identify
button is untouched. `only_unmarked` is a filter on the item loop at
`:1923`, beside the existing `info.skip` and `picked` tests.

Two things that could have gone wrong, and how they were settled:

- **Nested transactions — not relied on.** REAPER reference-counts
  `Undo_BeginBlock`, so an inner block would *probably* collapse into the outer
  one, but "probably" is not a thing to build one-press-one-undo on. `opts`
  carries `no_transaction`, and the step runs through `Trim.bare` —
  `core.Transaction`'s signature minus the transaction. The macro owns the
  block.
- **`Reload()` between steps.** Step 1 writes markers that step 2 must see.
  `Trim.markers_in` re-reads the item chunk, so the per-item path is already
  safe — but `Trim.dupe_plan` reads `state.take_markers`, which the identify
  pass has just made stale. Re-collect after step 1 exactly as `Trim.extras`
  does at `:1660`.

**The floor is not lowered.** `mark_item_min_span` (0.35) is a fraction of the
SPAN's length, so a clip trimmed tight to the speech still clears it — the
span's pauses hang outside the item, but 35% of the span is not close. Reuse
it unchanged; a "none" is reported, and the fix for a genuine miss is the
transcript, not a looser threshold.

## 4. Naming from the marker

Update from Marker renames the item from the surviving marker's asset, through
`vo.PlanAdopt` with the same `alt_append_pattern` Identify uses. The name is
the assignment, and a marker that says which line this is knows the name.

`PlanAdopt` never overwrites a name that already resolves to a line, so this
fills blanks and unresolvable names only. A *wrongly* named item is left wrong
— deliberately: correcting a name that resolves is a reassignment, and
reassignment is Identify's job, not a trim's.

## 5. Transcript

**No step.** `vo.TranscriptForRange` derives a take's words from the source
word list inside the marker's range (`VO/lib/ajsfx_vo.lua:1923`), and both
buttons end with a `Reload()`. Move the marker or trim the item onto it and the
words follow on the next frame. Nothing to press, nothing to store.

This is worth writing down because it is the one item on the list that looks
like it needs code and does not.

## 6. Where they sit

```
Match:  [ Match transcript to script ]  [ Identify the lines in these items ]
        [ Cut recording into takes ]

Edit:   [ Update from Item ]  [ Update from Marker ]
        [ Trim items to their markers ]  [ Snap markers to items ]
        [ Auto-adjust head and tail ]
        [ Remove Extra Take Markers ]  [ Apply the cut fades ]
```

**Cut recording into takes moves up into Match**, and the row it leaves is
renamed **Edit**. The two rows are the two states the user is actually in:

- **Match is the initial work.** One errand — *work out what this audio is and
  make it exist as takes* — run in order, once, on a fresh session: match the
  words, mark what they say, split on the marks. Cut was sitting at the top of
  a row of repair verbs it has nothing in common with, so a first pass had to
  jump a row and come back; worse, the row's macro (`Tidy Up Take`) sat
  directly above the one button in the group a fresh session presses first.
- **Edit is where the user lives afterwards.** Every verb in it acts on takes
  that already exist, and every one of them starts with a human having changed
  something by hand. This is not "fixing mistakes" — it is the normal working
  state of the tool, which is why the row is not called Fix.

The two macros lead Edit, in the MACRO slot the group already uses (`Tidy Up
Take` today, `Deliver` in Pull): one press for the whole job, with the single
steps it is built from still behind it.

**The cost, accepted.** `SPEC-toolbar.md` §Edit says the row labels are the
hero's own words — `Run the whole pass` reads *match → cut → pick → pull*, and
each word was a row. The labels now read Match / Edit / Pick / Pull, so the
mapping is 3-of-4. The hero's subtitle is unchanged, because the batch really
does still cut; what stops being true is that every phase has a row of its own.
Edit is the phase the batch cannot run at all — it is where a person has
already decided something — which is the same reason Check has no word in the
hero either.

**The tab is renamed Main.** It was `Edit`, which would have put an `Edit:` row
inside an `Edit` tab — one word doing two jobs at two scales. The tab is the
container and holds Match, Pick, Pull and Check as well, so it takes the name
that means *the work*; `Edit` stays on the row, where it names a phase. The
screen reads `[ Setup ] [ Main ]  …  [ Settings ]`.

The single-step buttons all stay. `Trim items to their markers` is Update from
Marker's step 2 with nothing else — the version to press when the markers are
already clean and the fades are already drawn.

**Tooltips state the authority in the first line**, since the names are now
deliberately symmetric and only one word apart:

> **Update from Item** — "The item's edges are right; everything else catches
> up." …
>
> **Update from Marker** — "The marker's bounds are right; the item catches
> up." …

## 7. The report

One formatter for both, extending `Trim.dupe_report`. Order follows the steps:

```
Marked 2 item(s) that had no take marker.
Removed 1 duplicate marker(s): Book (0.00) lost to IWinLittle (0.75).
Dropped the leftover markers from 12 clip(s).
Snapped 9 marker(s) to their item; filled the missing fades on 4.
3 clip(s) still hold several markers and were not snapped.
1 item(s) match no script line.
```

A step with nothing to do contributes no sentence. A press that did nothing at
all says so plainly instead of reporting success. `message_kind` is `warn` when
anything was refused (`several > 0`, `none > 0`, or a skipped duplicate
cluster), `ok` otherwise — today's rule, widened to the new refusals.

## 8. Testing

**Every step of both macros is an existing, already-tested planner** —
`PlanItemIdentity`, `PlanDuplicateMarkers`, `PlanMarkerPrune`,
`PlanTrimToRange`, `PlanAdopt`. The one genuinely new decision is the
ROUTING, so that is the one thing extracted into the lib and unit-tested;
everything else is a REAPER write, and the suite cannot load the Overview
script.

`vo.PlanUpdatePass`, in `tests/test_vo_tidy.lua`:

1. One marker → `act`, in both directions.
2. Several markers → `several`, refused in both directions. **The one that
   matters most**: an uncut recording holds one marker per take, and a verb
   that reduced "several markers on one item" to one would destroy a session
   on first press.
3. No marker, audio the matcher knows → `identify`, not refused. The score is
   never consulted.
4. No marker, no span → `unmatched`, reported rather than guessed at.
5. From Marker, no marker → `nomarker`. The one row where the directions
   differ.
6. A mixed scope routes every item exactly once.
7. `nil` items is not an error, and `dir` defaults to `"item"`.

The writes are checked by hand — `VO/MANUAL_TEST.md`, last section, thirteen
numbered checks. The one that cannot be skipped is #13: one press, one undo.

## 9. Not changing

- `Trim.extras`, `Trim.apply`, `Trim.snap_apply`, `Trim.dupe_plan` — the
  existing steps are the steps.
- The Identify button's own behaviour (`IdentifyItems` with no `opts`).
- Fade rule: filled per side, zero only, never overwritten.
- Scope: the selection, or everything.

## 10. Success criteria

- The name says which thing is the authority, with the tooltip closed.
- Neither button can leave a hand-trimmed clip with a stale marker, a stale
  name, missing fades, or no marker at all.
- Everything a button declined to do is named in the report.
- One undo step per press.
