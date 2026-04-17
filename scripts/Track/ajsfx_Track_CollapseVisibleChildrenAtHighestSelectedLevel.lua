-- @description Collapse Visible Children At Highest Selected Level
-- @author ajsfx
-- @version 2.1
-- @about Collapses all folder tracks at the same depth as the deepest selected track.
-- @provides
--   [main] .

local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path

local core = require("lib.ajsfx_core")

core.Transaction("Collapse High Level Folders", function()
  core.AdjustFolderStateDynamic("deepest", 2)
end)
