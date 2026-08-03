# ajsfx VO — Multiple Script CSVs & the Append Column — Design Spec

**Status:** Approved for planning · **Version:** 1.0 · **Date:** 2026-08-02

A character can record lines from several scripts in one session. Today a REAPER project
holds exactly one script CSV and one column mapping, so a second script means a second
project. This spec makes the script side a **list**: any number of CSVs, each with its own
column mapping and its own on/off switch, managed from a panel Overview owns.

Two scripts will sometimes deliver the same filename. Rather than rename anything behind
the user's back, the delivered name gains a second, user-typed part — an **Append** column —
and any name claimed by two script lines is shown in red until the user separates them. The
same rule covers two lines *within* one script that share a filename, a case that previously
had no fix at all.

Extends `VO/SPEC.md`, `VO/SPEC-csv-layout-filtering.md` and `VO/SPEC-overview.md`; the
pure/coupled layer split is used as defined there.

---

## 1. Goals and non-goals

### Goals
- A project holds an **ordered list of scripts**, each `{ path, mapping, enabled }`.
- Column mapping is **per script** — two CSVs from different games can be loaded together.
- A **Script panel** inside Overview manages the list: add, remove, enable/disable, map columns.
- One universal rule for duplicate delivered names: an **Append** column the user types into,
  with duplicates flagged **red** until the resolved names are unique.
- Existing single-script projects open unchanged, with no migration step for the user.

### Non-goals (this version)
- No automatic renaming, suffixing or prefilling of any filename. Ever. The user types.
- No per-script skip tokens or per-script character filter — both stay as they are.
- No change to matching, transcription, thresholds, cutting geometry or the backend.
- No reordering of scripts by drag. The list is in the order scripts were added.

---

## 2. Decisions (settled in brainstorming)

- Script manager = **a child window Overview owns**, like Settings and Find candidates —
  not a fourth sibling script. Scripts only matter to Overview's match, and a panel cannot
  fall out of sync with the project file the way a separate process could.
- Per-script settings = **column mapping + enabled toggle**. Skip tokens stay global.
- Duplicate handling = **the Append column**, not an automatic CSV-name suffix. One rule for
  cross-script and within-script clashes alike.
- Append is **per script line** — set it on any take, every take of that line shows it.
- `name_override` **wins outright**: an override means "call it exactly this", and never
  compounds with Append.
- Red is driven by the **resolved** name, so it clears the moment the clash is actually fixed.

---

## 3. Data model

### 3.1 Scripts

```
scripts = {
  { path = "D:/game/Chapter2.csv", mapping = { asset=…, text=…, speaker=… }, enabled = true },
  { path = "D:/game/Chapter5.csv", mapping = { … },                          enabled = true },
}
```

Ordered; the order is the order scripts were added. Duplicate paths are refused on add.
A script's **label** is `vo.ScriptLabel(path)` — the basename with its extension removed,
sanitized. Labels are used for display and as part of the Append storage key.

### 3.2 Script lines

`vo.BuildScriptLines` is unchanged. Merging adds `script` (the label of the script the line
came from) and `append_key` (§3.3) to each line. A later pass, `vo.ResolveNames`, adds:

| Field | Meaning |
|---|---|
| `deliver` | the **resolved** delivered name (§4.2). `asset` keeps the raw CSV value. |

`asset` remains the raw filename cell throughout: matching, take grouping and the Filename
column all continue to read it, so nothing downstream changes behaviour when Append is empty.

### 3.3 Line identity (the Append key)

Append is stored against a script line, but the project file's entry rows are keyed by a
stretch of audio, so it cannot live in an entry. The key is:

```
vo.AppendKey(script_label, asset, nth)
```

Appends are held as an **array of records**, not as a map keyed by the joined string:

```
appends = { { script = "Chapter2", asset = "line_042", nth = 1, text = "_ch2" }, … }
```

The array is what the project file round-trips and what the windows hold; `vo.AppendMap`
folds it into a `key → text` lookup for resolution, and `vo.SetAppend` is the one mutator.
Splitting a joined key back into three parts would be ambiguous the moment a filename
contained the separator, so the parts are never joined for storage.

`nth` is the 1-based occurrence index of that `asset` **within that script**. Row
numbers were rejected: inserting a line at the top of a CSV would orphan every Append below
it. The occurrence index survives insertions, deletions and edits elsewhere in the script;
it breaks only if two lines sharing one filename are reordered relative to each other within
a single script, which is accepted.

