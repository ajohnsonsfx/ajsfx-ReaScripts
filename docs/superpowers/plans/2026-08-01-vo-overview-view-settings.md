# VO Overview View Settings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the VO Overview table drag-reordered columns, a two-control Settings window, and a per-column header menu for vertical alignment, word wrap and font size.

**Architecture:** A new pure module `VO/lib/ajsfx_vo_view.lua` owns every default, every validation rule, the alignment arithmetic and all `ExtState` I/O — so the testable half of the feature never touches ImGui. `VO/ajsfx_VO_Overview.lua` consumes it for drawing: three attached fonts, a per-frame column-width cache that feeds row-height measurement one frame later, and a hand-opened header popup.

**Tech Stack:** Lua 5.4, REAPER ReaScript API, ReaImGui via the `'0.9.3'` shim, ReaPack packaging, plain-Lua tests against `tests/mock_reaper.lua`.

## Global Constraints

- The design spec is `docs/superpowers/specs/2026-08-01-vo-overview-view-settings-design.md`. It is the authority; this plan implements it.
- **ReaImGui API version is pinned to `'0.9.3'`.** Both scripts call `require('imgui')('0.9.3')`. Use only 0.9.3 signatures, whatever ReaImGui build is installed. Specifically: `im.CreateFont(family, size)`, `im.Attach(ctx, font)`, `im.PushFont(ctx, font)` — **not** the 0.10 form `PushFont(ctx, font, size)`.
- **Optional ImGui entry points go through `Api(name)`.** `VO/ajsfx_VO_Overview.lua:34` defines `local function Api(name) return rawget(im, name) end`. The ReaImGui shim raises on any unknown field, so `im.Foo and im.Foo(ctx)` is a crash, not a guard. Any field not guaranteed present in every 0.9.x binding must be fetched with `Api`.
- **ExtState section is `vo.EXT_SECTION`**, which is the string `"ajsfx_vo"` (`VO/lib/ajsfx_vo.lua:2451`). All new keys are prefixed `view_` and written with `persist = true`.
- **Per-column settings are keyed by the column's `key` field**, never by its index.
- Tests are plain Lua, run with `./run_tests.sh` from the repo root. No test framework: each file defines its own local `test(name, fn)` helper, prints PASS/FAIL, and calls `os.exit(1)` if anything failed. Follow `tests/test_vo.lua` exactly.
- **`VO/lib/ajsfx_vo.lua` is not modified by this plan.**
- Every `@version` bump must add or update `@changelog` in the same header — CI reads it for the ReaPack changelog.
- Commit after every task. Do not push; the branch is `feature/vo-overview`.

---

### Task 1: The pure view-settings module

Everything that can be tested without ImGui: defaults, validation, alignment
arithmetic, font-size clamping, and `ExtState` persistence.

**Files:**
- Create: `VO/lib/ajsfx_vo_view.lua`
- Create: `tests/test_vo_view.lua`

**Interfaces:**
- Consumes: nothing.
- Produces, all used by Tasks 2–4:
  - `view.ALIGNS` — array `{"top","middle","bottom"}`; `view.ALIGN_SET` — set form
  - `view.FONT_KEYS` — array `{"small","medium","large"}`; `view.FONT_SET` — set form
  - `view.FONT_MIN` = `6`, `view.FONT_MAX` = `48`
  - `view.FONT_DEFAULTS` — `{ small = 11, medium = 13, large = 16 }`
  - `view.WRAP_DEFAULTS` — `{ line_text = true }`
  - `view.ClampFontSize(n, fallback) -> integer`
  - `view.AlignOffset(row_h, cell_h, align) -> integer`
  - `view.NormalizeColumn(key, raw) -> { align = string, wrap = boolean, font = string }`
  - `view.LoadColumn(key) -> table` (same shape as `NormalizeColumn` returns)
  - `view.SaveColumn(key, col)` -> nil
  - `view.ClearColumns(keys)` -> nil, where `keys` is an array of column keys
  - `view.LoadRestore() -> boolean`, `view.SaveRestore(on)`
  - `view.LoadFontSizes() -> { small =, medium =, large = }`, `view.SaveFontSizes(sizes)`

- [ ] **Step 1: Write the failing test**

Create `tests/test_vo_view.lua`:

