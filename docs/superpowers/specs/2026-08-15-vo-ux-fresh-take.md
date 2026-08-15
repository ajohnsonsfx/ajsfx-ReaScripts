# VO Overview — a fresh UX take

**Status:** Exploration, nothing approved · **Date:** 2026-08-15

AJ's brief: the features are good, the UX was *converged on* rather than
designed, and it is cluttered with debris. A fresh take may be completely
different.

---

## 1. What the debris actually is

Naming the clutter precisely, because each piece was once a good decision:

1. **Buttons organized by implementation history.** The Main tab's four rows
   (Match / Fix / Pick / Pull) each carry a macro slot, a steps band, and a
   leftover band — a taxonomy that records *how the verbs were built*, not
   how the work flows. The parity watcher then obsoleted most of the Fix
   row's reasons to exist: sync is automatic, and what it can't decide
   queues. The rows survived the change that emptied them.
2. **Five panels for one question.** Check's panels (Out of sync, Takes
   without audio, Not yet identified, Unheard, Suspects) are fragments of a
   single question — *"what needs me?"* — split by DETECTION MECHANISM
   (which scan found it) instead of by what the user should do about it.
   Nobody cares which scanner fired; they care what to listen to next.
3. **Knowledge lives in tooltips.** The hero's tooltip is a manual. Twenty
   other tooltips carry load-bearing rules ("acts on the selection", "fills,
   never overwrites"). The UI tells you how it works instead of showing you
   where you are.
4. **Evidence far from the row.** beta33 fixed the worst of it, but panels
   still open away from the sheet rows they describe, and the Log is a
   separate tab from the actions that wrote it.
5. **Two windows and a settings script** (Overview, Sources, Settings) for
   one workflow.

## 2. What the tool actually is now

After the parity watcher, the human's remaining jobs are exactly four:

| job | today's surface |
|---|---|
| **Start** a session (transcribe, match, cut) | Setup tab + hero |
| **Judge** (ears: pick takes, OK reads, settle unsure rows) | sheet boxes + Check panels |
| **Answer** what the machine couldn't decide | Out of sync + Suspects |
| **Deliver** (pull, lay out, export) | Pull row + Sort panel |

Everything else — trims, snaps, renames, marks, alt numbers — happens by
itself or on a queue row. The UI's job is to make those four jobs obvious
and everything else invisible.

## 3. Three concepts

### A. The Inbox — one "Needs you" rail

The window stays sheet-centric, but the right side grows a persistent rail
that merges every actionable finding into ONE ranked list: out-of-sync
divergences, suspects (Selects first), undecided lines, conflicts, unheard
stretches. Each row: the evidence (words, names, verdict), a jump, and its
one or two verbs — the beta33 pattern, promoted from panel to permanent
fixture. The toolbar shrinks to the hero plus a count. Empty rail = done.

*Strength:* directly answers "what now"; kills the five Check panels; every
interaction is row-sized. *Weakness:* says nothing about overall progress —
you learn what's broken, not where you are.

### B. The Pipeline — status-first header

The top of the window becomes a stage strip, always visible:

```
Sources ✓   Matched 412/446   Cut ✓   Decided 180/195   Verified 61%   Delivered —
```

Each stage is a meter and a filter: click "Decided 180/195" and the sheet
shows exactly the 15 undecided lines, with only the picking verbs visible.
Click "Verified 61%" and it's the unverified takes with Verify/OK verbs.
Buttons exist only inside the stage that needs them; the strip is the whole
toolbar. The hero becomes the strip's own "advance everything" action.

*Strength:* the session's state is the UI — no tab answers "where am I"
because the header always does; verbs appear only in context, so the debris
has nowhere to accumulate. *Weakness:* more build; stages must be computed
honestly (we now have every counter it needs).

### C. The Contextual Sheet — zero toolbar

No rows of buttons at all. Verbs live on the selection: select a recording
and a floating bar offers Match/Cut; select a take and it offers Fix from… /
Verify / OK; select a line and it offers the pick verbs. Globals reduce to
the hero, search, and settings.

*Strength:* radically clean; nothing on screen that doesn't apply to what
you're touching. *Weakness:* discoverability — verbs you can't see are verbs
you forget exist; the failure mode of this session ("which button does it?")
gets worse, not better.

## 4. Recommendation: B as the frame, A as the engine, C inside the stages

The three aren't rivals. The pipeline strip answers *where am I*; the inbox
answers *what now*; contextual verbs answer *what can I do to THIS*. A
coherent whole:

- **Header:** the pipeline strip (B). Always visible, replaces the tab bar
  for Main/Check entirely. Setup collapses into the first stage ("Sources").
- **Right rail:** the inbox (A), fed by every existing scanner, ranked
  Selects-first, evidence-first. Replaces all five Check panels and the
  standalone Out of sync panel.
- **Sheet:** unchanged at heart (the line cards are good), but stage-filtered
  when a stage is clicked, and verbs appear contextually (C) within a
  filtered view instead of living in permanent rows.
- **Log:** a strip at the bottom of the inbox — actions and their reports in
  one column, newest first.

Phaseable in order: (1) inbox rail absorbing the Check panels, (2) pipeline
strip replacing the tab bar, (3) contextual verbs retiring the Main rows.
Each phase ships alone and the old surface retires only when its
replacement exists.

## 5. Open questions for AJ

1. Does the sheet stay the centerpiece, or would you rather LEAD with the
   inbox and treat the sheet as the drill-down?
2. How much of Sources belongs inside this window? (The whisper runs are
   long-lived background work — a stage meter fits them naturally.)
3. Keyboard: is this a mouse tool, or should the inbox be J/K-walkable with
   one-key verbs? (Cheap to add at design time, expensive later.)
