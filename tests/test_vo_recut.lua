-- Unit tests for vo.ClusterClumps and vo.PlanReCut -- the pure layer behind
-- the Overview's "Re-cut selected takes"
-- (docs/superpowers/specs/2026-08-14-vo-recut-clumps-design.md).

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

print("\n=== ajsfx_vo.lua Re-cut Unit Tests ===\n")

local TRACK = {}   -- opaque handle, compared by identity

-- One item info. `n` only makes the item handle unique and printable.
local function info(n, pos, len, offs, opts)
  opts = opts or {}
  return {
    item       = "item" .. n,
    pos        = pos,
    length     = len,
    start_offs = offs,
    playrate   = opts.playrate or 1.0,
    pitch      = opts.pitch or 0,
    path       = opts.path or "rec.wav",
    track      = opts.track or TRACK,
    locked     = opts.locked or false,
  }
end

print("ClusterClumps:")

test("items abutting in project AND source time are one clump", function()
  -- The observed Grumbar pair.
  local a = info(1, 1254.510, 0.595, 1254.510)
  local b = info(2, 1255.105, 1.125, 1255.105)
  local c = vo.ClusterClumps({ a, b })
  assert(#c == 1, "expected 1 clump, got " .. #c)
  assert(#c[1] == 2, "expected 2 items in the clump, got " .. #c[1])
  assert(c[1][1].item == "item1", "clump not ordered by pos")
end)

test("abutting in project time only is two clumps", function()
  -- Touching on the timeline, but item2 comes from elsewhere in the file:
  -- a deliberate assembly, never healed.
  local a = info(1, 10.0, 1.0, 100.0)
  local b = info(2, 11.0, 1.0, 500.0)
  assert(#vo.ClusterClumps({ a, b }) == 2)
end)

test("abutting in source time only is two clumps", function()
  local a = info(1, 10.0, 1.0, 100.0)
  local b = info(2, 30.0, 1.0, 101.0)
  assert(#vo.ClusterClumps({ a, b }) == 2)
end)

test("a gap larger than the tolerance splits the clump", function()
  local a = info(1, 10.0, 1.0, 100.0)
  local b = info(2, 11.01, 1.0, 101.01)
  assert(#vo.ClusterClumps({ a, b }) == 2)
end)

test("a gap inside the tolerance still clumps", function()
  local a = info(1, 10.0, 1.0, 100.0)
  local b = info(2, 11.0005, 1.0, 101.0005)
  assert(#vo.ClusterClumps({ a, b }) == 1)
end)

test("a lone item is a clump of one", function()
  local c = vo.ClusterClumps({ info(1, 10.0, 1.0, 100.0) })
  assert(#c == 1 and #c[1] == 1)
end)

test("different tracks never clump, however well they abut", function()
  local a = info(1, 10.0, 1.0, 100.0)
  local b = info(2, 11.0, 1.0, 101.0, { track = {} })
  assert(#vo.ClusterClumps({ a, b }) == 2)
end)

test("different sources never clump", function()
  local a = info(1, 10.0, 1.0, 100.0)
  local b = info(2, 11.0, 1.0, 101.0, { path = "other.wav" })
  assert(#vo.ClusterClumps({ a, b }) == 2)
end)

test("three in a row make one clump, transitively", function()
  local c = vo.ClusterClumps({
    info(1, 10.0, 1.0, 100.0),
    info(2, 11.0, 1.0, 101.0),
    info(3, 12.0, 2.0, 102.0),
  })
  assert(#c == 1 and #c[1] == 3)
end)

test("input order does not matter", function()
  local a = info(1, 10.0, 1.0, 100.0)
  local b = info(2, 11.0, 1.0, 101.0)
  local c = vo.ClusterClumps({ b, a })
  assert(#c == 1 and c[1][1].item == "item1")
end)

test("source abutment uses each item's own playrate", function()
  -- item1 covers 100.0..101.0 of the source at half speed: 2s long.
  local a = info(1, 10.0, 2.0, 100.0, { playrate = 0.5 })
  local b = info(2, 12.0, 1.0, 101.0)
  assert(#vo.ClusterClumps({ a, b }) == 1,
         "mixed rates must still cluster; the RATE REFUSAL is PlanReCut's job")
end)

print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed > 0 and 1 or 0)
