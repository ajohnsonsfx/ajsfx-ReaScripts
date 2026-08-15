# Spec: VO Overview UX redesign — strip, rail, contextual verbs

**Status:** Approved direction (AJ answered the fresh-take's open questions 2026-08-15)
**Source:** `docs/superpowers/specs/2026-08-15-vo-ux-fresh-take.md` (§4 recommendation)
**Plan:** `docs/superpowers/plans/2026-08-15-vo-ux-redesign.md`

**Goal:** One window whose header always answers *where am I* (pipeline
strip), whose right rail always answers *what needs me* (inbox), and whose
verbs appear only where they apply — replacing four tabs, five Check
panels, four Main button rows, and the separate Sources window.

**AJ's decisions (from the fresh-take's open questions):**

1. **Sheet stays the centerpiece.** The inbox is a persistent right rail,
   not the lead view.
2. **Sources fully merges.** The Sources window's content becomes the
   "Sources" pipeline stage; `ajsfx_VO_Sources.lua` retires.
3. **Keyboard designed in, with remappable keys.** Inbox is J/K-walkable
   with one-key verbs; the bindings are user-configurable in Settings.
4. **All three phases planned now.** Each phase still ships alone.

## Deliverables

- `VO/ajsfx_VO_Overview.lua` — modified in place across three beta releases.
- `VO/lib/ajsfx_vo.lua` — new pure planners: `vo.InboxBuild`, `vo.PipelineStages`.
- `VO/lib/ajsfx_vo_sources_ui.lua` — new module: Sources UI extracted for embedding.
- `VO/ajsfx_VO_Sources.lua` — deleted at end of phase 2.
- `VO/ajsfx_VO_Settings.lua` — new "Keyboard" section.
- Tests in `tests/` for every new pure function.

## Requirements

### Phase 1 — the Inbox rail (replaces the Check tab)

1. A persistent right-side rail lists every actionable finding in ONE
   ranked list, merging: parity queue + reconcile disagreements, takes
   without audio, orphan marks, unidentified spans, unheard bursts,
   suspects, and undecided lines (takes exist, no select picked).
2. Rank order (kind weights, ties keep source order):
   suspects on the Selects track (10) → out-of-sync refusals (20) →
   takes without audio / orphan marks (30) → unidentified spans (40) →
   undecided lines (50) → other suspects (60) → unheard stretches (70).
3. Every row is the beta33 evidence-row pattern: evidence text IS the jump
   button, then its one or two verbs. Verbs dispatch the same existing
   functions the Check panels dispatch today (`Trim.sync_dispatch`,
   `Trim.fix_from_transcript`, `Verify.KickSelection`, …).
4. Scanners that need a run (unheard, suspects show "?") appear in the rail
   as a single "Scan" row per stale scanner — never silently omitted.
5. Toolbar shows a "Needs you (N)" count; empty rail renders a done state.
6. Keyboard: next/prev walk, jump, verb-1, verb-2 — defaults J/K/Enter/1/2,
   remappable via new `CONFIG_SCHEMA` keys surfaced in Settings.
7. The Log becomes a strip at the bottom of the rail, newest first; the
   Log tab and the Check tab retire in the same release.

### Phase 2 — the Pipeline strip (replaces the tab bar)

8. A header strip, always visible:
   `Sources · Matched n/m · Cut · Decided n/m · Verified % · Delivered`.
   Counts come from the numbers the tool already computes
   (`vo.SummarizeOverview`, `vo.CheckCoverage`, `vo.PlanReconcile`,
   transcription progress) — no new scanners.
9. Each stage is a filter: clicking it shows only that stage's remainder
   rows in the sheet, with only that stage's verbs visible. Clicking the
   active stage clears the filter.
10. The Sources stage embeds the extracted Sources UI (scan, transcribe,
    backend line, progress). The standalone Sources window is deleted;
    whisper runs keep working as background jobs with the stage meter
    showing progress.
11. The Setup and Main tabs' remaining contents move into their stages;
    the tab bar is removed. The hero lives in the strip as its
    "advance everything" action.

### Phase 3 — Contextual verbs (retires the Main rows)

12. A fixed verb bar above the sheet (always visible — NOT a floating
    popup; discoverability is the named weakness of concept C) shows the
    verbs for the current selection context:
    recording selected → Match / Cut; take(s) → Fix from… / Verify / OK /
    Re-cut; line card → pick verbs; nothing → a hint line naming the
    contexts.
13. Mixed selections show only the verbs shared by every selected context.
14. The Match/Fix/Pick/Pull rows are removed. Globals reduce to: hero
    (in strip), search, Settings, "Keep the session in sync", and
    destructive verbs behind the existing confirm popups.

## Constraints

- `VO/ajsfx_VO_Overview.lua` is at Lua's 200-local cap: **no new top-level
  `local`s beyond at most ONE namespace table per phase** (`Inbox`,
  `Strip`, `Verbs`); everything else hangs off existing tables or the vo
  lib. `luac -p` after every edit.
- No new chunk reads; all counts come from existing state
  (`state.summary`, `state.check`, `state.reconcile`, `state.take_markers`).
- Pure logic lives in `VO/lib/ajsfx_vo.lua` with mock-REAPER tests.
- Each phase ships alone as a beta (`@version` bump + `@changelog`); an
  old surface retires only in the release that ships its replacement.
- Verbs are never renamed or resemantic'd — this is a re-housing, not a
  behavior change. The parity watcher, matcher, and scanners are untouched.
- Transcript text is never rewritten; marker assets never carry naming
  conventions (standing VO laws).

## Success criteria

- [ ] Phase 1: every finding the five Check panels showed appears in the
      rail, ranked per §2's weights; Check and Log tabs are gone; each
      rail verb reaches the same function the panel button reached.
- [ ] Phase 1: J/K/Enter/1/2 walk and act on the rail; changing a binding
      in Settings changes the live key.
- [ ] Phase 2: strip counts equal `DrawSummary`'s numbers for the same
      project state; clicking each stage filters the sheet to exactly its
      remainder set; clicking again clears.
- [ ] Phase 2: scan + transcribe + backend status all work from the
      Sources stage; `VO/ajsfx_VO_Sources.lua` no longer exists.
- [ ] Phase 3: a verb inventory (every button on today's Main tab) maps to
      a reachable home — context bar, stage, strip, or Settings — with
      zero orphans; the four Group rows are gone.
- [ ] Every release: `./run_tests.sh` green, `luac -p` clean on touched
      files, CI green after push, live-REAPER pass via the MCP harness.

## Edge cases

- Rail empty → "Nothing needs you" + summary counts (dopamine, not blank).
- Mixed selection with no shared verbs → bar shows the hint line.
- Duplicate key bindings → Settings shows an inline warning; last-drawn
  field wins, nothing crashes.
- Stage clicked while its count is 0 → filter still applies, sheet shows
  its empty-state line ("Everything here is decided").
- Whisper run mid-flight → Sources meter shows running progress; other
  stages stay clickable.

## Out of scope

- No matcher, parity, scanner, or cut-placement changes.
- No new scanners or counters; the strip renders what exists.
- No whisper-server work (parked separately).
- No changes to CSV/script handling or export formats.

## Assumptions [assumed unless AJ objects]

- Phase 3's verb bar is fixed above the sheet, not floating at the mouse.
- Deleting `ajsfx_VO_Sources.lua` is an acceptable ReaPack package removal
  (CI has handled removals before; users' installed copies are unaffected
  until they sync).
- The undecided-lines source for the rail is `state.summary.review`-class
  rows (recorded, no select) — no new scan.
