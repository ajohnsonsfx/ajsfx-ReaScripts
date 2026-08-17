# SPEC: the Todo list is a list of LINES

Status: approved design, 2026-08-17. Supersedes the per-take entry model the
rail has carried since the redesign (beta34).

## The complaint

A line in the Todo list read **"Marks vs track B"**. That was true and useless.
The real state was: *two takes of one line had been pulled to the Selects
track*, one of them wearing an alt name. Nothing was wrong with take B's
marks; what was wrong was that the line had two claimants for the select and
nobody had said which one is the delivery.

Two separate defects made the list say the wrong thing:

1. **The root has no finding.** `vo.SelectConflicts` counts only takes that
   are *ticked* Sel. Here exactly one was ticked and the other merely sat on
   the Selects track, so the function saw no conflict. And select conflicts
   were never fed to `vo.InboxBuild` at all -- they reached only the summary
   bar and the card badge, never Todo.
2. **The symptom is what surfaced.** `vo.PlanReconcile` correctly noticed take
   B was "on the Selects track but not ticked Sel" and that `out_of_sync`
   finding is what the rail had to show.

And it generalises: the problem spanned **two takes of one line**, so no
per-take entry could ever state it. The finding unit has to be the line.

## Req-1: one Todo entry per line

`counts.total` becomes the number of **line entries**, not findings.
"Todo (31)" means *31 lines need you*.

Scanners are untouched. Each still emits per-take findings; `vo.InboxBuild`
gains a collapse stage after the ranking sort.

### The line key

