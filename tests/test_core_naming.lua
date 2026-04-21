-- tests/test_core_naming.lua
-- Run from repo root: lua tests/test_core_naming.lua

-- ── Mock REAPER global ──────────────────────────────────────────────────────
reaper = {
    GetProjectName          = function() return "MyProject.rpp" end,
    GetSetProjectAuthor     = function() return true, "TestAuthor" end,
    HasExtState             = function(section, key) return false end,
    GetExtState             = function(section, key) return "" end,
    SetExtState             = function(section, key, val, persist) end,
    DeleteExtState          = function(section, key, persist) end,
    ShowConsoleMsg          = function(msg) io.write(msg) end,
    ShowMessageBox          = function(msg, title, flags) end,
}

-- ── Load core ───────────────────────────────────────────────────────────────
package.path = package.path .. ";lib/?.lua"
local core = require("ajsfx_core")

-- ── Minimal test runner ─────────────────────────────────────────────────────
local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        print("  PASS  " .. name)
        passed = passed + 1
    else
        print("  FAIL  " .. name .. "\n        " .. tostring(err))
        failed = failed + 1
    end
end
local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or "") .. "\n        expected: " .. tostring(b) .. "\n        got:      " .. tostring(a), 2)
    end
end

-- ── Settings tests ──────────────────────────────────────────────────────────
print("\n=== core.settings ===")

test("Load returns defaults when no ExtState", function()
    local s = core.settings.Load()
    assert_eq(s.delimiter,     "_",  "delimiter default")
    assert_eq(s.version_label, "v",  "version_label default")
    assert_eq(#s.custom_wildcards, 0, "custom_wildcards empty")
end)

-- ── Naming tests ────────────────────────────────────────────────────────────
print("\n=== core.naming ===")

test("SerializePreset produces type:label pipe-separated string", function()
    local preset = {
        name = "My Preset",
        sections = {
            { type = "shared", label = "Character" },
            { type = "input",  label = "Action" },
            { type = "shared", label = "Date" },
        }
    }
    local s = core.naming.SerializePreset(preset)
    assert_eq(s, "shared:Character|input:Action|shared:Date", "serialized form")
end)

test("DeserializePreset round-trips correctly", function()
    local preset = {
        name = "My Preset",
        sections = {
            { type = "shared", label = "Character" },
            { type = "input",  label = "Action" },
        }
    }
    local str = core.naming.SerializePreset(preset)
    local out = core.naming.DeserializePreset("My Preset", str)
    assert_eq(out.name, "My Preset")
    assert_eq(#out.sections, 2)
    assert_eq(out.sections[1].type,  "shared")
    assert_eq(out.sections[1].label, "Character")
    assert_eq(out.sections[2].type,  "input")
    assert_eq(out.sections[2].label, "Action")
end)

test("DeserializePreset migrates legacy format (leading delimiter field)", function()
    -- Old format: "delimiter|type:label|type:label"
    local legacy = "_|shared:Character|input:Action"
    local out = core.naming.DeserializePreset("Legacy", legacy)
    assert_eq(#out.sections, 2, "section count after migration")
    assert_eq(out.sections[1].label, "Character")
    assert_eq(out.sections[2].label, "Action")
end)

test("IsDefaultPreset returns true for defaults, false for custom", function()
    local defaults = {
        { name = "Standard Asset", sections = {} },
        { name = "VO Asset",       sections = {} },
    }
    assert_eq(core.naming.IsDefaultPreset("Standard Asset", defaults), true)
    assert_eq(core.naming.IsDefaultPreset("My Custom",      defaults), false)
end)

-- ── Wildcard tests ──────────────────────────────────────────────────────────
print("\n=== core.ResolveWildcards ===")

test("Resolves $year to 4-digit year", function()
  local result = core.ResolveWildcards("asset_$year")
  local expected = "asset_" .. os.date("%Y")
  assert_eq(result, expected)
end)

test("Resolves $project from mocked project name", function()
  local result = core.ResolveWildcards("$project_sfx")
  assert_eq(result, "MyProject_sfx")
end)

test("Resolves $monthname before $month to avoid partial match", function()
  local result = core.ResolveWildcards("$monthname")
  assert_eq(result, os.date("%B"))
end)

test("Custom wildcard resolved before built-in wildcards", function()
  -- Temporarily override HasExtState/GetExtState to return a custom wildcard
  local original_has = reaper.HasExtState
  local original_get = reaper.GetExtState
  reaper.HasExtState = function(section, key)
    if section == "ajsfx_UserSettings" and key == "custom_wildcards" then return true end
    return false
  end
  reaper.GetExtState = function(section, key)
    if section == "ajsfx_UserSettings" and key == "custom_wildcards" then
      return "$mydate\t$year$month"
    end
    return ""
  end
  core.settings.Invalidate()  -- bust cache so the new mock is picked up
  local result = core.ResolveWildcards("$mydate")
  local expected = os.date("%Y") .. os.date("%m")
  reaper.HasExtState = original_has
  reaper.GetExtState = original_get
  core.settings.Invalidate()  -- bust cache so subsequent tests don't see mock data
  assert_eq(result, expected, "custom wildcard + built-in expansion")
end)

-- ── ResolveGroupName tests ──────────────────────────────────────────────────
print("\n=== core.naming.ResolveGroupName ===")

test("Resolves shared + input sections with delimiter from settings", function()
  local batch = {
    sections = {
      { type = "shared", label = "Char" },
      { type = "input",  label = "Action" },
    },
    shared_values = { Char = "Hero" },
    groups = { [1] = { Action = "Attack" } },
  }
  local result = core.naming.ResolveGroupName(batch, 1)
  assert_eq(result, "Hero_Attack")
end)

test("Resolves wildcard in shared value", function()
  local batch = {
    sections = {
      { type = "shared", label = "Date" },
      { type = "input",  label = "Name" },
    },
    shared_values = { Date = "$year" },
    groups = { [1] = { Name = "Boom" } },
  }
  local result = core.naming.ResolveGroupName(batch, 1)
  local expected = os.date("%Y") .. "_Boom"
  assert_eq(result, expected)
end)

test("ResolveGroupName returns empty-joined string for out-of-bounds group_index", function()
  local batch = {
    sections = {
      { type = "input", label = "Name" },
    },
    shared_values = {},
    groups = { [1] = { Name = "Hero" } },
  }
  -- group_index 2 doesn't exist — should return "" not error
  local result = core.naming.ResolveGroupName(batch, 2)
  assert_eq(result, "")
end)

print("\nAll done: " .. passed .. " passed, " .. failed .. " failed")
if failed > 0 then os.exit(1) end
