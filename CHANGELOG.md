# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Added
- **Core Library**: Introduced `lib/ajsfx_core.lua` to centralize shared functionality for logging, debugging, and common REAPER API operations.
- **Documentation**: Added `README.md` with installation instructions and script descriptions.
- **Project Structure**: Added `.gitignore` to exclude development plans and configuration files.

### Changed
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
