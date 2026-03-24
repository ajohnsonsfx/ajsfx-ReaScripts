-- @description Uncollapse Visible Children At Highest Selected Level
-- @author ajsfx
-- @version 2.0
-- @about Uncollapses all folder tracks at the same depth as the deepest selected track.
-- @provides
--   [nomain] lib/ajsfx_core.lua

local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. package.path

local core = require("lib.ajsfx_core")

core.Transaction("Uncollapse High Level Folders", function()
  core.AdjustFolderStateDynamic("deepest", 0)
end)
