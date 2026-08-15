-- @noindex
-- Provided by the ajsfx VO package; see ajsfx_VO_Overview.lua's @provides.
--
-- ajsfx VO Sources — a thin window around lib/ajsfx_vo_sources_ui.lua,
-- which owns every row, button and panel this window shows. The UI moved
-- to a module (redesign spec, phase 2) so the same surface can draw here
-- and inside the Overview's Sources stage; this file only opens the
-- window and pumps the frame.

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path

local success, im = pcall(function()
  package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
  return require('imgui')('0.9.3')
end)
if not success then
  r.MB("This script requires the 'imgui' library.\n\n" ..
       "Install ReaImGui: ReaScript binding for Dear ImGui via ReaPack.",
       "Library not found", 0)
  return
end

local sources_ui = require("lib.ajsfx_vo_sources_ui")
sources_ui.attach(im)

local ctx = im.CreateContext('VO Sources')

local function loop()
  sources_ui.Tick()

  im.SetNextWindowSize(ctx, 900, 560, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'ajsfx VO Sources', true)

  if visible then
    sources_ui.Draw(ctx)
    im.End(ctx)
    sources_ui.RunPending()
  end

  if open then
    r.defer(loop)
  end
end

r.defer(loop)
