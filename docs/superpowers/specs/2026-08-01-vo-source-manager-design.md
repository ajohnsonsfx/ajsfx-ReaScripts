# VO — split ingest into Sources, Overview and Cut

**Date:** 2026-08-01
**Branch:** `feature/vo-source-manager`
**Scope:** `VO/` in full. Replaces `ajsfx_VO_ScriptMatch.lua`, rewrites what the
sidecar contains, moves matching out of the ingest step and into a live
derivation, and adds amplitude-aware boundary snapping.

**No backwards compatibility.** The tool has no users and no data worth
preserving. Old sidecars and trackers are neither read nor migrated.

---

## 1. Problem

`ajsfx_VO_ScriptMatch.lua` is three tools in one file: it transcribes, it
matches against a script, and it cuts. The three have different scopes,
different lifetimes and different owners, and they are welded together by a
single artefact — `<audio>_vo_report.csv` — that stores transcription and
matching baked into the same rows.

That welding causes the problems actually being solved here:

1. **A source is never simply "transcribed."** It is "transcribed against
   script X with mapping Y." Loading a different CSV invalidates work that had
   nothing to do with the script.
2. **Whisper's segment boundaries are stored as if they were line boundaries.**
   They are not. The recogniser guesses sentences; the script says where lines
   actually divide. Storing the guess means the script can never re-carve.
3. **There is no view of the project's audio as audio.** The user cannot ask
   "which of these recordings have I transcribed?" without loading a script.
4. **Cutting is entangled with ingest**, so re-cutting means re-entering the
   transcription dialog.

---

## 2. Goals

1. Transcription is a fact about a wav file and is stored beside it. Copying
   the wav and its sidecar into a new project means never re-transcribing.
2. Matching is derived live from (words + script) and is never persisted as an
   ingest artefact.
3. The user's judgements — selects, verified flags, notes, name overrides — are
   project work and live in one project file.
4. One window per verb: list the files, see the script, cut the result.
5. Boundaries land in silence, never inside a neighbouring word.

### Non-goals

- Multiple script CSVs in one project. The project file is shaped so this can
  be added (§4.2 keys carry a script id), but only one script is loaded at a
  time in this version.
- Manual re-carving of spans by dragging word ranges. §7 shapes for it.
- Speaker diarization, LLM disambiguation, performance judgement — unchanged
  non-goals from `VO/SPEC.md` §1.

---

## 3. Scripts

| Script | Owns | ReaPack |
|---|---|---|
| `ajsfx_VO_Overview.lua` | The script CSV, the matched view, every user judgement. The front door. | **package main file** |
| `ajsfx_VO_Sources.lua` | One row per source wav in the project. Transcribe / re-transcribe. Per-file detail. | `[main]` provided |
| `ajsfx_VO_Cut.lua` | Cuts, routes and names the selected takes. | `[main]` provided |
| `ajsfx_VO_Settings.lua` | Backend, model, paths, snapping knobs. | `[main]` provided |
| `VO/lib/ajsfx_vo.lua` | All pure logic, shared. | provided |
| `VO/lib/ajsfx_vo_view.lua` | Shared ImGui table presentation. | provided |

`ajsfx_VO_ScriptMatch.lua` is deleted. Making Overview the package main file
means ReaPack drops the old package and adds a new one; users reinstall once.
This is stated in the `@changelog`.

### 3.1 Launching a sibling script

```lua
local id = r.AddRemoveReaScript(true, 0, path, true)   -- idempotent
if id and id ~= 0 then r.Main_OnCommand(id, 0) end
```

`AddRemoveReaScript` returns the existing command ID when the script is already
registered, so this both installs and launches. It is the only supported way to
reach a sibling script by path; a hardcoded `_RS…` command ID is machine-local
and must not be used. `vo.LaunchSibling(filename)` wraps it, resolving the path
from `debug.getinfo`, and returns `false, reason` if registration fails so the
caller can show an inline error rather than failing silently.

### 3.2 Handoff between windows

`SetExtState("ajsfx_vo", "focus_source", path)` is written before launching
Sources. Sources reads it every frame, and on a non-empty value scrolls to and
selects that row, then clears the key. Reading every frame rather than once at
launch means an already-open Sources window responds too.

---

## 4. Data

Three layers, three owners, two files.

| Layer | File | Owner | Regenerable |
|---|---|---|---|
| **Words** | `<audio>_vo_transcript.csv`, one per source wav | Sources | yes — costs a whisper run |
| **Expected** | the script CSV | the production | n/a |
| **Judgements** | `<project>_vo.csv`, one per project | Overview | **no** |

The match is in neither file. It is computed from words + script every time it
is needed, and cached in memory keyed by (script path, mapping, source set).

### 4.1 Transcript sidecar

