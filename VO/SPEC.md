# ajsfx VO — Design Spec

**Status:** Implemented, unverified in REAPER · **Version:** 0.2 · **Date:** 2026-08-01

Script-matched cut-and-name for game VO / dialogue delivery, built as two windows —
**ajsfx VO Sources** and **ajsfx VO Overview** — plus **ajsfx VO Settings**. Cutting,
pulling and sorting are panels inside Overview; the separate **ajsfx VO Cut** window was
retired in 0.13 (see `SPEC-overview.md` §7). Given a recorded session in REAPER and a CSV script that lists each line's
text and its required asset filename, cut the session into one clip per line and name
each clip with the correct asset name.

This is **not** a transcription tool. The script already exists, so the problem is
forced alignment + matching, not blind recognition. That framing drives every design
decision below: transcription is a means of locating known text, and match confidence
is measured against the script rather than reported by the recognizer.

The tool was originally one script, `ajsfx_VO_ScriptMatch.lua`, that transcribed,
matched and cut in a single run. It is now split by verb — one window transcribes, one
window judges, one window cuts — because those three had different scopes and different
lifetimes and were welded together by an artefact that mixed transcription with
matching. See `docs/superpowers/specs/2026-08-01-vo-source-manager-design.md` for the
rationale behind the split; this document describes the result.

---

## 1. Goals and non-goals

### Goals

- Read a session script from CSV with **configurable column mapping** (nothing hardcoded).
- Transcribe recorded audio locally with word-level timestamps, once per wav, independent
  of any script.
- Match each spoken span against the script's `Text` column and assign its `AudioAsset`,
  recomputed live rather than stored.
- Cut the session into named clips with their edges snapped to silence, and route them to
  **Selects / Alts / Review** tracks nested under the recording they came from.
  Routing identifies a clip by its NAME, not by the match, so it serves rendered files
  this tool never cut as well as a session it did.
- Handle real session conditions: lines out of CSV order, multiple takes of a line,
  slates, false starts, and chatter between takes.
- Report confidence; flag low-confidence and unmatched spans for review rather than
  guessing silently.
- Run **fully locally and offline** by default.
- Be ReaPack-distributable and MIT-licensed.

### Non-goals (v1)

- Speaker diarization. Sessions are one actor at a time; the CSV `Character` column is a
  *filter*, not something to be inferred from audio.
- Blind transcription as a user-facing feature.
- LLM-assisted disambiguation — deferred to v2, see §11.
- Performance/quality judgement. "Confidence" measures textual match to the script,
  never how good the read was. The tool must never imply otherwise.
- Multiple script CSVs in one project. The project file's key format is shaped so this
  can be added later, but only one script is loaded at a time in this version.
- Manual re-carving of spans by dragging word ranges.

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
user (manually, or via the opt-in Settings button described in §9).

---

## 3. Verified technical findings

These were confirmed against upstream source rather than assumed. Anything **not**
verified is marked as such in §12.

1. **Word-level timestamps require no JSON parsing.**
   > **Superseded 2026-08-11** (`SPEC-word-anchors.md`): the CSV's `start,end` are a
   > contiguous partition, not word extents, and the DTW anchors that fix this exist
   > only in `-ojf` JSON-full output. The tool now runs `-ojf` and parses it with a
   > hand-rolled reader (`vo.ParseWhisperJSON`) — still no vendored dependency.
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
   > **Corrected 2026-08-11**: true only with flash attention off. `-fa` defaults to
   > on in v1.9.1 and silently prevents DTW (every `t_dtw` = -1; verified byte-identical
   > output with/without the flag). `vo.BuildWhisperArgv` emits `-nfa` alongside `-dtw`.
   > See `SPEC-word-anchors.md` §3.

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

## 4. Data

Two files own everything the tool knows. Neither the match between them, nor the cut
plan derived from it, is ever written to disk — both are recomputed every time they are
needed.

| File | One per | Owner | Regenerable |
|---|---|---|---|
| `<audio>_vo_transcript.csv` | source wav | ajsfx VO Sources | yes — costs a whisper run |
| `<project>_vo.csv` | project | ajsfx VO Overview | **no** |

### 4.1 Transcript sidecar

`vo.TranscriptPath(source_path)` derives `<dir>/<base>_vo_transcript.csv` from
`<dir>/<base>.<ext>`, stripping the final extension only, and returns `nil` for a nil or
empty path.

