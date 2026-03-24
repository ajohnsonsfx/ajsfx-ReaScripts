# ajsfx - REAPER Scripts

A collection of custom ReaScripts for REAPER, written in Lua.

## Installation via ReaPack (Recommended)

1.  Install [ReaPack](https://reapack.com/) if you haven't already.
2.  In REAPER, go to **Extensions → ReaPack → Import repositories...**
3.  Paste this URL and click OK:
    ```
    https://github.com/ajohnsonsfx/ajsfx-Scripts/raw/main/index.xml
    ```
4.  Go to **Extensions → ReaPack → Browse packages...**
5.  Search for "ajsfx" and install the scripts you want.
6.  ReaPack will automatically download the shared core library alongside each script.

## Manual Installation

1.  Download the scripts or clone this repository.
2.  Place the files in your REAPER Scripts directory (usually `AppData/Roaming/REAPER/Scripts` on Windows, or `~/Library/Application Support/REAPER/Scripts` on macOS).
3.  Ensure the `lib/` folder containing `ajsfx_core.lua` is present in the same directory as the scripts.
4.  Open REAPER.
5.  Open the Action List (`?`).
6.  Click `New Action` -> `Load ReaScript...`.
7.  Select the desired `.lua` files from your Scripts directory.

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
