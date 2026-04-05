# Project Guidelines: ajsfx (REAPER ReaScripts)

Tech Stack: Lua, REAPER API, ReaImGui, ReaPack.

## Code Style & Conventions
See `.agents/standards.md` for full coding patterns and branching/release workflows.
- Action Scripts: Wrap logic in `core.Transaction("Name", function() ... end)` for undo support and UI batching.
- Persistence: Use REAPER's `ExtState` API (`GetExtState`, `SetExtState`).

## Architecture
See `.agents/context.md` for project structure.
- `scripts/lib/ajsfx_core.lua` is required by non-GUI scripts and provides standard transactions, track depth traversal, and REAPER debug print utilities.

## Related Repositories
- [Sound Design Documentation](https://github.com/ajohnsonsfx/SoundDesignDocs) - General sound design techniques and reference docs (formerly part of this repo's `docs/` folder).

## REAPER Environment
See `.agents/reaper_api.md` for common API functions and state change usage.
- Use `r.GetProjectStateChangeCount(0)` for cache invalidation.

## Build and Test
- Tests are located in `tests/` utilizing a mock REAPER environment (`tests/mock_reaper.lua`).
- Run tests using `./run_tests.sh`.
- To release via ReaPack, merge `dev` to `main`, run `reapack-index`, commit `index.xml` and push.
