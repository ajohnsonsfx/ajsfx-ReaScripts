-- @description ajsfx VO Shared Library
-- @author ajsfx
-- @version 0.6
-- @changelog Transcript gap repair: a transcript hole of 5s+ that the audio says holds speech (whisper's swallowed-window failure) is re-run through whisper on just that span and the recovered words merged into the sidecar. New pure functions TranscriptGapSpans / PlanGapRepairs / MergeRepairWords, a span (-ot/-d) option on BuildWhisperArgv, and coupled MakeSourceProbe / RepairTranscriptGaps wired into TranscribeSources.
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
    local text    = trim(row[cols.text])
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
function vo.ResolveNames(lines, appends)
  appends = appends or {}
  for _, l in ipairs(lines or {}) do
    local extra = l.append_key and appends[l.append_key] or nil
    extra = extra and trim(extra) or ""
    l.deliver = (l.asset or "") .. extra
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
function vo.LoadScripts(entries, read_fn)
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
              sc.lines = vo.BuildScriptLines(rows, cols)
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
-- Returns: nil, or { from, to, phrase, cycles, words } (times in source seconds)
vo.LOOP_MAX_PHRASE  = 12
vo.LOOP_MIN_CYCLES  = 4
vo.LOOP_MIN_WORDS   = 12

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

  -- Sequence. A session is read roughly in script order, and that is the only
  -- evidence there is for placing a line too short to identify itself.
  order_weight         = 0.15,  -- score moved by reading in, or out of, order
  backbone_min_tokens  = 4,     -- shortest line trusted to establish the order

  pre_pad          = 0.150, -- seconds of head room before the first aligned word
  post_pad         = 0.250, -- seconds of tail after the last aligned word

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
  snap_head_room = 0.060, -- seconds of room before the measured speech onset
  snap_tail_room = 0.150, -- seconds of room after the measured speech end

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
  local subs = cfg and cfg.substitutions
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
  local subs = cfg and cfg.substitutions
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
  table.sort(pool, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    local la, lb = a.i1 - a.i0, b.i1 - b.i0
    if la ~= lb then return la > lb end
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
    if a.effective ~= b.effective then return a.effective > b.effective end
    local ma, mb = a.margin or 1.0, b.margin or 1.0
    if ma ~= mb then return ma > mb end
    -- A twelve-word match and a one-word match scoring the same are not equal
    -- evidence: only one of them could be an accident.
    local la, lb = a.i1 - a.i0, b.i1 - b.i0
    if la ~= lb then return la > lb end
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

  for i, s in ipairs(spans) do
    if snap then
      -- Where the speech in this span actually is. Whisper's word times put the
      -- surrounding pause INSIDE the span (see vo.FindSpeechBounds), so an edge
      -- has to be trimmed in to the sound before it is padded back out; without
      -- this every take runs to the next take and the clips tile the recording.
      -- Nothing found means the floor is untrustworthy here, so keep the edges.
      local sp0, sp1 = vo.FindSpeechBounds(s.raw_start, s.raw_stop, floor_db, probe, cfg)
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
      local start_hard = at_start - pre
      local prev_edge = spans[i - 1] and spans[i - 1].raw_stop
      if prev_edge and math.abs(prev_edge - s.raw_start) > 1e-3 then
        start_hard = math.max(start_hard, prev_edge)
      end
      local start_limit = start_hard
      local wb = word_end_before(words, s.raw_start)
      if wb then
        start_limit = math.max(start_limit, wb)
        if collapsed(wb, s.raw_start) then
          start_limit = settle(start_limit, start_hard, -1)
        end
      end

      local stop_hard = at_stop + post
      local next_edge = spans[i + 1] and spans[i + 1].raw_start
      if next_edge and math.abs(next_edge - s.raw_stop) > 1e-3 then
        stop_hard = math.min(stop_hard, next_edge)
      end
      local stop_limit = stop_hard
      local wa = word_start_after(words, s.raw_stop)
      if wa then
        stop_limit = math.min(stop_limit, wa)
        if collapsed(wa, s.raw_stop) then
          stop_limit = settle(stop_limit, stop_hard, 1)
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
      -- Colliding neighbours meet at the midpoint of their ORIGINAL gap, which
      -- keeps the result independent of the order spans were selected in.
      local mid = (prev.raw_stop + cur.raw_start) / 2
      -- Unless there was no gap. Whisper chains word times, so two takes can
      -- share an edge exactly -- and then "the midpoint" is that one instant,
      -- which hands back every millimetre of head room the take just won and
      -- leaves it cut on its own first syllable. A zero-width boundary is not
      -- evidence of anything; an onset belongs to the word that FOLLOWS it, so
      -- the later take's head wins and the earlier take's tail yields to it.
      if math.abs(cur.raw_start - prev.raw_stop) <= 1e-3 then
        prev.stop, prev.clamped = cur.start, true
      else
        if prev.stop > mid then prev.stop, prev.clamped = mid, true end
        if cur.start < mid then cur.start, cur.clamped = mid, true end
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
-- `-ml 1 -sow -ocsv` is the load-bearing combination: it forces one word per
-- segment and writes start,end,text as CSV, so no JSON library is needed.
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
  add("-ocsv")
  add("-ml", "1")  -- one word per segment; also enables token timestamps
  add("-sow")      -- split on word rather than mid-token
  add("-np")       -- no progress prints: we read the CSV, not stdout
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

  local preset = vo.DTWPresetForModel(cfg.whisper_model)
  if preset then add("-dtw", preset) end

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

--------------------------------
-- Pure layer: the transcript sidecar
--------------------------------

-- WORDS, not spans. A recording's transcription is a fact about the audio and
-- nothing else: no script, no mapping, no match. Storing whisper's own segment
-- grouping would store its guess at where lines divide, and the script -- not
-- the recogniser -- is what says that. `-ml 1` makes every whisper segment one
-- word anyway, so there is no grouping left to store.

vo.TRANSCRIPT_MARKER  = "ajsfx VO Transcript"
vo.TRANSCRIPT_VERSION = 1
vo.TRANSCRIPT_HEADER  = { "Start", "End", "Text" }

function vo.TranscriptPath(source_path)
  if not source_path or source_path == "" then return nil end
  return strip_ext(source_path) .. "_vo_transcript.csv"
end

-- `words` are in SOURCE time, as vo.ParseWhisperCSV produces them. This
-- function converts nothing, so it cannot silently write project times.
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
      parsed.words[#parsed.words + 1] = { t0 = t0, t1 = t1, text = row[3] or "" }
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
-- Words are grouped so a new paragraph starts after any word whose text ends
-- in `.`, `?` or `!` (optionally followed by a closing quote).
-- Returns: array of paragraphs, each an array of the original word tables (so
-- a caller needing per-word timing -- the detail panel's word interaction --
-- can index into the same objects vo.Paragraphs summarizes).
function vo.ParagraphWords(words)
  local paras, current = {}, {}
  for _, w in ipairs(words or {}) do
    current[#current + 1] = w
    if w.text:match("[%.%?%!]['\"]?$") then
      paras[#paras + 1] = current
      current = {}
    end
  end
  if #current > 0 then paras[#paras + 1] = current end
  return paras
end

-- vo.ParagraphWords, joined to display prose. Returns: array of paragraph
-- strings.
function vo.Paragraphs(words)
  local out = {}
  for _, para in ipairs(vo.ParagraphWords(words)) do
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
  "Name override", "Notes", "Keep", "Anchor", "Anchor start", "Anchor stop",
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
                  -- An anchor is the whole of what binds a take to its item;
                  -- dropping it would unbind every cut take on the next save.
                  or (e.anchor and e.anchor ~= "")
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
        e.anchor or "",
        e.anchor_start and string.format("%.3f", e.anchor_start) or "",
        e.anchor_stop  and string.format("%.3f", e.anchor_stop)  or "",
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
        -- Absent in files written before anchors existed; nil is correct there
        -- and means "this take is not bound to an item".
        anchor        = (row[10] and row[10] ~= "") and row[10] or nil,
        anchor_start  = tonumber(row[11] or ""),
        anchor_stop   = tonumber(row[12] or ""),
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

  -- Sources in a stable order, so take numbers do not shuffle between openings.
  local by_source = {}
  for _, sc in ipairs(input.matches or {}) do
    if sc and sc.path then by_source[#by_source + 1] = sc end
  end
  table.sort(by_source, function(a, b) return a.path < b.path end)

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
      take_index    = take_index,
      take_count    = take_count,
      script_row    = line and (line.index or line.row) or nil,
      user_status   = e.status,
      name_override = e.name_override,
      notes         = e.notes,
      is_primary    = false,
      user_select   = e.select or false,
      user_keep     = e.keep or false,
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
      user_select   = t and t.select or false,
      user_keep     = t and t.keep or false,
    }
  end

  local rows = {}

  -- Script order first: this is a script-shaped spreadsheet, so a line's takes
  -- sit together under it whether they were recorded in one session or five.
  for line_row, line in ipairs(lines) do
    local g = groups[line_row]
    if g and #g > 0 then
      table.sort(g, function(a, b)
        if a.source_order ~= b.source_order then return a.source_order < b.source_order end
        return (a.span.start or 0) < (b.span.start or 0)
      end)

      local built = {}
      for i, rec in ipairs(g) do
        built[#built + 1] = make_row(rec, line, i, #g)
      end

      -- The user's explicit Select IS the primary. There is no first/last
      -- fallback: guessing which take was meant is exactly what the Select
      -- column exists to stop, and a group with no select simply has no
      -- primary -- which Cut reports as needing a decision.
      local chosen
      for _, row in ipairs(built) do
        if row.user_select then chosen = row; break end
      end
      for _, row in ipairs(built) do
        row.is_primary = (row == chosen)
        rows[#rows + 1] = row
      end

      local p = planned_by_row[line_row]
      if p then
        for i, e in ipairs(p) do
          rows[#rows + 1] = planned_row(e, line, #g + i, #g + #p)
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
        take_count    = 0,
        script_row    = line.index or line.row,
        user_status   = t and t.status or nil,
        name_override = t and t.name_override or nil,
        notes         = t and t.notes or nil,
        is_primary    = false,
        user_select   = t and t.select or false,
      user_keep     = t and t.keep or false,
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
      select        = row.user_select or nil,
      keep          = row.user_keep or nil,
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
              verified = 0, flagged = 0, lines = 0 }
  local seen_asset = {}
  for _, row in ipairs(rows or {}) do
    n.total = n.total + 1
    if n[row.status] then n[row.status] = n[row.status] + 1 end
    if row.user_status and n[row.user_status] then
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
  { key = "snap_floor_percentile", kind = "number",
    default = vo.DEFAULTS.snap_floor_percentile },

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
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.RunWhisperAsync(cfg, argv, scratch_dir, on_done, on_cancel, on_error)
  local timeout_s = (cfg and cfg.timeout_s) or 1800

  local log_file  = scratch_dir .. "/whisper_log.txt"
  local done_file = scratch_dir .. "/whisper_done.txt"
  os.remove(done_file)

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

    launched = os.execute('wscript.exe //nologo //B "' .. vbs:gsub("/", "\\") .. '"')
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

  local function finished()
    local f = io.open(done_file, "r")
    if not f then return nil end
    local code = tonumber(f:read("l")) or -1
    f:close()
    return code
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
      if r.time_precise() > deadline then on_cancel() return end
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

    spin = (spin % #spinner) + 1
    if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
      ctx = im.CreateContext('VO Transcribe')
    end

    im.SetNextWindowSize(ctx, 460, 150, im.Cond_FirstUseEver)
    local visible, open = im.Begin(ctx, 'ajsfx VO — Transcribing', true,
      im.WindowFlags_NoCollapse)

    local pressed_cancel = false
    if visible then
      im.Text(ctx, spinner[spin] .. "  Transcribing session audio…")
      im.Spacing(ctx)
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
    launched = os.execute('wscript.exe //nologo //B "' .. vbs:gsub("/", "\\") .. '"')
  else
    launched = os.execute(string.format("(%s > %s 2>&1; echo $? > %s) &",
      cmd_str, vo.QuoteArg(log_file, "Other"), vo.QuoteArg(done_file, "Other")))
  end
  if not launched then on_error("Failed to launch curl") return end

  local function finished()
    local f = io.open(done_file, "r")
    if not f then return nil end
    local code = tonumber(f:read("l")) or -1
    f:close()
    return code
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
function vo.MakeSourceProbe(path)
  for _, info in ipairs(vo.CollectProjectSpans()) do
    if info.path == path and not info.skip then
      local take = r.GetActiveTake(info.item)
      local probe, destroy = vo.MakeTakeProbe(take)
      if probe then
        local src = r.GetMediaItemTake_Source(take)
        local duration = src and r.GetMediaSourceLength
                         and r.GetMediaSourceLength(src) or nil
        local function probe_src(t0, t1)
          return probe(vo.SourceTimeToProject(t0, info),
                       vo.SourceTimeToProject(t1, info))
        end
        return probe_src, destroy, duration
      end
      destroy()
    end
  end
  return nil, function() end, nil
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
  local probe, destroy, duration = vo.MakeSourceProbe(source_path)
  if not probe then
    destroy()
    on_done(words, nil)
    return
  end

  local floor_db = vo.MeasureNoiseFloor(vo.InterWordGaps(words), probe, cfg)
  local plans    = vo.PlanGapRepairs(words, duration, floor_db, probe, cfg)
  destroy()

  if #plans == 0 then
    on_done(words, nil)
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
          local f = io.open(out .. ".csv", "r")
          if not f then
            note_failure("whisper-cli wrote no CSV")
          else
            repairs[#repairs + 1] = { span = plan, words = vo.ParseWhisperCSV(f:read("a")) }
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
-- cb = { on_source, on_done, on_cancel, on_error }. on_error is called only for
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

    local source   = sources[index]
    local key      = vo.CacheKey(source.path, source.size, cfg)
    local prefix   = scratch .. "/" .. key
    local csv_path = prefix .. ".csv"

    -- The raw whisper CSV is what is cached; repair happens on the way out on
    -- both paths, so a cache hit gets the same mended transcript a fresh run
    -- would.
    local function repair_then_finish(words)
      vo.RepairTranscriptGaps(cfg, source.path, scratch, prefix, words,
        function(merged, report)
          finish(source, merged, report)
          step()
        end,
        cb.on_cancel)
    end

    if not cfg.force_retranscribe and vo.FileExists(csv_path) then
      local f = io.open(csv_path, "r")
      local words = vo.ParseWhisperCSV(f:read("a"))
      f:close()
      repair_then_finish(words)
      return
    end

    local argv = vo.BuildWhisperArgv(cfg, source.path, prefix)
    vo.RunWhisperAsync(cfg, argv, scratch,
      function(code, log)
        if code ~= 0 then
          fail(source, string.format("whisper-cli exited with code %d\n\n%s",
                                     code, log:sub(-1500)))
          step()
          return
        end
        local f = io.open(csv_path, "r")
        if not f then
          fail(source, "whisper-cli reported success but wrote no CSV:\n" .. csv_path)
          step()
          return
        end
        local words = vo.ParseWhisperCSV(f:read("a"))
        f:close()
        repair_then_finish(words)
      end,
      cb.on_cancel,
      function(err) fail(source, err); step() end)
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
function vo.EnsureChildTrack(parent, name)
  local parent_depth, child_depth =
    vo.FolderDepthForChild(r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH"))
  local child, created = vo.EnsureTrackBelow(parent, name)
  -- Depths are shaped only on creation. An existing child already sits inside
  -- the folder, and rewriting its depth from the PARENT's current depth would
  -- hand the track that closes the folder a 0 — leaving the folder open to
  -- swallow whatever gets added below it.
  if created then
    r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", parent_depth)
    r.SetMediaTrackInfo_Value(child, "I_FOLDERDEPTH", child_depth)
  end
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
