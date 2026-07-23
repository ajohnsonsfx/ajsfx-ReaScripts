-- @description Move cursor to right edge of last unmuted item on track
-- @author ajsfx
-- @version 1.0
-- @changelog Initial release
-- @about Moves the cursor to the right edge of the last unmuted item on selected tracks. Does nothing if no track is selected.
-- @provides
--   [main] .

local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path

local core = require("lib.ajsfx_core")

core.Transaction("Move cursor to right edge of last unmuted item on track", function()
  local tracks = core.GetSelectedTracksList()
  if #tracks == 0 then return end
  local pos = core.GetLastItemEnd(tracks, true)
  if not pos then return end
  r.SetEditCurPos(pos, true, false)
end)
