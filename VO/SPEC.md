# ajsfx VO ScriptMatch — Design Spec

**Status:** Draft for review · **Version:** 0.1 · **Date:** 2026-07-21

Script-matched cut-and-name for game VO / dialogue delivery. Given a recorded session
in REAPER and a CSV script that lists each line's text and its required asset filename,
cut the session into one clip per line and name each clip with the correct asset name.

This is **not** a transcription tool. The script already exists, so the problem is
forced alignment + matching, not blind recognition. That framing drives every design
decision below: transcription is a means of locating known text, and match confidence
is measured against the script rather than reported by the recognizer.

---

## 1. Goals and non-goals

### Goals

- Read a session script from CSV with **configurable column mapping** (nothing hardcoded).
- Transcribe the recorded session locally with word-level timestamps.
- Match each spoken span against the script's `Text` column and assign its `AudioAsset`.
- Cut the session and route clips to **Selects / Alts / Review** tracks, named correctly.
- Handle real session conditions: lines out of CSV order, multiple takes of a line,
  slates, false starts, and chatter between takes.
- Report confidence; flag low-confidence and unmatched spans for review rather than
  guessing silently.
- Run **fully locally and offline** by default.
- Be ReaPack-distributable and MIT-licensed.

### Non-goals (v1)

- Speaker diarization. Sessions are one actor at a time; the CSV `Speaker` column is a
  *filter*, not something to be inferred from audio.
- Blind transcription as a user-facing feature.
- LLM-assisted disambiguation — deferred to v2, see §11.
- Performance/quality judgement. "Confidence" measures textual match to the script,
  never how good the read was. The tool must never imply otherwise.

---

## 2. Clean-room and licensing statement

This tool is written independently for public release under this repository's MIT
license.

**No source code, assets, or structure from TeamAudio's ReaSpeech or reaspeech-lite
(both AGPL-3.0), or from any other AGPL/GPL project, has been read, copied, adapted,
or ported.** Neither project's source was opened during design or implementation.
Every upstream tool is used as an **external dependency invoked as a separate process**
— nothing is vendored or linked.

### Runtime dependency licenses

