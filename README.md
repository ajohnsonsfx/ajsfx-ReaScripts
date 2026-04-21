# ajsfx

A personal toolkit for REAPER — custom ReaScripts and sound design reference docs.

- **[Items/](Items/)**, **[Track/](Track/)** — Lua ReaScripts for track and item management
- **[pvx/](pvx/)** — PVX time-varying pitch/stretch scripts + JSFX host
- **[lib/](lib/)** — Shared `ajsfx_core` helper library
- **[docs/](docs/)** — Sound design guides and workflow references

---

## ReaScripts

### Installation via ReaPack (Recommended)

1. Install [ReaPack](https://reapack.com/) if you haven't already.
2. In REAPER, go to **Extensions → ReaPack → Import repositories...**
3. Paste this URL and click OK:
   ```
   https://github.com/ajohnsonsfx/ajsfx/raw/main/index.xml
   ```
4. Go to **Extensions → ReaPack → Browse packages...**
5. Search for "ajsfx-ReaScripts" and install the scripts you want.
6. ReaPack will automatically download the shared core library alongside each script.

### Manual Installation

1. Download the scripts or clone this repository.
2. Place `Items/`, `Track/`, `lib/`, and `pvx/` in your REAPER Scripts directory (usually `AppData/Roaming/REAPER/Scripts` on Windows, or `~/Library/Application Support/REAPER/Scripts` on macOS).
3. Place `pvx/ajsfx_PVXHost.jsfx` in your REAPER Effects directory.
4. Ensure `lib/ajsfx_core.lua` sits alongside the `Items/` and `Track/` folders, and `pvx/lib/ajsfx_pvx.lua` alongside the PVX scripts.
4. Open REAPER, open the Action List (`?`), click `New Action` → `Load ReaScript...`, and select the desired `.lua` files.

### Track Management

- **Track/ajsfx_Track_CollapseVisibleChildrenAtHighestSelectedLevel.lua** — Collapses visible children tracks at the highest selected level.
- **Track/ajsfx_Track_CollapseVisibleChildrenAtLowestSelectedLevel.lua** — Collapses visible children tracks at the lowest selected level.
- **Track/ajsfx_Track_UnCollapseVisibleChildrenAtHighestSelectedLevel.lua** — Uncollapses visible children tracks at the highest selected level.
- **Track/ajsfx_Track_UnCollapseVisibleChildrenAtLowestSelectedLevel.lua** — Uncollapses visible children tracks at the lowest selected level.
- **Track/ajsfx_TrackVersioning.lua** — Duplicates selected tracks, increments a version number on the original, and archives the old version into a folder.

### Item Management

#### PVX Time-Varying Pitch/Stretch

Apply smoothly-animated pitch and time-stretch curves to a single audio item, processed offline by [pvx](https://github.com/TheColby/pvx) (a Python phase-vocoder CLI). Primary use case: doppler/whoosh sound design — draw a pitch contour, render, pull snippets from the result.

**Workflow:**

0. **Install pvx (first time only):** Run `ajsfx_PVX_Install` from the Action List. It detects Python 3, creates a venv, pip-installs pvx, and saves the path automatically. Requires Python 3.8+ on your PATH.
1. **(Optional) Prepare a MIDI or empty item first:** Run `ajsfx_PVX_PrepareItem` to render it to an audio take and insert the PVX Host automatically.
2. **Add PVX Host to your audio item's Take FX chain** (or skip to step 3 if PrepareItem did it).
3. **Draw envelopes:** Right-click the Pitch or Stretch slider in the Take FX window → *Show take envelope* → draw your curve.
4. **Render:** Run `ajsfx_PVX_Render` from the Action List / toolbar / keyboard shortcut.  A new take `pvx_v1` (v2, v3…) is added to the source item.
5. **(Optional) Preview:** Run `ajsfx_PVX_Preview` to audition the pvx output over a time selection (or ±N seconds around the cursor) without mutating the project.
6. **Configure:** Run `ajsfx_PVX_Settings` to set the pvx binary path, scratch directory, poll rate, and preview duration.

**Dependencies:**

| Dependency | Required for | Install |
|---|---|---|
| [pvx](https://github.com/TheColby/pvx) | Render, Preview | Python venv binary |
| [SWS Extension](https://www.sws-extension.org/) | Preview playback | sws-extension.org |
| [ReaImGui](https://github.com/cfillion/reaimgui) | Settings panel | ReaPack |
| js_ReaScriptAPI | Browse-for-folder dialog (optional) | ReaPack |

**Scripts:**

- **pvx/ajsfx_PVX_Install.lua** — One-click installer: detects Python 3, creates a venv, pip-installs pvx, saves the binary path to Settings.
- **pvx/ajsfx_PVX_Render.lua** — Applies pitch/stretch envelopes via pvx; adds a new take `pvx_v<n>` on the source item.
- **pvx/ajsfx_PVX_Preview.lua** — Previews pvx output for a time selection or cursor window; no project mutation. Requires SWS.
- **pvx/ajsfx_PVX_PrepareItem.lua** — Renders a MIDI or empty item to audio and inserts the PVX Host JSFX on the new take.
- **pvx/ajsfx_PVX_Settings.lua** — ImGui settings panel (pvx binary path, scratch dir, poll rate, preview seconds, timeout, Clear Scratch).
- **pvx/ajsfx_PVXHost.jsfx** — Pass-through JSFX that exposes Pitch (semitones) and Stretch (log₂ factor) as automatable sliders.

---

#### General Item Scripts

- **Items/ajsfx_GentleNormalizer.lua** — Normalizes selected items gently to a target level or based on selection average/peak.
- **Items/ajsfx_MediaItemCounter.lua** — Displays a persistent, configurable counter for the number of media items on each visible track.
- **Items/ajsfx_MediaItemCounter_Settings.lua** — A GUI for configuring the Media Item Counter.
- **Items/ajsfx_SetAllSelectedItemsLengthToFirstSelectedItem.lua** — Sets the length of all selected items to match the length of the first selected item.
- **Items/ajsfx_ToggleMuteSelectedItemsOrTracks.lua** — Toggles mute with priority: Razor Edits > Selected Items > Selected Tracks.

---

## Sound Design Docs

Reference guides and notes for sound design and REAPER workflow. See the **[docs/](docs/)** folder.

---

## License

[MIT](LICENSE)
