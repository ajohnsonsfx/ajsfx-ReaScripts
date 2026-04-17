-- @description Set All Selected Items Length To First Selected Item
-- @author ajsfx
-- @version 1.1
-- @about Sets the length of all selected media items to match the length of the first selected item.
-- @provides
--   [main] .

local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path

local core = require("lib.ajsfx_core")

core.Transaction("Match Item Lengths", function()
  local item_count = r.CountSelectedMediaItems(0)
  if item_count < 2 then
    r.ShowConsoleMsg("ajsfx: Need at least 2 selected items to match lengths.\n")
    return
  end
  
  -- Get source length from first item
  local source_item = r.GetSelectedMediaItem(0, 0)
  local target_len = r.GetMediaItemInfo_Value(source_item, "D_LENGTH")
  
  -- Apply to subsequent items
  for i = 1, item_count - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    r.SetMediaItemInfo_Value(item, "D_LENGTH", target_len)
  end
  
  r.UpdateArrange()
end)
