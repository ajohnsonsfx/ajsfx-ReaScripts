# SPEC: Todo lives in the sheet, one per line

Status: approved design, 2026-08-17. Second draft -- the first draft kept the
rail and made its entries per-line; AJ's review folded the whole thing into
the sheet instead. Supersedes the per-take rail model (beta34).

## The complaint that started it

A line in the Todo rail read **"Marks vs track B"**. True and useless. The
real state: two takes of one line pulled to the Selects track, one wearing an
alt name -- the line had two claimants for the select and nobody had said
which is the delivery. Two defects:

1. **The root had no finding.** `vo.SelectConflicts` counts only takes
   *ticked* Sel; one claimant was merely parked on the Selects track. And
   select conflicts never fed `vo.InboxBuild` at all -- they reached the
   summary bar and card badge, never Todo.
2. **The symptom surfaced instead.** `vo.PlanReconcile` correctly said take B
   was "on the Selects track but not ticked Sel", and that per-take finding
   is all the rail could show.

The problem spanned two takes of one line: no per-take entry could state it.
The finding unit has to be the line. And once it is the line, the rail is a
second list of the same lines the sheet already draws -- so the rail goes,
and the Todo moves under each card.

## The idea

**The Todo list is everything between here and "done", in the order the work
happens.** Identifying takes, cutting, picking a select, verifying -- stages,
plus faults (conflicts, mismatches) when something is wrong. Each line card
shows its OWN next work, the sheet filters to lines that still have some, and
the session is finished when the filtered sheet is empty.

## Req-1: the per-line Todo strip

Each line card grows a Todo strip: one amber row per surviving finding for
that line, drawn under the card's existing content.

**Two axes (AJ): stages and errors.** A line has exactly ONE stage -- its
place in the pipeline -- and may additionally carry errors. The stage names
(AJ's list):

    1. "Not Found"     -- nothing plays this line: never matched, or the
                          audio left the project (tooltip says which)
    2. "Needs edit"    -- takes still sitting uncut on the recording track
    3. "Needs select"  -- takes exist, none is the pick
    4. "Unverified"    -- some tracked take of it has not been heard:
                          it carries neither an OK of yours (confirmed_state)
                          nor a Vet stamp of the machine.s. EVERY tracked
                          take, not only the one that ships -- AJ: "if I
                          listen to a line and it is NOT a read, I am going
                          to untrack it, so an empty OK box means I am not
                          done". A take dropped to Outs was still listened
                          to; a take with no item cannot be heard and holds
                          nothing open.
                          The retired Lock box was never a verdict -- it
                          settled which take, not whether the read is right,
                          and reading it here left a session of hand-OK.d
                          lines all saying Unverified (AJ, live).
                          Its one button is Verify, and the empty OK box
                          of the take that ships wears an amber ring: the
                          rung must never name a problem and no remedy,
                          nor make you hunt for where to click
    5. "Done"          -- stage ladder cleared AND no errors; the line
                          leaves the Todo filter

Only the earliest unmet stage shows -- a line that is Not Found has nothing
to edit. This is the strip's stage remainder logic (`Strip.RowPasses`
order), reused.

**EVERY RUNG READS PERSISTENT PROJECT STATE.** AJ's list opened with a "Not
Scanned" rung, meaning the suspects scan had not run. It was implemented,
shipped to a live session, and removed the same day: `state.suspects` is
cleared by `Rebuild` (`ajsfx_VO_Overview.lua:864`) on EVERY project change,
so the flag meant "nobody pressed Scan since your last edit" -- and being
rung 1, it swallowed every line the moment a checkbox was ticked. A real
58-line session showed 58 lines reading Not Scanned and not one showing the
stage it was actually at; the whole ladder was inert.

The law it leaves behind: **a stage may only read state that survives a
restart** (takes, items, uncut markers, picks, stamps). A scanner that has
not run is a fact about the SESSION -- the Session card says so, and carries
the button that fixes it -- never a fact about a line. A scan's findings
still arrive as ERRORS once it has run.

**Ignore: the decision that ends a line.** Some lines are CORRECT with
nothing delivered -- cut from the script, read by another performer,
delivered from elsewhere. No amount of work resolves them, so without a
way to dismiss one the list can never reach empty, and an empty list is
the whole promise (AJ). An ignored line builds no stage and no errors:
`vo.TodoBuild` drops it before the gather, so nothing about it can be
counted or drawn.

