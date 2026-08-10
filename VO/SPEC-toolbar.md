# ajsfx VO Overview Toolbar — Design Spec

**Status:** Approved design, unimplemented · **Date:** 2026-08-09

Reorganize the Overview toolbar so finding a button costs no thought. The
organizing rule the user can trust without reading anything: **buttons on the
left only update the tracking sheet; buttons on the right change audio
items.** Plus one new hero action, **Tidy**, a best-effort pass that is safe
by default.

---

## 1. The rule

Every control the user can press falls into exactly one of three categories:

| Category | Where it lives | Contract |
|---|---|---|
| **Sheet** — updates tracking only | Row 1, left zone | Can never change an item, a track, or the timeline. Always safe to press. |
| **Items** — changes audio items | Row 1, right zone | Splits, moves, names, trims, or marks items. In workflow order. |
| **View** — changes what you're looking at | Row 2 | Filters, folding, follow, search. Touches neither items nor tracking. |

The zones wear dimmed text labels (`Sheet:` / `Items:`), and every sheet-zone
tooltip opens with "Tracking only — no items change."

The one deliberate crossover: Tidy's two opt-in checkboxes reach into item
territory, and the popup labels them **"changes items"** so the boundary
stays honest (§4).

## 2. Row 1 layout

```
Sheet:  [Refresh] [Tidy ▾]   │   Items:  [Cut] [Pull] [Sort] [Place] [Tighten] [Repair]   │   [Script] [Sources…] [Settings]
```

- **Refresh** — the current Rematch, renamed and moved to first position.
  Re-reads transcripts and re-identifies lines from scratch; locked lines
  keep their placement. Tooltip keeps the existing explanation.
- **Tidy ▾** — new; §3–4.
- **Items zone** — the existing panel buttons plus Place and Tighten (moved
  off the filter toolbar), in the order work happens: cut → pull → sort →
  place → tighten → repair. Panel toggling behavior (held-down button, one
  panel at a time) is unchanged. Panel *contents* are unchanged.
- **Setup cluster** — Script, Sources…, Settings at the far right, out of
  the workflow's way. The bad-script warning still jumps to the Script panel.

## 3. Row 2 layout

```
[Search…]  [Character ▾]  [Filters] ([Clear filters])  [Unfold all] [Fold all]  [Follow]
```

Same controls as today minus Rematch, Select takes + combo, Place, and
Tighten (all relocated). Search moves to the front — it is the
highest-frequency control. Filter-row boxes, Follow popup, and all behavior
unchanged.

## 4. Tidy — the best-effort pass

**Click Tidy** → runs immediately, no dialog. Safe pass only:

1. Refresh (same code path as the Refresh button).
2. **Mark selects from track position**: for each line, every delivered item
   sitting on that line's Selects track gets its take marked **Sel** in the
   sheet. More than one item of a line on Selects → *all* are marked and the
   line card shows an amber badge: `2 selects — pick one`. Locked lines are
   untouched. This writes sheet state (project ExtState) only; no item
   changes, no undo point on the timeline.
3. One-line report in the message area:
   `Tidy: 14 lines refreshed, 3 selects marked, 2 conflicts.`

**The ▾ arrow** (separate small button beside Tidy) opens a popup:

- ☐ **Also name matched takes** *(changes items)* — apply script filenames to
  matched delivered takes that aren't named yet, and alt-pattern names to
  Keep-ticked rows (existing `ApplyAltNames` machinery).
- ☐ **Also pull named items to tracks** *(changes items)* — run the existing
  Pull on what the pass just named/matched.
- **[Select takes]** + take-pick combo — relocated from the toolbar,
  unchanged behavior (heuristic pick on multi-read lines, respects locks).

Both checkboxes persist in config (`vo.LoadConfig`/`SaveConfig`), default
off. When either is on, the item-changing steps run inside **one
`core.Transaction`** so the whole pass is a single undo step, and the Tidy
button's tooltip switches from "Tracking only…" to naming what it will do.

Order when everything is on: refresh → name → pull → mark selects (marking
runs last so it sees the post-pull track layout).

## 5. Select-conflict badge

A line with 2+ takes marked Sel (however it got that way — Tidy, or hand
ticks) shows the amber badge on its card title band and counts into the
summary line (`DrawSummary`) as `N lines need a select chosen`. The badge is
a state display, not a Tidy artifact: it appears and clears live as ticks
change.

## 6. Not changing

- Panel internals: Cut panel (Cut and Name, Re-cut anyway, Mark takes, Adopt
  session, Mark selected), Repair panel (Adopt timeline/sheet, Relink, Mark
  takes, Mark selected item(s), Sync take markers), Pull and Sort panels.
- The cards themselves, filtering semantics, follow behavior, fold
  persistence.
- Sources and Settings remain separate windows.

## 7. Success criteria

- A user who has never read the manual can answer "which button is safe to
  press?" from the toolbar alone.
- Refreshing the sheet is one click, leftmost button.
- The best-effort pass is one click and cannot move or rename anything
  unless its opt-ins were deliberately turned on.
- No existing capability is removed; everything relocated is findable by its
  category.