```csv
ajsfx VO Transcript,1
Source,RIVA_session.wav
Source bytes,412839104
Source hash,3fa9c21e
Backend,whisper.cpp
Model,ggml-medium.en.bin
Language,en

Start,End,Text
12.480,12.660,we
12.660,12.910,should
12.910,13.040,not
```

- **Times are source-relative, in seconds**, to three decimals. The file must survive
  its item being moved, trimmed, duplicated or opened elsewhere, none of which the audio
  knows about. `vo.ProjectTimeToSource` and `vo.SourceTimeToProject` convert at the
  boundary.
- **One row per word**, written by `vo.SerializeTranscript` straight from
  `whisper-cli -ml 1 -sow -ocsv`'s own output — `-ml 1` makes every whisper segment
  exactly one word, so there is no sentence grouping to preserve or lose. Where the
  Sources detail panel wants readable prose it reassembles words with single spaces and
  starts a new paragraph after a word ending in `.`, `?` or `!` (`vo.Paragraphs`) — a
  display rule computed at read time, never stored and never consulted by matching.
- **The preamble is the staleness check.** `Source bytes` is the cheap first pass;
  `Source hash` (`vo.FileFingerprint` — a size folded with three 64 KB sample windows)
  catches an in-place edit that leaves the file the same length. `vo.TranscriptMeta`
  builds the whole block together so a writer cannot record one without the other.
  `Backend`, `Model` and `Language` are informational, shown in the Sources detail panel.

`vo.ParseTranscript(text)` returns `{ version, source, source_bytes, source_hash,
backend, model, language, words }` or `nil, reason`. A malformed sidecar is reported
inline, never thrown — a bad file next to the audio must not stop a window opening.
`vo.TranscriptState(source_path)` returns `"yes"`, `"no"`, `"stale"` or `"error"` from
the parse result plus the size/hash check.

### 4.2 Project file

`vo.ProjectFilePath(project_path)` returns `<project dir>/<project name>_vo.csv`.

```csv
ajsfx VO Project,1
Script CSV,D:\Session\script.csv
Mapping,speaker=Character;asset=Filename;text=Line Text

Key,Filename,Source,Source start,Select,Status,Name override,Notes
RIVA_session.wav|12480,vo_riva_intro_01,D:\Session\RIVA_session.wav,12.480,yes,verified,,great read
|vo_riva_deck_03,vo_riva_deck_03,,,,,,re-record next session
```

`Status` is the user-set mark and keeps its established vocabulary — `verified` or
`flagged`, anything else dropped on load (`vo.TRACKER_STATUSES`). `Select` is a separate
column rather than a third status because a take can be both selected and flagged; it is
what Cut acts on.

- **Keys** are `<basename>|<source start in ms>` for a row backed by audio, and
  `|<filename>` for a script line with no audio — `vo.OverviewKey`. A `|<filename>` row
  is how a **note on an unrecorded line** is stored; this is what the audio-only sidecar
  cannot hold, and is the reason judgements are project-scoped rather than travelling
  with the wav.
- **Only rows carrying actual user work are written** (`vo.SerializeProjectFile`).
  Clearing a row's marks removes it from the file.
- `Script CSV` and `Mapping` live in this file rather than in `ProjExtState`, so the
  project file is the whole of the project's VO state. `ProjExtState` and `ExtState`
  keep only view preferences (column widths, order, per-column presentation), which are
  about the window, not the work.

`vo.ParseProjectFile` never raises. On `nil, reason` Overview **refuses to save** and
says so in the window, rather than overwriting work it could not read.

### 4.3 Row identity

A verified flag has to survive a re-transcription that nudges a boundary by a few tens
of milliseconds. Identity is therefore tolerant, in four passes, each run over every row
before the next begins:

1. exact key, same full path — the row has not moved
2. exact key, same basename — the project moved to another drive
3. within ±0.5 s, same filename, same full path — a boundary shifted
4. within ±0.5 s, same filename, same basename — both at once

Within a pass, proximity matches are taken globally nearest-first, and each project-file
entry can be claimed by at most one row. A take moved more than 0.5 s by
re-transcription loses its mark, deliberately: past that distance it is more likely a
different piece of audio, and silently migrating a "verified" onto the wrong take is
worse than dropping it. See `VO/SPEC-overview.md` §3 for the full account, unchanged
from before this split.

---

## 5. Architecture

