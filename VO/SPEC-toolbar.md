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
(`Match:`, `Pick:`) do the dividing instead — a label can be moved in a line,
where a tab boundary cannot. Split again when the domains are known.

### Setup
```
[ Choose script… ]  [ Sources and transcripts… ]        Script: HolyFool_VO.csv
```
Once-per-project errands. A script that fails to load switches here and opens
the panel by itself.

### Edit
```
[ Run the whole pass ]   match → cut → pick → pull

Match:  [ Match transcript to script ]  [ Find lines in items ]
        [ Assign items to lines ]  [ Adopt the whole session ]
Cut:    [ Cut recording into takes ]  [ Auto-adjust head and tail ]
Pick:   [ Auto-pick selects: last take ]  [ …first take ]  [ Auto-name the alts ]
Pull:   [ Pull items to their tracks ]  [ Lay items out in script order ]
Check:  [ Marks vs tracks (0) ]  [ Takes without audio (0) ]  [ Tidy up take markers ]
```

**The rows are the hero's own words.** `Run the whole pass` reads
`match → cut → pick → pull`, and below it sits one row per word, in the same
order, plus **Check** — the phase the batch button cannot run, because its
verbs need a person deciding. The hero is the map of the toolbar: the batch
path and the manual path are the same mental model, and finding a button costs
one question — *which part of the job am I doing?*

This replaced grouping by what a button touches (Match = sheet, Items = audio).
Phases are how the user thinks while working; the object-touched split was how
the engineer thought about safety, and it now lives in each button's name and
tooltip instead of in the layout. The cost is real — the Match row mixes a
sheet-only verb with item-writing ones — and accepted deliberately.

- **Match** — establish what everything is. *Match transcript to script*
  (batch, sheet-only) and the per-item forms as plain buttons: *Find lines in
  items* · *Assign items to lines* · *Adopt the whole session*. They lived in
  an "Identify line from item ▾" menu, which hid three distinct situations
  behind one generic name and an extra click.
- **Cut** — make each take physically its own item, with the right edges.
  *Cut recording into takes*; *Auto-adjust head and tail* (the old Tighten —
  its trims move the take marker too, so the finishing pass cannot create the
  disagreement Fix a line would then report).
- **Pick** — decide what ships. *Auto-pick selects: last take* / *first
  take* — two buttons, not a button and a rule combo, because the combo was
  the one control on the toolbar that did nothing when clicked: it set state
  for a later press, which is tab behaviour. Each button states its whole
  rule and acts; whichever was pressed last is the rule the hero uses.
  *Auto-name the alts*. The **Auto- prefix is a family**: each Auto- button is
  the batch form of a per-row sheet gesture (the Sel box, the name field, a
  hand-trimmed edge), applying one rule everywhere the user has not already
  decided. Locked lines and hand-set values always stand.
- **Pull** — deliver. *Pull items to their tracks* (its panel also carries
  *Pull the selected item(s) only*, the same verb at a smaller scope) and
  *Lay items out in script order*.
- **Check** — does the sheet agree with the timeline? *Fix a line* is gone:
  it was one panel holding three problems, and the button name said none of
  them. Split by REMEDY — *Marks vs tracks* (disagreements, fixed as a batch:
  adopt the timeline or adopt the sheet) and *Takes without audio* (markers
  and marks whose audio is gone — two of the old three sections, merged
  because they always shared the same per-row Relink). Both buttons wear
  their counts, so the row reads as state before anything is clicked: "(0)"
  everywhere means the session agrees with itself. *Tidy up take markers*
  closes the row. The orphan queue and the summary line are this phase's
  other half, living in the sheet itself.

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
