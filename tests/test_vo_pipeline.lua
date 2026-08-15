-- Unit tests for vo.PipelineStages: six honest meters from existing counters.
-- Run with: lua tests/test_vo_pipeline.lua (from the repository root)

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

print("\n=== ajsfx_vo.lua Pipeline Stages Unit Tests ===\n")

print("PipelineStages:")

local function stage(stages, id)
  for _, s in ipairs(stages) do
    if s.id == id then return s end
  end
end

test("always six stages in pipeline order", function()
  local st = vo.PipelineStages({})
  assert(#st == 6, "expected 6 stages, got " .. #st)
  local want = { "sources", "matched", "cut", "decided", "verified", "delivered" }
  for i, id in ipairs(want) do
    assert(st[i].id == id, ("slot %d: expected %s, got %s"):format(i, id, st[i].id))
  end
end)

test("nil input builds all-todo stages", function()
  local st = vo.PipelineStages(nil)
  assert(#st == 6, "nil input errored or short")
  assert(st[1].state == "todo", "expected todo, got " .. st[1].state)
end)

test("complete stage renders a check", function()
  local m = stage(vo.PipelineStages({ matched_done = 5, matched_total = 5 }), "matched")
  assert(m.state == "done", "expected done, got " .. m.state)
  assert(m.text == "Matched \226\156\147", "expected check text, got " .. m.text)
end)

test("partial stage renders n/m", function()
  local d = stage(vo.PipelineStages({ decided_done = 180, decided_total = 195 }), "decided")
  assert(d.state == "partial", "expected partial, got " .. d.state)
  assert(d.text == "Decided 180/195", "got " .. d.text)
end)

test("verified formats as percent", function()
  local v = stage(vo.PipelineStages({ verified_done = 61, verified_total = 100 }), "verified")
  assert(v.text == "Verified 61%", "got " .. v.text)
  assert(v.state == "partial", "expected partial, got " .. v.state)
end)

test("empty stage is a dash", function()
  local d = stage(vo.PipelineStages({}), "delivered")
  assert(d.state == "todo", "expected todo, got " .. d.state)
  assert(d.text == "Delivered \226\128\148", "got " .. d.text)
end)

test("running sources override counts", function()
  local s = stage(vo.PipelineStages({ sources_done = 2, sources_total = 6,
                                      sources_running = true }), "sources")
  assert(s.state == "running", "expected running, got " .. s.state)
  assert(s.text:find("2/6"), "running text should carry progress, got " .. s.text)
end)

test("done beats running only when not running", function()
  local s = stage(vo.PipelineStages({ sources_done = 6, sources_total = 6 }), "sources")
  assert(s.state == "done", "expected done, got " .. s.state)
end)

test("overshoot clamps to done, never n/m past total", function()
  local m = stage(vo.PipelineStages({ matched_done = 7, matched_total = 5 }), "matched")
  assert(m.state == "done", "7 of 5 should read done, got " .. m.state)
end)

test("counts pass through on the stage record", function()
  local d = stage(vo.PipelineStages({ decided_done = 3, decided_total = 9 }), "decided")
  assert(d.done == 3 and d.total == 9, "done/total not carried")
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