---

## 4. Pure layer (`VO/lib/ajsfx_vo.lua`, all unit-tested)

### 4.1 New functions

| Function | Purpose |
|---|---|
| `vo.ScriptLabel(path)` | `D:/game/Chapter2_Script.csv` → `Chapter2_Script`. Basename, extension stripped, `vo.SanitizeName` applied. Returns `""` for an empty path. |
| `vo.AppendKey(script_label, asset, nth)` | The stable per-line key, `label \| asset \| nth`. Components are already sanitized or CSV-quoted at the storage layer. |
| `vo.MergeScriptLines(scripts)` | Takes `{ { label=, lines={…}, enabled= }, … }`, returns one flat ordered list: script order, then row order within each script. Disabled scripts contribute nothing. Each line gains `script` and an `append_key`. **No filename is modified.** |
| `vo.AppendMap(append_rows)` | Folds the append array into `{ [AppendKey(…)] = text }`. |
| `vo.SetAppend(append_rows, script, asset, nth, text)` | The one mutator: adds, updates, or (on empty text) removes a record. Returns the array. |
| `vo.ResolveNames(lines, appends)` | Attaches `deliver = asset .. (appends[append_key] or "")` to every line, where `appends` is the map from `AppendMap`. An all-whitespace Append counts as empty. |
| `vo.DuplicateNames(rows)` | Row-level clash detection for the highlight (§4.3). |
| `vo.LoadScripts(entries, read_fn)` | Shared loader (§5.1). Pure given `read_fn`. |

### 4.2 Resolution rule

Two levels, because Append is per script **line** while `name_override` is per **take**:

```
line.deliver   = asset .. append              -- append may be ""; no separator inserted
take name      = name_override or line.deliver
```

No separator is inserted by the code. If the user wants `line_042_ch2` they type `_ch2`.
`name_override` wins outright and never compounds with Append — an override means "call it
exactly this".

### 4.3 Two clash checks, one rule

`vo.DuplicateAssets(lines)` is **line-level**: it compares `deliver or asset` instead of
`asset`, keeping its return shape (`{ asset, rows, texts }`, first-appearance order) with
`asset` now carrying the resolved name and `rows` spanning scripts. Both Overview and Cut
already call it for their summary and their pre-cut report, and both keep doing so.

`vo.DuplicateNames(rows)` is **row-level** and new. It exists because a per-take
`name_override` can separate a clash the line-level check still sees, or recreate one it
does not. Given overview rows carrying `line_key`, `deliver` and `name_override`, it
resolves `name_override or deliver` per row and returns the set of names claimed by rows
belonging to **two or more different script lines**. Takes of one line never flag each other.
This set drives the red highlight (§6.4).

### 4.4 Other changed functions

| Function | Change |
|---|---|
| `vo.AssignNames(spans, cfg)` | Names from `s.deliver or s.asset`. Take **grouping** is unchanged — it keys on the script line, not the delivered name, so two lines that still share a name keep their takes apart. |
| plan composition | `deliver` rides the candidate → span the same way `character` already does. Gap/unmatched spans carry `deliver = nil` and are named as today. |
| `vo.SerializeProjectFile` / `vo.ParseProjectFile` | §5.2. |

---

## 5. Coupled layer

### 5.1 Shared script loading

`ajsfx_VO_Overview.lua` and `ajsfx_VO_Cut.lua` each keep their own near-identical `LoadCSV`
today. Both are replaced by one call:

```
vo.LoadScripts(script_entries, read_fn)
  -> { scripts = { { path, label, mapping, enabled, header, rows, error }, … },
       lines   = <merged, in order> }
```

Per script: read the file, `vo.ParseCSV`, pop the header, `vo.ValidateHeaderNames`,
`vo.MapColumns`, `vo.BuildScriptLines`. Any failure sets that script's `error` and
contributes **no lines**; the other scripts still load. `read_fn` is injected so the whole
thing is testable headlessly.

`vo.ResolveNames` is applied by the caller, after the project file's appends and overrides
are known.

### 5.2 Project file (`<project>_vo.csv`)

The preamble gains two repeated row types:

```
Script,<path>,<encoded mapping>,<yes|>
Append,<script label>,<filename>,<nth>,<text>
```

