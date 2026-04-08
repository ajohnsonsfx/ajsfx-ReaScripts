-- @description ajsfx Core Library
-- @author ajsfx
-- @version 1.1
-- @about Shared functions for ajsfx scripts
-- @noindex

local r = reaper

local core = {}

local MAX_DEPTH = 100 -- Safety limit for parent traversal

-- Debug Helper
function core.Print(msg)
  r.ShowConsoleMsg(tostring(msg) .. "\n")
end

-- Error reporting: logs to console and shows a message box
function core.Error(msg)
  local text = tostring(msg)
  r.ShowConsoleMsg("ajsfx Error: " .. text .. "\n")
  r.ShowMessageBox(text, "Error", 0)
end

-- Transaction Wrapper (Undo + PreventUIRefresh)
function core.Transaction(name, func)
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)

  local status, err = pcall(func)

  r.PreventUIRefresh(-1)

  if status then
    r.Undo_EndBlock(name, -1)
  else
    r.Undo_EndBlock(name, -1) -- Still close block to avoid sticking
    core.Error("Script Error:\n" .. tostring(err))
  end
end

-- Get Track Depth with safety guard
function core.GetTrackDepth(track)
  if not track then return 0 end
  local depth = 0
  local parent = r.GetParentTrack(track)
  while parent and depth < MAX_DEPTH do
    depth = depth + 1
    parent = r.GetParentTrack(parent)
  end
  return depth
end

-- Check if track is effectively visible (not hidden by collapsed parent)
function core.IsTrackVisibleInArrangement(track)
  if not track then return false end

  -- First check if track itself is visible in TCP
  if r.GetMediaTrackInfo_Value(track, "B_SHOWINTCP") == 0 then return false end

  -- Check all parents for collapsed state
  local parent = r.GetParentTrack(track)
  local guard = 0
  while parent and guard < MAX_DEPTH do
    guard = guard + 1
    -- I_FOLDERCOMPACT: 0=normal, 1=small, 2=collapsed (tiny)
    -- If parent is collapsed (2), the child is hidden
    if r.GetMediaTrackInfo_Value(parent, "I_FOLDERCOMPACT") == 2 then
      return false
    end
    parent = r.GetParentTrack(parent)
  end

  return true
end

-- Analyze selected tracks to find min/max depth among visible ones
function core.GetSelectedTracksDepthRange()
  local count = r.CountSelectedTracks(0)
  if count == 0 then return nil end

  local min_depth = math.huge
  local max_depth = -1

  -- Iterate SELECTED tracks only
  for i = 0, count - 1 do
    local track = r.GetSelectedTrack(0, i)
    if core.IsTrackVisibleInArrangement(track) then
      local depth = core.GetTrackDepth(track)

      if depth > max_depth then
        max_depth = depth
      end

      if depth < min_depth then
        min_depth = depth
      end
    end
  end

  if max_depth == -1 then return nil end -- No visible tracks selected

  return {
    min = min_depth,
    max = max_depth
  }
end

-- Logic for collapsing/uncollapsing based on selection depth
function core.AdjustFolderStateDynamic(selector, action_state)
  -- selector: "deepest" (max depth) or "shallowest" (min depth)
  -- action_state: 0 (uncollapse), 2 (collapse)

  local range = core.GetSelectedTracksDepthRange()
  if not range then return end -- No selection or no visible tracks selected

  local target_depth
  if selector == "deepest" then
    target_depth = range.max
  else
    target_depth = range.min
  end

  -- Cache depth lookups to avoid redundant parent traversals
  local depth_cache = {}

  -- Iterate ALL tracks in project to find matches at this depth
  local track_count = r.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = r.GetTrack(0, i)

    -- Check if this track is visible in arrangement (parent not collapsed)
    if core.IsTrackVisibleInArrangement(track) then
      local depth = depth_cache[track]
      if not depth then
        depth = core.GetTrackDepth(track)
        depth_cache[track] = depth
      end

      -- Apply to tracks at the target depth
      if depth == target_depth then
        -- Apply the folder state (collapse/uncollapse)
        r.SetMediaTrackInfo_Value(track, "I_FOLDERCOMPACT", action_state)
      end
    end
  end

  r.UpdateArrange()
end

