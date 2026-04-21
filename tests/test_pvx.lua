-- Unit tests for lib/ajsfx_pvx.lua
-- Run with: lua tests/test_pvx.lua (from the repository root)
-- These tests mock the REAPER API since they run outside REAPER.

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

-- Minimal REAPER API mock (pure helpers don't need it, but require() needs the global)
reaper = {}

-- Load pvx library (run from repo root: lua tests/test_pvx.lua)
package.path = package.path .. ";pvx/lib/?.lua"
local pvx = require("ajsfx_pvx")

print("\n=== ajsfx_pvx.lua Unit Tests ===\n")

-- --- Log2StretchToFactor ---
print("Log2StretchToFactor:")

test("zero returns 1.0 (no stretch)", function()
  local f = pvx.Log2StretchToFactor(0)
  assert(math.abs(f - 1.0) < 1e-9, "Expected 1.0, got " .. tostring(f))
end)

test("+1 returns 2.0 (half speed)", function()
  local f = pvx.Log2StretchToFactor(1)
  assert(math.abs(f - 2.0) < 1e-9, "Expected 2.0, got " .. tostring(f))
end)

test("-1 returns 0.5 (double speed)", function()
  local f = pvx.Log2StretchToFactor(-1)
  assert(math.abs(f - 0.5) < 1e-9, "Expected 0.5, got " .. tostring(f))
end)

test("large positive clamped to 8.0", function()
  local f = pvx.Log2StretchToFactor(10)
  assert(f == 8.0, "Expected clamp to 8.0, got " .. tostring(f))
end)

test("large negative clamped to 0.125", function()
  local f = pvx.Log2StretchToFactor(-10)
  assert(f == 0.125, "Expected clamp to 0.125, got " .. tostring(f))
end)

-- --- FormatCSV ---
print("\nFormatCSV:")

test("single sample has header then data row", function()
  local samples = { {0.0, 1.5} }
  local csv = pvx.FormatCSV(samples, 50)
  local lines = {}
  for line in csv:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(#lines == 2, "Expected 2 lines (header + 1 data), got " .. #lines)
  assert(lines[1] == "time,value", "Header: " .. lines[1])
  assert(lines[2] == "0.000000,1.500000", "Data: " .. lines[2])
end)

test("two samples: header + two data rows", function()
  local samples = { {0.0, 0.0}, {1.0, 12.0} }
  local csv = pvx.FormatCSV(samples, 50)
  local lines = {}
  for line in csv:gmatch("[^\n]+") do lines[#lines + 1] = line end
  assert(#lines == 3, "Expected 3 lines, got " .. #lines)
  assert(lines[1] == "time,value",          "Header: "  .. lines[1])
  assert(lines[2] == "0.000000,0.000000",   "Line 2: "  .. lines[2])
  assert(lines[3] == "1.000000,12.000000",  "Line 3: "  .. lines[3])
end)

test("empty samples returns empty string", function()
  local csv = pvx.FormatCSV({}, 50)
  assert(csv == "", "Expected empty string, got: " .. csv)
end)

-- --- ShouldEmitCurve ---
print("\nShouldEmitCurve:")

test("has envelope -> always emit", function()
  assert(pvx.ShouldEmitCurve(true, 0.0, 0.0) == true)
end)

test("no envelope, slider at default -> skip", function()
  assert(pvx.ShouldEmitCurve(false, 0.0, 0.0) == false)
end)

test("no envelope, slider off-default -> emit", function()
  assert(pvx.ShouldEmitCurve(false, 2.0, 0.0) == true)
end)

test("no envelope, tiny float difference stays false", function()
  assert(pvx.ShouldEmitCurve(false, 0.0 + 1e-12, 0.0) == false)
end)

-- --- BuildArgv ---
print("\nBuildArgv:")

test("basic config: pvx placeholder, voc subcommand, --output, --interp", function()
  local cfg = { input = "/tmp/in.wav", output = "/tmp/out.wav", interp = 0 }
  local argv = pvx.BuildArgv(cfg)
  assert(argv[1] == "pvx",          "argv[1] should be pvx placeholder, got: " .. tostring(argv[1]))
  assert(argv[2] == "voc",          "argv[2] should be voc subcommand, got: "  .. tostring(argv[2]))
  assert(argv[3] == "/tmp/in.wav",  "argv[3] should be input path")

  local has_output = false
  local has_interp = false
  for i, v in ipairs(argv) do
    if v == "--output" then has_output = true; assert(argv[i+1] == "/tmp/out.wav") end
    if v == "--interp" then has_interp = true; assert(argv[i+1] == "linear")       end
  end
  assert(has_output, "Missing --output flag")
  assert(has_interp, "Missing --interp flag")
end)

test("no --phase-lock or --preserve-transients in argv", function()
  local cfg = { input = "in.wav", output = "out.wav", interp = 0 }
  local argv = pvx.BuildArgv(cfg)
  for _, v in ipairs(argv) do
    assert(v ~= "--phase-lock",          "--phase-lock should not appear")
    assert(v ~= "--preserve-transients", "--preserve-transients should not appear")
  end
end)

test("pitch_csv adds --pitch flag", function()
  local cfg = { input = "in.wav", output = "out.wav", interp = 0,
                pitch_csv = "/tmp/pitch.csv" }
  local argv = pvx.BuildArgv(cfg)
  local found = false
  for i, v in ipairs(argv) do
    if v == "--pitch" then found = true; assert(argv[i+1] == "/tmp/pitch.csv") end
  end
  assert(found, "--pitch flag not found")
end)

test("stretch_csv adds --stretch flag", function()
  local cfg = { input = "in.wav", output = "out.wav", interp = 0,
                stretch_csv = "/tmp/stretch.csv" }
  local argv = pvx.BuildArgv(cfg)
  local found = false
  for i, v in ipairs(argv) do
    if v == "--stretch" then found = true; assert(argv[i+1] == "/tmp/stretch.csv") end
  end
  assert(found, "--stretch flag not found")
end)

test("no pitch/stretch flags when csvs omitted", function()
  local cfg = { input = "in.wav", output = "out.wav", interp = 0 }
  local argv = pvx.BuildArgv(cfg)
  for _, v in ipairs(argv) do
    assert(v ~= "--pitch",   "--pitch should not appear")
    assert(v ~= "--stretch", "--stretch should not appear")
  end
end)

-- --- QuoteArg ---
print("\nQuoteArg:")

test("POSIX: simple path unchanged inside single-quotes", function()
  local q = pvx.QuoteArg("/home/user/file.wav", "Other")
  assert(q == "'/home/user/file.wav'", "Got: " .. q)
end)

test("POSIX: path with single-quote escaped", function()
  local q = pvx.QuoteArg("it's a file", "Other")
  assert(q == "'it'\\''s a file'", "Got: " .. q)
end)

test("Windows: path wrapped in double-quotes", function()
  local q = pvx.QuoteArg("C:\\Users\\foo\\bar.wav", "Windows")
  assert(q == '"C:\\Users\\foo\\bar.wav"', "Got: " .. q)
end)

test("Windows: interior double-quote escaped", function()
  local q = pvx.QuoteArg('say "hello"', "Windows")
  assert(q == '"say \\"hello\\""', "Got: " .. q)
end)

-- --- BumpTakeVersion ---
print("\nBumpTakeVersion:")

test("no existing pvx takes -> pvx_v1", function()
  local name = pvx.BumpTakeVersion({"dry", "wet"}, "pvx_v")
  assert(name == "pvx_v1", "Got: " .. name)
end)

test("existing pvx_v1 -> pvx_v2", function()
  local name = pvx.BumpTakeVersion({"dry", "pvx_v1"}, "pvx_v")
  assert(name == "pvx_v2", "Got: " .. name)
end)

test("gap in numbering -> uses max+1", function()
  local name = pvx.BumpTakeVersion({"pvx_v1", "pvx_v3"}, "pvx_v")
  assert(name == "pvx_v4", "Got: " .. name)
end)

test("empty list -> pvx_v1", function()
  local name = pvx.BumpTakeVersion({}, "pvx_v")
  assert(name == "pvx_v1", "Got: " .. name)
end)

test("non-matching names ignored", function()
  local name = pvx.BumpTakeVersion({"pvx_version2", "pvx_v"}, "pvx_v")
  assert(name == "pvx_v1", "Got: " .. name)
end)

-- --- Summary ---
print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
  os.exit(1)
end
