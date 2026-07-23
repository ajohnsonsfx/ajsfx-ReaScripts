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
  line_id = "LineID",
  text    = "Text",
  asset   = "AudioAsset",
  speaker = "Speaker",
  type    = "Type",
}

test("resolves configured names to 1-based indices", function()
  local cols = vo.MapColumns({ "LineID", "Speaker", "Text", "AudioAsset" }, MAPPING)
  assert(cols.line_id == 1, "line_id: " .. tostring(cols.line_id))
  assert(cols.speaker == 2, "speaker: " .. tostring(cols.speaker))
  assert(cols.text == 3, "text: " .. tostring(cols.text))
  assert(cols.asset == 4, "asset: " .. tostring(cols.asset))
end)

test("header whitespace is ignored", function()
  local cols = vo.MapColumns({ "  LineID  ", "Text", "AudioAsset" }, MAPPING)
  assert(cols.line_id == 1 and cols.text == 2, "Whitespace not trimmed")
end)

test("header matching is case-insensitive", function()
  local cols = vo.MapColumns({ "lineid", "TEXT", "audioasset" }, MAPPING)
  assert(cols.line_id == 1 and cols.text == 2 and cols.asset == 3, "Case not ignored")
end)

test("optional columns absent from header map to nil", function()
  local cols = vo.MapColumns({ "LineID", "Text", "AudioAsset" }, MAPPING)
  assert(cols.speaker == nil and cols.type == nil, "Optional columns should be nil")
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

local COLS = { line_id = 1, speaker = 2, type = 3, text = 4, asset = 5 }

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
  assert(lines[1].line_id == "NPC_001", "line_id: " .. tostring(lines[1].line_id))
  assert(lines[1].asset == "vo_npc_greet_01", "asset: " .. tostring(lines[1].asset))
  assert(lines[1].text == "Hello there traveller", "text: " .. tostring(lines[1].text))
end)

test("skip values drop rows by asset, case-insensitively", function()
  local lines = vo.BuildScriptLines(rows(), COLS, { skip_values = { "to record" } })
  for _, l in ipairs(lines) do
    assert(l.line_id ~= "NPC_002", "TO RECORD row was not skipped")
  end
end)

test("rows with empty text or empty asset are dropped", function()
  local lines = vo.BuildScriptLines(rows(), COLS, {})
  for _, l in ipairs(lines) do
    assert(l.text ~= "" and l.asset ~= "", "Empty row leaked through")
  end
end)

