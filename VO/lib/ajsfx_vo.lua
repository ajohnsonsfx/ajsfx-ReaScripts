-- @description ajsfx VO Shared Library
-- @author ajsfx
-- @version 0.10
-- @changelog LoadScripts takes an optional `filters` table and hands it to BuildScriptLines unchanged, so a caller's skip_values (the Settings-saved list) finally reaches the row filter instead of silently falling back to the default. From 0.9: Agreement: candidates are ranked by TOKENS of agreement (score x window length) rather than by score, so a short line matched perfectly no longer takes the words out of the middle of a long one. ExtraWords: an LCS alignment of a line against a take, for colouring the words the take has and the line does not. FindSpanLines: the matcher backwards -- which script lines could THESE words be -- behind the orphan right-click. TranscriptForRange: what was said inside a take marker's range, so marker-owned rows keep their transcript and score after a Cut. SummarizeOverview counts dismissed spans separately and leaves them out of the orphan count. ParagraphWords and the loop detector break on the reader's PAUSES, so four reads of one line are no longer reported as a transcriber loop. ParseExitFile: a launcher that has not written its exit code yet reads as not finished, not as failure. From 0.8: PlanAdopt, MakeSourceProbe, gap-hole reporting.
-- @noindex
-- @about Shared logic for the ajsfx VO windows.
--        Split into a pure layer (parsing, normalization, matching, naming —
--        unit-testable with no REAPER and no audio) and a REAPER-coupled layer.
--        See VO/SPEC.md for the design.

local r = reaper

local vo = {}

--------------------------------
-- Small shared helpers
--------------------------------

local function trim(s)
  return (tostring(s or ""):gsub("^%s*(.-)%s*$", "%1"))
end

local function fold(s)
  return trim(s):lower()
end

-- How many display rows a message will occupy: 1 plus one for every embedded
-- newline. Used to size UI reserves for messages whose line count varies
-- (a path-bearing error, a concatenated skip list) rather than assuming every
-- status message is exactly one line.
-- `cap`, if given, clamps the returned count so one pathological message
-- (e.g. a multi-hundred-line whisper log tail) cannot dominate a layout
-- reserve computed by summing CountLines() across several messages.
function vo.CountLines(s, cap)
  if s == nil or s == "" then return 0 end
  local n = 1
  for _ in tostring(s):gmatch("\n") do n = n + 1 end
  if cap and n > cap then return cap end
  return n
end

-- Shallow copy: a new table with the same top-level key/value pairs. Nested
-- tables (e.g. cfg.column_mapping) remain shared with the original -- callers
-- that need to isolate a config snapshot from later top-level field writes
-- (see the Cut panel's run config) only need the top level copied.
function vo.ShallowCopy(t)
  local out = {}
  for k, v in pairs(t) do out[k] = v end
  return out
end

--------------------------------
-- Pure layer: CSV parsing
--------------------------------

-- RFC4180 CSV parser.
-- Handles quoted fields, embedded commas/newlines/doubled quotes, CRLF and a
-- leading UTF-8 BOM. Wholly blank lines are skipped; ragged rows are preserved
-- as-is so the caller can report them.
-- Returns: array of rows, each row an array of field strings.
function vo.ParseCSV(text)
  local rows = {}
  if not text or text == "" then return rows end

  if text:sub(1, 3) == "\239\187\191" then text = text:sub(4) end

  local row, buf = {}, {}
  local in_quotes, row_had_quotes = false, false

  local function end_field()
    row[#row + 1] = table.concat(buf)
    buf = {}
  end

  local function end_row()
    end_field()
    -- A blank line parses as a single empty unquoted field — drop it.
    if not (#row == 1 and row[1] == "" and not row_had_quotes) then
      rows[#rows + 1] = row
    end
    row, row_had_quotes = {}, false
  end

  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if in_quotes then
      if c == '"' then
        if text:sub(i + 1, i + 1) == '"' then
          buf[#buf + 1] = '"'
          i = i + 1
        else
          in_quotes = false
        end
      else
        buf[#buf + 1] = c
      end
    elseif c == '"' then
      in_quotes, row_had_quotes = true, true
    elseif c == "," then
      end_field()
    elseif c == "\r" then
      -- Part of a CRLF pair: let the \n end the row. Bare CR ends it here.
      if text:sub(i + 1, i + 1) ~= "\n" then end_row() end
    elseif c == "\n" then
      end_row()
    else
      buf[#buf + 1] = c
    end
    i = i + 1
  end

  -- Final row with no trailing terminator (including an unterminated quote).
  if #buf > 0 or #row > 0 or in_quotes then end_row() end

  return rows
end

--------------------------------
-- Pure layer: column mapping
--------------------------------

-- Column mapping is fully configurable; nothing about the CSV shape is hardcoded
-- beyond which of our fields are required to do the job at all.
-- The asset (Filename) doubles as the line's identity: repeated takes share it,
-- so grouping and take-numbering key off it (see AssignNames). Text is the words
-- to match. Character is optional — absent, everything routes to plain tracks.
vo.REQUIRED_COLUMNS = { "asset", "text" }
vo.OPTIONAL_COLUMNS = { "speaker" }

vo.DEFAULT_COLUMN_MAPPING = {
  text    = "Line Text",
  asset   = "Filename",
  speaker = "Character",
}

-- Distinct character values, de-duplicated by case-insensitive key (first-seen
-- display wins), empties skipped. Order = first appearance.
function vo.DistinctCharacters(rows, col_index)
  local seen, out = {}, {}
  for _, row in ipairs(rows or {}) do
    local raw = trim(row[col_index] or "")
    if raw ~= "" then
      local key = fold(raw)
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = { key = key, display = raw }
      end
    end
  end
  return out
end

function vo.CanonicalizeMap(distinct)
  local m = {}
  for _, d in ipairs(distinct or {}) do m[d.key] = d.display end
  return m
end

-- Per-role header aliases (folded). Role sets are disjoint so a header word
-- can only claim one role.
vo.ROLE_ALIASES = {
  text    = { "text", "line text", "line_text", "linetext", "line", "dialogue", "vo" },
  asset   = { "filename", "file name", "audioasset", "asset", "file", "wav", "output" },
  speaker = { "character", "speaker", "char", "actor" },
}

-- Best-guess role -> header column name by folded alias match. Unmatched omitted.
function vo.AutoDetectMapping(header)
  local by_alias = {}
  for _, h in ipairs(header or {}) do
    local f = fold(h)
    if by_alias[f] == nil then by_alias[f] = h end
  end
  local mapping = {}
  for _, role in ipairs({ "asset", "text", "speaker" }) do
    for _, alias in ipairs(vo.ROLE_ALIASES[role]) do
      if by_alias[alias] then mapping[role] = by_alias[alias]; break end
    end
  end
  return mapping
end

-- Header column names must not contain a tab or newline (the layout encoding is
-- tab/line delimited). Returns ok, errmsg.
function vo.ValidateHeaderNames(header)
  for _, h in ipairs(header or {}) do
    if tostring(h):find("[\t\n\r]") then
      return false, "Column name contains a tab or newline, which is unsupported: " .. tostring(h)
    end
  end
  return true
end

-- Preset name rules. The name becomes part of the ExtState key `preset:<name>`,
-- and REAPER persists ExtState as key=value, so `=` is forbidden too.
function vo.ValidatePresetName(name)
  name = name or ""
  if name == "" then return false, "Enter a preset name." end
  if #name > 64 then return false, "Preset name is too long (max 64)." end
  if name == "__names__" then return false, "That name is reserved." end
  if name:find("[\t\n\r=]") then return false, "Preset name cannot contain tab, newline, or '='." end
  return true
end

-- Tab-delimited, line-based. Header names are tab/newline-validated on load, so
-- splitting each line on its FIRST tab is unambiguous.
function vo.SerializeLayout(layout)
  layout = layout or {}
  local lines = {}
  for _, role in ipairs({ "asset", "text", "speaker" }) do
    local col = layout.mapping and layout.mapping[role]
    if col and col ~= "" then lines[#lines + 1] = role .. "\t" .. col end
  end
  for _, tok in ipairs(layout.skip_values or {}) do
    if tok ~= "" then lines[#lines + 1] = "skip\t" .. tok end
  end
  return table.concat(lines, "\n")
end

function vo.DeserializeLayout(text)
  local layout = { mapping = {}, skip_values = {} }
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local k, v = line:match("^([^\t]+)\t(.*)$")
    if k == "skip" then
      if v ~= "" then layout.skip_values[#layout.skip_values + 1] = v end
    elseif k then
      layout.mapping[k] = v
    end
  end
  return layout
end

-- Resolve configured column names to 1-based indices in the header row.
-- Matching is case-insensitive and tolerant of surrounding whitespace.
-- Returns: cols table, or nil plus an error message listing the headers found.
function vo.MapColumns(header, mapping)
  mapping = mapping or vo.DEFAULT_COLUMN_MAPPING

  local index = {}
  for i, h in ipairs(header or {}) do
    local key = fold(h)
    if index[key] == nil then index[key] = i end -- first wins on duplicates
  end

  local cols, missing = {}, {}
  for _, field in ipairs(vo.REQUIRED_COLUMNS) do
    local want = mapping[field]
    local at = want and index[fold(want)] or nil
    if at then
      cols[field] = at
    else
      missing[#missing + 1] = want or field
    end
  end
  for _, field in ipairs(vo.OPTIONAL_COLUMNS) do
    local want = mapping[field]
    if want then cols[field] = index[fold(want)] end
  end

  if #missing > 0 then
    return nil, string.format(
      "Script CSV is missing required column(s): %s.\nHeaders found: %s",
      table.concat(missing, ", "),
      table.concat(header or {}, ", "))
  end

  return cols
end

--------------------------------
-- Pure layer: script lines
--------------------------------

-- Rows whose asset cell matches a skip value are not yet recorded and are
-- excluded from matching entirely.
vo.DEFAULT_SKIP_VALUES = { "TO RECORD" }

-- A cell wrapped in quotation marks loses them.
--
-- Scripts arrive with whole lines quoted -- a habit of the document the CSV was
-- exported from, not a fact about the line -- and the card then drew a quote
-- around that, so a line that quoted someone came out as `"Master say "No one
-- leaves.""`. Three levels of quoting for one sentence.
--
-- START AND END, both, or nothing happens: a line that merely quotes someone
-- (`Master say "No one leaves."`) keeps every mark it has, and so does one with
-- a stray quote at a single end. Only the outermost pair goes, so a wrapped
-- line that also quotes someone still reads as quoting them.
--
-- Smart quotes count. The same document habit produces them, and they are the
-- ones a person is least likely to notice and strip by hand.
local function quote_head(s)
  if s:sub(1, 3) == "\226\128\156" or s:sub(1, 3) == "\226\128\158" then return 3 end
  if s:sub(1, 1) == '"' then return 1 end
  return 0
end

local function quote_tail(s)
  if s:sub(-3) == "\226\128\157" then return 3 end
  if s:sub(-1) == '"' then return 1 end
  return 0
end

function vo.StripWrappingQuotes(s)
  if type(s) ~= "string" then return s end
  local head, tail = quote_head(s), quote_tail(s)
  -- `> head + tail`, not `>=`: a string that is nothing BUT its two quotes has
  -- no content to keep, and a single `"` must not read as its own wrapper.
  if head > 0 and tail > 0 and #s > head + tail then
    return trim(s:sub(head + 1, #s - tail))
  end
  return s
end

-- Turn data rows (header already removed) into script line records.
-- filters: { skip_values = {...}, speakers = { folded_key = true }, canonicalize }
-- The character filter is inert when no character column is mapped.
-- Returns: array of { text, asset, speaker, row }
function vo.BuildScriptLines(rows, cols, filters)
  filters = filters or {}

  local skip = {}
  for _, v in ipairs(filters.skip_values or vo.DEFAULT_SKIP_VALUES) do
    skip[fold(v)] = true
  end

  local speakers  = filters.speakers                 -- folded-key set, or nil = all
  local canon     = filters.canonicalize or {}

  local lines = {}
  for i, row in ipairs(rows or {}) do
    local text    = vo.StripWrappingQuotes(trim(row[cols.text]))
    local asset   = trim(row[cols.asset])

    local speaker_raw = cols.speaker and trim(row[cols.speaker]) or nil
    local speaker_key = speaker_raw and fold(speaker_raw) or nil
    local speaker     = speaker_raw and (canon[speaker_key] or speaker_raw) or nil

    local keep = text ~= "" and asset ~= "" and not skip[fold(asset)]
    -- Character filter applies ONLY when a character column is mapped: with no
    -- column the filter is inert (keep all — preserves the "filter inert without
    -- the column" contract); with a column, a row whose character is empty or
    -- not in the include-set is dropped.
    if keep and speakers and cols.speaker then
      keep = (speaker_key ~= nil) and speakers[speaker_key] == true
    end

    if keep then
      lines[#lines + 1] = {
        text    = text,
        asset   = asset,
        speaker = speaker,
        row     = i,
      }
    end
  end

  return lines
end

-- Script lines that two or more rows want DELIVERED under the same name, after
-- each line's Append has been applied.
-- The overview can still keep their takes apart -- it groups by script row --
-- but the delivered files cannot be kept apart, so one line's audio would
-- overwrite the other's. Nothing downstream can repair that; only the script
-- can. Returns: array of { asset, rows = { script row numbers }, texts = {…} },
-- in first-appearance order, or an empty array when every filename is unique.
function vo.DuplicateAssets(lines)
  local seen, order = {}, {}
  for _, l in ipairs(lines or {}) do
    -- The RESOLVED name, so an Append that separates two lines clears the
    -- clash and an Append that does not still shows it. `asset` is the fallback
    -- for callers that never ran ResolveNames (tests, older entry points).
    local name = l.deliver
    if name == nil or name == "" then name = l.asset end
    if name and name ~= "" then
      local g = seen[name]
      if not g then
        g = { asset = name, rows = {}, texts = {} }
        seen[name] = g
        order[#order + 1] = g
      end
      g.rows[#g.rows + 1] = l.row
      g.texts[#g.texts + 1] = l.text
    end
  end

  local dupes = {}
  for _, g in ipairs(order) do
    if #g.rows > 1 then dupes[#dupes + 1] = g end
  end
  return dupes
end

-- Row-level clash detection, for the red highlight in ajsfx VO Overview.
--
-- This exists alongside DuplicateAssets because the two questions differ. An
-- Append belongs to a script LINE; a name override belongs to a single TAKE. So
-- an override can separate a clash the line-level check still sees, or create
-- one it cannot see at all. Takes of a single line resolving to the same name is
-- normal and must never be flagged -- Cut is what numbers them apart.
--
-- rows: overview rows carrying line_key, deliver and optionally name_override.
-- Returns a set of the names claimed by two or more DIFFERENT script lines.
function vo.DuplicateNames(rows)
  local owners = {}
  for _, row in ipairs(rows or {}) do
    if row.line_key then
      local name = row.name_override
      if name == nil or name == "" then name = row.deliver end
      if name and name ~= "" then
        local o = owners[name]
        if not o then
          owners[name] = { row.line_key }
        elseif o[1] ~= row.line_key and o[2] == nil then
          o[2] = row.line_key
        end
      end
    end
  end

  local dupes = {}
  for name, o in pairs(owners) do
    if o[2] then dupes[name] = true end
  end
  return dupes
end

-- A script's short name, used in the Overview's Script column and as part of an
-- Append's storage key. Sanitized because it is displayed beside filenames and
-- must not carry anything a path would choke on.
function vo.ScriptLabel(path)
  if type(path) ~= "string" or path == "" then return "" end
  local base = path:match("([^/\\]+)$") or path
  local stem = base:match("^(.*)%.[^.]*$") or base
  return vo.SanitizeName(stem)
end

-- A script line's identity for the Append it carries. The parts are NEVER
-- joined for storage -- a filename containing the separator would make the
-- split ambiguous -- so this is a lookup key only, built from parts the project
-- file keeps apart. `nth` is the 1-based occurrence of `asset` WITHIN its own
-- script, chosen over the CSV row number so that inserting a line at the top of
-- a script does not orphan every Append below it.
function vo.AppendKey(script_label, asset, nth)
  return tostring(script_label or "") .. "|" .. tostring(asset or "")
       .. "|" .. tostring(nth or 1)
end

-- Several scripts' lines, flattened into the one ordered list the matcher, the
-- overview and the cut all already expect. NOTHING is renamed here: two scripts
-- delivering one filename produce two ordinary lines that happen to share a
-- name, and the Append column is what separates them. Merging's only job is to
-- record which script each line came from and to give it a stable key.
--
-- scripts: { { label, enabled, lines = <BuildScriptLines output> }, ... }
function vo.MergeScriptLines(scripts)
  local out = {}
  for _, sc in ipairs(scripts or {}) do
    if sc.enabled ~= false then
      -- Occurrence is counted WITHIN a script, so a filename appearing once in
      -- each of two scripts is the 1st in both. Counting globally would make an
      -- Append depend on which other scripts happened to be loaded.
      local nth = {}
      for _, l in ipairs(sc.lines or {}) do
        local line = vo.ShallowCopy(l)
        local n = (nth[l.asset] or 0) + 1
        nth[l.asset] = n
        line.script     = sc.label
        line.append_nth = n
        line.append_key = vo.AppendKey(sc.label, l.asset, n)
        out[#out + 1] = line
        -- Position across the WHOLE list, which `row` cannot be: `row` counts
        -- within one CSV, so two scripts both have a row 5 and anything keyed on
        -- it would read them as one line. This is what "script order" means with
        -- more than one script, and the script list's order is what sets it.
        line.index      = #out
      end
    end
  end
  return out
end

-- Appends are held as an ARRAY of records, never as a map keyed by the joined
-- string: splitting "label|asset|nth" back into three parts would be ambiguous
-- the moment a filename contained the separator. The array is what the project
-- file round-trips; the map below is built for lookup and thrown away.
-- Record: { script = <label>, asset = <filename>, nth = <integer>, text = <string> }
function vo.AppendMap(append_rows)
  local m = {}
  for _, a in ipairs(append_rows or {}) do
    m[vo.AppendKey(a.script, a.asset, a.nth)] = a.text or ""
  end
  return m
end

-- The one mutator. Setting an append to empty REMOVES its record rather than
-- storing "": the project file holds judgements, and "no append" is the absence
-- of one -- the same rule SerializeProjectFile already applies to entry rows.
function vo.SetAppend(append_rows, script, asset, nth, text)
  append_rows = append_rows or {}
  local clean = trim(tostring(text or ""))

  for i, a in ipairs(append_rows) do
    if a.script == script and a.asset == asset and a.nth == nth then
      if clean == "" then
        table.remove(append_rows, i)
      else
        a.text = clean
      end
      return append_rows
    end
  end

  if clean ~= "" then
    append_rows[#append_rows + 1] =
      { script = script, asset = asset, nth = nth, text = clean }
  end
  return append_rows
end

-- The delivered name a script line asks for, before any per-take override.
-- No separator is inserted: a user who wants "line_042_ch2" types "_ch2". That
-- is the whole point -- nothing here renames anything the user did not spell.
-- `names` is the filename OVERRIDE: what the user typed over the script's own
-- filename. It replaces the delivered name outright rather than stacking with
-- the Append, because it REPLACES the Append -- typing the whole name is the
-- mechanism now, and a leftover Append record tacking onto a name the user
-- typed in full would be the tool arguing with them.
--
-- Appends still apply where no override exists. They are no longer reachable
-- from the card, but a project written before this feature has real names
-- stored that way and must open with the names it was saved with.
--
-- `l.asset` is untouched -- it is the script's own filename, drawn in grey
-- under the name and copied by "Copy original filename".
function vo.ResolveNames(lines, appends, names)
  appends = appends or {}
  names   = names or {}
  for _, l in ipairs(lines or {}) do
    local override = l.append_key and names[l.append_key] or nil
    override = override and trim(override) or ""
    if override ~= "" then
      l.deliver     = override
      l.name_edited = true
    else
      local extra = l.append_key and appends[l.append_key] or nil
      extra = extra and trim(extra) or ""
      l.deliver     = (l.asset or "") .. extra
      l.name_edited = nil
    end
  end
  return lines
end

--------------------------------
-- Pure layer: name resolution
--------------------------------

-- What identifies an item is its NAME, not the transcript. Two cases need
-- serving with one mechanism: takes this session cut out of a long recording,
-- and rendered files delivered by someone else with no transcript at all. Both
-- carry the script's filename, so both resolve the same way.

-- A file extension is a delivery detail, not part of the name. Only a SHORT
-- ALPHABETIC tail counts as one: "line_042_v1.2" ends in a number, which is
-- part of what the file is called, and stripping it would merge two deliveries.
function vo.NormalizeItemName(name)
  local s = trim(tostring(name or "")):lower()
  return (s:gsub("%.(%a%a?%a?%a?)$", ""))
end

-- Two keys per line: the script's own filename, and the DELIVERED name (that
-- filename plus its Append, or the user's override). The delivered name is one
-- this tool wrote, so recognising it is reading our own output back, not a
-- guess -- it is what lets a second Pull see what the first one renamed.
--
-- A key two lines claim is deliberately POISONED rather than assigned to the
-- first: that clash is what the Append column exists to fix, and picking one
-- would put one line's audio under the other's name.
function vo.BuildNameIndex(lines)
  local index = {}
  local function add(key, line_index)
    if key == "" then return end
    if index[key] == nil then
      index[key] = line_index
    elseif index[key] ~= line_index then
      index[key] = false           -- false means "claimed twice"
    end
  end

  for i, l in ipairs(lines or {}) do
    local at = l.index or i
    add(vo.NormalizeItemName(l.asset), at)
    if l.deliver and l.deliver ~= l.asset then
      add(vo.NormalizeItemName(l.deliver), at)
    end
  end
  return index
end

-- Returns the line index, or nil plus "unknown" / "ambiguous". An item that
-- resolves to nothing is never touched by Pull or Sort -- an uncut recording
-- carries the recording's name, which is not a script filename, and that is
-- what keeps both tools off audio they were not asked to move.
function vo.ResolveItemName(index, name)
  local key = vo.NormalizeItemName(name)
  if key == "" then return nil, "unknown" end
  local at = (index or {})[key]
  if at == nil then return nil, "unknown" end
  if at == false then return nil, "ambiguous" end
  return at
end

-- "Have I got everything?" -- answered from the project's ITEM NAMES and the
-- script, and from nothing else.
--
-- No transcript, no match, no stored mapping. It re-reads the truth every time
-- it is asked, so it cannot drift out of sync with the project: the item's name
-- IS the assignment, and this only reports what those names say. An answer it
-- gives is wrong only if the names are wrong, which is a thing you can see.
--
-- `items` are { name = <take name>, track = <track name> }.
-- Returns:
--   by_line[line_index] = { count = n, tracks = { [track name] = n } }
--   delivered  how many script lines have at least one item named for them
--   missing    how many have none
--   extra      names in the project that resolve to no line, deduplicated
--   ambiguous  names claimed by two lines, which no name can distinguish
-- The alt suffix as a Lua matcher: the pattern's literal parts escaped, {n}
-- standing for the number. "_alt{n}" -> a name ending "_alt3" strips to its
-- base. Returns nil when the name carries no such suffix.
function vo.StripAltSuffix(name, pattern)
  if type(name) ~= "string" or type(pattern) ~= "string"
     or pattern == "" or not pattern:find("{n}", 1, true) then
    return nil
  end
  local escaped = pattern:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1")
  local matcher = "^(.-)" .. escaped:gsub("{n}", "%%d+") .. "$"
  local base = name:match(matcher)
  if base and base ~= "" then return base end
  return nil
end

-- Appends whose (script, asset, nth) no loaded line answers to. An Append
-- detaches SILENTLY when a script file is renamed, re-exported with rows
-- shifted, or removed -- the record survives in the project file, applies to
-- nothing, and the clash it used to clear comes back on the next cut. This is
-- what lets the window say so instead.
function vo.OrphanAppends(appends, lines)
  local live = {}
  for _, l in ipairs(lines or {}) do
    live[vo.AppendKey(l.script, l.asset, l.append_nth)] = true
  end
  local orphans = {}
  for _, a in ipairs(appends or {}) do
    if a.text and a.text ~= ""
       and not live[vo.AppendKey(a.script, a.asset, a.nth)] then
      orphans[#orphans + 1] = a
    end
  end
  return orphans
end

-- A LINE EDIT is what was actually said, where the script says something else.
--
-- The same record as an Append, keyed the same way, for the same reason: it is
-- a judgement about ONE line of ONE script, made by hand, that the CSV does not
-- know about. The script CSV is the author's and is never written to; this is
-- the project's opinion of it.
--
-- Not the substitution table. That is global -- one entry per misheard word,
-- correct only when the word is wrong everywhere. A line the director changed
-- on the day is not a transcription problem, and `bolvd=adon` would rewrite
-- every other line that says Bolvd.
--
-- Record: { script = <label>, asset = <filename>, nth = <integer>, text = <string> }
--
-- THREE things now wear this shape -- the Append, the line edit, and the
-- filename override -- so the map/set/orphan helpers are written once and
-- named for the shape rather than for any one of them. They differ only in
-- which array they are handed and what the caller does with the answer.
function vo.KeyedTextMap(rows)
  local m = {}
  for _, e in ipairs(rows or {}) do
    m[vo.AppendKey(e.script, e.asset, e.nth)] = e.text or ""
  end
  return m
end

-- The one mutator for all three. Empty REMOVES the record: "not set" is the
-- absence of one, the rule vo.SetAppend and SerializeProjectFile already share.
-- That also makes "Revert" and "clear the field" the same operation, so they
-- cannot disagree.
--
-- A value equal to the original is still stored. Deciding a line reads right as
-- written is a judgement, and dropping it would make the grey original row
-- flicker away and back as the user typed toward what the script says.
function vo.SetKeyedText(edit_rows, script, asset, nth, text)
  edit_rows = edit_rows or {}
  local clean = trim(tostring(text or ""))

  for i, e in ipairs(edit_rows) do
    if e.script == script and e.asset == asset and e.nth == nth then
      if clean == "" then table.remove(edit_rows, i) else e.text = clean end
      return edit_rows
    end
  end
  if clean ~= "" then
    edit_rows[#edit_rows + 1] =
      { script = script, asset = asset, nth = nth, text = clean }
  end
  return edit_rows
end

-- Edits no loaded line answers to -- a renamed or re-exported CSV is enough.
-- Surfaced, not repaired, exactly as vo.OrphanAppends is: which line it should
-- attach to is the user's call.
function vo.OrphanKeyedText(edits, lines)
  local live = {}
  for _, l in ipairs(lines or {}) do
    live[vo.AppendKey(l.script, l.asset, l.append_nth)] = true
  end
  local orphans = {}
  for _, e in ipairs(edits or {}) do
    if e.text and e.text ~= ""
       and not live[vo.AppendKey(e.script, e.asset, e.nth)] then
      orphans[#orphans + 1] = e
    end
  end
  return orphans
end

-- Put the edited words where every reader of a line already looks.
--
-- ONE override point. The matcher reads `l.text` (text_for[l.asset]),
-- ExtraWords colours against it, BuildOverview copies it into row.line_text,
-- and search puts it in the haystack -- so overriding here reaches all of them
-- and none of them needs to know this feature exists. A second code path is
-- how the sheet and the matcher would come to disagree about what a line says.
--
-- Called on every script load, on the SAME line tables, so it must be
-- idempotent: `text_original` is written once and `text` is always rebuilt
-- FROM it. Without that, the second pass would record the edited words as the
-- original and the script's own words would be gone for good.
function vo.ApplyLineEdits(lines, edit_map)
  edit_map = edit_map or {}
  for _, l in ipairs(lines or {}) do
    if l.text_original == nil then l.text_original = l.text end
    local e = l.append_key and edit_map[l.append_key] or nil
    l.text        = (e ~= nil and e ~= "") and e or l.text_original
    l.text_edited = ((e ~= nil and e ~= "") and true) or nil
  end
  return lines
end

-- A voiced leftover butted right up against a take's first sample usually
-- HOLDS that take's real opening -- a spoken lead-in ('"Leave," he says')
-- the matcher couldn't align to the script, so the span started at the
-- first scripted word and the preamble stayed behind on the recording
-- track. Warn, don't guess: adopting audio into a take is an editorial
-- decision. leftovers/takes carry source-time spans ({src_start, src_end,
-- name}); a take starting within `gap` seconds after a leftover ends is
-- flagged with that leftover.
function vo.FlagClippedHeads(leftovers, takes, gap)
  gap = gap or 0.300
  local flags = {}
  for _, lo in ipairs(leftovers or {}) do
    for _, tk in ipairs(takes or {}) do
      local d = (tk.src_start or 0) - (lo.src_end or 0)
      if d >= -0.010 and d <= gap then
        flags[#flags + 1] = { leftover = lo, take = tk.name, gap = d }
        break
      end
    end
  end
  return flags
end

-- How much of an item's edge is really room, seen from one end. `db_windows`
-- is a peak-dB profile walking INWARD from that edge, one window per `step`
-- seconds. The subtlety this exists for: a cut whose edge was clamped to the
-- neighbouring word's timestamp puts the NEIGHBOUR take's onset (or decay)
-- inside the item -- a short, edge-touching run of audio with a long stretch
-- of silence behind it. A plain first-hot-window scan reads that as "tight"
-- while the listener hears speech, dead air, then a foreign blip. A hot run
-- at the edge no longer than `blip_max`, separated from the item's own audio
-- by at least `gap_min` of silence, is counted as room right through it.
function vo.EffectiveRoom(db_windows, step, opts)
  opts = opts or {}
  local floor_db = opts.floor_db or -45.0
  local blip_max = opts.blip_max or 0.350
  local gap_min  = opts.gap_min  or 0.400
  local first_hot
  for i, db in ipairs(db_windows or {}) do
    if db > floor_db then first_hot = i break end
  end
  if not first_hot then return #(db_windows or {}) * step end
  local room = (first_hot - 1) * step
  -- The blip branch fires only when the very edge window is hot: a clamped
  -- neighbour word is TRUNCATED by the edge, so it rings right at it. The
  -- item's own final word -- however close -- has completed, and its decay
  -- leaves at least a breath of quiet at the edge. That quiet is what keeps
  -- a short real word behind a long pause from being read as bleed.
  if first_hot > 1 then return room end
  local run_end = first_hot
  while run_end < #db_windows and db_windows[run_end + 1] > floor_db do
    run_end = run_end + 1
  end
  local gap_end = run_end
  while gap_end < #db_windows and db_windows[gap_end + 1] <= floor_db do
    gap_end = gap_end + 1
  end
  local run_len = (run_end - first_hot + 1) * step
  local gap_len = (gap_end - run_end) * step
  -- Only a blip, only with real silence behind it, and only when the item's
  -- own audio actually exists further in -- otherwise the edge audio IS the
  -- content and the honest answer is the plain scan's.
  if run_len <= blip_max and gap_len >= gap_min and gap_end < #db_windows then
    return gap_end * step
  end
  return room
end

-- The finishing pass, planned from measurements. Each entry of `measured`
-- says how far an item's edges sit from its audio ({name, head_room,
-- tail_room, user_touched}); anything looser than room + slack is pulled
-- in to the standard room. Items the user has already trimmed by hand
-- (user_touched, detected by their non-default fades) are never planned.
-- Deltas are seconds to move INWARD -- strictly loss-free: only measured
-- silence is removed, speech is untouched by construction.
function vo.PlanTighten(measured, opts)
  opts = opts or {}
  local head_room  = opts.head_room  or vo.DEFAULTS.snap_head_room
  local tail_room  = opts.tail_room  or vo.DEFAULTS.snap_tail_room
  local head_slack = opts.head_slack or vo.DEFAULTS.trim_head_slack
  local tail_slack = opts.tail_slack or vo.DEFAULTS.trim_tail_slack
  local edits = {}
  for _, m in ipairs(measured or {}) do
    if not m.user_touched then
      local h = (m.head_room or 0) > (head_room + head_slack)
        and (m.head_room - head_room) or 0
      local t = (m.tail_room or 0) > (tail_room + tail_slack)
        and (m.tail_room - tail_room) or 0
      if h > 0 or t > 0 then
        edits[#edits + 1] = { name = m.name, head = h, tail = t }
      end
    end
  end
  return edits
end

-- Matched/review spans of zero (or negative) width are matcher artifacts --
-- whisper hands every token expanded from one word the same timestamps, and a
-- word at the very end of a file can carry t0 == t1. Cutting one produces a
-- millisecond sliver wearing a line's name. Dropped here, counted for the
-- report; unmatched spans are left alone (nothing cuts them anyway).
function vo.DropDegenerateSpans(spans)
  local kept, dropped = {}, 0
  for _, s in ipairs(spans or {}) do
    local cuttable = s.kind == "match" or s.kind == "review"
    if cuttable and (s.stop or 0) - (s.start or 0) <= 0 then
      dropped = dropped + 1
    else
      kept[#kept + 1] = s
    end
  end
  return kept, dropped
end

-- opts.source_names: set of vo.NormalizeItemName-ed source filenames. An item
-- still wearing its recording's own name is the uncut remainder of a session,
-- not a stray -- counting it as "not on the script" keeps one permanent
-- warning on screen, which teaches the user to ignore the only warning that
-- matters. opts.alt_pattern: the Pull panel's alt pattern, so a name the tool
-- itself wrote ("line_alt2") counts as a take of its line.
function vo.CheckCoverage(items, lines, opts)
  opts = opts or {}
  local index = vo.BuildNameIndex(lines)
  local by_line, extra_seen, extra, ambiguous = {}, {}, {}, 0

  for _, it in ipairs(items or {}) do
    local at, why = vo.ResolveItemName(index, it.name)
    if not at and why ~= "ambiguous" and opts.alt_pattern then
      local base = vo.StripAltSuffix(it.name, opts.alt_pattern)
      if base then at, why = vo.ResolveItemName(index, base) end
    end
    if not at and why ~= "ambiguous" and opts.source_names
       and opts.source_names[vo.NormalizeItemName(it.name)] then
      -- Skip entirely: neither delivered nor extra.
      at, why = nil, "source"
    end
    if why == "source" then -- luacheck: ignore
    elseif at then
      local rec = by_line[at]
      if not rec then rec = { count = 0, tracks = {} }; by_line[at] = rec end
      rec.count = rec.count + 1
      local track = it.track or ""
      rec.tracks[track] = (rec.tracks[track] or 0) + 1
    elseif why == "ambiguous" then
      ambiguous = ambiguous + 1
    else
      -- Deduplicated: three takes of a name the script does not have is one
      -- thing to look at, not three.
      local key = vo.NormalizeItemName(it.name)
      if key ~= "" and not extra_seen[key] then
        extra_seen[key] = true
        extra[#extra + 1] = it.name
      end
    end
  end

  local delivered, missing = 0, 0
  for i = 1, #(lines or {}) do
    if by_line[i] then delivered = delivered + 1 else missing = missing + 1 end
  end

  table.sort(extra)
  return { by_line = by_line, delivered = delivered, missing = missing,
           extra = extra, ambiguous = ambiguous }
end

-- Where each item goes, as a pure function of its NAME and its two ticks.
-- Selects and Alts are DELIVERED; Review is everything else -- undecided,
-- unwanted, or simply not listened to yet.
--
-- `items` are { id, name, override } in timeline order; `marks` maps an item id
-- to "select" (the delivery) or "keep" (delivered alongside it, as an alt). An item whose name resolves to nothing produces no move
-- at all: not moved, not renamed, not an error. It is counted so a run that
-- does nothing can say why.
--
-- `override` is a name the user chose for THIS TAKE, and it wins over the
-- line's delivered name. It is how two takes of one line can be delivered under
-- different names: the Append belongs to the line and would rename the select
-- as well as the alt.
function vo.PlanPull(items, lines, marks)
  marks = marks or {}
  local index = vo.BuildNameIndex(lines)

  local groups, order = {}, {}
  local summary = { selects = 0, alts = 0, review = 0,
                    unknown = 0, ambiguous = 0 }

  for _, item in ipairs(items or {}) do
    local at, why = vo.ResolveItemName(index, item.name)
    if at then
      if not groups[at] then
        groups[at] = {}
        order[#order + 1] = at
      end
      local g = groups[at]
      g[#g + 1] = item
    else
      local bucket = (why == "ambiguous") and "ambiguous" or "unknown"
      summary[bucket] = summary[bucket] + 1
    end
  end

  local moves = {}
  for _, at in ipairs(order) do
    local group   = groups[at]
    local line    = lines[at] or {}
    local deliver = line.deliver or line.asset

    -- One take is not a decision: a lone item IS the delivery, whether or not
    -- anybody ticked it, and a folder of rendered files carries no ticks at
    -- all. Everything else follows the two ticks.
    if #group == 1 and not marks[group[1].id] then
      moves[#moves + 1] = { id = group[1].id, line = at,
                            dest = "selects", rename = group[1].override or deliver }
      summary.selects = summary.selects + 1
    else
      for _, item in ipairs(group) do
        local mark = marks[item.id]
        if mark == "select" then
          moves[#moves + 1] = { id = item.id, line = at,
                                dest = "selects", rename = item.override or deliver }
          summary.selects = summary.selects + 1
        elseif mark == "keep" then
          -- Without a per-take name of its own an alt takes the line's, which
          -- clashes with the select. That clash is real and is reported in red
          -- rather than uniqued behind the user's back -- "Name alts" is the
          -- button that gives every alt a name.
          moves[#moves + 1] = { id = item.id, line = at,
                                dest = "alts", rename = item.override or deliver }
          summary.alts = summary.alts + 1
        else
          -- Unticked takes go to Review and STAY there. Not a rejection and not
          -- a decision -- the first Pull of a session puts everything there,
          -- and what is left after the marking is what was never wanted.
          moves[#moves + 1] = { id = item.id, line = at, dest = "review" }
          summary.review = summary.review + 1
        end
      end
    end
  end

  return moves, summary
end

-- Adopting a session cut before this tool arrived: plan the renames that make
-- the project's names say what the match found, at the items' CURRENT edges,
-- cutting nothing. Cut and Name would re-slice hand-fixed edits to fit whisper
-- word timings; this is the ingest path that treats the user's editing as the
-- truth and only fills in the names Pull needs to route.
--
-- A name that resolves to ANY script line -- including one this match
-- disagrees with, one claimed by two lines, or an alt-suffixed one -- is an
-- assignment the user (or a previous run) stated, and the match, being a
-- guess, never overwrites it. Only names the script does not know (a raw
-- recording filename, REAPER's default clip name) are adoptable.
--
-- `takes` are { item = <id>, name = <current take name>, deliver = <the
-- line's delivered name>, sel = <true when the row carries SEL> }; several
-- rows may share an item, and the SEL row speaks for it. `index` comes from
-- vo.BuildNameIndex; opts.alt_pattern is the Pull panel's alt pattern.
-- Returns renames { { item, name } } in input order, and counts
-- { renamed, already, assigned, no_name }.
function vo.PlanAdopt(takes, index, opts)
  opts = opts or {}
  local by_item, order = {}, {}
  for _, t in ipairs(takes or {}) do
    if t.item ~= nil then
      local cur = by_item[t.item]
      if not cur then
        order[#order + 1] = t.item
        by_item[t.item] = t
      elseif t.sel and not cur.sel then
        by_item[t.item] = t
      end
    end
  end

  local function is_assignment(name)
    local key = vo.NormalizeItemName(name)
    if key == "" then return false end
    if (index or {})[key] ~= nil then return true end  -- false = claimed twice
    if opts.alt_pattern then
      local base = vo.StripAltSuffix(name, opts.alt_pattern)
      if base and (index or {})[vo.NormalizeItemName(base)] ~= nil then
        return true
      end
    end
    return false
  end

  local renames = {}
  local counts = { renamed = 0, already = 0, assigned = 0, no_name = 0 }
  for _, id in ipairs(order) do
    local t = by_item[id]
    local deliver = t.deliver or ""
    if deliver == "" then
      counts.no_name = counts.no_name + 1
    elseif vo.NormalizeItemName(t.name or "") == vo.NormalizeItemName(deliver) then
      counts.already = counts.already + 1
    elseif is_assignment(t.name or "") then
      counts.assigned = counts.assigned + 1
    else
      renames[#renames + 1] = { item = id, name = vo.SanitizeName(deliver) }
      counts.renamed = counts.renamed + 1
    end
  end
  return renames, counts
end

-- The alt naming convention belongs to whoever the delivery is for, so it is
-- three fields rather than a hardcoded "_alt2". `{n}` is where the number goes;
-- with no placeholder it goes on the end. A pattern used with no number at all
-- is returned as written -- a single alt may not need a counter.
function vo.FormatAltAppend(pattern, n, digits)
  local text = tostring(pattern or "")
  if not n then return (text:gsub("{n}", "")) end
  local num = string.format("%0" .. math.max(1, math.floor(digits or 1)) .. "d", n)
  if text:find("{n}", 1, true) then
    return (text:gsub("{n}", num))
  end
  return text .. num
end

-- Gives every alt -- a row with Keep ticked and Sel not -- a delivered name of
-- its own.
--
-- It writes a PER-TAKE name, not an Append. An Append belongs to the script
-- LINE -- `vo.AppendKey` has no take component and `line.deliver` feeds every
-- take of the line -- so appending "_alt1" for an alt would rename its select
-- too, and the two would still collide. Two takes of one line can only be told
-- apart by a name held against the take, which is what `name_override` is.
--
-- Numbering runs per line, in the order the rows are given, and an alt that
-- ALREADY has a name still consumes its number -- otherwise naming the second
-- alt by hand would silently renumber the third.
--
-- It never overwrites: this button fills blanks, it does not impose a
-- convention on work already done. Returns `{ { index = <index into rows>,
-- name = <string> }, ... }` and the number skipped.
function vo.PlanAltNames(rows, opts)
  opts = opts or {}
  local pattern = opts.pattern or "_alt{n}"
  local start   = math.floor(tonumber(opts.start) or 1)
  local digits  = math.floor(tonumber(opts.digits) or 1)

  local edits, skipped, seen = {}, 0, {}
  for i, row in ipairs(rows or {}) do
    -- An alt is a take kept but not chosen: Keep ticked, Sel not.
    if row.user_keep and not row.user_select and row.asset then
      -- Keyed by the LINE, so two lines that happen to share a filename number
      -- their alts separately -- the same reason the cut gate was keyed this
      -- way before it.
      local key = tostring(row.script_row or ((row.script or "") .. "\0" .. row.asset))
      local n = (seen[key] or start - 1) + 1
      seen[key] = n
      if row.name_override and trim(row.name_override) ~= "" then
        skipped = skipped + 1
      else
        -- Built on the line's DELIVERED name, so an alt of a line that already
        -- carries an Append keeps it: line_042_ch2 -> line_042_ch2_alt1.
        local base = row.deliver or row.asset
        edits[#edits + 1] = {
          index = i,
          name  = base .. vo.FormatAltAppend(pattern, n, digits),
        }
      end
    end
  end
  return edits, skipped
end

-- Is this name nothing more than the alt convention applied to `base`?
--
-- It matters because "Name them" stamps the name it generates into
-- `name_override`, so a machine-made alt name is indistinguishable from a
-- hand-typed one by storage alone. A name the convention itself would have
-- produced is not a judgement about anything, and a verb that renumbers must be
-- free to renumber it -- otherwise one press of "Name them" freezes the
-- numbering forever. Anything else is somebody's decision and is left alone.
--
-- Anchored at both ends: "line_042_alt1_room" is a name with a reason behind
-- it, not the convention.
function vo.IsConventionalAltName(name, base, pattern)
  if not name or not base or base == "" then return false end
  -- Lua patterns: braces are not magic, so escaping the rest leaves "{n}"
  -- findable afterwards.
  local function esc(s)
    return (tostring(s):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
  end
  local tail = esc(pattern or "_alt{n}")
  if tail:find("{n}", 1, true) then
    tail = tail:gsub("{n}", "%%d+")
  else
    tail = tail .. "%d+"
  end
  return name:match("^" .. esc(base) .. tail .. "$") ~= nil
end

-- Takes the SHEET as authority and gives every delivered take the name its row
-- says it should have -- overwriting, unlike `vo.PlanAltNames`, which only fills
-- blanks. The deliberate opposite of fixing names from the transcript: that one
-- is for "I do not trust the name", this is for "the sheet is right, make the
-- timeline say so". Only the user knows which they mean, so both exist.
--
-- Per line, over its takes in row order:
--   name_override      -> that name, verbatim -- a hand-given name outranks any
--                         convention, and still CONSUMES its alt number so
--                         naming one alt by hand does not renumber the next
--   Sel                -> the plain delivered name
--   Keep without Sel   -> delivered name .. the alt append
--   neither            -> left alone. It is not a take being delivered, and
--                         renaming it would claim that it is.
--
-- Numbering is keyed by `script_row` like `vo.PlanAltNames`, so two lines that
-- share a filename number their alts separately. Because every run renumbers
-- from the top, a line whose alts drifted to `_alt2` comes back to `_alt1`.
--
-- Returns `{ { index = <index into rows>, name = <string> }, ... }`, the number
-- left alone, and the number ticked but unnameable -- so the REAPER side stays
-- a thin writer. The last two are counted separately because they are different
-- news: one is the verb working as designed, the other is the sheet missing
-- something.
function vo.PlanNamesFromSheet(rows, opts)
  opts = opts or {}
  local pattern = opts.pattern or "_alt{n}"
  local start   = math.floor(tonumber(opts.start) or 1)
  local digits  = math.floor(tonumber(opts.digits) or 1)

  local edits, skipped, nameless, seen = {}, 0, 0, {}
  for i, row in ipairs(rows or {}) do
    local base = row.deliver or row.asset
    if not (row.user_select or row.user_keep) then
      skipped = skipped + 1
    -- The sheet is the authority, so a ticked row the sheet cannot name is a
    -- row this verb has nothing to say about. Counted rather than guessed at,
    -- and counted BEFORE the numbering, so it does not silently eat an alt
    -- number from a line whose other takes are perfectly nameable.
    elseif not base or base == "" then
      nameless = nameless + 1
    else
      local name
      -- An alt is a take kept but not chosen, same reading as vo.PlanAltNames.
      if row.user_keep and not row.user_select then
        local key = tostring(row.script_row or ((row.script or "") .. "\0" .. tostring(row.asset)))
        local n = (seen[key] or start - 1) + 1
        seen[key] = n
        name = base .. vo.FormatAltAppend(pattern, n, digits)
      else
        name = base
      end
      local override = row.name_override and trim(row.name_override) or ""
      -- See vo.IsConventionalAltName: an override that is only the convention
      -- was written by the tool, not chosen, so it does not outrank the sheet.
      if override ~= "" and not vo.IsConventionalAltName(override, base, pattern) then
        name = override
      end
      edits[#edits + 1] = { index = i, name = name }
    end
  end
  return edits, skipped, nameless
end

-- The whole script side of a project, loaded in one call. Both ajsfx VO Overview
-- and the old ajsfx VO Cut window kept near-identical copies of this; it is now
-- one function, so a script that loads for the table cannot fail to load for
-- the cut.
--
-- `read_fn(path)` returns the file's text or nil. Injected rather than opened
-- here so the whole thing stays in the pure layer and is testable headlessly.
--
-- entries: { { path, mapping, enabled }, ... }
-- Returns { scripts = { { path, label, mapping, enabled, header, rows, lines,
--                        error }, ... },
--           lines   = <merged, in script-then-row order> }
--
-- `lines` do NOT carry `deliver`: the caller runs vo.ResolveNames once it has
-- read the project's appends.
-- `filters` is handed to vo.BuildScriptLines unchanged (skip_values,
-- speakers, canonicalize); nil keeps the defaults.
function vo.LoadScripts(entries, read_fn, filters)
  local scripts = {}

  for _, e in ipairs(entries or {}) do
    local sc = {
      path    = e.path,
      label   = vo.ScriptLabel(e.path),
      mapping = e.mapping or {},
      enabled = e.enabled ~= false,
      lines   = {},
    }
    scripts[#scripts + 1] = sc

    local text = (e.path and e.path ~= "") and read_fn(e.path) or nil
    if not text then
      sc.error = "Cannot read the script CSV:\n" .. tostring(e.path)
    else
      local rows = vo.ParseCSV(text)
      if #rows < 1 then
        sc.error = "The script CSV is empty."
      else
        local header = table.remove(rows, 1)
        local ok, err = vo.ValidateHeaderNames(header)
        if not ok then
          sc.error = err
        else
          -- Kept even on the errors below, because the header is what the
          -- column pickers are built from -- a script the user still has to map
          -- must show them something to pick.
          sc.header, sc.rows = header, rows
          if #rows == 0 then
            sc.error = "The script CSV has no data rows."
          else
            local cols = vo.MapColumns(header, sc.mapping)
            if not cols then
              sc.error = "This script's Filename and Line text columns are not mapped."
            else
              sc.lines = vo.BuildScriptLines(rows, cols, filters)
            end
          end
        end
      end
    end
  end

  return { scripts = scripts, lines = vo.MergeScriptLines(scripts) }
end

--------------------------------
-- Pure layer: number expansion
--------------------------------

-- Whisper writes spoken numbers as words; scripts write them as digits. Both
-- sides go through Normalize, so digits are expanded to their cardinal form.
-- Year forms ("nineteen ninety nine") and other readings are deliberately not
-- guessed — the substitution table is the override for those.
local CARDINAL_ONES = {
  [0] = "zero",
  "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
  "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
  "seventeen", "eighteen", "nineteen",
}

local CARDINAL_TENS = {
  [2] = "twenty", [3] = "thirty",  [4] = "forty",  [5] = "fifty",
  [6] = "sixty",  [7] = "seventy", [8] = "eighty", [9] = "ninety",
}

-- Irregular ordinal forms; anything else takes a plain "th".
local ORDINAL_FORMS = {
  zero = "zeroth", one = "first", two = "second", three = "third",
  five = "fifth", eight = "eighth", nine = "ninth", twelve = "twelfth",
  twenty  = "twentieth",  thirty  = "thirtieth",  forty = "fortieth",
  fifty   = "fiftieth",   sixty   = "sixtieth",   seventy = "seventieth",
  eighty  = "eightieth",  ninety  = "ninetieth",
  hundred = "hundredth",  thousand = "thousandth",
}

-- Cardinal words for an integer in [0, 9999]. Returns nil outside that range.
function vo.NumberToWords(n)
  if type(n) ~= "number" or n ~= math.floor(n) or n < 0 or n > 9999 then return nil end
  if n == 0 then return "zero" end

  local parts = {}
  local thousands = math.floor(n / 1000)
  if thousands > 0 then
    parts[#parts + 1] = CARDINAL_ONES[thousands]
    parts[#parts + 1] = "thousand"
    n = n % 1000
  end

  local hundreds = math.floor(n / 100)
  if hundreds > 0 then
    parts[#parts + 1] = CARDINAL_ONES[hundreds]
    parts[#parts + 1] = "hundred"
    n = n % 100
  end

  if n > 0 then
    if n < 20 then
      parts[#parts + 1] = CARDINAL_ONES[n]
    else
      parts[#parts + 1] = CARDINAL_TENS[math.floor(n / 10)]
      if n % 10 > 0 then parts[#parts + 1] = CARDINAL_ONES[n % 10] end
    end
  end

  return table.concat(parts, " ")
end

-- Ordinal words for an integer in [0, 9999]. Only the final word changes.
function vo.NumberToOrdinalWords(n)
  local words = vo.NumberToWords(n)
  if not words then return nil end
  local head, last = words:match("^(.*%s)(%S+)$")
  if not last then head, last = "", words end
  return head .. (ORDINAL_FORMS[last] or (last .. "th"))
end

-- "42" -> "forty two", "3rd" -> "third". Returns nil if the token is not a
-- number we expand, so the caller keeps it verbatim.
local function ExpandNumberToken(token)
  local digits, suffix = token:match("^(%d+)(%a*)$")
  if not digits then return nil end
  local n = tonumber(digits)
  if suffix == "" then return vo.NumberToWords(n) end
  if suffix == "st" or suffix == "nd" or suffix == "rd" or suffix == "th" then
    return vo.NumberToOrdinalWords(n)
  end
  return nil
end

--------------------------------
-- Pure layer: normalization
--------------------------------

-- Unicode punctuation that would otherwise survive the ASCII-only pass below.
-- Curly apostrophes vanish (so "don’t" folds to "dont", matching "don't");
-- dashes, quotes and ellipses become word breaks.
local UNICODE_PUNCT = {
  ["\226\128\152"] = "",  -- U+2018 left single quote
  ["\226\128\153"] = "",  -- U+2019 right single quote
  ["\226\128\147"] = " ", -- U+2013 en dash
  ["\226\128\148"] = " ", -- U+2014 em dash
  ["\226\128\156"] = " ", -- U+201C left double quote
  ["\226\128\157"] = " ", -- U+201D right double quote
  ["\226\128\166"] = " ", -- U+2026 ellipsis
}

-- Fold text to the common form used on both the script and transcript sides.
-- Order matters: punctuation is stripped first so substitution keys match real
-- tokens, and substitutions run before number expansion so a user can override
-- any reading this module gets wrong (e.g. ["1999"] = "nineteen ninety nine").
-- subs: optional table of normalized token -> replacement text
function vo.Normalize(text, subs)
  local s = tostring(text or ""):lower()

  for from, to in pairs(UNICODE_PUNCT) do s = s:gsub(from, to) end
  s = s:gsub("'", "")

  -- ASCII punctuation becomes a word break. Bytes >= 0x80 are left alone so
  -- accented words stay whole (both sides fold identically either way).
  s = s:gsub("[\1-\127]", function(c)
    if c:find("[%w%s]") then return c end
    return " "
  end)

  local substituted = {}
  for token in s:gmatch("%S+") do
    local replacement = subs and subs[token]
    if replacement then
      for part in tostring(replacement):lower():gmatch("%S+") do
        substituted[#substituted + 1] = part
      end
    else
      substituted[#substituted + 1] = token
    end
  end

  local out = {}
  for _, token in ipairs(substituted) do
    local words = ExpandNumberToken(token)
    if words then
      for word in words:gmatch("%S+") do out[#out + 1] = word end
    else
      out[#out + 1] = token
    end
  end

  return table.concat(out, " ")
end

-- Whitespace tokenizer. Input is expected to be Normalize()d already.
function vo.Tokenize(s)
  local tokens = {}
  for token in tostring(s or ""):gmatch("%S+") do
    tokens[#tokens + 1] = token
  end
  return tokens
end

-- The words a take has that its line does not, as drawable runs.
--
-- The sheet used to colour a whole transcript amber when its match score fell
-- in the "review" band -- the colour encoded a threshold, with no legend and no
-- number, so from the outside it read as random. This says something the reader
-- can act on instead: here are the words that are not in the line.
--
-- Aligns the two token streams by longest common subsequence, so a word only
-- counts as extra when it cannot be paired with one in the line IN ORDER. A
-- multiset would call the second half of a double-read extra and also let a word
-- that moved across the line pass unmarked; the LCS gets both right. Comparison
-- is on Normalize()d tokens.
--
-- A word that PAIRS is shown with the LINE's spelling, not the transcriber's:
-- whisper's capitalisation and punctuation are a guess, the script's are the
-- writer's, and two guesses side by side on one card read as a difference that
-- means something when it does not. What the reader actually said still shows
-- wherever it diverges -- an unpaired word keeps its own spelling and its amber.
--
-- Returns: array of { text = string, extra = boolean } in take order, adjacent
-- runs of the same verdict merged. Marks nothing when there is no line to
-- compare against -- an orphan is not a take full of extra words.
function vo.ExtraWords(line_text, take_text, subs)
  local raw = {}
  for token in tostring(take_text or ""):gmatch("%S+") do raw[#raw + 1] = token end
  if #raw == 0 then return {} end

  -- The line's display words, and which comparison tokens each one yields --
  -- the mirror of the take side below, because a paired take word has to be
  -- able to name the line word whose spelling it is about to borrow.
  local line_raw = {}
  for token in tostring(line_text or ""):gmatch("%S+") do line_raw[#line_raw + 1] = token end
  local line, line_owner = {}, {}
  for i, token in ipairs(line_raw) do
    for _, t in ipairs(vo.Tokenize(vo.Normalize(token, subs))) do
      line[#line + 1] = t
      line_owner[#line] = i
    end
  end
  if #line == 0 then
    return { { text = table.concat(raw, " "), extra = false } }
  end

  -- The comparison stream, with each token remembering which display word it
  -- came from. One display word can yield several: Normalize breaks "well-worn"
  -- in two, and the line it is being compared against says "well worn".
  local take, owner = {}, {}
  for i, token in ipairs(raw) do
    for _, t in ipairs(vo.Tokenize(vo.Normalize(token, subs))) do
      take[#take + 1] = t
      owner[#take] = i
    end
  end
  if #take == 0 then
    return { { text = table.concat(raw, " "), extra = false } }
  end

  -- LCS lengths over (line, take); walk back for which take tokens paired.
  local n, m = #line, #take
  local L = {}
  for i = 0, n do L[i] = {} for j = 0, m do L[i][j] = 0 end end
  for i = 1, n do
    for j = 1, m do
      if line[i] ~= "" and line[i] == take[j] then L[i][j] = L[i - 1][j - 1] + 1
      else L[i][j] = math.max(L[i - 1][j], L[i][j - 1]) end
    end
  end

  -- Walking back from the end pairs the LATEST valid occurrence, which is the
  -- right tie to take: where a reader stumbled and went again, both halves pair
  -- equally well, and the half worth colouring is the false start, not the read
  -- they settled on.
  -- paired[take token] = the line token it went with, so the walk below can
  -- reach the line's display word and not just the fact that there was one.
  local paired = {}
  local i, j = n, m
  while i > 0 and j > 0 do
    if line[i] ~= "" and line[i] == take[j] then
      paired[j] = i
      i, j = i - 1, j - 1
    elseif L[i - 1][j] >= L[i][j - 1] then i = i - 1
    else j = j - 1 end
  end

  -- Back to display words. Each take word owns the comparison tokens it made.
  local toks_of = {}
  for k = 1, m do
    local list = toks_of[owner[k]]
    if not list then list = {} toks_of[owner[k]] = list end
    list[#list + 1] = k
  end

  local runs = {}
  local function push(text, extra)
    local last = runs[#runs]
    if last and last.extra == extra then last.text = last.text .. " " .. text
    else runs[#runs + 1] = { text = text, extra = extra } end
  end

  local spoken_for = {}
  for k = 1, #raw do
    local toks = toks_of[k]
    if not toks then
      -- Normalizes to nothing at all (punctuation standing on its own): never
      -- extra, because there was nothing here to fail to match.
      push(raw[k], false)
    else
      -- A word Normalize split is extra if ANY part of it went unpaired.
      local whole, owners = true, {}
      for _, t in ipairs(toks) do
        local li = paired[t]
        if not li then whole = false break end
        local o = line_owner[li]
        if owners[#owners] ~= o then owners[#owners + 1] = o end
      end
      if not whole then
        push(raw[k], true)
      else
        local text = {}
        for _, o in ipairs(owners) do
          if not spoken_for[o] then
            spoken_for[o] = true
            text[#text + 1] = line_raw[o]
          end
        end
        -- Nothing left to say: several take words paired into one line word
        -- ("well worn" read against a scripted "well-worn"), and that one word
        -- is already on screen.
        if #text > 0 then push(table.concat(text, " "), false) end
      end
    end
  end
  return runs
end

--------------------------------
-- Pure layer: whisper output
--------------------------------

-- Parse the CSV written by `whisper-cli -ml 1 -sow -ocsv`: start,end,text with
-- times in milliseconds and RFC4180-quoted text. The header row and any row with
-- non-numeric times or empty text are dropped, so a header is optional.
-- Returns: array of { t0 = seconds, t1 = seconds, text = string }
function vo.ParseWhisperCSV(text)
  local words = {}
  for _, row in ipairs(vo.ParseCSV(text)) do
    local t0, t1 = tonumber(row[1]), tonumber(row[2])
    local word = trim(row[3])
    if t0 and t1 and word ~= "" then
      words[#words + 1] = { t0 = t0 / 1000.0, t1 = t1 / 1000.0, text = word }
    end
  end
  return words
end

-- A minimal JSON reader, sized to whisper-cli's -ojf output and nothing more.
--
-- Hand-rolled on purpose: the repo vendors no dependencies, and every other
-- format here (CSV, TKM chunks) is parsed the same way. Handles objects,
-- arrays, strings with the JSON escapes whisper actually emits, numbers,
-- true/false/null. Returns the decoded value and the next index, or nil on
-- malformed input -- callers treat that as "not a transcript".
local function json_decode(s, i)
  i = s:find("[^ \t\r\n]", i or 1)
  if not i then return nil end
  local c = s:sub(i, i)
  if c == "{" or c == "[" then
    local out, want_key = {}, (c == "{")
    i = i + 1
    while true do
      i = s:find("[^ \t\r\n]", i)
      if not i then return nil end
      local d = s:sub(i, i)
      if d == (want_key and "}" or "]") then return out, i + 1 end
      if d == "," then i = i + 1
      elseif want_key then
        local key; key, i = json_decode(s, i)
        if type(key) ~= "string" then return nil end
        i = s:find("[^ \t\r\n]", i)
        if not i or s:sub(i, i) ~= ":" then return nil end
        local val; val, i = json_decode(s, i + 1)
        if i == nil then return nil end
        out[key] = val
      else
        local val; val, i = json_decode(s, i)
        if i == nil then return nil end
        out[#out + 1] = val
      end
    end
  elseif c == '"' then
    local buf, j = {}, i + 1
    while true do
      local k = s:find('[\\"]', j)
      if not k then return nil end
      buf[#buf + 1] = s:sub(j, k - 1)
      if s:sub(k, k) == '"' then
        return table.concat(buf), k + 1
      end
      local e = s:sub(k + 1, k + 1)
      if     e == "n" then buf[#buf + 1] = "\n"
      elseif e == "t" then buf[#buf + 1] = "\t"
      elseif e == "r" then buf[#buf + 1] = "\r"
      elseif e == "u" then
        -- Whisper text is UTF-8 in the string body; \u escapes only ever
        -- carry ASCII here. Anything above is kept as a literal '?' rather
        -- than growing a UTF-16 decoder for bytes no caller reads.
        local hex = s:sub(k + 2, k + 5)
        local cp = tonumber(hex, 16)
        buf[#buf + 1] = (cp and cp < 128) and string.char(cp) or "?"
        j = k + 6
      else buf[#buf + 1] = e end
      if e ~= "u" then j = k + 2 end
    end
  elseif s:find("^true", i)  then return true,  i + 4
  elseif s:find("^false", i) then return false, i + 5
  elseif s:find("^null", i)  then return nil,   i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[+%-]?%d*", i)
    if not num or num == "" then return nil end
    return tonumber(num), i + #num
  end
end

-- Parse the JSON written by `whisper-cli -ml 1 -sow -ojf`. With -ml 1 a
-- SEGMENT is one word; its `tokens` are sub-word pieces ("Br"/"ant"/"ley").
--
-- The point of -ojf over -ocsv is the per-token `t_dtw`: a cross-attention
-- anchor that sits ON the word, where `offsets` are a contiguous partition of
-- the timeline that can miss the word entirely (SPEC-word-anchors.md §2). The
-- word's anchor is the smallest qualifying token anchor; special tokens
-- ("[_BEG_]" etc.) and unset anchors (t_dtw < 0, whisper's "never computed"
-- sentinel) don't qualify. A word with no qualifying token gets anchor = nil
-- and downstream falls back to t0.
-- Returns: array of { t0, t1 = seconds, text = string, anchor = seconds|nil }
function vo.ParseWhisperJSON(text)
  local doc = type(text) == "string" and json_decode(text) or nil
  local segs = doc and doc.transcription
  if type(segs) ~= "table" then return {} end
  local words = {}
  for _, seg in ipairs(segs) do
    local word = trim(seg.text or "")
    local off = seg.offsets
    if word ~= "" and type(off) == "table"
       and tonumber(off.from) and tonumber(off.to) then
      local anchor
      for _, tok in ipairs(seg.tokens or {}) do
        local dt = tonumber(tok.t_dtw)
        if dt and dt >= 0 and not tostring(tok.text or ""):find("^%[_") then
          local a = dt / 100.0
          if not anchor or a < anchor then anchor = a end
        end
      end
      words[#words + 1] = { t0 = off.from / 1000.0, t1 = off.to / 1000.0,
                            text = word, anchor = anchor }
    end
  end
  return words
end

-- Longest stretch of `words` that is one short phrase repeated back to back.
--
-- This is the signature of a whisper decoder that has fallen into a repetition
-- loop: it keeps emitting the same phrase, with confident timestamps, until the
-- audio runs out. Nothing downstream can distinguish that from real speech, so
-- it has to be caught here and shown to the user -- a transcript that ends in a
-- loop is not merely inaccurate, it is missing however many minutes the loop
-- covered. `-mc 0` in vo.BuildWhisperArgv makes it far less likely; this is the
-- check that it worked.
--
-- Thresholds are set so ordinary repetition in a read ("no, no, no") cannot
-- trip it: a run needs at least 4 cycles AND 12 repeated words.
--
-- AND the cycles must be BACK TO BACK. This is what separates a decoder loop
-- from an actor, and it was missing: on a real session the detector reported
-- "Do not repeat that." four times as a loop and told the user to re-transcribe
-- a 39-minute file. The script has that line. Four takes of a short line is
-- normal -- it is what this whole tool is for.
--
-- A decoder emitting the same phrase over and over does not breathe: the
-- repeats abut. A reader going again pauses first, however briefly (0.22s,
-- 0.60s and 0.84s between the four reads above). So a pause of
-- LOOP_MAX_PAUSE or more ends the run, and four re-reads count as at most two
-- cycles -- under the threshold, silent.
--
-- False negative it accepts: a loop that happens to fall either side of a
-- pause reads as two shorter runs. That is the right way to be wrong. Missing
-- a loop costs a transcript the user can re-run; crying wolf costs a good
-- transcript they were told to throw away.
-- Returns: nil, or { from, to, phrase, cycles, words } (times in source seconds)
vo.LOOP_MAX_PHRASE  = 12
vo.LOOP_MIN_CYCLES  = 4
vo.LOOP_MIN_WORDS   = 12
vo.LOOP_MAX_PAUSE   = 0.35

function vo.DetectRepetitionLoop(words)
  local n = #(words or {})
  local best
  local i = 1
  while i <= n do
    local run_end = i
    local best_k, best_cycles = nil, 0
    for k = 1, vo.LOOP_MAX_PHRASE do
      if i + 2 * k - 1 > n then break end
      local cycles = 1
      while true do
        local a, b = i + (cycles - 1) * k, i + cycles * k
        if b + k - 1 > n then break end
        local same = true
        for j = 0, k - 1 do
          if words[a + j].text ~= words[b + j].text then same = false break end
        end
        if not same then break end
        -- A breath ANYWHERE in the stretch being added means a person said it
        -- again. Checking only the junction between blocks is not enough: with
        -- a phrase offset by a word or two, the block boundary falls mid-read
        -- and the pause hides inside the block.
        local breathed = false
        for j = b, b + k - 1 do
          local prev, this = words[j - 1], words[j]
          local gap = (prev.t1 and this.t0) and (this.t0 - prev.t1) or 0
          if gap >= vo.LOOP_MAX_PAUSE then breathed = true break end
        end
        if breathed then break end
        cycles = cycles + 1
      end
      if cycles * k > best_cycles * (best_k or 1) then
        best_k, best_cycles = k, cycles
      end
    end
    local span = best_k and best_cycles * best_k or 0
    if best_k and best_cycles >= vo.LOOP_MIN_CYCLES and span >= vo.LOOP_MIN_WORDS then
      if not best or span > best.words then
        local phrase = {}
        for j = 0, best_k - 1 do phrase[#phrase + 1] = words[i + j].text end
        best = {
          from   = words[i].t0,
          to     = words[i + span - 1].t1,
          phrase = table.concat(phrase, " "),
          cycles = best_cycles,
          words  = span,
        }
      end
      run_end = i + span - 1
    end
    i = run_end + 1
  end
  return best
end

--------------------------------
-- Pure layer: take identity
--------------------------------

-- Take identity lives in RANGED TAKE MARKERS (the section below), not in
-- item GUIDs: a marker is a source-time fact about the performance, visible
-- and draggable in the arrange view, and it survives any item surgery via
-- split propagation. The GUID-anchor mechanism that briefly lived here was
-- retired before ever being published.

-- THE TRACK IS THE DECISION, alongside the governing idea that the name is the
-- assignment: an item on the Selects track IS the select, one on Alts IS a
-- keep. Pull already writes this direction; this reads it back.
--
-- Track placement is the most damage-resistant signal in the system. Marks live
-- in a source-time key that a re-match can invalidate and item names can be
-- edited by anything, but "this item sits on Selects" survives all of it -- so
-- it is what lets scrambled marks heal themselves.
--
-- The Review track deliberately maps to nothing: it means "undecided, look at
-- this", which is the absence of a decision rather than a mark.
function vo.MarkFromTrack(track_name, cfg)
  if not track_name or track_name == "" then return nil end
  cfg = cfg or {}
  local name = fold(track_name)
  if name == fold(cfg.track_selects or "Selects") then return "select" end
  if name == fold(cfg.track_alts    or "Alts")    then return "keep"   end
  return nil
end

-- THE OTHER DIRECTION: which destination a take's marks say it belongs on.
-- The exact inverse of vo.MarkFromTrack, and its neighbour on purpose -- a tick
-- that moves an item and an item whose track speaks for its tick have to agree,
-- or the sheet would fight itself on the next rebuild.
--
-- Sel wins over Keep, the same precedence vo.PlanPull uses: a take that is both
-- is THE delivery, and a take that is only Keep ships beside it as an alt.
--
-- Returns nil for "no decision", and nil is deliberately NOT Review here. Pull
-- parks undecided takes on Review because a first pass has to put everything
-- somewhere before anyone has listened. Auto-sort answers a click that just
-- REMOVED a decision, and the honest place for a take nobody is keeping is the
-- recording it was cut out of -- the caller reads nil as "hand it back to its
-- parent".
function vo.TrackForMarks(marks)
  marks = marks or {}
  if marks.select then return "selects" end
  if marks.keep   then return "alts"    end
  return nil
end

-- What a take's Sel and Keep actually are, given what the user stored and where
-- the item sits. ONE function, so the rule cannot drift between the sheet, Pull
-- and the repair pass.
--
--   1. an explicit decision -- including an explicit NO -- always wins
--   2. otherwise the item's track decides
--   3. otherwise unticked
--
-- Each mark is decided independently: saying "no" to Sel must not stop Keep
-- following an Alts track.
function vo.EffectiveMarks(entry, track_name, cfg)
  local from_track = vo.MarkFromTrack(track_name, cfg)
  local sel, keep
  if entry and entry.select ~= nil then sel  = entry.select
  else                                  sel  = (from_track == "select") end
  if entry and entry.keep   ~= nil then keep = entry.keep
  else                                  keep = (from_track == "keep")   end
  return { select = sel, keep = keep }
end

-- What is in an item: one take, or several. Detected, not asked.
--
-- This used to be two buttons the user had to choose between -- "Find lines in
-- items" for items holding several takes, "Assign items to lines" for items
-- that are already one take each -- and choosing wrong did the wrong thing.
-- But the tool can SEE which it is: count the match spans that fall inside the
-- item. That was never a decision, only a fact nobody had asked for.
--
-- The two answers genuinely differ, which is why the split existed:
--
--   ONE span inside   the item IS that take. Its marker spans the whole item,
--                     at the user's own edges (hand-trimmed edges are truth),
--                     and the item takes the line's name -- the name IS the
--                     assignment.
--   MANY spans inside the item CONTAINS takes. One marker per span, at the
--                     SPAN's bounds, and the item is NOT renamed: an item
--                     holding four lines cannot be named after one of them.
--
-- A span counts as "inside" when `floor` of the SPAN's own length is within
-- the item, not `floor` of the item -- so a clip holding one take plus the
-- tail of the previous one still reads as one take, which is what it is.
--
-- Naming is decided independently of marking, so a session already marked by
-- an earlier run still gets named: that is what "adopt an existing session"
-- was a separate button for.
--
-- `items`: { { key, from, to, spans = { { start, stop, asset, deliver,
--              marked } } } } -- from/to are SOURCE times.
-- Returns: plans { { key, kind, markers = { { start, stop, asset } }, name } },
--          counts { one, many, none }
function vo.PlanItemIdentity(items, opts)
  opts = opts or {}
  local floor_ = opts.floor or 0.35

  local plans = {}
  local counts = { one = 0, many = 0, none = 0 }

  for _, it in ipairs(items or {}) do
    local from, to = it.from, it.to
    local inside = {}
    if from and to and to > from then
      for _, s in ipairs(it.spans or {}) do
        local len = (s.stop or 0) - (s.start or 0)
        if len > 0 then
          local overlap = math.min(s.stop, to) - math.max(s.start, from)
          if overlap > 0 and (overlap / len) >= floor_ then
            inside[#inside + 1] = s
          end
        end
      end
    end

    local plan = { key = it.key, markers = {} }
    if #inside == 0 then
      plan.kind = "none"
      counts.none = counts.none + 1
    elseif #inside == 1 then
      -- The item IS this take: marker at the item's own edges.
      local s = inside[1]
      plan.kind = "one"
      plan.name = s.deliver or s.asset
      plan.span = s
      if not s.marked then
        plan.markers[1] = { start = from, stop = to, asset = s.asset }
      end
      counts.one = counts.one + 1
    else
      -- The item CONTAINS takes: marker per span, at the span's own bounds.
      plan.kind = "many"
      table.sort(inside, function(a, b) return (a.start or 0) < (b.start or 0) end)
      for _, s in ipairs(inside) do
        -- `replace` re-derives the edges of takes that ALREADY have a marker.
        -- Normally an existing marker is left alone -- re-running has to be
        -- safe -- but that also meant a change to the boundary settings could
        -- never reach a session that had been identified once: every re-run
        -- skipped every span and the markers never moved, whatever the
        -- settings said. The caller keeps the existing marker's id, so this
        -- moves edges without breaking the row's identity.
        if (not s.marked) or opts.replace then
          plan.markers[#plan.markers + 1] =
            { start = s.start, stop = s.stop, asset = s.asset, span = s,
              redo = s.marked and true or nil }
        end
      end
      counts.many = counts.many + 1
    end
    plans[#plans + 1] = plan
  end

  return plans, counts
end

-- Which item gets which step of an update pass -- the routing behind Update
-- from Item and Update from Marker (VO/SPEC-authority-buttons.md).
--
-- Both buttons ask the same question of every item in scope: how many take
-- markers does it hold? The answer decides the step, and the two directions
-- differ in exactly one row of the table -- what a marker-less item means.
--
--   2+ markers   a RECORDING, not a take. Refused by both: there is no one
--                marker to pair the item with, and snapping or trimming to
--                one of several would be a guess. Cut is what splits these.
--   1 marker     the pair to act on -- snap the marker to the item ("item"),
--                or trim the item to the marker ("marker").
--   0 markers    "item": the item is the authority, so a missing marker is a
--                marker that was never written or was deleted -- identify it
--                (`identify`) when the matcher recognises the audio, report it
--                (`unmatched`) when it does not. A weak match is not a reason
--                to refuse; nobody asked about the score.
--                "marker": there is no authority to update from (`nomarker`).
--
-- `identify` is a FIRST pass, not a verdict: the caller marks those items and
-- then re-reads them, at which point they hold one marker and take the `act`
-- path. That is why this returns keys rather than deciding their fate here --
-- the chunk after the write is the only honest source for the second question.
--
-- items: { { key, marker_count, span_count } } -- span_count is the match or
-- review spans inside the item, and is only consulted for dir "item".
function vo.PlanUpdatePass(items, dir)
  local from_item = (dir or "item") == "item"
  local out = { identify = {}, act = {}, several = {},
                unmatched = {}, nomarker = {} }
  for _, it in ipairs(items or {}) do
    local n, spans = it.marker_count or 0, it.span_count or 0
    local bucket
    if n > 1 then                bucket = out.several
    elseif n == 1 then           bucket = out.act
    elseif not from_item then    bucket = out.nomarker
    elseif spans > 0 then        bucket = out.identify
    else                         bucket = out.unmatched end
    bucket[#bucket + 1] = it.key
  end
  return out
end

-- Parity: does one take's marker, item and sheet row still tell one story?
--
-- Pure -- the caller assembles the elements, this only compares. A recording
-- (several markers) is never compared: it has no one name and no one range,
-- and Cut is what turns it into takes. An unmarked item is Match's business,
-- not parity's. Duplicate clusters reach the queue from the update pass's
-- refusals, not from here.
-- See docs/superpowers/specs/2026-08-14-vo-parity-watcher-design.md §3.
--
-- takes: { { key, marker = {asset,start,stop}|nil, marker_count,
--            item = {name,from,to}|nil, sheet = {asset}|nil }, ... }
-- opts:  { eps = edge tolerance in seconds (default 0.005),
--          alt_pattern = the alt naming pattern, so a conventional alt name
--                        over its own line's marker is agreement, not drift }
-- Returns: { { key, fields = {"name"|"edges",...}, detail }, ... }
function vo.ParityDiff(takes, opts)
  opts = opts or {}
  local eps = opts.eps or 0.005
  local out = {}
  for _, tk in ipairs(takes or {}) do
    if tk.marker and (tk.marker_count or 0) == 1 then
      local fields, detail = {}, nil
      local iname = tk.item and tk.item.name
      if iname and iname ~= "" and iname ~= tk.marker.asset
         and not vo.IsConventionalAltName(iname, tk.marker.asset,
                                          opts.alt_pattern) then
        fields[#fields + 1] = "name"
        detail = string.format("marker says %s, item says %s",
                               tostring(tk.marker.asset), iname)
      end
      if tk.sheet and tk.sheet.asset and tk.sheet.asset ~= tk.marker.asset then
        if fields[#fields] ~= "name" then fields[#fields + 1] = "name" end
        detail = detail or string.format("marker says %s, sheet says %s",
                 tostring(tk.marker.asset), tostring(tk.sheet.asset))
      end
      if tk.item and tk.item.from
         and (math.abs(tk.marker.start - tk.item.from) > eps
              or math.abs(tk.marker.stop - (tk.item.to or 0)) > eps) then
        fields[#fields + 1] = "edges"
        detail = detail or string.format(
          "marker %.3f-%.3f, item %.3f-%.3f",
          tk.marker.start, tk.marker.stop, tk.item.from, tk.item.to or 0)
      end
      if #fields > 0 then
        out[#out + 1] = { key = tk.key, fields = fields, detail = detail }
      end
    end
  end
  return out
end

-- Shape one project's collected take markers plus sheet rows into ParityDiff
-- input. `collected` is vo.CollectTakeMarkers' by-path map; `rows` are sheet
-- rows (item, asset, take_name). An item the sheet does not know contributes
-- no sheet element and no item name -- ParityDiff treats nil as nothing to
-- compare, not as a divergence.
function vo.ParityAssemble(collected, rows, opts)
  local sheet_by_item = {}
  for _, row in ipairs(rows or {}) do
    if row.item and not sheet_by_item[row.item] then
      sheet_by_item[row.item] = { asset = row.asset, name = row.take_name }
    end
  end
  local out = {}
  for _, group in pairs(collected or {}) do
    for _, entry in ipairs(group) do
      local item = entry.info and entry.info.item
      if item then
        local tool = {}
        for _, m in ipairs(entry.markers or {}) do
          local asset, id = vo.ParseMarkerName(m.name or "")
          if id and not vo.IsNoteMarker(m.name or "") then
            tool[#tool + 1] = { asset = asset, start = m.pos or 0,
                                stop = (m.pos or 0) + (m.length or 0) }
          end
        end
        local row = sheet_by_item[item]
        out[#out + 1] = {
          key = item,
          marker = tool[1],
          marker_count = #tool,
          item = entry.coverage and {
            name = row and row.name or nil,
            from = entry.coverage.from,
            to   = entry.coverage.to,
          } or nil,
          sheet = (row and row.asset) and { asset = row.asset } or nil,
        }
      end
    end
  end
  return out
end

-- Which single element did the user edit? The watcher hands in what changed
-- since the baseline; exactly one changed element IS the authority, anything
-- else is nil -- the tool acts on knowledge or it asks (spec §4.2).
--
-- "edge" means LENGTH or the source window changed, not position alone: a
-- track move keeps an item's length, and treating position as an edge would
-- turn every vertical drag into two changed elements and queue every one.
-- The caller (the snapshot pass) owns that distinction; here four booleans
-- go in and one name comes out.
function vo.ParityAttribute(changed)
  if not changed then return nil end
  local map = { edge = "item", name = "name", marker = "marker",
                track = "sheet" }
  local hit = nil
  for k, authority in pairs(map) do
    if changed[k] then
      if hit then return nil end
      hit = authority
    end
  end
  return hit
end

-- Which of `ranges` is the same take as `span`, by overlap.
--
-- "Is this take already marked?" cannot be asked by comparing start times. A
-- marker is written at the CUT's edges -- speech bounds, padded, snapped -- and
-- the span is the matcher's raw whisper bounds, so the two never share a start
-- and an equality test answers "not marked" for every take that has one. What
-- that cost: Identify minted a fresh marker for every span on every press while
-- carrying the old ones over, so each run doubled the markers in the item.
--
-- Overlap is the honest question. Measured against the SHORTER of the two, so a
-- marker padded well outside its span still reads as that span's marker, and a
-- long recording's marker cannot claim a short take inside it.
--
-- ranges, span: { start, stop } in the same time base.
-- Returns: index into `ranges`, or nil when nothing overlaps enough.
function vo.BestOverlap(ranges, span, min_fraction)
  if not span or not span.start or not span.stop then return nil end
  local need = min_fraction or 0.5
  local best, best_share
  for i, m in ipairs(ranges or {}) do
    local lo = math.max(m.start or 0, span.start)
    local hi = math.min(m.stop or 0, span.stop)
    local over = hi - lo
    if over > 0 then
      local shorter = math.min((m.stop or 0) - (m.start or 0), span.stop - span.start)
      local share = (shorter > 0) and (over / shorter) or 0
      if share >= need and (not best_share or share > best_share) then
        best, best_share = i, share
      end
    end
  end
  return best, best_share
end

-- What a batch action acts on: the selection, whichever way it was made.
--
-- There are two selections in this tool and they used to be different ideas --
-- the sheet's row selection, and REAPER's item selection -- with a checkbox
-- ("Selected rows only") deciding whether the first one counted at all. Two
-- selections and a toggle is three things to hold in mind before pressing
-- anything, which is the opposite of feeling in control.
--
-- They are one idea, because `row.item` is the bridge. A row IS a take; an
-- item CONTAINS takes. After Cut that is one take per item and the two
-- selections name the same set. Before Cut one recording item holds every take
-- in the session, so selecting it selects them all -- which is exactly what
-- "cut this recording" should mean. The same rule reads correctly at both
-- stages, so the UI never has to distinguish them.
--
-- Never silently widens. A selection that matches nothing in view returns an
-- EMPTY scope rather than falling back to everything -- acting on 169 lines
-- because the one you picked was filtered out is the worst possible answer --
-- and NO selection returns an empty scope too.
--
-- That second rule replaced "no selection means everything". The old default
-- was defensible on paper (the filters are the scoping tool) and wrong in the
-- hand: the difference between a run over three takes and a run over the whole
-- session was whether a click had landed, and the two look identical until
-- after the press. A verb with nothing to act on is a no-op you can see
-- coming; a verb quietly acting on everything is not. The caller shows the
-- empty scope and disables the button rather than letting a press be a
-- surprise.
--
-- `rows` is the pool a ROW selection picks FROM (what the filters are showing).
-- `all_rows` is the unfiltered pool an ITEM selection picks from; omit it and
-- both fall back to `rows`, which is the old behaviour.
--
-- THE TWO SELECTIONS ARE FILTERED DIFFERENTLY, and they have to be:
--
--   a ROW selection is already filtered, tautologically -- you cannot click a
--   row the filters are hiding, so narrowing it by the filters changes nothing
--   and keeps "a filtered table acts on what it is showing" true.
--
--   an ITEM selection is made in the ARRANGE, where the sheet's filters do not
--   exist. Selecting a recording means the takes inside it; what the table
--   happens to be displaying is not part of that intention. Intersecting the
--   two produced the worst outcome available: a speaker filter left on from
--   earlier reading silently emptied the scope of an explicit selection, so
--   "select the recording, press Cut" cut nothing and said only that something
--   was hidden.
--
-- This is NOT the "never silently widens" rule being relaxed. That rule exists
-- so that NO selection means nothing rather than everything, and it is
-- untouched: no selection still returns an empty scope. Honouring a selection
-- the user made by hand is the opposite of widening silently.
--
-- Returns: rows in scope, picked (whether any selection exists at all).
-- picked == false always means #rows == 0; the two together let the caller
-- tell "nothing selected" from "selection is hidden by the filters".
function vo.ResolveScope(rows, selected_uids, selected_items, all_rows)
  local picked = (selected_uids and next(selected_uids) ~= nil)
              or (selected_items and next(selected_items) ~= nil)
  if not picked then return {}, false end

  local out, seen = {}, {}
  local function take(row)
    if seen[row] then return end
    seen[row] = true
    out[#out + 1] = row
  end

  for _, row in ipairs(rows or {}) do
    if row.uid ~= nil and selected_uids and selected_uids[row.uid] then take(row) end
  end
  for _, row in ipairs(all_rows or rows or {}) do
    if row.item ~= nil and selected_items and selected_items[row.item] then take(row) end
  end
  return out, true
end

-- One take of a line is the Select; the line key is what "one line" means.
-- By SCRIPT ROW, never by filename: two CSV rows may share a filename (the
-- Append column separates them), and keying by name would fuse them. This
-- is the same rule the sheet's SetSelect exclusivity uses -- one function,
-- so the two cannot drift.
function vo.LineKey(row)
  return row.script_row or ("asset:" .. tostring(row.asset))
end

-- Lines carrying more than one Sel. Not an error state to be prevented --
-- track placement legitimately creates it (EffectiveMarks rule 2: two items
-- of a line dragged onto Selects both read as Sel) -- but a decision the
-- user still has to make, so Tidy counts them and the card badges them.
-- Orphans are skipped: they are not lines, and their asset keys collide.
function vo.SelectConflicts(rows)
  local by_key, order = {}, {}
  for _, row in ipairs(rows or {}) do
    if row.user_select and row.status ~= "orphan" then
      local key = vo.LineKey(row)
      local got = by_key[key]
      if not got then
        got = { key = key, label = row.deliver or row.asset or "(unnamed)", count = 0 }
        by_key[key] = got
        order[#order + 1] = got
      end
      got.count = got.count + 1
    end
  end
  local out = {}
  for _, c in ipairs(order) do
    if c.count >= 2 then out[#out + 1] = c end
  end
  return out
end

--------------------------------
-- Pure layer: ranged take markers
--------------------------------

-- The item state chunk stores take markers as `TKM <srcpos> <name> <color>
-- <length>` -- the fourth field is UNDOCUMENTED and API-invisible, but REAPER
-- renders it as a range, native mouse gestures edit it (drag moves the start
-- with length intact, alt-drag moves the end), and API edits leave it alone.
-- Verified in v7.78, 2026-08-09; see SoundDesignDocs
-- Workflow/reaper-session-automation.md §4. All range I/O is chunk I/O, so
-- this whole layer is string work and unit-testable.

function vo.ParseTKMChunk(chunk)
  local out = {}
  for line in tostring(chunk or ""):gmatch("[^\n]+") do
    local body = line:match("^%s*TKM%s+(.*)$")
    if body then
      local pos_s, rest = body:match("^(%S+)%s+(.*)$")
      local pos = tonumber(pos_s)
      if pos and rest then
        local name, tail
        local q = rest:sub(1, 1)
        if q == '"' or q == "'" or q == "`" then
          name, tail = rest:match("^" .. q .. "(.-)" .. q .. "%s*(.*)$")
        else
          name, tail = rest:match("^(%S+)%s*(.*)$")
        end
        if name then
          local color_s, len_s = (tail or ""):match("^(%S*)%s*(%S*)")
          out[#out + 1] = {
            pos    = pos,
            name   = name,
            color  = tonumber(color_s) or 0,
            length = tonumber(len_s) or 0,
          }
        end
      end
    end
  end
  return out
end

-- REAPER's chunk quoting: bare when the token has no whitespace or quotes,
-- else wrapped in whichever of " ' ` the token does not contain.
local function tkm_quote(name)
  name = tostring(name or "")
  if name ~= "" and not name:find("[%s\"'`]") then return name end
  for _, q in ipairs({ '"', "'", "`" }) do
    if not name:find(q, 1, true) then return q .. name .. q end
  end
  return '"' .. name:gsub('"', "'") .. '"'
end

function vo.FormatTKMLine(m)
  return string.format("TKM %.14g %s %d %.14g",
    m.pos or 0, tkm_quote(m.name), math.floor(m.color or 0), m.length or 0)
end

-- Replace ALL TKM lines in an item chunk with `markers`. Existing lines are
-- stripped; new ones are inserted where the old ones sat, or before the
-- take's <SOURCE block when there were none. v1 refuses multi-take items
-- (second TAKE block): the VO session shape is single-take, and guessing
-- which take owns which line is exactly the ambiguity this tool is built to
-- avoid. Returns the (possibly unchanged) chunk and whether it patched.
function vo.PatchTKMChunk(chunk, markers)
  chunk = tostring(chunk or "")
  if chunk:find("\n%s*TAKE%s*\n") or chunk:find("\n%s*TAKE%s+%S") then
    return chunk, false
  end

  local lines, insert_at = {}, nil
  for line in chunk:gmatch("[^\n]+") do
    if line:match("^%s*TKM%s") then
      insert_at = insert_at or (#lines + 1)
    else
      if not insert_at and line:match("^%s*<SOURCE") then
        insert_at = #lines + 1
      end
      lines[#lines + 1] = line
    end
  end
  insert_at = insert_at or #lines  -- last resort: before the closing '>'

  local add = {}
  for _, m in ipairs(markers or {}) do add[#add + 1] = vo.FormatTKMLine(m) end
  for i = #add, 1, -1 do table.insert(lines, insert_at, add[i]) end
  return table.concat(lines, "\n"), true
end

-- Marker names are `<asset> ~<id>`: the visible half says which script line,
-- the id is what the project file keys marks on, so a drag can never detach
-- them. The id is strictly ` ~` + base36 at the END of the name -- a tilde
-- anywhere else is just a character in an asset.
function vo.FormatMarkerName(asset, id)
  return tostring(asset or "") .. " ~" .. tostring(id or "")
end

-- NOTE MARKERS: a run saying, on the timeline, what it decided about a take.
--
-- "It was identified but not faded or pulled" is a question you ask while
-- LOOKING AT THE CLIP, so the answer belongs there rather than in a report you
-- have to go and find. A note is a zero-length take marker -- a point, not a
-- range, so it never reads as a take's extent -- carrying a timestamp and a few
-- words.
--
-- It deliberately has NO ` ~id`, which is what makes it free. Every piece of
-- identity logic in the tool is guarded by `if id then`, so a note is invisible
-- to counting, to the coverage rule, to Remove Extra Take Markers and to
-- everything that decides what a take is. vo.WriteTakeMarkers already keeps
-- id-less markers when it rewrites the tool's set, so a note also survives a
-- re-cut -- which is why the writer prunes its own previous notes rather than
-- letting one accumulate per run.
--
-- The `!` prefix is what makes a note recognisable as OURS while still being
-- id-less. A marker you placed by hand is untouched unless you happened to
-- start its name with an exclamation mark.
vo.NOTE_PREFIX = "!"

-- How much of a reason a note keeps. Long enough for a whole sentence, since
-- the note IS the explanation and half of one explains nothing.
vo.NOTE_MAX_CHARS = 220

function vo.IsNoteMarker(name)
  return tostring(name or ""):sub(1, #vo.NOTE_PREFIX) == vo.NOTE_PREFIX
end

-- `when` is a preformatted stamp (the caller owns the clock, so this stays
-- testable); `text` is the reason. Both are flattened to one line.
function vo.FormatNoteMarker(when, text)
  -- The tilde is REMOVED, not merely discouraged. ParseMarkerName anchors an
  -- id to the end of the name, so a reason that happened to end in "~k9" --
  -- quoting a marker, say -- would make this note parse as a take with a
  -- phantom id, and the sheet would grow a take nothing recorded. Found by the
  -- test that tries exactly that, not by reading the pattern.
  local function clean(s)
    return tostring(s or ""):gsub("~", "-"):gsub("[%c]", " ")
                            :gsub("%s+", " "):gsub("^%s*(.-)%s*$", "%1")
  end
  -- The note's own cut-off, and the only one in the chain: names go into the
  -- chunk quoted (vo.FormatTKMLine -> tkm_quote), so spaces survive the round
  -- trip and nothing below this truncates. 80 characters was short enough to
  -- lose the end of an ordinary sentence -- a reason cut mid-word reads as a
  -- bug in the tool rather than as the explanation it is. What REAPER shows on
  -- a narrow item is clipped by the item's width whatever this says; that is a
  -- zoom level, not lost text.
  local body = clean(text)
  if #body > vo.NOTE_MAX_CHARS then
    body = body:sub(1, vo.NOTE_MAX_CHARS - 1) .. "\u{2026}"
  end
  local stamp = clean(when)
  local out = vo.NOTE_PREFIX
  if stamp ~= "" then out = out .. " " .. stamp end
  if body ~= "" then out = out .. "  " .. body end
  return out
end

-- Replace this item's note markers with one saying `text`, at `pos` (source
-- time). Passing no text just clears them. Returns ok, and how many were
-- removed.
--
-- Zero length, always: a note is an annotation, not an extent.
function vo.WriteNoteMarker(item, pos, when, text)
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok then return false, 0 end
  local keep, dropped = {}, 0
  for _, m in ipairs(vo.ParseTKMChunk(chunk)) do
    if vo.IsNoteMarker(m.name) then
      dropped = dropped + 1
    else
      keep[#keep + 1] = m
    end
  end
  if text and text ~= "" then
    keep[#keep + 1] = { pos = pos or 0, name = vo.FormatNoteMarker(when, text),
                        color = 0, length = 0 }
  end
  local patched, did = vo.PatchTKMChunk(chunk, keep)
  if not did then return false, 0 end
  r.SetItemStateChunk(item, patched, false)
  return true, dropped
end

-- The id is ANCHORED TO THE END, and that anchor is load-bearing: text after it
-- stops the name matching at all, and a marker that does not parse is a take
-- the sheet cannot see. Text before it is captured as part of the asset, which
-- is what names the item.
--
-- That is why a run's explanation of what it did to a take is NOT kept here.
-- It rides on a separate note marker (vo.FormatNoteMarker) that carries no id
-- at all, so it cannot cost a take its identity however it is worded.
function vo.ParseMarkerName(name)
  name = tostring(name or "")
  local asset, id = name:match("^(.-)%s+~(%w+)$")
  if asset and id and id:match("^[0-9a-z]+$") and #id <= 4 then
    return asset, id
  end
  return name, nil
end

-- The COVERAGE RULE: a marker counts only where its range intersects the
-- source window of the item holding it. Split copies land everywhere, but
-- after a cut only the piece covering the span keeps an intersecting window
-- -- so this one rule absorbs split residue without bookkeeping. When two
-- items genuinely cover one marker (overlaps, comps), the one covering more
-- of the range wins; ids make "same take seen twice" unambiguous.
-- Markers without our ` ~id` suffix belong to the user, not the tool.
--
-- `per_item` is an array of { coverage = {from,to}, markers = ParseTKMChunk
-- result }; item_index in the output indexes back into it.
-- How much two markers must share before they are one take rather than two.
--
-- A fraction of the SHORTER marker, so a long marker cannot swallow a short
-- one by merely containing its start. ONE number, read by both places that ask
-- the question -- vo.CountingMarkers' dedupe and vo.ClusterMarkerRanges --
-- because they were answering it differently and that disagreement is what let
-- a take vanish from the sheet while Remove Extra Take Markers saw nothing
-- wrong.
vo.marker_same_take = 0.80

-- How much of a MARKER a span must account for before that marker is taken to
-- be this take's marker rather than one that merely swallows it.
--
-- A marker is the padded form of its span -- a few hundred milliseconds of head
-- and tail room -- so a real pairing accounts for nearly all of it. A marker
-- left straddling two clips by a split accounts for about half, and that is the
-- case this number exists to reject.
--
-- Without it, "does a marker already own this audio?" was answered by ANY
-- overlap, so one over-long marker covering two takes made the second take read
-- as already marked. Identify then refused to mark it, "Update from Item"
-- refused to mark it, and the clip sat there named, unmarked, and with no
-- button that would fix it -- which is exactly how it looked from the outside:
-- nothing wrong on screen, and nothing that helped.
vo.marker_covers_span = 0.60

-- How much of the span that marks it a clip must actually contain before it is
-- a whole take rather than a piece of one.
--
-- A clip covering half of a 13-second "take" is not a take, it is the front of
-- a match that swallowed two reads -- and it looks EXACTLY like a healthy clip
-- on screen: named, in the sheet, audible. Identify is right to leave it alone
-- (its span really is marked), so no button fixes it and nothing says why. This
-- is the number that lets the tool notice and say so.
vo.partial_take_fraction = 0.70

-- Is `mk` plausibly the marker FOR `span`, rather than one that merely reaches
-- across it? Both ranges are source time, { start, stop }.
--
-- Two questions, because one is not enough:
--   most of the SPAN inside the marker  -- the marker really does cover it
--   most of the MARKER used by the span -- and it is not covering much else
function vo.MarkerOwnsSpan(mk, span, fraction)
  if not (mk and span) then return false end
  local a0, a1 = mk.start or 0, mk.stop or 0
  local b0, b1 = span.start or 0, span.stop or 0
  local mlen, slen = a1 - a0, b1 - b0
  if mlen <= 0 or slen <= 0 then return false end
  local overlap = math.min(a1, b1) - math.max(a0, b0)
  if overlap <= 0 then return false end
  return overlap >= slen * vo.marker_same_take
     and overlap >= mlen * (fraction or vo.marker_covers_span)
end

-- How much of a marker, or of an item, the two must share before the marker is
-- one the item HOLDS rather than one it merely touches.
vo.marker_in_item = 0.50

-- Is this marker in this item, or is it just brushing it?
--
-- "Any overlap at all" was the rule, and it made a clip read as a recording
-- because the previous take's marker ended a fifth of a second inside it --
-- a marker you cannot even see on the clip, since almost none of it is there.
-- Every verb needing "the one marker here" then refused the clip.
--
-- EITHER side satisfies it, and that is the whole design:
--
--   half of the MARKER is inside     the ordinary case. A take's own marker
--                                    sits almost entirely within its clip.
--   half of the ITEM is covered      the hard-trimmed case. Trim a clip to one
--                                    second inside a five-second marker and
--                                    only a fifth of the marker is inside --
--                                    but the marker covers ALL of the clip, so
--                                    it is unmistakably that clip's marker.
--
-- Requiring both would lose the second case, which is exactly the case Update
-- from Item exists for. Requiring neither is where this started.
--
-- `mk` is { start, stop } in source time, `cov` is { from, to } -- the item's
-- source window, as vo.SourceCoverageRanges returns it.
function vo.MarkerInItem(mk, cov, fraction)
  fraction = fraction or vo.marker_in_item
  if not (mk and cov) then return false end
  local m_from, m_to = mk.start or 0, mk.stop or 0
  local i_from, i_to = cov.from or 0, cov.to or 0
  local m_len, i_len = m_to - m_from, i_to - i_from
  if m_len <= 0 or i_len <= 0 then return false end
  local overlap = math.min(m_to, i_to) - math.max(m_from, i_from)
  if overlap <= 0 then return false end
  return overlap >= m_len * fraction or overlap >= i_len * fraction
end

function vo.CountingMarkers(per_item)
  local best = {}
  for idx, rec in ipairs(per_item or {}) do
    local cov = rec.coverage
    if cov then
      for _, m in ipairs(rec.markers or {}) do
        local asset, id = vo.ParseMarkerName(m.name)
        if id then
          local start, stop = m.pos, m.pos + (m.length or 0)
          local overlap = math.min(stop, cov.to) - math.max(start, cov.from)
          if overlap > 0 then
            local cur = best[id]
            if not cur or overlap > cur.overlap then
              best[id] = { id = id, asset = asset, start = start, stop = stop,
                           item_index = idx, overlap = overlap }
            end
          end
        end
      end
    end
  end
  local out = {}
  for _, rec in pairs(best) do
    rec.overlap = nil
    out[#out + 1] = rec
  end
  table.sort(out, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return tostring(a.id) < tostring(b.id)
  end)

  -- Two markers for one take: same line, overlapping audio, different ids.
  --
  -- Deduped on OVERLAP, never on the name alone -- two takes of one line share
  -- an asset and are two different performances, which is the whole point of
  -- this tool. But one line cannot be performed twice in the same instant, so
  -- same asset AND overlapping in time is one take wearing two markers.
  --
  -- Overlap means MOST of the shorter marker -- `vo.marker_same_take` of it,
  -- the same fraction PlanDuplicateMarkers clusters on, because it is the same
  -- question asked in the same place: are these two markers on one take?
  --
  -- It was "more than a millisecond", and a millisecond is not a rule, it is a
  -- float-noise guard that got asked to do a rule's job. Two things overlap by
  -- more than a millisecond:
  --
  --   a genuine double  two ids minted for ONE take. They sit on the same
  --                     audio, near enough all of it -- 80% is not a close
  --                     call, it is the floor of a landslide.
  --   bleeding edges    two ADJACENT takes of one line, where the earlier
  --                     take's marker has been snapped to its own item and
  --                     that item has generous tail room. Observed live:
  --                     0.85s of overlap on markers 4.9s and 5.3s long -- 17%
  --                     of the shorter, and unmistakably two performances.
  --
  -- The millisecond rule called the second one a double and dropped the later
  -- id, so the take vanished from the sheet AND -- since PlanMarkerPrune keeps
  -- only what survives this function -- Update from Item deleted the marker
  -- off the clip the user had just trimmed. Generous boundaries guarantee
  -- adjacent takes overlap; that is the design, so the rule has to survive it.
  --
  -- The float-noise case is still covered, and by more margin than before: two
  -- takes cut back to back share an instant, which is 0% of either.
  --
  -- The earliest id wins so the answer is stable between runs, and stability
  -- is what matters here: the marks are keyed `tkm|<id>`, so a survivor that
  -- changed run to run would move the user's Sel and Keep around under them.
  local kept = {}
  for _, rec in ipairs(out) do
    local dup = nil
    for _, k in ipairs(kept) do
      if k.asset == rec.asset then
        local overlap = math.min(k.stop, rec.stop) - math.max(k.start, rec.start)
        local shorter = math.min(k.stop - k.start, rec.stop - rec.start)
        if shorter > 0 and overlap >= shorter * vo.marker_same_take then
          dup = k
          break
        end
      end
    end
    if not dup then
      kept[#kept + 1] = rec
    elseif tostring(rec.id) < tostring(dup.id) then
      dup.id, dup.start, dup.stop, dup.item_index =
        rec.id, rec.start, rec.stop, rec.item_index
    end
  end
  return kept
end

-- What was said inside a marker's range, and how well it matched.
--
-- Markers are the truth about WHICH takes exist -- that is the whole point of
-- them -- but they are only positions and a name, so a row built from a marker
-- knew nothing about the words. After a Cut, which is when markers take over,
-- the transcript column emptied across the whole sheet: the one column that
-- tells you what a take actually says, gone at exactly the moment there are
-- takes to read.
--
-- The match still knows. The TEXT is the words whose anchors fall inside the
-- range (vo.WordsInRange); the SCORE comes from the single matched span that
-- overlaps most, since a score is a fact about one placement and averaging
-- two would mean nothing.
--
-- `flat` is the flattened { span, source_path } list BuildOverview already
-- builds. `words` is this source's word list; a caller without one gets nil,
-- and the row shows empty. There used to be a fallback that concatenated
-- every overlapping span's WHOLE transcript -- which is how a marker holding
-- part of a span read as all of it, the original §1 bug of
-- SPEC-range-transcript.md. Empty is honest; a neighbour's words are not.
-- Returns: text, score, in_sequence -- all nil when nothing overlaps.
-- The words a range holds, by ANCHOR: `w.anchor or w.t0` inside [from, to).
--
-- The anchor is the word's DTW timestamp -- one point that sits ON the word
-- (SPEC-word-anchors.md). It exists because no rule over t0/t1 can be right:
-- with `-ml 1` whisper's segments are a contiguous PARTITION of the timeline,
-- so t0 is really where the previous word stopped and t1 is where the next
-- one starts, and a word after a long pause can sit past its own window's end
-- entirely. A midpoint rule shipped and failed on "guards." (word at the
-- window's start, 85.99-90.36 for a sub-second word); an onset rule shipped
-- and failed on "you" (word at the window's end, stamped 428.16-428.92 for a
-- word audible at 428.59). Opposite directions, same disease: the window is
-- displaced, not imprecise.
--
-- t0 is the fallback for a word with no anchor -- a model without a DTW
-- preset, or a token whisper never anchored -- and degrades to the old onset
-- behaviour, never worse. Anchors are sharp: membership is exact, with no
-- tolerance, because measured on 289 real cuts every widening of the range
-- only stole neighbours' words.
--
-- Half-open on purpose. A word anchored exactly at `to` belongs to the next
-- range, so two markers meeting at a boundary cannot both claim it.
--
-- Shared by the sheet's transcript and by the duplicate-marker planner, which
-- must judge on exactly the words the sheet shows -- two rules here would mean
-- a marker deleted on evidence the user was never shown.
function vo.WordsInRange(words, from, to)
  local out = {}
  if not (from and to and to > from) then return out end
  for _, w in ipairs(words or {}) do
    if w.t0 and w.text and w.text ~= "" then
      local at = w.anchor or w.t0
      if at >= from and at < to then out[#out + 1] = w end
    end
  end
  return out
end

function vo.TranscriptForRange(flat, path, from, to, words)
  if not (path and from and to and to > from) then return nil end
  local hits, best, best_overlap = {}, nil, 0
  for _, rec in ipairs(flat or {}) do
    local s = rec.span
    if rec.source_path == path and s and s.start and s.stop then
      local overlap = math.min(s.stop, to) - math.max(s.start, from)
      if overlap > 0 then
        hits[#hits + 1] = s
        if (s.kind == "match" or s.kind == "review") and overlap > best_overlap then
          best, best_overlap = s, overlap
        end
      end
    end
  end
  if #hits == 0 then return nil end

  -- Which words is vo.WordsInRange's rule -- the ANCHOR; see the reasoning
  -- there. A range the words say is empty reads as empty, not as its
  -- neighbours': the retired span fallback showed whole overlapping spans and
  -- was confidently wrong every time a marker held part of one.
  local text = {}
  for _, w in ipairs(vo.WordsInRange(words, from, to)) do text[#text + 1] = w.text end
  if #text == 0 then return nil end
  return table.concat(text, " "), best and best.score or nil,
         best and best.in_sequence or nil
end

-- Every take-marker boundary that contradicts the words (SPEC-anchor-
-- boundaries.md §4). Read-only: flags name the marker and the words so the
-- user -- or a re-snap verb -- acts on them; nothing here moves anything.
--
-- The Chain/Even failure this exists for: a marker edge cut at whisper's old
-- partition edge leaves the take's own last word ANCHORED on the far side.
-- The sheet already shows that word amber in the NEIGHBOUR'S row; this walks
-- every marker and reports both sides of the tear in one list -- the missing
-- word from the row that lost it, the extra from the row that gained it.
--
-- Alignment is vo.ExtraWords in both directions, so a reader stumble flags
-- only the doubled word, and substitutions apply the same way they do on the
-- sheet. One rule everywhere, or a flag accuses a marker on evidence the
-- sheet never showed.
--
-- markers: flat array of { id, asset, start, stop, source_path }.
-- lines:   script lines; the first whose asset matches names the text, the
--          same first-wins rule BuildOverview groups by.
-- words_by_source: path -> word list. subs: normalized token -> replacement.
-- Returns: array of { marker_id, asset, kind, words, start, stop,
--          source_path } in marker order; kind is one of "extra", "missing",
--          "empty", "no-line". A clean marker contributes nothing.
function vo.CheckMarkerWords(markers, lines, words_by_source, subs)
  local text_of = {}
  for _, l in ipairs(lines or {}) do
    if l.asset and text_of[l.asset] == nil then text_of[l.asset] = l.text end
  end

  local flags = {}
  local function flag(m, kind, words)
    flags[#flags + 1] = { marker_id = m.id, asset = m.asset, kind = kind,
                          words = words, start = m.start, stop = m.stop,
                          source_path = m.source_path }
  end

  local function extras_of(runs)
    local out = {}
    for _, run in ipairs(runs) do
      if run.extra then out[#out + 1] = run.text end
    end
    return table.concat(out, " ")
  end

  for _, m in ipairs(markers or {}) do
    local line_text = text_of[m.asset]
    local words = words_by_source and words_by_source[m.source_path]
    local got = {}
    for _, w in ipairs(vo.WordsInRange(words, m.start, m.stop)) do
      got[#got + 1] = w.text
    end
    local got_text = table.concat(got, " ")

    if not line_text then
      flag(m, "no-line", got_text)
    elseif #got == 0 then
      flag(m, "empty", "")
    else
      local extra = extras_of(vo.ExtraWords(line_text, got_text, subs))
      if extra ~= "" then flag(m, "extra", extra) end
      -- The mirror: the LINE read against the TAKE, so a line word the range
      -- does not hold surfaces as that side's "extra".
      local missing = extras_of(vo.ExtraWords(got_text, line_text, subs))
      if missing ~= "" then flag(m, "missing", missing) end
    end
  end
  return flags
end

-- The best-effort answer to "which line is this item?": the match span whose
-- own audio this item's window covers most. Fraction is of the SPAN, not the
-- item -- an item holding a whole take plus room reads 1.0, an item holding
-- half a take reads 0.5 -- so the caller can put a floor under a guess before
-- writing it anywhere. Only match/review spans are candidates: an orphan or
-- chatter span has no line to offer.
function vo.BestSpanForItem(coverage, spans)
  if not coverage then return nil, 0 end
  local best, best_frac = nil, 0
  for _, s in ipairs(spans or {}) do
    if (s.kind == "match" or s.kind == "review")
       and s.start and s.stop and s.stop > s.start then
      local overlap = math.min(s.stop, coverage.to) - math.max(s.start, coverage.from)
      if overlap > 0 then
        local frac = overlap / (s.stop - s.start)
        if frac > best_frac then best, best_frac = s, frac end
      end
    end
  end
  return best, best_frac
end

-- An item carries the take markers its own window covers, and nothing else.
--
-- This used to mirror the source's takes within `reach` seconds of each item's
-- window, so widening an item revealed its neighbours as labelled ranges. The
-- idea was sound and the cost was not: markers live in the item's state CHUNK,
-- which the tool re-reads whenever the project changes, so every mirrored copy
-- is paid for on every rescan forever. On a 451-clip session at the 30s default
-- that was ~10,000 marker lines to read and discard; REAPER's split, which
-- copies the whole set into both halves, had already pushed it to 184,459.
--
-- So: one take, one marker, in the clip that IS that take. Widening an item
-- shows bare waveform again -- the neighbours are still in the sheet, which is
-- where the session is read. A setting was removed rather than defaulted to 0,
-- because a knob whose other positions are all slower is not a choice.
--
-- `group` is CollectTakeMarkers' per-path shape ({ coverage, markers, info }).
-- Returns rewrites { { item_index, markers } } -- only the items whose tool
-- markers differ from what they should hold -- and the canonical marker count.
-- User markers are untouched (vo.WriteTakeMarkers preserves them).
function vo.PlanMarkerMirror(group)
  local reach = 0
  local canonical = vo.CountingMarkers(group)
  local rewrites = {}
  for idx, rec in ipairs(group or {}) do
    local cov = rec.coverage
    if cov then
      local want = {}
      for _, c in ipairs(canonical) do
        if c.stop > cov.from - reach and c.start < cov.to + reach then
          want[#want + 1] = { start = c.start, stop = c.stop,
                              asset = c.asset, id = c.id }
        end
      end

      local have, have_n = {}, 0
      for _, m in ipairs(rec.markers or {}) do
        local asset, id = vo.ParseMarkerName(m.name)
        if id then
          have_n = have_n + 1
          -- A duplicated id inside one item is split residue by definition;
          -- counting it above forces the rewrite that collapses it.
          have[id] = { start = m.pos, stop = m.pos + (m.length or 0),
                       asset = asset }
        end
      end

      local same = have_n == #want
      if same then
        for _, w in ipairs(want) do
          local h = have[w.id]
          if not h or math.abs(h.start - w.start) > 1e-6
             or math.abs(h.stop - w.stop) > 1e-6 or h.asset ~= w.asset then
            same = false
            break
          end
        end
      end
      if not same then
        rewrites[#rewrites + 1] = { item_index = idx, markers = want }
      end
    end
  end
  return rewrites, #canonical
end

-- The same idea as vo.PlanMarkerMirror, minus the mirroring: an item keeps the
-- markers it OWNS and loses the rest. It can never gain one.
--
-- The difference matters, and cost a real session to learn. PlanMarkerMirror
-- gives an item every canonical marker that INTERSECTS its window, which is
-- not the same as every marker that belongs to it. A take marker written from
-- the transcript before the clip was trimmed can start inside one item and run
-- well into the next -- and the mirror pass then hands a copy to BOTH. The
-- clip that had one marker now has two, so every verb needing "the one marker
-- in this item" -- Trim, Snap -- refuses it as a recording. Pressing tidy made
-- the session less tidy.
--
-- Ownership is vo.CountingMarkers' answer, which is already the rule the rest
-- of the tool reads by: per marker id, the single item covering most of its
-- range. Everything else on an item is a leftover, whether REAPER's split
-- copied it there or an earlier mirror pass did.
--
-- Same shape as PlanMarkerMirror: `group` is CollectTakeMarkers' per-path
-- form, and it returns rewrites { { item_index, markers } } for the items that
-- differ, plus the canonical marker count. User markers are untouched.
function vo.PlanMarkerPrune(group)
  local canonical = vo.CountingMarkers(group)
  local owner = {}
  for _, c in ipairs(canonical) do owner[c.id] = c end

  local rewrites = {}
  for idx, rec in ipairs(group or {}) do
    local want, have_n, seen = {}, 0, {}
    for _, m in ipairs(rec.markers or {}) do
      local _, id = vo.ParseMarkerName(m.name)
      if id then
        have_n = have_n + 1
        local c = owner[id]
        -- `seen` collapses an id duplicated INSIDE one item, which is split
        -- residue by definition; have_n still counts both, so the mismatch
        -- below forces the rewrite that drops the copy.
        if c and c.item_index == idx and not seen[id] then
          seen[id] = true
          want[#want + 1] = { start = c.start, stop = c.stop,
                              asset = c.asset, id = c.id }
        end
      end
    end
    if have_n ~= #want then
      rewrites[#rewrites + 1] = { item_index = idx, markers = want }
    end
  end
  return rewrites, #canonical
end

-- Add ONE marker to an item without losing the ones already there.
--
-- vo.WriteTakeMarkers replaces the tool's whole set, so every caller adding a
-- single marker has to hand it the existing ones too. Forgetting that does not
-- fail loudly: it silently wipes every other take in the item, which on an
-- uncut recording is the entire session's identification.
--
-- `existing` is vo.ParseTKMChunk's shape ({ pos, name, length }); user markers
-- (no ` ~id` suffix) are dropped from the result because WriteTakeMarkers
-- preserves those itself, and returning them here would write them twice.
--
-- Returns the list to write, plus whether the marker was actually added. It is
-- NOT added when this line is already marked over the same audio -- an overlap
-- covering more than half the new range, the same rule vo.UnidentifiedSpans
-- uses for "this span is claimed". Marking the same take twice is a duplicate
-- row and a duplicate cut, and pressing a button twice must not cause either.
function vo.PlanMarkerAdd(existing, add)
  local list = {}
  local claimed = false
  local span = (add.stop or add.start) - add.start
  for _, m in ipairs(existing or {}) do
    local asset, id = vo.ParseMarkerName(m.name)
    if id then
      local start, stop = m.pos, m.pos + (m.length or 0)
      list[#list + 1] = { start = start, stop = stop, asset = asset, id = id }
      if asset == add.asset and span > 0 then
        local over = math.min(stop, add.stop) - math.max(start, add.start)
        if over > span / 2 then claimed = true end
      end
    end
  end
  if claimed then return list, false end
  list[#list + 1] = { start = add.start, stop = add.stop,
                      asset = add.asset, id = add.id }
  return list, true
end

-- Hand ONE marker to a different line, leaving every sibling alone.
--
-- This is how a take moves between lines: the marker names the LINE, so
-- rewriting its asset IS the move. The id and the span are deliberately kept --
-- the id because the stored marks are keyed `tkm|<id>` and a fresh one would
-- strand every note and tick on the take being moved, the span because where
-- the performance sits in the source is a fact about the recording and has
-- nothing to do with which line it was filed under.
--
-- Same `existing` shape and same user-marker handling as vo.PlanMarkerAdd.
-- Returns the list to write, plus whether anything changed -- false when no
-- marker carries that id, or when it already names that asset.
function vo.PlanMarkerRetarget(existing, marker_id, new_asset)
  local list, changed = {}, false
  for _, m in ipairs(existing or {}) do
    local asset, id = vo.ParseMarkerName(m.name)
    if id then
      if id == marker_id and asset ~= new_asset then
        asset = new_asset
        changed = true
      end
      list[#list + 1] = { start = m.pos, stop = m.pos + (m.length or 0),
                          asset = asset, id = id }
    end
  end
  return list, changed
end

-- Take one marker out, leaving every sibling alone.
--
-- Un-assigning a take: with no marker naming it, the audio goes back to being
-- an unmatched span, which is what the orphan list is built from. The audio
-- itself is never touched.
function vo.PlanMarkerRemove(existing, marker_id)
  local list, changed = {}, false
  for _, m in ipairs(existing or {}) do
    local asset, id = vo.ParseMarkerName(m.name)
    if id then
      if id == marker_id then
        changed = true
      else
        list[#list + 1] = { start = m.pos, stop = m.pos + (m.length or 0),
                            asset = asset, id = id }
      end
    end
  end
  return list, changed
end

-- Markers that are arguing over the SAME stretch of audio, grouped.
--
-- The unit of work is the range, never the item. An uncut recording
-- legitimately holds one counting marker per take, so a rule of the form
-- "several markers on one item, keep the best" would destroy such a session on
-- its first press. Two markers belong together only when they overlap by
-- `fraction` of the SHORTER of the two -- fighting over the same audio, not
-- merely adjacent.
--
-- Grouping is transitive within a source (A-B and B-C puts all three in one
-- cluster: it is one argument about one stretch), and markers on different
-- sources never cluster, whatever their timestamps say.
--
-- Returns an array of arrays. A cluster of one is every normal take, and is
-- returned as such rather than dropped, so callers can count what they saw.
function vo.ClusterMarkerRanges(markers, fraction)
  fraction = fraction or vo.marker_same_take
  local list = {}
  for _, m in ipairs(markers or {}) do
    if m.start and m.stop and m.stop > m.start then list[#list + 1] = m end
  end

  -- Union-find over the pairs that overlap enough, which is what makes the
  -- grouping transitive without an ordering assumption.
  local parent = {}
  for i = 1, #list do parent[i] = i end
  local function root(i)
    while parent[i] ~= i do parent[i] = parent[parent[i]]; i = parent[i] end
    return i
  end

  for i = 1, #list do
    for j = i + 1, #list do
      local a, b = list[i], list[j]
      if a.source_path == b.source_path then
        local overlap = math.min(a.stop, b.stop) - math.max(a.start, b.start)
        local shorter = math.min(a.stop - a.start, b.stop - b.start)
        if shorter > 0 and overlap / shorter >= fraction - 1e-9 then
          local ra, rb = root(i), root(j)
          if ra ~= rb then parent[rb] = ra end
        end
      end
    end
  end

  local by_root, order = {}, {}
  for i = 1, #list do
    local rt = root(i)
    if not by_root[rt] then by_root[rt] = {}; order[#order + 1] = rt end
    table.insert(by_root[rt], list[i])
  end
  local out = {}
  for _, rt in ipairs(order) do out[#out + 1] = by_root[rt] end
  return out
end

-- Which of several markers competing for one stretch of audio is the real one.
--
-- The words decide. Each marker's own script line is scored against the words
-- inside that marker's own range -- the same normalise/tokenise/Levenshtein
-- measure vo.FindSpanLines uses -- and the best keeps its marker while the
-- rest are planned for deletion.
--
-- It refuses far more readily than it acts, and every refusal is per cluster
-- rather than per press: a session with four clear duplicates and one
-- ambiguous cluster cleans the four and reports the fifth. A verb that
-- silently deleted the wrong take marker on a bad transcript is one nobody
-- would press twice.
--
-- input: { markers, lines, words = { [source_path] = word list }, cfg, opts }
-- opts:  { fraction = 0.80, floor = 0.50, gap = 0.20 }
-- Returns { deletes, kept, skipped } -- see VO/SPEC-duplicate-markers.md.
function vo.PlanDuplicateMarkers(input)
  input = input or {}
  local opts     = input.opts or {}
  local fraction = opts.fraction or 0.80
  local floor_   = opts.floor    or 0.50
  local gap      = opts.gap      or 0.20
  local cfg      = input.cfg
  local words    = input.words or {}

  -- First line wins an asset, matching every other lookup in this file.
  local text_for = {}
  for _, l in ipairs(input.lines or {}) do
    if l.asset and text_for[l.asset] == nil then text_for[l.asset] = l.text or "" end
  end

  local plan = { deletes = {}, kept = {}, skipped = {} }

  for _, cluster in ipairs(vo.ClusterMarkerRanges(input.markers, fraction)) do
    if #cluster > 1 then
      local scored, any_words = {}, false
      for _, m in ipairs(cluster) do
        local heard = vo.WordsInRange(words[m.source_path], m.start, m.stop)
        local text = {}
        for _, w in ipairs(heard) do text[#text + 1] = w.text end
        local window = vo.Tokenize(vo.Normalize(table.concat(text, " "), cfg and cfg.substitutions))
        if #window > 0 then any_words = true end
        -- An asset naming no script line scores 0: it cannot win, and it loses
        -- to any real match. Two of them together therefore fail the floor and
        -- are reported rather than guessed between.
        local toks = vo.Tokenize(vo.Normalize(text_for[m.asset] or "", cfg and cfg.substitutions))
        local score = 0
        if #toks > 0 and #window > 0 then
          score = 1 - vo.Levenshtein(toks, window) / math.max(#toks, #window)
        end
        scored[#scored + 1] = { marker = m, score = score }
      end

      table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return tostring(a.marker.id) < tostring(b.marker.id)
      end)

      local why
      if not any_words then
        why = "no words"
      elseif scored[1].score < floor_ then
        why = "no clear match"
      elseif scored[1].score - scored[2].score < gap then
        why = "too close to call"
      end

      if why then
        local named = {}
        for _, s in ipairs(scored) do
          named[#named + 1] = { id = s.marker.id, asset = s.marker.asset,
                                score = s.score }
        end
        plan.skipped[#plan.skipped + 1] = { why = why, markers = named }
      else
        local win = scored[1]
        plan.kept[#plan.kept + 1] = {
          id = win.marker.id, asset = win.marker.asset, score = win.score,
          source_path = win.marker.source_path, item_index = win.marker.item_index,
        }
        for k = 2, #scored do
          local s = scored[k]
          plan.deletes[#plan.deletes + 1] = {
            id = s.marker.id, asset = s.marker.asset, score = s.score,
            source_path = s.marker.source_path, item_index = s.marker.item_index,
            lost_to = win.marker.asset, lost_to_score = win.score,
          }
        end
      end
    end
  end

  return plan
end

-- What the sheet and the timeline disagree about, and what is simply broken.
--
-- Pure: it reads rows that already carry their resolved item's GUID and track
-- name (the coupled layer puts those there), so the whole reconciliation is
-- testable without REAPER.
--
-- Returns four independent lists rather than one flat one, because each has a
-- different fix and the panel shows only the non-empty ones:
--
--   disagree       -- the sheet says one thing, the item's track says another
--   unbacked_markers -- a marker row with no item under it: the marker line
--                       survives in some chunk, but nothing in the project
--                       plays that audio any more
--   orphan_marks     -- marks on a row with no audio left to attach to:
--                       usually a deleted marker, or damage from before
--                       markers existed
function vo.PlanReconcile(rows, cfg)
  local plan = { disagree = {}, unbacked_markers = {}, orphan_marks = {} }

  for _, row in ipairs(rows or {}) do
    if row.marker_id and not row.item_guid and not row.item then
      plan.unbacked_markers[#plan.unbacked_markers + 1] =
        { row = row, detail = "marker with no audio under it" }
    end

    -- Only rows that HAVE an item can disagree with where it sits.
    if row.item_guid then
      local from_track = vo.MarkFromTrack(row.track_name, cfg)
      local wants_sel  = (from_track == "select")
      local wants_keep = (from_track == "keep")
      if (row.user_select == true) ~= wants_sel then
        plan.disagree[#plan.disagree + 1] = { row = row, detail = wants_sel
          and "on the Selects track but not ticked Sel"
          or  "ticked Sel but the item is not on the Selects track" }
      elseif (row.user_keep == true) ~= wants_keep then
        plan.disagree[#plan.disagree + 1] = { row = row, detail = wants_keep
          and "on the Alts track but not ticked Keep"
          or  "ticked Keep but the item is not on the Alts track" }
      end
    elseif not row.marker_id
           and (row.mark_select ~= nil or row.mark_keep ~= nil
                or (row.notes and row.notes ~= "") or row.user_status) then
      -- Marks with nothing to attach to. An UNMARKED row with no item is just
      -- a line nobody has recorded yet, which is not a finding -- and a
      -- marker row with no item is the unbacked_markers case above, not this.
      plan.orphan_marks[#plan.orphan_marks + 1] =
        { row = row, detail = "marks with no item" }
    end
  end

  return plan
end

--------------------------------
-- Pure layer: transcript gap repair
--------------------------------

-- Confirmed failure mode (ChristianBrently_Grumbar, 2026-08-08): a slate
-- ("Actor reading Character.") followed by a pause at the head of a recording
-- makes whisper emit a gap token that swallows the rest of its first 30s
-- window -- speech from ~1.4s to the window boundary is never decoded, though
-- levels are normal, and nothing in the run reports it. Re-running whisper on
-- the same audio STARTING AFTER the slate recovers every word, so the repair
-- is: find a transcript hole that the audio says holds speech, re-run whisper
-- on just that span (-ot/-d), and merge the recovered words back in.
--
-- The functions here are the pure half: gap finding, repair planning against
-- an injected probe, and the merge. vo.RepairTranscriptGaps in the coupled
-- layer chains the actual whisper runs.

-- Stretches of the transcript with no decoded words: between consecutive
-- words, before the first word, and -- when the audio's duration is known --
-- after the last. Only stretches at least `gap_repair_min_gap` long count:
-- an ordinary between-takes pause is not a suspect, and the energy check in
-- vo.PlanGapRepairs is what separates a long think from a swallowed read.
-- Returns: array of { from, to } in source seconds.
function vo.TranscriptGapSpans(words, duration, cfg)
  local min_gap = vo.Opt(cfg, "gap_repair_min_gap")
  local edges = {}
  local at = 0.0
  for _, w in ipairs(words or {}) do
    edges[#edges + 1] = { from = at, to = w.t0 or at }
    at = math.max(at, w.t1 or at)
  end
  if duration and duration > at then
    edges[#edges + 1] = { from = at, to = duration }
  end

  local gaps = {}
  for _, g in ipairs(edges) do
    if (g.to - g.from) >= min_gap then gaps[#gaps + 1] = g end
  end
  return gaps
end

-- Which gaps actually hold speech, and the span to hand back to whisper.
--
-- The audio is the only evidence available: the transcript cannot tell a
-- swallowed read from a long silence, because both look like the same hole.
-- vo.FindSpeechBounds answers with the first and last moment above the floor;
-- a gap whose speech runs at least `gap_repair_min_speech` is a suspect, and
-- the repair span is that speech padded by `gap_repair_pad` -- clamped to the
-- gap, so the re-run can never start on the already-decoded word before it
-- (for the confirmed case, that word IS the slate that caused the swallow).
--
-- No floor or no probe means no repairs, not repairs everywhere: with nothing
-- to measure against, every silence would read as speech and every long pause
-- would cost a whisper run.
-- Returns: array of { from, to } repair spans in source seconds.
function vo.PlanGapRepairs(words, duration, floor_db, probe, cfg)
  if not probe or not floor_db then return {} end
  local min_speech = vo.Opt(cfg, "gap_repair_min_speech")
  local pad        = vo.Opt(cfg, "gap_repair_pad")

  local plans = {}
  for _, gap in ipairs(vo.TranscriptGapSpans(words, duration, cfg)) do
    local first, last = vo.FindSpeechBounds(gap.from, gap.to, floor_db, probe, cfg)
    if first and last and (last - first) >= min_speech then
      plans[#plans + 1] = {
        from = math.max(gap.from, first - pad),
        to   = math.min(gap.to,   last + pad),
      }
    end
  end
  return plans
end

-- Fold repair-run words back into the transcript.
--
-- `repairs` is an array of { span = { from, to }, words = { ... } }, one per
-- repair run, with words in SOURCE seconds -- whisper's -ot offset is included
-- in its output timestamps, so no shifting happens here. A repair word whose
-- midpoint falls outside its own span is dropped: it is wrong by construction
-- (a whisper build whose offset output turned out slice-relative, or decode
-- bleed past the requested duration) and merging it would corrupt the very
-- transcript the repair is trying to save. Original words are never removed.
-- Returns: merged word array sorted by t0, and how many words were added.
function vo.MergeRepairWords(words, repairs)
  local merged = {}
  for _, w in ipairs(words or {}) do merged[#merged + 1] = w end

  local added = 0
  for _, rep in ipairs(repairs or {}) do
    local span = rep.span or {}
    -- replace=true: the span already holds words and the fresh ones supersede
    -- them (Verify's stale-merge). Without it the stored in-span words stay
    -- and the fresh ones are appended alongside -- duplicates. Gap repair
    -- keeps the append semantics: its spans are gaps, there is nothing there.
    if rep.replace then
      local kept = {}
      for _, w in ipairs(merged) do
        local mid = ((w.t0 or 0) + (w.t1 or 0)) / 2
        if mid < (span.from or 0) - 1e-6 or mid > (span.to or 0) + 1e-6 then
          kept[#kept + 1] = w
        end
      end
      merged = kept
    end
    for _, w in ipairs(rep.words or {}) do
      local mid = ((w.t0 or 0) + (w.t1 or 0)) / 2
      if mid >= (span.from or 0) - 1e-6 and mid <= (span.to or 0) + 1e-6 then
        merged[#merged + 1] = w
        added = added + 1
      end
    end
  end

  table.sort(merged, function(a, b) return (a.t0 or 0) < (b.t0 or 0) end)
  return merged, added
end

--------------------------------
-- Pure layer: configuration
--------------------------------

vo.DEFAULTS = {
  accept_threshold = 0.80,  -- score at or above this is a confident match
  review_floor     = 0.55,  -- below this the words are left unconsumed
  margin_threshold = 0.05,  -- lead over the runner-up line needed to be confident
  anchor_count     = 3,     -- rarest tokens per line used to propose candidates
  window_slack     = 0.30,  -- window lengths tried around the script line length

  -- Which take "Select takes" marks when a line was read more than once.
  auto_select_take = "last",  -- "last" | "first"

  -- Tick a mark and the item MOVES to the track that mark means, without
  -- waiting for a Pull. Off by default: everything else a tick does is
  -- reversible bookkeeping, and this one rearranges audio.
  auto_sort_marks = false,

  -- Sequence. A session is read roughly in script order, and that is the only
  -- evidence there is for placing a line too short to identify itself.
  order_weight         = 0.15,  -- score moved by reading in, or out of, order
  backbone_min_tokens  = 4,     -- shortest line trusted to establish the order

  -- Ceilings on the room below, and the FIXED pad when snapping is off.
  pre_pad          = 0.300, -- seconds of head room before the first aligned word
  post_pad         = 0.600, -- seconds of tail after the last aligned word

  -- Boundary snapping. With it on, pre_pad/post_pad above become the MAXIMUM
  -- reach of the search rather than a fixed amount; the search itself is also
  -- bounded by the neighbouring word's timestamp, which is what makes it
  -- structurally impossible for a clip to contain a syllable of the next line.
  snap_boundaries   = true,
  snap_min_silence  = 0.060, -- seconds below the floor needed to place a boundary
  -- How far either side of a CHAINED word boundary to look for the dip that
  -- really divides two words. Whisper marks the join a hair late, so cutting on
  -- the mark can split an onset between both clips; the quietest window inside
  -- this reach belongs to neither. See vo.QuietestBoundary.
  --
  -- OFF by default (0 disables it), and deliberately so. The mechanism is real
  -- -- one take rendered "Look." where the source says "Book." -- but three
  -- attempts at placing that boundary each fixed one side of the join and cost
  -- the other, and the only instrument available to judge them (whispering
  -- half-second clips) is too noisy to settle it: the same fragment came back
  -- "Book.", "Boo." and "6." across runs. Turning this on changes every cut in
  -- every session, so it waits for a verification method that can tell a
  -- clipped syllable from a recogniser having a bad day.
  chained_boundary_reach = 0,
  -- The gate, in the same terms REAPER's Dynamic Split uses: one dBFS number,
  -- above which is speech and below which is silence.
  --
  -- Two ways to arrive at it. AUTO measures the room in this recording's own
  -- pauses and puts the gate `snap_floor_offset` dB above it -- right by
  -- default on any recording, since a fixed -60 is too low for a noisy room and
  -- too high for a clean one. Turning Auto off types the number in directly,
  -- which is what you want when you can see the waveform and know where the
  -- room tone sits.
  snap_gate_auto    = true,
  snap_gate_db      = -60.0, -- dBFS gate used when Auto is off
  snap_floor_offset = 6.0,   -- dB above the measured noise floor
  snap_floor_window = 0.500, -- seconds of the quietest gap used to measure it
  -- Which gap sets the floor, as a fraction of the gaps sorted quietest-first.
  -- Not the minimum: one near-silent patch left by noise reduction would put
  -- the floor below the file's own room tone, and every silence test then fails.
  snap_floor_percentile = 0.25,

  -- With snapping on, edges sit at a FIXED distance from the measured speech
  -- bounds -- every clip gets the same head and tail room, clamped by the
  -- neighbouring word and by pre/post_pad. Placing the edge wherever the
  -- probe first crossed the floor gave 0ms on clean silence and the full pad
  -- on uneven room tone: 0-1760ms of head room across one session.
  -- Generous on purpose. Whisper does not transcribe a mumbled word, a trailing
  -- inarticulate sound or a breath welded to the end of a read, so the measured
  -- speech bounds land INSIDE the real take and a minimal room cuts the take's
  -- own ending off. The two errors are not symmetric: a long clip is trimmed
  -- with the waveform in front of you, while a clip missing its ending gives no
  -- sign of what was lost or how much, so fixing it means going back to the
  -- source. Err long. The neighbouring-word fence in vo.ApplyPadding is what
  -- makes that safe -- no amount of room can reach another line's audio -- so
  -- being generous costs room tone, and Auto-adjust is the deliberate second
  -- pass that takes it back.
  --
  -- The tail gets more than the head because that is where the untranscribed
  -- sound lives: reads trail off, they do not trail on.
  snap_head_room = 0.120, -- seconds of room before the measured speech onset
  snap_tail_room = 0.400, -- seconds of room after the measured speech end

  -- The unheard-audio scan: sound the transcript never heard. A burst has to
  -- be at least a read's worth of sound to count -- shorter is a click, a
  -- chair, a breath -- and a dip shorter than the join is the inside of a
  -- read (a stop consonant, a caught breath), not a boundary between two.
  unheard_min_length = 0.30, -- seconds of sound before a burst counts as a read
  unheard_join       = 0.25, -- dips shorter than this stay one burst

  -- Every cut clip gets a short protective fade: shorter in, longer out,
  -- both well inside the head/tail room so they live in silence.
  cut_fade_in  = 0.010, -- seconds
  cut_fade_out = 0.050, -- seconds

  -- A leftover on the recording track shorter than this is deleted at Pull
  -- regardless of content: a breath, a click or a single syllable under two
  -- seconds is not audio anyone returns for. Measured on a real session,
  -- every keepable leftover (chatter, false starts) ran 2s or longer.
  pull_min_leftover = 2.0, -- seconds

  -- Tighten (the finishing pass): edges sitting further from the audio
  -- than room + slack are pulled in to the standard snap room. The slack
  -- keeps it from fussing over near-misses; hand-trimmed items (their
  -- fades differ from cut_fade_in/out) are never touched.
  trim_head_slack = 0.250, -- seconds beyond snap_head_room tolerated
  trim_tail_slack = 0.400, -- seconds beyond snap_tail_room tolerated

  -- A voiced leftover ending within this of a take's first sample likely
  -- holds that take's clipped opening (a spoken lead-in the matcher could
  -- not align). Pull warns about the pair instead of guessing.
  clipped_head_gap = 0.300, -- seconds

  -- Per-session toggles (see SPEC.md §4). Defaults cut and name every take
  -- identically, leaving the user to audition and delete.
  use_alts_track   = false,
  suffix_alt_names = false,

  -- Transcript gap repair (see "Pure layer: transcript gap repair").
  -- min_gap is well above any between-lines pause worth ignoring and well
  -- below the ~28s hole the confirmed failure leaves; min_speech screens out
  -- a chair creak or a cough without screening out a single swallowed word;
  -- pad gives whisper a running start without reaching back to the word --
  -- the slate -- that caused the swallow (the clamp in PlanGapRepairs is what
  -- guarantees that).
  gap_repair_min_gap    = 5.0,  -- seconds of transcript hole before suspicion
  gap_repair_min_speech = 0.75, -- seconds of above-floor audio to confirm it
  gap_repair_pad        = 0.35, -- seconds of margin around the found speech


  -- The floor under "which line is this item?" for Mark selected item(s):
  -- the best match span must have at least this fraction of itself inside
  -- the item before the guess is written anywhere.
  mark_item_min_span = 0.35,

  review_prefix           = "REVIEW_",
  unmatched_prefix        = "UNMATCHED_",
  unmatched_snippet_words = 4,
  max_name_length         = 96,
}

-- The destination of a span that is NOT pulled off the source track (SPEC.md
-- §4). It deliberately has no entry in ApplyPlan's dest_names: ApplyPlan skips
-- these spans outright, so the audio is never split, moved or renamed. It still
-- appears in the report, which is where unmatched audio gets flagged now.
vo.DEST_IN_PLACE = "source"

-- Read a config value, falling back to the documented default.
function vo.Opt(cfg, key)
  local v = cfg and cfg[key]
  if v == nil then return vo.DEFAULTS[key] end
  return v
end

--------------------------------
-- Pure layer: matching
--------------------------------

-- Token-level Levenshtein distance between two token arrays.
-- Three-row DP: O(#a * #b) time, O(#b) space.
--
-- Beyond insert/delete/substitute there are two free moves: two tokens on one
-- side may FUSE into one token on the other, and one may SPLIT into two, at no
-- cost, whenever the concatenation matches exactly. Where a word break falls is
-- a spelling decision, not a difference in what was said -- the script writes
-- "Some day it will be you" and the recognizer hears "Someday, it'll be you",
-- and those are the same line read the same way. Plain edit distance charged
-- that line two errors out of six and left it at 67%, low enough that window
-- trimming then dropped "Someday" off the front of the take. It also covers the
-- recognizer's habit of fusing a pair ("book man" -> "bookman").
--
-- Free, rather than cheap, because the equality test is exact: the operation
-- can only fire on a genuine tokenization difference, never on a different word.
function vo.Levenshtein(a, b)
  local n, m = #a, #b
  if n == 0 then return m end
  if m == 0 then return n end

  -- prev2 = row i-2, prev = row i-1, cur = row i.
  local prev2, prev, cur = {}, {}, {}
  for j = 0, m do prev[j] = j end

  for i = 1, n do
    cur[0] = i
    local ai = a[i]
    for j = 1, m do
      local best = prev[j - 1] + ((ai == b[j]) and 0 or 1)
      local del = prev[j] + 1
      local ins = cur[j - 1] + 1
      if del < best then best = del end
      if ins < best then best = ins end
      -- a[i-1]a[i] fused into b[j]
      if i >= 2 and a[i - 1] .. ai == b[j] and prev2[j - 1] < best then
        best = prev2[j - 1]
      end
      -- a[i] split into b[j-1]b[j]
      if j >= 2 and ai == b[j - 1] .. b[j] and prev[j - 2] < best then
        best = prev[j - 2]
      end
      cur[j] = best
    end
    prev2, prev, cur = prev, cur, prev2
  end

  return prev[m]
end

-- Normalize a whisper word list into a flat token stream.
-- A single word may normalize to several tokens ("42" -> "forty two"); each
-- carries the source word's timing so token indices stay mappable to time.
-- Returns: array of { text, t0, t1, word = source word index }
function vo.BuildWordTokens(words, cfg)
  local subs = cfg and cfg.substitutionstitutions
  local out = {}
  for i, w in ipairs(words or {}) do
    for token in vo.Normalize(w.text, subs):gmatch("%S+") do
      out[#out + 1] = { text = token, t0 = w.t0, t1 = w.t1, word = i }
    end
  end
  return out
end

-- Build an IDF-weighted inverted index over the script lines.
-- Only each line's rarest tokens (its "anchors") get postings — those are the
-- positions worth proposing a candidate window at.
-- Returns: { n, tokens = {[line] = {token…}}, idf, postings, anchors }
function vo.BuildIndex(lines, cfg)
  local anchor_count = vo.Opt(cfg, "anchor_count")
  local subs = cfg and cfg.substitutionstitutions
  local n = #lines

  local index = { n = n, tokens = {}, idf = {}, postings = {}, anchors = {} }

  local df = {}
  for i, line in ipairs(lines) do
    local tokens = vo.Tokenize(vo.Normalize(line.text, subs))
    index.tokens[i] = tokens
    local seen = {}
    for _, t in ipairs(tokens) do
      if not seen[t] then
        seen[t] = true
        df[t] = (df[t] or 0) + 1
      end
    end
  end

  for token, count in pairs(df) do
    index.idf[token] = math.log(1 + n / count)
  end

  for i, tokens in ipairs(index.tokens) do
    local first, distinct = {}, {}
    for pos, t in ipairs(tokens) do
      if first[t] == nil then
        first[t] = pos
        distinct[#distinct + 1] = t
      end
    end

    -- Rarest first; ties broken by position so the ordering is deterministic.
    table.sort(distinct, function(x, y)
      if index.idf[x] ~= index.idf[y] then return index.idf[x] > index.idf[y] end
      return first[x] < first[y]
    end)

    local anchors = {}
    for k = 1, math.min(anchor_count, #distinct) do
      local token = distinct[k]
      anchors[#anchors + 1] = { token = token, pos = first[token] }
      local postings = index.postings[token]
      if not postings then
        postings = {}
        index.postings[token] = postings
      end
      postings[#postings + 1] = { line = i, pos = first[token] }
    end
    index.anchors[i] = anchors
  end

  return index
end

-- Classify a scored candidate.
-- "match" needs both a high score and a clear lead over the runner-up line:
-- a perfect score against two near-identical script lines is not confidence.
-- Returns: "match", "review", or nil (reject).
function vo.Classify(score, margin, cfg)
  if score >= vo.Opt(cfg, "accept_threshold")
     and margin >= vo.Opt(cfg, "margin_threshold") then
    return "match"
  end
  if score >= vo.Opt(cfg, "review_floor") then return "review" end
  return nil
end

-- Propose and score candidate spans over the word stream.
-- Every occurrence of a line's anchor token proposes a window starting at
-- `hit_position - token_offset_within_line`; windows of ±window_slack around the
-- line length are scored and the best kept.
-- Returns: array of { i0, i1, start, stop, score, margin, line_idx, asset, character }
function vo.FindCandidates(word_tokens, lines, index, cfg)
  local slack  = vo.Opt(cfg, "window_slack")
  local floor_ = vo.Opt(cfg, "review_floor")
  local deltas = { -slack, -slack / 2, 0, slack / 2, slack }

  local stream, stream_len = {}, #word_tokens
  for i, t in ipairs(word_tokens) do stream[i] = t.text end

  local candidates, seen = {}, {}

  for p = 1, stream_len do
    local postings = index.postings[stream[p]]
    if postings then
      for _, posting in ipairs(postings) do
        local line_idx  = posting.line
        local line_toks = index.tokens[line_idx]
        local line_len  = #line_toks
        local start     = p - posting.pos + 1
        local key       = line_idx .. ":" .. start

        if start >= 1 and line_len > 0 and not seen[key] then
          seen[key] = true

          local function score_window(a, b)
            local window = {}
            for k = a, b do window[#window + 1] = stream[k] end
            return 1 - vo.Levenshtein(line_toks, window) / math.max(line_len, #window)
          end

          local best_score, best_stop
          for _, delta in ipairs(deltas) do
            local width = math.floor(line_len * (1 + delta) + 0.5)
            if width < 1 then width = 1 end
            local stop = math.min(start + width - 1, stream_len)
            if stop >= start then
              local score = score_window(start, stop)
              if not best_score or score > best_score then
                best_score, best_stop = score, stop
              end
            end
          end

          if best_score and best_score >= floor_ then
            -- Shrink to the tightest window that scores at least as well. The
            -- start is derived from the anchor's offset within the line, so a
            -- word the recognizer dropped or fused *before* the anchor pushes
            -- it a token early — onto the tail of the previous line. That
            -- phantom token overlaps the previous span and would cost this line
            -- its match during selection. A shorter window scoring the same is
            -- strictly better: it excludes audio that isn't part of the line.
            --
            -- The bar RISES as the window improves. Comparing against the
            -- original score alone let shrinking walk straight through the best
            -- window and out the far side, back down to a merely equal one --
            -- which is how "Old book man say if you guard door, read what door
            -- guards" lost its "old book man" and half its score, the
            -- recognizer having fused "book man" into one word.
            local i0, i1 = start, best_stop
            local bar = best_score
            while i1 > i0 do
              local s = score_window(i0 + 1, i1)
              if s < bar then break end
              i0, bar = i0 + 1, math.max(bar, s)
            end
            while i1 > i0 do
              local s = score_window(i0, i1 - 1)
              if s < bar then break end
              i1, bar = i1 - 1, math.max(bar, s)
            end
            -- The window that is actually kept is the one that gets scored.
            best_score = score_window(i0, i1)

            candidates[#candidates + 1] = {
              i0       = i0,
              i1       = i1,
              start    = word_tokens[i0].t0,
              stop     = word_tokens[i1].t1,
              score    = best_score,
              line_idx  = line_idx,
              asset     = lines[line_idx].asset,
              deliver   = lines[line_idx].deliver,
              character = lines[line_idx].speaker,
            }
          end
        end
      end
    end
  end

  -- Margin is the lead over the best *other* line proposing the same start.
  -- No competitor at all means no ambiguity to resolve.
  local groups = {}
  for _, c in ipairs(candidates) do
    local g = groups[c.i0]
    if not g then
      g = {}
      groups[c.i0] = g
    end
    g[#g + 1] = c
  end
  for _, group in pairs(groups) do
    for _, c in ipairs(group) do
      local runner_up
      for _, other in ipairs(group) do
        if other.line_idx ~= c.line_idx
           and (not runner_up or other.score > runner_up) then
          runner_up = other.score
        end
      end
      c.margin = runner_up and (c.score - runner_up) or 1.0
    end
  end

  table.sort(candidates, function(a, b)
    if a.i0 ~= b.i0 then return a.i0 < b.i0 end
    if a.score ~= b.score then return a.score > b.score end
    return a.line_idx < b.line_idx
  end)

  return candidates
end

-- How much of a candidate is agreement, measured in tokens rather than as a
-- fraction.
--
-- Score is a RATE, and greedy selection needs a QUANTITY. A four-token line
-- matched perfectly scores 1.0; a nine-token line with one word fused by the
-- recognizer scores 0.89. Ranked on score the short line goes first and takes
-- the words out of the middle of the long one -- but 1.0 of four tokens is four
-- tokens of agreement and 0.89 of nine is eight, and eight tokens landing in a
-- row is the thing that cannot be an accident. Length was only ever consulted to
-- break an exact tie, which almost never happens between windows of different
-- widths.
--
-- Uses `effective` where it exists, so a candidate that contradicts the read
-- carries its order penalty into the comparison instead of around it.
function vo.Agreement(c)
  if not (c and c.i0 and c.i1) then return 0 end
  return (c.effective or c.score or 0) * (c.i1 - c.i0 + 1)
end

-- The spine of the read: the matches that cannot be coincidences, in the order
-- they were spoken.
--
-- Scoring each line on its own is blind to sequence, and that is fatal for short
-- lines. A script line that is just "You." scores a perfect 1.0 against every
-- one of the hundreds of times the actor says "you" in the middle of some other
-- line -- and, being perfect, it wins the greedy selection and blocks the line
-- that word really belonged to. Nothing in the line itself can resolve that.
-- Where it sits in the read can: a session is performed roughly in script order,
-- so the "You." that belongs to script line 42 is the one between the matches
-- for 41 and 43.
--
-- Only long, confident, unambiguous matches are trusted to define that order --
-- they are the ones no accident can produce. The result is then reduced to its
-- longest non-decreasing run of line indices, because a line genuinely read out
-- of sequence is a real thing but must not be allowed to define the sequence:
-- every line after it would be judged against it.
-- Returns: candidates in stream order, each also marked `.backbone = true`.
function vo.BuildBackbone(candidates, cfg)
  local min_tokens = vo.Opt(cfg, "backbone_min_tokens")
  local accept     = vo.Opt(cfg, "accept_threshold")
  local margin     = vo.Opt(cfg, "margin_threshold")

  local pool = {}
  for _, c in ipairs(candidates or {}) do
    if (c.i1 - c.i0 + 1) >= min_tokens
       and c.score >= accept and (c.margin or 1.0) >= margin then
      pool[#pool + 1] = c
    end
  end
  -- Ranked by tokens of agreement, not by score: the pool has already been gated
  -- on score and margin, so what is left to decide between two overlapping
  -- windows is which one is more evidence, and that is a count (vo.Agreement).
  table.sort(pool, function(a, b)
    local aa, ab = vo.Agreement(a), vo.Agreement(b)
    if aa ~= ab then return aa > ab end
    if a.score ~= b.score then return a.score > b.score end
    return a.i0 < b.i0
  end)

  local kept = {}
  for _, c in ipairs(pool) do
    local clash = false
    for _, s in ipairs(kept) do
      if c.i0 <= s.i1 and s.i0 <= c.i1 then clash = true break end
    end
    if not clash then kept[#kept + 1] = c end
  end
  table.sort(kept, function(a, b) return a.i0 < b.i0 end)

  -- Longest non-decreasing subsequence of line indices. Non-DEcreasing rather
  -- than increasing: a retake repeats a line index, and two takes of one line
  -- are in order, not out of it.
  local n = #kept
  local len, prev, best_i, best_len = {}, {}, nil, 0
  for i = 1, n do
    len[i] = 1
    for j = 1, i - 1 do
      if kept[j].line_idx <= kept[i].line_idx and len[j] + 1 > len[i] then
        len[i], prev[i] = len[j] + 1, j
      end
    end
    if len[i] > best_len then best_len, best_i = len[i], i end
  end

  local seq, k = {}, best_i
  while k do
    table.insert(seq, 1, kept[k])
    k = prev[k]
  end
  for _, c in ipairs(seq) do c.backbone = true end
  return seq
end

-- Whether a candidate sits where the read says it should.
-- true  the line index fits between the backbone matches either side of it
-- false it contradicts one of them
-- nil   there is no backbone evidence near it, so order says nothing
function vo.OrderConsistency(c, backbone)
  local before, after
  for _, b in ipairs(backbone or {}) do
    if b ~= c then
      if b.i1 < c.i0 then before = b
      elseif b.i0 > c.i1 and not after then after = b end
    end
  end
  if not (before or after) then return nil end
  -- Strict: equality is a retake of the same line, which is in order.
  if before and c.line_idx < before.line_idx then return false end
  if after  and c.line_idx > after.line_idx  then return false end
  return true
end

-- Greedy interval scheduling over scored candidates: the backbone first, then
-- best score, ties broken by the wider margin and then by length, skipping
-- anything overlapping an accepted span.
--
-- Order evidence is applied narrowly and in one direction only.
--
-- One direction: it can cost a candidate `order_weight` and its confidence, but
-- never add either. Sitting in the right place says nothing about whether the
-- words were right, and a weak text match promoted to confident by its position
-- is exactly the silent mis-name the review pass exists to prevent.
--
-- Narrowly: only against candidates too short to identify themselves. A line of
-- five distinct words matched perfectly is not made wrong by being read out of
-- order -- sessions are recorded out of order all the time, and pickups, ADR and
-- per-character passes must all still match. A line of one or two words is the
-- opposite case: it matches everywhere that word occurs, so its position in the
-- read is the ONLY thing that can say which occurrence is the right one.
--
-- Nothing is ever dropped for reading out of order; the worst that happens is
-- review, which is a person looking at it.
-- Returns: chronologically ordered spans, each with a `kind`.
function vo.SelectSpans(candidates, cfg, backbone, pinned)
  local weight     = vo.Opt(cfg, "order_weight")
  local min_tokens = vo.Opt(cfg, "backbone_min_tokens")

  -- Pinned lines are placed by hand; the matcher has nothing to add about them.
  local ordered = {}
  for i, c in ipairs(candidates) do
    ordered[i] = c
    -- Not `backbone and ... or nil`: false is a verdict here, and that idiom
    -- would quietly turn "out of order" into "no evidence".
    if backbone and (c.i1 - c.i0 + 1) < min_tokens then
      c.in_sequence = vo.OrderConsistency(c, backbone)
    end
    c.effective = (c.in_sequence == false)
      and math.max(0.0, c.score - weight) or c.score
  end

  -- Selection is greedy, so the ORDER candidates are considered in is what
  -- decides which of two overlapping placements survives -- and raw score is a
  -- bad answer to that. A one-word line scores a perfect 1.0 against any
  -- occurrence of its word, including one in the middle of a twelve-word line
  -- that scores 0.75 because the recogniser fused two words. Ranked on score
  -- alone the single word wins and cuts the long line in half, and demoting it
  -- to review is not enough: a review-grade placement it should never have had
  -- still blocks the real one.
  --
  -- So candidates are considered in tiers of how much they are worth believing,
  -- and only ranked by score within a tier.
  local function tier(c)
    if c.backbone then return 1 end             -- long, confident, unambiguous
    if c.in_sequence == false then return 5 end -- contradicts the read: last
    -- A line too short to identify itself takes what is left once the lines
    -- that CAN identify themselves have taken theirs. Where a short line's
    -- window sits inside a long one's, only one of them can be right, and the
    -- long one is not the one that could have happened by accident. Nothing is
    -- lost by waiting: vo.ResidualPass comes back for whatever went unplaced.
    if (c.i1 - c.i0 + 1) < min_tokens then return 4 end
    return c.kind_pre == "match" and 2 or 3     -- confident before uncertain
  end

  for _, c in ipairs(ordered) do
    c.kind_pre = vo.Classify(c.effective, c.margin or 1.0, cfg)
    -- Contradicting the read costs a short line its confidence however well it
    -- scored: a perfect match for a one-word line is perfect wherever that word
    -- happens to fall.
    if c.kind_pre == "match" and c.in_sequence == false then c.kind_pre = "review" end
    c.tier = tier(c)
  end

  table.sort(ordered, function(a, b)
    if a.tier ~= b.tier then return a.tier < b.tier end
    -- Within a tier, by tokens of agreement: a twelve-word match and a one-word
    -- match are not equal evidence, and waiting for their scores to tie exactly
    -- before saying so leaves the short one winning almost every time.
    local aa, ab = vo.Agreement(a), vo.Agreement(b)
    if aa ~= ab then return aa > ab end
    if a.effective ~= b.effective then return a.effective > b.effective end
    local ma, mb = a.margin or 1.0, b.margin or 1.0
    if ma ~= mb then return ma > mb end
    return a.i0 < b.i0
  end)

  -- Seeded, not merged in and re-sorted: a pin is not competing for its place.
  local chosen = {}
  for _, p in ipairs(pinned or {}) do chosen[#chosen + 1] = p end

  for _, c in ipairs(ordered) do
    if c.kind_pre then
      local overlaps = false
      for _, s in ipairs(chosen) do
        if c.i0 <= s.i1 and s.i0 <= c.i1 then
          overlaps = true
          break
        end
      end
      if not overlaps then
        local span = {}
        for k, v in pairs(c) do span[k] = v end
        span.kind = c.kind_pre
        span.kind_pre, span.tier = nil, nil
        chosen[#chosen + 1] = span
      end
    end
  end

  table.sort(chosen, function(a, b) return a.i0 < b.i0 end)
  return chosen
end

-- A second look, at what is left over.
--
-- Selection is greedy and one-shot, so a line can end up with nothing not
-- because it scored badly anywhere but because every window it wanted was taken
-- by a line that got there first. That is an artefact of the order candidates
-- were considered in, not a fact about the recording, and the evidence for it
-- is still sitting there: unclaimed audio, and lines with no placement at all.
--
-- So match again with only those two -- the lines nobody placed, against the
-- audio nobody claimed. There is no competition from the first pass to lose
-- this time, and nothing already decided can be disturbed, because a candidate
-- is only considered if it falls entirely in unclaimed territory.
--
-- Repeats until a pass adds nothing, since placing one line frees no audio but
-- can reveal that two lines were fighting over the same stretch and only one
-- needed it. Bounded, because a bug here would otherwise be an infinite loop.
vo.RESIDUAL_PASSES = 3

function vo.ResidualPass(word_tokens, lines, spans, cfg, index)
  local added = {}
  local current = spans

  for _ = 1, vo.RESIDUAL_PASSES do
    local covered, placed = {}, {}
    for _, s in ipairs(current) do
      if s.i0 and s.i1 then
        for k = s.i0, s.i1 do covered[k] = true end
      end
      if s.line_idx then placed[s.line_idx] = true end
    end

    -- Postings for the unplaced lines only, so no window is proposed that we
    -- would only throw away.
    local postings, any = {}, false
    for token, list in pairs(index.postings) do
      local mine = {}
      for _, p in ipairs(list) do
        if not placed[p.line] then mine[#mine + 1] = p end
      end
      if #mine > 0 then
        postings[token] = mine
        any = true
      end
    end
    if not any then break end

    local restricted = {
      n = index.n, idf = index.idf, tokens = index.tokens,
      anchors = index.anchors, postings = postings,
    }

    local fresh = {}
    for _, c in ipairs(vo.FindCandidates(word_tokens, lines, restricted, cfg)) do
      local clear = true
      for k = c.i0, c.i1 do
        if covered[k] then clear = false break end
      end
      if clear then fresh[#fresh + 1] = c end
    end
    if #fresh == 0 then break end

    local won = vo.SelectSpans(fresh, cfg, nil, nil)
    if #won == 0 then break end
    for _, s in ipairs(won) do
      s.residual = true
      added[#added + 1] = s
    end

    local merged = {}
    for _, s in ipairs(current) do merged[#merged + 1] = s end
    for _, s in ipairs(won)     do merged[#merged + 1] = s end
    current = merged
  end

  return added
end

-- Spans a person placed by hand.
--
-- A pin is not a guess with a score. It is somebody who listened to the audio
-- and said "this stretch IS this line", which is better evidence than anything
-- the matcher can produce, so pinned spans are seeded into the selection before
-- the greedy pass and everything overlapping them loses.
--
-- A pin speaks for its own TAKE and says nothing about the line's others. It
-- once dropped them, on the reasoning that you pin a line when the matcher put
-- it somewhere wrong -- but the same gesture is used to confirm one take of
-- three, and there the suppression silently deleted two real ones. The two
-- mistakes are not equally bad: an extra take is visible in the Take column
-- and can be dealt with, a deleted one is not there to notice.
--
-- The pin's own times are kept, not the matched words' -- the range is the part
-- the person chose. The token range is only what tells the rest of the pass
-- which words are now spoken for.
-- Returns: spans, unresolved (pins that name no word in this transcript)
function vo.PinnedSpans(word_tokens, pins, lines)
  local by_asset = {}
  for i, line in ipairs(lines or {}) do
    if line.asset and by_asset[line.asset] == nil then by_asset[line.asset] = i end
  end

  local spans, unresolved = {}, {}
  for _, pin in ipairs(pins or {}) do
    local line_idx = by_asset[pin.asset]
    local i0, i1
    for k, t in ipairs(word_tokens or {}) do
      -- A word counts as pinned when its midpoint is inside the range, so a
      -- word clipped by the edge of the selection goes one way or the other
      -- rather than both.
      local mid = (t.t0 + t.t1) / 2
      if mid >= pin.start and mid <= pin.stop then
        i0 = i0 or k
        i1 = k
      end
    end

    if not line_idx then
      unresolved[#unresolved + 1] = { pin = pin, why = "no script line named " .. pin.asset }
    elseif not i0 then
      unresolved[#unresolved + 1] = { pin = pin, why = "no transcribed word in that range" }
    else
      spans[#spans + 1] = {
        i0        = i0,
        i1        = i1,
        start     = pin.start,
        stop      = pin.stop,
        score     = 1.0,
        margin    = 1.0,
        effective = 1.0,
        kind      = "match",
        pinned    = true,
        line_idx  = line_idx,
        asset     = pin.asset,
        deliver   = lines[line_idx].deliver,
        character = lines[line_idx].speaker,
      }
    end
  end

  table.sort(spans, function(a, b) return a.i0 < b.i0 end)
  return spans, unresolved
end

-- The matcher, backwards: which script lines could THESE words be, best first.
--
-- vo.FindLineCandidates answers "where did this line go?"; this answers "what is
-- this?", which is the question a span nothing claimed actually poses. The list
-- of orphans reads as a pile of unknown audio precisely because the tool could
-- only ever ask the first question, one line at a time, and a person looking at
-- an orphan does not yet know which line to ask about.
--
-- No index and no anchors: the window is fixed, so every line is simply scored
-- against it. That is the same Levenshtein the matcher uses, and at a few hundred
-- lines against ten tokens it costs nothing -- the index exists to find WINDOWS,
-- and here the window is already known.
--
-- Deliberately looser than the batch pass by default. A person looking at one
-- span can accept weaker evidence than a sweep over sixteen hundred words should:
-- the risk that makes the global threshold conservative is a wrong name written
-- silently across the session, and it does not apply to one deliberate act.
--
-- Decides nothing and stores nothing.
-- Returns: { { line_idx, score, asset, deliver, text, speaker }, ... }
function vo.FindSpanLines(lines, text, cfg, opts)
  opts = opts or {}
  local floor_ = opts.floor or 0.25
  local limit  = opts.limit or 12
  local window = vo.Tokenize(vo.Normalize(text or "", cfg and cfg.substitutions))
  if #window == 0 or not lines then return {} end

  local out = {}
  for idx, line in ipairs(lines) do
    local toks = vo.Tokenize(vo.Normalize(line.text or "", cfg and cfg.substitutions))
    if #toks > 0 then
      local score = 1 - vo.Levenshtein(toks, window) / math.max(#toks, #window)
      if score >= floor_ then
        out[#out + 1] = { line_idx = idx, score = score, asset = line.asset,
                          deliver = line.deliver or line.asset,
                          text = line.text, speaker = line.speaker }
      end
    end
  end

  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.line_idx < b.line_idx
  end)
  while #out > limit do table.remove(out) end
  return out
end

-- Every distinct place one script line could sit in one transcript, best first.
--
-- Deliberately NOT the matcher. The matcher has to choose one placement and
-- live with it; this shows the ones it passed over -- including the ones it
-- scored too low to consider at all -- so a person can go and listen to them.
-- It decides nothing, changes nothing and is stored nowhere.
--
-- More of the line's words propose windows than the matcher uses: the matcher
-- can afford to miss a placement because another of its anchors will find it,
-- and a search cannot. Not ALL of them, though -- the commonest words of a long
-- line would propose a near-identical window at every "the" in the recording.
--
-- The whole `lines` set is needed, not just the one being searched for: which of
-- a line's words are rare enough to anchor on is a fact about the script, and a
-- line indexed by itself has no rare words at all.
--
-- `opts.words`, when given, is the raw word list the tokens were built from, so
-- the text shown back is what was actually said rather than the normalised form
-- matching works on.
-- Returns: { { i0, i1, start, stop, score, text, before, after }, ... }
function vo.FindLineCandidates(lines, line_idx, word_tokens, cfg, opts)
  opts = opts or {}
  local line = lines and lines[line_idx]
  if not line or not word_tokens or #word_tokens == 0 then return {} end

  local sub = {}
  for k, v in pairs(cfg or {}) do sub[k] = v end
  sub.anchor_count = math.max(vo.Opt(cfg, "anchor_count") or 3, 8)
  -- Below the review floor on purpose. A placement the matcher was right to
  -- reject is still the answer to "where did this line go?".
  sub.review_floor = opts.floor or 0.25

  local full = vo.BuildIndex(lines, sub)
  -- Every other line's postings are dropped rather than filtered afterwards:
  -- they would propose windows only to have them thrown away.
  local index = {
    n = full.n, idf = full.idf, tokens = full.tokens, anchors = full.anchors,
    postings = {},
  }
  for token, list in pairs(full.postings) do
    local mine = {}
    for _, p in ipairs(list) do
      if p.line == line_idx then mine[#mine + 1] = p end
    end
    if #mine > 0 then index.postings[token] = mine end
  end

  local found = vo.FindCandidates(word_tokens, lines, index, sub)

  table.sort(found, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.i0 < b.i0
  end)

  -- Places, not scoring variants: several anchors of one line propose windows a
  -- token or two apart, and listing them all would bury the distinct placements.
  local kept = {}
  for _, c in ipairs(found) do
    local clash = false
    for _, k in ipairs(kept) do
      if c.i0 <= k.i1 and k.i0 <= c.i1 then clash = true break end
    end
    if not clash then
      kept[#kept + 1] = c
      if #kept >= (opts.limit or 12) then break end
    end
  end

  local raw   = opts.words
  local ctx_n = opts.context or 6
  -- Read back over the RAW words the token range covers, not over the tokens.
  -- Normalising drops words -- and one word can expand into several tokens --
  -- so reading the tokens back gives text with holes in it, which is no use to
  -- someone trying to recognise a moment in a recording.
  local function say(a, b)
    a, b = math.max(1, a), math.min(#word_tokens, b)
    if a > b then return "" end
    local out = {}
    if raw and word_tokens[a].word and word_tokens[b].word then
      for k = word_tokens[a].word, word_tokens[b].word do
        if raw[k] then out[#out + 1] = raw[k].text end
      end
    else
      for k = a, b do out[#out + 1] = word_tokens[k].text end
    end
    return table.concat(out, " ")
  end

  local out = {}
  for _, c in ipairs(kept) do
    out[#out + 1] = {
      i0     = c.i0,
      i1     = c.i1,
      start  = c.start,
      stop   = c.stop,
      score  = c.score,
      text   = say(c.i0, c.i1),
      before = say(c.i0 - ctx_n, c.i0 - 1),
      after  = say(c.i1 + 1, c.i1 + ctx_n),
    }
  end
  return out
end

-- Any run of tokens no span consumed becomes an unmatched span.
-- Slates, false starts and chatter land here without being modelled explicitly.
function vo.FindGaps(word_tokens, spans)
  local covered = {}
  for _, s in ipairs(spans or {}) do
    for i = s.i0, s.i1 do covered[i] = true end
  end

  local gaps = {}
  local i, n = 1, #word_tokens
  while i <= n do
    if covered[i] then
      i = i + 1
    else
      local j = i
      while j + 1 <= n and not covered[j + 1] do j = j + 1 end

      local text = {}
      for k = i, j do text[#text + 1] = word_tokens[k].text end

      gaps[#gaps + 1] = {
        i0         = i,
        i1         = j,
        kind       = "unmatched",
        start      = word_tokens[i].t0,
        stop       = word_tokens[j].t1,
        transcript = table.concat(text, " "),
      }
      i = j + 1
    end
  end

  return gaps
end

--------------------------------
-- Pure layer: naming
--------------------------------

-- Windows refuses these as filenames regardless of extension, and clip names
-- become filenames on render.
local RESERVED_DEVICE_NAMES = {
  con = true, prn = true, aux = true, nul = true,
}
for i = 1, 9 do
  RESERVED_DEVICE_NAMES["com" .. i] = true
  RESERVED_DEVICE_NAMES["lpt" .. i] = true
end

-- Fold a name to something safe on every filesystem REAPER renders to.
-- Everything outside [A-Za-z0-9._-] collapses to a single underscore.
function vo.SanitizeName(s, max_len)
  max_len = max_len or vo.DEFAULTS.max_name_length

  s = tostring(s or "")
  s = s:gsub("[^%w%.%_%-]", "_")
  s = s:gsub("_+", "_")
  s = s:gsub("^_+", ""):gsub("_+$", "")

  if #s > max_len then
    s = s:sub(1, max_len)
    s = s:gsub("_+$", "")
  end

  if s == "" then return "unnamed" end

  local stem = s:match("^([^%.]*)") or s
  if RESERVED_DEVICE_NAMES[stem:lower()] then s = "_" .. s end

  return s
end

-- Track name for a character bucket: "<Character>_<Base>" when a character is
-- present, else the base name. The character is sanitized like a clip name.
-- Is this track one Pull made? Needed because Pull runs more than once: on the
-- second pass an item already sits on "<CHAR>_Review", and nesting its new
-- destination under THAT would bury a track inside a track every run. The
-- recording it came from is the first parent that is not one of ours.
--
-- Matched on the base names rather than a marker, because the user can rename
-- them in Settings and a project can hold any number of characters.
function vo.IsDestTrackName(name, bases)
  name = tostring(name or "")
  if name == "" then return false end
  for _, base in ipairs(bases or {}) do
    if base ~= "" and (name == base or name:sub(-(#base + 1)) == "_" .. base) then
      return true
    end
  end
  return false
end

function vo.CharacterTrackName(character, base)
  if character and character ~= "" then
    return vo.SanitizeName(character) .. "_" .. base
  end
  return base
end

--------------------------------
-- Pure layer: silence detection
--------------------------------

-- Every function here takes its amplitude readings through an injected
-- `probe(t0, t1) -> dBFS or nil`. Nothing in this section touches REAPER, so
-- the placement rules are unit-testable against a synthetic amplitude curve;
-- the real probe is vo.MakeTakeProbe in the coupled layer.

-- The stretches between consecutive words -- where a boundary is allowed to go.
-- Words that touch or overlap yield nothing: there is no gap to search.
function vo.InterWordGaps(words)
  local out = {}
  for i = 2, #(words or {}) do
    local from, to = words[i - 1].t1 or 0, words[i].t0 or 0
    if to > from then out[#out + 1] = { from = from, to = to } end
  end
  return out
end

-- The room's noise floor, measured rather than assumed: a fixed -60 dBFS is
-- wrong on a noisy room and wrong in the other direction on a clean one.
-- One window is sampled from the middle of each gap long enough to hold it,
-- and the quietest reading plus the offset is the floor.
--
-- Returns nil when nothing could be measured, which the caller must read as
-- "snapping is unavailable" rather than as a floor of zero -- a floor of zero
-- dBFS would call every sample silent and snap every boundary to its limit.
function vo.MeasureNoiseFloor(gaps, probe, cfg)
  if not probe then return nil end
  local window  = vo.Opt(cfg, "snap_floor_window")
  local minimum = vo.Opt(cfg, "snap_min_silence")
  local levels  = {}

  for _, g in ipairs(gaps or {}) do
    local span = g.to - g.from
    -- Measure over as much of the gap as there is, up to the configured window
    -- -- NOT only over gaps long enough to fill it. Requiring a full window
    -- meant a recording whose pauses all fell just short of it yielded no floor
    -- at all, and snapping silently degraded to fixed pads for the whole file.
    -- Ordinary speech has most of its gaps well under half a second.
    if span >= minimum then
      local w   = math.min(window, span)
      local mid = (g.from + g.to) / 2
      local db  = probe(mid - w / 2, mid + w / 2)
      if db then levels[#levels + 1] = db end
    end
  end

  if #levels == 0 then return nil end

  -- A LOW PERCENTILE, not the minimum. Noise reduction leaves patches of a
  -- cleaned recording at near-digital silence, and taking the quietest of them
  -- set a floor the rest of the file could never meet -- measured -75dB against
  -- its own room tone of about -67, so every silence test failed, snapping fell
  -- back to fixed pads everywhere, and no edge could tell room from speech.
  -- The percentile sits under the room tone without chasing an outlier down.
  table.sort(levels)
  local at = math.max(1, math.ceil(vo.Opt(cfg, "snap_floor_percentile") * #levels))
  return levels[math.min(at, #levels)] + vo.Opt(cfg, "snap_floor_offset")
end

-- The gate this run will use, in dBFS: one number, whichever way it was reached.
--
-- Everything downstream -- speech bounds, the walk through a welded breath, the
-- quiet test on a finished edge -- asks the same question, "is this above the
-- gate", so there is exactly one number to understand. It is either typed in or
-- measured from the room; `snap_gate_auto` decides which.
--
-- Returns nil only when Auto is on and nothing could be measured, which the
-- caller must read as "snapping is unavailable" rather than as a gate of zero
-- dBFS -- that would call every sample silent and snap every edge to its limit.
function vo.ResolveGate(gaps, probe, cfg)
  if not vo.Opt(cfg, "snap_gate_auto") then
    return vo.Opt(cfg, "snap_gate_db"), "fixed"
  end
  local measured = vo.MeasureNoiseFloor(gaps, probe, cfg)
  if not measured then return nil end
  return measured, "measured"
end

-- The first and last moment inside [from, to] that is louder than the floor.
--
-- Whisper's word timestamps are contiguous by construction: a word's END is
-- simply the next word's START, so 94% of them touch exactly. The pause around
-- a take is therefore INSIDE the span, not outside it -- the first word of a
-- take carries the silence before it and the last word carries the silence
-- after. Snapping outward from those edges has nowhere to go, and every take
-- gets cut from the previous take's last syllable to the next take's first, so
-- the clips tile the recording end to end with no breaks between them at all.
--
-- Finding where the speech actually starts and stops inside the span is what
-- gives the edges something to mean. The audio is the only evidence available:
-- the word times cannot tell speech from the pause they absorbed.
--
-- Returns: first, last -- both nil when nothing in the range is above the
-- floor, which the caller must read as "no speech found here", falling back to
-- the span's own edges rather than trimming to nothing.
function vo.FindSpeechBounds(from, to, floor_db, probe, cfg)
  local step = vo.Opt(cfg, "snap_min_silence")
  if not probe or not floor_db or step <= 0 then return nil, nil end
  if (to - from) <= step then return nil, nil end

  -- Stepped by index, not by accumulation: a span can be twenty seconds long
  -- at a sixty-millisecond step, and drifting a window edge a hair past the
  -- speech is enough to read the pause as sound and give the trim nothing to do.
  local first, last
  local n = 0
  while from + (n + 1) * step <= to + 1e-9 do
    local a  = from + n * step
    local db = probe(a, a + step)
    if db and db > floor_db then
      if not first then first = a end
      last = a + step
    end
    n = n + 1
  end
  return first, last
end

-- Sound the transcript never heard: audible bursts in audio that nothing
-- covers -- no counting marker, no transcribed word.
--
-- Every other queue starts from the transcript. UnidentifiedSpans lists reads
-- the matcher scored that no marker claims; orphans list reads that matched no
-- line; both need whisper to have HEARD the read. A read whisper skipped
-- entirely -- it happens, and it leaves an audible burst sitting in a marker
-- gap -- has no span and no word, so no transcript-side check can ever
-- surface it. Only the amplitude knows it is there. This is the last net.
--
-- `covered` is the union of everything already spoken for, in any order:
-- counting-marker ranges and transcribed-word ranges. Only the UNCOVERED
-- remainder is scanned, so a marker's generous tail lapping a burst's head
-- hides that lapped part and nothing else -- hiding the whole burst because
-- its first tenth was covered would lose the take.
--
-- A burst must hold at least `unheard_min_length` of sound (shorter is a
-- click or a chair, not a read), and dips shorter than `unheard_join` stay
-- inside one burst (a stop consonant is not a boundary). Same windowing as
-- vo.FindSpeechBounds, same injected probe, same gate.
--
--   from, to  -- the range to scan, in the same time base as `probe`
--   covered   -- array of { from, to }, unsorted, overlaps welcome
--   floor_db  -- from vo.ResolveGate; nil means the scan is unavailable
--
-- Returns: array of { from, to }, in order. Empty when nothing qualifies --
-- including when there is no probe or no floor, which the caller must read
-- as "could not look" rather than "looked and found nothing".
function vo.UnheardBursts(from, to, covered, floor_db, probe, cfg)
  local step    = vo.Opt(cfg, "snap_min_silence")
  local min_len = vo.Opt(cfg, "unheard_min_length")
  local join    = vo.Opt(cfg, "unheard_join")
  if not probe or not floor_db or step <= 0 then return {} end
  if (to or 0) - (from or 0) <= step then return {} end

  local cov = {}
  for _, c in ipairs(covered or {}) do
    if (c.to or 0) > (c.from or 0) then cov[#cov + 1] = { from = c.from, to = c.to } end
  end
  table.sort(cov, function(a, b) return a.from < b.from end)
  local merged = {}
  for _, c in ipairs(cov) do
    local last = merged[#merged]
    if last and c.from <= last.to + 1e-9 then
      if c.to > last.to then last.to = c.to end
    else
      merged[#merged + 1] = c
    end
  end

  local gaps, at = {}, from
  for _, c in ipairs(merged) do
    if c.from > at + 1e-9 then gaps[#gaps + 1] = { from = at, to = math.min(c.from, to) } end
    at = math.max(at, c.to)
    if at >= to then break end
  end
  if at < to - 1e-9 then gaps[#gaps + 1] = { from = at, to = to } end

  local out = {}
  for _, g in ipairs(gaps) do
    -- Stepped by index, not accumulation, for the same reason as
    -- vo.FindSpeechBounds: drift over a long gap moves every edge.
    local runs, n = {}, 0
    while g.from + (n + 1) * step <= g.to + 1e-9 do
      local a  = g.from + n * step
      local db = probe(a, a + step)
      if db and db > floor_db then
        local last = runs[#runs]
        if last and a - last.to <= join + 1e-9 then
          last.to = a + step
        else
          runs[#runs + 1] = { from = a, to = a + step }
        end
      end
      n = n + 1
    end
    for _, rn in ipairs(runs) do
      if rn.to - rn.from >= min_len - 1e-9 then out[#out + 1] = rn end
    end
  end
  return out
end

-- Where to divide two words whose timestamps TOUCH.
--
-- Whisper chains word times -- a word's end is simply the next word's start --
-- so a boundary between two takes is routinely one instant with no gap in it.
-- That instant is not where the sound divides: the mark lands a hair late and
-- the following word's onset begins before it. Cutting there leaves the first
-- clip holding a fragment of the next word's attack and the second clip
-- decapitated ("Book." rendered as "Look.").
--
-- A fixed offset cannot settle it -- both clips want the same milliseconds --
-- so the audio is asked instead: the quietest window within `reach` of the mark
-- is the dip BETWEEN the words, and that is the boundary. Relative, so it needs
-- no absolute floor, which is what lets it work on a recording whose floor
-- measurement is wrong.
--
-- Both neighbours run this on the same mark and so agree exactly, which is what
-- stops either of them holding a piece of the other.
-- Returns: the boundary time, or nil with no probe.
function vo.QuietestBoundary(mark, reach, step, probe)
  if not probe or not mark or (reach or 0) <= 0 or (step or 0) <= 0 then return nil end
  local n = math.floor(reach / step)
  local best, best_db
  -- Outward from the mark, so an exact tie -- a run of digital silence, say --
  -- keeps the boundary as near the transcript's own answer as it can.
  for d = 0, n do
    local ks = (d == 0) and { 0 } or { -d, d }
    for _, k in ipairs(ks) do
      local at = mark + k * step
      local db = probe(at - step / 2, at + step / 2)
      if db and (not best_db or db < best_db - 1e-9) then best, best_db = at, db end
    end
  end
  return best
end

-- Place one boundary between a word edge and a hard limit.
--
--   from      -- the word's own edge, in the same time base as `probe`
--   limit     -- how far the boundary may travel: the neighbouring word's edge,
--                or the pad, whichever is nearer. NEVER exceeded.
--   direction -- -1 searching backwards (a span start), +1 forwards (a stop)
--   floor_db  -- from vo.MeasureNoiseFloor
--   probe     -- amplitude reader, or nil
--
-- Steps outward from the word in `snap_min_silence` windows and stops at the
-- far edge of the first window lying entirely below the floor, so the clip
-- keeps that much silence as head or tail. Falls back to `limit` when there is
-- no probe, no floor, no room, or no silence -- reported as "pad" so the run
-- summary can say why an edge sits where it does.
--
-- Returns: boundary time, "silence" or "pad".
function vo.SnapBoundary(from, limit, direction, floor_db, probe, cfg)
  local min_sil = vo.Opt(cfg, "snap_min_silence")
  if not probe or not floor_db or min_sil <= 0 then return limit, "pad" end

  local reach = math.abs(limit - from)
  if reach < min_sil then return limit, "pad" end

  local travelled = 0
  while travelled + min_sil <= reach + 1e-9 do
    local near = from + direction * travelled
    local a    = (direction < 0) and (near - min_sil) or near
    local db   = probe(a, a + min_sil)
    if db and db <= floor_db then
      return (direction < 0) and a or (a + min_sil), "silence"
    end
    travelled = travelled + min_sil
  end

  return limit, "pad"
end

--------------------------------
-- Pure layer: boundaries
--------------------------------

-- Pad each span outwards, then clamp so neighbours never overlap and nothing
-- crosses the containing item's bounds. Colliding neighbours meet at the
-- midpoint of their original gap, which keeps the result independent of the
-- order spans were selected in. Mutates and returns `spans`.
--
-- bounds: optional { start = number, stop = number }
-- probe, floor_db: optional. Supply BOTH (and leave cfg.snap_boundaries on) to
--   place each edge by looking for silence instead of applying a fixed pad;
--   each span then carries `snapped` = "silence" or "pad". With either absent
--   this behaves exactly as it always did, which is why the fixed-pad tests
--   still describe the truth.
-- The last word to END at or before `t`, and the first to START at or after it.
-- Words the caller passes are in the SAME time base as the spans.
local function word_end_before(words, t)
  local best
  for _, w in ipairs(words or {}) do
    local e = w.t1 or w.stop
    if e and e <= t + 1e-9 and (not best or e > best) then best = e end
  end
  return best
end

local function word_start_after(words, t)
  local best
  for _, w in ipairs(words or {}) do
    local s = w.t0 or w.start
    if s and s >= t - 1e-9 and (not best or s < best) then best = s end
  end
  return best
end

function vo.ApplyPadding(spans, cfg, bounds, probe, floor_db, words)
  local pre  = vo.Opt(cfg, "pre_pad")
  local post = vo.Opt(cfg, "post_pad")
  local snap = vo.Opt(cfg, "snap_boundaries") and probe and floor_db

  for _, s in ipairs(spans) do s.raw_start, s.raw_stop = s.start, s.stop end

  -- A word whisper CHAINED onto a span's edge that NO span claims is that
  -- take's own edge word, misheard. The matcher scores a substituted edge word
  -- and a dropped one identically -- "Adon no speak to us, so master is
  -- Archivist" heard as "both no speak to us so master is alchemist" loses one
  -- point either way -- so it tightens to the window without them, and the
  -- word fence below then guarantees the cut excludes the take's own first and
  -- last words. Every take of that line, every run, and nothing on the
  -- timeline says what was lost.
  --
  -- Chaining is the evidence: whisper ends a word exactly where the next
  -- begins only when it decoded them as one utterance. A word a real time gap
  -- separates from the span stays fenced out exactly as before -- that is the
  -- false start / aside case, and it belongs to nobody. Claimed words are
  -- untouchable regardless: they are another take.
  --
  -- ONE word per edge, not a walk. The failure this repairs is a misheard
  -- WORD, singular; run with a deeper reach, a take's start absorbed its own
  -- first word and then kept going through the PREVIOUS take's unmatched last
  -- word -- three takes of "Adon no speak to us" chained end to end, and take
  -- three stole take two's "Archivist". A run of several unheard words is the
  -- substitution list's job, not absorption's.
  --
  -- Starts run before stops so that when one unclaimed word is chained
  -- between two takes, the LATER take's head wins -- an onset belongs to the
  -- word that follows it, same rule as the overlap clamp below. The earlier
  -- take's stop pass then finds the word claimed and leaves it alone.
  if snap and words then
    local function unclaimed(w)
      local mid = ((w.t0 or 0) + (w.t1 or 0)) / 2
      for _, o in ipairs(spans) do
        if mid >= o.raw_start - 1e-6 and mid <= o.raw_stop + 1e-6 then
          return false
        end
      end
      return true
    end
    for _, s in ipairs(spans) do
      local best
      for _, w in ipairs(words) do
        if w.t0 and w.t1 and math.abs(w.t1 - s.raw_start) <= 1e-3
           and w.t0 < s.raw_start - 1e-6 and unclaimed(w) then
          if not best or w.t0 < best then best = w.t0 end
        end
      end
      if best then s.raw_start = best end
    end
    for _, s in ipairs(spans) do
      local best
      for _, w in ipairs(words) do
        if w.t0 and w.t1 and math.abs(w.t0 - s.raw_stop) <= 1e-3
           and w.t1 > s.raw_stop + 1e-6 and unclaimed(w) then
          if not best or w.t1 > best then best = w.t1 end
        end
      end
      if best then s.raw_stop = best end
    end
  end

  for i, s in ipairs(spans) do
    if snap then
      -- The span's own words' ANCHORS, and the nearest neighbouring words'
      -- (SPEC-anchor-boundaries.md §5). Raw extents are partition edges, and
      -- a word's anchor can sit on the far side of its own window's edge --
      -- "chain." stamped to 586.210 with the word anchored at 586.52 -- so a
      -- span's own last word can live PAST raw_stop. Ownership is judged by
      -- window containment (the partition tiles exactly); the fence anchors
      -- are the nearest words outside. A neighbour anchor that would sit at
      -- or inside the span's own is a degenerate transcript, not a fence.
      local own_a0, own_a1, prev_a, next_a
      if words then
        for _, w in ipairs(words) do
          local a = w.anchor
          if a and w.t0 and w.t1 then
            if w.t0 >= s.raw_start - 1e-6 and w.t1 <= s.raw_stop + 1e-6 then
              if not own_a0 or a < own_a0 then own_a0 = a end
              if not own_a1 or a > own_a1 then own_a1 = a end
            elseif w.t1 <= s.raw_start + 1e-6 then
              if not prev_a or a > prev_a then prev_a = a end
            elseif w.t0 >= s.raw_stop - 1e-6 then
              if not next_a or a < next_a then next_a = a end
            end
          end
        end
        if prev_a and own_a0 and prev_a >= own_a0 then prev_a = nil end
        if next_a and own_a1 and next_a <= own_a1 then next_a = nil end
      end
      -- For the overlap pass below: the dip between two takes is searched
      -- between THESE, not between raw edges that may share an instant.
      s._own_a0, s._own_a1 = own_a0, own_a1

      -- Where the speech in this span actually is. Whisper's word times put the
      -- surrounding pause INSIDE the span (see vo.FindSpeechBounds), so an edge
      -- has to be trimmed in to the sound before it is padded back out; without
      -- this every take runs to the next take and the clips tile the recording.
      -- Nothing found means the floor is untrustworthy here, so keep the edges.
      -- The window reaches to the span's own anchors: a raw extent cut at a
      -- partition edge excludes part of the span's own last word, and speech
      -- measured only inside it would never see what the extent already lost.
      local sp0, sp1 = vo.FindSpeechBounds(
        math.min(s.raw_start, own_a0 or s.raw_start),
        math.max(s.raw_stop,  own_a1 or s.raw_stop), floor_db, probe, cfg)
      local at_start = sp0 or s.raw_start
      local at_stop  = sp1 or s.raw_stop

      -- The search window is bounded by the neighbouring WORD -- every word the
      -- transcript holds, not just the ones this cut selected. Bounding by the
      -- neighbouring SPAN alone is not enough: a false start or an aside sitting
      -- between two selected takes is audio that belongs to neither, and an edge
      -- allowed to travel its full pad into it can swallow a syllable of it.
      -- With the word bound in place that is structurally impossible, whatever
      -- the amplitude does inside the window. Raw boundaries throughout: a
      -- neighbour's already-padded edge describes a decision, not where audio is.
      -- The word bound is a timestamp, not a measurement, and whisper CHAINS
      -- them: the previous word ends exactly where this one starts, so on a
      -- chained transcript the clamp collapses onto the word and the clip is
      -- cut with nothing to spare. That is worst for exactly the onsets most
      -- at risk -- s, f, th, a breath -- which begin before whisper's mark and
      -- sit below the floor, invisible to both the snap and the clamp.
      --
      -- So where the bound has collapsed, the AUDIO places it instead: the
      -- quietest window near the mark is the dip between the two words. A fixed
      -- offset was tried first and is not enough -- moving the shared edge 30ms
      -- earlier saved the later take's "B" and left the same attack in the
      -- earlier take's tail ("I only win a little." became "I only win, little
      -- boy."). Both clips want those milliseconds; only the dip belongs to
      -- neither. Bounded by the pad so it can never travel far.
      local function settle(mark, hard, dir)
        local reach = math.min(vo.Opt(cfg, "chained_boundary_reach"),
                               math.abs(hard - mark))
        local at = vo.QuietestBoundary(mark, reach, 0.010, probe)
        if not at then return mark end
        -- Never past the pad, in either direction.
        if dir < 0 then return math.max(at, hard) end
        return math.min(at, hard)
      end

      -- ONLY where the bound has collapsed onto the take's own edge. A word
      -- ending well before this one starts describes a real pause, and that
      -- boundary is meaningful evidence -- nothing may reach past it. A word
      -- ending at the very instant this one begins describes nothing at all;
      -- it is whisper's chaining, and it is the case that clips syllables.
      local function collapsed(bound, edge)
        return bound ~= nil and math.abs(bound - edge) <= 1e-3
      end

      -- The neighbouring SPAN's edge bounds this one only where it is a real
      -- boundary. Chained word times make two takes share an instant exactly,
      -- and clamping to that collapses the reach to nothing -- the same trap as
      -- the word bound below. Overlap is prevented after the loop regardless.
      --
      -- With a neighbour ANCHOR in hand the fence is that anchor and nothing
      -- else: a point inside the neighbouring word, never chained, with the
      -- whole inter-take window before it. The pad then stops limiting how far
      -- an edge may TRAVEL -- it only ever limited travel because a t0/t1
      -- fence could not be trusted -- and goes back to being what it always
      -- claimed: room kept beyond the sound (`head`/`tail` below). Without an
      -- anchor the old fence-and-settle path runs unchanged, which is what
      -- keeps anchor-less transcripts exactly as they were.
      local start_hard, start_fenced
      if prev_a then
        start_hard, start_fenced = prev_a, true
      else
        start_hard = at_start - pre
      end
      local prev_edge = spans[i - 1] and spans[i - 1].raw_stop
      if prev_edge and math.abs(prev_edge - s.raw_start) > 1e-3 then
        start_hard = math.max(start_hard, prev_edge)
      end
      local start_limit = start_hard
      if not start_fenced then
        local wb = word_end_before(words, s.raw_start)
        if wb then
          start_limit = math.max(start_limit, wb)
          if collapsed(wb, s.raw_start) then
            start_limit = settle(start_limit, start_hard, -1)
          end
        end
      end

      local stop_hard, stop_fenced
      if next_a then
        stop_hard, stop_fenced = next_a, true
      else
        stop_hard = at_stop + post
      end
      local next_edge = spans[i + 1] and spans[i + 1].raw_start
      if next_edge and math.abs(next_edge - s.raw_stop) > 1e-3 then
        stop_hard = math.min(stop_hard, next_edge)
      end
      local stop_limit = stop_hard
      if not stop_fenced then
        local wa = word_start_after(words, s.raw_stop)
        if wa then
          stop_limit = math.min(stop_limit, wa)
          if collapsed(wa, s.raw_stop) then
            stop_limit = settle(stop_limit, stop_hard, 1)
          end
        end
      end

      -- A fixed distance from the SPEECH, not wherever the probe first
      -- crossed the floor: the crossing point depends on room tone and
      -- breaths, which handed one session anywhere from 0 to 1760ms of head
      -- room. Speech bounds are the measurement; the room around them is a
      -- constant, clamped by the neighbouring word and the pad maximums.
      -- A breath or a "ha" welded to the take's first word is part of the
      -- take, but whisper does not transcribe it, so the word time starts
      -- after it. Walk outward through CONTIGUOUS sound until real silence,
      -- bounded by the neighbour limits -- so a leading noise is captured,
      -- and a neighbouring word can never be.
      local function extend_through_sound(t, limit, dir)
        local step = 0.02
        while (dir < 0 and t - step >= limit) or (dir > 0 and t + step <= limit) do
          local w0 = (dir < 0) and (t - step) or t
          local db = probe(w0, w0 + step)
          if not db or db <= floor_db then break end
          t = t + dir * step
        end
        return t
      end
      at_start = extend_through_sound(at_start, start_limit, -1)
      at_stop  = extend_through_sound(at_stop,  stop_limit,  1)

      local head = math.min(pre,  vo.Opt(cfg, "snap_head_room"))
      local tail = math.min(post, vo.Opt(cfg, "snap_tail_room"))
      s.start = math.max(start_limit, at_start - head)
      s.stop  = math.min(stop_limit,  at_stop  + tail)
      -- "silence" is a verified claim: speech was measured on both ends AND
      -- the room the edges sit in actually reads quiet. Loud room tone or an
      -- unmeasurable floor reports "pad" so the run can say which clips to
      -- listen to.
      local function edge_quiet(x0, x1)
        if x1 - x0 < 1e-6 then return true end
        local db = probe(x0, x1)
        return db ~= nil and db <= floor_db
      end
      s.snapped = (sp0 and sp1
                   and edge_quiet(s.start, math.min(at_start, s.start + 0.05))
                   and edge_quiet(math.max(at_stop, s.stop - 0.05), s.stop))
                  and "silence" or "pad"
    else
      s.start = s.raw_start - pre
      s.stop  = s.raw_stop + post
    end
  end

  for i = 2, #spans do
    local prev, cur = spans[i - 1], spans[i]
    if cur.start < prev.stop then
      -- When both sides carry anchors, the shared edge is the QUIETEST window
      -- between the earlier take's last word and the later take's first
      -- (SPEC-anchor-boundaries.md §5.4): sound never broke between them --
      -- breath or lip noise bridged the takes -- and the dip is the one
      -- instant that belongs to neither. Symmetric by construction, so the
      -- result cannot depend on which span is visited first.
      local shared
      if probe and prev._own_a1 and cur._own_a0
         and cur._own_a0 > prev._own_a1 + 0.02 then
        local mid = (prev._own_a1 + cur._own_a0) / 2
        shared = vo.QuietestBoundary(mid, (cur._own_a0 - prev._own_a1) / 2,
                                     0.010, probe)
      end
      if shared then
        if prev.stop > shared then prev.stop, prev.clamped = shared, true end
        if cur.start < shared then cur.start, cur.clamped = shared, true end
      else
        -- Colliding neighbours meet at the midpoint of their ORIGINAL gap,
        -- which keeps the result independent of the order spans were
        -- selected in.
        local mid = (prev.raw_stop + cur.raw_start) / 2
        -- Unless there was no gap. Whisper chains word times, so two takes
        -- can share an edge exactly -- and then "the midpoint" is that one
        -- instant, which hands back every millimetre of head room the take
        -- just won and leaves it cut on its own first syllable. A zero-width
        -- boundary is not evidence of anything; an onset belongs to the word
        -- that FOLLOWS it, so the later take's head wins and the earlier
        -- take's tail yields to it.
        if math.abs(cur.raw_start - prev.raw_stop) <= 1e-3 then
          prev.stop, prev.clamped = cur.start, true
        else
          if prev.stop > mid then prev.stop, prev.clamped = mid, true end
          if cur.start < mid then cur.start, cur.clamped = mid, true end
        end
      end
    end
  end

  local function clamp_to_bounds(s)
    if not bounds then return end
    if bounds.start and s.start < bounds.start then
      s.start, s.clamped = bounds.start, true
    end
    if bounds.stop and s.stop > bounds.stop then
      s.stop, s.clamped = bounds.stop, true
    end
  end

  for _, s in ipairs(spans) do clamp_to_bounds(s) end

  -- Both clamps above move one boundary without consulting the other, so either
  -- can push a boundary past its own opposite edge and invert the span. The
  -- neighbour clamp does it whenever the plan's order is not chronological —
  -- BuildMatch sorts by token index, and whisper timestamps are not guaranteed
  -- monotonic (nor distinct: every token expanded from one word shares its
  -- times), so `mid` can land beyond the later span's own end. The bounds clamp
  -- does it for a span lying wholly outside the item.
  --
  -- An inverted span is not a cosmetic reporting problem: ApplyPlan splits at
  -- start and again at stop, and with stop <= start the second split is a no-op,
  -- which sweeps the whole remainder of the item onto one track (see
  -- vo.MIN_SPLIT_LENGTH). Rather than lose the take, fall back to the span's own
  -- recognized boundaries — unpadded, but real — and flag it so the report can
  -- say why it was not padded like its neighbours. Only if the raw span is
  -- itself degenerate, or lies outside the item, does it stay uncuttable, and
  -- even then it is collapsed to zero width rather than left negative.
  for _, s in ipairs(spans) do
    if s.stop <= s.start then
      s.start, s.stop = s.raw_start, s.raw_stop
      s.degenerate = true
      clamp_to_bounds(s)
      if s.stop < s.start then s.stop = s.start end
    end
  end

  return spans
end

--------------------------------
-- Pure layer: routing and naming
--------------------------------

-- A span's `deliver` is COPIED from its line when the match is built, and the
-- match is memoised precisely so that typing an Append does not rebuild it.
-- That copy is stale the moment an Append lands -- so anything that names
-- takes from spans must re-copy from the CURRENT lines first, or it delivers
-- yesterday's name. Same line lookup as BuildOverview: the span's own
-- line_idx when it still agrees on the asset, else the first line using it.
function vo.RefreshSpanDeliveries(spans, lines)
  lines = lines or {}
  local first_row_using = {}
  for i, l in ipairs(lines) do
    if l.asset and first_row_using[l.asset] == nil then first_row_using[l.asset] = i end
  end
  for _, s in ipairs(spans or {}) do
    if s.asset then
      local li = s.line_idx
      if not (li and lines[li] and lines[li].asset == s.asset) then
        li = first_row_using[s.asset]
      end
      local line = li and lines[li] or nil
      if line then
        s.deliver = line.deliver
        -- Same staleness family as deliver: any line-derived field cached on a
        -- memoised span re-copies here, in the one place, or it drifts.
        if line.speaker and line.speaker ~= "" then s.character = line.speaker end
      end
    end
  end
  return spans
end

-- Group repeated takes of a line (keyed by the Filename/asset, which is the
-- line's identity), number them chronologically, then route and name every span
-- according to the three per-session toggles.
-- Only `match` spans are numbered: a review clip is not a delivered take, so
-- counting it would leave gaps in the delivered take numbers.
-- Mutates and returns `spans` (adds take_index, primary, dest, name).
--
-- IDEMPOTENT, and relied upon as such: take_index, primary, dest and name are
-- every one of them re-derived from kind/asset/start/score/transcript plus cfg,
-- and unconditionally overwritten -- nothing here reads a previously assigned
-- value. That is what lets the two callers that assemble a plan out of
-- separately-named halves (the transcribe/retain merge and the multi-source
-- load) simply re-run it over the union: two
-- spans of the same line arriving from two different sources are only seen as
-- takes of one line if something numbers them TOGETHER, and the halves were each
-- numbered when they were the only spans for that asset.
-- The per-group sort is a total order (start, then stop, then transcript) so
-- that re-running cannot permute equal-keyed spans and hand them different take
-- numbers than the previous pass did; table.sort is not stable.
function vo.AssignNames(spans, cfg)
  local use_alts         = vo.Opt(cfg, "use_alts_track")
  local suffix           = vo.Opt(cfg, "suffix_alt_names")
  local review_prefix    = vo.Opt(cfg, "review_prefix")
  local unmatched_prefix = vo.Opt(cfg, "unmatched_prefix")
  local snippet_words    = vo.Opt(cfg, "unmatched_snippet_words")
  local max_len          = vo.Opt(cfg, "max_name_length")

  local groups, order = {}, {}
  for _, s in ipairs(spans) do
    if s.kind == "match" and s.asset then
      local g = groups[s.asset]
      if not g then
        g = {}
        groups[s.asset] = g
        order[#order + 1] = s.asset
      end
      g[#g + 1] = s
    end
  end

  for _, asset in ipairs(order) do
    local g = groups[asset]
    table.sort(g, function(a, b)
      if a.start ~= b.start then return a.start < b.start end
      if (a.stop or 0) ~= (b.stop or 0) then return (a.stop or 0) < (b.stop or 0) end
      local at, bt = tostring(a.transcript or ""), tostring(b.transcript or "")
      if at ~= bt then return at < bt end
      return (a.score or 0) < (b.score or 0)
    end)
    for i, s in ipairs(g) do s.take_index = i end

    -- The user's explicit Select IS the primary. Guessing "first" or "last" is
    -- exactly what the Select column exists to stop, so a group of several
    -- takes with no select simply has no primary -- and Cut reports it as
    -- needing a decision rather than picking one.
    --
    -- A group of ONE is the exception: there is nothing to choose between, so
    -- the lone take is primary whether or not it was ticked. Without this a
    -- single unticked take would be routed to Alts and suffixed _tk01, which
    -- is not a decision the user declined to make -- it is one they never had.
    local primary = nil
    if #g == 1 then
      primary = g[1]
    else
      for _, s in ipairs(g) do
        if s.select == true then primary = s; break end
      end
    end
    for _, s in ipairs(g) do s.primary = (s == primary) end
  end

  -- The name the SCRIPT asks this span to be delivered under: the filename plus
  -- whatever the user typed in the Append column. The grouping above still keys
  -- on the raw asset, and must -- two script lines that share a filename are
  -- still two lines, and numbering their takes together would be wrong.
  local function delivered(s)
    if s.deliver ~= nil and s.deliver ~= "" then return s.deliver end
    return s.asset
  end

  for _, s in ipairs(spans) do
    if s.kind == "match" then
      s.dest = (use_alts and not s.primary) and "alts" or "selects"
      if suffix and not s.primary then
        s.name = vo.SanitizeName(
          string.format("%s_tk%02d", delivered(s), s.take_index), max_len)
      else
        s.name = vo.SanitizeName(delivered(s), max_len)
      end

    elseif s.kind == "review" then
      s.dest = "review"
      s.name = vo.SanitizeName(
        string.format("%s%s_s%.2f", review_prefix, delivered(s) or "", s.score or 0),
        max_len)

    else
      -- Unmatched audio (slates, chatter, false starts) is left exactly where it
      -- was recorded. The name below is NOT applied to a take — nothing is cut —
      -- it is the label for this span's row in the report, which is the only
      -- place unmatched audio is flagged. Keep it: it is what makes the
      -- unmatched_prefix / unmatched_snippet_words settings mean anything.
      s.dest = vo.DEST_IN_PLACE
      local words = {}
      for w in tostring(s.transcript or ""):gmatch("%S+") do
        words[#words + 1] = w
        if #words >= snippet_words then break end
      end
      s.name = unmatched_prefix .. vo.SanitizeName(table.concat(words, " "), max_len)
    end
  end

  return spans
end

--------------------------------
-- Pure layer: speech backend
--------------------------------

-- `-dtw` computes token-level timestamps via cross-attention DTW, which
-- sharpens word boundaries. The presets are model-specific and passing an
-- unknown one makes whisper-cli abort, so only the presets confirmed against
-- upstream source are emitted. Anything else (including the .en models) simply
-- runs without DTW — less precise boundaries, but it runs. See SPEC.md §10.
vo.DTW_PRESETS = {
  tiny = "tiny", base = "base", small = "small", medium = "medium",
  ["large-v1"] = "large.v1", ["large-v2"] = "large.v2", ["large-v3"] = "large.v3",
  -- Verified against ggml-org/whisper.cpp v1.9.1 examples/cli/cli.cpp:
  -- params.dtw == "large.v3.turbo" -> WHISPER_AHEADS_LARGE_V3_TURBO.
  ["large-v3-turbo"] = "large.v3.turbo",
}

-- Map a ggml model path to its DTW preset, or nil when there isn't a known one.
function vo.DTWPresetForModel(model_path)
  if not model_path or model_path == "" then return nil end
  local name = model_path:match("([^/\\]+)$") or model_path
  name = name:gsub("%.bin$", ""):gsub("^ggml%-", "")
  return vo.DTW_PRESETS[name:lower()]
end

-- Build the whisper-cli command line.
-- `-ml 1 -sow -ojf` is the load-bearing combination: one word per segment,
-- written as JSON-full — the only output that carries per-token `t_dtw`, the
-- anchor vo.ParseWhisperJSON turns into word.anchor. CSV was used before it
-- was known that `offsets` can miss the word entirely (SPEC-word-anchors.md).
-- whisper.cpp resamples and downmixes internally, so the take's source file is
-- passed straight through — no render step and no ffmpeg.
-- `span`, when given, is { from, to } in source seconds and becomes -ot/-d in
-- whole milliseconds: a gap-repair run decodes only that stretch. whisper's
-- output timestamps include the offset, so the repair CSV parses straight into
-- source time like a full run's.
-- Returns: array of strings (argv, NOT pre-joined).
function vo.BuildWhisperArgv(cfg, audio, out_prefix, span)
  cfg = cfg or {}

  local argv = { cfg.whisper_bin or "whisper-cli" }
  local function add(...)
    for _, v in ipairs({ ... }) do argv[#argv + 1] = v end
  end

  if cfg.whisper_model and cfg.whisper_model ~= "" then
    add("-m", cfg.whisper_model)
  end
  add("-f", audio)
  add("-of", out_prefix)
  add("-ojf")
  add("-ml", "1")  -- one word per segment; also enables token timestamps
  add("-sow")      -- split on word rather than mid-token
  -- Progress prints stay ON (no -np) even though the words are read from the
  -- JSON (-ojf), not stdout: the per-segment "[hh:mm:ss --> hh:mm:ss]  word" lines and
  -- the -pp percentages are the only view into a run that otherwise sits
  -- silent for minutes. The log is captured to a file either way
  -- (vo.RunWhisperAsync), which tails it for vo.LatestWhisperProgress.
  add("-pp")       -- print-progress: "progress = NN%" lines alongside segments
  -- No prior-text conditioning. whisper.cpp feeds each window the text it just
  -- decoded, and on a long read that feedback can lock the decoder into
  -- repeating one phrase for the rest of the file -- confidently, with
  -- plausible timestamps, so nothing downstream can tell it from real speech.
  -- The context is only worth anything for cross-sentence language modelling,
  -- and matching is against a KNOWN script, so we give up nothing to remove it.
  add("-mc", "0")
  -- Discard a window as non-speech only when it is almost certainly not speech.
  -- The default 0.60 threw away 29 seconds of a real read -- four script lines,
  -- at full level, gone with no error anywhere. The trade is not symmetric
  -- here: this is a recording where every second is MEANT to be speech, so an
  -- invented word in a silence costs an unmatched span nobody reads, while a
  -- dropped line costs a line.
  add("-nth", "0.9")

  if span then
    add("-ot", string.format("%d", math.floor((span.from or 0) * 1000 + 0.5)))
    add("-d",  string.format("%d",
        math.floor(((span.to or 0) - (span.from or 0)) * 1000 + 0.5)))
  end

  if cfg.whisper_threads then add("-t", tostring(cfg.whisper_threads)) end
  if cfg.whisper_language and cfg.whisper_language ~= "" then
    add("-l", cfg.whisper_language)
  end

  -- -nfa is paired with -dtw, never emitted alone: flash attention (default
  -- on in v1.9.1) computes attention without ever materialising the matrix
  -- DTW aligns against, so with -fa every t_dtw is silently -1 -- verified
  -- byte-identical output with and without -dtw. A model with no preset gains
  -- no anchors, so it keeps flash attention's speed.
  local preset = vo.DTWPresetForModel(cfg.whisper_model)
  if preset then add("-dtw", preset) add("-nfa") end

  return argv
end

--------------------------------
-- Pure layer: backend acquisition catalogs
--------------------------------

-- Pinned whisper.cpp release. Binary URLs target this tag exactly; bumping it
-- is a deliberate, tested change (a silent asset rename would break downloads).
vo.WHISPER_RELEASE = "v1.9.1"

-- Multilingual, DTW-verified models only. .en variants are excluded because
-- their DTW presets are unverified (VO/SPEC.md §10) and this tool depends on
-- sharp word boundaries. expected_bytes are approximate (well-known ggml sizes)
-- and used only as a truncation floor; the binary sizes below are exact.
vo.MODEL_CATALOG = {
  { name = "base",     filename = "ggml-base.bin",     label = "base (multilingual, ~148 MB)",     expected_bytes = 147951465  },
  { name = "small",    filename = "ggml-small.bin",    label = "small (multilingual, ~488 MB)",    expected_bytes = 487601967  },
  { name = "medium",         filename = "ggml-medium.bin",         label = "medium (multilingual, ~1.5 GB)",           expected_bytes = 1533763059 },
  { name = "large-v3-turbo", filename = "ggml-large-v3-turbo.bin", label = "large-v3-turbo (multilingual, ~1.6 GB)",   expected_bytes = 1624555275 },
  { name = "large-v3",       filename = "ggml-large-v3.bin",       label = "large-v3 (multilingual, ~3.1 GB)",         expected_bytes = 3095033483 },
}

-- Prebuilt CUDA whisper-cli builds from the pinned release. Both bundle their
-- CUDA runtime DLLs and depend only on a recent NVIDIA driver. Sizes verified
-- via the GitHub API.
vo.BINARY_CATALOG = {
  { key = "cuda-12.4", asset = "whisper-cublas-12.4.0-bin-x64.zip", label = "CUDA 12.4 (recommended, ~678 MB)", expected_bytes = 677887125 },
  { key = "cuda-11.8", asset = "whisper-cublas-11.8.0-bin-x64.zip", label = "CUDA 11.8 (older drivers, ~279 MB)", expected_bytes = 278557654 },
}

-- Which catalog entry the configured model IS, by filename. The settings combo
-- used to open on entry 1 whatever was configured, so it named a model the run
-- was not using -- and "Get" beside it offered to download the wrong one.
-- Returns: 1-based index into vo.MODEL_CATALOG, or nil for a model off-catalog.
function vo.ModelCatalogIndex(model_path)
  if not model_path or model_path == "" then return nil end
  local file = (model_path:match("([^/\\]+)$") or model_path):lower()
  for i, m in ipairs(vo.MODEL_CATALOG) do
    if file == m.filename:lower() then return i end
  end
  return nil
end

-- Which binary build the configured whisper-cli belongs to. Each build extracts
-- into a folder named for its key (see the settings downloader), so the key
-- appears as a path component; nothing else in the path can look like one.
-- Returns: 1-based index into vo.BINARY_CATALOG, or nil (a hand-picked exe).
function vo.BinaryCatalogIndex(bin_path)
  if not bin_path or bin_path == "" then return nil end
  local p = bin_path:gsub("\\", "/"):lower()
  for i, b in ipairs(vo.BINARY_CATALOG) do
    if p:find("/" .. b.key:lower() .. "/", 1, true) then return i end
  end
  return nil
end

-- How many decode threads to give whisper-cli, from a LOGICAL core count.
--
-- whisper.cpp scales with PHYSICAL cores and loses to itself past them --
-- hyperthread siblings contend for the same vector units, so asking for every
-- logical core is measurably slower than asking for half of them. Assume the
-- usual two threads per core, keep two logical threads' worth of the machine
-- for REAPER's audio thread and the UI, and never go below 1.
--
-- Capped at 16: beyond that whisper's own scaling has flattened and the extra
-- threads only add contention.
function vo.SuggestThreads(logical)
  logical = tonumber(logical) or 0
  if logical < 1 then return nil end
  local physical = math.floor(logical / 2)
  if physical < 1 then physical = 1 end
  local n = (physical > 2) and (physical - 1) or physical
  if n > 16 then n = 16 end
  return n
end

-- The machine's logical core count, or nil when it cannot be read. Environment
-- first (free, and set on Windows), then one cheap shell call elsewhere.
function vo.CPUCoreCount()
  local n = tonumber(os.getenv("NUMBER_OF_PROCESSORS") or "")
  if n and n >= 1 then return math.floor(n) end
  local ok, pipe = pcall(io.popen, vo.IsWindows() and "echo %NUMBER_OF_PROCESSORS%"
                                                   or "getconf _NPROCESSORS_ONLN")
  if ok and pipe then
    local out = pipe:read("*a") or ""
    pipe:close()
    n = tonumber(out:match("%d+") or "")
    if n and n >= 1 then return math.floor(n) end
  end
  return nil
end

function vo.ModelDownloadURL(name)
  return "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-" .. name .. ".bin"
end

function vo.BinaryDownloadURL(key)
  for _, b in ipairs(vo.BINARY_CATALOG) do
    if b.key == key then
      return "https://github.com/ggml-org/whisper.cpp/releases/download/" ..
             vo.WHISPER_RELEASE .. "/" .. b.asset
    end
  end
  return nil
end

-- Human-readable byte size for the UI.
function vo.FormatBytes(n)
  if not n or n < 0 then return "?" end
  local units = { "B", "KB", "MB", "GB", "TB" }
  local i, v = 1, n
  while v >= 1024 and i < #units do v = v / 1024; i = i + 1 end
  if i == 1 then return string.format("%d %s", v, units[i]) end
  return string.format("%.1f %s", v, units[i])
end

-- Seconds as m:ss, so a time the UI reports can be typed into REAPER's
-- transport and found. Hours only appear once there are hours.
function vo.FormatTime(seconds)
  local s = math.max(0, math.floor((seconds or 0) + 0.5))
  local h, m = math.floor(s / 3600), math.floor(s / 60) % 60
  if h > 0 then return string.format("%d:%02d:%02d", h, m, s % 60) end
  return string.format("%d:%02d", m, s % 60)
end

--------------------------------
-- Pure layer: backend acquisition paths & checks
--------------------------------

-- Downloads live under the plugin's own folder, not loose in the resource
-- root. Given the VO script directory (…/Scripts/<repo>/VO/), return
-- …/Scripts/<repo>/Resources — deriving the repo folder from the install path
-- so the name is never hardcoded (mirrors how PVX derives its venv dir).
-- Pure over the passed directory for unit-testing; the caller supplies its own
-- dir from debug.getinfo.
function vo.PluginResourceRoot(script_dir)
  local dir = (script_dir or ""):gsub("[/\\]+$", "")   -- strip trailing separators
  dir = dir:gsub("[/\\][^/\\]+$", "")                  -- drop the VO segment -> repo root
  return dir .. "/Resources"
end

-- Model/binary storage under the plugin resource root (from PluginResourceRoot).
-- Pure over the injected base so it can be unit-tested.
function vo.ResolveModelsDir(resource_root)
  return (resource_root or "") .. "/whisper-models"
end

function vo.ResolveBinDir(resource_root)
  return (resource_root or "") .. "/whisper-bin"
end

-- A download is valid when it reaches at least ~95% of the expected size. This
-- catches truncated transfers and HTML error pages saved under the target name.
-- With no/zero expected size, any non-empty file passes.
function vo.VerifyDownloadSize(path, expected)
  local actual = vo.FileSize(path)
  if not actual then return false end
  if not expected or expected <= 0 then return actual > 0 end
  return actual >= math.floor(expected * 0.95)
end

-- True when the model file is present in dir. Existence only: download-time
-- VerifyDownloadSize already guards integrity, and re-checking size here would
-- force a multi-GB read every UI frame. Corruption is caught on next use.
function vo.ModelIsInstalled(dir, name)
  return vo.FileExists(dir .. "/ggml-" .. name .. ".bin")
end

-- Find whisper-cli.exe in a flat listing of extracted paths (case-insensitive).
-- Pure over the listing so the caller supplies whatever directory walk it used.
function vo.LocateWhisperCliExe(entries)
  for _, p in ipairs(entries or {}) do
    local base = p:match("[^/\\]+$") or p
    if base:lower() == "whisper-cli.exe" then return p end
  end
  return nil
end

-- Read the active compute backend out of a captured whisper-cli log. whisper
-- only initializes its device when a model loads, so this is fed the log of a
-- real (tiny) run. Keys on "CUDA"; pulls the name from a "Device N: <name>"
-- line. To be confirmed against real output on first run — see VO/SPEC.md §9.
function vo.ParseBackendFromLog(text)
  text = text or ""
  local name = text:match("Device%s+%d+:%s*([^,\r\n]+)")
  if text:find("CUDA") and name then
    return { device = "CUDA", name = name:match("^%s*(.-)%s*$") }
  end
  return { device = "CPU" }
end

-- One line of whisper-cli output, read for how far the decode has got.
-- Two shapes carry progress, and only these two:
--   "[00:07:55.960 --> 00:07:56.360]  some"     one per decoded segment
--   "whisper_print_progress_callback: progress =  35%"   with -pp
-- Returns { seconds = <segment end, in source time> } or { percent = n }, and
-- nil for every other line -- which is most of them (system info, model load).
-- The segment END is taken, not the start: it is the furthest point known to
-- be decoded, and it is what a "decoding 7:56 of 38:44" readout means.
function vo.ParseWhisperProgressLine(line)
  line = tostring(line or "")

  local h, m, s = line:match("%-%->%s*(%d+):(%d+):(%d+%.?%d*)%s*%]")
  if h then
    return { seconds = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) }
  end

  local pct = line:match("progress%s*=%s*(%d+)%s*%%")
  if pct then return { percent = tonumber(pct) } end

  return nil
end

-- Furthest progress in a chunk of whisper-cli log. Last match wins, and the
-- two kinds are tracked separately because they arrive on different lines --
-- a tail that ends mid-way through a run of segment prints still carries the
-- percent from further back.
-- Returns nil when the chunk holds no progress at all.
function vo.LatestWhisperProgress(text)
  local out = nil
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    local p = vo.ParseWhisperProgressLine(line)
    if p then
      out = out or {}
      if p.seconds then out.seconds = p.seconds end
      if p.percent then out.percent = p.percent end
    end
  end
  return out
end

-- "7:56 of 38:44 (20%)" for a progress reading. Percent is computed from the
-- timestamp when the duration is known, because that is the honest number:
-- whisper's own -pp percent counts decode windows, which is close but not the
-- same thing. Falls back to whichever half is available; nil when neither is.
function vo.FormatWhisperProgress(info, duration)
  if not info then return nil end

  local pct = info.percent
  if info.seconds and duration and duration > 0 then
    pct = math.floor(math.min(1, info.seconds / duration) * 100 + 0.5)
  end

  if info.seconds then
    local at = vo.FormatTime(info.seconds)
    if duration and duration > 0 then
      return string.format("%s of %s (%d%%)", at, vo.FormatTime(duration), pct)
    end
    return at
  end

  if pct then return string.format("%d%%", pct) end
  return nil
end

-- The tail of a log, for an error message. Progress lines are dropped first:
-- with prints on, a failing run ends in thousands of segment lines, and a
-- plain tail would show those instead of the error that stopped it.
function vo.LogTailForError(text, max_chars)
  local kept = {}
  for line in tostring(text or ""):gmatch("[^\r\n]+") do
    if not vo.ParseWhisperProgressLine(line) then kept[#kept + 1] = line end
  end
  local out = table.concat(kept, "\n")
  return out:sub(-(max_chars or 1500))
end

--------------------------------
-- Pure layer: plan composition
--------------------------------

-- Match stored words against the script, one source file at a time.
-- Pure: no REAPER, no audio, no I/O.
--
--   transcripts -- array of { path = <source file>, words = <vo.ParseTranscript
--                  words> }, in SOURCE time
--   lines       -- script lines from vo.BuildScriptLines
--   Returns     -- array of { path, spans }, spans in SOURCE time
--
-- Per-source rather than pooled, deliberately: two recordings' words occupy
-- overlapping time ranges in their own files, so pooling them would let the
-- matcher build a span that starts in one recording and ends in another. The
-- index is built once and shared -- it depends only on the script.
--
-- Padding and naming are NOT done here. Padding needs sample access to snap to
-- silence (vo.ApplyPadding + vo.SnapBoundary), and take numbering needs every
-- source at once (vo.BuildOverview). Both belong to the caller, and keeping
-- this function free of them is what lets Overview re-run it on every script
-- change without touching audio.
-- `pins` is a flat list of { asset, source, start, stop } placed by hand; each
-- one applies to the transcript whose path it names. Pins that cannot be
-- resolved come back on the entry as `unresolved` rather than being dropped: a
-- pin that silently does nothing is worse than no pin at all.
function vo.BuildMatch(transcripts, lines, cfg, pins)
  local index = vo.BuildIndex(lines, cfg)
  local out = {}

  local pins_by_source = {}
  for _, p in ipairs(pins or {}) do
    local list = pins_by_source[p.source]
    if not list then
      list = {}
      pins_by_source[p.source] = list
    end
    list[#list + 1] = p
  end

  for _, t in ipairs(transcripts or {}) do
    local tokens     = vo.BuildWordTokens(t.words, cfg)
    local pinned, unresolved = vo.PinnedSpans(tokens, pins_by_source[t.path], lines)
    local candidates = vo.FindCandidates(tokens, lines, index, cfg)
    -- Per source file, because that is the unit a read is performed in.
    local backbone   = vo.BuildBackbone(candidates, cfg)
    local spans      = vo.SelectSpans(candidates, cfg, backbone, pinned)

    -- Give the lines that got nothing a look at the audio nobody claimed.
    for _, s in ipairs(vo.ResidualPass(tokens, lines, spans, cfg, index)) do
      spans[#spans + 1] = s
    end
    table.sort(spans, function(a, b) return a.i0 < b.i0 end)

    local gaps       = vo.FindGaps(tokens, spans)

    local plan = {}
    for _, s in ipairs(spans) do plan[#plan + 1] = s end
    for _, g in ipairs(gaps)  do plan[#plan + 1] = g end
    table.sort(plan, function(a, b)
      if a.i0 ~= b.i0 then return a.i0 < b.i0 end
      return a.i1 < b.i1
    end)

    -- Matched spans need their transcript too, for the table and the report.
    for _, s in ipairs(plan) do
      if not s.transcript then
        local text = {}
        for k = s.i0, s.i1 do text[#text + 1] = tokens[k].text end
        s.transcript = table.concat(text, " ")
      end
    end

    local kept, dropped = vo.DropDegenerateSpans(plan)
    out[#out + 1] = { path = t.path, spans = kept, unresolved = unresolved,
                      degenerate_dropped = dropped }
  end

  return out
end

--------------------------------
-- Pure layer: report
--------------------------------

-- RFC4180 field escaping: quote when the field contains a comma, quote or
-- newline, and double any embedded quotes.
function vo.EscapeCSVField(s)
  s = tostring(s or "")
  if s:find('[",\r\n]') then
    return '"' .. s:gsub('"', '""') .. '"'
  end
  return s
end

function vo.FormatCSVRow(fields)
  local out = {}
  for i, f in ipairs(fields) do out[i] = vo.EscapeCSVField(f) end
  return table.concat(out, ",")
end

-- role=column pairs joined by ";". Kept human-legible because the project file
-- is opened in spreadsheets; the role order matches vo.SerializeLayout.
local function encode_mapping(mapping)
  local out = {}
  for _, role in ipairs({ "asset", "text", "speaker" }) do
    local col = mapping and mapping[role]
    if col and col ~= "" then out[#out + 1] = role .. "=" .. col end
  end
  return table.concat(out, ";")
end

local function decode_mapping(text)
  local mapping = {}
  for pair in tostring(text or ""):gmatch("[^;]+") do
    local role, col = pair:match("^%s*([^=]+)=(.*)$")
    if role then mapping[role:match("^%s*(.-)%s*$")] = col end
  end
  return mapping
end

-- How many distinct tracks a list of items sits on. vo.ApplyPlan resolves every
-- span against ONE source track, so a cut over items spanning two tracks would
-- either fail loudly (sequential takes) or -- worse -- silently resolve track 2's
-- spans onto track 1's items (simultaneous boom + lav takes). The dialog gates
-- Cut on this being 1; transcription across several tracks stays fine.
function vo.DistinctTrackCount(items)
  -- Keyed by tostring, not by the value itself: a MediaTrack* comes back from
  -- the API as userdata, and identity as a TABLE KEY depends on REAPER handing
  -- back the same object rather than a fresh wrapper around the same pointer.
  -- tostring gives "(MediaTrack*)0x…", which is the pointer either way.
  local seen, n = {}, 0
  for _, item in ipairs(items or {}) do
    if item.track ~= nil then
      local key = tostring(item.track)
      if not seen[key] then
        seen[key] = true
        n = n + 1
      end
    end
  end
  return n
end


--------------------------------
-- Pure layer: subprocess exit code
--------------------------------

-- Read an exit code out of the launcher's done-file contents.
--
-- Returns a NUMBER when the launcher has written one, and nil for "not
-- finished yet" -- including an empty file, which is the state `> done.txt`
-- leaves behind between creating the file and writing into it. The poll loop
-- opens that file at frame rate, so it WILL sometimes catch it empty.
--
-- The distinction is the whole point. Reading an empty file as -1 told the
-- user "whisper-cli exited with code -1" about a run that had not started
-- failing, and on a real session that message cost the first 30 seconds of a
-- read: the gap repair that would have recovered it was recorded as a failure
-- while the process it launched went on to succeed unheard.
function vo.ParseExitFile(text)
  if type(text) ~= "string" then return nil end
  local line = text:match("^[^\r\n]*") or ""
  return tonumber((line:gsub("^%s+", ""):gsub("%s+$", "")))
end

--------------------------------
-- Pure layer: shell quoting
--------------------------------

-- Quote a single argv entry for the platform shell.
-- Deliberately duplicated from pvx.QuoteArg rather than shared: SPEC.md §11
-- keeps the subprocess plumbing per-tool until both are exercised in REAPER.
function vo.QuoteArg(s, os_name)
  s = tostring(s or "")
  if os_name == "Windows" then
    s = s:gsub('"', '\\"')
    return '"' .. s .. '"'
  end
  s = s:gsub("'", "'\\''")
  return "'" .. s .. "'"
end

--------------------------------
-- Pure layer: transcription cache key
--------------------------------

-- Key a cached transcript by everything that could change its content: the
-- source file (path and size), the model, and the decode parameters. Threshold
-- changes deliberately do NOT invalidate it — re-running after tuning a
-- threshold is what the cache is for.
-- Returns: a short filename-safe string.
function vo.CacheKey(source_path, file_size, cfg)
  local material = table.concat({
    tostring(source_path or ""),
    tostring(file_size or 0),
    tostring(cfg and cfg.whisper_model or ""),
    tostring(cfg and cfg.whisper_language or ""),
    tostring(vo.DTWPresetForModel(cfg and cfg.whisper_model) or ""),
  }, "\0")

  -- FNV-1a, 32-bit. Not cryptographic — this only needs to change when the
  -- inputs change, and collisions merely cost a re-transcription.
  local hash = 2166136261
  for i = 1, #material do
    hash = hash ~ material:byte(i)
    hash = (hash * 16777619) & 0xFFFFFFFF
  end

  return string.format("vo_%08x", hash)
end

--------------------------------
-- Pure layer: file paths and time base
--------------------------------

-- Only the final extension is stripped, and the character class excludes path
-- separators so a dot in a directory name cannot be mistaken for one.
local function strip_ext(path)
  return (tostring(path):gsub("%.[^%.\\/]*$", ""))
end

-- The trailing path component, either separator. Used as the PORTABLE half of a
-- tracker key: a project that moves to another drive keeps its basenames even
-- though every full path changed.
local function basename(path)
  return (tostring(path or ""):match("[^\\/]*$")) or ""
end

vo.Basename = basename

-- The project file lives beside the project: Session.rpp -> Session_vo.csv.
-- One per project, not one per source: it holds the user's own work (selects,
-- verified marks, notes, renames) plus the script it is all about. Unlike a
-- transcript it is never regenerated from audio.
function vo.ProjectFilePath(project_path)
  if not project_path or project_path == "" then return nil end
  return strip_ext(project_path) .. "_vo.csv"
end

-- Exact inverses of the arithmetic in vo.MapWordsToProject. A transcript lives
-- next to the audio, so it must store times the audio file itself can vouch
-- for; the item's position, trim and playrate belong to the project, not the
-- recording.
local function safe_playrate(item)
  local pr = item and item.playrate or 1.0
  if pr <= 0 then pr = 1.0 end
  return pr
end

function vo.ProjectTimeToSource(t, item)
  return (t - ((item and item.pos) or 0)) * safe_playrate(item)
       + ((item and item.start_offs) or 0)
end

function vo.SourceTimeToProject(t, item)
  return ((item and item.pos) or 0)
       + (t - ((item and item.start_offs) or 0)) / safe_playrate(item)
end

-- The SOURCE-TIME stretch of a media source that a list of items actually
-- plays: one range per item, in the same time base the transcript uses. A span
-- outside every one of these ranges has no audio behind it in this project --
-- the item was trimmed after transcription -- and Cut drops it rather than
-- cutting silence. All items passed in are expected to reference the same
-- source file; the caller groups them.
-- Defined HERE, below safe_playrate: it is a plain file local, so a definition
-- above it would resolve the name as a nil global and only fail inside REAPER.
function vo.SourceCoverageRanges(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    local from = item.start_offs or 0
    local to   = from + (item.length or 0) * safe_playrate(item)
    out[#out + 1] = { from = from, to = to }
  end
  return out
end

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

-- The clumps that are actually a SPLIT LINE: two or more items carrying the
-- same line assignment.
--
-- Contiguity alone cannot answer this. A correct cut splits at markers that
-- abut exactly, so its output is a run of items touching in project AND source
-- time -- indistinguishable, by geometry, from the damage this verb repairs. A
-- report keyed on geometry would therefore flag every healthy session forever,
-- and a warning that is always on is not a warning.
--
-- What separates them is the ASSIGNMENT. Two contiguous items that are two
-- different lines are a normal cut; two contiguous items claiming ONE line are
-- that line broken in half, which is the whole complaint. The name is the
-- assignment (vo-name-is-the-assignment), so a repeated name is the signal.
--
-- Blank names never match each other: an unnamed item is undecided, not
-- claimed, and two undecided items are not evidence of anything.
function vo.ClumpsSharingALine(clumps)
  local out = {}
  for _, clump in ipairs(clumps or {}) do
    if #clump > 1 then
      local seen, shared = {}, false
      for _, info in ipairs(clump) do
        local nm = info.name
        if nm and nm ~= "" then
          if seen[nm] then shared = true end
          seen[nm] = true
        end
      end
      if shared then out[#out + 1] = clump end
    end
  end
  return out
end

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

-- djb2 over the words whose midpoint falls inside [from, to]. The hash keys
-- the vetted fingerprint to the transcript content under one item, so a
-- gap-repair merge elsewhere in the file cannot invalidate this item.
--
-- DELIBERATELY the midpoint rule, not the anchor rule the judges use
-- (2026-08-14 sweep): a fingerprint only needs to be SELF-consistent --
-- stamp-write and recompute agree -- and switching the rule would falsify
-- every stamp in every project at once, unchecking every Vet and OK for no
-- gain in honesty. Do not "fix" this to WordsInRange casually.
function vo.WordsHash(words, from, to)
  local h = 5381
  for _, w in ipairs(words or {}) do
    -- Sidecar word lists are sorted by t0 (SerializeTranscript writes them in
    -- order; MergeRepairWords re-sorts), so once a word starts past the span
    -- nothing later can have its midpoint inside it. Without this break the
    -- rebuild's stamp recompute rescans a long recording's ENTIRE transcript
    -- once per stamped row, on every project state change.
    if (w.t0 or 0) > to + 1e-6 then break end
    local mid = ((w.t0 or 0) + (w.t1 or 0)) / 2
    if mid >= from - 1e-6 and mid <= to + 1e-6 then
      local s = string.format("%s@%.2f", w.text or "", w.t0 or 0)
      for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    end
  end
  return string.format("%08x", h)
end

-- The vetted stamp's value: everything the machine judged, quantised so float
-- formatting cannot fake a mismatch. Compared whole, never parsed. Checked =
-- stored stamp equals a fresh recompute; any edit to the item, marker, name
-- or words falsifies the equality, which is the whole invalidation story.
function vo.VettedFingerprint(fp)
  local rate = fp.playrate or 1.0
  if rate <= 0 then rate = 1.0 end
  local from = fp.start_offs or 0
  local to = from + (fp.length or 0) * rate
  local q = function(x) return x and string.format("%.4f", x) or "-" end
  local path = (fp.source_path or ""):lower():gsub("\\", "/")
  return table.concat({
    "v1", path, q(from), q(fp.length), q(rate),
    fp.take_name or "", q(fp.mk_pos), q(fp.mk_len),
    vo.WordsHash(fp.words, from, to),
  }, "|")
end

-- Every Verify tunable in one place, so tuning is one edit.
vo.VERIFY_THRESH = {
  stale_ratio = 0.20, -- CompareWords: edit-distance ratio above this = stale
  match       = 0.72, -- JudgeLine: named-line score at/above this = match
  reject      = 0.45, -- JudgeLine: named-line score below this may lose to a rival
  margin      = 0.15, -- JudgeLine: rival must beat the named line by this much
  pad         = 0.25, -- PlanVerify: seconds of span padding for edge words
  thin_cover  = 0.40, -- ScanSuspects: word coverage below this fraction = thin
}

function vo.NormalizeTokens(words)
  local out = {}
  for _, w in ipairs(words or {}) do
    local t = (w.text or ""):lower():gsub("[^%w']", "")
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end

-- Fresh decode vs stored transcript: is the sidecar still describing this
-- audio? Whisper's run-to-run jitter (case, punctuation, the odd token) must
-- not read as staleness -- only a real divergence may trigger a merge.
function vo.CompareWords(fresh, stored, thresh)
  local a, b = vo.NormalizeTokens(fresh), vo.NormalizeTokens(stored)
  if #a == 0 and #b == 0 then return { same = true, ratio = 0 } end
  if #a == 0 or #b == 0 then return { same = false, ratio = 1 } end
  -- Token-level Levenshtein, same shape as the char-level one FindSpanLines uses.
  local prev = {}
  for j = 0, #b do prev[j] = j end
  for i = 1, #a do
    local cur = { [0] = i }
    for j = 1, #b do
      local cost = (a[i] == b[j]) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  local ratio = prev[#b] / math.max(#a, #b)
  return { same = ratio <= (thresh or vo.VERIFY_THRESH).stale_ratio, ratio = ratio }
end

-- Which line do these words actually say? Verify's second comparison.
-- "wrong" needs a clear rival: a low named score alone is only "unsure",
-- because moving an item on a hunch is worse than leaving a flag.
function vo.JudgeLine(fresh_words, lines, named_asset, cfg, thresh)
  local T = thresh or vo.VERIFY_THRESH
  local toks = vo.NormalizeTokens(fresh_words)
  local text = table.concat(toks, " ")
  local hits = vo.FindSpanLines(lines or {}, text, cfg or {}, { floor = 0, limit = 8 })
  local named_score, best_other = 0, nil
  for _, h in ipairs(hits) do
    if h.asset == named_asset then
      if h.score > named_score then named_score = h.score end
    elseif not best_other or h.score > best_other.score then
      best_other = h
    end
  end
  if named_score >= T.match then return { verdict = "match", named_score = named_score } end
  if best_other and best_other.score >= T.match
     and named_score < T.reject
     and best_other.score - named_score >= T.margin then
    return { verdict = "wrong", named_score = named_score, best = best_other }
  end
  return { verdict = "unsure", named_score = named_score }
end

-- What the Verify queue will decode: one entry per deliverable row, span
-- padded so edge words are not clipped, grouped per source file.
function vo.PlanVerify(rows, thresh)
  local T = thresh or vo.VERIFY_THRESH
  local out = {}
  for _, row in ipairs(rows or {}) do
    if row.status ~= "orphan" and row.item and row.source_path
       and row.source_start and row.source_stop then
      out[#out + 1] = {
        uid = row.uid, asset = row.asset, item = row.item,
        take_name = row.take_name, source_path = row.source_path,
        span = { from = math.max(0, row.source_start - T.pad),
                 to = row.source_stop + T.pad },
        mk_pos = row.marker_pos, mk_len = row.marker_len,
        locked = row.user_status == "verified",  -- Lock; the machine may not move it
      }
    end
  end
  table.sort(out, function(a, b)
    if a.source_path ~= b.source_path then return a.source_path < b.source_path end
    return a.span.from < b.span.from
  end)
  return out
end

local function words_within(words, from, to)
  local out = {}
  for _, w in ipairs(words or {}) do
    local mid = ((w.t0 or 0) + (w.t1 or 0)) / 2
    if mid >= from - 1e-6 and mid <= to + 1e-6 then out[#out + 1] = w end
  end
  return out
end

-- Exposed for the Verify driver: whisper decodes a full 30-second window no
-- matter how short -d says the span is, so a span decode comes back carrying
-- every take that follows the item. Fresh words MUST be clipped to the span
-- before any comparison, or one take is judged against five takes' words.
vo.WordsWithin = words_within

-- The line a take should be judged against: the one its NAME claims. The
-- name is the assignment; the marker's line (fallback_asset) is only the
-- answer for a take with no name at all. Shared by Verify's judge and the
-- Suspects scan so neither can regress to judging the marker's line -- the
-- bug that let a misnamed take pass as clear (commit 32c68c6).
function vo.NamedAssetOf(take_name, fallback_asset, lines, cfg)
  if not take_name or take_name == "" then return fallback_asset end
  local base = vo.StripAltSuffix(take_name, (cfg or {}).alt_append_pattern)
               or take_name
  local at = vo.ResolveItemName(vo.BuildNameIndex(lines or {}), base)
  return at and ((lines or {})[at] or {}).asset or base
end

-- The free hunt: no whisper, stored data only. Report-only by contract --
-- the caller decides what to do with the list.
function vo.ScanSuspects(rows, transcripts, lines, cfg, thresh)
  local T = thresh or vo.VERIFY_THRESH
  local by_path = {}
  for _, t in ipairs(transcripts or {}) do by_path[t.path] = t.words end
  local out = {}
  for _, row in ipairs(rows or {}) do
    if row.status ~= "orphan" and row.item and row.source_path
       and row.source_start and row.source_stop then
      local trig = {}
      -- Anchor rule, the same one the sheet displays by -- ScanSuspects
      -- judges STORED words, and the midpoint rule flagged (or cleared)
      -- takes on a displaced window's text the sheet never showed.
      local words = vo.WordsInRange(by_path[row.source_path],
                                    row.source_start, row.source_stop)
      local span = row.source_stop - row.source_start
      local covered = 0
      for _, w in ipairs(words) do covered = covered + ((w.t1 or 0) - (w.t0 or 0)) end
      -- Independent, not elseif: a row can be thin AND misnamed, and the
      -- panel promises to show every trigger that fired.
      if span > 0 and covered / span < T.thin_cover then
        trig.thin = true
      end
      if #words > 0 then
        -- Judged against the NAME's line, not the marker's: a misnamed take
        -- over a correct marker is exactly what this trigger exists to catch.
        --
        -- UNLESS the human already judged it. A live OK (confirmed_state
        -- "ok") is the user having looked at this exact state and said
        -- "this read IS this line" -- re-flagging it every scan would make
        -- the confirmation meaningless. The words are left as heard; only
        -- the verdict is overridden. Any edit falsifies the fingerprint
        -- and the trigger comes back.
        local v = vo.JudgeLine(words, lines,
          vo.NamedAssetOf(row.take_name, row.asset, lines, cfg), cfg, T)
        if v.verdict ~= "match" and row.confirmed_state ~= "ok" then
          trig.name_mismatch = true
        end
      end
      if not row.marker_id then trig.unmarked = true end
      if row.vetted_state == "mismatch"
         or row.confirmed_state == "mismatch" then trig.stamp = true end
      if next(trig) then out[#out + 1] = { row = row, triggers = trig } end
    end
  end
  return out
end

vo.VETTED_EXT = "P_EXT:ajsfx_vo_vetted"

-- The HUMAN's mark, on its own key: "I checked, this read IS this line."
-- Deliberately NOT a flavour of the Vet stamp -- Vet is the machine's
-- verdict and OK is the user's, two different facts that can disagree, so
-- they are two boxes and two keys. Same fingerprint format though: an OK
-- self-clears on any edit exactly like a Vet, because a confirmation that
-- outlives the state the user actually looked at is a lie.
vo.CONFIRMED_EXT = "P_EXT:ajsfx_vo_confirmed"

function vo.ReadVetted(item)
  local ok, v = r.GetSetMediaItemInfo_String(item, vo.VETTED_EXT, "", false)
  if ok and v ~= "" then return v end
  return nil
end

function vo.WriteVetted(item, fp_string)
  r.GetSetMediaItemInfo_String(item, vo.VETTED_EXT, fp_string or "", true)
end

function vo.ReadConfirmed(item)
  local ok, v = r.GetSetMediaItemInfo_String(item, vo.CONFIRMED_EXT, "", false)
  if ok and v ~= "" then return v end
  return nil
end

function vo.WriteConfirmed(item, fp_string)
  r.GetSetMediaItemInfo_String(item, vo.CONFIRMED_EXT, fp_string or "", true)
end

-- Merge overlapping/touching source ranges into the fewest that cover the same
-- audio, in time order. Input may be in any order and may overlap; the ranges
-- come from items scattered across the project, so neither is a safe assumption.
function vo.MergeRanges(ranges)
  local sorted = {}
  for _, g in ipairs(ranges or {}) do
    local from, to = g.from or g.start or 0, g.to or g.stop or 0
    if to > from then sorted[#sorted + 1] = { from = from, to = to } end
  end
  table.sort(sorted, function(a, b) return a.from < b.from end)
  local out = {}
  for _, g in ipairs(sorted) do
    local last = out[#out]
    if last and g.from <= last.to then
      if g.to > last.to then last.to = g.to end
    else
      out[#out + 1] = { from = g.from, to = g.to }
    end
  end
  return out
end

-- ONE ITEM, ONE TAKE PER LINE: markers inside a single item that name the SAME
-- asset are one take seen twice, and the one covering more of the item wins.
--
-- The gap this closes, measured on a real clip: two markers for
-- "..._Trying", 0.385s and 1.875s, ADJACENT and not overlapping at all. The
-- existing dedupe (vo.marker_same_take) merges markers that overlap by 80% of
-- the shorter, so at zero overlap it correctly concluded they were two
-- different takes and left both -- which left the item with no single range to
-- trim onto, and a note saying so instead of a fix.
--
-- Overlap is the wrong question between markers that are already inside one
-- item. Two takes of one line cannot both be in one clip: cutting is what puts
-- each take in its own item, so a second marker for the same line here is
-- residue -- REAPER's split copying the set into both halves, or a re-mark
-- landing beside the old one -- not a second performance.
--
-- Only ever within one asset. Two markers naming DIFFERENT lines in one item is
-- an uncut recording holding two takes, which is the normal state of a session
-- before the cut and must never be pruned.
--
-- markers: { { start, stop, asset, id } }. cov: the item's { from, to } source
-- window. Returns keep, dropped -- both arrays, keep in the given order.
function vo.PlanSameAssetPrune(markers, cov)
  local function inside(mk)
    if not cov then return (mk.stop or 0) - (mk.start or 0) end
    local o = math.min(mk.stop or 0, cov.to or 0) - math.max(mk.start or 0, cov.from or 0)
    return (o > 0) and o or 0
  end

  local best = {}
  for _, mk in ipairs(markers or {}) do
    if mk.asset and mk.asset ~= "" then
      local cur = best[mk.asset]
      -- Ties break on the LONGER marker, then on nothing at all: a stable
      -- first-wins, so the same item pruned twice keeps the same id and the
      -- marks filed under it survive a second press.
      if not cur
         or inside(mk) > inside(cur)
         or (inside(mk) == inside(cur)
             and (mk.stop - mk.start) > (cur.stop - cur.start)) then
        best[mk.asset] = mk
      end
    end
  end

  local keep, dropped = {}, {}
  for _, mk in ipairs(markers or {}) do
    if not mk.asset or mk.asset == "" or best[mk.asset] == mk then
      keep[#keep + 1] = mk
    else
      dropped[#dropped + 1] = mk
    end
  end
  return keep, dropped
end

-- SPEECH THE PROJECT NO LONGER HOLDS: stretches of a source where the
-- transcript has words but no item in the project plays them.
--
-- This is the reverse of every other check in the tool. Those all start from
-- what the project contains and ask whether it is right; this one starts from
-- the RECORDING and asks what the project lost. Nothing else can, because
-- everything the tool knows about a take -- its marker, its name, its row --
-- lives on the item, so an item that is gone takes its own evidence with it.
-- The transcript is the only record that outlives the timeline, which is what
-- makes it the thing to ask.
--
-- A word counts as present when at least half of it is covered. Half, not "any
-- overlap" and not "all of it": a word straddling an item edge must not read as
-- missing (that would restore a sliver beside every clip), and a word barely
-- clipped by a neighbour must not read as present (that would leave the read it
-- belongs to unrecoverable).
--
-- Runs of missing words become one range each, padded and then CLAMPED to the
-- covered audio either side. Clamping rather than overlapping is the one place
-- this verb is not generous: a restored item that laps over its neighbour puts
-- two items on the same audio, and the whole tool reasons about a take through
-- the item covering it. Butted up against them instead, the union is continuous
-- and every stage sees each stretch exactly once.
--
-- covered: source ranges the project already plays, { from, to }, any order.
-- words:   the source's transcript words, { t0, t1, text }.
-- Returns: array of { from, to, text, count } in time order.
function vo.MissingAudioGaps(covered, words, min_gap, pad)
  min_gap = min_gap or 0.20
  pad     = pad or 0.25
  local held = vo.MergeRanges(covered)

  local function covered_fraction(t0, t1)
    local len = t1 - t0
    if len <= 0 then return 1.0 end
    local hit = 0.0
    for _, g in ipairs(held) do
      local o = math.min(g.to, t1) - math.max(g.from, t0)
      if o > 0 then hit = hit + o end
    end
    return hit / len
  end

  -- Where the padding has to stop on each side: the covered audio nearest the
  -- RUN, not nearest the padded edge. Measuring from the padded edge asks the
  -- wrong question -- pad far enough and it steps clean over a whole covered
  -- range and finds the one beyond, which is how a 5-second pad landed inside
  -- an item instead of butting against it.
  local function clamp_low(t, anchor)
    local best = -math.huge
    for _, g in ipairs(held) do
      if g.to <= anchor and g.to > best then best = g.to end
    end
    return (best > -math.huge) and math.max(t, best) or t
  end
  local function clamp_high(t, anchor)
    local best = math.huge
    for _, g in ipairs(held) do
      if g.from >= anchor and g.from < best then best = g.from end
    end
    return (best < math.huge) and math.min(t, best) or t
  end

  local out, run = {}, nil
  local function close_run()
    if not run then return end
    local from = clamp_low(run.from - pad, run.from)
    local to   = clamp_high(run.to + pad, run.to)
    if to - from >= min_gap then
      out[#out + 1] = { from = from, to = to,
                        text = table.concat(run.text, " "), count = #run.text }
    end
    run = nil
  end

  for _, w in ipairs(words or {}) do
    local t0, t1 = w.t0 or 0, w.t1 or 0
    if t1 > t0 and covered_fraction(t0, t1) < 0.5 then
      -- Two missing words with an ITEM between them are two lost stretches,
      -- not one. Only a covered word closed a run before, so a hole either
      -- side of a surviving clip came back as a single range straddling it --
      -- and restoring that would have laid an item over the clip.
      if run and t0 > run.to and covered_fraction(run.to, t0) > 0 then
        close_run()
      end
      if not run then run = { from = t0, to = t1, text = {} } end
      run.to = math.max(run.to, t1)
      run.text[#run.text + 1] = tostring(w.text or "")
    else
      close_run()
    end
  end
  close_run()
  return out
end

-- Where an item has to sit to show exactly one stretch of its source.
--
-- The other direction from vo.SourceCoverageRanges: given the SOURCE range you
-- want visible, work out the item's position, length and start offset. This is
-- what "trim the item to its take marker" is -- the marker says which audio the
-- take is, and the item is moved and resized to show that and nothing else.
--
-- The audio stays where it is in the project: the same source sample sits at
-- the same project time before and after, because the position moves by exactly
-- the amount the start offset does (scaled by playrate). Trimming the head is
-- not a nudge left, it is a nudge right by the amount removed.
--
-- Returns nil for a range with no length, which is a marker worth reporting
-- rather than acting on.
function vo.PlanTrimToRange(item, from, to)
  if not (item and from and to) or to <= from then return nil end
  local rate = safe_playrate(item)
  return {
    pos        = (item.pos or 0) + (from - (item.start_offs or 0)) / rate,
    length     = (to - from) / rate,
    start_offs = from,
  }
end

--------------------------------
-- Pure layer: the transcript sidecar
--------------------------------

-- WORDS, not spans. A recording's transcription is a fact about the audio and
-- nothing else: no script, no mapping, no match. Storing whisper's own segment
-- grouping would store its guess at where lines divide, and the script -- not
-- the recogniser -- is what says that. `-ml 1` makes every whisper segment one
-- word anyway, so there is no grouping left to store.

vo.TRANSCRIPT_MARKER  = "ajsfx VO Transcript"
-- Version 2 added the Anchor column (SPEC-word-anchors.md). Matching is
-- exact, so v1 sidecars read as unsupported and the Sources window offers the
-- re-transcribe -- deliberate: an anchor-less transcript reproduces exactly
-- the "wrong words under a take" bug that anchors exist to kill.
vo.TRANSCRIPT_VERSION = 2
vo.TRANSCRIPT_HEADER  = { "Start", "End", "Text", "Anchor" }

function vo.TranscriptPath(source_path)
  if not source_path or source_path == "" then return nil end
  return strip_ext(source_path) .. "_vo_transcript.csv"
end

-- `words` are in SOURCE time, as vo.ParseWhisperJSON produces them. This
-- function converts nothing, so it cannot silently write project times.
-- Anchor is empty, not 0.000, when a word has none: zero is a real time.
function vo.SerializeTranscript(words, meta)
  meta = meta or {}
  local out = {
    vo.FormatCSVRow({ vo.TRANSCRIPT_MARKER, tostring(vo.TRANSCRIPT_VERSION) }),
    vo.FormatCSVRow({ "Source",       meta.source or "" }),
    vo.FormatCSVRow({ "Source bytes", tostring(meta.source_bytes or 0) }),
    vo.FormatCSVRow({ "Source hash",  meta.source_hash or "" }),
    vo.FormatCSVRow({ "Backend",      meta.backend or "" }),
    vo.FormatCSVRow({ "Model",        meta.model or "" }),
    vo.FormatCSVRow({ "Language",     meta.language or "" }),
    "",
    vo.FormatCSVRow(vo.TRANSCRIPT_HEADER),
  }
  for _, w in ipairs(words or {}) do
    out[#out + 1] = vo.FormatCSVRow({
      string.format("%.3f", w.t0 or 0),
      string.format("%.3f", w.t1 or 0),
      w.text or "",
      w.anchor and string.format("%.3f", w.anchor) or "",
    })
  end
  return table.concat(out, "\n") .. "\n"
end

function vo.ParseTranscript(text)
  if type(text) ~= "string" or text == "" then
    return nil, "The transcript file is empty."
  end

  local rows = vo.ParseCSV(text)
  if not rows[1] or rows[1][1] ~= vo.TRANSCRIPT_MARKER then
    return nil, "Not an " .. vo.TRANSCRIPT_MARKER .. " file."
  end

  local version = tonumber(rows[1][2] or "")
  if version ~= vo.TRANSCRIPT_VERSION then
    return nil, "Unsupported transcript version: " .. tostring(rows[1][2])
  end

  local parsed = { version = version, source = "", source_bytes = 0,
                   source_hash = "", backend = "", model = "", language = "",
                   words = {} }

  local i, header_at = 2, nil
  while rows[i] do
    local key = rows[i][1] or ""
    if key == vo.TRANSCRIPT_HEADER[1] then header_at = i; break end
    if     key == "Source"       then parsed.source       = rows[i][2] or ""
    elseif key == "Source bytes" then parsed.source_bytes = tonumber(rows[i][2] or "") or 0
    elseif key == "Source hash"  then parsed.source_hash  = rows[i][2] or ""
    elseif key == "Backend"      then parsed.backend      = rows[i][2] or ""
    elseif key == "Model"        then parsed.model        = rows[i][2] or ""
    elseif key == "Language"     then parsed.language     = rows[i][2] or ""
    end
    i = i + 1
  end

  if not header_at then
    return nil, "The transcript has no word header row."
  end

  for j = header_at + 1, #rows do
    local row = rows[j]
    local t0, t1 = tonumber(row[1] or ""), tonumber(row[2] or "")
    if t0 and t1 then
      parsed.words[#parsed.words + 1] = { t0 = t0, t1 = t1, text = row[3] or "",
                                          anchor = tonumber(row[4] or "") }
    end
  end

  return parsed
end

-- Reassemble a transcript's one-word-per-row storage into display prose.
--
-- Display only. Nothing here is stored, and matching never sees it: `-ml 1`
-- destroyed whisper's own sentence grouping, and the SCRIPT is what says where
-- lines divide anyway. This is purely a reading aid for the detail panel.
--
-- Words are grouped where the reader PAUSED: a break after any word followed
-- by `min_pause` seconds of nothing (default vo.PARAGRAPH_PAUSE).
--
-- It used to break on sentence punctuation, and that was actively misleading.
-- The panel showed `Do not tell master, not do tell master, do not tell
-- master.` as one line and `on an island like this, on an island like this,
-- on an island like this one...` as another, which reads like the transcript
-- found long sentences. It did not: those are a reader going again, and again,
-- and the punctuation whisper hung on them is a guess. Presenting a guess as
-- structure invites the user to blame the transcript for damage that is not
-- there.
--
-- A pause is the one boundary in this data that came from the performance
-- rather than from the recognizer. It is still DISPLAY ONLY -- nothing is
-- stored, and matching never sees it; the SCRIPT is what says where lines
-- divide.
--
-- Caveat worth knowing: whisper stretches each word's end to the next word's
-- start, so most gaps read as exactly zero and only real pauses survive. That
-- is precisely why this works, and also why the breaks are sparser than the
-- pauses a listener hears.
--
-- Returns: array of paragraphs, each an array of the original word tables (so
-- a caller needing per-word timing -- the detail panel's word interaction --
-- can index into the same objects vo.Paragraphs summarizes).
vo.PARAGRAPH_PAUSE = 0.35

function vo.ParagraphWords(words, min_pause)
  min_pause = min_pause or vo.PARAGRAPH_PAUSE
  local paras, current = {}, {}
  local list = words or {}
  for i, w in ipairs(list) do
    current[#current + 1] = w
    local nxt = list[i + 1]
    local gap = (nxt and w.t1 and nxt.t0) and (nxt.t0 - w.t1) or nil
    if gap and gap >= min_pause then
      paras[#paras + 1] = current
      current = {}
    end
  end
  if #current > 0 then paras[#paras + 1] = current end
  return paras
end

-- vo.ParagraphWords, joined to display prose. Returns: array of paragraph
-- strings.
function vo.Paragraphs(words, min_pause)
  local out = {}
  for _, para in ipairs(vo.ParagraphWords(words, min_pause)) do
    local texts = {}
    for _, w in ipairs(para) do texts[#texts + 1] = w.text end
    out[#out + 1] = table.concat(texts, " ")
  end
  return out
end

--------------------------------
-- Pure layer: the project file
--------------------------------

-- The project file holds the one kind of data in this tool that CANNOT be
-- recomputed: what the user did. Selects, verified checkmarks, notes and
-- delivery-name overrides are judgements ABOUT audio, not facts derived FROM
-- it, so they live in their own file. Re-transcribing a recording rewrites its
-- transcript wholesale; it must not cost the user a single checkmark. That
-- separation is the whole reason this format exists rather than more columns
-- on the transcript.
--
-- It also carries the script CSV path and the column mapping, which used to
-- live in ProjExtState. A project's VO state is now one file, and moving the
-- project moves it.

vo.PROJECT_MARKER  = "ajsfx VO Project"
vo.PROJECT_VERSION = 1

vo.PROJECT_HEADER = {
  "Key", "Filename", "Source", "Source start", "Select", "Status",
  "Name override", "Notes", "Keep",
}

-- Statuses the USER sets. Derived statuses (missing/recorded/review/orphan) are
-- computed from the transcripts every time and are deliberately never stored.
-- Select is NOT one of these: a take can be both selected and flagged, so it
-- gets its own column rather than competing for this one.
vo.TRACKER_STATUSES = { verified = true, flagged = true }

-- How far a span may move and still be recognised as "the same take". A
-- re-transcription nudging a boundary by a few tens of milliseconds is the
-- normal case and must keep its checkmark; half a second is well past any
-- boundary jitter and into "this is a different piece of audio" territory.
vo.TRACKER_REMATCH_TOLERANCE = 0.5

-- Portable half of a row's identity. Basename rather than full path so a project
-- that moves drives keeps its marks; full-path disambiguation happens in the
-- lookup below, which tries the exact path first. Milliseconds, rounded, because
-- the transcript itself only stores 3 decimal places.
function vo.OverviewKey(source_path, source_start, asset)
  if not source_path or source_path == "" then
    return "|" .. tostring(asset or "")
  end
  return basename(source_path) .. "|"
       .. string.format("%d", math.floor((source_start or 0) * 1000 + 0.5))
end

-- A PLANNED take: a row the user added before any audio exists for it, to hang
-- notes and marks on until an item is linked. Every other row is DERIVED --
-- from a span or from an item's name -- so a planned row can only live in the
-- project file, and the key prefix is what says so: it is why the entry
-- survives serialization with no other work on it, why index_tracker keeps it
-- out of the line-marks bucket, and how BuildOverview knows to grow a row from
-- it. `id` only needs to be unique within the project file (the caller uses a
-- GUID).
vo.PLANNED_PREFIX = "planned|"

function vo.PlannedKey(asset, id)
  return vo.PLANNED_PREFIX .. tostring(asset or "") .. "|" .. tostring(id or "")
end

function vo.IsPlannedKey(key)
  return type(key) == "string"
     and key:sub(1, #vo.PLANNED_PREFIX) == vo.PLANNED_PREFIX
end

-- Marks are TRI-STATE in the file: "yes", "no", or empty.
--
-- Empty means "no opinion", which is what lets an item's TRACK speak for it
-- (vo.EffectiveMarks). That makes an explicit "no" load-bearing: without a way
-- to say it, un-ticking a take whose item sits on Selects would be re-ticked by
-- the track on the very next rebuild and the un-tick would spring back.
local function mark_to_field(v)
  if v == true  then return "yes" end
  if v == false then return "no"  end
  return ""
end

local function field_to_mark(v)
  v = fold(v or "")
  if v == "yes" then return true  end
  if v == "no"  then return false end
  return nil
end

-- `meta` carries the script side of a project's VO state:
-- { scripts = { { path, mapping, enabled }, ... }, appends = { ... }, pins = { ... } }.
-- It lives here rather than in ProjExtState so the project file is the WHOLE of
-- a project's VO state.
function vo.SerializeProjectFile(entries, meta)
  meta = meta or {}
  local out = {
    vo.FormatCSVRow({ vo.PROJECT_MARKER, tostring(vo.PROJECT_VERSION) }),
  }

  -- One row per script, in the order the user added them. This replaces the
  -- single "Script CSV" + "Mapping" pair; ParseProjectFile still reads that pair
  -- so a project saved by an older version opens untouched.
  for _, sc in ipairs(meta.scripts or {}) do
    if sc.path and sc.path ~= "" then
      out[#out + 1] = vo.FormatCSVRow({
        "Script", sc.path, encode_mapping(sc.mapping),
        sc.enabled ~= false and "yes" or "",
      })
    end
  end

  -- Appends are keyed by script LINE, not by a stretch of audio, so like Pins
  -- they cannot live in the entry table. An append whose script is no longer in
  -- the list is still written: removing a script and adding it back must not
  -- throw the user's naming away.
  for _, a in ipairs(meta.appends or {}) do
    if a.text and a.text ~= "" then
      out[#out + 1] = vo.FormatCSVRow({
        "Append", a.script or "", a.asset or "",
        tostring(a.nth or 1), a.text,
      })
    end
  end

  -- Line edits sit beside the Appends and for the same reason: both are keyed
  -- by the script LINE, not by a stretch of audio, so neither can live in the
  -- entry table. An edit whose script is no longer in the list is still
  -- written -- removing a script and adding it back must not throw the user's
  -- words away.
  for _, e in ipairs(meta.line_edits or {}) do
    if e.text and e.text ~= "" then
      out[#out + 1] = vo.FormatCSVRow({
        "Line", e.script or "", e.asset or "",
        tostring(e.nth or 1), e.text,
      })
    end
  end

  -- The filename the user typed over the script's own. Same key, same rules;
  -- it supersedes Append, which is no longer reachable from the card but is
  -- still written above so a project saved by an older version keeps its names.
  for _, n in ipairs(meta.names or {}) do
    if n.text and n.text ~= "" then
      out[#out + 1] = vo.FormatCSVRow({
        "Name", n.script or "", n.asset or "",
        tostring(n.nth or 1), n.text,
      })
    end
  end

  -- The words this reader's transcriber mishears. A property of the session,
  -- not of the machine, so it travels with the project rather than sitting in
  -- global ExtState where it would follow you into unrelated work.
  for _, s in ipairs(meta.subs or {}) do
    if s.from and s.from ~= "" then
      out[#out + 1] = vo.FormatCSVRow({ "Sub", s.from, s.to or "" })
    end
  end

  -- Pins live in the preamble rather than the entry table because they are keyed
  -- by the SCRIPT LINE, while every entry row is keyed by a stretch of audio.
  -- Keeping them out of that table is also what lets them be added without
  -- changing the entry columns, and so without invalidating existing files.
  for _, p in ipairs(meta.pins or {}) do
    if p.asset and p.asset ~= "" and p.source and p.source ~= "" then
      out[#out + 1] = vo.FormatCSVRow({
        "Pin", p.asset, p.source,
        string.format("%.3f", p.start or 0),
        string.format("%.3f", p.stop or 0),
      })
    end
  end

  -- How the table was left: which filters were on, what was searched for, how it
  -- was sorted. Not a decision about the AUDIO like everything above, but it is
  -- a decision about THIS project -- a character filter names this project's
  -- characters -- so it belongs beside them rather than in the global ExtState
  -- that holds column widths. A reader that predates these rows skips them.
  local v = meta.view
  if v then
    local function row(key, ...) out[#out + 1] = vo.FormatCSVRow({ "View", key, ... }) end
    if v.character and v.character ~= ""                 then row("character", v.character) end
    if v.search and v.search ~= ""                       then row("search", v.search) end
    if v.filter_row                                      then row("filter_row", "yes") end
    -- The SORT is deliberately not here. ImGui owns the header clicks and keeps
    -- the sort spec in its own ini alongside the column widths; storing it here
    -- too would give it two owners, and ImGui's would win on the first frame.
    -- Sorted, so a file that is otherwise unchanged does not churn its diff on
    -- every save just because a table iterated in a different order.
    local keys = {}
    for key, needle in pairs(v.col_filters or {}) do
      if needle and needle ~= "" then keys[#keys + 1] = key end
    end
    table.sort(keys)
    for _, key in ipairs(keys) do row("column", key, v.col_filters[key]) end
    -- Which lines were folded shut. Sorted for the same diff-stability reason
    -- as the column filters above.
    local expanded = {}
    for _, k in ipairs(v.expanded or {}) do
      if k ~= "" then expanded[#expanded + 1] = tostring(k) end
    end
    table.sort(expanded)
    for _, k in ipairs(expanded) do row("expanded", k) end
  end

  local rest = {
    "",
    vo.FormatCSVRow(vo.PROJECT_HEADER),
  }
  for _, line in ipairs(rest) do out[#out + 1] = line end

  for _, e in ipairs(entries or {}) do
    -- Only rows carrying actual user work are written. Without this the file
    -- would grow a line per script line per session and the signal would drown.
    -- An explicit "no" IS work -- see mark_to_field -- so these test against
    -- nil rather than truthiness, or the no would be dropped and reappear as a
    -- tick inferred from the track.
    local has_work = e.select ~= nil or e.keep ~= nil
                  or (e.status and e.status ~= "")
                  or (e.name_override and e.name_override ~= "")
                  or (e.notes and e.notes ~= "")
                  -- A planned take's existence IS the work: it derives from
                  -- nothing else, so dropping a bare one would delete the row.
                  or vo.IsPlannedKey(e.key)
    if has_work then
      out[#out + 1] = vo.FormatCSVRow({
        e.key or "",
        e.asset or "",
        e.source or "",
        e.source_start and string.format("%.3f", e.source_start) or "",
        mark_to_field(e.select),
        e.status or "",
        e.name_override or "",
        e.notes or "",
        mark_to_field(e.keep),
      })
    end
  end

  return table.concat(out, "\n") .. "\n"
end

-- Returns the parsed file, or nil plus a reason. Nothing here raises: a project
-- file mangled by a spreadsheet round-trip must never stop the window opening,
-- because the window is the only place the user can fix it.
function vo.ParseProjectFile(text)
  if type(text) ~= "string" or text == "" then
    return nil, "The project file is empty."
  end

  local rows = vo.ParseCSV(text)
  if not rows[1] or rows[1][1] ~= vo.PROJECT_MARKER then
    return nil, "Not an " .. vo.PROJECT_MARKER .. " file."
  end

  local version = tonumber(rows[1][2] or "")
  if version ~= vo.PROJECT_VERSION then
    return nil, "Unsupported project file version: " .. tostring(rows[1][2])
  end

  local parsed = { version = version, scripts = {}, appends = {},
                   line_edits = {}, names = {}, subs = {},
                   entries = {}, pins = {}, view = { col_filters = {}, expanded = {} } }
  -- The pre-multi-script format, folded in below only if no Script row appears.
  local legacy_path, legacy_mapping = nil, nil

  local i, header_at = 2, nil
  while rows[i] do
    local key = rows[i][1] or ""
    if key == vo.PROJECT_HEADER[1] then header_at = i; break end
    if     key == "Script CSV" then legacy_path    = rows[i][2] or ""
    elseif key == "Mapping"    then legacy_mapping = decode_mapping(rows[i][2])
    elseif key == "Script" then
      local path = rows[i][2] or ""
      if path ~= "" then
        parsed.scripts[#parsed.scripts + 1] = {
          path    = path,
          mapping = decode_mapping(rows[i][3]),
          -- Anything other than an explicit "" reads as enabled, so a row
          -- hand-edited in a spreadsheet does not silently switch a script off.
          enabled = (rows[i][4] or "") ~= "",
        }
      end
    elseif key == "Append" then
      local script, asset = rows[i][2] or "", rows[i][3] or ""
      local nth, text = tonumber(rows[i][4] or ""), rows[i][5] or ""
      if asset ~= "" and nth and text ~= "" then
        parsed.appends[#parsed.appends + 1] =
          { script = script, asset = asset, nth = math.floor(nth), text = text }
      end
    elseif key == "Line" then
      -- Read even when no loaded line answers to it: disabling a script, or
      -- re-exporting the CSV under a new name, must not destroy the user's
      -- words. vo.OrphanKeyedText is what surfaces those.
      local script, asset = rows[i][2] or "", rows[i][3] or ""
      local nth, text = tonumber(rows[i][4] or ""), rows[i][5] or ""
      if asset ~= "" and nth and text ~= "" then
        parsed.line_edits[#parsed.line_edits + 1] =
          { script = script, asset = asset, nth = math.floor(nth), text = text }
      end
    elseif key == "Sub" then
      local from, to = rows[i][2] or "", rows[i][3] or ""
      if from ~= "" then
        parsed.subs[#parsed.subs + 1] = { from = from, to = to }
      end
    elseif key == "Name" then
      local script, asset = rows[i][2] or "", rows[i][3] or ""
      local nth, text = tonumber(rows[i][4] or ""), rows[i][5] or ""
      if asset ~= "" and nth and text ~= "" then
        parsed.names[#parsed.names + 1] =
          { script = script, asset = asset, nth = math.floor(nth), text = text }
      end
    elseif key == "View" then
      local what, a, b = rows[i][2] or "", rows[i][3] or "", rows[i][4] or ""
      -- "status" was a preset filter that no longer exists; a file written by
      -- that version is read without it rather than rejected.
      if     what == "character"  then parsed.view.character  = a ~= "" and a or nil
      elseif what == "search"     then parsed.view.search     = a ~= "" and a or nil
      elseif what == "filter_row" then parsed.view.filter_row = a ~= ""
      elseif what == "column" and a ~= "" and b ~= "" then
        parsed.view.col_filters[a] = b
      elseif what == "expanded" and a ~= "" then
        parsed.view.expanded[#parsed.view.expanded + 1] = a
      end
    elseif key == "Pin" then
      local asset, source = rows[i][2] or "", rows[i][3] or ""
      local from, to = tonumber(rows[i][4] or ""), tonumber(rows[i][5] or "")
      -- A pin with no range is not a weaker pin, it is a corrupt one.
      if asset ~= "" and source ~= "" and from and to and to > from then
        parsed.pins[#parsed.pins + 1] =
          { asset = asset, source = source, start = from, stop = to }
      end
    end
    i = i + 1
  end

  -- A project saved before scripts became a list. Folded in only when no Script
  -- row was found, so an explicit list always wins over a stale legacy row.
  if #parsed.scripts == 0 and legacy_path and legacy_path ~= "" then
    parsed.scripts[1] = { path = legacy_path, mapping = legacy_mapping or {},
                          enabled = true }
  end

  if not header_at then
    return nil, "The project file has no header row."
  end

  for j = header_at + 1, #rows do
    local row = rows[j]
    local key = row[1] or ""
    if key ~= "" then
      local status = fold(row[6] or "")
      -- Two independent marks. 0.13 briefly wrote "alt" in the Select field
      -- before Keep had a column of its own; it reads as a keep, so a file
      -- written by that version keeps the work rather than losing it.
      --
      -- Written as statements, NOT `field_to_mark(row[9]) or legacy`: an
      -- explicit "no" is `false`, and `false or legacy` would evaluate the
      -- legacy branch and turn the user's no into a yes.
      local keep = field_to_mark(row[9])
      if keep == nil and fold(row[5] or "") == "alt" then keep = true end

      parsed.entries[#parsed.entries + 1] = {
        key           = key,
        asset         = row[2] ~= "" and row[2] or nil,
        source        = row[3] ~= "" and row[3] or nil,
        source_start  = tonumber(row[4] or ""),
        select        = field_to_mark(row[5]),
        keep          = keep,
        -- An unrecognised status is dropped rather than carried: it would
        -- otherwise render as an unknown badge with no way to clear it.
        status        = vo.TRACKER_STATUSES[status] and status or nil,
        name_override = row[7] ~= "" and row[7] or nil,
        notes         = row[8] ~= "" and row[8] or nil,
      }
    end
  end

  return parsed
end

-- Index tracker entries for lookup, bucketed by full source path AND by
-- basename. The full path is tried first so two recordings that happen to share
-- a filename never share a checkmark; the basename bucket is the fallback that
-- lets a moved project still find its own rows.
local function index_tracker(entries)
  local by_path, by_base, by_asset = {}, {}, {}
  for _, e in ipairs(entries or {}) do
    if e.source and e.source ~= "" then
      by_path[e.source] = by_path[e.source] or {}
      table.insert(by_path[e.source], e)
      local b = basename(e.source)
      by_base[b] = by_base[b] or {}
      table.insert(by_base[b], e)
    elseif e.asset and not vo.IsPlannedKey(e.key) then
      -- Planned entries share the asset but are TAKES, not the line's own
      -- marks; letting one in here would shadow the "|<asset>" entry that
      -- carries a missing line's notes.
      by_asset[e.asset] = e
    end
  end
  return { by_path = by_path, by_base = by_base, by_asset = by_asset }
end

-- Assign tracker entries to span records, at most one row per entry.
--
-- Four passes, most specific first, and each pass runs over EVERY record before
-- the next begins. That ordering is the whole correctness argument:
--
--   1. exact key, same full path   -- the row has not moved
--   2. exact key, same basename    -- the project moved to another drive
--   3. near miss, same full path   -- re-transcription nudged the boundary
--   4. near miss, same basename    -- both of the above at once
--
-- Resolving per-record instead would let an earlier record claim, through the
-- loose basename bucket, an entry that a later record matches on its full path
-- -- which is exactly how two recordings sharing a filename end up sharing one
-- checkmark. Within a pass, proximity matches are taken globally nearest-first,
-- so a mark can never migrate onto a farther take than the one it belongs to.
local function resolve_tracker(index, recs)
  local claimed, resolved = {}, {}

  -- Returns nil rather than an empty table when the fallback bucket is the very
  -- table the "path" level already searched, so a miss is not retried.
  local function bucket_for(rec, level)
    local exact = index.by_path[rec.source_path]
    if level == "path" then return exact end
    local base = index.by_base[basename(rec.source_path)]
    if base ~= exact then return base end
    return nil
  end

  local function exact_pass(level)
    for _, rec in ipairs(recs) do
      if not resolved[rec] then
        for _, e in ipairs(bucket_for(rec, level) or {}) do
          if e.key == rec.key and not claimed[e] then
            resolved[rec], claimed[e] = e, true
            break
          end
        end
      end
    end
  end

  local function near_pass(level)
    local candidates = {}
    for _, rec in ipairs(recs) do
      if not resolved[rec] and rec.span.asset then
        for _, e in ipairs(bucket_for(rec, level) or {}) do
          if not claimed[e] and e.asset == rec.span.asset and e.source_start then
            local delta = math.abs(e.source_start - (rec.span.start or 0))
            if delta <= vo.TRACKER_REMATCH_TOLERANCE then
              candidates[#candidates + 1] = { rec = rec, entry = e, delta = delta }
            end
          end
        end
      end
    end

    table.sort(candidates, function(a, b)
      if a.delta ~= b.delta then return a.delta < b.delta end
      -- Ties broken deterministically, so identical inputs always produce the
      -- same assignment regardless of table iteration order.
      return tostring(a.rec.key) < tostring(b.rec.key)
    end)

    for _, c in ipairs(candidates) do
      if not resolved[c.rec] and not claimed[c.entry] then
        resolved[c.rec], claimed[c.entry] = c.entry, true
      end
    end
  end

  exact_pass("path")
  exact_pass("base")
  near_pass("path")
  near_pass("base")

  return resolved
end

-- Assemble the unified overview: every line the script SAYS should exist, every
-- span the live match says DOES exist, and the user's own marks over the top.
--
-- Inputs are already-parsed structures so this runs headless:
--   lines   -- from vo.BuildScriptLines: { text, asset, speaker, row }
--   matches -- from vo.BuildMatch: array of { path = <source file>, spans = … }
--   entries -- the `entries` array from vo.ParseProjectFile, or nil
--
-- Take numbering is done here rather than by vo.AssignNames because AssignNames
-- sorts a group by `start` alone, which is only meaningful inside ONE source
-- file. Ordering takes of a line recorded across two sessions needs a source
-- ordinal ahead of the timestamp, so the rule is shared but the code is not.
function vo.BuildOverview(input)
  input = input or {}
  local lines   = input.lines or {}
  local entries = input.entries
  -- Takes defined by MARKERS (vo.CountingMarkers output grouped by asset).
  -- A line that appears here builds its rows from the markers and the match's
  -- opinion of it is ignored: markers are the truth, the match was only ever
  -- the generator.
  local takes_by_asset = input.takes_by_asset or {}

  -- The per-source word lists, when the caller has them. A marker row's text
  -- is the words INSIDE its range, and only the caller -- which already read
  -- the transcripts to build the match -- can supply them. A caller that does
  -- not falls back to span text inside vo.TranscriptForRange.
  local words_by_source = {}
  for _, t in ipairs(input.transcripts or {}) do
    if t.path then words_by_source[t.path] = t.words or {} end
  end

  -- Plain key lookup for marker-keyed marks. NOT via index_tracker: tkm keys
  -- have no source bucket, and letting them into by_asset would shadow the
  -- line-level "|<asset>" entry -- the same hazard planned keys hit.
  local by_key = {}
  for _, e in ipairs(entries or {}) do
    if e.key then by_key[e.key] = e end
  end

  -- Sources in a stable order, so take numbers do not shuffle between openings.
  local by_source = {}
  for _, sc in ipairs(input.matches or {}) do
    if sc and sc.path then by_source[#by_source + 1] = sc end
  end
  table.sort(by_source, function(a, b) return a.path < b.path end)

  -- The canonical source order, for anything that has to number across files.
  -- Marker takes sort by SOURCE first and time second: two sessions each start
  -- their own file at zero, so ordering on time alone interleaves two unrelated
  -- timebases and hands a line's takes their letters in an order that means
  -- nothing. A source carrying no matches is not in this list and sorts last.
  local source_rank = {}
  for i, sc in ipairs(by_source) do source_rank[sc.path] = i end

  local index = index_tracker(entries)

  -- Flatten every span, tagged with its source and its global ordering key.
  local spans = {}
  for si, sc in ipairs(by_source) do
    local ordered = {}
    for _, s in ipairs(sc.spans or {}) do ordered[#ordered + 1] = s end
    table.sort(ordered, function(a, b) return (a.start or 0) < (b.start or 0) end)
    for _, s in ipairs(ordered) do
      spans[#spans + 1] = {
        span = s, source_path = sc.path, source_order = si,
        key = vo.OverviewKey(sc.path, s.start, s.asset),
      }
    end
  end

  -- Resolved up front, over ALL spans at once: entry assignment is competitive,
  -- so it cannot be decided one row at a time.
  local resolved = resolve_tracker(index, spans)

  -- A line's identity for grouping is its script ROW, not its filename. Those
  -- are normally the same thing, but a script CAN name two different lines with
  -- one filename, and grouping by filename then shows each of them the other's
  -- takes -- eight takes of "Jump right in!" three of which are audibly a
  -- different line. The span already knows which line it matched, so trust
  -- that; the filename lookup is the fallback for spans that carry no line
  -- index (older callers, hand-built tests).
  local first_row_using = {}
  for i, l in ipairs(lines) do
    if l.asset and first_row_using[l.asset] == nil then first_row_using[l.asset] = i end
  end
  local function line_row_of(s)
    local li = s.line_idx
    if li and lines[li] and lines[li].asset == s.asset then return li end
    return first_row_using[s.asset]
  end

  -- Planned entries grow rows here, beside their line, ordered by key so the
  -- numbering cannot shuffle between rebuilds. One whose asset no longer names
  -- any line surfaces as an orphan rather than vanishing: it is user work, and
  -- silently dropping it on a script edit is exactly the kind of loss the
  -- orphan section exists to prevent.
  local planned_by_row, planned_orphans = {}, {}
  for _, e in ipairs(entries or {}) do
    if vo.IsPlannedKey(e.key) then
      local li = e.asset and first_row_using[e.asset]
      if li then
        planned_by_row[li] = planned_by_row[li] or {}
        table.insert(planned_by_row[li], e)
      else
        planned_orphans[#planned_orphans + 1] = e
      end
    end
  end
  for _, list in pairs(planned_by_row) do
    table.sort(list, function(a, b) return tostring(a.key) < tostring(b.key) end)
  end

  local function planned_row(e, line, take_index, take_count)
    return {
      key           = e.key,
      status        = line and "planned" or "orphan",
      planned       = true,
      asset         = e.asset,
      deliver       = (line and line.deliver) or e.asset,
      script        = line and line.script or nil,
      append_key    = line and line.append_key or nil,
      append_nth    = line and line.append_nth or nil,
      line_key      = line and line.append_key or nil,
      character     = line and line.speaker or nil,
      line_text     = line and line.text or nil,
      line_original = line and (line.text_original or line.text) or nil,
      line_edited   = line and line.text_edited or nil,
      take_index    = take_index,
      take_count    = take_count,
      script_row    = line and (line.index or line.row) or nil,
      user_status   = e.status,
      name_override = e.name_override,
      notes         = e.notes,
      is_primary    = false,
      mark_select   = e.select,
      mark_keep     = e.keep,
      user_select   = e.select == true,
      user_keep     = e.keep == true,
    }
  end

  -- Group the spans that claim a script line, so takes can be numbered.
  local groups = {}
  for _, rec in ipairs(spans) do
    local s = rec.span
    local row_idx = (s.kind == "match" or s.kind == "review") and s.asset
                    and line_row_of(s) or nil
    if row_idx then
      groups[row_idx] = groups[row_idx] or {}
      table.insert(groups[row_idx], rec)
    else
      rec.orphan = true
    end
  end

  local function make_row(rec, line, take_index, take_count)
    local s = rec.span
    local t = resolved[rec]
    return {
      key           = rec.key,
      status        = rec.orphan and "orphan"
                      or (s.kind == "review" and "review" or "recorded"),
      asset         = s.asset,
      deliver       = (line and line.deliver) or s.deliver or s.asset,
      script        = line and line.script or nil,
      append_key    = line and line.append_key or nil,
      append_nth    = line and line.append_nth or nil,
      -- The line's identity for clash detection. Orphans have none: audio that
      -- matched no script line has no delivered name to collide with.
      line_key      = line and line.append_key or nil,
      character     = s.character or (line and line.speaker) or nil,
      line_text     = line and line.text or nil,
      line_original = line and (line.text_original or line.text) or nil,
      line_edited   = line and line.text_edited or nil,
      transcript    = s.transcript,
      score         = s.score,
      -- false when this match contradicts the order the rest of the read was in;
      -- nil when order had nothing to say about it. The table explains a review
      -- with it, since a 100% score in review is otherwise baffling.
      in_sequence   = s.in_sequence,
      pinned        = s.pinned or nil,
      source_path   = rec.source_path,
      source_start  = s.start,
      source_stop   = s.stop,
      take_index    = take_index,
      take_count    = take_count,
      name          = s.name,
      script_row    = line and (line.index or line.row) or nil,
      user_status   = t and t.status or nil,
      name_override = t and t.name_override or nil,
      notes         = t and t.notes or nil,
      -- The STORED marks, tri-state: true / false / nil for "no opinion".
      -- Written back by vo.ProjectEntriesFromRows.
      mark_select   = t and t.select,
      mark_keep     = t and t.keep,
      -- The EFFECTIVE marks, always boolean, for the checkbox and for Pull.
      -- The coupled layer recomputes these through vo.EffectiveMarks once it
      -- knows which track the item sits on; this is the no-item answer.
      user_select   = (t and t.select) == true,
      user_keep     = (t and t.keep) == true,
    }
  end

  -- A take defined by its MARKER: the row carries the marker's own span and
  -- keys its marks by the marker id -- a key no drag can move, which is the
  -- whole point.
  local function marker_row(mk, line, take_index, take_count)
    local t = by_key["tkm|" .. mk.id]
    -- The marker says WHICH take; the match still knows what was said there.
    local said, score, in_seq =
      vo.TranscriptForRange(spans, mk.source_path, mk.start, mk.stop,
                            words_by_source[mk.source_path])
    return {
      key           = "tkm|" .. mk.id,
      marker_id     = mk.id,
      status        = "recorded",
      transcript    = said,
      score         = score,
      in_sequence   = in_seq,
      asset         = line.asset,
      deliver       = line.deliver or line.asset,
      script        = line.script,
      append_key    = line.append_key,
      append_nth    = line.append_nth,
      line_key      = line.append_key,
      character     = line.speaker,
      line_text     = line.text,
      line_original = line.text_original or line.text,
      line_edited   = line.text_edited,
      source_start  = mk.start,
      source_stop   = mk.stop,
      take_index    = take_index,
      take_count    = take_count,
      script_row    = line.index or line.row,
      user_status   = t and t.status or nil,
      name_override = t and t.name_override or nil,
      notes         = t and t.notes or nil,
      is_primary    = false,
      mark_select   = t and t.select,
      mark_keep     = t and t.keep,
      user_select   = (t and t.select) == true,
      user_keep     = (t and t.keep) == true,
    }
  end

  local rows = {}

  -- Script order first: this is a script-shaped spreadsheet, so a line's takes
  -- sit together under it whether they were recorded in one session or five.
  for line_row, line in ipairs(lines) do
    local g = groups[line_row]
    local mks = takes_by_asset[line.asset]
    if mks and #mks > 0 then
      -- Markers own this line. Numbering follows marker start order; the Sel
      -- primary is the user's explicit tick, same no-fallback rule as below.
      local ordered = {}
      for _, mk in ipairs(mks) do ordered[#ordered + 1] = mk end
      table.sort(ordered, function(a, b)
        local ra = source_rank[a.source_path] or math.huge
        local rb = source_rank[b.source_path] or math.huge
        if ra ~= rb then return ra < rb end
        -- Two sources both outside the match list still need a stable answer.
        if ra == math.huge and a.source_path ~= b.source_path then
          return tostring(a.source_path) < tostring(b.source_path)
        end
        if a.start ~= b.start then return (a.start or 0) < (b.start or 0) end
        return tostring(a.id) < tostring(b.id)
      end)
      local built = {}
      for i, mk in ipairs(ordered) do
        built[#built + 1] = marker_row(mk, line, i, #ordered)
      end
      local chosen
      for _, row in ipairs(built) do
        if row.user_select then chosen = row break end
      end
      for _, row in ipairs(built) do
        row.is_primary = (row == chosen)
        rows[#rows + 1] = row
      end
      local p = planned_by_row[line_row]
      if p then
        for i, e in ipairs(p) do
          rows[#rows + 1] = planned_row(e, line, #ordered + i, #ordered + #p)
        end
      end
    else
      local key = vo.OverviewKey(nil, nil, line.asset)
      local t = index.by_asset[line.asset]
      rows[#rows + 1] = {
        key           = key,
        status        = "missing",
        asset         = line.asset,
        deliver       = line.deliver or line.asset,
        script        = line.script,
        append_key    = line.append_key,
        append_nth    = line.append_nth,
        line_key      = line.append_key,
        character     = line.speaker,
        line_text     = line.text,
        line_original = line.text_original or line.text,
        line_edited   = line.text_edited,
        take_count    = 0,
        -- How many match or review spans this line has in the session, none of
        -- them marked. Zero means nothing was recorded; four means the audio is
        -- sitting there and Identify has not been run on it. "Missing" must
        -- never read as "we looked and there is nothing" when there is.
        heard         = g and #g or 0,
        script_row    = line.index or line.row,
        user_status   = t and t.status or nil,
        name_override = t and t.name_override or nil,
        notes         = t and t.notes or nil,
        is_primary    = false,
        mark_select   = t and t.select,
        mark_keep     = t and t.keep,
        user_select   = (t and t.select) == true,
        user_keep     = (t and t.keep) == true,
      }

      local p = planned_by_row[line_row]
      if p then
        for i, e in ipairs(p) do
          rows[#rows + 1] = planned_row(e, line, i, #p)
        end
      end
    end
  end

  -- Orphans last: audio that matched no script line, or matched a line the
  -- current filters exclude. Never silently dropped -- unrecognised audio is
  -- exactly what the user opened this window to find.
  for _, rec in ipairs(spans) do
    if rec.orphan then
      local row = make_row(rec, nil, nil, nil)
      row.is_primary = false
      rows[#rows + 1] = row
    end
  end
  for _, e in ipairs(planned_orphans) do
    rows[#rows + 1] = planned_row(e, nil, nil, nil)
  end

  return rows
end

-- Audio the matcher recognised that no marker has claimed.
--
-- Once a marker is the only thing that makes a take, the reads Identify scored
-- too low would simply vanish from the sheet -- exactly the takes most in need
-- of a person. This is where they go: the Check panel's "Not yet identified".
--
-- Covered means a marker on the SAME SOURCE overlaps at least HALF the span.
-- Half, not any: a marker trimmed short still owns its take, and a marker that
-- merely brushes a neighbouring span does not claim it.
--
-- Orphans -- spans matching no script line -- are deliberately absent. "Which
-- line is this?" and "this line's audio is not tracked yet" are two different
-- questions, and they have two different queues.
--
-- Pure. Same `input` shape as vo.BuildOverview.
function vo.UnidentifiedSpans(input)
  input = input or {}
  local lines = input.lines or {}

  -- Every counting marker, bucketed by the source it sits in.
  local marks_by_source = {}
  for _, mks in pairs(input.takes_by_asset or {}) do
    for _, mk in ipairs(mks) do
      local p = mk.source_path
      if p and mk.start and mk.stop then
        marks_by_source[p] = marks_by_source[p] or {}
        table.insert(marks_by_source[p], mk)
      end
    end
  end

  -- A span claims a line the way BuildOverview groups it: its own line index
  -- when that line agrees on the asset, else the first line using the name.
  local first_row_using = {}
  for i, l in ipairs(lines) do
    if l.asset and first_row_using[l.asset] == nil then first_row_using[l.asset] = i end
  end

  local out = {}
  for _, sc in ipairs(input.matches or {}) do
    for _, s in ipairs((sc and sc.spans) or {}) do
      local line
      if s.asset then
        local li = s.line_idx
        if li and lines[li] and lines[li].asset == s.asset then
          line = lines[li]
        else
          line = lines[first_row_using[s.asset] or 0]
        end
      end
      if (s.kind == "match" or s.kind == "review") and line
         and s.start and s.stop and s.stop > s.start then
        local need = (s.stop - s.start) * 0.5
        local covered = false
        for _, mk in ipairs(marks_by_source[sc.path] or {}) do
          if math.min(mk.stop, s.stop) - math.max(mk.start, s.start) >= need then
            covered = true
            break
          end
        end
        if not covered then
          out[#out + 1] = {
            source_path = sc.path,
            start       = s.start,
            stop        = s.stop,
            asset       = s.asset,
            deliver     = line.deliver or s.deliver or s.asset,
            score       = s.score,
            transcript  = s.transcript,
          }
        end
      end
    end
  end

  table.sort(out, function(a, b)
    if a.source_path ~= b.source_path then
      return tostring(a.source_path) < tostring(b.source_path)
    end
    return (a.start or 0) < (b.start or 0)
  end)
  return out
end

-- Fold the overview back into project-file entries for writing. Rows carrying
-- no user work are still returned; SerializeProjectFile is what drops them, so
-- a row the user CLEARED is written as empty here and then vanishes from the
-- file.
function vo.ProjectEntriesFromRows(rows)
  local entries = {}
  for _, row in ipairs(rows or {}) do
    entries[#entries + 1] = {
      key           = row.key,
      source        = row.source_path,
      source_start  = row.source_start,
      asset         = row.asset,
      -- The STORED mark, never row.user_select: that one may have been
      -- inferred from the item's track, and writing an inference down as an
      -- explicit decision would make it permanent and unclearable.
      select        = row.mark_select,
      keep          = row.mark_keep,
      status        = row.user_status,
      name_override = row.name_override,
      notes         = row.notes,
    }
  end
  return entries
end

-- The Overview table's draw list. Flat overview rows (already in script
-- order, adopted/extra rows already inserted beside their lines) become a
-- typed node list: character headers, line parents with their takes nested,
-- and one trailing section for orphans. Pure, so the shape the window draws
-- is testable without ImGui.
--
-- rollup.got is NOT computed here: it reads the live project's item names
-- (DELIVERY in the window), which this layer must not touch.
function vo.GroupOverview(rows)
  local nodes, orphans = {}, {}
  local current_char, open_line = nil, nil

  local function line_key_of(row)
    return row.script_row or ("asset:" .. tostring(row.asset))
  end

  for _, row in ipairs(rows or {}) do
    if row.status == "orphan" then
      orphans[#orphans + 1] = row
    else
      local key = line_key_of(row)
      if not (open_line and open_line._key == key) then
        local char = row.character or ""
        if char ~= "" and char ~= current_char then
          nodes[#nodes + 1] = { kind = "character", name = char }
          current_char = char
        end
        open_line = { kind = "line", _key = key, rep = row, takes = {},
                      rollup = { status = "missing", has_sel = false,
                                 locks = 0, take_count = 0 } }
        nodes[#nodes + 1] = open_line
      end
      -- A row with no take_index is a line that matched nothing: it IS the
      -- parent and contributes no child. Everything else is a take.
      if row.take_index and row.status ~= "missing" then
        local t = open_line.takes
        t[#t + 1] = row
        local rl = open_line.rollup
        rl.take_count = #t
        if row.status == "review" then
          rl.status = "review"
        elseif row.status ~= "planned" and rl.status ~= "review" then
          -- A planned take is an intention, not audio: it counts as a take
          -- but must not make an unrecorded line read as recorded.
          rl.status = "recorded"
        end
        if row.user_select then rl.has_sel = true end
        if row.user_status == "verified" then rl.locks = rl.locks + 1 end
      end
    end
  end

  if #orphans > 0 then
    nodes[#nodes + 1] = { kind = "orphans", takes = orphans }
  end
  return nodes
end

-- Take rows are lettered, not numbered: A, B, C ... Z, AA, AB (spreadsheet
-- columns -- bijective base 26). Letters read as "which take" where a bare
-- number beside the line's # would read as another position.
function vo.TakeLetter(n)
  n = math.floor(tonumber(n) or 0)
  if n < 1 then return "" end
  local out = ""
  while n > 0 do
    local rem = (n - 1) % 26
    out = string.char(65 + rem) .. out
    n = math.floor((n - 1) / 26)
  end
  return out
end

-- Line-level visibility: filters choose LINES, and a line travels whole.
-- `match` sees take rows and line reps alike -- both are overview rows, so
-- one predicate (character, search, per-column needles) serves both.
function vo.FilterGroups(nodes, match)
  local out, pending_char = {}, nil
  for _, node in ipairs(nodes or {}) do
    if node.kind == "character" then
      pending_char = node
    elseif node.kind == "line" then
      local visible = match(node.rep)
      if not visible then
        for _, t in ipairs(node.takes) do
          if match(t) then visible = true break end
        end
      end
      if visible then
        if pending_char then out[#out + 1] = pending_char; pending_char = nil end
        out[#out + 1] = node
      end
    elseif node.kind == "orphans" then
      local kept = {}
      for _, t in ipairs(node.takes) do
        if match(t) then kept[#kept + 1] = t end
      end
      if #kept > 0 then
        out[#out + 1] = { kind = "orphans", takes = kept }
      end
    end
  end
  return out
end

-- Counts for the header summary line.
function vo.SummarizeOverview(rows)
  local n = { total = 0, recorded = 0, review = 0, missing = 0, orphan = 0,
              verified = 0, flagged = 0, junk = 0, lines = 0 }
  local seen_asset = {}
  for _, row in ipairs(rows or {}) do
    n.total = n.total + 1
    -- Dismissed audio leaves the orphan count rather than adding to it. That is
    -- the whole point of being able to dismiss: with it, "not on the script: 0"
    -- means every span has been looked at and decided, and the session really
    -- is finished. Without it the number can only ever be ignored, which is
    -- what made the list feel like a wall instead of a queue.
    if row.status == "orphan" and row.user_status == "junk" then
      n.junk = n.junk + 1
    elseif n[row.status] then
      n[row.status] = n[row.status] + 1
    end
    if row.user_status and row.user_status ~= "junk" and n[row.user_status] then
      n[row.user_status] = n[row.user_status] + 1
    end
    -- Script coverage counts LINES, not takes: five takes of one line is one
    -- line delivered, and a progress number that says otherwise is a lie.
    if row.status ~= "orphan" and row.asset and not seen_asset[row.asset] then
      seen_asset[row.asset] = true
      n.lines = n.lines + 1
      if row.status ~= "missing" then n.delivered = (n.delivered or 0) + 1 end
    end
  end
  n.delivered = n.delivered or 0
  return n
end

--------------------------------
-- Pure layer: timeline layout
--------------------------------

-- Laying the session out along the timeline moves ITEMS, never spans. An item
-- holding five lines is one thing you can drag, so it is positioned by its
-- first recognised line and everything after it is placed clear of its whole
-- length. Cutting stays the Cut window's job -- see SPEC-overview.md section 1.

-- How much two items must overlap before they are treated as one welded unit.
-- REAPER trims adjacent takes to abut exactly, and float error can make the
-- second start a hair before the first ends; a millisecond is well inside that
-- noise and well below any crossfade a person would actually draw.
vo.OVERLAP_EPSILON = 0.001

-- Order two geometry records the way the timeline shows them.
local function geometry_before(a, b)
  if (a.pos or 0) ~= (b.pos or 0) then return (a.pos or 0) < (b.pos or 0) end
  return (a.index or 0) < (b.index or 0)
end

-- Weld items that must travel together into clusters moved by a single delta.
--
-- Two relations weld, and they chain through each other:
--
-- 1. OVERLAP, same track only. A crossfade is nothing but an overlap: move one
--    side of it and the fade is gone. Cross-track overlaps do NOT weld --
--    Cut pulls selects onto per-character tracks, where two characters
--    overlapping in time is the normal case and means nothing about editing;
--    welding those would chain a multi-character session into one immovable blob.
--
-- 2. ITEM GROUP, across tracks. A group is the user saying "these belong
--    together" out loud. Moving one member and stranding the rest is the same
--    damage as breaking a crossfade, so a nonzero group id welds every item
--    carrying it, whatever track they sit on. Group id 0 means ungrouped and
--    never welds.
--
-- `geometry` is { { item=, index=, track=, pos=, length=, locked=, group= }, ... }.
-- Nothing here touches REAPER, so the caller decides what an "item" is.
function vo.ClusterItems(geometry)
  geometry = geometry or {}

  -- Tracks are numbered by first appearance so the cluster ordering tiebreak
  -- stays deterministic without the pure layer knowing what a track is.
  local track_rank, ranks = {}, 0
  for _, g in ipairs(geometry) do
    if track_rank[g.track] == nil then
      ranks = ranks + 1
      track_rank[g.track] = ranks
    end
  end

  local parent = {}
  for i = 1, #geometry do parent[i] = i end
  local function find(i)
    while parent[i] ~= i do
      parent[i] = parent[parent[i]]   -- path halving
      i = parent[i]
    end
    return i
  end
  local function union(a, b)
    a, b = find(a), find(b)
    if a ~= b then parent[b] = a end
  end

  -- Relation 1: overlap within a track ------------------------------------
  local by_track, track_order = {}, {}
  for i, g in ipairs(geometry) do
    local list = by_track[g.track]
    if list == nil then
      list = {}
      by_track[g.track] = list
      track_order[#track_order + 1] = g.track
    end
    list[#list + 1] = { at = i, g = g }
  end

  for _, track in ipairs(track_order) do
    local list = by_track[track]
    table.sort(list, function(a, b) return geometry_before(a.g, b.g) end)

    local chain_at, chain_stop
    for _, entry in ipairs(list) do
      local pos  = entry.g.pos or 0
      local stop = pos + (entry.g.length or 0)
      if chain_at and pos < (chain_stop - vo.OVERLAP_EPSILON) then
        union(chain_at, entry.at)
        if stop > chain_stop then chain_stop = stop end
      else
        chain_at, chain_stop = entry.at, stop
      end
    end
  end

  -- Relation 2: item groups, across tracks ---------------------------------
  local group_head = {}
  for i, g in ipairs(geometry) do
    local id = tonumber(g.group) or 0
    if id ~= 0 then
      if group_head[id] then union(group_head[id], i) else group_head[id] = i end
    end
  end

  -- Emit one cluster per component, in first-appearance order --------------
  local clusters, by_root = {}, {}
  for i, g in ipairs(geometry) do
    local root = find(i)
    local cluster = by_root[root]
    if not cluster then
      cluster = { members = {}, pos = g.pos or 0,
                  stop = (g.pos or 0) + (g.length or 0), locked = false }
      by_root[root] = cluster
      clusters[#clusters + 1] = cluster
    end
    cluster.members[#cluster.members + 1] = g
    if (g.pos or 0) < cluster.pos then cluster.pos = g.pos or 0 end
    local stop = (g.pos or 0) + (g.length or 0)
    if stop > cluster.stop then cluster.stop = stop end
    -- Moving half a cluster would destroy the very thing the cluster exists to
    -- protect, so one locked member locks all of them.
    if g.locked then cluster.locked = true end
  end

  for _, cluster in ipairs(clusters) do
    -- Callers read the head of the edit off members[1], so timeline order here
    -- is part of the contract, not a convenience.
    table.sort(cluster.members, geometry_before)
    local head = cluster.members[1]
    cluster.track       = head.track
    cluster.track_order = track_rank[head.track] or 0
  end

  table.sort(clusters, function(a, b)
    if a.pos ~= b.pos then return a.pos < b.pos end
    return a.track_order < b.track_order
  end)
  return clusters
end

-- Order clusters by the age of the recording they came from, oldest first, then
-- by position within that recording. Unknown ages sort after known ones, and
-- ties break on the path, so the result never depends on table iteration order.
local function order_source_paths(ids, ages)
  table.sort(ids, function(a, b)
    if (a == "") ~= (b == "") then return b == "" end
    local aa, ab = ages[a], ages[b]
    if (aa == nil) ~= (ab == nil) then return ab == nil end
    if aa and ab and aa ~= ab then return aa < ab end
    return a < b
  end)
  return ids
end

-- Decide where every cluster should sit. Returns `moves` and a `summary`;
-- applying them is the caller's job, so this whole function is testable with no
-- REAPER at all.
--
--   input.clusters   as returned by vo.ClusterItems, each with a `.key` of
--                    { script_row=, source_path=, source_start=, orphan= }
--   input.order      "script" | "record"
--   input.spacing    "fixed" | "original"   (original is record order only)
--   input.gap        seconds between consecutive items
--   input.source_gap seconds between two different recordings
--   input.source_age { [path] = <number>, ... }
--   input.start      project time the run begins at
function vo.PlanTimelineLayout(input)
  input = input or {}

  local clusters = {}
  for _, c in ipairs(input.clusters or {}) do clusters[#clusters + 1] = c end

  local order      = (input.order == "record") and "record" or "script"
  -- "Original spacing" means "replay this recording's own gaps". Script order is
  -- an order the recording never had, so there is nothing to replay and the
  -- fixed gap is the only honest answer. The dialog greys the control out; this
  -- makes it true even if a caller asks for it anyway.
  local spacing    = (order == "record" and input.spacing == "original")
                     and "original" or "fixed"
  local gap        = tonumber(input.gap) or 2.0
  local source_gap = tonumber(input.source_gap) or 60.0
  local ages       = input.source_age or {}

  local summary = { clusters = #clusters, items = 0, groups = 0,
                    clamped = 0, orphans = 0, span = 0 }
  for _, c in ipairs(clusters) do
    summary.items = summary.items + #(c.members or {})
  end
  if #clusters == 0 then return {}, summary end

  local start = tonumber(input.start)
  if not start then
    start = math.huge
    for _, c in ipairs(clusters) do
      if c.pos < start then start = c.pos end
    end
  end

  -- Group the clusters, in the order the groups will be laid down --------
  local groups = {}
  if order == "record" then
    local buckets, ids = {}, {}
    for _, c in ipairs(clusters) do
      local path = (c.key and c.key.source_path) or ""
      if not buckets[path] then
        buckets[path] = {}
        ids[#ids + 1] = path
      end
      local bucket = buckets[path]
      bucket[#bucket + 1] = c
    end
    for _, path in ipairs(order_source_paths(ids, ages)) do
      local bucket = buckets[path]
      table.sort(bucket, function(a, b)
        local sa = (a.key and a.key.source_start) or 0
        local sb = (b.key and b.key.source_start) or 0
        if sa ~= sb then return sa < sb end
        return a.pos < b.pos
      end)
      groups[#groups + 1] = { path = path, clusters = bucket }
    end
  else
    -- Orphans -- audio matching no script line -- have no place in script order,
    -- so they follow the run instead of being left behind for a sorted item to
    -- land on top of.
    local main, orphans = {}, {}
    for _, c in ipairs(clusters) do
      local k = c.key or {}
      if k.orphan or not k.script_row then
        orphans[#orphans + 1] = c
      else
        main[#main + 1] = c
      end
    end
    table.sort(main, function(a, b)
      if a.key.script_row ~= b.key.script_row then
        return a.key.script_row < b.key.script_row
      end
      local sa = a.key.source_start or 0
      local sb = b.key.source_start or 0
      if sa ~= sb then return sa < sb end
      return a.pos < b.pos
    end)
    table.sort(orphans, function(a, b) return a.pos < b.pos end)

    summary.orphans = #orphans
    for _, c in ipairs(orphans) do main[#main + 1] = c end
    groups[1] = { path = "", clusters = main }
  end
  summary.groups = #groups

  -- Place them ----------------------------------------------------------
  local moves, cursor, prev_stop = {}, start, nil

  for gi, group in ipairs(groups) do
    if gi > 1 and prev_stop then cursor = prev_stop + source_gap end
    local group_start = cursor
    local base = (group.clusters[1] and group.clusters[1].key
                  and group.clusters[1].key.source_start) or 0

    for _, c in ipairs(group.clusters) do
      local length = c.stop - c.pos
      local pos
      if spacing == "original" then
        pos = group_start + (((c.key and c.key.source_start) or 0) - base)
        -- An item retimed since it was recorded can be longer than the gap it
        -- originally sat in. Preserving the source layout would then stack it on
        -- its neighbour, so it slides forward and the count is reported.
        if prev_stop and pos < prev_stop then
          pos = prev_stop
          summary.clamped = summary.clamped + 1
        end
      else
        pos = cursor
      end

      moves[#moves + 1] = { cluster = c, pos = pos, delta = pos - c.pos }

      local stop = pos + length
      prev_stop = (prev_stop and stop < prev_stop) and prev_stop or stop
      cursor = prev_stop + gap
    end
  end

  summary.span = (prev_stop or start) - start
  return moves, summary
end

-- I_FOLDERDEPTH is a DELTA applied after a track, not a level, so nesting a new
-- child under an existing track is arithmetic rather than a special case.
--
-- Inserting child C directly below parent T, where T's current depth is d:
--   T becomes 1      -- opens a folder, so C sits one level in
--   C becomes d - 1  -- returns the level to exactly where T left it
--
-- That one rule covers every shape T can be in:
--   d =  0  a plain track      -> C = -1, C closes the folder T just opened
--   d = -1  the last child     -> C = -2, C closes both T's folder and its parent's
--   d =  1  already a folder   -> C =  0, T stays a folder and C becomes its first child
--   d = -2  closes two levels  -> C = -3, and so on
--
-- Getting this wrong re-indents every track BELOW the parent, which is why it
-- lives here with tests rather than inline at the call site.
function vo.FolderDepthForChild(parent_depth)
  local d = tonumber(parent_depth) or 0
  return 1, d - 1
end

--------------------------------
-- Pure layer: substitution table as editable text
--------------------------------

-- Parse the Settings panel's substitution box: one "from = to" per line.
-- Keys are folded to lowercase because they are matched against tokens that
-- have already been through Normalize. Only the first "=" separates, so a
-- replacement may itself contain one.
function vo.ParseSubstitutionText(text)
  local subs = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local from, to = line:match("^([^=]*)=(.*)$")
    if from then
      from, to = fold(from), trim(to)
      if from ~= "" then subs[from] = to end
    end
  end
  return subs
end

-- Substitutions belong to the PROJECT, not to the machine.
--
-- They were global ExtState, which meant `bolvd = adon` followed you into every
-- other project you opened -- and the words a transcriber mishears are facts
-- about one reader on one day, not about the tool. Worse, they were invisible
-- from the sheet: the place you notice a mishearing is the card, and the fix
-- was two windows away.
--
-- Stored as records, like every other per-line judgement in the project file:
-- `{ from = <folded token>, to = <replacement> }`. The `from = to` text box is
-- still how they are EDITED -- it is a good editor for a short table -- so
-- these two convert between the box and the records.
function vo.SubRows(text)
  local map = vo.ParseSubstitutionText(text)
  local keys = {}
  for from in pairs(map) do keys[#keys + 1] = from end
  -- Sorted, so the box does not reshuffle under the cursor between edits and
  -- so the project file's diff is stable.
  table.sort(keys)
  local rows = {}
  for _, from in ipairs(keys) do
    rows[#rows + 1] = { from = from, to = map[from] }
  end
  return rows
end

function vo.SubMap(rows)
  local m = {}
  for _, s in ipairs(rows or {}) do
    if s.from and s.from ~= "" then m[s.from] = s.to or "" end
  end
  return m
end

-- Render the substitution table back to editable text, sorted so the panel
-- shows a stable order rather than reshuffling on every open.
function vo.FormatSubstitutionText(subs)
  local keys = {}
  for from in pairs(subs or {}) do keys[#keys + 1] = from end
  table.sort(keys)

  local lines = {}
  for _, from in ipairs(keys) do
    lines[#lines + 1] = from .. " = " .. tostring(subs[from])
  end
  return table.concat(lines, "\n")
end

--------------------------------
-- Coupled layer: configuration
--------------------------------

vo.EXT_SECTION = "ajsfx_vo"

-- One declarative schema drives both load and save, so the two cannot drift
-- apart as fields are added.
vo.CONFIG_SCHEMA = {
  { key = "whisper_bin",        kind = "string", default = "whisper-cli" },
  { key = "whisper_model",      kind = "string", default = "" },
  { key = "whisper_threads",    kind = "number", default = 4 },
  { key = "whisper_language",   kind = "string", default = "en" },
  { key = "scratch_dir",        kind = "string", default = "" },
  { key = "timeout_s",          kind = "number", default = 1800 },
  { key = "force_retranscribe", kind = "bool",   default = false },

  { key = "accept_threshold",   kind = "number", default = vo.DEFAULTS.accept_threshold },
  { key = "review_floor",       kind = "number", default = vo.DEFAULTS.review_floor },
  { key = "margin_threshold",   kind = "number", default = vo.DEFAULTS.margin_threshold },
  { key = "anchor_count",       kind = "number", default = vo.DEFAULTS.anchor_count },
  { key = "auto_select_take",    kind = "string", default = vo.DEFAULTS.auto_select_take },
  { key = "auto_sort_marks",     kind = "bool",   default = vo.DEFAULTS.auto_sort_marks },
  { key = "order_weight",        kind = "number", default = vo.DEFAULTS.order_weight },
  { key = "backbone_min_tokens", kind = "number", default = vo.DEFAULTS.backbone_min_tokens },
  { key = "pre_pad",            kind = "number", default = vo.DEFAULTS.pre_pad },
  { key = "post_pad",           kind = "number", default = vo.DEFAULTS.post_pad },

  { key = "snap_boundaries",    kind = "bool",   default = vo.DEFAULTS.snap_boundaries },
  { key = "snap_min_silence",   kind = "number", default = vo.DEFAULTS.snap_min_silence },
  { key = "chained_boundary_reach", kind = "number",
    default = vo.DEFAULTS.chained_boundary_reach },
  { key = "snap_floor_offset",  kind = "number", default = vo.DEFAULTS.snap_floor_offset },
  { key = "snap_floor_window",  kind = "number", default = vo.DEFAULTS.snap_floor_window },
  { key = "snap_gate_auto",     kind = "bool",   default = vo.DEFAULTS.snap_gate_auto },
  { key = "snap_gate_db",       kind = "number", default = vo.DEFAULTS.snap_gate_db },
  { key = "snap_floor_percentile", kind = "number",
    default = vo.DEFAULTS.snap_floor_percentile },
  -- The room a cut, a take marker and Tighten all put around the speech.
  -- These were DEFAULTS-only for a long time, which meant vo.Opt could never
  -- see a user's value -- and since ApplyPadding clamps the exposed pads to
  -- them (min(pre_pad, snap_head_room)), dragging the pads did nothing at all.
  { key = "snap_head_room",     kind = "number", default = vo.DEFAULTS.snap_head_room },
  { key = "snap_tail_room",     kind = "number", default = vo.DEFAULTS.snap_tail_room },
  { key = "unheard_min_length", kind = "number", default = vo.DEFAULTS.unheard_min_length },
  { key = "unheard_join",       kind = "number", default = vo.DEFAULTS.unheard_join },
  { key = "trim_head_slack",    kind = "number", default = vo.DEFAULTS.trim_head_slack },
  { key = "trim_tail_slack",    kind = "number", default = vo.DEFAULTS.trim_tail_slack },

  -- Re-cut refuses a clump whose items disagree about playrate or pitch,
  -- because healing them collapses two different readings of the audio into
  -- one and the result is a lie about what was recorded. This lets the user
  -- say "do it anyway" -- the survivor takes the longest item's rate, and a
  -- REVIEW note records what was dropped, so the override is never silent.
  { key = "recut_ignore_rate",  kind = "bool",   default = false },

  { key = "track_selects",      kind = "string", default = "Selects" },
  { key = "track_alts",         kind = "string", default = "Alts" },
  { key = "track_review",       kind = "string", default = "Review" },
  -- The alt naming convention. Not bounded here: vo.PlanAltNames floors and
  -- clamps its own inputs, so a hand-edited ExtState cannot break a run.
  { key = "alt_append_pattern", kind = "string", default = "_alt{n}" },
  { key = "alt_append_start",   kind = "number", default = 1 },
  { key = "alt_append_digits",  kind = "number", default = 1 },

  { key = "review_prefix",      kind = "string", default = vo.DEFAULTS.review_prefix },
  { key = "unmatched_prefix",   kind = "string", default = vo.DEFAULTS.unmatched_prefix },
}

-- Load settings from ExtState, falling back to documented defaults.
-- The PROJECT's substitutions, when a project has them.
--
-- Set once by the Overview after it reads the project file, and read by
-- LoadConfig below -- so every existing `vo.LoadConfig()` call site picks up
-- this session's table without knowing the feature moved. There are dozens of
-- them across two scripts; threading an argument through all of them to say
-- the same thing every time would be worse than one slot with one writer.
--
-- nil means "no project loaded yet", which is not the same as an empty table:
-- a project that has deliberately no substitutions must not fall back to the
-- global ones left over from the last one.
local project_subs = nil

function vo.SetProjectSubstitutions(map)
  project_subs = map
end

function vo.LoadConfig()
  local function get(key)
    if r.HasExtState(vo.EXT_SECTION, key) then
      return r.GetExtState(vo.EXT_SECTION, key)
    end
    return nil
  end

  local cfg = {}
  for _, field in ipairs(vo.CONFIG_SCHEMA) do
    local raw = get(field.key)
    if raw == nil or raw == "" then
      cfg[field.key] = field.default
    elseif field.kind == "number" then
      cfg[field.key] = tonumber(raw) or field.default
    elseif field.kind == "bool" then
      cfg[field.key] = (raw == "1")
    else
      cfg[field.key] = raw
    end
  end

  cfg.column_mapping = {}
  for field, default_name in pairs(vo.DEFAULT_COLUMN_MAPPING) do
    local raw = get("col_" .. field)
    cfg.column_mapping[field] = (raw and raw ~= "") and raw or default_name
  end

  cfg.skip_values = {}
  local skip_raw = get("skip_values")
  if skip_raw and skip_raw ~= "" then
    for v in skip_raw:gmatch("[^\n]+") do
      cfg.skip_values[#cfg.skip_values + 1] = v
    end
  else
    for _, v in ipairs(vo.DEFAULT_SKIP_VALUES) do
      cfg.skip_values[#cfg.skip_values + 1] = v
    end
  end

  cfg.substitutions = {}
  local subs_raw = get("substitutions")
  if subs_raw and subs_raw ~= "" then
    for line in subs_raw:gmatch("[^\n]+") do
      local from, to = line:match("^([^\t]*)\t(.*)$")
      if from and from ~= "" then cfg.substitutions[from] = to end
    end
  end
  -- The project wins outright once one is loaded -- not merged with the global
  -- table. Merging would make a substitution impossible to REMOVE: deleting it
  -- from the project would silently restore whatever the machine had, and the
  -- user would be arguing with a table they cannot see from here.
  if project_subs then cfg.substitutions = project_subs end

  return cfg
end

-- Persist settings to ExtState. Mirrors LoadConfig via the shared schema.
function vo.SaveConfig(cfg)
  local function set(key, value)
    r.SetExtState(vo.EXT_SECTION, key, tostring(value), true)
  end

  for _, field in ipairs(vo.CONFIG_SCHEMA) do
    local value = cfg[field.key]
    if value == nil then value = field.default end
    if field.kind == "bool" then
      set(field.key, value and "1" or "0")
    else
      set(field.key, value)
    end
  end

  for field, default_name in pairs(vo.DEFAULT_COLUMN_MAPPING) do
    set("col_" .. field,
        (cfg.column_mapping and cfg.column_mapping[field]) or default_name)
  end

  set("skip_values", table.concat(cfg.skip_values or vo.DEFAULT_SKIP_VALUES, "\n"))

  local subs = {}
  for from, to in pairs(cfg.substitutions or {}) do
    subs[#subs + 1] = from .. "\t" .. to
  end
  table.sort(subs) -- deterministic serialization
  set("substitutions", table.concat(subs, "\n"))
end

--------------------------------
-- Coupled layer: layout presets
--------------------------------

local LAYOUT_SECTION = "ajsfx_vo_layouts"

-- Names of saved layout presets, in the order they were first saved.
function vo.ListLayoutPresets()
  local raw = r.GetExtState(LAYOUT_SECTION, "__names__")
  local names = {}
  for n in (raw or ""):gmatch("[^\n]+") do names[#names + 1] = n end
  return names
end

-- Persist a layout under `name`. Refuses (and stores nothing) for an invalid
-- name — see ValidatePresetName for the rules the ExtState key must satisfy.
function vo.SaveLayoutPreset(name, layout)
  local ok = vo.ValidatePresetName(name)
  if not ok then return false end
  r.SetExtState(LAYOUT_SECTION, "preset:" .. name, vo.SerializeLayout(layout), true)
  local names, seen = vo.ListLayoutPresets(), false
  for _, n in ipairs(names) do if n == name then seen = true break end end
  if not seen then names[#names + 1] = name end
  r.SetExtState(LAYOUT_SECTION, "__names__", table.concat(names, "\n"), true)
  return true
end

-- Load a previously saved layout, or nil if `name` was never saved.
function vo.LoadLayoutPreset(name)
  if not r.HasExtState(LAYOUT_SECTION, "preset:" .. name) then return nil end
  return vo.DeserializeLayout(r.GetExtState(LAYOUT_SECTION, "preset:" .. name))
end

function vo.DeleteLayoutPreset(name)
  r.DeleteExtState(LAYOUT_SECTION, "preset:" .. name, true)
  local kept = {}
  for _, n in ipairs(vo.ListLayoutPresets()) do if n ~= name then kept[#kept + 1] = n end end
  r.SetExtState(LAYOUT_SECTION, "__names__", table.concat(kept, "\n"), true)
end

--------------------------------
-- Pure layer: source time -> project time
--------------------------------

-- Map words from source-file time into project time for one item, keeping only
-- those whose midpoint falls inside the item's visible source range.
-- The midpoint rule matters: a word straddling the item edge belongs to
-- whichever side holds most of it, and using an edge instead would let the same
-- word be claimed by two adjacent items.
-- item: { pos, length, start_offs, playrate }
function vo.MapWordsToProject(words, item)
  local playrate = item.playrate or 1.0
  if playrate <= 0 then playrate = 1.0 end

  local src_start = item.start_offs or 0
  local src_end   = src_start + (item.length or 0) * playrate

  local out = {}
  for _, w in ipairs(words or {}) do
    local midpoint = (w.t0 + w.t1) / 2
    if midpoint >= src_start and midpoint <= src_end then
      out[#out + 1] = {
        t0   = item.pos + (w.t0 - src_start) / playrate,
        t1   = item.pos + (w.t1 - src_start) / playrate,
        text = w.text,
      }
    end
  end
  return out
end

--------------------------------
-- Coupled layer: filesystem helpers
--------------------------------

function vo.FileExists(path)
  if not path or path == "" then return false end
  local f = io.open(path, "rb")
  if f then f:close() return true end
  return false
end

function vo.FileSize(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local size = f:seek("end")
  f:close()
  return size
end

-- A content fingerprint cheap enough to run on every status check. Hashing a
-- 30-minute wav in Lua would cost more than it buys, so this folds the file's
-- size together with three 64 KB windows -- head, middle, tail. It exists to
-- catch what size alone misses: an in-place edit that leaves the file the same
-- length. It is not a security hash and does not try to be.
vo.FINGERPRINT_WINDOW = 65536

function vo.FileFingerprint(path)
  if not path or path == "" then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end

  local size = f:seek("end")
  local w    = vo.FINGERPRINT_WINDOW
  local offsets = { 0 }
  if size > w then
    offsets[#offsets + 1] = math.floor((size - w) / 2)
    offsets[#offsets + 1] = size - w
  end

  -- Polynomial rolling hash in plain arithmetic: every intermediate stays under
  -- 2^53, so this behaves identically on any Lua the script might run under.
  local h = 2166136261
  local function fold(n) h = (h * 31 + n) % 4294967291 end

  fold(size % 4294967291)
  for _, off in ipairs(offsets) do
    f:seek("set", off)
    local chunk = f:read(w) or ""
    for i = 1, #chunk, 256 do
      local bytes = { string.byte(chunk, i, math.min(i + 255, #chunk)) }
      for j = 1, #bytes do fold(bytes[j]) end
    end
  end

  f:close()
  return string.format("%08x", h)
end

-- The identity block every transcript carries. Built in one place so a writer
-- cannot record a size without a fingerprint, or either without the path.
function vo.TranscriptMeta(source_path, extra)
  extra = extra or {}
  return {
    source       = source_path or "",
    source_bytes = vo.FileSize(source_path) or 0,
    source_hash  = vo.FileFingerprint(source_path) or "",
    backend      = extra.backend or "",
    model        = extra.model or "",
    language     = extra.language or "",
  }
end

function vo.IsWindows()
  return (r.GetOS() or ""):find("Win") ~= nil
end

-- Scratch directory for transcripts and launcher files. Prefers the configured
-- path, then a folder beside the project, then the system temp dir.
function vo.ResolveScratchDir(cfg)
  if cfg and cfg.scratch_dir and cfg.scratch_dir ~= "" then
    return cfg.scratch_dir
  end

  local ok, proj_path = pcall(function()
    return select(2, r.EnumProjects(-1, ""))
  end)
  if ok and proj_path and proj_path ~= "" then
    local dir = proj_path:match("^(.*)[/\\][^/\\]*$")
    if dir and dir ~= "" then return dir .. "/vo_scratch" end
  end

  local tmp = os.getenv("TEMP") or os.getenv("TMPDIR") or "/tmp"
  return tmp .. "/vo_scratch"
end

function vo.EnsureDir(path)
  if not path or path == "" then return false end
  if r.RecursiveCreateDirectory then
    r.RecursiveCreateDirectory(path, 0)
  end
  return true
end

-- Is the speech backend usable? Returns ok, message.
-- Checked before any project mutation so a misconfigured backend can never
-- leave a half-cut session behind.
function vo.IsBackendReady(cfg)
  local bin = cfg and cfg.whisper_bin or ""
  if bin == "" then
    return false, "No whisper-cli path is set. Open ajsfx VO Settings."
  end
  -- A bare command name is resolved by the shell via PATH, so it can't be
  -- stat'd here; only an explicit path is checked for existence.
  if bin:find("[/\\]") and not vo.FileExists(bin) then
    return false, "whisper-cli not found at:\n" .. bin
  end

  local model = cfg and cfg.whisper_model or ""
  if model == "" then
    return false, "No Whisper model is set. Open ajsfx VO Settings."
  end
  if not vo.FileExists(model) then
    return false, "Whisper model not found at:\n" .. model
  end

  return true, "Ready"
end

--------------------------------
-- Coupled layer: async transcription
--------------------------------

-- Run whisper-cli detached, with an ImGui progress window and a working Cancel.
-- Deliberately duplicated from pvx.RunPVXAsync (SPEC.md §11): extracting a
-- shared runner while neither tool has been exercised in REAPER would risk
-- breaking the one that currently works.
--
-- `opts` is optional: { on_progress = f(info), duration = <source seconds> }.
-- on_progress fires at most twice a second with the latest decode position,
-- { seconds, percent, duration }, so a caller can say how far into the file
-- whisper has got instead of just "running".
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.RunWhisperAsync(cfg, argv, scratch_dir, on_done, on_cancel, on_error, opts)
  opts = opts or {}
  local timeout_s = (cfg and cfg.timeout_s) or 1800

  local log_file  = scratch_dir .. "/whisper_log.txt"
  local done_file = scratch_dir .. "/whisper_done.txt"
  os.remove(done_file)
  -- The log too: the batch reuses one scratch dir, and the new process only
  -- truncates the log once it is actually running -- asynchronously. The first
  -- poll for file N+1 fires immediately, and without this it reads file N's
  -- leftover tail and reports the WRONG FILE's position as progress.
  os.remove(log_file)

  local is_win = vo.IsWindows()

  local quoted = {}
  for _, a in ipairs(argv) do
    quoted[#quoted + 1] = vo.QuoteArg(a, is_win and "Windows" or "Other")
  end
  local cmd_str = table.concat(quoted, " ")

  local exe_name = (argv[1]:match("[/\\]([^/\\]+)$") or argv[1])
  if is_win and not exe_name:lower():find("%.exe$") then
    exe_name = exe_name .. ".exe"
  end

  local launched
  if is_win then
    -- Same two-file launch as PVX: a .bat runs the command and writes the exit
    -- code, and a .vbs starts the .bat fully hidden and asynchronously. The
    -- VBScript hop sidesteps the nested cmd.exe quoting that makes a direct
    -- detached launch unreliable.
    local bat, vbs = scratch_dir .. "/vo_run.bat", scratch_dir .. "/vo_launch.vbs"
    local log_win, done_win = log_file:gsub("/", "\\"), done_file:gsub("/", "\\")

    local fb = io.open(bat, "w")
    if not fb then on_error("Cannot write launcher batch file: " .. bat) return end
    fb:write("@echo off\r\n")
    fb:write(cmd_str .. ' > "' .. log_win .. '" 2>&1\r\n')
    fb:write('echo %ERRORLEVEL% > "' .. done_win .. '"\r\n')
    fb:close()

    local fv = io.open(vbs, "w")
    if not fv then on_error("Cannot write VBScript launcher: " .. vbs) return end
    fv:write('Set oShell = CreateObject("WScript.Shell")\r\n')
    fv:write('oShell.Run "cmd /c " & Chr(34) & "' ..
             bat:gsub("/", "\\"):gsub('"', '""') .. '" & Chr(34), 0, False\r\n')
    fv:close()

    -- ExecProcess, not os.execute: os.execute goes through cmd.exe, which
    -- flashes a console and steals focus ON EVERY LAUNCH -- once per queue
    -- item on a Verify run. ExecProcess spawns wscript directly, windowless;
    -- -2 means don't wait. nil is the only failure signal.
    launched = r.ExecProcess('wscript.exe //nologo //B "' .. vbs:gsub("/", "\\") .. '"', -2) ~= nil
  else
    launched = os.execute(string.format("(%s > %s 2>&1; echo $? > %s) &",
      cmd_str,
      vo.QuoteArg(log_file, "Other"),
      vo.QuoteArg(done_file, "Other")))
  end

  if not launched then
    on_error("Failed to launch whisper-cli")
    return
  end

  local function read_log()
    local lf = io.open(log_file, "r")
    if not lf then return "" end
    local text = lf:read("a")
    lf:close()
    return text or ""
  end

  -- nil means NOT FINISHED. See vo.ParseExitFile: the launcher creates this
  -- file with `>` and writes the code into it a moment later, so an empty read
  -- is a race, not an exit code.
  local function finished()
    local f = io.open(done_file, "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return vo.ParseExitFile(text)
  end

  -- Mid-run progress: the log the completion path reads at the end is already
  -- being written line by line, so it can be tailed while whisper is still in
  -- it. Only the last few KB are read, and only when the file has grown --
  -- polling a log that reaches megabytes on a long read must not itself cost
  -- anything noticeable per frame.
  local PROGRESS_INTERVAL = 0.5
  local PROGRESS_TAIL     = 8192
  local progress_at, progress_size = 0, -1
  local progress          = nil

  local function poll_progress(now)
    if now - progress_at < PROGRESS_INTERVAL then return end
    progress_at = now

    local lf = io.open(log_file, "rb")
    if not lf then return end
    local size = lf:seek("end") or 0
    if size == progress_size then lf:close() return end
    progress_size = size

    local seeked = size > PROGRESS_TAIL
    lf:seek("set", math.max(0, size - PROGRESS_TAIL))
    local tail = lf:read("a") or ""
    lf:close()

    -- A tail read starts mid-line; that fragment is dropped rather than
    -- parsed, so a half-written timestamp can't be read as a real position.
    if seeked then tail = tail:gsub("^[^\r\n]*[\r\n]+", "", 1) end

    local info = vo.LatestWhisperProgress(tail)
    if not info then return end
    info.duration = opts.duration
    progress = info
    if opts.on_progress then opts.on_progress(info) end
  end

  local ok_im, im = pcall(function()
    package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
    return require('imgui')('0.9.3')
  end)

  if not ok_im then
    -- No ReaImGui: block without UI rather than failing outright.
    local deadline = r.time_precise() + timeout_s
    while true do
      local code = finished()
      if code then on_done(code, read_log()) return end
      local now = r.time_precise()
      poll_progress(now)
      if now > deadline then on_cancel() return end
    end
  end

  local ctx        = im.CreateContext('VO Transcribe')
  local start_time = r.time_precise()
  local cancelled  = false
  local spinner    = { "|", "/", "-", "\\" }
  local spin       = 0

  local function kill()
    if is_win then
      os.execute('taskkill /F /IM "' .. exe_name .. '" > NUL 2>&1')
    else
      os.execute("pkill -f " .. vo.QuoteArg(exe_name, "Other") .. " 2>/dev/null")
    end
    cancelled = true
  end

  local function poll()
    if cancelled then return end

    local elapsed = r.time_precise() - start_time
    if elapsed > timeout_s then
      kill(); on_cancel(); return
    end

    local code = finished()
    if code then on_done(code, read_log()) return end

    poll_progress(r.time_precise())

    spin = (spin % #spinner) + 1
    if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
      ctx = im.CreateContext('VO Transcribe')
    end

    im.SetNextWindowSize(ctx, 460, 172, im.Cond_FirstUseEver)
    local visible, open = im.Begin(ctx, 'ajsfx VO — Transcribing', true,
      im.WindowFlags_NoCollapse)

    local pressed_cancel = false
    if visible then
      -- opts.label lets a queued caller (Verify) say WHICH item this decode
      -- is -- "item 12 of 65" -- instead of the generic session line.
      im.Text(ctx, spinner[spin] .. "  " .. (opts.label or "Transcribing session audio…"))
      im.Spacing(ctx)
      local where = vo.FormatWhisperProgress(progress, opts.duration)
      im.TextDisabled(ctx, where and ("decoding " .. where) or "starting up…")
      im.TextDisabled(ctx, string.format("%.0fs elapsed (timeout %ds)", elapsed, timeout_s))
      im.Spacing(ctx)
      im.TextDisabled(ctx, "Nothing in the project is changed until this finishes.")
      im.Spacing(ctx)
      im.Separator(ctx)
      im.Spacing(ctx)
      pressed_cancel = im.Button(ctx, "Cancel")
    end

    -- Always End after Begin; skipping it corrupts ImGui's push/pop stack.
    im.End(ctx)

    if pressed_cancel or not open then
      kill(); on_cancel(); return
    end

    r.defer(poll)
  end

  r.defer(poll)
end

-- Download a URL to dest_path with a progress window and working Cancel.
-- Detached curl via the same two-file launch as RunWhisperAsync; deliberately
-- parallel to it rather than a shared refactor (VO/SPEC.md §11).
-- curl -L follows the HF/GitHub redirects; --fail turns HTTP errors into a
-- non-zero exit instead of saving an error page.
-- UNVERIFIED outside REAPER — see VO/SPEC.md §9.
function vo.RunDownloadAsync(cfg, url, dest_path, expected_bytes, on_done, on_cancel, on_error)
  local scratch = vo.ResolveScratchDir(cfg)
  vo.EnsureDir(scratch)
  local timeout_s = 3600  -- generous fixed cap; large models/binaries take a while
  local is_win    = vo.IsWindows()

  local log_file  = scratch .. "/vo_download_log.txt"
  local done_file = scratch .. "/vo_download_done.txt"
  os.remove(done_file)

  local argv = { "curl", "-L", "--fail", "-o", dest_path, url }
  local quoted = {}
  for _, a in ipairs(argv) do
    quoted[#quoted + 1] = vo.QuoteArg(a, is_win and "Windows" or "Other")
  end
  local cmd_str = table.concat(quoted, " ")

  local launched
  if is_win then
    local bat, vbs = scratch .. "/vo_dl.bat", scratch .. "/vo_dl.vbs"
    local log_win, done_win = log_file:gsub("/", "\\"), done_file:gsub("/", "\\")
    local fb = io.open(bat, "w")
    if not fb then on_error("Cannot write launcher batch file: " .. bat) return end
    fb:write("@echo off\r\n")
    fb:write(cmd_str .. ' > "' .. log_win .. '" 2>&1\r\n')
    fb:write('echo %ERRORLEVEL% > "' .. done_win .. '"\r\n')
    fb:close()
    local fv = io.open(vbs, "w")
    if not fv then on_error("Cannot write VBScript launcher: " .. vbs) return end
    fv:write('Set oShell = CreateObject("WScript.Shell")\r\n')
    fv:write('oShell.Run "cmd /c " & Chr(34) & "' ..
             bat:gsub("/", "\\"):gsub('"', '""') .. '" & Chr(34), 0, False\r\n')
    fv:close()
    -- Same windowless ExecProcess launch as RunWhisperAsync, same reason:
    -- os.execute's cmd.exe hop flashes a console and steals focus.
    launched = r.ExecProcess('wscript.exe //nologo //B "' .. vbs:gsub("/", "\\") .. '"', -2) ~= nil
  else
    launched = os.execute(string.format("(%s > %s 2>&1; echo $? > %s) &",
      cmd_str, vo.QuoteArg(log_file, "Other"), vo.QuoteArg(done_file, "Other")))
  end
  if not launched then on_error("Failed to launch curl") return end

  -- nil means NOT FINISHED. See vo.ParseExitFile: the launcher creates this
  -- file with `>` and writes the code into it a moment later, so an empty read
  -- is a race, not an exit code.
  local function finished()
    local f = io.open(done_file, "r")
    if not f then return nil end
    local text = f:read("a")
    f:close()
    return vo.ParseExitFile(text)
  end

  local function read_log()
    local lf = io.open(log_file, "r")
    if not lf then return "" end
    local t = lf:read("a") or ""
    lf:close()
    return #t > 600 and ("…" .. t:sub(-600)) or t
  end

  local function fail_partial(msg)
    os.remove(dest_path)
    local tail = read_log()
    on_error(tail ~= "" and (msg .. "\n" .. tail) or msg)
  end

  local ok_im, im = pcall(function()
    package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
    return require('imgui')('0.9.3')
  end)

  local start_time = r.time_precise()

  if not ok_im then
    -- No ReaImGui: block without UI.
    while true do
      local code = finished()
      if code then
        if code == 0 and vo.VerifyDownloadSize(dest_path, expected_bytes) then on_done()
        else fail_partial("Download failed or incomplete (curl exit " .. code .. ").") end
        return
      end
      if r.time_precise() - start_time > timeout_s then fail_partial("Download timed out.") return end
    end
  end

  local ctx       = im.CreateContext('VO Download')
  local cancelled = false
  local spinner   = { "|", "/", "-", "\\" }
  local spin      = 0

  local function kill()
    if is_win then os.execute('taskkill /F /IM curl.exe > NUL 2>&1')
    else os.execute("pkill -f curl 2>/dev/null") end
    cancelled = true
  end

  local function poll()
    if cancelled then return end
    local elapsed = r.time_precise() - start_time
    if elapsed > timeout_s then kill(); fail_partial("Download timed out.") return end

    local code = finished()
    if code then
      if code == 0 and vo.VerifyDownloadSize(dest_path, expected_bytes) then on_done()
      else fail_partial("Download failed or incomplete (curl exit " .. code .. ").") end
      return
    end

    spin = (spin % #spinner) + 1
    if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
      ctx = im.CreateContext('VO Download')
    end
    im.SetNextWindowSize(ctx, 460, 160, im.Cond_FirstUseEver)
    local visible, open = im.Begin(ctx, 'ajsfx VO — Downloading', true, im.WindowFlags_NoCollapse)
    local pressed_cancel = false
    if visible then
      local got = vo.FileSize(dest_path)
      im.Text(ctx, spinner[spin] .. "  Downloading…")
      im.Spacing(ctx)
      im.TextDisabled(ctx, string.format("%s of ~%s",
        got and vo.FormatBytes(got) or "0 B", vo.FormatBytes(expected_bytes)))
      im.Spacing(ctx)
      im.TextDisabled(ctx, string.format("%.0fs elapsed (timeout %ds)", elapsed, timeout_s))
      im.Spacing(ctx); im.Separator(ctx); im.Spacing(ctx)
      pressed_cancel = im.Button(ctx, "Cancel")
    end
    im.End(ctx)  -- always End after Begin
    if pressed_cancel or not open then kill(); os.remove(dest_path); on_cancel() return end
    r.defer(poll)
  end

  r.defer(poll)
end

-- Extract a zip into dest_dir and return the list of extracted file paths.
-- tar ships with Windows 10 >= 1803 and reads zip; PowerShell Expand-Archive is
-- the fallback. UNVERIFIED outside REAPER — see VO/SPEC.md §9.
function vo.ExtractZip(zip_path, dest_dir)
  vo.EnsureDir(dest_dir)
  local is_win = vo.IsWindows()
  local q = function(s) return vo.QuoteArg(s, is_win and "Windows" or "Other") end

  local ok = os.execute(string.format("tar -xf %s -C %s", q(zip_path), q(dest_dir)))
  if not ok and is_win then
    ok = os.execute(string.format(
      'powershell -NoProfile -Command "Expand-Archive -Force -Path %s -DestinationPath %s"',
      q(zip_path), q(dest_dir)))
  end
  if not ok then return false, "Could not extract " .. zip_path end

  -- Walk dest_dir for a file listing.
  local entries = {}
  local lister = is_win
    and ('dir /b /s ' .. ('"' .. dest_dir:gsub("/", "\\") .. '"'))
    or  ('find ' .. q(dest_dir) .. ' -type f')
  local p = io.popen(lister)
  if p then
    for line in p:lines() do
      local trimmed = line:match("^%s*(.-)%s*$")
      if trimmed ~= "" then entries[#entries + 1] = trimmed:gsub("\\", "/") end
    end
    p:close()
  end
  return true, entries
end

-- Run a tiny real transcription of a generated silent WAV to force whisper to
-- initialize its device, then read the backend out of the log.
-- UNVERIFIED outside REAPER — see VO/SPEC.md §9.
function vo.ProbeBackendDevice(cfg, on_result)
  local scratch = vo.ResolveScratchDir(cfg)
  vo.EnsureDir(scratch)
  local wav = scratch .. "/vo_probe.wav"
  vo.WriteSilentWav(wav, 1.0)  -- 1s of silence; defined below

  local argv = vo.BuildWhisperArgv(cfg, wav, scratch .. "/vo_probe")

  -- Reuse the whisper runner so device init + log capture match a real run.
  vo.RunWhisperAsync(cfg, argv, scratch,
    function(_code, log) on_result(vo.ParseBackendFromLog(log or "")) end,
    function() on_result({ device = "unknown" }) end,
    function(_msg) on_result({ device = "unknown" }) end)
end

-- Minimal 16-bit mono 16kHz WAV of `seconds` of silence (whisper resamples
-- internally, so 16kHz is fine). Pure file writer.
function vo.WriteSilentWav(path, seconds)
  local rate, bits, ch = 16000, 16, 1
  local n = math.floor(rate * (seconds or 0.2))
  local data_bytes = n * (bits // 8) * ch
  local function u32(v) return string.char(v&255,(v>>8)&255,(v>>16)&255,(v>>24)&255) end
  local function u16(v) return string.char(v&255,(v>>8)&255) end
  local f = io.open(path, "wb")
  if not f then return false end
  f:write("RIFF"); f:write(u32(36 + data_bytes)); f:write("WAVE")
  f:write("fmt "); f:write(u32(16)); f:write(u16(1)); f:write(u16(ch))
  f:write(u32(rate)); f:write(u32(rate * ch * (bits//8)))
  f:write(u16(ch * (bits//8))); f:write(u16(bits))
  f:write("data"); f:write(u32(data_bytes)); f:write(string.rep("\0", data_bytes))
  f:close()
  return true
end

--------------------------------
-- Coupled layer: transcript gap repair
--------------------------------

-- A SOURCE-time amplitude probe over the audio behind `path`, built on the
-- first usable project item currently playing it. The take accessor reasons in
-- project time, so the wrapper converts through that item's placement; a probe
-- outside the item's coverage answers nil, which every pure consumer already
-- reads as "nothing measurable there". Also reports the source's full duration
-- so gap finding can see a swallowed tail.
-- Returns: probe or nil, destroy (ALWAYS call it), duration or nil.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
-- Length of a media file in seconds, without touching the project. A bare
-- PCM source, not vo.MakeSourceProbe: progress only needs the denominator, and
-- that path inserts a temporary track and item to get sample access.
-- Returns nil when the file cannot be opened.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.SourceDuration(path)
  if not (r.PCM_Source_CreateFromFile and r.GetMediaSourceLength) then return nil end
  local src = r.PCM_Source_CreateFromFile(path)
  if not src then return nil end
  local len = r.GetMediaSourceLength(src)
  if r.PCM_Source_Destroy then r.PCM_Source_Destroy(src) end
  if not len or len <= 0 then return nil end
  return len
end

function vo.MakeSourceProbe(path)
  -- An item that shows the WHOLE file probes in place ...
  for _, info in ipairs(vo.CollectProjectSpans()) do
    if info.path == path and not info.skip then
      local take = r.GetActiveTake(info.item)
      local src  = take and r.GetMediaItemTake_Source(take)
      local full = src and r.GetMediaSourceLength
                   and r.GetMediaSourceLength(src) or nil
      local shown = (info.length or 0) * (info.playrate or 1)
      if full and (info.start_offs or 0) <= 0.01 and shown >= full - 0.01 then
        local probe, destroy = vo.MakeTakeProbe(take)
        if probe then
          local function probe_src(t0, t1)
            return probe(vo.SourceTimeToProject(t0, info),
                         vo.SourceTimeToProject(t1, info))
          end
          return probe_src, destroy, full
        end
        destroy()
      end
    end
  end
  -- ... but a session already cut into clips has no such item, and a take
  -- accessor is bounded by its item: probing the first clip that references
  -- the file reads silence everywhere outside that clip's little window.
  -- That is how gap repair measured "no speech" in a 28-second hole full of
  -- takes and silently repaired nothing -- on exactly the session shape it
  -- was built for. A temporary full-length item is the only window that can
  -- see the whole source.
  return vo.MakeTempSourceProbe(path)
end

-- A probe over the whole of `path` through a temporary full-length item on a
-- temporary track, both removed by the returned destroy. Project time equals
-- source time on this item (position 0, offset 0), so no conversion is
-- needed. Callers hold the probe only across a synchronous scan -- never
-- across a defer -- so the temporary track's lifetime stays invisible.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.MakeTempSourceProbe(path)
  if not (r.InsertTrackAtIndex and r.AddMediaItemToTrack
          and r.AddTakeToMediaItem and r.PCM_Source_CreateFromFile) then
    return nil, function() end, nil
  end
  local src = r.PCM_Source_CreateFromFile(path)
  local duration = src and r.GetMediaSourceLength
                   and r.GetMediaSourceLength(src) or nil
  if not src or not duration or duration <= 0 then
    return nil, function() end, nil
  end

  r.PreventUIRefresh(1)
  r.InsertTrackAtIndex(r.CountTracks(0), false)
  local track = r.GetTrack(0, r.CountTracks(0) - 1)
  local item  = r.AddMediaItemToTrack(track)
  local take  = r.AddTakeToMediaItem(item)
  r.SetMediaItemTake_Source(take, src)
  r.SetMediaItemInfo_Value(item, "D_POSITION", 0.0)
  r.SetMediaItemInfo_Value(item, "D_LENGTH", duration)

  local probe, destroy_probe = vo.MakeTakeProbe(take)
  local cleaned = false
  local function destroy()
    if cleaned then return end
    cleaned = true
    destroy_probe()
    r.DeleteTrack(track)
    r.PreventUIRefresh(-1)
  end
  if not probe then
    destroy()
    return nil, function() end, nil
  end
  return probe, destroy, duration
end

-- The coupled half of gap repair (see "Pure layer: transcript gap repair"):
-- probe the audio behind the transcript's holes, and for each hole that holds
-- speech, re-run whisper on just that span and fold the recovered words in.
--
-- Always calls `on_done(words, report)`: with the original words and a nil
-- report when there is nothing to do (no item to probe, no floor, no suspect
-- gap), or with the merged words and { spans, added, notes } after repairs.
-- A repair run that fails leaves that gap as it was and says so in `notes` --
-- a failed rescue must not cost the transcription that already succeeded.
--
-- The floor comes from the transcript's own inter-word gaps, same as boundary
-- snapping. A transcript with NO decoded words has no gaps to measure, so a
-- fully swallowed file cannot be repaired this way -- only a file with words
-- on at least one side of the hole, which is the confirmed failure shape.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.RepairTranscriptGaps(cfg, source_path, scratch, prefix, words, on_done, on_cancel)
  -- A hole that cannot be judged must still be NAMED: "no probe, so nothing
  -- was repaired" and "checked, and it is genuine silence" look identical
  -- from the outside, and the first one silently costs takes. The report's
  -- notes are how the difference reaches the user.
  local function unchecked_report(duration, why)
    local gaps = vo.TranscriptGapSpans(words, duration, cfg)
    if #gaps == 0 then return nil end
    local notes = {}
    for _, g in ipairs(gaps) do
      notes[#notes + 1] = string.format(
        "gap at %s-%s could not be checked: %s",
        vo.FormatTime(g.from), vo.FormatTime(g.to), why)
    end
    return { spans = {}, added = 0, notes = notes }
  end

  local probe, destroy, duration = vo.MakeSourceProbe(source_path)
  if not probe then
    destroy()
    on_done(words, unchecked_report(duration,
      "the source audio could not be probed"))
    return
  end

  local floor_db = vo.ResolveGate(vo.InterWordGaps(words), probe, cfg)
  local plans    = vo.PlanGapRepairs(words, duration, floor_db, probe, cfg)
  destroy()

  if #plans == 0 then
    on_done(words, floor_db == nil
      and unchecked_report(duration, "no noise floor could be measured")
      or nil)
    return
  end

  local repairs, notes = {}, {}
  local i = 0
  local run
  run = function()
    i = i + 1
    if i > #plans then
      local merged, added = vo.MergeRepairWords(words, repairs)
      on_done(merged, { spans = plans, added = added, notes = notes })
      return
    end

    local plan = plans[i]
    local out  = string.format("%s_repair%d", prefix, i)
    local function note_failure(why)
      notes[#notes + 1] = string.format("gap at %s-%s not repaired: %s",
        vo.FormatTime(plan.from), vo.FormatTime(plan.to), why)
    end

    local argv = vo.BuildWhisperArgv(cfg, source_path, out, plan)
    vo.RunWhisperAsync(cfg, argv, scratch,
      function(code, log)
        if code ~= 0 then
          note_failure(string.format("whisper-cli exited with code %d", code))
        else
          local f = io.open(out .. ".json", "r")
          if not f then
            note_failure("whisper-cli wrote no JSON")
          else
            -- t_dtw from an -ot offset run is absolute source time (verified
            -- against a 415s-offset decode), so anchors merge without any
            -- conversion, same as t0/t1.
            repairs[#repairs + 1] = { span = plan, words = vo.ParseWhisperJSON(f:read("a")) }
            f:close()
          end
        end
        run()
      end,
      on_cancel,
      function(err) note_failure(tostring(err)); run() end)
  end
  run()
end

--------------------------------
-- Coupled layer: take marker I/O
--------------------------------

-- Read every item's take markers, paired with the item's source coverage --
-- the input shape vo.CountingMarkers wants. Chunk reads are the only way at
-- the ranges (the API cannot see the length); a few hundred items times a few
-- KB at the rebuild throttle is fine, and the result is grouped per source
-- path so markers from one recording can never claim a line in another.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.CollectTakeMarkers(items)
  local by_path = {}
  for _, info in ipairs(items or {}) do
    if info.item and info.path and not info.skip then
      local ok, chunk = r.GetItemStateChunk(info.item, "", false)
      if ok then
        local group = by_path[info.path]
        if not group then group = {}; by_path[info.path] = group end
        group[#group + 1] = {
          coverage = vo.SourceCoverageRanges({ info })[1],
          markers  = vo.ParseTKMChunk(chunk),
          info     = info,
        }
      end
    end
  end
  return by_path
end

-- Mint a marker id: 3 base36 chars, unique against `taken`. Entropy comes
-- from os.clock and a stride, and uniqueness from the check, not the source.
function vo.MintMarkerId(taken)
  local chars = "0123456789abcdefghijklmnopqrstuvwxyz"
  local seed = math.floor((os.clock() * 1e6) % 46656)
  for tries = 0, 46655 do
    local v = (seed + tries * 7 + 13) % 46656
    local id = chars:sub(math.floor(v / 1296) + 1, math.floor(v / 1296) + 1)
             .. chars:sub(math.floor(v / 36) % 36 + 1, math.floor(v / 36) % 36 + 1)
             .. chars:sub(v % 36 + 1, v % 36 + 1)
    if not (taken and taken[id]) then
      if taken then taken[id] = true end
      return id
    end
  end
  return nil
end

-- Write `markers` (source-time { start, stop, asset, id }) into the item's
-- take, replacing the tool's previous lines but PRESERVING the user's own
-- markers (no ` ~id` suffix): the tool never deletes what it did not write.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.WriteTakeMarkers(item, markers)
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok then return false, "cannot read item chunk" end
  local keep = {}
  for _, m in ipairs(vo.ParseTKMChunk(chunk)) do
    local _, id = vo.ParseMarkerName(m.name)
    if not id then keep[#keep + 1] = m end
  end
  for _, mk in ipairs(markers or {}) do
    keep[#keep + 1] = {
      pos    = mk.start,
      name   = vo.FormatMarkerName(mk.asset, mk.id),
      color  = 0,
      length = (mk.stop or mk.start) - mk.start,
    }
  end
  local patched, did = vo.PatchTKMChunk(chunk, keep)
  if not did then return false, "item has multiple takes" end
  r.SetItemStateChunk(item, patched, false)
  return true
end

-- Write ONE marker onto an item, keeping every marker already in it.
--
-- The safe form of "mark this take": vo.PlanMarkerAdd decides what the item
-- should hold, this writes it. Returns ok, added, why -- `added` false with ok
-- true means this line was already marked over that audio and nothing changed,
-- which is a no-op to report, not an error.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.AddMarkerToItem(item, add)
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok then return false, false, "cannot read item chunk" end
  local list, added = vo.PlanMarkerAdd(vo.ParseTKMChunk(chunk), add)
  if not added then return true, false end
  local wrote, why = vo.WriteTakeMarkers(item, list)
  return wrote and true or false, wrote and true or false, why
end

-- Move ONE marker to another line, in place, keeping every other marker.
--
-- The write half of vo.PlanMarkerRetarget; the rule worth testing lives in the
-- planner, and this does only chunk in, chunk out. Returns ok, changed, why --
-- `changed` false with ok true means the marker already named that line, which
-- is a no-op to report, not an error.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.RetargetMarkerOnItem(item, marker_id, new_asset)
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok then return false, false, "cannot read item chunk" end
  local list, changed = vo.PlanMarkerRetarget(vo.ParseTKMChunk(chunk),
                                              marker_id, new_asset)
  if not changed then return true, false end
  local wrote, why = vo.WriteTakeMarkers(item, list)
  return wrote and true or false, wrote and true or false, why
end

-- Take ONE marker off an item, keeping every other marker.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.RemoveMarkerFromItem(item, marker_id)
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok then return false, false, "cannot read item chunk" end
  local list, changed = vo.PlanMarkerRemove(vo.ParseTKMChunk(chunk), marker_id)
  if not changed then return true, false end
  local wrote, why = vo.WriteTakeMarkers(item, list)
  return wrote and true or false, wrote and true or false, why
end

-- Transcribe a list of unique source files in sequence, reusing cached
-- transcripts.
--
-- Built for batches. A project where every line was recorded to its own file
-- is not the exception -- it is a normal delivery shape, and it means 50+
-- sources in one run. Two consequences are baked in here rather than left to
-- the caller:
--
--   1. `cb.on_source(path, words, i, total)` fires as EACH file finishes, so
--      the caller can write that file's transcript immediately. Handing back
--      one big map at the end would mean a cancel at file 40 threw away 39
--      completed whisper runs, which on a large model is most of an hour.
--   2. A file that fails does NOT abort the batch. Its reason is collected and
--      the run moves to the next source; `cb.on_done(results, failures)` reports
--      them together at the end. One unreadable wav must not cost the other 56.
--
-- A user CANCEL is different from a failure and does stop the run: it is an
-- instruction, not an accident. Everything already written stays written.
--
-- Every parsed result then passes through vo.RepairTranscriptGaps before it is
-- reported, so a transcript with a swallowed window (see "Pure layer:
-- transcript gap repair") is mended before the sidecar is ever written. A
-- source with nothing to repair passes through untouched, at the cost of a
-- probe pass; a repair that fails reports itself in the per-source report and
-- keeps the unrepaired words.
--
-- cb = { on_source, on_progress, on_done, on_cancel, on_error }.
-- on_progress(path, index, total, info) fires while a file is still decoding,
-- at most twice a second, with { seconds, percent, duration } -- the within-
-- file half of the count on_source reports between files.
-- on_error is called only for
-- a failure that stopped the whole run (there are none left today); per-source
-- failures arrive through on_done. on_source receives the gap-repair report
-- (or nil) as its fifth argument; on_done receives all reports, keyed by path,
-- as its third.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.TranscribeSources(cfg, sources, cb)
  cb = cb or {}
  local scratch = vo.ResolveScratchDir(cfg)
  vo.EnsureDir(scratch)

  local results, failures, repair_reports = {}, {}, {}
  local index = 0

  local function finish(source, words, report)
    results[source.path] = words
    if report then repair_reports[source.path] = report end
    if cb.on_source then cb.on_source(source.path, words, index, #sources, report) end
  end

  local function fail(source, reason)
    failures[#failures + 1] = { path = source.path, reason = reason }
  end

  local step
  step = function()
    index = index + 1
    if index > #sources then
      if cb.on_done then cb.on_done(results, failures, repair_reports) end
      return
    end

    local source    = sources[index]
    local key       = vo.CacheKey(source.path, source.size, cfg)
    local prefix    = scratch .. "/" .. key
    local json_path = prefix .. ".json"

    -- The raw whisper JSON is what is cached; repair happens on the way out on
    -- both paths, so a cache hit gets the same mended transcript a fresh run
    -- would. An old .csv beside the wav is NOT a cache hit: it has no anchors,
    -- and serving it would quietly reintroduce the bug the anchors fix.
    local function repair_then_finish(words)
      vo.RepairTranscriptGaps(cfg, source.path, scratch, prefix, words,
        function(merged, report)
          finish(source, merged, report)
          step()
        end,
        cb.on_cancel)
    end

    if not cfg.force_retranscribe and vo.FileExists(json_path) then
      local f = io.open(json_path, "r")
      local words = vo.ParseWhisperJSON(f:read("a"))
      f:close()
      repair_then_finish(words)
      return
    end

    -- The denominator for "decoding 7:56 of 38:44". Probed once per file, and
    -- only for display: a source whose length can't be read still transcribes,
    -- it just reports a bare position instead of a fraction.
    local duration = source.duration or vo.SourceDuration(source.path)

    local argv = vo.BuildWhisperArgv(cfg, source.path, prefix)
    vo.RunWhisperAsync(cfg, argv, scratch,
      function(code, log)
        if code ~= 0 then
          fail(source, string.format("whisper-cli exited with code %d\n\n%s",
                                     code, vo.LogTailForError(log, 1500)))
          step()
          return
        end
        local f = io.open(json_path, "r")
        if not f then
          fail(source, "whisper-cli reported success but wrote no JSON:\n" .. json_path)
          step()
          return
        end
        local words = vo.ParseWhisperJSON(f:read("a"))
        f:close()
        repair_then_finish(words)
      end,
      cb.on_cancel,
      function(err) fail(source, err); step() end,
      { duration = duration,
        on_progress = cb.on_progress and function(info)
          cb.on_progress(source.path, index, #sources, info)
        end or nil })
  end

  step()
end

--------------------------------
-- Coupled layer: transcript files
--------------------------------

function vo.ReadTranscript(source_path)
  local path = vo.TranscriptPath(source_path)
  if not path then return nil, "No source path." end
  local f = io.open(path, "r")
  -- This exact string is how vo.TranscriptState tells "never transcribed" from
  -- "transcribed, but the file is broken". Do not reword it without changing
  -- that check too.
  if not f then return nil, "no transcript" end
  local text = f:read("a")
  f:close()
  return vo.ParseTranscript(text)
end

-- Returns false plus a reason rather than raising: a read-only or network media
-- directory must leave the session usable, just not persistent.
function vo.WriteTranscript(source_path, words, meta)
  local path = vo.TranscriptPath(source_path)
  if not path then return false, "No source path." end
  local f, err = io.open(path, "w")
  if not f then return false, tostring(err or ("Could not write " .. path)) end
  f:write(vo.SerializeTranscript(words, meta))
  f:close()
  return true, path
end

-- What Sources puts in its Transcribed column.
--   "no"    -- no transcript file beside the audio
--   "error" -- a file is there but could not be parsed; reason says why
--   "stale" -- parsed, but the audio has changed size since it was made
--   "yes"   -- parsed and current
-- Returns: state, parsed transcript or nil, reason or nil.
function vo.TranscriptState(source_path)
  local parsed, why = vo.ReadTranscript(source_path)
  if not parsed then
    if why == "no transcript" then return "no" end
    return "error", nil, why
  end
  local size = vo.FileSize(source_path)
  if size and parsed.source_bytes and parsed.source_bytes > 0
     and size ~= parsed.source_bytes then
    return "stale", parsed
  end
  -- Same length is not the same audio. The fingerprint is the check that catches
  -- an in-place re-render or edit; size is only the cheap first pass.
  if parsed.source_hash and parsed.source_hash ~= "" then
    local hash = vo.FileFingerprint(source_path)
    if hash and hash ~= parsed.source_hash then
      return "stale", parsed
    end
  end
  return "yes", parsed
end

--------------------------------
-- Coupled layer: launching sibling scripts
--------------------------------

-- AddRemoveReaScript is idempotent: it returns the EXISTING command ID when the
-- script is already in the action list, so this both installs and launches. A
-- hardcoded _RS… command ID would be machine-local and is never used.
--
-- `filename` is a sibling of the VO scripts, i.e. one level above lib/.
function vo.LaunchSibling(filename)
  local here = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
  if not here then return false, "Could not resolve the script directory." end
  local path = here .. "../" .. filename
  local id = r.AddRemoveReaScript(true, 0, path, true)
  if not id or id == 0 then
    return false, "Could not register " .. filename .. " as an action."
  end
  r.Main_OnCommand(id, 0)
  return true, path
end

--------------------------------
-- Coupled layer: amplitude probing
--------------------------------

vo.PROBE_FLOOR_DB = -150.0  -- what digital silence reports as, instead of -inf

-- An amplitude reader over one take, for vo.SnapBoundary and
-- vo.MeasureNoiseFloor. Times are PROJECT time, matching the accessor's own
-- base -- convert source times with vo.SourceTimeToProject before probing.
--
-- Returns the probe and a destroy function. ALWAYS call destroy, including on
-- the error path: an undestroyed accessor holds the media file open.
function vo.MakeTakeProbe(take)
  if not take or not r.CreateTakeAudioAccessor then return nil, function() end end
  local acc = r.CreateTakeAudioAccessor(take)
  if not acc then return nil, function() end end

  local source = r.GetMediaItemTake_Source(take)
  local rate   = source and r.GetMediaSourceSampleRate and
                 r.GetMediaSourceSampleRate(source) or 48000
  if not rate or rate <= 0 then rate = 48000 end
  local chans  = source and r.GetMediaSourceNumChannels and
                 r.GetMediaSourceNumChannels(source) or 1
  if not chans or chans < 1 then chans = 1 end

  -- The accessor's clock starts at the take's own start, but every caller
  -- reasons in PROJECT time -- word timings, span edges, gaps. Converting
  -- HERE is what makes that true for an item anywhere on the timeline: with
  -- the shift missing, a session whose recording sat at 10:00 handed every
  -- probe a time outside the accessor, got nil, and silently lost the noise
  -- floor -- and with it the whole boundary snap.
  local item = r.GetMediaItemTake_Item and r.GetMediaItemTake_Item(take)
  local item_pos = item and r.GetMediaItemInfo_Value(item, "D_POSITION") or 0

  local function probe(t0, t1)
    t0, t1 = t0 - item_pos, t1 - item_pos
    local n = math.floor((t1 - t0) * rate)
    if n < 1 then return nil end
    -- Cap the read so a pathological window cannot allocate without bound.
    if n > 65536 then n = 65536 end
    local buf = r.new_array(n * chans)
    buf.clear()
    if r.GetAudioAccessorSamples(acc, rate, chans, t0, n, buf) ~= 1 then return nil end
    local sum = 0.0
    for i = 1, n * chans do
      local v = buf[i] or 0.0
      sum = sum + v * v
    end
    local rms = math.sqrt(sum / (n * chans))
    if rms <= 0 then return vo.PROBE_FLOOR_DB end
    return 20.0 * math.log(rms, 10)
  end

  return probe, function() r.DestroyAudioAccessor(acc) end
end

-- How many FRAMES one batched read may ask for. The same ceiling the per-window
-- probe puts on a single read, so a pathological item cannot allocate without
-- bound; the profile below simply makes many windows share one read of this
-- size instead of taking one read each.
vo.PROFILE_MAX_FRAMES = 65536

-- Take every Nth sample when measuring a window's level, rather than all of
-- them. 1 measures every sample.
--
-- This is where the time actually was, and it took measuring to find: profiling
-- 125 seconds of audio across 40 items costs 10ms of buffer allocation, 63ms of
-- REAPER decoding the audio, and 398ms summing squares in Lua. The sum is 84%
-- of it, so batching the reads -- which only ever attacked the 10ms -- measured
-- as a wash, and no arrangement of block sizes changed that.
--
-- Sound to subsample because of what the number is FOR. Each window is 10ms and
-- its level is compared against a noise floor to answer "is this speech or is
-- this room?". At 48kHz every 4th sample still averages 120 of them per window,
-- and the RMS of a subsample is an unbiased estimate of the RMS of the whole
-- for any signal that is not conspiring with the stride. Speech and room tone
-- are not.
vo.PROFILE_STRIDE = 4

-- Every `step`-long window between `from` and `to` (PROJECT time), as dB, in
-- order. The batched form of calling MakeTakeProbe in a loop.
--
-- Same arithmetic, far fewer calls. Profiling an item window-by-window costs
-- one r.new_array ALLOCATION and one GetAudioAccessorSamples CALL per window --
-- at a 10ms step that is 100 of each per second of audio, so a 3.5s take took
-- 350 of each and a 1720s recording took 172,000. Reading a block once and
-- slicing the windows out of it in Lua does the identical multiply-adds over
-- the identical samples, but amortises the allocation and the API call across
-- ~136 windows at a time.
--
-- The arithmetic per window is identical to the loop it replaces -- the same
-- multiply-adds over the same sample count -- and `spw` is fixed rather than
-- recomputed per window because every window in the old loop was a whole step
-- and floored to the same count anyway, so pinning it removes a float wobble
-- rather than introducing one.
--
-- It is NOT bit-identical, and pretending otherwise would be the wrong claim to
-- build on. A batch asks the accessor for one run of frames, so a sample's time
-- inside it is reached by a different float path than the same sample reached
-- window by window (k*spw/rate against k*step). On real audio that is inaudible
-- and unmeasurable; against a synthetic source that steps between amplitudes at
-- an exact instant it can flip a single sample at that instant. What must hold
-- is that vo.EffectiveRoom reaches the same edge either way, and the tests
-- assert that rather than value equality.
--
-- Returns: the array of dB values (PROBE_FLOOR_DB where a read failed, which is
-- what the per-window caller substituted for a nil probe), or nil if no
-- accessor could be made.
function vo.MakeTakeProfile(take, from, to, step)
  if not take or not r.CreateTakeAudioAccessor then return nil end
  if not (from and to and step) or step <= 0 or to <= from then return nil end

  local acc = r.CreateTakeAudioAccessor(take)
  if not acc then return nil end

  local source = r.GetMediaItemTake_Source(take)
  local rate   = source and r.GetMediaSourceSampleRate and
                 r.GetMediaSourceSampleRate(source) or 48000
  if not rate or rate <= 0 then rate = 48000 end
  local chans  = source and r.GetMediaSourceNumChannels and
                 r.GetMediaSourceNumChannels(source) or 1
  if not chans or chans < 1 then chans = 1 end

  -- The accessor's clock starts at the take's own start; callers reason in
  -- project time. Same conversion MakeTakeProbe makes, and for the same reason.
  local item = r.GetMediaItemTake_Item and r.GetMediaItemTake_Item(take)
  local item_pos = item and r.GetMediaItemInfo_Value(item, "D_POSITION") or 0

  local spw = math.floor(step * rate)
  local total = math.floor((to - from) / step)
  if spw < 1 or total < 1 then
    r.DestroyAudioAccessor(acc)
    return nil
  end

  local per_block = math.floor(vo.PROFILE_MAX_FRAMES / spw)
  if per_block < 1 then per_block = 1 end

  local stride = math.floor(vo.PROFILE_STRIDE or 1)
  if stride < 1 then stride = 1 end

  local out = {}
  local w = 0
  while w < total do
    local nw     = math.min(per_block, total - w)
    local frames = nw * spw
    local buf    = r.new_array(frames * chans)
    buf.clear()
    -- Associated exactly as the per-window probe associated it -- (pos + k*step)
    -- - item_pos, not (pos - item_pos) + k*step. The two differ in the last
    -- bits, and this is the one difference between batched and per-window
    -- reading that is ours to remove rather than the accessor's.
    local t0 = (from + w * step) - item_pos
    local ok = r.GetAudioAccessorSamples(acc, rate, chans, t0, frames, buf) == 1
    for k = 0, nw - 1 do
      if not ok then
        out[#out + 1] = vo.PROBE_FLOOR_DB
      else
        -- Divided by what was actually summed, not by the window size: a
        -- stride that does not divide the window evenly would otherwise report
        -- every window a little quiet, which is a floor comparison shifted.
        local base, sum, cnt = k * spw * chans, 0.0, 0
        for i = 1, spw * chans, stride do
          local v = buf[base + i] or 0.0
          sum = sum + v * v
          cnt = cnt + 1
        end
        local rms = (cnt > 0) and math.sqrt(sum / cnt) or 0.0
        out[#out + 1] = (rms <= 0) and vo.PROBE_FLOOR_DB
                        or (20.0 * math.log(rms, 10))
      end
    end
    w = w + nw
  end

  r.DestroyAudioAccessor(acc)
  return out
end

--------------------------------
-- Coupled layer: project inspection
--------------------------------

-- Inspect one item. Items that cannot be transcribed come back with a `skip`
-- reason rather than aborting the run, so the report can list them and the rest
-- of the session still processes.
--
-- Shared by the selection-scoped and project-scoped collectors below so the
-- skip rules cannot drift apart: an item the Overview shows as usable but
-- Sources refuses to transcribe (or vice versa) is a bug report waiting to
-- happen, and the only defence is one copy of the rules.
local function inspect_item(item)
  local take = r.GetActiveTake(item)
  local info = { item = item, pos = r.GetMediaItemInfo_Value(item, "D_POSITION") }

  if not take then
    info.skip = "no active take"
  elseif r.TakeIsMIDI(take) then
    info.skip = "MIDI take"
  else
    local source   = r.GetMediaItemTake_Source(take)
    local path     = source and r.GetMediaSourceFileName(source, "") or ""
    local playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")

    if path == "" then
      info.skip = "take has no source file"
    elseif playrate <= 0 then
      info.skip = "reversed or zero playrate"
    elseif math.abs(playrate - 1.0) > 1e-6 then
      -- MapWordsToProject handles playrate correctly and is unit-tested for
      -- it, but SPEC.md §8 keeps v1 conservative until that path has been
      -- exercised against a real stretched item in REAPER.
      info.skip = string.format("playrate %.3f is not 1.0", playrate)
    else
      info.path       = path
      info.length     = r.GetMediaItemInfo_Value(item, "D_LENGTH")
      info.start_offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
      info.playrate   = playrate
      info.track      = r.GetMediaItem_Track(item)
    end
  end

  return info
end

-- Inspect the selected items.
function vo.CollectSourceSpans()
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    items[#items + 1] = inspect_item(r.GetSelectedMediaItem(0, i))
  end
  table.sort(items, function(a, b) return (a.pos or 0) < (b.pos or 0) end)
  return items
end

-- Inspect EVERY item in the project. The Overview is a whole-session picture, so
-- unlike the cutting path it cannot key off the selection: the point is to see
-- lines you are not currently looking at.
function vo.CollectProjectSpans()
  local items = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    items[#items + 1] = inspect_item(r.GetMediaItem(0, i))
  end
  table.sort(items, function(a, b) return (a.pos or 0) < (b.pos or 0) end)
  return items
end

-- Position, length, track and lock state of EVERY item in the project.
--
-- Deliberately not built on inspect_item: clustering has to see items that
-- window skips (MIDI, time-stretched), because a crossfade partner still has to
-- travel with its neighbour whether or not this tool understands its contents.
-- No take is touched -- this is geometry only.
function vo.CollectItemGeometry()
  local out = {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local item = r.GetMediaItem(0, i)
    out[#out + 1] = {
      item   = item,
      index  = i,
      track  = r.GetMediaItem_Track(item),
      pos    = r.GetMediaItemInfo_Value(item, "D_POSITION"),
      length = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
      locked = r.GetMediaItemInfo_Value(item, "C_LOCK") >= 0.5,
      -- 0 means ungrouped. Grouped items weld across tracks; see vo.ClusterItems.
      group  = r.GetMediaItemInfo_Value(item, "I_GROUPID"),
    }
  end
  return out
end

-- Modification time of each source file, as a comparable number.
--
-- Lua has no stat, so this needs help from outside. js_ReaScriptAPI provides it
-- silently and is used when present; on macOS and Linux a single batched `stat`
-- covers the rest. On Windows without js_ReaScriptAPI nothing here can read a
-- file date without flashing a console window per file, so the map comes back
-- empty and the caller falls back to filename order and says so -- guessing at
-- "oldest" would reorder a session wrongly and silently.
--
-- Returns the map and HOW MANY of the requested paths it managed to date. A
-- count rather than a boolean because a partial read is the dangerous case: if
-- three of four files date, the fourth still sorts last with nothing said about
-- it, and the caller can only warn about that if it knows the difference.
function vo.SourceModifiedTimes(paths)
  local ages, found = {}, 0
  paths = paths or {}
  if #paths == 0 then return ages, 0 end

  if r.JS_File_Stat then
    for _, path in ipairs(paths) do
      -- retval 0 is success; the times come back as "YYYY-MM-DD HH:MM:SS".
      local retval, _size, _accessed, modified = r.JS_File_Stat(path)
      if retval == 0 and type(modified) == "string" then
        local y, mo, d, h, mi, s =
          modified:match("(%d+)-(%d+)-(%d+)%s+(%d+):(%d+):(%d+)")
        if y then
          ages[path] = os.time({ year = tonumber(y), month = tonumber(mo),
                                 day = tonumber(d), hour = tonumber(h),
                                 min = tonumber(mi), sec = tonumber(s) })
          found = found + 1
        end
      end
    end
    if found > 0 then return ages, found end
  end

  if not vo.IsWindows() then
    local quoted, wanted = {}, {}
    for _, path in ipairs(paths) do
      quoted[#quoted + 1] = "'" .. path:gsub("'", "'\\''") .. "'"
      wanted[path] = true
    end
    -- GNU coreutils and BSD stat disagree on the flag, so try both in one shell.
    local cmd = "stat -c '%Y %n' " .. table.concat(quoted, " ")
             .. " 2>/dev/null || stat -f '%m %N' " .. table.concat(quoted, " ")
             .. " 2>/dev/null"
    local pipe = io.popen(cmd)
    if pipe then
      for line in pipe:lines() do
        -- Only paths we asked about count: the `||` fallback can run both stats
        -- on a system where the first partly succeeds, and a path echoed back in
        -- a shape we did not send is not an answer to the question we asked.
        local stamp, path = line:match("^(%d+)%s+(.+)$")
        if stamp and path and wanted[path] and ages[path] == nil then
          ages[path] = tonumber(stamp)
          found = found + 1
        end
      end
      pipe:close()
    end
  end

  return ages, found
end

-- The distinct source files present in the project, as a sorted array of paths.
-- This is the list of transcripts worth trying to read.
function vo.ProjectSourcePaths(items)
  local seen, paths = {}, {}
  for _, info in ipairs(items or {}) do
    if info.path and not seen[info.path] then
      seen[info.path] = true
      paths[#paths + 1] = info.path
    end
  end
  table.sort(paths)
  return paths
end

-- Find the live item playing a given SOURCE-time position, and that position in
-- project time. Returns nil when the audio is not in the project at all -- a
-- transcript can outlive the item that produced it.
--
-- This resolves correctly both BEFORE and AFTER a cut, and that is not luck:
-- splitting an item leaves each piece pointing at the same source file with an
-- adjusted D_STARTOFFS, so a source-time coordinate still lands in exactly one
-- piece's coverage range. Nothing here needs to know whether a cut has happened.
-- Two passes, and the order matters.
--
-- Once a recording has been cut, its items ABUT in source time: one ends at
-- exactly the source offset where the next begins. A take's start is precisely
-- that instant, so a single inclusive test matches the item that ENDS there --
-- the take before the one being asked about. The project time came out right,
-- because the boundary is the same instant either way, so it looked like the
-- cursor landing correctly on the wrong item, and only on takes whose padding
-- had not moved their edge inward.
--
-- So: the item that CONTAINS the time wins, upper bound exclusive. Only if no
-- item contains it does one that merely ends there answer -- which is what
-- keeps a time at the very end of the last item resolvable at all.
function vo.ResolveSourceTime(source_path, source_start, items)
  if not source_path or source_path == "" or not source_start then return nil end

  local function find(inclusive_end)
    for _, info in ipairs(items or {}) do
      if info.path == source_path and not info.skip then
        local range = vo.SourceCoverageRanges({ info })[1]
        if range and source_start >= range.from
           and (source_start < range.to
                or (inclusive_end and source_start <= range.to)) then
          return info.item, vo.SourceTimeToProject(source_start, info), info
        end
      end
    end
    return nil
  end

  local item, proj, info = find(false)
  if item then return item, proj, info end
  return find(true)
end

-- Cut resolves a span to the item holding its AUDIO -- the one covering the
-- largest share of it -- rather than to whichever item covers the start
-- instant. The instant lookup breaks on RE-cuts: takes cut earlier abut
-- exactly at word boundaries, and float error at a shared edge lands the
-- instant in the PREVIOUS item's tail, where the span then clamps to nothing
-- and is skipped as too short. A majority cannot be fooled by an edge.
-- `min_fraction` keeps the strictness the instant lookup provided: a span
-- whose audio is mostly gone (trimmed since transcription) still refuses to
-- resolve, rather than cutting a truncated take under the full line's name.
function vo.ResolveSourceSpanForCut(source_path, start, stop, items, min_fraction)
  if not source_path or source_path == "" or not start or not stop then return nil end
  min_fraction = min_fraction or 0.95

  local length = stop - start
  if length <= 0 then
    -- A zero-width span has no majority to take; the instant lookup is all
    -- there is to ask.
    return vo.ResolveSourceTime(source_path, start, items)
  end

  local best, best_cover = nil, 0
  for _, info in ipairs(items or {}) do
    if info.path == source_path and not info.skip then
      local range = vo.SourceCoverageRanges({ info })[1]
      if range then
        local cover = math.min(stop, range.to) - math.max(start, range.from)
        if cover > best_cover then best, best_cover = info, cover end
      end
    end
  end

  if not best or best_cover / length < min_fraction then return nil end
  return best.item, vo.SourceTimeToProject(start, best), best
end

-- The item holding a take, when the take's own start may no longer be in the
-- project at all.
--
-- Trimming an item's head throws away source time, and a take that began in
-- what was trimmed has no covered start -- so vo.ResolveSourceTime, which asks
-- about one instant, answers nothing and the row goes blank even though most of
-- the take is still sitting there. This asks about the take's WHOLE span and
-- takes the item covering most of it.
--
-- Returns item, the project time of the first covered moment, info, and the
-- coverage: "full" when the take's start is really there, "partial" when the
-- answer is a best effort over what is left. Callers that must not act on a
-- truncated take -- cutting, above all -- check that flag; navigation does not
-- care, because taking the user near a take beats taking them nowhere.
function vo.ResolveSourceSpan(source_path, source_start, source_stop, items)
  -- With no span to weigh, the instant is all there is to ask.
  if not source_stop or not source_start or source_stop <= source_start then
    local item, proj, info = vo.ResolveSourceTime(source_path, source_start, items)
    if item then return item, proj, info, "full" end
    return nil
  end

  -- MAJORITY, never the start instant. The instant has two ways to lie after a
  -- cut, and both were live faults:
  --
  --   * padding leaves a GAP between takes, so a take's recognised start can
  --     touch the END of the take before it -- and the mark, the audition and
  --     the row all landed one take early;
  --   * the recording track still carries the unnamed remainders between
  --     takes, and one of those can CONTAIN the start instant while holding a
  --     few milliseconds of the take -- the row then points at a fragment and
  --     the line's Sel never reaches Selects at all.
  --
  -- The measure is how much of the ITEM is this take, not how much of the take
  -- the item holds. Both are needed, and only this one settles both faults: a
  -- leftover holding a sliver of the take is mostly other things, while the
  -- clip cut for the take is entirely the take. Ranking by the take's side
  -- instead loses the reverse case -- whisper inflates a final word's end into
  -- the pause after it, so a span can be LONGER than its own clip, and the
  -- leftover that follows then holds more of the span than the clip does.
  -- Absolute overlap breaks ties, which is what decides between two items that
  -- are each wholly inside the take.
  local best, best_share, best_overlap = nil, -1, 0
  for _, cand in ipairs(items or {}) do
    if cand.path == source_path and not cand.skip then
      local range = vo.SourceCoverageRanges({ cand })[1]
      if range then
        local from    = math.max(source_start, range.from)
        local to      = math.min(source_stop,  range.to)
        local overlap = to - from
        if overlap > 0 then
          local length = range.to - range.from
          local share  = (length > 0) and (overlap / length) or 0
          if share > best_share + 1e-9
             or (math.abs(share - best_share) <= 1e-9 and overlap > best_overlap) then
            best, best_share, best_overlap = { cand, from, range }, share, overlap
          end
        end
      end
    end
  end

  -- Nothing holds any of it: an item that at least touches the start beats no
  -- answer at all, which is what keeps a time at the very end of the last item
  -- resolvable.
  if not best then
    local item, proj, info = vo.ResolveSourceTime(source_path, source_start, items)
    if item then return item, proj, info, "full" end
    return nil
  end

  local cand, from, range = best[1], best[2], best[3]
  -- "full" means the take's own start is really in there; "partial" is a best
  -- effort over what is left of it. Cutting checks this, navigation does not.
  local full = source_start >= range.from and source_start < range.to
  return cand.item, vo.SourceTimeToProject(from, cand), cand,
         full and "full" or "partial"
end

-- Find a track by name, or create one directly below `track`.
-- Returns the track and whether this call created it, so a caller that shapes
-- folder depths can leave an already-placed track's depth alone.
function vo.EnsureTrackBelow(track, name)
  for i = 0, r.CountTracks(0) - 1 do
    local candidate = r.GetTrack(0, i)
    local _, existing = r.GetSetMediaTrackInfo_String(candidate, "P_NAME", "", false)
    if existing == name then return candidate, false end
  end

  -- IP_TRACKNUMBER is 1-based, so it is already the 0-based index *after* this
  -- track — exactly where the new one belongs.
  local insert_at = math.floor(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
  r.InsertTrackAtIndex(insert_at, true)
  local created = r.GetTrack(0, insert_at)
  r.GetSetMediaTrackInfo_String(created, "P_NAME", name, true)
  return created, true
end

-- The name a track answers to, falling back to its number when it has none.
local function track_label(track)
  local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if name and name ~= "" then return name end
  return string.format("Track %d",
    math.floor(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER")))
end

-- A track named `name`, nested as a CHILD of `parent`. The depth rule turns on
-- what the parent's depth WAS, so it is read before the insert.
--
-- Pull's destinations are children rather than siblings because a session's
-- Selects belong to the recording they came out of: collapsed, the recording
-- and everything cut from it read as one thing.
-- The children of `parent`, in track order: everything below it until the
-- folder closes. Depth accumulates -- a child that opens its own folder adds 1,
-- one that closes subtracts -- and the parent's own run ends when the running
-- total goes negative.
--
-- Only a folder HEADER has children. A plain track (depth 0) must return
-- nothing here: its running total starts at zero, so a complete folder sitting
-- below it -- some OTHER recording's +1 ... -1 -- nets back to zero without
-- ever going negative, and the scan would swallow that whole folder as if it
-- were this track's own. That is the wrong-Alts bug all over again, just with
-- the unbuilt recording sitting above the built one.
function vo.FolderChildren(parent)
  local out = {}
  if r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH") < 1 then return out end
  local first = math.floor(r.GetMediaTrackInfo_Value(parent, "IP_TRACKNUMBER"))
  local depth = 0
  for i = first, r.CountTracks(0) - 1 do
    local t = r.GetTrack(0, i)
    out[#out + 1] = t
    depth = depth + r.GetMediaTrackInfo_Value(t, "I_FOLDERDEPTH")
    if depth < 0 then break end
  end
  return out
end

-- A track named `name` among THIS parent's children, or nil.
--
-- Scoped to the folder, and that is the whole point. vo.EnsureTrackBelow
-- searches the project by name, which is right for a track that is meant to be
-- unique and wrong for these: every recording has its own "Selects", "Alts" and
-- "Review". With two recordings in a session the second one's build found the
-- FIRST one's Alts, decided it already existed, and nested nothing under itself
-- -- so the second recording's alts had nowhere of their own to go.
function vo.FindChildTrack(parent, name)
  for _, t in ipairs(vo.FolderChildren(parent)) do
    local _, existing = r.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
    if existing == name then return t end
  end
  return nil
end

function vo.EnsureChildTrack(parent, name)
  local parent_depth, child_depth =
    vo.FolderDepthForChild(r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH"))
  -- This parent's OWN child, or none. Deliberately NOT vo.EnsureTrackBelow:
  -- its search is project-wide, so with two recordings it would hand back the
  -- other one's "Alts" and this folder would never get its own.
  local existing = vo.FindChildTrack(parent, name)
  if existing then return existing end

  -- IP_TRACKNUMBER is 1-based, so it is already the 0-based index *after* the
  -- parent -- exactly where a first child belongs.
  local insert_at = math.floor(r.GetMediaTrackInfo_Value(parent, "IP_TRACKNUMBER"))
  r.InsertTrackAtIndex(insert_at, true)
  local child = r.GetTrack(0, insert_at)
  r.GetSetMediaTrackInfo_String(child, "P_NAME", name, true)
  -- Depths are shaped only on creation. An existing child already sits inside
  -- the folder, and rewriting its depth from the PARENT's current depth would
  -- hand the track that closes the folder a 0 — leaving the folder open to
  -- swallow whatever gets added below it.
  r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", parent_depth)
  r.SetMediaTrackInfo_Value(child, "I_FOLDERDEPTH", child_depth)
  return child
end

-- One destination child track per source track, nested under it.
--
-- Sorting lays audio out somewhere new every time rather than shuffling it in
-- place, so a run can never drop an item on top of audio it was not asked to
-- touch. One child PER SOURCE, not one for the lot: Cut pulls selects
-- onto per-character tracks, and collapsing ALEX and JORDAN onto a single track
-- would throw away the separation that step exists to create.
--
-- Every child of one run shares a run number, so a run reads as one set at a
-- glance and the run before it is still sitting there untouched.
--
-- Returns { [source_track] = destination_track } and the run number used.
function vo.EnsureSortChildTracks(source_tracks)
  source_tracks = source_tracks or {}

  local taken = {}
  for i = 0, r.CountTracks(0) - 1 do
    local _, name = r.GetSetMediaTrackInfo_String(r.GetTrack(0, i), "P_NAME", "", false)
    taken[name or ""] = true
  end

  local labels = {}
  for _, track in ipairs(source_tracks) do labels[track] = track_label(track) end

  local function child_name(track, run)
    return string.format("%s sorted %d", labels[track], run)
  end

  -- The run number is shared, so it has to be free for EVERY source at once.
  local run = 1
  while true do
    local free = true
    for _, track in ipairs(source_tracks) do
      if taken[child_name(track, run)] then free = false break end
    end
    if free then break end
    run = run + 1
  end

  local dest = {}
  for _, track in ipairs(source_tracks) do
    dest[track] = vo.EnsureChildTrack(track, child_name(track, run))
  end

  return dest, run
end

--------------------------------
-- Coupled layer: apply
--------------------------------

-- Find the item on `track` that contains `time`.
local function ItemContaining(track, time)
  for i = 0, r.CountTrackMediaItems(track) - 1 do
    local item = r.GetTrackMediaItem(track, i)
    local pos  = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local stop = pos + r.GetMediaItemInfo_Value(item, "D_LENGTH")
    if time >= pos - 1e-9 and time < stop - 1e-9 then return item end
  end
  return nil
end

-- A span shorter than this is not a cuttable clip. It matters beyond tidiness:
-- ApplyPlan splits at span.start and again at span.stop, but REAPER's
-- SplitMediaItem is a no-op when the split position lands on the item's own
-- edge. A span with stop == start therefore leaves the second split undone, so
-- `piece` is the WHOLE remainder of the item — and moving it sweeps every later
-- span's audio onto one track, orphaning the rest of the session. Degenerate
-- spans (a zero-duration recognizer word, or a span neighbour-clamped to nil
-- width) are skipped and reported rather than allowed to corrupt the take.
vo.MIN_SPLIT_LENGTH = 0.001  -- seconds

-- Split the session into its takes and NAME each one. Spans destined for
-- vo.DEST_IN_PLACE (unmatched audio) are left untouched instead.
--
-- It moves nothing. Where a take goes is Pull's question, and Pull answers it
-- from the name written here rather than from the match -- which is what lets
-- it serve a folder of rendered files that was never cut at all.
--
-- The name applied is the script's own filename, with no Append and no
-- override: two takes of one line SHOULD collide at this stage, because which
-- of them is the delivery is not a question cutting can answer.
--
-- Splitting rather than copying is deliberate (SPEC.md §4): with the pieces
-- physically separated it is obvious what has been cut and what has not.
-- Caller wraps this in core.Transaction so the whole run is one undo step.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
-- Returns: applied count, array of failure strings.
function vo.ApplyPlan(plan, source_track)
  local applied = 0
  local failures = {}
  local cfg = vo.LoadConfig()
  local fade_in  = vo.Opt(cfg, "cut_fade_in")
  local fade_out = vo.Opt(cfg, "cut_fade_out")

  for _, span in ipairs(plan) do
    local length = (span.stop or 0) - (span.start or 0)
    local item = ItemContaining(source_track, span.start)
    if span.dest == vo.DEST_IN_PLACE then
      -- Left exactly as recorded: not split, not moved, not renamed. Because the
      -- splits below happen at span.start AND span.stop, skipping the span means
      -- neither cut is made and the audio stays welded into the surrounding
      -- source item. Not a failure, and not counted as applied. Checked first so
      -- a degenerate unmatched span can't report a spurious "too short to cut".

    elseif length < vo.MIN_SPLIT_LENGTH then
      failures[#failures + 1] = string.format(
        "%s: span too short to cut (%.3fs at %.3fs) — skipped",
        span.name or "(unnamed)", length, span.start or 0)
    elseif not item then
      failures[#failures + 1] =
        string.format("%s: no item at %.3fs", span.name or "(unnamed)", span.start)
    else
      -- Split twice: the middle piece is the span. Guarded above so span.stop is
      -- strictly greater than span.start, keeping the second split real.
      local right = r.SplitMediaItem(item, span.start)
      local piece = right or item
      r.SplitMediaItem(piece, span.stop)

      -- Named where it lies: the LINE's delivered base name -- the script
      -- filename plus the line's Append, never a take suffix. Not span.name
      -- (which may carry _tkNN or a review prefix): which take is the delivery
      -- is not a question cutting can answer, so takes of one line SHOULD
      -- collide here. The Append is different -- it is part of the line's own
      -- name, and two lines sharing a filename are only tellable apart by it.
      -- Writing the bare filename would leave their takes claimed by both
      -- lines at once, which nothing downstream can resolve.
      local take = r.GetActiveTake(piece)
      if take then
        r.GetSetMediaItemTakeInfo_String(take, "P_NAME",
          span.deliver or span.asset or span.name or "", true)
      end
      -- Protective fades, shorter in than out, sitting inside the head/tail
      -- room the boundary placement just guaranteed.
      if fade_in  and fade_in  > 0 then
        r.SetMediaItemInfo_Value(piece, "D_FADEINLEN", fade_in)
      end
      if fade_out and fade_out > 0 then
        r.SetMediaItemInfo_Value(piece, "D_FADEOUTLEN", fade_out)
      end
      applied = applied + 1
    end
  end

  r.UpdateArrange()
  return applied, failures
end

-- Build the inline, non-modal summary shown after a Cut (Task 8: popups ask,
-- never tell). Returns an array of {text, warn} lines rather than a single
-- string: warn=true lines are the ones that need a warning colour, so the
-- caller never has to re-inspect the counts to decide how to render them.
--
-- The counts (matched/review/unmatched, clips cut) always fit on two lines
-- regardless of how many script lines were involved -- they are totals, not
-- a per-line dump. Skipped items and apply-time failures are NOT bounded the
-- same way (one entry per problem), but in practice both lists are capped by
-- the size of the current selection, which the user chose -- unlike, say, an
-- unbounded per-word transcript. They are still joined onto single lines
-- rather than one line each, so a bad run cannot blow out the counted table
-- height Task 6 relies on.
function vo.FormatCutSummary(plan, applied, skipped, failures)
  local counts = { match = 0, review = 0, unmatched = 0 }
  for _, span in ipairs(plan or {}) do
    counts[span.kind] = (counts[span.kind] or 0) + 1
  end

  local lines = {
    { text = string.format(
        "%d matched, %d for review, %d unmatched (left untouched on the source track).",
        counts.match, counts.review, counts.unmatched),
      warn = false },
    { text = string.format("%d clip(s) cut and named.", applied),
      warn = false },
  }

  if skipped and #skipped > 0 then
    lines[#lines + 1] = {
      text = string.format("%d item(s) skipped: %s", #skipped, table.concat(skipped, "; ")),
      warn = true,
    }
  end

  if failures and #failures > 0 then
    lines[#lines + 1] = {
      text = string.format("%d problem(s) while cutting: %s", #failures, table.concat(failures, "; ")),
      warn = true,
    }
  end

  return lines
end

return vo
