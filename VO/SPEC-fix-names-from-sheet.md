# Fix names from the sheet

Status: BUILT in 0.15beta10. `vo.PlanNamesFromSheet` + `vo.IsConventionalAltName`
in the pure layer, `Trim.fix_names_from_sheet` and the button in Overview's Fix
row. NOT YET VERIFIED IN REAPER.

One thing below changed in the building. Rule 1 said a `name_override` always
wins verbatim. It cannot: `ApplyAltNames` STAMPS its generated name into
`name_override`, so after one press of "Auto-name the alts" every alt looks
hand-given and this verb would be a no-op on exactly the projects that need it.
An override that is only the convention applied to the line is renumbered; one
with anything else in it is obeyed. See `vo.IsConventionalAltName`. That also
answers the open question at the bottom of this file.

## The ask

A button that takes the SHEET as authority and renames items to match it —
selects and alts both. "Assume each line is in the right spot in the sheet, and
name it accordingly."

## Why it does not exist yet

Three verbs each do part of it and none does this:

- `ApplyAltNames` names alts only, and **fills blanks** — it never overwrites a
  name already there.
- `vo.PlanAdopt` fills a blank take name from its marker's asset. Same rule:
  "correcting one is a reassignment, which is Identify's job, not a trim's."
- `Trim.fix_names_from_transcript` overwrites, but its authority is the
  **transcript**, not the sheet.

So the gap is precisely: an OVERWRITING rename whose authority is the sheet.
That is a new claim, not a gap in an existing verb — which is why it needs its
own button rather than a flag on one of the three above.

## Authority

The sheet. Deliberately opposite to `fix_names_from_transcript`: that one is for
"I do not trust the name", this one is for "the sheet is right, make the
timeline say so". Both must exist because the user knows which they mean and the
tool cannot.

## The name each take should have

Per line, over its takes in row order:

1. `name_override` set          -> that name, verbatim. A hand-given name wins
                                   over any convention.
2. Sel ticked                   -> `row.deliver or row.asset`, plain.
3. Keep without Sel             -> `deliver .. vo.FormatAltAppend(pattern, n,
                                   digits)`, n counting alts from
                                   `alt_append_start` (1).
4. Neither Keep nor Sel         -> LEAVE ALONE. Not a take being delivered;
                                   renaming it would claim it is.

Numbering is keyed by `script_row`, same as `vo.PlanAltNames`, so two lines
sharing a filename number separately.

## What it writes

The item's take name (`P_NAME`). **That is all.**

The spec originally said to write the take marker's asset as well. That was
built, run once in REAPER, and reverted: the marker's asset is what the sheet
reads to decide which LINE a take belongs to, so writing the alt convention into
it re-pointed several takes of a line at the same row — every take reading as a
select, and every one jumping to the same line when clicked.

The marker names the **line**. The item name names the **delivery**. Only the
second is this verb's business. So this cannot move a take's Keep or Sel, and
should not: a take on the wrong line is a reassignment, which is Identify's job.

An uncut recording holds many takes in one item, and an item has one name. The
first take claims it, the rest are counted and reported — what they need is a
cut, not a rename.

## Build it as

`vo.PlanNamesFromSheet(rows, opts) -> edits, skipped` in the pure layer, tests
first. `opts = { pattern, start, digits }`. Returns
`{ { index, name }, ... }` like `vo.PlanAltNames` does, so the REAPER side stays
a thin writer.

Tests that must exist:

- a select gets the plain delivered name, its alts get `_alt1`, `_alt2`
- `name_override` beats the convention
- a row with neither Keep nor Sel is untouched
- two lines sharing a filename number their alts separately
- running it twice changes nothing the second time (idempotent)
- a line whose select is NOT ticked: every take is an alt, numbering still
  starts at 1

## Where it goes

Fix row, steps band, beside `Fix wrong names from transcript`. The two are the
pair: one takes the sheet's word, one takes the audio's.

## Open question, carried from this session

The user reports alts starting at `_alt2`. Verified live: `alt_append_pattern =
"_alt{n}"`, `alt_append_start = 1`, `alt_append_digits = 1`, and
`vo.PlanAltNames` computes the first alt as `n = (start - 1) + 1 = 1`. So the
default path is correct. Two by-design behaviours can still produce a visible
first alt of `_alt2`:

- an alt that already carries a `name_override` CONSUMES its number (so hand
  naming the second alt does not renumber the third)
- a take that is Keep without Sel IS an alt, so if the intended select was never
  ticked Sel it takes `_alt1` and the next take is `_alt2`

Resolve this BEFORE building the above — this verb inherits the same numbering,
and if the numbering really is off by one it is off by one in both.
