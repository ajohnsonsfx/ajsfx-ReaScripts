# ajsfx VO Cut — Design Spec

**Status:** Implemented, unverified in REAPER · **Date:** 2026-08-01

A small run window, launched from Overview, that cuts, routes and names the
takes marked **Select**. This is the only VO window that mutates the project.
It owns no data of its own: it re-derives the match from the transcripts and
the script (`vo.BuildMatch`, `VO/SPEC.md` §6), reads the project file for the
user's selects, and applies the result inside one undo step.

---

## 1. What gets cut

A candidate list is built from every source's match spans (`VO/SPEC.md` §6):

- every `match` span whose row is ticked **Select** in Overview,
- every sibling `match` span of a resolved line's asset when **Use alts
  track** is on (so the non-selected takes have somewhere to go),
- every `review` span, unconditionally — a low-confidence match is always
  flagged for a human, never silently guessed at or silently dropped.

`unmatched`/gap spans are never candidates: unmatched audio is left exactly as
recorded, not split, moved or renamed.

Each candidate is resolved against the live item that currently plays it
(`vo.ResolveSourceTime`, via `vo.SourceCoverageRanges`) and converted into
project time. A span whose source has no item covering it any more — the item
was trimmed since transcription — is dropped from the cut and counted in the
summary rather than being cut against silence.

---

## 2. The gate

Cut refuses to run, with the reason shown inline, when:

| Condition | Message |
|---|---|
| Any loaded transcript is `stale` | Names the file(s); re-transcribe in Sources first. |
| Nothing is ticked Select | "Nothing is selected. Tick Select in Overview on the takes you want cut." |
| A line has more than one take and none is selected | Names the line(s) as needing a decision. |

The gate is re-evaluated on the same throttled rescan as the rest of the
window's state (`RELOAD_THROTTLE`, 1.5 s, mirroring Overview's own
`GetProjectStateChangeCount` pattern per `CLAUDE.md`), and again immediately
after every cut.

---

## 3. Toggles

Two per-run toggles, session-only state in this window rather than persisted
`ExtState` — `vo.CONFIG_SCHEMA` deliberately excludes them, because they
describe how *this* run should route non-selected takes, not a standing
preference.

| Toggle | Values | Effect |
|---|---|---|
| `use_alts_track` | off / on | **off:** only the selected take of each line is cut. **on:** every other take of a line with a resolved select is also cut, onto the Alts track. |
| `suffix_alt_names` | off / on | **on:** non-selected takes get `_tk01`, `_tk02`… while the selected take keeps the bare asset name. |

`primary_take` — the old `first`/`last` toggle that guessed which take of a
repeated line was the one to keep — is gone. The **Select** column in Overview
now says so explicitly, and a line with no select and several takes is
reported as needing a decision rather than guessed at (§2).

---

## 4. Naming and routing

`vo.AssignNames` runs once over every candidate from every source together, so
two takes of one line recorded across two separate recordings number as takes
1 and 2 of that line rather than each starting its own count. Routing is
`Selects` / `Alts` / `Review`, using the track names configured in Settings.

**Two sources both selecting the same `Filename`** are both cut — this is
expected, not an error, since each is a separate row with its own key
(`VO/SPEC.md` §4.2). Normally there is one `Selects` track. Only when a name
collision actually exists — the same delivered name coming from more than one
source path — do the colliding sources get one track each, named
`Selects — <basename>` (or `Alts —`/`Review —`, per destination), and the
collision is reported inline in the summary. Neither clip is dropped and
neither is silently renamed; the user decides which is the keeper.

---

## 5. Boundary snapping

Replaces the old fixed `pre_pad` / `post_pad` behaviour.

### Rule