For `<dir>/<base>.<ext>` the sidecar is `<dir>/<base>_vo_transcript.csv`.
`vo.TranscriptPath(source_path)` returns it, stripping the final extension only,
and `nil` for nil or empty input.

```csv
ajsfx VO Transcript,1
Source,RIVA_session.wav
Source bytes,412839104
Backend,whisper.cpp
Model,ggml-medium.en.bin
Language,en

Start,End,Text,Segment
12.480,12.660,we,0
12.660,12.910,should,0
12.910,13.040,not,0
```

- **Times are source-relative, in seconds**, to three decimals. The file must
  survive its item being moved, trimmed, duplicated or opened elsewhere, none
  of which the audio knows about. `vo.ProjectTimeToSource` and
  `vo.SourceTimeToProject` (already present, `ajsfx_vo.lua:1662`) convert at
  the boundary.
- **One row per word.** `whisper-cli -ml 1 -sow -ocsv` already emits exactly
  this, so writing it is a passthrough, not extra work.
- **`Segment`** is whisper's own segment index, carried as a hint only. Nothing
  in matching may treat it as a line boundary — that is the mistake this
  rewrite exists to undo. It is retained because it is free and is useful when
  displaying raw transcript text in the detail view.
- **Preamble** records what produced the words. `Source bytes` is the staleness
  check. `Backend`, `Model` and `Language` are informational, shown in the
  detail view so the user can see a file was done on the small model.

`vo.SerializeTranscript(words, meta)` writes it; `vo.ParseTranscript(text)`
returns `{ version, source, source_bytes, backend, model, language, words }` or
`nil, reason`. A malformed sidecar is reported inline, never thrown: a bad file
next to the audio must not stop a window opening.

`vo.SerializeSidecar`, `vo.ParseSidecar`, `vo.PartitionPlanBySource`,
`vo.MergeSidecarSpans` and `vo.SidecarPath` are deleted.

### 4.2 Project file

`<project dir>/<project name>_vo.csv`. `vo.ProjectFilePath()` returns it.

```csv
ajsfx VO Project,1
Script CSV,D:\Session\script.csv
Mapping,speaker=Character;asset=Filename;text=Line Text

Key,Filename,Source,Source start,Select,Verified,Name override,Notes
RIVA_session.wav|12480,vo_riva_intro_01,D:\Session\RIVA_session.wav,12.480,yes,yes,,great read
|vo_riva_deck_03,vo_riva_deck_03,,,,,,re-record next session
```

- **Keys** are `<basename>|<source start in ms>` for a row backed by audio, and
  `|<filename>` for a script line with no audio. This is `vo.OverviewKey`,
  unchanged (`ajsfx_vo.lua:1724`).
- A `|<filename>` row is how a **note on an unrecorded line** is stored. This
  is what the audio-only sidecar could not hold and is the reason judgements
  are project-scoped.
- **Only rows carrying actual user work are written.** Clearing a row's marks
  removes it from the file.
- `Script CSV` and `Mapping` move out of `ProjExtState` and into this file, so
  the project file is the whole of the project's VO state. `ProjExtState` keeps
  only view preferences (column widths, order, per-column presentation), which
  are about the window, not the work.
- **A `Script id` column is reserved but unused in this version.** When
  multiple scripts land, keys become script-scoped without a format break.

`vo.ParseProjectFile` never raises. On `nil, reason` Overview **refuses to
save** and says so in the window, rather than overwriting work it could not
read.

### 4.3 Row identity

Unchanged from `VO/SPEC-overview.md` §3 — four tolerant passes (exact key +
full path, exact key + basename, ±0.5 s + full path, ±0.5 s + basename),
globally nearest-first within a pass, each entry claimable once. Re-transcribing
a recording must not cost a checkmark, and word-level storage makes small
boundary movement *more* likely, not less, so the tolerance matters more here
than it did before.

---

## 5. Matching, live

`vo.BuildMatch(words_by_source, script_lines, cfg)` is a pure function returning
the same span shape `vo.BuildPlan` returns today. It is called by Overview
whenever the script, the mapping, or the set of loaded sidecars changes, and by
Cut immediately before it runs. It is never persisted.

The existing pipeline is reused wholesale — `vo.BuildWordTokens`,
`vo.BuildIndex`, `vo.FindCandidates`, `vo.SelectSpans`, `vo.Classify`,
`vo.AssignNames` are unchanged. The change is upstream of them: word tokens now
come from a parsed sidecar rather than from a whisper run, and downstream of
them: the result goes to the screen rather than to a file.

Cost is bounded by the whole project's word count. A one-hour session is on the
order of 10⁴ words; the index build is linear and the candidate search is
already gated by `vo.FindCandidates`. It is recomputed on change, not per
frame, and the result is memoised on a key of `(script path, mapping string,
sorted source path list, source bytes list)`.