| Dependency | Role | License | MIT-compatible | Verified |
|---|---|---|---|---|
| [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (`whisper-cli`) | Default speech backend; external binary | MIT (`Copyright (c) 2023-2026 The ggml authors`) | Yes | 2026-07-21, from repo `LICENSE` |
| ggml Whisper models (`ggml-*.bin`) | Model weights; user-supplied, **never committed** | MIT (OpenAI Whisper weights) | Yes | 2026-07-21 |
| [ReaImGui](https://github.com/cfillion/reaimgui) | Settings panel, progress UI | LGPL-3.0 | Yes — used as a REAPER extension through its public scripting API; not linked, not vendored, not redistributed. Already a dependency of existing ajsfx scripts. | 2026-07-21 |
| [WhisperX](https://github.com/m-bain/whisperX) *(optional, v2)* | Higher-accuracy forced alignment | BSD-2-Clause | Yes | 2026-07-21 |
| [faster-whisper](https://github.com/SYSTRAN/faster-whisper) *(WhisperX transitive)* | CTranslate2 Whisper runtime | MIT | Yes | 2026-07-21 |
| REAPER / ReaScript API | Host | Proprietary host application; scripting API use imposes no license terms on scripts | Yes | — |

**No copyleft dependency is vendored.** If a future requirement can only be met by a
copyleft component, it will be flagged in this document and an alternative proposed
rather than the component being bundled.

**Model weights are never committed to this repository.** They are downloaded by the
user (manually, or via the opt-in Settings button described in §7).

---

## 3. Verified technical findings

These were confirmed against upstream source rather than assumed. Anything **not**
verified is marked as such in §10.

1. **Word-level timestamps require no JSON parsing.**
   `whisper-cli -ml 1 -sow -ocsv` forces one word per segment and writes a CSV of
   `start,end,text` where times are **milliseconds** and text is RFC4180-quoted
   (doubled `"` via `escape_double_quotes_in_csv`). Setting `-ml > 0` automatically
   enables token timestamps inside the CLI. This eliminates the need for a Lua JSON
   library — and therefore an entire vendored dependency and its license question.
   *Source: `examples/cli/cli.cpp`.*

2. **`-dtw <preset>` computes token-level timestamps** via cross-attention dynamic time
   warping, improving boundary accuracy. Presets are model-specific
   (`tiny`, `base`, `small`, `medium`, `large.v1/v2/v3`), so the flag is only emitted
   when the configured model maps to a known preset.

3. **whisper.cpp resamples and downmixes internally.**
   `read_audio_data` uses miniaudio with
   `ma_decoder_config_init(ma_format_f32, mono, WHISPER_SAMPLE_RATE)`, accepting
   WAV/FLAC/MP3/Vorbis at any sample rate and converting to 16 kHz mono itself.
   **Consequence: no render step, no ffmpeg dependency, and no mutation of the user's
   project render settings.** The take's source file is fed directly to the CLI.
   *Source: `examples/common-whisper.cpp`.*

4. **`index.xml` must not be hand-edited.** Per `.agents/standards.md`, CI
   (`.github/workflows/reapack.yml`) runs the test suite and rebuilds `index.xml` via
   `reapack-index --rebuild --commit` on merge to `main`. Correct `@version`,
   `@changelog`, and `@provides` headers are what matter. A new top-level `VO/`
   directory becomes a ReaPack category automatically.

---

## 4. User-facing behaviour

### Input

Selected media item(s) on a track — the recorded session. Multiple items are supported
(a session split across several recordings on one track).

### Output

The session is **split**, and the pieces are moved down to new tracks created directly
beneath the source track:

| Track | Receives | Default name |
|---|---|---|
| **Selects** | Matched takes (all of them, or just the primary — see toggles) | `Selects` |
| **Alts** | Non-primary takes, when the Alts toggle is on | `Alts` |
| **Review** | Low-confidence matches **and** unmatched audio (slates, chatter, false starts) | `Review` |

Splitting rather than copying is deliberate: with the pieces physically removed from the
source track, it is immediately obvious what has been pulled and what has not. Every
mutation lives in a single `core.Transaction`, so the whole run is one undo step.

Clips are named by setting the take name (`P_NAME`). Non-speech silence between spans
remains on the source track.

Named **regions** over the Selects clips are available for Region Render Matrix
delivery, but are **off by default** (Settings toggle).

### The three per-session toggles

These live in the **run dialog**, not Settings, because they change from session to
session with the rhythm of the actor and director.

| Setting | Values | Effect |
|---|---|---|
| `use_alts_track` | off / on | **off:** every take goes to Selects. **on:** non-primary takes go to Alts. |
| `suffix_alt_names` | off / on | **off:** all takes named identically (`vo_npc_greet_01`). **on:** non-primary takes get `_tk01`, `_tk02`… |
| `primary_take` | `last` / `first` | Which take of a repeated line is the primary — the last read, or the first. |

Defaults are `use_alts_track = off`, `suffix_alt_names = off`, `primary_take = last`:
every take is cut and named identically, and the user auditions and deletes. Take
numbering is chronological across all matches of a line; the primary carries the bare
`AudioAsset` name whenever suffixing is on.

### Naming of flagged clips

- Low-confidence: `REVIEW_<AudioAsset>_s<score>` (e.g. `REVIEW_vo_npc_greet_01_s0.67`)
- Unmatched: `UNMATCHED_<sanitized transcript snippet>` (e.g. `UNMATCHED_take_two`)

Prefixes are configurable. All names pass through a filesystem-safe sanitizer.

---

## 5. Architecture

```
VO/
  SPEC.md                     this document
  ajsfx_VO_ScriptMatch.lua    main action
  ajsfx_VO_Settings.lua       ImGui settings, backend readiness, optional model fetch
  lib/ajsfx_vo.lua            all logic — pure layer + REAPER-coupled layer
tests/
  test_vo.lua                 unit tests
  fixtures/vo_sample_script.csv
```

`@provides` mirrors the established PVX pattern so the shared core ships alongside:

```lua
-- @provides
--   [main] .
--   lib/ajsfx_vo.lua
--   ../lib/ajsfx_core.lua > lib/ajsfx_core.lua
```

### Data flow

```
selected items ──> unique source files ──> whisper-cli (cached) ──> word CSV
                                                                       │
CSV script ──> script lines (filtered) ────────────────────────────────┤
                                                                       v
                                        BuildPlan()  [PURE — unit-tested]
                                                                       │
                                                    ┌──────────────────┴───────────┐
                                                    v                              v
                                          ApplyPlan() [REAPER]              report CSV
                                     split → move → rename → regions
```

### The pure / coupled split

The load-bearing design decision. `BuildPlan(script_lines, word_stream, cfg)` is a pure
function returning an array of span records:

```lua
{ start = 12.34, stop = 15.02,
  kind = "match" | "review" | "unmatched",
  line_id = "NPC_014", asset = "vo_npc_greet_01",
  score = 0.94, margin = 0.31, take_index = 2,
  dest = "selects" | "alts" | "review",
  name = "vo_npc_greet_01" }
```

`ApplyPlan(plan, cfg)` consumes that array and performs every REAPER mutation. All the
interesting behaviour — parsing, normalization, alignment, scoring, span selection,
duplicate grouping, routing, naming — is therefore testable headlessly with no REAPER
and no audio. This mirrors how `pvx/lib/ajsfx_pvx.lua` separates its pure helpers
(`BuildArgv`, `QuoteArg`, `BumpTakeVersion`) from its REAPER-coupled ones.

### Module API

**Pure layer**

| Function | Purpose |
|---|---|
| `vo.ParseCSV(text)` | RFC4180 parser: quoted fields, embedded commas/newlines/quotes, CRLF, BOM |
| `vo.MapColumns(header, mapping)` | Resolve configured column names to indices |
| `vo.BuildScriptLines(rows, cols, filters)` | Apply skip values and Speaker/Type filters |
| `vo.Normalize(text, subs)` | Lowercase, strip punctuation/apostrophes, expand numbers, apply substitutions |
| `vo.NumberToWords(n)` / `vo.NumberToOrdinalWords(n)` | Cardinal/ordinal expansion for 0–9999 |
| `vo.Tokenize(s)` | Whitespace tokenizer |
| `vo.ParseWhisperCSV(text)` | Word rows → `{t0, t1, text}` with ms → seconds |
| `vo.BuildWordTokens(words, cfg)` | Normalized token stream; carries each word's times onto every token it expands into |
| `vo.Opt(cfg, key)` | Config read with documented fallback (`vo.DEFAULTS`) |
| `vo.Levenshtein(a, b)` | Token-level edit distance |
| `vo.BuildIndex(lines, cfg)` | IDF-weighted inverted index over script tokens |
| `vo.FindCandidates(words, lines, index, cfg)` | Anchor-driven candidate spans with scores |
| `vo.Classify(score, margin, cfg)` | `match` / `review` / reject |
| `vo.SelectSpans(candidates, cfg)` | Non-overlapping selection |
| `vo.FindGaps(words, spans)` | Unconsumed word runs → unmatched spans |
| `vo.ApplyPadding(spans, cfg, bounds)` | Pre/post pad with neighbour and item-bound clamping |
| `vo.AssignNames(spans, cfg)` | Duplicate grouping, take numbering, routing, naming |
| `vo.SanitizeName(s, max_len)` | Filesystem-safe names |
| `vo.BuildPlan(lines, words, cfg)` | Composes all of the above |
| `vo.EscapeCSVField(s)` / `vo.FormatCSVRow(fields)` | RFC4180 output escaping |
| `vo.BuildReport(plan, lines)` | Report CSV string |
| `vo.DTWPresetForModel(path)` | Model filename → `-dtw` preset, or nil |
| `vo.BuildWhisperArgv(cfg, audio, out_prefix)` | Backend command line |

Two functions were added during implementation that this table originally lacked.
`BuildWordTokens` exists because normalization is not token-count preserving —
`"42"` is one recognizer word but two tokens — so timings must be carried onto
each expanded token or every span containing a number drifts. `Classify` was
split out of `SelectSpans` so the threshold edges are testable directly.

**REAPER-coupled layer**

| Function | Purpose |
|---|---|
| `vo.CollectSourceSpans()` | Selected items → source path, source range, playrate, position |
| `vo.MapWordsToProject(words, item_info)` | Source time → project time |
| `vo.RunWhisperAsync(...)` | Detached process, progress UI, cancel |
| `vo.EnsureTrackBelow(track, name)` | Create-or-reuse destination track |
| `vo.ApplyPlan(plan, cfg)` | Split, move, rename, optional regions |

---

## 6. Matching approach

Global word-stream matching, **not** silence-splitting. Silence detection cannot
distinguish a take boundary from a dramatic pause; the transcript can. Segmentation is
therefore a *result* of matching rather than an input to it.

### Pipeline

1. **Transcribe per unique source file.** Each selected item's take source is
   transcribed once. Words are mapped into project time per item, keeping only words
   whose midpoint falls inside that item's visible source range; the results are merged
   into one project-ordered word stream.

2. **Normalize both sides identically.** Lowercase; strip punctuation and apostrophes
   (`don't` → `dont`); expand digits to words (0–9999, ordinals, years); collapse
   whitespace; apply a user-editable substitution table. Because script and transcript
   pass through the same function, internal consistency matters more than linguistic
   correctness.

3. **Generate candidates from rare-token anchors.** An IDF-weighted inverted index over
   script tokens supplies each line's *k* rarest tokens. Every occurrence of such a
   token in the word stream proposes a candidate window beginning at
   `hit_position − token_offset_within_line`. This avoids an O(lines × positions) scan
   while still finding lines recorded far out of order.

4. **Score each candidate.** Token-level Levenshtein over a window of ±30% of the line
   length: `score = 1 − dist / max(#line, #window)`. The runner-up line's score at the
   same position gives `margin`, which detects genuinely ambiguous near-duplicate lines.

   The winning window is then **shrunk to the tightest range preserving that score**.
   A candidate's start is derived from its anchor's offset within the line, so any word
   the recognizer drops *before* the anchor pushes the start one token early — onto the
   tail of the previous line. Left un-trimmed that phantom token overlaps the preceding
   span, and step 5 rejects the whole line for overlapping. A shorter window scoring the
   same is strictly better regardless: it excludes audio that is not part of the line,
   which tightens the cut as well as the match.

5. **Select non-overlapping spans** greedily by score (interval scheduling), tie-broken
   by margin.

6. **Classify:**
   - `match` — `score ≥ accept_threshold` (default 0.80) **and** `margin ≥ margin_threshold` (default 0.05)
   - `review` — `score ≥ review_floor` (default 0.55)
   - otherwise the words remain unconsumed

7. **Gap sweep.** Any run of unconsumed words becomes an `unmatched` span — this is
   where slates, chatter, and false starts land, without needing to be modelled
   explicitly.

8. **Refine boundaries.** Start = first aligned word start − `pre_pad` (default 150 ms);
   end = last aligned word end + `post_pad` (default 250 ms). Clamped so neighbouring
   spans never overlap and never cross the containing item's bounds.

9. **Group duplicates.** Spans sharing a `line_id` are sorted chronologically and
   numbered `take_index` 1..N. The primary is chosen per `primary_take`, then routing
   and naming follow the three toggles.

### Transcription caching

Keyed by source path + file size + model + whisper parameters, stored in
`<project>/vo_scratch/`. Re-running after a threshold change is instant. This is what
makes threshold iteration practical, and it is the reason the audio stage is cleanly
separated from the matching stage. A force-retranscribe toggle bypasses it.

---

## 7. Configuration

Persisted via `ExtState` section `ajsfx_vo` per `.agents/standards.md`; the per-project
script CSV path uses `SetProjExtState`.

**Settings panel** (`ajsfx_VO_Settings.lua`): whisper binary path, model path, threads,
DTW preset, language, accept threshold, review floor, margin threshold, pre/post pad,
destination track names, review/unmatched name prefixes, create-regions toggle, CSV
column mapping, skip values (default `TO RECORD`), substitution table, scratch
directory, force-retranscribe, backend readiness indicator.

**Run dialog** (`ajsfx_VO_ScriptMatch.lua`): script CSV picker (remembered per project),
Speaker/Type filter, and the three per-session toggles.

### The single network path

The Settings panel offers an **opt-in model download** button that fetches a ggml model
from Hugging Face. This is the only code in the tool that touches the network. It is:

- never triggered automatically,
- clearly labelled in the UI as a network operation,
- concerned only with model weights — **no dialogue text or audio is ever transmitted**,
- entirely skippable by pointing Settings at a manually downloaded model.

The matching path contains no network code whatsoever.

---

## 8. Failure handling

Transcription completes **before** any project mutation, so cancelling or failing leaves
the project untouched. All mutations occur inside one `core.Transaction`, giving a
single undo point and automatic error reporting via `core.Error`.

| Condition | Behaviour |
|---|---|
| No items selected | Message box; no mutation |
| Backend not configured / binary or model missing | Message box pointing at Settings; no mutation |
| Take is MIDI or empty, playrate ≠ 1.0, or reversed | Item skipped and listed in the report; run continues |
| whisper exits non-zero | Show tail of log; abort before mutation |
| Zero words transcribed | Abort with message |
| CSV missing mapped columns | Message listing the headers actually found |
| No span clears the review floor | Report still written; only the Review track is created |
| User cancels transcription | Nothing committed |
| Span crosses an item boundary | Clamped to the containing item; noted in the report |

### Report

Always written, next to the project. One row per span — start, stop, kind, LineID,
AudioAsset, score, margin, take_index, destination, transcript, script text — plus a
trailing section listing script lines that received **no** match at all (the "did we
actually record everything?" check). This report is also the designed input for the
deferred LLM pass.

---

## 9. Test plan

### Automated (headless, runs in CI)

`tests/test_vo.lua`, following the harness style of `tests/test_pvx.lua`, run by
`./run_tests.sh`. Lua 5.4 is available locally and in CI.

The central technique is a **synthetic transcript generator**: given the sample script
CSV, it emits a word stream with deterministic (fixed-seed) noise — dropped words,
substituted words, injected slates, repeated takes, and shuffled line order. This
exercises the entire matching pipeline against known ground truth with no audio and no
REAPER, and turns threshold changes into a regression test.

Coverage:

- **CSV parsing** — quoted fields, embedded commas, embedded newlines, doubled quotes, CRLF, BOM, ragged rows
- **Column mapping** — configurable names, missing-column errors, header whitespace
- **Filtering** — `TO RECORD` skipping, Speaker and Type filters
- **Normalization** — case, punctuation, apostrophes, digits→words both directions, substitution table
- **Whisper CSV parsing** — ms→seconds, quoted text, empty rows
- **Levenshtein / scoring** — identical, disjoint, single edit, boundary lengths
- **Candidate generation** — out-of-order lines, near-duplicate lines, rare-anchor selection
- **Span selection** — overlap rejection, score/margin tie-breaks
- **Gap sweep** — slates and chatter become unmatched spans
- **Pad clamping** — neighbour collisions, item-bound collisions
- **Duplicate handling** — take numbering and naming/routing across **all eight** toggle combinations
- **Classification** — accept/review/unmatched threshold edges, low-margin ambiguity
- **Name sanitization** — path separators, reserved characters, length
- **Report generation** — row shape, unmatched-lines section
- **`BuildPlan` end-to-end** — synthetic session with out-of-order lines, two takes of one line, a slate, and chatter

### Manual (REAPER-in-the-loop — cannot be verified headlessly)

Documented separately in `VO/MANUAL_TEST.md`, with a sample dataset: a six-line script
CSV including one `TO RECORD` row, one line to be recorded twice, and two speakers.
Procedure: record yourself reading the lines **out of order, with a slate and chatter
between takes**, then run the tool and verify Selects / Alts / Review contents against
an expected table, for each toggle combination. Includes undo integrity, region
creation, and a Region Render Matrix delivery check.

---

## 10. Explicitly unverified

Stated plainly rather than assumed working:

- **whisper-cli has not been executed.** Its flags and CSV output format were read from
  upstream source (`examples/cli/cli.cpp`), not observed. The first manual test must
  confirm the actual CSV shape.
- **`-ot` / `-d` offset semantics are unconfirmed** — specifically whether reported
  timestamps are absolute to the file start or relative to the offset. v1 sidesteps this
  by transcribing whole source files and filtering words by item range. If range-limited
  transcription is added later, this must be verified first.
- **ReaImGui progress/cancel behaviour** in the async runner is untested outside REAPER.
- **Split / move / rename correctness and undo integrity** require a real project.
- **Region creation and Region Render Matrix delivery** require a real project.
- **Collision behaviour of identically-named regions** in the Render Matrix is expected
  to append `-01`, `-02` to output files, but is unverified.
- **`-dtw` presets for the `.en` models are unverified**, so `BuildWhisperArgv` emits the
  flag only for the presets confirmed against upstream source (§3.2). An English-only
  model therefore runs *without* DTW — less precise word boundaries, but it runs, which
  is the right failure direction given an unknown preset makes whisper-cli abort. Confirm
  the `.en` preset names in the first manual test and widen the table if they hold.
- **Number readings are cardinal only.** `1999` normalizes to "one thousand nine hundred
  ninety nine", not "nineteen ninety nine", and the recognizer will usually produce the
  latter. Year and other non-cardinal readings are not guessed; the substitution table is
  the documented override, which is why substitutions are applied *before* number
  expansion. Whether game VO scripts contain enough bare years to justify a year heuristic
  is a judgement call for the repo owner, not something to infer.

---

## 11. Deferred to v2 — designed for, not dismissed

- **LLM-assisted disambiguation** for spans whose top two candidates fall within the
  margin threshold. The report's ambiguity rows are precisely the payload such a pass
  would consume, so the extension point already exists. It will be **opt-in, off by
  default, and gated behind a first-use dialog** stating explicitly that dialogue text
  leaves the machine. v1 deliberately ships with **no network code in the matching
  path**, so there is nothing to enable accidentally.
- **WhisperX backend** (BSD-2-Clause) as an optional higher-accuracy path via wav2vec2
  forced alignment. Backend selection is already an indirection in `BuildWhisperArgv`.
  torch/CUDA will never become a hard requirement for using the tool.
- **ImGui review panel** for accept / reject / reassign before commit.
- **Shared async-subprocess runner.** v1 keeps its own copy in `VO/lib/ajsfx_vo.lua`
  rather than refactoring PVX's working `RunPVXAsync` without REAPER testing available.
  This is **known, deliberate duplication**, to be resolved by extracting a shared
  runner once both are exercised in REAPER.

---

## 12. Implementation phases

1. ~~**Groundwork**~~ — *done.* Feature branch `feature/vo-script-match`; added the
   missing MIT `LICENSE` (`README.md` linked to one that did not exist); wrote this spec.
2. ~~**Pure layer, test-first**~~ — *done.* `VO/lib/ajsfx_vo.lua` + `tests/test_vo.lua`
   (161 tests) + `tests/fixtures/vo_sample_script.csv`. Every function in the pure-layer
   table above is implemented and covered, including all eight toggle combinations and a
   deterministic synthetic-transcript generator driving `BuildPlan` end-to-end.
3. **Backend + Settings** — argv builder, async runner, cache, Settings panel.
4. **Apply layer + main action** — track creation, split/move/rename, optional regions,
   run dialog wiring, report.
5. **Docs** — README section, `VO/MANUAL_TEST.md`, sample dataset.

Release follows `.agents/standards.md`: `@version` and `@changelog` on every script,
CI rebuilds `index.xml` on merge to `main`. **`index.xml` is never hand-edited.**

> **Note on library indexing.** `VO/lib/ajsfx_vo.lua` carries `@noindex`. Without it,
> `reapack-index` publishes a shared library as its own installable package — `index.xml`
> currently lists `pvx/lib/ajsfx_pvx.lua` as a `pvx/lib` package with `main="main"`, which
> also registers the library in REAPER's action list as a script that does nothing when
> run. The library still ships correctly via the main script's `@provides`. The existing
> `pvx/lib` package is left alone deliberately: it is already published, so removing it
> would withdraw a package from users who have it installed — a call for the repo owner,
> not a drive-by fix.

> **Note on branching.** `.agents/standards.md` describes a `dev` → `main` workflow, but
> `origin/dev` is currently **68 commits behind `main`** and still carries the obsolete
> `scripts/` layout from before the `Items/` / `Track/` / `lib/` / `pvx/` split — its
> test suite does not even run against the current tree. This branch was therefore taken
> from `main`. Either `dev` should be reset to `main` or the documented workflow updated;
> flagged for the repo owner rather than decided here.
