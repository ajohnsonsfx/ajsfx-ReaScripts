# VO ScriptMatch — per-source sidecar and live selection

**Date:** 2026-07-25
**Scope:** `VO/ajsfx_VO_ScriptMatch.lua` and `VO/lib/ajsfx_vo.lua`. Changes where the
run report lives, what it contains, when it is written, and whether it is ever read
back. Reshapes the dialog's relationship to the item selection as a consequence.

## Problem

The run report is written once per project, to `<project dir>/<project name>_vo_report.csv`,
at the moment the cut is applied. Three things follow from that, all of them unwanted:

1. **One report per project.** A second VO session in the same project overwrites the
   first. There is no way to keep results for several recordings side by side.
2. **The report is write-only.** Nothing reads it back, so a transcription is lost the
   moment the dialog closes. Reopening on the same audio re-runs the match from the
   cached transcript at best, and re-runs whisper at worst.
3. **The dialog cannot open without a selection.** `vo.CollectSourceSpans()` runs once
   at script load and its result is frozen in a module-level local. An empty or
   unusable selection is a launch-time precondition, enforced by a focus-stealing
   message box before any window appears.

The transcript cache is already keyed per source file, by
`vo.CacheKey(source_path, file_size, cfg)`. The expensive half of the tool is therefore
already organised around the audio file; only the result is not.

## Goal

Make the audio file the unit of persistence. A recording carries its own transcription
result beside it, the dialog picks that up whenever the recording is selected, and no
part of the flow depends on what was selected at the instant the script was launched.

## Requirements

### R1 — Sidecar identity and location

For a source file `<dir>/<base>.<ext>`, the sidecar is `<dir>/<base>_vo_report.csv`.

`vo.SidecarPath(source_path)` returns this. It strips the final extension only, so
`RIVA_session.wav` yields `RIVA_session_vo_report.csv` and a file with no extension
yields `<name>_vo_report.csv`. It returns `nil` for a nil or empty path.

The sidecar is written **on Transcribe**, not on Cut. A session where the user
transcribes, inspects the table and never cuts still leaves its result on disk. Cut
rewrites it, because applying the plan can clamp spans (see R3).

The per-project report path is removed. `ReportPath()` and `ProjectDir()` in the dialog
have no remaining callers and are deleted.

### R2 — Sidecar format

The existing two-section report layout is kept and a preamble is added. The file stays
readable in a spreadsheet.

```
ajsfx VO ScriptMatch,1
Source,RIVA_session.wav
Source bytes,412839104
Script CSV,D:/proj/script.csv
Mapping,speaker=Character;asset=Filename;text=Line Text

Source start,Source stop,Kind,Filename,Character,Score,Margin,Take,Dest,Name,Transcript,Line text,Clamped
12.480,15.220,match,vo_riva_intro_01,RIVA,0.9821,0.4410,1,Selects,vo_riva_intro_01,we should not have come,We should not have come.,

SCRIPT LINES WITH NO MATCH
Filename,Character,Text
vo_riva_deck_03,RIVA,Seal it. Nobody goes below.
```

Preamble fields:

| Key | Meaning |
|---|---|
| `ajsfx VO ScriptMatch` | Format version, currently `1`. A file whose first cell is not this string is not a sidecar. |
| `Source` | Base name of the audio file, for human identification. Not used for matching. |
| `Source bytes` | `vo.FileSize` of the audio at transcription time. The staleness check (R6). |
| `Script CSV` | Absolute path of the script the plan was built from. |
| `Mapping` | The role→column mapping, `role=column` pairs joined by `;`, same roles as `vo.SerializeLayout`. |

The trailing `SCRIPT LINES WITH NO MATCH` section is retained for readability and is
**ignored on load**. It is derivable from the script and the spans, so treating it as
input would create a second source of truth that can disagree with the first.

`vo.SerializeSidecar(spans, lines, meta)` produces this text, where `meta` is
`{ source, source_bytes, script_csv, mapping }`. It replaces `vo.BuildReport`, which is
deleted rather than kept alongside — one writer, one format.

`vo.ParseSidecar(text)` returns `{ version, source, source_bytes, script_csv, mapping, spans }`,
or `nil` plus a reason string when the first cell is not the format marker, the version
is unrecognised, or the span header row is absent. A malformed sidecar is reported, not
thrown: a bad file next to the audio must not prevent the dialog from opening.

### R3 — Source-relative time

Spans in the sidecar are in **source-file time**, not project time.

Today `vo.MapWordsToProject(words, item)` converts whisper's source times into project
times using the item's position, start offset and playrate, and every stage after that
carries project time. A file living beside the audio has to survive its item being
moved, trimmed, duplicated, or opened in a different project, none of which the audio
file itself knows about.

Two pure conversions are added, exact inverses of the arithmetic already in
`MapWordsToProject`:

```
vo.ProjectTimeToSource(t, item)  ->  (t - item.pos) * playrate + item.start_offs
vo.SourceTimeToProject(t, item)  ->  item.pos + (t - item.start_offs) / playrate
```

