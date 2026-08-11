# ajsfx VO — Range-true transcripts, and a fades verb

**Status:** Designed, not implemented · **Date:** 2026-08-10

Two small changes that fix one complaint: *the text captured for this line is
wrong.* Neither of them reassigns a take to a different line — this spec is
about the words shown under a take, and about the fades on the item, and about
nothing else.

A third item raised in the same conversation — emptying the take row's
right-click menu into the toolbar — is deliberately **not** in this spec. See
§4.

---

## 1. The complaint

A take defined by a take marker builds its row through `marker_row` in
`vo.BuildOverview`, and its text comes from `vo.TranscriptForRange`
(`VO/lib/ajsfx_vo.lua`). That function gathers every match span on the source
that *overlaps* the marker's range and concatenates each one's **entire**
transcript.

So a marker covering the last two words of one span and the first three of the
next reads as both spans in full — a dozen words the take does not contain.
Drag a marker in, trim an item, snap a marker to a hand-trimmed item: the text
does not narrow with it, because span text is span-shaped.

The score has the same shape but is not the same problem: a score is a fact
about one placement, and `TranscriptForRange` already picks the single
best-overlapping span for it rather than averaging. That behaviour stays.

---

## 2. Marker rows read their words

`vo.TranscriptForRange` derives its text from the source's **word list**
instead of from span transcripts:

- keep every word whose timestamp falls inside `[from, to]`,
- join with single spaces — the same construction span transcripts use
  (`s.transcript = table.concat(text, " ")` in `vo.BuildMatch`), so nothing
  downstream sees a new shape.

Inclusion rule: a word counts when its **midpoint** `(t0 + t1) / 2` lies inside
the range. Whisper pads word ends into the following silence, so testing `t1`
alone pulls in a word the range does not really hold; testing `t0` alone keeps
a word whose audio is mostly outside. The midpoint is the cheap answer that is
right at both edges.

The score and `in_sequence` returns are unchanged: still the single match or
review span with the greatest overlap.

**Always on.** This is not a button. Every rebuild derives marker text this
way, so dragging a marker in the arrange view, trimming an item to its marker,
or snapping a marker to an item all leave the sheet's text correct without a
press. There is no state where the old behaviour is wanted.

### 2.1 Getting the words there

`vo.BuildOverview` currently receives `input.matches` (spans, no words). It
gains `input.transcripts` — the same `{ path = ..., words = ... }` list the
Overview already builds to call `vo.BuildMatch`
(`VO/ajsfx_VO_Overview.lua`, the transcripts loop before `state.matches`). No
new file reads: the list is in hand at the call site and is passed on.

`vo.TranscriptForRange` takes the word list for the source as an argument
alongside the flattened spans it already takes.

### 2.2 Fallback

A source with no word list loaded — a caller that did not pass
`input.transcripts`, or a hand-built test — falls back to the current
span-concatenation behaviour rather than returning nothing. A row with
approximate text beats a row with none, and the existing tests keep passing on
the old path.

### 2.3 What follows for free

- Extra-word colouring (`ExtraRuns` → `vo.ExtraWords`) reads `row.transcript`,
  so the words highlighted as "in the take, not in the line" narrow with the
  range.
- Check's counts, which read the same rows, stop reporting extra words that
  belong to a neighbouring take.

---

## 3. A verb that applies the cut fades

A toolbar button under **Edit**: set `D_FADEINLEN` / `D_FADEOUTLEN` on every
selected item to `cut_fade_in` / `cut_fade_out` (`vo.Opt`). One
`core.Transaction`, one undo step, scope is the selection like every other
verb.

Reports the count it changed. An item already carrying the default fades is
not a write and is not counted, so a press over a tidy session says so instead
of claiming work — the same honesty rule `Trim.snap_apply` follows.

### 3.1 The consequence, stated on purpose

**Default fades are the "nobody touched this by hand" sentinel.** `TightenItems`
("Auto-adjust head and tail") skips any item whose fades differ from the cut
defaults, which is how a hand-trimmed item is protected from being re-measured
and moved.

Pressing this button therefore **re-enrols** a hand-trimmed item into
Auto-adjust. That is the correct reading of the gesture — "this item is
finished and standard again" — but it is not free, and the button's tooltip
says so in plain words.

---

## 4. Out of scope: the right-click migration

The take row's menu (`DrawTakeRowMenu`) holds ten verbs, and the stated
direction is that all of them should live in the toolbar and the menu should go
away.

Three port straight across, and two of those already have toolbar twins on this
branch: Snap marker to item, Trim item to marker, Delete take marker.

The rest are per-row **by nature** and have no toolbar home yet:

| Verb | Why it resists a batch button |
|---|---|
| "This is line…" | A scored candidate list for one specific row. |
| "This is junk" | Per-span decision, though it could batch. |
| "Find candidates" | Already batches over the selection; needs a results home. |
| "Add take marker from selected item" | One row, one REAPER item. |
| "Assign selected item to this line" | One target row. |
| "Make this take the Select" | One row, by definition. |
| "Lock to time selection" | One stretch of audio is one line. |

Moving those needs a "current row" region in the toolbar that does not exist,
and designing it by guess would waste the work. It gets its own brainstorm and
its own spec.

---

## 5. Testing

Against the mock REAPER environment in `tests/`:

1. `TranscriptForRange` over a range covering part of two spans returns only
   the words inside it, not both spans in full.
2. Midpoint inclusion: a word straddling the range start with most of its
   duration outside is excluded; one with most inside is kept.
3. The score return still comes from the greatest-overlap match span, and is
   unaffected by which words the range holds.
4. No word list for the source → the old span-concatenation text, unchanged.
5. `BuildOverview` with `input.transcripts` produces marker rows whose text
   matches the range; without it, existing test expectations hold.
6. The fades verb sets both fade lengths and reports zero changed when every
   selected item already carries the defaults.