```
VO/
  SPEC.md                     this document
  SPEC-overview.md            the project-wide matching and judgement window
  SPEC-sources.md             the transcription window
  SPEC-cut.md                 the cutting window and boundary snapping
  ajsfx_VO_Overview.lua       package main file — matches live, owns judgements
  ajsfx_VO_Sources.lua        transcribes; owns the transcript sidecars
  ajsfx_VO_Cut.lua            cuts, routes and names; the only script that mutates
  ajsfx_VO_Settings.lua       ImGui settings, backend readiness, model fetch, snapping
  lib/ajsfx_vo.lua            all logic — pure layer + REAPER-coupled layer
  lib/ajsfx_vo_view.lua       shared ImGui table presentation
tests/
  test_vo.lua                 unit tests
  test_vo_view.lua            unit tests for the view-settings module
  fixtures/vo_sample_script.csv
```

The windows divide by verb: Sources transcribes, Overview matches, records judgements and
mutates the project. `ajsfx_VO_Overview.lua` is the ReaPack **package main file**; Sources
and Settings ship alongside it as additional `[main]` entries in its `@provides`, the same
pattern PVX uses for its own siblings:

```lua
-- @provides
--   [main] .
--   [main] ajsfx_VO_Sources.lua
--   [main] ajsfx_VO_Cut.lua
--   [main] ajsfx_VO_Settings.lua
--   lib/ajsfx_vo.lua
--   lib/ajsfx_vo_view.lua
--   ../lib/ajsfx_core.lua > lib/ajsfx_core.lua
```

`ajsfx_VO_ScriptMatch.lua` is deleted; there is no migration path from its report and
tracker formats, and the ReaPack package it defined is retired in favour of the one
`ajsfx_VO_Overview.lua` now defines. A user with the old package installed reinstalls
once and re-transcribes.

A sibling script is launched with `vo.LaunchSibling(filename)`, which wraps
`r.AddRemoveReaScript(true, 0, path, true)` — idempotent, so it both registers and
launches, and is the only supported way to reach a sibling script by path. Handoff
between windows (Overview asking Sources to focus a file) goes through
`SetExtState("ajsfx_vo", "focus_source", path)`, read every frame by Sources so an
already-open window responds too.

See `VO/SPEC-sources.md`, `VO/SPEC-overview.md` and `VO/SPEC-cut.md` for what each
window actually does.

---

## 6. Matching, live

`vo.BuildMatch(transcripts, script_lines, cfg)` is a pure function returning one
`{ path, spans }` entry per source, called by Overview whenever the script, the mapping,
or the set of loaded transcripts changes, and by Cut immediately before it runs. It is
never persisted — see §4.

### Pipeline

1. **Normalize both sides identically.** Lowercase; strip punctuation and apostrophes
   (`don't` → `dont`); expand digits to words (0–9999, ordinals, years); collapse
   whitespace; apply a user-editable substitution table. Because script and transcript
   pass through the same function, internal consistency matters more than linguistic
   correctness.

2. **Generate candidates from rare-token anchors.** An IDF-weighted inverted index over
   script tokens (`vo.BuildIndex`) supplies each line's *k* rarest tokens. Every
   occurrence of such a token in the word stream proposes a candidate window beginning at
   `hit_position − token_offset_within_line`. This avoids an O(lines × positions) scan
   while still finding lines recorded far out of order.

3. **Score each candidate.** Token-level Levenshtein over a window of ±30% of the line
   length: `score = 1 − dist / max(#line, #window)`. The runner-up line's score at the
   same position gives `margin`, which detects genuinely ambiguous near-duplicate lines.
   The winning window is then shrunk to the tightest range preserving that score, so a
   word the recognizer dropped before the anchor cannot leave a phantom token overlapping
   the previous span.

4. **Select non-overlapping spans** greedily by score (interval scheduling), tie-broken
   by margin.

5. **Classify** (`vo.Classify`):
   - `match` — `score ≥ accept_threshold` (default 0.80) **and** `margin ≥ margin_threshold` (default 0.05)
   - `review` — `score ≥ review_floor` (default 0.55)
   - otherwise the words remain unconsumed

6. **Gap sweep.** Any run of unconsumed words becomes an `unmatched`/`review` span
   (`vo.FindGaps`) — this is where slates, chatter, and false starts land, without
   needing to be modelled explicitly.

Cost is bounded by the whole project's word count; a one-hour session is on the order of
10⁴ words, the index build is linear, and the candidate search is already gated by
`vo.FindCandidates`. Overview recomputes on change, not per frame, and memoises the
result on `(script path, mapping string, sorted source path list, source bytes list)`.

**Conflicting selects across sources are expected and not an error.** Two recordings can
both carry a select for the same `Filename`; each is a separate row with its own key,
and both survive — see `VO/SPEC-cut.md` for where they land.