Both treat a playrate of zero or less as `1.0`, matching `MapWordsToProject`.

Write converts each span's `start`/`stop` to source time. Load converts back against
whichever item currently references that source. A span whose source time falls outside
every current item for that source is **dropped on load** and counted; the dialog
reports the count (R6). This is the case where the item was trimmed after transcription.

The `Clamped` column records whether `ClampSpansToItems` adjusted a span. It is written
for information and ignored on load, since clamping is re-derived from the current items.

### R4 — Partitioning and union

`vo.PartitionPlanBySource(plan, items)` returns a map of source path to the list of
spans whose midpoint falls inside an item drawn from that source, with times already
converted to source time. Spans matching no item are omitted. This is what makes N
sidecars from one plan.

Loading runs the other way. For each distinct source path in the current selection, the
sidecar is parsed if present and its spans converted to project time and appended to a
single in-memory plan. **The dialog's model stays one plan.** Statuses fold to one per
script line by the existing rank rule in the Status column — any `match` beats any
`review`, which beats `unmatched` — so a line present in one recording and absent from
another reads `matched`.

Loaded spans are sorted by project start, matching `vo.BuildPlan`'s contract.

### R5 — Live selection

`vo.CollectSourceSpans()` moves from a launch-time snapshot into the frame loop. It is
re-run only when the **set of distinct source paths** in the selection changes; moving
an item, or selecting a second item from a file already in the set, does not trigger a
reload. The comparison is a sorted, concatenated key of the source paths.

No selection is a legal state. There is no launch-time precondition and no message box:

| Selection state | Dialog |
|---|---|
| Nothing selected | Table draws with header and selectors; Transcribe and Cut disabled; inline line: `Select the recorded session item(s) on a track.` |
| Selected, none usable | Same, with the existing per-item skip reasons listed inline. |
| Some usable | Normal operation. |

When the source set changes, any in-memory plan for sources no longer selected is
discarded and sidecars for newly selected sources are loaded. An unsaved plan is never
silently carried across a selection change.

The backend-not-ready check at launch also becomes an inline state rather than a message
box: the dialog opens, Transcribe is disabled, and the reason plus the instruction to
run `ajsfx VO Settings` appears inline.

### R6 — Verification on load

Two conditions are checked, each handled at the level it actually operates on.

**Audio changed** — recorded `Source bytes` differs from the file's current size. Every
span's timing in that sidecar is suspect at once, so this is a file-level fact and not a
per-line one. The plan loads, an amber line names the file
(`RIVA_session.wav has changed since it was transcribed — Re-transcribe to refresh.`),
and **Cut is disabled** while any loaded sidecar is in this state. The result stays
visible and readable; it cannot be acted on.

**Script changed** — the sidecar's `Script CSV` differs from the currently loaded path.
The plan loads, Cut stays enabled, and an amber line notes the mismatch naming both
paths. The mapping recorded in the preamble is *not* applied to the dialog; the user's
current mapping wins. The preamble mapping exists so the mismatch can be described, not
so it can override a deliberate choice.

Per-line consequences need no new mechanism:

| Case | Behaviour |
|---|---|
| Script line with no span in any sidecar | Existing `no match` status |
| Span whose Filename is absent from the current script | Kept in the plan, not shown in the table (the table is driven by script lines), counted and reported inline: `3 transcribed lines are not in this script.` |
| Span dropped because it fell outside every current item (R3) | Counted and reported inline: `2 transcribed spans fall outside the selected items.` |

### R7 — Transcribe and Re-transcribe

A source counts as **already transcribed** when its sidecar loaded cleanly *and* passed
the audio-changed check in R6. A stale sidecar does not count: its timings are the
reason Cut is disabled, so leaving it out of a Transcribe run would strand the user.

There is one button, and its label reflects what pressing it will do:

| Selected sources | Label | Action |
|---|---|---|
| None already transcribed | `Transcribe` | Transcribe all of them |
| Some already transcribed | `Transcribe` | Transcribe only the rest; a tooltip names how many are being skipped |
| All already transcribed | `Re-transcribe` | Transcribe all of them, setting `cfg.force_retranscribe` |

`cfg.force_retranscribe` bypasses both the sidecar and the scratch-dir transcript cache.
The button is never disabled on account of existing plans — only by the run gating that
already exists (no usable selection, unmapped required column, invalid CSV, backend not
ready).

Either way, each source's sidecar is rewritten when its transcription completes.

### R8 — Popups ask, never tell

A modal is warranted when it asks the user a question whose answer changes what happens
next. Reporting status, results or errors does not qualify — that belongs inline, in the
dialog the user is already looking at, and must not steal window focus.

Retained as focus-stealing OS dialogs, because each asks:

- Preset overwrite confirmation (`DoSave`)
- Preset delete confirmation
- The `Save As…` name prompt

Retained by necessity:

