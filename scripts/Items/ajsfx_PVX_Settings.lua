-- @description ajsfx PVX Settings
-- @author ajsfx
-- @version 0.1
-- @about Settings panel for ajsfx PVX Render/Preview. Configure the pvx binary
--        path, scratch directory, poll rate, preview duration, and render timeout.
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
local pvx_lib = require("lib.ajsfx_pvx")

local success, im = pcall(function()
  package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
  return require('imgui')('0.9.3')
end)

if not success then
  r.MB("This script requires the 'imgui' library (ReaImGui).\n" ..
       "Install it via ReaPack: Extensions → ReaPack → Browse packages → ReaImGui.",
       "ReaImGui not found", 0)
  return
end

-- -----------------------------------------------------------------------
-- State
-- -----------------------------------------------------------------------

local ctx = im.CreateContext('PVX Settings')

local DEFAULT_CONFIG = {
  pvx_binary    = "pvx",
  scratch_dir   = "",
  poll_rate     = 10,
  preview_secs  = 2.0,
  timeout_s     = 300,
  pvx_version   = "",
}

local cfg = pvx_lib.LoadConfig()
-- Ensure all keys present (in case new keys added since last save)
for k, v in pairs(DEFAULT_CONFIG) do
  if cfg[k] == nil then cfg[k] = v end
end

local status_msg = ""

-- -----------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------

local function ClearScratch()
  local scratch = pvx_lib.ResolveScratchDir(cfg)
  if scratch == "" then
    status_msg = "Scratch dir not set."
    return
  end

  local os_name = r.GetOS()
  local removed = 0

  if os_name:find("Win") then
    local path = scratch:gsub("/", "\\")
    -- Remove contents but keep the directory
    local result = os.execute('del /Q /S "' .. path .. '\\*" 2>NUL')
    status_msg = "Scratch cleared (Windows)."
  else
    local result = os.execute("rm -f '" .. scratch .. "'/* 2>/dev/null")
    status_msg = "Scratch cleared."
  end
end

local function CheckPVXVersion()
  local bin = cfg.pvx_binary or "pvx"
  local tmp_out = os.tmpname() .. "_pvx_ver.txt"
  local cmd

  local os_name = r.GetOS()
  if os_name:find("Win") then
    cmd = '"' .. bin:gsub('"', '\\"') .. '" --version > "' ..
      tmp_out:gsub('"', '\\"') .. '" 2>&1'
  else
    cmd = "'" .. bin:gsub("'", "'\\''") .. "' --version > '" ..
      tmp_out:gsub("'", "'\\''") .. "' 2>&1"
  end

  os.execute(cmd)

  local f = io.open(tmp_out, "r")
  if f then
    local line = f:read("*l") or ""
    f:close()
    os.remove(tmp_out)
    cfg.pvx_version = line:match("%S.*") or "unknown"
    status_msg = "pvx version: " .. cfg.pvx_version
  else
    cfg.pvx_version = ""
    status_msg = "Could not run pvx — check binary path."
  end

  pvx_lib.SaveConfig(cfg)
end

-- -----------------------------------------------------------------------
-- Main loop
-- -----------------------------------------------------------------------

local function loop()
  if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
    ctx = im.CreateContext('PVX Settings')
  end

  im.SetNextWindowSize(ctx, 420, 320, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'ajsfx PVX Settings', true)

  if visible then
    -- pvx binary path
    im.Text(ctx, "pvx Binary Path:")
    im.SetNextItemWidth(ctx, -80)
    local rv_bin, new_bin = im.InputText(ctx, "##pvx_binary", cfg.pvx_binary)
    if rv_bin then cfg.pvx_binary = new_bin end
    im.SameLine(ctx)
    if im.Button(ctx, "Check") then
      CheckPVXVersion()
    end

    if cfg.pvx_version ~= "" then
      im.TextDisabled(ctx, "  Version: " .. cfg.pvx_version)
    end

    im.Spacing(ctx)

    -- Scratch directory
    im.Text(ctx, "Scratch Directory (leave blank for project subdir):")
    im.SetNextItemWidth(ctx, -80)
    local rv_scratch, new_scratch = im.InputText(ctx, "##scratch_dir", cfg.scratch_dir)
    if rv_scratch then cfg.scratch_dir = new_scratch end
    im.SameLine(ctx)
    -- Optional: js_ReaScriptAPI browse button
    if r.JS_Dialog_BrowseForFolder then
      if im.Button(ctx, "Browse") then
        local ok, path = r.JS_Dialog_BrowseForFolder("Select scratch directory", "")
        if ok == 1 and path and path ~= "" then
          cfg.scratch_dir = path
        end
      end
    else
      im.BeginDisabled(ctx, true)
      im.Button(ctx, "Browse")
      im.EndDisabled(ctx)
    end

    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)

    -- Poll rate
    local rv_poll, new_poll = im.SliderInt(ctx, "Poll Rate (Hz)", cfg.poll_rate, 1, 60)
    if rv_poll then cfg.poll_rate = new_poll end
    im.TextDisabled(ctx, "  How often to check if pvx has finished (default: 10 Hz)")

    im.Spacing(ctx)

    -- Preview seconds
    local rv_prev, new_prev = im.SliderDouble(ctx, "Preview Secs", cfg.preview_secs,
      0.5, 10.0, "%.1f s")
    if rv_prev then cfg.preview_secs = new_prev end
    im.TextDisabled(ctx, "  Seconds around cursor used when no time selection is set")

    im.Spacing(ctx)

    -- Timeout
    local rv_to, new_to = im.SliderInt(ctx, "Render Timeout (s)", cfg.timeout_s, 10, 3600)
    if rv_to then cfg.timeout_s = new_to end
    im.TextDisabled(ctx, "  Auto-cancel after this many seconds (default: 300)")

    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)

    -- Action buttons
    if im.Button(ctx, "Save") then
      pvx_lib.SaveConfig(cfg)
      status_msg = "Settings saved."
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Reset to Defaults") then
      cfg = {
        pvx_binary    = DEFAULT_CONFIG.pvx_binary,
        scratch_dir   = DEFAULT_CONFIG.scratch_dir,
        poll_rate     = DEFAULT_CONFIG.poll_rate,
        preview_secs  = DEFAULT_CONFIG.preview_secs,
        timeout_s     = DEFAULT_CONFIG.timeout_s,
        pvx_version   = DEFAULT_CONFIG.pvx_version,
      }
      pvx_lib.SaveConfig(cfg)
      status_msg = "Reset to defaults."
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Clear Scratch") then
      ClearScratch()
    end

    if status_msg ~= "" then
      im.Spacing(ctx)
      im.Text(ctx, status_msg)
    end

    im.End(ctx)
  end

  if open then
    r.defer(loop)
  end
end

loop()
