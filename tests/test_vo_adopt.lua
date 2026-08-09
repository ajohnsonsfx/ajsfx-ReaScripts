-- Unit tests for vo.PlanAdopt in VO/lib/ajsfx_vo.lua.
-- Run with: lua tests/test_vo_adopt.lua (from the repository root)
--
-- The gap under test: a session that was cut and edited BEFORE this tool
-- arrived has items with no useful names. Cut and Name would re-slice the
-- user's hand-fixed edges; Mark takes banks the edges but names nothing, and
-- Pull routes by name only -- so the session is stuck. Adopt is the bridge:
-- name every matched take after its script line at the item's CURRENT edges,
-- cutting nothing and never overwriting a name that is already an assignment.

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

print("\n=== ajsfx_vo.lua PlanAdopt Unit Tests ===\n")

local LINES = {
  { asset = "line_book",  text = "Book." },
  { asset = "line_story", text = "Story thing." },
  { asset = "line_dup",   deliver = "line_dup_ch2", text = "Duplicated." },
}
local INDEX = vo.BuildNameIndex(LINES)

test("an item still carrying the recording's name is renamed to its line", function()
  local renames, counts = vo.PlanAdopt({
    { item = "i1", name = "Grumbar full read-CMKB_Cleaned.wav",
      deliver = "line_book" },
  }, INDEX)
  assert(#renames == 1, "renames: " .. #renames)
  assert(renames[1].item == "i1")
  assert(renames[1].name == "line_book", "name: " .. renames[1].name)
  assert(counts.renamed == 1)
end)

test("an item already named for its line is left alone and counted", function()
  local renames, counts = vo.PlanAdopt({
    { item = "i1", name = "line_book", deliver = "line_book" },
  }, INDEX)
  assert(#renames == 0, "renamed an already-correct item")
  assert(counts.already == 1, "already: " .. counts.already)
end)

test("a name that IS an assignment to another line is never overwritten", function()
  -- The user said "this item is line_story" by naming it. The match
  -- disagreeing is the match's problem: names are facts, spans are guesses.
  local renames, counts = vo.PlanAdopt({
    { item = "i1", name = "line_story", deliver = "line_book" },
  }, INDEX)
  assert(#renames == 0, "overwrote a user assignment")
  assert(counts.assigned == 1, "assigned: " .. tostring(counts.assigned))
end)

test("an alt-suffixed assignment is an assignment too", function()
  local renames, counts = vo.PlanAdopt({
    { item = "i1", name = "line_story_alt2", deliver = "line_book" },
  }, INDEX, { alt_pattern = "_alt{n}" })
  assert(#renames == 0, "overwrote an alt assignment")
  assert(counts.assigned == 1)
end)

test("the delivered name wins over the asset when the line has an Append", function()
  local renames = vo.PlanAdopt({
    { item = "i1", name = "raw.wav", deliver = "line_dup_ch2" },
  }, INDEX)
  assert(#renames == 1)
  assert(renames[1].name == "line_dup_ch2", "name: " .. renames[1].name)
end)

test("two rows behind one item plan one rename, and the Sel row speaks", function()
  local renames, counts = vo.PlanAdopt({
    { item = "i1", name = "raw.wav", deliver = "line_story" },
    { item = "i1", name = "raw.wav", deliver = "line_book", sel = true },
  }, INDEX)
  assert(#renames == 1, "renames: " .. #renames)
  assert(renames[1].name == "line_book", "the Sel row lost: " .. renames[1].name)
  assert(counts.renamed == 1)
end)

test("a row with no delivered name is skipped and counted", function()
  local renames, counts = vo.PlanAdopt({
    { item = "i1", name = "raw.wav", deliver = "" },
    { item = "i2", name = "raw.wav" },
  }, INDEX)
  assert(#renames == 0)
  assert(counts.no_name == 2, "no_name: " .. counts.no_name)
end)

test("names are sanitized on the way out", function()
  local dirty_lines = { { asset = 'bad"name' } }
  local renames = vo.PlanAdopt({
    { item = "i1", name = "raw.wav", deliver = 'bad"name' },
  }, vo.BuildNameIndex(dirty_lines))
  assert(#renames == 1)
  assert(renames[1].name == vo.SanitizeName('bad"name'),
         "not sanitized: " .. renames[1].name)
end)

test("empty input plans nothing", function()
  local renames, counts = vo.PlanAdopt({}, INDEX)
  assert(#renames == 0)
  assert(counts.renamed == 0 and counts.already == 0
         and counts.assigned == 0 and counts.no_name == 0)
end)

test("two takes of one line both adopt the same plain name", function()
  -- Same rule as Cut and Name: takes share the plain name and Pull is what
  -- separates them. Adopt must not invent alt suffixes behind the user's back.
  local renames = vo.PlanAdopt({
    { item = "i1", name = "raw.wav", deliver = "line_book" },
    { item = "i2", name = "raw.wav", deliver = "line_book" },
  }, INDEX)
  assert(#renames == 2)
  assert(renames[1].name == "line_book" and renames[2].name == "line_book")
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