```lua
-- Unit tests for VO/lib/ajsfx_vo_view.lua
-- Run with: lua tests/test_vo_view.lua (from the repository root)
-- Pure presentation settings: no ImGui, and REAPER only for ExtState.

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    print("  FAIL: " .. name .. " - " .. tostring(err))
  end
end

-- The mock must install the global `reaper` BEFORE the module captures it: the
-- module does `local r = reaper` at load time.
package.path = package.path .. ";VO/lib/?.lua;tests/?.lua"
local mock = require("mock_reaper")
mock.reset()
local view = require("ajsfx_vo_view")

print("\n=== ajsfx_vo_view.lua Unit Tests ===\n")

--------------------------------
-- ClampFontSize
--------------------------------
print("ClampFontSize:")

test("a size in range is kept, floored to whole points", function()
  assert(view.ClampFontSize(14.7, 13) == 14, "Got " .. tostring(view.ClampFontSize(14.7, 13)))
end)

test("a size above the maximum clamps to 48", function()
  assert(view.ClampFontSize(500, 13) == 48, "Got " .. tostring(view.ClampFontSize(500, 13)))
end)

test("a size below the minimum clamps to 6", function()
  assert(view.ClampFontSize(1, 13) == 6, "Got " .. tostring(view.ClampFontSize(1, 13)))
end)

test("a non-number falls back rather than erroring", function()
  assert(view.ClampFontSize("banana", 13) == 13, "Got " .. tostring(view.ClampFontSize("banana", 13)))
  assert(view.ClampFontSize(nil, 13) == 13, "nil should fall back")
end)

test("a numeric string is accepted, since ExtState returns strings", function()
  assert(view.ClampFontSize("17", 13) == 17, "Got " .. tostring(view.ClampFontSize("17", 13)))
end)

--------------------------------
-- AlignOffset
--------------------------------
print("\nAlignOffset:")

test("top puts the cell at the row's top", function()
  assert(view.AlignOffset(40, 13, "top") == 0, "Got " .. view.AlignOffset(40, 13, "top"))
end)

test("middle centres the cell in the row", function()
  assert(view.AlignOffset(40, 13, "middle") == 13, "Got " .. view.AlignOffset(40, 13, "middle"))
end)

test("bottom drops the cell to the row's foot", function()
  assert(view.AlignOffset(40, 13, "bottom") == 27, "Got " .. view.AlignOffset(40, 13, "bottom"))
end)

test("a cell as tall as its row never offsets", function()
  assert(view.AlignOffset(13, 13, "bottom") == 0, "Equal heights should not move")
end)

test("a cell taller than its row never offsets negatively", function()
  assert(view.AlignOffset(13, 40, "middle") == 0, "Negative offset would draw outside the row")
end)

test("an unrecognised alignment behaves as middle", function()
  assert(view.AlignOffset(40, 13, "sideways") == 13, "Unknown align should fall back to middle")
end)

--------------------------------
-- NormalizeColumn
--------------------------------
print("\nNormalizeColumn:")

test("an empty column takes the defaults", function()
  local c = view.NormalizeColumn("notes", nil)
  assert(c.align == "middle", "Got align " .. tostring(c.align))
  assert(c.wrap == false, "Got wrap " .. tostring(c.wrap))
  assert(c.font == "medium", "Got font " .. tostring(c.font))
end)

test("line_text defaults to wrapping, because it is the column that needs it", function()
  assert(view.NormalizeColumn("line_text", nil).wrap == true, "line_text should wrap by default")
end)

test("valid values survive normalisation", function()
  local c = view.NormalizeColumn("notes", { align = "bottom", wrap = true, font = "large" })
  assert(c.align == "bottom" and c.wrap == true and c.font == "large", "Valid values were altered")
end)

test("unrecognised values fall back to the defaults without erroring", function()
  local c = view.NormalizeColumn("notes", { align = "diagonal", font = "enormous" })
  assert(c.align == "middle", "Got align " .. tostring(c.align))
  assert(c.font == "medium", "Got font " .. tostring(c.font))
end)

test("an explicit false overrides a wrapping default", function()
  local c = view.NormalizeColumn("line_text", { wrap = false })
  assert(c.wrap == false, "An explicit false must win over the default")
end)

--------------------------------
-- Persistence
--------------------------------
print("\nPersistence:")

test("a saved column round-trips through ExtState", function()
  mock.reset()
  view.SaveColumn("notes", { align = "top", wrap = true, font = "small" })
  local c = view.LoadColumn("notes")
  assert(c.align == "top" and c.wrap == true and c.font == "small",
         "Round-trip lost a value: " .. tostring(c.align) .. "/" ..
         tostring(c.wrap) .. "/" .. tostring(c.font))
end)

test("an unsaved column loads its defaults", function()
  mock.reset()
  local c = view.LoadColumn("line_text")
  assert(c.align == "middle" and c.wrap == true and c.font == "medium",
         "Unsaved column did not take defaults")
end)

test("a corrupt stored value loads as the default", function()
  mock.reset()
  reaper.SetExtState("ajsfx_vo", "view_col_notes_align", "diagonal", true)
  assert(view.LoadColumn("notes").align == "middle", "A hand-edited key must not break loading")
end)

test("ClearColumns removes every stored column key", function()
  mock.reset()
  view.SaveColumn("notes", { align = "top", wrap = true, font = "small" })
  view.SaveColumn("line_text", { align = "bottom", wrap = false, font = "large" })
  view.ClearColumns({ "notes", "line_text" })
  assert(reaper.GetExtState("ajsfx_vo", "view_col_notes_align") == "", "notes align survived")
  assert(reaper.GetExtState("ajsfx_vo", "view_col_line_text_wrap") == "", "line_text wrap survived")
  assert(view.LoadColumn("notes").align == "middle", "Cleared column should read as default")
end)

test("restore defaults to on and round-trips", function()
  mock.reset()
  assert(view.LoadRestore() == true, "Restore should default to on")
  view.SaveRestore(false)
  assert(view.LoadRestore() == false, "Restore did not round-trip")
  view.SaveRestore(true)
  assert(view.LoadRestore() == true, "Restore did not round-trip back")
end)

test("font sizes default to 11/13/16 and round-trip clamped", function()
  mock.reset()
  local s = view.LoadFontSizes()
  assert(s.small == 11 and s.medium == 13 and s.large == 16,
         "Got " .. s.small .. "/" .. s.medium .. "/" .. s.large)
  view.SaveFontSizes({ small = 2, medium = 20, large = 999 })
  local t = view.LoadFontSizes()
  assert(t.small == 6 and t.medium == 20 and t.large == 48,
         "Sizes should be clamped on save: " .. t.small .. "/" .. t.medium .. "/" .. t.large)
end)

print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
./run_tests.sh
```

Expected: `tests/test_vo_view.lua` fails with `module 'ajsfx_vo_view' not found`, and the runner exits non-zero. The other four test files must still pass.

- [ ] **Step 3: Write the module**

Create `VO/lib/ajsfx_vo_view.lua`:

