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

test("a saved wrap of off overrides a wrapping default", function()
  mock.reset()
  view.SaveColumn("line_text", { wrap = false })
  assert(view.LoadColumn("line_text").wrap == false,
         "A stored 0 must beat the line_text default")
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
