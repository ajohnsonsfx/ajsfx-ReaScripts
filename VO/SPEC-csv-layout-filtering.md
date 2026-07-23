# ajsfx VO — Per-Project CSV Layout & Filtering — Design Spec

**Status:** Draft for review · **Version:** 0.1 · **Date:** 2026-07-23

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
- CSV **Layout** (column mapping + skip token) and **filtering** live in ScriptMatch, not
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
  mapping = { text=<col>, asset=<col>, speaker=<col>|nil, line_id=<col>|nil, type=<col>|nil },
  skip_values = { "TO RECORD", ... },   -- asset cells that mean "not yet recorded"
}
```

- **Roles:** `text` (required), `asset`/filename (required), `speaker`/character (optional —
  mapping it enables per-character routing), `line_id` (optional), `type` (optional; mapped,
  not acted on).
- Filter selections (which characters to include) are **run state**, not part of the layout.

---

## 4. Pure layer (new / changed in `VO/lib/ajsfx_vo.lua`, all unit-tested)

| Function | Purpose |
|---|---|
| `vo.DistinctColumnValues(rows, col_index)` | Ordered, de-duplicated, trimmed, non-empty values of a column (first-seen order). Feeds the character multi-select. |
| `vo.AutoDetectMapping(header)` | Best-guess `role→columnName` by case-insensitive match of header names against a per-role **alias set** (e.g. speaker ⇐ {speaker, character, char, actor}; asset ⇐ {audioasset, filename, asset, file, wav, output}; text ⇐ {text, line, dialogue, vo}; line_id ⇐ {lineid, id, line_id}; type ⇐ {type, category, kind}). Unmatched roles omitted. |
| `vo.SerializeLayout(layout)` / `vo.DeserializeLayout(text)` | Round-trip a layout to/from a line-based string for ExtState. Tolerant of column names containing spaces/commas (tab-delimited, one entry per line). |
| `vo.CharacterTrackName(character, base)` | `SanitizeName(character).."_"..base` when character is non-empty, else `base`. |
| **`vo.BuildScriptLines` (changed)** | Filter by an **include-set of characters** instead of a single speaker string: `filters.speakers = { [foldedName]=true }` (nil ⇒ all). Existing `type` filter parameter retained but unused by callers. |
| **plan composition (changed)** | Each span built from a matched line carries `span.character = line.speaker`. Unmatched/gap spans have `character = nil`. |

`REQUIRED_COLUMNS = { text, asset }`, `OPTIONAL_COLUMNS = { line_id, speaker, type }`
(unchanged shape; `MapColumns` already resolves role→index from names).

---

## 5. Coupled layer

### 5.1 Routing (`vo.ApplyPlan`, changed)
Replace the fixed `dest_names[span.dest]` track name with a per-character name:

```
base      = { selects=cfg.track_selects, alts=cfg.track_alts, review=cfg.track_review }[span.dest]
full_name = vo.CharacterTrackName(span.character, base)
```

Cache ensured tracks keyed by `full_name` (not by `span.dest`), so each `<Character>_<Base>`
track is created lazily on first use via `EnsureTrackBelow(source_track, full_name)`. Region
creation and take naming are unchanged (region/clip name stays the asset name).

### 5.2 Layout preset storage (global ExtState, section `ajsfx_vo_layouts`)
- `__names__` = newline-joined preset names (ordered).
- `<name>` = `SerializeLayout(layout)`.
- Helpers: `SaveLayoutPreset(name, layout)`, `LoadLayoutPreset(name)`, `ListLayoutPresets()`,
  `DeleteLayoutPreset(name)`. (Coupled: thin ExtState wrappers over the pure serializer.)

### 5.3 Per-`.rpp` memory (`ProjExtState`, section `ajsfx_vo`)
- `script_csv` (exists), plus `layout` = `SerializeLayout(current)` and `layout_name` =
  selected preset name (or empty when the inline mapping is unsaved).
- **Restore precedence on open:** if `layout_name` names a preset that still exists, load that
  preset; otherwise fall back to the inline `layout`; otherwise auto-detect from the header.
  The CSV path restores independently.

---

## 6. UI — ScriptMatch run dialog

Rework `ajsfx_VO_ScriptMatch.lua`'s dialog:

1. **Script CSV** — path + Browse (exists). On successful load, parse the header once; if the
   file/header changes, re-populate the dropdowns and character list.
2. **Layout** — preset dropdown + **Save / Save As… / Delete**; below it a **role dropdown per
   column** (Text*, Filename*, Character, LineID, Type), each listing the header's column names
   (optionals include `(none)`). Auto-detected on first load; editing marks the layout dirty.
   A **skip token** field (part of the layout) defaults to `TO RECORD`.
3. **Filters** — **Character** multi-select (checkbox per distinct value, all checked),
   shown only when a Character column is mapped.
4. **This session** — existing alts / suffix / primary toggles (unchanged).
5. **Transcribe and cut** — unchanged flow; on run, `MapColumns` uses the active layout's
   mapping and `BuildScriptLines` uses the character include-set.

### Settings changes (`ajsfx_VO_Settings.lua`)
Remove the column-mapping and skip-value fields from the "Script CSV" panel; keep the
**Substitutions** editor (rename the panel accordingly). Backend / Matching / Output panels
unchanged. `DEFAULT_COLUMN_MAPPING` remains as the auto-detect seed; the user-editable global
`column_mapping` is no longer surfaced (the layout system supersedes it).

---

## 7. Error handling
- CSV unreadable / no data rows / missing a **required** role → clear message, nothing runs
  (as today).
- No character column mapped → routing falls back to plain `Selects/Alts/Review`; the
  character filter section is hidden.
- Deleting the active preset → dropdown falls back to `(unsaved)` with the inline mapping
  retained.
- Character filter with everything unchecked → "No characters selected" and nothing runs.

---

## 8. Testing

**Pure / headless (`tests/test_vo.lua`):**
- `DistinctColumnValues` — order, de-dup, trim, empties skipped.
- `AutoDetectMapping` — exact/case-insensitive header matches; unmatched roles omitted.
- `SerializeLayout`/`DeserializeLayout` — round-trip incl. names with spaces and commas.
- `CharacterTrackName` — with/without character, sanitization of unsafe characters.
- `BuildScriptLines` — character include-set (subset kept, others dropped), nil ⇒ all,
  skip-token still honored.
- plan composition — a span from a `speaker="Guard"` line carries `character="Guard"`;
  gap/unmatched spans carry `nil`.

**Manual (`VO/MANUAL_TEST.md`, REAPER):** dropdowns populate from a real header; auto-detect;
Save/Load/Delete presets; per-`.rpp` restore; character multi-select narrows the run;
per-character tracks (`Guard_Selects`, `Hero_Review`, …) created only when populated; a CSV
with no character column still routes to plain tracks.

---

## 9. Deferred (TODO — captured, not built)
- **Type-based organization on the timeline:** group clips by Type (all barks together, all
  dialogue together), and/or route Types to separate tracks or sub-tracks. Design open; the
  Type column is already mapped so the data is available when this is picked up.

---

## 10. Versioning & release
Per `.agents/standards.md`: bump `@version` + `@changelog` on `ajsfx_VO_ScriptMatch.lua`
(indexed package) and the `@noindex` lib and Settings; `index.xml` is CI-rebuilt on merge.
