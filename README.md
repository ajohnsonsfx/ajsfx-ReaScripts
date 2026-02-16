# ajsfx - REAPER Scripts

A collection of custom ReaScripts for REAPER, written in Lua.

## Installation

1.  Download the scripts or clone this repository.
2.  Place the files in your REAPER Scripts directory (usually `AppData/Roaming/REAPER/Scripts` on Windows, or `~/Library/Application Support/REAPER/Scripts` on macOS).
3.  Open REAPER.
4.  Open the Action List (`?`).
5.  Click `New Action` -> `Load ReaScript...`.
6.  Select the desired `.lua` files from your Scripts directory.

## Dependencies

These scripts rely on a shared core library. Ensure the `lib/` folder containing `ajsfx_core.lua` is present in the same directory as the scripts.

## Scripts

### Track Management
*   **ajsfx_Track_CollapseVisibleChildrenAtHighestSelectedLevel.lua**: Collapses visible children tracks at the highest selected level.
*   **ajsfx_Track_CollapseVisibleChildrenAtLowestSelectedLevel.lua**: Collapses visible children tracks at the lowest selected level.
*   **ajsfx_Track_UnCollapseVisibleChildrenAtHighestSelectedLevel.lua**: Uncollapses visible children tracks at the highest selected level.
*   **ajsfx_Track_UnCollapseVisibleChildrenAtLowestSelectedLevel.lua**: Uncollapses visible children tracks at the lowest selected level.

### Item Management
*   **ajsfx_GentleNormalizer.lua**: Normalizes selected items gently (likely to a target that isn't 0dB, preserving dynamics).
*   **ajsfx_MediaItemCounter.lua**: Counts the number of selected media items.
*   **ajsfx_SetAllSelectedItemsLengthToFirstSelectedItem.lua**: Sets the length of all selected items to match the length of the first selected item.
*   **ajsfx_ToggleMuteSelectedItemsOrTracks.lua**: Toggles mute for selected items. If no items are selected, toggles mute for selected tracks.

## License

[MIT](LICENSE) (or specify your preferred license)