```lua
-- @noindex
-- Presentation settings for the ajsfx VO Overview table.
--
-- Everything here is pure but for ExtState: no ImGui, no project state. The
-- window's LOOK — which column wraps, how tall its rows sit, what size it draws
-- at — is a property of the user, not of the session, so it lives in ExtState
-- and is shared by every project.
--
-- Deliberately NOT part of vo.CONFIG_SCHEMA: that schema drives the ScriptMatch
-- Settings dialog and describes matching. Nothing in this file affects a match.

local r = reaper

local view = {}

-- Shared with ajsfx_vo.lua's EXT_SECTION. Repeated rather than required so this
-- module stays loadable on its own, which is what makes it testable.
view.SECTION = "ajsfx_vo"

view.ALIGNS    = { "top", "middle", "bottom" }
view.ALIGN_SET = { top = true, middle = true, bottom = true }

view.FONT_KEYS = { "small", "medium", "large" }
view.FONT_SET  = { small = true, medium = true, large = true }

-- 6 is the smallest size that still renders legibly at 100% scaling; 48 is well
-- past any use for a table and stops a typo turning one row into a screenful.
view.FONT_MIN, view.FONT_MAX = 6, 48

-- Medium is 13 because that is what the table already draws at, so a user who
-- never opens Settings sees no change.
view.FONT_DEFAULTS = { small = 11, medium = 13, large = 16 }

view.DEFAULT_ALIGN = "middle"
view.DEFAULT_FONT  = "medium"

-- The one column long enough to be worth wrapping out of the box. Everything
-- else is a name, a number or a status and reads better clipped to one line.
view.WRAP_DEFAULTS = { line_text = true }

local ALIGN_FACTOR = { top = 0, middle = 0.5, bottom = 1 }

-- -----------------------------------------------------------------------
-- Pure helpers
-- -----------------------------------------------------------------------

-- ExtState hands back strings, and a user can type anything into the size
-- fields, so this accepts both and never errors.
function view.ClampFontSize(n, fallback)
  local size = tonumber(n)
  if not size then return fallback end
  size = math.floor(size)
  if size < view.FONT_MIN then return view.FONT_MIN end
  if size > view.FONT_MAX then return view.FONT_MAX end
  return size
end

-- How far down a cell of height `cell_h` sits in a row of height `row_h`.
-- Clamped at zero: a cell taller than its row (a wrapped cell that decided the
-- row height in the first place) must not be pushed above the row's top.
function view.AlignOffset(row_h, cell_h, align)
  local factor = ALIGN_FACTOR[align]
  if not factor then factor = ALIGN_FACTOR[view.DEFAULT_ALIGN] end
  local slack = (row_h or 0) - (cell_h or 0)
  if slack <= 0 then return 0 end
  return math.floor(slack * factor)
end

-- A column's settings with every unrecognised value replaced by its default.
-- `raw` may be nil, partial, or hand-edited nonsense from ExtState.
function view.NormalizeColumn(key, raw)
  raw = raw or {}
  local wrap
  if raw.wrap == nil then
    wrap = view.WRAP_DEFAULTS[key] == true
  else
    wrap = raw.wrap == true
  end
  return {
    align = view.ALIGN_SET[raw.align] and raw.align or view.DEFAULT_ALIGN,
    wrap  = wrap,
    font  = view.FONT_SET[raw.font] and raw.font or view.DEFAULT_FONT,
  }
end

-- -----------------------------------------------------------------------
-- Persistence
-- -----------------------------------------------------------------------

local function Get(key)
  local v = r.GetExtState(view.SECTION, key)
  if v == "" then return nil end
  return v
end

local function Set(key, value)
  r.SetExtState(view.SECTION, key, tostring(value), true)
end

local function ColumnKey(key, field) return "view_col_" .. key .. "_" .. field end

function view.LoadColumn(key)
  local wrap_raw = Get(ColumnKey(key, "wrap"))
  return view.NormalizeColumn(key, {
    align = Get(ColumnKey(key, "align")),
    -- nil (never saved) is not the same as "0" (saved as off): only the second
    -- may override a wrapping default.
    wrap  = (wrap_raw ~= nil) and (wrap_raw == "1") or nil,
    font  = Get(ColumnKey(key, "font")),
  })
end

function view.SaveColumn(key, col)
  local c = view.NormalizeColumn(key, col)
  Set(ColumnKey(key, "align"), c.align)
  Set(ColumnKey(key, "wrap"), c.wrap and "1" or "0")
  Set(ColumnKey(key, "font"), c.font)
end

function view.ClearColumns(keys)
  for _, key in ipairs(keys or {}) do
    for _, field in ipairs({ "align", "wrap", "font" }) do
      r.DeleteExtState(view.SECTION, ColumnKey(key, field), true)
    end
  end
end

function view.LoadRestore()
  -- Absent means on. Remembering a layout is the behaviour a user expects
  -- without asking for it, so the box starts ticked.
  return Get("view_restore") ~= "0"
end

function view.SaveRestore(on)
  Set("view_restore", on and "1" or "0")
end

function view.LoadFontSizes()
  local out = {}
  for _, k in ipairs(view.FONT_KEYS) do
    out[k] = view.ClampFontSize(Get("view_font_" .. k), view.FONT_DEFAULTS[k])
  end
  return out
end

function view.SaveFontSizes(sizes)
  sizes = sizes or {}
  for _, k in ipairs(view.FONT_KEYS) do
    Set("view_font_" .. k, view.ClampFontSize(sizes[k], view.FONT_DEFAULTS[k]))
  end
end

return view
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
./run_tests.sh
```

Expected: all five test files pass, `test_vo_view.lua` reporting `20 passed, 0 failed`, and the runner exits 0.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo_view.lua tests/test_vo_view.lua
git commit -m "feat(VO): add the pure view-settings module behind the Overview table"
```

---

### Task 2: Settings window, column reorder, and Restore view settings

The two things that need no measurement: the flag that lets columns be dragged,
and the window holding the checkbox that decides whether the drag is remembered.

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`

**Interfaces:**
- Consumes from Task 1: `view.LoadRestore`, `view.SaveRestore`, `view.LoadFontSizes`, `view.SaveFontSizes`, `view.ClearColumns`, `view.FONT_KEYS`, `view.FONT_DEFAULTS`, `view.ClampFontSize`.
- Produces, used by Tasks 3–4:
  - `state.view` — `{ restore = boolean, sizes = { small=, medium=, large= }, cols = { [key] = {align=,wrap=,font=} } }`
  - `state.settings_open` — boolean
  - `ColumnKeys()` -> array of every `key` in `COLUMNS`, in declaration order
  - `BumpViewGen()` -> nil, invalidates cached row heights (a no-op stub here; Task 4 gives it a body)
  - `DrawSettingsWindow()` -> nil

- [ ] **Step 1: Require the module and load its settings at startup**

In `VO/ajsfx_VO_Overview.lua`, after the existing `local vo = require("lib.ajsfx_vo")` (line 18), add:

```lua
local view = require("lib.ajsfx_vo_view")
```

Add these fields to the `state` table (after `message_kind = "ok",` at line 160):

```lua
  -- Presentation. Loaded once at startup and written through on every change;
  -- nothing reads ExtState per frame.
  view          = { restore = true, sizes = {}, cols = {} },
  settings_open = false,
```

Immediately after the `COLUMNS` table (after line 90), add:

```lua
-- Every column key, in declaration order. Used to load, save and clear the
-- per-column settings without anything having to restate the list.
local function ColumnKeys()
  local keys = {}
  for i, c in ipairs(COLUMNS) do keys[i] = c.key end
  return keys
end
```

Immediately **below the `state` table** (after line 161), add the generation
counter. It goes here, not further down, because `Rebuild()` at line 307 has to
call it and Lua resolves upvalues by position:

```lua
-- Bumped whenever anything that changes a row's height changes: a settings
-- edit, a column resize, or a rebuild. Task 4 uses it to invalidate cached row
-- heights; declared here so every mutator, Rebuild included, is below it.
local view_gen = 0
local function BumpViewGen() view_gen = view_gen + 1 end
```

Below the `LoadLayoutSettings` / `SaveLayoutSettings` pair (after line 633), add:

