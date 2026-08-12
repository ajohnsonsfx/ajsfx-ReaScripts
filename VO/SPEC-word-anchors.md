# ajsfx VO — Word anchors: `t_dtw` carries the words, the envelope carries the edge

**Status:** Approved · **Date:** 2026-08-11

One change of principle, three changes of code: whisper's word *windows*
(`t0`/`t1`) stop deciding which words a range holds, because they cannot;
whisper's DTW *anchors* (`t_dtw`) take over that job, because measurement says
they can; and the amplitude machinery keeps sole ownership of where a cut edge
goes, because nothing else measured comes close.

---

## 1. The complaint

A take of the line "You." displayed its transcript as "tower is". The take was
*assigned* correctly — the marker, the filename, the row were all right — and
the words shown under it belonged to the neighbouring read.

`vo.WordsInRange` decides membership by onset: a word is in `[from, to)` when
its `t0` is. For the marker at source 428.593–429.894, whisper had stamped:

```
428.160  428.920  you      t0 before the marker -> excluded
428.920  429.890  tower    t0 inside            -> included
429.890  430.990  is       t0 inside by 4ms     -> included
```

The audible "You" runs 428.593–429.894. Whisper's window for it had already
*ended* before most of the word was spoken.

## 2. Why no rule over `t0`/`t1` can work

`-ml 1` makes whisper emit one word per segment, and segments are contiguous:
a word's `start` is the previous word's `end` — the beginning of the preceding
pause, not of the word. The word sits *somewhere* inside its window, and after
a long pause it can sit **past the window's end entirely**: a fresh decode of
the same session stamps take 3's `Tower` at 429.060–430.230 while the audible
word starts ~430.26. The window closes before the word opens.

