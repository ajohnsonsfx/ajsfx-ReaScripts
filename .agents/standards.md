# Coding Patterns & Standards

## Simple Action Patterns (non-GUI)
These wrap logic in `core.Transaction()` for undo support and UI refresh batching:

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

## ImGui `Begin/End` Contracts
Scripts with persistent windows use `reaper-imgui` (v0.9.3) via a deferred loop.
When `im.Begin` returns `false` (window collapsed or clipped), the wrapper **automatically calls `ImGui::End()` internally**.

**Correct pattern:**
```lua
local visible, open = im.Begin(ctx, "Window Title", true, flags)
if visible then
    -- draw content
    im.End(ctx)  -- only called when visible=true
end
```
*Note: `im.BeginChild`/`im.EndChild` always require a matching `EndChild`.*

## `ExtState` Persistence
Settings are persisted using REAPER's `ExtState` API:
- **Read**: `r.GetExtState(section, key)` / `r.HasExtState(section, key)`
- **Write**: `r.SetExtState(section, key, value, true)` — `true` = persist to disk
- **Delete**: `r.DeleteExtState(section, key, true)`

## Color Formats
Colors use REAPER's `AABBGGRR` integer format. Use helper functions `ColorToRGBA` / `RGBAToColor` to convert to/from ImGui's `RGBA`.

## ReaPack Metadata Requirements
Every script requires metadata headers:
```lua
-- @description Human-readable name
-- @author ajsfx
-- @version X.Y
-- @about Brief description
```

### `@provides` Block
If using a shared library, explicitly provide the script itself:
```lua
-- @provides
--   [main] .
--   [nomain] ../lib/ajsfx_core.lua
```

## File Naming
`ajsfx_<Category>_<Description>.lua` or `ajsfx_<Description>.lua` (PascalCase).

## Branching & Release Workflow

This project uses a standard `dev` to `main` workflow for versioning and releases via ReaPack.

### Branches
- **`main`**: The stable branch. This branch is used for ReaPack releases. It should always contain working, tested code.
- **`dev`**: The active development branch. Daily work, new features, and experimentation happen here.

### Versioning & Release Process
1.  **Work in `dev`**: All development starts in the `dev` branch.
2.  **Test in REAPER**: Ensure all scripts and changes are thoroughly tested within the REAPER environment.
3.  **Bump `@version` tags**: Update the `@version` metadata tag in the script headers for any modified scripts.
4.  **Merge `dev` into `main`**: Once changes are stable and tested, merge the `dev` branch into `main`.
5.  **Run `reapack-index`**: Execute the `reapack-index` command to update the `index.xml` file.
6.  **Commit and Push**: Commit the changes to `main` (including the updated `index.xml`) and push to the remote repository.
