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

return core
