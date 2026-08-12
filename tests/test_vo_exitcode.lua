-- Unit tests for vo.ParseExitFile -- the launcher's done-file, read back.
--
-- Why this is its own function: the Windows launcher runs
--   whisper-cli ... > log 2>&1
--   echo %ERRORLEVEL% > done.txt
-- and the poll loop opens done.txt at frame rate. `>` CREATES the file before
-- the code is written into it, so a poll can open it empty. The old reader did
--   tonumber(f:read("l")) or -1
-- which turned "not written yet" into the exit code -1, and the tool told the
-- user "whisper-cli exited with code -1" about a run that was still starting.
-- On one real session that lost the first 30 seconds of a read.

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    print("  FAIL: " .. name .. " - " .. tostring(err))
  end
end

package.path = package.path .. ";VO/lib/?.lua;tests/?.lua"
local mock = require("mock_reaper")
mock.reset()
local vo = require("ajsfx_vo")

print("\n=== ajsfx_vo.lua ParseExitFile Unit Tests ===\n")

test("a plain zero is success", function()
  assert(vo.ParseExitFile("0") == 0, "expected 0")
end)

test("echo leaves a trailing space and CRLF, and that is still a code", function()
  assert(vo.ParseExitFile("0 \r\n") == 0, "expected 0")
  assert(vo.ParseExitFile("3 \r\n") == 3, "expected 3")
end)

test("a real non-zero code survives", function()
  assert(vo.ParseExitFile("-1073741819") == -1073741819, "a crash code is a code")
end)

test("EMPTY means not finished, not failure", function()
  assert(vo.ParseExitFile("") == nil, "empty must read as nil")
  assert(vo.ParseExitFile("   ") == nil, "whitespace must read as nil")
  assert(vo.ParseExitFile("\r\n") == nil, "a bare newline must read as nil")
end)

test("a missing file means not finished", function()
  assert(vo.ParseExitFile(nil) == nil, "nil must read as nil")
end)

test("junk means not finished rather than a made-up code", function()
  assert(vo.ParseExitFile("ECHO is off.") == nil, "junk must read as nil")
end)

print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed == 0 and 0 or 1)
