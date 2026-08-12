# ajsfx VO — Anchor-fenced boundaries: the cutting half

**Status:** Implemented, both halves · **Date:** 2026-08-12 ·
Completes `SPEC-word-anchors.md`

Word anchors fixed what a range *reads as*. This spec points the same signal
at what a range *is*: where Identify's cuts and take-marker boundaries land.
It has two independent halves — **catch** (flag every boundary that
contradicts the words, read-only) and **place** (derive boundaries from
anchors + silence so re-Identify gets them right).

---

## 1. The found failure

Spot-checking the un-adjusted block, source 584.9–590.5, script lines
"Chain is chain." then "Even if you smile.":

```
markers (old pipeline):        words (fresh decode):
ChainIsChain   584.900-586.210    Chain  window 584.900-585.090  anchor 585.060
EvenIfYouSmile 586.210-590.470    is     window 585.090-585.130  anchor 585.860
                                  chain  window 585.130-586.210  anchor 586.520
                                  even   window 586.210-587.070  anchor 588.160
```

The marker edge sits at 586.210 — the whisper *partition edge* where
`chain.`'s window ends and `even`'s begins. The spoken "chain." anchors at
586.52, **after** the edge. The sheet (anchors, correct) reads
`[chain is][chain. even if you smile.]`. The audio agrees with the sheet.

## 2. Why the current cut machinery cannot fix this

`vo.ApplyPadding` (VO/lib/ajsfx_vo.lua:4153) is amplitude-driven but fenced
by `t0`/`t1`:

- Span extents come from `vo.FindCandidates`: `start = words[i0].t0`,
  `stop = words[i1].t1` — partition edges. Here ChainIsChain's raw stop is
  586.210, which *excludes part of its own last word*.
- `vo.FindSpeechBounds` measures speech **inside the raw span**, so it
  cannot see the word the extent already lost.
- The stop fence is `word_start_after` (:4144) = next word's `t0` = 586.210.
  Chained exactly, so the fence collapses onto the edge;
  `extend_through_sound` (:4312) has zero room; `settle`/`QuietestBoundary`
  only reach `chained_boundary_reach`, default **0** (off, :2848).

Every guard is doing its job; the *inputs* are partition edges. Re-Identify
today reproduces the bad split exactly.

## 3. The design rule, completed

Anchors say **which** words belong to a take and **where the search windows
are**; silence says **where the edge goes**; `t0`/`t1` steer **nothing**.

Between any two adjacent takes there is now a trustworthy window: from the
earlier take's last anchor to the later take's first anchor (586.52 → 588.16
here — 1.6 s wide where the old fences gave zero). Every boundary decision
happens inside such a window, by amplitude.

## 4. Catch: `vo.CheckMarkerWords` (implemented)

Pure function, read-only, surfaced in Check and on the remote seam
(`marker_words`). For every take marker: `vo.WordsInRange` (anchor rule)
over the marker's range vs the line the marker names, normalized with the
project substitutions.

Flags, in take order:
- **extra** — a word inside the marker that the line does not contain
  (EvenIfYouSmile gains `chain.`),
- **missing** — a line word not inside the marker (ChainIsChain loses
  `chain`),
- **empty** — a marker whose range holds no words at all.

Comparison is LCS-based via the same alignment `vo.ExtraWords` uses, so a
reader stumble ("orders orders loud") flags the duplicate, not the whole
take. No auto-fix: the flag names the marker, the words, and the side
(head/tail) so the user — or the placement half below — acts on it.

## 5. Place: anchor fences in the cut path (awaiting approval)

Four changes, all in `VO/lib/ajsfx_vo.lua`:

1. **Span extents stay `t0`/`t1`** — amended at implementation. Changing
   `FindCandidates` extents would shift every overlap consumer (span
   scoring, coverage, the absorption pass's chaining tests) for no gain:
   ApplyPadding receives the word list, so it derives the anchor picture
   itself — each span's own first/last word anchors (ownership by window
   containment; a word's anchor can sit past its own window's edge, which
   is the whole disease) and the nearest neighbour anchors as fences. The
   speech-bounds window stretches to the span's own anchors, so audio the
   raw extent excluded is measured, not lost.
2. **Fences from anchors.** With a neighbour anchor in hand the fence IS
   that anchor — a point inside the neighbouring word, never chained, with
   the whole inter-take window before it. Without one (t0-fallback words),
   the old `word_end_before`/`word_start_after` + `collapsed()`/`settle()`
   path runs unchanged.
3. **Pads become room, not reach.** `extend_through_sound` walks from the
   speech bounds through contiguous sound until real silence, bounded by
   the anchor fences — the walk must be able to cross the whole inter-take
   window, so the `stop_hard = at_stop + post` cap moves: `pre`/`post`
   (and `snap_head_room`/`snap_tail_room`) clamp how much *silence* is
   kept beyond the found sound, never how far the walk may travel toward
   the fence.
4. **The dip rule for unbroken sound.** When two takes' extended edges
   cross (breath/lip noise bridges them and silence never comes), the
   shared edge is `vo.QuietestBoundary` between the two anchors — replaces
   the raw-gap midpoint rule (:4353) for this case. Symmetric, so both
   spans compute the same instant.

Worked example: ChainIsChain raw span becomes 585.06 → 586.52 (anchors).
Speech bounds find sound; the stop edge walks right through "chain."'s
remaining sound to the real silence (~587.2), + tail room 0.4 → ~587.6,
fence (anchor of `even`, 588.16) never reached. EvenIfYouSmile's head walks
left to the same silence, − head room. The split lands in the audible gap.
Every rule is the existing machinery; only its inputs and caps change.

**Blast radius:** placement changes re-derived cuts only. Existing take
markers never move (marker-is-the-row: drags are truth); the catch half +
a per-flag re-snap verb is how old markers get fixed, one confirmed flag at
a time.

## 6. Testing

Catch (implemented with this spec):
- The Chain/Even numbers verbatim: ChainIsChain flags missing "chain",
  EvenIfYouSmile flags extra "chain".
- A stumble ("orders orders loud" vs "Orders loud.") flags one extra word.
- Substitutions apply (rose/rows does not flag).
- Clean markers flag nothing; an empty range flags "empty".

Place (with its implementation):
- ApplyPadding with anchored words: chained-window fixture cuts in the dip,
  not at the partition edge; the guards.-style padded-window fixture still
  errs long.
- t0-fallback fixture (no anchors): behaviour unchanged, existing tests.
- The midpoint rule keeps ruling where a real raw gap exists.
