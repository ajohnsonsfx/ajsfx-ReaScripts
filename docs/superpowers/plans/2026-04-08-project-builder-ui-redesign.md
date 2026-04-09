# Project Builder UI Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the Project Builder UI with batch tabs, an inline preset editor, a collapsible track layout diagram, shared-column group editing, and a persistent output panel — while extracting wildcard resolution, naming presets, and user settings into `ajsfx_core.lua` for reuse across future scripts.

**Architecture:** Core library additions (`core.settings`, `core.naming`, `core.ResolveWildcards`) are built and tested first as pure Lua with no GUI dependency. The ProjectBuilder script is then progressively rewritten task by task, each ending with a working, committable script. The floating preset editor window is eliminated in favour of an inline horizontal pill strip; the batch list sidebar becomes a tab bar; a fixed right-side output panel replaces the collapsible bottom drawer.

**Tech Stack:** Lua 5.4, REAPER ReaImGui (`imgui` 0.9.3), REAPER ExtState for persistence, `ajsfx_core.lua` shared library.

**Spec:** `docs/superpowers/specs/2026-04-08-project-builder-ui-redesign.md`

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `scripts/lib/ajsfx_core.lua` | Modify | Add `core.settings`, `core.naming`, `core.ResolveWildcards` |
| `scripts/Track/ajsfx_ProjectBuilder.lua` | Rewrite GUI | Tabs, inline preset editor, layout diagram, groups table, output panel, settings window |
| `tests/test_core_naming.lua` | Create | Unit tests for `core.naming` and `core.ResolveWildcards` (runs with plain `lua`) |

---

## Task 1: Add `core.settings` to `ajsfx_core.lua`

**Files:**
- Modify: `scripts/lib/ajsfx_core.lua`
- Create: `tests/test_core_naming.lua`

- [ ] **Step 1: Create the test scaffold**

Create `tests/test_core_naming.lua`:

```lua
-- tests/test_core_naming.lua
-- Run from repo root: lua tests/test_core_naming.lua

-- ── Mock REAPER global ──────────────────────────────────────────────────────
reaper = {
    GetProjectName          = function() return "MyProject.rpp" end,
    GetSetProjectAuthor     = function() return true, "TestAuthor" end,
    HasExtState             = function(section, key) return false end,
    GetExtState             = function(section, key) return "" end,
    SetExtState             = function(section, key, val, persist) end,
    DeleteExtState          = function(section, key, persist) end,
    ShowConsoleMsg          = function(msg) io.write(msg) end,
    ShowMessageBox          = function(msg, title, flags) end,
}

-- ── Load core ───────────────────────────────────────────────────────────────
package.path = package.path .. ";scripts/lib/?.lua"
local core = require("ajsfx_core")

-- ── Minimal test runner ─────────────────────────────────────────────────────
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("  PASS  " .. name)
        passed = passed + 1
    else
        print("  FAIL  " .. name .. "\n        " .. tostring(err))
        failed = failed + 1
    end
end
local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "") .. "\n        expected: " .. tostring(b) .. "\n        got:      " .. tostring(a), 2)
    end
end

-- ── Settings tests ──────────────────────────────────────────────────────────
print("\n=== core.settings ===")

test("Load returns defaults when no ExtState", function()
    local s = core.settings.Load()
    assert_eq(s.delimiter,     "_",  "delimiter default")
    assert_eq(s.version_label, "v",  "version_label default")
    assert_eq(#s.custom_wildcards, 0, "custom_wildcards empty")
end)

print("\nAll done: " .. passed .. " passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
```

