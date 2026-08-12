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

---

## 5. Implementation

### 5.1 `vo.BuildOverview` — `VO/lib/ajsfx_vo.lua`

The row-assembly loop (`for line_row, line in ipairs(lines)`, around the
`local rows = {}` near the end of the function) has three branches today:
markers, spans, neither. **Delete the middle one.** The `elseif g and #g > 0
then ... end` block goes; its `planned_by_row` tail moves into the `missing`
branch so a planned take still appears on an unmarked line.

`groups` is still built — `UnidentifiedSpans` and `heard` both need it.

The `missing` row gains one field:

```lua
heard = g and #g or 0,
```

`take_count` stays 0: a heard span is not a take.

### 5.2 `vo.UnidentifiedSpans(input)` — new, same file

Takes the same `input` shape as `BuildOverview` (it needs `matches` and
`takes_by_asset`). For every span of kind `match` or `review`, find whether any
counting marker on the same source overlaps at least half of it; return the
ones nothing covers, sorted by source then start.

Pure. No REAPER calls. Put it beside `BuildOverview`.

### 5.3 The Check panel — `VO/ajsfx_VO_Overview.lua`

A `PanelButton` in the Check group, `"Not yet identified (%d)"`, drawn like
`DrawNoAudioPanel`. Each row: source basename, timecode, the line it scored
against, its score, its transcript. Clicking a timecode moves the edit cursor,
as the Sources report already does.

### 5.4 The `heard` hint

Where a `missing` card draws today, add `heard` when it is > 0 — e.g. a small
disabled chip reading `heard 4x`. Nothing clickable: the verb that acts on it
is Identify.

---

## 6. Converting the existing tests

30 `BuildOverview` call sites, 28 of which build takes from spans. The rule:

- **Asserting how TAKES behave** → give it markers via `takes_by_asset`, keep
  the assertion.
- **Asserting how SPANS group or re-match** → keep the spans, assert the new
  outcome (`missing`, `heard`).

By name, in `tests/test_vo.lua`:

**Give markers** (they are about takes):
- multiple takes become sibling rows, numbered chronologically
- with no select recorded, no take is the primary
- an explicit select in the project file names the primary
- two transcripts fold into one list, takes numbered across both
- a review span reads as review, not recorded
- two script lines sharing a filename keep their own takes apart
- rows follow script order, not audio order
- a span with no line index still groups by filename

**Assert the new outcome** (they are about spans, and their subject is now
`missing` + `heard`, or `UnidentifiedSpans`):
- a script with no audio at all is entirely missing — unchanged, already right
- one source's missing line and another's audio coexist in one list
- audio matching no script line becomes an orphan row, listed last — orphans
  are unaffected, confirm it still passes
- audio for a line the filters excluded is an orphan, never dropped — same

**The whole "project-file overlay and rematch" block** (9 tests, from "an exact
key match carries the verified flag and notes" to "a name override is carried
but never overwrites the matched filename") tests entry re-attachment by source
time, which only ever mattered for span rows. Marker rows key by `tkm|<id>`
and cannot drift. These tests keep testing `index_tracker`/`resolve_tracker`
directly, or move to marker keys — **decide per test, do not delete wholesale**:
the tolerance rules still guard the planned-key and per-asset lookups.

`ProjectEntriesFromRows / SummarizeOverview` (4 tests): the round-trip ones need
marker rows; the summary ones need a `heard`-aware assertion.

`tests/test_vo_markers.lua` (4 call sites) already passes `takes_by_asset` and
should need no change — run it first as the canary.

---

## 7. Session context this spec came out of

Facts established on 2026-08-10/11 that are not recorded in the code:

- The project's transcript was re-run with `ggml-large-v3` after
  `large-v3-turbo` produced onsets drifting 2–3 s inside continuous phrases.
  That single change fixed most mis-identification: a test line went from
  scoring 0.500 for the right script line (losing to a near-twin at 0.600) to
  1.000 vs 0.667.
- Substitutions now in the project's Settings, found by comparing heard words
  against the script vocabulary: `bolvd=adon`, `bold=adon`,
  `chainself=chained self`, `toadman=toad man`, `bookman=book man`, `high=i`,
  `tauor=tower`, `archivists=archivist`, `sentin=sentence`. None of those
  appear in the script, so none can create a false match. `high=i` was
  responsible for every take of `I guard… leaving.` starting one word late.
- A tool worth building later: **suggest substitutions** — heard words that
  appear nowhere in the script, ranked by count. That computation found all of
  the above in seconds.
- Also worth building: **find reads with no marker**, which §2 here is the
  first half of.
- The session was untracked to 0 markers to test the new Untrack verb, so the
  project is a clean slate for verifying this change end to end.
