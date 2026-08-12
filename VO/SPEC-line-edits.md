# ajsfx VO — Editing a line, and copying one

**Status:** Designed, not implemented · **Date:** 2026-08-11

Type the words that were actually said, and the matcher scores against those.
The script's own line stays on the card underneath, in grey, and can always be
copied out.

---

## 1. The problem

The script says `Adon`. The read says `Bolvd`. Every take of that line then
scores badly against the only text the matcher has, and the line sits in the
sheet looking unrecorded while its audio is right there.

Today the only fix is the **substitution table** in Settings — global, one
entry per misheard word, and correct only when the word is wrong *everywhere*.
A line the director changed on the day is not a transcription problem and does
not belong in that table: `bolvd=adon` would rewrite every other line that says
Bolvd.

So: a per-line override. It is the same class of thing as an Append — a
judgement about one line, made by hand, that the CSV does not know about.

## 2. The data — Append's shape, reused

Append already solves "a per-line judgement, keyed to script + filename +
occurrence, round-tripped in the project file, absent when empty." A line edit
is the same record with a different meaning, so it reuses the same machinery
rather than inventing a parallel one:

```lua
vo.LineEditMap(rows)                            -- lookup map, built and thrown away
vo.SetLineEdit(rows, script, asset, nth, text)  -- the one mutator
vo.OrphanLineEdits(edits, lines)                -- edits whose line is gone
```

Project file row, beside `Append`:

```
Line,<script>,<asset>,<nth>,<text>
```

Held as an ARRAY of records, never a map keyed on the joined string — splitting
`label|asset|nth` back into three parts is ambiguous the moment a filename
contains the separator. That is `vo.AppendMap`'s reasoning and it applies here
unchanged.

**Setting an edit to empty removes the record.** "No edit" is the absence of
one, not a stored empty string — the rule `vo.SetAppend` and
`SerializeProjectFile` already apply. It also means `Revert to script line` and
"clear the field" are the same operation, and cannot disagree.

**An edit equal to the original is still an edit**, and is stored. Deciding
that the line is right as written is a judgement worth keeping; silently
dropping it would make the grey row flicker away and re-appear as the user
typed back to where they started.

## 3. How it reaches the matcher — one override, applied early

```lua
vo.ApplyLineEdits(lines, edits)
```

Runs immediately after `vo.MergeScriptLines`, which is where `append_key` is
minted and therefore the first point an edit can be looked up. For each line
with an edit:

```lua
line.text_original = line.text   -- what the CSV says
line.text          = edit        -- what was actually said
```

**Everything downstream is untouched**, which is the whole point of overriding
here rather than at each consumer:

| reads `line.text` | gets |
|---|---|
| the matcher (`ajsfx_vo.lua:2302`, `text_for[l.asset]`) | scores takes against the edited words |
| `vo.ExtraWords` | colours the take's extra words against the edited line |
| `vo.BuildOverview` | `row.line_text` is the edited text, so the card shows it |
| search (`row.line_text` in the haystack) | finds the line by what was said |

One override point, no second code path. A second path is how the sheet and the
matcher would come to disagree about what a line says — the exact failure this
feature would otherwise introduce.

`text_original` rides along on the line and into the card row, and is the only
new field the renderer needs.

**Re-matching is required, not automatic.** Changing the words invalidates
every score on that line, and re-running the match is a several-second pass
over every transcript. It is `Match transcript to script`'s job and the user
presses it.

**And there is no staleness badge**, deliberately. Editing the script CSV on
disk has the same consequence and carries no indicator either; the contract is
already "change the words, press Match". Inventing a badge for one of the two
ways to change a line — the rarer one — would teach that the other way is safe.
If scores-out-of-date turns out to need saying, it needs saying for both, and
that is its own change. The `Edit line…` popup names the requirement in a
single dim line instead: *press Match transcript to script to re-score.*

## 4. The card

### 4.1 The line stays text

The words render exactly as they do now — wrapped `im.Text`, in the transcript
column, in row 1. **Not an input field.**

Three reasons, and the third is the one that decides it:

1. The words are the biggest click target on the card, and clicking them
   unfolds it. That is the common action; editing is rare.
2. 169 live `InputTextMultiline` widgets is 169 child windows with their own
   state, every frame, for a field touched a dozen times in a session.
3. **ImGui's single-line `InputText` cannot wrap.** The line already wraps
   before the filename column, so an inline field would either scroll sideways
   — showing ~40 characters of a long line — or force `InputTextMultiline`,
   which is a bordered box in the middle of the card. Editing in a popup keeps
   the display code exactly as it is.

### 4.2 The grey original, below

`text_original`, drawn in the same `im.TextDisabled` grey as `Script:`, always
BELOW the line — never above. The line as it will be matched reads first; the
line as written is the reference under it.

| card is | shows the grey original |
|---|---|
| unfolded | **always**, edited or not |
| folded | only when edited |