test("speaker filter keeps only that speaker", function()
  local lines = vo.BuildScriptLines(rows(), COLS, { speaker = "NPC" })
  assert(#lines == 2, "Expected 2 NPC lines, got " .. #lines)
  for _, l in ipairs(lines) do
    assert(l.speaker == "NPC", "Non-NPC line leaked: " .. tostring(l.speaker))
  end
end)

test("type filter keeps only that type", function()
  local lines = vo.BuildScriptLines(rows(), COLS, { type = "Barks" })
  assert(#lines == 1, "Expected 1 Barks line, got " .. #lines)
  assert(lines[1].line_id == "NPC_003", "Wrong line: " .. tostring(lines[1].line_id))
end)

test("filters are case-insensitive and whitespace-tolerant", function()
  local lines = vo.BuildScriptLines(rows(), COLS, { speaker = " player " })
  assert(#lines == 1, "Expected 1 Player line, got " .. #lines)
  assert(lines[1].line_id == "PLR_001", "Wrong line: " .. tostring(lines[1].line_id))
end)

test("each line records its source row number for reporting", function()
  local lines = vo.BuildScriptLines(rows(), COLS, {})
  assert(lines[1].row == 1, "row: " .. tostring(lines[1].row))
  assert(lines[2].row == 3, "row: " .. tostring(lines[2].row))
end)

test("missing optional speaker column leaves speaker nil and filter inert", function()
  local cols = { line_id = 1, text = 4, asset = 5 }
  local lines = vo.BuildScriptLines(rows(), cols, { speaker = "NPC" })
  assert(#lines == 3, "Speaker filter should be inert without the column, got " .. #lines)
  assert(lines[1].speaker == nil, "speaker should be nil")
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

local function script_lines(specs)
  local lines = {}
  for i, s in ipairs(specs) do
    lines[i] = { line_id = s[1], text = s[2], asset = s[3], row = i }
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
    if near(c.score, 1.0) then seen[c.line_id] = true end
  end
  assert(seen.L1 and seen.L2, "Both lines should be found regardless of order")
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
  assert(c.line_id == "L1" and c.asset == "vo_gate_north", "identity not carried")
  assert(near(c.start, 0.0), "start: " .. tostring(c.start))
  assert(near(c.stop, 1.9), "stop: " .. tostring(c.stop))
end)

--------------------------------
-- SelectSpans
--------------------------------
print("\nSelectSpans:")

local function cand(i0, i1, score, margin, id)
  return { i0 = i0, i1 = i1, score = score, margin = margin or 1.0,
           line_id = id or ("L" .. i0), asset = "a" .. i0,
           start = i0 * 1.0, stop = i1 * 1.0 }
end

test("non-overlapping candidates are all kept", function()
  local spans = vo.SelectSpans({ cand(1, 3, 0.9), cand(5, 7, 0.9) }, {})
  assert(#spans == 2, "Expected 2 spans, got " .. #spans)
end)

test("of two overlapping candidates the higher score wins", function()
  local spans = vo.SelectSpans({ cand(1, 4, 0.7, 1.0, "LOW"), cand(2, 5, 0.95, 1.0, "HIGH") }, {})
  assert(#spans == 1, "Expected 1 span, got " .. #spans)
  assert(spans[1].line_id == "HIGH", "Wrong winner: " .. spans[1].line_id)
end)

test("equal scores are tie-broken by the wider margin", function()
  local spans = vo.SelectSpans({ cand(1, 4, 0.9, 0.02, "THIN"), cand(2, 5, 0.9, 0.50, "WIDE") }, {})
  assert(spans[1].line_id == "WIDE", "Wrong winner: " .. spans[1].line_id)
end)

test("candidates below the review floor are discarded", function()
  local spans = vo.SelectSpans({ cand(1, 3, 0.40) }, {})
  assert(#spans == 0, "Expected 0 spans, got " .. #spans)
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

--------------------------------
-- AssignNames
--------------------------------
print("\nAssignNames:")

-- Two takes of L1 plus a single take of L2, already chronological.
local function take_spans()
  return {
    { kind = "match", line_id = "L1", asset = "vo_a", score = 0.95, start = 0, stop = 1 },
    { kind = "match", line_id = "L2", asset = "vo_b", score = 0.93, start = 2, stop = 3 },
    { kind = "match", line_id = "L1", asset = "vo_a", score = 0.97, start = 5, stop = 6 },
  }
end

local function assigned(cfg)
  local spans = take_spans()
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

test("combo 1 - alts off, suffix off, primary last: all to selects, bare names", function()
  local s = assigned({ use_alts_track = false, suffix_alt_names = false, primary_take = "last" })
  assert(s[1].dest == "selects" and s[3].dest == "selects", "both to selects")
  assert(s[1].name == "vo_a" and s[3].name == "vo_a", "both bare")
end)

test("combo 2 - alts off, suffix off, primary first: all to selects, bare names", function()
  local s = assigned({ use_alts_track = false, suffix_alt_names = false, primary_take = "first" })
  assert(s[1].dest == "selects" and s[3].dest == "selects", "both to selects")
  assert(s[1].name == "vo_a" and s[3].name == "vo_a", "both bare")
end)

test("combo 3 - alts off, suffix on, primary last: earlier take suffixed", function()
  local s = assigned({ use_alts_track = false, suffix_alt_names = true, primary_take = "last" })
  assert(s[1].name == "vo_a_tk01", "take 1: " .. s[1].name)
  assert(s[3].name == "vo_a", "primary: " .. s[3].name)
  assert(s[1].dest == "selects" and s[3].dest == "selects", "both to selects")
end)

test("combo 4 - alts off, suffix on, primary first: later take suffixed", function()
  local s = assigned({ use_alts_track = false, suffix_alt_names = true, primary_take = "first" })
  assert(s[1].name == "vo_a", "primary: " .. s[1].name)
  assert(s[3].name == "vo_a_tk02", "take 2: " .. s[3].name)
end)

test("combo 5 - alts on, suffix off, primary last: earlier take to alts", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = false, primary_take = "last" })
  assert(s[1].dest == "alts", "take 1 dest: " .. s[1].dest)
  assert(s[3].dest == "selects", "primary dest: " .. s[3].dest)
  assert(s[1].name == "vo_a" and s[3].name == "vo_a", "both bare")
end)

test("combo 6 - alts on, suffix off, primary first: later take to alts", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = false, primary_take = "first" })
  assert(s[1].dest == "selects", "primary dest: " .. s[1].dest)
  assert(s[3].dest == "alts", "take 2 dest: " .. s[3].dest)
end)

test("combo 7 - alts on, suffix on, primary last", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = true, primary_take = "last" })
  assert(s[1].dest == "alts" and s[1].name == "vo_a_tk01", s[1].dest .. "/" .. s[1].name)
  assert(s[3].dest == "selects" and s[3].name == "vo_a", s[3].dest .. "/" .. s[3].name)
end)

test("combo 8 - alts on, suffix on, primary first", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = true, primary_take = "first" })
  assert(s[1].dest == "selects" and s[1].name == "vo_a", s[1].dest .. "/" .. s[1].name)
  assert(s[3].dest == "alts" and s[3].name == "vo_a_tk02", s[3].dest .. "/" .. s[3].name)
end)

