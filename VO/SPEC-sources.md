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

---

## 3. Detail panel

Double-clicking a row opens a detail panel in the same window — a child region
below the table, not a separate script — and a second double-click on the same
row closes it again. What it shows depends on the row's status:

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

Coupled layer:

- `vo.CollectProjectSpans`, `vo.ProjectSourcePaths` — shared with Overview and
  Cut, so the MIDI / no-source / playrate skip rules cannot drift apart between
  windows.
- `vo.TranscriptState`, `vo.ReadTranscript`, `vo.WriteTranscript` — the
  filesystem side of the sidecar.
- `vo.TranscribeSources`, `vo.RunWhisperAsync` — the detached async runner with
  progress and cancel.
- `vo.LaunchSibling`, `vo.IsBackendReady`.

`ajsfx_VO_Sources.lua` carries `@noindex` and ships as a `[main]` entry in
`ajsfx_VO_Overview.lua`'s `@provides` (`VO/SPEC.md` §5). It mutates nothing in
the project — it writes only transcript sidecars beside the audio — and reads
no script CSV.
