-- @description Uncollapse Visible Children At Lowest Selected Level
-- @author ajsfx
-- @version 2.0
-- @about Uncollapses all folder tracks at the same depth as the shallowest selected track.

local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. package.path

local core = require("lib.ajsfx_core")

core.Transaction("Uncollapse Low Level Folders", function()
  core.AdjustFolderStateDynamic("shallowest", 0)
end)
