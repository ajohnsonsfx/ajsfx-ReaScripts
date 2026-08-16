-- Unit tests for vo.PlanRoleNames: the track decides the role, the base
-- still names the line.
-- Run with: lua tests/test_vo_role_names.lua (from the repository root)

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

print("\n=== ajsfx_vo.lua PlanRoleNames Unit Tests ===\n")

local CFG = { alt_append_pattern = "_alt{n}", alt_append_start = 1,
              alt_append_digits = 1 }
local KNOWN = { Foo = true, Bar = true }

local function renamed(plan, row)
  for _, rn in ipairs(plan.renames) do
    if rn.row == row then return rn.name end
  end
  return nil
end

print("PlanRoleNames:")

test("agreeing names plan nothing", function()
  local rows = {
    { name = "Foo",      track_name = "Selects" },
    { name = "Foo_alt1", track_name = "Alts" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(#plan.renames == 0, "expected no renames, got " .. #plan.renames)
  assert(#plan.conflicts == 0, "expected no conflicts")
end)

test("alt dragged to Selects is promoted to the plain name", function()
  local rows = { { name = "Foo_alt2", track_name = "Selects" } }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[1]) == "Foo", "expected promotion to Foo")
end)

test("select dragged to Alts is demoted to a numbered alt", function()
  local rows = { { name = "Foo", track_name = "Alts" } }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[1]) == "Foo_alt1", "expected demotion to Foo_alt1")
end)

test("a full swap renames both sides in one plan", function()
  local rows = {
    { name = "Foo",      track_name = "Alts" },     -- demoted
    { name = "Foo_alt1", track_name = "Selects" },  -- promoted
    { name = "Foo_alt2", track_name = "Alts" },     -- bystander
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  -- The demoted select must not land on _alt1 (being vacated is not enough:
  -- the number is claimed by a row this plan still lists) nor _alt2 (held).
  assert(renamed(plan, rows[1]) == "Foo_alt3",
         "demoted select got " .. tostring(renamed(plan, rows[1])))
  assert(renamed(plan, rows[2]) == "Foo", "promotion missing")
  assert(renamed(plan, rows[3]) == nil, "bystander was renamed")
end)

test("plain name on Outs is renamed away like a demotion", function()
  local rows = {
    { name = "Foo",      track_name = "Outs" },
    { name = "Foo_alt1", track_name = "Alts" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[1]) == "Foo_alt2", "out kept the plain name")
end)

test("items off the role tracks are never renamed", function()
  local rows = {
    { name = "Foo",      track_name = "Review" },
    { name = "Foo_alt1", track_name = "GRUMBAR raw" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(#plan.renames == 0, "renamed an item off the role tracks")
end)

test("an untouchable row's alt number is never reassigned", function()
  local rows = {
    { name = "Foo_alt1", track_name = "Review" },  -- keeps its number
    { name = "Foo",      track_name = "Alts" },    -- demoted, must skip 1
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[2]) == "Foo_alt2",
         "demotion collided with an off-track alt number")
end)

test("duplicate alt numbers on role tracks are renumbered", function()
  local rows = {
    { name = "Foo_alt1", track_name = "Alts" },
    { name = "Foo_alt1", track_name = "Alts" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(#plan.renames == 1, "expected exactly one renumber")
  assert(plan.renames[1].row == rows[2], "renumbered the first holder")
  assert(plan.renames[1].name == "Foo_alt2", "expected Foo_alt2")
end)

test("two items on Selects is a conflict, not a guess", function()
  local rows = {
    { name = "Foo",      track_name = "Selects" },
    { name = "Foo_alt1", track_name = "Selects" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(#plan.renames == 0, "renamed inside a conflicted line")
  assert(#plan.conflicts == 1, "expected 1 conflict")
  assert(plan.conflicts[1].base == "Foo")
end)

test("promotion blocked by an off-track plain name is a conflict", function()
  local rows = {
    { name = "Foo_alt1", track_name = "Selects" },
    { name = "Foo",      track_name = "Review" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(#plan.renames == 0, "renamed despite the blocked plain name")
  assert(#plan.conflicts == 1, "expected 1 conflict")
end)

test("a base no line answers to is left entirely alone", function()
  local rows = {
    { name = "StrayThing",      track_name = "Alts" },
    { name = "StrayThing_alt1", track_name = "Selects" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(#plan.renames == 0, "renamed a name outside the session")
end)

test("nil known_bases plans nothing at all", function()
  local rows = { { name = "Foo", track_name = "Alts" } }
  local plan = vo.PlanRoleNames(rows, nil, CFG)
  assert(#plan.renames == 0 and #plan.conflicts == 0,
         "planned without a line list")
end)

test("custom track names from cfg are honoured", function()
  local cfg = { alt_append_pattern = "_alt{n}", track_selects = "Deliver",
                track_alts = "Spares", track_outs = "Bin" }
  local rows = {
    { name = "Foo_alt1", track_name = "Deliver" },
    { name = "Foo",      track_name = "Spares" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, cfg)
  assert(renamed(plan, rows[1]) == "Foo", "custom Selects name ignored")
  assert(renamed(plan, rows[2]) == "Foo_alt2", "custom Alts name ignored")
end)

test("alt digits pad the assigned number", function()
  local cfg = { alt_append_pattern = "_alt{n}", alt_append_digits = 2 }
  local rows = { { name = "Foo", track_name = "Alts" } }
  local plan = vo.PlanRoleNames(rows, KNOWN, cfg)
  assert(renamed(plan, rows[1]) == "Foo_alt01",
         "got " .. tostring(renamed(plan, rows[1])))
end)

test("two lines are planned independently", function()
  local rows = {
    { name = "Foo",      track_name = "Alts" },
    { name = "Bar_alt3", track_name = "Selects" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[1]) == "Foo_alt1")
  assert(renamed(plan, rows[2]) == "Bar")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
