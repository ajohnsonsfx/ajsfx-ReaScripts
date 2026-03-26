# CLAUDE.md — ajsfx-Scripts

This file provides guidance for AI assistants working in this repository.

## Project Overview

A collection of custom ReaScripts (Lua) for [REAPER](https://www.reaper.fm/), the digital audio workstation. Scripts automate track and media item management tasks. They are loaded into REAPER's Action List and invoked as actions or toolbar buttons.

## Repository Structure

```
ajsfx-Scripts/
├── lib/
│   └── ajsfx_core.lua                          # Shared core library
├── ajsfx_GentleNormalizer.lua                   # ImGui GUI script
├── ajsfx_MediaItemCounter.lua                   # ImGui overlay script (toggle)
├── ajsfx_MediaItemCounter_Settings.lua          # ImGui settings panel for the counter
├── ajsfx_SetAllSelectedItemsLengthToFirstSelectedItem.lua
├── ajsfx_ToggleMuteSelectedItemsOrTracks.lua
├── ajsfx_Track_CollapseVisibleChildrenAtHighestSelectedLevel.lua
├── ajsfx_Track_CollapseVisibleChildrenAtLowestSelectedLevel.lua
├── ajsfx_Track_UnCollapseVisibleChildrenAtHighestSelectedLevel.lua
├── ajsfx_Track_UnCollapseVisibleChildrenAtLowestSelectedLevel.lua
├── CHANGELOG.md
├── README.md
└── .gitignore
```

## Core Library — `lib/ajsfx_core.lua`

All scripts (except the ImGui-heavy ones) require this library. It provides:

| Function | Description |
|---|---|
| `core.Print(msg)` | Debug output to REAPER's console |
| `core.Transaction(name, func)` | Wraps a function in `Undo_BeginBlock` / `Undo_EndBlock` + `PreventUIRefresh`. Catches errors via `pcall` and shows a message box on failure. |
| `core.GetTrackDepth(track)` | Returns folder nesting depth (0 = top level) |
| `core.IsTrackVisibleInArrangement(track)` | Returns `true` if track is visible (not hidden by a collapsed parent) |
| `core.GetSelectedTracksDepthRange()` | Returns `{min, max}` depth among visible selected tracks, or `nil` |
| `core.AdjustFolderStateDynamic(selector, action_state)` | Collapses/uncollapses folder tracks at a target depth. `selector` = `"deepest"` or `"shallowest"`. `action_state` = `0` (uncollapse) or `2` (collapse) |
| `core.GetRazorEdits(track)` | Parses `P_RAZOREDITS` from a track; returns list of `{start_time, end_time, guid}` |

## Script Patterns

### Simple action scripts (non-GUI)
These wrap their logic in `core.Transaction()` for undo support and UI refresh batching:

```lua
local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. package.path

local core = require("lib.ajsfx_core")

core.Transaction("Undo Block Name", function()
  -- logic here
end)
```

### ImGui GUI scripts
Scripts with persistent windows use the `reaper-imgui` library (`imgui` v0.9.3) via a deferred loop:

```lua
local success, im = pcall(function()
    package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
    return require('imgui')('0.9.3')
end)

local function Loop()
    -- validate ctx, draw UI
    if open then r.defer(Loop) end
end
r.defer(Loop)
```

ImGui contexts must be validated each frame with `im.ValidatePtr(ctx, 'ImGui_Context*')` and recreated if invalid.

### Toggle scripts (like `ajsfx_MediaItemCounter.lua`)
Scripts that run as toggleable REAPER actions use `r.get_action_context()` to get `cmdID`, then:
- Set toggle state on start: `r.SetToggleCommandState(section, cmdID, 1)`
- Clear toggle state on exit via `r.atexit()`

## Configuration / State Persistence

Settings are persisted using REAPER's `ExtState` API (survives restarts when `persist = true`):

- **Section name**: `"ajsfx_MediaItemCounter"` (counter config), `"ajsfx_MediaItemCounter_Presets"` (presets)
- **Read**: `r.GetExtState(section, key)` / `r.HasExtState(section, key)`
- **Write**: `r.SetExtState(section, key, value, true)` — `true` = persist to disk
- **Delete**: `r.DeleteExtState(section, key, true)`

The counter script polls for config changes every 0.5 seconds to pick up changes made by the settings script without requiring a restart.

## Color Format Convention

Colors in the counter scripts use REAPER's `AABBGGRR` integer format (not standard RGBA). Helper functions `ColorToRGBA` / `RGBAToColor` convert between this format and ImGui's `RGBA` format (used by `im.ColorEdit4`).

## Script Metadata Headers

Every script begins with ReaScript metadata comments:

```lua
-- @description Human-readable name
-- @author ajsfx
-- @version X.Y
-- @about Brief description
```

**ReaPack `@provides` Quirk:**
If your script relies on a shared library (like `ajsfx_core.lua`) and you declare an `@provides` block to include it, you **must** also explicitly provide the script itself using `[main] .`. Otherwise, ReaPack assumes the script is *only* a provider of the library and will not register it as a main action in the REAPER Action List.

Correct `@provides` usage:
```lua
-- @provides
--   [main] .
--   [nomain] ../lib/ajsfx_core.lua
```

Keep these accurate when editing scripts.

## Key REAPER API Concepts

- `r.CountSelectedTracks(0)` / `r.GetSelectedTrack(0, i)` — iterate selected tracks
- `r.CountSelectedMediaItems(0)` / `r.GetSelectedMediaItem(0, i)` — iterate selected items
- `r.GetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT")` — folder collapse state: `0`=normal, `1`=small, `2`=collapsed
- `r.GetMediaTrackInfo_Value(track, "B_SHOWINTCP")` — track visibility in TCP
- `r.GetParentTrack(track)` — parent track for depth traversal
- `r.CalculateNormalization(source, type, target, 0, 0)` — returns linear gain needed to hit target level
- `r.JS_Window_FindChildByID` / `r.JS_Window_GetRect` — js_ReaScriptAPI extension for window geometry
- `r.GetProjectStateChangeCount(0)` — cache invalidation signal

## Development Conventions

1. **Always use `core.Transaction()`** for any script that modifies project state. This ensures proper undo block management and UI refresh batching.
2. **Load `ajsfx_core` via relative path** — use the `debug.getinfo` pattern to resolve `script_path` before `require("lib.ajsfx_core")`.
3. **ImGui version pinning** — all GUI scripts load `imgui` at version `'0.9.3'`. Do not change this without testing.
4. **No global state between scripts** — scripts are isolated Lua environments. Shared state uses `r.ExtState`.
5. **Mute toggle logic** — uses "any unmuted → mute all, else unmute all" semantics. Maintain this pattern in similar toggle operations.
6. **Track collapse scripts** operate on ALL tracks at the target depth, not just selected ones. The selection is only used to determine the target depth.
7. **Performance** — `ajsfx_MediaItemCounter` uses render caching (`DrawCache`) and project-state-change-count invalidation to avoid redundant per-frame iteration. Maintain this pattern in overlay scripts.

## File Naming

All scripts follow the pattern: `ajsfx_<Category>_<Description>.lua` or `ajsfx_<Description>.lua`. Use PascalCase for multi-word segments.

## What to Ignore

The `.gitignore` excludes:
- `.clinerules` — Cline AI assistant rules file
- `plans/` — development planning documents
- `.vscode/` — editor config
- `*.bak`, `*.RPP-bak` — REAPER project backups
