-- Unit tests for VO/lib/ajsfx_vo.lua
-- Run with: lua tests/test_vo.lua (from the repository root)
-- The pure layer needs no REAPER API; the global is stubbed only so require() works.

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

-- The mock must install the global `reaper` BEFORE ajsfx_vo captures it, since
-- the module does `local r = reaper` at load time. Later mock.reset() calls are
-- safe: the installed closures resolve mock.extstate at call time.
package.path = package.path .. ";VO/lib/?.lua;tests/?.lua"
local mock = require("mock_reaper")
mock.reset()
local vo = require("ajsfx_vo")

print("\n=== ajsfx_vo.lua Unit Tests ===\n")

--------------------------------
-- ParseCSV
--------------------------------
print("ParseCSV:")

test("simple rows split on commas", function()
  local rows = vo.ParseCSV("a,b,c\n1,2,3\n")
  assert(#rows == 2, "Expected 2 rows, got " .. #rows)
  assert(rows[1][1] == "a" and rows[1][3] == "c", "Header mismatch")
  assert(rows[2][2] == "2", "Data mismatch: " .. tostring(rows[2][2]))
end)

test("quoted field with embedded comma stays one field", function()
  local rows = vo.ParseCSV('id,text\n1,"Hello, friend"\n')
  assert(#rows[2] == 2, "Expected 2 fields, got " .. #rows[2])
  assert(rows[2][2] == "Hello, friend", "Got: " .. tostring(rows[2][2]))
end)

test("doubled quotes inside a quoted field become one quote", function()
  local rows = vo.ParseCSV('id,text\n1,"She said ""go"" twice"\n')
  assert(rows[2][2] == 'She said "go" twice', "Got: " .. tostring(rows[2][2]))
end)

test("embedded newline inside a quoted field stays in the field", function()
  local rows = vo.ParseCSV('id,text\n1,"line one\nline two"\n')
  assert(#rows == 2, "Expected 2 rows, got " .. #rows)
  assert(rows[2][2] == "line one\nline two", "Got: " .. tostring(rows[2][2]))
end)

test("CRLF line endings are handled", function()
  local rows = vo.ParseCSV("a,b\r\n1,2\r\n")
  assert(#rows == 2, "Expected 2 rows, got " .. #rows)
  assert(rows[2][2] == "2", "Trailing CR leaked: " .. string.format("%q", rows[2][2]))
end)

test("UTF-8 BOM is stripped from the first field", function()
  local rows = vo.ParseCSV("\239\187\191LineID,Text\n1,hi\n")
  assert(rows[1][1] == "LineID", "Got: " .. string.format("%q", rows[1][1]))
end)

test("ragged rows keep their own field counts", function()
  local rows = vo.ParseCSV("a,b,c\n1,2\n")
  assert(#rows[1] == 3 and #rows[2] == 2, "Expected 3 then 2 fields")
end)

test("blank lines are skipped", function()
  local rows = vo.ParseCSV("a,b\n\n1,2\n\n")
  assert(#rows == 2, "Expected 2 rows, got " .. #rows)
end)

test("empty input returns no rows", function()
  local rows = vo.ParseCSV("")
  assert(#rows == 0, "Expected 0 rows, got " .. #rows)
end)

test("unterminated quote consumes to end of input", function()
  local rows = vo.ParseCSV('id,text\n1,"never closed\n')
  assert(rows[2][2] == "never closed\n", "Got: " .. string.format("%q", rows[2][2]))
end)

--------------------------------
-- MapColumns
--------------------------------
print("\nMapColumns:")

local MAPPING = {
  text    = "Text",
  asset   = "AudioAsset",
  speaker = "Speaker",
}

test("resolves configured names to 1-based indices", function()
  local cols = vo.MapColumns({ "LineID", "Speaker", "Text", "AudioAsset" }, MAPPING)
  assert(cols.speaker == 2, "speaker: " .. tostring(cols.speaker))
  assert(cols.text == 3, "text: " .. tostring(cols.text))
  assert(cols.asset == 4, "asset: " .. tostring(cols.asset))
end)

test("header whitespace is ignored", function()
  local cols = vo.MapColumns({ "  Text  ", "AudioAsset" }, MAPPING)
  assert(cols.text == 1 and cols.asset == 2, "Whitespace not trimmed")
end)

test("header matching is case-insensitive", function()
  local cols = vo.MapColumns({ "lineid", "TEXT", "audioasset" }, MAPPING)
  assert(cols.text == 2 and cols.asset == 3, "Case not ignored")
end)

test("optional columns absent from header map to nil", function()
  local cols = vo.MapColumns({ "LineID", "Text", "AudioAsset" }, MAPPING)
  assert(cols.speaker == nil, "Optional speaker column should be nil")
end)

test("missing required column returns nil plus an error naming found headers", function()
  local cols, err = vo.MapColumns({ "LineID", "Dialogue" }, MAPPING)
  assert(cols == nil, "Expected nil on missing required column")
  assert(err:find("AudioAsset"), "Error should name the missing column: " .. tostring(err))
  assert(err:find("Dialogue"), "Error should list headers found: " .. tostring(err))
end)

--------------------------------
-- BuildScriptLines
--------------------------------
print("\nBuildScriptLines:")

local COLS = { speaker = 2, text = 4, asset = 5 }

local function rows()
  return {
    { "NPC_001", "NPC",    "Dialogue", "Hello there traveller", "vo_npc_greet_01" },
    { "NPC_002", "NPC",    "Dialogue", "Not recorded yet",      "TO RECORD"       },
    { "PLR_001", "Player", "Dialogue", "I am the player",       "vo_plr_line_01"  },
    { "NPC_003", "NPC",    "Barks",    "Look out",              "vo_npc_bark_01"  },
    { "",        "NPC",    "Dialogue", "",                      ""                },
  }
end

test("builds one record per usable row", function()
  local lines = vo.BuildScriptLines(rows(), COLS, {})
  assert(#lines == 3, "Expected 3 lines (TO RECORD and empty dropped), got " .. #lines)
  assert(lines[1].asset == "vo_npc_greet_01", "asset: " .. tostring(lines[1].asset))
  assert(lines[1].text == "Hello there traveller", "text: " .. tostring(lines[1].text))
end)

test("skip values drop rows by asset, case-insensitively", function()
  local lines = vo.BuildScriptLines(rows(), COLS, { skip_values = { "to record" } })
  for _, l in ipairs(lines) do
    assert(l.asset ~= "TO RECORD", "TO RECORD row was not skipped")
  end
end)

test("rows with empty text or empty asset are dropped", function()
  local lines = vo.BuildScriptLines(rows(), COLS, {})
  for _, l in ipairs(lines) do
    assert(l.text ~= "" and l.asset ~= "", "Empty row leaked through")
  end
end)

test("character include-set keeps only included characters", function()
  local lines = vo.BuildScriptLines(rows(), COLS, { speakers = { npc = true } })
  assert(#lines == 2, "Expected 2 NPC lines, got " .. #lines)
  for _, l in ipairs(lines) do
    assert(l.speaker == "NPC", "Non-NPC line leaked: " .. tostring(l.speaker))
  end
end)

test("character include-set matches on folded key (case/space-insensitive)", function()
  local lines = vo.BuildScriptLines(rows(), COLS, { speakers = { player = true } })
  assert(#lines == 1, "Expected 1 Player line, got " .. #lines)
  assert(lines[1].asset == "vo_plr_line_01", "Wrong line: " .. tostring(lines[1].asset))
end)

test("each line records its source row number for reporting", function()
  local lines = vo.BuildScriptLines(rows(), COLS, {})
  assert(lines[1].row == 1, "row: " .. tostring(lines[1].row))
  assert(lines[2].row == 3, "row: " .. tostring(lines[2].row))
end)

test("missing optional speaker column leaves speaker nil and filter inert", function()
  local cols = { text = 4, asset = 5 }
  local lines = vo.BuildScriptLines(rows(), cols, { speakers = { npc = true } })
  assert(#lines == 3, "Speaker filter should be inert without the column, got " .. #lines)
  assert(lines[1].speaker == nil, "speaker should be nil")
end)

--------------------------------
-- DuplicateAssets
--------------------------------
print("\nDuplicateAssets:")

test("a script whose filenames are all unique reports nothing", function()
  local lines = { { asset = "a", text = "Alpha", row = 1 },
                  { asset = "b", text = "Bravo", row = 2 } }
  assert(#vo.DuplicateAssets(lines) == 0, "Expected no duplicates")
end)

test("two lines under one filename are reported with their script rows", function()
  local lines = { { asset = "a",   text = "Alpha", row = 1 },
                  { asset = "dup", text = "Jump right in!", row = 39 },
                  { asset = "dup", text = "The nightmares...", row = 42 } }
  local d = vo.DuplicateAssets(lines)
  assert(#d == 1, "Expected 1 duplicate, got " .. #d)
  assert(d[1].asset == "dup", "asset: " .. tostring(d[1].asset))
  assert(d[1].rows[1] == 39 and d[1].rows[2] == 42,
    "rows: " .. table.concat(d[1].rows, ","))
  assert(d[1].texts[1] == "Jump right in!", "The text is there to tell them apart")
end)

test("three lines under one filename report as one group of three", function()
  local lines = { { asset = "x", text = "1", row = 1 },
                  { asset = "x", text = "2", row = 2 },
                  { asset = "x", text = "3", row = 3 } }
  local d = vo.DuplicateAssets(lines)
  assert(#d == 1 and #d[1].rows == 3, "Expected one group of three")
end)

test("lines with no filename are not duplicates of each other", function()
  local lines = { { asset = "", text = "1", row = 1 },
                  { asset = "", text = "2", row = 2 } }
  assert(#vo.DuplicateAssets(lines) == 0, "Empty filenames are not a collision")
end)

test("the resolved name is what collides, not the raw filename", function()
  local lines = { { asset = "dup", deliver = "dup_a",  text = "A", row = 1 },
                  { asset = "dup", deliver = "dup_b",  text = "B", row = 2 } }
  assert(#vo.DuplicateAssets(lines) == 0,
    "Appends that separate the names must clear the clash")
end)

test("two scripts delivering one name collide like two rows of one script", function()
  local lines = { { asset = "dup", deliver = "dup", text = "A", row = 1, script = "Ch2" },
                  { asset = "dup", deliver = "dup", text = "B", row = 1, script = "Ch5" } }
  local d = vo.DuplicateAssets(lines)
  assert(#d == 1 and #d[1].rows == 2, "Expected one group of two")
  assert(d[1].asset == "dup", "The group is named by the resolved name")
end)

test("a line with no deliver falls back to its filename", function()
  local lines = { { asset = "dup", text = "A", row = 1 },
                  { asset = "dup", text = "B", row = 2 } }
  assert(#vo.DuplicateAssets(lines) == 1, "The fallback must still detect the clash")
end)

--------------------------------
-- ScriptLabel / AppendKey
--------------------------------
print("\nScriptLabel:")

test("a windows path becomes its basename without the extension", function()
  assert(vo.ScriptLabel("D:/game/Chapter2_Script.csv") == "Chapter2_Script",
    "Got " .. tostring(vo.ScriptLabel("D:/game/Chapter2_Script.csv")))
end)

test("backslashes are separators too", function()
  assert(vo.ScriptLabel("D:\\game\\Chapter5.csv") == "Chapter5",
    "Got " .. tostring(vo.ScriptLabel("D:\\game\\Chapter5.csv")))
end)

test("a label a filesystem would reject is sanitized", function()
  local got = vo.ScriptLabel("D:/game/Act 1: Pickups.csv")
  assert(not got:find("[:]"), "Colon survived: " .. got)
  assert(got ~= "", "Sanitizing must not empty a real name")
end)

test("no path is the empty label", function()
  assert(vo.ScriptLabel(nil) == "", "nil should give an empty label")
  assert(vo.ScriptLabel("") == "", "empty should give an empty label")
end)

test("a name with no extension is left alone", function()
  assert(vo.ScriptLabel("D:/game/script") == "script",
    "Got " .. tostring(vo.ScriptLabel("D:/game/script")))
end)

print("\nAppendKey:")

test("the same line keys the same way twice", function()
  assert(vo.AppendKey("Ch2", "line_042", 1) == vo.AppendKey("Ch2", "line_042", 1),
    "The key must be deterministic")
end)

test("two occurrences of one filename in one script key differently", function()
  assert(vo.AppendKey("Ch2", "line_042", 1) ~= vo.AppendKey("Ch2", "line_042", 2),
    "Occurrence must be part of the key")
end)

test("one filename in two scripts keys differently", function()
  assert(vo.AppendKey("Ch2", "line_042", 1) ~= vo.AppendKey("Ch5", "line_042", 1),
    "Script must be part of the key")
end)

--------------------------------
-- MergeScriptLines
--------------------------------
print("\nMergeScriptLines:")

local function script(label, enabled, assets)
  local lines = {}
  for i, a in ipairs(assets) do
    lines[i] = { asset = a, text = "line " .. a, row = i }
  end
  return { label = label, enabled = enabled, lines = lines }
end

test("lines come out in script order then row order", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "a", "b" }),
    script("Ch5", true, { "c" }),
  })
  assert(#merged == 3, "Expected 3 lines, got " .. #merged)
  assert(merged[1].asset == "a" and merged[2].asset == "b" and merged[3].asset == "c",
    "Order is script-then-row")
end)

test("each line is numbered across the whole list, not within its own script", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "a", "b" }),
    script("Ch5", true, { "c", "d" }),
  })
  for i, l in ipairs(merged) do
    assert(l.index == i, "Line " .. i .. " has index " .. tostring(l.index))
  end
  -- Both scripts have a row 2; only the merged index tells the two apart, which
  -- is what "which line comes first" means once a project reads several scripts.
  assert(merged[2].row == merged[4].row, "The fixture's rows must collide")
  assert(merged[2].index ~= merged[4].index, "Merged indices must not collide")
end)

test("reordering the script list renumbers the lines", function()
  local a, b = script("Ch2", true, { "a" }), script("Ch5", true, { "c" })
  assert(vo.MergeScriptLines({ a, b })[1].asset == "a", "Ch2 leads as given")
  local swapped = vo.MergeScriptLines({ b, a })
  assert(swapped[1].asset == "c" and swapped[1].index == 1,
    "The list's order is the line order")
  assert(swapped[2].asset == "a" and swapped[2].index == 2, "…and it renumbers")
end)

test("a disabled script leaves no gap in the numbering", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true,  { "a" }),
    script("Ch5", false, { "c" }),
    script("Ch7", true,  { "d" }),
  })
  assert(#merged == 2 and merged[2].index == 2,
    "Numbering counts the lines that are there, not the ones switched off")
end)

test("each line knows which script it came from", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "a" }),
    script("Ch5", true, { "c" }),
  })
  assert(merged[1].script == "Ch2", "Got " .. tostring(merged[1].script))
  assert(merged[2].script == "Ch5", "Got " .. tostring(merged[2].script))
end)

test("a disabled script contributes nothing", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true,  { "a" }),
    script("Ch5", false, { "c" }),
  })
  assert(#merged == 1 and merged[1].asset == "a",
    "A disabled script must contribute no lines")
end)

test("no filename is modified by merging", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "line_042" }),
    script("Ch5", true, { "line_042" }),
  })
  assert(merged[1].asset == "line_042" and merged[2].asset == "line_042",
    "Merging must never rename anything")
end)

test("a clash across scripts gets two distinct append keys", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "line_042" }),
    script("Ch5", true, { "line_042" }),
  })
  assert(merged[1].append_key ~= merged[2].append_key,
    "Two scripts' identical filenames are still two different lines")
end)

test("two lines sharing a filename inside one script get distinct keys", function()
  local merged = vo.MergeScriptLines({ script("Ch2", true, { "dup", "dup" }) })
  assert(merged[1].append_key ~= merged[2].append_key,
    "Occurrence index must separate them")
end)

test("occurrence counting is per script, not global", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "shared" }),
    script("Ch5", true, { "shared" }),
  })
  assert(merged[1].append_key == vo.AppendKey("Ch2", "shared", 1), "Ch2 line is its 1st")
  assert(merged[2].append_key == vo.AppendKey("Ch5", "shared", 1), "Ch5 line is its 1st too")
  assert(merged[1].append_nth == 1 and merged[2].append_nth == 1,
    "The occurrence integer rides along for the mutator")
end)

test("enabled defaults to true when the field is absent", function()
  local merged = vo.MergeScriptLines({ { label = "Ch2",
    lines = { { asset = "a", text = "t", row = 1 } } } })
  assert(#merged == 1, "A script with no enabled field is enabled")
end)

--------------------------------
-- Name resolution
--------------------------------
print("\nResolveItemName:")

local function name_lines(...)
  local lines = {}
  for i, a in ipairs({...}) do
    lines[i] = { asset = a, deliver = a, index = i, text = "line " .. a }
  end
  return lines
end

test("case, padding and extension are not part of a name", function()
  assert(vo.NormalizeItemName("Line_042.wav") == "line_042",
    "Got " .. vo.NormalizeItemName("Line_042.wav"))
  assert(vo.NormalizeItemName("  line_042  ") == "line_042", "whitespace")
  assert(vo.NormalizeItemName("line_042") == "line_042", "already clean")
end)

test("only a trailing extension is removed, never part of the name", function()
  -- A filename may legitimately contain dots; only the last short suffix goes.
  assert(vo.NormalizeItemName("vo.guard.halt.wav") == "vo.guard.halt",
    "Got " .. vo.NormalizeItemName("vo.guard.halt.wav"))
  assert(vo.NormalizeItemName("line_042_v1.2") == "line_042_v1.2",
    "A numeric tail is not an extension: " .. vo.NormalizeItemName("line_042_v1.2"))
end)

test("an item resolves to the line that names it", function()
  local idx = vo.BuildNameIndex(name_lines("line_041", "line_042"))
  assert(vo.ResolveItemName(idx, "line_042.WAV") == 2, "should resolve to line 2")
  assert(vo.ResolveItemName(idx, "line_041") == 1, "should resolve to line 1")
end)

test("an item resolves through the delivered name too", function()
  -- What Pull renamed on a previous run must still be recognisable, or a second
  -- Pull would see its own output as unknown audio.
  local lines = name_lines("line_042")
  lines[1].deliver = "line_042_ch2"
  local idx = vo.BuildNameIndex(lines)
  assert(vo.ResolveItemName(idx, "line_042_ch2") == 1, "delivered name")
  assert(vo.ResolveItemName(idx, "line_042") == 1, "plain name still works")
end)

test("a name no line claims resolves to nothing, and says why", function()
  local idx = vo.BuildNameIndex(name_lines("line_042"))
  local hit, why = vo.ResolveItemName(idx, "RIVA_session_take3")
  assert(hit == nil, "must not resolve")
  assert(why == "unknown", "Got " .. tostring(why))
end)

test("a name two lines claim resolves to nothing rather than guessing", function()
  local idx = vo.BuildNameIndex(name_lines("line_042", "line_042"))
  local hit, why = vo.ResolveItemName(idx, "line_042")
  assert(hit == nil, "an ambiguous name must not pick one")
  assert(why == "ambiguous", "Got " .. tostring(why))
end)

test("a line whose Append separates it from its twin resolves again", function()
  local lines = name_lines("line_042", "line_042")
  lines[2].deliver = "line_042_ch2"
  local idx = vo.BuildNameIndex(lines)
  assert(vo.ResolveItemName(idx, "line_042_ch2") == 2, "the appended one is unambiguous")
  assert(vo.ResolveItemName(idx, "line_042") == nil, "the bare name is still shared")
end)

test("an empty or missing name resolves to nothing", function()
  local idx = vo.BuildNameIndex(name_lines("line_042"))
  assert(vo.ResolveItemName(idx, "") == nil, "empty")
  assert(vo.ResolveItemName(idx, nil) == nil, "nil")
end)

--------------------------------
-- PlanPull
--------------------------------
print("\nPlanPull:")

local function pull_items(...)
  local items = {}
  for i, n in ipairs({...}) do items[i] = { id = i, name = n } end
  return items
end

local function dest_of(moves, id)
  for _, m in ipairs(moves) do if m.id == id then return m.dest end end
  return nil
end

test("one item for a line is the delivery without being marked", function()
  -- One take is not a decision. Requiring a mark here would make Pull useless
  -- on a folder of rendered files, which is half of what it is for.
  local moves, n = vo.PlanPull(pull_items("line_042"), name_lines("line_042"), {})
  assert(#moves == 1 and moves[1].dest == "selects", "Got " .. tostring(moves[1].dest))
  assert(moves[1].rename == "line_042", "renamed to the delivered name")
  assert(n.selects == 1, "counted")
end)

test("Sel delivers and the unticked takes wait on review", function()
  local moves = vo.PlanPull(pull_items("line_042", "line_042", "line_042"),
                            name_lines("line_042"), { [2] = "select" })
  assert(dest_of(moves, 2) == "selects", "the ticked one delivers")
  assert(dest_of(moves, 1) == "review" and dest_of(moves, 3) == "review",
    "the rest stay where the first pull put them")
end)

test("Keep is delivered alongside the select, as an alt", function()
  local moves = vo.PlanPull(pull_items("line_042", "line_042", "line_042"),
                            name_lines("line_042"), { [1] = "select", [2] = "keep" })
  assert(dest_of(moves, 1) == "selects", "select")
  assert(dest_of(moves, 2) == "alts", "keep")
  assert(dest_of(moves, 3) == "review", "unticked")
end)

test("nothing ticked puts the whole session on review", function()
  -- The first pull of a real session: cut, named, nothing listened to yet.
  local moves, n = vo.PlanPull(pull_items("line_042", "line_042"),
                               name_lines("line_042"), {})
  assert(dest_of(moves, 1) == "review" and dest_of(moves, 2) == "review",
    "both go to review")
  assert(n.review == 2, "counted")
end)

test("a Keep with no Sel is still delivered as an alt", function()
  -- The ticks are independent now: marking an alt must not require choosing a
  -- select first, which is exactly what the old three-state cycle forced.
  local moves = vo.PlanPull(pull_items("line_042", "line_042"),
                            name_lines("line_042"), { [1] = "keep" })
  assert(dest_of(moves, 1) == "alts", "the keep is delivered")
  assert(dest_of(moves, 2) == "review", "the other still waits")
end)

test("a lone take that IS ticked keeps to its tick", function()
  local moves = vo.PlanPull(pull_items("line_042"), name_lines("line_042"),
                            { [1] = "keep" })
  assert(dest_of(moves, 1) == "alts",
    "the one-take shortcut must not override an explicit tick")
end)

test("an item no line claims is left entirely alone", function()
  local moves, n = vo.PlanPull(pull_items("RIVA_session"), name_lines("line_042"), {})
  assert(#moves == 0, "nothing to move")
  assert(n.unknown == 1, "but it is counted, so an empty run is never silent")
end)

test("an ambiguous name is counted apart from an unknown one", function()
  local moves, n = vo.PlanPull(pull_items("line_042"),
                               name_lines("line_042", "line_042"), {})
  assert(#moves == 0, "nothing moves")
  assert(n.ambiguous == 1 and n.unknown == 0, "the user can fix an ambiguity")
end)

test("a take's own name wins over the line's delivered name", function()
  -- The Append belongs to the LINE, so it renames the select as well as the
  -- alt. A per-take override is the only thing that can separate two takes of
  -- one line, which is what an alt delivery needs.
  local items = pull_items("line_042", "line_042")
  items[2].override = "line_042_alt1"
  local moves = vo.PlanPull(items, name_lines("line_042"),
                            { [1] = "select", [2] = "keep" })
  for _, m in ipairs(moves) do
    if m.dest == "selects" then
      assert(m.rename == "line_042", "the select keeps the line's name")
    else
      assert(m.rename == "line_042_alt1", "Got " .. tostring(m.rename))
    end
  end
end)

test("only delivered items are renamed", function()
  local lines = name_lines("line_042")
  lines[1].deliver = "line_042_ch2"
  local moves = vo.PlanPull(pull_items("line_042", "line_042"), lines,
                            { [1] = "select" })
  assert(dest_of(moves, 1) == "selects", "select")
  for _, m in ipairs(moves) do
    if m.dest == "selects" then
      assert(m.rename == "line_042_ch2", "Got " .. tostring(m.rename))
    else
      assert(m.rename == nil, "a take that is not delivered keeps its name")
    end
  end
end)

--------------------------------
-- ResolveSourceTime
--------------------------------
print("\nResolveSourceTime:")

-- Two items of one recording, abutting in source time the way a cut leaves
-- them: A covers source 0..10 at project 100, B covers 10..20 at project 110.
local function cut_items()
  return {
    { item = "A", path = "s.wav", pos = 100, length = 10, start_offs = 0,  playrate = 1 },
    { item = "B", path = "s.wav", pos = 110, length = 10, start_offs = 10, playrate = 1 },
  }
end

test("a time inside an item resolves to that item", function()
  local item = vo.ResolveSourceTime("s.wav", 5, cut_items())
  assert(item == "A", "Got " .. tostring(item))
  assert(vo.ResolveSourceTime("s.wav", 15, cut_items()) == "B", "second item")
end)

test("a time on a boundary belongs to the item that STARTS there", function()
  -- The bug: an inclusive upper bound matched the item that ENDS at that
  -- instant, so clicking a take selected the take before it. The project time
  -- came out right either way, which is what made it look like a selection
  -- problem rather than a resolution one.
  local item, proj = vo.ResolveSourceTime("s.wav", 10, cut_items())
  assert(item == "B", "Got " .. tostring(item))
  assert(math.abs(proj - 110) < 1e-9, "project time: " .. tostring(proj))
end)

test("a time at the very end of the last item still resolves", function()
  -- Nothing starts there, so the fallback pass has to accept the item that
  -- ends there or the row would resolve to nothing at all.
  local item = vo.ResolveSourceTime("s.wav", 20, cut_items())
  assert(item == "B", "Got " .. tostring(item))
end)

test("a time no item covers resolves to nothing", function()
  assert(vo.ResolveSourceTime("s.wav", 40, cut_items()) == nil, "past the end")
  assert(vo.ResolveSourceTime("other.wav", 5, cut_items()) == nil, "another source")
end)

test("a take whose start was trimmed away still finds its item", function()
  -- The item now begins at source 12, and the take runs 10..20. Its start is
  -- gone, but eight of its ten seconds are right there.
  local items = { { item = "B", path = "s.wav", pos = 100, length = 8,
                    start_offs = 12, playrate = 1 } }
  local item, proj, _, coverage = vo.ResolveSourceSpan("s.wav", 10, 20, items)
  assert(item == "B", "Got " .. tostring(item))
  assert(coverage == "partial", "coverage: " .. tostring(coverage))
  assert(math.abs(proj - 100) < 1e-9,
    "lands on the first covered moment, not off the front: " .. tostring(proj))
end)

test("an intact take reports full coverage", function()
  local item, proj, _, coverage = vo.ResolveSourceSpan("s.wav", 5, 8, cut_items())
  assert(item == "A" and coverage == "full", "Got " .. tostring(item))
  assert(math.abs(proj - 105) < 1e-9, "project time: " .. tostring(proj))
end)

test("the item holding MOST of the take wins", function()
  local items = {
    { item = "A", path = "s.wav", pos = 0,  length = 1, start_offs = 10, playrate = 1 },
    { item = "B", path = "s.wav", pos = 50, length = 6, start_offs = 13, playrate = 1 },
  }
  -- The take runs 9..20 and its start is covered by neither: A holds one second
  -- of what is left, B holds six.
  local item = vo.ResolveSourceSpan("s.wav", 9, 20, items)
  assert(item == "B", "Got " .. tostring(item))
end)

test("a take with nothing left of it resolves to nothing", function()
  local items = { { item = "B", path = "s.wav", pos = 100, length = 5,
                    start_offs = 40, playrate = 1 } }
  assert(vo.ResolveSourceSpan("s.wav", 10, 20, items) == nil, "no overlap at all")
end)

--------------------------------
-- IsDestTrackName
--------------------------------
print("\nIsDestTrackName:")

test("a track Pull made is recognised, with or without a character", function()
  local bases = { "Selects", "Alts", "Review" }
  assert(vo.IsDestTrackName("MERIS_Selects", bases), "character prefixed")
  assert(vo.IsDestTrackName("Review", bases), "bare base name")
  assert(vo.IsDestTrackName("JORDAN_Alts", bases), "another character")
end)

test("a recording's own track is not one of ours", function()
  -- The check that matters: a second pull must nest under the RECORDING, not
  -- under the Review track the first pull put the item on.
  local bases = { "Selects", "Alts", "Review" }
  assert(not vo.IsDestTrackName("MERIS raw session", bases), "a recording")
  assert(not vo.IsDestTrackName("", bases), "an unnamed track")
  assert(not vo.IsDestTrackName("Selects and outtakes", bases),
    "a name that merely starts with one of ours")
  assert(not vo.IsDestTrackName("PreReview", bases),
    "the separator matters, or any suffix would match")
end)

test("renamed destinations are recognised, the defaults then are not", function()
  local bases = { "DELIVER", "ALT", "CHECK" }
  assert(vo.IsDestTrackName("MERIS_DELIVER", bases), "renamed in Settings")
  assert(not vo.IsDestTrackName("MERIS_Selects", bases),
    "the default name is just a track once it has been renamed")
end)

--------------------------------
-- Alt appends
--------------------------------
print("\nAltAppends:")

test("the number goes where the pattern says", function()
  assert(vo.FormatAltAppend("_alt{n}", 2, 1) == "_alt2", "tail")
  assert(vo.FormatAltAppend("{n}_x", 2, 1) == "2_x", "head")
  assert(vo.FormatAltAppend("_alt", 2, 1) == "_alt2",
    "with no placeholder the number goes on the end")
  assert(vo.FormatAltAppend("_pickup", nil, 1) == "_pickup",
    "a pattern used without a number is left alone")
end)

test("digits pad the number", function()
  assert(vo.FormatAltAppend("_alt{n}", 2, 2) == "_alt02", "two digits")
  assert(vo.FormatAltAppend("_alt{n}", 12, 2) == "_alt12", "no truncation")
end)

-- mark is "select", "keep", or nil -- the two ticks the table now carries.
local function alt_row(mark, asset, line, override)
  return { user_select = mark == "select", user_keep = mark == "keep",
           script = "Ch2", asset = asset, deliver = asset,
           script_row = line or 1, name_override = override }
end

test("alts are numbered per line, from the start value", function()
  local edits = vo.PlanAltNames({
    alt_row("select", "line_042", 1), alt_row("keep", "line_042", 1),
    alt_row("keep", "line_042", 1),    alt_row("keep", "line_099", 2),
  }, { pattern = "_alt{n}", start = 1, digits = 1 })
  assert(#edits == 3, "three alts, got " .. #edits)
  assert(edits[1].name == "line_042_alt1" and edits[2].name == "line_042_alt2",
    "numbered in timeline order within their line")
  assert(edits[3].name == "line_099_alt1",
    "a different line starts again: " .. tostring(edits[3].name))
end)

test("an alt is named per take, so the select keeps its own name", function()
  -- The bug this replaces: an Append belongs to the line, so writing one for
  -- the alt renamed the select as well and the two still collided.
  local rows = {
    alt_row("select", "line_042", 1), alt_row("keep", "line_042", 1),
  }
  local edits = vo.PlanAltNames(rows, { pattern = "_alt{n}", start = 1, digits = 1 })
  assert(#edits == 1 and edits[1].index == 2,
    "only the alt is renamed, and by its position in the rows")
  assert(edits[1].name == "line_042_alt1", "Got " .. tostring(edits[1].name))
end)

test("an alt of a line that already has an Append keeps it", function()
  local row = alt_row("keep", "line_042", 1)
  row.deliver = "line_042_ch2"
  local edits = vo.PlanAltNames({ row }, { pattern = "_alt{n}", start = 1, digits = 1 })
  assert(edits[1].name == "line_042_ch2_alt1", "Got " .. tostring(edits[1].name))
end)

test("two lines sharing a filename number their alts separately", function()
  local edits = vo.PlanAltNames({
    alt_row("keep", "dup", 7), alt_row("keep", "dup", 9),
  }, { pattern = "_alt{n}", start = 1, digits = 1 })
  assert(edits[1].name == "dup_alt1" and edits[2].name == "dup_alt1",
    "each line counts its own alts")
end)

test("the start value moves the first number", function()
  local edits = vo.PlanAltNames({ alt_row("keep", "line_042", 1) },
    { pattern = "_alt{n}", start = 2, digits = 1 })
  assert(edits[1].name == "line_042_alt2", "Got " .. tostring(edits[1].name))
end)

test("a name already chosen is never overwritten", function()
  local edits, skipped = vo.PlanAltNames({
    alt_row("keep", "line_042", 1, "line_042_pickup"), alt_row("keep", "line_042", 1),
  }, { pattern = "_alt{n}", start = 1, digits = 1 })
  assert(#edits == 1, "only the blank one is filled, got " .. #edits)
  assert(skipped == 1, "and the other is counted")
  assert(edits[1].name == "line_042_alt2",
    "the skipped alt still consumes its number: " .. tostring(edits[1].name))
end)

test("only alts are touched", function()
  local edits = vo.PlanAltNames({
    alt_row("select", "line_042", 1), alt_row(nil, "line_042", 1),
  }, { pattern = "_alt{n}", start = 1, digits = 1 })
  assert(#edits == 0, "a select and an unticked take are not alts")
end)

--------------------------------
-- AppendMap / SetAppend / ResolveNames
--------------------------------
print("\nAppendMap and SetAppend:")

test("records fold into a key-to-text map", function()
  local m = vo.AppendMap({ { script = "Ch2", asset = "a", nth = 1, text = "_x" } })
  assert(m[vo.AppendKey("Ch2", "a", 1)] == "_x", "Lookup failed")
end)

test("setting a new append adds one record", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "_x")
  assert(#rows == 1 and rows[1].text == "_x", "Expected one record")
end)

test("setting an existing append replaces it in place", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "_x")
  vo.SetAppend(rows, "Ch2", "a", 1, "_y")
  assert(#rows == 1, "Expected one record, got " .. #rows)
  assert(rows[1].text == "_y", "Got " .. tostring(rows[1].text))
end)

test("setting an append to empty removes the record", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "_x")
  vo.SetAppend(rows, "Ch2", "a", 1, "")
  assert(#rows == 0, "An empty append is not a judgement; it is the absence of one")
end)

test("whitespace-only counts as empty", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "   ")
  assert(#rows == 0, "Whitespace-only must remove the record")
end)

test("appends for other lines are untouched", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "_x")
  vo.SetAppend(rows, "Ch5", "a", 1, "_y")
  vo.SetAppend(rows, "Ch2", "a", 1, "")
  assert(#rows == 1 and rows[1].script == "Ch5", "Only the named record may change")
end)

print("\nResolveNames:")

test("no append leaves the filename alone", function()
  local lines = { { asset = "a", append_key = vo.AppendKey("Ch2", "a", 1) } }
  vo.ResolveNames(lines, {})
  assert(lines[1].deliver == "a", "Got " .. tostring(lines[1].deliver))
end)

test("an append is concatenated with no separator", function()
  local lines = { { asset = "line_042", append_key = vo.AppendKey("Ch2", "line_042", 1) } }
  vo.ResolveNames(lines, vo.AppendMap({
    { script = "Ch2", asset = "line_042", nth = 1, text = "_ch2" } }))
  assert(lines[1].deliver == "line_042_ch2", "Got " .. tostring(lines[1].deliver))
end)

test("a whitespace-only append resolves to the bare filename", function()
  local lines = { { asset = "a", append_key = vo.AppendKey("Ch2", "a", 1) } }
  vo.ResolveNames(lines, { [vo.AppendKey("Ch2", "a", 1)] = "   " })
  assert(lines[1].deliver == "a", "Got " .. tostring(lines[1].deliver))
end)

test("a line with no append key still resolves", function()
  local lines = { { asset = "a" } }
  vo.ResolveNames(lines, {})
  assert(lines[1].deliver == "a", "A key-less line must not error")
end)

--------------------------------
-- DuplicateNames
--------------------------------
print("\nDuplicateNames:")

test("two lines resolving to one name are flagged", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "dup" },
    { line_key = "k2", deliver = "dup" },
  })
  assert(dupes["dup"] == true, "Expected dup to be flagged")
end)

test("two takes of ONE line never flag each other", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "dup" },
    { line_key = "k1", deliver = "dup" },
  })
  assert(next(dupes) == nil, "Takes of one line share a name by design")
end)

test("an override that separates a clash clears it", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "dup", name_override = "dup_a" },
    { line_key = "k2", deliver = "dup" },
  })
  assert(next(dupes) == nil, "The override separated them")
