# ajsfx VO — Cut, Pull, Sort, and the character selection

Design, 2026-08-04. Supersedes the parts of `VO/SPEC-overview.md` §7 (timeline
layout) and `VO/SPEC.md` §5 (cut destinations) that this contradicts.

## 1. What is wrong today

Three separate problems, one root.

**The toolbar has no shape.** `Script`, `Sources…`, `Cut…` and `Settings` sit in
a row; the timeline layout is an inline bar of five controls under the filters;
the character filter is a combo in the filter row. Nothing says which of these
change what you SEE and which change the PROJECT.

**Cut does three things at once** — it splits spans out of the recording, names
the pieces, and moves them onto Selects/Alts/Review tracks. You cannot have the
splits without the routing, and the tracks it makes are siblings of the source
track rather than children of it.

**The root: Sort and Pull ask the transcript what an item is.** That is the
wrong question. The user's two real cases are

1. takes cut out of a long session recording, and
2. rendered wav files delivered by someone else, already named,

and in BOTH the thing that identifies an item is its NAME. Case 2 has no
transcripts at all, so a match-driven Sort cannot serve it. Asking the name
instead serves both, and drops the dependency on matching from two of the three
tools.

## 2. The shape

Six buttons, one row:

```
Script   Sources…   Cut and Name   Pull   Sort   Settings
```

`Sources…` and `Settings` open their own windows, as now. The other four toggle
an inline panel, one open at a time, in the space the Script panel already uses.

| | reads | writes | needs the transcript |
|---|---|---|---|
| **Cut and Name** | the match | splits the recording, names each piece | **yes** |
| **Pull** | item names, and the Select tick | renames to the delivered name, moves to child tracks | no |
| **Sort** | item names | item positions on the timeline | no |

Cut is the only tool left that consults the match. That is correct: cutting a
span out of a continuous recording is a question only the transcript can answer.

## 3. Name resolution

The one mechanism Pull and Sort share. A pure function, testable headlessly:

```
vo.ResolveItemNames(item_names, lines) -> { [i] = line_index | nil }, ambiguous
```

**Normalisation** — lowercase, trimmed, any file extension removed. So
`line_042`, `Line_042`, `line_042.wav` and `  line_042  ` are one key.

