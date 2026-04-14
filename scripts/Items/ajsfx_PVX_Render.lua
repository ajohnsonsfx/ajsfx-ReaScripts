-- @description ajsfx PVX Render
-- @author ajsfx
-- @version 0.1
-- @about Applies time-varying pitch/stretch to the selected audio item via pvx.
--        Renders a new take on the source item. Requires ajsfx PVX Host on the take FX chain.
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

local SAMPLE_RATE_HZ = 50  -- envelope samples per second

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

-- Ensure scratch dir exists (mkdir -p equivalent)
local function EnsureDir(path)
  local os_name = r.GetOS()
  if os_name:find("Win") then
    os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>NUL')
  else
    os.execute("mkdir -p '" .. path .. "'")
  end
end

-- Delete a take from an item by take handle (does not touch the source file)
local function DeleteTake(item, take)
  -- REAPER 6.44+ has GetSetMediaItemTakeInfo with delete semantics,
  -- but the cross-version approach is to remove via SWS or direct
  -- MediaItem_SelectTake + action. Use the built-in:
  local n = r.GetMediaItemNumTakes(item)
  for i = 0, n - 1 do
    if r.GetMediaItemTake(item, i) == take then
      r.SelectAllMediaItems(0, false)
      r.SetMediaItemSelected(item, true)
      r.SetActiveTake(take)
      r.Main_OnCommand(40129, 0) -- Item: Delete active take from items
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

  -- Sample pitch envelope (param 0)
  -- TakeFX_GetParam returns (value, minval, maxval) — capture only the first.
  local pitch_samples = pvx.SampleEnvelope(take, host_fx, 0, item_pos, item_len, SAMPLE_RATE_HZ)
  local pitch_val     = r.TakeFX_GetParam(take, host_fx, 0)
  local has_pitch_env = pitch_samples ~= nil
  -- If no envelope, build a flat 2-point array at the slider value
  if not pitch_samples then
    pitch_samples = { {0.0, pitch_val}, {item_len, pitch_val} }
  end

  -- Sample stretch envelope (param 1)
  local stretch_samples = pvx.SampleEnvelope(take, host_fx, 1, item_pos, item_len, SAMPLE_RATE_HZ)
  local stretch_val     = r.TakeFX_GetParam(take, host_fx, 1)
  local has_stretch_env = stretch_samples ~= nil
  if not stretch_samples then
    stretch_samples = { {0.0, stretch_val}, {item_len, stretch_val} }
  end

  -- Get static params from sliders 3-5
  local interp_val  = r.TakeFX_GetParam(take, host_fx, 2)
  local phase_val   = r.TakeFX_GetParam(take, host_fx, 3)
  local trans_val   = r.TakeFX_GetParam(take, host_fx, 4)

  -- Write CSV files if needed
  local pitch_csv   = nil
  local stretch_csv = nil

  if pvx.ShouldEmitCurve(has_pitch_env, pitch_val, 0.0) then
    pitch_csv = scratch_dir .. "/pitch.csv"
    local f = io.open(pitch_csv, "w")
    if not f then return false, "Cannot write pitch.csv to: " .. pitch_csv end
    f:write(pvx.FormatCSV(pitch_samples, SAMPLE_RATE_HZ))
    f:close()
  end

  if pvx.ShouldEmitCurve(has_stretch_env, stretch_val, 0.0) then
    stretch_csv = scratch_dir .. "/stretch.csv"
    -- Convert log2 stretch values to linear factors before writing
    local linear_samples = {}
    for _, pair in ipairs(stretch_samples) do
      linear_samples[#linear_samples + 1] = { pair[1], pvx.Log2StretchToFactor(pair[2]) }
    end
    local f = io.open(stretch_csv, "w")
    if not f then return false, "Cannot write stretch.csv to: " .. stretch_csv end
    f:write(pvx.FormatCSV(linear_samples, SAMPLE_RATE_HZ))
    f:close()
  end

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

  -- Replace the first "pvx" token with the configured binary path
  argv[1] = config.pvx_binary or "pvx"

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

local function Stage3_AndImport(item, take, host_fx, wav2, scratch_dir)
  -- Check for post-PVX FX (any FX after PVX Host)
  local fx_count = r.TakeFX_GetCount(take)
  local post_fx_count = fx_count - host_fx - 1

  local final_wav = wav2

  if post_fx_count > 0 then
    -- Import wav2 as a temp take, bake post-chain via 41999, then remove temp take
    local temp_track_added = false
    local temp_item = nil

    -- We need a scratch track to host the temp item with the post-FX chain
    -- Strategy: insert a hidden track, add the item there, copy post-FX, bake, clean up
    -- For v1 simplicity: if post-PVX FX exist, warn and skip post-bake
    -- (full post-bake via hidden track is complex; flag for v1.1)
    core.Print("Warning: Post-PVX Take FX detected (" .. post_fx_count ..
      " FX after PVX Host). Post-chain bake is not yet implemented. " ..
      "The import will use the raw pvx output. Move post-chain FX to a track for now.")
    -- final_wav stays as wav2
  end

  -- Import final_wav as a new take
  local take_names = CollectTakeNames(item)
  local new_name   = pvx.BumpTakeVersion(take_names, "pvx_v")

  core.Transaction("ajsfx PVX Render: " .. new_name, function()
    -- Insert new source file as a take on the item
    -- REAPER API: AddMediaItemTake then set source
    local new_take = r.AddTakeToMediaItem(item)
    if not new_take then error("Failed to add take to item") end

    local source = r.PCM_Source_CreateFromFile(final_wav)
    if not source then error("Failed to load rendered file: " .. final_wav) end

    r.GetSetMediaItemTakeInfo_String(new_take, "P_NAME", new_name, true)
    r.SetMediaItemTake_Source(new_take, source)
    r.SetActiveTake(new_take)

    -- Clear FX chain on the new take (it inherits none, but be explicit)
    r.TakeFX_SetEnabled(new_take, 0, false) -- no-op if no FX, harmless

    r.UpdateItemInProject(item)
  end)
end

-- -----------------------------------------------------------------------
-- Main entry point
-- -----------------------------------------------------------------------

local item, take, host_fx = ValidateSelection()
if not item then return end

local config     = pvx.LoadConfig()
local scratch    = pvx.ResolveScratchDir(config)
EnsureDir(scratch)

-- Stage 1
local wav1, bake_take, err1 = Stage1_PreBake(item, take, host_fx)
if not wav1 then
  core.Error("Render failed (Stage 1):\n" .. (err1 or "unknown error"))
  return
end

-- Remove the scratch take that 41999 adds to the item (keep only the file)
if bake_take then
  DeleteTake(item, bake_take)
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
    Stage3_AndImport(item, take, host_fx, wav2, scratch)
  end,
  function()
    -- User cancelled or timed out — leave scratch dir for debugging
    core.Print("ajsfx PVX Render: cancelled.")
  end
)

if not ok2 then
  core.Error("Render failed (Stage 2 setup):\n" .. (err2 or "unknown error"))
end