end)

test("an override that recreates a clash is flagged", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "alpha", name_override = "bravo" },
    { line_key = "k2", deliver = "bravo" },
  })
  assert(dupes["bravo"] == true, "An override can create a clash too")
end)

test("an empty override is ignored", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "dup", name_override = "" },
    { line_key = "k2", deliver = "dup" },
  })
  assert(dupes["dup"] == true, "An empty override is not a rename")
end)

test("rows with no line are skipped", function()
  local dupes = vo.DuplicateNames({
    { deliver = "orphan" },
    { deliver = "orphan" },
  })
  assert(next(dupes) == nil, "Audio matching no script line has no name to clash")
end)

test("an empty name is never a clash", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "" },
    { line_key = "k2", deliver = "" },
  })
  assert(next(dupes) == nil, "Empty names are not a collision")
end)

--------------------------------
-- Normalize
--------------------------------
print("\nNormalize:")

test("lowercases and strips terminal punctuation", function()
  assert(vo.Normalize("Hello, There!") == "hello there", vo.Normalize("Hello, There!"))
end)

test("apostrophes are removed rather than split", function()
  assert(vo.Normalize("don't") == "dont", vo.Normalize("don't"))
end)

test("unicode right single quote is removed too", function()
  local s = vo.Normalize("don\226\128\153t")
  assert(s == "dont", "Got: " .. s)
end)

test("hyphens and em dashes become word breaks", function()
  local s = vo.Normalize("well-worn \226\128\148 truly")
  assert(s == "well worn truly", "Got: " .. s)
end)

test("collapses runs of whitespace", function()
  assert(vo.Normalize("  a   b\t\nc  ") == "a b c", vo.Normalize("  a   b\t\nc  "))
end)

test("empty and nil input normalize to empty string", function()
  assert(vo.Normalize("") == "", "empty")
  assert(vo.Normalize(nil) == "", "nil")
end)

test("single digit expands to a word", function()
  assert(vo.Normalize("i have 3 apples") == "i have three apples", vo.Normalize("i have 3 apples"))
end)

test("zero expands to zero", function()
  assert(vo.Normalize("0") == "zero", vo.Normalize("0"))
end)

test("compound tens expand without a hyphen", function()
  assert(vo.Normalize("21") == "twenty one", vo.Normalize("21"))
end)

test("hundreds expand without 'and'", function()
  assert(vo.Normalize("105") == "one hundred five", vo.Normalize("105"))
end)

test("thousands expand", function()
  assert(vo.Normalize("1999") == "one thousand nine hundred ninety nine", vo.Normalize("1999"))
end)

test("numbers above the supported range are left as digits", function()
  assert(vo.Normalize("10000") == "10000", vo.Normalize("10000"))
end)

test("ordinals expand to ordinal words", function()
  assert(vo.Normalize("1st") == "first", vo.Normalize("1st"))
  assert(vo.Normalize("2nd") == "second", vo.Normalize("2nd"))
  assert(vo.Normalize("3rd") == "third", vo.Normalize("3rd"))
  assert(vo.Normalize("12th") == "twelfth", vo.Normalize("12th"))
  assert(vo.Normalize("22nd") == "twenty second", vo.Normalize("22nd"))
end)

test("spelled-out numbers in the script are left untouched", function()
  assert(vo.Normalize("twenty one") == "twenty one", vo.Normalize("twenty one"))
end)

test("substitution table replaces whole tokens", function()
  local s = vo.Normalize("restore my hp", { hp = "hit points" })
  assert(s == "restore my hit points", "Got: " .. s)
end)

test("substitutions run before number expansion so they can override it", function()
  local s = vo.Normalize("in 1999 it fell", { ["1999"] = "nineteen ninety nine" })
  assert(s == "in nineteen ninety nine it fell", "Got: " .. s)
end)

test("substitution keys are matched after punctuation stripping", function()
  local s = vo.Normalize("Dr. Kaine", { dr = "doctor" })
  assert(s == "doctor kaine", "Got: " .. s)
end)

--------------------------------
-- Tokenize
--------------------------------
print("\nTokenize:")

