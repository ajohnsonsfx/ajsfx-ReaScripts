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

    1. "Not Scanned"   -- the scanners that would judge this line have not run
    2. "Not Found"     -- nothing plays this line: never matched, or the
                          audio left the project (tooltip says which)
    3. "Needs edit"    -- takes still sitting uncut on the recording track
    4. "Needs select"  -- takes exist, none is the pick
    5. "Unverified"    -- delivered but no ears/stamp on it
    6. "Done"          -- stage ladder cleared AND no errors; the line
                          leaves the Todo filter

Only the earliest unmet stage shows -- a line that is Not Found has nothing
to edit. This is the strip's stage remainder logic (`Strip.RowPasses`
order), reused.

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

**Errors debounce; fixes do not (the anti-jank law).** Mid-work transients
-- two selects for the moment between a drag and its counter-drag, a
half-finished rename -- must not flash Conflict. One asymmetric rule at one
layer (the error feed in the collapse stage):

    A NEW error is drawn only once the project has sat still for
    ERROR_SETTLE seconds (3; a constant, not a config knob). A FIXED
    error disappears instantly.

"Sat still" is `GetProjectStateChangeCount` not ticking -- the project's
own edit clock, so it covers drags, ticks, scripts and hand edits without
knowing which was which. Each error key gets a first-seen time at rebuild;
it draws when the settle window has passed with no ticks. Once drawn it is
STICKY -- resuming work does not re-hide it -- until the error itself is
gone. Stages do not debounce: they move only on real completions.

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
- The old "scan not run" status rows dissolve into the per-line **Not
  Scanned** stage: while a scanner has not run this session, every line it
  would judge sits at Not Scanned. Honest and impossible to miss -- a stale
  scanner can never read as a clean sheet.

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
- scanner not run -> lines it would judge sit at Not Scanned; running it
  moves them to their real stage
- home stages: an error pulls the displayed stage back to its home when the
  home is earlier than the ladder rung; never forward
- Done requires ladder cleared and zero errors
- debounce: a fresh error inside the settle window is withheld from the
  strip and the count; the same error past the window draws; once drawn it
  stays through new edits; a fixed error vanishes on the next rebuild
  (pure-layer tests inject the clock and the change count)

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