This is displacement, not imprecision, and it is why the history here looks
the way it does: a midpoint rule shipped and failed on `guards.` (word at the
window's start), the onset rule shipped and failed on `you` (word at the
window's end). Overlap fails too — `tower`'s window overlaps the "You." marker
by 100% of itself. Two anchors failing in opposite directions is the tell that
the input is broken, not the rule.

## 3. The lever: DTW anchors, and why they were silently off

whisper.cpp can compute token-level timestamps by dynamic time warping over
the decoder's cross-attention (`-dtw <preset>`): one point per token that sits
*on* the word, not a partition of the timeline. This tool has passed `-dtw`
since the beginning — and it has never done anything, because **flash
attention (`-fa`, default on in v1.9.1) never materialises the attention
matrix DTW aligns against.** The flag parses, the run succeeds, every `t_dtw`
comes back -1. `-nfa` turns it back on.

Measured on the Grumbar session (39 min, 1618 words, ggml-large-v3):

- **100% of words carry an anchor, strictly monotonic, zero inversions.**
- The failing take: `You` anchors at 428.660 — 67ms from the audible onset,
  inside the marker. `tower` anchors at 430.640 — outside it. The bug's
  input is simply correct now.
- Decode cost: ~1m00s → ~1m20s for the full session. Accepted.
- `t_dtw` from an `-ot` offset run is in absolute source time (verified:
  428.66 from a 415s-offset decode), so gap-repair merges need no conversion.
- `-nfa` also changes decoded *words*, deterministically (two FA-on runs are
  byte-identical). Mixed against the script — "stone" improves, "Rows"
  regresses to "Rose" — a wash handled where it always was: substitutions.

Scored against the project's 289 real cuts (51 hand-trimmed) — *does the
audio inside the cut transcribe to exactly some script line?*:

| membership rule | all | hand-trimmed |
|---|---|---|
| sidecar `t0` (production) | 49.1% | 51.0% |
| fresh decode `t0` | 21.8% | 17.6% |
| fresh decode **`t_dtw`** | **54.7%** | **54.9%** |

The sidecar's cuts were generated *from* its own numbers and it still loses.
Most remaining misses are label/scope noise (slate audio under a line's
marker, items holding several takes), not timing. And an edge-tolerance sweep
is monotonically harmful (54.7% at 0ms → 36.7% at ±500ms): **anchors are
sharp; never fuzz them.**

## 4. What anchors must never do: place edges

The other half of the measurement kills the tempting shortcut. On the 158
cuts whose audio matches a line, the human edge sits:

- head: median **0.538s** before the first word's anchor (p10 0.100, p90 1.980)
- tail: median **0.948s** after the last word's anchor (p10 0.290, p90 1.645)

— inside inter-take gaps of ~2.0s. No arithmetic on anchors (constant pad,
half-gap, gap-fraction) predicts the cut better than median error 0.39s with
p90 over 1.3s. Where the edge goes inside two seconds of room tone depends on
breath, lip noise, and taste — only the waveform knows. The silence machinery
(`vo.MeasureNoiseFloor`, `vo.FindSpeechBounds`, `vo.QuietestBoundary`,
`vo.ApplyPadding`) is not overkill; it is the only component that can do this
job, and it keeps it.

**The rule: anchors answer *which words*; the envelope answers *where the
edge goes*; neither answers the other's question.** `t0`/`t1` remain only as
generous span extents on the cut side, where erring long is the standing
policy and the amplitude pass fixes the edges anyway.

(Free observation for defaults: the human leaves ~2× the room after a read
that they leave before it. Padding should not be symmetric — `pre_pad` 0.3 /
`post_pad` 0.6 already agrees.)

## 5. The changes

### 5.1 Invocation — `vo.BuildWhisperArgv`

`-ocsv` becomes `-ojf` (JSON full — the only output that carries `t_dtw`).
`-nfa` is emitted **iff** `-dtw` is: a model with no DTW preset gains no
anchors and keeps flash attention's speed. Callers that opened `<prefix>.csv`
open `<prefix>.json`. A stale `.csv` beside a wav is no longer a decode cache.

### 5.2 Parsing — `vo.ParseWhisperJSON`

A minimal hand-rolled JSON reader (house style; the repo vendors nothing).
With `-ml 1` a segment IS a word: `t0`/`t1` from `offsets` (ms → s), `text`
trimmed, and `anchor` = the smallest `t_dtw`/100 across the segment's tokens,
skipping special tokens (`[_...]`) and `t_dtw < 0`. No qualifying token →
`anchor = nil`. `vo.ParseWhisperCSV` remains for the legacy shape but has no
production caller.

### 5.3 Sidecar v2

Header gains a 4th column: `Start,End,Text,Anchor` (empty when nil), version
bumps to **2**. Version matching stays exact: a v1 sidecar reads as
"Unsupported transcript version" and the Sources window's existing unreadable-
sidecar row offers the re-transcribe. Deliberate hard cutoff — an anchor-less
transcript reproduces exactly the bug this spec exists to kill, and
re-transcribing costs ~1.5 minutes.

### 5.4 Membership — `vo.WordsInRange`

The membership point becomes `w.anchor or w.t0`; the half-open `[from, to)`
stays. The `t0` fallback covers anchor-less words (no DTW preset for the
model), degrading to today's behaviour, never worse. `vo.PlanDuplicateMarkers`
judges duplicates through this same function and improves for free — the
"one rule, or a marker dies on evidence the user never saw" invariant holds.

### 5.5 No more confident wrongness — `vo.TranscriptForRange`

The span-concatenation fallback (whole neighbouring spans' text for a partial
range — the original §1 bug of SPEC-range-transcript.md, kept alive for
callers without word lists) is removed. No words → `nil` → empty text on the
row. Production always has words: the Overview builds its word lists from the
same transcripts matching requires.

## 6. Testing

Against the mock harness (`./run_tests.sh`):

1. `ParseWhisperJSON`: real `-ojf` fixture — escapes, special tokens,
   a `t_dtw = -1` token, a multi-token word taking the min, empty segments
   dropped, anchor nil when no token qualifies.
2. `BuildWhisperArgv`: `-ojf` present and `-ocsv` absent; `-nfa` present
   exactly when `-dtw` is; `-ot`/`-d` span behaviour unchanged.
3. Sidecar: v2 round-trip with and without anchors; a v1 file rejects as
   unsupported; a v3 file rejects.
4. `WordsInRange`: the real "You." numbers — `you` (t0 428.16, anchor
   428.66) IS in 428.593–429.894 and `tower` (anchor 430.64) is NOT; the
   `guards.` case still passes through the t0 fallback; half-open boundary
   unchanged.
5. `TranscriptForRange`: no word list → nil, not span text.
6. `MergeRepairWords`: anchors survive the merge untouched.

In REAPER (MANUAL_TEST.md): re-transcribe Grumbar, confirm the 4-column
sidecar, and confirm the take at source 428.593–429.894 reads **"You."** —
the original complaint — with its TowerIsMouth neighbours still correct.