test("a single-take line never goes to alts even with the toggle on", function()
  local s = assigned({ use_alts_track = true, suffix_alt_names = true, primary_take = "last" })
  assert(s[2].dest == "selects" and s[2].name == "vo_b", s[2].dest .. "/" .. s[2].name)
end)

test("low-confidence spans go to review named with their score", function()
  local spans = { { kind = "review", line_id = "L1", asset = "vo_npc_greet_01", score = 0.67, start = 0, stop = 1 } }
  vo.AssignNames(spans, {})
  assert(spans[1].dest == "review", "dest: " .. spans[1].dest)
  assert(spans[1].name == "REVIEW_vo_npc_greet_01_s0.67", "name: " .. spans[1].name)
end)

test("unmatched spans go to review named from their transcript", function()
  local spans = { { kind = "unmatched", transcript = "take two", start = 0, stop = 1 } }
  vo.AssignNames(spans, {})
  assert(spans[1].dest == "review", "dest: " .. spans[1].dest)
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
    { kind = "review",    line_id = "L1", asset = "vo_a", score = 0.6, start = 0, stop = 1 },
    { kind = "unmatched", transcript = "hey",             start = 2, stop = 3 },
  }
  vo.AssignNames(spans, { review_prefix = "CHK_", unmatched_prefix = "JUNK_" })
  assert(spans[1].name == "CHK_vo_a_s0.60", "name: " .. spans[1].name)
  assert(spans[2].name == "JUNK_hey", "name: " .. spans[2].name)
end)

test("names are passed through the sanitizer", function()
  local spans = { { kind = "match", line_id = "L1", asset = "vo/a b", score = 0.9, start = 0, stop = 1 } }
  vo.AssignNames(spans, {})
  assert(spans[1].name == "vo_a_b", "name: " .. spans[1].name)
end)

