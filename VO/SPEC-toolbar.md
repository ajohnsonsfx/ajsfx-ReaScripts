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
[ Setup ]  [ Sheet ]  [ Items ]  [ Fix a line ]                    [ Settings ]
──────────────────────────────────────────────────────────────────────────────
 <the selected tab's buttons>
 <a detail panel, if a button opened one>
```

`Settings` is a tab-shaped button on the trailing edge, not a tab: it opens a
window rather than showing buttons.

### Setup
```
[ Choose script… ]  [ Sources and transcripts… ]        Script: HolyFool_VO.csv
```
Once-per-project errands. The loaded-script readout lives here, where you go
when it is wrong. A script that fails to load switches to this tab and opens
the panel by itself.

### Sheet
```
[ Match transcript to script ]   [ Pick a take for each line ] [Last ▾]
```
- **Match transcript to script** — re-reads every transcript, identifies the
  lines again from scratch, and writes down what the timeline shows: a take
  whose item sits on Selects is marked Sel. Lines left carrying two selects
  are counted (§4).

  It is named for the job because matching IS the job, and nothing else in
  the toolbar said the word. Asked "how do I make it match?", a user could
  not find this button under its previous name.
- **Pick a take for each line** — the old Select takes, with its rule combo
  visible beside it rather than hidden in a menu.

**No opt-ins.** This button briefly carried two — *also name matched takes*,
*also pull named items to their tracks* — which put item surgery behind a
Sheet button and broke §1 in the one place it mattered most. Both jobs live
in the Items tab. A tab whose contract is "never changes an item" cannot have
an exception, however well labelled.

There is no Refresh button. Refreshing was a strict subset of updating the
sheet, and two buttons where one contains the other cannot be told apart no
matter how they are named.

### Items — in workflow order
```
[ Cut recording into takes ]  [ Identify line from item ▾ ]
[ Pull items to their tracks ]  [ Lay items out in script order ]
[ Auto-adjust head and tail ]
```
- **Cut recording into takes** — opens the Cut panel (unchanged internals
  minus the relocated buttons below).
- **Identify line from item ▾** — the one home for "these items already
  exist, work out which line each one is": *Mark takes at their current
  edges*, *Adopt this whole session (mark and name)*, *Identify the item(s)
  selected in REAPER*, *Sync take markers across copies*. All four used to
  appear in the Cut panel **and** the Repair panel.
- **Pull items to their tracks** — opens the Pull panel, which now also
  carries **Pull the selected item(s) only** (the old `Place`). Pull and
  Place were the same verb at two scopes, so they sit together.
- **Lay items out in script order** — the old Sort; opens the layout bar.
- **Auto-adjust head and tail** — the old Tighten. Acts on the press. Named
  for both directions: it trims a loose edge and extends a clipped one.

### Fix a line
The reconciliation panel (adopt timeline / adopt sheet / relink / marker
add-snap-delete) is the tab's whole body — no button opens it. It earns tab
level by being the only thing that works on **one line** instead of the
session; buried among batch actions it reads as one.

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
