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

test("plain name on Outs is renamed away, into the out namespace", function()
  local rows = {
    { name = "Foo",      track_name = "Outs" },
    { name = "Foo_alt1", track_name = "Alts" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[1]) == "Foo_out1", "out kept the plain name: "
         .. tostring(renamed(plan, rows[1])))
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

test("residue with no take marker does not reserve an alt number", function()
  -- Cut leaves named leftovers on the recording track. They carry no take
  -- marker, so they are not takes -- and a non-take must not push the line's
  -- real alt off _alt1. This was live: a session read _alt2, _alt3, _alt4
  -- with no _alt1 anywhere, every number eaten by residue.
  local rows = {
    { name = "Foo_alt1", track_name = "JOB raw", is_take = false },
    { name = "Foo",      track_name = "Alts" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[1]) == nil, "residue was renamed")
  assert(renamed(plan, rows[2]) == "Foo_alt1",
         "demotion skipped past residue, got " .. tostring(renamed(plan, rows[2])))
end)

test("residue holding the plain name does not block a promotion", function()
  local rows = {
    { name = "Foo",      track_name = "JOB raw", is_take = false },
    { name = "Foo_alt1", track_name = "Selects" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(#plan.conflicts == 0, "residue blocked a promotion")
  assert(renamed(plan, rows[2]) == "Foo", "promotion missing")
end)

test("an off-track row that IS a take still reserves its number", function()
  -- The guard still has to work: a real take parked on Review carries a
  -- marker, and handing its number to somebody else changes what a name
  -- already seen outside this project means.
  local rows = {
    { name = "Foo_alt1", track_name = "Review", is_take = true },
    { name = "Foo",      track_name = "Alts" },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[2]) == "Foo_alt2",
         "a real off-track take lost its number")
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

print("Renumber (straighten) mode:")

local RN = { renumber = true }

test("gaps close: a lone alt4 becomes alt1", function()
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_alt4", track_name = "Alts",    pos = 10 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG, RN)
  assert(renamed(plan, rows[2]) == "Foo_alt1",
         "got " .. tostring(renamed(plan, rows[2])))
end)

test("alts renumber in timeline order; outs number separately", function()
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_alt7", track_name = "Alts",    pos = 30 },
    { name = "Foo_alt2", track_name = "Alts",    pos = 10 },
    { name = "Foo_alt9", track_name = "Outs",    pos = 5 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG, RN)
  assert(renamed(plan, rows[3]) == "Foo_alt1", "earlier alt should be alt1")
  assert(renamed(plan, rows[2]) == "Foo_alt2", "later alt should be alt2")
  assert(renamed(plan, rows[4]) == "Foo_out1",
         "an out must not take an alt number: "
         .. tostring(renamed(plan, rows[4])))
end)

test("already-straight names plan zero renames (idempotent)", function()
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_alt1", track_name = "Alts",    pos = 10 },
    { name = "Foo_alt2", track_name = "Alts",    pos = 20 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG, RN)
  assert(#plan.renames == 0, "expected no renames, got " .. #plan.renames)
end)

test("a promoted select's vacated number IS reused when straightening", function()
  local rows = {
    { name = "Foo_alt1", track_name = "Selects", pos = 0 },   -- promoted
    { name = "Foo_alt2", track_name = "Alts",    pos = 10 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG, RN)
  assert(renamed(plan, rows[1]) == "Foo", "promotion missing")
  assert(renamed(plan, rows[2]) == "Foo_alt1",
         "straighten should reuse the vacated number")
end)

test("an off-track holder's number is skipped, not reassigned", function()
  local rows = {
    { name = "Foo_alt1", track_name = "Review", pos = 0 },  -- untouchable
    { name = "Foo_alt5", track_name = "Alts",   pos = 10 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG, RN)
  assert(renamed(plan, rows[2]) == "Foo_alt2",
         "must skip the untouchable alt1")
  assert(renamed(plan, rows[1]) == nil, "renamed an off-track item")
end)

test("straighten still refuses a conflicted line", function()
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_alt1", track_name = "Selects", pos = 10 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG, RN)
  assert(#plan.renames == 0 and #plan.conflicts == 1)
end)


print("\nOuts get their own suffix and their own numbers:")

test("an Outs take is named _out, not _alt", function()
  -- AJ: otherwise "we have a lot of alt files that are not delivered, and it
  -- sort of messes with the alt naming."
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_alt1", track_name = "Outs",    pos = 10 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[2]) == "Foo_out1",
         "got " .. tostring(renamed(plan, rows[2])))
end)

test("outs do not consume alt numbers", function()
  -- The whole point: the alts delivered alongside the select stay 1..N with
  -- no gaps punched in them by takes nobody ships.
  local rows = {
    { name = "Foo",  track_name = "Selects", pos = 0 },
    { name = "Foo_alt6", track_name = "Outs",    pos = 10 },
    { name = "Foo_alt7", track_name = "Alts",    pos = 20 },
    { name = "Foo_alt8", track_name = "Outs",    pos = 30 },
    { name = "Foo_alt9", track_name = "Alts",    pos = 40 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  -- The conservative pass leaves a uniquely-held alt number alone, so the
  -- two alts keep 7 and 9. What moves is the OUTS: an _alt name says
  -- nothing about the Outs track, so each is renamed into its own
  -- namespace, numbering from 1 and taking no alt number with it.
  assert(renamed(plan, rows[3]) == nil, "an alt keeping its number was renamed")
  assert(renamed(plan, rows[5]) == nil, "an alt keeping its number was renamed")
  assert(renamed(plan, rows[2]) == "Foo_out1", "first out: "
         .. tostring(renamed(plan, rows[2])))
  assert(renamed(plan, rows[4]) == "Foo_out2", "second out: "
         .. tostring(renamed(plan, rows[4])))
end)

test("straighten leaves the delivered alts 1..N with no gaps", function()
  -- The whole point, stated where it is actually true: after a straighten,
  -- the numbers a line ships read 1, 2 with nothing rejected punched out of
  -- the middle, however many outs sit beside them.
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_alt6", track_name = "Outs",    pos = 10 },
    { name = "Foo_alt7", track_name = "Alts",    pos = 20 },
    { name = "Foo_alt8", track_name = "Outs",    pos = 30 },
    { name = "Foo_alt9", track_name = "Alts",    pos = 40 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG, { renumber = true })
  assert(renamed(plan, rows[3]) == "Foo_alt1", tostring(renamed(plan, rows[3])))
  assert(renamed(plan, rows[5]) == "Foo_alt2", tostring(renamed(plan, rows[5])))
  assert(renamed(plan, rows[2]) == "Foo_out1", tostring(renamed(plan, rows[2])))
  assert(renamed(plan, rows[4]) == "Foo_out2", tostring(renamed(plan, rows[4])))
end)

test("an out already correctly named plans nothing", function()
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_out1", track_name = "Outs",    pos = 10 },
    { name = "Foo_alt1", track_name = "Alts",    pos = 20 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(#plan.renames == 0, "planned " .. #plan.renames)
end)

test("a take moved from Outs back to Alts is renamed across namespaces", function()
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_out1", track_name = "Alts",    pos = 10 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[2]) == "Foo_alt1",
         "got " .. tostring(renamed(plan, rows[2])))
end)

test("an out name off the role tracks still reserves its out number", function()
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_out1", track_name = "Review",  pos = 10 },  -- untouchable
    { name = "Foo_alt3", track_name = "Outs",    pos = 20 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG)
  assert(renamed(plan, rows[3]) == "Foo_out2",
         "must skip the held out1; got " .. tostring(renamed(plan, rows[3])))
end)

test("straighten renumbers each namespace from 1", function()
  local rows = {
    { name = "Foo",      track_name = "Selects", pos = 0 },
    { name = "Foo_alt7", track_name = "Alts",    pos = 10 },
    { name = "Foo_alt9", track_name = "Outs",    pos = 20 },
    { name = "Foo_alt4", track_name = "Alts",    pos = 30 },
  }
  local plan = vo.PlanRoleNames(rows, KNOWN, CFG, { renumber = true })
  assert(renamed(plan, rows[2]) == "Foo_alt1", tostring(renamed(plan, rows[2])))
  assert(renamed(plan, rows[4]) == "Foo_alt2", tostring(renamed(plan, rows[4])))
  assert(renamed(plan, rows[3]) == "Foo_out1", tostring(renamed(plan, rows[3])))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
