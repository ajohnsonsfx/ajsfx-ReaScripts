# ajsfx VO — Remove duplicate take markers

**Status:** Designed, not implemented · **Date:** 2026-08-10

One verb for the case where two script lines have both claimed the same stretch
of audio: score each claim against the words actually spoken there, delete the
losers, and refuse when the words do not clearly decide.

Companion to `VO/SPEC-range-transcript.md`, which is what makes the words
available per range in the first place.

---

## 1. The shape of the problem

Observed in a live session, item at project `631.4541`:

```
TKM 31.87 "DBP_Grumbar_Grumbar_IWinLittle ~mkm" 0 3
TKM 31.87 "DBP_Grumbar_Grumbar_Book ~mkt"       0 3
```

Two counting markers, byte-identical ranges, two different lines. The words in
`31.87–34.87` are *"I only win little."* — so one claim is right and the other
is on audio that is not its line at all.

The cost is not cosmetic. An item holding several counting markers reads as *a
recording, not a take*, so **Trim items to their markers** and **Snap markers to
items** both skip it, and the sheet shows one clip as a take of two lines.

**Tidy up take markers does not fix this.** `vo.PlanMarkerMirror` dedupes by
marker **id**, and these are two different ids. Tidy correctly removes the
non-covering copies that a split scattered onto neighbouring items; it has no
opinion about two ids competing for one range.

---

## 2. The one rule that keeps this safe

**Cluster by overlapping range, never by item.**

An uncut recording legitimately holds one counting marker per take. A verb that
reduced "several markers on one item" to one would destroy such a session on
first press. So the unit of work is not the item — it is a set of markers whose
ranges are fighting over the same audio.

Two markers cluster when

```
overlap / min(length_a, length_b) >= 0.80
```

Clustering is transitive within a source: A–B and B–C put all three in one
cluster. Markers on different sources never cluster.

A cluster of one is every normal take, and is left alone. Only clusters of two
or more are considered at all.

---

## 3. Choosing the survivor

For each marker in a cluster, score its own line against the words inside its
own range — not the cluster's union, so a marker whose range is genuinely
slightly different is judged on what it actually covers:

```
score = 1 - Levenshtein(line_tokens, range_word_tokens)
            / max(#line_tokens, #range_word_tokens)
```

with `vo.Normalize` / `vo.Tokenize` and the configured substitutions, exactly as
`vo.FindSpanLines` does. The highest score keeps its marker; the rest are
deleted.

A marker whose asset matches no script line scores `0`. It cannot win, and it
loses to any real match.

---

## 4. When it refuses

The cluster is left **entirely** untouched, and named in the report, when any
of these holds:

| Condition | Why |
|---|---|
| The range has no words | No transcript, no opinion. |
| Best score `< 0.50` | Nothing matches the audio well — the transcript or the cut is wrong, not the markers. |
| Best minus runner-up `< 0.20` | A near-tie is a judgment call, not an automation. |

Refusing is per cluster, not per press: a session with four clear duplicates and
one ambiguous cluster cleans the four and reports the fifth.

---

## 5. The pure planner

```
vo.PlanDuplicateMarkers({
  markers = { { id, asset, start, stop, source_path, item_index }, ... },
  lines   = script lines,
  words   = { [source_path] = { {t0,t1,text}, ... } },
  cfg     = config (for subs),
  opts    = { fraction = 0.80, floor = 0.50, gap = 0.20 },
})
  -> {
    deletes = { { id, asset, source_path, item_index, score, lost_to }, ... },
    kept    = { { id, asset, source_path, item_index, score }, ... },
    skipped = { { why, markers = { {id, asset, score}, ... } }, ... },
  }
```

`why` is one of `"no words"`, `"no clear match"`, `"too close to call"` — the
three rows of §4, in that order of precedence.

Clustering is its own function, `vo.ClusterMarkerRanges(markers, fraction)`,
returning an array of arrays. It is worth testing on its own: the transitivity
and the never-cross-sources rule are where this would go wrong.

Neither function touches REAPER. The Overview collects markers, calls the
planner, and writes.

---

## 6. The two verbs

Scope for both is the REAPER selection, everything when nothing is selected.
One `core.Transaction` each, one undo step. Writes go through
`vo.WriteTakeMarkers`, so markers the tool does not own are preserved. Both
mark the project file dirty: marker bounds are VO data.

### 6.1 Remove Extra Take Markers

Everything on a clip that is not its own take marker, in one step. Two kinds of
extra, deliberately one button rather than two the user has to tell apart:

1. **Duplicates** — §2–§4 above.
2. **Leftovers** — markers before and after the clip's own audio, which is what
   REAPER's split leaves when it copies the whole marker set into both halves.
   Dropped by the coverage rule (`vo.PlanMarkerMirror`).

**Order matters: duplicates first.** The mirror pass decides which *copy* of a
marker id is canonical; running it first would faithfully preserve a duplicate
the words are about to delete. The marker collection is re-read between the two
passes, so the mirror plan is not built from pre-delete chunks.

This replaces the old project-wide **Tidy up take markers** button, whose whole
behaviour is the leftovers half. `SyncTakeMarkers` survives as the seam's
`sync_markers` command.

### 6.2 Tidy Up Take

The button for *"I just trimmed this clip by hand — make it right again"*, in
one undo step:

1. **Remove Extra Take Markers**, exactly as §6.1.
2. **Snap** the surviving marker to the item's current edges. A clip still
   holding several markers — because the words refused to choose — is left
   unsnapped and reported: snapping one of several to the whole item is a
   guess.
3. **Fill** the fades. Per side, never overwritten: a zero fade-in gets
   `cut_fade_in`, a zero fade-out gets `cut_fade_out`, and any non-zero fade on
   either side is left exactly alone.

The fill-don't-overwrite rule is what makes this safe to press repeatedly. A
trim leaves the edge it cut at zero and the other edge's fade intact, so this
restores exactly what the trim removed — and a fade drawn by hand survives.
It also keeps `TightenItems`'s hand-trimmed sentinel (custom fades mean "leave
this alone") meaningful, which a blanket overwrite would destroy.

### 6.3 The report

Names the losers. A delete you cannot audit is a delete you stop trusting.
Both verbs share one formatter so they cannot describe the same step
differently.

```
Removed 1 duplicate marker(s): Book (0.00) lost to IWinLittle (0.75).
Left alone -- too close to call (Book 0.31 vs OldBook 0.29).
Dropped the leftover markers from 12 clip(s).
```

A press that finds nothing says so plainly rather than reporting success.

---

## 7. Testing

Against the mock REAPER environment in `tests/`:

1. Two identical ranges, one line matching the words and one not → the
   non-matching marker is deleted, the matching one kept.
2. An uncut recording — five markers, distinct ranges, no overlap → nothing is
   clustered and nothing is deleted. This is the test that matters most.
3. Overlap exactly at the 0.80 boundary clusters; just under it does not.
4. Transitivity: A–B overlap and B–C overlap put all three in one cluster.
5. Two markers with the same range on different sources never cluster.
6. Best score `0.45` → skipped as `"no clear match"`, nothing deleted.
7. Best `0.60`, runner-up `0.50` → skipped as `"too close to call"`.
8. A range with no words → skipped as `"no words"`.
9. A marker whose asset is in no script line loses to any real match, and two
   such markers together are skipped rather than one being picked arbitrarily.