**Conflicting selects across sources are expected and not an error.** Two
recordings can both carry a select for the same `Filename`; each is a separate
row with its own key, and both survive. §6.3 says where they land.

---

## 6. Windows

### 6.1 VO Sources

One row per distinct source path among the project's media items —
`vo.ProjectSourcePaths(items)` (`ajsfx_vo.lua:3287`), already present.

| Column | Content |
|---|---|
| File | Basename. Full path on hover. |
| Transcribed | `yes` / `no` / `stale` |
| Words | Word count from the sidecar |
| Length | Source duration |
| Model | From the sidecar preamble |
| Items | How many project items reference this source |

`stale` means the sidecar parsed but `Source bytes` no longer matches the file
on disk. A stale sidecar still loads and still shows its words; it is Cut that
refuses to act on it (§6.3).

Selecting rows and pressing **Transcribe** runs whisper over them. The label is
`Re-transcribe` when every selected row is already `yes`, matching the existing
rule in `vo.SourcesNeedingTranscription`. Runs are sequential, with the existing
async progress reporting from `vo.RunWhisperAsync`.

**Double-clicking a row opens the detail panel** in the same window — a split
below or beside the list, not a new script. It shows the preamble, the raw
transcript as flowing text grouped by whisper segment, per-word timings on
hover, and a `Re-transcribe this file` button. Clicking a word moves the edit
cursor to that position in the first project item referencing the source.

Backend-not-ready is an inline state with the reason and a button that launches
Settings. No message boxes.

### 6.2 VO Overview

Unchanged in shape from `VO/SPEC-overview.md` §4 — one unified table, one row
per script line per take, orphans last. Changes:

- Statuses derive from `vo.BuildMatch` rather than from parsed sidecars.
- **Top bar gains `Sources…` and `Cut…`**, each launching its script via
  `vo.LaunchSibling`.
- **Double-clicking a Source cell** launches Sources focused on that file
  (§3.2).
- **A `Select` column** replaces the old `Primary` column. It is the user's
  explicit choice of take, and it is what Cut acts on.
- Script CSV path and mapping are loaded from and saved to the project file.

### 6.3 VO Cut

A small run dialog, launched from Overview, acting on rows marked `Select`.

| Toggle | Values | Effect |
|---|---|---|
| `use_alts_track` | off / on | **off:** every take to Selects. **on:** non-selected takes to Alts. |
| `suffix_alt_names` | off / on | **on:** non-selected takes get `_tk01`, `_tk02`… |

**`primary_take` is deleted.** It existed to guess which take the user meant;
the `Select` column now says so explicitly. A line with no select and several
takes is reported as needing a decision, and is not cut.

Cut is disabled while any loaded sidecar is `stale`, with the file named
inline. Routing, `vo.EnsureTrackBelow`, `vo.ApplyPlan` and the transaction
wrapper are unchanged.

**Two sources both selecting the same `Filename`** produce two clips with the
same name. Normally there is one `Selects` track. When and only when a name
collision exists, the colliding sources get one track each, named
`Selects — <basename>`, and the collision is reported inline. Neither clip is
dropped and neither is renamed; the user decides which is the keeper.

---

## 7. Boundary snapping

Replaces the fixed `pre_pad` / `post_pad` behaviour in `vo.ApplyPadding`
(`ajsfx_vo.lua:892`).

### Rule

