-- @description ajsfx PVX Preview
-- @author ajsfx
-- @version 0.3
-- @about Previews the pvx-processed output for the selected audio item without
--        mutating the project. Currently processes the full item; playback seeks
--        to the edit cursor (or time-selection start) so you hear the window of
--        interest. Requires SWS extension for playback.
-- @provides
--   [main] .
--   lib/ajsfx_pvx.lua
--   ../lib/ajsfx_core.lua > lib/ajsfx_core.lua

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path
local core = require("lib.ajsfx_core")
local pvx  = require("lib.ajsfx_pvx")

local MAX_PREVIEW_SECS = 10.0

-- Track the current preview source so re-invoke stops previous playback
local _current_preview = nil

-- -----------------------------------------------------------------------
-- SWS check
-- -----------------------------------------------------------------------

local function CheckSWS()
  if not r.CF_Preview_PlayEx then
    core.Error("Preview requires the SWS extension.\n" ..
               "Download at: https://www.sws-extension.org/")
    return false
  end
  return true
end

-- -----------------------------------------------------------------------
-- Stop any running preview
-- -----------------------------------------------------------------------

local function StopPreview()
  if _current_preview then
    r.CF_Preview_StopAll()
    _current_preview = nil
  end
end

-- -----------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------

local function ValidateSelection()
  local count = r.CountSelectedMediaItems(0)
  if count == 0 then
    core.Error("No item selected.\nSelect a single audio item.")
    return nil
  end
  if count > 1 then
    core.Error("Multiple items selected.\nSelect exactly one audio item.")
    return nil
  end

  local item = r.GetSelectedMediaItem(0, 0)
  local take = r.GetActiveTake(item)

  if not take or r.TakeIsMIDI(take) then
    core.Error("Active take is MIDI or empty.\nRun 'ajsfx PVX PrepareItem' first.")
    return nil
  end

  local host_fx = pvx.FindHostFX(take)
  if not host_fx then
    core.Error("'ajsfx PVX Host' not found on the active take's FX chain.")
    return nil
  end

  return item, take, host_fx
end

-- -----------------------------------------------------------------------
-- Determine preview window [t_start, t_end] in item-local seconds
-- -----------------------------------------------------------------------

local function GetPreviewWindow(item, config)
  local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local item_end = item_pos + item_len

  local sel_start, sel_end = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local has_sel = (sel_end - sel_start) > 0.001

  local t_proj_start, t_proj_end

  if has_sel then
    -- Clamp time selection to item bounds
    t_proj_start = math.max(sel_start, item_pos)
    t_proj_end   = math.min(sel_end,   item_end)
  else
    local cursor = r.GetCursorPosition()
    local half   = math.min(config.preview_secs or 2.0, MAX_PREVIEW_SECS / 2)
    t_proj_start = math.max(cursor - half, item_pos)
    t_proj_end   = math.min(cursor + half, item_end)
  end

  if t_proj_end - t_proj_start < 0.01 then
    core.Error("Preview window is too short (< 10ms). Move cursor inside the item.")
    return nil
  end

  -- Convert to item-local
  local t_local_start = t_proj_start - item_pos
  local t_local_end   = t_proj_end   - item_pos
  return t_local_start, t_local_end, item_pos
end

-- -----------------------------------------------------------------------
-- Stage 1: bake preview window (pre-PVX FX only)
-- -----------------------------------------------------------------------