```lua
-- -----------------------------------------------------------------------
-- Presentation settings
-- -----------------------------------------------------------------------

local function LoadViewSettings()
  state.view.restore = view.LoadRestore()
  state.view.sizes   = view.LoadFontSizes()
  state.view.cols    = {}
  for _, key in ipairs(ColumnKeys()) do
    -- With restore off the stored per-column settings are ignored AND cleared
    -- (see SetRestore), so this branch only ever sees an empty store. Reading
    -- the defaults explicitly keeps that true even if a key survives somehow.
    state.view.cols[key] = state.view.restore and view.LoadColumn(key)
                           or view.NormalizeColumn(key, nil)
  end
  BumpViewGen()
end

local function ColumnView(key)
  return state.view.cols[key] or view.NormalizeColumn(key, nil)
end

local function SetColumnView(key, field, value)
  local col = ColumnView(key)
  col[field] = value
  state.view.cols[key] = col
  if state.view.restore then view.SaveColumn(key, col) end
  BumpViewGen()
end

-- Turning restore OFF clears the stored per-column settings outright rather
-- than merely ignoring them, so "off" means one thing. Leaving them in place
-- would hide a layer of preferences that reappears the moment the box is
-- ticked again, which is a surprise with no upside.
local function SetRestore(on)
  state.view.restore = on
  view.SaveRestore(on)
  if not on then
    view.ClearColumns(ColumnKeys())
    for _, key in ipairs(ColumnKeys()) do
      state.view.cols[key] = view.NormalizeColumn(key, nil)
    end
  else
    for _, key in ipairs(ColumnKeys()) do
      view.SaveColumn(key, ColumnView(key))
    end
  end
  BumpViewGen()
end
```

- [ ] **Step 2: Call the loader at startup**

In the startup block, immediately after `LoadLayoutSettings()` (line 1208), add:

```lua
LoadViewSettings()
```

- [ ] **Step 3: Add the table flags**

In `DrawTable` (line 1156), replace the flags expression:

```lua
  local flags = im.TableFlags_Borders | im.TableFlags_Resizable
              | im.TableFlags_Reorderable
              | im.TableFlags_ScrollY | im.TableFlags_RowBg
  -- With restore off ImGui neither reads nor writes this table's widths and
  -- order, so the table opens at the widths COLUMNS declares. ImGui keys table
  -- settings by (table id, column count) anyway, so adding a column in a later
  -- version invalidates a saved layout by itself — which is correct.
  if not state.view.restore then
    local no_saved = Api('TableFlags_NoSavedSettings')
    if no_saved then flags = flags | no_saved end
  end
```

- [ ] **Step 4: Write the Settings window**

Add above the `Startup and loop` banner (before line 1200):

```lua
-- -----------------------------------------------------------------------
-- Settings
--
-- A window, not a modal: the point of changing a font size is watching the
-- table change under it.
-- -----------------------------------------------------------------------

local function DrawSettingsWindow()
  if not state.settings_open then return end

  im.SetNextWindowSize(ctx, 360, 200, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'VO Overview Settings', true)
  state.settings_open = open

  -- End is called only when Begin returned visible, matching the main window's
  -- loop. That is ReaImGui's contract, and it differs from upstream Dear ImGui.
  if visible then
    local changed, on = im.Checkbox(ctx, "Restore view settings", state.view.restore)
    if changed then SetRestore(on) end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx,
        "Remember the column widths, the column order, and each column's\n" ..
        "alignment, word wrap and font size, and put them back next time.\n" ..
        "Turning this off clears what is already stored.")
    end

    im.Spacing(ctx)
    -- SeparatorText is not in every 0.9.x binding, and the shim raises on an
    -- unknown field, so `im.SeparatorText and ...` would itself be the crash.
    local SeparatorText = Api('SeparatorText')
    if SeparatorText then SeparatorText(ctx, "Font sizes") else im.Separator(ctx) end
    im.TextDisabled(ctx, "Right-click a column header to pick which one it uses.")

    for _, key in ipairs(view.FONT_KEYS) do
      im.SetNextItemWidth(ctx, 100)
      local label = key:sub(1, 1):upper() .. key:sub(2)
      local hit, size = im.InputInt(ctx, label .. "##font_" .. key,
                                    state.view.sizes[key] or view.FONT_DEFAULTS[key])
      if hit then
        -- Clamped rather than rejected: there is no number a user can type here
        -- that should produce an error message.
        state.view.sizes[key] = view.ClampFontSize(size, view.FONT_DEFAULTS[key])
        view.SaveFontSizes(state.view.sizes)
        BumpViewGen()
      end
    end

    im.End(ctx)
  elseif open then
    -- Begin returns false when the window is collapsed; End is still required.
    im.End(ctx)
  end
end
```

- [ ] **Step 5: Add the Settings button and call the window**

In `loop()`, in the top bar after the `Choose…` button block (after line 1255), add:

```lua
    im.SameLine(ctx)
    if im.Button(ctx, "Settings") then state.settings_open = true end
```

After the main window's `im.End(ctx)` (line 1315) and before the
`if pending_action then` block, add:

```lua
    -- Drawn after the main window's End so it is a sibling, not a child.
    DrawSettingsWindow()
```

- [ ] **Step 6: Check the file still loads**

```bash
luac -p VO/ajsfx_VO_Overview.lua && ./run_tests.sh
```

Expected: `luac -p` prints nothing (syntax OK) and the runner exits 0. If `luac`
is not installed, use `lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))"`.

- [ ] **Step 7: Test in REAPER**

Open ajsfx VO Overview. Confirm:
1. Drag a column header sideways — the column moves, and the cells move with it.
2. Close and reopen the script — the new order is kept.
3. Click Settings — the window opens with Restore ticked and 11 / 13 / 16.
4. Untick Restore, close and reopen the script — columns are back at their
   declared widths and order.

- [ ] **Step 8: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "feat(VO): let Overview columns be dragged, and add a Settings window for restoring the view"
```

---

### Task 3: Fonts and the header context menu

Three attached fonts, and the menu that assigns one to a column. Alignment and
wrap are written by the menu here but have no visible effect until Task 4; the
menu is built once rather than twice.

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`

