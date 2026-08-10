# ajsfx VO Overview Toolbar — Design Spec

**Status:** Implemented, unverified in REAPER · **Date:** 2026-08-10
(supersedes the 2026-08-09 three-zone layout)

Reorganize the Overview toolbar so finding a button costs no thought.

---

## 1. The rule

**A tab never does anything. A button always does something.**

That is the whole contract, and it is what the previous layout broke: `Sort`
opened a panel while `Place`, the button beside it, moved audio on the press.
Two identical-looking controls with opposite consequences is the thing that
made the row unreadable.

Second rule, subordinate to the first: **the button name carries the
meaning, not the tooltip.** Names are deliberately long. A tooltip explains
consequences and edge cases; it is never the only place the button's job is
written down.

## 2. Layout

```
[ Setup ]  [ Edit ]                                                [ Settings ]
──────────────────────────────────────────────────────────────────────────────
 <the selected tab's buttons>
 <a detail panel, if a button opened one>
```

`Settings` is a tab-shaped button on the trailing edge, not a tab: it opens a
window rather than showing buttons.

**Two tabs, deliberately, and Edit is crowded.** This started as five (Setup /
Sheet / Items / Fix a line / Settings) and the extra boundaries cost more than
they bought: matching, cutting and fixing happen in one breath, so every
boundary put a tab switch in the middle of the work. Dim group labels
(`Match:`, `Items:`) do the dividing instead — a label can be moved in a line,
where a tab boundary cannot. Split again when the domains are known.

### Setup
```
[ Choose script… ]  [ Sources and transcripts… ]        Script: HolyFool_VO.csv
```
Once-per-project errands. A script that fails to load switches here and opens
the panel by itself.

### Edit
```
Match:  [ Match transcript to script ]  [ Pick a take for each line ] [Last ▾]
      | Items:  [ Cut recording into takes ]  [ Identify line from item ▾ ]
                [ Pull items to their tracks ]  [ Lay items out in script order ]
                [ Auto-adjust head and tail ]
      | [ Fix a line ]
```

**Match** — sheet only, no item is touched.
- **Match transcript to script** — re-reads every transcript, identifies the
  lines again from scratch, and writes down what the timeline shows: a take
  whose item sits on Selects is marked Sel. Lines left carrying two selects
  are counted (§4). Named for the job because matching IS the job, and nothing
  else in the toolbar said the word.
- **Pick a take for each line** — with its rule combo visible beside it.

It briefly carried two opt-ins (*also name matched takes*, *also pull*), which
put item surgery behind a sheet action. Removed: both jobs are in Items, and a
group whose contract is "changes nothing but the sheet" cannot have an
exception, however well labelled.

**Items** — in workflow order.
- **Cut recording into takes** — opens the Cut panel.
- **Identify line from item ▾** — the one home for "these items already
  exist, work out what they are", named for the SITUATION the user is in:
  *Find lines in items* (long items holding several takes: find them all,
  mark each inside the item, split nothing) · *Assign items to lines* (items
  already one take each: work out which line each selected item is, mark it
  at its current edges, name it, log it) · *Adopt this whole session* · *Sync
  take markers across copies*. All four used to appear in the Cut panel **and**
  the Repair panel.
- **Pull items to their tracks** — opens the Pull panel, which also carries
  **Pull the selected item(s) only** (the old `Place`): the same verb at a
  smaller scope, so they sit together.
- **Lay items out in script order** — the old Sort.
- **Auto-adjust head and tail** — the old Tighten. Named for both directions:
  it trims a loose edge and extends a clipped one.

**Fix a line** — the reconciliation panel (adopt timeline / adopt sheet /
relink / marker add-snap-delete), behind its own button at the end of the row.
It is the only thing here that works on ONE line rather than the session, so it
sits past a separator instead of among the batch actions.

### The ribbon's height

The ribbon reserves the tallest height a tab has taken **at this width**, and a
shorter tab pads to it. Each tab's row was as tall as its own contents, so
switching tabs moved the whole sheet up or down under the cursor — you click
`Setup` and the card you were reading jumps.

Measured, not declared: the buttons wrap, so the same tab is two rows on a wide
window and four on a narrow one. A constant would be right at exactly one width.
The reservation is discarded when the width changes, so widening the window does
not keep the tall reservation it needed when it was narrow.

### The empty sheet

With no script and no transcript, the card area asks for both — a button each,
and a tick against whichever is already done. It used to say only that there was
nothing to show, leaving both to be found inside a tab. The emptiest screen is
the one that most needs to say what to do next.

This is also the answer to "transcribe should always be visible": the moment a
first pass reaches for it is the moment the sheet is empty, and that is where it
now is. Sources stays in Setup otherwise — it is a once-or-twice-per-file
errand, not a constant one, and `Run the whole pass` removed the other reason to
live in the toolbar.

## 3. Row 2 — view only

```
[Search…]  [Character ▾]  [Filters] ([Clear filters])  [Unfold all] [Fold all]  [Follow]
```
Unchanged. Touches neither items nor tracking.

## 4. Select-conflict badge

A line with 2+ takes marked Sel — track placement can legitimately create
this — shows an amber `N selects — pick one` badge on its card band and
counts into `DrawSummary`. A live state display, not an artifact of the
update pass.

## 5. Not changing

- Panel internals beyond the moves listed above; the cards; filtering,
  follow and fold behavior; Sources and Settings as separate windows.

## 6. Success criteria

- Nothing at the top acts on click; nothing below the tabs merely navigates.
- A button's name tells you what it does with the tooltip closed.
- No capability removed, and nothing reachable from two places.
