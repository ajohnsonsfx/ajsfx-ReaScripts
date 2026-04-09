# Project Builder UI Redesign

**Date:** 2026-04-08  
**Script:** `scripts/Track/ajsfx_ProjectBuilder.lua`  
**Status:** Approved for implementation

---

## Problem Statement

The current UI has two core friction points:

1. **Disjointed flow** — configuring a batch requires jumping between the batch list, the preset selector, and a floating preset editor window. Each is a separate mental context.
2. **Disconnected preset editor** — the floating window is spatially detached from the batch it affects, making it unclear which batch is being changed.

Additionally, the wildcard resolution and preset persistence logic is embedded in the ProjectBuilder script, making it unavailable to other ajsfx scripts that will need it.

---

## Architecture Changes

### `lib/ajsfx_core.lua` — new additions

**`core.ResolveWildcards(str)`**  
Moved from ProjectBuilder. Resolves built-in wildcards (`$year`, `$month`, `$day`, `$monthname`, `$hour`, `$hour12`, `$minute`, `$project`, `$user`, `$computer`, `$author`) and user-defined custom wildcards (loaded from user settings). User wildcards are resolved first, then built-in wildcards, so a user wildcard like `$mydate = $year$month$day` expands correctly.

**`core.naming` sub-module**
- `core.naming.SerializePreset(preset)` / `DeserializePreset(name, str)` — current flat string format (`type:label|type:label`)
- `core.naming.LoadAllPresets(section, defaults)` / `SaveCustomPresets(section, presets)` — generic preset persistence keyed by ExtState section, so any script can maintain its own preset list
- `core.naming.IsDefaultPreset(name, defaults)`
- `core.naming.ResolveGroupName(batch, group_index)` — resolves all sections using `ResolveWildcards`

**`core.settings` sub-module**  
Global user settings stored in ExtState section `ajsfx_UserSettings`:
- `delimiter` (string, default `_`) — used across all scripts as the default name delimiter
- `custom_wildcards` (list of `{name, pattern}`) — user-defined wildcards, e.g. `$mydate` → `$year$month$day`. Names must start with `$`, must not shadow built-in wildcards.
- `version_label` (string, default `v`) — prefix used for version suffixes by versioning scripts, e.g. `v` produces `v01`, `v02`

### `scripts/Track/ajsfx_ProjectBuilder.lua` — scope after extraction

Retains:
- All ImGui GUI code
- Batch/group data model and session persistence (ProjectBuilder-specific)
- Track generation logic (`generate_tracks`)

Removes:
- `resolve_wildcards` (→ `core.ResolveWildcards`)
- `serialize_preset` / `deserialize_preset` / `load_all_presets` / `save_custom_presets` / `is_default_preset` (→ `core.naming`)
- `resolve_group_name` (→ `core.naming.ResolveGroupName`)

---

## GUI Layout

### Window

Default size: 860 × 540. Resizable. Min width ~600 to prevent panel collapse.

### Tab Bar (top)

One tab per batch. Label format: `Batch N · Preset Name`. Active tab is highlighted. A `＋ Add Batch` button sits after the last tab. Tabs can be closed with a small `×` on each tab. Clicking a batch section in the Output Panel switches to that batch's tab.

### Config Area (left, fills remaining width)

Each tab shows an independent config area with three sections stacked vertically:

**1. NAME PRESET**

- Dropdown to select the active preset for this batch.
- Three buttons to the right of the dropdown: `Save`, `＋ New`, `Delete`.
  - `Delete` is disabled for default presets.
  - `Save` opens an inline save dialog (see below).
- Below the dropdown and buttons: the **inline horizontal preset editor**.

**Inline preset editor strip**

Displays the active preset's sections as a horizontal row of pills. Each pill contains:
- A type badge (`shared` in green, `input` in blue) — clicking it toggles between shared and input
- An editable label text field
- `←` / `→` arrow buttons to reorder (visible on hover)
- `×` to remove the section

At the left end: a `delim` label showing the global delimiter (read-only, links to Settings). At the right end: a `＋ section` button to add a new section (defaults to `input` type).

The strip renders sections inline with delimiter characters between them, matching the visual format `[Character]_[Action]_[Date]`. Changes to the preset are live — the groups table preview column updates as you type.

**Save preset dialog**