-- Parse Razor Edits from a track
-- Returns list of {start_time, end_time, guid}
function core.GetRazorEdits(track)
  local retval, str = r.GetSetMediaTrackInfo_String(track, "P_RAZOREDITS", "", false)
  if not retval or str == "" then return {} end

  local edits = {}
  -- Format: "start end GUID start end GUID"
  -- Lua pattern to capture 3 items
  for s, e, guid in str:gmatch('(%S+)%s+(%S+)%s+"([^"]*)"') do
      table.insert(edits, {start_time = tonumber(s), end_time = tonumber(e), guid = guid})
  end
  -- Handle unquoted GUIDs only if quoted pattern found nothing
  if #edits == 0 then
      for s, e, guid in str:gmatch('(%S+)%s+(%S+)%s+(%S+)') do
        -- Check if GUID looks like a GUID {braces}
        if guid:sub(1,1) == "{" then
             table.insert(edits, {start_time = tonumber(s), end_time = tonumber(e), guid = guid})
        end
      end
  end

  return edits
end

--------------------------------
-- Color Conversion (AABBGGRR <-> RGBA)
--------------------------------

-- Convert REAPER's AABBGGRR integer to ImGui's RRGGBBAA
function core.ColorToRGBA(color)
  local a = (color >> 24) & 0xFF
  local b = (color >> 16) & 0xFF
  local g = (color >> 8) & 0xFF
  local r_val = color & 0xFF
  return (r_val << 24) | (g << 16) | (b << 8) | a
end

-- Convert ImGui's RRGGBBAA to REAPER's AABBGGRR integer
function core.RGBAToColor(color)
  local a = color & 0xFF
  local b = (color >> 8) & 0xFF
  local g = (color >> 16) & 0xFF
  local r_val = (color >> 24) & 0xFF
  return (a << 24) | (b << 16) | (g << 8) | r_val
end

--------------------------------
-- Media Item Counter Config
--------------------------------

local MEDIA_COUNTER_SECTION = "ajsfx_MediaItemCounter"

core.MEDIA_COUNTER_DEFAULTS = {
  FONT_SIZE = 12,
  FONT_NAME = "Arial",
  TEXT_COLOR = 0x99FFFFFF, -- White with 60% alpha (AABBGGRR format)
  HORIZONTAL_OFFSET = 5,
  VERTICAL_ALIGN = 0.5,
  H_ALIGN = 0, -- 0=Left, 1=Middle, 2=Right
  REFRESH_RATE = 30,
}

-- Load Media Item Counter config from ExtState with defaults
function core.LoadMediaCounterConfig()
  local defaults = core.MEDIA_COUNTER_DEFAULTS
  local cfg = {
    FONT_SIZE = defaults.FONT_SIZE,
    FONT_NAME = defaults.FONT_NAME,
    TEXT_COLOR = defaults.TEXT_COLOR,
    HORIZONTAL_OFFSET = defaults.HORIZONTAL_OFFSET,
    VERTICAL_ALIGN = defaults.VERTICAL_ALIGN,
    H_ALIGN = defaults.H_ALIGN,
    REFRESH_RATE = defaults.REFRESH_RATE,
  }

  if r.HasExtState(MEDIA_COUNTER_SECTION, "FONT_SIZE") then cfg.FONT_SIZE = tonumber(r.GetExtState(MEDIA_COUNTER_SECTION, "FONT_SIZE")) or cfg.FONT_SIZE end
  if r.HasExtState(MEDIA_COUNTER_SECTION, "TEXT_COLOR") then cfg.TEXT_COLOR = tonumber(r.GetExtState(MEDIA_COUNTER_SECTION, "TEXT_COLOR")) or cfg.TEXT_COLOR end
  if r.HasExtState(MEDIA_COUNTER_SECTION, "HORIZONTAL_OFFSET") then cfg.HORIZONTAL_OFFSET = tonumber(r.GetExtState(MEDIA_COUNTER_SECTION, "HORIZONTAL_OFFSET")) or cfg.HORIZONTAL_OFFSET end
  if r.HasExtState(MEDIA_COUNTER_SECTION, "VERTICAL_ALIGN") then cfg.VERTICAL_ALIGN = tonumber(r.GetExtState(MEDIA_COUNTER_SECTION, "VERTICAL_ALIGN")) or cfg.VERTICAL_ALIGN end
  if r.HasExtState(MEDIA_COUNTER_SECTION, "H_ALIGN") then cfg.H_ALIGN = tonumber(r.GetExtState(MEDIA_COUNTER_SECTION, "H_ALIGN")) or cfg.H_ALIGN end
  if r.HasExtState(MEDIA_COUNTER_SECTION, "REFRESH_RATE") then cfg.REFRESH_RATE = tonumber(r.GetExtState(MEDIA_COUNTER_SECTION, "REFRESH_RATE")) or cfg.REFRESH_RATE end

  return cfg
