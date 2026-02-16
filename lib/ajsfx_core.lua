-- @description ajsfx Core Library
-- @author ajsfx
-- @version 1.0
-- @about Shared functions for ajsfx scripts

local r = reaper

local core = {}

-- Debug Helper
function core.Print(msg)
  r.ShowConsoleMsg(tostring(msg) .. "\n")
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
    r.ShowMessageBox("Script Error:\n" .. tostring(err), "Error", 0)
  end
end

-- Get Track Depth (optimized)
function core.GetTrackDepth(track)
  if not track then return 0 end
  local depth = 0
  local parent = r.GetParentTrack(track)
  while parent do
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
  while parent do
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
  
  -- Iterate ALL tracks in project to find matches at this depth
  local track_count = r.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = r.GetTrack(0, i)
    
    -- Check if this track is visible in arrangement (parent not collapsed)
    if core.IsTrackVisibleInArrangement(track) then
      local depth = core.GetTrackDepth(track)
      
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
  -- Handle unquoted GUIDs just in case
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

return core
