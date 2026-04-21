-- @description ajsfx PVX Shared Library
-- @author ajsfx
-- @version 0.2
-- @about Shared helpers for ajsfx PVX Render/Preview scripts.
--        Venv path is now derived from this file's install location
--        (Scripts/<repo>/pvx/lib/) instead of a hardcoded string.

local r = reaper

local pvx = {}

--------------------------------
-- Pure helpers (unit-testable)
--------------------------------

-- Convert log2 stretch slider value to linear time-stretch factor.
-- slider value 0 = 1x (no stretch), +1 = 2x slower, -1 = 0.5x faster.
-- Clamped to [0.125, 8.0] (±3 octaves of stretch).
function pvx.Log2StretchToFactor(v)
  local factor = 2 ^ v
  if factor < 0.125 then return 0.125 end
  if factor > 8.0   then return 8.0   end
  return factor
end

-- Format a samples table as a CSV string for pvx.
-- Includes the required "time,value" header row (pvx uses csv.DictReader).
-- samples: array of {t_seconds, v} pairs
-- Returns: CSV string with header, or "" for empty samples.
function pvx.FormatCSV(samples, rate_hz)
  if #samples == 0 then return "" end
  local lines = { "time,value" }
  for _, pair in ipairs(samples) do
    lines[#lines + 1] = string.format("%.6f,%.6f", pair[1], pair[2])
  end
  return table.concat(lines, "\n")
end

-- Decide whether to emit a curve CSV to pvx.
-- has_envelope: bool — a Take FX envelope exists for this param
-- slider_value: current slider value (number)
-- default_value: the slider's neutral default
function pvx.ShouldEmitCurve(has_envelope, slider_value, default_value)
  if has_envelope then return true end
  -- No envelope but slider is off-default — emit a flat curve
  return math.abs(slider_value - default_value) > 1e-9
end

-- Build the pvx argv table from a config table.
-- CLI: pvx voc <input> [--pitch CSV] [--stretch CSV] [--interp MODE] --output <output>
-- config fields:
--   input         (string)     — path to input WAV
--   output        (string)     — path to output WAV
--   pitch_csv     (string|nil) — path to pitch CSV; omitted if nil
--   stretch_csv   (string|nil) — path to stretch CSV; omitted if nil
--   interp        (number)     — 0=linear, 1=cubic, 2=polynomial
-- Returns: array of strings (argv, NOT pre-joined; argv[1] is "pvx" placeholder)
function pvx.BuildArgv(config)
  local interp_names = { [0]="linear", [1]="cubic", [2]="polynomial" }

  local argv = {
    "pvx",   -- placeholder; caller replaces with real binary path
    "voc",
    config.input,
    "--output", config.output,
    "--interp", interp_names[config.interp] or "linear",
  }

  if config.pitch_csv then
    argv[#argv + 1] = "--pitch"
    argv[#argv + 1] = config.pitch_csv
  end

  if config.stretch_csv then
    argv[#argv + 1] = "--stretch"
    argv[#argv + 1] = config.stretch_csv
  end

  return argv
end

-- Cross-platform shell argument quoting.
-- os_name: "Windows" | "OSX" | "Other"
function pvx.QuoteArg(s, os_name)
  if os_name == "Windows" then
    -- Wrap in double-quotes; escape interior double-quotes with backslash
    s = s:gsub('"', '\\"')
    return '"' .. s .. '"'
  else
    -- POSIX single-quote wrapping; literal single-quotes become '\''
    s = s:gsub("'", "'\\''")
    return "'" .. s .. "'"
  end
end

-- Determine the next take version name given a list of existing take names.
-- E.g. existing = {"dry","pvx_v1","pvx_v2"}, base="pvx_v" -> "pvx_v3"
function pvx.BumpTakeVersion(existing_names, base)
  local max_n = 0
  for _, name in ipairs(existing_names) do
    local n = tonumber(name:match("^" .. base:gsub("%-", "%%-") .. "(%d+)$"))
    if n and n > max_n then max_n = n end
  end
  return base .. tostring(max_n + 1)
end

--------------------------------
-- REAPER-coupled helpers
--------------------------------

-- Find the "ajsfx PVX Host" JSFX on the given take.
-- Returns fx_index (0-based) or nil if not found.
function pvx.FindHostFX(take)
  local fx_count = r.TakeFX_GetCount(take)
  for i = 0, fx_count - 1 do
    local _, name = r.TakeFX_GetFXName(take, i, "")
    if name:find("ajsfx PVX Host", 1, true) then
      return i
    end
  end
  return nil
end

-- Sample a Take FX parameter envelope at uniform intervals over item duration.
-- take:        REAPER take
-- fx_idx:      0-based fx index
-- param_idx:   0-based parameter index (0=Pitch, 1=Stretch)
-- item_pos:    item position in project seconds
-- item_len:    item length in project seconds
-- rate_hz:     samples per second (e.g. 50)
-- Returns: array of {t_seconds_item_local, value} or nil if no envelope
function pvx.SampleEnvelope(take, fx_idx, param_idx, item_pos, item_len, rate_hz)
  local env = r.TakeFX_GetEnvelope(take, fx_idx, param_idx, false)
  if not env then return nil end

  local step   = 1.0 / rate_hz
  local n      = math.max(2, math.floor(item_len * rate_hz) + 1)
  local samples = {}

  for i = 0, n - 1 do
    local t_local  = math.min(i * step, item_len)
    local t_proj   = item_pos + t_local
    local _, value = r.Envelope_Evaluate(env, t_proj, 0, 0)
    samples[#samples + 1] = { t_local, value }
  end

  -- Always include the exact end point
  if samples[#samples][1] < item_len - 1e-9 then
    local _, value = r.Envelope_Evaluate(env, item_pos + item_len, 0, 0)
    samples[#samples + 1] = { item_len, value }
  end

  return samples
end

-- Disable specified FX indices on a take, run action 41999 (Render items to new take),
-- find the newly created take's source file path, then restore FX enabled state.
-- bypass_fx_indices: array of 0-based fx indices to disable during render
-- Returns: wav_path (string) of the new take's source file, or nil on error.
-- NOTE: The caller is responsible for removing the scratch take created by 41999
--       if they only want the file on disk (not the take in the project).
function pvx.BakeTakeViaAction41999(item, bypass_fx_indices)
  local take = r.GetActiveTake(item)
  if not take then return nil end

  -- Snapshot + disable listed FX
  local was_enabled = {}
  for _, idx in ipairs(bypass_fx_indices) do
    was_enabled[idx] = r.TakeFX_GetEnabled(take, idx)
    r.TakeFX_SetEnabled(take, idx, false)
  end

  -- Count takes before render so we can find the new one
  local takes_before = r.GetMediaItemNumTakes(item)

  -- Run render action (renders selected items to new take)
  r.SelectAllMediaItems(0, false)
  r.SetMediaItemSelected(item, true)
  r.Main_OnCommand(41999, 0)

  -- Restore FX enabled state
  for _, idx in ipairs(bypass_fx_indices) do
    r.TakeFX_SetEnabled(take, idx, was_enabled[idx])
  end

  -- Find the new take (41999 appends one take)
  local takes_after = r.GetMediaItemNumTakes(item)
  if takes_after <= takes_before then
    return nil -- render produced nothing
  end

  local new_take_idx = takes_after - 1
  local new_take = r.GetMediaItemTake(item, new_take_idx)
  if not new_take then return nil end

  local src = r.GetMediaItemTake_Source(new_take)
  if not src then return nil end

  local wav_path = r.GetMediaSourceFileName(src, "")
  return wav_path, new_take
end

-- Spawn pvx asynchronously (detached process) with an ImGui cancel window.
-- argv:        array of strings (command + args, unquoted; this fn quotes them)
-- scratch_dir: directory where pid.txt, log.txt, done.txt are written
-- on_done:     fn(exit_code, log_txt) called on completion
-- on_cancel:   fn() called when user cancels or times out
-- on_error:    fn(msg) called on spawn failure
-- poll_rate:   Hz for done.txt polling (default 10)
-- timeout_s:   seconds before auto-cancel (default 300)
function pvx.RunPVXAsync(argv, scratch_dir, on_done, on_cancel, on_error, poll_rate, timeout_s)
  poll_rate = poll_rate or 10
  timeout_s = timeout_s or 300

  local pid_file  = scratch_dir .. "/pid.txt"
  local log_file  = scratch_dir .. "/log.txt"
  local done_file = scratch_dir .. "/done.txt"

  -- Remove stale sentinel files
  os.remove(done_file)
  os.remove(pid_file)

  local os_name = r.GetOS()
  local is_win  = os_name:find("Win") ~= nil

  -- Quote all argv entries for shell
  local quoted = {}
  for _, a in ipairs(argv) do
    quoted[#quoted + 1] = pvx.QuoteArg(a, is_win and "Windows" or "Other")
  end
  local cmd_str = table.concat(quoted, " ")

  -- Extract just the executable name for taskkill (Windows cancel)
  local pvx_exe_name = (argv[1]:match("[/\\]([^/\\]+)$") or argv[1])
  if not pvx_exe_name:lower():find("%.exe$") then
    pvx_exe_name = pvx_exe_name .. ".exe"
  end

  local launch_ok
  if is_win then
    -- Windows: two-file approach.
    --
    -- pvx_run.bat  — runs pvx synchronously, writes done.txt when done.
    --                Sets HOME=%USERPROFILE% (pvx requires HOME; not set on Windows).
    --
    -- pvx_launch.vbs — WScript.Shell.Run(cmd, 0, False):
    --                   0     = fully hidden window (no flicker, no taskbar entry)
    --                   False = async, returns immediately
    --                  VBScript sidesteps all the cmd.exe / PowerShell inline-
    --                  quoting layers that make nested process launch unreliable.
    local bat     = scratch_dir .. "/pvx_run.bat"
    local vbs     = scratch_dir .. "/pvx_launch.vbs"
    local log_win  = log_file:gsub("/", "\\")
    local done_win = done_file:gsub("/", "\\")
    local bat_win  = bat:gsub("/", "\\")
    local vbs_win  = vbs:gsub("/", "\\")

    -- Write the bat
    local fb = io.open(bat, "w")
    if not fb then
      on_error("Cannot write launcher batch file: " .. bat)
      return
    end
    fb:write("@echo off\r\n")
    fb:write("set HOME=%USERPROFILE%\r\n")
    fb:write("set PWD=%CD%\r\n")
    fb:write(cmd_str .. ' > "' .. log_win .. '" 2>&1\r\n')
    fb:write('echo %ERRORLEVEL% > "' .. done_win .. '"\r\n')
    fb:close()

    -- Write the VBScript launcher
    local fv = io.open(vbs, "w")
    if not fv then
      on_error("Cannot write VBScript launcher: " .. vbs)
      return
    end
    -- Chr(34) = double-quote; keeps the bat path safe without nested escaping
    fv:write('Set oShell = CreateObject("WScript.Shell")\r\n')
    fv:write('oShell.Run "cmd /c " & Chr(34) & "' ..
      bat_win:gsub('"', '""') .. '" & Chr(34), 0, False\r\n')
    fv:close()

    -- //nologo = no startup banner, //B = batch mode (suppress UI dialogs)
    launch_ok = os.execute('wscript.exe //nologo //B "' .. vbs_win .. '"')
  else
    -- Unix: subshell captures PID and writes done sentinel
    local shell_cmd = string.format(
      "(%s > %s 2>&1; echo $? > %s) & echo $! > %s",
      cmd_str,
      pvx.QuoteArg(log_file, "Other"),
      pvx.QuoteArg(done_file, "Other"),
      pvx.QuoteArg(pid_file, "Other")
    )
    launch_ok = os.execute(shell_cmd)
  end

  if not launch_ok then
    on_error("Failed to launch pvx subprocess")
    return
  end

  -- ImGui progress window + defer poll loop
  local success_im, im = pcall(function()
    package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
    return require('imgui')('0.9.3')
  end)
  if not success_im then
    -- No ImGui available — fall back to blocking poll with no UI
    local deadline = r.time_precise() + timeout_s
    while true do
      local f = io.open(done_file, "r")
      if f then
        local code = tonumber(f:read("*l")) or -1
        f:close()
        local lf = io.open(log_file, "r")
        local log_txt = lf and lf:read("*a") or ""
        if lf then lf:close() end
        on_done(code, log_txt)
        return
      end
      if r.time_precise() > deadline then
        on_cancel()
        return
      end
    end
  end

  local ctx        = im.CreateContext('PVX Render')
  local start_time = r.time_precise()
  local cancelled  = false
  local log_lines  = {}  -- last N lines read from log.txt

  -- Read the tail of the log file into log_lines (at most max_lines).
  local function UpdateLogLines(max_lines)
    local lf = io.open(log_file, "r")
    if not lf then return end
    local buf = {}
    for line in lf:lines() do
      buf[#buf + 1] = line
      -- Keep buffer bounded so large logs don't accumulate in memory
      if #buf > max_lines * 3 then table.remove(buf, 1) end
    end
    lf:close()
    log_lines = {}
    for i = math.max(1, #buf - max_lines + 1), #buf do
      log_lines[#log_lines + 1] = buf[i]
    end
  end

  local function cancel_process()
    if is_win then
      -- Windows v1: kill by executable name (no reliable PID from cmd /c start)
      os.execute('taskkill /F /IM "' .. pvx_exe_name .. '" > NUL 2>&1')
    else
      -- Unix: use the PID written by the subshell
      local pf = io.open(pid_file, "r")
      if pf then
        local pid = pf:read("*l")
        pf:close()
        if pid and pid ~= "" then
          os.execute("kill -9 " .. pid .. " 2>/dev/null")
        end
      end
    end
    cancelled = true
  end

  local spin_chars = { "|", "/", "-", "\\" }
  local spin_idx   = 0

  local function poll()
    if cancelled then return end

    spin_idx = (spin_idx % #spin_chars) + 1
    local elapsed = r.time_precise() - start_time

    -- Timeout
    if elapsed > timeout_s then
      cancel_process()
      ctx = nil
      on_cancel()
      return
    end

    -- Check done file
    local f = io.open(done_file, "r")
    if f then
      local code = tonumber(f:read("*l")) or -1
      f:close()
      local lf = io.open(log_file, "r")
      local log_txt = lf and lf:read("*a") or ""
      if lf then lf:close() end
      -- Contexts are managed by REAPER; no DestroyContext needed.
      ctx = nil
      on_done(code, log_txt)
      return
    end

    -- Update log display (read last 6 lines of pvx output)
    UpdateLogLines(6)

    -- Draw progress window
    if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
      ctx = im.CreateContext('PVX Render')
    end

    im.SetNextWindowSize(ctx, 500, 200, im.Cond_FirstUseEver)
    local visible, open = im.Begin(ctx, 'ajsfx PVX Render', true,
      im.WindowFlags_NoCollapse)

    if visible then
      im.Text(ctx, spin_chars[spin_idx] .. "  Running pvx...  " ..
        string.format("%.0fs / %ds", elapsed, timeout_s))
      im.Spacing(ctx)
      im.Separator(ctx)
      im.Spacing(ctx)
      -- Stream log output — shows pvx progress bar and stage names
      if #log_lines == 0 then
        im.TextDisabled(ctx, "(waiting for pvx output...)")
      else
        for _, line in ipairs(log_lines) do
          im.TextUnformatted(ctx, line)
        end
      end
      im.Spacing(ctx)
      im.Separator(ctx)
      im.Spacing(ctx)
      if im.Button(ctx, "Cancel") then
        im.End(ctx)  -- End before early return
        cancel_process()
        ctx = nil
        on_cancel()
        return
      end
    end

    -- Always call End after Begin — skipping it corrupts ImGui's push/pop
    -- stack and can cause spurious open=false returns in subsequent frames.
    im.End(ctx)

    -- Check close button AFTER End (safe to act on after stack is balanced)
    if not open then
      cancel_process()
      ctx = nil
      on_cancel()
      return
    end

    r.defer(poll)
  end

  r.defer(poll)
end

-- Load PVX config from ExtState.  Returns a config table with defaults.
function pvx.LoadConfig()
  local section = "ajsfx_pvx"
  local function get(key, default)
    if r.HasExtState(section, key) then
      return r.GetExtState(section, key)
    end
    return default
  end
  return {
    pvx_binary    = get("pvx_binary",    "pvx"),
    scratch_dir   = get("scratch_dir",   ""),
    poll_rate     = tonumber(get("poll_rate",   "10")),
    preview_secs  = tonumber(get("preview_secs","2.0")),
    timeout_s     = tonumber(get("timeout_s",  "300")),
    pvx_version   = get("pvx_version",   ""),
  }
end

-- Save PVX config to ExtState.
function pvx.SaveConfig(cfg)
  local section = "ajsfx_pvx"
  r.SetExtState(section, "pvx_binary",   tostring(cfg.pvx_binary   or "pvx"),    true)
  r.SetExtState(section, "scratch_dir",  tostring(cfg.scratch_dir  or ""),       true)
  r.SetExtState(section, "poll_rate",    tostring(cfg.poll_rate    or 10),       true)
  r.SetExtState(section, "preview_secs", tostring(cfg.preview_secs or 2.0),      true)
  r.SetExtState(section, "timeout_s",    tostring(cfg.timeout_s    or 300),      true)
  r.SetExtState(section, "pvx_version",  tostring(cfg.pvx_version  or ""),       true)
end

-- Resolve the scratch directory for pvx temp files.
-- Prefers config.scratch_dir; falls back to a subdir of the project path;
-- last resort: system temp dir.
function pvx.ResolveScratchDir(config)
  if config and config.scratch_dir and config.scratch_dir ~= "" then
    return config.scratch_dir
  end

  -- Try project directory
  local proj_path = r.GetProjectPath("")
  if proj_path and proj_path ~= "" then
    return proj_path .. "/pvx_scratch"
  end

  -- Fall back to system temp
  local tmp = os.tmpname()
  -- os.tmpname returns a file path; get its directory
  local dir = tmp:match("(.*[/\\])")
  return (dir or "/tmp") .. "pvx_scratch"
end

--------------------------------
-- Installation helpers
--------------------------------

-- Locate the Scripts/<repo>/ directory this lib is installed under, so the
-- installer and readiness check agree on one venv location regardless of
-- what ReaPack repo name the user imported under.
local function GetScriptsDir()
  local res_base = r.GetResourcePath():gsub("\\", "/")
  local lib_path = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
  return lib_path:match("^(.-)/pvx/lib/") or (res_base .. "/Scripts/ajsfx-ReaScripts")
end

-- Expected pvx binary path in the shared venv (sibling of pvx/).
function pvx.GetDefaultVenvBin()
  local is_win = r.GetOS():find("Win") ~= nil
  local base   = GetScriptsDir() .. "/venv"
  if is_win then
    return (base .. "/Scripts/pvx.exe"):gsub("/", "\\")
  else
    return base .. "/bin/pvx"
  end
end

-- Resolve the pvx binary path to use for a subprocess launch.
-- Prefers cfg.pvx_binary if it exists on disk; otherwise falls back to the
-- default venv binary if that exists. Returns nil if neither
-- path resolves to an actual file. Single source of truth — IsPVXReady and
-- every argv builder should call this so they can't disagree.
function pvx.GetPVXBinary(cfg)
  local bin = cfg and cfg.pvx_binary or ""
  if bin ~= "" and bin ~= "pvx" then
    local f = io.open(bin, "r")
    if f then f:close(); return bin end
  end
  local def = pvx.GetDefaultVenvBin()
  local f2 = io.open(def, "r")
  if f2 then f2:close(); return def end
  return nil
end

-- Returns true if pvx is installed and the binary can be found.
function pvx.IsPVXReady(cfg)
  return pvx.GetPVXBinary(cfg) ~= nil
end

-- Module-local: find a Python 3 interpreter on PATH.
local function FindPython()
  local is_win = r.GetOS():find("Win") ~= nil
  local candidates = is_win and { "python", "py", "python3" }
                              or { "python3", "python" }
  for _, cmd in ipairs(candidates) do
    local f = io.popen(cmd .. ' --version 2>&1')
    if f then
      local out = f:read("*l") or ""
      f:close()
      if out:find("Python 3") then return cmd end
    end
  end
  return nil
end

-- Async pvx installer.  Opens a visible terminal window showing pip progress.
-- on_done(pvx_bin_path) : called when install completes; binary path is saved to ExtState.
-- on_error(msg)         : called on failure.
function pvx.RunInstallAsync(on_done, on_error)
  local is_win      = r.GetOS():find("Win") ~= nil
  local scripts_dir = GetScriptsDir()
  local venv_path   = scripts_dir .. "/venv"
  local pip_path    = venv_path .. (is_win and "/Scripts/pip.exe" or "/bin/pip")
  local pvx_bin     = venv_path .. (is_win and "/Scripts/pvx.exe" or "/bin/pvx")
  local done_file   = scripts_dir .. "/install_done.txt"
  local zip_url     = "https://github.com/TheColby/pvx/archive/refs/heads/main.zip"

  local python_cmd = FindPython()
  if not python_cmd then
    on_error("Python 3 not found on PATH.\n" ..
             "Install Python 3.8+ from https://python.org and ensure it is on your PATH.")
    return
  end

  local function native(p) return is_win and p:gsub("/", "\\") or p end

  -- Ensure scripts_dir exists before writing the launcher script there
  if is_win then
    os.execute('mkdir "' .. native(scripts_dir) .. '" 2>NUL')
  else
    os.execute("mkdir -p '" .. scripts_dir .. "'")
  end

  os.remove(done_file)  -- clear any stale sentinel

  if is_win then
    local bat             = scripts_dir .. "/pvx_install.bat"
    local bat_win         = native(bat)
    local pip_win         = native(pip_path)
    local venv_win        = native(venv_path)
    local venv_python_win = native(venv_path .. "/Scripts/python.exe")
    local done_win        = native(done_file)

    local fb = io.open(bat, "w")
    if not fb then on_error("Cannot write installer bat: " .. bat); return end

    fb:write("@echo off\r\n")
    fb:write("title ajsfx PVX Install\r\n")
    fb:write("set HOME=%USERPROFILE%\r\n")
    fb:write("set PWD=%CD%\r\n")
    fb:write("echo === ajsfx PVX Install ===\r\n")
    fb:write("echo Python: " .. python_cmd .. "\r\n")
    fb:write("echo Venv:   " .. venv_win .. "\r\n")
    fb:write("echo.\r\n")
    -- Create venv if pip.exe not yet present
    fb:write('if not exist "' .. pip_win .. '" (\r\n')
    fb:write("  echo Creating Python virtual environment...\r\n")
    fb:write("  " .. python_cmd .. ' -m venv "' .. venv_win .. '"\r\n')
    fb:write("  if errorlevel 1 (\r\n")
    fb:write("    echo ERROR: Failed to create venv!\r\n")
    fb:write("    set INSTALL_CODE=1\r\n")
    fb:write("    goto :write_done\r\n")
    fb:write("  )\r\n")
    fb:write("  echo.\r\n")
    fb:write(")\r\n")
    fb:write("echo Upgrading pip...\r\n")
    fb:write('"' .. venv_python_win .. '" -m pip install --upgrade pip\r\n')
    fb:write("echo.\r\n")
    fb:write("echo Installing pvx from GitHub...\r\n")
    fb:write("echo (This may take a minute)\r\n")
    fb:write('"' .. venv_python_win .. '" -m pip install ' .. zip_url .. ' --disable-pip-version-check\r\n')
    fb:write("set INSTALL_CODE=%ERRORLEVEL%\r\n")
    fb:write("echo.\r\n")
    fb:write("if %INSTALL_CODE% EQU 0 (\r\n")
    fb:write("  echo pvx installed successfully!\r\n")
    fb:write(") else (\r\n")
    fb:write("  echo ERROR: Installation failed! See above for details.\r\n")
    fb:write(")\r\n")
    fb:write(":write_done\r\n")
    fb:write('echo %INSTALL_CODE% > "' .. done_win .. '"\r\n')
    fb:write("echo.\r\n")
    fb:write("echo You can close this window.\r\n")
    fb:close()

    -- VBScript launcher: style=1 (normal visible window), async.
    -- os.execute → system() creates a hidden cmd.exe; 'start' from within it
    -- doesn't reliably produce a visible window. WScript.Shell.Run bypasses
    -- that chain and sets the window style directly.
    local vbs     = scripts_dir .. "/pvx_install.vbs"
    local vbs_win = native(vbs)
    local fv = io.open(vbs, "w")
    if not fv then on_error("Cannot write installer launcher: " .. vbs); return end
    fv:write('Set oShell = CreateObject("WScript.Shell")\r\n')
    fv:write('oShell.Run "cmd /k " & Chr(34) & "' ..
      bat_win:gsub('"', '""') .. '" & Chr(34), 1, False\r\n')
    fv:close()
    local ok = os.execute('wscript.exe //nologo //B "' .. vbs_win .. '"')
    if not ok then on_error("Failed to launch installer window."); return end
  else
    local sh = scripts_dir .. "/pvx_install.sh"
    local sf = io.open(sh, "w")
    if not sf then on_error("Cannot write installer script: " .. sh); return end
    sf:write("#!/bin/bash\n")
    sf:write("echo '=== ajsfx PVX Install ==='\n")
    sf:write("echo 'Python: " .. python_cmd .. "'\n")
    sf:write("mkdir -p '" .. scripts_dir .. "'\n")
    sf:write("if [ ! -f '" .. pip_path .. "' ]; then\n")
    sf:write("  echo 'Creating venv...'\n")
    sf:write("  " .. python_cmd .. " -m venv '" .. venv_path .. "'\n")
    sf:write("  [ $? -ne 0 ] && { echo 'ERROR: venv failed!'; echo 1 > '" .. done_file .. "'; exit 1; }\n")
    sf:write("fi\n")
    local venv_python = venv_path .. "/bin/python"
    sf:write("echo 'Upgrading pip...'\n")
    sf:write("'" .. venv_python .. "' -m pip install --upgrade pip\n")
    sf:write("echo 'Installing pvx from GitHub...'\n")
    sf:write("'" .. pip_path .. "' install " .. zip_url .. " --disable-pip-version-check\n")
    sf:write("echo $? > '" .. done_file .. "'\n")
    sf:write("[ $? -eq 0 ] && echo 'pvx installed successfully!' || echo 'ERROR: Installation failed!'\n")
    sf:write("echo 'Press enter to close.'; read\n")
    sf:close()
    os.execute("chmod +x '" .. sh .. "'")
    local ok = os.execute("open -a Terminal '" .. sh .. "' 2>/dev/null") or
               os.execute("x-terminal-emulator -e 'bash " .. sh .. "' 2>/dev/null") or
               os.execute("xterm -e 'bash " .. sh .. "' 2>/dev/null")
    if not ok then
      on_error("Could not open a terminal. Run the installer manually:\n" .. sh)
      return
    end
  end

  -- Poll for done file; no progress UI needed since the installer window is visible
  local start_time = r.time_precise()
  local timeout    = 600  -- 10 minutes

  local function poll()
    local f = io.open(done_file, "r")
    if f then
      local content = f:read("*a") or ""
      f:close()
      -- File may exist but still be flushing (empty or whitespace) — keep polling
      local code_str = content:match("(%-?%d+)")
      if not code_str then
        if r.time_precise() - start_time > timeout then
          on_error("Installation timed out; done file never populated.")
          return
        end
        r.defer(poll)
        return
      end
      local code = tonumber(code_str)
      os.remove(done_file)
      if code == 0 then
        local bin = is_win and native(pvx_bin) or pvx_bin
        r.SetExtState("ajsfx_pvx", "pvx_binary", bin, true)
        on_done(bin)
      else
        on_error("pvx installation failed (exit code " .. tostring(code) ..
                 "). Check the installer window for details.")
      end
      return
    end
    if r.time_precise() - start_time > timeout then
      on_error("Installation timed out after " .. timeout .. " seconds.")
      return
    end
    r.defer(poll)
  end

  r.defer(poll)
end

return pvx
