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

This project uses short-lived feature branches merged into `main`, which is the
release branch for ReaPack.

### Branches
- **`main`**: The only long-lived branch. Publishes to ReaPack, so it should always contain working, tested code.
- **`feature/<name>`**: Short-lived. Branch from `main`, merge back when done, delete.

> There used to be a long-lived `dev` branch. It fell 77 commits behind `main`
> while still carrying the pre-`Items/`/`Track/`/`pvx/` layout, so its test suite
> no longer ran against the tree at all — and because nothing merged from it, the
> documented workflow silently stopped describing reality. It was deleted on
> 2026-07-22 after confirming it held no commits that were not already in `main`.
> Don't reintroduce a long-lived branch without a reason to maintain it.

### Versioning & Release Process
1.  **Branch from `main`**: `git switch -c feature/<name> main`.
2.  **Test**: `./run_tests.sh` must pass; also exercise changes in REAPER.
3.  **Bump `@version` tags**: Update the `@version` metadata tag in the script headers for any modified scripts.
4.  **Add `@changelog` to each modified script**: Immediately below the `@version` line in the script header, add or update the `@changelog` tag with a plain-English summary of what changed in this version. CI extracts this tag and writes it into `index.xml` — without it, ReaPack shows a blank changelog to users.
    ```lua
    -- @version 0.5
    -- @changelog Fix fallback path for TakeFX when no track FX present
    ```
5.  **Merge into `main`**: Once changes are stable and tested, merge the feature branch into `main` and delete it.
6.  **CI handles the rest**: `.github/workflows/reapack.yml` runs the test suite and, on success, rebuilds `index.xml` via `reapack-index --rebuild --commit` and pushes it back to `main`. No manual `reapack-index` step is required post-merge; if CI's test job fails, fix the regression before the index will update.
7.  **Check the run actually succeeded**: `gh run list --limit 1`. A red CI job means nothing published, and the failure is silent from the repo's point of view — the pipeline sat broken from April to July 2026 without anyone noticing, so no releases went out in that window despite commits landing on `main`.

### Packaging traps that fail quietly

Both of these produce a **warning** from `reapack-index`, not an error, so the
build still reports success while shipping something wrong. Read the build log,
don't just check the green tick.

- **Only one package may `@provides` a given file.** If two scripts in a category
  both provide the same shared library, one package is dropped from `index.xml`
  entirely. Ship them as a single package with multiple `[main]` entries instead
  (see `VO/ajsfx_VO_ScriptMatch.lua`).
- **A library without `@noindex` becomes its own package**, and with `main="main"`
  it also registers in REAPER's action list as a script that does nothing when
  run. `pvx/lib/ajsfx_pvx.lua` is in this state; it is left alone only because it
  is already published and withdrawing it would affect existing installs.
