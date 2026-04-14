# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- **PVX Time-Varying Pitch/Stretch**: New feature — apply animated pitch and time-stretch curves to a single audio item using the pvx phase-vocoder CLI.
  - `scripts/FX/ajsfx_PVXHost.jsfx` — pass-through JSFX exposing Pitch (semitones) and Stretch (log₂ factor) sliders as REAPER automation targets.
  - `scripts/Items/ajsfx_PVX_Render.lua` — three-stage render pipeline (pre-PVX FX bake → pvx async → post-chain bake); imports result as `pvx_v<n>` take.
  - `scripts/Items/ajsfx_PVX_Preview.lua` — non-mutating preview via SWS `CF_Preview_PlayEx`; uses time selection or cursor window.
  - `scripts/Items/ajsfx_PVX_PrepareItem.lua` — converts MIDI/empty items to audio takes and inserts PVX Host automatically.
  - `scripts/Items/ajsfx_PVX_Settings.lua` — ImGui settings panel (binary path, scratch dir, poll rate, preview seconds, timeout, Clear Scratch).
  - `scripts/lib/ajsfx_pvx.lua` — shared pvx helper library (pure + REAPER-coupled functions).
  - `tests/test_pvx.lua` — unit tests for all pure helpers.
- **Unit Tests**: Added `tests/test_core.lua` with tests for color conversion, depth guard, razor edit parsing, toggle mute helpers, and config loading.
- **Core Library**: Added `core.Error()` for unified error reporting (console + message box), `core.ColorToRGBA()`/`core.RGBAToColor()` for color format conversion, `core.LoadMediaCounterConfig()` for shared config loading, `core.ToggleMuteItems()`/`core.ToggleMuteTracks()` for DRY mute toggle logic.

### Changed
- **Media Item Counter**: Fixed track visibility check to use `core.IsTrackVisibleInArrangement()` instead of raw `B_SHOWINTCP`, preventing counters from rendering on tracks hidden by collapsed parents.
- **Media Item Counter**: Replaced inline config loading with shared `core.LoadMediaCounterConfig()`. Added named constants for magic numbers (`MIN_TRACK_HEIGHT`, `CONFIG_CHECK_INTERVAL`, `DPI_SCROLL_SIZE`).
- **Media Item Counter Settings**: Replaced inline defaults, config loading, and color conversion with shared core functions. Added preset parsing validation with pcall and safety limit of 100 presets.
- **Gentle Normalizer**: Now uses `core.Transaction()` instead of manual undo blocks. Renamed `Loop()` to `loop()` for consistency. Added named constants for default values.
- **Toggle Mute**: Replaced 3 duplicated toggle patterns with `core.ToggleMuteItems()`/`core.ToggleMuteTracks()`.
- **Set Item Length**: Added user feedback when fewer than 2 items are selected.
- **Core Library**: Added depth guard (max 100) in `GetTrackDepth()` and `IsTrackVisibleInArrangement()`. Added depth caching in `AdjustFolderStateDynamic()`. Updated `Transaction()` error handler to use `core.Error()`.

### Fixed
- **Author Metadata**: Corrected `@author` from "Gemini Code Assist" to "ajsfx" in Media Item Counter and Settings scripts.

## [1.0.0] - 2026-03-24

### Added
- **Media Item Counter Settings**: Introduced `ajsfx_MediaItemCounter_Settings.lua` as a dedicated ImGui settings panel for the Media Item Counter script. Features include double-click to reset, preset saving/loading, and a new Horizontal Anchor setting (Left/Middle/Right).
- **Core Library**: Introduced `lib/ajsfx_core.lua` to centralize shared functionality for logging, debugging, and common REAPER API operations.
- **Documentation**: Added `README.md` with installation instructions and script descriptions.
- **Project Structure**: Added `.gitignore` to exclude development plans and configuration files.

### Changed
- **Media Item Counter**: Separated settings UI into its own script (`ajsfx_MediaItemCounter_Settings.lua`) and added support for Horizontal Anchoring to align the counter text.
- **Refactoring**: All scripts have been refactored to use the new `ajsfx_core` library, improving maintainability and reducing code duplication.
    - `ajsfx_GentleNormalizer.lua`
    - `ajsfx_MediaItemCounter.lua`
    - `ajsfx_SetAllSelectedItemsLengthToFirstSelectedItem.lua`
    - `ajsfx_ToggleMuteSelectedItemsOrTracks.lua`
    - `ajsfx_Track_CollapseVisibleChildrenAtHighestSelectedLevel.lua`
    - `ajsfx_Track_CollapseVisibleChildrenAtLowestSelectedLevel.lua`
    - `ajsfx_Track_UnCollapseVisibleChildrenAtHighestSelectedLevel.lua`
    - `ajsfx_Track_UnCollapseVisibleChildrenAtLowestSelectedLevel.lua`
- **Error Handling**: Improved error handling and debugging output across all scripts via the core library.
