-- @description ajsfx PVX Render
-- @author ajsfx
-- @version 0.3
-- @about Applies time-varying pitch/stretch to the selected audio item via pvx.
--        Renders a new take on the source item. Requires ajsfx PVX Host on the take FX chain.
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

-- -----------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------

-- Collect all take names on an item
local function CollectTakeNames(item)
  local names = {}
  local n = r.GetMediaItemNumTakes(item)
  for i = 0, n - 1 do
    local take = r.GetMediaItemTake(item, i)
    if take then
      local _, name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      names[#names + 1] = name
    end
  end
  return names
end

-- -----------------------------------------------------------------------
-- Validation
-- -----------------------------------------------------------------------

local function ValidateSelection()
  local count = r.CountSelectedMediaItems(0)
  if count == 0 then
    core.Error("No item selected.\nSelect a single audio item and try again.")
    return nil
  end
  if count > 1 then
    core.Error("Multiple items selected.\nSelect exactly one audio item.")
    return nil
  end

  local item = r.GetSelectedMediaItem(0, 0)
  local take = r.GetActiveTake(item)

  if not take then
    core.Error("Selected item has no active take.")
    return nil
  end

  if r.TakeIsMIDI(take) then
    core.Error("Selected take is MIDI.\nRun 'ajsfx PVX PrepareItem' first to render to audio.")
    return nil
  end

  local host_fx = pvx.FindHostFX(take)
  if not host_fx then
    core.Error("'ajsfx PVX Host' not found on the active take's FX chain.\n" ..
               "Add it via Take FX chain, or use 'ajsfx PVX PrepareItem'.")
    return nil
  end

  return item, take, host_fx
end

-- -----------------------------------------------------------------------
-- Stage 1: Pre-PVX bake
-- -----------------------------------------------------------------------

-- Returns: wav1_path (string), cleanup_take (take handle to delete), or nil on error
local function Stage1_PreBake(item, take, host_fx)
  local fx_count = r.TakeFX_GetCount(take)

  -- Collect indices of PVX Host + every FX at or after it
  local bypass_indices = {}
  for i = host_fx, fx_count - 1 do
    bypass_indices[#bypass_indices + 1] = i
  end

  local wav1, new_take = pvx.BakeTakeViaAction41999(item, bypass_indices)
  if not wav1 or wav1 == "" then
    return nil, nil, "Stage 1: action 41999 produced no output"
  end

  return wav1, new_take, nil
end

-- -----------------------------------------------------------------------
-- Stage 2: Build pvx argv + CSV files, spawn async
-- -----------------------------------------------------------------------

-- Returns: false + err_msg on failure, or true and kicks off async
local function Stage2_RunPVX(item, take, host_fx, wav1, scratch_dir, config, on_done, on_cancel)
  local item_pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local item_len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local rate_hz  = config.envelope_rate_hz

  local pitch_csv, err1 = pvx.SampleAndEmitCurve(
    take, host_fx, 0, item_pos, item_len, rate_hz,
    scratch_dir, "pitch.csv", 0.0, nil)
  if err1 then return false, err1 end

  local stretch_csv, err2 = pvx.SampleAndEmitCurve(
    take, host_fx, 1, item_pos, item_len, rate_hz,
    scratch_dir, "stretch.csv", 0.0, pvx.Log2StretchToFactor)
  if err2 then return false, err2 end

  -- Static params from sliders 3-5 (TakeFX_GetParam returns value, min, max)
  local interp_val = r.TakeFX_GetParam(take, host_fx, 2)
  local phase_val  = r.TakeFX_GetParam(take, host_fx, 3)
  local trans_val  = r.TakeFX_GetParam(take, host_fx, 4)

  local wav2 = scratch_dir .. "/pvx_out.wav"

  local argv = pvx.BuildArgv({
    input         = wav1,
    output        = wav2,
    interp        = math.floor(interp_val + 0.5),
    phase_lock    = math.floor(phase_val  + 0.5),
    preserve_trans= math.floor(trans_val  + 0.5),
    pitch_csv     = pitch_csv,
    stretch_csv   = stretch_csv,
  })

  -- Resolve the pvx binary via the single-source-of-truth helper; IsPVXReady
  -- was checked by caller, so GetPVXBinary should always return a valid path.
  local bin = pvx.GetPVXBinary(config)
  if not bin then
    return false, "pvx binary not found (ajsfx_pvx.GetPVXBinary returned nil)"
  end
  argv[1] = bin

  pvx.RunPVXAsync(
    argv, scratch_dir,
    function(exit_code, log_txt)
      on_done(exit_code, log_txt, wav2)
    end,
    on_cancel,
    function(err)
      core.Error("pvx spawn error: " .. err)
    end,
    config.poll_rate,
    config.timeout_s
  )

  return true, nil
end

-- -----------------------------------------------------------------------
-- Stage 3 + Import
-- -----------------------------------------------------------------------

local function Stage3_AndImport(item, take, host_fx, wav2)
  -- Post-PVX Take FX bake is not implemented. If any FX sit after the Host,
  -- abort before mutating the project so the user knows to move them.
  local fx_count      = r.TakeFX_GetCount(take)
  local post_fx_count = fx_count - host_fx - 1
  if post_fx_count > 0 then
    core.Error(("Post-PVX Take FX detected (%d FX after PVX Host).\n\n" ..
      "Post-chain bake is not implemented. Move those FX to a track " ..
      "(or remove them) and re-run Render."):format(post_fx_count))
    return
  end

  -- Import wav2 as a new take
  local take_names = CollectTakeNames(item)
  local new_name   = pvx.BumpTakeVersion(take_names, "pvx_v")

  core.Transaction("ajsfx PVX Render: " .. new_name, function()
    local new_take = r.AddTakeToMediaItem(item)
    if not new_take then error("Failed to add take to item") end

    local source = r.PCM_Source_CreateFromFile(wav2)
    if not source then error("Failed to load rendered file: " .. wav2) end

    r.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", new_name, true)
    r.SetMediaItemTake_Source(new_take, source)
    r.SetActiveTake(new_take)

    r.UpdateItemInProject(item)
  end)
end

-- -----------------------------------------------------------------------
-- Main entry point
-- -----------------------------------------------------------------------

local item, take, host_fx = ValidateSelection()
if not item then return end

local config = pvx.LoadConfig()

if not pvx.IsPVXReady(config) then
  local ok = r.ShowMessageBox(
    "pvx is not installed.\n\n" ..
    "Install it now? This will open an installer window and requires an internet connection.\n\n" ..
    "After installation completes, re-run this render script.",
    "pvx required", 1)
  if ok == 1 then
    pvx.RunInstallAsync(
      function(_)
        r.MB("pvx installed!\n\nRe-run ajsfx PVX Render to process your item.",
             "pvx installed", 0)
      end,
      function(err) core.Error("pvx installation failed:\n" .. err) end
    )
  end
  return
end

local scratch = pvx.ResolveScratchDir(config)
pvx.EnsureDir(scratch)

-- Stage 1
local wav1, bake_take, err1 = Stage1_PreBake(item, take, host_fx)
if not wav1 then
  core.Error("Render failed (Stage 1):\n" .. (err1 or "unknown error"))
  return
end

-- Remove the scratch take that 41999 adds to the item (keep only the file)
if bake_take then
  pvx.DeleteTake(item, bake_take)
end

-- Stage 2 (async) → on completion → Stage 3 + import
local ok2, err2 = Stage2_RunPVX(item, take, host_fx, wav1, scratch, config,
  function(exit_code, log_txt, wav2)
    -- Runs in a deferred context when pvx finishes
    if exit_code ~= 0 then
      core.Error(string.format(
        "pvx exited with code %d.\n\nLog:\n%s", exit_code, log_txt or ""))
      return
    end
    Stage3_AndImport(item, take, host_fx, wav2)
  end,
  function()
    -- User cancelled or timed out — leave scratch dir for debugging
    core.Print("ajsfx PVX Render: cancelled.")
  end
)

if not ok2 then
  core.Error("Render failed (Stage 2 setup):\n" .. (err2 or "unknown error"))
end