local function BakePreviewWindow(item, take, host_fx)
  -- Action 41999 renders the full item; pvx processes the full baked audio,
  -- and we seek to the preview window at playback time. Input-range trimming
  -- (to avoid processing audio the user will never hear) is a future optimization.
  local fx_count = r.TakeFX_GetCount(take)
  local bypass_indices = {}
  for i = host_fx, fx_count - 1 do
    bypass_indices[#bypass_indices + 1] = i
  end

  local wav1, new_take = pvx.BakeTakeViaAction41999(item, bypass_indices)
  if not wav1 or wav1 == "" then
    return nil, nil, "Preview Stage 1: bake produced no output"
  end

  return wav1, new_take, nil
end

-- -----------------------------------------------------------------------
-- Main entry point
-- -----------------------------------------------------------------------

if not CheckSWS() then return end

local item, take, host_fx = ValidateSelection()
if not item then return end

StopPreview()

local config  = pvx.LoadConfig()
local rate_hz = config.envelope_rate_hz

if not pvx.IsPVXReady(config) then
  local ok = r.ShowMessageBox(
    "pvx is not installed.\n\n" ..
    "Install it now? This will open an installer window and requires an internet connection.\n\n" ..
    "After installation completes, re-run this preview script.",
    "pvx required", 1)
  if ok == 1 then
    pvx.RunInstallAsync(
      function(_)
        r.MB("pvx installed!\n\nRe-run ajsfx PVX Preview to audition your item.",
             "pvx installed", 0)
      end,
      function(err) core.Error("pvx installation failed:\n" .. err) end
    )
  end
  return
end

local scratch = pvx.ResolveScratchDir(config)
pvx.EnsureDir(scratch)

local t_start, _, item_pos = GetPreviewWindow(item, config)
if not t_start then return end

local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")

-- Stage 1: bake
local wav1, bake_take, err1 = BakePreviewWindow(item, take, host_fx)
if not wav1 then
  core.Error("Preview failed (Stage 1):\n" .. (err1 or "unknown error"))
  return
end
if bake_take then
  pvx.DeleteTake(item, bake_take)
end

local pitch_csv, pitch_err = pvx.SampleAndEmitCurve(
  take, host_fx, 0, item_pos, item_len, rate_hz,
  scratch, "preview_pitch.csv", 0.0, nil)
if pitch_err then core.Error(pitch_err); return end

local stretch_csv, stretch_err = pvx.SampleAndEmitCurve(
  take, host_fx, 1, item_pos, item_len, rate_hz,
  scratch, "preview_stretch.csv", 0.0, pvx.Log2StretchToFactor)
if stretch_err then core.Error(stretch_err); return end

-- Static params from sliders 3-5 (TakeFX_GetParam returns value, min, max)
local interp_val = r.TakeFX_GetParam(take, host_fx, 2)
local phase_val  = r.TakeFX_GetParam(take, host_fx, 3)
local trans_val  = r.TakeFX_GetParam(take, host_fx, 4)

local wav2 = scratch .. "/preview_pvx_out.wav"

local argv = pvx.BuildArgv({
  input          = wav1,
  output         = wav2,
  interp         = math.floor(interp_val  + 0.5),
  phase_lock     = math.floor(phase_val   + 0.5),
  preserve_trans = math.floor(trans_val   + 0.5),
  pitch_csv      = pitch_csv,
  stretch_csv    = stretch_csv,
})

local bin = pvx.GetPVXBinary(config)
if not bin then
  core.Error("pvx binary not found (ajsfx_pvx.GetPVXBinary returned nil).")
  return
end
argv[1] = bin

pvx.RunPVXAsync(
  argv, scratch,
  function(exit_code, log_txt, _)
    if exit_code ~= 0 then
      core.Error(string.format("pvx exited with code %d.\n\nLog:\n%s",
        exit_code, log_txt or ""))
      return
    end

    -- Play via SWS preview bus (no project mutation). Seek to t_start so the
    -- user hears the requested window first.
    local src = r.PCM_Source_CreateFromFile(wav2)
    if not src then
      core.Error("Could not load pvx preview output: " .. wav2)
      return
    end

    local preview = r.CF_Preview_Create(src)
    if not preview then
      core.Error("CF_Preview_Create failed — SWS required for Preview.")
      return
    end

    _current_preview = preview
    r.CF_Preview_SetValue(preview, "D_VOLUME", 1.0)
    r.CF_Preview_SetValue(preview, "D_POSITION", t_start)
    r.CF_Preview_PlayEx(preview, 0)  -- 0 = play on preview bus
  end,
  function()
    core.Print("ajsfx PVX Preview: cancelled.")
  end,
  function(err)
    core.Error("pvx spawn error: " .. err)
  end,
  config.poll_rate,
  config.timeout_s
)