- `PROJECT_VERSION` stays **1**. The change is additive and old files stay readable.
- **Backward compatibility:** `ParseProjectFile` still recognises the old `Script CSV` and
  `Mapping` rows. When present and no `Script` row exists, they fold into a single enabled
  script entry. `SerializeProjectFile` writes only the new rows, so a project migrates
  silently the first time it saves.
- An `Append` row with an empty text is not written — the project file holds judgements only,
  consistent with the existing `has_work` rule for entry rows.
- An `Append` row naming a script that is no longer in the list is **retained on rewrite**,
  so removing a script and adding it back does not lose the user's work. It is inert while
  the script is absent.

### 5.3 Match invalidation

`MatchKey` folds in, per script and in order: `path`, `vo.SerializeLayout({mapping=…})` and
the enabled flag. Ticking a script off, remapping one of its columns, or adding a script
re-matches instantly from the stored transcripts, exactly as swapping the single CSV does
today.

Appends and overrides are **not** in the match key: they change only the delivered name, not
which audio matches which line, so a rename must not cost a re-match.

---

## 6. UI

### 6.1 Toolbar

```
Script:  Chapter2_Script.csv +2 more     [Script] [Sources…] [Cut…] [Settings]
```

`Columns…` is removed — mapping now lives per row in the Script panel. The label shows the
first enabled script's basename plus a count of the rest, with the full list in a tooltip.
No scripts, or none enabled, reads `none chosen` as today.

### 6.2 The Script panel

A child window Overview owns, toggled by `[Script]`, drawn after the main window's `End` so
it is a sibling — the pattern the Settings and Find-candidates windows already use. It opens
itself when a script fails to map, the way `mapping_open` does today.

```
Scripts                                              [Add script…]
☑  Chapter2_Script.csv    Filename[▾] Line text[▾] Character[▾]   [Remove]
☑  Chapter5_Script.csv    Filename[▾] Line text[▾] Character[▾]   [Remove]
☐  Pickups.csv            ⚠ Filename column not mapped            [Remove]
```

- **Enabled** checkbox: a disabled script stays in the list and in the project file but
  contributes no lines and takes no part in matching or duplicate detection.
- **Name**: basename; tooltip is the full path.
- **Three combos** per script, populated from that script's own header, auto-detected on
  first load via the existing `vo.AutoDetectMapping`, overridable. Character offers `(none)`.
- **Per-row error** replaces the combos when the file is unreadable, empty, or its header is
  rejected.
- **[Add script…]** opens `GetUserFileNameForRead` starting in the project's folder (the
  existing behaviour), and refuses a path already in the list with a message.
- **[Remove]** drops the script; its Appends are kept (§5.2).

### 6.3 The Append column

A new table column immediately right of **Filename**, inline-editable like Notes, sortable
and filterable through the existing column machinery. Empty by default; nothing is prefilled.

Editing it on any take writes it for **every take of that script line** — the value is stored
per line, so all takes of the line redraw with it. Editing is a project-file change and marks
the state dirty like any other edit.

### 6.4 Duplicate highlighting

Driven by `vo.DuplicateNames` (§4.3) over the visible rows of every enabled script. For each
row whose resolved name is claimed by a *different* script line:

- the **Filename** cell draws its text red;
- the **Append** cell draws a red background.

Both appear on every take of the line, and both clear the frame the resolved names differ —
including when the separation comes from a `name_override` rather than an Append. An override
that *recreates* a clash turns red the same way.

A row with a `name_override` shows the red on its Filename cell only: its Append is not what
would fix it. Clearing the override hands it back to the Append rule.

The summary line reports the count from the same check:
`3 filenames are delivered by more than one line.` This replaces the existing within-script
duplicate note, which said the same thing about a narrower case.

### 6.5 A new Script column

Overview gains a **Script** column carrying each line's script label, immediately right of
Character — sortable and filterable like every other column. Without it there is no way to
tell which CSV a line came from once several are loaded.

It is **always visible**, not hidden by default: this table deliberately does not support
per-column visibility (`DrawHeaderMenu` replaces ImGui's built-in column menu precisely
because visibility is unsupported), and adding that machinery is not worth it here. A user
who does not want the column drags it narrow, and the width persists like any other.

---

## 7. Error handling

