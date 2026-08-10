# ajsfx VO Sources — Design Spec

**Status:** Implemented, unverified in REAPER · **Date:** 2026-08-01

One row per distinct source wav referenced by the project's media items, and
whether it has been transcribed. This is the only window that owns
transcription — it does not read the script CSV, does not match, and does not
cut. A transcript is a fact about a wav file, and this is where that fact gets
made. See `VO/SPEC.md` §4.1 for the sidecar format this window writes.

---

## 1. Rows

One row per path from `vo.ProjectSourcePaths(vo.CollectProjectSpans())` —
every source at least one project item currently plays.

| Column | Content |
|---|---|
| File | Basename. |
| Transcribed | `Yes` / `No` / `Stale` / `Error` |
| Words | Word count from the sidecar. |
| Model | From the sidecar preamble. |
| Items | How many project items reference this source. |

Rows are rebuilt from `vo.TranscriptState(path)` whenever the project's state
counter moves, throttled to once per second (`RELOAD_THROTTLE`) so a drag
gesture — which can move the counter every frame — cannot force a filesystem
stat of every source on every frame. A caller that needs an immediate rescan
(a transcript that has just landed on disk) sets the scan marker back to `-1`,
which always wins over the throttle.

`Stale` means the sidecar parsed but its `Source bytes` (and, if that still
matches, its `Source hash`) no longer match the file on disk. A stale sidecar
still loads and still shows its words in the detail panel; it is Cut that
refuses to act on it. `Error` means the sidecar exists but could not be
parsed — the row names the reason rather than hiding the file.

---

## 2. Transcribing

Selecting rows (spreadsheet rules: click replaces, Ctrl/Cmd-click toggles,
Shift-click takes the range from the anchor, all keyed against whichever rows
the current filter shows) and pressing the run button transcribes them. The
button reads **Transcribe** unless every selected row already reads `Yes`, in
which case it reads **Re-transcribe** — a `Stale` row counts as needing the
work, not as already done.

Runs go through `vo.TranscribeSources`, sequential across the selected files,
with a progress line naming the file currently in flight and a row highlight
that follows it. Each file's words are written to its sidecar as soon as that
file finishes (`vo.WriteTranscript`), not batched to the end of the run — a
cancel partway through keeps every file that already completed, and only the
untranscribed remainder needs re-running afterwards. A write failure (for
example a read-only audio directory) is collected and reported inline as a
warning once the batch finishes; files that did write keep their result, and
the window stays usable.

Backend-not-ready is an inline red line naming the reason, with a **Settings…**
button that launches `ajsfx_VO_Settings.lua` via `vo.LaunchSibling`. No message
boxes anywhere in this window.

### 2.1 Gap repair

Whisper has a confirmed failure mode (ChristianBrently_Grumbar, 2026-08-08): a
slate ("Actor reading Character.") followed by a pause at the head of a
recording makes the decoder emit a gap token that swallows the rest of its
first 30-second window — speech from ~1.4s to the window boundary is never
decoded, levels are normal, and nothing in the run reports it. Re-running the
same audio starting after the slate recovers every word.

So every transcription result — fresh or cache hit — passes through
`vo.RepairTranscriptGaps` before its sidecar is written:

1. **Find the holes.** `vo.TranscriptGapSpans`: stretches of at least
   `gap_repair_min_gap` (5s) with no decoded words, including before the first
   word and, when the source duration is known, after the last.