- The missing-ReaImGui message at script top. It cannot be shown in a dialog that
  requires ReaImGui to draw.

Converted to inline dialog state:

| Current | Becomes |
|---|---|
| `Select the recorded session item(s) on a track first.` | Inline empty state (R5) |
| Backend not ready | Inline, Transcribe disabled (R5) |
| `None of the selected items can be transcribed` | Inline skip reasons (R5) |
| Run summary after Cut | Inline result line plus the Status column, which already shows the per-line outcome |
| `The transcription produced no words` | Inline amber line |
| `Cancelled. Nothing in the project was changed.` | Inline neutral line |
| Transcription error | Inline red line, as `state.message` already does |

### R9 — Behaviour preserved

No change to matching, scoring, classification, padding, naming, routing, or
`vo.ApplyPlan`. No change to layout presets, the column mapping model, the preview
table, the character filter, or SPEC §5.3 restore precedence for `script_csv`,
`layout` and `layout_name` in `ProjExtState`. Those remain per-project, which is
correct: they describe the script and the user's mapping of it, not a recording.

## Accepted consequences

1. **Sidecars are written next to the audio.** A read-only or network media directory
   makes the write fail. Handled as an inline warning naming the path; the plan stays in
   memory and the session is still usable, it simply will not persist.

2. **`vo.BuildReport` is removed.** Any external expectation of the old per-project
   report path is broken. Acceptable: the tool is pre-1.0, the file was write-only, and
   the sidecar is a superset of its content.

3. **Report content now depends on the item, not just the plan.** Source-relative times
   mean the file cannot be produced from a plan alone; it needs the items that produced
   it. `PartitionPlanBySource` takes both, and this is why serialisation lives in a
   function that accepts items rather than in `BuildReport`'s old signature.

4. **A trimmed item silently loses spans.** Spans outside the current item bounds are
   dropped on load rather than clamped, because a clamped span with no audio behind it
   is worse than an absent one. The dropped count is reported (R6) so it is not silent
   in practice.

5. **Selection changes discard an unsaved plan for deselected sources.** Deliberate. The
   alternative — accumulating plans for files no longer selected — makes what Cut will
   act on unpredictable.

6. **The dialog does more work per frame.** Bounded by comparing a concatenated string of
   source paths; `CollectSourceSpans` itself only re-runs when that key changes.

## Future work

Shaped for, not built:

1. **Click an item, highlight its row.** The live selection model in R5 is the enabler.
   With source-relative spans already on hand, mapping an edit-cursor or item click to
   the span containing it, and scrolling the table to that line, is additive.
2. **Cutting across multiple source files.** Routing spans from several recordings to
   Selects / Alts tracks is unaddressed here. R4 keeps the plan unified in memory, which
   is the shape that work would need, but nothing in this spec claims the routing is
   correct for a multi-source cut.

## Testing

Everything added to `VO/lib/ajsfx_vo.lua` is pure and gets unit tests in `tests/`:

- `vo.SidecarPath` — normal extension, no extension, nil and empty input, a path
  containing a dot in a directory name.
- `vo.ProjectTimeToSource` / `vo.SourceTimeToProject` — round-trip at playrate 1.0 and
  at a non-unity playrate, non-zero `start_offs`, and the playrate ≤ 0 guard.
- `vo.SerializeSidecar` → `vo.ParseSidecar` round-trip preserving every span field,
  including fields containing commas, quotes and newlines (exercising
  `vo.EscapeCSVField`).
- `vo.ParseSidecar` rejection: empty text, wrong format marker, unknown version, missing
  span header. Each returns nil plus a reason, never an error.
- `vo.PartitionPlanBySource` — two sources, spans assigned by midpoint, a span matching
  no item omitted, and source-time conversion applied.

The existing 232 tests must continue to pass, except those covering `vo.BuildReport`,
which are rewritten against `vo.SerializeSidecar`.

Dialog behaviour is verified manually in REAPER:

1. Open with nothing selected; confirm no message box appears and the dialog shows the
   empty state with Transcribe disabled.
2. Select an item; confirm the table becomes active without reopening the script.
3. Transcribe; confirm `<audio>_vo_report.csv` appears beside the audio file and the
   Status column populates.
4. Close and reopen the script with the same item selected; confirm the statuses return
   with no transcription run.
5. Select a *different* recording with its own sidecar; confirm the table switches to it.
6. Select both recordings at once; confirm both sidecars load and statuses union.
7. Move the item on the timeline, reopen; confirm the spans still align with the audio.
8. Re-record over the .wav so its size changes; confirm the amber staleness line names
   the file and Cut is disabled.
9. Load a different script CSV; confirm the mismatch line appears and Cut stays enabled.
10. Press Re-transcribe; confirm whisper actually re-runs and the sidecar is rewritten.
11. Cut; confirm the summary appears inline and no message box takes focus.
12. Make the audio directory read-only; confirm the write failure is an inline warning
    and the session remains usable.