**`Script:` shares this row.** It used to have a row of its own directly below.
Both are dim, both say where the line came from, and `Script:` sits out at the
left margin in a column the transcript text never reaches — so stacking them
spent a whole row of every open card on one short label. They are one
provenance row now: `Script: <name>` on the left, the script's own words in the
transcript column.

A folded card is one horizontal row and nothing else — that rule stands, so an
unedited folded card is unchanged. An unfolded card has a fixed shape you can
rely on, which is worth one row of height on a card you have deliberately
opened. On a folded card the grey row therefore MEANS something: this line was
changed.

When unfolded and unedited the two rows are identical text. That is not a bug
to design away: the grey row is a fixed place to look, and reading the same
words twice costs nothing next to checking whether a row is missing.

### 4.3 Right-click the line

```
Copy
Copy original line
──────────────────
Edit line…
Revert to script line      (greyed when there is no edit)
```

**Both Copy items are always present, and never move.** Sending someone a line,
or pasting it into a substitution, is a routine errand that has nothing to do
with whether the line was edited — a menu item that appears and disappears
makes the user check the menu before they can use it. When there is no edit the
two copy the same text, which is the correct answer to both questions.

`Revert to script line` is `im.MenuItem(ctx, ..., enabled)` with `enabled =
has_edit`, so it holds its slot rather than shifting `Edit line…` up under the
cursor.

### 4.4 Edit line…

The same popup mechanics as `##append_edit`: `im.OpenPopup` / `im.BeginPopup`,
the write deferred through `pending_action` so the project is not mutated
inside an ImGui frame.

- `im.InputTextMultiline`, about the width of the card, ~3 rows.
- Pre-filled with the current text — the edit if there is one, the CSV line if
  not. Typing over what is there is the gesture.
- Committed on `Ctrl+Enter` or on the popup closing; `Escape` discards.
  Multiline inputs take Enter as a newline, so Enter cannot be the commit.
- A `Revert to script line` button beside the field, so the popup can undo
  itself without reopening the menu.

Not a `core.Transaction`: this writes no items and no markers. It marks the
project file dirty, exactly as `SetAppend` does.

### 4.5 Right-click the script and the filename

The same errand, in the two other places it comes up:

- **`Script:`** — right-click copies the FULL path. The card shows a basename
  with its extension stripped, so the thing displayed is not the thing anyone
  needs to paste.

  **Corrected during implementation:** this spec claimed the tooltip already
  carried the full path. It did not. `row.script` is the script's *label*
  (`vo.ScriptLabel` — sanitized basename, no extension), so the tooltip was
  showing the same string as the text beside it, and a naive `Copy(row.script)`
  would have copied a label while promising a path. The path lives only on the
  loaded script, so both the tooltip and the menu item now look it up by label
  in `state.loaded.scripts`; `Copy full path` is greyed if no loaded script
  answers to that label.
- **the filename** — already has `Copy` (`##band_name_menu`). Unchanged.

## 5. Testing

Pure layer, in `tests/test_vo.lua` beside the Append tests:

1. `SetLineEdit` stores, replaces, and — set to empty — REMOVES the record.
2. An edit equal to the original is stored, not silently dropped.
3. `LineEditMap` keys by script + asset + nth; the same filename in two scripts
   keeps its own edits.
4. `ApplyLineEdits` moves the CSV words to `text_original` and puts the edit in
   `text`; a line with no edit gets neither field disturbed.
5. The matcher scores against the edited text — the case this exists for: a
   line reading `Adon`, a take saying `Bolvd`, scores poorly before the edit
   and matches after it.
6. `OrphanLineEdits` reports an edit whose line is no longer in any enabled
   script, and does not report a live one.
7. The project file round-trips a `Line` row, including text containing a
   comma and a quote.
8. A `Line` row for a line that no longer exists is READ, not dropped —
   orphans are reported, and disabling a script must not destroy its edits.

The card rendering is not unit-testable (the suite cannot load the Overview
script); it goes into `VO/MANUAL_TEST.md`.

## 6. Not doing

- **Editing the CSV on disk.** The script file is the author's; an edit here is
  this project's judgement about it, which is why it lives in the project file
  beside the Appends.
- **Auto re-matching on edit.** §3.
- **A bulk edit pass, or suggesting edits from the transcript.** The
  substitution suggester in `SPEC-marker-is-the-row.md` §7 is the tool for
  finding these at scale; this is the one-at-a-time fix.
- **Touching the delivered filename.** The filename comes from the CSV's asset
  column and the Append. Editing the words does not rename the file.

## 7. Success criteria

- A line whose read differs from the script can be made to match, without
  touching the global substitution table.
- The script's own words are never lost and are always one right-click from the
  clipboard.
- An unedited card looks and behaves exactly as it does today when folded.
- The sheet and the matcher can never disagree about what a line says.
