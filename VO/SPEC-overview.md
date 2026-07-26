# ajsfx VO Overview — Design Spec

**Status:** Implemented · **Version:** 0.1 · **Date:** 2026-07-25

A project-wide picture of the dialogue in a session: every line the script says
should be there, every line that actually is, and the user's own marks over the
top. One table, all recordings, whether or not anything has been cut yet.

---

## 1. Why this is a separate script

`ajsfx_VO_ScriptMatch.lua` was built to **cut and pull takes**. A spreadsheet UI
was later grown onto the front of it, and the two purposes pull against each
other at every turn:

| | ScriptMatch | Overview |
|---|---|---|
| Scope | the current item selection, on one track | every item in the project |
| Lifetime | one run | the whole job, across sessions |
| Owns | derived data (transcripts, spans) | the user's judgements |
| Verb | *do something to this audio* | *tell me where I am* |

Trying to serve both from one dialog is what produced a selection-following
window that had to defend a live plan against every reselect. Splitting them
lets each be simple. Overview is the front door; small focused actions can hang
off it later.

### Non-goals

Overview does **not** transcribe, cut, split, move items between tracks, or pull
selects. Those belong to ScriptMatch and must not migrate here — that is exactly
the drift this split exists to prevent. The only thing Overview writes to the
project is a take name, and only when the user types one.

---

## 2. The three data layers

| Layer | File | Owner | Regenerable |
|---|---|---|---|
| **Expected** | the script CSV | the production | n/a |
| **Actual** | `<audio>_vo_report.csv`, one per source | ScriptMatch | yes — disposable |
| **The user's work** | `<project>_vo_tracker.csv`, one per project | Overview | **no** |

The separation is the point of the whole design. Re-transcribing a recording
rewrites its sidecar wholesale; it must not cost the user a single checkmark.
Verified flags, notes, name overrides and select choices are *judgements about*
audio, not facts *derived from* it, so they get their own file that transcription
never touches.

The script CSV path and its column mapping live in `SetProjExtState` under
`ajsfx_vo`, **shared with ScriptMatch**. Map the columns once; both windows know
them.

### Tracker format

```csv
ajsfx VO Overview,1

Key,Source,Source start,Filename,Status,Name override,Notes,Primary
RIVA.wav|1230,D:\Session\RIVA.wav,1.230,vo_guard_halt_01,verified,,great read,yes
```

Only rows carrying actual user work are written — otherwise the file would grow
a line per script line per session and the signal would drown. Clearing a row's
marks removes it from the file.

`vo.ParseTracker` never raises. A tracker mangled by a spreadsheet round-trip
returns `nil, reason`, and Overview then **refuses to save** rather than
overwriting whatever the user still has in there, and says so in the window.

---

## 3. Row identity

A verified flag has to survive a re-transcription that nudges a boundary by a few
tens of milliseconds. Identity is therefore tolerant, in four passes, each run
over every row before the next begins:

1. exact key, same full path — the row has not moved
2. exact key, same basename — the project moved to another drive
3. within ±0.5 s, same filename, same full path — a boundary shifted
4. within ±0.5 s, same filename, same basename — both at once

Keys are `<basename>|<source start in ms>` for audio rows and `|<filename>` for
script lines with no audio. Basename rather than full path so a project that
moves drives keeps its tracker; the full-path pass runs first so two recordings
that happen to share a filename never share a checkmark.

Within a pass, proximity matches are taken **globally nearest-first**, and each
tracker entry can be claimed by at most one row. Resolving per-row instead would
let one row claim, through the loose basename bucket, an entry that a later row
matches on its full path.

### Known limits

- A take moved more than 0.5 s by re-transcription loses its mark. This is
  deliberate: past that distance it is more likely a different piece of audio,
  and silently migrating a "verified" onto the wrong take is worse than dropping
  it.
- Two different lines recorded within 0.5 s of each other cannot swap marks —
  the rematch requires the same filename — but a *deleted* take can cause the
  remaining takes of that line to shift by one.
