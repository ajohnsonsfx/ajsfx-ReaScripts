# ajsfx VO — Per-Project CSV Layout & Filtering — Design Spec

**Status:** Draft for review · **Version:** 0.2 · **Date:** 2026-07-23
**Revision 0.2:** rewritten after an independent adversarial review of 0.1 — corrects the
`line_id` requirement, adds character canonicalization, robust preset storage, overwrite
confirmation, explicit removal of the old free-text filters, and the dialog lifecycle.

> **Post-0.2 amendment (2026-07-23, after in-REAPER testing):** the mapping is simplified
> to just three roles — **Character** (optional), **Filename** (required), **Line Text**
> (required). The **LineID** and **Type** columns are removed: LineID was never used by the
> matcher, and the **Filename** is now the line's identity (repeated takes group by it, and
> `AssignNames`/`BuildReport` key off it). The Type column and its future timeline-grouping
> TODO are dropped for now. Where sections below say `line_id` is required or `type` is
> mapped, read this amendment instead. (A separate fix in the same change hardens
> `ApplyPlan` against zero-length spans — see `vo.MIN_SPLIT_LENGTH`.)

Move CSV handling out of global Settings and into the **ajsfx VO ScriptMatch** run
dialog, where it belongs: a game project's CSV format is consistent across many REAPER
sessions but differs between games. Replace hand-typed column names with **header-driven
dropdowns**, add **named CSV Layout presets** for reuse across a game, add a **multi-select
character filter**, and route matched clips to **per-character track sets**.

Extends `VO/SPEC.md` and `VO/SPEC-backend-acquisition.md`; terms and the pure/coupled layer
split are used as defined there.

---

## 1. Goals and non-goals

### Goals
- CSV **Layout** (column mapping + skip tokens) and **filtering** live in ScriptMatch, not
  global Settings.
- No hand-typing of column names: after a CSV is loaded, each role is a **dropdown of the
  file's actual header columns**, auto-detected on first load and overridable.
- **Named "CSV Layout" presets** (Save / Save As / Load / Delete), stored globally, reused
  across every REAPER session of a game. The current layout + CSV path also auto-persist
  **per REAPER project** (`.rpp`) for convenience.
- **Character filter:** a multi-select of the distinct values in the mapped character
  column, all included by default; uncheck to exclude. Per-run (not saved in the layout).
- **Per-character routing:** each matched clip goes to `<Character>_<Base>`
  (Base ∈ Selects/Alts/Review, base names from Settings), each track created only when it
  actually receives a clip.

### Non-goals (this version)
- **Type-based organization.** The Type column is still mapped, but nothing acts on it yet.
  See §9 (deferred).
- **Substitutions stay global** in Settings (matching/vocabulary tuning, not CSV structure).
- **Preset rename** — deferred (§9); Save As under a new name + Delete covers it for now.
- No change to matching, transcription, thresholds, or the backend.

---

## 2. Decisions (settled in brainstorming)

- Persistence = **named presets + per-`.rpp` auto-memory** (both).
- Character filter = **multi-select, all-on by default** (exclude by unchecking).
- Type = **mapped but unused** this version.
- Substitutions = **remain in global Settings**.
- Per-character prefix applies **whenever a character column is mapped**, even for a single
  character (predictable). No character column mapped → today's plain `Selects/Alts/Review`.

---

## 3. Data model

A **Layout** is the reusable description of a game's CSV format:

```
layout = {
  mapping = { line_id=<col>, text=<col>, asset=<col>, speaker=<col>|nil, type=<col>|nil },
  skip_values = { "TO RECORD", ... },   -- asset cells that mean "not yet recorded"
}
```

- **Required roles:** `line_id`, `text`, `asset` (filename) — matching the shipped
  `vo.REQUIRED_COLUMNS`. `line_id` is load-bearing: take-grouping and naming key off it
  (`FindCandidates`/`AssignNames`), so it must be mapped or duplicate takes collapse.