2. **Ask the audio.** The transcript cannot tell a swallowed read from a long
   silence — both are the same hole — so `vo.PlanGapRepairs` probes each hole
   against the measured noise floor (`vo.MeasureNoiseFloor` over the
   transcript's own inter-word gaps, same as boundary snapping). A hole with at
   least `gap_repair_min_speech` (0.75s) of above-floor audio is a swallowed
   read; the rest are left alone.
3. **Re-run and merge.** whisper runs again on just that span
   (`vo.BuildWhisperArgv`'s `-ot`/`-d`), padded by `gap_repair_pad` but clamped
   to the hole so the re-run can never start on the already-decoded word that
   caused the swallow. `vo.MergeRepairWords` folds the recovered words in —
   whisper's offset output stays in source time — dropping any word that lands
   outside its own span, and never removing an original word.

A repaired file reports how many words were recovered in the end-of-run
summary; a repair run that fails leaves that gap as it was and says so there
too. No floor, no probe (source not in the project), or a transcript with no
words at all (nothing to measure a floor from) means no repairs — never
repairs everywhere.

---

## 3. Detail panel

A **single click** on a row opens a detail panel in the same window — a child
region below the table, not a separate script. It used to take a double-click,
which meant the log — the only place a run says what went wrong — was behind a
gesture nobody would try. Ctrl- and shift-clicks are multi-select and leave the
panel alone, and the panel follows the selection rather than toggling. What it
shows depends on the row's status:

- **`No`** — just the filename and a **Transcribe** button for that one file.
- **`Error`** — the filename, the parse failure reason, and the sidecar's path,
  so the user can go delete it rather than guess.
- **`Yes` / `Stale`** — the full preamble (source, byte count, hash, backend,
  model, language, word count), the transcript reassembled into readable
  paragraphs (`vo.Paragraphs` — a display-only regrouping; see `VO/SPEC.md`
  §4.1 for why no sentence grouping is stored), the focused paragraph's words
  as individually clickable buttons with a hover tooltip showing each word's
  source-time range, and a **Re-transcribe this file** button. A `Stale` row
  additionally shows a coloured warning line above all of that.

Clicking a paragraph focuses it; clicking a word inside the focused paragraph
moves the edit cursor to that word's position in the first project item that
references the source (`vo.SourceTimeToProject`), converting from the
sidecar's source-relative time. A source with no item left in the project has
nothing to seek to and the click is a no-op.

**Copy report** puts everything on the panel — identity, backend, model, any
problems, and the whole transcript — on the clipboard as text. A run used to
report its problems with no way to get them off the screen but a screenshot;
whatever is worth printing is worth pasting into a bug report. Selecting words
on screen instead would mean a read-only text box, which loses the colour that
makes the problems findable.

Every reported trouble spot that names a **timecode draws it as a link** —
underlined, blue, hand cursor — and clicking it moves the edit cursor there, so
the user can listen and decide whether it is a real hole or the reader genuinely
said that. A button beside the message would work; the link is better, because
the thing you want to go to is the thing you click.

**Delete transcript…** removes the sidecar, behind a confirm that names the file
and says what goes and what stays. Transcribing the wrong file is an ordinary
mistake and the only cure used to be opening the project folder and working out
which `*_vo_transcript.csv` it was; being opaque about it did not make it safer,
it moved the work somewhere the tool could not check. Little is at risk, and for
a principled reason: what the user DECIDED lives in the project file, take
identity lives in ranged take markers inside the items, and the delivered name
lives on the take — none of that is in the transcript, which is the one file
here whisper can rebuild. What goes is the transcript COLUMN and the ability to
re-derive matches until it is re-run. Offered on an `Error` row too, that being
the one most likely to want removing.

Re-transcribing from the detail panel always forces the run — it does not
consult the transcription cache — so pressing the button is guaranteed to
produce a fresh result even when a sidecar already exists.

---

## 4. Handoff from Overview

Double-clicking a Source cell in `ajsfx_VO_Overview.lua` writes the source
path to `SetExtState("ajsfx_vo", "focus_source", path)` and launches this
script via `vo.LaunchSibling`. Sources reads that key every frame — not once
at startup — so an already-open window responds to a second handoff too. On a
non-empty value it clears the key, selects and scrolls to the matching row,
and opens its detail panel; if the current filter would hide the row, the
filter is cleared rather than making the handoff look like it did nothing.

---

## 5. Architecture

Pure layer in `lib/ajsfx_vo.lua`, unit-tested with no REAPER:

- `vo.TranscriptPath`, `vo.TranscriptMeta`, `vo.FileFingerprint`
- `vo.SerializeTranscript`, `vo.ParseTranscript`
- `vo.ParagraphWords`, `vo.Paragraphs`
- `vo.ParseWhisperCSV`, `vo.BuildWhisperArgv`, `vo.DTWPresetForModel`
- `vo.TranscriptGapSpans`, `vo.PlanGapRepairs`, `vo.MergeRepairWords` — gap
  repair (§2.1), tested in `tests/test_vo_gap_repair.lua`

Coupled layer:

- `vo.CollectProjectSpans`, `vo.ProjectSourcePaths` — shared with Overview and
  Cut, so the MIDI / no-source / playrate skip rules cannot drift apart between
  windows.
- `vo.TranscriptState`, `vo.ReadTranscript`, `vo.WriteTranscript` — the
  filesystem side of the sidecar.
- `vo.TranscribeSources`, `vo.RunWhisperAsync` — the detached async runner with
  progress and cancel.
- `vo.MakeSourceProbe`, `vo.RepairTranscriptGaps` — the audio probe behind gap
  repair and the repair-run chaining (§2.1).
- `vo.LaunchSibling`, `vo.IsBackendReady`.

`ajsfx_VO_Sources.lua` carries `@noindex` and ships as a `[main]` entry in
`ajsfx_VO_Overview.lua`'s `@provides` (`VO/SPEC.md` §5). It mutates nothing in
the project — it writes only transcript sidecars beside the audio — and reads
no script CSV.