end

--------------------------------
-- Toggle Mute Helpers
--------------------------------

-- Toggle mute on a list of media items (any unmuted -> mute all, else unmute all)
function core.ToggleMuteItems(items)
  if #items == 0 then return end

  local any_unmuted = false
  for _, item in ipairs(items) do
    if r.GetMediaItemInfo_Value(item, "B_MUTE") == 0 then
      any_unmuted = true
      break
    end
  end

  local new_state = any_unmuted and 1 or 0
  for _, item in ipairs(items) do
    r.SetMediaItemInfo_Value(item, "B_MUTE", new_state)
  end
end

-- Toggle mute on a list of tracks (any unmuted -> mute all, else unmute all)
function core.ToggleMuteTracks(tracks)
  if #tracks == 0 then return end

  local any_unmuted = false
  for _, track in ipairs(tracks) do
    if r.GetMediaTrackInfo_Value(track, "B_MUTE") == 0 then
      any_unmuted = true
      break
    end
  end

  local new_state = any_unmuted and 1 or 0
  for _, track in ipairs(tracks) do
    r.SetMediaTrackInfo_Value(track, "B_MUTE", new_state)
  end
end

--------------------------------
-- Geometry Helpers
--------------------------------

-- Check if an item (pos, length) intersects a time range (start_time, end_time)
function core.ItemIntersectsRange(item_pos, item_length, range_start, range_end)
  local item_end = item_pos + item_length
  return item_pos < range_end and item_end > range_start
end

--------------------------------
-- Normalization Math
--------------------------------

-- Convert a linear gain value to decibels.  Returns nil if gain <= 0.
function core.LinearToDb(gain)
  if gain <= 0 then return nil end
  return 20 * math.log(gain, 10)
end

-- Convert a decibel value to linear gain.
function core.DbToLinear(db)
  return 10 ^ (db / 20)
end

-- Calculate the gain (in dB) to apply for a "gentle" normalization.
-- required_gain_db: full gain adjustment needed to hit the target
-- strength_pct: 0–100 percentage of adjustment to apply
-- Returns the scaled gain in dB and its linear equivalent.
function core.CalculateGentleNormGain(required_gain_db, strength_pct)
  local apply_db = required_gain_db * (strength_pct / 100.0)
  local apply_linear = core.DbToLinear(apply_db)
  return apply_db, apply_linear
end

--------------------------------
-- Wildcard Resolution
--------------------------------

function core.ResolveWildcards(str)
  -- Resolve user-defined custom wildcards first (they may contain built-in wildcards)
  local settings = core.settings.Load()
  for _, wc in ipairs(settings.custom_wildcards) do
    -- wc.name starts with "$" — escape for Lua pattern: "$" becomes "%$"
    local pattern = "%" .. wc.name
    local replacement = (wc.pattern:gsub("%%", "%%%%"))
    str = str:gsub(pattern, replacement)
  end

  -- Resolve built-in wildcards (ordered longest-first to prevent partial matches)
  local proj_name = r.GetProjectName(0, "")
  proj_name = proj_name:match("(.+)%.[^.]+$") or proj_name

  local replacements = {
    { "monthname", os.date("%B")                                        },
    { "computer",  os.getenv("COMPUTERNAME") or ""                     },
    { "project",   proj_name                                            },
    { "author",    select(2, r.GetSetProjectAuthor(0, false, "")) or "" },
    { "minute",    os.date("%M")                                        },
    { "hour12",    os.date("%I")                                        },
    { "year2",     os.date("%y")                                        },
    { "month",     os.date("%m")                                        },
    { "year",      os.date("%Y")                                        },
    { "hour",      os.date("%H")                                        },
    { "user",      os.getenv("USERNAME") or os.getenv("USER") or ""    },
    { "day",       os.date("%d")                                        },
  }
  for _, rep in ipairs(replacements) do
    str = str:gsub("%$" .. rep[1], (rep[2]:gsub("%%", "%%%%")))
  end
  return str
end

--------------------------------
-- Naming
--------------------------------

core.naming = {}
core.naming.DEFAULT_SECTION = "ajsfx_Presets"