- **Optional roles:** `speaker` (character — mapping it enables per-character routing),
  `type` (mapped, not acted on).
- `skip_values` is a **multi-token list** (the current multiline behavior is preserved).
- Filter selections (which characters to include) are **run state**, not part of the layout.

**Character canonicalization.** A game CSV can spell a character inconsistently
(`Guard` / `guard` / `Guard `). To avoid duplicate checkboxes and duplicate tracks, one
**canonical display form per case-insensitive key** is chosen (first-seen wins). The filter,
the line-build, and the track name all use that canonical form, so every spelling of a
character collapses to one filter entry and one track set.

---

## 4. Pure layer (new / changed in `VO/lib/ajsfx_vo.lua`, all unit-tested)

| Function | Purpose |
|---|---|
| `vo.DistinctCharacters(rows, col_index)` | Ordered list `{ {key=<folded>, display=<first-seen trimmed>}, … }`, de-duplicated by folded key, empties skipped. Also usable to build a `folded→display` canonicalizer. Feeds the character multi-select. |
| `vo.AutoDetectMapping(header)` | Best-guess `role→columnName` by case-insensitive match of header names against a per-role **alias set** (speaker ⇐ {speaker, character, char, actor}; asset ⇐ {audioasset, filename, asset, file, wav, output}; text ⇐ {text, line, dialogue, vo}; line_id ⇐ {lineid, id, line_id, cue}; type ⇐ {type, category, kind}). Unmatched roles omitted. |
| `vo.SerializeLayout(layout)` / `vo.DeserializeLayout(text)` | Round-trip a layout to/from a tab-delimited, line-based string (`role\tcolumnName`, `skip\ttoken`). **Import validation (below) guarantees no mapped column name contains a tab or newline**, so the encoding is unambiguous. |
| `vo.ValidateHeaderNames(header)` | Returns ok / error: rejects header column names containing a tab or newline (unsupportable in the layout encoding, and pathological in real CSVs). Called on load. |
| `vo.ValidatePresetName(name)` | Non-empty, ≤ 64 chars, no newline/tab/`=` (the name becomes part of the ExtState **key** `preset:<name>`, and REAPER persists ExtState as `key=value`); not the reserved token `__names__`. |
| `vo.CharacterTrackName(character, base)` | `SanitizeName(character).."_"..base` when `character` is a non-empty string, else `base`. |
| **`vo.BuildScriptLines` (changed)** | Character filter becomes an **include-set**: `filters.speakers = { [foldedKey]=true }` (nil ⇒ all; empty table ⇒ none). Each kept line's `speaker` is rewritten to its **canonical display** form (via a `filters.canonicalize` map) so downstream routing is spelling-stable. The existing `skip_values` and `type` filter behavior is retained unchanged (ScriptMatch simply passes no `type` filter). |
| **plan composition (changed)** | Candidates already carry `line_idx` (ajsfx_vo.lua:589); attach `character = lines[line_idx].speaker` (already canonical from BuildScriptLines) onto each candidate, carried through `SelectSpans`/`AssignNames` to the final span. Gap/unmatched spans carry `character = nil`. |

`REQUIRED_COLUMNS`/`OPTIONAL_COLUMNS` and `MapColumns` are unchanged.

---

## 5. Coupled layer

### 5.1 Routing (`vo.ApplyPlan`, changed)
Compute the base name with the existing safety fallback, then per-character:

```
base      = dest_names[span.dest] or dest_names.review   -- keep the nil-guard
full_name = vo.CharacterTrackName(span.character, base)
```

Cache ensured tracks keyed by `full_name` (not by `span.dest`), so each `<Character>_<Base>`
track is created lazily on first use via `EnsureTrackBelow(source_track, full_name)`.
- A **matched** span (including review-confidence) carries a character → `<Character>_Selects`
  / `<Character>_Alts` / `<Character>_Review`.