Boundary placement (padding and silence snapping) and the toggles that route and name
the cut clips are Cut's job — see `VO/SPEC-cut.md` §6–7.

---

## 7. Configuration

Persisted via `ExtState` section `ajsfx_vo` per `.agents/standards.md`.

**Settings panel** (`ajsfx_VO_Settings.lua`): whisper binary path, model path, threads,
DTW preset, language, accept threshold, review floor, margin threshold, boundary
snapping (`snap_boundaries`, `pre_pad`/`post_pad` as maximum reach,
`snap_min_silence`, `snap_floor_offset`, `snap_floor_window`), destination track names,
review/unmatched name prefixes, create-regions toggle, CSV column mapping presets, skip
values (default `TO RECORD`), substitution table, scratch directory, force-retranscribe,
backend readiness indicator.

The script CSV path and its column mapping are **not** here any more — they live in the
project file (§4.2), since they describe the project's work, not the machine's backend.

**Cut window** (`ajsfx_VO_Cut.lua`): the two per-session toggles below. `primary_take`
is gone — see `VO/SPEC-cut.md` §6.

| Toggle | Values | Effect |
|---|---|---|
| `suffix_alt_names` | off / on | **off:** all takes named identically (`vo_npc_greet_01`). **on:** non-selected takes get `_tk01`, `_tk02`… |

`use_alts_track` was removed in 0.13. Alts are marked per take in the Select column
rather than switched on per run — see `SPEC-overview.md` §7.

These are session-only state in the Cut window, not part of `vo.CONFIG_SCHEMA`, so they
do not persist between runs — the user's `Select` column is the persistent decision.

### The single network path

The Settings panel offers an **opt-in model download** button. As implemented it
**opens the Hugging Face model page in the user's browser** rather than downloading the
file itself: shipping an untested downloader — with its own TLS, redirect, resume and
partial-file failure modes — buys little over the browser the user already has, and the
browser makes the network operation visible rather than hidden inside a REAPER script.
The user-facing contract is unchanged. This is the only code in the tool that touches
the network at all. It is:

- never triggered automatically,
- clearly labelled in the UI as a network operation,
- concerned only with model weights — **no dialogue text or audio is ever transmitted**,
- entirely skippable by pointing Settings at a manually downloaded model.

The matching path contains no network code whatsoever.

---

## 8. Failure handling

Cut's mutations occur inside one `core.Transaction`, giving a single undo point and
automatic error reporting via `core.Error`. Everything upstream of Cut — transcribing in
Sources, matching in Overview — reads and computes only; nothing it does needs undoing.

| Condition | Behaviour |
|---|---|
| No recorded audio in the project | Sources shows "No recorded audio in this project yet."; Transcribe has nothing to act on |
| Backend not configured / binary or model missing | Inline red line in Sources/Cut naming the reason, with a `Settings…` button; Transcribe disabled |
| A transcript file cannot be parsed | Sources reports that row `error`, names the reason inline; the other rows still load |
| Audio changed since it was transcribed | Sources reports the row `stale`; Overview still matches against the (now stale) words; Cut refuses to run and names the file |
| Transcript write fails (e.g. read-only directory) | Reported inline as a warning after the batch; files that did write keep their result, and the session stays usable |
| CSV missing mapped columns | Inline message listing the headers actually found |
| Nothing is selected in Overview | Cut shows "Nothing is selected." and does not run |
| A line has several takes and none is selected | Cut lists it as needing a decision and does not run |
| Two sources both select the same `Filename` | Both are cut; each source gets its own `Selects — <basename>` track and the collision is reported inline |
| The project file cannot be parsed | Overview reports the reason inline and **refuses to save**, so the file on disk is not overwritten |
| A span's source has no item left in the project | Dropped from the cut and counted in the summary, rather than cut against silence |

---

## 9. Test plan

### Automated (headless, runs in CI)

`tests/test_vo.lua`, run by `./run_tests.sh`. Lua 5.4 is available locally and in CI.
Coverage includes the transcript sidecar (`vo.SerializeTranscript` / `vo.ParseTranscript`
round-trip and rejection cases), the project file (`vo.SerializeProjectFile` /
`vo.ParseProjectFile` round-trip including a `|<filename>` row with no audio),
`vo.BuildMatch` against parsed transcripts (including two sources matching the same
`Filename`), and boundary snapping (`vo.SnapBoundary`) against a synthetic amplitude
callback — silence found, no silence found (pad fallback, flag set), a window shorter
than `snap_min_silence`, no neighbouring word at the start of a file, and the invariant
that a boundary never crosses the neighbouring word's timestamp. The rest of the pure
layer (CSV parsing, column mapping, normalization, candidate generation, scoring,
classification, naming) is unchanged from the single-script version and stays covered
under the same names.