For a span's start boundary, the search window is `[prev_word_end,
first_word_start]`, clamped to at most `pre_pad` seconds of reach. For the stop
boundary it is `[last_word_end, next_word_start]`, clamped to `post_pad`. Where
there is no neighbouring word — start of file, end of file, a gap longer than
the pad — the pad itself bounds the reach.

Within that window, walk outward from the word and place the boundary at the
first point where RMS amplitude stays below the noise floor for at least
`snap_min_silence` milliseconds. If no such point exists, fall back to the full
pad and set the span's in-memory `snapped` field to `pad` (otherwise `silence`)
so Cut's inline report can say why an edge sits where it does. This is a field
on the computed span, not a persisted column — nothing about the match is
written to disk.

The window is derived from the neighbouring **words**, so a boundary
structurally cannot enter the next line's audio regardless of what the
amplitude does. That is the whole reason the transcript bounds the search
rather than the amplitude alone.

### Noise floor

Measured, not fixed. On first snap for a source, sample the quietest
`snap_floor_window` (default 500 ms) across the file's existing inter-word gaps
and take its RMS; the floor is that value plus `snap_floor_offset` dB (default
+6). Cached per source for the session. A fixed −60 dBFS fails on a noisy room
and on a very clean one in opposite directions.

### Sample access

`vo.MeasureGapRMS(take, t0, t1, cfg)` uses `reaper.CreateTakeAudioAccessor` and
`reaper.GetAudioAccessorSamples` into a `reaper.new_array`, reading only the
window. Total read per session is bounded by (number of spans × 2 × pad
seconds), a few seconds of audio for a full session. The accessor is created
once per take and destroyed with `DestroyAudioAccessor` in the same scope,
including on the error path.

### Settings

| Key | Default | Meaning |
|---|---|---|
| `snap_boundaries` | `true` | Master switch. Off restores fixed-pad behaviour exactly. |
| `pre_pad` | `0.150` | **Maximum** reach before the first word |
| `post_pad` | `0.250` | **Maximum** reach after the last word |
| `snap_min_silence` | `0.060` | Seconds below floor required to place a boundary |
| `snap_floor_offset` | `6.0` | dB above the measured noise floor |
| `snap_floor_window` | `0.500` | Seconds of quietest audio used to measure the floor |

---

## 8. Testing

Everything added to `VO/lib/ajsfx_vo.lua` is pure and unit-tested in `tests/`:

- `vo.TranscriptPath` — normal extension, no extension, dot in a directory
  name, nil, empty.
- `vo.SerializeTranscript` → `vo.ParseTranscript` round-trip preserving every
  word field, including text containing commas, quotes and newlines.
- `vo.ParseTranscript` rejection: empty, wrong marker, unknown version, missing
  word header. Each returns `nil, reason`, never raises.
- `vo.ParseProjectFile` / `vo.SerializeProjectFile` round-trip, including a
  `|<filename>` row with no audio, and rejection cases.
- `vo.BuildMatch` — same expectations as the existing `vo.BuildPlan` tests,
  fed from parsed transcripts instead of a whisper run; plus two sources
  matching the same `Filename` producing two spans.
- Boundary snapping — `vo.SnapBoundary` tested against a synthetic amplitude
  callback rather than real audio, covering: silence found inside the window;
  no silence found (falls back to pad, flag set); window shorter than
  `snap_min_silence`; no neighbouring word at start of file; and the invariant
  that the result never crosses the neighbouring word's timestamp.

Tests that cover `vo.BuildReport`, `vo.SerializeSidecar`, `vo.ParseSidecar`,
`vo.SerializeTracker`, `vo.ParseTracker` and `vo.PartitionPlanBySource` are
deleted along with those functions.

Manual verification in REAPER, recorded in `VO/MANUAL_TEST.md`:

1. Open Sources with an untranscribed project; every row reads `no`.
2. Transcribe one file; `<audio>_vo_transcript.csv` appears, row reads `yes`,
   word count is non-zero.
3. Double-click the row; the detail panel shows the transcript text; clicking a
   word moves the edit cursor to the right place.
4. Open Overview; statuses populate with no whisper run.
5. Load a *different* script CSV; statuses re-derive immediately, no
   re-transcription, no staleness warning.
6. Copy the wav and its sidecar to a fresh project; Overview shows the lines
   with zero marks and no whisper run.
7. Re-record over the wav so its size changes; Sources reads `stale`, Cut is
   disabled and names the file.
8. Mark selects, press Cut; clips land named and routed, in one undo step.
9. Two sources both selecting the same Filename; two Selects tracks appear and
   the collision is reported inline.
10. With `snap_boundaries` on, confirm clip edges sit in silence and never
    contain a syllable of the neighbouring line. Turn it off; confirm the
    fixed pads return.
11. Make the audio directory read-only; the sidecar write failure is an inline
    warning and the session stays usable.

---

## 9. Accepted consequences

1. **Every existing sidecar and tracker is dead.** Deliberate, per the no-users
   position. Nothing reads the old formats.
2. **The ReaPack package is renamed.** Users reinstall once.
3. **Sidecars are larger** — one row per word rather than per matched line. A
   one-hour session is on the order of 10⁴ rows, a few hundred KB of CSV. Worth
   it: it is what makes the file script-agnostic.
4. **Matching cost moves from ingest to every script change.** Bounded and
   memoised (§5), but a very large project will show a beat on CSV load.
5. **Snapping reads sample data**, so it depends on the item's take rather than
   the source path alone. A span whose source has no item in the project cannot
   be snapped and falls back to its pads.
6. **Judgements do not travel with the wav.** Only transcription does. Export
   tooling is listed as future work.

---

## 10. Future work

Shaped for, not built:

1. **Export** — transcript plus matched data out to CSV/SRT/whatever the
   delivery needs.
2. **Multiple scripts in one project** — the `Script id` column in §4.2 is
   reserved for it.
3. **Manual re-carve** — per-row start/stop overrides in the project file, and
   a word-range drag in the Sources detail view. The project file already has
   per-line rows, so the columns are additive.
4. **Comped and partially re-rendered sources** — a wav assembled from two
   recordings has no coherent sidecar. Currently it is simply a new file
   needing a new transcription; nothing smarter is attempted.