A finding groups under `vo.LineKey(row)` when it carries a row. Findings that
carry only a media item (the parity watcher's `divergence` entries) have no
row, so they key on the take name's stem -- `"name:" .. base` -- exactly the
string `Inbox.Parts` already computes for them today.

This seam is real and is left as-is: a divergence finding and a row finding
for the same line will not merge if the take's name stem disagrees with the
line's asset. That is the same drift the rail has today, and closing it means
resolving the item back to a row, which belongs to a different change.

Findings with no line at all (`unheard`, `scan_suspects`, `scan_unheard`) keep
their own pseudo-groups and count as one entry each, as they do now.

### Entry shape

    { key       = <line key>,
      label     = <display name: row.deliver or row.asset, or the stem>,
      headline  = <the surviving finding with the lowest weight>,
      findings  = { <every surviving finding for this line, rank order> } }

`headline` is `findings[1]`; it is named separately so the walk and the label
do not have to re-derive it.

The entry *replaces* today's group header rather than adding a level, so the
rail's visual structure does not change: line name, then one amber issue row
per surviving finding with its fixes beside it. What changes is that the
header is now an addressable thing with a count behind it.

Grouping moves to `vo.InboxBuild`, which makes two existing passes redundant
and they come out: the display-order reshuffle in `Inbox.MaybeAssemble` (the
"DISPLAY ORDER IS WALK ORDER" loop) and the regroup at the top of
`Inbox.Draw`. Both exist only because the list arrived flat. `Inbox.Parts`
stays -- it still supplies `cat`, `take` and `tip` per finding -- but its
`group` field becomes the entry's label rather than the grouping key.

## Req-2: causal suppression

A finding that is merely the downstream shadow of another finding on the same
line is **deleted** -- not counted, not drawn, no "+N more". It returns on its
own when the root clears, because the scanners rerun on the next rebuild.

The rules live in one table beside `vo.INBOX_WEIGHT`, keyed root -> predicate
on the victim:

    vo.INBOX_SUPPRESS = {
      contested_select = <out_of_sync findings whose detail names track placement>,
      no_audio         = <suspect findings on the same row triggering thin or no_words>,
    }

**Rule 1 -- contested select swallows track placement.** When a line is
contested, an `out_of_sync` finding on that line whose detail names the track
("on the Selects track but not ticked Sel", "ticked Sel but the item is not on
the Selects track") is the arithmetic of the contest, not news. The predicate
tests `d.detail:find("track", 1, true)`, the same test
`Inbox.MaybeAssemble` already uses to decide an OK stamp cannot silence a
placement finding.

**Rule 2 -- no audio swallows the words.** A `no_audio` finding says the
marker has nothing playing under it. A `suspect` finding on that same row
triggering `thin` or `no_words` is reporting that no words were found in the
audio that is not there. Suspect triggers *other* than thin/no_words
(`name_mismatch`, `unmarked`, `stamp`) survive -- those are about the marks,
which still exist.

**Not a rule: `undecided`.** A line with no take picked is genuinely
undecided, and its takes' own problems still matter -- you need them to decide.

Adding a rule later means one entry in this table plus its test. Anything
suppressed must be re-derivable: if clearing the root would not make the
symptom disappear on the next rebuild, it is not a symptom and must not be
suppressed.

## Req-3: contested = ticked OR parked on Selects

`vo.SelectConflicts(rows, cfg)` widens. A take **claims the select** when

    row.user_select == true  OR  vo.MarkFromTrack(row.track_name, cfg) == "select"

excluding orphans and missing rows, as today. Two or more claimants on one
`vo.LineKey` is a contest.

Widening the existing function rather than adding a second detector is the
point: the summary bar, the card badge, and Todo then cannot report different
numbers for the same state. The `cfg` argument is new and optional -- omitted,
it falls back to `vo.LoadConfig()`'s defaults at the call sites that have no
cfg to hand.

Returned entries carry their claimants so the entry can name them:

    { key = <line key>, label = <line name>, count = N, claimants = { <rows> } }

### The count's copy changes

Every place that number is shown now reads **"N lines with multiple
selects"** -- not "two selects", because a widened contest can be three.
Affected: the Tidy summary message and the card badge tooltip.

The number will go **up** on existing sessions. That is a correction: lines
like the one that started this spec were always contested and were never
counted.

## Req-4: the new finding, and its verbs

New kind `contested_select`, weight **15** -- below `suspect_select` (10),
above `out_of_sync` (20), so it outranks and can suppress what it causes.

Category text: **"Multiple selects"**. Tooltip names the claimants by take
letter and says which track each sits on.

**Its only verb is Jump.**

This is a deliberate limit, and it is the general law for Todo verbs from here
on: *a Todo entry offers a button only for a fix that is already a button
somewhere else.* Picking the select is done by dragging the item or ticking
the Sel box -- the rail does not grow a second interface for it. `SetSelect`
already enforces exclusivity and demotes the losing sibling to Keep, and Pull
already moves items; neither needs a rail wrapper.

The consequence is a **sequence**, and it is the intended behaviour: you clear
the contest by hand, and if the names fall out of step as a result, the next
rebuild posts *that* -- "Name mismatch", with its existing Fix-from button.
One issue at a time, each one true when it appears.

## Req-5: the walk

J/K move entry to entry -- line to line. Verb keys act on the entry's
headline finding. `state.inbox_sel` indexes entries, not findings.

## Testing

`tests/test_vo_inbox.lua` gains:

- collapse: three findings across two takes of one line produce one entry;
  `counts.total` counts entries
- headline: the lowest-weight survivor becomes `headline`
- suppression rule 1: a contested line's track-placement `out_of_sync` finding
  is absent from `findings` and from `counts.total`
- suppression rule 1 boundary: an `out_of_sync` finding on the same line whose
  detail does *not* name the track survives
- suppression rule 2: `thin` and `no_words` suspects vanish under `no_audio`;
  `name_mismatch` on the same row survives
- `undecided` suppresses nothing
- no-line findings (`unheard`, `scan_*`) each remain one entry

`tests/test_vo_tidy.lua` gains, for the widened `vo.SelectConflicts`:

- one ticked + one parked on Selects = contested (the bug that started this)
- two ticked, neither on Selects = still contested
- one ticked, one on Alts = not contested
- orphans never claim
- claimant rows come back on the entry

## Out of scope

- Resolving a divergence finding's item back to a sheet row so it shares a
  line key with row findings.
- Any new verb, popup, or picker for choosing the select.
- Changing how any scanner decides what is wrong. This spec changes only
  which findings are *posted*, and how they are counted and grouped.
