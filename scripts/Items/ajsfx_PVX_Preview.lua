-- @description ajsfx PVX Preview
-- @author ajsfx
-- @version 0.1
-- @about Previews the pvx-processed output for the selected audio item without
--        mutating the project. Uses a time selection if present, otherwise previews
--        N seconds around the edit cursor. Requires SWS extension for playback.
-- @provides
--   [main] .
--   [nomain] ../lib/ajsfx_core.lua
--   [nomain] ../lib/ajsfx_pvx.lua
--   [nomain] ../FX/ajsfx_PVXHost.jsfx

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path
local core = require("lib.ajsfx_core")
local pvx  = require("lib.ajsfx_pvx")

local SAMPLE_RATE_HZ = 50
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
-- Helpers shared with Render (inlined to keep scripts self-contained)
-- -----------------------------------------------------------------------

local function EnsureDir(path)
  local os_name = r.GetOS()
  if os_name:find("Win") then
    os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>NUL')
  else
    os.execute("mkdir -p '" .. path .. "'")
  end
end

local function DeleteTake(item, take)
  local n = r.GetMediaItemNumTakes(item)
  for i = 0, n - 1 do
    if r.GetMediaItemTake(item, i) == take then
      r.SelectAllMediaItems(0, false)
      r.SetMediaItemSelected(item, true)
      r.SetActiveTake(take)
      r.Main_OnCommand(40129, 0) -- Item: Delete active take
      return
    end
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

local function BakePreviewWindow(item, take, host_fx, t_local_start, t_local_end)
  -- Temporarily trim item to the window using time selection + split/render approach
  -- Simpler: restrict envelope sampling to [t_local_start, t_local_end] and
  -- let pvx receive a pre-trimmed WAV. We produce the trimmed WAV by:
  --   1. Setting time selection to the window
  --   2. Using action 41999 which respects time selection when items overlap it
  -- NOTE: 41999 renders the full item; we trim post-pvx by passing time offsets
  -- to pvx. For the pre-bake we produce the full item WAV and let pvx trim via
  -- --start / --end flags.  This avoids project mutation (no split needed).

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
local scratch = pvx.ResolveScratchDir(config)
EnsureDir(scratch)

local t_start, t_end, item_pos = GetPreviewWindow(item, config)
if not t_start then return end

local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")

-- Stage 1: bake
local wav1, bake_take, err1 = BakePreviewWindow(item, take, host_fx, t_start, t_end)
if not wav1 then
  core.Error("Preview failed (Stage 1):\n" .. (err1 or "unknown error"))
  return
end
if bake_take then
  DeleteTake(item, bake_take)
end

-- Sample envelopes for the full item (pvx will use --start/--end to trim)
-- TakeFX_GetParam returns (value, minval, maxval) — capture only the first.
local pitch_samples = pvx.SampleEnvelope(take, host_fx, 0, item_pos, item_len, SAMPLE_RATE_HZ)
local pitch_val     = r.TakeFX_GetParam(take, host_fx, 0)
local has_pitch_env = pitch_samples ~= nil
if not pitch_samples then
  pitch_samples = { {0.0, pitch_val}, {item_len, pitch_val} }
end

local stretch_samples = pvx.SampleEnvelope(take, host_fx, 1, item_pos, item_len, SAMPLE_RATE_HZ)
local stretch_val     = r.TakeFX_GetParam(take, host_fx, 1)
local has_stretch_env = stretch_samples ~= nil
if not stretch_samples then
  stretch_samples = { {0.0, stretch_val}, {item_len, stretch_val} }
end

local interp_val  = r.TakeFX_GetParam(take, host_fx, 2)
local phase_val   = r.TakeFX_GetParam(take, host_fx, 3)
local trans_val   = r.TakeFX_GetParam(take, host_fx, 4)

-- Write CSVs
local pitch_csv   = nil
local stretch_csv = nil

if pvx.ShouldEmitCurve(has_pitch_env, pitch_val, 0.0) then
  pitch_csv = scratch .. "/preview_pitch.csv"
  local f = io.open(pitch_csv, "w")
  if f then
    f:write(pvx.FormatCSV(pitch_samples, SAMPLE_RATE_HZ))
    f:close()
  end
end

if pvx.ShouldEmitCurve(has_stretch_env, stretch_val, 0.0) then
  stretch_csv = scratch .. "/preview_stretch.csv"
  local linear_samples = {}
  for _, pair in ipairs(stretch_samples) do
    linear_samples[#linear_samples + 1] = { pair[1], pvx.Log2StretchToFactor(pair[2]) }
  end
  local f = io.open(stretch_csv, "w")
  if f then
    f:write(pvx.FormatCSV(linear_samples, SAMPLE_RATE_HZ))
    f:close()
  end
end

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
argv[1] = config.pvx_binary or "pvx"

-- Append --start / --end to restrict pvx output to the preview window
-- (pvx is expected to support these flags for time-range output)
argv[#argv + 1] = "--start"
argv[#argv + 1] = string.format("%.6f", t_start)
argv[#argv + 1] = "--end"
argv[#argv + 1] = string.format("%.6f", t_end)

pvx.RunPVXAsync(
  argv, scratch,
  function(exit_code, log_txt, _)
    if exit_code ~= 0 then
      core.Error(string.format("pvx exited with code %d.\n\nLog:\n%s",
        exit_code, log_txt or ""))
      return
    end

    -- Play via SWS preview bus (no project mutation)
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
