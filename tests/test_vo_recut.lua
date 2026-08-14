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

print("\nPlanReCut:")

-- The clump observed on the Grumbar session, plus its right-hand neighbour.
local function grumbar()
  local a = info(1, 1254.510, 0.595, 1254.510)
  local b = info(2, 1255.105, 1.125, 1255.105)
  local right = info(3, 1258.280, 3.770, 1258.280)
  return { a, b }, { right }
end

test("window is the clump coverage when no span overflows it", function()
  local clump = { info(1, 10.0, 1.0, 100.0), info(2, 11.0, 1.0, 101.0) }
  local spans = { { source_path = "rec.wav", start = 100.2, stop = 101.8 } }
  local p = vo.PlanReCut(clump, spans, {}, {})
  assert(not p.refuse, "unexpected refusal: " .. tostring(p.refuse))
  assert(math.abs(p.window.from - 100.0) < 1e-6, "from " .. p.window.from)
  assert(math.abs(p.window.to - 102.0) < 1e-6, "to " .. p.window.to)
  assert(p.grew == false, "window should not have grown")
end)

test("a span overflowing the coverage grows the window", function()
  local clump, neighbours = grumbar()
  local spans = {
    { source_path = "rec.wav", start = 1254.20, stop = 1255.74 },
    { source_path = "rec.wav", start = 1255.74, stop = 1258.28 },
  }
  local p = vo.PlanReCut(clump, spans, neighbours, {})
  assert(not p.refuse, tostring(p.refuse))
  -- Coverage is 1254.510..1256.230; the second span overflows to 1258.28.
  assert(math.abs(p.window.to - 1258.28) < 1e-6, "to " .. p.window.to)
  assert(p.grew == true)
end)

test("growth stops at a same-track neighbour's edge", function()
  local clump, neighbours = grumbar()
  -- A span that would run past item3's start at source 1258.28.
  local spans = { { source_path = "rec.wav", start = 1255.74, stop = 1262.00 } }
  local p = vo.PlanReCut(clump, spans, neighbours, {})
  assert(math.abs(p.window.to - 1258.28) < 1e-6,
         "must clamp to the neighbour, got " .. p.window.to)
end)

test("growth stops at a neighbour on the left too", function()
  local left = info(9, 1249.200, 2.497, 1249.200)   -- ends at source 1251.697
  local clump = select(1, grumbar())
  local spans = { { source_path = "rec.wav", start = 1248.00, stop = 1255.00 } }
  local p = vo.PlanReCut(clump, spans, { left }, {})
  assert(math.abs(p.window.from - 1251.697) < 1e-6,
         "must clamp to the left neighbour, got " .. p.window.from)
end)

test("a neighbour on another track does not bound the window", function()
  local clump, _ = grumbar()
  local elsewhere = info(3, 1258.280, 3.770, 1258.280, { track = {} })
  local spans = { { source_path = "rec.wav", start = 1255.74, stop = 1259.00 } }
  local p = vo.PlanReCut(clump, spans, { elsewhere }, {})
  assert(math.abs(p.window.to - 1259.00) < 1e-6, "to " .. p.window.to)
end)

test("spans from another source are ignored", function()
  local clump = { info(1, 10.0, 1.0, 100.0) }
  local spans = { { source_path = "other.wav", start = 50.0, stop = 500.0 } }
  local p = vo.PlanReCut(clump, spans, {}, {})
  assert(p.refuse, "a clump with no span of its own must refuse")
end)

test("no span clearing the window refuses rather than guessing", function()
  local clump = { info(1, 10.0, 1.0, 100.0) }
  local p = vo.PlanReCut(clump, {}, {}, {})
  assert(p.refuse and p.refuse:match("no match"), tostring(p.refuse))
  assert(p.window == nil, "a refusal must carry no window")
end)

test("a locked item refuses the whole clump", function()
  local a = info(1, 10.0, 1.0, 100.0)
  local b = info(2, 11.0, 1.0, 101.0, { locked = true })
  local spans = { { source_path = "rec.wav", start = 100.2, stop = 101.8 } }
  local p = vo.PlanReCut({ a, b }, spans, {}, {})
  assert(p.refuse and p.refuse:match("locked"), tostring(p.refuse))
end)

test("mixed playrates refuse by default", function()
  local a = info(1, 10.0, 2.0, 100.0, { playrate = 0.5 })
  local b = info(2, 12.0, 1.0, 101.0)
  local spans = { { source_path = "rec.wav", start = 100.2, stop = 101.8 } }
  local p = vo.PlanReCut({ a, b }, spans, {}, {})
  assert(p.refuse and p.refuse:match("playrate"), tostring(p.refuse))
end)