test("review spans do not consume take numbers from delivered takes", function()
  local spans = {
    { kind = "review", line_id = "L1", asset = "vo_a", score = 0.60, start = 0, stop = 1 },
    { kind = "match",  line_id = "L1", asset = "vo_a", score = 0.95, start = 2, stop = 3 },
    { kind = "match",  line_id = "L1", asset = "vo_a", score = 0.97, start = 4, stop = 5 },
  }
  vo.AssignNames(spans, { suffix_alt_names = true, primary_take = "last" })
  assert(spans[2].take_index == 1, "first delivered take: " .. tostring(spans[2].take_index))
  assert(spans[2].name == "vo_a_tk01", "name: " .. spans[2].name)
  assert(spans[3].name == "vo_a", "primary: " .. spans[3].name)
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
print("\nBuildPlan:")

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
    local takes = (opts.repeats and opts.repeats[line.line_id]) or 1
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
      truth[#truth + 1] = line.line_id
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
  local plan  = vo.BuildPlan(lines, words, {})

  local got = {}
  for _, s in ipairs(plan) do
    if s.kind == "match" then got[s.line_id] = s.asset end
  end
  for _, l in ipairs(lines) do
    assert(got[l.line_id] == l.asset,
      "Line " .. l.line_id .. " expected " .. l.asset .. ", got " .. tostring(got[l.line_id]))
  end
end)

test("lines recorded out of script order are still all matched", function()
  local lines = load_fixture()
  local words = synthesize(lines, { shuffle = true })
  local plan  = vo.BuildPlan(lines, words, {})

  local count = 0
  for _, s in ipairs(plan) do
    if s.kind == "match" then count = count + 1 end
  end
  assert(count == #lines, "Expected " .. #lines .. " matches, got " .. count)
end)

test("slates and chatter become unmatched spans without losing any line", function()
  local lines = load_fixture()
  local words = synthesize(lines, { slates = true, chatter = true })
  local plan  = vo.BuildPlan(lines, words, {})

  local matches, unmatched = 0, 0
  for _, s in ipairs(plan) do
    if s.kind == "match" then matches = matches + 1
    elseif s.kind == "unmatched" then unmatched = unmatched + 1 end
  end
  assert(matches == #lines, "Expected " .. #lines .. " matches, got " .. matches)
  assert(unmatched > 0, "Expected slates/chatter to surface as unmatched spans")
end)

test("unmatched spans are routed to review, never to selects", function()
  local lines = load_fixture()
  local words = synthesize(lines, { slates = true, chatter = true })
  local plan  = vo.BuildPlan(lines, words, {})
  for _, s in ipairs(plan) do
    if s.kind == "unmatched" then
      assert(s.dest == "review", "unmatched routed to " .. tostring(s.dest))
    end
  end
end)

test("a noisy transcript never silently loses a line", function()
  local lines = load_fixture()
  local words = synthesize(lines, { drop_rate = 0.10, sub_rate = 0.05, seed = 7 })
  local plan  = vo.BuildPlan(lines, words, {})

  local found = {}
  for _, s in ipairs(plan) do
    if s.kind == "match" or s.kind == "review" then found[s.line_id] = s.kind end
  end
  for _, l in ipairs(lines) do
    assert(found[l.line_id], "Lost line " .. l.line_id .. " to transcription noise")
  end
end)

test("a line missing one word of five is still a confident match", function()
  -- At this seed the recognizer drops the leading "Open" from NPC_002.
  local lines = load_fixture()
  local words = synthesize(lines, { drop_rate = 0.10, sub_rate = 0.05, seed = 7 })
  local plan  = vo.BuildPlan(lines, words, {})
  for _, s in ipairs(plan) do
    if s.line_id == "NPC_002" then
      assert(s.kind == "match", "NPC_002 kind: " .. s.kind)
      assert(s.name == "vo_guard_gate_01", "NPC_002 name: " .. s.name)
    end
  end
end)

test("a line missing a third of its words is flagged, not asserted", function()
  -- PLR_001 loses 2 of its 6 words at this seed. A 0.67 score is a real match
  -- but not a confident one; the tool must say so rather than stamp an asset
  -- name on it. This is the guarantee the Review track exists to provide.
  local lines = load_fixture()
  local words = synthesize(lines, { drop_rate = 0.10, sub_rate = 0.05, seed = 7 })
  local plan  = vo.BuildPlan(lines, words, {})
  local seen = false
  for _, s in ipairs(plan) do
    if s.line_id == "PLR_001" then
      seen = true
      assert(s.kind == "review", "PLR_001 kind: " .. s.kind)
      assert(s.dest == "review", "PLR_001 dest: " .. tostring(s.dest))
      assert(s.name:find("^REVIEW_"), "PLR_001 name: " .. s.name)
    end
  end
  assert(seen, "PLR_001 produced no span at all")
end)

test("a line recorded twice yields two numbered takes", function()
  local lines = load_fixture()
  local words = synthesize(lines, { repeats = { NPC_001 = 2 } })
  local plan  = vo.BuildPlan(lines, words, {})

  local takes = {}
  for _, s in ipairs(plan) do
    if s.kind == "match" and s.line_id == "NPC_001" then takes[#takes + 1] = s end
  end
  assert(#takes == 2, "Expected 2 takes of NPC_001, got " .. #takes)
  table.sort(takes, function(a, b) return a.start < b.start end)
  assert(takes[1].take_index == 1 and takes[2].take_index == 2, "take numbering wrong")
  assert(takes[2].primary == true, "last take should be primary by default")
end)

test("plan spans are chronological and never overlap", function()
  local lines = load_fixture()
  local words = synthesize(lines, { slates = true, repeats = { NPC_002 = 2 } })
  local plan  = vo.BuildPlan(lines, words, {})

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
  local plan  = vo.BuildPlan(lines, words, {})
  for i, s in ipairs(plan) do
    assert(s.dest, "span " .. i .. " has no dest")
    assert(s.name and s.name ~= "", "span " .. i .. " has no name")
    assert(s.stop > s.start, "span " .. i .. " has non-positive length")
  end
end)

test("an empty word stream yields an empty plan", function()
  local lines = load_fixture()
  assert(#vo.BuildPlan(lines, {}, {}) == 0, "Expected an empty plan")
end)

test("audio with no script match produces only unmatched spans", function()
  local lines = load_fixture()
  local words = {}
  local t = 0
  for w in ("completely unrelated studio chatter about lunch"):gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.3, text = w }
    t = t + 0.35
  end
  local plan = vo.BuildPlan(lines, words, {})
  for _, s in ipairs(plan) do
    assert(s.kind == "unmatched", "Expected only unmatched spans, got " .. s.kind)
  end
end)

--------------------------------
-- BuildReport
--------------------------------
print("\nBuildReport:")

test("report starts with a header row", function()
  local lines = load_fixture()
  local report = vo.BuildReport({}, lines)
  local first = report:match("^([^\n]*)")
  assert(first:find("LineID"), "header: " .. first)
  assert(first:find("score"), "header: " .. first)
end)

test("report has one row per plan span", function()
  local lines = load_fixture()
  local words = synthesize(lines)
  local plan  = vo.BuildPlan(lines, words, {})
  local rows  = vo.ParseCSV(vo.BuildReport(plan, lines))
  -- header + one row per span, then the no-match section
  assert(#rows > #plan, "Report is missing rows")
  assert(rows[2][4] == plan[1].line_id, "First data row: " .. tostring(rows[2][4]))
end)

test("the report round-trips through our own CSV parser", function()
  local lines = load_fixture()
  local words = synthesize(lines, { slates = true })
  local plan  = vo.BuildPlan(lines, words, {})
  local rows  = vo.ParseCSV(vo.BuildReport(plan, lines))
  for _, row in ipairs(rows) do
    assert(#row >= 1, "Report produced an unparseable row")
  end
end)

test("script text containing a comma is quoted in the report", function()
  local lines = load_fixture()
  local plan  = { { kind = "match", line_id = "NPC_002", asset = "vo_guard_gate_01",
                    score = 0.9, margin = 0.5, start = 0, stop = 1,
                    dest = "selects", name = "vo_guard_gate_01", transcript = "open the north gate quickly" } }
  local report = vo.BuildReport(plan, lines)
  assert(report:find('"Open the north gate, quickly."', 1, true),
    "Script text with a comma was not quoted")
end)

test("lines that received no match are listed in their own section", function()
  local lines = load_fixture()
  local plan  = { { kind = "match", line_id = "NPC_001", asset = "vo_guard_halt_01",
                    score = 0.95, margin = 0.5, start = 0, stop = 1,
                    dest = "selects", name = "vo_guard_halt_01" } }
  local report = vo.BuildReport(plan, lines)

  assert(report:find("SCRIPT LINES WITH NO MATCH", 1, true), "Missing no-match section")
  local tail = report:match("SCRIPT LINES WITH NO MATCH(.*)$")
  assert(tail:find("PLR_001", 1, true), "Unmatched line PLR_001 not listed")
  assert(not tail:find("NPC_001", 1, true), "Matched line NPC_001 should not be listed")
end)

test("a review span does not count as a match for the no-match section", function()
  local lines = load_fixture()
  local plan  = { { kind = "review", line_id = "NPC_001", asset = "vo_guard_halt_01",
                    score = 0.60, margin = 0.5, start = 0, stop = 1,
                    dest = "review", name = "REVIEW_vo_guard_halt_01_s0.60" } }
  local tail = vo.BuildReport(plan, lines):match("SCRIPT LINES WITH NO MATCH(.*)$")
  assert(tail:find("NPC_001", 1, true), "A review-only line still needs flagging as unmatched")
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
  assert(cfg.create_regions == false, "regions should default off")
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

test("booleans round-trip rather than becoming truthy strings", function()
  mock.reset()
  local cfg = vo.LoadConfig()
  cfg.create_regions = true
  cfg.force_retranscribe = false
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(back.create_regions == true, "create_regions: " .. tostring(back.create_regions))
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
  assert(cfg.column_mapping.asset == "AudioAsset", "default asset column")
  cfg.column_mapping.asset = "Filename"
  cfg.column_mapping.text  = "Dialogue"
  vo.SaveConfig(cfg)

  local back = vo.LoadConfig()
  assert(back.column_mapping.asset == "Filename", back.column_mapping.asset)
  assert(back.column_mapping.text == "Dialogue", back.column_mapping.text)
  assert(back.column_mapping.line_id == "LineID", "untouched column changed")
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
  local m = vo.AutoDetectMapping({ "Cue", "VO Line", "Filename", "Character", "Category" })
  assert(m.line_id == "Cue", tostring(m.line_id))
  assert(m.asset == "Filename", tostring(m.asset))
  assert(m.speaker == "Character", tostring(m.speaker))
  assert(m.type == "Category", tostring(m.type))
  -- "VO Line" matches text alias "line"/"vo" only if exact-token; unmatched roles omitted
  assert(m.text == nil or type(m.text) == "string")
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
    mapping = { line_id="Cue ID", text="VO, Text", asset="File Name", speaker="Character" },
    skip_values = { "TO RECORD", "HOLD" },
  }
  local back = vo.DeserializeLayout(vo.SerializeLayout(layout))
  assert(back.mapping.line_id == "Cue ID", back.mapping.line_id)
  assert(back.mapping.text == "VO, Text", back.mapping.text)
  assert(back.mapping.asset == "File Name")
  assert(back.mapping.speaker == "Character")
  assert(back.mapping.type == nil, "type should stay unmapped")
  assert(#back.skip_values == 2 and back.skip_values[1] == "TO RECORD" and back.skip_values[2] == "HOLD")
end)

test("DeserializeLayout of empty/garbage yields an empty layout", function()
  local l = vo.DeserializeLayout("")
  assert(next(l.mapping) == nil and #l.skip_values == 0)
end)

print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