**The lookup holds two keys per line:** the script's own Filename (`asset`) and
the DELIVERED name (`asset` + Append, or the user's Item name override). Both
are names this tool generates, so recognising them is not a heuristic — it is
reading back what we wrote. This is what lets a second Pull see the items the
first one renamed, and lets Sort order a Selects track that has already been
pulled.

**Ambiguity** — when two script lines normalise to one key, that key resolves to
nothing and is reported. It is exactly the clash the Append column exists to
fix, and guessing between them would put one line's audio under the other's
name.

**An item that resolves to nothing is never touched.** Not moved, not renamed,
not counted as an error — counted in the summary as "N items not on the script"
so an empty run is never silently empty.

This is also what retires the "do not act on uncut items" rule: an uncut
recording carries the recording's name, which is not a script filename, so it
resolves to nothing and both tools skip it. One rule, not two.

## 4. Cut and Name

Splits each selected span out of its source item and names the piece **the plain
CSV filename** — no Append, no override, no uniquing. Clashes are fine and
expected at this stage; they are what Pull resolves. Leaves the piece on the
recording's own track.

Its existing gate stays: a line with several takes and no Select is a decision
the user has to make, and Cut says so rather than choosing.

What it no longer does: move anything, create any track, write any region.

## 5. Pull

Two of the four destinations are DELIVERED and two are not. That is the
distinction the routing exists to make:

| track | delivered | holds |
|---|---|---|
| `<CHARACTER> Selects` | yes | the take you are delivering, one per line |
| `<CHARACTER> Alts` | yes | takes you are also delivering, alongside the select |
| `<CHARACTER> Outs` | no | the rest of the session's takes, kept, not shipped |
| `<CHARACTER> Review` | no | a line whose delivery nothing has decided |

Items are grouped by the line they resolve to, and routed by what the Select
cell says (§5.1):

- **one item for the line** → renamed to the delivered name and moved to
  **Selects**, whether or not it is marked. One take is not a decision.
- **several items, one marked Select** → that one is renamed and moved to
  **Selects**; those marked Alt are renamed and moved to **Alts**; the rest go
  to **Outs**, unrenamed.
- **several items, none marked Select** → all move to **Review**, unrenamed, and
  are reported. Which one is the delivery is a decision, not a guess. An Alt
  without a Select is not a delivery either — it is half a decision, and it
  goes to Review with the rest of its group.

The Select cell is the ONLY thing Pull reads from the table, and it is read as
"which ITEM is this": the row carrying the mark names an item, and that item
takes the mark if it is one of the group. A rendered file with no row has no
mark, which is why a folder of unlabelled duplicates goes to Review — the rule
above already covers it, with nothing special-cased.

### 5.1 Select becomes three-state

The Select cell cycles **blank → Select → Alt → blank**. A line may carry one
Select and any number of Alts; marking a second row Select clears the first, as
it does today.

An Alt is a delivery, so it needs a filename of its own. **The user supplies
it**, through the Append column that already exists for two lines sharing a
filename — and an Alt with no Append shows the same red clash against its own
Select. Nothing is ever renamed automatically; that rule does not bend for alts.

In the project file the `Select` column carries `yes` for a select and `alt` for
an alt, in the same field. A file written before this reads `yes` as a select
and everything else as unmarked, so no version bump and no migration.

The **Select takes** button and Cut's gate both keep counting only Selects: an
alt does not answer the question "which take is the delivery".

### 5.2 Auto append alts

Typing an Append for every alt by hand is the tedious half of the rule above, so
the Pull panel offers to fill them in — on a press, never on its own. The
convention is yours to define, because it belongs to whoever you are delivering
to:

```
Auto append alts:  pattern [_alt{n}]  start at [1]  digits [1]   [Apply]
                   line_042_alt1, line_042_alt2, line_042_alt3
```

- **pattern** — free text. `{n}` is where the number goes; with no `{n}` the
  number goes on the end. `_alt{n}`, `_ALT{n}`, `-take{n}`, `{n}` alone, or a
  pattern with no number at all (a single alt needs no counter) all work.
- **start at** — the first alt's number. 1 gives `_alt1`; 2 gives `_alt2` and
  reads the select as take 1.
- **digits** — zero padding. 1 gives `_alt2`, 2 gives `_alt02`.
- the line under the controls previews the result against a real line from the
  current rows, so the convention is checked before it is applied.

Numbering runs per line, in timeline order, over the alts of that line only.

**It never overwrites an Append you typed.** Those rows are skipped and counted
in the summary — the button fills blanks, it does not impose a convention on
work you have already done. Clearing an Append by hand and pressing again is how
you change your mind.

Scope follows the same rule as every other tool here: the selected rows if any
are selected, otherwise every row currently shown. The pattern, start and digits
live in the settings beside the track names, since a delivery convention outlives
one project.

Destination tracks are created as **children of the item's current track**,
nested with `vo.FolderDepthForChild` — the same code `vo.EnsureSortChildTracks`
already uses. This is the bug this design fixes.

The `use_alts_track` toggle goes: with alts marked per take rather than switched
on per run, there is nothing for it to toggle. The `track_alts` name setting
stays and is joined by `track_outs`.

## 6. Sort

Unchanged in what it does — orders items on the timeline, on fresh child tracks
per source, one run number across the whole run — with one change in what it
acts on:

- **Script order** now means "in the order the script lists the lines", resolved
  by NAME. An item that resolves to nothing is left where it is.
- **Record order** is unchanged and still means "in the order they were
  captured", which needs a source position rather than a name. A rendered file
  has no position in a recording, so record order simply has fewer members.

The no-overlap guarantees are unchanged and are structural, not checks:

1. every run lands on **fresh** child tracks, so it cannot land on audio it was
   not asked to move
2. placement is a monotonic cursor (`pos = cursor; cursor = pos + length + gap`)
3. original spacing, the one mode that replays recorded offsets, clamps `pos` to
   the previous stop and counts every clamp into the summary
4. items overlapping on one track weld into one cluster and travel together, so
   crossfades survive

The panel reports what it is about to move — item count, recording count, and
how many items resolved to nothing — before it is pressed.

## 7. Character becomes a selection

Today's character *filter* hides rows. It becomes an *editing selection* that
constrains **matching**:

- only the selected character's lines enter the match index, the candidate
  search and the residual pass
- another character's line can never claim a take, including when two characters
  say the same words
- **an explicit lock still wins** — a pin is a decision the user made, and a
  selection must not override it

What it does NOT do: hide anything. Other characters' lines stay in the table
with no takes against them. They are not red "Missing" — a line you are not
editing is not missing — they carry a new quiet status, **Other**, styled like
Orphan, and the summary counts them apart from real missing lines.

It lives at the top of the Script panel (*Editing character: [ ▾ ]*), mirrored
beside the `Script:` label in the toolbar so it is visible when the panel is
shut, and it is stored in the project file. Changing it re-derives the match; it
never re-transcribes.

## 8. What is removed

- **The status filter presets.** The Status column's own filter box already
  matches Recorded / Review / Missing / Orphan / Flagged, and Lock covers
  verified. Six presets for what one filter box does.
- **`ajsfx_VO_Cut.lua`**, outright. Its gate moves into the Cut panel, its
  per-character track overrides into the Pull panel. There are no users to
  migrate.
- **The `use_alts_track` toggle**, per §5. The Alts track itself stays.

## 9. Testing

The pure layer carries the weight, as everywhere else in this project:

- `vo.ResolveItemNames` — case, extension, whitespace, delivered-name recognition,
  ambiguity, and the "resolves to nothing" path
- Pull's routing decision as a pure function of the resolution result and the
  Select marks: one item → select; several with a Select → select, alts, outs;
  several without → all review; an Alt with no Select → review; resolving to
  nothing → untouched
- the Select column's three states through a project-file round trip, including
  a file written before alts existed
- the alt-append pattern as a pure function: `{n}` placed anywhere or absent,
  start and padding, numbering per line, and an existing Append left alone
- the character selection's effect on `vo.BuildIndex` and `vo.ResidualPass`:
  an ineligible line never wins a window, and a pinned one still does
- child-track nesting reuses `vo.FolderDepthForChild`, which is already covered

The REAPER-coupled layer (splitting, moving, folder depth) stays thin and is
checked by `VO/MANUAL_TEST.md`, which gains a section per tool.

## 10. Deliberately not now

**Per-item verification.** Transcribing just a cut item, rather than the whole
raw recording, to confirm the piece holds the line it is named for — with word
positions written as item markers so the check stays attached to the item it
describes and travels with it. Recorded here so the idea is not lost; it needs
its own design, particularly around what keeps a marker set in sync with an item
that is later trimmed.
