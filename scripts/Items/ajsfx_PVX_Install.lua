-- @description ajsfx PVX Install
-- @author ajsfx
-- @version 0.2
-- @about Installs the pvx phase-vocoder CLI into an isolated venv and saves
--        the binary path to ajsfx PVX Settings. Requires Python 3.8+ on PATH
--        and an internet connection. Opens a visible terminal window showing
--        installation progress.
-- @provides
--   [main] .

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path
local pvx_lib = require("lib.ajsfx_pvx")

r.ClearConsole()
r.ShowConsoleMsg("=== ajsfx PVX Install ===\n\n")

local cfg = pvx_lib.LoadConfig()
if pvx_lib.IsPVXReady(cfg) then
  local ok = r.ShowMessageBox(
    "pvx is already installed.\n\nReinstall?",
    "ajsfx PVX Install", 1)
  if ok ~= 1 then return end
end

r.ShowConsoleMsg("Opening installer window...\n")

pvx_lib.RunInstallAsync(
  function(pvx_bin)
    r.ShowConsoleMsg("pvx binary: " .. pvx_bin .. "\n")
    r.ShowConsoleMsg("Installation complete!\n")
    r.MB(
      "pvx installed successfully!\n\n" ..
      "Binary: " .. pvx_bin .. "\n\n" ..
      "You can now use ajsfx PVX Render and Preview.",
      "ajsfx PVX Install", 0)
  end,
  function(err)
    r.ShowConsoleMsg("ERROR: " .. err .. "\n")
    r.MB("Installation failed:\n\n" .. err, "ajsfx PVX Install — Error", 0)
  end
)