Stored keyed by the LINE (`Ignore,script,asset,nth,1` in the sidecar,
beside the line edits and names), never as a take mark: takes come and go,
and the reason a line is dismissed has nothing to do with any one of them.
One press covers every take and survives a restart. Nothing is renamed,
moved or deleted -- the card stays, showing `Ignored` and a **Restore**
button, because a dismissed line must never be a dead end. Restoring brings
the line and its findings straight back, since nothing was stored while it
was gone. Seam: `ignore <needle>` / `unignore <needle>`.

**Errors re-open their home stage.** Every error kind names the stage whose
work fixes it, and a line's displayed stage is the EARLIEST of its ladder
rung and any live error's home stage -- a verified line that grows a second
select drops back to `Needs select · Conflict`, because picking the select
is the work you now have to redo. The header reads `<stage> · Conflict`;
the strip's rows beneath list each error with its evidence and verbs.

The mapping (AJ-approved 2026-08-17):

    Marker/marks without audio          -> Not Found
    Name/Edges mismatch (parity)        -> Needs edit
    Unmarked item                       -> Needs edit
    Multiple selects / marks vs track   -> Needs select
    Words mismatch (suspect)            -> Unverified
    Vet stale                           -> Unverified

Done requires both the ladder cleared and zero errors.

**Edit-boundary refresh (the anti-jank law).** Mid-gesture transients must
never draw, and a real mistake must show as soon as the tool notices it -- so
there is NO settle timer OF ITS OWN (a first draft had one; AJ: 3s is long
enough to make an actual mistake and lose the context). Instead:

    The Todo recomputes ONLY on a `GetProjectStateChangeCount` tick, and
    shows whatever is true as of the rebuild that tick triggers.

This is airtight against MID-GESTURE flashes because of two invariants, not
a heuristic:

1. REAPER bumps the change count when an edit LANDS -- mouse release,
   action completion -- never mid-gesture. Half a drag is invisible to the
   Todo by construction.
2. Every tool verb is one `core.Transaction` (already project law). A
   multi-step fix -- SetSelect demoting the sibling, Pull moving items --
   is one tick, one rebuild; the Todo never sees intermediate steps.

It is not instant, though: the tick only schedules a rebuild, and rebuilds
ride the window's existing `RELOAD_THROTTLE` (1.5s, `ajsfx_VO_Overview.lua`)
that already governed every other automatic rescan -- a drag gesture moves
the change counter every frame, and rebuilding on each one would force a
matching pass and a project-file read that often. So a mistake can take up
to ~1.5s to surface, never longer, and never a flash of something that was
never true. "No settle timer" means no CORRECTNESS-bearing timer was added
on top of that -- nothing here waits to see if you meant it, the way the
retired 3s draft did.

Drop take B on Selects while A still holds the pick: `Needs select ·
Conflict` appears within one throttle window of that release -- the moment
it might be an actual mistake. Drag one off: it clears the same way.
Nothing to tune.

LAW FOR FUTURE VERBS: any new operation that mutates in more than one step
MUST be transaction-wrapped, or its intermediate states become visible
Todo flashes. This is now a correctness requirement, not just undo hygiene.

Rows keep today's rail anatomy: amber category button = the jump, evidence in
the tooltip, fix verbs beside it. **Verb law (AJ):** a Todo row offers a
button only for a fix that is already a button somewhere else (Fix from...,
Fix names). Work done by dragging or ticking gets Jump only -- no second
interface. Clearing one issue by hand lets the next rebuild post whatever is
now true, one issue at a time, each true when it appears.

## Req-2: show/hide, filter, count

- **Show/hide.** One button toggles all Todo strips, persisted like the other
  panel collapses (`ui-copy` law: big panels collapse, counts stay visible).
- **Filter.** New sheet filter **"Todo"**: only lines with a non-empty Todo.
  Finishing a line's last item drops it from view on the next rebuild --
  the sheet drains as the work completes.
- **Count.** The strip button keeps reading "Todo (N)" where **N = lines
  with work** (plus Session entries, Req-5). Counting stays on while strips
  are hidden.

## Req-3: causal suppression

A finding that is the downstream shadow of another on the same line is
**deleted** -- not counted, not drawn. It returns by itself when the root
clears, because scanners rerun each rebuild. Rules in one table beside
`vo.INBOX_WEIGHT`:

    vo.INBOX_SUPPRESS = {
      contested_select = <out_of_sync findings whose detail names track placement>,
      no_audio         = <suspect findings on the same row triggering thin or no_words>,
    }

- **Contested select swallows track placement.** "On the Selects track but
  not ticked Sel" is the arithmetic of the contest, not news. Predicate:
  `detail:find("track", 1, true)` -- the same test the OK-stamp bypass uses.