Appears as a small popover near the Save button. Contains:
- A text field pre-filled with the current preset name.
- If the typed name matches an existing preset: amber warning `⚠ "Name" already exists. Overwrite it?` with `Cancel` and `Overwrite` buttons.
- If the typed name is unique: `Cancel` and `Save` buttons, no additional messaging.
- Default presets cannot be overwritten; the `Overwrite` button is disabled if the name matches a default.

**2. TRACK LAYOUT**

A spinner row showing: `Groups | Aux | Audio | MIDI` counts. To the right of the row: a `▼ Preview` / `▶ Preview` toggle.

When expanded (default on first use, state persisted per-batch in session):
- A diagram panel attached below the spinner row showing the structure for one representative group, using Unicode box-drawing characters:
  ```
  📁 Hero_Attack_2026
  ├─ Aux_1
  ├─ Aux_2
  ├─ Audio 1  → Aux_1, Aux_2
  └─ Audio 4  → Aux_1, Aux_2
  × 3 groups · 18 tracks total
  ```
- Aux tracks shown in amber (`#ffcc66`), Audio in blue (`#88ccff`), MIDI in purple (`#cc88ff`) to distinguish from Audio since they generate different track types.
- "1 of N groups shown" label when groups > 1.

**3. GROUPS**

A scrollable table. Columns: `#` | one column per section | `Preview`.

- **Shared columns** (green header badge): all cells in the column display the same value. Clicking any cell in the column opens an input for the shared value — editing it updates all rows instantly. Cells are tinted green to communicate they are linked.
- **Input columns** (blue header badge): each cell is an independent input field per row.
- **Preview column**: resolved full name, updated live. Shown in blue (`#4a9eff`). Disabled/grey if name resolves to empty.

Table height is capped and scrollable when groups exceed visible area.

### Output Panel (right, fixed width ~195px)

Always visible. Contains:

**Batch sections** — one per batch, stacked vertically. Each section:
- Header: `Batch N · Preset Name` (bold batch number, muted preset name)
- Sub-header: `N Aux · N Audio · N MIDI · N groups` (track layout summary, muted)
- Group name list: resolved names, one per line. Color-coded by batch (cycles through a palette for visual distinction).
- The entire batch section is a clickable region — clicking switches to that batch's tab. Hover highlight on the whole block.

**Generate button** — anchored at the bottom of the panel. Full panel width. On success: closes the window and clears session state. On validation failure: shows REAPER message box with the error.

### Settings Window

Opened via a small `⚙` gear icon in the Output Panel, above the Generate button. Separate floating window, always-on-top, auto-resize.

**Global Delimiter**  
Single text input. Default `_`. Affects all scripts that call `core.settings`.

**Custom Wildcards**  
A small table: `$name` | `pattern` | delete button. Add row button at the bottom. Names must begin with `$`. Patterns may reference built-in wildcards. Resolved before built-in wildcards so composition works. Example: `$mydate` → `$year$month$day`.

**Version Label**  
Single text input. Default `v`. Used by versioning scripts to format version suffixes (e.g. `v` → `v01`, `V` → `V01`). Exact formatting (zero-padding, case) is the versioning script's concern; this stores the prefix.

Save/close button. Changes take effect immediately on close.

---

## Preset Data Model Change

Delimiter is removed from the preset serialization format. The current format `delimiter|type:label|...` becomes `type:label|type:label|...`. Existing saved presets that include a leading delimiter field are migrated on load: if the first segment doesn't contain `:`, treat it as a legacy delimiter and discard it.

---

## Session Persistence

Unchanged in structure. The `delimiter` field in serialized batches is dropped; the global delimiter is read from `core.settings` at generation time.

---

## Future Scripts (informed by this design)

- **`ajsfx_TrackNamer.lua`** — multiline text input, one name per line. Each line is passed through `core.ResolveWildcards`. Creates flat (non-folder) tracks. Uses global delimiter and custom wildcards from `core.settings`.
- **Versioning script** — reads selected track names, appends a pattern using `core.naming` presets and `core.ResolveWildcards`. Uses `core.settings.version_label` for version formatting.
- **Ludexicon integration (future)** — `core.naming.LoadAllPresets` will eventually support loading from Ludexicon's JSON taxonomy format. The `PatternComponent` (slot/literal) model maps directly to `{type, label}` sections. No changes to the ProjectBuilder GUI are anticipated for this integration.
