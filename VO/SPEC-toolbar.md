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

Third rule: **every verb acts on the selection, and the scope is always on
screen.** See §2.1.

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
Acting on 12 selected row(s).

Match:  [ Match transcript to script ]  [ Identify the lines in these items ]
Cut:    [ Cut recording into takes ]  [ Trim items to their markers ]
        [ Auto-adjust head and tail ]
Pick:   [ Auto-pick selects: last take ]  [ …first take ]  [ Auto-name the alts ]
Pull:   [ Pull items to their tracks ]  [ Build the destination tracks ]
        [ Lay items out in script order ]
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

- **Match** — establish what everything is. Two verbs: *Match transcript to
  script* re-derives the whole match from the words (sheet only), and
  *Identify the lines in these items* writes what the match says into the
  audio — take markers, and names where an item is one take.

  **Identify detects the shape of the audio instead of asking.** It was three
  buttons (*Find lines in items*, *Assign items to lines*, *Adopt this whole
  session*) which differed only in what shape the audio was in, and choosing
  wrong did the wrong thing silently. `vo.PlanItemIdentity` counts the match
  spans falling inside each item:

  | spans inside | the item is… | so… |
  |---|---|---|
  | **one** | that take | marker spans the ITEM, at the user's own edges; item takes the line's name |
  | **many** | a recording holding takes | marker per span, at each SPAN's bounds; item is NOT renamed — it has no one line to be named after |
  | **none** | not on the script | reported, never guessed at |

  A span counts as inside when `mark_item_min_span` (0.35) of the SPAN's own
  length is within the item — so a clip holding one take plus the tail of the
  previous one still reads as one take, which is what it is.

  Naming is decided independently of marking, so a session an earlier run
  already marked still gets its names: that is what *Adopt this whole session*
  existed for. `vo.PlanAdopt` never overwrites a name that already resolves to
  a line, so re-running is safe.
- **Cut** — make each take physically its own item, with the right edges.
  *Trim items to their markers* is the manual half of "the marker is what the
  cut will be": drag a marker to where the clip should start and end, then trim
  the item onto it — no re-cut, no re-match, no split. The audio does not move
  (`vo.PlanTrimToRange` moves the position by exactly what the start offset
  changes, so the same source sample stays at the same project time). An item
  holding SEVERAL markers is a recording, not a take, and is left alone. Its
  per-row form sits in the take menu beside its opposite, *Snap marker to
  item*.

  *Cut recording into takes* acts on the press (it used to open a panel whose
  only real control was a second copy of itself; the panel is now the report
  the run opens by itself); *Auto-adjust head and tail* (the old Tighten —
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
  *Pull the selected item(s) only*, the same verb at a smaller scope),
  *Build the destination tracks*, and *Lay items out in script order*.

  **Build the destination tracks** makes Selects / Alts / Review under each
  recording without moving anything. Pull creates them as a side effect of
  having somewhere to put an item, so until the first successful pull there is
  nowhere to drag a take by hand and no way to see the shape the session is
  heading for. It shares Pull's own helpers (`Dest.names`,
  `Dest.recording_of`, `vo.EnsureChildTrack`), so the folders it builds are
  the folders Pull would have built — created in reverse so they read Selects
  / Alts / Review top to bottom, and nested under the RECORDING rather than
  under whatever destination an item currently sits on, which is what stops a
  re-run burying a track inside a track. Idempotent: a track that already
  exists is left alone, depth included.
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

### 2.1 Scope: the selection, shown

**Every verb acts on what is selected; nothing is selected means everything the
filters show.** One rule, no per-panel checkbox, and a dim line under the hero
says what the next press will act on before it is pressed.

**There are two selections and they are one idea.** The sheet selects rows;
REAPER selects items. `row.item` is the bridge, and `vo.ResolveScope` unions
them — a row is in scope if its own row is selected, or if the item it lives in
is. That reads correctly at both stages of the job, which is why the UI never
has to distinguish lines from items:

| | one item is… | selecting the item means… |
|---|---|---|
| **before Cut** | the whole recording, holding every take | every take in it — *"cut this recording"* |
| **after Cut** | exactly one take | that take |

That asymmetry is the reason the rule is written on takes rather than on items.
Before Cut there is no parity to appeal to: one item holds four hundred takes.
Resolving item → takes (never item → item) makes the same sentence true at both
stages.

**It never silently widens.** A selection that resolves to nothing in view —
because the filters are hiding it — gives an EMPTY scope and says so. Acting on
169 lines because the one you picked was filtered out is the worst available
answer.

**Why the scope line is not optional.** This replaced a "Selected rows only"
checkbox that defaulted to OFF, because clicking a row to audition it also
selects its item (`SyncProjectSelection`), so honouring the selection meant
listening could silently narrow the next run. The tool was protecting itself
from its own selection by ignoring it. Honouring it always and *showing* the
result is the honest version of the same safety: if the line says "3 rows",
nothing can act on 169.

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