- **No audio swallows the words.** thin / no_words on a row whose marker has
  no audio under it reports that no words were found in audio that is not
  there. Other suspect triggers on that row (name_mismatch, unmarked, stamp)
  survive -- they are about the marks, which exist.
- **Not a rule: undecided.** A line with no pick still needs its takes'
  problems visible -- you need them to decide.
- Stage suppression is structural (Req-1: earliest unmet stage only), not a
  table entry.

Rule of admission: if clearing the root would not make the symptom vanish on
the next rebuild, it is not a symptom and must not be suppressed.

## Req-4: contested = ticked OR parked on Selects

`vo.SelectConflicts(rows, cfg)` widens: a take claims the select when

    row.user_select == true  OR  vo.MarkFromTrack(row.track_name, cfg) == "select"

(orphans and missing excluded, as today). 2+ claimants on one `vo.LineKey` =
contested. Widening the existing function keeps the card badge, Tidy message
and Todo reporting one number. Entries carry `claimants = { <rows> }` so the
card can name them by take letter and track.

New fault kind **`contested_select`**, weight 15 (below suspect_select 10,
above out_of_sync 20). Category text: **"Multiple selects"**. Jump only.

Copy everywhere the count shows (Tidy summary, card badge tooltip):
**"N lines with multiple selects"** -- a contest can be three. The number
goes up on existing sessions; that is a correction, those lines were always
contested and never counted.

## Req-5: the Session card and line resolution

- Findings resolve to their line through `state.overview` (the reconciled
  sheet+items state). Parity findings that carry only an item resolve
  through the item->row index Rebuild already builds; the take-name-stem
  fallback survives only for an item in no row at all.
- Findings with no line -- **unheard sound** spans -- live on one pinned
  **Session** card at the top of the sheet, along with the batch verbs.
  Jump-only rows; each counts toward N.
- The "scan not run" rows stay SESSION-level, on that card, each with the
  Scan button that clears it. They are the honest answer to "is this sheet
  judged yet" without pretending to be a property of any line (Req-1).

## Req-6: keyboard walk

The rail's J/K moves to the sheet: J/K hop between lines that still have
Todo (respecting the current filter), verb keys act on the focused line's
top finding. Same config bindings, same guard off active widgets and popups.

## What gets deleted, what survives

Deleted:

- `Inbox.Draw`, the rail child window, `Inbox.WIDTH`, the rail's layout
  share in the body split, and the rail-hidden toggle wiring (the show/hide
  button re-targets the in-card strips).
- The display-order reshuffle in `Inbox.MaybeAssemble` and `Inbox.Draw`'s
  regroup pass -- grouping moves into `vo.InboxBuild`.

Survives, re-housed rather than reinterpreted (the same contract as when the
panels became the rail in beta33):

- `Inbox.MaybeAssemble`'s feed-staleness logic and OK-stamp filtering.
- `Inbox.Parts`' per-finding category/take/tip split -- it feeds the card
  strips now.
- `Inbox.FixVerbs` and the batch verbs ("Fix N out of sync...", "Adopt
  timeline for N"); batch verbs move to the Session card.

## Testing

`tests/test_vo_inbox.lua` gains, for the collapse in `vo.InboxBuild`:

- three findings across two takes of one line -> one line entry; counts
  count lines
- lowest-weight survivor is the entry's lead
- suppression rule 1: contested line's track-placement out_of_sync gone from
  findings and counts; a non-placement out_of_sync on the same line survives
- suppression rule 2: thin and no_words vanish under no_audio on the same
  row; name_mismatch survives
- undecided suppresses nothing
- line-less findings (unheard) group under the session key
- stage entry: a line reports only its earliest unmet stage
- a scanner that has not run changes no line's stage, and `not_scanned` is
  not in `vo.TODO_STAGES`
- home stages: an error pulls the displayed stage back to its home when the
  home is earlier than the ladder rung; never forward
- Done requires ladder cleared and zero errors
- edit-boundary refresh: the collapse recomputes only when the injected
  change count ticks; an unchanged count returns the cached result
  untouched (pure-layer test, change count injected)

`tests/test_vo_tidy.lua` gains, for widened `vo.SelectConflicts`:

- one ticked + one parked on Selects = contested (the originating bug)
- two ticked, neither on Selects = contested
- one ticked + one on Alts = not contested
- orphans never claim; claimant rows ride the entry

## Out of scope

- Any new verb, popup, or picker for choosing the select.
- Changing what any scanner decides is wrong -- this changes what is posted,
  grouped, and counted, not what is detected.
- Auto-running scanners so stage 4/5 entries appear without a manual scan
  (the "scan not run" Session rows keep that honest for now).
