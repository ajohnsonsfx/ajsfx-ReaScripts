# VO "Re-cut selected takes" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a VO Overview verb that returns a clump of over-split items to being a
recording, then re-runs the existing match-and-cut over it so the line is re-derived
with proper cuts and one marker each.

**Architecture:** Two pure planners in `VO/lib/ajsfx_vo.lua` (`vo.ClusterClumps`,
`vo.PlanReCut`) decide everything and write nothing. One applier, `Trim.recut(opts)`
in `VO/ajsfx_VO_Overview.lua`, executes the plan inside a single `core.Transaction`:
native heal (40548) → resize to the reclaim window → strip markers → `MatchTakes` →
`Trim.cut_from_markers`. No new matcher, no new cutter, no render.

**Tech Stack:** Lua 5.x, REAPER API, ReaImGui, `tests/mock_reaper.lua`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-14-vo-recut-clumps-design.md`. Read it first.
- **No new top-level `local` in `ajsfx_VO_Overview.lua`.** The main chunk sits at Lua's
  200-local ceiling and a new file local is a LOAD-time error. All new Overview
  functions go on the existing `Trim` table (declared at `VO/ajsfx_VO_Overview.lua:1391`)
  — the pattern the file already uses for exactly this reason.
  - **Spec deviation, deliberate:** the spec §5 says "one new top-level local
    `ReCutTakes(opts)`". Using `Trim.recut` instead is strictly safer and matches
    `Trim.cut_from_markers` / `Trim.update` / `Trim.extras`. Same behaviour, zero
    local-budget cost.
- **`luac -p VO/ajsfx_VO_Overview.lua` must pass** before any commit touching that file.
  The test suite never loads the Overview chunk, so a local-limit break shows up as a
  green suite and a script that will not start.
- Run the whole suite with `./run_tests.sh`. Every test file is standalone Lua.
- Tolerance for all time comparisons: `1e-3` seconds (1ms), named `tol`.
- Time units: `pos` and `length` are PROJECT seconds; `start_offs`, `start`, `stop`,
  `from`, `to` are SOURCE seconds. Source extent of an item is
  `start_offs + length * playrate`.
- Never write `mk.asset` outside a verb that is claiming line membership
  (`vo-marker-names-the-line`). This verb deletes markers and lets `MatchTakes`
  write the new ones; it never edits an asset in place.
- `@version` / `@changelog` in the Overview header get bumped in the final task, not
  per-task. Merging is not releasing; only a changed `@version` publishes.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `VO/lib/ajsfx_vo.lua` | Pure planners `vo.ClusterClumps`, `vo.PlanReCut`; new config field `recut_ignore_rate` | Modify |
| `tests/test_vo_recut.lua` | Unit tests for both planners | Create |
| `VO/ajsfx_VO_Overview.lua` | `Trim.recut_items`, `Trim.recut`, the button + tip, the `MatchTakes` clump pre-check | Modify |
| `VO/ajsfx_VO_Settings.lua` | Checkbox for `recut_ignore_rate` | Modify |
| `VO/SPEC-recut-clumps.md` | Spec copy alongside the other VO specs | Create |

---

### Task 1: `vo.ClusterClumps`

Groups a flat list of item infos into clumps of items that abut in **both** project
time and source time — the test that proves a run of items is one continuous stretch
of recording that was split, rather than a deliberate assembly.

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (add beside `vo.SourceCoverageRanges`, ~line 5701)
- Test: `tests/test_vo_recut.lua` (create)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  ```
  vo.ClusterClumps(items, tol) -> clumps
    items : array of info tables, each { item, pos, length, start_offs,
            playrate, path, track, locked }. `item` and `track` are opaque
            handles compared by identity only; the planner never calls REAPER.
            Order is not assumed — the function sorts its own copy by pos.
    tol   : seconds, default 1e-3
    clumps: array of arrays of the SAME info tables, each inner array ordered
            by pos. Every input info appears in exactly one clump. A lone item
            is a clump of one.
  ```

- [ ] **Step 1: Write the failing test file**

Create `tests/test_vo_recut.lua`:

```lua
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
```

- [ ] **Step 2: Run it and confirm it fails**

```bash
./run_tests.sh 2>&1 | grep -A2 "test_vo_recut"
```

Expected: `FAIL` on every `ClusterClumps` test with "attempt to call a nil value (field 'ClusterClumps')".

- [ ] **Step 3: Implement `vo.ClusterClumps`**

Insert into `VO/lib/ajsfx_vo.lua` immediately after `vo.SourceCoverageRanges` (which
ends at line 5701), before the `vo.WordsHash` comment block:

```lua
-- Group items into CLUMPS: runs that abut in project time AND source time, and
-- so are one continuous stretch of the recording that got split.
--
-- Requiring BOTH is the whole safety of the re-cut. Two items that merely touch
-- on the timeline but come from different parts of the file are a deliberate
-- assembly -- healing them would splice unrelated audio into one clip and call
-- it a take. Two items from adjacent source that sit apart on the timeline were
-- moved there on purpose. Only a run that matches on both axes was one clip.
--
-- Mixed playrates still cluster: the source test uses each item's own rate, so
-- the arithmetic is right either way. Whether a mixed-rate clump may be HEALED
-- is vo.PlanReCut's decision, not this one -- clustering answers "was this one
-- clip?", not "may I touch it?".
--
-- A lone item is a clump of one. That is not a special case to filter out: an
-- item with one misplaced marker is the degenerate form of the same problem,
-- and re-cutting it is meaningful.
function vo.ClusterClumps(items, tol)
  tol = tol or 1e-3
  local sorted = {}
  for _, info in ipairs(items or {}) do sorted[#sorted + 1] = info end
  table.sort(sorted, function(a, b) return (a.pos or 0) < (b.pos or 0) end)

  local clumps, current = {}, nil
  for _, info in ipairs(sorted) do
    local joins = false
    if current then
      local prev = current[#current]
      local same = prev.track == info.track and prev.path == info.path
      if same then
        local p_end = (prev.pos or 0) + (prev.length or 0)
        local s_end = (prev.start_offs or 0)
                    + (prev.length or 0) * safe_playrate(prev)
        joins = math.abs(p_end - (info.pos or 0)) <= tol
            and math.abs(s_end - (info.start_offs or 0)) <= tol
      end
    end
    if joins then
      current[#current + 1] = info
    else
      current = { info }
      clumps[#clumps + 1] = current
    end
  end
  return clumps
end
```

`safe_playrate` is the existing file-local helper used by `vo.SourceCoverageRanges`;
it is in scope at this insertion point.

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
./run_tests.sh
```

Expected: `test_vo_recut.lua` prints 11 passed, 0 failed, and every other test file is
unchanged and passing.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo_recut.lua && git commit -m "VO: cluster selected items into clumps that abut in project and source time"
```

---

### Task 2: `vo.PlanReCut`

Decides, for one clump, whether to re-cut it and over what window. Writes nothing.

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (immediately after `vo.ClusterClumps`)
- Test: `tests/test_vo_recut.lua` (append)

**Interfaces:**
- Consumes: `vo.ClusterClumps` (Task 1) produces the `clump` argument.
- Produces:
  ```
  vo.PlanReCut(clump, spans, neighbours, opts) -> plan
    clump      : one clump from vo.ClusterClumps -- array of info tables,
                 ordered by pos, at least one entry.
    spans      : array of match spans for ANY source, each
                 { source_path, start, stop } in SOURCE seconds. Spans whose
                 source_path differs from the clump's are ignored here rather
                 than by the caller, so a caller cannot forget to filter.
    neighbours : array of info tables for items NOT in the clump, any track.
                 Only same-track, same-path entries bound the window.
    opts       : { ignore_rate = bool, tol = number, min_overlap = number }
                 min_overlap defaults to 1e-3 -- a span must share more than
                 this many seconds with the coverage to count as intersecting,
                 so a span merely touching the edge cannot drag the window.

    plan = {
      refuse       = string or nil,  -- human-readable reason; nil means go
      window       = { from = number, to = number } or nil,  -- SOURCE seconds
      grew         = bool,           -- window is wider than the coverage
      rate         = number,         -- playrate the survivor takes
      pitch        = number,         -- pitch the survivor takes
      dropped_rate = { { playrate, pitch }, ... },  -- discarded, ignore_rate only
      items        = clump,          -- passed straight through
    }
  ```
  A plan with `refuse` set has `window = nil` and must not be applied.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo_recut.lua`, immediately before the final `print`/`os.exit`:

```lua
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
```

- [ ] **Step 2: Run and confirm the new tests fail**

```bash
./run_tests.sh 2>&1 | grep "PlanReCut" -A20
```

Expected: 13 FAILs, "attempt to call a nil value (field 'PlanReCut')". The 11
`ClusterClumps` tests still pass.

- [ ] **Step 3: Implement `vo.PlanReCut`**

Insert into `VO/lib/ajsfx_vo.lua` immediately after `vo.ClusterClumps`:

```lua
-- Decide whether a clump may be re-cut, and over what SOURCE window.
--
-- The window starts as the clump's own source coverage -- the same question
-- vo.ResolveSourceSpanForCut asks when it resolves a span to its item, so
-- scope and resolution cannot disagree (vo-rows-are-not-spans). It then grows
-- to swallow any matched span it only PARTLY holds, because a line straddling
-- the clump's edge cannot be re-derived from half of itself, and stopping
-- short only re-earns the PARTIAL complaint on the next pass.
--
-- Growth is bounded by the nearest item that is not in the clump, on the same
-- track and source. Re-cut may reclaim audio no item covers; it may never eat
-- a neighbour.
--
-- It decides and returns. Nothing here touches REAPER, and a plan carrying
-- `refuse` has no window at all -- an applier that ignores the refusal has
-- nothing to apply.
function vo.PlanReCut(clump, spans, neighbours, opts)
  opts = opts or {}
  local tol = opts.tol or 1e-3
  local min_overlap = opts.min_overlap or 1e-3
  local plan = { items = clump, rate = 1.0, pitch = 0, dropped_rate = {},
                 grew = false }

  if not clump or #clump == 0 then
    plan.refuse = "empty clump"
    return plan
  end

  for _, info in ipairs(clump) do
    if info.locked then
      plan.refuse = "an item in the clump is locked"
      return plan
    end
  end

  -- The survivor's rate and pitch: the longest item's, so the majority of the
  -- audio keeps sounding as it did.
  local longest = clump[1]
  for _, info in ipairs(clump) do
    if (info.length or 0) > (longest.length or 0) then longest = info end
  end
  plan.rate  = safe_playrate(longest)
  plan.pitch = longest.pitch or 0

  local mixed_rate, mixed_pitch = false, false
  for _, info in ipairs(clump) do
    if math.abs(safe_playrate(info) - plan.rate) > 1e-6 then mixed_rate = true end
    if math.abs((info.pitch or 0) - plan.pitch) > 1e-6 then mixed_pitch = true end
  end

  if mixed_rate or mixed_pitch then
    if not opts.ignore_rate then
      plan.refuse = mixed_rate
        and "items in the clump have different playrates"
        or  "items in the clump have different pitch"
      return plan
    end
    for _, info in ipairs(clump) do
      local rate, pitch = safe_playrate(info), info.pitch or 0
      if math.abs(rate - plan.rate) > 1e-6
      or math.abs(pitch - plan.pitch) > 1e-6 then
        plan.dropped_rate[#plan.dropped_rate + 1] =
          { playrate = rate, pitch = pitch }
      end
    end
  end

  -- Coverage: the union of the clump's source ranges. The clump abuts by
  -- construction, so first-from to last-to is the union.
  local ranges = vo.SourceCoverageRanges(clump)
  local from, to = ranges[1].from, ranges[1].to
  for _, rg in ipairs(ranges) do
    if rg.from < from then from = rg.from end
    if rg.to   > to   then to   = rg.to   end
  end
  local cov_from, cov_to = from, to

  local path = clump[1].path
  local touched = 0
  for _, s in ipairs(spans or {}) do
    if s.source_path == path then
      local overlap = math.min(s.stop or 0, cov_to) - math.max(s.start or 0, cov_from)
      if overlap > min_overlap then
        touched = touched + 1
        if (s.start or 0) < from then from = s.start end
        if (s.stop  or 0) > to   then to   = s.stop  end
      end
    end
  end

  if touched == 0 then
    plan.refuse = "no match span covers this clump"
    return plan
  end

  -- Clamp to the nearest neighbour on the same track and source. A neighbour
  -- ENTIRELY inside the grown window would otherwise be silently overrun, so
  -- the bound is taken from any neighbour lying on the correct side of the
  -- coverage, not merely of the window.
  for _, nb in ipairs(neighbours or {}) do
    if nb.track == clump[1].track and nb.path == path then
      local nb_from = nb.start_offs or 0
      local nb_to   = nb_from + (nb.length or 0) * safe_playrate(nb)
      if nb_to <= cov_from + tol and nb_to > from then from = nb_to end
      if nb_from >= cov_to - tol and nb_from < to then to = nb_from end
    end
  end

  if to - from <= tol then
    plan.refuse = "the reclaim window collapsed to nothing"
    return plan
  end

  plan.window = { from = from, to = to }
  plan.grew = (from < cov_from - tol) or (to > cov_to + tol)
  return plan
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
./run_tests.sh
```

Expected: `test_vo_recut.lua` prints 24 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo_recut.lua && git commit -m "VO: plan the re-cut window for a clump, bounded by its neighbours"
```

---

### Task 3: The `recut_ignore_rate` setting

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — `vo.CONFIG_SCHEMA` (~line 7760, after `trim_tail_slack`)
- Modify: `VO/ajsfx_VO_Settings.lua` — the checkbox
- Test: `tests/test_vo_recut.lua` (append)

**Interfaces:**
- Consumes: `vo.PlanReCut`'s `opts.ignore_rate` (Task 2).
- Produces: `vo.LoadConfig().recut_ignore_rate` — boolean, default `false`.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_vo_recut.lua`, before the final `print`/`os.exit`:

```lua
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
```

- [ ] **Step 2: Run and confirm it fails**

```bash
./run_tests.sh 2>&1 | grep "recut_ignore_rate"
```

Expected: `FAIL: recut_ignore_rate is in the schema and defaults to false - ... recut_ignore_rate is not in vo.CONFIG_SCHEMA`.

- [ ] **Step 3: Add the schema field**

In `VO/lib/ajsfx_vo.lua`, in `vo.CONFIG_SCHEMA`, immediately after the
`trim_tail_slack` line:

```lua
  -- Re-cut refuses a clump whose items disagree about playrate or pitch,
  -- because healing them collapses two different readings of the audio into
  -- one and the result is a lie about what was recorded. This lets the user
  -- say "do it anyway" -- the survivor takes the longest item's rate, and a
  -- REVIEW note records what was dropped, so the override is never silent.
  { key = "recut_ignore_rate", kind = "bool",   default = false },
```

- [ ] **Step 4: Add the Settings checkbox**

Open `VO/ajsfx_VO_Settings.lua`, find the group of boundary/trim checkboxes, and add
alongside them, following whatever `Bool`/`Checkbox` helper that file already uses for
`snap_boundaries`:

```lua
Bool("recut_ignore_rate", "Ignore item pitch/playrate when re-cutting",
     "Re-cut selected takes normally refuses a clump whose items have\n" ..
     "different playrates or pitch: healing them would change how the\n" ..
     "audio sounds. With this on it proceeds anyway -- the surviving\n" ..
     "clip takes the LONGEST item's rate and pitch, and a REVIEW note\n" ..
     "marker records what was dropped.")
```

Match the exact helper name and argument order used by the neighbouring
`snap_boundaries` entry in that file; do not invent a new helper.

- [ ] **Step 5: Run the tests and confirm they pass**

```bash
./run_tests.sh && luac -p VO/ajsfx_VO_Settings.lua && echo "SETTINGS COMPILES"
```

Expected: 25 passed, 0 failed, and `SETTINGS COMPILES`.

- [ ] **Step 6: Commit**

```bash
git add VO/lib/ajsfx_vo.lua VO/ajsfx_VO_Settings.lua tests/test_vo_recut.lua && git commit -m "VO: add the recut_ignore_rate setting"
```

---

### Task 4: `Trim.recut` — the applier and the button

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — add `Trim.recut_items` and `Trim.recut` after
  `Trim.cut_from_markers` (ends ~line 6427); add the button in the Edit row beside
  "Cut from markers" (~line 11904)

**Interfaces:**
- Consumes: `vo.ClusterClumps`, `vo.PlanReCut`, `vo.LoadConfig().recut_ignore_rate`,
  and the existing `Trim.scope()`, `Trim.bare`, `Trim.cut_from_markers`, `MatchTakes`,
  `Reload`, `state`, `core.Transaction`, `vo.PlanTrimToRange`, `vo.WriteTakeMarkers`,
  `vo.WriteNoteMarker`.
- Produces:
  ```
  Trim.recut_items() -> infos
    Reads the REAPER selection into the info shape vo.ClusterClumps needs,
    WITHOUT the playrate skip that vo.CollectSourceSpans applies -- a
    non-unity-rate item must reach vo.PlanReCut so the refusal (or the
    recut_ignore_rate override) can be reported, rather than vanishing
    upstream. Fields: item, pos, length, start_offs, playrate, pitch, path,
    track, locked.

  Trim.recut(opts) -> nil
    opts.no_transaction  the caller owns the undo block
    opts.no_reload       the caller has already reloaded
    Writes state.message / state.message_kind and state.cut_result.
  ```

- [ ] **Step 1: Add `Trim.recut_items`**

Insert after `Trim.cut_from_markers` in `VO/ajsfx_VO_Overview.lua`:

```lua
-- The selection, in the shape vo.ClusterClumps wants.
--
-- Deliberately NOT vo.CollectSourceSpans: that skips any item whose playrate
-- is not 1.0, and a skipped info carries no length or offset at all -- so a
-- stretched clump would not merely refuse, it would be invisible, and the
-- report would say "nothing selected" about two items plainly on screen. The
-- rate question belongs to vo.PlanReCut, which can refuse it OR honour the
-- user's override; it cannot do either if the item never arrives.
function Trim.recut_items()
  local out = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local item = r.GetSelectedMediaItem(0, i)
    local take = item and r.GetActiveTake(item)
    if take and not r.TakeIsMIDI(take) then
      local source = r.GetMediaItemTake_Source(take)
      local path   = source and r.GetMediaSourceFileName(source, "") or ""
      if path ~= "" then
        out[#out + 1] = {
          item       = item,
          pos        = r.GetMediaItemInfo_Value(item, "D_POSITION"),
          length     = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
          start_offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
          playrate   = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
          pitch      = r.GetMediaItemTakeInfo_Value(take, "D_PITCH"),
          path       = path,
          track      = r.GetMediaItem_Track(item),
          locked     = r.GetMediaItemInfo_Value(item, "C_LOCK") >= 1,
        }
      end
    end
  end
  table.sort(out, function(a, b) return (a.pos or 0) < (b.pos or 0) end)
  return out
end
```

- [ ] **Step 2: Add `Trim.recut`**

Insert immediately after `Trim.recut_items`:

```lua
-- "Re-cut selected takes": un-split a clump so the cut can run again.
--
-- The verb owns no matcher and no cutter. It puts the audio back into the one
-- state the existing pipeline already knows how to process -- A RECORDING --
-- and then presses the existing buttons at it. Everything here is undo-able as
-- ONE press, which matters more than usual: this is the verb that throws away
-- markers, and a user who does not like the result must get the old ones back
-- with one Ctrl+Z.
--
-- Order is not negotiable:
--   1. heal    -- native 40548, no render, requires the abutment ClusterClumps
--                 already proved
--   2. resize  -- reveal the reclaimed source; still no render
--   3. strip   -- WHY it works. MatchTakes UPDATES rather than re-marks, so a
--                 surviving wrong marker would be kept and re-measured, and the
--                 re-cut would faithfully reproduce the bad cut.
--   4. match   -- the item is a recording again; mark every read in it
--   5. cut     -- split at those markers
function Trim.recut(opts)
  opts = opts or {}
  if not opts.no_reload then Reload() end
  local cfg = vo.LoadConfig()
  local picked = Trim.recut_items()

  if #picked == 0 then
    state.message = "Re-cut needs a selection: select the split clips first."
    state.message_kind = "error"
    return
  end

  local clumps = vo.ClusterClumps(picked)
  local in_clump = {}
  for _, clump in ipairs(clumps) do
    for _, info in ipairs(clump) do in_clump[info.item] = true end
  end
  local neighbours = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local item = r.GetMediaItem(0, i)
    if not in_clump[item] then
      local take = r.GetActiveTake(item)
      local source = take and not r.TakeIsMIDI(take)
                     and r.GetMediaItemTake_Source(take) or nil
      if source then
        neighbours[#neighbours + 1] = {
          item       = item,
          length     = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
          start_offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
          playrate   = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
          path       = r.GetMediaSourceFileName(source, ""),
          track      = r.GetMediaItem_Track(item),
        }
      end
    end
  end

  local spans = state.spans or {}
  local plans, refusals = {}, {}
  for _, clump in ipairs(clumps) do
    local plan = vo.PlanReCut(clump, spans, neighbours,
                              { ignore_rate = cfg.recut_ignore_rate })
    if plan.refuse then
      refusals[#refusals + 1] = plan.refuse
    else
      plans[#plans + 1] = plan
    end
  end

  if #plans == 0 then
    state.message = (#refusals > 0)
      and ("Nothing re-cut: " .. table.concat(refusals, "; ") .. ".")
      or  "Nothing re-cut: the selection holds no clump to heal."
    state.message_kind = "error"
    state.cut_result, state.cut_result_kind = state.message, "error"
    return
  end

  local healed, grown, noted = 0, 0, 0
  ;(opts.no_transaction and Trim.bare or core.Transaction)(
      "VO Overview: re-cut selected takes", function()
    for _, plan in ipairs(plans) do
      -- 1. HEAL. Select exactly this clump, nothing else: 40548 works on the
      -- selection, and a stray item left selected from the last press would be
      -- healed into a neighbour without a word.
      r.Main_OnCommand(40289, 0)  -- Item: Unselect all items
      for _, info in ipairs(plan.items) do
        r.SetMediaItemSelected(info.item, true)
      end
      if #plan.items > 1 then
        r.Main_OnCommand(40548, 0)  -- Item: Heal splits in items
        healed = healed + 1
      end

      -- The survivor is whatever is selected now. Heal leaves one item; with a
      -- clump of one, that is the item we started from.
      local survivor = r.GetSelectedMediaItem(0, 0) or plan.items[1].item
      local take = r.GetActiveTake(survivor)

      -- 2. RESIZE to the reclaim window. vo.PlanTrimToRange does the source ->
      -- project arithmetic; it is the same helper the trim path uses, so the
      -- two cannot round differently.
      if take then
        r.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", plan.rate)
        r.SetMediaItemTakeInfo_Value(take, "D_PITCH", plan.pitch)
        local geom = vo.PlanTrimToRange({
          pos = r.GetMediaItemInfo_Value(survivor, "D_POSITION"),
          start_offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
          playrate = plan.rate,
        }, plan.window.from, plan.window.to)
        if geom then
          r.SetMediaItemInfo_Value(survivor, "D_POSITION", geom.pos)
          r.SetMediaItemInfo_Value(survivor, "D_LENGTH", geom.length)
          r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", geom.start_offs)
          if plan.grew then grown = grown + 1 end
        end
      end

      -- 3. STRIP every tool marker. vo.WriteTakeMarkers with an empty list
      -- removes the tool's own lines and preserves any marker the user placed
      -- by hand -- the tool never deletes what it did not write.
      vo.WriteTakeMarkers(survivor, {})

      -- The override is loud or it is not honest.
      if #plan.dropped_rate > 0 then
        local bits = {}
        for _, d in ipairs(plan.dropped_rate) do
          bits[#bits + 1] = string.format("playrate %.3f / pitch %+d",
                                          d.playrate, math.floor(d.pitch))
        end
        vo.WriteNoteMarker(survivor,
          r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"), os.date("%Y-%m-%d %H:%M"),
          string.format("RATE: re-cut dropped %s from %d item(s).",
                        table.concat(bits, ", "), #plan.dropped_rate))
        noted = noted + 1
      end
    end

    -- 4 and 5. The healed recordings are still the selection. Hand them to the
    -- existing pipeline unchanged: match marks every read in them, cut splits
    -- at those markers. No reload between -- both take no_reload only when the
    -- caller has already looked, and here the geometry just changed underneath.
    MatchTakes({ mark = true })
    Trim.cut_from_markers({ no_transaction = true, quiet = true })
  end)

  local parts = { string.format("Re-cut %d clump(s); healed %d split(s).",
                                #plans, healed) }
  if grown > 0 then
    parts[#parts + 1] = string.format(
      "%d reclaimed source a matched line ran into.", grown)
  end
  if noted > 0 then
    parts[#parts + 1] = string.format(
      "%d carry a REVIEW note about dropped rate/pitch.", noted)
  end
  if #refusals > 0 then
    parts[#parts + 1] = string.format("%d clump(s) refused: %s.",
                                      #refusals, table.concat(refusals, "; "))
  end
  state.message = table.concat(parts, " ")
  state.message_kind = (#refusals > 0) and "warn" or "ok"
  state.cut_result, state.cut_result_kind = state.message, state.message_kind
end
```

**Note on `state.spans`:** verify the field name that holds the current match spans by
running `grep -n "state\.spans\|state\.match" VO/ajsfx_VO_Overview.lua | head`. If the
spans live under a different key (e.g. `state.match.spans`), use that instead — the
requirement is only that they are the SAME spans `CutCandidates` reads, so scope and
resolution cannot disagree.

- [ ] **Step 3: Add the button**

In `VO/ajsfx_VO_Overview.lua`, in the Edit row immediately after the "Cut from markers"
button and its `Tip(...)` block (~line 11904):

```lua
      if im.Button(ctx, "Re-cut selected takes") then
        pending_action = function()
          local ok, err = pcall(Trim.recut)
          if not ok then
            state.message = "Re-cut failed: " .. tostring(err)
            state.message_kind = "error"
            r.ShowConsoleMsg("ajsfx VO — Re-cut FAILED\n" .. tostring(err) .. "\n\n")
          end
        end
      end
      Tip("ONE line arrived as several clips. Put it back together and cut it\n" ..
          "again, properly.\n\n" ..
          "It looks for CLUMPS: runs of selected clips that touch on the\n" ..
          "timeline AND come from touching parts of the recording -- which is\n" ..
          "what a clip that was split looks like, and what a clip you\n" ..
          "assembled from two places does not.\n\n" ..
          "For each clump, in one press:\n\n" ..
          "  1. heal the splits back into one clip (no render -- the audio is\n" ..
          "     never re-written),\n" ..
          "  2. grow it outward if a matched line only PARTLY fits inside it,\n" ..
          "     stopping at the next clip on the track,\n" ..
          "  3. throw its take markers away,\n" ..
          "  4. match, and 5. cut -- exactly the two buttons above.\n\n" ..
          "The markers go because \"Match takes to script\" UPDATES rather\n" ..
          "than re-marks: a wrong marker left in place would be kept, and the\n" ..
          "re-cut would faithfully rebuild the bad cut.\n\n" ..
          "It REFUSES a clump whose clips disagree about playrate or pitch --\n" ..
          "healing those changes how the audio sounds. Settings has an\n" ..
          "override; it leaves a REVIEW note when used.\n\n" ..
          "One Ctrl+Z puts everything back." .. NEEDS_SEL)
```

- [ ] **Step 4: Verify it compiles and the suite is still green**

```bash
luac -p VO/ajsfx_VO_Overview.lua && echo "OVERVIEW COMPILES" && ./run_tests.sh
```

Expected: `OVERVIEW COMPILES` and every test file passing. A failure here reading
`main function has more than 200 local variables` means something was added as a file
local instead of onto `Trim`.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua && git commit -m "VO: Re-cut selected takes heals a clump and re-runs match and cut over it"
```

---

### Task 5: The `Match takes to script` clump pre-check

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — `MatchTakes` (starts line 7385)

**Interfaces:**
- Consumes: `vo.ClusterClumps` (Task 1), `Trim.recut_items` (Task 4).
- Produces: nothing new; appends one line to `MatchTakes`'s existing report.

- [ ] **Step 1: Add the pre-check**

In `MatchTakes`, immediately after the `local conflicts = vo.SelectConflicts(state.overview)`
line and before `local bits = { ... }`, add:

```lua
  -- A clump is not this verb's to fix -- it reports and points at the button.
  -- Re-cutting from the catch-all would throw markers away on a press the user
  -- made for a different reason, and a clump they split deliberately is not a
  -- bug the sheet gets to overrule.
  local split_clumps = 0
  for _, clump in ipairs(vo.ClusterClumps(Trim.recut_items())) do
    if #clump > 1 then split_clumps = split_clumps + 1 end
  end
```

Then, immediately after the existing `if #conflicts > 0 then ... end` block that appends
to `bits`, add:

```lua
  if split_clumps > 0 then
    bits[#bits + 1] = string.format(
      "%d clump(s) of split clips found -- press \"Re-cut selected takes\"",
      split_clumps)
  end
```

**Ordering note:** `MatchTakes` is defined at line 7385 and `Trim.recut_items` in Task 4
is defined around line 6430 — earlier in the file, so the call resolves. `Trim` is a
table looked up at call time regardless, so ordering cannot break this.

- [ ] **Step 2: Verify it compiles and the suite is green**

```bash
luac -p VO/ajsfx_VO_Overview.lua && echo "OVERVIEW COMPILES" && ./run_tests.sh
```

Expected: `OVERVIEW COMPILES`, all tests passing.

- [ ] **Step 3: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua && git commit -m "VO: Match takes to script reports clumps instead of silently re-cutting them"
```

---

### Task 6: Spec copy, version bump, and live verification

**Files:**
- Create: `VO/SPEC-recut-clumps.md`
- Modify: `VO/ajsfx_VO_Overview.lua` — `@version` and `@changelog` in the header

- [ ] **Step 1: Put the spec where the other VO specs live**

```bash
cp docs/superpowers/specs/2026-08-14-vo-recut-clumps-design.md VO/SPEC-recut-clumps.md
```

Then change its `**Status:**` line from `Designed, not implemented` to
`Implemented 2026-08-14`, and add a line under §5 recording the `Trim.recut`
deviation from "one new top-level local".

- [ ] **Step 2: Bump the version and changelog**

In `VO/ajsfx_VO_Overview.lua`'s header, raise `@version` to the next beta
(read the current value first — do not assume) and add:

```
@changelog
  + Re-cut selected takes: heal a line that arrived as several clips, reclaim
    source a matched line ran into, and re-run match and cut over it.
  + Match takes to script reports clumps of split clips.
  + Settings: ignore item pitch/playrate when re-cutting.
```

CI reads `@changelog` to populate what ReaPack shows users, and only a CHANGED
`@version` publishes anything at all.

- [ ] **Step 3: Live-verify on the Grumbar clump**

Restart the Overview so the edited code is loaded (firing the registered action while
it runs TERMINATES it; fire twice):

```bash
echo "restart the Overview via mcp_stop_overview.lua then mcp_start_overview.lua"
```

Select items at project `1254.510` and `1255.105` on track 3, then drive the headless
bridge (`vo_cmd.txt` + `mcp_vo_cmd.lua`) or press the button, and confirm with
`mcp_clump_probe.lua`:

- one item spanning source `1254.51–1258.28` becomes two;
- named `DBP_Grumbar_Grumbar_MyLeash` and `DBP_Grumbar_Grumbar_IBreakOar`;
- one ranged counting marker on each, neither overhanging its item;
- the `! 2026-08-13 13:23 PARTIAL:` note is gone;
- one Ctrl+Z restores the two-item, four-marker state exactly.

- [ ] **Step 4: Commit and confirm CI**

```bash
git add VO/SPEC-recut-clumps.md VO/ajsfx_VO_Overview.lua && git commit -m "VO: ship Re-cut selected takes" && git push
```

Then confirm the run went green — a failed run publishes nothing and says nothing:

```bash
gh run list --limit 1
```

Also skim the build log: `reapack-index` reports packaging mistakes as warnings, so the
index can build "successfully" while silently omitting a package.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §2.1 Cluster into clumps | Task 1 |
| §2.2 Reclaim window, neighbour clamp | Task 2 |
| §2.3 Heal (40548) + resize | Task 4 step 2 |
| §2.4 Strip markers | Task 4 step 2 |
| §2.5 Re-match and re-cut | Task 4 step 2 |
| §2.6 Flag the ambiguous | **Gap — see below** |
| §3 Refusals | Task 2 (locked, rate, pitch, no span); no-transcript falls out of "no match span covers this clump", since an untranscribed source produces no spans |
| §3.1 `recut_ignore_rate` | Task 3, applied in Task 2 and noted in Task 4 |
| §4 `Match takes to script` hook | Task 5 |
| §5 Code placement | Global Constraints + Task 4 (deviation recorded) |
| §6 Verification | Tasks 1–3 unit, Task 6 live |

**Gap found and closed:** §2.6 (stamp a `! REVIEW:` note when a re-cut take's
select-vs-alt role is ambiguous) has no task above. It is deliberately deferred, not
forgotten: the ambiguity is computed from the sheet AFTER the cut has produced its
items, and `vo.PlanPull` already counts `ambiguous` for exactly this condition. Folding
it in blind would mean guessing at that integration. **Task 7 below covers it**, and it
is the one task to skip if the live run in Task 6 shows the cut already resolves roles
cleanly.

**Placeholder scan:** no TBDs; every code step carries the actual code. Two steps ask
the implementer to VERIFY a name against the file (`state.spans` in Task 4, the
`Bool` helper in Task 3) rather than guess — those are checks with a stated fallback,
not placeholders.

**Type consistency:** `vo.ClusterClumps` returns arrays of the same info tables it was
given; `vo.PlanReCut` consumes one such array as `clump` and passes it back as
`plan.items`. Field names `pos / length / start_offs / playrate / pitch / path / track /
locked` are identical in the test helper, the planner, and `Trim.recut_items`.

---

### Task 7: `! REVIEW:` note for ambiguous select-vs-alt

Run this only if Task 6's live verification shows a re-cut take whose role is genuinely
undecided.

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — end of `Trim.recut`

**Interfaces:**
- Consumes: `vo.PlanPull(items, state.lines, marks)`, whose second return value already
  carries `.ambiguous` — the count of name clashes, used today by the Pull panel at
  `VO/ajsfx_VO_Overview.lua:7729`.

- [ ] **Step 1: Reload after the cut and ask which produced takes clash**

At the end of `Trim.recut`, after the transaction closes:

```lua
  Reload()
  local items, marks = Trim.scope(), nil
  local pull = select(1, vo.PlanPull(items, state.lines, marks))
  for _, entry in ipairs(pull or {}) do
    if entry.ambiguous then
      vo.WriteNoteMarker(entry.item, entry.source_start or 0,
        os.date("%Y-%m-%d %H:%M"),
        string.format("REVIEW: %s already has a take claiming select -- " ..
                      "is this one the select, an alt, or a replacement?",
                      tostring(entry.asset)))
    end
  end
```

Check `vo.PlanPull`'s actual entry shape first (`grep -n "function vo.PlanPull" -A40
VO/lib/ajsfx_vo.lua`) and use its real field names — the flag may be named
`clash` rather than `ambiguous`.

- [ ] **Step 2: Verify it compiles, the suite is green, and re-run the live check**

```bash
luac -p VO/ajsfx_VO_Overview.lua && ./run_tests.sh
```

- [ ] **Step 3: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua && git commit -m "VO: re-cut flags a take whose select-vs-alt role is undecided"
```
