# Project Guidelines: ajsfx (REAPER ReaScripts)

Tech Stack: Lua, REAPER API, ReaImGui, ReaPack.

## Code Style & Conventions
See `.agents/standards.md` for full coding patterns and branching/release workflows.
- Action Scripts: Wrap logic in `core.Transaction("Name", function() ... end)` for undo support and UI batching.
- Persistence: Use REAPER's `ExtState` API (`GetExtState`, `SetExtState`).

## Architecture
See `.agents/context.md` for project structure.
- `lib/ajsfx_core.lua` (at repo root) is required by non-GUI scripts and provides standard transactions, track depth traversal, and REAPER debug print utilities.
- Script categories live one level up: `Items/`, `Track/`, `pvx/` at repo root — each maps directly to a ReaPack category under `Scripts/<repo>/<category>/`.
- `pvx/` contains the PVX time-varying pitch/stretch feature (scripts, JSFX host, shared `pvx/lib/ajsfx_pvx.lua`). PVX scripts are self-contained: their `@provides` ships a copy of `ajsfx_core.lua` into `pvx/lib/` so they don't depend on the `scripts/` category being installed.
- The venv created by `ajsfx_PVX_Install` lives at `Scripts/<repo>/venv/`, with location derived at runtime from `ajsfx_pvx.lua`'s install path via `debug.getinfo` — no hardcoded repo name.
- **PVX CLI contract is owned upstream at [TheColby/pvx](https://github.com/TheColby/pvx).** When changing `pvx.BuildArgv` or JSFX slider choices, verify flag names and allowed values against `src/pvx/core/voc.py` in that repo (argparse definitions) — our JSFX labels and slider value maps must match pvx's vocabulary. Binary resolution goes through `pvx.GetPVXBinary(cfg)` — every argv builder must use it so readiness checks and launches can't disagree.

## Related Repositories
- [Sound Design Documentation](https://github.com/ajohnsonsfx/SoundDesignDocs) - General sound design techniques and reference docs (formerly part of this repo's `docs/` folder).

## REAPER Environment
See `.agents/reaper_api.md` for common API functions and state change usage.
- Use `r.GetProjectStateChangeCount(0)` for cache invalidation.

## Build and Test
- Tests are located in `tests/` utilizing a mock REAPER environment (`tests/mock_reaper.lua`).
- Run tests using `./run_tests.sh`.
- CI (`.github/workflows/reapack.yml`) runs the test suite on every push and PR, and gates the auto-rebuild of `index.xml` on tests passing. To release, merge `dev` → `main`; CI rebuilds and pushes `index.xml` itself — no manual `reapack-index` needed post-merge.