function core.naming.SerializePreset(preset)
  -- Format: type:label|type:label|...  (no delimiter — delimiter is global in settings)
  local parts = {}
  for _, s in ipairs(preset.sections) do
    parts[#parts + 1] = s.type .. ":" .. s.label
  end
  return table.concat(parts, "|")
end

function core.naming.DeserializePreset(name, str)
  local parts = {}
  for part in str:gmatch("[^|]+") do
    parts[#parts + 1] = part
  end
  if #parts < 1 then return nil end

  -- Legacy migration: if first segment has no ":", it was the old delimiter field — discard it
  local start = 1
  if not parts[1]:find(":") then
    start = 2
  end

  local preset = { name = name, sections = {} }
  for i = start, #parts do
    local stype, label = parts[i]:match("^(%w+):(.+)$")
    if stype and label then
      preset.sections[#preset.sections + 1] = { type = stype, label = label }
    end
  end
  return preset
end

function core.naming.IsDefaultPreset(name, defaults)
  for _, dp in ipairs(defaults) do
    if dp.name == name then return true end
  end
  return false
end

function core.naming.LoadAllPresets(section, defaults)
  local presets = {}
  -- Deep-copy defaults first
  for _, dp in ipairs(defaults) do
    local p = { name = dp.name, sections = {} }
    for _, s in ipairs(dp.sections) do
      p.sections[#p.sections + 1] = { type = s.type, label = s.label }
    end
    presets[#presets + 1] = p
  end
  -- Load custom presets from ExtState
  if r.HasExtState(section, "LIST") then
    local list_str = r.GetExtState(section, "LIST")
    for name in list_str:gmatch("[^|]+") do
      if name ~= "" and not core.naming.IsDefaultPreset(name, defaults) then
        local key = "P_" .. name
        if r.HasExtState(section, key) then
          local p = core.naming.DeserializePreset(name, r.GetExtState(section, key))
          if p then
            presets[#presets + 1] = p
          end
        end
      end
    end
  end
  return presets
end

function core.naming.SaveCustomPresets(section, presets, defaults)
  local names = {}
  for _, p in ipairs(presets) do
    if not core.naming.IsDefaultPreset(p.name, defaults) then
      names[#names + 1] = p.name
      r.SetExtState(section, "P_" .. p.name, core.naming.SerializePreset(p), true)
    end
  end
  r.SetExtState(section, "LIST", table.concat(names, "|"), true)
end

function core.naming.DeleteCustomPreset(section, presets, name, defaults)
  if core.naming.IsDefaultPreset(name, defaults) then return presets end
  r.DeleteExtState(section, "P_" .. name, true)
  local new = {}
  for _, p in ipairs(presets) do
    if p.name ~= name then new[#new + 1] = p end
  end
  core.naming.SaveCustomPresets(section, new, defaults)
  return new
end

function core.naming.ResolveGroupName(batch, group_index)
  local settings = core.settings.Load()
  local parts = {}
  for _, section in ipairs(batch.sections) do
    local value
    if section.type == "shared" then
      value = batch.shared_values[section.label] or ""
    else
      value = (batch.groups[group_index] and batch.groups[group_index][section.label]) or ""
    end
    parts[#parts + 1] = core.ResolveWildcards(value)
  end
  return table.concat(parts, settings.delimiter)
end

--------------------------------
-- Settings
--------------------------------

core.settings = {}
local SETTINGS_SECTION = "ajsfx_UserSettings"

function core.settings.Load()
  local s = {
    delimiter        = "_",
    custom_wildcards = {},
    version_label    = "v",
  }
  if r.HasExtState(SETTINGS_SECTION, "delimiter") then
    s.delimiter = r.GetExtState(SETTINGS_SECTION, "delimiter")
  end
  if r.HasExtState(SETTINGS_SECTION, "version_label") then
    s.version_label = r.GetExtState(SETTINGS_SECTION, "version_label")
  end
  if r.HasExtState(SETTINGS_SECTION, "custom_wildcards") then
    local raw = r.GetExtState(SETTINGS_SECTION, "custom_wildcards")
    for line in raw:gmatch("[^\n]+") do
      local name, pattern = line:match("^([^\t]+)\t(.+)$")
      if name and pattern then
        s.custom_wildcards[#s.custom_wildcards + 1] = { name = name, pattern = pattern }
      end
    end
  end
  return s
end

function core.settings.Save(s)
  r.SetExtState(SETTINGS_SECTION, "delimiter",        s.delimiter,     true)
  r.SetExtState(SETTINGS_SECTION, "version_label",    s.version_label, true)
  local lines = {}
  for _, wc in ipairs(s.custom_wildcards) do
    lines[#lines + 1] = wc.name .. "\t" .. wc.pattern
  end
  r.SetExtState(SETTINGS_SECTION, "custom_wildcards", table.concat(lines, "\n"), true)
end

return core