- [ ] **Step 2: Run the test — expect failure** (core.settings doesn't exist yet)

```
cd D:\GitHub\ajohnsonsfx\ajsfx
lua tests/test_core_naming.lua
```

Expected: error `attempt to index a nil value (field 'settings')`

- [ ] **Step 3: Add `core.settings` to `ajsfx_core.lua`**

Insert before the final `return core` line in `scripts/lib/ajsfx_core.lua`:

```lua
--------------------------------
-- Settings
--------------------------------

core.settings = {}
local SETTINGS_SECTION = "ajsfx_UserSettings"

function core.settings.Load()
    local s = {
        delimiter       = "_",
        custom_wildcards = {},
        version_label   = "v",
    }
    if r.HasExtState(SETTINGS_SECTION, "delimiter") then
        local d = r.GetExtState(SETTINGS_SECTION, "delimiter")
        if d ~= "" then s.delimiter = d end
    end
    if r.HasExtState(SETTINGS_SECTION, "version_label") then
        local vl = r.GetExtState(SETTINGS_SECTION, "version_label")
        if vl ~= "" then s.version_label = vl end
    end
    if r.HasExtState(SETTINGS_SECTION, "custom_wildcards") then
        local raw = r.GetExtState(SETTINGS_SECTION, "custom_wildcards")
        for line in raw:gmatch("[^\n]+") do
            local name, pattern = line:match("^([^\t]+)\t(.+)$")
            if name and pattern then
                s.custom_wildcards[#s.custom_wildcards + 1] = { name = name, pattern = pattern }
            end
        end
    end
    return s
end

function core.settings.Save(s)
    r.SetExtState(SETTINGS_SECTION, "delimiter",     s.delimiter,     true)
    r.SetExtState(SETTINGS_SECTION, "version_label", s.version_label, true)
    local lines = {}
    for _, wc in ipairs(s.custom_wildcards) do
        lines[#lines + 1] = wc.name .. "\t" .. wc.pattern
    end
    r.SetExtState(SETTINGS_SECTION, "custom_wildcards", table.concat(lines, "\n"), true)
end
```

- [ ] **Step 4: Run test — expect pass**

```
lua tests/test_core_naming.lua
```

Expected: `PASS  Load returns defaults when no ExtState` / `1 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/ajsfx_core.lua tests/test_core_naming.lua
git commit -m "feat: add core.settings (delimiter, custom_wildcards, version_label)"
```

---

## Task 2: Add `core.naming` to `ajsfx_core.lua`

**Files:**
- Modify: `scripts/lib/ajsfx_core.lua`
- Modify: `tests/test_core_naming.lua`

- [ ] **Step 1: Add naming tests to the test file**

Append to `tests/test_core_naming.lua` (before the final print/exit lines):

```lua
-- ── Naming tests ────────────────────────────────────────────────────────────
print("\n=== core.naming ===")

test("SerializePreset produces type:label pipe-separated string", function()
    local preset = {
        name = "My Preset",
        sections = {
            { type = "shared", label = "Character" },
            { type = "input",  label = "Action" },
            { type = "shared", label = "Date" },
        }
    }
    local s = core.naming.SerializePreset(preset)
    assert_eq(s, "shared:Character|input:Action|shared:Date", "serialized form")
end)

test("DeserializePreset round-trips correctly", function()
    local preset = {
        name = "My Preset",
        sections = {
            { type = "shared", label = "Character" },
            { type = "input",  label = "Action" },
        }
    }
    local str = core.naming.SerializePreset(preset)
    local out = core.naming.DeserializePreset("My Preset", str)
    assert_eq(out.name, "My Preset")
    assert_eq(#out.sections, 2)
    assert_eq(out.sections[1].type,  "shared")
    assert_eq(out.sections[1].label, "Character")
    assert_eq(out.sections[2].type,  "input")
    assert_eq(out.sections[2].label, "Action")
end)

test("DeserializePreset migrates legacy format (leading delimiter field)", function()
    -- Old format: "delimiter|type:label|type:label"
    local legacy = "_|shared:Character|input:Action"
    local out = core.naming.DeserializePreset("Legacy", legacy)
    assert_eq(#out.sections, 2, "section count after migration")
    assert_eq(out.sections[1].label, "Character")
    assert_eq(out.sections[2].label, "Action")
end)

test("IsDefaultPreset returns true for defaults, false for custom", function()
    local defaults = {
        { name = "Standard Asset", sections = {} },
        { name = "VO Asset",       sections = {} },
    }
    assert_eq(core.naming.IsDefaultPreset("Standard Asset", defaults), true)
    assert_eq(core.naming.IsDefaultPreset("My Custom",      defaults), false)
end)
```

- [ ] **Step 2: Run tests — expect failures** (core.naming doesn't exist yet)

```
lua tests/test_core_naming.lua
```

Expected: errors on `core.naming` calls.

- [ ] **Step 3: Add `core.naming` to `ajsfx_core.lua`**

Insert before `core.settings = {}` in `scripts/lib/ajsfx_core.lua`:

```lua
--------------------------------
-- Naming
--------------------------------

core.naming = {}
local PRESETS_SECTION_DEFAULT = "ajsfx_Presets"

function core.naming.SerializePreset(preset)
    -- Format: type:label|type:label|...  (no delimiter — delimiter is global)
    local parts = {}
    for _, s in ipairs(preset.sections) do
        parts[#parts + 1] = s.type .. ":" .. s.label
    end
    return table.concat(parts, "|")
end

function core.naming.DeserializePreset(name, str)
    local parts = {}
    for part in str:gmatch("[^|]+") do
        parts[#parts + 1] = part
    end
    if #parts < 1 then return nil end

    -- Legacy migration: if first segment has no ":", it was the old delimiter field — discard it
    local start = 1
    if not parts[1]:find(":") then
        start = 2
    end

    local preset = { name = name, sections = {} }
    for i = start, #parts do
        local stype, label = parts[i]:match("^(%w+):(.+)$")
        if stype and label then
            preset.sections[#preset.sections + 1] = { type = stype, label = label }
        end
    end
    return preset
end

function core.naming.IsDefaultPreset(name, defaults)
    for _, dp in ipairs(defaults) do
        if dp.name == name then return true end
    end
    return false
end

function core.naming.LoadAllPresets(section, defaults)
    local presets = {}
    -- Deep-copy defaults first
    for _, dp in ipairs(defaults) do
        local p = { name = dp.name, sections = {} }
        for _, s in ipairs(dp.sections) do
            p.sections[#p.sections + 1] = { type = s.type, label = s.label }
        end
        presets[#presets + 1] = p
    end
    -- Load custom presets from ExtState
    if r.HasExtState(section, "LIST") then
        local list_str = r.GetExtState(section, "LIST")
        for name in list_str:gmatch("[^|]+") do
            if name ~= "" and not core.naming.IsDefaultPreset(name, defaults) then
                local key = "P_" .. name
                if r.HasExtState(section, key) then
                    local p = core.naming.DeserializePreset(name, r.GetExtState(section, key))
                    if p then
                        presets[#presets + 1] = p
                    end
                end
            end
        end
    end
    return presets
end

function core.naming.SaveCustomPresets(section, presets, defaults)
    local names = {}
    for _, p in ipairs(presets) do
        if not core.naming.IsDefaultPreset(p.name, defaults) then
            names[#names + 1] = p.name
            r.SetExtState(section, "P_" .. p.name, core.naming.SerializePreset(p), true)
        end
    end
    r.SetExtState(section, "LIST", table.concat(names, "|"), true)
end
```

- [ ] **Step 4: Run tests — expect all pass**

```
lua tests/test_core_naming.lua
```

Expected: 4 naming tests pass, 1 settings test passes. `5 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/ajsfx_core.lua tests/test_core_naming.lua
git commit -m "feat: add core.naming (preset serialization, persistence, migration)"
```

---

## Task 3: Add `core.ResolveWildcards` with custom wildcard support

**Files:**
- Modify: `scripts/lib/ajsfx_core.lua`
- Modify: `tests/test_core_naming.lua`

- [ ] **Step 1: Add wildcard + `core.naming.ResolveGroupName` tests**

Append to `tests/test_core_naming.lua` (before the final print/exit lines):

```lua
-- ── Wildcard tests ──────────────────────────────────────────────────────────
print("\n=== core.ResolveWildcards ===")

test("Resolves $year to 4-digit year", function()
    local result = core.ResolveWildcards("asset_$year")
    local expected = "asset_" .. os.date("%Y")
    assert_eq(result, expected)
end)

test("Resolves $project from mocked project name", function()
    local result = core.ResolveWildcards("$project_sfx")
    assert_eq(result, "MyProject_sfx")
end)

test("Resolves $monthname before $month to avoid partial match", function()
    local result = core.ResolveWildcards("$monthname")
    assert_eq(result, os.date("%B"))
end)

test("Custom wildcard resolved before built-in wildcards", function()
    -- Temporarily override HasExtState/GetExtState to return a custom wildcard
    local original_has = reaper.HasExtState
    local original_get = reaper.GetExtState
    reaper.HasExtState = function(section, key)
        if section == "ajsfx_UserSettings" and key == "custom_wildcards" then return true end
        return false
    end
    reaper.GetExtState = function(section, key)
        if section == "ajsfx_UserSettings" and key == "custom_wildcards" then
            return "$mydate\t$year$month"
        end
        return ""
    end
    local result = core.ResolveWildcards("$mydate")
    local expected = os.date("%Y") .. os.date("%m")
    reaper.HasExtState = original_has
    reaper.GetExtState = original_get
    assert_eq(result, expected, "custom wildcard + built-in expansion")
end)

-- ── ResolveGroupName tests ──────────────────────────────────────────────────
print("\n=== core.naming.ResolveGroupName ===")

test("Resolves shared + input sections with delimiter from settings", function()
    local batch = {
        sections = {
            { type = "shared", label = "Char" },
            { type = "input",  label = "Action" },
        },
        shared_values = { Char = "Hero" },
        groups = { [1] = { Action = "Attack" } },
    }
    local result = core.naming.ResolveGroupName(batch, 1)
    assert_eq(result, "Hero_Attack")
end)

test("Resolves wildcard in shared value", function()
    local batch = {
        sections = {
            { type = "shared", label = "Date" },
            { type = "input",  label = "Name" },
        },
        shared_values = { Date = "$year" },
        groups = { [1] = { Name = "Boom" } },
    }
    local result = core.naming.ResolveGroupName(batch, 1)
    local expected = os.date("%Y") .. "_Boom"
    assert_eq(result, expected)
end)
```

- [ ] **Step 2: Run tests — expect failures on wildcard tests**

```
lua tests/test_core_naming.lua
```

Expected: 5 existing tests pass, 6 new tests fail.

- [ ] **Step 3: Add `core.ResolveWildcards` and update `core.naming.ResolveGroupName`**

Insert before the `core.naming = {}` block in `scripts/lib/ajsfx_core.lua`:

```lua
--------------------------------
-- Wildcard Resolution
--------------------------------

function core.ResolveWildcards(str)
    -- Resolve user-defined custom wildcards first (they may contain built-in wildcards)
    local settings = core.settings.Load()
    for _, wc in ipairs(settings.custom_wildcards) do
        -- wc.name starts with "$" — escape for Lua pattern: "$" becomes "%$"
        local pattern = "%" .. wc.name
        local replacement = wc.pattern:gsub("%%", "%%%%")
        str = str:gsub(pattern, replacement)
    end

    -- Resolve built-in wildcards (ordered longest-first to prevent partial matches)
    local proj_name = r.GetProjectName(0, "")
    proj_name = proj_name:match("(.+)%.[^.]+$") or proj_name

    local replacements = {
        { "monthname", os.date("%B")                                        },
        { "computer",  os.getenv("COMPUTERNAME") or ""                     },
        { "project",   proj_name                                            },
        { "author",    select(2, r.GetSetProjectAuthor(0, false, "")) or "" },
        { "minute",    os.date("%M")                                        },
        { "hour12",    os.date("%I")                                        },
        { "year2",     os.date("%y")                                        },
        { "month",     os.date("%m")                                        },
        { "year",      os.date("%Y")                                        },
        { "hour",      os.date("%H")                                        },
        { "user",      os.getenv("USERNAME") or os.getenv("USER") or ""    },
        { "day",       os.date("%d")                                        },
    }
    for _, rep in ipairs(replacements) do
        str = str:gsub("%$" .. rep[1], rep[2]:gsub("%%", "%%%%"))
    end
    return str
end
```

Then add `ResolveGroupName` at the end of the `core.naming` block (after `SaveCustomPresets`):

```lua
function core.naming.ResolveGroupName(batch, group_index)
    local settings = core.settings.Load()
    local parts = {}
    for _, section in ipairs(batch.sections) do
        local value
        if section.type == "shared" then
            value = batch.shared_values[section.label] or ""
        else
            value = (batch.groups[group_index] and batch.groups[group_index][section.label]) or ""
        end
        parts[#parts + 1] = core.ResolveWildcards(value)
    end
    return table.concat(parts, settings.delimiter)
end
```

- [ ] **Step 4: Run all tests — expect all pass**

```
lua tests/test_core_naming.lua
```

Expected: `11 passed, 0 failed`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/ajsfx_core.lua tests/test_core_naming.lua
git commit -m "feat: add core.ResolveWildcards with custom wildcard support and core.naming.ResolveGroupName"
```

---

## Task 4: Update ProjectBuilder to use `core.naming` + `core.settings`

Remove the old embedded functions and update the batch model. The script remains fully functional after this task.

**Files:**
- Modify: `scripts/Track/ajsfx_ProjectBuilder.lua`

- [ ] **Step 1: Replace the CONSTANTS, WILDCARD RESOLUTION, NAME RESOLUTION, and PRESET PERSISTENCE sections**

In `scripts/Track/ajsfx_ProjectBuilder.lua`, delete the following sections entirely:
- `--- WILDCARD RESOLUTION ---` (the `resolve_wildcards` function)
- `--- NAME RESOLUTION ---` (the `resolve_group_name` function)
- `--- PRESET PERSISTENCE ---` (all five functions: `is_default_preset`, `serialize_preset`, `deserialize_preset`, `load_all_presets`, `save_custom_presets`)

Replace the `PRESETS_SECTION` constant line and add a reference to defaults:

```lua
local EXT_SECTION     = "ajsfx_ProjectBuilder"
local PRESETS_SECTION = "ajsfx_ProjectBuilder_Presets"
local MAX_PRESETS     = 50
local MAX_GROUPS      = 64
local MAX_AUX         = 8
local MAX_CONTENT     = 64
local MAX_SECTIONS    = 16

local DEFAULT_PRESETS = {
    {
        name     = "Standard Asset",
        sections = {
            { type = "shared", label = "Character" },
            { type = "input",  label = "Action" },
            { type = "shared", label = "Date" },
        }
    },
    {
        name     = "VO Asset",
        sections = {
            { type = "shared", label = "Prefix" },
            { type = "input",  label = "Character" },
            { type = "shared", label = "Date" },
        }
    },
    {
        name     = "Blank",
        sections = {
            { type = "input", label = "Name" },
        }
    },
}
```

- [ ] **Step 2: Update all call sites to use `core.*` equivalents**

Replace every call in the script:

| Old call | New call |
|---|---|
| `resolve_wildcards(str)` | `core.ResolveWildcards(str)` |
| `resolve_group_name(batch, gi)` | `core.naming.ResolveGroupName(batch, gi)` |
| `is_default_preset(name)` | `core.naming.IsDefaultPreset(name, DEFAULT_PRESETS)` |
| `serialize_preset(p)` | `core.naming.SerializePreset(p)` |
| `deserialize_preset(name, str)` | `core.naming.DeserializePreset(name, str)` |
| `load_all_presets()` | `core.naming.LoadAllPresets(PRESETS_SECTION, DEFAULT_PRESETS)` |
| `save_custom_presets(presets)` | `core.naming.SaveCustomPresets(PRESETS_SECTION, presets, DEFAULT_PRESETS)` |

- [ ] **Step 3: Drop `delimiter` from the batch model and session persistence**

In `create_batch_from_preset`, remove `delimiter = preset.delimiter`:

```lua
local function create_batch_from_preset(preset)
    local batch = {
        preset_name  = preset.name,
        sections     = deep_copy_sections(preset.sections),
        shared_values = {},
        num_groups   = 1,
        num_aux      = 1,
        num_audio    = 4,
        num_midi     = 0,
        groups       = {},
    }
    batch.groups[1] = {}
    for _, s in ipairs(batch.sections) do
        if s.type == "input" then
            batch.groups[1][s.label] = ""
        end
    end
    return batch
end
```

In `serialize_session`, remove the `b.delimiter` field from the BATCH line:

```lua
local parts = {
    "BATCH",
    b.preset_name,
    tostring(b.num_groups),
    tostring(b.num_aux),
    tostring(b.num_audio),
    tostring(b.num_midi),
}
```

In `deserialize_session`, update BATCH parsing (field indices shift by 1):

```lua
if parts[1] == "BATCH" and #parts >= 5 then
    current = {
        preset_name   = parts[2],
        sections      = {},
        shared_values = {},
        num_groups    = tonumber(parts[3]) or 1,
        num_aux       = tonumber(parts[4]) or 1,
        num_audio     = tonumber(parts[5]) or 4,
        num_midi      = tonumber(parts[6]) or 0,
        groups        = {},
    }
```

- [ ] **Step 4: Update `validate_batches` — replace `batch.delimiter` references**

The validation currently uses `batch.delimiter:rep(...)` to detect empty names. Replace with the global delimiter:

```lua
local function validate_batches(batches)
    local settings = core.settings.Load()
    if #batches == 0 then return false, "No batches configured." end
    for bi, batch in ipairs(batches) do
        if #batch.sections == 0 then
            return false, "Batch " .. bi .. " has no name sections."
        end
        for gi = 1, batch.num_groups do
            local name = core.naming.ResolveGroupName(batch, gi)
            local empty_name = settings.delimiter:rep(#batch.sections - 1)
            if name == "" or name == empty_name then
                return false, "Batch " .. bi .. ", Group " .. gi .. ": name resolves to empty.\nPlease fill in all sections."
            end
        end
    end
    local proj_name = r.GetProjectName(0, "")
    if proj_name == "" then
        for _, batch in ipairs(batches) do
            for _, s in ipairs(batch.sections) do
                local value
                if s.type == "shared" then
                    value = batch.shared_values[s.label] or ""
                else
                    for gi = 1, batch.num_groups do
                        value = (batch.groups[gi] and batch.groups[gi][s.label]) or ""
                        if value:find("%$project") then
                            return false, "Project is unsaved — $project will resolve to empty.\nPlease save the project first or remove the $project wildcard."
                        end
                    end
                end
                if value and value:find("%$project") then
                    return false, "Project is unsaved — $project will resolve to empty.\nPlease save the project first or remove the $project wildcard."
                end
            end
        end
    end
    return true, nil
end
```

- [ ] **Step 5: Load all_presets using core.naming**

Replace the GUI state initialisation block:

```lua
local all_presets    = core.naming.LoadAllPresets(PRESETS_SECTION, DEFAULT_PRESETS)
local batches        = load_session() or {}
local selected_batch = #batches > 0 and 1 or 0
```

- [ ] **Step 6: Run the script in REAPER and verify it opens without errors**

Open REAPER → run `ajsfx_ProjectBuilder`. Confirm the window opens, batches load, preset dropdown works, Generate still functions. Check the REAPER console for errors.

- [ ] **Step 7: Commit**

```bash
git add scripts/Track/ajsfx_ProjectBuilder.lua
git commit -m "refactor: migrate ProjectBuilder to use core.naming, core.settings, core.ResolveWildcards"
```

---

## Task 5: Replace sidebar with batch tab bar

**Files:**
- Modify: `scripts/Track/ajsfx_ProjectBuilder.lua`

- [ ] **Step 1: Add `layout_preview_open` to the batch model**

In `create_batch_from_preset`, add:

```lua
layout_preview_open = true,
```

In `deserialize_session`, after the BATCH block is created, it will default to `nil` for this field — the draw code will treat `nil` as `true` (shown below).

- [ ] **Step 2: Replace `draw_batch_list` and the two-column main loop with a tab bar**

Delete `draw_batch_list()` entirely. Replace the entire body of `Loop()` between `if visible then` and `im.End(ctx)` with:

```lua
if visible then
    -- Tab bar
    if im.BeginTabBar(ctx, "##batches", im.TabBarFlags_None) then
        for i, b in ipairs(batches) do
            local tab_label = "Batch " .. i .. " \xc2\xb7 " .. (b.preset_name ~= "" and b.preset_name or "?") .. "##tab" .. i
            local tab_flags = im.TabItemFlags_None
            local tab_open = true
            local visible_tab, p_tab_open = im.BeginTabItem(ctx, tab_label, true, tab_flags)
            if not p_tab_open then
                -- User clicked × on this tab — remove the batch
                table.remove(batches, i)
                if selected_batch > #batches then selected_batch = #batches end
                if visible_tab then im.EndTabItem(ctx) end
                im.EndTabBar(ctx)
                goto continue_loop
            end
            if visible_tab then
                selected_batch = i
                draw_batch_config()
                im.EndTabItem(ctx)
            end
        end
        -- Add Batch button as a non-closable tab
        if im.TabItemButton(ctx, "\xe2\x9e\x95 Add Batch", im.TabItemFlags_Trailing) then
            local preset = all_presets[1]
            batches[#batches + 1] = create_batch_from_preset(preset)
            selected_batch = #batches
        end
        im.EndTabBar(ctx)
    end
    ::continue_loop::
    im.End(ctx)
end
```

- [ ] **Step 3: Update `draw_batch_config` to remove the child wrapper and cancel/generate buttons**

`draw_batch_config` currently wraps in `im.BeginChild`. Remove the child wrapper — the tab provides the container. Also remove the old Cancel/Generate button block from `draw_batch_config`. The function should start directly with the preset selector content.

- [ ] **Step 4: Re-add standalone Cancel + Generate below the tab bar (temporary — will move to output panel in Task 9)**

After `im.EndTabBar` and before `im.End`:

```lua
im.Spacing(ctx)
local avail_w = im.GetContentRegionAvail(ctx)
local btn_w = 100
im.SetCursorPosX(ctx, im.GetCursorPosX(ctx) + avail_w - (btn_w * 2 + 10))
if im.Button(ctx, "Cancel", btn_w, 0) then open = false end
im.SameLine(ctx)
local can_generate = #batches > 0
if not can_generate then im.BeginDisabled(ctx) end
if im.Button(ctx, "Generate", btn_w, 0) then
    if generate_tracks(batches) then
        r.DeleteExtState(EXT_SECTION, "SESSION", true)
        open = false
    end
end
if not can_generate then im.EndDisabled(ctx) end
```

- [ ] **Step 5: Run in REAPER — verify tab bar works**

Confirm: tabs appear per batch, active tab highlights, `+ Add Batch` adds a tab, `×` on a tab removes the batch, selecting a tab shows that batch's config.

- [ ] **Step 6: Commit**

```bash
git add scripts/Track/ajsfx_ProjectBuilder.lua
git commit -m "feat: replace batch list sidebar with tab bar"
```

---

## Task 6: Replace preset popup editor with inline horizontal strip + save dialog

**Files:**
- Modify: `scripts/Track/ajsfx_ProjectBuilder.lua`

- [ ] **Step 1: Add save dialog state variables near the GUI state block**

```lua
local save_dialog_open = false
local save_dialog_name = ""
```

- [ ] **Step 2: Delete `draw_preset_editor()` and `editing_preset` / `edit_new_preset_name` / `edit_is_new` state variables**

Remove all four state variables (`editing_preset`, `edit_new_preset_name`, `edit_is_new`, and the preset editor input buffers). Delete the entire `draw_preset_editor()` function. Remove the `draw_preset_editor()` call from the main loop.

- [ ] **Step 3: Replace the NAME PRESET section in `draw_batch_config` with the new preset row + inline strip**

Delete the existing `-- Preset selector` block and replace with:

```lua
-- ── NAME PRESET ──────────────────────────────────────────────────────────
im.SeparatorText(ctx, "Name Preset")

local avail_w = im.GetContentRegionAvail(ctx)
local btn_w   = 50
local n_btns  = core.naming.IsDefaultPreset(batch.preset_name, DEFAULT_PRESETS) and 2 or 3
local combo_w = avail_w - (btn_w * n_btns) - (8 * n_btns)

im.SetNextItemWidth(ctx, combo_w)
if im.BeginCombo(ctx, "##PresetCombo", batch.preset_name) then
    for _, p in ipairs(all_presets) do
        local is_selected = batch.preset_name == p.name
        if im.Selectable(ctx, p.name .. "##" .. p.name, is_selected) then
            batch.preset_name   = p.name
            batch.sections      = deep_copy_sections(p.sections)
            batch.shared_values = {}
            -- clear input buffers for this batch
            for k in pairs(input_buffers) do
                if k:find("^" .. bid) then input_buffers[k] = nil end
            end
            sync_batch_groups(batch)
        end
    end
    im.EndCombo(ctx)
end

im.SameLine(ctx)
if im.Button(ctx, "Save##preset", btn_w, 0) then
    save_dialog_open = true
    save_dialog_name = batch.preset_name
    input_buffers["save_name"] = batch.preset_name
    im.OpenPopup(ctx, "##save_preset_dialog")
end

im.SameLine(ctx)
if im.Button(ctx, "New##preset", btn_w, 0) then
    -- Create a new blank preset and start editing it
    local new_p = { name = "New Preset", sections = { { type = "input", label = "Name" } } }
    all_presets[#all_presets + 1] = new_p
    core.naming.SaveCustomPresets(PRESETS_SECTION, all_presets, DEFAULT_PRESETS)
    batch.preset_name   = new_p.name
    batch.sections      = deep_copy_sections(new_p.sections)
    batch.shared_values = {}
    sync_batch_groups(batch)
end

if not core.naming.IsDefaultPreset(batch.preset_name, DEFAULT_PRESETS) then
    im.SameLine(ctx)
    if im.Button(ctx, "Del##preset", btn_w, 0) then
        all_presets = core.naming.DeleteCustomPreset(all_presets, batch.preset_name, DEFAULT_PRESETS)
        local p = all_presets[1]
        batch.preset_name   = p.name
        batch.sections      = deep_copy_sections(p.sections)
        batch.shared_values = {}
        sync_batch_groups(batch)
    end
end

-- Save dialog popup
if im.BeginPopup(ctx, "##save_preset_dialog") then
    im.Text(ctx, "Save preset as:")
    im.SetNextItemWidth(ctx, 220)
    local rv, val = im.InputText(ctx, "##save_name", get_buf("save_name", save_dialog_name))
    if rv then
        save_dialog_name = val
        input_buffers["save_name"] = val
    end

    local name_exists = false
    for _, p in ipairs(all_presets) do
        if p.name == save_dialog_name then name_exists = true; break end
    end
    local is_default = core.naming.IsDefaultPreset(save_dialog_name, DEFAULT_PRESETS)

    if name_exists then
        im.TextColored(ctx, 0xFFAA44FF, "\xe2\x9a\xa0 \"" .. save_dialog_name .. "\" already exists. Overwrite?")
    end
    im.Spacing(ctx)

    if im.Button(ctx, "Cancel##save", 80, 0) then
        im.CloseCurrentPopup(ctx)
    end
    im.SameLine(ctx)

    local can_save = save_dialog_name ~= "" and not is_default
    if not can_save then im.BeginDisabled(ctx) end
    local confirm_label = name_exists and "Overwrite" or "Save"
    if im.Button(ctx, confirm_label .. "##save_confirm", 80, 0) then
        -- Find existing or append
        local found = false
        for idx, p in ipairs(all_presets) do
            if p.name == save_dialog_name then
                all_presets[idx] = { name = save_dialog_name, sections = deep_copy_sections(batch.sections) }
                found = true
                break
            end
        end
        if not found then
            all_presets[#all_presets + 1] = { name = save_dialog_name, sections = deep_copy_sections(batch.sections) }
        end
        batch.preset_name = save_dialog_name
        core.naming.SaveCustomPresets(PRESETS_SECTION, all_presets, DEFAULT_PRESETS)
        im.CloseCurrentPopup(ctx)
    end
    if not can_save then im.EndDisabled(ctx) end
    im.EndPopup(ctx)
end

-- ── Inline horizontal preset editor strip ────────────────────────────────
im.PushStyleColor(ctx, im.Col_ChildBg, 0x1A1A2AFF)
im.BeginChild(ctx, "##preset_strip_" .. bid, -1, 34, im.ChildFlags_Border)

-- Delimiter display (read-only, from global settings)
local settings = core.settings.Load()
im.TextDisabled(ctx, "delim:")
im.SameLine(ctx, 0, 4)
im.TextColored(ctx, 0x888888FF, settings.delimiter)
im.SameLine(ctx, 0, 8)
im.TextDisabled(ctx, "|")
im.SameLine(ctx, 0, 8)

local swap_a, swap_b, remove_idx = nil, nil, nil
for i, s in ipairs(batch.sections) do
    im.PushID(ctx, "strip_" .. i)

    -- Type badge button (toggles shared ↔ input)
    local badge_color = s.type == "shared" and 0x1A3A1AFF or 0x1A2A3AFF
    local text_color  = s.type == "shared" and 0x88FF88FF or 0x88CCFFFF
    im.PushStyleColor(ctx, im.Col_Button,        badge_color)
    im.PushStyleColor(ctx, im.Col_ButtonHovered, badge_color + 0x00101000)
    im.PushStyleColor(ctx, im.Col_Text,          text_color)
    if im.SmallButton(ctx, s.type == "shared" and "S" or "I") then
        s.type = s.type == "shared" and "input" or "shared"
        -- Remove stale shared_value if switching to input
        if s.type == "input" then batch.shared_values[s.label] = nil end
        sync_batch_groups(batch)
    end
    im.PopStyleColor(ctx, 3)
    im.SameLine(ctx, 0, 3)

    -- Label input
    im.SetNextItemWidth(ctx, 70)
    local buf_id = bid .. "strip_" .. i
    local rv_l, val_l = im.InputText(ctx, "##lbl", get_buf(buf_id, s.label))
    if rv_l then
        local old_label = s.label
        s.label = val_l
        input_buffers[buf_id] = val_l
        -- Rename keys in shared_values and groups
        if batch.shared_values[old_label] ~= nil then
            batch.shared_values[val_l] = batch.shared_values[old_label]
            batch.shared_values[old_label] = nil
        end
        for _, g in ipairs(batch.groups) do
            if g[old_label] ~= nil then
                g[val_l] = g[old_label]
                g[old_label] = nil
            end
        end
    end
    im.SameLine(ctx, 0, 2)

    -- Reorder arrows
    if i > 1 then
        if im.SmallButton(ctx, "<") then swap_a, swap_b = i, i - 1 end
    else
        im.SmallButton(ctx, " ")
    end
    im.SameLine(ctx, 0, 1)
    if i < #batch.sections then
        if im.SmallButton(ctx, ">") then swap_a, swap_b = i, i + 1 end
    else
        im.SmallButton(ctx, " ")
    end
    im.SameLine(ctx, 0, 2)

    -- Delete
    im.PushStyleColor(ctx, im.Col_Text, 0xFF6666FF)
    if im.SmallButton(ctx, "x") then remove_idx = i end
    im.PopStyleColor(ctx)

    -- Delimiter between sections
    if i < #batch.sections then
        im.SameLine(ctx, 0, 4)
        im.TextColored(ctx, 0x666666FF, settings.delimiter)
        im.SameLine(ctx, 0, 4)
    end

    im.PopID(ctx)
end

-- Apply reorder / removal
if swap_a and swap_b then
    batch.sections[swap_a], batch.sections[swap_b] = batch.sections[swap_b], batch.sections[swap_a]
    local ba = bid .. "strip_" .. swap_a
    local bb = bid .. "strip_" .. swap_b
    input_buffers[ba], input_buffers[bb] = input_buffers[bb], input_buffers[ba]
end
if remove_idx then
    table.remove(batch.sections, remove_idx)
    for i2, s in ipairs(batch.sections) do
        input_buffers[bid .. "strip_" .. i2] = s.label
    end
    sync_batch_groups(batch)
end

-- Add section button
im.SameLine(ctx, 0, 10)
if im.SmallButton(ctx, "+ section") and #batch.sections < MAX_SECTIONS then
    batch.sections[#batch.sections + 1] = { type = "input", label = "Name" }
    input_buffers[bid .. "strip_" .. #batch.sections] = "Name"
    sync_batch_groups(batch)
end

im.EndChild(ctx)
im.PopStyleColor(ctx)
```

- [ ] **Step 4: Add `core.naming.DeleteCustomPreset` to `ajsfx_core.lua`**

Add to the `core.naming` block in `scripts/lib/ajsfx_core.lua`:

```lua
function core.naming.DeleteCustomPreset(presets, name, defaults)
    if core.naming.IsDefaultPreset(name, defaults) then return presets end
    local new = {}
    for _, p in ipairs(presets) do
        if p.name ~= name then new[#new + 1] = p end
    end
    return new
end
```

- [ ] **Step 5: Run in REAPER — verify preset strip works**

Confirm: sections appear as pills, S/I badge toggles type, label field editable, `<`/`>` reorders, `x` removes, `+ section` appends. Save dialog opens with current name pre-filled; overwrite warning shows when name matches existing; saves correctly.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/ajsfx_core.lua scripts/Track/ajsfx_ProjectBuilder.lua
git commit -m "feat: replace preset popup editor with inline horizontal strip and save dialog"
```

---

## Task 7: Add collapsible track layout diagram

**Files:**
- Modify: `scripts/Track/ajsfx_ProjectBuilder.lua`

- [ ] **Step 1: Replace the existing `-- Layout` section in `draw_batch_config`**

Delete the old `im.SeparatorText(ctx, "Layout")` block and the entire hierarchy drawing code (the `draw_list`, `root_x/y`, `BeginGroup`, `im.Indent` blocks). Replace with:

```lua
-- ── TRACK LAYOUT ──────────────────────────────────────────────────────────
im.SeparatorText(ctx, "Track Layout")

local avail_lw = im.GetContentRegionAvail(ctx)
local spinner_w = 30

-- Spinners row
im.SetNextItemWidth(ctx, spinner_w)
local rv_g, val_g = im.InputInt(ctx, "##ng", batch.num_groups, 1, 1)
if rv_g then
    batch.num_groups = math.max(1, math.min(MAX_GROUPS, val_g))
    sync_batch_groups(batch)
end
im.SameLine(ctx) im.Text(ctx, "Groups")

im.SameLine(ctx, 0, 16)
im.SetNextItemWidth(ctx, spinner_w)
local rv_a, val_a = im.InputInt(ctx, "##na", batch.num_aux, 1, 1)
if rv_a then batch.num_aux = math.max(0, math.min(MAX_AUX, val_a)) end
im.SameLine(ctx) im.Text(ctx, "Aux")

im.SameLine(ctx, 0, 16)
im.SetNextItemWidth(ctx, spinner_w)
local rv_au, val_au = im.InputInt(ctx, "##nau", batch.num_audio, 1, 1)
if rv_au then batch.num_audio = math.max(0, math.min(MAX_CONTENT, val_au)) end
im.SameLine(ctx) im.Text(ctx, "Audio")

im.SameLine(ctx, 0, 16)
im.SetNextItemWidth(ctx, spinner_w)
local rv_mi, val_mi = im.InputInt(ctx, "##nmi", batch.num_midi, 1, 1)
if rv_mi then batch.num_midi = math.max(0, math.min(MAX_CONTENT, val_mi)) end
im.SameLine(ctx) im.Text(ctx, "MIDI")

-- Preview toggle (right-aligned)
local toggle_label = (batch.layout_preview_open ~= false) and "\xe2\x96\xbc Preview" or "\xe2\x96\xb6 Preview"
im.SameLine(ctx, avail_lw - 60)
if im.SmallButton(ctx, toggle_label) then
    batch.layout_preview_open = not (batch.layout_preview_open ~= false)
end

-- Collapsible diagram
if batch.layout_preview_open ~= false then
    local COLOR_AUX  = 0xFFCC66FF
    local COLOR_AUDIO = 0x88CCFFFF
    local COLOR_MIDI  = 0xCC88FFFF

    im.PushStyleColor(ctx, im.Col_ChildBg, 0x1A1A2AFF)
    im.BeginChild(ctx, "##layout_diagram_" .. bid, -1, 0, im.ChildFlags_AutoResizeY + im.ChildFlags_Border)

    local settings_d = core.settings.Load()
    local preview_name = core.naming.ResolveGroupName(batch, 1)
    if preview_name == "" then preview_name = "(unnamed)" end

    if batch.num_groups > 1 then
        im.TextDisabled(ctx, "1 of " .. batch.num_groups .. " groups shown")
    end

    im.Text(ctx, "\xf0\x9f\x93\x81 " .. preview_name)

    local total    = batch.num_aux + batch.num_audio + batch.num_midi
    local printed  = 0

    for a = 1, batch.num_aux do
        printed = printed + 1
        local is_last = printed == total
        local prefix  = is_last and "\xe2\x94\x94\xe2\x94\x80 " or "\xe2\x94\x9c\xe2\x94\x80 "
        im.SameLine(ctx, 0, 0) im.NewLine(ctx)
        im.TextColored(ctx, COLOR_AUX, prefix .. "Aux_" .. a)
    end

    -- Build send label once
    local send_label = ""
    if batch.num_aux > 0 then
        local parts = {}
        for a = 1, math.min(batch.num_aux, 3) do parts[#parts+1] = "Aux_" .. a end
        if batch.num_aux > 3 then parts[#parts+1] = "..." end
        send_label = "  \xe2\x86\x92 " .. table.concat(parts, ", ")
    end

    for c = 1, batch.num_audio + batch.num_midi do
        printed = printed + 1
        local is_last = printed == total
        local prefix  = is_last and "\xe2\x94\x94\xe2\x94\x80 " or "\xe2\x94\x9c\xe2\x94\x80 "
        local color   = c <= batch.num_audio and COLOR_AUDIO or COLOR_MIDI
        local ltype   = c <= batch.num_audio and "Audio " or "MIDI "
        local idx     = c <= batch.num_audio and c or (c - batch.num_audio)
        im.SameLine(ctx, 0, 0) im.NewLine(ctx)
        im.TextColored(ctx, color, prefix .. ltype .. idx)
        if send_label ~= "" then
            im.SameLine(ctx, 0, 0)
            im.TextDisabled(ctx, send_label)
        end
    end

    local track_total = (batch.num_aux + batch.num_audio + batch.num_midi) * batch.num_groups
    im.Spacing(ctx)
    im.TextDisabled(ctx, "\xc3\x97 " .. batch.num_groups .. " groups \xc2\xb7 " .. track_total .. " tracks total")

    im.EndChild(ctx)
    im.PopStyleColor(ctx)
end
```

- [ ] **Step 2: Run in REAPER — verify diagram**

Confirm: spinners update counts, `▶ Preview` / `▼ Preview` toggles the diagram, diagram shows correct folder name, aux (amber), audio (blue), MIDI (purple), send arrows, track total. Verify collapse state persists when switching tabs and returning.

- [ ] **Step 3: Commit**

```bash
git add scripts/Track/ajsfx_ProjectBuilder.lua
git commit -m "feat: add collapsible track layout diagram with Unicode tree"
```

---

## Task 8: Rewrite groups table with inline shared-column editing

**Files:**
- Modify: `scripts/Track/ajsfx_ProjectBuilder.lua`

- [ ] **Step 1: Replace the existing `-- Group input sections table` block in `draw_batch_config`**

Delete the existing `if #input_sections > 0 then` block (the entire groups table and the `else` preview block). Replace with:

```lua
-- ── GROUPS ─────────────────────────────────────────────────────────────────
im.SeparatorText(ctx, "Groups")

local col_count = 1 + #batch.sections + 1  -- # + sections + Preview
local tbl_flags = im.TableFlags_Borders + im.TableFlags_RowBg + im.TableFlags_ScrollY
local tbl_h     = math.min(batch.num_groups * 26 + 26, 260)

if im.BeginTable(ctx, "##groups_" .. bid, col_count, tbl_flags, 0, tbl_h) then

    im.TableSetupColumn(ctx, "#",       im.TableColumnFlags_WidthFixed,   24)
    for _, s in ipairs(batch.sections) do
        im.TableSetupColumn(ctx, s.label, im.TableColumnFlags_WidthFixed, 140)
    end
    im.TableSetupColumn(ctx, "Preview", im.TableColumnFlags_WidthStretch)

    -- Custom header row with colored badges
    im.TableNextRow(ctx, im.TableRowFlags_Headers)
    im.TableNextColumn(ctx)
    im.Text(ctx, "#")
    for _, s in ipairs(batch.sections) do
        im.TableNextColumn(ctx)
        local col = s.type == "shared" and 0x88FF88FF or 0x88CCFFFF
        im.TextColored(ctx, col, s.label)
        im.SameLine(ctx, 0, 4)
        local badge_col = s.type == "shared" and 0x1A3A1AFF or 0x1A2A3AFF
        im.PushStyleColor(ctx, im.Col_Text, col)
        im.SmallButton(ctx, s.type == "shared" and "shared" or "input")  -- non-interactive label
        im.PopStyleColor(ctx)
    end
    im.TableNextColumn(ctx)
    im.Text(ctx, "Preview")

    -- Data rows
    for gi = 1, batch.num_groups do
        im.TableNextRow(ctx)
        im.PushID(ctx, gi)

        -- Index column
        im.TableNextColumn(ctx)
        im.TextDisabled(ctx, tostring(gi))

        -- Section columns
        for _, s in ipairs(batch.sections) do
            im.TableNextColumn(ctx)

            if s.type == "shared" then
                -- Shared: editing any cell updates batch.shared_values[s.label]
                local buf_id = bid .. "sv_" .. s.label
                local current = batch.shared_values[s.label] or ""
                im.PushStyleColor(ctx, im.Col_FrameBg, 0x1A2A1AFF)
                im.SetNextItemWidth(ctx, -1)
                local rv, val = im.InputText(ctx, "##sv_" .. s.label, get_buf(buf_id, current))
                if rv then
                    batch.shared_values[s.label] = val
                    input_buffers[buf_id] = val
                end
                im.PopStyleColor(ctx)
            else
                -- Input: per-row independent field
                local buf_id = bid .. "grp_" .. gi .. "_" .. s.label
                im.SetNextItemWidth(ctx, -1)
                local rv, val = im.InputText(ctx, "##" .. s.label, get_buf(buf_id, batch.groups[gi][s.label] or ""))
                if rv then
                    batch.groups[gi][s.label] = val
                    input_buffers[buf_id] = val
                end
            end
        end

        -- Preview column
        im.TableNextColumn(ctx)
        local preview = core.naming.ResolveGroupName(batch, gi)
        if preview == "" or preview == core.settings.Load().delimiter:rep(#batch.sections - 1) then
            im.TextDisabled(ctx, "(empty)")
        else
            im.TextColored(ctx, 0x4A9EFFFF, preview)
        end

        im.PopID(ctx)
    end

    im.EndTable(ctx)
end
```

- [ ] **Step 2: Run in REAPER — verify groups table**

Confirm: shared columns are green-tinted, editing any shared cell updates all rows instantly, input cells are independent per row, preview column updates live as you type.

- [ ] **Step 3: Commit**

```bash
git add scripts/Track/ajsfx_ProjectBuilder.lua
git commit -m "feat: groups table with inline shared-column editing"
```

---

## Task 9: Add output panel + move Generate button

**Files:**
- Modify: `scripts/Track/ajsfx_ProjectBuilder.lua`

- [ ] **Step 1: Add batch color palette constant near the top of the file**

After the `local DEFAULT_PRESETS` block:

```lua
local BATCH_COLORS = {
    0x88FF88FF, -- green
    0x88CCFFFF, -- blue
    0xFFCC66FF, -- amber
    0xCC88FFFF, -- purple
    0xFF8888FF, -- red
    0x88FFFFFF, -- cyan
}
local function batch_color(i)
    return BATCH_COLORS[((i - 1) % #BATCH_COLORS) + 1]
end
```

- [ ] **Step 2: Restructure the main loop layout to split config and output panel**

In `Loop()`, after `local visible, open = im.Begin(...)`, replace the entire visible block with a horizontal split:

```lua
if visible then
    -- Horizontal split: tab area (left) + output panel (right, fixed)
    local PANEL_W = 200

    -- Output panel
    im.SameLine(ctx, im.GetContentRegionAvail(ctx) - PANEL_W + im.GetCursorPosX(ctx))
    -- (We'll use a child positioned after the tabs — see below)

    -- ── Left: tabs ──────────────────────────────────────────────────────
    local left_w = im.GetContentRegionAvail(ctx) - PANEL_W - 6
    im.BeginChild(ctx, "##left_area", left_w, -1, im.ChildFlags_None)

    if im.BeginTabBar(ctx, "##batches", im.TabBarFlags_None) then
        for i = #batches, 1, -1 do  -- iterate in reverse so removal doesn't shift indices
        end
        -- (reset — iterate forward properly)
        local i = 1
        while i <= #batches do
            local b = batches[i]
            local tab_label = "Batch " .. i .. " \xc2\xb7 " .. (b.preset_name ~= "" and b.preset_name or "?") .. "##tab" .. i
            local visible_tab, p_tab_open = im.BeginTabItem(ctx, tab_label, true, im.TabItemFlags_None)
            if not p_tab_open then
                table.remove(batches, i)
                if selected_batch >= i and selected_batch > 1 then selected_batch = selected_batch - 1 end
                if visible_tab then im.EndTabItem(ctx) end
                -- don't increment i
            else
                if visible_tab then
                    selected_batch = i
                    draw_batch_config()
                    im.EndTabItem(ctx)
                end
                i = i + 1
            end
        end
        if im.TabItemButton(ctx, "\xe2\x9e\x95 Add Batch", im.TabItemFlags_Trailing) then
            batches[#batches + 1] = create_batch_from_preset(all_presets[1])
            selected_batch = #batches
        end
        im.EndTabBar(ctx)
    end

    im.EndChild(ctx)

    -- ── Right: output panel ─────────────────────────────────────────────
    im.SameLine(ctx)
    im.PushStyleColor(ctx, im.Col_ChildBg, 0x141420FF)
    im.BeginChild(ctx, "##output_panel", PANEL_W, -1, im.ChildFlags_Border)

    im.TextDisabled(ctx, "OUTPUT PREVIEW")
    local total_tracks = 0
    for _, b in ipairs(batches) do
        total_tracks = total_tracks + (b.num_aux + b.num_audio + b.num_midi) * b.num_groups
    end
    im.TextDisabled(ctx, tostring(total_tracks) .. " tracks total")
    im.Separator(ctx)
    im.Spacing(ctx)

    for bi, b in ipairs(batches) do
        -- Clickable batch block
        local block_start_y = im.GetCursorPosY(ctx)
        local clicked = im.Selectable(ctx, "##batch_block_" .. bi, selected_batch == bi,
            im.SelectableFlags_None, im.GetContentRegionAvail(ctx), 0)
        if clicked then selected_batch = bi end
        im.SetCursorPosY(ctx, block_start_y)

        -- Batch header
        im.TextColored(ctx, 0xDDDDDDFF, "Batch " .. bi)
        im.SameLine(ctx, 0, 4)
        im.TextDisabled(ctx, "\xc2\xb7 " .. b.preset_name)
        im.TextDisabled(ctx, b.num_aux .. " Aux \xc2\xb7 " .. b.num_audio .. " Audio"
            .. (b.num_midi > 0 and (" \xc2\xb7 " .. b.num_midi .. " MIDI") or "")
            .. " \xc2\xb7 " .. b.num_groups .. " groups")

        -- Group name list
        local color = batch_color(bi)
        for gi = 1, b.num_groups do
            local name = core.naming.ResolveGroupName(b, gi)
            if name ~= "" then
                im.TextColored(ctx, color, name)
            end
        end
        im.Spacing(ctx)
        im.Separator(ctx)
        im.Spacing(ctx)
    end

    -- Spacer + gear icon + Generate
    local remaining = im.GetContentRegionAvail(ctx)
    if remaining > 40 then
        im.Dummy(ctx, 0, remaining - 40)
    end

    -- Settings gear button
    if im.Button(ctx, "\xe2\x9a\x99 Settings", -1, 0) then
        settings_open = true
    end
    im.Spacing(ctx)

    local can_generate = #batches > 0
    if not can_generate then im.BeginDisabled(ctx) end
    if im.Button(ctx, "\xe2\x9a\xa1 GENERATE", -1, 0) then
        if generate_tracks(batches) then
            r.DeleteExtState(EXT_SECTION, "SESSION", true)
            open = false
        end
    end
    if not can_generate then im.EndDisabled(ctx) end

    im.EndChild(ctx)
    im.PopStyleColor(ctx)

    im.End(ctx)
end
```

- [ ] **Step 3: Remove the temporary Cancel + Generate buttons added in Task 5**

Delete the `im.Spacing / SetCursorPosX / Cancel / Generate` block that was added at the bottom of the main loop in Task 5.

- [ ] **Step 4: Run in REAPER — verify output panel**

Confirm: output panel appears on the right with all batches listed, batch header shows preset name, track layout summary shows under header (not per-group), group names are color-coded per batch, clicking a batch block switches to that tab, Generate button works.

- [ ] **Step 5: Commit**

```bash
git add scripts/Track/ajsfx_ProjectBuilder.lua
git commit -m "feat: add persistent output panel with clickable batch sections and Generate button"
```

---

## Task 10: Add Settings window

**Files:**
- Modify: `scripts/Track/ajsfx_ProjectBuilder.lua`

- [ ] **Step 1: Add settings state variables near the GUI state block**

```lua
local settings_open = false
local settings_state = core.settings.Load()  -- working copy while window is open
local settings_new_wc_name    = ""
local settings_new_wc_pattern = ""
```

- [ ] **Step 2: Add `draw_settings_window()` function**

Add before the `-- MAIN LOOP` section:

```lua
--------------------------------
-- --- SETTINGS WINDOW ---
--------------------------------
local function draw_settings_window()
    if not settings_open then return end

    im.SetNextWindowSize(ctx, 420, 0, im.Cond_Appearing)
    local vis, p_open = im.Begin(ctx, "ajsfx Settings###ajsfx_settings",
        true, im.WindowFlags_AlwaysAutoResize)

    if not p_open then
        settings_open = false
        if vis then im.End(ctx) end
        return
    end
    if not vis then im.End(ctx); return end

    -- ── Global Delimiter ──────────────────────────────────────────────────
    im.SeparatorText(ctx, "Global Delimiter")
    im.TextWrapped(ctx, "Used as the separator between name sections across all ajsfx scripts.")
    im.Spacing(ctx)
    im.SetNextItemWidth(ctx, 60)
    local rv_d, val_d = im.InputText(ctx, "Delimiter", get_buf("st_delim", settings_state.delimiter))
    if rv_d then
        settings_state.delimiter = val_d
        input_buffers["st_delim"] = val_d
    end

    im.Spacing(ctx)

    -- ── Version Label ─────────────────────────────────────────────────────
    im.SeparatorText(ctx, "Version Label")
    im.TextWrapped(ctx, "Prefix used when versioning scripts append version numbers (e.g. \"v\" produces v01, v02).")
    im.Spacing(ctx)
    im.SetNextItemWidth(ctx, 60)
    local rv_vl, val_vl = im.InputText(ctx, "Version prefix", get_buf("st_vl", settings_state.version_label))
    if rv_vl then
        settings_state.version_label = val_vl
        input_buffers["st_vl"] = val_vl
    end

    im.Spacing(ctx)

    -- ── Custom Wildcards ──────────────────────────────────────────────────
    im.SeparatorText(ctx, "Custom Wildcards")
    im.TextWrapped(ctx, "Define your own wildcards using built-in ones. E.g. $mydate \xe2\x86\x92 $year$month$day")
    im.Spacing(ctx)

    local remove_wc = nil
    if im.BeginTable(ctx, "##wc_table", 3,
        im.TableFlags_Borders + im.TableFlags_RowBg, 0, 0) then
        im.TableSetupColumn(ctx, "Name",    im.TableColumnFlags_WidthFixed,   100)
        im.TableSetupColumn(ctx, "Pattern", im.TableColumnFlags_WidthStretch)
        im.TableSetupColumn(ctx, "",        im.TableColumnFlags_WidthFixed,    30)
        im.TableHeadersRow(ctx)

        for wi, wc in ipairs(settings_state.custom_wildcards) do
            im.TableNextRow(ctx)
            im.PushID(ctx, wi)

            im.TableNextColumn(ctx)
            im.SetNextItemWidth(ctx, -1)
            local rv_wn, val_wn = im.InputText(ctx, "##wn", get_buf("st_wn_" .. wi, wc.name))
            if rv_wn then
                wc.name = val_wn
                input_buffers["st_wn_" .. wi] = val_wn
            end

            im.TableNextColumn(ctx)
            im.SetNextItemWidth(ctx, -1)
            local rv_wp, val_wp = im.InputText(ctx, "##wp", get_buf("st_wp_" .. wi, wc.pattern))
            if rv_wp then
                wc.pattern = val_wp
                input_buffers["st_wp_" .. wi] = val_wp
            end

            im.TableNextColumn(ctx)
            im.PushStyleColor(ctx, im.Col_Text, 0xFF6666FF)
            if im.SmallButton(ctx, "x") then remove_wc = wi end
            im.PopStyleColor(ctx)

            im.PopID(ctx)
        end
        im.EndTable(ctx)
    end

    if remove_wc then
        table.remove(settings_state.custom_wildcards, remove_wc)
    end

    im.Spacing(ctx)

    -- New wildcard row
    im.SetNextItemWidth(ctx, 100)
    local rv_nn, val_nn = im.InputText(ctx, "##new_wc_name",
        get_buf("st_new_wn", settings_new_wc_name))
    if rv_nn then
        settings_new_wc_name = val_nn
        input_buffers["st_new_wn"] = val_nn
    end
    im.SameLine(ctx)
    im.SetNextItemWidth(ctx, 160)
    local rv_np, val_np = im.InputText(ctx, "##new_wc_pat",
        get_buf("st_new_wp", settings_new_wc_pattern))
    if rv_np then
        settings_new_wc_pattern = val_np
        input_buffers["st_new_wp"] = val_np
    end
    im.SameLine(ctx)
    local BUILTIN_WILDCARDS = {
        "$monthname","$computer","$project","$author","$minute",
        "$hour12","$year2","$month","$year","$hour","$user","$day"
    }
    local function is_builtin(name)
        for _, b in ipairs(BUILTIN_WILDCARDS) do if b == name then return true end end
        return false
    end
    local can_add = settings_new_wc_name:sub(1, 1) == "$"
        and settings_new_wc_name ~= ""
        and settings_new_wc_pattern ~= ""
        and not is_builtin(settings_new_wc_name)
    if not can_add then im.BeginDisabled(ctx) end
    if im.Button(ctx, "+ Add") then
        settings_state.custom_wildcards[#settings_state.custom_wildcards + 1] = {
            name    = settings_new_wc_name,
            pattern = settings_new_wc_pattern,
        }
        settings_new_wc_name    = ""
        settings_new_wc_pattern = ""
        input_buffers["st_new_wn"] = ""
        input_buffers["st_new_wp"] = ""
    end
    if not can_add then im.EndDisabled(ctx) end

    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)

    if im.Button(ctx, "Save & Close", 120, 0) then
        core.settings.Save(settings_state)
        settings_open = false
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Cancel", 80, 0) then
        -- Discard working copy, reload from saved state
        settings_state = core.settings.Load()
        settings_open  = false
    end

    im.End(ctx)
end
```

- [ ] **Step 3: Call `draw_settings_window()` in the main loop**

After `draw_preset_editor()` was removed — add the call at the bottom of `Loop()` before `im.PopStyleVar`:

```lua
draw_settings_window()
```

- [ ] **Step 4: Run in REAPER — verify settings window**

Confirm: `⚙ Settings` button opens the window, delimiter field defaults to `_`, version label defaults to `v`, custom wildcards can be added with `$name` / pattern, added wildcards appear in the table, `x` removes them, `Save & Close` persists to ExtState (verify by reopening), custom wildcards resolve correctly in name previews.

- [ ] **Step 5: Commit**

```bash
git add scripts/Track/ajsfx_ProjectBuilder.lua
git commit -m "feat: add settings window (global delimiter, version label, custom wildcards)"
```

---

## Task 11: Final cleanup + window sizing

**Files:**
- Modify: `scripts/Track/ajsfx_ProjectBuilder.lua`

- [ ] **Step 1: Update default window size and minimum size**

In the `Loop()` function, update:

```lua
im.SetNextWindowSize(ctx, 860, 540, im.Cond_FirstUseEver)
```

- [ ] **Step 2: Remove any dead code and unused variables**

Search for and remove:
- Any remaining references to `editing_preset`, `edit_new_preset_name`, `edit_is_new` (should already be gone from Task 6)
- The old `COLOR_SHARED`, `COLOR_INPUT`, `COLOR_DELIM` constants (now inlined in the strip drawing code)
- The old `draw_preset_layout()` helper function
- The old `draw_labeled_input_text()` and `draw_labeled_input_int()` helpers if no longer used

- [ ] **Step 3: Add `.superpowers` to `.gitignore` if not already present**

```bash
grep -q ".superpowers" .gitignore || echo ".superpowers/" >> .gitignore
```

- [ ] **Step 4: Run all tests**

```
lua tests/test_core_naming.lua
```

Expected: `11 passed, 0 failed`

- [ ] **Step 5: Full end-to-end verification in REAPER**

Open REAPER. Run `ajsfx_ProjectBuilder`. Verify:
- [ ] Window opens at 860×540
- [ ] Default presets load (Standard Asset, VO Asset, Blank)
- [ ] Add Batch creates a new tab
- [ ] Tab `×` removes the batch
- [ ] Preset strip shows sections as pills, S/I toggles, `<`/`>` reorders, label editable
- [ ] Save dialog pre-fills preset name; shows overwrite warning for existing names
- [ ] Track layout spinners update counts, `▼ Preview` shows diagram, `▶ Preview` hides it
- [ ] Groups table shared columns sync across rows, input columns independent
- [ ] Preview column updates live
- [ ] Output panel shows all batches, clicking a batch section switches tabs
- [ ] `⚙ Settings` opens settings window; delimiter change updates output previews
- [ ] Custom wildcard defined in settings resolves in group name previews
- [ ] `⚡ GENERATE` creates tracks with correct folder/aux/audio structure
- [ ] Session saves on close, reloads correctly on reopen

- [ ] **Step 6: Final commit**

```bash
git add scripts/Track/ajsfx_ProjectBuilder.lua scripts/lib/ajsfx_core.lua .gitignore
git commit -m "feat: complete Project Builder UI redesign

- Batch tab bar replaces sidebar
- Inline horizontal preset editor strip replaces popup window
- Collapsible track layout diagram
- Groups table with inline shared-column editing
- Persistent output panel with clickable batch navigation
- Settings window for delimiter, version label, custom wildcards
- core.naming, core.settings, core.ResolveWildcards extracted to shared library"
```