**Interfaces:**
- Consumes from Tasks 1–2: `view.ALIGNS`, `view.FONT_KEYS`, `ColumnView(key)`, `SetColumnView(key, field, value)`, `state.view.sizes`, `BumpViewGen`.
- Produces, used by Task 4:
  - `PushCellFont(key)` -> nil, pushes the column's font and increments `font_depth`
  - `PopCellFont()` -> nil
  - `font_depth` — upvalue integer, unwound by `DrawTable`
  - `EnsureFonts()` -> nil, (re)creates and attaches the three fonts when `fonts_dirty`
  - `DrawHeaderMenu(c)` -> nil, drawn immediately after that column's `im.TableHeader`

- [ ] **Step 1: Add the font pool**

Add **immediately after `local ctx = im.CreateContext('VO Overview')`** (line
790, under the `Drawing` banner). Position matters: everything below uses `ctx`,
and `ctx` is a file-local declared at 790. A function written above that line
would bind the *global* `ctx`, which is nil.

```lua
-- -----------------------------------------------------------------------
-- Fonts
--
-- ReaImGui fonts are created at a fixed size and must be attached to the
-- context before the frame that uses them, so a size change cannot take effect
-- until the next frame. At frame rate that is invisible.
--
-- Medium pushes its own font rather than relying on the default, so all three
-- presets are editable in the same way.
-- -----------------------------------------------------------------------

local fonts       = {}     -- [size_key] = font object, or nil if creation failed
local fonts_dirty = true   -- set whenever a preset size changes

local function EnsureFonts()
  if not fonts_dirty then return end
  fonts_dirty = false

  for _, key in ipairs(view.FONT_KEYS) do
    local old = fonts[key]
    if old then
      -- Detach before dropping the reference: an attached font ReaImGui still
      -- holds outlives the Lua variable that made it.
      pcall(function() im.Detach(ctx, old) end)
      fonts[key] = nil
    end
    local size = state.view.sizes[key] or view.FONT_DEFAULTS[key]
    local ok, font = pcall(function()
      local f = im.CreateFont('sans-serif', size)
      im.Attach(ctx, f)
      return f
    end)
    if ok then
      fonts[key] = font
    else
      -- The table still draws, in the default font. Named rather than
      -- swallowed: a font that would not load is exactly the kind of silent
      -- difference a user would otherwise blame on the setting not working.
      state.message, state.message_kind =
        "Could not create the " .. key .. " font; that size will draw at the default.", "error"
    end
  end
end

-- Depth of the font stack, so an error thrown mid-row can be unwound. ImGui
-- raises on an unbalanced font stack at EndTable, which would bury the real
-- error under a second one.
local font_depth = 0

-- Paired by return value, not by testing the depth: when a font failed to
-- create the push is skipped, and a Pop that only checked `font_depth > 0`
-- would then pop an OUTER caller's font instead of nothing.
local function PushCellFont(key)
  local font = fonts[ColumnView(key).font]
  if not font then return false end
  im.PushFont(ctx, font)
  font_depth = font_depth + 1
  return true
end

local function PopCellFont(pushed)
  if not pushed then return end
  im.PopFont(ctx)
  font_depth = font_depth - 1
end
```

Every call site is therefore `local f = PushCellFont(key)` … `PopCellFont(f)`.

- [ ] **Step 2: Rebuild fonts between frames**

In `loop()`, immediately after the `ValidatePtr` block that may recreate the
context (after line 1216), add:

```lua
  -- Between frames, before Begin: attaching during a frame is not guaranteed to
  -- take effect for that frame. A recreated context has no fonts attached at
  -- all, so the recreate branch above must force this.
  EnsureFonts()
```

and inside that `ValidatePtr` branch, after `ctx = im.CreateContext('VO Overview')`, add:

```lua
    fonts, fonts_dirty = {}, true
```

In `DrawSettingsWindow`, in the `InputInt` handler from Task 2, add
`fonts_dirty = true` alongside `BumpViewGen()`:

```lua
        view.SaveFontSizes(state.view.sizes)
        fonts_dirty = true
        BumpViewGen()
```

- [ ] **Step 3: Write the header context menu**

Add immediately above `DrawTableBody` (above line 983):

```lua
-- The header menu.
--
-- BeginPopupContextItem is not used. TableHeader opens ImGui's OWN column menu
-- on right-click as soon as the table is Reorderable, and two popups cannot be
-- open at one level. Opening ours explicitly in the same frame, AFTER
-- TableHeader has opened ImGui's, replaces it — which is the behaviour wanted:
-- the built-in menu offers only column visibility, which this window does not
-- support.
local function DrawHeaderMenu(c)
  local popup_id = "hdr_" .. c.key
  if im.IsItemClicked(ctx, 1) then im.OpenPopup(ctx, popup_id) end
  if not im.BeginPopup(ctx, popup_id) then return end

  local col = ColumnView(c.key)

  if im.BeginMenu(ctx, "Vertical align") then
    for _, a in ipairs(view.ALIGNS) do
      local label = a:sub(1, 1):upper() .. a:sub(2)
      if im.MenuItem(ctx, label, nil, col.align == a) then
        SetColumnView(c.key, "align", a)
      end
    end
    im.EndMenu(ctx)
  end

  if im.MenuItem(ctx, "Word wrap", nil, col.wrap) then
    SetColumnView(c.key, "wrap", not col.wrap)
  end

  if im.BeginMenu(ctx, "Font size") then
    for _, f in ipairs(view.FONT_KEYS) do
      local label = f:sub(1, 1):upper() .. f:sub(2)
      local size  = state.view.sizes[f] or view.FONT_DEFAULTS[f]
      if im.MenuItem(ctx, string.format("%s (%d)", label, size), nil, col.font == f) then
        SetColumnView(c.key, "font", f)
      end
    end
    im.EndMenu(ctx)
  end

  im.EndPopup(ctx)
end
```

- [ ] **Step 4: Hang the menu off each header**

In `DrawTableBody`'s hand-drawn header loop (lines 992–998), replace the body of
the `for` with:

```lua
    for i, c in ipairs(COLUMNS) do
      im.TableSetColumnIndex(ctx, i - 1)
      im.TableHeader(ctx, c.label)
      if c.tip and im.IsItemHovered(ctx) then im.SetTooltip(ctx, c.tip) end
      DrawHeaderMenu(c)
    end
```

The `TableHeadersRow` fallback below it gets no menu: that branch only runs on a
binding too old to expose `TableRowFlags_Headers`, and there is no per-column
item there to hang a popup on.

- [ ] **Step 5: Prove the fonts work on one cell**

Only the Character cell is converted here. Task 4 replaces every text cell in
this loop with a `CellText` helper that pushes the font itself, so converting
the rest now would be work thrown away — but one converted cell is what makes
the menu testable at the end of this task.