- Take numbering across several source files orders by source path, then by
  time within the file. With one recording per session and dated filenames this
  is recording order; it is not guaranteed to be for arbitrary filenames.

---

## 4. Behaviour

### Rows

One unified list. Every script line appears; a line with several takes appears
once per take, as sibling rows.

| Status | Means |
|---|---|
| **Recorded** | a matched span exists |
| **Review** | the span matched below the accept threshold |
| **Missing** | the script has this line, no audio matches it |
| **Orphan** | audio matching no script line, or a line the filters exclude |

Orphans are listed last and never silently dropped: unrecognised audio is
exactly what the user opened this window to find.

### Resolving a row to an item

A row carries a **source-time** coordinate. Resolution finds the project item
whose take plays that stretch of that file, and converts to project time.

This works identically **before and after a cut**, and that is not luck:
splitting an item leaves each piece pointing at the same source file with an
adjusted `D_STARTOFFS`, so a source-time coordinate still lands in exactly one
piece's coverage range. Nothing in the resolution path knows or cares whether a
cut has happened.

A row whose audio is not in the project resolves to nothing, is dimmed, and is
not navigable — a sidecar can outlive the item that produced it.

### Interactions

- **Click a row** — moves the edit cursor there, seeks playback, selects the item.
- **OK checkbox** — marks verified. `Space` toggles the selected row, but only
  when no text field has focus, or typing a space in Notes would fire it.
- **Sel radio** — chooses which take of a line is the select, overriding the
  configured first/last rule. Choosing one clears the rest of its group, so the
  tracker can never hold two selects for one filename.
- **Filename** — editable. Committed on Enter or on losing focus, never per
  keystroke, so each commit is one undo point. The name is sanitized, recorded
  in the tracker, and applied to the take inside a `core.Transaction`. A row
  with an override shows an amber `*`.
- **Notes** — editable free text, saved to the tracker.

Filters: status, character, and a text search across filename, line, transcript
and notes. Sorting is an explicit droplist rather than clickable headers —
ImGui's sort-spec API is unused elsewhere in this repo and the version risk was
not worth it for v1. Script order is the default and the stable tiebreak for
every other sort.

### Refresh

A per-frame probe of `GetProjectStateChangeCount` + item count decides *whether*
to rebuild; a 1.5 s throttle bounds how often that leads to actual sidecar file
I/O, since a drag gesture moves the counter every frame. **Refresh** forces a
re-read — that is the button to press after transcribing in ScriptMatch.

Tracker writes are throttled to 2 s while typing and flushed on window close.

---

## 5. Architecture

Pure layer in `lib/ajsfx_vo.lua`, unit-tested with no REAPER:

- `vo.TrackerPath`, `vo.OverviewKey`
- `vo.SerializeTracker`, `vo.ParseTracker`
- `vo.BuildOverview`, `vo.TrackerEntriesFromRows`, `vo.SummarizeOverview`

Coupled layer:

- `vo.CollectProjectSpans` — project-wide sibling of `vo.CollectSourceSpans`.
  Both call one shared `inspect_item`, so the MIDI / no-source / playrate skip
  rules cannot drift apart between the two windows.
- `vo.ProjectSourcePaths`, `vo.ResolveSourceTime`

`ajsfx_VO_Overview.lua` is ReaImGui only: no matching, no file format knowledge,
no REAPER mutation beyond `P_NAME` and the transport.

`ListClipper` is deliberately not used in the table — ReaImGui rejects it as
excessive creation of short-lived resources, which is why ScriptMatch dropped it
from its preview table too. ImGui's own table clipping keeps off-screen rows out
of the draw list.

Packaging: Overview ships inside the **existing** ScriptMatch package as a third
`[main]` entry. It must not declare its own `@provides` for `lib/ajsfx_vo.lua` —
only one package may provide a given file, and the loser is dropped from
`index.xml` silently.
