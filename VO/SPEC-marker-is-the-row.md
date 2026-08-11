# ajsfx VO — A marker is a row

**Status:** Designed, not implemented · **Date:** 2026-08-11

One rule: **a take exists in the sheet when, and only when, a take marker says
it does.** Nothing is tracked until Identify marks it.

This is the sheet catching up with a decision the rest of the tool already
made — *a take marker is what the cut will be*. Cut works from markers, Trim
and Snap work from markers, the marks are keyed by marker id. Only the sheet
still had a second opinion.

---

## 1. What changes

`vo.BuildOverview` builds a line's takes from two sources today: the markers in
`takes_by_asset` when there are any, and the match spans otherwise. **The
second source is removed.**

| Line has | Today | After |
|---|---|---|
| markers | marker rows | marker rows, unchanged |
| spans, no markers | span rows, tickable | `missing`, with `heard = N` |
| neither | `missing` | `missing` |

A `missing` row gains `heard`: how many match or review spans that line has in
the session. Zero means nothing was recorded; four means the audio is sitting
there and Identify has not been run on it. `missing` must never read as "we
looked and there is nothing" when there is.

Planned rows (`vo.PlannedKey`) are unaffected: a planned take is an explicit
user act, not a guess, and appends after the marker rows exactly as now.

### 1.1 What this deletes

Span rows move when the transcript is re-run, so their stored decisions had to
be re-attached by source time within a tolerance — `vo.OverviewKey`,
`resolve_tracker`, `index_tracker`'s time buckets, and the 40 ms/2 s rematch
rules. A marker id does not move, so **none of that is needed for take rows**
once markers are the only source.

It is not deleted in this change. The functions stay, still tested, still used
for the planned-key and per-asset lookups; only the take-row path stops calling
them. Removing them is a separate pass with its own risk.

---

## 2. Where unmarked audio goes

Deleting span rows without replacing them would hide the reads Identify scored
too low — exactly the takes most in need of a human. So they get their own
place.

`vo.UnidentifiedSpans(input)` returns every match or review span that no
counting marker covers:

```
{ { source_path, start, stop, asset, deliver, score, transcript }, ... }
```

A span counts as covered when a marker overlaps at least **half** of it. Half,
not any: a marker clipped short still owns its take, and a marker that merely
brushes a neighbouring span does not.

This is a **Check** panel, "Not yet identified", wearing its count like the
other Check rows. `(0)` means every span the matcher found has been marked.

Orphans — spans matching no line at all — keep their own separate queue. The
two questions are different: "which line is this?" versus "this line's audio is
not tracked yet".

---

## 3. Why this is worth the churn

- **The sheet stops lying.** Today a line shows four tickable takes that no
  verb will act on, because Cut, Trim and Snap all need markers. Ticking Sel on
  a span row decides nothing.
- **Counts become answerable.** "40 of 131 lines have takes" means 40 have been
  identified. Today it means the matcher had an opinion.
- **Untrack becomes visible.** Removing the markers removes the rows, which is
  what a user pressing Untrack expects to see.
- **One mental model.** Marker = row. Nothing else to learn.

The cost is that the sheet is empty before Identify runs. That is honest: a
session that has not been identified has nothing tracked.

---

## 4. Testing

The existing `BuildOverview` tests build takes from spans, which is the removed
path. Converting them is the bulk of this work, and the rule for the conversion
is: **a test asserting how TAKES behave gets markers; a test asserting how
SPANS are grouped or re-matched keeps its spans and asserts the new outcome**
(`missing`, `heard`).

New tests:

1. A line with spans and no markers is `missing` with `heard` equal to the span
   count.
2. A line with neither is `missing` with `heard = 0`.
3. A line with markers ignores its spans entirely for row-building, including
   when the spans outnumber the markers.
4. Planned rows still append after marker rows, and appear on a line whose only
   other content is planned.
5. `UnidentifiedSpans` returns a span no marker touches.
6. `UnidentifiedSpans` omits a span a marker covers by more than half, and
   returns one a marker covers by less.
7. `UnidentifiedSpans` ignores orphan/unmatched spans — they are the other
   queue's business.
8. `SummarizeOverview` counts a `heard > 0` missing line as missing, not as
   recorded.