In `DrawTableBody`, replace the Character cell (lines 1067–1068):

```lua
    im.TableSetColumnIndex(ctx, 3)
    local cf = PushCellFont("character")
    im.Text(ctx, row.character or "")
    PopCellFont(cf)
```

- [ ] **Step 6: Unwind the font stack on error**

In `DrawTable` (lines 1166–1170), extend the unwind loop:

```lua
  local ok, err = pcall(DrawTableBody)
  while id_depth > 0 do
    im.PopID(ctx)
    id_depth = id_depth - 1
  end
  while font_depth > 0 do
    im.PopFont(ctx)
    font_depth = font_depth - 1
  end
  im.EndTable(ctx)
```

- [ ] **Step 7: Check the file still loads**

```bash
lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && ./run_tests.sh
```

Expected: no output from the first command, runner exits 0.

- [ ] **Step 8: Test in REAPER**

1. Right-click the Line text header — the menu shows Vertical align, Word wrap
   (ticked), Font size, and **not** ImGui's column-visibility list.
2. Set Character to Large — that column's text grows, the toolbar does not move.
3. Close and reopen — Large is still set.
4. In Settings, change Large to 24 — the column grows on the next frame.

- [ ] **Step 9: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "feat(VO): per-column font sizes and a right-click menu on the Overview headers"
```

---

### Task 4: Word wrap, row heights and vertical alignment

The measured half. Wrap makes rows tall; tall rows make alignment a question;
both need the row's height before the row is drawn, which ImGui will not give.

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`

**Interfaces:**
- Consumes from Tasks 1–3: `view.AlignOffset`, `ColumnView`, `PushCellFont`, `PopCellFont`, `view_gen`, `BumpViewGen`.
- Produces: nothing later tasks consume.

- [ ] **Step 1: Add the width cache and the row measurer**

Add immediately above `DrawHeaderMenu` (from Task 3):

```lua
-- -----------------------------------------------------------------------
-- Row heights
--
-- ImGui has no TableGetColumnWidth: a cell's usable width is only knowable from
-- inside that cell, which is a frame too late to size the row it belongs to.
-- So cells record their width as they draw, and the NEXT frame measures with
-- it. While a column edge is being dragged the heights are therefore one frame
-- stale; they settle on the following frame, which at frame rate is not
-- perceptible. The alternative — a hidden measuring pass — costs a whole extra
-- table every frame.
-- -----------------------------------------------------------------------

local cell_width = {}   -- [column index 0-based] = last seen content width

-- Recording a width is what invalidates cached heights on a resize or reorder.
local function RecordCellWidth(index)
  local w = im.GetContentRegionAvail(ctx)
  local prev = cell_width[index]
  if not prev or math.abs(prev - w) > 0.5 then
    cell_width[index] = w
    BumpViewGen()
  end
end

-- Which columns wrap, and what text they wrap. Kept next to the measurer so
-- adding a wrapping column is one edit, not two.
local WRAPPABLE = {
  { index = 7,  key = "line_text",  text = function(row) return row.line_text or "" end },
  { index = 8,  key = "transcript", text = function(row) return row.transcript or "" end },
  { index = 3,  key = "character",  text = function(row) return row.character or "" end },
  { index = 5,  key = "asset",      text = function(row) return row.asset or "" end },
  { index = 9,  key = "source",
    text = function(row) return row.source_path and vo.Basename(row.source_path) or "" end },
}

-- The height this row needs, cached against the generation counter so a table
-- nobody is touching costs one comparison per row per frame. DrawTableBody
-- emits every row every frame (no ListClipper — ReaImGui rejects it here), so
-- an uncached CalcTextSize per wrapping cell would be paid on every row.
local function RowHeight(row)
  if row._vh_gen == view_gen and row._vh then return row._vh end

  -- Floored at the frame height so a row holding an InputText is never shorter
  -- than the widget in it.
  local h = im.GetFrameHeight(ctx)

  for _, w in ipairs(WRAPPABLE) do
    local col = ColumnView(w.key)
    local text = w.text(row)
    if col.wrap and text ~= "" then
      local width = cell_width[w.index]
      if width and width > 1 then
        local f = PushCellFont(w.key)
        local _, th = im.CalcTextSize(ctx, text, nil, width)
        PopCellFont(f)
        if th > h then h = th end
      end
    end
  end

  row._vh, row._vh_gen = h, view_gen
  return h
end
```

- [ ] **Step 2: Add the cell-drawing helpers**

Add immediately below `RowHeight`:

```lua
-- Depth of the text-wrap stack, unwound by DrawTable for the same reason the ID
-- and font stacks are.
local wrap_depth = 0

-- Move the caret down so this cell sits where its column's alignment says. The
-- height of what is about to be drawn has to be passed in: ImGui cannot be
-- asked after the fact without having already drawn it in the wrong place.
local function AlignCell(key, row_h, cell_h)
  local offset = view.AlignOffset(row_h, cell_h, ColumnView(key).align)
  if offset > 0 then im.SetCursorPosY(ctx, im.GetCursorPosY(ctx) + offset) end
end

-- One text cell: right font, right vertical position, wrapped or not.
-- `kind` is "plain" | "disabled" | a colour integer.
local function CellText(key, index, row_h, text, kind)
  RecordCellWidth(index)
  text = text or ""
  local col = ColumnView(key)
  local f = PushCellFont(key)

  local cell_h
  if col.wrap and text ~= "" then
    local width = cell_width[index]
    local _, th = im.CalcTextSize(ctx, text, nil, (width and width > 1) and width or nil)
    cell_h = th
  else
    cell_h = im.GetTextLineHeight(ctx)
  end
  AlignCell(key, row_h, cell_h)

  if col.wrap then
    -- 0.0 means "wrap at the end of the content region", which inside a table
    -- cell is the column edge.
    im.PushTextWrapPos(ctx, 0.0)
    wrap_depth = wrap_depth + 1
  end

  if kind == "disabled" then
    im.TextDisabled(ctx, text)
  elseif type(kind) == "number" then
    im.TextColored(ctx, kind, text)
  else
    im.Text(ctx, text)
  end

  if col.wrap then
    im.PopTextWrapPos(ctx)
    wrap_depth = wrap_depth - 1
  end
  PopCellFont(f)
end

-- A widget cell. Widgets never wrap: a single-line InputText cannot, and making
-- these multiline would change what Enter means in a field where Enter commits
-- a rename. They take the vertical offset all the same.
local function CellWidget(key, index, row_h)
  RecordCellWidth(index)
  AlignCell(key, row_h, im.GetFrameHeight(ctx))
end
```