- An **unmatched** gap span has no character → plain `Review` (base name), never per-character.
- No character column mapped → every span has `character = nil` → today's plain behavior.

Region creation and take naming are unchanged (region/clip name stays the asset name).

### 5.2 Layout preset storage (global ExtState, section `ajsfx_vo_layouts`)
- `__names__` = newline-joined preset names, ordered (names validated to contain no newline).
- `preset:<name>` = `SerializeLayout(layout)` (the `preset:` prefix keeps a preset value from
  ever colliding with `__names__`).
- Helpers: `SaveLayoutPreset(name, layout)`, `LoadLayoutPreset(name)`, `ListLayoutPresets()`,
  `DeleteLayoutPreset(name)` — thin ExtState wrappers over the pure serializer.
- **Overwrite is explicit:** saving onto an existing preset name prompts for confirmation
  (ExtState writes bypass undo, so a silent clobber is unrecoverable). `ValidatePresetName`
  gates the name first.

### 5.3 Per-`.rpp` memory (`ProjExtState`, section `ajsfx_vo`)
- `script_csv` (exists), plus `layout` = `SerializeLayout(current)` and `layout_name` =
  selected preset name (empty when the inline mapping is unsaved).
- **Restore precedence on open:** if `layout_name` names a preset that still exists, load that
  preset; else fall back to the inline `layout`; else auto-detect from the header. The CSV
  path restores independently.

---

## 6. UI — ScriptMatch run dialog

Rework `ajsfx_VO_ScriptMatch.lua`'s dialog. **The current free-text `Speaker` and `Type`
filter inputs are removed** and replaced as below.

1. **Script CSV** — path + Browse (exists).
2. **Layout** — preset dropdown + **Save / Save As… / Delete**; below it a **role dropdown per
   column**: **LineID\***, **Text\***, **Filename/AudioAsset\*** (required), **Character**,
   **Type** (optional; each optional includes a `(none)` entry). Dropdowns list the loaded
   header's column names. Auto-detected on first load; editing marks the layout dirty
   (dropdown shows `(unsaved)`). A **Skip tokens** multiline field (part of the layout,
   default `TO RECORD`).
3. **Filters** — **Character** multi-select (checkbox per canonical value, all checked),
   shown only when a Character column is mapped.
4. **This session** — existing alts / suffix / primary toggles (unchanged).
5. **Transcribe and cut** — unchanged flow; on run, `MapColumns` uses the active layout's
   mapping and `BuildScriptLines` uses the character include-set + canonicalizer.

### 6.1 Dialog lifecycle (header ↔ dropdowns)
- **On open / on CSV path change:** if the path is readable, parse the header once and run
  `ValidateHeaderNames`; on failure show the error and leave the run disabled. Then
  (re)populate every role dropdown and the character list from the new header.
- **Restoring a layout** (preset or per-`.rpp`): for each role, if the remembered column name
  is present in the current header, select it; if absent, that role becomes **unmapped**. A
  missing **required** role disables the run with a clear message until the user picks one.
- **Character list** is rebuilt whenever the header or the mapped character column changes;
  previously-unchecked characters that still exist stay unchecked, new ones default checked.

### Settings changes (`ajsfx_VO_Settings.lua`)
Remove the column-mapping and skip-value fields from the "Script CSV" panel; keep the
**Substitutions** editor (rename the panel to "Substitutions"). Backend / Matching / Output
panels unchanged. `DEFAULT_COLUMN_MAPPING` stays as the auto-detect seed; the user-editable
global `column_mapping` is no longer surfaced (`LoadConfig`/`SaveConfig` keep it for
backward compatibility; nothing else reads it once the layout system is in place).

---

## 7. Error handling
- CSV unreadable / no data rows / missing a **required** role → clear message, nothing runs.
- Header column name containing a tab/newline → `ValidateHeaderNames` error, run disabled.
- No character column mapped → routing falls back to plain `Selects/Alts/Review`; the
  character filter section is hidden.