For a span's start boundary, the search window is `[prev_word_end,
first_word_start]`, clamped to at most `pre_pad` seconds of reach. For the stop
boundary it is `[last_word_end, next_word_start]`, clamped to `post_pad`. Where
there is no neighbouring word — start of file, end of file, a gap longer than
the pad — the pad itself bounds the reach.

Within that window, `vo.SnapBoundary` walks outward from the word and places
the boundary at the first point where RMS amplitude stays below the noise
floor for at least `snap_min_silence` milliseconds. If no such point exists,
it falls back to the full pad and the span's in-memory `snapped` field is set
to `"pad"` (otherwise `"silence"`), so the cut summary can report how many
edges fell back to the fixed pad and by implication how many landed in actual
silence. This field lives only on the computed span for the duration of the
run — nothing about a boundary's placement is written to disk.

The window is derived from the neighbouring **words**, so a boundary
structurally cannot enter the next line's audio regardless of what the
amplitude does. That is the reason the transcript bounds the search rather
than the amplitude alone deciding where to stop.

### Noise floor

Measured per item, not fixed. Before applying padding to an item's spans, Cut
takes every inter-word gap the item actually covers (`vo.InterWordGaps`,
filtered to the words `vo.SourceCoverageRanges` says this item plays — a
source already split across several items has words belonging to its
siblings, and letting those leak in would drag the measured floor down with
silence the probe was never meant to see), converts the gaps to project time,
and samples the quietest `snap_floor_window` (default 500 ms) across them via
`vo.MeasureNoiseFloor`. The floor is that value plus `snap_floor_offset` dB
(default +6). A fixed floor fails on a noisy room and on a very clean one in
opposite directions.

### Sample access

`vo.MakeTakeProbe(take)` wraps `reaper.CreateTakeAudioAccessor` and
`reaper.GetAudioAccessorSamples`, reading only the windows the search actually
needs. The accessor is created once per item and destroyed in the same scope
via a `pcall`/`destroy()` pair that runs on the error path too — the accessor
holds the file open until it is destroyed.

### Settings

Configured in `ajsfx_VO_Settings.lua`'s Boundaries section (`VO/lib/ajsfx_vo.lua`'s
`vo.DEFAULTS`):

| Key | Default | Meaning |
|---|---|---|
| `snap_boundaries` | `true` | Master switch. Off restores fixed-pad behaviour exactly. |
| `pre_pad` | `0.150` | **Maximum** reach before the first word. |
| `post_pad` | `0.250` | **Maximum** reach after the last word. |
| `snap_min_silence` | `0.060` | Seconds below the floor required to place a boundary. |
| `snap_floor_offset` | `6.0` | dB above the measured noise floor. |
| `snap_floor_window` | `0.500` | Seconds of the quietest gap used to measure the floor. |

With `snap_boundaries` off, `pre_pad`/`post_pad` behave exactly as they did
before snapping existed: a fixed pad from the first/last aligned word,
unconditionally.

---

## 6. Applying the cut

Every mutation — track creation, split, move, rename, and any regions —
happens inside one `core.Transaction("VO Cut", ...)`, so the whole run is a
single undo step (`CLAUDE.md`). Spans are grouped by `(source track,
destination, per-source override)` before applying, since `vo.ApplyPlan` takes
one source track per call and a name collision (§4) needs its own group.

The summary shown after a run (`vo.FormatCutSummary`, plus the collision and
pad-fallback lines this window adds) reports: how much of the whole match has
audio at all, how many clips this run actually applied, which candidates were
skipped because no item covered them, any per-source name collisions, and how
many clip edges fell back to the fixed pad.

---

## 7. Architecture

Pure layer used by this window, all in `lib/ajsfx_vo.lua` and unit-tested with
no REAPER:

- `vo.BuildMatch` (shared with Overview — see `VO/SPEC.md` §6)
- `vo.InterWordGaps`, `vo.MeasureNoiseFloor`, `vo.SnapBoundary`, `vo.ApplyPadding`
- `vo.AssignNames`, `vo.FormatCutSummary`
- `vo.ProjectFilePath`, `vo.ParseProjectFile` (reads the same project file
  Overview writes)

Coupled layer:

- `vo.CollectProjectSpans`, `vo.ProjectSourcePaths`, `vo.SourceCoverageRanges`,
  `vo.ResolveSourceTime`, `vo.SourceTimeToProject`
- `vo.TranscriptState`, `vo.MakeTakeProbe`
- `vo.EnsureTrackBelow`, `vo.ApplyPlan`

`ajsfx_VO_Cut.lua` carries `@noindex` and ships as a `[main]` entry in
`ajsfx_VO_Overview.lua`'s `@provides` (`VO/SPEC.md` §5). It loads the project
file and the script CSV once at launch, the same way the old single-script
tool did, and re-derives everything else from the live project on its own
throttled rescan.