- [ ] **Step 3: Rewrite the row loop to use them**

In `DrawTableBody`, replace the row loop's opening (lines 1016–1019):

```lua
  for i, row in ipairs(state.visible) do
    local row_h = RowHeight(row)
    im.TableNextRow(ctx, 0, row_h)
    im.PushID(ctx, i)
    id_depth = id_depth + 1
```

Then, cell by cell:

```lua
    -- Verified ------------------------------------------------------------
    im.TableSetColumnIndex(ctx, 0)
    CellWidget("verify", 0, row_h)
    local checked = row.user_status == "verified"
    local hit, now = im.Checkbox(ctx, "##ok", checked)
    if hit then pending_action = function() SetStatus(row, now and "verified" or nil) end end
```

Status — the row-spanning `Selectable` is given the row's height so a click
anywhere in a tall row still selects it, instead of only in its top
`FrameHeight` pixels:

```lua
    im.TableSetColumnIndex(ctx, 1)
    RecordCellWidth(1)
    local sel_flags = im.SelectableFlags_SpanAllColumns
    local overlap = Api('SelectableFlags_AllowOverlap')
    if overlap then sel_flags = sel_flags | overlap end
    local style = STATUS_STYLE[row.status]
    if im.Selectable(ctx, "##row", state.selection[row.uid] == true, sel_flags, 0, row_h) then
      local captured = ReadModifiers()
      local at = i
      pending_action = function() ClickRow(row, at, captured) end
    end
    if im.IsItemHovered(ctx) and not row.item then
      im.SetTooltip(ctx, row.status == "missing"
        and "This line has no audio in the project yet."
        or  "The audio for this row is not in this project.")
    end
    im.SameLine(ctx)
    -- SameLine returns the caret to the TOP of the tall selectable, so the
    -- status word needs its own offset.
    local f = PushCellFont("status")
    AlignCell("status", row_h, im.GetTextLineHeight(ctx))
    if row.user_status == "flagged" then
      im.TextColored(ctx, 0xDD6666FF, "Flagged")
    elseif style then
      im.TextColored(ctx, style.colour, style.label)
    end
    PopCellFont(f)
```

Select:

```lua
    im.TableSetColumnIndex(ctx, 2)
    if row.status ~= "missing" and row.status ~= "orphan" and (row.take_count or 0) > 0 then
      CellWidget("primary", 2, row_h)
      if im.RadioButton(ctx, "##sel", row.is_primary == true) then
        pending_action = function() SetPrimary(row) end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, (row.take_count > 1)
          and "Mark this take as the select."
          or  "The only take of this line.")
      end
    end
```

Character:

```lua
    im.TableSetColumnIndex(ctx, 3)
    CellText("character", 3, row_h, row.character, "plain")
```

Item name — the disabled branch is text, the editable branch is a widget:

```lua
    im.TableSetColumnIndex(ctx, 4)
    local shown = row.take_name or row.name_override or row.asset or ""
    if row.status == "missing" then
      CellText("item_name", 4, row_h, shown, "disabled")
      TooltipEvenWhenDisabled("This line has no take yet, so there is no item to name.")
    else
      CellWidget("item_name", 4, row_h)
      im.SetNextItemWidth(ctx, -1)
      local fchanged, fname = im.InputText(ctx, "##fn", shown,
                                           im.InputTextFlags_EnterReturnsTrue)
      if fchanged or im.IsItemDeactivatedAfterEdit(ctx) then
        if fname ~= shown then
          local captured = fname
          pending_action = function() Rename(row, captured) end
        end
      end
    end
```

CSV filename — the popup block is unchanged and stays after the text:

```lua
    im.TableSetColumnIndex(ctx, 5)
    local csv_name = row.asset or ""
    CellText("asset", 5, row_h, csv_name, "disabled")
    if csv_name ~= "" and im.BeginPopupContextItem(ctx, "##csv_menu") then
      ... unchanged ...
    end
```

Take, Line text, Transcript, Source, Time:

```lua
    im.TableSetColumnIndex(ctx, 6)
    if (row.take_count or 0) > 1 then
      CellText("take", 6, row_h, string.format("%d/%d", row.take_index or 0, row.take_count), "plain")
    elseif row.take_index then
      CellText("take", 6, row_h, "1/1", "disabled")
    else
      RecordCellWidth(6)
    end

    im.TableSetColumnIndex(ctx, 7)
    CellText("line_text", 7, row_h, row.line_text, "plain")

    im.TableSetColumnIndex(ctx, 8)
    if row.score and row.status == "review" then
      CellText("transcript", 8, row_h, row.transcript, 0xDDAA33FF)
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, string.format("Match confidence %.0f%%.", row.score * 100))
      end
    else
      CellText("transcript", 8, row_h, row.transcript, "disabled")
    end

    im.TableSetColumnIndex(ctx, 9)
    CellText("source", 9, row_h, row.source_path and vo.Basename(row.source_path) or "", "disabled")

    im.TableSetColumnIndex(ctx, 10)
    CellText("time", 10, row_h, FormatTime(row.proj_time), "disabled")
```

Notes:

```lua
    im.TableSetColumnIndex(ctx, 11)
    CellWidget("notes", 11, row_h)
    im.SetNextItemWidth(ctx, -1)
    local nchanged, notes = im.InputText(ctx, "##notes", row.notes or "")
    if nchanged then
      local captured = notes
      pending_action = function() SetNotes(row, captured) end
    end
```

- [ ] **Step 4: Invalidate cached heights on rebuild**

At the end of `Rebuild()` (after the `row.uid` loop, line 347), add:

```lua
  -- Row text may have changed, so every cached height is stale.
  BumpViewGen()
```

`BumpViewGen` is declared below `Rebuild` in the file. Move its declaration —
the `local view_gen = 0` / `local function BumpViewGen()` pair added in Task 2 —
up to just below the `state` table (after line 161) so it is in scope for both.

- [ ] **Step 5: Unwind the wrap stack on error**

In `DrawTable`, extend the unwind loop added in Task 3:

```lua
  while wrap_depth > 0 do
    im.PopTextWrapPos(ctx)
    wrap_depth = wrap_depth - 1
  end
```

Place it after the font loop and before `im.EndTable(ctx)`.

- [ ] **Step 6: Check the file still loads**

```bash
lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))" && ./run_tests.sh
```