test("mixed pitch refuses by default", function()
  local a = info(1, 10.0, 1.0, 100.0, { pitch = -1 })
  local b = info(2, 11.0, 1.0, 101.0)
  local spans = { { source_path = "rec.wav", start = 100.2, stop = 101.8 } }
  local p = vo.PlanReCut({ a, b }, spans, {}, {})
  assert(p.refuse and p.refuse:match("pitch"), tostring(p.refuse))
end)

test("ignore_rate proceeds, takes the LONGEST item's rate, records the rest", function()
  -- item1 is 2.0s long at rate 0.5; item2 is 1.0s at rate 1.0.
  local a = info(1, 10.0, 2.0, 100.0, { playrate = 0.5, pitch = -2 })
  local b = info(2, 12.0, 1.0, 101.0)
  local spans = { { source_path = "rec.wav", start = 100.2, stop = 101.8 } }
  local p = vo.PlanReCut({ a, b }, spans, {}, { ignore_rate = true })
  assert(not p.refuse, tostring(p.refuse))
  assert(math.abs(p.rate - 0.5) < 1e-9, "rate " .. tostring(p.rate))
  assert(math.abs(p.pitch - (-2)) < 1e-9, "pitch " .. tostring(p.pitch))
  assert(#p.dropped_rate == 1, "dropped " .. #p.dropped_rate)
  assert(math.abs(p.dropped_rate[1].playrate - 1.0) < 1e-9)
end)

test("uniform rates need no override and drop nothing", function()
  local clump = { info(1, 10.0, 1.0, 100.0), info(2, 11.0, 1.0, 101.0) }
  local spans = { { source_path = "rec.wav", start = 100.2, stop = 101.8 } }
  local p = vo.PlanReCut(clump, spans, {}, {})
  assert(not p.refuse, tostring(p.refuse))
  assert(math.abs(p.rate - 1.0) < 1e-9)
  assert(#p.dropped_rate == 0)
end)

test("an empty clump refuses without indexing nil", function()
  local p = vo.PlanReCut({}, {}, {}, {})
  assert(p.refuse, "an empty clump must refuse")
end)

print("\nClumpsSharingALine:")

test("two items claiming one line is a split line", function()
  local a = info(1, 10.0, 1.0, 100.0); a.name = "line_a"
  local b = info(2, 11.0, 1.0, 101.0); b.name = "line_a"
  assert(#vo.ClumpsSharingALine({ { a, b } }) == 1)
end)

test("two items that are two different lines is a normal cut", function()
  -- Exactly what a correct cut leaves behind: markers abut, so the items do.
  local a = info(1, 10.0, 1.0, 100.0); a.name = "line_a"
  local b = info(2, 11.0, 1.0, 101.0); b.name = "line_b"
  assert(#vo.ClumpsSharingALine({ { a, b } }) == 0,
         "a healthy cut must not be reported as a clump")
end)

test("a clump of one is never a split line", function()
  local a = info(1, 10.0, 1.0, 100.0); a.name = "line_a"
  assert(#vo.ClumpsSharingALine({ { a } }) == 0)
end)

test("blank names do not match each other", function()
  local a = info(1, 10.0, 1.0, 100.0); a.name = ""
  local b = info(2, 11.0, 1.0, 101.0); b.name = ""
  assert(#vo.ClumpsSharingALine({ { a, b } }) == 0,
         "two undecided items are not evidence of a split line")
end)

test("the observed Grumbar clump is a split line", function()
  -- Both items were named DBP_Grumbar_Grumbar_IBreakOar.
  local a = info(1, 1254.510, 0.595, 1254.510)
  local b = info(2, 1255.105, 1.125, 1255.105)
  a.name, b.name = "DBP_Grumbar_Grumbar_IBreakOar", "DBP_Grumbar_Grumbar_IBreakOar"
  assert(#vo.ClumpsSharingALine({ { a, b } }) == 1)
end)

test("three items, only two sharing, still reports the clump once", function()
  local a = info(1, 10.0, 1.0, 100.0); a.name = "line_a"
  local b = info(2, 11.0, 1.0, 101.0); b.name = "line_b"
  local c = info(3, 12.0, 1.0, 102.0); c.name = "line_a"
  assert(#vo.ClumpsSharingALine({ { a, b, c } }) == 1)
end)

print("\nConfig:")

test("recut_ignore_rate is in the schema and defaults to false", function()
  local found
  for _, f in ipairs(vo.CONFIG_SCHEMA) do
    if f.key == "recut_ignore_rate" then found = f end
  end
  assert(found, "recut_ignore_rate is not in vo.CONFIG_SCHEMA")
  assert(found.kind == "bool", "kind: " .. tostring(found.kind))
  assert(found.default == false, "default: " .. tostring(found.default))
end)

print(string.format("\n%d passed, %d failed\n", passed, failed))
os.exit(failed > 0 and 1 or 0)
