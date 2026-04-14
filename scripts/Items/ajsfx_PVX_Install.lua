-- @description ajsfx PVX Install
-- @author ajsfx
-- @version 0.1
-- @about Detects Python 3, creates a venv in the REAPER Scripts folder,
--        pip-installs pvx, and saves the binary path to ajsfx PVX Settings.
--        Run this once before using ajsfx PVX Render or Preview.
-- @provides
--   [main] .

local r = reaper

-- -----------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------

local function Print(msg)
  r.ShowConsoleMsg(msg .. "\n")
end

local function Fail(msg)
  Print("ERROR: " .. msg)
  r.ShowMessageBox(msg, "ajsfx PVX Install — Error", 0)
end

local is_win = r.GetOS():find("Win") ~= nil

local function NativePath(p)
  return is_win and p:gsub("/", "\\") or p
end

-- -----------------------------------------------------------------------
-- Step 1: Find a working Python 3 interpreter
-- -----------------------------------------------------------------------

local function FindPython()
  local candidates = is_win and { "python", "py", "python3" }
                              or { "python3", "python" }
  for _, cmd in ipairs(candidates) do
    local f = io.popen(cmd .. ' --version 2>&1')
    if f then
      local out = f:read("*l") or ""
      f:close()
      if out:find("Python 3") then
        return cmd, out:match("Python (%S+)")
      end
    end
  end
  return nil
end

-- -----------------------------------------------------------------------
-- Step 2: Create venv (skip if already exists)
-- -----------------------------------------------------------------------

local function EnsureVenv(python_cmd, venv_path)
  -- Check if venv already exists by probing the pip executable
  local pip = is_win and (venv_path .. "\\Scripts\\pip.exe")
                      or (venv_path .. "/bin/pip")
  local f = io.open(NativePath(pip), "r")
  if f then
    f:close()
    Print("Venv already exists at: " .. venv_path)
    return true, pip
  end

  Print("Creating venv at: " .. venv_path .. "  (this may take a moment…)")
  local ok = os.execute(python_cmd .. ' -m venv "' .. NativePath(venv_path) .. '"')
  if not ok then
    return false, nil, "Failed to create venv. Make sure Python has the 'venv' module available."
  end
  return true, pip
end

-- -----------------------------------------------------------------------
-- Step 3: pip install pvx
-- -----------------------------------------------------------------------

-- Run a pip command and return (success_bool, output_string).
-- Uses io.popen so stdout+stderr are captured directly — no shell
-- redirection needed (os.execute on Windows doesn't go through cmd.exe
-- so ">" redirection silently drops all output).
local function RunPip(pip_path, args)
  local q = '"' .. NativePath(pip_path) .. '"'
  local cmd = q .. " " .. args .. " 2>&1"
  local f = io.popen(cmd)
  local out = f and (f:read("*a") or "") or ""
  local ok  = f and f:close()  -- true / nil based on exit code
  return ok, out
end

local function InstallPVX(pip_path)
  -- Upgrade pip first — Python 3.12+ venvs can ship with a pip that
  -- predates newer package metadata formats and will silently fail.
  Print("Upgrading pip…  (REAPER will be unresponsive for a moment)")
  local _, upg_out = RunPip(pip_path, "install --upgrade pip")
  Print(upg_out ~= "" and upg_out or "(no output)")

  -- Try PyPI
  Print("Running: pip install pvx")
  local ok1, out1 = RunPip(pip_path, "install pvx")
  Print(out1 ~= "" and out1 or "(no output)")
  if ok1 then return true, nil end

  -- Not on PyPI — try GitHub zip (no git binary required)
  Print("pip install pvx failed. Trying GitHub zip…")
  local zip_url = "https://github.com/TheColby/pvx/archive/refs/heads/main.zip"
  local ok2, out2 = RunPip(pip_path, 'install "' .. zip_url .. '"')
  Print(out2 ~= "" and out2 or "(no output)")
  if ok2 then return true, nil end

  return false,
    "pip install failed from both PyPI and GitHub.\n\n" ..
    "PyPI log:\n" .. out1 .. "\n\nGitHub log:\n" .. out2
end

-- -----------------------------------------------------------------------
-- Step 4: Verify the pvx binary exists and get its version
-- -----------------------------------------------------------------------

local function VerifyPVX(pvx_path)
  local f = io.open(NativePath(pvx_path), "r")
  if not f then
    return false, "pvx binary not found at expected path:\n" .. pvx_path
  end
  f:close()

  -- Get version string
  local vf = io.popen('"' .. NativePath(pvx_path) .. '" --version 2>&1')
  local version = ""
  if vf then
    version = vf:read("*l") or ""
    vf:close()
  end
  return true, version
end

-- -----------------------------------------------------------------------
-- Main
-- -----------------------------------------------------------------------

r.ClearConsole()
Print("=== ajsfx PVX Install ===")
Print("")

-- Step 1: Python
Print("Looking for Python 3…")
local python_cmd, py_version = FindPython()
if not python_cmd then
  Fail("Python 3 not found.\n\n" ..
       "Install Python 3.8+ from https://python.org and ensure it is on your PATH.\n" ..
       "On Windows you can also install from the Microsoft Store.")
  return
end
Print("Found: " .. python_cmd .. "  (" .. (py_version or "?") .. ")")
Print("")

-- Determine venv location
local venv_path = r.GetResourcePath() .. "/Scripts/ajsfx_pvx_venv"
Print("Venv path: " .. venv_path)
Print("")

-- Step 2: Venv
local venv_ok, pip_path, venv_err = EnsureVenv(python_cmd, venv_path)
if not venv_ok then
  Fail(venv_err)
  return
end
Print("")

-- Step 3: pip install
local pip_ok, pip_err = InstallPVX(pip_path)  -- returns (bool, err_string|nil)
if not pip_ok then
  Fail(pip_err)
  return
end
Print("")

-- Step 4: Verify + find binary
local pvx_path = is_win and (venv_path .. "\\Scripts\\pvx.exe")
                         or (venv_path .. "/bin/pvx")

local ok, version_or_err = VerifyPVX(pvx_path)
if not ok then
  Fail(version_or_err)
  return
end

-- Step 5: Save to ExtState (same section as ajsfx_PVX_Settings)
r.SetExtState("ajsfx_pvx", "pvx_binary", NativePath(pvx_path), true)
if version_or_err ~= "" then
  r.SetExtState("ajsfx_pvx", "pvx_version", version_or_err, true)
end

Print("pvx binary: " .. NativePath(pvx_path))
Print("pvx version: " .. (version_or_err ~= "" and version_or_err or "unknown"))
Print("")
Print("=== Installation complete! ===")
Print("Binary path saved to ajsfx PVX Settings.")
Print("You can now use ajsfx PVX Render and Preview.")

r.ShowMessageBox(
  "pvx installed successfully!\n\n" ..
  "Binary: " .. NativePath(pvx_path) .. "\n" ..
  (version_or_err ~= "" and ("Version: " .. version_or_err .. "\n") or "") ..
  "\nYou can now run ajsfx PVX Render and Preview.",
  "ajsfx PVX Install — Complete", 0)
