-- @description ajsfx PVX PrepareItem
-- @author ajsfx
-- @version 0.2
-- @about Prepares any selected item for PVX processing:
--        MIDI/empty → renders to audio first (action 41999), then adds PVX Host.
--        Existing audio take → adds PVX Host directly (no re-render needed).
--        Also creates and shows the Pitch and Stretch envelope lanes automatically.
-- @provides
--   [main] .

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path
local core = require("lib.ajsfx_core")
local pvx  = require("lib.ajsfx_pvx")

-- -----------------------------------------------------------------------
-- Show pitch + stretch envelope lanes for the PVX Host on a take
-- -----------------------------------------------------------------------

local function ShowPVXEnvelopes(take, host_fx_idx)
  -- Param 0 = Pitch, Param 1 = Stretch
  for param = 0, 1 do
    local env = r.TakeFX_GetEnvelope(take, host_fx_idx, param, true)
    if env then
      -- Setting ACTIVE = "1" is the programmatic equivalent of
      -- right-click slider → "Show take envelope" in the arrange view.
      r.GetSetEnvelopeInfo_String(env, "ACTIVE", "1", true)
    end
  end
  r.UpdateArrange()
end

-- -----------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------

local function ValidateSelection()
  local count = r.CountSelectedMediaItems(0)
  if count == 0 then
    core.Error("No item selected.\nSelect an audio, MIDI, or empty item.")
    return nil
  end
  if count > 1 then
    core.Error("Multiple items selected.\nSelect exactly one item.")
    return nil
  end

  local item = r.GetSelectedMediaItem(0, 0)
  local take = r.GetActiveTake(item)

  local is_midi  = take and r.TakeIsMIDI(take)
  local is_empty = not take
  local is_audio = take and not r.TakeIsMIDI(take)

  if is_audio then
    -- Audio take: check whether PVX Host is already there
    local host_fx = pvx.FindHostFX(take)
    if host_fx then
      -- Already prepared — just re-show the envelopes
      return item, false, true  -- (item, needs_render, already_has_host)
    else
      -- Audio take without host → add it directly, no re-render needed
      return item, false, false
    end
  end

  -- MIDI or empty → needs action 41999 to produce audio first
  return item, true, false  -- (item, needs_render, already_has_host)
end

-- -----------------------------------------------------------------------
-- Main
-- -----------------------------------------------------------------------

local item, needs_render, already_has_host = ValidateSelection()
if not item then return end

local take

if needs_render then
  -- MIDI / empty: render to audio take first
  r.Main_OnCommand(41999, 0)
  take = r.GetActiveTake(item)
  if not take or r.TakeIsMIDI(take) then
    core.Error("Could not find a new audio take after rendering.\n" ..
               "Make sure the track has a valid input or MIDI content.")
    return
  end
else
  take = r.GetActiveTake(item)
end

-- Add PVX Host if not already present
local host_fx_idx = pvx.FindHostFX(take)

if already_has_host then
  -- Just re-show the envelopes
  ShowPVXEnvelopes(take, host_fx_idx)
  r.ShowConsoleMsg("ajsfx PVX PrepareItem: PVX Host already present — envelope lanes refreshed.\n")
  return
end

if not host_fx_idx then
  -- "JS: " prefix is required by TakeFX_AddByName to match JSFX files by type+name
  local added_idx = r.TakeFX_AddByName(take, "JS: ajsfx PVX Host", 0, -1)
  if added_idx < 0 then
    core.Error("Could not add 'ajsfx PVX Host' to the take FX chain.\n" ..
               "Make sure the JSFX is installed in your REAPER Effects folder.\n" ..
               "Expected name: 'ajsfx PVX Host' (from ajsfx_PVXHost.jsfx).")
    return
  end
  host_fx_idx = added_idx
end

-- Show pitch + stretch envelope lanes
ShowPVXEnvelopes(take, host_fx_idx)

r.UpdateItemInProject(item)

r.ShowConsoleMsg("ajsfx PVX PrepareItem: ready.\n" ..
  "Pitch and Stretch envelope lanes are now visible.\n" ..
  "Draw curves, then run 'ajsfx PVX Render'.\n")
