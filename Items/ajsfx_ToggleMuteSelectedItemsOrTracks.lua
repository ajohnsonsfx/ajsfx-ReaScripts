-- @description Smart Toggle Mute (Razor > Items > Tracks)
-- @author ajsfx
-- @version 2.0
-- @about Toggles mute intelligently. Priority: 1. Razor Edits (mutes items in area), 2. Selected Items, 3. Selected Tracks.
-- @provides
--   [nomain] ../lib/ajsfx_core.lua

local r = reaper
-- Ensure correct package path
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path

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
        if core.ItemIntersectsRange(pos, len, edit.start_time, edit.end_time) then
          table.insert(razor_items, item)
        end
      end
    end
  end
  
  if #razor_items > 0 then
    core.ToggleMuteItems(razor_items)
    r.UpdateArrange()
    return
  end

  -- Priority 2: Selected Items
  local selected_item_count = r.CountSelectedMediaItems(0)
  if selected_item_count > 0 then
    local selected_items = {}
    for i = 0, selected_item_count - 1 do
      table.insert(selected_items, r.GetSelectedMediaItem(0, i))
    end
    core.ToggleMuteItems(selected_items)
    r.UpdateArrange()
    return
  end

  -- Priority 3: Selected Tracks
  local selected_track_count = r.CountSelectedTracks(0)
  if selected_track_count > 0 then
    local selected_tracks = {}
    for i = 0, selected_track_count - 1 do
      table.insert(selected_tracks, r.GetSelectedTrack(0, i))
    end
    core.ToggleMuteTracks(selected_tracks)
    r.UpdateArrange()
    return
  end

end)
