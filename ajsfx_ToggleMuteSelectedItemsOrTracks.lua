-- @description Smart Toggle Mute (Razor > Items > Tracks)
-- @author ajsfx
-- @version 2.0
-- @about Toggles mute intelligently. Priority: 1. Razor Edits (mutes items in area), 2. Selected Items, 3. Selected Tracks.

local r = reaper
-- Ensure correct package path
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. package.path

local core = require("lib.ajsfx_core")

core.Transaction("Smart Toggle Mute", function()
  
  -- Priority 1: Razor Edits
  local razor_items = {}
  local track_count = r.CountTracks(0)
  for i = 0, track_count - 1 do
    local track = r.GetTrack(0, i)
    local razor_edits = core.GetRazorEdits(track)
    
    for _, edit in ipairs(razor_edits) do
      local item_count = r.CountTrackMediaItems(track)
      for j = 0, item_count - 1 do
        local item = r.GetTrackMediaItem(track, j)
        local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
        local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
        local end_pos = pos + len
        
        -- Check for intersection
        if pos < edit.end_time and end_pos > edit.start_time then
          table.insert(razor_items, item)
        end
      end
    end
  end
  
  if #razor_items > 0 then
    local any_unmuted = false
    for _, item in ipairs(razor_items) do
      if r.GetMediaItemInfo_Value(item, "B_MUTE") == 0 then
        any_unmuted = true
        break
      end
    end
    
    local new_state = any_unmuted and 1 or 0
    for _, item in ipairs(razor_items) do
      r.SetMediaItemInfo_Value(item, "B_MUTE", new_state)
    end
    
    r.UpdateArrange()
    return
  end
  
  -- Priority 2: Selected Items
  local selected_item_count = r.CountSelectedMediaItems(0)
  if selected_item_count > 0 then
    local any_unmuted = false
    for i = 0, selected_item_count - 1 do
      local item = r.GetSelectedMediaItem(0, i)
      if r.GetMediaItemInfo_Value(item, "B_MUTE") == 0 then
        any_unmuted = true
        break
      end
    end
    
    local new_state = any_unmuted and 1 or 0
    for i = 0, selected_item_count - 1 do
      local item = r.GetSelectedMediaItem(0, i)
      r.SetMediaItemInfo_Value(item, "B_MUTE", new_state)
    end
    
    r.UpdateArrange()
    return
  end
  
  -- Priority 3: Selected Tracks
  local selected_track_count = r.CountSelectedTracks(0)
  if selected_track_count > 0 then
    local any_unmuted = false
    for i = 0, selected_track_count - 1 do
      local track = r.GetSelectedTrack(0, i)
      if r.GetMediaTrackInfo_Value(track, "B_MUTE") == 0 then
        any_unmuted = true
        break
      end
    end
    
    local new_state = any_unmuted and 1 or 0
    for i = 0, selected_track_count - 1 do
      local track = r.GetSelectedTrack(0, i)
      r.SetMediaTrackInfo_Value(track, "B_MUTE", new_state)
    end
    
    r.UpdateArrange()
    return
  end

end)