test("splits on whitespace", function()
  local t = vo.Tokenize("one two three")
  assert(#t == 3 and t[1] == "one" and t[3] == "three", "Got " .. #t .. " tokens")
end)

test("empty string yields no tokens", function()
  assert(#vo.Tokenize("") == 0, "Expected 0 tokens")
end)

test("leading and trailing whitespace yields no empty tokens", function()
  local t = vo.Tokenize("  a  b  ")
  assert(#t == 2, "Expected 2 tokens, got " .. #t)
end)

--------------------------------
-- ParseWhisperCSV
--------------------------------
print("\nParseWhisperCSV:")

local function near(a, b) return math.abs(a - b) < 1e-9 end

test("header row is skipped and milliseconds become seconds", function()
  local w = vo.ParseWhisperCSV('start,end,text\n1230,1480,"hello"\n')
  assert(#w == 1, "Expected 1 word, got " .. #w)
  assert(near(w[1].t0, 1.23), "t0: " .. tostring(w[1].t0))
  assert(near(w[1].t1, 1.48), "t1: " .. tostring(w[1].t1))
  assert(w[1].text == "hello", "text: " .. tostring(w[1].text))
end)

test("a file with no header row still parses", function()
  local w = vo.ParseWhisperCSV('0,500,"hey"\n')
  assert(#w == 1 and w[1].text == "hey", "Expected 1 word")
end)

test("quoted text containing a comma survives", function()
  local w = vo.ParseWhisperCSV('start,end,text\n0,100,"well, then"\n')
  assert(w[1].text == "well, then", "Got: " .. tostring(w[1].text))
end)

test("whisper pads word text with a leading space which is trimmed", function()
  local w = vo.ParseWhisperCSV('start,end,text\n0,100," hello"\n')
  assert(w[1].text == "hello", "Got: " .. string.format("%q", w[1].text))
end)

test("rows with empty text are dropped", function()
  local w = vo.ParseWhisperCSV('start,end,text\n0,100,""\n100,200,"ok"\n')
  assert(#w == 1 and w[1].text == "ok", "Expected only the non-empty word")
end)

test("rows with non-numeric timestamps are dropped", function()
  local w = vo.ParseWhisperCSV('start,end,text\nbad,100,"x"\n100,200,"ok"\n')
  assert(#w == 1 and w[1].text == "ok", "Expected only the well-formed word")
end)

test("empty input yields no words", function()
  assert(#vo.ParseWhisperCSV("") == 0, "Expected 0 words")
end)

--------------------------------
-- Levenshtein
--------------------------------
print("\nLevenshtein:")

test("identical token arrays have distance zero", function()
  assert(vo.Levenshtein({ "a", "b", "c" }, { "a", "b", "c" }) == 0, "Expected 0")
end)

test("one substitution costs one", function()
  assert(vo.Levenshtein({ "a", "b", "c" }, { "a", "x", "c" }) == 1, "Expected 1")
end)

test("one insertion costs one", function()
  assert(vo.Levenshtein({ "a", "c" }, { "a", "b", "c" }) == 1, "Expected 1")
end)

test("one deletion costs one", function()
  assert(vo.Levenshtein({ "a", "b", "c" }, { "a", "c" }) == 1, "Expected 1")
end)

test("wholly disjoint arrays cost the longer length", function()
  assert(vo.Levenshtein({ "a", "b" }, { "x", "y", "z" }) == 3, "Expected 3")
end)

test("empty against n costs n", function()
  assert(vo.Levenshtein({}, { "a", "b" }) == 2, "Expected 2")
  assert(vo.Levenshtein({ "a", "b" }, {}) == 2, "Expected 2")
end)

test("both empty cost zero", function()
  assert(vo.Levenshtein({}, {}) == 0, "Expected 0")
end)

test("two tokens fused into one cost nothing", function()
  -- The script writes "some day", the recognizer hears "someday". Same words.
  assert(vo.Levenshtein({ "some", "day", "it" }, { "someday", "it" }) == 0, "Expected 0")
  assert(vo.Levenshtein({ "book", "man" }, { "bookman" }) == 0, "Expected 0")
end)

test("one token split into two costs nothing", function()
  assert(vo.Levenshtein({ "someday", "it" }, { "some", "day", "it" }) == 0, "Expected 0")
end)

test("a fusion inside a longer line still costs nothing", function()
  assert(vo.Levenshtein(
    { "some", "day", "it", "will", "be", "you" },
    { "someday", "it", "will", "be", "you" }) == 0, "Expected 0")
end)

test("two fusions in one line still cost nothing", function()
  -- "Someday, it'll be you" -- both "some day" and "it will" come back fused.
  assert(vo.Levenshtein(
    { "some", "day", "it", "will", "be", "you" },
    { "someday", "itwill", "be", "you" }) == 0, "Expected 0")
end)

test("a fusion that is not an exact join still costs", function()
  -- Free only when the concatenation matches exactly; otherwise it is a
  -- different word and must be charged as one.
  assert(vo.Levenshtein({ "some", "day" }, { "someone" }) == 2, "Expected 2")
end)

--------------------------------
-- BuildWordTokens
--------------------------------
print("\nBuildWordTokens:")

-- Build a whisper-style word list from a sentence, one word every 0.5s.
local function whisper_words(sentence, t0)
  t0 = t0 or 0
  local words = {}
  for w in sentence:gmatch("%S+") do
    words[#words + 1] = { t0 = t0, t1 = t0 + 0.4, text = w }
    t0 = t0 + 0.5
  end
  return words
end

test("one plain word yields one token carrying its times", function()
  local toks = vo.BuildWordTokens(whisper_words("Hello"), {})
  assert(#toks == 1, "Expected 1 token, got " .. #toks)
  assert(toks[1].text == "hello", "text: " .. toks[1].text)
  assert(near(toks[1].t0, 0) and near(toks[1].t1, 0.4), "times not carried")
end)

test("a numeral expands to several tokens sharing the source word's times", function()
  local toks = vo.BuildWordTokens({ { t0 = 1.0, t1 = 2.0, text = "42" } }, {})
  assert(#toks == 2, "Expected 2 tokens, got " .. #toks)
  assert(toks[1].text == "forty" and toks[2].text == "two", "Wrong expansion")
  assert(near(toks[1].t0, 1.0) and near(toks[1].t1, 2.0), "token 1 times")
  assert(near(toks[2].t0, 1.0) and near(toks[2].t1, 2.0), "token 2 times")
end)

test("every token records the index of the word it came from", function()
  local toks = vo.BuildWordTokens({
    { t0 = 0, t1 = 1, text = "take" },
    { t0 = 1, t1 = 2, text = "42" },
  }, {})
  assert(toks[1].word == 1, "word: " .. tostring(toks[1].word))
  assert(toks[2].word == 2 and toks[3].word == 2, "expanded tokens keep word index")
end)

test("a word that normalizes to nothing is dropped", function()
  local toks = vo.BuildWordTokens({ { t0 = 0, t1 = 1, text = "--" } }, {})
  assert(#toks == 0, "Expected 0 tokens, got " .. #toks)
end)

--------------------------------
-- BuildIndex
--------------------------------
print("\nBuildIndex:")

-- Specs are { label, text, asset }; the label is only a human reading aid — the
-- asset (Filename) is the line's identity everywhere downstream.
local function script_lines(specs)
  local lines = {}
  for i, s in ipairs(specs) do
    lines[i] = { text = s[2], asset = s[3], row = i }
  end
  return lines
end

local IDX_LINES = script_lines({
  { "L1", "open the north gate", "vo_gate_north" },
  { "L2", "open the south gate", "vo_gate_south" },
  { "L3", "open the gate",       "vo_gate_plain" },
})

test("tokenizes each line", function()
  local idx = vo.BuildIndex(IDX_LINES, {})
  assert(#idx.tokens[1] == 4, "Expected 4 tokens, got " .. #idx.tokens[1])
  assert(idx.tokens[1][3] == "north", "tokens[1][3]: " .. tostring(idx.tokens[1][3]))
end)

test("a token in every line has lower idf than a token in one line", function()
  local idx = vo.BuildIndex(IDX_LINES, {})
  assert(idx.idf["north"] > idx.idf["gate"], "north should outrank gate")
  assert(idx.idf["open"] == idx.idf["gate"], "open and gate appear equally often")
end)

test("anchors are the rarest tokens of a line", function()
  local idx = vo.BuildIndex(IDX_LINES, { anchor_count = 1 })
  assert(#idx.anchors[1] == 1, "Expected 1 anchor, got " .. #idx.anchors[1])
  assert(idx.anchors[1][1].token == "north", "anchor: " .. tostring(idx.anchors[1][1].token))
  assert(idx.anchors[1][1].pos == 3, "pos: " .. tostring(idx.anchors[1][1].pos))
end)

test("anchor count is capped by the line's distinct token count", function()
  local idx = vo.BuildIndex(script_lines({ { "L", "go", "a" } }), { anchor_count = 5 })
  assert(#idx.anchors[1] == 1, "Expected 1 anchor, got " .. #idx.anchors[1])
end)

test("postings list every line position an anchor token occurs at", function()
  local idx = vo.BuildIndex(IDX_LINES, { anchor_count = 1 })
  local p = idx.postings["north"]
  assert(p and #p == 1, "Expected 1 posting for north")
  assert(p[1].line == 1 and p[1].pos == 3, "posting: " .. tostring(p[1].line) .. "/" .. tostring(p[1].pos))
  -- Line 3 ("open the gate") contains no rare token, but it must still anchor on
  -- something or it could never be found at all.
  local common = idx.postings["open"]
  assert(common and #common == 1 and common[1].line == 3,
    "A line of only common words must still get an anchor")
end)

--------------------------------
-- Classify
--------------------------------
print("\nClassify:")

test("high score with clear margin is a match", function()
  assert(vo.Classify(0.95, 0.40, {}) == "match", "Expected match")
end)

test("score exactly at the accept threshold is a match", function()
  assert(vo.Classify(0.80, 0.05, {}) == "match", "Expected match at the boundary")
end)

test("high score with a thin margin is ambiguous and goes to review", function()
  assert(vo.Classify(0.95, 0.01, {}) == "review", "Expected review")
end)

test("middling score is review", function()
  assert(vo.Classify(0.60, 1.0, {}) == "review", "Expected review")
end)

test("score below the review floor is rejected outright", function()
  assert(vo.Classify(0.40, 1.0, {}) == nil, "Expected nil")
end)

test("thresholds are configurable", function()
  assert(vo.Classify(0.70, 1.0, { accept_threshold = 0.65 }) == "match", "Expected match")
end)

--------------------------------
-- FindCandidates
--------------------------------
print("\nFindCandidates:")

test("a verbatim reading of one line scores 1.0", function()
  local lines = script_lines({ { "L1", "open the north gate", "a" } })
  local idx   = vo.BuildIndex(lines, {})
  local toks  = vo.BuildWordTokens(whisper_words("open the north gate"), {})
  local cands = vo.FindCandidates(toks, lines, idx, {})
  assert(#cands >= 1, "Expected at least 1 candidate")
  assert(near(cands[1].score, 1.0), "score: " .. tostring(cands[1].score))
  assert(cands[1].i0 == 1 and cands[1].i1 == 4, "span: " .. cands[1].i0 .. ".." .. cands[1].i1)
end)

test("a line the recognizer fused keeps its first word", function()
  -- Regression: "Some day it will be you" against a read heard as "Someday, it
  -- will be you". Plain edit distance scored the full window and the window
  -- missing "someday" identically at 0.67, and trimming then dropped the word
  -- off the front of the take -- the line was delivered without "Someday".
  local lines = script_lines({ { "L1", "Some day it will be you.", "a" } })
  local idx   = vo.BuildIndex(lines, {})
  local toks  = vo.BuildWordTokens(
    whisper_words("takes every ounce of strength someday it will be you"), {})
  local cands = vo.FindCandidates(toks, lines, idx, {})
  assert(#cands >= 1, "Expected a candidate")
  local c = cands[1]
  assert(near(c.score, 1.0), "score: " .. tostring(c.score))
  assert(toks[c.i0].text == "someday",
    "window starts at: " .. tostring(toks[c.i0].text))
  assert(toks[c.i1].text == "you", "window ends at: " .. tostring(toks[c.i1].text))
end)

test("finds lines recorded out of script order", function()
  local lines = script_lines({
    { "L1", "open the north gate", "a" },
    { "L2", "close the iron door", "b" },
  })
  local idx  = vo.BuildIndex(lines, {})
  local toks = vo.BuildWordTokens(whisper_words("close the iron door open the north gate"), {})
  local cands = vo.FindCandidates(toks, lines, idx, {})
  local seen = {}
  for _, c in ipairs(cands) do
    if near(c.score, 1.0) then seen[c.asset] = true end
  end
  assert(seen.a and seen.b, "Both lines should be found regardless of order")
end)

test("a dropped word still scores above the accept threshold", function()
  local lines = script_lines({ { "L1", "open the north gate right now", "a" } })
  local idx   = vo.BuildIndex(lines, {})
  local toks  = vo.BuildWordTokens(whisper_words("open the north gate now"), {})
  local cands = vo.FindCandidates(toks, lines, idx, {})
  assert(#cands >= 1, "Expected a candidate")
  assert(cands[1].score > 0.80, "score: " .. tostring(cands[1].score))
end)

test("near-duplicate lines sharing an anchor produce a thin margin", function()
  local lines = script_lines({
    { "L1", "hold the line",     "a" },
    { "L2", "hold the line now", "b" },
  })
  local idx   = vo.BuildIndex(lines, { anchor_count = 3 })
  local toks  = vo.BuildWordTokens(whisper_words("hold the line"), {})
  local cands = vo.FindCandidates(toks, lines, idx, {})
  local best
  for _, c in ipairs(cands) do
    if not best or c.score > best.score then best = c end
  end
  assert(best.margin < 0.40, "Expected a thin margin, got " .. tostring(best.margin))
end)

test("an unambiguous single candidate gets full margin", function()
  local lines = script_lines({ { "L1", "open the north gate", "a" } })
  local idx   = vo.BuildIndex(lines, {})
  local toks  = vo.BuildWordTokens(whisper_words("open the north gate"), {})
  local cands = vo.FindCandidates(toks, lines, idx, {})
  assert(near(cands[1].margin, 1.0), "margin: " .. tostring(cands[1].margin))
end)

test("audio containing none of the script yields no usable candidate", function()
  local lines = script_lines({ { "L1", "open the north gate", "a" } })
  local idx   = vo.BuildIndex(lines, {})
  local toks  = vo.BuildWordTokens(whisper_words("this is completely unrelated chatter"), {})
  local cands = vo.FindCandidates(toks, lines, idx, {})
  for _, c in ipairs(cands) do
    assert(c.score < 0.55, "Unrelated audio scored " .. tostring(c.score))
  end
end)

test("a window is trimmed to the tightest range that keeps its best score", function()
  -- The recognizer dropped the leading "open", so anchor arithmetic proposes a
  -- window starting one token early — on the tail of whatever came before.
  -- Left un-trimmed, that phantom token overlaps the previous span and gets the
  -- whole line rejected during selection.
  local lines = script_lines({ { "L1", "open the north gate quickly", "a" } })
  local idx   = vo.BuildIndex(lines, {})
  local toks  = vo.BuildWordTokens(whisper_words("there the north gate quickly"), {})
  local cands = vo.FindCandidates(toks, lines, idx, {})
  assert(#cands >= 1, "Expected a candidate")
  assert(cands[1].i0 == 2, "Expected trim to token 2, got " .. cands[1].i0)
  assert(near(cands[1].start, 0.5), "start should follow the trim: " .. cands[1].start)
end)

test("trimming never shortens an exact match", function()
  local lines = script_lines({ { "L1", "open the north gate", "a" } })
  local idx   = vo.BuildIndex(lines, {})
  local toks  = vo.BuildWordTokens(whisper_words("open the north gate"), {})
  local c     = vo.FindCandidates(toks, lines, idx, {})[1]
  assert(c.i0 == 1 and c.i1 == 4, "Exact match was trimmed: " .. c.i0 .. ".." .. c.i1)
end)

test("candidates carry the script line's identity and times", function()
  local lines = script_lines({ { "L1", "open the north gate", "vo_gate_north" } })
  local idx   = vo.BuildIndex(lines, {})
  local toks  = vo.BuildWordTokens(whisper_words("open the north gate"), {})
  local c     = vo.FindCandidates(toks, lines, idx, {})[1]
  assert(c.asset == "vo_gate_north", "identity (asset) not carried")
  assert(near(c.start, 0.0), "start: " .. tostring(c.start))
  assert(near(c.stop, 1.9), "stop: " .. tostring(c.stop))
end)

--------------------------------
-- SelectSpans
--------------------------------
print("\nSelectSpans:")

local function cand(i0, i1, score, margin, id)
  return { i0 = i0, i1 = i1, score = score, margin = margin or 1.0,
           asset = id or ("a" .. i0),
           start = i0 * 1.0, stop = i1 * 1.0 }
end

test("non-overlapping candidates are all kept", function()
  local spans = vo.SelectSpans({ cand(1, 3, 0.9), cand(5, 7, 0.9) }, {})
  assert(#spans == 2, "Expected 2 spans, got " .. #spans)
end)

test("of two overlapping candidates the higher score wins", function()
  local spans = vo.SelectSpans({ cand(1, 4, 0.7, 1.0, "LOW"), cand(2, 5, 0.95, 1.0, "HIGH") }, {})
  assert(#spans == 1, "Expected 1 span, got " .. #spans)
  assert(spans[1].asset == "HIGH", "Wrong winner: " .. spans[1].asset)
end)

test("equal scores are tie-broken by the wider margin", function()
  local spans = vo.SelectSpans({ cand(1, 4, 0.9, 0.02, "THIN"), cand(2, 5, 0.9, 0.50, "WIDE") }, {})
  assert(spans[1].asset == "WIDE", "Wrong winner: " .. spans[1].asset)
end)

test("candidates below the review floor are discarded", function()
  local spans = vo.SelectSpans({ cand(1, 3, 0.40) }, {})
  assert(#spans == 0, "Expected 0 spans, got " .. #spans)
end)

test("a long match beats a short one of equal score and margin", function()
  -- Without this a one-word line scoring a perfect 1.0 outranks the twelve-word
  -- line whose audio it sits inside, and takes the audio with it.
  local spans = vo.SelectSpans({ cand(4, 4, 1.0, 1.0, "WORD"),
                                 cand(1, 9, 1.0, 1.0, "LINE") }, {})
  assert(#spans == 1, "Expected 1 span, got " .. #spans)
  assert(spans[1].asset == "LINE", "Wrong winner: " .. spans[1].asset)
end)

--------------------------------
-- Read order: BuildBackbone, OrderConsistency
--------------------------------
print("\nRead order:")

local function ocand(i0, i1, line_idx, score, margin)
  local c = cand(i0, i1, score or 1.0, margin or 1.0, "L" .. line_idx)
  c.line_idx = line_idx
  return c
end

test("only long, confident, unambiguous matches define the order", function()
  local short_ = ocand(1, 2, 1, 1.0)          -- 2 tokens: too short to trust
  local unsure = ocand(10, 20, 2, 0.60)       -- below the accept threshold
  local thin   = ocand(30, 40, 3, 1.0, 0.01)  -- a rival line scored almost as well
  local good   = ocand(50, 60, 4, 1.0)
  local bone = vo.BuildBackbone({ short_, unsure, thin, good }, {})
  assert(#bone == 1, "Expected 1 backbone entry, got " .. #bone)
  assert(bone[1] == good, "the wrong candidate was trusted")
  assert(good.backbone == true, "the backbone entry was not marked")
end)

test("a line read out of sequence does not get to define the sequence", function()
  -- Four trustworthy matches, one of which is a pickup of line 90 dropped in
  -- the middle. The longest run that reads in order is the other three.
  local a, pickup, b, c = ocand(1, 10, 1), ocand(20, 30, 90), ocand(40, 50, 2), ocand(60, 70, 3)
  local bone = vo.BuildBackbone({ a, pickup, b, c }, {})
  assert(#bone == 3, "Expected 3 backbone entries, got " .. #bone)
  assert(bone[1] == a and bone[2] == b and bone[3] == c, "wrong run kept")
  assert(pickup.backbone ~= true, "the out-of-order pickup was trusted")
end)

test("two takes of one line are in order, not out of it", function()
  local a, take1, take2 = ocand(1, 10, 1), ocand(20, 30, 2), ocand(40, 50, 2)
  local bone = vo.BuildBackbone({ a, take1, take2 }, {})
  assert(#bone == 3, "a retake broke the run: " .. #bone)
end)

test("a candidate between its neighbours reads in sequence", function()
  local bone = { ocand(1, 10, 10), ocand(40, 50, 20) }
  assert(vo.OrderConsistency(ocand(20, 21, 15), bone) == true, "in-sequence rejected")
  assert(vo.OrderConsistency(ocand(20, 21, 10), bone) == true, "a retake was rejected")
  assert(vo.OrderConsistency(ocand(20, 21, 5),  bone) == false, "too early accepted")
  assert(vo.OrderConsistency(ocand(20, 21, 90), bone) == false, "too late accepted")
end)

test("with no backbone near it, order says nothing either way", function()
  assert(vo.OrderConsistency(ocand(1, 2, 5), {}) == nil, "an empty backbone judged")
  local self_ = ocand(1, 10, 3)
  assert(vo.OrderConsistency(self_, { self_ }) == nil, "a candidate judged against itself")
end)

test("a perfect match in the wrong place is flagged, never asserted", function()
  -- The reported failure: a script line that is only "You." scores 1.0 against
  -- every "you" in the read. The one in the wrong place must not be named.
  local bone   = { ocand(1, 10, 10), ocand(40, 50, 20) }
  local stray  = ocand(20, 20, 3, 1.0)   -- line 3, spoken between lines 10 and 20
  local proper = ocand(25, 25, 15, 1.0)
  local spans  = vo.SelectSpans({ bone[1], bone[2], stray, proper }, {}, bone)
  local kinds = {}
  for _, s in ipairs(spans) do kinds[s.asset] = s.kind end
  assert(kinds.L3 == "review", "the stray match was not flagged: " .. tostring(kinds.L3))
  assert(kinds.L15 == "match", "the properly placed match was demoted: " .. tostring(kinds.L15))
end)

test("reading in order is never enough on its own to assert a weak match", function()
  -- Position is not evidence about the words. A 0.67 line stays in review.
  local bone  = { ocand(1, 10, 10), ocand(40, 50, 20) }
  local weak  = ocand(20, 26, 15, 0.67)
  local spans = vo.SelectSpans({ weak }, {}, bone)
  assert(#spans == 1 and spans[1].kind == "review",
    "a weak match was promoted by its position: " .. tostring(spans[1] and spans[1].kind))
end)

test("a long line read out of order keeps its confidence", function()
  -- Pickups, ADR and per-character passes are all recorded out of script order.
  -- A line long enough to identify itself is not made wrong by where it fell.
  local bone   = { ocand(1, 10, 10), ocand(40, 50, 20) }
  local pickup = ocand(20, 27, 3, 1.0)   -- 8 tokens, line 3, spoken far too late
  local spans  = vo.SelectSpans({ pickup }, {}, bone)
  assert(spans[1].kind == "match", "a long pickup was demoted: " .. spans[1].kind)
  assert(spans[1].in_sequence == nil, "order was judged on a line that can identify itself")
end)

--------------------------------
-- Selection order and the residual pass
--------------------------------
print("\nSelection order:")

-- The real failure this came from: the recogniser fused "book man" into
-- "bookman" and dropped the closing "guards", and the script also has a line
-- that is only "You." -- one of the words in the middle of it.
local function bookman_lines()
  return vo.BuildScriptLines(
    { { "vo_book", "GRUMBAR", 'Old book man say "If you guard door, read what door guards."' },
      { "vo_you",  "GRUMBAR", "You." } },
    { asset = 1, speaker = 2, text = 3 }, {})
end

local function said(text)
  local words, t = {}, 0.0
  for w in text:gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.4, text = w }
    t = t + 0.5
  end
  return words
end

test("a window is scored as it is finally kept, not as it was proposed", function()
  -- Trimming may only stop somewhere at least as good as the BEST it has seen.
  -- Comparing against the proposed score alone walked through the best window
  -- and out the far side to a merely equal one, losing "old bookman" and a
  -- quarter of the score with it.
  local lines = bookman_lines()
  local toks  = vo.BuildWordTokens(
    said("wrong old bookman say if you guard door read what door old"), {})
  local hits  = vo.FindLineCandidates(lines, 1, toks, {})
  assert(hits[1].text:find("^old bookman say"),
    "the window lost its opening words: [" .. hits[1].text .. "]")
  assert(hits[1].score >= 0.74,
    string.format("scored %.3f, expected the 0.75 the kept window is worth", hits[1].score))
end)

test("a one-word line cannot cut a twelve-word line in half", function()
  local lines = bookman_lines()
  local got = vo.BuildMatch({ { path = "s.wav",
    words = said("old bookman say if you guard door read what door") } }, lines, {})
  local found
  for _, s in ipairs(got[1].spans) do
    if s.asset == "vo_book" then found = s end
  end
  assert(found, "the long line was lost entirely")
  assert(found.i0 == 1, "the long line was cut at the front: i0 = " .. found.i0)
  assert(found.transcript:find("guard door read what door"),
    "the long line was cut at the back: " .. found.transcript)
end)

test("confident placements are laid down before uncertain ones", function()
  -- Equal-ish scores, opposite confidence: the one that classifies as a match
  -- must take the audio, not merely the one that scored a hair higher.
  local sure   = cand(1, 6, 0.90, 0.50, "SURE")
  local unsure = cand(4, 9, 0.92, 0.01, "UNSURE")   -- thin margin, so review
  local spans  = vo.SelectSpans({ unsure, sure }, {})
  assert(#spans == 1, "Expected 1 span, got " .. #spans)
  assert(spans[1].asset == "SURE", "an uncertain placement blocked a confident one")
end)

test("a line that lost every window gets a second look at what is left", function()
  -- "seal it" is spoken twice. The first is taken by the longer line that
  -- contains it; on one pass the second occurrence goes to nobody, because the
  -- greedy sweep had already placed the line elsewhere.
  local lines = vo.BuildScriptLines(
    { { "vo_long", "R", "seal it nobody goes below" },
      { "vo_short", "R", "seal it" } },
    { asset = 1, speaker = 2, text = 3 }, {})
  local got = vo.BuildMatch({ { path = "s.wav",
    words = said("seal it nobody goes below and later seal it") } }, lines, {})
  local by_asset = {}
  for _, s in ipairs(got[1].spans) do
    if s.asset then by_asset[s.asset] = s end
  end
  assert(by_asset.vo_long, "the long line was lost")
  assert(by_asset.vo_short, "the short line never got its second look")
  assert(by_asset.vo_short.i0 > by_asset.vo_long.i1,
    "the second look landed on audio that was already taken")
end)

test("the residual pass cannot disturb anything the first pass decided", function()
  local lines = bookman_lines()
  local words = said("old bookman say if you guard door read what door")
  local one = vo.BuildMatch({ { path = "s.wav", words = words } }, lines, {})[1].spans
  local kept = {}
  for _, s in ipairs(one) do
    if s.asset then kept[#kept + 1] = s.asset .. "@" .. s.i0 .. "-" .. s.i1 end
  end
  -- Running it again over the same input must be idempotent: the residual pass
  -- only ever looks at token runs nothing claimed.
  local two = vo.BuildMatch({ { path = "s.wav", words = words } }, lines, {})[1].spans
  local again = {}
  for _, s in ipairs(two) do
    if s.asset then again[#again + 1] = s.asset .. "@" .. s.i0 .. "-" .. s.i1 end
  end
  assert(table.concat(kept, ",") == table.concat(again, ","),
    "matching is not deterministic: " .. table.concat(kept, ",") ..
    " vs " .. table.concat(again, ","))
end)

--------------------------------
-- PinnedSpans
--------------------------------
print("\nPinnedSpans:")

local function pin_lines()
  return vo.BuildScriptLines(
    { { "vo_you", "RIVA", "You." },
      { "vo_seal", "RIVA", "seal it nobody goes below" } },
    { asset = 1, speaker = 2, text = 3 }, {})
end

local function pin_tokens()
  local words, t = {}, 0.0
  for w in ("seal it nobody goes below you watch you left"):gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.4, text = w }
    t = t + 0.5
  end
  return vo.BuildWordTokens(words, {})
end

test("a pin becomes a match at exactly the range that was chosen", function()
  local spans = vo.PinnedSpans(pin_tokens(),
    { { asset = "vo_you", source = "s.wav", start = 4.0, stop = 4.45 } }, pin_lines())
  assert(#spans == 1, "Expected 1 pinned span, got " .. #spans)
  assert(spans[1].kind == "match", "kind: " .. spans[1].kind)
  assert(spans[1].pinned == true, "the span is not marked pinned")
  assert(spans[1].asset == "vo_you", "asset: " .. tostring(spans[1].asset))
  -- The person's range, not the matched word's.
  assert(spans[1].start == 4.0 and spans[1].stop == 4.45,
    string.format("range: %.2f-%.2f", spans[1].start, spans[1].stop))
  assert(spans[1].i0 == 9 and spans[1].i1 == 9,
    string.format("tokens: %d-%d", spans[1].i0, spans[1].i1))
end)

test("a word half inside the range goes one way, not both", function()
  -- Token 2 ("it") runs 0.50-0.90; a range ending at 0.60 clips it, and its
  -- midpoint of 0.70 is outside, so it stays out.
  local spans = vo.PinnedSpans(pin_tokens(),
    { { asset = "vo_seal", source = "s.wav", start = 0.0, stop = 0.60 } }, pin_lines())
  assert(spans[1].i1 == 1, "i1: " .. spans[1].i1)
end)

test("a pin naming no word, or no script line, is reported not dropped", function()
  local lines = pin_lines()
  local _, u1 = vo.PinnedSpans(pin_tokens(),
    { { asset = "vo_you", source = "s.wav", start = 90.0, stop = 91.0 } }, lines)
  assert(#u1 == 1 and u1[1].why:find("no transcribed word"), "silent on an empty range")

  local _, u2 = vo.PinnedSpans(pin_tokens(),
    { { asset = "vo_gone", source = "s.wav", start = 0.0, stop = 1.0 } }, lines)
  assert(#u2 == 1 and u2[1].why:find("no script line"), "silent on a missing line")
end)

test("a pin beats the matcher and takes the audio with it", function()
  local lines = pin_lines()
  local words, t = {}, 0.0
  for w in ("seal it nobody goes below"):gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.4, text = w }
    t = t + 0.5
  end
  -- vo_you pinned over the whole of vo_seal's audio: an absurd pin, chosen
  -- because it proves the pin wins rather than merely coexists.
  local got = vo.BuildMatch({ { path = "s.wav", words = words } }, lines, {},
    { { asset = "vo_you", source = "s.wav", start = 0.0, stop = 2.4 } })
  local kinds = {}
  for _, s in ipairs(got[1].spans) do
    if s.asset then kinds[s.asset] = s.kind end
  end
  assert(kinds.vo_you == "match", "the pin did not win: " .. tostring(kinds.vo_you))
  assert(kinds.vo_seal == nil, "the matcher's placement survived under the pin")
end)

test("a pin speaks for its own take and not for the line's others", function()
  -- "you" is said twice; one occurrence is pinned. The other is still a real
  -- take of that line and has to survive. This once deleted it, on the
  -- reasoning that you pin to correct a mistake -- but the same gesture
  -- confirms one take of three, and there the deletion was silent and wrong.
  local lines = pin_lines()
  local words, t = {}, 0.0
  for w in ("you seal it nobody goes below you"):gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.4, text = w }
    t = t + 0.5
  end
  local got = vo.BuildMatch({ { path = "s.wav", words = words } }, lines, {},
    { { asset = "vo_you", source = "s.wav", start = 3.0, stop = 3.45 } })
  local you = {}
  for _, s in ipairs(got[1].spans) do
    if s.asset == "vo_you" then you[#you + 1] = s end
  end
  assert(#you == 2, "the pin swallowed the line's other take: " .. #you)
  local pinned = 0
  for _, s in ipairs(you) do if s.pinned then pinned = pinned + 1 end end
  assert(pinned == 1, "expected exactly one pinned take, got " .. pinned)
end)

test("two takes of one line can be pinned independently", function()
  local lines = pin_lines()
  local words, t = {}, 0.0
  for w in ("you seal it nobody goes below you"):gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.4, text = w }
    t = t + 0.5
  end
  local got = vo.BuildMatch({ { path = "s.wav", words = words } }, lines, {}, {
    { asset = "vo_you", source = "s.wav", start = 0.0, stop = 0.45 },
    { asset = "vo_you", source = "s.wav", start = 3.0, stop = 3.45 },
  })
  local pinned = 0
  for _, s in ipairs(got[1].spans) do
    if s.asset == "vo_you" and s.pinned then pinned = pinned + 1 end
  end
  assert(pinned == 2, "expected both takes pinned, got " .. pinned)
end)

test("pins round-trip through the project file", function()
  local pins = {
    { asset = "vo_you",  source = "D:/s/A.wav", start = 12.5,  stop = 13.25 },
    { asset = "vo_seal", source = "D:/s/B.wav", start = 100.0, stop = 104.5 },
  }
  local scripts = { { path = "s.csv", mapping = {}, enabled = true } }
  local text   = vo.SerializeProjectFile({}, { scripts = scripts, pins = pins })
  local parsed = assert(vo.ParseProjectFile(text))
  assert(#parsed.pins == 2, "Expected 2 pins, got " .. #parsed.pins)
  assert(parsed.pins[1].asset == "vo_you", "asset lost")
  assert(parsed.pins[1].source == "D:/s/A.wav", "source lost")
  assert(math.abs(parsed.pins[1].start - 12.5) < 1e-6, "start lost")
  assert(math.abs(parsed.pins[2].stop - 104.5) < 1e-6, "stop lost")
  assert(parsed.scripts[1].path == "s.csv", "the preamble was disturbed")
end)

test("a project file with no pins still reads, and a corrupt pin is dropped", function()
  local text = vo.SerializeProjectFile({},
    { scripts = { { path = "s.csv", mapping = {}, enabled = true } } })
  local parsed = assert(vo.ParseProjectFile(text))
  assert(#parsed.pins == 0, "phantom pins")

  local bad = text:gsub("Script,", "Pin,vo_x,,0,0\nScript,", 1)
  local reparsed = assert(vo.ParseProjectFile(bad))
  assert(#reparsed.pins == 0, "a pin with no source or range was kept")
end)

--------------------------------
-- FindLineCandidates
--------------------------------
print("\nFindLineCandidates:")

local function tokens_from(text)
  local words, t = {}, 0.0
  for w in text:gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.2, text = w }
    t = t + 0.25
  end
  return vo.BuildWordTokens(words, {}), words
end

-- The searched line plus two decoys, so idf is a real fact about a script
-- rather than a degenerate one about a single line.
local function script_lines(text)
  return vo.BuildScriptLines(
    { { "vo_x_01", "RIVA", text },
      { "vo_y_01", "RIVA", "alpha bravo charlie delta" },
      { "vo_z_01", "RIVA", "echo foxtrot golf hotel" } },
    { asset = 1, speaker = 2, text = 3 }, {})
end

test("a one-word line is found at every place that word occurs", function()
  local toks = tokens_from("you should go now and you will see why you left")
  local hits = vo.FindLineCandidates(script_lines("You."), 1, toks, {})
  assert(#hits == 3, "Expected 3 placements, got " .. #hits)
  for _, h in ipairs(hits) do
    assert(h.score == 1.0, "a perfect word match scored " .. h.score)
  end
end)

test("placements come back best first and never overlap each other", function()
  local toks = tokens_from("seal it nobody goes below and then seal it again")
  local hits = vo.FindLineCandidates(script_lines("seal it nobody goes below"), 1, toks, {})
  assert(hits[1].score == 1.0, "the exact placement did not come first")
  for i = 2, #hits do
    assert(hits[i].score <= hits[i - 1].score, "placements out of order")
    assert(hits[i].i0 > hits[i - 1].i1, "placements overlap")
  end
end)

test("placements the matcher would reject are still offered", function()
  -- Two of five words survive: far below review_floor, and exactly what someone
  -- asking "where did this line go?" needs to see.
  local toks = tokens_from("we come")
  local hits = vo.FindLineCandidates(script_lines("we should not have come"), 1, toks, {})
  assert(#hits >= 1, "a weak placement was hidden")
  assert(hits[1].score < vo.DEFAULTS.review_floor,
    "this fixture no longer tests a sub-floor placement: " .. hits[1].score)
end)

test("each placement carries the words either side of it", function()
  local toks = tokens_from("alpha bravo charlie seal it delta echo foxtrot")
  local hits = vo.FindLineCandidates(script_lines("seal it"), 1, toks, {}, { context = 2 })
  assert(hits[1].text == "seal it", "text: " .. hits[1].text)
  assert(hits[1].before == "bravo charlie", "before: " .. hits[1].before)
  assert(hits[1].after == "delta echo", "after: " .. hits[1].after)
end)

test("the text shown back is what was said, not the normalised form", function()
  local toks, raw = tokens_from("Open the gate, Captain!")
  local hits = vo.FindLineCandidates(script_lines("open the gate"), 1, toks, {},
                                     { words = raw, context = 1 })
  assert(hits[1].text == "Open the gate,", "text: " .. hits[1].text)
  assert(hits[1].after == "Captain!", "after: " .. hits[1].after)
end)

test("the limit is honoured and an empty transcript is not an error", function()
  local toks = tokens_from("you you you you you you you you")
  assert(#vo.FindLineCandidates(script_lines("You."), 1, toks, {}, { limit = 3 }) == 3,
    "limit ignored")
  assert(#vo.FindLineCandidates(script_lines("You."), 1, {}, {}) == 0, "empty transcript threw")
  assert(#vo.FindLineCandidates(script_lines("You."), 9, tokens_from("you"), {}) == 0, "an out-of-range line index threw")
end)

test("without a backbone nothing is judged on order at all", function()
  local stray = ocand(20, 20, 3, 1.0)
  local spans = vo.SelectSpans({ stray }, {}, nil)
  assert(spans[1].kind == "match", "order was applied with no backbone")
  assert(spans[1].in_sequence == nil, "in_sequence set with no backbone")
end)

test("spans are returned in chronological order", function()
  local spans = vo.SelectSpans({ cand(5, 7, 0.9), cand(1, 3, 0.95) }, {})
  assert(spans[1].i0 == 1 and spans[2].i0 == 5, "Not chronological")
end)

test("each selected span is classified", function()
  local spans = vo.SelectSpans({ cand(1, 3, 0.95, 0.5), cand(5, 7, 0.60, 1.0) }, {})
  assert(spans[1].kind == "match", "kind: " .. tostring(spans[1].kind))
  assert(spans[2].kind == "review", "kind: " .. tostring(spans[2].kind))
end)

test("adjacent but non-overlapping candidates both survive", function()
  local spans = vo.SelectSpans({ cand(1, 3, 0.9), cand(4, 6, 0.9) }, {})
  assert(#spans == 2, "Expected 2 spans, got " .. #spans)
end)

--------------------------------
-- FindGaps
--------------------------------
print("\nFindGaps:")

test("tokens before the first span become an unmatched run", function()
  local toks = vo.BuildWordTokens(whisper_words("take two open the gate"), {})
  local gaps = vo.FindGaps(toks, { { i0 = 3, i1 = 5 } })
  assert(#gaps == 1, "Expected 1 gap, got " .. #gaps)
  assert(gaps[1].i0 == 1 and gaps[1].i1 == 2, "gap: " .. gaps[1].i0 .. ".." .. gaps[1].i1)
  assert(gaps[1].kind == "unmatched", "kind: " .. tostring(gaps[1].kind))
  assert(gaps[1].transcript == "take two", "transcript: " .. tostring(gaps[1].transcript))
end)

test("tokens after the last span become an unmatched run", function()
  local toks = vo.BuildWordTokens(whisper_words("open the gate that was rough"), {})
  local gaps = vo.FindGaps(toks, { { i0 = 1, i1 = 3 } })
  assert(#gaps == 1 and gaps[1].i0 == 4 and gaps[1].i1 == 6, "Wrong trailing gap")
end)

test("tokens between two spans become their own run", function()
  local toks = vo.BuildWordTokens(whisper_words("one slate here two"), {})
  local gaps = vo.FindGaps(toks, { { i0 = 1, i1 = 1 }, { i0 = 5, i1 = 5 } })
  assert(#gaps == 1, "Expected 1 gap, got " .. #gaps)
  assert(gaps[1].i0 == 2 and gaps[1].i1 == 4, "gap: " .. gaps[1].i0 .. ".." .. gaps[1].i1)
end)

test("a fully consumed stream yields no gaps", function()
  local toks = vo.BuildWordTokens(whisper_words("open the gate"), {})
  assert(#vo.FindGaps(toks, { { i0 = 1, i1 = 3 } }) == 0, "Expected 0 gaps")
end)

test("gaps carry the times of their first and last token", function()
  local toks = vo.BuildWordTokens(whisper_words("take two open"), {})
  local gaps = vo.FindGaps(toks, { { i0 = 3, i1 = 3 } })
  assert(near(gaps[1].start, 0.0), "start: " .. tostring(gaps[1].start))
  assert(near(gaps[1].stop, 0.9), "stop: " .. tostring(gaps[1].stop))
end)

test("an empty span list makes the whole stream one gap", function()
  local toks = vo.BuildWordTokens(whisper_words("nothing matched at all"), {})
  local gaps = vo.FindGaps(toks, {})
  assert(#gaps == 1 and gaps[1].i0 == 1 and gaps[1].i1 == 4, "Expected one whole-stream gap")
end)

--------------------------------
-- SanitizeName
--------------------------------
print("\nSanitizeName:")

test("path separators become underscores", function()
  assert(vo.SanitizeName("vo/npc\\greet") == "vo_npc_greet", vo.SanitizeName("vo/npc\\greet"))
end)

test("reserved filesystem characters become underscores", function()
  assert(vo.SanitizeName('a:b*c?d"e<f>g|h') == "a_b_c_d_e_f_g_h", vo.SanitizeName('a:b*c?d"e<f>g|h'))
end)

test("whitespace becomes underscores", function()
  assert(vo.SanitizeName("take two") == "take_two", vo.SanitizeName("take two"))
end)

test("runs of separators collapse to one underscore", function()
  assert(vo.SanitizeName("a///b") == "a_b", vo.SanitizeName("a///b"))
end)

test("leading and trailing separators are trimmed", function()
  assert(vo.SanitizeName("  /a/  ") == "a", vo.SanitizeName("  /a/  "))
end)

test("hyphens dots and underscores are preserved", function()
  assert(vo.SanitizeName("vo_a-b.wav") == "vo_a-b.wav", vo.SanitizeName("vo_a-b.wav"))
end)

test("names are truncated to the length limit", function()
  local s = vo.SanitizeName(string.rep("x", 200), 10)
  assert(#s == 10, "Expected 10 chars, got " .. #s)
end)

test("an empty result falls back to a placeholder", function()
  assert(vo.SanitizeName("///") == "unnamed", vo.SanitizeName("///"))
  assert(vo.SanitizeName("") == "unnamed", vo.SanitizeName(""))
end)

test("windows reserved device names are escaped", function()
  assert(vo.SanitizeName("CON") == "_CON", vo.SanitizeName("CON"))
  assert(vo.SanitizeName("com1") == "_com1", vo.SanitizeName("com1"))
end)

test("a device name used as a prefix is left alone", function()
  assert(vo.SanitizeName("console") == "console", vo.SanitizeName("console"))
end)

--------------------------------
-- ApplyPadding
--------------------------------
print("\nInterWordGaps:")

test("gaps sit between consecutive words", function()
  local gaps = vo.InterWordGaps({
    { t0 = 0.0, t1 = 0.5, text = "a" },
    { t0 = 1.0, t1 = 1.5, text = "b" },
    { t0 = 3.0, t1 = 3.5, text = "c" },
  })
  assert(#gaps == 2, "Expected 2 gaps, got " .. #gaps)
  assert(math.abs(gaps[1].from - 0.5) < 1e-9, "gap 1 from: " .. gaps[1].from)
  assert(math.abs(gaps[1].to   - 1.0) < 1e-9, "gap 1 to: " .. gaps[1].to)
  assert(math.abs(gaps[2].to   - 3.0) < 1e-9, "gap 2 to: " .. gaps[2].to)
end)

test("overlapping or touching words produce no gap", function()
  local gaps = vo.InterWordGaps({
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 1.0, t1 = 2.0, text = "b" },
    { t0 = 1.5, t1 = 2.5, text = "c" },
  })
  assert(#gaps == 0, "Expected no gaps, got " .. #gaps)
end)

test("fewer than two words means no gaps", function()
  assert(#vo.InterWordGaps({}) == 0, "empty")
  assert(#vo.InterWordGaps(nil) == 0, "nil must not raise")
  assert(#vo.InterWordGaps({ { t0 = 0, t1 = 1, text = "a" } }) == 0, "single")
end)

--------------------------------
print("\nMeasureNoiseFloor:")

test("the floor is the quietest measurable gap plus the offset", function()
  local gaps = { { from = 0, to = 2 }, { from = 5, to = 7 } }
  local probe = function(t0, _) return t0 < 3 and -50.0 or -70.0 end
  local floor = vo.MeasureNoiseFloor(gaps, probe, { snap_floor_offset = 6.0 })
  assert(floor and math.abs(floor - (-64.0)) < 1e-9, "Floor: " .. tostring(floor))
end)

test("a gap shorter than snap_min_silence is ignored", function()
  local floor = vo.MeasureNoiseFloor({ { from = 0, to = 0.01 } },
                                     function() return -70 end,
                                     { snap_floor_window = 0.5, snap_min_silence = 0.06 })
  assert(floor == nil, "Expected nil, got " .. tostring(floor))
end)

-- Ordinary speech has most of its pauses well under half a second. Requiring a
-- gap long enough to fill the whole window meant a file whose pauses all fell
-- just short of it measured no floor at all, and snapping quietly turned itself
-- off for that file. A REAPER run caught this; the mock never could.
test("a gap shorter than the window is still measured, over what there is", function()
  local seen = {}
  local probe = function(t0, t1) seen[#seen + 1] = t1 - t0; return -70 end
  local floor = vo.MeasureNoiseFloor({ { from = 1.0, to = 1.2 } }, probe,
                                     { snap_floor_window = 0.5, snap_min_silence = 0.06,
                                       snap_floor_offset = 6.0 })
  assert(floor and math.abs(floor - (-64.0)) < 1e-9, "Floor: " .. tostring(floor))
  assert(#seen == 1 and math.abs(seen[1] - 0.2) < 1e-9,
    "should measure the gap's own width: " .. tostring(seen[1]))
end)

test("a gap longer than the window is measured over the window only", function()
  local seen = {}
  local probe = function(t0, t1) seen[#seen + 1] = t1 - t0; return -70 end
  vo.MeasureNoiseFloor({ { from = 0, to = 4 } }, probe,
                       { snap_floor_window = 0.5, snap_min_silence = 0.06 })
  assert(#seen == 1 and math.abs(seen[1] - 0.5) < 1e-9,
    "should cap at the window: " .. tostring(seen[1]))
end)

test("no probe means no floor", function()
  assert(vo.MeasureNoiseFloor({ { from = 0, to = 5 } }, nil, {}) == nil, "Expected nil")
end)

test("a probe that cannot read returns nil rather than a bogus floor", function()
  local floor = vo.MeasureNoiseFloor({ { from = 0, to = 5 } },
                                     function() return nil end, {})
  assert(floor == nil, "Expected nil, got " .. tostring(floor))
end)

--------------------------------
print("\nSnapBoundary:")

-- A probe describing one loud region [a, b]; everything else is silent.
local function loud_between(a, b)
  return function(t0, t1)
    if t1 > a and t0 < b then return -10.0 end
    return -80.0
  end
end

test("a start boundary walks back into silence and stops there", function()
  local t, how = vo.SnapBoundary(1.0, 0.5, -1, -60.0, loud_between(1.0, 2.0),
                                 { snap_min_silence = 0.05 })
  assert(how == "silence", "How: " .. tostring(how))
  assert(math.abs(t - 0.95) < 1e-9, "Boundary: " .. tostring(t))
end)

test("a stop boundary walks forward into silence and stops there", function()
  local t, how = vo.SnapBoundary(2.0, 2.5, 1, -60.0, loud_between(1.0, 2.0),
                                 { snap_min_silence = 0.05 })
  assert(how == "silence", "How: " .. tostring(how))
  assert(math.abs(t - 2.05) < 1e-9, "Boundary: " .. tostring(t))
end)

test("no silence in the window falls back to the limit and says so", function()
  local t, how = vo.SnapBoundary(2.0, 2.2, 1, -60.0, loud_between(0.0, 10.0),
                                 { snap_min_silence = 0.05 })
  assert(how == "pad", "How: " .. tostring(how))
  assert(math.abs(t - 2.2) < 1e-9, "Boundary: " .. tostring(t))
end)

test("a window shorter than the minimum silence falls back immediately", function()
  local t, how = vo.SnapBoundary(2.0, 2.1, 1, -60.0, loud_between(0, 0),
                                 { snap_min_silence = 0.5 })
  assert(how == "pad" and math.abs(t - 2.1) < 1e-9, "Got " .. t .. " / " .. how)
end)

test("no probe, and no floor, each fall back to the limit", function()
  local a, ha = vo.SnapBoundary(2.0, 2.5, 1, -60.0, nil, {})
  assert(ha == "pad" and math.abs(a - 2.5) < 1e-9, "no probe: " .. a .. " / " .. ha)
  local b, hb = vo.SnapBoundary(2.0, 2.5, 1, nil, function() return -80 end, {})
  assert(hb == "pad" and math.abs(b - 2.5) < 1e-9, "no floor: " .. b .. " / " .. hb)
end)

test("the result never crosses the limit, in either direction", function()
  local cfg, quiet = { snap_min_silence = 0.05 }, function() return -80.0 end
  local a = vo.SnapBoundary(1.0, 0.5, -1, -60.0, quiet, cfg)
  assert(a >= 0.5 - 1e-9 and a <= 1.0 + 1e-9, "Backward escaped: " .. a)
  local b = vo.SnapBoundary(1.0, 1.5, 1, -60.0, quiet, cfg)
  assert(b >= 1.0 - 1e-9 and b <= 1.5 + 1e-9, "Forward escaped: " .. b)
end)

--------------------------------
print("\nApplyPadding:")

test("spans are padded by pre_pad and post_pad", function()
  local spans = { { start = 5.0, stop = 6.0 } }
  vo.ApplyPadding(spans, { pre_pad = 0.1, post_pad = 0.2 })
  assert(near(spans[1].start, 4.9), "start: " .. spans[1].start)
  assert(near(spans[1].stop, 6.2), "stop: " .. spans[1].stop)
end)

test("the unpadded times are preserved for reporting", function()
  local spans = { { start = 5.0, stop = 6.0 } }
  vo.ApplyPadding(spans, { pre_pad = 0.1, post_pad = 0.2 })
  assert(near(spans[1].raw_start, 5.0) and near(spans[1].raw_stop, 6.0), "raw times lost")
end)

test("colliding neighbours meet at the midpoint of the original gap", function()
  local spans = { { start = 0.0, stop = 1.0 }, { start = 1.2, stop = 2.0 } }
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5 })
  assert(near(spans[1].stop, 1.1), "prev stop: " .. spans[1].stop)
  assert(near(spans[2].start, 1.1), "next start: " .. spans[2].start)
end)

test("a comfortable gap is padded fully without clamping", function()
  local spans = { { start = 0.0, stop = 1.0 }, { start = 5.0, stop = 6.0 } }
  vo.ApplyPadding(spans, { pre_pad = 0.1, post_pad = 0.2 })
  assert(near(spans[1].stop, 1.2), "prev stop: " .. spans[1].stop)
  assert(near(spans[2].start, 4.9), "next start: " .. spans[2].start)
end)

test("padding never crosses the containing item's bounds", function()
  local spans = { { start = 0.05, stop = 9.95 } }
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5 }, { start = 0.0, stop = 10.0 })
  assert(near(spans[1].start, 0.0), "start: " .. spans[1].start)
  assert(near(spans[1].stop, 10.0), "stop: " .. spans[1].stop)
end)

test("a span clamped at a bound is flagged for the report", function()
  local spans = { { start = 0.05, stop = 1.0 } }
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5 }, { start = 0.0, stop = 10.0 })
  assert(spans[1].clamped == true, "Expected clamped flag")
end)

-- A span must never come out of padding inverted (stop < start). ApplyPadding
-- clamps each boundary independently, and the plan it is handed is ordered by
-- token index, not by time — so a neighbour whose recognized times overlap or
-- invert can push a boundary past its own opposite edge. A negative-length span
-- is not merely an odd report line: ApplyPlan splits at start and again at stop,
-- and an inverted span makes the second split meaningless.

test("an inverted neighbour clamp falls back to the raw times", function()
  -- The first span outlives the second, so the midpoint lands beyond the
  -- second span's own end. Observed in a real run as a -0.180s span.
  local spans = {
    { start = 1911.0, stop = 1913.0 },
    { start = 1911.1, stop = 1911.2 },
  }
  vo.ApplyPadding(spans, { pre_pad = 0.150, post_pad = 0.250 })
  assert(near(spans[2].start, 1911.1), "start: " .. spans[2].start)
  assert(near(spans[2].stop, 1911.2), "stop: " .. spans[2].stop)
end)

test("a span rescued from inversion is flagged for the report", function()
  local spans = {
    { start = 1911.0, stop = 1913.0 },
    { start = 1911.1, stop = 1911.2 },
  }
  vo.ApplyPadding(spans, { pre_pad = 0.150, post_pad = 0.250 })
  assert(spans[2].degenerate == true, "Expected degenerate flag")
  assert(spans[1].degenerate == nil, "Healthy span wrongly flagged")
end)

test("a span wholly outside the item bounds is never negative", function()
  local spans = { { start = 12.0, stop = 12.5 } }
  vo.ApplyPadding(spans, { pre_pad = 0.150, post_pad = 0.250 }, { start = 0.0, stop = 10.0 })
  assert(spans[1].stop >= spans[1].start,
    "Inverted: " .. spans[1].start .. " -> " .. spans[1].stop)
end)

test("a zero-width recognizer span stays zero-width, never negative", function()
  local spans = {
    { start = 10.0, stop = 10.0 },
    { start = 10.0, stop = 10.0 },
  }
  vo.ApplyPadding(spans, { pre_pad = 0.150, post_pad = 0.250 })
  for i, s in ipairs(spans) do
    assert(s.stop >= s.start, "Inverted span " .. i .. ": " .. s.start .. " -> " .. s.stop)
  end
end)

test("ordinary padding is untouched by the inversion guard", function()
  local spans = { { start = 5.0, stop = 6.0 } }
  vo.ApplyPadding(spans, { pre_pad = 0.1, post_pad = 0.2 })
  assert(near(spans[1].start, 4.9) and near(spans[1].stop, 6.2), "padding changed")
  assert(spans[1].degenerate == nil, "Healthy span wrongly flagged")
end)

--------------------------------
print("\nApplyPadding (snapping):")

local function pad_span(a, b) return { start = a, stop = b, kind = "match", asset = "x" } end

test("without a probe the fixed pads are applied exactly as before", function()
  local spans = { pad_span(2.0, 3.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.1, post_pad = 0.2 })
  assert(near(spans[1].start, 1.9), "start: " .. spans[1].start)
  assert(near(spans[1].stop,  3.2), "stop: " .. spans[1].stop)
  assert(spans[1].snapped == nil, "snapped should not be set without a probe")
end)

test("with a probe the boundary lands in silence inside the pad", function()
  local spans = { pad_span(2.0, 3.0) }
  local probe = function(t0, t1) if t1 > 2.0 and t0 < 3.0 then return -10 end return -80 end
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5, snap_min_silence = 0.05 },
                  nil, probe, -60)
  assert(near(spans[1].start, 1.95), "start: " .. spans[1].start)
  assert(near(spans[1].stop,  3.05), "stop: " .. spans[1].stop)
  assert(spans[1].snapped == "silence", "snapped: " .. tostring(spans[1].snapped))
end)

--------------------------------
print("\nFindSpeechBounds:")

test("the sound inside a span is found, and the pause around it is not", function()
  -- Speech in (12, 14) of a span running 10 to 16.
  local probe = function(t0, t1) if t1 > 12.0 and t0 < 14.0 then return -10 end return -80 end
  local a, b = vo.FindSpeechBounds(10.0, 16.0, -60, probe, { snap_min_silence = 0.5 })
  assert(near(a, 12.0), "speech start: " .. tostring(a))
  assert(near(b, 14.0), "speech stop: " .. tostring(b))
end)

test("a span that is silent throughout reports nothing rather than nothing found", function()
  local a, b = vo.FindSpeechBounds(10.0, 16.0, -60, function() return -80 end,
                                   { snap_min_silence = 0.5 })
  assert(a == nil and b == nil, "Silence must not be trimmed to a point")
end)

test("no probe and no floor means no answer", function()
  assert(vo.FindSpeechBounds(0, 5, -60, nil, {}) == nil, "no probe")
  assert(vo.FindSpeechBounds(0, 5, nil, function() return -10 end, {}) == nil, "no floor")
end)

test("whisper's contiguous word times no longer weld the takes together", function()
  -- The real shape of the bug. Whisper ends each word where the next begins,
  -- so a take's span carries the pause before it AND the pause after it, and
  -- two takes of a line share a boundary exactly. Cut faithfully, that tiles
  -- the recording: every clip runs to the start of the next with no break.
  -- Speech is in (10.5, 11.5) and (13.5, 14.5); the spans meet at 13.0.
  local spans = { pad_span(10.0, 13.0), pad_span(13.0, 16.0) }
  local words = { { t0 = 10.0, t1 = 13.0 }, { t0 = 13.0, t1 = 16.0 } }
  local probe = function(t0, t1)
    if (t1 > 10.5 and t0 < 11.5) or (t1 > 13.5 and t0 < 14.5) then return -10 end
    return -80
  end
  vo.ApplyPadding(spans, { pre_pad = 0.3, post_pad = 0.3, snap_min_silence = 0.1 },
                  nil, probe, -60, words)

  assert(spans[1].stop < spans[2].start - 0.5,
    string.format("The takes still touch: %.3f then %.3f", spans[1].stop, spans[2].start))
  -- Each clip holds its own line with a little air, not three seconds of room.
  assert(spans[1].start > 10.2 and spans[1].stop < 11.9,
    string.format("take 1: %.3f..%.3f", spans[1].start, spans[1].stop))
  assert(spans[2].start > 13.2 and spans[2].stop < 14.9,
    string.format("take 2: %.3f..%.3f", spans[2].start, spans[2].stop))
end)

test("a take whose words are already tight is padded exactly as before", function()
  -- The good case must not regress: speech fills the span, so there is nothing
  -- to trim in and the edges travel outward into the pad as they always did.
  local spans = { pad_span(2.0, 3.0) }
  local probe = function(t0, t1) if t1 > 2.0 and t0 < 3.0 then return -10 end return -80 end
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5, snap_min_silence = 0.05 },
                  nil, probe, -60)
  assert(near(spans[1].start, 1.95), "start: " .. spans[1].start)
  assert(near(spans[1].stop,  3.05), "stop: " .. spans[1].stop)
end)

test("a boundary never crosses into the neighbouring take's audio", function()
  local spans = { pad_span(2.0, 3.0), pad_span(3.1, 4.0) }
  -- Silent everywhere: maximum temptation for the search to run away.
  vo.ApplyPadding(spans, { pre_pad = 1.0, post_pad = 1.0, snap_min_silence = 0.02 },
                  nil, function() return -80 end, -60)
  assert(spans[1].stop <= 3.1 + 1e-9, "span 1 stop ate into span 2: " .. spans[1].stop)
  assert(spans[2].start >= 3.0 - 1e-9, "span 2 start ate into span 1: " .. spans[2].start)
  assert(spans[1].stop <= spans[2].start + 1e-9, "spans overlap after snapping")
end)

-- The span list only holds what this cut selected. A false start or an aside
-- between two selected takes is audio that belongs to neither, and the words
-- are the only record that it is there at all.
test("a boundary stops at a word no span selected", function()
  local spans = { pad_span(2.0, 3.0) }
  local words = {
    { t0 = 2.0, t1 = 3.0, text = "chosen" },
    { t0 = 3.2, t1 = 3.6, text = "aside" },   -- not in the span list
  }
  vo.ApplyPadding(spans, { pre_pad = 1.0, post_pad = 1.0, snap_min_silence = 0.02 },
                  nil, function() return -80 end, -60, words)
  assert(spans[1].stop <= 3.2 + 1e-9,
    "the edge travelled into an unselected word: " .. spans[1].stop)
end)

test("a word behind the span bounds the start the same way", function()
  local spans = { pad_span(2.0, 3.0) }
  local words = {
    { t0 = 1.2, t1 = 1.7, text = "before" },
    { t0 = 2.0, t1 = 3.0, text = "chosen" },
  }
  vo.ApplyPadding(spans, { pre_pad = 1.0, post_pad = 1.0, snap_min_silence = 0.02 },
                  nil, function() return -80 end, -60, words)
  assert(spans[1].start >= 1.7 - 1e-9,
    "the edge travelled back over an unselected word: " .. spans[1].start)
end)

test("the span's own words do not bound its edges", function()
  -- A word list always contains the span's own words; if those bounded it, no
  -- edge could ever move at all.
  local spans = { pad_span(2.0, 3.0) }
  local words = { { t0 = 2.0, t1 = 3.0, text = "chosen" } }
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5, snap_min_silence = 0.02 },
                  nil, function() return -80 end, -60, words)
  assert(spans[1].start < 2.0, "start did not move: " .. spans[1].start)
  assert(spans[1].stop  > 3.0, "stop did not move: " .. spans[1].stop)
end)

test("without words the pad is still the only limit", function()
  local spans = { pad_span(2.0, 3.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.4, post_pad = 0.4, snap_min_silence = 0.02 },
                  nil, function() return -80 end, -60)
  assert(near(spans[1].start, 1.98), "start: " .. spans[1].start)
end)

test("no silence found is reported as pad, not silence", function()
  local spans = { pad_span(2.0, 3.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.2, post_pad = 0.2, snap_min_silence = 0.05 },
                  nil, function() return -10 end, -60)
  assert(spans[1].snapped == "pad", "snapped: " .. tostring(spans[1].snapped))
  assert(near(spans[1].stop, 3.2), "stop should fall back to the pad: " .. spans[1].stop)
end)

test("snap_boundaries = false ignores the probe entirely", function()
  local spans = { pad_span(2.0, 3.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5, snap_boundaries = false },
                  nil, function() return -80 end, -60)
  assert(near(spans[1].start, 1.5), "start: " .. spans[1].start)
  assert(spans[1].snapped == nil, "snapped should not be set when disabled")
end)

test("bounds still clamp a snapped boundary", function()
  local spans = { pad_span(0.1, 1.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.1, snap_min_silence = 0.02 },
                  { start = 0.0, stop = 10.0 }, function() return -80 end, -60)
  assert(spans[1].start >= 0.0 - 1e-9, "start escaped bounds: " .. spans[1].start)
end)

test("raw boundaries are still recorded when snapping", function()
  local spans = { pad_span(2.0, 3.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5, snap_min_silence = 0.05 },
                  nil, function() return -80 end, -60)
  assert(near(spans[1].raw_start, 2.0) and near(spans[1].raw_stop, 3.0),
    "raw boundaries must survive so the report can compare them")
end)

--------------------------------
-- AssignNames
--------------------------------
print("\nAssignNames:")

-- Two takes of vo_a plus a single take of vo_b, already chronological. Grouping
-- keys off the asset (Filename), so the two vo_a spans are takes of one line.
local function take_spans()
  return {
    { kind = "match", asset = "vo_a", score = 0.95, start = 0, stop = 1 },
    { kind = "match", asset = "vo_b", score = 0.93, start = 2, stop = 3 },
    { kind = "match", asset = "vo_a", score = 0.97, start = 5, stop = 6 },
  }
end

-- `select_index` is the span the user ticked in Overview. There is no
-- first/last fallback any more: an unticked multi-take line has no primary.
local function assigned(cfg, select_index)
  local spans = take_spans()
  if select_index then spans[select_index].select = true end
  vo.AssignNames(spans, cfg)
  return spans
end

test("takes of one line are numbered chronologically", function()
  local s = assigned({})
  assert(s[1].take_index == 1, "first take: " .. tostring(s[1].take_index))
  assert(s[3].take_index == 2, "second take: " .. tostring(s[3].take_index))
  assert(s[2].take_index == 1, "L2 is its own take 1: " .. tostring(s[2].take_index))
end)

test("a line with one take is always its own primary", function()
  local s = assigned({})
  assert(s[2].primary == true, "L2 should be primary")
  assert(s[2].dest == "selects" and s[2].name == "vo_b", "L2 routing/name")
end)

test("combo 1 - alts off, suffix off, later take selected: all to selects, bare names", function()
  local s = assigned({ use_alts_track = false, suffix_alt_names = false }, 3)
  assert(s[1].dest == "selects" and s[3].dest == "selects", "both to selects")
  assert(s[1].name == "vo_a" and s[3].name == "vo_a", "both bare")
end)

test("combo 2 - alts off, suffix off, earlier take selected: all to selects, bare names", function()
  local s = assigned({ use_alts_track = false, suffix_alt_names = false }, 1)
  assert(s[1].dest == "selects" and s[3].dest == "selects", "both to selects")
  assert(s[1].name == "vo_a" and s[3].name == "vo_a", "both bare")
end)

test("combo 3 - alts off, suffix on, later take selected: earlier take suffixed", function()
  local s = assigned({ use_alts_track = false, suffix_alt_names = true }, 3)
  assert(s[1].name == "vo_a_tk01", "take 1: " .. s[1].name)
  assert(s[3].name == "vo_a", "primary: " .. s[3].name)
  assert(s[1].dest == "selects" and s[3].dest == "selects", "both to selects")
end)

test("combo 4 - alts off, suffix on, earlier take selected: later take suffixed", function()
  local s = assigned({ use_alts_track = false, suffix_alt_names = true }, 1)
  assert(s[1].name == "vo_a", "primary: " .. s[1].name)
  assert(s[3].name == "vo_a_tk02", "take 2: " .. s[3].name)
end)

test("combo 5 - alts on, suffix off, later take selected: earlier take to alts", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = false }, 3)
  assert(s[1].dest == "alts", "take 1 dest: " .. s[1].dest)
  assert(s[3].dest == "selects", "primary dest: " .. s[3].dest)
  assert(s[1].name == "vo_a" and s[3].name == "vo_a", "both bare")
end)

test("combo 6 - alts on, suffix off, earlier take selected: later take to alts", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = false }, 1)
  assert(s[1].dest == "selects", "primary dest: " .. s[1].dest)
  assert(s[3].dest == "alts", "take 2 dest: " .. s[3].dest)
end)

test("combo 7 - alts on, suffix on, later take selected", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = true }, 3)
  assert(s[1].dest == "alts" and s[1].name == "vo_a_tk01", s[1].dest .. "/" .. s[1].name)
  assert(s[3].dest == "selects" and s[3].name == "vo_a", s[3].dest .. "/" .. s[3].name)
end)

test("combo 8 - alts on, suffix on, earlier take selected", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = true }, 1)
  assert(s[1].dest == "selects" and s[1].name == "vo_a", s[1].dest .. "/" .. s[1].name)
  assert(s[3].dest == "alts" and s[3].name == "vo_a_tk02", s[3].dest .. "/" .. s[3].name)
end)

test("a single-take line never goes to alts even with the toggle on", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = true }, 3)
  assert(s[2].dest == "selects" and s[2].name == "vo_b", s[2].dest .. "/" .. s[2].name)
end)

test("a several-take line with no select has no primary at all", function()
  local s = assigned({ suffix_alt_names = true })
  assert(s[1].primary == false and s[3].primary == false,
    "Guessing which take was meant is what Select exists to stop")
  assert(s[1].name == "vo_a_tk01" and s[3].name == "vo_a_tk02",
    "Both takes are suffixed when none is the primary")
end)

test("a single take is primary even without a select, so it is never suffixed", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = true })
  assert(s[2].primary == true, "A group of one has nothing to choose between")
  assert(s[2].dest == "selects" and s[2].name == "vo_b", s[2].dest .. "/" .. s[2].name)
end)

test("low-confidence spans go to review named with their score", function()
  local spans = { { kind = "review", asset = "vo_npc_greet_01", score = 0.67, start = 0, stop = 1 } }
  vo.AssignNames(spans, {})
  assert(spans[1].dest == "review", "dest: " .. spans[1].dest)
  assert(spans[1].name == "REVIEW_vo_npc_greet_01_s0.67", "name: " .. spans[1].name)
end)

test("unmatched spans stay in place, labelled from their transcript", function()
  local spans = { { kind = "unmatched", transcript = "take two", start = 0, stop = 1 } }
  vo.AssignNames(spans, {})
  assert(spans[1].dest == vo.DEST_IN_PLACE, "dest: " .. spans[1].dest)
  assert(spans[1].dest ~= "review", "unmatched must not route to the Review track")
  -- The name is a report label, not a take name: nothing is cut for this span.
  assert(spans[1].name == "UNMATCHED_take_two", "name: " .. spans[1].name)
end)

test("long unmatched transcripts are trimmed to a snippet", function()
  local spans = { { kind = "unmatched", transcript = "one two three four five six", start = 0, stop = 1 } }
  vo.AssignNames(spans, { unmatched_snippet_words = 3 })
  assert(spans[1].name == "UNMATCHED_one_two_three", "name: " .. spans[1].name)
end)

test("an unmatched span with no transcript still gets a name", function()
  local spans = { { kind = "unmatched", transcript = "", start = 0, stop = 1 } }
  vo.AssignNames(spans, {})
  assert(spans[1].name == "UNMATCHED_unnamed", "name: " .. spans[1].name)
end)

test("review and unmatched prefixes are configurable", function()
  local spans = {
    { kind = "review",    asset = "vo_a", score = 0.6, start = 0, stop = 1 },
    { kind = "unmatched", transcript = "hey",  start = 2, stop = 3 },
  }
  vo.AssignNames(spans, { review_prefix = "CHK_", unmatched_prefix = "JUNK_" })
  assert(spans[1].name == "CHK_vo_a_s0.60", "name: " .. spans[1].name)
  assert(spans[2].name == "JUNK_hey", "name: " .. spans[2].name)
end)

test("names are passed through the sanitizer", function()
  local spans = { { kind = "match", asset = "vo/a b", score = 0.9, start = 0, stop = 1 } }
  vo.AssignNames(spans, {})
  assert(spans[1].name == "vo_a_b", "name: " .. spans[1].name)
end)

test("review spans do not consume take numbers from delivered takes", function()
  local spans = {
    { kind = "review", asset = "vo_a", score = 0.60, start = 0, stop = 1 },
    { kind = "match",  asset = "vo_a", score = 0.95, start = 2, stop = 3 },
    { kind = "match",  asset = "vo_a", score = 0.97, start = 4, stop = 5, select = true },
  }
  vo.AssignNames(spans, { suffix_alt_names = true })
  assert(spans[2].take_index == 1, "first delivered take: " .. tostring(spans[2].take_index))
  assert(spans[2].name == "vo_a_tk01", "name: " .. spans[2].name)
  assert(spans[3].name == "vo_a", "primary: " .. spans[3].name)
end)

-- Two sources each holding a read of the same line. Each half was named on its
-- own -- a group of one, so each is its own primary with a bare name -- and if
-- nothing re-names the union, Cut puts two items named "L001" on Selects.
-- The later read carries the user's Select, which is what makes it the primary
-- once the two halves are numbered together.
local function separately_named_halves(cfg)
  local a = { { kind = "match", asset = "L001", score = 0.95, start = 0, stop = 1 } }
  local b = { { kind = "match", asset = "L001", score = 0.96, start = 9, stop = 10,
                select = true } }
  vo.AssignNames(a, cfg)
  vo.AssignNames(b, cfg)
  local union = {}
  for _, s in ipairs(a) do union[#union + 1] = s end
  for _, s in ipairs(b) do union[#union + 1] = s end
  return union
end

test("halves named in isolation both claim take 1 and primary (the collision)", function()
  local u = separately_named_halves({ suffix_alt_names = true })
  assert(u[1].take_index == 1 and u[2].take_index == 1, "both should still be take 1")
  assert(u[1].primary and u[2].primary, "both should still be primary")
  assert(u[1].name == u[2].name, "both should still carry the same name")
end)

test("re-naming the union gives one primary and distinct take numbers", function()
  local u = separately_named_halves({ suffix_alt_names = true })
  vo.AssignNames(u, { suffix_alt_names = true })
  assert(u[1].take_index == 1, "earlier take: " .. tostring(u[1].take_index))
  assert(u[2].take_index == 2, "later take: " .. tostring(u[2].take_index))
  local primaries = 0
  for _, s in ipairs(u) do if s.primary then primaries = primaries + 1 end end
  assert(primaries == 1, "exactly one primary, got " .. primaries)
  assert(u[1].name ~= u[2].name, "names must differ: " .. u[1].name .. " / " .. u[2].name)
  assert(u[1].name == "L001_tk01" and u[2].name == "L001", u[1].name .. " / " .. u[2].name)
end)

test("re-naming the union routes the non-primary to alts", function()
  local u = separately_named_halves({ use_alts_track = true })
  vo.AssignNames(u, { use_alts_track = true })
  assert(u[1].dest == "alts", "earlier take dest: " .. tostring(u[1].dest))
  assert(u[2].dest == "selects", "primary dest: " .. tostring(u[2].dest))
end)

test("AssignNames is idempotent over an already-named plan", function()
  local cfg = { use_alts_track = true, suffix_alt_names = true }
  local once = take_spans()
  vo.AssignNames(once, cfg)
  local snapshot = {}
  for i, s in ipairs(once) do
    snapshot[i] = { s.take_index, s.primary, s.dest, s.name }
  end
  for _ = 1, 3 do vo.AssignNames(once, cfg) end
  for i, s in ipairs(once) do
    assert(s.take_index == snapshot[i][1], "take_index drifted at " .. i)
    assert(s.primary    == snapshot[i][2], "primary drifted at " .. i)
    assert(s.dest       == snapshot[i][3], "dest drifted at " .. i)
    assert(s.name       == snapshot[i][4], "name drifted at " .. i)
  end
end)

test("re-running over the union is itself idempotent", function()
  local cfg = { suffix_alt_names = true }
  local u = separately_named_halves(cfg)
  vo.AssignNames(u, cfg)
  local n1, n2, t1, t2 = u[1].name, u[2].name, u[1].take_index, u[2].take_index
  vo.AssignNames(u, cfg)
  assert(u[1].name == n1 and u[2].name == n2, "names drifted on the second pass")
  assert(u[1].take_index == t1 and u[2].take_index == t2, "take numbers drifted")
end)

test("take numbering does not depend on input order when four takes tie on every other key", function()
  -- table.sort is not stable, so spans tied on start/stop/transcript must be
  -- broken by a further key (score) or their relative order -- and thus
  -- take_index -- depends on whatever order they happened to arrive in
  -- (e.g. CSV row order from a reload), rather than on the spans themselves.
  -- With only two tied elements, Lua 5.4's table.sort preserves input order
  -- regardless of tie-break logic, so this needs at least four spans tied on
  -- every key but `score` before an order-dependent (pre-fix) comparator
  -- actually produces a different permutation for a different input order.
  local cfg = { suffix_alt_names = true }

  local function make(order)
    local by_id = {
      { kind = "match", asset = "L001", start = 4, stop = 5, transcript = "x", score = 0.4, id = 1 },
      { kind = "match", asset = "L001", start = 4, stop = 5, transcript = "x", score = 0.3, id = 2 },
      { kind = "match", asset = "L001", start = 4, stop = 5, transcript = "x", score = 0.2, id = 3 },
      { kind = "match", asset = "L001", start = 4, stop = 5, transcript = "x", score = 0.1, id = 4 },
    }
    local spans = {}
    for i, id in ipairs(order) do spans[i] = by_id[id] end
    return spans
  end

  local forward = make({ 1, 2, 3, 4 })
  local reverse = make({ 4, 3, 2, 1 })
  vo.AssignNames(forward, cfg)
  vo.AssignNames(reverse, cfg)

  local by_id_forward, by_id_reverse = {}, {}
  for _, s in ipairs(forward) do by_id_forward[s.id] = s.take_index end
  for _, s in ipairs(reverse) do by_id_reverse[s.id] = s.take_index end

  for id = 1, 4 do
    assert(by_id_forward[id] == by_id_reverse[id],
      "take_index for span id " .. id .. " depends on input order: "
      .. tostring(by_id_forward[id]) .. " vs " .. tostring(by_id_reverse[id]))
  end
end)

--------------------------------
-- BuildWhisperArgv
--------------------------------
print("\nBuildWhisperArgv:")

local function argv_index(argv, flag)
  for i, a in ipairs(argv) do
    if a == flag then return i end
  end
  return nil
end

local function argv_value(argv, flag)
  local i = argv_index(argv, flag)
  return i and argv[i + 1] or nil
end

local WHISPER_CFG = {
  whisper_bin = "C:/tools/whisper-cli.exe",
  whisper_model = "C:/models/ggml-base.bin",
  whisper_threads = 8,
  whisper_language = "en",
}

test("argv[1] is the configured binary", function()
  local argv = vo.BuildWhisperArgv(WHISPER_CFG, "in.wav", "out")
  assert(argv[1] == "C:/tools/whisper-cli.exe", "argv[1]: " .. tostring(argv[1]))
end)

test("word-level timestamps are forced with -ml 1 and -sow", function()
  local argv = vo.BuildWhisperArgv(WHISPER_CFG, "in.wav", "out")
  assert(argv_value(argv, "-ml") == "1", "-ml: " .. tostring(argv_value(argv, "-ml")))
  assert(argv_index(argv, "-sow"), "-sow missing")
end)

test("CSV output is requested", function()
  local argv = vo.BuildWhisperArgv(WHISPER_CFG, "in.wav", "out")
  assert(argv_index(argv, "-ocsv"), "-ocsv missing")
end)

test("input file, model and output prefix are passed", function()
  local argv = vo.BuildWhisperArgv(WHISPER_CFG, "in.wav", "out")
  assert(argv_value(argv, "-f") == "in.wav", "-f: " .. tostring(argv_value(argv, "-f")))
  assert(argv_value(argv, "-m") == "C:/models/ggml-base.bin", "-m wrong")
  assert(argv_value(argv, "-of") == "out", "-of: " .. tostring(argv_value(argv, "-of")))
end)

test("threads and language come from config", function()
  local argv = vo.BuildWhisperArgv(WHISPER_CFG, "in.wav", "out")
  assert(argv_value(argv, "-t") == "8", "-t: " .. tostring(argv_value(argv, "-t")))
  assert(argv_value(argv, "-l") == "en", "-l: " .. tostring(argv_value(argv, "-l")))
end)

test("a known model maps to its dtw preset", function()
  local argv = vo.BuildWhisperArgv(WHISPER_CFG, "in.wav", "out")
  assert(argv_value(argv, "-dtw") == "base", "-dtw: " .. tostring(argv_value(argv, "-dtw")))
end)

test("large model versions map to their own presets", function()
  local cfg = { whisper_model = "/m/ggml-large-v3.bin" }
  assert(vo.DTWPresetForModel(cfg.whisper_model) == "large.v3",
    tostring(vo.DTWPresetForModel(cfg.whisper_model)))
end)

test("an unrecognised model emits no dtw flag rather than an invalid one", function()
  local argv = vo.BuildWhisperArgv({ whisper_model = "/m/ggml-base.en.bin" }, "in.wav", "out")
  assert(argv_index(argv, "-dtw") == nil, "-dtw should be omitted for unverified presets")
end)

test("a missing binary falls back to the bare command name", function()
  local argv = vo.BuildWhisperArgv({}, "in.wav", "out")
  assert(argv[1] == "whisper-cli", "argv[1]: " .. tostring(argv[1]))
end)

test("prior-text conditioning is disabled so the decoder cannot loop", function()
  local argv = vo.BuildWhisperArgv(WHISPER_CFG, "in.wav", "out")
  assert(argv_value(argv, "-mc") == "0", "-mc: " .. tostring(argv_value(argv, "-mc")))
end)

test("speech is only discarded when it is almost certainly not speech", function()
  local argv = vo.BuildWhisperArgv(WHISPER_CFG, "in.wav", "out")
  assert(tonumber(argv_value(argv, "-nth")) >= 0.9,
    "-nth: " .. tostring(argv_value(argv, "-nth")))
end)

--------------------------------
-- DetectRepetitionLoop
--------------------------------
print("\nDetectRepetitionLoop:")

local function loop_words(list)
  local out = {}
  for i, w in ipairs(list) do
    out[i] = { t0 = i * 1.0, t1 = i * 1.0 + 0.5, text = w }
  end
  return out
end

local function repeated(phrase, times, before, after)
  local list = {}
  for _, w in ipairs(before or {}) do list[#list + 1] = w end
  for _ = 1, times do
    for _, w in ipairs(phrase) do list[#list + 1] = w end
  end
  for _, w in ipairs(after or {}) do list[#list + 1] = w end
  return loop_words(list)
end

test("clean speech reports no loop", function()
  local words = loop_words({ "the", "quick", "brown", "fox", "jumps", "over",
                             "the", "lazy", "dog", "and", "then", "sleeps" })
  assert(vo.DetectRepetitionLoop(words) == nil, "clean speech flagged as a loop")
end)

test("ordinary repetition in a read is not a loop", function()
  -- "no, no, no, no" and a repeated two-word beat both stay under threshold.
  assert(vo.DetectRepetitionLoop(repeated({ "no" }, 5)) == nil, "5 repeats flagged")
  assert(vo.DetectRepetitionLoop(repeated({ "get", "out" }, 3)) == nil, "3 cycles flagged")
end)

test("a repeated phrase past both thresholds is reported", function()
  local phrase = { "Riddle", "that", "punish", "you", "for", "answering." }
  local found = vo.DetectRepetitionLoop(repeated(phrase, 40, { "and", "so" }))
  assert(found, "loop not detected")
  assert(found.cycles == 40, "cycles: " .. tostring(found.cycles))
  assert(found.words == 240, "words: " .. tostring(found.words))
  assert(found.phrase == "Riddle that punish you for answering.",
    "phrase: " .. tostring(found.phrase))
end)

test("the reported span is where the loop starts and ends, not the whole file", function()
  local found = vo.DetectRepetitionLoop(repeated({ "a", "b" }, 10, { "x", "y", "z" }))
  -- three leading words, so the loop's first word is index 4 (t0 = 4.0) and its
  -- last is index 23 (t1 = 23.5).
  assert(math.abs(found.from - 4.0) < 1e-9, "from: " .. tostring(found.from))
  assert(math.abs(found.to - 23.5) < 1e-9, "to: " .. tostring(found.to))
end)

test("the longest run wins when a file contains more than one", function()
  local list = {}
  for _, w in ipairs(repeated({ "short" }, 14)) do list[#list + 1] = w.text end
  list[#list + 1] = "break"
  for _, w in ipairs(repeated({ "long", "one" }, 30)) do list[#list + 1] = w.text end
  local found = vo.DetectRepetitionLoop(loop_words(list))
  assert(found.phrase == "long one", "phrase: " .. tostring(found.phrase))
  assert(found.words == 60, "words: " .. tostring(found.words))
end)

test("an empty or nil transcript is handled without throwing", function()
  assert(vo.DetectRepetitionLoop(nil) == nil, "nil flagged")
  assert(vo.DetectRepetitionLoop({}) == nil, "empty flagged")
end)

--------------------------------
-- CSV output helpers
--------------------------------
print("\nEscapeCSVField:")

test("a plain field is untouched", function()
  assert(vo.EscapeCSVField("hello") == "hello", vo.EscapeCSVField("hello"))
end)

test("a field containing a comma is quoted", function()
  assert(vo.EscapeCSVField("a,b") == '"a,b"', vo.EscapeCSVField("a,b"))
end)

test("embedded quotes are doubled and the field quoted", function()
  assert(vo.EscapeCSVField('say "hi"') == '"say ""hi"""', vo.EscapeCSVField('say "hi"'))
end)

test("a field containing a newline is quoted", function()
  assert(vo.EscapeCSVField("a\nb") == '"a\nb"', vo.EscapeCSVField("a\nb"))
end)

--------------------------------
-- BuildPlan
--------------------------------
print("\nBuildMatch:")

-- BuildMatch plus the padding and naming that used to live inside BuildPlan.
-- The matching pipeline these tests exercise did not change; only where the
-- pieces live did, so the composition is rebuilt here rather than the coverage
-- thrown away. Padding and naming moved out because one needs sample access
-- and the other needs every source at once -- neither of which BuildMatch has.
local function build_named_plan(lines, words, cfg)
  local matched = vo.BuildMatch({ { path = "s.wav", words = words } }, lines, cfg)
  local plan = (matched[1] and matched[1].spans) or {}
  vo.ApplyPadding(plan, cfg, cfg and cfg.bounds)
  vo.AssignNames(plan, cfg)
  return plan
end

-- Deterministic synthetic transcript generator.
-- Emits a whisper-style word list from the script with controllable noise, so
-- the whole matching pipeline can be exercised against known ground truth with
-- no audio and no REAPER.
local function synthesize(lines, opts)
  opts = opts or {}
  math.randomseed(opts.seed or 20260721)

  local order = {}
  for i = 1, #lines do order[i] = i end
  if opts.shuffle then
    for i = #order, 2, -1 do
      local j = math.random(i)
      order[i], order[j] = order[j], order[i]
    end
  end

  local words, truth = {}, {}
  local t = 0.0

  local function emit(text)
    words[#words + 1] = { t0 = t, t1 = t + 0.30, text = text }
    t = t + 0.35
  end
  local function pause() t = t + 1.0 end

  local drop = opts.drop_rate or 0
  local sub  = opts.sub_rate or 0

  for _, li in ipairs(order) do
    local line = lines[li]
    local takes = (opts.repeats and opts.repeats[line.asset]) or 1
    for _ = 1, takes do
      if opts.slates then
        emit("take"); emit("two"); pause()
      end
      for w in line.text:gmatch("%S+") do
        local roll = math.random()
        if roll < drop then                 -- word dropped by the recognizer
        elseif roll < drop + sub then emit("uhh")  -- word misheard
        else emit(w) end
      end
      truth[#truth + 1] = line.asset
      pause()
    end
  end

  if opts.chatter then
    emit("okay"); emit("lets"); emit("move"); emit("on"); pause()
  end

  return words, truth
end

-- Load the sample script fixture the way the real action will.
local function load_fixture()
  local f = assert(io.open("tests/fixtures/vo_sample_script.csv", "r"),
                   "fixture not found - run from the repository root")
  local text = f:read("a")
  f:close()
  local rows = vo.ParseCSV(text)
  local header = table.remove(rows, 1)
  local cols = assert(vo.MapColumns(header, vo.DEFAULT_COLUMN_MAPPING))
  return vo.BuildScriptLines(rows, cols, {}), rows, cols
end

test("the sample fixture parses and drops the TO RECORD row", function()
  local lines = load_fixture()
  assert(#lines == 5, "Expected 5 usable lines, got " .. #lines)
  for _, l in ipairs(lines) do
    assert(l.asset ~= "TO RECORD", "TO RECORD leaked through")
  end
end)

test("the fixture's quoted commas and apostrophes survive parsing", function()
  local lines = load_fixture()
  assert(lines[2].text == "Open the north gate, quickly.", "text: " .. lines[2].text)
  assert(lines[5].text:find("I'll"), "apostrophe lost: " .. lines[5].text)
end)

test("a clean read of every line matches every line", function()
  local lines = load_fixture()
  local words = synthesize(lines)
  local plan  = build_named_plan(lines, words, {})

  local got = {}
  for _, s in ipairs(plan) do
    if s.kind == "match" then got[s.asset] = s.asset end
  end
  for _, l in ipairs(lines) do
    assert(got[l.asset] == l.asset,
      "Line " .. l.asset .. " expected " .. l.asset .. ", got " .. tostring(got[l.asset]))
  end
end)

test("lines recorded out of script order are still all matched", function()
  local lines = load_fixture()
  local words = synthesize(lines, { shuffle = true })
  local plan  = build_named_plan(lines, words, {})

  local count = 0
  for _, s in ipairs(plan) do
    if s.kind == "match" then count = count + 1 end
  end
  assert(count == #lines, "Expected " .. #lines .. " matches, got " .. count)
end)

test("slates and chatter become unmatched spans without losing any line", function()
  local lines = load_fixture()
  local words = synthesize(lines, { slates = true, chatter = true })
  local plan  = build_named_plan(lines, words, {})

  local matches, unmatched = 0, 0
  for _, s in ipairs(plan) do
    if s.kind == "match" then matches = matches + 1
    elseif s.kind == "unmatched" then unmatched = unmatched + 1 end
  end
  assert(matches == #lines, "Expected " .. #lines .. " matches, got " .. matches)
  assert(unmatched > 0, "Expected slates/chatter to surface as unmatched spans")
end)

test("unmatched spans are left in place, never routed to a track", function()
  local lines = load_fixture()
  local words = synthesize(lines, { slates = true, chatter = true })
  local plan  = build_named_plan(lines, words, {})
  for _, s in ipairs(plan) do
    if s.kind == "unmatched" then
      assert(s.dest == vo.DEST_IN_PLACE, "unmatched routed to " .. tostring(s.dest))
    end
  end
end)

test("a noisy transcript never silently loses a line", function()
  local lines = load_fixture()
  local words = synthesize(lines, { drop_rate = 0.10, sub_rate = 0.05, seed = 7 })
  local plan  = build_named_plan(lines, words, {})

  local found = {}
  for _, s in ipairs(plan) do
    if s.kind == "match" or s.kind == "review" then found[s.asset] = s.kind end
  end
  for _, l in ipairs(lines) do
    assert(found[l.asset], "Lost line " .. l.asset .. " to transcription noise")
  end
end)

test("a line missing one word of five is still a confident match", function()
  -- At this seed the recognizer drops the leading "Open" from vo_guard_gate_01.
  local lines = load_fixture()
  local words = synthesize(lines, { drop_rate = 0.10, sub_rate = 0.05, seed = 7 })
  local plan  = build_named_plan(lines, words, {})
  for _, s in ipairs(plan) do
    if s.asset == "vo_guard_gate_01" then
      assert(s.kind == "match", "vo_guard_gate_01 kind: " .. s.kind)
      assert(s.name == "vo_guard_gate_01", "vo_guard_gate_01 name: " .. s.name)
    end
  end
end)

test("a line missing a third of its words is flagged, not asserted", function()
  -- vo_hero_captain_01 loses 2 of its 6 words at this seed. A 0.67 score is a
  -- real match but not a confident one; the tool must say so rather than stamp
  -- an asset name on it. This is the guarantee the Review track exists to provide.
  local lines = load_fixture()
  local words = synthesize(lines, { drop_rate = 0.10, sub_rate = 0.05, seed = 7 })
  local plan  = build_named_plan(lines, words, {})
  local seen = false
  for _, s in ipairs(plan) do
    if s.asset == "vo_hero_captain_01" then
      seen = true
      assert(s.kind == "review", "vo_hero_captain_01 kind: " .. s.kind)
      assert(s.dest == "review", "vo_hero_captain_01 dest: " .. tostring(s.dest))
      assert(s.name:find("^REVIEW_"), "vo_hero_captain_01 name: " .. s.name)
    end
  end
  assert(seen, "vo_hero_captain_01 produced no span at all")
end)

test("a line recorded twice yields two numbered takes", function()
  local lines = load_fixture()
  local words = synthesize(lines, { repeats = { vo_guard_halt_01 = 2 } })
  local plan  = build_named_plan(lines, words, {})

  local takes = {}
  for _, s in ipairs(plan) do
    if s.kind == "match" and s.asset == "vo_guard_halt_01" then takes[#takes + 1] = s end
  end
  assert(#takes == 2, "Expected 2 takes of vo_guard_halt_01, got " .. #takes)
  table.sort(takes, function(a, b) return a.start < b.start end)
  assert(takes[1].take_index == 1 and takes[2].take_index == 2, "take numbering wrong")
end)

test("plan spans are chronological and never overlap", function()
  local lines = load_fixture()
  local words = synthesize(lines, { slates = true, repeats = { vo_guard_gate_01 = 2 } })
  local plan  = build_named_plan(lines, words, {})

  for i = 2, #plan do
    assert(plan[i].start >= plan[i - 1].start - 1e-9,
      "span " .. i .. " starts before its predecessor")
    assert(plan[i].start >= plan[i - 1].stop - 1e-9,
      "span " .. i .. " overlaps its predecessor")
  end
end)

test("every span carries a destination and a name", function()
  local lines = load_fixture()
  local words = synthesize(lines, { slates = true })
  local plan  = build_named_plan(lines, words, {})
  for i, s in ipairs(plan) do
    assert(s.dest, "span " .. i .. " has no dest")
    assert(s.name and s.name ~= "", "span " .. i .. " has no name")
    assert(s.stop > s.start, "span " .. i .. " has non-positive length")
  end
end)

test("an empty word stream yields an empty plan", function()
  local lines = load_fixture()
  assert(#build_named_plan(lines, {}, {}) == 0, "Expected an empty plan")
end)

--------------------------------
-- BuildMatch: the per-source contract
--------------------------------

-- Data rows only, and `cols` are column INDICES, not header names.
local function match_lines()
  return vo.BuildScriptLines(
    { { "vo_a_01", "RIVA", "we should not have come" },
      { "vo_b_01", "RIVA", "seal it nobody goes below" } },
    { asset = 1, speaker = 2, text = 3 }, {})
end

local function words_from(text, t0)
  local words, t = {}, t0 or 0
  for w in text:gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.2, text = w }
    t = t + 0.25
  end
  return words
end

test("one source produces one entry keyed by its path", function()
  local got = vo.BuildMatch(
    { { path = "D:/s/A.wav", words = words_from("we should not have come") } },
    match_lines(), {})
  assert(#got == 1, "Expected 1 result, got " .. #got)
  assert(got[1].path == "D:/s/A.wav", "Path: " .. tostring(got[1].path))
end)

test("the spoken line matches its script line", function()
  local got = vo.BuildMatch(
    { { path = "D:/s/A.wav", words = words_from("we should not have come") } },
    match_lines(), {})
  local found = false
  for _, s in ipairs(got[1].spans) do
    if s.kind == "match" and s.asset == "vo_a_01" then found = true end
  end
  assert(found, "vo_a_01 was not matched")
end)

test("two sources speaking the same line each get their own span", function()
  local got = vo.BuildMatch({
    { path = "D:/s/A.wav", words = words_from("we should not have come") },
    { path = "D:/s/B.wav", words = words_from("we should not have come") },
  }, match_lines(), {})
  assert(#got == 2, "Expected 2 results, got " .. #got)
  for _, entry in ipairs(got) do
    local hits = 0
    for _, s in ipairs(entry.spans) do
      if s.kind == "match" and s.asset == "vo_a_01" then hits = hits + 1 end
    end
    assert(hits == 1, entry.path .. " produced " .. hits .. " matches, expected 1")
  end
end)

test("spans come back in time order and carry their transcript", function()
  local got = vo.BuildMatch(
    { { path = "D:/s/A.wav", words = words_from("we should not have come") } },
    match_lines(), {})
  local last = -math.huge
  for _, s in ipairs(got[1].spans) do
    assert(s.start >= last, "Spans out of order")
    last = s.start
    assert(type(s.transcript) == "string", "Span has no transcript")
  end
end)

test("no padding is applied -- start equals the first word's own time", function()
  local words = words_from("we should not have come", 5.0)
  local got = vo.BuildMatch({ { path = "D:/s/A.wav", words = words } },
                            match_lines(), { pre_pad = 1.0, post_pad = 1.0 })
  for _, s in ipairs(got[1].spans) do
    if s.kind == "match" then
      assert(s.start >= 5.0 - 1e-6,
             "Padding leaked into BuildMatch: start=" .. tostring(s.start))
    end
  end
end)

test("no names are assigned -- that is the cutter's job", function()
  local got = vo.BuildMatch(
    { { path = "D:/s/A.wav", words = words_from("we should not have come") } },
    match_lines(), {})
  for _, s in ipairs(got[1].spans) do
    assert(s.name == nil, "Span already named: " .. tostring(s.name))
    assert(s.dest == nil, "Span already routed: " .. tostring(s.dest))
  end
end)

test("an empty transcript list returns an empty result", function()
  assert(#vo.BuildMatch({}, match_lines(), {}) == 0, "Expected no results")
end)

test("a source with no words still returns an entry with no spans", function()
  local got = vo.BuildMatch({ { path = "D:/s/A.wav", words = {} } }, match_lines(), {})
  assert(#got == 1, "Expected 1 result, got " .. #got)
  assert(#got[1].spans == 0, "Expected no spans, got " .. #got[1].spans)
end)

test("audio with no script match produces only unmatched spans", function()
  local lines = load_fixture()
  local words = {}
  local t = 0
  for w in ("completely unrelated studio chatter about lunch"):gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.3, text = w }
    t = t + 0.35
  end
  local plan = build_named_plan(lines, words, {})
  for _, s in ipairs(plan) do
    assert(s.kind == "unmatched", "Expected only unmatched spans, got " .. s.kind)
  end
end)
--------------------------------
-- QuoteArg
--------------------------------
print("\nQuoteArg:")

test("Windows: a plain path is wrapped in double quotes", function()
  assert(vo.QuoteArg("C:/a b/x.wav", "Windows") == '"C:/a b/x.wav"', vo.QuoteArg("C:/a b/x.wav", "Windows"))
end)

test("Windows: interior double quotes are escaped", function()
  assert(vo.QuoteArg('a"b', "Windows") == '"a\\"b"', vo.QuoteArg('a"b', "Windows"))
end)

test("POSIX: a plain path is wrapped in single quotes", function()
  assert(vo.QuoteArg("/a b/x.wav", "Other") == "'/a b/x.wav'", vo.QuoteArg("/a b/x.wav", "Other"))
end)

test("POSIX: interior single quotes are escaped", function()
  assert(vo.QuoteArg("it's", "Other") == "'it'\\''s'", vo.QuoteArg("it's", "Other"))
end)

--------------------------------
-- CacheKey
--------------------------------
print("\nCacheKey:")

local CACHE_CFG = { whisper_model = "/m/ggml-base.bin", whisper_language = "en" }

test("the same inputs always produce the same key", function()
  local a = vo.CacheKey("/audio/take.wav", 1024, CACHE_CFG)
  local b = vo.CacheKey("/audio/take.wav", 1024, CACHE_CFG)
  assert(a == b, a .. " ~= " .. b)
end)

test("a different source path produces a different key", function()
  assert(vo.CacheKey("/audio/a.wav", 1024, CACHE_CFG) ~= vo.CacheKey("/audio/b.wav", 1024, CACHE_CFG),
    "Key ignored the source path")
end)

test("a re-recorded file of a different size invalidates the key", function()
  assert(vo.CacheKey("/a.wav", 1024, CACHE_CFG) ~= vo.CacheKey("/a.wav", 2048, CACHE_CFG),
    "Key ignored the file size")
end)

test("changing the model invalidates the key", function()
  local other = { whisper_model = "/m/ggml-small.bin", whisper_language = "en" }
  assert(vo.CacheKey("/a.wav", 1024, CACHE_CFG) ~= vo.CacheKey("/a.wav", 1024, other),
    "Key ignored the model")
end)

test("changing the language invalidates the key", function()
  local other = { whisper_model = "/m/ggml-base.bin", whisper_language = "de" }
  assert(vo.CacheKey("/a.wav", 1024, CACHE_CFG) ~= vo.CacheKey("/a.wav", 1024, other),
    "Key ignored the language")
end)

test("the key is safe to use as a filename", function()
  local k = vo.CacheKey("C:/Sessions/take 01.wav", 999, CACHE_CFG)
  assert(k:match("^vo_%x+$"), "Unsafe cache key: " .. k)
end)

--------------------------------
-- LoadConfig / SaveConfig
--------------------------------
print("\nConfig:")

test("an empty ExtState yields documented defaults", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  assert(cfg.accept_threshold == 0.80, "accept: " .. tostring(cfg.accept_threshold))
  assert(cfg.review_floor == 0.55, "floor: " .. tostring(cfg.review_floor))
  assert(cfg.track_selects == "Selects", "selects: " .. tostring(cfg.track_selects))
  assert(cfg.track_review == "Review", "review: " .. tostring(cfg.track_review))
  assert(cfg.whisper_language == "en", "language: " .. tostring(cfg.whisper_language))
end)

test("numbers round-trip through save and load", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  cfg.accept_threshold = 0.72
  cfg.pre_pad = 0.4
  cfg.whisper_threads = 12
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(math.abs(back.accept_threshold - 0.72) < 1e-9, "accept: " .. back.accept_threshold)
  assert(math.abs(back.pre_pad - 0.4) < 1e-9, "pre_pad: " .. back.pre_pad)
  assert(back.whisper_threads == 12, "threads: " .. tostring(back.whisper_threads))
end)

-- The snapping keys existed in vo.DEFAULTS before they were in the schema, so
-- vo.Opt answered with them while LoadConfig did not -- a setting the user could
-- change and never keep. These two assert the whole path, not just the default.
test("the snapping settings default to the documented values", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  assert(cfg.snap_boundaries == true, "snap: " .. tostring(cfg.snap_boundaries))
  assert(math.abs(cfg.snap_min_silence - 0.060) < 1e-9, "min silence: " .. tostring(cfg.snap_min_silence))
  assert(math.abs(cfg.snap_floor_offset - 6.0) < 1e-9, "offset: " .. tostring(cfg.snap_floor_offset))
  assert(math.abs(cfg.snap_floor_window - 0.500) < 1e-9, "window: " .. tostring(cfg.snap_floor_window))
end)

test("the snapping settings round-trip through save and load", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  cfg.snap_boundaries   = false
  cfg.snap_min_silence  = 0.12
  cfg.snap_floor_offset = 9.5
  cfg.snap_floor_window = 0.25
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(back.snap_boundaries == false, "snap: " .. tostring(back.snap_boundaries))
  assert(math.abs(back.snap_min_silence - 0.12) < 1e-9, "min silence: " .. tostring(back.snap_min_silence))
  assert(math.abs(back.snap_floor_offset - 9.5) < 1e-9, "offset: " .. tostring(back.snap_floor_offset))
  assert(math.abs(back.snap_floor_window - 0.25) < 1e-9, "window: " .. tostring(back.snap_floor_window))
end)

test("booleans round-trip rather than becoming truthy strings", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  cfg.snap_boundaries = true
  cfg.force_retranscribe = false
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(back.snap_boundaries == true, "snap_boundaries: " .. tostring(back.snap_boundaries))
  assert(back.force_retranscribe == false, "force_retranscribe: " .. tostring(back.force_retranscribe))
end)

test("strings round-trip", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  cfg.whisper_model = "C:/models/ggml-medium.bin"
  cfg.track_review = "Needs Checking"
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(back.whisper_model == "C:/models/ggml-medium.bin", back.whisper_model)
  assert(back.track_review == "Needs Checking", back.track_review)
end)

test("the column mapping round-trips", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  assert(cfg.column_mapping.asset == "Filename", "default asset column")
  cfg.column_mapping.asset = "AssetName"
  cfg.column_mapping.text  = "Dialogue"
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(back.column_mapping.asset == "AssetName", back.column_mapping.asset)
  assert(back.column_mapping.text == "Dialogue", back.column_mapping.text)
  assert(back.column_mapping.speaker == "Character", "untouched column changed")
end)

test("skip values round-trip and default to TO RECORD", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  assert(#cfg.skip_values == 1 and cfg.skip_values[1] == "TO RECORD", "default skip values")
  cfg.skip_values = { "TO RECORD", "HOLD", "CUT" }
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(#back.skip_values == 3, "count: " .. #back.skip_values)
  assert(back.skip_values[3] == "CUT", back.skip_values[3])
end)

test("the substitution table round-trips", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  cfg.substitutions = { hp = "hit points", ["1999"] = "nineteen ninety nine" }
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(back.substitutions.hp == "hit points", tostring(back.substitutions.hp))
  assert(back.substitutions["1999"] == "nineteen ninety nine", tostring(back.substitutions["1999"]))
end)

test("an empty substitution table round-trips as empty", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  cfg.substitutions = {}
  vo.SaveConfig(cfg)
  local back = vo.LoadConfig()
  assert(next(back.substitutions) == nil, "Expected no substitutions")
end)

test("a loaded config drives Normalize and BuildWhisperArgv directly", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  cfg.substitutions = { hp = "hit points" }
  cfg.whisper_model = "/m/ggml-base.bin"
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(vo.Normalize("my hp", back.substitutions) == "my hit points", "config did not reach Normalize")
  local argv = vo.BuildWhisperArgv(back, "in.wav", "out")
  assert(argv_value(argv, "-dtw") == "base", "config did not reach BuildWhisperArgv")
end)

--------------------------------
-- MapWordsToProject
--------------------------------
print("\nMapWordsToProject:")

-- An item at project position 10s, 4s long, playing its source from 0s at 1x.
local function item_at(pos, length, start_offs, playrate)
  return { pos = pos, length = length, start_offs = start_offs or 0, playrate = playrate or 1.0 }
end

test("source time maps to project time through the item position", function()
  local w = vo.MapWordsToProject({ { t0 = 2.0, t1 = 2.5, text = "x" } }, item_at(10, 4))
  assert(#w == 1, "Expected 1 word, got " .. #w)
  assert(near(w[1].t0, 12.0), "t0: " .. w[1].t0)
  assert(near(w[1].t1, 12.5), "t1: " .. w[1].t1)
end)

test("the take's start offset is subtracted", function()
  local w = vo.MapWordsToProject({ { t0 = 7.0, t1 = 7.5, text = "x" } }, item_at(10, 4, 5.0))
  assert(near(w[1].t0, 12.0), "t0: " .. w[1].t0)
end)

test("playrate compresses source time into project time", function()
  local w = vo.MapWordsToProject({ { t0 = 4.0, t1 = 5.0, text = "x" } }, item_at(10, 4, 0, 2.0))
  assert(near(w[1].t0, 12.0), "t0: " .. w[1].t0)
  assert(near(w[1].t1, 12.5), "t1: " .. w[1].t1)
end)

test("words before the visible source range are dropped", function()
  -- Item shows source 5s..9s; a word at 1s is trimmed off the front of the item.
  local w = vo.MapWordsToProject({ { t0 = 1.0, t1 = 1.5, text = "x" } }, item_at(10, 4, 5.0))
  assert(#w == 0, "Expected the word to be dropped, got " .. #w)
end)

test("words after the visible source range are dropped", function()
  local w = vo.MapWordsToProject({ { t0 = 20.0, t1 = 20.5, text = "x" } }, item_at(10, 4, 5.0))
  assert(#w == 0, "Expected the word to be dropped, got " .. #w)
end)

test("a word is kept or dropped by its midpoint, not its edges", function()
  -- Source range is 0s..4s. This word straddles the end: midpoint 3.9 is inside.
  local w = vo.MapWordsToProject({ { t0 = 3.8, t1 = 4.0, text = "x" } }, item_at(10, 4))
  assert(#w == 1, "A word mostly inside the item should be kept")
  -- This one straddles with midpoint 4.1, outside.
  local w2 = vo.MapWordsToProject({ { t0 = 4.0, t1 = 4.2, text = "x" } }, item_at(10, 4))
  assert(#w2 == 0, "A word mostly outside the item should be dropped")
end)

test("word text and ordering are preserved", function()
  local w = vo.MapWordsToProject({
    { t0 = 0.0, t1 = 0.5, text = "one" },
    { t0 = 1.0, t1 = 1.5, text = "two" },
  }, item_at(10, 4))
  assert(#w == 2 and w[1].text == "one" and w[2].text == "two", "Order or text lost")
end)

test("a stretched item scales its visible source range too", function()
  -- At 2x playrate a 4s item consumes 8s of source, so a word at 7s is inside.
  local w = vo.MapWordsToProject({ { t0 = 7.0, t1 = 7.2, text = "x" } }, item_at(10, 4, 0, 2.0))
  assert(#w == 1, "Expected the word to be kept, got " .. #w)
  assert(near(w[1].t0, 13.5), "t0: " .. w[1].t0)
end)

--------------------------------
-- Substitution text (Settings panel editing)
--------------------------------
print("\nSubstitution text:")

test("a simple mapping parses", function()
  local subs = vo.ParseSubstitutionText("hp = hit points")
  assert(subs.hp == "hit points", tostring(subs.hp))
end)

test("surrounding whitespace is trimmed from both sides", function()
  local subs = vo.ParseSubstitutionText("   hp   =   hit points   ")
  assert(subs.hp == "hit points", "[" .. tostring(subs.hp) .. "]")
end)

test("keys are lowercased to match normalized tokens", function()
  local subs = vo.ParseSubstitutionText("HP = hit points")
  assert(subs.hp == "hit points", "Key was not folded: " .. tostring(next(subs)))
end)

test("a value may contain equals signs", function()
  local subs = vo.ParseSubstitutionText("eq = equals = sign")
  assert(subs.eq == "equals = sign", tostring(subs.eq))
end)

test("blank lines and lines without a separator are ignored", function()
  local subs = vo.ParseSubstitutionText("hp = hit points\n\nnonsense\n\nmp = magic")
  assert(subs.hp == "hit points" and subs.mp == "magic", "valid lines lost")
  assert(subs.nonsense == nil, "invalid line kept")
end)

test("a line with an empty key is ignored", function()
  local subs = vo.ParseSubstitutionText(" = orphaned")
  assert(next(subs) == nil, "Expected no substitutions")
end)

test("empty text yields an empty table", function()
  assert(next(vo.ParseSubstitutionText("")) == nil, "Expected empty")
  assert(next(vo.ParseSubstitutionText(nil)) == nil, "Expected empty")
end)

test("formatting is sorted so the panel does not reshuffle between opens", function()
  local text = vo.FormatSubstitutionText({ zulu = "z", alpha = "a", mike = "m" })
  assert(text == "alpha = a\nmike = m\nzulu = z", "[" .. text .. "]")
end)

test("format and parse round-trip", function()
  local original = { hp = "hit points", ["1999"] = "nineteen ninety nine" }
  local back = vo.ParseSubstitutionText(vo.FormatSubstitutionText(original))
  assert(back.hp == "hit points", tostring(back.hp))
  assert(back["1999"] == "nineteen ninety nine", tostring(back["1999"]))
end)

test("an empty table formats to an empty string", function()
  assert(vo.FormatSubstitutionText({}) == "", "Expected empty string")
end)

--------------------------------
-- Backend acquisition: catalogs & URLs
--------------------------------
print("Backend acquisition — catalogs & URLs:")

test("model download URL uses the HuggingFace resolve path", function()
  assert(vo.ModelDownloadURL("base") ==
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin",
    vo.ModelDownloadURL("base"))
end)

test("binary download URL is pinned to the release tag", function()
  assert(vo.BinaryDownloadURL("cuda-12.4") ==
    "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-cublas-12.4.0-bin-x64.zip",
    tostring(vo.BinaryDownloadURL("cuda-12.4")))
end)

test("binary download URL is nil for an unknown key", function()
  assert(vo.BinaryDownloadURL("nope") == nil)
end)

test("every offered model has a verified DTW preset", function()
  assert(#vo.MODEL_CATALOG == 5, "expected 5 models, got " .. #vo.MODEL_CATALOG)
  for _, m in ipairs(vo.MODEL_CATALOG) do
    assert(vo.DTWPresetForModel(m.filename) ~= nil,
      "no DTW preset for " .. m.filename)
    assert(m.expected_bytes and m.expected_bytes > 0, "bad size for " .. m.name)
  end
end)

test("large-v3-turbo is offered and maps to its verified DTW preset", function()
  local found
  for _, m in ipairs(vo.MODEL_CATALOG) do
    if m.name == "large-v3-turbo" then found = m end
  end
  assert(found, "large-v3-turbo missing from MODEL_CATALOG")
  assert(found.expected_bytes == 1624555275, "turbo size drift")
  assert(vo.DTWPresetForModel("ggml-large-v3-turbo.bin") == "large.v3.turbo",
    tostring(vo.DTWPresetForModel("ggml-large-v3-turbo.bin")))
end)

test("binary catalog carries the exact verified asset sizes", function()
  local by_key = {}
  for _, b in ipairs(vo.BINARY_CATALOG) do by_key[b.key] = b end
  assert(by_key["cuda-12.4"].expected_bytes == 677887125, "12.4 size drift")
  assert(by_key["cuda-11.8"].expected_bytes == 278557654, "11.8 size drift")
end)

test("FormatBytes scales into human units", function()
  assert(vo.FormatBytes(512) == "512 B", vo.FormatBytes(512))
  assert(vo.FormatBytes(1536) == "1.5 KB", vo.FormatBytes(1536))
  assert(vo.FormatBytes(677887125) == "646.5 MB", vo.FormatBytes(677887125))
end)

test("FormatTime reads as a transport position", function()
  assert(vo.FormatTime(0) == "0:00", vo.FormatTime(0))
  assert(vo.FormatTime(9.4) == "0:09", vo.FormatTime(9.4))
  assert(vo.FormatTime(1385.2) == "23:05", vo.FormatTime(1385.2))
  assert(vo.FormatTime(3725) == "1:02:05", vo.FormatTime(3725))
  assert(vo.FormatTime(nil) == "0:00", vo.FormatTime(nil))
end)

--------------------------------
-- Backend acquisition: paths, size checks, exe locator
--------------------------------
print("Backend acquisition — paths & filesystem helpers:")

-- Write a file of exactly `bytes` length; returns its path.
local function write_sized_file(bytes)
  local path = os.tmpname()
  local f = assert(io.open(path, "wb"))
  if bytes > 0 then f:write(string.rep("x", bytes)) end
  f:close()
  return path
end

test("ResolveModelsDir/ResolveBinDir append under the resource root", function()
  assert(vo.ResolveModelsDir("C:/RPR") == "C:/RPR/whisper-models", vo.ResolveModelsDir("C:/RPR"))
  assert(vo.ResolveBinDir("C:/RPR")    == "C:/RPR/whisper-bin",    vo.ResolveBinDir("C:/RPR"))
end)

test("PluginResourceRoot drops the VO segment and points at <repo>/Resources", function()
  assert(vo.PluginResourceRoot("C:/x/Scripts/ajsfx-ReaScripts/VO/") ==
    "C:/x/Scripts/ajsfx-ReaScripts/Resources",
    vo.PluginResourceRoot("C:/x/Scripts/ajsfx-ReaScripts/VO/"))
  -- tolerates a missing trailing separator and backslashes
  assert(vo.PluginResourceRoot("C:\\x\\ajsfx-ReaScripts\\VO") ==
    "C:\\x\\ajsfx-ReaScripts/Resources",
    vo.PluginResourceRoot("C:\\x\\ajsfx-ReaScripts\\VO"))
end)

test("VerifyDownloadSize passes at/above the 95% floor", function()
  local p = write_sized_file(1000)
  assert(vo.VerifyDownloadSize(p, 1000) == true, "exact size should pass")
  assert(vo.VerifyDownloadSize(p, 1050) == true, "95% floor should pass")
  os.remove(p)
end)

test("VerifyDownloadSize fails a truncated/error-page download", function()
  local p = write_sized_file(10)          -- tiny HTML error page saved as .bin
  assert(vo.VerifyDownloadSize(p, 1000) == false, "truncated should fail")
  os.remove(p)
end)

test("VerifyDownloadSize fails when the file is missing", function()
  assert(vo.VerifyDownloadSize("nope/does-not-exist.bin", 1000) == false)
end)

test("ModelIsInstalled reflects whether the model file is present", function()
  local dir = os.tmpname() .. "_models"
  os.execute((package.config:sub(1,1) == '\\'
    and ('mkdir "' .. dir .. '" 2>NUL')
    or  ('mkdir -p "' .. dir .. '" 2>/dev/null')))
  assert(vo.ModelIsInstalled(dir, "base") == false, "absent model must read as not installed")
  local f = assert(io.open(dir .. "/ggml-base.bin", "wb")); f:write("stub"); f:close()
  assert(vo.ModelIsInstalled(dir, "base") == true, "present model must read as installed")
  os.remove(dir .. "/ggml-base.bin")
end)

test("LocateWhisperCliExe finds the exe case-insensitively in a nested listing", function()
  local entries = {
    "C:/RPR/whisper-bin/README.txt",
    "C:/RPR/whisper-bin/Release/Whisper-CLI.exe",
    "C:/RPR/whisper-bin/Release/ggml.dll",
  }
  assert(vo.LocateWhisperCliExe(entries) == "C:/RPR/whisper-bin/Release/Whisper-CLI.exe",
    tostring(vo.LocateWhisperCliExe(entries)))
end)

test("LocateWhisperCliExe returns nil when absent or empty", function()
  assert(vo.LocateWhisperCliExe({ "a/b.dll" }) == nil)
  assert(vo.LocateWhisperCliExe({}) == nil)
end)

--------------------------------
-- Backend acquisition: device log parser
--------------------------------
print("\nBackend acquisition — device log parser:")

test("ParseBackendFromLog reports CUDA and the device name", function()
  local log = table.concat({
    "whisper_init_from_file_with_params_no_state: loading model",
    "ggml_cuda_init: found 1 CUDA devices:",
    "  Device 0: NVIDIA GeForce RTX 4070, compute capability 8.9",
    "whisper_backend_init_gpu: using CUDA0 backend",
  }, "\n")
  local d = vo.ParseBackendFromLog(log)
  assert(d.device == "CUDA", d.device)
  assert(d.name == "NVIDIA GeForce RTX 4070", tostring(d.name))
end)

test("ParseBackendFromLog reports CPU when no CUDA lines are present", function()
  local log = "whisper_backend_init: using CPU backend\nsystem_info: n_threads = 8"
  local d = vo.ParseBackendFromLog(log)
  assert(d.device == "CPU", d.device)
  assert(d.name == nil)
end)

test("ParseBackendFromLog reports CPU when CUDA is mentioned but no device is listed", function()
  local log = "ggml_cuda_init: found 0 CUDA devices:\nwhisper_backend_init: using CPU backend"
  local d = vo.ParseBackendFromLog(log)
  assert(d.device == "CPU", d.device)
  assert(d.name == nil)
end)

test("ParseBackendFromLog handles empty/nil input as CPU", function()
  assert(vo.ParseBackendFromLog("").device == "CPU")
  assert(vo.ParseBackendFromLog(nil).device == "CPU")
end)

--------------------------------
-- Backend acquisition: silent WAV writer (pure)
--------------------------------
print("Backend acquisition — WriteSilentWav:")

test("WriteSilentWav writes a valid 16k mono silent WAV of the right length", function()
  local p = os.tmpname()
  assert(vo.WriteSilentWav(p, 0.5) == true)
  local f = assert(io.open(p, "rb")); local b = f:read("a"); f:close()
  assert(b:sub(1, 4) == "RIFF", "missing RIFF")
  assert(b:sub(9, 12) == "WAVE", "missing WAVE")
  -- 16000 Hz * 0.5 s * 2 bytes/sample + 44-byte header
  assert(#b == 44 + 16000, "unexpected size " .. #b)
  os.remove(p)
end)

--------------------------------
-- CSV layout — distinct/auto-detect/validators
--------------------------------
print("\nCSV layout — distinct/auto-detect/validators:")

test("DistinctCharacters folds case/space, keeps first-seen display, drops empties", function()
  local rows = { {"a","Guard"}, {"b","guard"}, {"c",""}, {"d","Guard "}, {"e","Hero"} }
  local d = vo.DistinctCharacters(rows, 2)
  assert(#d == 2, "#d="..#d)
  assert(d[1].display == "Guard" and d[1].key == "guard", d[1].display.."/"..d[1].key)
  assert(d[2].display == "Hero", d[2].display)
  local canon = vo.CanonicalizeMap(d)
  assert(canon["guard"] == "Guard" and canon["hero"] == "Hero")
end)

test("AutoDetectMapping matches role aliases case-insensitively", function()
  local m = vo.AutoDetectMapping({ "VO Line", "Filename", "Character", "Category" })
  assert(m.asset == "Filename", tostring(m.asset))
  assert(m.speaker == "Character", tostring(m.speaker))
  -- "VO Line" folds to "vo line", which matches no text alias exactly, so text
  -- is left unmapped. Documents this real limitation rather than a tautology.
  assert(m.text == nil, "an unrecognized header should not auto-detect: " .. tostring(m.text))
end)

test("AutoDetectMapping maps the canonical Character/Filename/Line Text headers", function()
  local m = vo.AutoDetectMapping({ "Character", "Filename", "Line Text" })
  assert(m.speaker == "Character", tostring(m.speaker))
  assert(m.asset   == "Filename",  tostring(m.asset))
  assert(m.text    == "Line Text", tostring(m.text))
end)

test("ValidateHeaderNames rejects tab/newline in a column name", function()
  assert((vo.ValidateHeaderNames({ "A", "B" })) == true)
  assert((vo.ValidateHeaderNames({ "A", "B\tC" })) == false)
  assert((vo.ValidateHeaderNames({ "A", "B\nC" })) == false)
end)

test("ValidatePresetName enforces the naming rules", function()
  assert((vo.ValidatePresetName("Ubisoft VO")) == true)
  assert((vo.ValidatePresetName("")) == false)
  assert((vo.ValidatePresetName("__names__")) == false)
  assert((vo.ValidatePresetName("Boss=Final")) == false)
  assert((vo.ValidatePresetName("a\tb")) == false)
  assert((vo.ValidatePresetName(string.rep("x", 65))) == false)
end)

--------------------------------
-- CSV layout — serialize/deserialize
--------------------------------
print("\nCSV layout — serialize:")

test("SerializeLayout/DeserializeLayout round-trip incl. spaces and commas", function()
  local layout = {
    mapping = { text="VO, Text", asset="File Name", speaker="Character" },
    skip_values = { "TO RECORD", "HOLD" },
  }
  local back = vo.DeserializeLayout(vo.SerializeLayout(layout))
  assert(back.mapping.text == "VO, Text", back.mapping.text)
  assert(back.mapping.asset == "File Name")
  assert(back.mapping.speaker == "Character")
  assert(#back.skip_values == 2 and back.skip_values[1] == "TO RECORD" and back.skip_values[2] == "HOLD")
end)

test("DeserializeLayout of empty/garbage yields an empty layout", function()
  local l = vo.DeserializeLayout("")
  assert(next(l.mapping) == nil and #l.skip_values == 0)
end)

--------------------------------
-- CSV layout — track name, filter, threading
--------------------------------
print("\nCSV layout — track name, filter, threading:")

test("CharacterTrackName prefixes with a sanitized character or falls back to base", function()
  assert(vo.CharacterTrackName("Guard", "Selects") == "Guard_Selects")
  assert(vo.CharacterTrackName("", "Review") == "Review")
  assert(vo.CharacterTrackName(nil, "Alts") == "Alts")
  assert(vo.CharacterTrackName("Guard/M", "Selects") == vo.SanitizeName("Guard/M") .. "_Selects")
end)

test("BuildScriptLines keeps only included characters and canonicalizes speaker", function()
  local cols = { line_id=1, text=2, asset=3, speaker=4 }
  local rows = {
    { "L1","hi","a1","Guard" },
    { "L2","yo","a2","guard" },   -- same character, different case
    { "L3","hey","a3","Hero" },
  }
  local lines = vo.BuildScriptLines(rows, cols, {
    speakers = { guard = true },              -- include only Guard
    canonicalize = { guard = "Guard", hero = "Hero" },
  })
  assert(#lines == 2, "#lines="..#lines)
  assert(lines[1].speaker == "Guard" and lines[2].speaker == "Guard", "canonicalized")
end)

test("BuildScriptLines nil speakers keeps all; empty keeps none", function()
  local cols = { line_id=1, text=2, asset=3, speaker=4 }
  local rows = { { "L1","hi","a1","Guard" }, { "L2","yo","a2","Hero" } }
  assert(#vo.BuildScriptLines(rows, cols, { canonicalize={guard="Guard",hero="Hero"} }) == 2)
  assert(#vo.BuildScriptLines(rows, cols, { speakers = {}, canonicalize={} }) == 0)
end)

test("a matched span carries the canonical character; unmatched carries nil", function()
  local lines = {
    { line_id="L1", text="open the gate", asset="g1", speaker="Guard" },
  }
  -- words that match the one line, plus a stray unmatched word (a slate)
  local words = {
    { t0=0.0, t1=0.4, text="open" }, { t0=0.4, t1=0.8, text="the" }, { t0=0.8, t1=1.2, text="gate" },
    { t0=5.0, t1=5.4, text="slate" },
  }
  local plan = build_named_plan(lines, words, { accept_threshold=0.5, review_floor=0.3, margin_threshold=0.0, anchor_count=1 })
  local matched, unmatched
  for _, s in ipairs(plan) do
    if s.kind == "match" then matched = s elseif s.kind == "unmatched" then unmatched = s end
  end
  assert(matched and matched.character == "Guard", "matched character: " .. tostring(matched and matched.character))
  assert(unmatched and unmatched.character == nil, "unmatched should have no character")
end)

--------------------------------
-- CSV layout — layout preset storage (ExtState)
--------------------------------
print("\nCSV layout — layout presets (ExtState):")

test("SaveLayoutPreset/ListLayoutPresets/LoadLayoutPreset/DeleteLayoutPreset round-trip", function()
  mock.reset()
  local layout = {
    mapping = { text = "VO, Text", asset = "File Name", speaker = "Character" },
    skip_values = { "TO RECORD", "HOLD" },
  }
  assert(vo.SaveLayoutPreset("Ubisoft VO", layout) == true, "SaveLayoutPreset should return true")

  local names = vo.ListLayoutPresets()
  local found = false
  for _, n in ipairs(names) do if n == "Ubisoft VO" then found = true end end
  assert(found, "Expected preset name in ListLayoutPresets")

  local back = vo.LoadLayoutPreset("Ubisoft VO")
  assert(back and back.mapping.asset == "File Name", "mapping did not round-trip")
  assert(back.mapping.text == "VO, Text", "mapping with comma did not round-trip: " .. tostring(back.mapping.text))
  assert(#back.skip_values == 2 and back.skip_values[2] == "HOLD", "skip_values did not round-trip")

  assert(vo.LoadLayoutPreset("No Such Preset") == nil, "Expected nil for an unknown preset")

  vo.DeleteLayoutPreset("Ubisoft VO")
  for _, n in ipairs(vo.ListLayoutPresets()) do
    assert(n ~= "Ubisoft VO", "Expected name gone from ListLayoutPresets after delete")
  end
  assert(vo.LoadLayoutPreset("Ubisoft VO") == nil, "Expected preset gone after delete")
end)

test("SaveLayoutPreset refuses an invalid name and stores nothing", function()
  mock.reset()
  local ok = vo.SaveLayoutPreset("bad=name", { mapping = {}, skip_values = {} })
  assert(ok == false, "Expected false for an invalid preset name")
  assert(#vo.ListLayoutPresets() == 0, "Expected no names stored for a refused save")
  assert(vo.LoadLayoutPreset("bad=name") == nil, "Expected nothing stored under the bad name")
end)

--------------------------------
-- ApplyPlan (coupled): a degenerate span must not corrupt the session
--------------------------------
print("\nApplyPlan:")

test("a zero-length span is skipped and never sweeps the rest of the item", function()
  mock.reset()

  -- One source item [0,100] on a named "Raw" track.
  local raw = { info = {}, name = "Raw", items = {} }
  raw.items[1] = {
    info  = { D_POSITION = 0, D_LENGTH = 100 },
    take  = { info = {}, source = "mock_source" },
    track = raw,
  }
  mock.tracks = { raw }

  -- Chronological plan: a normal clip, a DEGENERATE zero-length span (start ==
  -- stop, exactly what neighbour-clamping produced in the field), then another
  -- normal clip after it.
  local plan = {
    { start = 10, stop = 20, dest = "selects", asset = "A", name = "A", kind = "match" },
    { start = 50, stop = 50, dest = "selects", asset = "Z", name = "Z", kind = "match" },
    { start = 60, stop = 70, dest = "selects", asset = "B", name = "B", kind = "match" },
  }
  local cfg = { track_selects = "Selects", track_alts = "Alts", track_review = "Review" }

  local applied, failures = vo.ApplyPlan(plan, raw)

  -- Cutting moves nothing and creates no track: where a take goes is Pull's
  -- question, and it is answered from the name, not from this plan.
  assert(#mock.tracks == 1, "Cutting must create no tracks, got " .. #mock.tracks)

  -- Both real spans are cut; the degenerate one is not.
  assert(applied == 2, "Expected 2 clips applied, got " .. tostring(applied))

  -- No piece may exceed the longest real span (10s) apart from the leftovers
  -- between them. The bug left the whole 50..100 tail welded as one item, so
  -- the check that matters is that the piece at 60 exists at its own length.
  local found_b = false
  for _, it in ipairs(raw.items) do
    if math.abs(it.info.D_POSITION - 60) < 1e-6 and math.abs(it.info.D_LENGTH - 10) < 1e-6 then
      found_b = true
    end
  end
  assert(found_b, "The clip after the zero-length span was never cut")

  -- Everything is still on Raw, and the tail still reaches 100.
  local raw_end = 0
  for _, it in ipairs(raw.items) do
    raw_end = math.max(raw_end, it.info.D_POSITION + it.info.D_LENGTH)
  end
  assert(math.abs(raw_end - 100) < 1e-6, "Raw tail was lost; last end = " .. raw_end)

  -- The degenerate span is reported, not silently dropped.
  local reported = false
  for _, f in ipairs(failures) do if f:find('"Z"') or f:find("Z:") then reported = true end end
  assert(reported, "The skipped zero-length span should be reported")
end)

test("an unmatched span is neither split nor moved", function()
  mock.reset()

  -- One source item [0,100] on a named "Raw" track.
  local raw = { info = {}, name = "Raw", items = {} }
  raw.items[1] = {
    info  = { D_POSITION = 0, D_LENGTH = 100 },
    take  = { info = {}, source = "mock_source" },
    track = raw,
  }
  mock.tracks = { raw }

  -- A matched clip, then unmatched audio (a slate), then another matched clip.
  local plan = {
    { start = 10, stop = 20, dest = "selects",          name = "A", kind = "match" },
    { start = 30, stop = 40, dest = vo.DEST_IN_PLACE,   name = "UNMATCHED_take_two",
      kind = "unmatched" },
    { start = 60, stop = 70, dest = "selects",          name = "B", kind = "match" },
  }
  local cfg = { track_selects = "Selects", track_alts = "Alts", track_review = "Review" }

  local applied, failures = vo.ApplyPlan(plan, raw)

  local function track_by_name(nm)
    for _, t in ipairs(mock.tracks) do if t.name == nm then return t end end
  end

  -- Only the two matched spans are cut, and skipping the unmatched one is not
  -- an error.
  assert(applied == 2, "Expected 2 clips applied, got " .. tostring(applied))
  assert(#failures == 0, "Unexpected failures: " .. table.concat(failures, "; "))

  -- Nothing routed to Review, so that track is never created.
  assert(not track_by_name("Review"), "A Review track was created for unmatched audio")

  -- The heart of it: the source item was never split at 30 or 40, so the slate
  -- is still welded into the surrounding item rather than standing alone.
  for _, it in ipairs(raw.items) do
    local p, e = it.info.D_POSITION, it.info.D_POSITION + it.info.D_LENGTH
    for _, edge in ipairs({ 30, 40 }) do
      assert(math.abs(p - edge) > 1e-6, "Raw was split at " .. edge .. " (item start)")
      assert(math.abs(e - edge) > 1e-6, "Raw was split at " .. edge .. " (item end)")
    end
  end

  -- And one single Raw item still spans the whole 30..40 range.
  local covers = false
  for _, it in ipairs(raw.items) do
    local p, e = it.info.D_POSITION, it.info.D_POSITION + it.info.D_LENGTH
    if p <= 30 + 1e-6 and e >= 40 - 1e-6 then covers = true end
  end
  assert(covers, "No single Raw item still covers the unmatched span 30..40")

  -- The unmatched label never reached a take name anywhere in the project: it
  -- is a report label only.
  for _, t in ipairs(mock.tracks) do
    for _, it in ipairs(t.items or {}) do
      assert(not (it.take and it.take.name == "UNMATCHED_take_two"),
             "The unmatched label was applied as a take name on " .. tostring(t.name))
    end
  end
end)

--------------------------------
print("\nProject/source time conversion:")

test("project time converts to source time through position and offset", function()
  -- item at 10s, source starts at 5s: project 12s is source 7s
  assert(near(vo.ProjectTimeToSource(12.0, item_at(10, 4, 5.0)), 7.0),
    "Got: " .. vo.ProjectTimeToSource(12.0, item_at(10, 4, 5.0)))
end)

test("source time converts back to project time", function()
  assert(near(vo.SourceTimeToProject(7.0, item_at(10, 4, 5.0)), 12.0),
    "Got: " .. vo.SourceTimeToProject(7.0, item_at(10, 4, 5.0)))
end)

test("the conversions round-trip at unity playrate", function()
  local it = item_at(10, 4, 5.0)
  local back = vo.SourceTimeToProject(vo.ProjectTimeToSource(12.345, it), it)
  assert(near(back, 12.345), "Got: " .. back)
end)

test("the conversions round-trip at a non-unity playrate", function()
  local it = item_at(10, 4, 5.0, 2.0)
  local back = vo.SourceTimeToProject(vo.ProjectTimeToSource(12.345, it), it)
  assert(near(back, 12.345), "Got: " .. back)
end)

test("playrate scales the source interval, matching MapWordsToProject", function()
  -- MapWordsToProject maps source t to pos + (t - start_offs) / playrate.
  -- At playrate 2.0 with start_offs 0, source 4.0s lands at project 10 + 2 = 12.
  assert(near(vo.SourceTimeToProject(4.0, item_at(10, 4, 0, 2.0)), 12.0),
    "Got: " .. vo.SourceTimeToProject(4.0, item_at(10, 4, 0, 2.0)))
  assert(near(vo.ProjectTimeToSource(12.0, item_at(10, 4, 0, 2.0)), 4.0),
    "Got: " .. vo.ProjectTimeToSource(12.0, item_at(10, 4, 0, 2.0)))
end)

test("a playrate of zero or less is treated as 1.0", function()
  assert(near(vo.ProjectTimeToSource(12.0, item_at(10, 4, 0, 0)), 2.0),
    "Got: " .. vo.ProjectTimeToSource(12.0, item_at(10, 4, 0, 0)))
  assert(near(vo.SourceTimeToProject(2.0, item_at(10, 4, 0, -1)), 12.0),
    "Got: " .. vo.SourceTimeToProject(2.0, item_at(10, 4, 0, -1)))
end)

--------------------------------
-- FormatCutSummary — inline, non-modal Cut summary
--------------------------------
print("\nFormatCutSummary:")

test("counts and clips-cut always produce exactly two non-warning lines", function()
  local plan = {
    { kind = "match" }, { kind = "match" }, { kind = "review" }, { kind = "unmatched" },
  }
  local lines = vo.FormatCutSummary(plan, 3, {}, {})
  assert(#lines == 2, "Expected 2 lines, got " .. #lines)
  assert(lines[1].text == "2 matched, 1 for review, 1 unmatched (left untouched on the source track).",
    "Got: " .. lines[1].text)
  assert(lines[1].warn == false, "Counts line must not be a warning")
  assert(lines[2].text == "3 clip(s) cut and named.", "Got: " .. lines[2].text)
  assert(lines[2].warn == false, "Clips-cut line must not be a warning")
end)

test("an empty plan still reports zero counts, not nil", function()
  local lines = vo.FormatCutSummary({}, 0, nil, nil)
  assert(#lines == 2, "Expected 2 lines, got " .. #lines)
  assert(lines[1].text == "0 matched, 0 for review, 0 unmatched (left untouched on the source track).",
    "Got: " .. lines[1].text)
end)

test("skipped items add one warning line naming the count and reasons", function()
  local lines = vo.FormatCutSummary({}, 0, { "item at 1.000s: no source" }, {})
  assert(#lines == 3, "Expected 3 lines, got " .. #lines)
  assert(lines[3].warn == true, "Skipped-items line must be a warning")
  assert(lines[3].text == "1 item(s) skipped: item at 1.000s: no source", "Got: " .. lines[3].text)
end)

test("apply failures add one warning line naming the count and reasons", function()
  local lines = vo.FormatCutSummary({}, 0, {}, { "L001: span too short to cut" })
  assert(#lines == 3, "Expected 3 lines, got " .. #lines)
  assert(lines[3].warn == true, "Failures line must be a warning")
  assert(lines[3].text == "1 problem(s) while cutting: L001: span too short to cut", "Got: " .. lines[3].text)
end)

test("skipped and failures both present produce two warning lines, in order", function()
  local lines = vo.FormatCutSummary({}, 0, { "skip A" }, { "fail B" })
  assert(#lines == 4, "Expected 4 lines, got " .. #lines)
  assert(lines[3].text:find("skipped", 1, true) ~= nil, "Skipped line should come first")
  assert(lines[4].text:find("problem", 1, true) ~= nil, "Failures line should come second")
  assert(lines[3].warn == true and lines[4].warn == true, "Both must be warnings")
end)

--------------------------------
-- CountLines
--------------------------------
print("CountLines:")

test("no newline counts as one line", function()
  assert(vo.CountLines("single line") == 1, "Expected 1")
end)

test("empty string counts as zero lines", function()
  assert(vo.CountLines("") == 0, "Expected 0")
  assert(vo.CountLines(nil) == 0, "Expected 0 for nil")
end)

test("trailing newline still counts once past it", function()
  assert(vo.CountLines("line one\n") == 2, "Expected 2")
end)

test("multiple embedded newlines count every line", function()
  assert(vo.CountLines("whisper-cli not found at:\n/some/path") == 2, "Expected 2")
  assert(vo.CountLines("a\nb\nc") == 3, "Expected 3")
end)

test("cap clamps a pathological line count", function()
  local long = string.rep("x\n", 40) .. "x" -- 41 lines
  assert(vo.CountLines(long) == 41, "Expected 41 uncapped")
  assert(vo.CountLines(long, 8) == 8, "Expected clamp to 8")
end)

test("cap does not affect a count under the cap", function()
  assert(vo.CountLines("a\nb\nc", 8) == 3, "Expected 3, cap should not raise or clip below its own value")
end)

test("cap is a no-op for empty/nil input", function()
  assert(vo.CountLines("", 8) == 0, "Expected 0")
  assert(vo.CountLines(nil, 8) == 0, "Expected 0")
end)

--------------------------------
-- ShallowCopy
--------------------------------
print("ShallowCopy:")

test("copies top-level keys into a new table", function()
  local src = { a = 1, b = "two", c = true }
  local out = vo.ShallowCopy(src)
  assert(out.a == 1 and out.b == "two" and out.c == true, "Expected values to match")
  assert(out ~= src, "Expected a distinct table, not the same reference")
end)

test("later writes to the source do not affect the copy", function()
  local src = { whisper_model = "base.en" }
  local out = vo.ShallowCopy(src)
  src.whisper_model = "large-v3"
  assert(out.whisper_model == "base.en", "Copy must not see later top-level writes to the source")
end)

test("writes to the copy do not affect the source", function()
  local src = { force_retranscribe = false }
  local out = vo.ShallowCopy(src)
  out.force_retranscribe = true
  assert(src.force_retranscribe == false, "Source must not see writes to the copy")
end)

test("nested tables remain shared (shallow, not deep)", function()
  local src = { column_mapping = { asset = "Asset" } }
  local out = vo.ShallowCopy(src)
  assert(out.column_mapping == src.column_mapping, "Expected nested table to be the same reference")
end)

--------------------------------
print("\nSourceCoverageRanges:")

test("one range per item, in source time", function()
  local rs = vo.SourceCoverageRanges({ item_at(10, 4), item_at(30, 5, 20.0) })
  assert(#rs == 2, "Expected 2 ranges, got " .. #rs)
  assert(near(rs[1].from, 0) and near(rs[1].to, 4), "range 1: " .. rs[1].from .. ".." .. rs[1].to)
  assert(near(rs[2].from, 20) and near(rs[2].to, 25), "range 2: " .. rs[2].from .. ".." .. rs[2].to)
end)

test("playrate stretches the source span the item covers", function()
  local rs = vo.SourceCoverageRanges({ item_at(0, 4, 0, 2.0) })
  assert(near(rs[1].to, 8.0), "4s at 2x plays 8s of source, got " .. rs[1].to)
end)

test("a zero playrate falls back to 1x rather than collapsing the range", function()
  local rs = vo.SourceCoverageRanges({ item_at(0, 4, 0, 0) })
  assert(near(rs[1].to, 4.0), "Expected 4.0, got " .. rs[1].to)
end)

test("no items yields no ranges", function()
  assert(#vo.SourceCoverageRanges({}) == 0, "Expected no ranges")
  assert(#vo.SourceCoverageRanges(nil) == 0, "Expected no ranges from nil")
end)

--------------------------------
print("\nDistinctTrackCount:")

test("items on one track count as one", function()
  local t = {}
  assert(vo.DistinctTrackCount({ { track = t }, { track = t }, { track = t } }) == 1,
    "Expected 1 distinct track")
end)

test("items on two tracks count as two", function()
  assert(vo.DistinctTrackCount({ { track = {} }, { track = {} } }) == 2,
    "Expected 2 distinct tracks")
end)

test("no items, or items with no track, count as zero", function()
  assert(vo.DistinctTrackCount({}) == 0, "Expected 0")
  assert(vo.DistinctTrackCount(nil) == 0, "Expected 0 from nil")
  assert(vo.DistinctTrackCount({ { track = nil } }) == 0, "Expected 0 when no track is resolved")
end)

--------------------------------
print("\nProjectFilePath / OverviewKey:")

test("the project file sits beside the project, one per project", function()
  assert(vo.ProjectFilePath("D:\\Session\\Ep01.rpp") == "D:\\Session\\Ep01_vo.csv",
    "Got " .. tostring(vo.ProjectFilePath("D:\\Session\\Ep01.rpp")))
  assert(vo.ProjectFilePath("/mix/Ep01.RPP") == "/mix/Ep01_vo.csv")
end)

test("only the final extension is stripped, dots in directories are safe", function()
  assert(vo.ProjectFilePath("D:\\v1.2\\Ep01.rpp") == "D:\\v1.2\\Ep01_vo.csv",
    "Got " .. tostring(vo.ProjectFilePath("D:\\v1.2\\Ep01.rpp")))
end)

test("an empty or missing project path yields no project file path", function()
  assert(vo.ProjectFilePath(nil) == nil, "nil in, nil out")
  assert(vo.ProjectFilePath("") == nil, "empty in, nil out")
end)

test("an audio row keys on basename and milliseconds", function()
  assert(vo.OverviewKey("D:\\Session\\RIVA.wav", 1.23, "a") == "RIVA.wav|1230",
    "Got " .. vo.OverviewKey("D:\\Session\\RIVA.wav", 1.23, "a"))
  assert(vo.OverviewKey("/mix/RIVA.wav", 1.23, "a") == "RIVA.wav|1230",
    "The same recording under a different path keys the same")
end)

test("a script-only row keys on its filename", function()
  assert(vo.OverviewKey(nil, nil, "vo_guard_bark_01") == "|vo_guard_bark_01")
end)

test("keys round to the millisecond the transcript actually stores", function()
  assert(vo.OverviewKey("a.wav", 1.2304, "x") == "a.wav|1230")
  assert(vo.OverviewKey("a.wav", 1.2306, "x") == "a.wav|1231")
end)

--------------------------------
print("\nSerializeProjectFile / ParseProjectFile:")

local PF_HEADER = "Key,Filename,Source,Source start,Select,Status,Name override,Notes"

local function pf_meta()
  return { scripts = { { path = "D:\\S\\script.csv", enabled = true,
      mapping = { asset = "Filename", text = "Line Text", speaker = "Character" } } } }
end

local function round_trip(entries, meta)
  local parsed, err = vo.ParseProjectFile(vo.SerializeProjectFile(entries, meta or pf_meta()))
  assert(parsed, "Round trip failed: " .. tostring(err))
  return parsed
end

test("a full entry survives the round trip", function()
  local out = round_trip({
    { key = "RIVA.wav|1230", source = "D:\\S\\RIVA.wav", source_start = 1.23,
      asset = "vo_guard_halt_01", select = true, status = "verified",
      name_override = "vo_guard_halt_01_alt", notes = "great read" },
  })
  assert(#out.entries == 1, "Expected 1 entry, got " .. #out.entries)
  local e = out.entries[1]
  assert(e.key == "RIVA.wav|1230", "key")
  assert(e.source == "D:\\S\\RIVA.wav", "source")
  assert(math.abs(e.source_start - 1.23) < 1e-6, "source_start")
  assert(e.asset == "vo_guard_halt_01", "asset")
  assert(e.select == true, "select")
  assert(e.status == "verified", "status")
  assert(e.name_override == "vo_guard_halt_01_alt", "name_override")
  assert(e.notes == "great read", "notes")
end)

test("Sel and Keep round-trip as independent ticks", function()
  local out = round_trip({
    { key = "A.wav|1000", asset = "line_042", select = true },
    { key = "A.wav|2000", asset = "line_042", keep = true },
    { key = "A.wav|3000", asset = "line_042", select = true, keep = true },
    { key = "A.wav|4000", asset = "line_042", notes = "spare" },
  })
  assert(out.entries[1].select == true and not out.entries[1].keep, "select alone")
  assert(out.entries[2].keep == true and not out.entries[2].select, "keep alone")
  assert(out.entries[3].select == true and out.entries[3].keep == true, "both")
  assert(not out.entries[4].select and not out.entries[4].keep, "neither")
end)

test("a Keep alone counts as user work", function()
  local out = round_trip({ { key = "A.wav|1", asset = "x", keep = true } })
  assert(#out.entries == 1, "a keep is a judgement and must be written")
end)

test("a file written before Keep had a column still reads its marks", function()
  -- 0.13 briefly wrote "alt" in the Select field, before the cycling mark was
  -- split into two ticks. It reads as a Keep, so that work survives.
  local text = table.concat({
    "ajsfx VO Project,1", "", PF_HEADER,
    "A.wav|1000,line_042,D:\\A.wav,1.000,yes,,,",
    "A.wav|2000,line_042,D:\\A.wav,2.000,alt,,,",
    "A.wav|3000,line_042,D:\\A.wav,3.000,,,,x",
  }, "\n")
  local out = vo.ParseProjectFile(text)
  assert(out, "must parse")
  assert(out.entries[1].select == true, "yes still means Sel")
  assert(out.entries[2].keep == true and not out.entries[2].select,
    "the old alt becomes a Keep")
  assert(not out.entries[3].select and not out.entries[3].keep, "empty is unticked")
end)

test("the script path and mapping survive the round trip", function()
  local out = round_trip({})
  local sc = out.scripts[1]
  assert(sc.path == "D:\\S\\script.csv", "path: " .. tostring(sc.path))
  assert(sc.mapping.asset == "Filename", "mapping asset")
  assert(sc.mapping.text == "Line Text", "mapping text")
  assert(sc.mapping.speaker == "Character", "mapping speaker")
end)

test("the filters survive the round trip", function()
  local out = round_trip({}, { scripts = {}, view = {
    character = "Meris", search = "halt", filter_row = true,
    col_filters = { asset = "guard", line_text = "halt, now" },
  } })
  local v = out.view
  assert(v.character == "Meris", "character: " .. tostring(v.character))
  assert(v.search == "halt", "search: " .. tostring(v.search))
  assert(v.filter_row == true, "filter_row")
  assert(v.col_filters.asset == "guard", "column filter")
  assert(v.col_filters.line_text == "halt, now", "a filter containing a comma")
end)

test("a character whose name is a CSV nightmare survives", function()
  local out = round_trip({}, { scripts = {},
    view = { character = 'MERIS, "the fixer"' } })
  assert(out.view.character == 'MERIS, "the fixer"',
    "Got " .. tostring(out.view.character))
end)

test("a view with nothing filtered writes no View rows", function()
  local text = vo.SerializeProjectFile({}, { scripts = {}, view = {
    search = "", filter_row = false, col_filters = { asset = "" } } })
  assert(not text:find("View", 1, true), "An unfiltered table must add nothing:\n" .. text)
end)

test("a project file with no View rows loads with no filters", function()
  local out = round_trip({})
  assert(out.view, "view must always be present, even empty")
  assert(out.view.character == nil and out.view.search == nil, "no stored filters")
  assert(next(out.view.col_filters) == nil, "no stored column filters")
end)

test("a script CSV path containing a comma survives", function()
  local out = round_trip({}, { scripts = {
    { path = "D:\\S\\ep1, final.csv", mapping = {}, enabled = true } } })
  assert(out.scripts[1].path == "D:\\S\\ep1, final.csv",
    "Got " .. tostring(out.scripts[1].path))
end)

test("scripts round-trip with their mapping and enabled flag", function()
  local text = vo.SerializeProjectFile({}, { scripts = {
    { path = "D:/g/Ch2.csv", mapping = { asset = "File", text = "Line" }, enabled = true },
    { path = "D:/g/Ch5.csv", mapping = { asset = "Fn" },                  enabled = false },
  } })
  local p = assert(vo.ParseProjectFile(text), "Should parse")
  assert(#p.scripts == 2, "Expected 2 scripts, got " .. #p.scripts)
  assert(p.scripts[1].path == "D:/g/Ch2.csv", "Got " .. tostring(p.scripts[1].path))
  assert(p.scripts[1].mapping.asset == "File", "Mapping lost")
  assert(p.scripts[1].enabled == true, "Enabled lost")
  assert(p.scripts[2].enabled == false, "Disabled lost")
end)

test("appends round-trip", function()
  local text = vo.SerializeProjectFile({}, {
    scripts = { { path = "D:/g/Ch2.csv", mapping = {}, enabled = true } },
    appends = { { script = "Ch2", asset = "line_042", nth = 2, text = "_take" } },
  })
  local p = assert(vo.ParseProjectFile(text), "Should parse")
  assert(#p.appends == 1, "Expected 1 append, got " .. #p.appends)
  assert(p.appends[1].script == "Ch2", "script lost")
  assert(p.appends[1].asset == "line_042", "asset lost")
  assert(p.appends[1].nth == 2, "nth lost or not a number: " .. tostring(p.appends[1].nth))
  assert(p.appends[1].text == "_take", "text lost")
end)

test("an append naming an absent script survives a rewrite", function()
  local first = vo.SerializeProjectFile({}, {
    scripts = {},
    appends = { { script = "Removed", asset = "a", nth = 1, text = "_x" } },
  })
  local p = assert(vo.ParseProjectFile(first), "Should parse")
  assert(#p.appends == 1, "Removing a script must not lose its appends")
end)

test("a file from the previous version parses into one enabled script", function()
  local old = table.concat({
    vo.FormatCSVRow({ vo.PROJECT_MARKER, "1" }),
    vo.FormatCSVRow({ "Script CSV", "D:/g/Only.csv" }),
    vo.FormatCSVRow({ "Mapping", "asset=Filename;text=Line" }),
    "",
    vo.FormatCSVRow(vo.PROJECT_HEADER),
  }, "\n") .. "\n"
  local p = assert(vo.ParseProjectFile(old), "The old format must still open")
  assert(#p.scripts == 1, "Expected 1 script, got " .. #p.scripts)
  assert(p.scripts[1].path == "D:/g/Only.csv", "Path lost")
  assert(p.scripts[1].mapping.asset == "Filename", "Mapping lost")
  assert(p.scripts[1].enabled == true, "A migrated script is enabled")
end)

test("a new-format file ignores a stray old-format row", function()
  local text = table.concat({
    vo.FormatCSVRow({ vo.PROJECT_MARKER, "1" }),
    vo.FormatCSVRow({ "Script CSV", "D:/g/Stale.csv" }),
    vo.FormatCSVRow({ "Script", "D:/g/Real.csv", "asset=F", "yes" }),
    "",
    vo.FormatCSVRow(vo.PROJECT_HEADER),
  }, "\n") .. "\n"
  local p = assert(vo.ParseProjectFile(text), "Should parse")
  assert(#p.scripts == 1 and p.scripts[1].path == "D:/g/Real.csv",
    "An explicit Script row wins over the legacy fallback")
end)

test("entries still round-trip alongside the new rows", function()
  local text = vo.SerializeProjectFile(
    { { key = "a.wav|1500", source = "D:/a.wav", source_start = 1.5,
        asset = "line_1", select = true } },
    { scripts = { { path = "D:/g/Ch2.csv", mapping = {}, enabled = true } } })
  local p = assert(vo.ParseProjectFile(text), "Should parse")
  assert(#p.entries == 1 and p.entries[1].select == true, "Entry rows must be unharmed")
end)

--------------------------------
-- LoadScripts
--------------------------------
print("\nLoadScripts:")

local CSV_A = "Filename,Line\nline_a,Alpha\nline_b,Bravo\n"
local CSV_B = "Filename,Line\nline_c,Charlie\n"

local function reader(files)
  return function(path) return files[path] end
end

test("two readable scripts merge into one line list", function()
  local got = vo.LoadScripts(
    { { path = "a.csv", mapping = { asset = "Filename", text = "Line" }, enabled = true },
      { path = "b.csv", mapping = { asset = "Filename", text = "Line" }, enabled = true } },
    reader({ ["a.csv"] = CSV_A, ["b.csv"] = CSV_B }))
  assert(#got.lines == 3, "Expected 3 lines, got " .. #got.lines)
  assert(got.lines[3].asset == "line_c", "Order is script-then-row")
end)

test("each script gets a label from its path", function()
  local got = vo.LoadScripts(
    { { path = "D:/g/Ch2.csv", mapping = { asset = "Filename", text = "Line" } } },
    reader({ ["D:/g/Ch2.csv"] = CSV_A }))
  assert(got.scripts[1].label == "Ch2", "Got " .. tostring(got.scripts[1].label))
  assert(got.lines[1].script == "Ch2", "Lines carry the label")
end)

test("an unreadable script errors alone and the rest still load", function()
  local got = vo.LoadScripts(
    { { path = "gone.csv", mapping = { asset = "Filename", text = "Line" } },
      { path = "b.csv",    mapping = { asset = "Filename", text = "Line" } } },
    reader({ ["b.csv"] = CSV_B }))
  assert(got.scripts[1].error ~= nil and got.scripts[1].error ~= "",
    "The missing file must carry a reason")
  assert(#got.lines == 1 and got.lines[1].asset == "line_c",
    "The readable script must still contribute")
end)

test("a script with no mapping errors rather than silently matching nothing", function()
  local got = vo.LoadScripts({ { path = "a.csv", mapping = {} } },
                             reader({ ["a.csv"] = CSV_A }))
  assert(got.scripts[1].error ~= nil and got.scripts[1].error ~= "",
    "An unmapped script must say so")
  assert(#got.lines == 0, "It must contribute no lines")
end)

test("an empty CSV errors", function()
  local got = vo.LoadScripts(
    { { path = "e.csv", mapping = { asset = "Filename", text = "Line" } } },
    reader({ ["e.csv"] = "" }))
  assert(got.scripts[1].error ~= nil and got.scripts[1].error ~= "", "Expected an error")
end)

test("a header-only CSV errors but keeps its header for the column pickers", function()
  local got = vo.LoadScripts(
    { { path = "h.csv", mapping = { asset = "Filename", text = "Line" } } },
    reader({ ["h.csv"] = "Filename,Line\n" }))
  assert(got.scripts[1].error ~= nil and got.scripts[1].error ~= "", "Expected an error")
  assert(got.scripts[1].header and got.scripts[1].header[1] == "Filename",
    "The header must survive so the mapping combos can still be used")
end)

test("a disabled script is loaded but contributes no lines", function()
  local got = vo.LoadScripts(
    { { path = "a.csv", mapping = { asset = "Filename", text = "Line" }, enabled = false } },
    reader({ ["a.csv"] = CSV_A }))
  assert(got.scripts[1].header ~= nil,
    "A disabled script is still read, so it can be re-enabled")
  assert(#got.lines == 0, "It contributes nothing while off")
end)

--------------------------------
-- deliver threading
--------------------------------
print("\ndeliver threading:")

test("AssignNames names a take from deliver, not from asset", function()
  local spans = { { kind = "match", asset = "line_042", deliver = "line_042_ch2",
                    start = 0, stop = 1, select = true } }
  vo.AssignNames(spans, {})
  assert(spans[1].name and spans[1].name:find("line_042_ch2", 1, true),
    "Got " .. tostring(spans[1].name))
end)

test("AssignNames falls back to asset when there is no deliver", function()
  local spans = { { kind = "match", asset = "line_042", start = 0, stop = 1,
                    select = true } }
  vo.AssignNames(spans, {})
  assert(spans[1].name and spans[1].name:find("line_042", 1, true),
    "Got " .. tostring(spans[1].name))
end)

test("overview rows carry the line's identity and delivered name", function()
  local lines = { { asset = "line_a", text = "Alpha", row = 1,
                    script = "Ch2", append_key = "Ch2|line_a|1", append_nth = 1,
                    deliver = "line_a_x" } }
  local rows = vo.BuildOverview({ lines = lines, matches = {}, entries = {} })
  assert(#rows == 1, "Expected 1 row, got " .. #rows)
  assert(rows[1].line_key == "Ch2|line_a|1", "Got " .. tostring(rows[1].line_key))
  assert(rows[1].deliver == "line_a_x", "Got " .. tostring(rows[1].deliver))
  assert(rows[1].script == "Ch2", "Got " .. tostring(rows[1].script))
  assert(rows[1].append_nth == 1, "The occurrence integer must reach the row")
end)

test("a row with no matching line carries no line key", function()
  local rows = vo.BuildOverview({ lines = {}, matches = {}, entries = {} })
  for _, row in ipairs(rows) do
    assert(row.line_key == nil, "An orphan must not claim a script line")
  end
end)

test("notes survive commas, quotes and newlines", function()
  local nasty = 'take 2, "the good one"\nwatch the plosive'
  local out = round_trip({
    { key = "a.wav|0", source = "a.wav", source_start = 0, notes = nasty },
  })
  assert(out.entries[1].notes == nasty, "Got " .. tostring(out.entries[1].notes))
end)

test("rows carrying no user work are not written at all", function()
  local out = round_trip({
    { key = "a.wav|0", source = "a.wav", source_start = 0, asset = "x" },
    { key = "a.wav|1", source = "a.wav", source_start = 1, asset = "y",
      status = "verified" },
  })
  assert(#out.entries == 1, "Expected only the verified row, got " .. #out.entries)
  assert(out.entries[1].key == "a.wav|1", "Wrong row survived")
end)

test("a select alone counts as user work", function()
  local out = round_trip({
    { key = "a.wav|0", source = "a.wav", source_start = 0, asset = "x", select = true },
  })
  assert(#out.entries == 1, "Expected the selected row to be kept, got " .. #out.entries)
  assert(out.entries[1].select == true, "Select lost in the round trip")
end)

test("clearing a row's marks removes it from the file", function()
  local out = round_trip({
    { key = "a.wav|0", source = "a.wav", source_start = 0, asset = "x",
      status = nil, notes = "", name_override = "", select = false, keep = false },
  })
  assert(#out.entries == 0, "A cleared row must vanish, got " .. #out.entries)
end)

test("a script line with no audio keeps its note and has no source", function()
  local out = round_trip({
    { key = "|vo_deck_03", asset = "vo_deck_03", notes = "re-record next session" },
  })
  assert(#out.entries == 1, "Expected the script-line row to be kept")
  assert(out.entries[1].source == nil, "A script-line row has no source")
  assert(out.entries[1].notes == "re-record next session", "notes")
end)

test("an empty project file serializes and parses back to nothing", function()
  local out = round_trip({})
  assert(out and #out.entries == 0, "Expected an empty entry list")
end)

test("garbage never raises, it reports", function()
  for _, bad in ipairs({ "", "not a csv at all", "a,b,c\n1,2,3", "\n\n\n" }) do
    local parsed, reason = vo.ParseProjectFile(bad)
    assert(parsed == nil, "Garbage must not parse: " .. bad)
    assert(type(reason) == "string" and reason ~= "", "A reason is required")
  end
  assert(vo.ParseProjectFile(nil) == nil, "nil must not raise")
  assert(vo.ParseProjectFile(42) == nil, "a non-string must not raise")
end)

test("a future project file version is refused, not misread", function()
  local text = vo.SerializeProjectFile({}, pf_meta()):gsub("^(ajsfx VO Project),1", "%1,99")
  local parsed, reason = vo.ParseProjectFile(text)
  assert(parsed == nil, "A version 99 project file must not parse")
  assert(reason:match("version"), "The reason should name the version, got " .. reason)
end)

test("a project file with no header row is refused", function()
  local parsed, reason = vo.ParseProjectFile('ajsfx VO Project,1\nScript CSV,x\n')
  assert(parsed == nil, "A headerless file must not parse")
  assert(type(reason) == "string" and reason ~= "", "A reason is required")
end)

test("a project file with a header but no rows is valid and empty", function()
  local out = vo.ParseProjectFile('ajsfx VO Project,1\n\n' .. PF_HEADER .. '\n')
  assert(out and #out.entries == 0, "Expected a valid empty project file")
end)

test("an unrecognised status is dropped rather than shown as an unknown badge", function()
  local text = 'ajsfx VO Project,1\n\n' .. PF_HEADER .. '\n'
            .. 'a.wav|0,x,a.wav,0.000,,bogus,,note\n'
  local out = vo.ParseProjectFile(text)
  assert(#out.entries == 1, "The row should still load")
  assert(out.entries[1].status == nil,
         "A bogus status must be dropped, got " .. tostring(out.entries[1].status))
  assert(out.entries[1].notes == "note", "The rest of the row must survive")
end)

test("status and select are read case-insensitively", function()
  local text = 'ajsfx VO Project,1\n\n' .. PF_HEADER .. '\n'
            .. 'a.wav|0,x,a.wav,0.000,YES,VERIFIED,,\n'
  local out = vo.ParseProjectFile(text)
  assert(out.entries[1].status == "verified", "Got " .. tostring(out.entries[1].status))
  assert(out.entries[1].select == true, "Select should read case-insensitively")
end)

--------------------------------
print("\nBuildOverview:")

local function line(asset, text, speaker, row)
  return { asset = asset, text = text, speaker = speaker, row = row }
end

local function span(start, stop, kind, asset, transcript, score)
  return { start = start, stop = stop, kind = kind, asset = asset,
           transcript = transcript, score = score }
end

local function by_asset(rows, asset)
  local out = {}
  for _, row in ipairs(rows) do
    if row.asset == asset then out[#out + 1] = row end
  end
  return out
end

test("a script with no audio at all is entirely missing", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", "Guard", 1), line("b", "Bravo", "Hero", 2) },
  })
  assert(#rows == 2, "Expected 2 rows, got " .. #rows)
  for _, row in ipairs(rows) do
    assert(row.status == "missing", "Expected missing, got " .. row.status)
    assert(row.source_path == nil, "A missing row has no audio")
    assert(row.take_count == 0, "A missing row has no takes")
  end
  assert(rows[1].line_text == "Alpha" and rows[1].character == "Guard",
    "Script text and character carry through to missing rows")
end)

test("rows follow script order, not audio order", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1), line("b", "Bravo", nil, 2) },
    matches = { { path = "s.wav", spans = {
      span(10, 11, "match", "b", "bravo", 0.9),
      span(1, 2, "match", "a", "alpha", 0.9),
    } } },
  })
  assert(rows[1].asset == "a" and rows[2].asset == "b",
    "Expected script order a,b; got " .. rows[1].asset .. "," .. rows[2].asset)
end)

test("two script lines sharing a filename keep their own takes apart", function()
  -- Regression: grouping by filename showed each line the other's takes -- five
  -- takes of "Jump right in!" three of which were audibly a different line.
  local a = span(1, 2, "match", "dup", "jump right in", 0.9)
  local b = span(10, 11, "match", "dup", "the nightmares have been getting stronger", 0.9)
  a.line_idx, b.line_idx = 1, 2
  local rows = vo.BuildOverview({
    lines = { line("dup", "Jump right in!", nil, 1),
              line("dup", "The nightmares have been getting stronger...", nil, 2) },
    matches = { { path = "s.wav", spans = { a, b } } },
  })
  assert(#rows == 2, "Expected 2 rows, got " .. #rows)
  for _, row in ipairs(rows) do
    assert(row.take_count == 1,
      "Each line has one take of its own, got " .. tostring(row.take_count))
  end
  assert(rows[1].transcript == "jump right in", "Row 1 got: " .. tostring(rows[1].transcript))
  assert(rows[2].transcript:find("nightmares"), "Row 2 got: " .. tostring(rows[2].transcript))
end)

test("a span with no line index still groups by filename", function()
  -- The fallback for spans that predate line_idx: one line, two takes.
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(1, 2, "match", "a", "alpha", 0.9),
      span(5, 6, "match", "a", "alpha", 0.9),
    } } },
  })
  assert(#rows == 2 and rows[1].take_count == 2,
    "Expected one line with two takes, got " .. #rows .. " rows")
end)

test("audio matching no script line becomes an orphan row, listed last", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(1, 2, "unmatched", nil, "take two", nil),
      span(5, 6, "match", "a", "alpha", 0.95),
    } } },
  })
  assert(#rows == 2, "Expected 2 rows, got " .. #rows)
  assert(rows[1].status == "recorded" and rows[1].asset == "a", "Script row comes first")
  assert(rows[2].status == "orphan", "Expected an orphan, got " .. rows[2].status)
  assert(rows[2].transcript == "take two", "The orphan keeps its transcript")
end)

test("audio for a line the filters excluded is an orphan, never dropped", function()
  -- 'b' is not in `lines` (filtered out by character), but its audio exists.
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(1, 2, "match", "b", "bravo", 0.9) } } },
  })
  assert(#rows == 2, "Expected the missing line plus the orphan, got " .. #rows)
  local orphan = rows[2]
  assert(orphan.status == "orphan", "Got " .. orphan.status)
  assert(orphan.asset == "b", "The orphan keeps the asset it claimed")
end)

test("a review span reads as review, not recorded", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(1, 2, "review", "a", "alfa", 0.61) } } },
  })
  assert(rows[1].status == "review", "Got " .. rows[1].status)
  assert(math.abs(rows[1].score - 0.61) < 1e-6, "The score carries through")
end)

test("multiple takes become sibling rows, numbered chronologically", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(30, 31, "match", "a", "alpha three", 0.9),
      span(10, 11, "match", "a", "alpha one", 0.9),
      span(20, 21, "match", "a", "alpha two", 0.9),
    } } },
  })
  assert(#rows == 3, "Expected 3 take rows, got " .. #rows)
  for i, row in ipairs(rows) do
    assert(row.take_index == i, "Take " .. i .. " misnumbered as " .. tostring(row.take_index))
    assert(row.take_count == 3, "Every take knows the group size")
  end
  assert(rows[1].transcript == "alpha one", "Takes are ordered by time, not file order")
end)

test("with no select recorded, no take is the primary", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(10, 11, "match", "a", "one", 0.9),
      span(20, 21, "match", "a", "two", 0.9),
    } } },
  })
  assert(rows[1].is_primary == false and rows[2].is_primary == false,
    "Guessing a take is exactly what the Select column exists to stop")
end)

test("an explicit select in the project file names the primary", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(10, 11, "match", "a", "one", 0.9),
      span(20, 21, "match", "a", "two", 0.9),
      span(30, 31, "match", "a", "three", 0.9),
    } } },
    entries = { { key = "s.wav|20000", source = "s.wav", source_start = 20,
                  asset = "a", select = true } },
  })
  assert(rows[2].is_primary == true, "The user's chosen take is the select")
  assert(rows[3].is_primary == false, "The last take yields to the user's choice")
end)

test("two transcripts fold into one list, takes numbered across both", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = {
      { path = "B_session2.wav", spans = { span(5, 6, "match", "a", "second day", 0.9) } },
      { path = "A_session1.wav", spans = { span(9, 9.5, "match", "a", "first day", 0.9) } },
    },
  })
  assert(#rows == 2, "Expected both sessions' takes, got " .. #rows)
  assert(rows[1].source_path == "A_session1.wav",
    "Sources order stably by path, not by argument order; got " .. rows[1].source_path)
  assert(rows[1].take_index == 1 and rows[2].take_index == 2,
    "Takes number continuously across sources")
  assert(rows[1].is_primary == false and rows[2].is_primary == false,
    "Neither is primary until the user selects one, whichever source it came from")
end)

test("one source's missing line and another's audio coexist in one list", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1), line("b", "Bravo", nil, 2),
              line("c", "Charlie", nil, 3) },
    matches = {
      { path = "s1.wav", spans = { span(1, 2, "match", "a", "alpha", 0.9) } },
      { path = "s2.wav", spans = { span(1, 2, "match", "c", "charlie", 0.9) } },
    },
  })
  assert(#rows == 3, "Expected 3 rows, got " .. #rows)
  assert(rows[1].status == "recorded" and rows[1].source_path == "s1.wav", "a from s1")
  assert(rows[2].status == "missing", "b is still missing")
  assert(rows[3].status == "recorded" and rows[3].source_path == "s2.wav", "c from s2")
end)

--------------------------------
print("\nBuildOverview: project-file overlay and rematch:")

local function verified_at(start)
  return { { key = vo.OverviewKey("s.wav", start, "a"), source = "s.wav",
             source_start = start, asset = "a", status = "verified",
             notes = "checked" } }
end

test("an exact key match carries the verified flag and notes", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(10, 11, "match", "a", "alpha", 0.9) } } },
    entries = verified_at(10),
  })
  assert(rows[1].user_status == "verified", "Got " .. tostring(rows[1].user_status))
  assert(rows[1].notes == "checked", "Notes carry through")
end)

test("a boundary nudged 40ms by re-transcription keeps its checkmark", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(10.04, 11, "match", "a", "alpha", 0.9) } } },
    entries = verified_at(10),
  })
  assert(rows[1].user_status == "verified",
    "A 40ms shift must not lose the mark; got " .. tostring(rows[1].user_status))
end)

test("a span two seconds away is different audio and does not inherit the mark", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(12, 13, "match", "a", "alpha", 0.9) } } },
    entries = verified_at(10),
  })
  assert(rows[1].user_status == nil,
    "A 2s shift must not inherit the mark; got " .. tostring(rows[1].user_status))
end)

test("the rematch never crosses to a different script line", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1), line("b", "Bravo", nil, 2) },
    -- 'b' sits 100ms from where 'a' was verified, but it is a different line.
    matches = { { path = "s.wav", spans = { span(10.1, 11, "match", "b", "bravo", 0.9) } } },
    entries = verified_at(10),
  })
  local b = by_asset(rows, "b")[1]
  assert(b.user_status == nil,
    "A different asset must not inherit the mark; got " .. tostring(b.user_status))
end)

test("the nearest candidate wins when several are in tolerance", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(10.0, 10.5, "match", "a", "near", 0.9),
      span(10.4, 10.9, "match", "a", "far",  0.9),
    } } },
    entries = { { key = "s.wav|9999", source = "s.wav", source_start = 10.05,
                  asset = "a", notes = "mine" } },
  })
  assert(rows[1].notes == "mine", "The nearer span should adopt the entry")
  assert(rows[2].notes == nil, "The farther span should not also claim it")
end)

test("a project moved to another drive still finds its marks", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "E:\\Moved\\s.wav",
                   spans = { span(10, 11, "match", "a", "alpha", 0.9) } } },
    entries = { { key = "s.wav|10000", source = "D:\\Old\\s.wav", source_start = 10,
                  asset = "a", status = "verified" } },
  })
  assert(rows[1].user_status == "verified",
    "The basename fallback should find it; got " .. tostring(rows[1].user_status))
end)

test("two recordings sharing a filename do not share a checkmark", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = {
      { path = "D:\\A\\take.wav", spans = { span(10, 11, "match", "a", "one", 0.9) } },
      { path = "D:\\B\\take.wav", spans = { span(10, 11, "match", "a", "two", 0.9) } },
    },
    entries = { { key = "take.wav|10000", source = "D:\\B\\take.wav",
                  source_start = 10, asset = "a", status = "verified" } },
  })
  local marked, unmarked = 0, 0
  for _, row in ipairs(rows) do
    if row.user_status == "verified" then marked = marked + 1 else unmarked = unmarked + 1 end
  end
  assert(marked == 1 and unmarked == 1,
    "Exactly one row may be verified; got " .. marked .. " marked")
  for _, row in ipairs(rows) do
    if row.user_status == "verified" then
      assert(row.source_path == "D:\\B\\take.wav",
        "The full path must win over the basename; got " .. row.source_path)
    end
  end
end)

test("a missing script line can still carry notes", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    entries = { { key = "|a", asset = "a", notes = "reschedule with actor" } },
  })
  assert(rows[1].status == "missing", "Still missing")
  assert(rows[1].notes == "reschedule with actor", "Notes on a missing line survive")
end)

test("a name override is carried but never overwrites the matched filename", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(10, 11, "match", "a", "alpha", 0.9) } } },
    entries = { { key = "s.wav|10000", source = "s.wav", source_start = 10,
                  asset = "a", name_override = "vo_alpha_final" } },
  })
  assert(rows[1].asset == "a", "The script's filename is untouched")
  assert(rows[1].name_override == "vo_alpha_final", "The override rides alongside")
end)

--------------------------------
print("\nProjectEntriesFromRows / SummarizeOverview:")

test("a full overview round-trips through the tracker unchanged", function()
  local built = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1), line("b", "Bravo", nil, 2) },
    matches = { { path = "s.wav", spans = { span(10, 11, "match", "a", "alpha", 0.9) } } },
    entries = { { key = "s.wav|10000", source = "s.wav", source_start = 10,
                  asset = "a", status = "verified", notes = "good" } },
  })
  local text   = vo.SerializeProjectFile(vo.ProjectEntriesFromRows(built))
  local parsed = vo.ParseProjectFile(text)
  local again  = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1), line("b", "Bravo", nil, 2) },
    matches = { { path = "s.wav", spans = { span(10, 11, "match", "a", "alpha", 0.9) } } },
    entries = parsed.entries,
  })
  assert(again[1].user_status == "verified", "The mark survives a save/load cycle")
  assert(again[1].notes == "good", "So do the notes")
end)

test("marks survive a re-transcription that shifts every boundary slightly", function()
  local lines = { line("a", "Alpha", nil, 1) }
  local first = vo.BuildOverview({
    lines = lines,
    matches = { { path = "s.wav", spans = { span(10, 11, "match", "a", "alpha", 0.9) } } },
  })
  first[1].user_status = "verified"
  first[1].notes = "keeper"
  local saved = vo.ParseProjectFile(vo.SerializeProjectFile(vo.ProjectEntriesFromRows(first)))

  -- Re-transcribed: the same take, boundaries moved by 30ms.
  local second = vo.BuildOverview({
    lines = lines,
    matches = { { path = "s.wav", spans = { span(10.03, 11.02, "match", "a", "alpha", 0.91) } } },
    entries = saved.entries,
  })
  assert(second[1].user_status == "verified",
    "This is the whole point of the design; got " .. tostring(second[1].user_status))
  assert(second[1].notes == "keeper", "Notes survive too")
end)

test("the summary counts lines delivered, not takes recorded", function()
  local n = vo.SummarizeOverview(vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1), line("b", "Bravo", nil, 2),
              line("c", "Charlie", nil, 3) },
    matches = { { path = "s.wav", spans = {
      span(1, 2, "match",  "a", "one",   0.9),
      span(3, 4, "match",  "a", "two",   0.9),
      span(5, 6, "review", "b", "bravo", 0.6),
      span(7, 8, "unmatched", nil, "slate", nil),
    } } },
  }))
  assert(n.lines == 3, "Three script lines, got " .. n.lines)
  assert(n.delivered == 2, "Two lines have audio, got " .. n.delivered)
  assert(n.recorded == 2, "Two matched take rows, got " .. n.recorded)
  assert(n.review == 1, "One review row, got " .. n.review)
  assert(n.missing == 1, "One missing line, got " .. n.missing)
  assert(n.orphan == 1, "One orphan, got " .. n.orphan)
end)

test("the summary counts the user's marks", function()
  local n = vo.SummarizeOverview({
    { status = "recorded", asset = "a", user_status = "verified" },
    { status = "recorded", asset = "b", user_status = "flagged" },
    { status = "recorded", asset = "c" },
  })
  assert(n.verified == 1 and n.flagged == 1, "Marks counted independently of status")
  assert(n.total == 3, "Total counts every row")
end)

test("summarizing nothing is zero, not an error", function()
  local n = vo.SummarizeOverview(nil)
  assert(n.total == 0 and n.lines == 0 and n.delivered == 0, "All zero")
end)

--------------------------------
-- ClusterItems
--------------------------------
print("\nClusterItems:")

-- Tracks are opaque to the pure layer, so plain tables stand in for them.
local TRACK_A, TRACK_B = { "A" }, { "B" }

local function geo(track, pos, length, opts)
  opts = opts or {}
  return { item = opts.item or (tostring(pos) .. "@" .. tostring(track[1])),
           index = opts.index or 0, track = track,
           pos = pos, length = length, locked = opts.locked, group = opts.group }
end

test("items that do not touch stay separate", function()
  local c = vo.ClusterItems({ geo(TRACK_A, 0, 1), geo(TRACK_A, 5, 1) })
  assert(#c == 2, "Expected 2 clusters, got " .. #c)
  assert(c[1].pos == 0 and c[1].stop == 1, "First cluster spans its item")
end)

test("an overlap on one track welds into a single cluster", function()
  local c = vo.ClusterItems({ geo(TRACK_A, 0, 2), geo(TRACK_A, 1.5, 2) })
  assert(#c == 1, "Expected 1 cluster, got " .. #c)
  assert(#c[1].members == 2, "Both items are members")
  assert(c[1].pos == 0 and math.abs(c[1].stop - 3.5) < 1e-9,
    "Cluster spans from the first start to the last end")
end)

test("the same overlap across two tracks does not cluster", function()
  -- Two characters talking over each other is not an edit; welding them would
  -- chain a multi-character session into one immovable blob.
  local c = vo.ClusterItems({ geo(TRACK_A, 0, 2), geo(TRACK_B, 1.5, 2) })
  assert(#c == 2, "Expected 2 clusters, got " .. #c)
end)

test("exactly abutting items do not cluster", function()
  local c = vo.ClusterItems({ geo(TRACK_A, 0, 2), geo(TRACK_A, 2, 2) })
  assert(#c == 2, "A trimmed butt-join is not a crossfade, got " .. #c)
end)

test("a sub-millisecond gap error still does not cluster", function()
  local c = vo.ClusterItems({ geo(TRACK_A, 0, 2), geo(TRACK_A, 2 - 0.0002, 2) })
  assert(#c == 2, "Float noise below the epsilon is not an overlap, got " .. #c)
end)

test("a chain of overlaps is one cluster even when the ends do not overlap", function()
  local c = vo.ClusterItems({
    geo(TRACK_A, 0, 2), geo(TRACK_A, 1.5, 2), geo(TRACK_A, 3, 2),
  })
  assert(#c == 1, "Expected 1 chained cluster, got " .. #c)
  assert(#c[1].members == 3, "All three travel together")
end)

test("a locked member locks the whole cluster", function()
  local c = vo.ClusterItems({
    geo(TRACK_A, 0, 2), geo(TRACK_A, 1.5, 2, { locked = true }),
  })
  assert(c[1].locked == true, "Half a crossfade must never move on its own")
end)

test("clusters come back in timeline order regardless of input order", function()
  local c = vo.ClusterItems({ geo(TRACK_B, 9, 1), geo(TRACK_A, 3, 1) })
  assert(c[1].pos == 3 and c[2].pos == 9, "Sorted by position")
end)

test("clustering nothing is empty, not an error", function()
  assert(#vo.ClusterItems(nil) == 0, "nil is an empty project")
end)

test("a shared item group welds across tracks", function()
  -- A group is the user saying "these belong together" out loud. Stranding one
  -- half on its old track is the same damage as breaking a crossfade.
  local c = vo.ClusterItems({
    geo(TRACK_A, 0, 1, { group = 7 }), geo(TRACK_B, 40, 1, { group = 7 }),
  })
  assert(#c == 1, "Expected 1 cluster, got " .. #c)
  assert(#c[1].members == 2, "Both travel together")
  assert(c[1].pos == 0 and c[1].stop == 41, "The cluster spans both members")
end)

test("group id 0 is ungrouped and never welds", function()
  local c = vo.ClusterItems({
    geo(TRACK_A, 0, 1, { group = 0 }), geo(TRACK_B, 40, 1, { group = 0 }),
  })
  assert(#c == 2, "Zero is 'no group', not a group, got " .. #c)
end)

test("different groups stay apart", function()
  local c = vo.ClusterItems({
    geo(TRACK_A, 0, 1, { group = 1 }), geo(TRACK_B, 40, 1, { group = 2 }),
  })
  assert(#c == 2, "Expected 2 clusters, got " .. #c)
end)

test("a group and an overlap sharing a member form one cluster", function()
  -- The crossfaded partner on track A has no group of its own, but it is welded
  -- to one that does, so the whole chain has to move as a unit.
  local c = vo.ClusterItems({
    geo(TRACK_A, 0, 2),
    geo(TRACK_A, 1.5, 2, { group = 3 }),
    geo(TRACK_B, 90, 1, { group = 3 }),
  })
  assert(#c == 1, "Expected 1 chained cluster, got " .. #c)
  assert(#c[1].members == 3, "All three travel together")
end)

test("cluster members stay in timeline order", function()
  -- Callers read the head of the edit off members[1]; this is contract, not luck.
  local c = vo.ClusterItems({
    geo(TRACK_B, 90, 1, { group = 3 }), geo(TRACK_A, 5, 1, { group = 3 }),
  })
  assert(c[1].members[1].pos == 5, "Earliest member first")
  assert(c[1].track == TRACK_A, "The cluster reports its head's track")
end)

--------------------------------
-- FolderDepthForChild
--------------------------------
print("\nFolderDepthForChild:")

test("nesting a child under a plain track opens and closes a folder", function()
  local parent, child = vo.FolderDepthForChild(0)
  assert(parent == 1 and child == -1, "Got " .. parent .. ", " .. child)
end)

test("nesting under the last child of a folder closes both levels", function()
  local parent, child = vo.FolderDepthForChild(-1)
  assert(parent == 1 and child == -2, "Got " .. parent .. ", " .. child)
end)

test("nesting under an existing folder makes the child its first child", function()
  local parent, child = vo.FolderDepthForChild(1)
  assert(parent == 1 and child == 0, "The parent stays a folder; got "
    .. parent .. ", " .. child)
end)

test("nesting under a track that closes two levels closes three", function()
  local parent, child = vo.FolderDepthForChild(-2)
  assert(parent == 1 and child == -3, "Got " .. parent .. ", " .. child)
end)

test("a missing depth is read as a plain track", function()
  local parent, child = vo.FolderDepthForChild(nil)
  assert(parent == 1 and child == -1, "nil is depth 0")
end)

--------------------------------
-- PlanTimelineLayout
--------------------------------
print("\nPlanTimelineLayout:")

local function cl(pos, length, key)
  return { members = { {} }, pos = pos, stop = pos + length,
           track = TRACK_A, track_order = 1, key = key or {} }
end

local function positions(moves)
  local out = {}
  for i, m in ipairs(moves) do out[i] = m.pos end
  return out
end

test("script order follows the CSV rows, not the timeline", function()
  local moves = vo.PlanTimelineLayout({
    clusters = { cl(0, 1, { script_row = 3 }), cl(10, 1, { script_row = 1 }) },
    order = "script", gap = 2, start = 0,
  })
  assert(moves[1].cluster.key.script_row == 1, "Row 1 lays down first")
  assert(moves[1].pos == 0, "The run begins at start")
  assert(moves[2].pos == 3, "1s item + 2s gap")
end)

test("a long item pushes the next one clear of its whole length", function()
  -- The whole reason sorting does not need to cut: an item holding five lines
  -- is placed by its first line and the next item clears all of it.
  local moves = vo.PlanTimelineLayout({
    clusters = { cl(0, 30, { script_row = 1 }), cl(100, 1, { script_row = 2 }) },
    order = "script", gap = 2, start = 0,
  })
  assert(moves[2].pos == 32, "Expected 32, got " .. moves[2].pos)
end)

test("script order appends orphans after the run", function()
  local moves, n = vo.PlanTimelineLayout({
    clusters = {
      cl(0, 1, { orphan = true }),
      cl(10, 1, { script_row = 2 }),
      cl(20, 1, { script_row = 1 }),
    },
    order = "script", gap = 1, start = 0,
  })
  assert(n.orphans == 1, "One orphan counted")
  assert(moves[3].cluster.key.orphan == true, "The orphan lands last")
  assert(moves[3].pos == 4, "After both sorted items, got " .. moves[3].pos)
end)

test("the run starts at the earliest affected item when no start is given", function()
  local moves = vo.PlanTimelineLayout({
    clusters = { cl(50, 1, { script_row = 2 }), cl(20, 1, { script_row = 1 }) },
    order = "script", gap = 1,
  })
  assert(moves[1].pos == 20, "Expected 20, got " .. moves[1].pos)
  assert(moves[1].delta == 0, "The anchor item does not move")
end)

test("record order puts the older recording first and gaps between them", function()
  local moves, n = vo.PlanTimelineLayout({
    clusters = {
      cl(0,  1, { source_path = "new.wav", source_start = 0 }),
      cl(10, 1, { source_path = "old.wav", source_start = 5 }),
      cl(20, 1, { source_path = "old.wav", source_start = 1 }),
    },
    order = "record", spacing = "fixed", gap = 2, source_gap = 60, start = 0,
    source_age = { ["old.wav"] = 100, ["new.wav"] = 200 },
  })
  assert(n.groups == 2, "Two recordings, got " .. n.groups)
  assert(moves[1].cluster.key.source_start == 1, "Oldest file, earliest take first")
  assert(moves[2].pos == 3, "2s gap inside a recording")
  assert(moves[3].cluster.key.source_path == "new.wav", "Newer file second")
  assert(moves[3].pos == 64, "60s between recordings, got " .. moves[3].pos)
end)

test("record order falls back to the path when ages are unknown", function()
  local moves = vo.PlanTimelineLayout({
    clusters = {
      cl(0, 1, { source_path = "b.wav", source_start = 0 }),
      cl(5, 1, { source_path = "a.wav", source_start = 0 }),
    },
    order = "record", gap = 1, source_gap = 10, start = 0, source_age = {},
  })
  assert(moves[1].cluster.key.source_path == "a.wav", "Deterministic without ages")
end)

test("a file with a known age sorts before one with none", function()
  local moves = vo.PlanTimelineLayout({
    clusters = {
      cl(0, 1, { source_path = "a.wav", source_start = 0 }),
      cl(5, 1, { source_path = "b.wav", source_start = 0 }),
    },
    order = "record", gap = 1, source_gap = 10, start = 0,
    source_age = { ["b.wav"] = 1 },
  })
  assert(moves[1].cluster.key.source_path == "b.wav", "Known age wins")
end)

test("original spacing replays the recording's own gaps", function()
  local moves, n = vo.PlanTimelineLayout({
    clusters = {
      cl(0,  1, { source_path = "s.wav", source_start = 10 }),
      cl(50, 1, { source_path = "s.wav", source_start = 42 }),
    },
    order = "record", spacing = "original", gap = 2, start = 5,
    source_age = { ["s.wav"] = 1 },
  })
  assert(moves[1].pos == 5, "The group begins at start")
  assert(moves[2].pos == 37, "32s apart, exactly as recorded; got " .. moves[2].pos)
  assert(n.clamped == 0, "Nothing had to slide")
end)

test("original spacing slides a retimed item forward instead of stacking it", function()
  local moves, n = vo.PlanTimelineLayout({
    clusters = {
      cl(0,  20, { source_path = "s.wav", source_start = 0 }),
      cl(50,  1, { source_path = "s.wav", source_start = 5 }),
    },
    order = "record", spacing = "original", gap = 2, start = 0,
    source_age = { ["s.wav"] = 1 },
  })
  assert(moves[2].pos == 20, "Clamped to the previous end, got " .. moves[2].pos)
  assert(n.clamped == 1, "And reported, got " .. n.clamped)
end)

test("original spacing is refused for script order", function()
  -- There is no original layout for an order the recording never had.
  local moves = vo.PlanTimelineLayout({
    clusters = { cl(0, 1, { script_row = 1, source_start = 0 }),
                 cl(9, 1, { script_row = 2, source_start = 100 }) },
    order = "script", spacing = "original", gap = 2, start = 0,
  })
  assert(moves[2].pos == 3, "Fixed gap applied anyway, got " .. moves[2].pos)
end)

test("the summary counts what will move", function()
  local c = vo.ClusterItems({ geo(TRACK_A, 0, 2), geo(TRACK_A, 1.5, 2),
                              geo(TRACK_A, 10, 1) })
  for i, cluster in ipairs(c) do cluster.key = { script_row = i } end
  local _, n = vo.PlanTimelineLayout({ clusters = c, order = "script",
                                       gap = 1, start = 0 })
  assert(n.clusters == 2, "Two clusters, got " .. n.clusters)
  assert(n.items == 3, "Three items, got " .. n.items)
  assert(math.abs(n.span - 5.5) < 1e-9, "3.5s + 1s gap + 1s, got " .. n.span)
end)

test("planning nothing is empty, not an error", function()
  local moves, n = vo.PlanTimelineLayout({ clusters = {} })
  assert(#moves == 0 and n.clusters == 0, "Nothing to lay out")
end)

--------------------------------
-- Transcript sidecar
--------------------------------
print("\nTranscriptPath:")

test("swaps the final extension for _vo_transcript.csv", function()
  assert(vo.TranscriptPath("D:/s/RIVA.wav") == "D:/s/RIVA_vo_transcript.csv",
         "Got: " .. tostring(vo.TranscriptPath("D:/s/RIVA.wav")))
end)

test("a path with no extension just gains the suffix", function()
  assert(vo.TranscriptPath("D:/s/RIVA") == "D:/s/RIVA_vo_transcript.csv",
         "Got: " .. tostring(vo.TranscriptPath("D:/s/RIVA")))
end)

test("a dot in a directory name is not treated as an extension", function()
  local got = vo.TranscriptPath("D:/my.session/RIVA.wav")
  assert(got == "D:/my.session/RIVA_vo_transcript.csv", "Got: " .. tostring(got))
end)

test("nil and empty return nil", function()
  assert(vo.TranscriptPath(nil) == nil, "nil should return nil")
  assert(vo.TranscriptPath("") == nil, "empty should return nil")
end)

print("\nSerializeTranscript / ParseTranscript:")

local function sample_words()
  return {
    { t0 = 12.480, t1 = 12.660, text = "we" },
    { t0 = 12.660, t1 = 12.910, text = "should" },
    { t0 = 12.910, t1 = 13.040, text = "not," },
  }
end

local function sample_meta()
  return { source = "RIVA.wav", source_bytes = 412839104, source_hash = "deadbeef",
           backend = "whisper.cpp", model = "ggml-medium.bin", language = "en" }
end

test("round-trip preserves every word and every preamble field", function()
  local text = vo.SerializeTranscript(sample_words(), sample_meta())
  local got, why = vo.ParseTranscript(text)
  assert(got, "Parse failed: " .. tostring(why))
  assert(got.version == 1, "Version: " .. tostring(got.version))
  assert(got.source == "RIVA.wav", "Source: " .. tostring(got.source))
  assert(got.source_bytes == 412839104, "Bytes: " .. tostring(got.source_bytes))
  assert(got.source_hash == "deadbeef", "Hash: " .. tostring(got.source_hash))
  assert(got.backend == "whisper.cpp", "Backend: " .. tostring(got.backend))
  assert(got.model == "ggml-medium.bin", "Model: " .. tostring(got.model))
  assert(got.language == "en", "Language: " .. tostring(got.language))
  assert(#got.words == 3, "Word count: " .. #got.words)
  assert(math.abs(got.words[1].t0 - 12.480) < 1e-6, "t0: " .. tostring(got.words[1].t0))
  assert(math.abs(got.words[3].t1 - 13.040) < 1e-6, "t1: " .. tostring(got.words[3].t1))
  assert(got.words[3].text == "not,", "text: " .. tostring(got.words[3].text))
end)

test("a word containing a comma, a quote and a newline survives", function()
  local words = { { t0 = 0, t1 = 1, text = 'he said "go,"\nquietly' } }
  local got = vo.ParseTranscript(vo.SerializeTranscript(words, sample_meta()))
  assert(got, "Parse failed")
  assert(got.words[1].text == 'he said "go,"\nquietly', "Got: " .. tostring(got.words[1].text))
end)

test("times are written to three decimals", function()
  local text = vo.SerializeTranscript({ { t0 = 1.23456, t1 = 2.5, text = "x" } }, sample_meta())
  assert(text:find("1.235,2.500,x", 1, true), "Row not found in:\n" .. text)
end)

test("an empty word list still produces a parseable file", function()
  local got, why = vo.ParseTranscript(vo.SerializeTranscript({}, sample_meta()))
  assert(got, "Parse failed: " .. tostring(why))
  assert(#got.words == 0, "Expected no words, got " .. #got.words)
end)

test("empty text is rejected with a reason", function()
  local got, why = vo.ParseTranscript("")
  assert(got == nil and type(why) == "string", "Expected nil + reason")
end)

test("a foreign file is rejected with a reason", function()
  local got, why = vo.ParseTranscript("Start,End,Text\n1,2,hi\n")
  assert(got == nil and type(why) == "string", "Expected nil + reason")
end)

test("an unknown version is rejected with a reason", function()
  local got, why = vo.ParseTranscript("ajsfx VO Transcript,99\n\nStart,End,Text\n")
  assert(got == nil and type(why) == "string", "Expected nil + reason")
end)

test("a missing word header is rejected with a reason", function()
  local got, why = vo.ParseTranscript("ajsfx VO Transcript,1\nSource,a.wav\n")
  assert(got == nil and type(why) == "string", "Expected nil + reason")
end)

--------------------------------
print("\nParagraphs / ParagraphWords:")

test("a word ending in a sentence terminator closes a paragraph", function()
  local words = {
    { t0 = 0, t1 = 1, text = "we" },
    { t0 = 1, t1 = 2, text = "should" },
    { t0 = 2, t1 = 3, text = "go." },
    { t0 = 3, t1 = 4, text = "okay" },
  }
  local paras = vo.Paragraphs(words)
  assert(#paras == 2, "Expected 2 paragraphs, got " .. #paras)
  assert(paras[1] == "we should go.", "Para 1: " .. tostring(paras[1]))
  assert(paras[2] == "okay", "Para 2: " .. tostring(paras[2]))
end)

test("? and ! and a trailing closing quote also close a paragraph", function()
  local paras = vo.Paragraphs({
    { text = "really?" }, { text = "yes!" }, { text = "he" }, { text = "said" },
    { text = 'stop."' }, { text = "done" },
  })
  assert(#paras == 4, "Expected 4 paragraphs, got " .. #paras)
  assert(paras[1] == "really?", "Para 1: " .. tostring(paras[1]))
  assert(paras[2] == "yes!", "Para 2: " .. tostring(paras[2]))
  assert(paras[3] == 'he said stop."', "Para 3: " .. tostring(paras[3]))
end)

test("a trailing run with no terminator still becomes its own paragraph", function()
  local paras = vo.Paragraphs({ { text = "hello" }, { text = "there" } })
  assert(#paras == 1, "Expected 1 paragraph, got " .. #paras)
  assert(paras[1] == "hello there", "Got: " .. tostring(paras[1]))
end)

test("an empty or nil word list produces no paragraphs", function()
  assert(#vo.Paragraphs({}) == 0, "Expected 0 for empty list")
  assert(#vo.Paragraphs(nil) == 0, "Expected 0 for nil")
end)

test("ParagraphWords groups the same original word tables Paragraphs summarizes", function()
  local w1, w2, w3 = { t0 = 0, t1 = 1, text = "hi." }, { t0 = 1, t1 = 2, text = "there" }, { t0 = 2, t1 = 3, text = "friend." }
  local groups = vo.ParagraphWords({ w1, w2, w3 })
  assert(#groups == 2, "Expected 2 groups, got " .. #groups)
  assert(#groups[1] == 1 and groups[1][1] == w1, "Group 1 should be {w1}")
  assert(#groups[2] == 2 and groups[2][1] == w2 and groups[2][2] == w3, "Group 2 should be {w2, w3}")
end)

--------------------------------
print("\nFileFingerprint / TranscriptMeta:")

local function write_file(path, bytes)
  local f = assert(io.open(path, "wb"))
  f:write(bytes)
  f:close()
end

test("the same bytes fingerprint the same way twice", function()
  local p = os.tmpname()
  write_file(p, string.rep("abc", 1000))
  local a, b = vo.FileFingerprint(p), vo.FileFingerprint(p)
  os.remove(p)
  assert(a and a == b, "Got " .. tostring(a) .. " and " .. tostring(b))
end)

test("one changed byte at the same length changes the fingerprint", function()
  local p, q = os.tmpname(), os.tmpname()
  write_file(p, string.rep("abc", 1000))
  write_file(q, string.rep("abc", 999) .. "abX")
  local a, b = vo.FileFingerprint(p), vo.FileFingerprint(q)
  os.remove(p); os.remove(q)
  assert(a ~= b, "Both fingerprinted as " .. tostring(a))
end)

test("a file larger than three windows still fingerprints its tail", function()
  local w = vo.FINGERPRINT_WINDOW
  local p, q = os.tmpname(), os.tmpname()
  write_file(p, string.rep("a", w * 3) .. "tail")
  write_file(q, string.rep("a", w * 3) .. "TAIL")
  local a, b = vo.FileFingerprint(p), vo.FileFingerprint(q)
  os.remove(p); os.remove(q)
  assert(a ~= b, "Tail change was not seen: " .. tostring(a))
end)

test("a missing file has no fingerprint", function()
  assert(vo.FileFingerprint("no/such/file.wav") == nil, "Expected nil")
  assert(vo.FileFingerprint(nil) == nil, "Expected nil for nil")
end)

test("TranscriptMeta records path, size and fingerprint together", function()
  local p = os.tmpname()
  write_file(p, string.rep("x", 128))
  local meta = vo.TranscriptMeta(p, { backend = "whisper.cpp", model = "m", language = "en" })
  os.remove(p)
  assert(meta.source == p, "Source: " .. tostring(meta.source))
  assert(meta.source_bytes == 128, "Bytes: " .. tostring(meta.source_bytes))
  assert(meta.source_hash ~= "" and meta.source_hash ~= nil, "Missing hash")
  assert(meta.backend == "whisper.cpp", "Backend: " .. tostring(meta.backend))
end)

--------------------------------
print("\nTranscriptState:")

-- Writes an audio stand-in plus its transcript, runs the state check, and
-- cleans both up. `mutate` is handed the audio path after the transcript is
-- written, so a test can edit the file behind the transcript's back.
local function state_of(bytes, mutate)
  local audio = os.tmpname() .. ".wav"
  write_file(audio, bytes)
  vo.WriteTranscript(audio, { { t0 = 0, t1 = 1, text = "hi" } }, vo.TranscriptMeta(audio))
  if mutate then mutate(audio) end
  local state, parsed, why = vo.TranscriptState(audio)
  os.remove(audio)
  os.remove(vo.TranscriptPath(audio))
  return state, parsed, why
end

test("an untranscribed source reads as no", function()
  local audio = os.tmpname() .. ".wav"
  write_file(audio, "data")
  local state = vo.TranscriptState(audio)
  os.remove(audio)
  assert(state == "no", "Got " .. tostring(state))
end)

test("an untouched source reads as yes", function()
  local state = state_of(string.rep("a", 4096))
  assert(state == "yes", "Got " .. tostring(state))
end)

test("a resized source reads as stale", function()
  local state = state_of(string.rep("a", 4096), function(audio)
    write_file(audio, string.rep("a", 8192))
  end)
  assert(state == "stale", "Got " .. tostring(state))
end)

test("a same-length rewrite reads as stale, which size alone would miss", function()
  local state = state_of(string.rep("a", 4096), function(audio)
    write_file(audio, string.rep("b", 4096))
  end)
  assert(state == "stale", "Got " .. tostring(state))
end)

test("an unparseable transcript reads as error with a reason", function()
  local audio = os.tmpname() .. ".wav"
  write_file(audio, "data")
  write_file(vo.TranscriptPath(audio), "not a transcript at all\n")
  local state, _, why = vo.TranscriptState(audio)
  os.remove(audio)
  os.remove(vo.TranscriptPath(audio))
  assert(state == "error", "Got " .. tostring(state))
  assert(type(why) == "string", "Expected a reason")
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