- **One bad script, others fine.** An unreadable file, an empty file, a header rejected by
  `ValidateHeaderNames`, or a missing required mapping disables **that script only**. Banner:
  `1 of 3 scripts is not usable — press Script.` The rest match normally.
- **No scripts / none enabled** → the existing "none chosen" empty state; nothing runs.
- **Duplicate path on add** → refused with a message; the list is unchanged.
- **Append that sanitizes to nothing** (e.g. only characters `SanitizeName` strips) → the
  resolved name falls back to the raw `asset`, and the clash stays red. The Append cell shows
  what the user typed; it is sanitized only where it reaches a take name.
- **Project file unreadable** → unchanged: saving stays off and the window says so.
- **A script file that disappears between sessions** → that script shows its read error in the
  panel and contributes nothing; it is not silently dropped from the list.

---

## 8. Testing

### Pure / headless (`tests/test_vo.lua`)
- `ScriptLabel` — extension stripped, path separators handled, sanitized, empty path.
- `AppendKey` — stable across an unrelated row insertion; distinct for the 1st and 2nd
  occurrence of one filename within a script; distinct across two scripts.
- `MergeScriptLines` — order is script-then-row; a disabled script contributes nothing; no
  filename is modified; `script` and `append_key` are attached.
- `ResolveNames` — append concatenates with no separator; whitespace-only append is empty;
  a missing key leaves `deliver == asset`.
- `DuplicateAssets` — a cross-script clash and a within-script clash are reported
  identically; the clash clears once appends differ.
- `DuplicateNames` — takes of one line never flag each other; an override that separates a
  clash clears it; an override that recreates one is reported; an empty override is ignored.
- `LoadScripts` (with a stub `read_fn`) — one failing script does not stop the others; the
  failing script contributes no lines and carries an `error`.
- Project file — `Script` and `Append` rows round-trip; an old `Script CSV` + `Mapping` file
  parses into one enabled script; an `Append` naming an absent script survives a rewrite.
- `AssignNames` — names from `deliver`; grouping is still by script line, so two lines that
  still share a name keep their takes apart.

### Manual (`VO/MANUAL_TEST.md`, REAPER)
- Add a second script; both scripts' lines appear; the Script column distinguishes them.
- Disable a script; its lines vanish and the match re-runs with no re-transcription.
- Remove a script, add it back; its Appends are still there.
- Two scripts delivering one filename: both go red, type an Append on one, both clear.
- Two lines within one script sharing a filename: same behaviour.
- Rename with the existing Name override so it separates a clash: red clears.
- Run Cut: clips carry the appended names.
- Open a project saved by the previous version: its single script and mapping are intact.

---

## 9. Deferred (captured, not built)

- **Per-script skip tokens and character filter.** Both are global/per-run today and no
  concrete need has appeared for splitting them per script.
- **Reordering scripts.** The list is add-order; drag-to-reorder is UI work with no
  behavioural payoff, since merged order only affects the `#` column.
- **Suggesting an Append.** Deliberately excluded — the whole point of this design is that
  nothing renames a delivered file except the user.

---

## 10. Versioning & release

Per `.agents/standards.md`: bump `@version` + `@changelog` on `ajsfx_VO_Overview.lua` and
`ajsfx_VO_Cut.lua` (indexed packages) and on the `@noindex` lib. `index.xml` is CI-rebuilt on
merge; confirm the run is green afterwards.

---

## 11. Implementation phases (for the plan)

1. **Pure layer, test-first:** `ScriptLabel`, `AppendKey`, `MergeScriptLines`,
   `ResolveNames`, `DuplicateNames`, `LoadScripts`; the `DuplicateAssets` change; `deliver`
   threading through plan composition and `AssignNames`.
2. **Project file:** `Script` and `Append` rows, plus the old-format fallback (§5.2).
3. **Overview — script list:** replace `state.script_csv`/`state.mapping` with `state.scripts`,
   route loading through `vo.LoadScripts`, extend `MatchKey`.
4. **Overview — Script panel** (§6.2) and the toolbar change (§6.1).
5. **Overview — Append column, red highlighting, Script column** (§6.3–6.5).
6. **Cut:** drop its private `LoadCSV` in favour of `vo.LoadScripts`; verify names.
7. **Docs & versions:** `MANUAL_TEST.md` sections, `@version`/`@changelog` bumps.