Expected: no output from the first command, runner exits 0.

- [ ] **Step 7: Test in REAPER**

1. Line text wraps out of the box; a long line makes its row tall.
2. With a tall row, the OK checkbox sits vertically centred. Set Line text's
   align to Top — the checkbox stays put, the text moves to the row's top.
   Set the OK column to Top — the checkbox moves.
3. Click the empty right-hand end of a tall row — the row still selects.
4. Drag the Line text column narrower — rows grow taller, without flicker.
5. Type in a Notes field on a tall row — the field is where the alignment says
   and Enter still behaves as before.
6. Scroll a long table — no stutter. If there is, confirm `BumpViewGen` is not
   being called every frame by adding a temporary counter print.

- [ ] **Step 8: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "feat(VO): word wrap and per-column vertical alignment in the Overview table"
```

---

### Task 5: Ship it — packaging, version, manual test notes

The new lib file must be listed in `@provides` or ReaPack will not install it,
and `reapack-index` reports that kind of mistake as a *warning*, so the index
builds "successfully" while the package is broken.

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua:1-14` (header only)
- Modify: `VO/MANUAL_TEST.md`
- Modify: `VO/SPEC-overview.md`

**Interfaces:**
- Consumes: the finished feature.
- Produces: nothing.

- [ ] **Step 1: Add the new lib to `@provides`**

In `VO/ajsfx_VO_ScriptMatch.lua`, in the `@provides` block, add a line after
`lib/ajsfx_vo.lua`:

```
--   lib/ajsfx_vo_view.lua
```

The full block becomes:

```
-- @provides
--   [main] .
--   [main] ajsfx_VO_Settings.lua
--   [main] ajsfx_VO_Overview.lua
--   lib/ajsfx_vo.lua
--   lib/ajsfx_vo_view.lua
--   ../lib/ajsfx_core.lua > lib/ajsfx_core.lua
```

- [ ] **Step 2: Bump the version and write the changelog**

In the same header, change `-- @version 0.10` to `-- @version 0.11` and replace
the `@changelog` line with:

```
-- @changelog VO Overview columns can now be dragged into any order, and each column carries its own presentation. Right-click a column header for vertical alignment (top, middle or bottom), word wrap, and a font size; Line text wraps out of the box, and wrapped text makes rows as tall as they need to be while every other cell in the row sits where its own alignment says. A new Settings button in the top bar holds two controls: "Restore view settings", which remembers column widths, column order and each column's alignment, wrap and font between sessions, and the point sizes behind the Small, Medium and Large presets. Turning restore off clears what is already stored, so it means one thing.
```

- [ ] **Step 3: Record the manual tests**

Append to `VO/MANUAL_TEST.md`:

```markdown
## Overview — view settings (2026-08-01)

1. Drag a column header sideways. The column moves and its cells move with it.
   Close and reopen the script: the order is kept.
2. Settings → untick "Restore view settings". Close and reopen: columns are back
   at their declared widths and order, and every header menu reads Middle /
   wrap off / Medium — except Line text, which is wrap on.
3. Re-tick it, set Character to Large, reopen: Large is kept.
4. Right-click any header. The menu shows Vertical align, Word wrap and Font
   size — NOT ImGui's column-visibility list.
5. Turn Word wrap on for Line text. A long line grows its row. The OK checkbox
   stays vertically centred; set the OK column to Top and it moves to the top.
6. Click the empty right-hand end of a tall row: the row still selects, and the
   edit cursor moves.
7. Drag the Line text column narrower. Rows grow taller within a frame, without
   flicker.
8. Settings → set Large to 24. The columns using Large grow on the next frame;
   the toolbar does not move.
9. Settings → type 999 into Small. It clamps to 48 with no error message.
```

- [ ] **Step 4: Note the feature in the Overview spec**

Append to `VO/SPEC-overview.md`:

```markdown
## Presentation settings

How the table LOOKS is a property of the user, not of the session, so none of it
touches the project or the tracker. Column widths and column order are persisted
by ImGui itself, into `REAPER/ReaImGui/<hash>.ini`. Everything else lives in
`ExtState` under section `ajsfx_vo` with a `view_` prefix:

- `view_restore` — whether any of it is remembered at all. Turning it off clears
  the stored per-column keys rather than merely ignoring them, so "off" means
  one thing rather than hiding a layer that reappears when it is turned back on.
- `view_font_small` / `view_font_medium` / `view_font_large` — the point sizes
  behind the three presets. Medium is 13, the size the table has always drawn at.
- `view_col_<key>_align` / `_wrap` / `_font` — per column.

Per-column keys use the column's `key` field, never its index, so dragging
columns into a new order cannot scramble which setting belongs to which column,
and inserting a column in a later version does not shift every stored preference
by one.

The full design, including why row heights are measured a frame late, is in
`docs/superpowers/specs/2026-08-01-vo-overview-view-settings-design.md`.
```

- [ ] **Step 5: Run the full suite**

```bash
./run_tests.sh
```

Expected: all five files pass, exit 0.

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua VO/MANUAL_TEST.md VO/SPEC-overview.md
git commit -m "chore(VO): ship the Overview view settings — provides, version 0.11, manual tests"
```

- [ ] **Step 7: Push and confirm CI is green**

```bash
git push -u origin feature/vo-overview
```

Then:

```bash
gh run list --limit 1
```

Expected: the newest run is `completed / success`. A failed run publishes
nothing and says nothing. Also skim the build log for `reapack-index` warnings —
a packaging mistake is reported as a warning, so the index can build
"successfully" while silently omitting `lib/ajsfx_vo_view.lua`.

---

## Notes for the implementer

**Why the module is separate.** `VO/ajsfx_VO_Overview.lua` calls
`im.CreateContext` at load time, so it cannot be `require`d by a test. Anything
worth testing has to live somewhere else. `VO/lib/ajsfx_vo.lua` was ruled out to
keep this change off the module ScriptMatch and the Settings dialog both depend
on.

**Why `Api()` exists.** The ReaImGui shim's metatable raises on any unknown
field, so `im.Foo and im.Foo(ctx)` crashes on the bindings that lack `Foo`
rather than guarding against them. Anything not guaranteed in every 0.9.x
binding — `TableFlags_NoSavedSettings`, `SeparatorText`,
`SelectableFlags_AllowOverlap` — must go through `Api`.

**The one-frame lag is intended.** Do not try to remove it with a hidden
measuring pass. It costs a whole extra table per frame and buys nothing a user
can see.
