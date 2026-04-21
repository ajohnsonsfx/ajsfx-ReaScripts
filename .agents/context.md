# Project Context & Structure

## Repository Layout
```
ajsfx/
├── Items/                                       # Media item scripts
├── Track/                                       # Track management scripts
├── pvx/                                         # PVX pitch/stretch scripts + JSFX host
│   └── lib/ajsfx_pvx.lua                        # PVX helpers + self-locating venv
├── lib/
│   └── ajsfx_core.lua                           # Shared core library
├── docs/                                        # Sound design reference docs
├── README.md
└── .gitignore
```

## Shared Core Library (`lib/ajsfx_core.lua`)
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

## Project Overview
A collection of custom ReaScripts (Lua) for [REAPER](https://www.reaper.fm/), the digital audio workstation. Scripts automate track and media item management tasks. They are loaded into REAPER's Action List and invoked as actions or toolbar buttons.