`tests/test_vo_view.lua` covers the view-settings module (`VO/lib/ajsfx_vo_view.lua`)
independently.

### Manual (REAPER-in-the-loop — cannot be verified headlessly)

Documented in `VO/MANUAL_TEST.md`.

---

## 10. Explicitly unverified

Stated plainly rather than assumed working. **No manual testing in REAPER has been run
for the Cut and Name, Pull and Sort panels** — they are implemented and pass the
automated suite, but have not been exercised against real audio yet. See
`VO/MANUAL_TEST.md` for the checks that would clear them.

- **whisper-cli has not been executed.** Its flags and CSV output format were read from
  upstream source (`examples/cli/cli.cpp`), not observed. The first manual test must
  confirm the actual CSV shape.
- **`-dtw` presets for the `.en` models are unverified**, so `vo.BuildWhisperArgv` emits
  the flag only for the presets confirmed against upstream source (§3.2). An
  English-only model therefore runs *without* DTW today.
- **Number readings are cardinal only.** `1999` normalizes to "one thousand nine hundred
  ninety nine", not "nineteen ninety nine". The substitution table is the documented
  override, applied before number expansion.
- **ReaImGui progress/cancel behaviour** in the async transcription runner is untested
  outside REAPER.
- **Split / move / rename correctness and undo integrity** in Cut require a real project.
- **Region creation and Region Render Matrix delivery**, including the collision
  behaviour of identically-named regions, are unverified.
- **Boundary snapping's amplitude reads** (`vo.MeasureGapRMS` via
  `CreateTakeAudioAccessor`) have not been run against real audio; the pure logic in
  `vo.SnapBoundary` is unit-tested against synthetic callbacks only.
- **The transcript-write-failure warning** (a read-only audio directory) has not been
  triggered in REAPER; see `VO/MANUAL_TEST.md`.
- **The project-file-corruption refusal-to-save path** has not been triggered in REAPER.

---

## 11. Deferred to v2 — designed for, not dismissed

- **Export** — transcript plus matched data out to CSV/SRT/whatever the delivery needs.
- **Multiple scripts in one project** — the project file's key format is shaped for it.
- **Manual re-carve** — per-row start/stop overrides in the project file, and a
  word-range drag in the Sources detail view.
- **LLM-assisted disambiguation** for spans whose top two candidates fall within the
  margin threshold. It will be **opt-in, off by default, and gated behind a first-use
  dialog** stating explicitly that dialogue text leaves the machine. The tool
  deliberately ships with **no network code in the matching path**, so there is nothing
  to enable accidentally.
- **WhisperX backend** (BSD-2-Clause) as an optional higher-accuracy path via wav2vec2
  forced alignment. Backend selection is already an indirection in `BuildWhisperArgv`.
  torch/CUDA will never become a hard requirement for using the tool.
- **ImGui review panel** for accept / reject / reassign before commit.
- **Comped and partially re-rendered sources.** A wav assembled from two recordings has
  no coherent sidecar today; it is simply a new file needing a new transcription.

---

## 12. Implementation history

The tool shipped first as one script (`ajsfx_VO_ScriptMatch.lua`), then grew a
project-wide tracking window (`ajsfx_VO_Overview.lua`) alongside it, then was split into
the three-window design this document describes. The split's rationale and task-by-task
plan are in `docs/superpowers/plans/2026-08-01-vo-source-manager.md`; its design
rationale is in `docs/superpowers/specs/2026-08-01-vo-source-manager-design.md`.

Release follows `.agents/standards.md`: `@version` and `@changelog` on every script, CI
rebuilds `index.xml` on merge to `main`. **`index.xml` is never hand-edited.**

> **Note on library indexing.** `VO/lib/ajsfx_vo.lua` and `VO/lib/ajsfx_vo_view.lua`
> carry `@noindex`. Without it, `reapack-index` publishes a shared library as its own
> installable package, which also registers it in REAPER's action list as a script that
> does nothing when run. The library still ships correctly via `ajsfx_VO_Overview.lua`'s
> `@provides`.

> **Note on branching.** `.agents/standards.md` describes a `dev` → `main` workflow, but
> `origin/dev` has historically lagged `main` significantly and carried an obsolete
> layout. VO feature work is taken from `main` directly; this is unchanged by the
> three-window split and is a standing note for the repo owner rather than something
> resolved here.
