-- @description Uncollapse Visible Children At Lowest Selected Level
-- @author ajsfx
-- @version 2.1
-- @about Uncollapses all folder tracks at the same depth as the shallowest selected track.
-- @provides
--   [main] .

local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path

local core = require("lib.ajsfx_core")

core.Transaction("Uncollapse Low Level Folders", function()
  core.AdjustFolderStateDynamic("shallowest", 0)
end)
