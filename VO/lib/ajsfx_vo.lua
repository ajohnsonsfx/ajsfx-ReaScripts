-- @description ajsfx VO Shared Library
-- @author ajsfx
-- @version 0.1
-- @noindex
-- @about Shared logic for ajsfx VO ScriptMatch.
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
vo.REQUIRED_COLUMNS = { "line_id", "text", "asset" }
vo.OPTIONAL_COLUMNS = { "speaker", "type" }

vo.DEFAULT_COLUMN_MAPPING = {
  line_id = "LineID",
  text    = "Text",
  asset   = "AudioAsset",
  speaker = "Speaker",
  type    = "Type",
}

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
-- filters: { skip_values = {...}, speaker = "NPC", type = "Barks" }
-- Speaker/Type filters are inert when the corresponding column is unmapped.
-- Returns: array of { line_id, text, asset, speaker, type, row }
function vo.BuildScriptLines(rows, cols, filters)
  filters = filters or {}

  local skip = {}
  for _, v in ipairs(filters.skip_values or vo.DEFAULT_SKIP_VALUES) do
    skip[fold(v)] = true
  end

  local want_speaker = filters.speaker and fold(filters.speaker) or nil
  local want_type    = filters.type    and fold(filters.type)    or nil
  if want_speaker == "" then want_speaker = nil end
  if want_type    == "" then want_type    = nil end

  local lines = {}
  for i, row in ipairs(rows or {}) do
    local text    = trim(row[cols.text])
    local asset   = trim(row[cols.asset])
    local speaker = cols.speaker and trim(row[cols.speaker]) or nil
    local ltype   = cols.type    and trim(row[cols.type])    or nil

    local keep = text ~= "" and asset ~= "" and not skip[fold(asset)]
    if keep and want_speaker and speaker then keep = fold(speaker) == want_speaker end
    if keep and want_type    and ltype   then keep = fold(ltype)   == want_type    end

    if keep then
      lines[#lines + 1] = {
        line_id = trim(row[cols.line_id]),
        text    = text,
        asset   = asset,
        speaker = speaker,
        type    = ltype,
        row     = i,
      }
    end
  end

  return lines
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

--------------------------------
-- Pure layer: configuration
--------------------------------