- Character filter with everything unchecked → "No characters selected", nothing runs.
- Character spelled inconsistently (`Guard`/`guard`) → collapsed to one canonical filter
  entry and one track set (§3 canonicalization). (Two names differing only by a character
  `SanitizeName` maps to `_` — e.g. `Guard M` vs `Guard/M` — still share one track; character
  names rarely carry such separators, so this is accepted.)
- Save/Save As onto an existing preset name → confirmation prompt before overwrite; invalid
  name → rejected with the `ValidatePresetName` reason.
- Deleting the active preset → dropdown falls back to `(unsaved)` with the inline mapping
  retained; other `.rpp`s referencing that name fall through to their inline layout (§5.3).

---

## 8. Testing

**Pure / headless (`tests/test_vo.lua`):**
- `DistinctCharacters` — order, fold-dedup (`Guard`/`guard` → one), trim, empties skipped,
  display = first-seen.
- `AutoDetectMapping` — alias/case-insensitive matches; unmatched roles omitted.
- `SerializeLayout`/`DeserializeLayout` — round-trip incl. column names with spaces and
  commas; and `ValidateHeaderNames` rejects tab/newline.
- `ValidatePresetName` — empty, over-length, newline/tab, reserved `__names__`.
- `CharacterTrackName` — with/without character, sanitization of unsafe characters.
- `BuildScriptLines` — character include-set (subset kept, others dropped), nil ⇒ all,
  empty ⇒ none, canonical rewrite of `speaker`, skip-token still honored, `line_id` populated.
- plan composition — a span from a `speaker="Guard"` line carries canonical `character="Guard"`
  (even when the row said `guard`); gap/unmatched spans carry `nil`.

**Manual (`VO/MANUAL_TEST.md`, REAPER):** dropdowns populate from a real header; auto-detect;
required-role-missing disables run; Save/Save As (with overwrite confirm)/Load/Delete;
per-`.rpp` restore incl. a column that disappeared from a swapped CSV; character multi-select
narrows the run; per-character tracks (`Guard_Selects`, `Hero_Review`, …) created only when
populated; a CSV with no character column still routes to plain tracks; an unmatched slate
lands on plain `Review`, not `<Character>_Review`.

---

## 9. Deferred (TODO — captured, not built)
- **Type-based organization on the timeline:** group clips by Type (all barks together, all
  dialogue together), and/or route Types to separate tracks or sub-tracks. Design open; the
  Type column is already mapped so the data is available when this is picked up.
- **Preset rename.** Save As + Delete suffices for now.
- **Character in the run report.** `BuildReport` currently omits the destination
  character/track; a column could be added when the report is next revised.

---

## 10. Versioning & release
Per `.agents/standards.md`: bump `@version` + `@changelog` on `ajsfx_VO_ScriptMatch.lua`
(indexed package) and the `@noindex` lib and Settings; `index.xml` is CI-rebuilt on merge.

---

## 11. Implementation phases (for the plan)
1. **Pure layer, test-first:** `DistinctCharacters`, `AutoDetectMapping`,
   `Serialize/DeserializeLayout`, `ValidateHeaderNames`, `ValidatePresetName`,
   `CharacterTrackName`; the `BuildScriptLines` include-set + canonicalization change; the
   span `character` threading. All covered in `tests/test_vo.lua`.
2. **Preset & per-`.rpp` storage:** the coupled ExtState/ProjExtState wrappers (§5.2/§5.3).
3. **Routing:** `ApplyPlan` per-character track naming (§5.1) — manual-tested like the
   existing apply layer, with `CharacterTrackName` and the threading covered in phase 1.
4. **ScriptMatch dialog rework** (§6) incl. lifecycle (§6.1).
5. **Settings trim** (§6 Settings changes) + docs/version bumps + `MANUAL_TEST.md` sections.