vo.DEFAULTS = {
  accept_threshold = 0.80,  -- score at or above this is a confident match
  review_floor     = 0.55,  -- below this the words are left unconsumed
  margin_threshold = 0.05,  -- lead over the runner-up line needed to be confident
  anchor_count     = 3,     -- rarest tokens per line used to propose candidates
  window_slack     = 0.30,  -- window lengths tried around the script line length
  pre_pad          = 0.150, -- seconds of head room before the first aligned word
  post_pad         = 0.250, -- seconds of tail after the last aligned word

  -- Per-session toggles (see SPEC.md §4). Defaults cut and name every take
  -- identically, leaving the user to audition and delete.
  use_alts_track   = false,
  suffix_alt_names = false,
  primary_take     = "last", -- "last" or "first"

  review_prefix           = "REVIEW_",
  unmatched_prefix        = "UNMATCHED_",
  unmatched_snippet_words = 4,
  max_name_length         = 96,
}

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
-- Two-row DP: O(#a * #b) time, O(#b) space.
function vo.Levenshtein(a, b)
  local n, m = #a, #b
  if n == 0 then return m end
  if m == 0 then return n end

  local prev, cur = {}, {}
  for j = 0, m do prev[j] = j end

  for i = 1, n do
    cur[0] = i
    local ai = a[i]
    for j = 1, m do
      local sub = prev[j - 1] + ((ai == b[j]) and 0 or 1)
      local del = prev[j] + 1
      local ins = cur[j - 1] + 1
      local best = sub
      if del < best then best = del end
      if ins < best then best = ins end
      cur[j] = best
    end
    prev, cur = cur, prev
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
-- Returns: array of { i0, i1, start, stop, score, margin, line_idx, line_id, asset }
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
            -- Shrink to the tightest window that still achieves the best score.
            -- The start is derived from the anchor's offset within the line, so
            -- a word the recognizer dropped *before* the anchor pushes it one
            -- token early — onto the tail of the previous line. That phantom
            -- token overlaps the previous span and would cost this line its
            -- match during selection. A shorter window scoring the same is
            -- strictly better: it excludes audio that isn't part of the line.
            local i0, i1 = start, best_stop
            while i1 > i0 and score_window(i0 + 1, i1) >= best_score do i0 = i0 + 1 end
            while i1 > i0 and score_window(i0, i1 - 1) >= best_score do i1 = i1 - 1 end

            candidates[#candidates + 1] = {
              i0       = i0,
              i1       = i1,
              start    = word_tokens[i0].t0,
              stop     = word_tokens[i1].t1,
              score    = best_score,
              line_idx = line_idx,
              line_id  = lines[line_idx].line_id,
              asset    = lines[line_idx].asset,
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

-- Greedy interval scheduling over scored candidates: best score first, ties
-- broken by the wider margin, skipping anything overlapping an accepted span.
-- Returns: chronologically ordered spans, each with a `kind`.
function vo.SelectSpans(candidates, cfg)
  local ordered = {}
  for i, c in ipairs(candidates) do ordered[i] = c end

  table.sort(ordered, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    local ma, mb = a.margin or 1.0, b.margin or 1.0
    if ma ~= mb then return ma > mb end
    return a.i0 < b.i0
  end)

  local chosen = {}
  for _, c in ipairs(ordered) do
    local kind = vo.Classify(c.score, c.margin or 1.0, cfg)
    if kind then
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
        span.kind = kind
        chosen[#chosen + 1] = span
      end
    end
  end

  table.sort(chosen, function(a, b) return a.i0 < b.i0 end)
  return chosen
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

--------------------------------
-- Pure layer: boundaries
--------------------------------

-- Pad each span outwards, then clamp so neighbours never overlap and nothing
-- crosses the containing item's bounds. Colliding neighbours meet at the
-- midpoint of their original gap, which keeps the result independent of the
-- order spans were selected in. Mutates and returns `spans`.
-- bounds: optional { start = number, stop = number }
function vo.ApplyPadding(spans, cfg, bounds)
  local pre  = vo.Opt(cfg, "pre_pad")
  local post = vo.Opt(cfg, "post_pad")

  for _, s in ipairs(spans) do
    s.raw_start, s.raw_stop = s.start, s.stop
    s.start = s.start - pre
    s.stop  = s.stop + post
  end

  for i = 2, #spans do
    local prev, cur = spans[i - 1], spans[i]
    if cur.start < prev.stop then
      local mid = (prev.raw_stop + cur.raw_start) / 2
      if prev.stop > mid then prev.stop, prev.clamped = mid, true end
      if cur.start < mid then cur.start, cur.clamped = mid, true end
    end
  end

  if bounds then
    for _, s in ipairs(spans) do
      if bounds.start and s.start < bounds.start then
        s.start, s.clamped = bounds.start, true
      end
      if bounds.stop and s.stop > bounds.stop then
        s.stop, s.clamped = bounds.stop, true
      end
    end
  end

  return spans
end

--------------------------------
-- Pure layer: routing and naming
--------------------------------

-- Group repeated takes of a line, number them chronologically, then route and
-- name every span according to the three per-session toggles.
-- Only `match` spans are numbered: a review clip is not a delivered take, so
-- counting it would leave gaps in the delivered take numbers.
-- Mutates and returns `spans` (adds take_index, primary, dest, name).
function vo.AssignNames(spans, cfg)
  local use_alts         = vo.Opt(cfg, "use_alts_track")
  local suffix           = vo.Opt(cfg, "suffix_alt_names")
  local primary_take     = vo.Opt(cfg, "primary_take")
  local review_prefix    = vo.Opt(cfg, "review_prefix")
  local unmatched_prefix = vo.Opt(cfg, "unmatched_prefix")
  local snippet_words    = vo.Opt(cfg, "unmatched_snippet_words")
  local max_len          = vo.Opt(cfg, "max_name_length")

  local groups, order = {}, {}
  for _, s in ipairs(spans) do
    if s.kind == "match" and s.line_id then
      local g = groups[s.line_id]
      if not g then
        g = {}
        groups[s.line_id] = g
        order[#order + 1] = s.line_id
      end
      g[#g + 1] = s
    end
  end

  for _, line_id in ipairs(order) do
    local g = groups[line_id]
    table.sort(g, function(a, b) return a.start < b.start end)
    for i, s in ipairs(g) do s.take_index = i end
    local primary = (primary_take == "first") and g[1] or g[#g]
    for _, s in ipairs(g) do s.primary = (s == primary) end
  end

  for _, s in ipairs(spans) do
    if s.kind == "match" then
      s.dest = (use_alts and not s.primary) and "alts" or "selects"
      if suffix and not s.primary then
        s.name = vo.SanitizeName(string.format("%s_tk%02d", s.asset, s.take_index), max_len)
      else
        s.name = vo.SanitizeName(s.asset, max_len)
      end

    elseif s.kind == "review" then
      s.dest = "review"
      s.name = vo.SanitizeName(
        string.format("%s%s_s%.2f", review_prefix, s.asset or "", s.score or 0), max_len)

    else
      s.dest = "review"
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
-- Returns: array of strings (argv, NOT pre-joined).
function vo.BuildWhisperArgv(cfg, audio, out_prefix)
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
  { name = "medium",   filename = "ggml-medium.bin",   label = "medium (multilingual, ~1.5 GB)",   expected_bytes = 1533763059 },
  { name = "large-v3", filename = "ggml-large-v3.bin", label = "large-v3 (multilingual, ~3.1 GB)", expected_bytes = 3095033483 },
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

--------------------------------
-- Pure layer: backend acquisition paths & checks
--------------------------------

-- Storage lives under REAPER's resource path so it is shared across projects.
-- Pure over the injected resource path so it can be unit-tested; callers pass
-- r.GetResourcePath().
function vo.ResolveModelsDir(resource_path)
  return (resource_path or "") .. "/whisper-models"
end

function vo.ResolveBinDir(resource_path)
  return (resource_path or "") .. "/whisper-bin"
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

--------------------------------
-- Pure layer: plan composition
--------------------------------

-- Compose the whole matching pipeline. Pure: no REAPER, no audio, no I/O.
-- lines: script lines from BuildScriptLines
-- words: whisper words from ParseWhisperCSV, already in project time
-- Returns: chronological array of span records ready for ApplyPlan.
function vo.BuildPlan(lines, words, cfg)
  local tokens     = vo.BuildWordTokens(words, cfg)
  local index      = vo.BuildIndex(lines, cfg)
  local candidates = vo.FindCandidates(tokens, lines, index, cfg)
  local spans      = vo.SelectSpans(candidates, cfg)
  local gaps       = vo.FindGaps(tokens, spans)

  local plan = {}
  for _, s in ipairs(spans) do plan[#plan + 1] = s end
  for _, g in ipairs(gaps)  do plan[#plan + 1] = g end
  table.sort(plan, function(a, b)
    if a.i0 ~= b.i0 then return a.i0 < b.i0 end
    return a.i1 < b.i1
  end)

  -- Matched spans need their transcript too, for the report.
  for _, s in ipairs(plan) do
    if not s.transcript then
      local text = {}
      for k = s.i0, s.i1 do text[#text + 1] = tokens[k].text end
      s.transcript = table.concat(text, " ")
    end
  end

  vo.ApplyPadding(plan, cfg, cfg and cfg.bounds)
  vo.AssignNames(plan, cfg)

  return plan
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

vo.REPORT_HEADER = {
  "start", "stop", "kind", "LineID", "AudioAsset", "score", "margin",
  "take_index", "destination", "name", "transcript", "script_text", "clamped",
}

-- Build the run report: one row per span, then a trailing section listing
-- script lines that received no match at all — the "did we actually record
-- everything?" check. A review-only line still counts as unrecorded.
function vo.BuildReport(plan, lines)
  local by_id = {}
  for _, l in ipairs(lines or {}) do by_id[l.line_id] = l end

  local matched = {}
  local out = { vo.FormatCSVRow(vo.REPORT_HEADER) }

  for _, s in ipairs(plan or {}) do
    if s.kind == "match" and s.line_id then matched[s.line_id] = true end
    local line = s.line_id and by_id[s.line_id] or nil
    out[#out + 1] = vo.FormatCSVRow({
      string.format("%.3f", s.start or 0),
      string.format("%.3f", s.stop or 0),
      s.kind or "",
      s.line_id or "",
      s.asset or "",
      s.score  and string.format("%.4f", s.score)  or "",
      s.margin and string.format("%.4f", s.margin) or "",
      s.take_index and tostring(s.take_index) or "",
      s.dest or "",
      s.name or "",
      s.transcript or "",
      line and line.text or "",
      s.clamped and "yes" or "",
    })
  end

  out[#out + 1] = ""
  out[#out + 1] = vo.FormatCSVRow({ "SCRIPT LINES WITH NO MATCH" })
  out[#out + 1] = vo.FormatCSVRow({ "LineID", "AudioAsset", "Text" })
  for _, l in ipairs(lines or {}) do
    if not matched[l.line_id] then
      out[#out + 1] = vo.FormatCSVRow({ l.line_id, l.asset, l.text })
    end
  end

  return table.concat(out, "\n") .. "\n"
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
  { key = "pre_pad",            kind = "number", default = vo.DEFAULTS.pre_pad },
  { key = "post_pad",           kind = "number", default = vo.DEFAULTS.post_pad },

  { key = "track_selects",      kind = "string", default = "Selects" },
  { key = "track_alts",         kind = "string", default = "Alts" },
  { key = "track_review",       kind = "string", default = "Review" },
  { key = "create_regions",     kind = "bool",   default = false },

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

  local ctx        = im.CreateContext('VO ScriptMatch')
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
      ctx = im.CreateContext('VO ScriptMatch')
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

-- Transcribe a list of unique source files in sequence, reusing cached
-- transcripts. Calls on_done(map) with path -> word array.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.TranscribeSources(cfg, sources, on_done, on_cancel, on_error)
  local scratch = vo.ResolveScratchDir(cfg)
  vo.EnsureDir(scratch)

  local results = {}
  local index   = 0

  local function step()
    index = index + 1
    if index > #sources then
      on_done(results)
      return
    end

    local source    = sources[index]
    local key       = vo.CacheKey(source.path, source.size, cfg)
    local prefix    = scratch .. "/" .. key
    local csv_path  = prefix .. ".csv"

    if not cfg.force_retranscribe and vo.FileExists(csv_path) then
      local f = io.open(csv_path, "r")
      results[source.path] = vo.ParseWhisperCSV(f:read("a"))
      f:close()
      step()
      return
    end

    local argv = vo.BuildWhisperArgv(cfg, source.path, prefix)
    vo.RunWhisperAsync(cfg, argv, scratch,
      function(code, log)
        if code ~= 0 then
          local tail = log:sub(-1500)
          on_error(string.format("whisper-cli exited with code %d for:\n%s\n\n%s",
                                 code, source.path, tail))
          return
        end
        local f = io.open(csv_path, "r")
        if not f then
          on_error("whisper-cli reported success but wrote no CSV:\n" .. csv_path)
          return
        end
        results[source.path] = vo.ParseWhisperCSV(f:read("a"))
        f:close()
        step()
      end,
      on_cancel,
      on_error)
  end

  step()
end

--------------------------------
-- Coupled layer: project inspection
--------------------------------

-- Inspect the selected items. Items that cannot be transcribed are returned
-- with a `skip` reason rather than aborting the run, so the report can list
-- them and the rest of the session still processes.
function vo.CollectSourceSpans()
  local items = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    local item = r.GetSelectedMediaItem(0, i)
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

    items[#items + 1] = info
  end

  table.sort(items, function(a, b) return (a.pos or 0) < (b.pos or 0) end)
  return items
end

-- Find a track by name, or create one directly below `track`.
function vo.EnsureTrackBelow(track, name)
  for i = 0, r.CountTracks(0) - 1 do
    local candidate = r.GetTrack(0, i)
    local _, existing = r.GetSetMediaTrackInfo_String(candidate, "P_NAME", "", false)
    if existing == name then return candidate end
  end

  -- IP_TRACKNUMBER is 1-based, so it is already the 0-based index *after* this
  -- track — exactly where the new one belongs.
  local insert_at = math.floor(r.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
  r.InsertTrackAtIndex(insert_at, true)
  local created = r.GetTrack(0, insert_at)
  r.GetSetMediaTrackInfo_String(created, "P_NAME", name, true)
  return created
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

-- Split the session and move each span to its destination track, named.
-- Splitting rather than copying is deliberate (SPEC.md §4): with the pieces
-- physically removed it is obvious what has been pulled and what has not.
-- Caller wraps this in core.Transaction so the whole run is one undo step.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
-- Returns: applied count, array of failure strings.
function vo.ApplyPlan(plan, cfg, source_track)
  local dest_names = {
    selects = cfg.track_selects or "Selects",
    alts    = cfg.track_alts    or "Alts",
    review  = cfg.track_review  or "Review",
  }

  local tracks  = {}
  local applied = 0
  local failures = {}

  for _, span in ipairs(plan) do
    local item = ItemContaining(source_track, span.start)
    if not item then
      failures[#failures + 1] =
        string.format("%s: no item at %.3fs", span.name or "(unnamed)", span.start)
    else
      -- Split twice: the middle piece is the span.
      local right = r.SplitMediaItem(item, span.start)
      local piece = right or item
      r.SplitMediaItem(piece, span.stop)

      local dest_name = dest_names[span.dest] or dest_names.review
      if not tracks[span.dest] then
        tracks[span.dest] = vo.EnsureTrackBelow(source_track, dest_name)
      end

      if r.MoveMediaItemToTrack(piece, tracks[span.dest]) then
        local take = r.GetActiveTake(piece)
        if take then
          r.GetSetMediaItemTakeInfo_String(take, "P_NAME", span.name, true)
        end
        if cfg.create_regions and span.dest == "selects" then
          r.AddProjectMarker2(0, true, span.start, span.stop, span.name, -1, 0)
        end
        applied = applied + 1
      else
        failures[#failures + 1] =
          string.format("%s: could not move to %s", span.name or "(unnamed)", dest_name)
      end
    end
  end

  r.UpdateArrange()
  return applied, failures
end

return vo
