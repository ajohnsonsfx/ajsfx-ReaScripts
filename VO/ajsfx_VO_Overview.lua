-- @noindex
-- Provided by the ajsfx VO ScriptMatch package; see that script's @provides.
--
-- ajsfx VO Overview — a project-wide picture of the dialogue in a session.
--
-- Every line the script says should exist, every span a LIVE match against
-- each source's transcript says does exist, in one table across every
-- recording in the project. This script does not transcribe (ajsfx VO
-- Sources) or cut (ajsfx VO Cut): it reads the per-source transcripts plus
-- one project file (<project>_vo.csv) and adds the one thing nothing else
-- records, which is what the USER decided. The match itself is never stored
-- -- see the memoised LoadMatches below. See VO/SPEC-overview.md.

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path
local core = require("lib.ajsfx_core")
local vo   = require("lib.ajsfx_vo")
local view = require("lib.ajsfx_vo_view")

local success, im = pcall(function()
  package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
  return require('imgui')('0.9.3')
end)
if not success then
  r.MB("This script requires the 'imgui' library.\n\n" ..
       "Install ReaImGui: ReaScript binding for Dear ImGui via ReaPack.",
       "Library not found", 0)
  return
end

-- ReaImGui's shim raises on ANY unknown field rather than returning nil, so
-- `im.Maybe and im.Maybe(ctx)` is not a guard — it is a crash on the bindings
-- that lack the field. Every optional entry point has to come through here.
local function Api(name) return rawget(im, name) end

-- Modifier state, read live. GetKeyMods is not in every 0.9.x binding; where it
-- is missing the individual modifier keys still answer.
local GET_KEY_MODS   = Api('GetKeyMods')
local MOD_SHORTCUT   = Api('Mod_Shortcut') or Api('Mod_Ctrl')
local MOD_SHIFT      = Api('Mod_Shift')
local KEY_LSHIFT     = Api('Key_LeftShift')
local KEY_RSHIFT     = Api('Key_RightShift')
local KEY_LCTRL      = Api('Key_LeftCtrl')
local KEY_RCTRL      = Api('Key_RightCtrl')
local KEY_LSUPER     = Api('Key_LeftSuper')

-- Needed to draw the header row by hand; without it the table falls back to
-- TableHeadersRow and simply has no header tooltips.
local HEADER_ROW_FLAGS = Api('TableRowFlags_Headers')
local KEY_RSUPER     = Api('Key_RightSuper')

-- Transcripts and the project file are read off disk, and matching is linear
-- in the project's whole word count, so the rebuild cannot sit on the
-- per-frame path. A project-state counter decides WHETHER to rebuild; this
-- decides how often that question may lead to actual file I/O and matching
-- (CLAUDE.md: use GetProjectStateChangeCount(0) for cache invalidation).
local RELOAD_THROTTLE = 1.5   -- seconds between row rescans
local FLUSH_THROTTLE  = 2.0   -- seconds between project file writes while typing

local STATUS_STYLE = {
  recorded = { label = "Recorded", colour = 0x66BB66FF },
  review   = { label = "Review",   colour = 0xDDAA33FF },
  missing  = { label = "Missing",  colour = 0xDD6666FF },
  orphan   = { label = "Orphan",   colour = 0x9999AAFF },
}

local COLUMNS = {
  { key = "verify",     label = "OK",         width =  28 },
  { key = "status",     label = "Status",     width =  74 },
  { key = "select",     label = "Select",     width =  60 },
  { key = "character",  label = "Character",  width =  90 },
  -- Two names, deliberately. "Item name" is what the user is changing and what
  -- REAPER's render patterns read; "CSV filename" is the script's own name for
  -- the line, kept visible and read-only so a rename never loses the original.
  { key = "item_name",  label = "Item name",  width = 190,
    tip = "The take's name in REAPER. Editable, and what the stock render\n" ..
          "patterns read. Nothing here renames a file on disk." },
  { key = "asset",      label = "CSV filename", width = 160,
    tip = "The filename from the script CSV. Not editable.\n" ..
          "Right-click a cell to copy it or to put it back on the item." },
  { key = "take",       label = "Take",       width =  44 },
  { key = "line_text",  label = "Line text",  width = 240 },
  { key = "transcript", label = "Transcript", width = 240 },
  { key = "source",     label = "Source",     width = 120 },
  { key = "time",       label = "Time",       width =  76 },
  { key = "notes",      label = "Notes",      width = 200 },
}

-- Every column key, in declaration order. Used to load, save and clear the
-- per-column settings without anything having to restate the list.
local function ColumnKeys()
  local keys = {}
  for i, c in ipairs(COLUMNS) do keys[i] = c.key end
  return keys
end

local SORTS = {
  { key = "script",    label = "Script order" },
  { key = "status",    label = "Status" },
  { key = "filename",  label = "Filename" },
  { key = "character", label = "Character" },
  { key = "timeline",  label = "Timeline position" },
}

local LAYOUT_ORDERS = {
  { key = "script", label = "Script order" },
  { key = "record", label = "Record order" },
}

local LAYOUT_SPACINGS = {
  { key = "fixed",    label = "Fixed gap" },
  { key = "original", label = "Original spacing" },
}

local STATUS_FILTERS = {
  { key = "all",       label = "All" },
  { key = "missing",   label = "Missing" },
  { key = "review",    label = "Needs review" },
  { key = "orphan",    label = "Orphans" },
  { key = "unverified",label = "Not yet verified" },
  { key = "verified",  label = "Verified" },
  { key = "flagged",   label = "Flagged" },
}

local state = {
  script_csv    = "",
  header        = nil,
  rows          = nil,        -- raw script CSV rows
  mapping       = {},
  header_error  = "",
  lines         = {},         -- vo.BuildScriptLines(state.rows, ...)

  items         = {},         -- vo.CollectProjectSpans()

  -- Matching is DERIVED, never stored -- see LoadMatches. Memoised on exactly
  -- the inputs that can change it, so the frame loop never pays to re-run it.
  matches       = {},         -- vo.BuildMatch result: { { path=, spans= }, ... }
  match_key     = nil,

  entries       = {},         -- vo.ParseProjectFile entries, the in-memory truth
  project_path  = nil,
  project_error = "",
  parse_failed  = false,      -- the project file is unreadable; saving is refused
  dirty         = false,
  last_flush    = 0,

  overview      = {},         -- vo.BuildOverview result
  visible       = {},         -- after filters
  summary       = {},

  scanned_at    = -1,         -- GetProjectStateChangeCount when rows were built
  last_rescan   = 0,

  selection     = {},         -- set of row UIDs, spreadsheet-style
  focus_key     = nil,        -- the row the caret is on
  anchor        = nil,        -- row UID a shift-range extends from

  layout_order   = "script",  -- "script" | "record"
  layout_spacing = "fixed",   -- "fixed"  | "original"
  layout_gap     = 2.0,
  layout_src_gap = 60.0,

  sort          = "script",
  status_filter = "all",
  character     = nil,
  search        = "",

  message       = "",
  message_kind  = "ok",

  -- Presentation. Loaded once at startup and written through on every change;
  -- nothing reads ExtState per frame.
  view          = { restore = true, mirror = false, sizes = {}, cols = {} },
  settings_open = false,
}


-- -----------------------------------------------------------------------
-- Disk
-- -----------------------------------------------------------------------

local function ReadFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function WriteFile(path, text)
  local f = io.open(path, "wb")
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

local function ProjectPath()
  local _, path = r.EnumProjects(-1, "")
  return path or ""
end

-- -----------------------------------------------------------------------
-- The script side
-- -----------------------------------------------------------------------

local function LoadCSV(path)
  state.header, state.rows, state.header_error = nil, nil, ""
  if not path or path == "" then return end

  local text = ReadFile(path)
  if not text then
    state.header_error = "Cannot read the script CSV:\n" .. path
    return
  end

  local rows = vo.ParseCSV(text)
  if #rows < 1 then
    state.header_error = "The script CSV is empty."
    return
  end

  local header = table.remove(rows, 1)
  local ok, err = vo.ValidateHeaderNames(header)
  if not ok then
    state.header_error = err
    return
  end

  state.header, state.rows = header, rows
  if #rows == 0 then state.header_error = "The script CSV has no data rows." end
end

-- The mapping the project file persisted, falling back to whatever the header
-- itself suggests. A project whose columns were never mapped still opens with
-- something sensible rather than an empty table. Skip values are not part of
-- the project file (vo.PROJECT_HEADER carries only the mapping); the default
-- skip list (vo.DEFAULT_SKIP_VALUES) is what vo.BuildScriptLines falls back to
-- when none is supplied.
local function ApplyMappingDefaults()
  if state.mapping and next(state.mapping) then return end
  state.mapping = state.header and vo.AutoDetectMapping(state.header) or {}
end

-- The script lines this project expects, after skip tokens and the character
-- filter. Returns an empty list (never nil) so callers need no special case.
local function ScriptLines()
  if not state.header or not state.rows or state.header_error ~= "" then return {} end
  local cols = vo.MapColumns(state.header, state.mapping)
  if not cols then return {} end
  return vo.BuildScriptLines(state.rows, cols)
end

-- -----------------------------------------------------------------------
-- The audio side
-- -----------------------------------------------------------------------

local function LoadProjectFile()
  state.entries, state.project_error, state.parse_failed = {}, "", false
  state.script_csv, state.mapping = "", {}

  local proj = ProjectPath()
  state.project_path = (proj ~= "") and vo.ProjectFilePath(proj) or nil
  if not state.project_path then return end

  local text = ReadFile(state.project_path)
  if not text then return end          -- no project file yet is the normal first run

  local parsed, reason = vo.ParseProjectFile(text)
  if parsed then
    state.entries    = parsed.entries
    state.script_csv = parsed.script_csv
    state.mapping     = parsed.mapping
  else
    -- The file is NOT overwritten on a parse failure: writing would destroy
    -- whatever the user still has in there. Saving stays off until they fix or
    -- remove it, and the window says so.
    state.parse_failed = true
    state.project_error = "Cannot read " .. vo.Basename(state.project_path)
                       .. ": " .. tostring(reason)
  end
end

local function SaveProjectFile()
  if state.parse_failed then
    state.message, state.message_kind =
      "The project file could not be read, so it will not be overwritten. " ..
      "Fix or delete it first:\n" .. tostring(state.project_path), "error"
    return false
  end

  local path = vo.ProjectFilePath(ProjectPath())
  if not path then
    state.message, state.message_kind =
      "Save the project before marking anything — the VO project file lives beside it.",
      "error"
    return false
  end
  state.project_path = path

  local ok = WriteFile(path, vo.SerializeProjectFile(
    vo.ProjectEntriesFromRows(state.overview),
    { script_csv = state.script_csv, mapping = state.mapping }))
  if not ok then
    state.message, state.message_kind = "Cannot write " .. tostring(path), "error"
    return false
  end
  return true
end

local function FlushProjectFile(force)
  if not state.dirty or state.parse_failed or not state.project_path then return end
  if not force and (r.time_precise() - state.last_flush) < FLUSH_THROTTLE then return end

  if SaveProjectFile() then
    state.dirty, state.last_flush = false, r.time_precise()
  end
end

-- Matching is DERIVED, never stored. It is recomputed when the script, the
-- mapping, or the set of transcripts changes -- and memoised on exactly those
-- inputs, because it is linear in the project's whole word count and the frame
-- loop must not pay for it.
--
-- Keyed on the TRANSCRIPT file's size, not the audio's: re-transcribing does
-- not touch the audio (so the audio's own size never changes), but it always
-- rewrites the transcript, which is what actually needs to invalidate the
-- cache. No staleness bookkeeping is needed in this window as a result.
--
-- The settings are inputs too: anchor_count, review_floor, window_slack and the
-- substitution list all steer matching, and a user who changes one in Settings
-- while this window is open must see the result. Rather than list the knobs --
-- a list that would rot the next time one is added -- the whole config folds
-- into the key.
local function CfgKey(cfg)
  local keys = {}
  for k in pairs(cfg or {}) do keys[#keys + 1] = k end
  table.sort(keys)

  local parts = {}
  for _, k in ipairs(keys) do
    local v = cfg[k]
    if type(v) == "table" then
      local inner = {}
      for ik, iv in pairs(v) do inner[#inner + 1] = tostring(ik) .. "=" .. tostring(iv) end
      table.sort(inner)
      v = "{" .. table.concat(inner, ",") .. "}"
    end
    parts[#parts + 1] = k .. "=" .. tostring(v)
  end
  return table.concat(parts, ";")
end

local function MatchKey(paths, script_csv, mapping, cfg)
  local parts = { script_csv or "", vo.SerializeLayout({ mapping = mapping }), CfgKey(cfg) }
  for _, p in ipairs(paths) do
    local tpath = vo.TranscriptPath(p)
    parts[#parts + 1] = p .. ":" .. tostring(tpath and vo.FileSize(tpath) or 0)
  end
  return table.concat(parts, "|")
end

local function LoadMatches(cfg)
  local paths = vo.ProjectSourcePaths(state.items)
  local key   = MatchKey(paths, state.script_csv, state.mapping, cfg)
  if key == state.match_key then return state.matches end

  local transcripts = {}
  for _, path in ipairs(paths) do
    local parsed = vo.ReadTranscript(path)
    if parsed then transcripts[#transcripts + 1] = { path = path, words = parsed.words } end
  end

  state.matches   = vo.BuildMatch(transcripts, state.lines or {}, cfg)
  state.match_key = key
  return state.matches
end

-- -----------------------------------------------------------------------
-- Assembly
-- -----------------------------------------------------------------------

local function Rebuild()
  state.items = vo.CollectProjectSpans()
  state.lines = ScriptLines()
  local cfg   = vo.LoadConfig()

  state.overview = vo.BuildOverview({
    lines   = state.lines,
    matches = LoadMatches(cfg),
    entries = state.entries,
    cfg     = cfg,
  })
  state.summary = vo.SummarizeOverview(state.overview)

  -- Resolve each row to a live item once per rebuild rather than per frame:
  -- this walks every project item per row and is far too expensive to redo at
  -- frame rate on a long session.
  for _, row in ipairs(state.overview) do
    if row.source_path and row.source_start then
      local item, proj_time =
        vo.ResolveSourceTime(row.source_path, row.source_start, state.items)
      row.item, row.proj_time = item, proj_time
    end
    -- The name REAPER is showing on the item right now, so the Item name column
    -- reflects a rename made anywhere else in the project, not just here.
    if row.item then
      local take = r.GetActiveTake(row.item)
      if take then
        local _, name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        row.take_name = (name ~= "") and name or nil
      end
    end
  end

  -- Row keys are NOT unique. A script line with no audio yet keys as
  -- "|<asset>", so a whole character's un-recorded lines collapse onto one key
  -- whenever they share an asset name (or have none). Keys stay as they are —
  -- the project file matches on them — but anything that addresses ONE ROW
  -- gets its own identifier: the key plus an ordinal among the rows sharing
  -- it. Stable across rebuilds because BuildOverview is deterministic.
  local seen = {}
  for _, row in ipairs(state.overview) do
    local n = (seen[row.key] or 0) + 1
    seen[row.key] = n
    row.uid = row.key .. "#" .. n
  end
end

-- An immediate, unthrottled rebuild -- for a deliberate user action (Refresh,
-- a timeline sort) rather than the automatic per-frame path below.
local function Reload()
  Rebuild()
  state.scanned_at  = r.GetProjectStateChangeCount(0)
  state.last_rescan = r.time_precise()
end

-- Rebuild rows when the project-state counter moves, throttled so a drag
-- gesture (which can move the counter every frame) cannot force a matching
-- pass, a transcript stat, and a project-file read on every frame. The
-- state-change counter moves on any edit (an item split, moved, renamed,
-- deleted), which is precisely when a row's resolved item can go stale.
local function MaybeRescan()
  local count = r.GetProjectStateChangeCount(0)
  if count == state.scanned_at then return end
  if state.scanned_at ~= -1
     and (r.time_precise() - state.last_rescan) < RELOAD_THROTTLE then
    return
  end
  Reload()
end

-- -----------------------------------------------------------------------
-- User edits
-- -----------------------------------------------------------------------

-- The project-file entry backing a row, created on demand. Rows are rebuilt
-- often, so edits are written to the entry (which survives) rather than to
-- the row.
local function EntryFor(row)
  for _, e in ipairs(state.entries) do
    if e.key == row.key and (e.source or "") == (row.source_path or "") then return e end
  end
  local e = {
    key = row.key, source = row.source_path, source_start = row.source_start,
    asset = row.asset, select = false,
  }
  state.entries[#state.entries + 1] = e
  return e
end

local function Mutate(row, fn)
  fn(EntryFor(row))
  state.dirty = true
  Rebuild()
end

local function SetStatus(row, status)
  Mutate(row, function(e) e.status = status end)
end

local function SetNotes(row, notes)
  Mutate(row, function(e) e.notes = (notes ~= "") and notes or nil end)
end

-- Exactly one take of a line may be the select, so turning one ON clears the
-- rest of its group. Without this the project file could hold two selected
-- rows for one filename and BuildOverview would silently pick whichever the
-- build order put first (see vo.BuildOverview's "no first/last fallback").
local function SetSelect(row, on)
  if on then
    for _, other in ipairs(state.overview) do
      if other ~= row and other.asset == row.asset and other.status ~= "orphan"
         and other.user_select then
        Mutate(other, function(e) e.select = false end)
      end
    end
  end
  Mutate(row, function(e) e.select = on end)
end

-- Renaming is the one edit that reaches into the project. It is recorded in
-- the project file AND applied to the take, so the delivery name survives
-- even if the item is later deleted, and one edit is one undo step.
local function Rename(row, name)
  local clean = vo.SanitizeName(name)
  if clean == "" then
    state.message, state.message_kind =
      "That name has no characters a filesystem will accept.", "error"
    return
  end

  -- The take is written BEFORE the entry, because Mutate rebuilds and the
  -- rebuild reads the take's live name back into the row.
  if row.item then
    core.Transaction("VO Overview: rename take", function()
      local take = r.GetActiveTake(row.item)
      if take then
        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", clean, true)
      end
    end)
    -- Transaction holds UI refresh off for its duration, so the arrange view
    -- would otherwise keep showing the old name until something else redrew it.
    r.UpdateArrange()
  end

  Mutate(row, function(e) e.name_override = clean end)
  state.message, state.message_kind = "Renamed to " .. clean .. ".", "ok"
end

-- Putting the script's own name back. The entry's override is CLEARED rather
-- than set to the asset name: an override equal to the script's name is not a
-- judgement about anything, and the project file holds only judgements.
local function ResetName(row)
  local clean = vo.SanitizeName(row.asset or "")
  if clean == "" then return end

  if row.item then
    core.Transaction("VO Overview: reset take name", function()
      local take = r.GetActiveTake(row.item)
      if take then
        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", clean, true)
      end
    end)
    r.UpdateArrange()
  end

  Mutate(row, function(e) e.name_override = nil end)
  state.message, state.message_kind = "Reset to " .. clean .. ".", "ok"
end

-- -----------------------------------------------------------------------
-- Selection
--
-- Spreadsheet rules: click replaces, ctrl/cmd-click toggles, shift-click takes
-- the range from the anchor. Ranges walk state.visible rather than the full
-- overview, so a shift-click selects what the user can actually see between the
-- two rows they clicked.
-- -----------------------------------------------------------------------

local function SelectedRows()
  local out = {}
  for _, row in ipairs(state.visible) do
    if state.selection[row.uid] then out[#out + 1] = row end
  end
  return out
end

-- Push the row selection out to the project. The edit cursor follows the FOCUS
-- row only: seeking once per gesture rather than once per selected row keeps a
-- fifty-row shift-click from thrashing the transport.
local function SyncProjectSelection()
  r.Main_OnCommand(40289, 0)                       -- unselect all items
  local seen = {}
  for _, row in ipairs(SelectedRows()) do
    if row.item and not seen[row.item] then
      seen[row.item] = true
      r.SetMediaItemSelected(row.item, true)
    end
  end
  for _, row in ipairs(state.visible) do
    if row.uid == state.focus_key and row.proj_time then
      r.SetEditCurPos(row.proj_time, true, true)   -- move and seek playback
      break
    end
  end
  r.UpdateArrange()
end

local function ClickRow(row, index, mods)
  local ctrl  = (mods.shortcut == true)
  local shift = (mods.shift == true)

  -- The anchor is remembered as a row UID, not an index: a re-sort between the
  -- two clicks would leave an index pointing at an unrelated row.
  local anchor_index
  for i, other in ipairs(state.visible) do
    if other.uid == state.anchor then anchor_index = i; break end
  end

  if shift and anchor_index then
    state.selection = {}
    local from, to = anchor_index, index
    if from > to then from, to = to, from end
    for i = from, to do
      local other = state.visible[i]
      if other then state.selection[other.uid] = true end
    end
  elseif ctrl then
    state.selection[row.uid] = (not state.selection[row.uid]) or nil
    state.anchor = row.uid
  else
    state.selection = { [row.uid] = true }
    state.anchor = row.uid
  end

  state.focus_key = row.uid
  SyncProjectSelection()
end

-- -----------------------------------------------------------------------
-- Filtering
-- -----------------------------------------------------------------------

local function Matches(row)
  local f = state.status_filter
  if f == "unverified" then
    if row.user_status == "verified" or row.status == "orphan" then return false end
  elseif f == "verified" or f == "flagged" then
    if row.user_status ~= f then return false end
  elseif f ~= "all" then
    if row.status ~= f then return false end
  end

  if state.character and (row.character or "") ~= state.character then return false end

  if state.search ~= "" then
    local needle = state.search:lower()
    local hay = ((row.asset or "") .. " " .. (row.line_text or "") .. " "
              .. (row.transcript or "") .. " " .. (row.notes or "")):lower()
    if not hay:find(needle, 1, true) then return false end
  end
  return true
end

local SORT_RANK = { missing = 1, review = 2, orphan = 3, recorded = 4 }

local function ApplyFilters()
  local out = {}
  for i, row in ipairs(state.overview) do
    if Matches(row) then
      row.order = i     -- script order is the stable tiebreak for every sort
      out[#out + 1] = row
    end
  end

  local mode = state.sort
  if mode ~= "script" then
    table.sort(out, function(a, b)
      local ka, kb
      if mode == "status" then
        ka, kb = SORT_RANK[a.status] or 9, SORT_RANK[b.status] or 9
      elseif mode == "filename" then
        ka, kb = (a.asset or ""):lower(), (b.asset or ""):lower()
      elseif mode == "character" then
        ka, kb = (a.character or ""):lower(), (b.character or ""):lower()
      else -- timeline; rows with no audio sort last rather than at time zero
        ka = a.proj_time or math.huge
        kb = b.proj_time or math.huge
      end
      if ka ~= kb then return ka < kb end
      return a.order < b.order
    end)
  end

  state.visible = out

  -- The selection never outlives the filter. Keeping hidden rows selected would
  -- let a Sort move items the user cannot see, which is the one surprise this
  -- tool must not spring.
  local kept = {}
  for _, row in ipairs(out) do
    if state.selection[row.uid] then kept[row.uid] = true end
  end
  state.selection = kept

  local visible_key = {}
  for _, row in ipairs(out) do visible_key[row.uid] = true end
  if state.focus_key and not visible_key[state.focus_key] then state.focus_key = nil end
  if state.anchor    and not visible_key[state.anchor]    then state.anchor    = nil end
end

-- -----------------------------------------------------------------------
-- Laying out the timeline
--
-- This moves ITEMS, never spans, and never cuts: cutting is ScriptMatch's job
-- (SPEC-overview.md section 1). An item holding several lines is positioned by
-- its first recognised line, and the next item is placed clear of the whole of
-- it. Overlapping items on one track travel together so crossfades survive.
-- -----------------------------------------------------------------------

local LAYOUT_KEYS = {
  layout_order   = "order",
  layout_spacing = "spacing",
  layout_gap     = "gap",
  layout_src_gap = "src_gap",
}

local function LoadLayoutSettings()
  for field, key in pairs(LAYOUT_KEYS) do
    -- Deliberately not part of vo.CONFIG_SCHEMA: that schema drives the Settings
    -- dialog, and these belong to this window's toolbar, not to matching.
    local raw = r.GetExtState(vo.EXT_SECTION, "layout_" .. key)
    if raw and raw ~= "" then
      if type(state[field]) == "number" then
        state[field] = tonumber(raw) or state[field]
      else
        state[field] = raw
      end
    end
  end
end

local function SaveLayoutSettings()
  for field, key in pairs(LAYOUT_KEYS) do
    r.SetExtState(vo.EXT_SECTION, "layout_" .. key, tostring(state[field]), true)
  end
end

-- -----------------------------------------------------------------------
-- Presentation settings
--
-- How the table LOOKS belongs to the user, not to the session, so all of this
-- lives in ExtState and is shared by every project. Column widths and order are
-- not here: ImGui persists those itself, into REAPER/ReaImGui/<hash>.ini.
-- -----------------------------------------------------------------------

local function LoadViewSettings()
  state.view.restore = view.LoadRestore()
  state.view.mirror  = view.LoadMirror()
  state.view.sizes   = view.LoadFontSizes()
  state.view.cols    = {}
  for _, key in ipairs(ColumnKeys()) do
    -- With restore off the stored per-column settings are ignored AND cleared
    -- (see SetRestore), so this branch only ever sees an empty store. Reading
    -- the defaults explicitly keeps that true even if a key survives somehow.
    state.view.cols[key] = state.view.restore and view.LoadColumn(key)
                           or view.NormalizeColumn(key, nil)
  end

  -- The mirror is an invariant, not a one-off copy, so it is enforced on load
  -- too: a store edited by hand, or written by a version that did not have the
  -- setting, must not open with the two columns disagreeing while the box says
  -- they match.
  if state.view.mirror then
    local src, dst = state.view.cols.line_text, state.view.cols.transcript
    if src and dst then
      dst.align, dst.wrap, dst.font = src.align, src.wrap, src.font
    end
  end
end

local function ColumnView(key)
  return state.view.cols[key] or view.NormalizeColumn(key, nil)
end

local function WriteColumnView(key, field, value)
  local col = ColumnView(key)
  col[field] = value
  state.view.cols[key] = col
  if state.view.restore then view.SaveColumn(key, col) end
end

-- Line text and Transcript are read against each other — having both columns is
-- only useful for comparing what the script says with what was said — so they
-- can be pinned together. Enforced on write and on switching the mirror on,
-- which keeps ColumnView a plain lookup rather than something that has to
-- resolve a pairing on every cell of every row.
--
-- Column WIDTH is not mirrored, and cannot be: ReaImGui exposes no
-- TableSetColumnWidth, widths live in ImGui's own saved table state, and
-- TableSetupColumn's initial width is ignored once a layout exists.
local MIRROR_PAIR = { line_text = "transcript", transcript = "line_text" }

local function SetColumnView(key, field, value)
  WriteColumnView(key, field, value)
  local twin = state.view.mirror and MIRROR_PAIR[key]
  if twin then WriteColumnView(twin, field, value) end
end

local function SetAllAlign(align)
  for _, key in ipairs(ColumnKeys()) do
    WriteColumnView(key, "align", align)
  end
end

local function SetMirror(on)
  state.view.mirror = on
  view.SaveMirror(on)
  if not on then return end
  -- Line text is the reference: it is the column the user has usually already
  -- set up, and the one Transcript is being checked against.
  local src = ColumnView("line_text")
  for _, field in ipairs({ "align", "wrap", "font" }) do
    WriteColumnView("transcript", field, src[field])
  end
end

-- Turning restore OFF clears the stored per-column settings outright rather
-- than merely ignoring them, so "off" means one thing. Leaving them in place
-- would hide a layer of preferences that reappears the moment the box is
-- ticked again, which is a surprise with no upside.
local function SetRestore(on)
  state.view.restore = on
  view.SaveRestore(on)
  if not on then
    view.ClearColumns(ColumnKeys())
    for _, key in ipairs(ColumnKeys()) do
      state.view.cols[key] = view.NormalizeColumn(key, nil)
    end
  else
    for _, key in ipairs(ColumnKeys()) do
      view.SaveColumn(key, ColumnView(key))
    end
  end
end

-- The rows the tool acts on: the selection if there is one, otherwise every row
-- currently visible. Filters therefore scope the sort when the selection does not.
local function AffectedRows()
  local sel = SelectedRows()
  if #sel > 0 then return sel, true end
  return state.visible, false
end

-- Clusters worth moving, each tagged with the sort key of its earliest member.
-- Returns the clusters and the number skipped for being locked.
local function BuildSortClusters()
  local rows = AffectedRows()

  -- One key per ITEM, taken from its earliest recognised line: an uncut item
  -- holding five lines is a single thing you can drag, so the first line in it
  -- decides where the whole thing goes.
  local keys, wanted = {}, {}
  for _, row in ipairs(rows) do
    if row.item then
      wanted[row.item] = true
      local start = row.source_start or 0
      local existing = keys[row.item]
      if not existing or start < existing.source_start then
        keys[row.item] = {
          script_row   = row.script_row,
          source_start = start,
          source_path  = row.source_path,
          orphan       = (row.status == "orphan") or (row.script_row == nil),
        }
      end
    end
  end

  local chosen, locked = {}, 0
  for _, cluster in ipairs(vo.ClusterItems(vo.CollectItemGeometry())) do
    local touches = false
    for _, member in ipairs(cluster.members) do
      if wanted[member.item] then touches = true; break end
    end
    if touches then
      if cluster.locked then
        -- Moving half a cluster would destroy the crossfade the cluster exists
        -- to protect, so a locked member protects all of them.
        locked = locked + 1
      else
        -- Members are in timeline order, so the first one that carries a key is
        -- the head of the edit.
        for _, member in ipairs(cluster.members) do
          if keys[member.item] then cluster.key = keys[member.item]; break end
        end
        chosen[#chosen + 1] = cluster
      end
    end
  end

  return chosen, locked
end

local function FormatSpan(seconds)
  seconds = math.max(0, math.floor((seconds or 0) + 0.5))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function SortOnTimeline()
  local clusters, locked = BuildSortClusters()
  if #clusters == 0 then
    state.message, state.message_kind =
      (locked > 0)
        and "Every item in range is locked; nothing was moved."
        or  "No audio in range to lay out.", "error"
    return
  end

  -- File dates are only read here, on Apply, never per frame.
  local ages, wanted_dates, got_dates = {}, 0, 0
  if state.layout_order == "record" then
    local paths, seen = {}, {}
    for _, c in ipairs(clusters) do
      local path = c.key and c.key.source_path
      if path and path ~= "" and not seen[path] then
        seen[path] = true
        paths[#paths + 1] = path
      end
    end
    -- One recording needs no ordering at all, so nothing has to be dated.
    wanted_dates = (#paths > 1) and #paths or 0
    ages, got_dates = vo.SourceModifiedTimes(paths)
  end

  local moves, n = vo.PlanTimelineLayout({
    clusters   = clusters,
    order      = state.layout_order,
    spacing    = state.layout_spacing,
    gap        = state.layout_gap,
    source_gap = state.layout_src_gap,
    source_age = ages,
  })

  -- Every run lays its audio out on fresh child tracks rather than shuffling it
  -- where it sits, so a sort can never land on top of audio it was not asked to
  -- touch. Distinct tracks first, in the order the members were seen, so the
  -- destination set is deterministic.
  local sources, seen_track = {}, {}
  for _, move in ipairs(moves) do
    for _, member in ipairs(move.cluster.members) do
      if member.track and not seen_track[member.track] then
        seen_track[member.track] = true
        sources[#sources + 1] = member.track
      end
    end
  end

  local run
  core.Transaction("VO Overview: sort on timeline", function()
    local dest
    dest, run = vo.EnsureSortChildTracks(sources)
    for _, move in ipairs(moves) do
      for _, member in ipairs(move.cluster.members) do
        -- Track first, then position: a member keeps its OWN source-to-
        -- destination mapping, so a group welded across two tracks stays spread
        -- across two destinations instead of collapsing onto one.
        local target = dest[member.track]
        if target then r.MoveMediaItemToTrack(member.item, target) end
        r.SetMediaItemInfo_Value(member.item, "D_POSITION", member.pos + move.delta)
      end
    end
  end)
  r.UpdateArrange()
  r.TrackList_AdjustWindows(false)
  Reload()

  local notes = {}
  if n.groups > 1  then notes[#notes + 1] = n.groups .. " recordings" end
  if n.orphans > 0 then notes[#notes + 1] = n.orphans .. " orphans appended" end
  if n.clamped > 0 then notes[#notes + 1] = n.clamped .. " spaced closer to avoid overlap" end
  if locked > 0    then notes[#notes + 1] = locked .. " locked, left alone" end
  if wanted_dates > 0 and got_dates < wanted_dates then
    notes[#notes + 1] = (got_dates == 0)
      and "no file dates available, ordered by filename"
      or  string.format("only %d of %d recordings could be dated; the rest sort last",
                        got_dates, wanted_dates)
  end

  state.message = string.format('Laid out %d items over %s, on %d new "sorted %d" track%s.%s',
    n.items, FormatSpan(n.span), #sources, run or 1, #sources == 1 and "" or "s",
    (#notes > 0) and (" " .. table.concat(notes, " · ") .. ".") or "")
  -- The sort succeeded. Locked clusters and missing dates are things the user
  -- needs told, not failures, so they do not turn the line red.
  state.message_kind = "ok"
end

-- -----------------------------------------------------------------------
-- Drawing
-- -----------------------------------------------------------------------

local ctx = im.CreateContext('VO Overview')

-- -----------------------------------------------------------------------
-- Fonts
--
-- ReaImGui fonts are created at a fixed size and must be attached to the
-- context before the frame that uses them, so a size change cannot take effect
-- until the next frame. At frame rate that is invisible.
--
-- Medium pushes its own font rather than relying on the default, so all three
-- presets are editable in the same way.
--
-- Everything below uses ctx, which is why the block sits here rather than with
-- the other settings code: a function written above that local would bind the
-- GLOBAL ctx, which is nil.
-- -----------------------------------------------------------------------

local fonts       = {}     -- [size_key] = font object, or nil if creation failed
local fonts_dirty = true   -- set whenever a preset size changes
local fonts_off   = false  -- a push failed once; stop trying (see PushCellFont)

local function EnsureFonts()
  if not fonts_dirty or fonts_off then return end
  fonts_dirty = false

  for _, key in ipairs(view.FONT_KEYS) do
    local old = fonts[key]
    if old then
      -- Detach before dropping the reference: an attached font ReaImGui still
      -- holds outlives the Lua variable that made it.
      pcall(function() im.Detach(ctx, old) end)
      fonts[key] = nil
    end
    local size = state.view.sizes[key] or view.FONT_DEFAULTS[key]
    local ok, font = pcall(function()
      local f = im.CreateFont('sans-serif', size)
      im.Attach(ctx, f)
      return f
    end)
    if ok then
      fonts[key] = font
    else
      -- The table still draws, in the default font. Named rather than
      -- swallowed: a font that would not load is exactly the kind of silent
      -- difference a user would otherwise blame on the setting not working.
      state.message, state.message_kind =
        "Could not create the " .. key .. " font; that size will draw at the default.", "error"
    end
  end
end

-- Depth of the font stack, so an error thrown mid-row can be unwound. ImGui
-- raises on an unbalanced font stack at EndTable, which would bury the real
-- error under a second one.
local font_depth = 0

-- Paired by return value, not by testing the depth: when a font failed to
-- create the push is skipped, and a Pop that only checked `font_depth > 0`
-- would then pop an OUTER caller's font instead of nothing.
-- The push is guarded, and one failure turns the whole pool off for the
-- session. ReaImGui 0.10 reworked fonts — they became sizeless, with the size
-- moving to PushFont — and this script pins the '0.9.3' shim, which is supposed
-- to keep the old two-argument form working. If some binding does not adapt it,
-- the alternative to this guard is an error thrown on every cell of every row.
-- Degrading to the default font costs the user a preference; it does not cost
-- them the table.
local function PushCellFont(key)
  if fonts_off then return false end
  local font = fonts[ColumnView(key).font]
  if not font then return false end

  local ok = pcall(im.PushFont, ctx, font)
  if not ok then
    fonts_off, fonts = true, {}
    state.message, state.message_kind =
      "This ReaImGui build did not accept the font sizes; the table is drawing " ..
      "at its default size. Everything else still works.", "error"
    return false
  end
  font_depth = font_depth + 1
  return true
end

local function PopCellFont(pushed)
  if not pushed then return end
  im.PopFont(ctx)
  font_depth = font_depth - 1
end

local function FormatTime(t)
  if not t then return "" end
  local m = math.floor(t / 60)
  return string.format("%d:%06.3f", m, t - m * 60)
end

local function Combo(label, width, options, current, on_pick)
  im.SetNextItemWidth(ctx, width)
  local shown = current
  for _, o in ipairs(options) do
    if o.key == current then shown = o.label; break end
  end
  if im.BeginCombo(ctx, label, shown) then
    for _, o in ipairs(options) do
      if im.Selectable(ctx, o.label, o.key == current) then on_pick(o.key) end
    end
    im.EndCombo(ctx)
  end
end

local function DrawFilters()
  Combo("##status", 130, STATUS_FILTERS, state.status_filter,
        function(k) state.status_filter = k end)
  im.SameLine(ctx)

  -- Characters come from the rows, not the CSV: an orphan can carry a character
  -- the current script filter excludes, and hiding it from the droplist would
  -- make that row unreachable.
  local seen, chars = {}, { { key = "__all__", label = "(all characters)" } }
  for _, row in ipairs(state.overview) do
    local c = row.character
    if c and c ~= "" and not seen[c] then
      seen[c] = true
      chars[#chars + 1] = { key = c, label = c }
    end
  end
  table.sort(chars, function(a, b)
    if a.key == "__all__" then return true end
    if b.key == "__all__" then return false end
    return a.label < b.label
  end)
  Combo("##character", 140, chars, state.character or "__all__",
        function(k) state.character = (k ~= "__all__") and k or nil end)
  im.SameLine(ctx)

  Combo("##sort", 150, SORTS, state.sort, function(k) state.sort = k end)
  im.SameLine(ctx)

  im.SetNextItemWidth(ctx, 200)
  local changed, text = im.InputTextWithHint(ctx, "##search", "Search…", state.search)
  if changed then state.search = text end

  im.SameLine(ctx)
  if im.Button(ctx, "Refresh") then Reload() end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Re-read every transcript and re-match against the script.\n" ..
                       "Do this after transcribing in ajsfx VO Sources.")
  end
end

local pending_action = nil   -- deferred so nothing mutates mid-table

local function Copy(text)
  local set = rawget(im, 'SetClipboardText')
  if set then
    set(ctx, text)
  elseif r.CF_SetClipboard then
    r.CF_SetClipboard(text)
  else
    state.message, state.message_kind =
      "No clipboard is available. Install SWS or a newer ReaImGui.", "error"
    return
  end
  state.message, state.message_kind = "Copied " .. text .. ".", "ok"
end

local function KeyDown(key)
  return key ~= nil and im.IsKeyDown(ctx, key) or false
end

local function ReadModifiers()
  if GET_KEY_MODS then
    local mods = GET_KEY_MODS(ctx)
    return {
      shortcut = MOD_SHORTCUT ~= nil and (mods & MOD_SHORTCUT) ~= 0 or false,
      shift    = MOD_SHIFT    ~= nil and (mods & MOD_SHIFT)    ~= 0 or false,
    }
  end
  return {
    shortcut = KeyDown(KEY_LCTRL) or KeyDown(KEY_RCTRL)
            or KeyDown(KEY_LSUPER) or KeyDown(KEY_RSUPER),
    shift    = KeyDown(KEY_LSHIFT) or KeyDown(KEY_RSHIFT),
  }
end

-- A hovered tooltip that still works on a disabled widget, so the greyed-out
-- spacing control can explain WHY it is greyed out.
local function TooltipEvenWhenDisabled(text)
  local flags = Api('HoveredFlags_AllowWhenDisabled') or 0
  if im.IsItemHovered(ctx, flags) then im.SetTooltip(ctx, text) end
end

local function GapField(label, width, value, tip)
  im.SetNextItemWidth(ctx, width)
  local changed, v = im.InputDouble(ctx, label, value, 0, 0, "%.2f s")
  if tip then TooltipEvenWhenDisabled(tip) end
  if changed then return true, math.max(0, v) end
  return false, value
end

local function DrawLayoutBar()
  im.Text(ctx, "Sort on timeline:")
  im.SameLine(ctx)

  Combo("##layout_order", 120, LAYOUT_ORDERS, state.layout_order, function(k)
    state.layout_order = k
    SaveLayoutSettings()
  end)
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx,
      "Script order: the order the CSV lists the lines.\n" ..
      "Record order: the order they were captured, oldest recording first.")
  end
  im.SameLine(ctx)

  -- Original spacing replays a recording's own gaps, which script order has no
  -- equivalent of. The control greys out rather than silently doing nothing.
  local by_script = state.layout_order == "script"
  if by_script then im.BeginDisabled(ctx, true) end
  Combo("##layout_spacing", 140, LAYOUT_SPACINGS,
        by_script and "fixed" or state.layout_spacing,
        function(k) state.layout_spacing = k; SaveLayoutSettings() end)
  if by_script then im.EndDisabled(ctx) end
  TooltipEvenWhenDisabled(by_script
    and "Original spacing needs an order the recording actually had.\nSwitch to record order to use it."
    or  "Fixed gap: the same space after every item.\nOriginal spacing: the gaps as they were recorded.")
  im.SameLine(ctx)

  local fixed = by_script or state.layout_spacing == "fixed"
  if not fixed then im.BeginDisabled(ctx, true) end
  local changed, gap = GapField("between items##layout_gap", 80, state.layout_gap,
    "Space left after the end of each item.")
  if not fixed then im.EndDisabled(ctx) end
  if changed then state.layout_gap = gap; SaveLayoutSettings() end
  im.SameLine(ctx)

  local by_record = state.layout_order == "record"
  if not by_record then im.BeginDisabled(ctx, true) end
  local schanged, sgap = GapField("between recordings##layout_src_gap", 80,
    state.layout_src_gap,
    "Space left between the last item of one recording\nand the first of the next, so it is clear where a file ended.")
  if not by_record then im.EndDisabled(ctx) end
  if schanged then state.layout_src_gap = sgap; SaveLayoutSettings() end
  im.SameLine(ctx)

  if im.Button(ctx, "Sort") then
    pending_action = SortOnTimeline
  end

  -- Counted from the rows alone: clustering walks every item in the project and
  -- has no business running at frame rate.
  local rows, from_selection = AffectedRows()
  local items, sources, item_seen, source_seen = 0, 0, {}, {}
  for _, row in ipairs(rows) do
    if row.item and not item_seen[row.item] then
      item_seen[row.item] = true
      items = items + 1
    end
    local path = row.source_path
    if path and not source_seen[path] then
      source_seen[path] = true
      sources = sources + 1
    end
  end
  im.SameLine(ctx)
  im.TextDisabled(ctx, string.format("%d item%s from %d recording%s (%s)",
    items, items == 1 and "" or "s", sources, sources == 1 and "" or "s",
    from_selection and "selected rows" or "all shown rows"))
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx,
      "With rows selected, only those items move.\n" ..
      "With nothing selected, every item behind the rows shown here moves.\n" ..
      "Overlapping items on one track always travel together, so crossfades survive.")
  end
end

-- Depth of the row ID stack, so an error thrown mid-row can be unwound. ImGui
-- does NOT balance PushID for us at EndTable: it raises "Mismatching
-- PushID/PopID" instead, which buries the real error under a second one.
local id_depth = 0

-- -----------------------------------------------------------------------
-- Row heights
--
-- ImGui has no TableGetColumnWidth: a cell's usable width is only knowable from
-- inside that cell, which is a frame too late to size the row it belongs to.
-- So cells record their width as they draw, and the NEXT frame measures with
-- it. While a column edge is being dragged the heights are therefore one frame
-- stale; they settle on the following frame, which at frame rate is not
-- perceptible. The alternative — a hidden measuring pass — costs a whole extra
-- table every frame.
-- -----------------------------------------------------------------------

-- Heights are MEASURED, never predicted.
--
-- The obvious approach — CalcTextSize(text, wrap_width) with a width taken from
-- GetContentRegionAvail — does not work: inside a table cell that call reports
-- more than the column's own width, so the prediction wraps the text into fewer
-- lines than ImGui goes on to draw. The row comes out genuinely taller than the
-- estimate, and every offset computed from the estimate is short by the
-- difference. Reading back what was actually drawn cannot be wrong in that way,
-- and costs one GetItemRectSize per text cell instead of a CalcTextSize.
--
-- The cost is a frame of lag, which this file already accepts elsewhere, and
-- which is not perceptible at frame rate.
--
-- Rows carry their own measurements:
--   row._h        the tallest cell drawn last frame — the row's content height
--   row._ch[i]    the height column i drew last frame
-- Both are absent on a row's first frame and after a rebuild, where the frame
-- height stands in until the first measurement lands.

-- What alignment is computed against. Floored at the frame height so a row
-- holding an InputText is never treated as shorter than the widget in it.
local function RowHeight(row)
  local floor_h = im.GetFrameHeight(ctx)
  local h = row._h or floor_h
  return (h > floor_h) and h or floor_h
end

-- Start of a row: the accumulator is seeded with the frame height, so widget
-- cells need no measuring of their own — none of them is taller than that,
-- except the filled fields, which are exactly RowHeight by construction and so
-- cannot make the row grow.
local function BeginRowMeasure(row)
  row._ch  = row._ch or {}
  row._acc = im.GetFrameHeight(ctx)
end

local function EndRowMeasure(row)
  row._h = row._acc
end

-- Read back what the cell just drew. Called only from CellText: it is the only
-- helper whose content can exceed one line.
local function MeasureCell(row, index)
  local _, h = im.GetItemRectSize(ctx)
  row._ch[index] = h
  if h > row._acc then row._acc = h end
end

-- Depth of the text-wrap stack, unwound by DrawTable for the same reason the ID
-- and font stacks are.
local wrap_depth = 0

-- Move the caret down so this cell sits where its column's alignment says. The
-- height of what is about to be drawn has to be passed in: ImGui cannot be
-- asked after the fact without having already drawn it in the wrong place.
-- Moved in SCREEN coordinates, not window-local ones. GetCursorPosY/SetCursorPosY
-- are relative to the window origin and go through a Pos/Scroll conversion; the
-- window here is the table's inner scrolling child, and that round trip is the
-- only non-trivial arithmetic in this path. Screen coordinates have no
-- conversion to get wrong.
local function AlignCell(key, row_h, cell_h)
  local offset = view.AlignOffset(row_h, cell_h, ColumnView(key).align)
  if offset <= 0 then return end
  local x, y = im.GetCursorScreenPos(ctx)
  im.SetCursorScreenPos(ctx, x, y + offset)
end

-- One text cell: right font, right vertical position, wrapped or not.
-- `kind` is "plain" | "disabled" | a colour integer.
local function CellText(row, key, index, row_h, text, kind)
  text = text or ""
  local col = ColumnView(key)
  local f = PushCellFont(key)

  -- A wrapped cell's height is whatever it drew last frame; an unwrapped one is
  -- always a single line, which needs no measuring.
  local cell_h
  if col.wrap and text ~= "" then
    cell_h = row._ch[index] or im.GetTextLineHeight(ctx)
  else
    cell_h = im.GetTextLineHeight(ctx)
  end
  AlignCell(key, row_h, cell_h)

  if col.wrap then
    -- 0.0 means "wrap at the end of the content region", which inside a table
    -- cell is the column edge.
    im.PushTextWrapPos(ctx, 0.0)
    wrap_depth = wrap_depth + 1
  end

  if kind == "disabled" then
    im.TextDisabled(ctx, text)
  elseif type(kind) == "number" then
    im.TextColored(ctx, kind, text)
  else
    im.Text(ctx, text)
  end

  if col.wrap then
    im.PopTextWrapPos(ctx)
    wrap_depth = wrap_depth - 1
  end
  -- Measured under the cell's own font, before it is popped.
  MeasureCell(row, index)
  PopCellFont(f)
end

-- A widget cell. Widgets never wrap: a single-line InputText cannot, and making
-- these multiline would change what Enter means in a field where Enter commits
-- a rename. They take the vertical offset all the same.
local function CellWidget(key, row_h)
  AlignCell(key, row_h, im.GetFrameHeight(ctx))
end

-- Depth of the style-colour stack, unwound by DrawTable alongside the ID, font
-- and wrap stacks.
local colour_depth = 0

-- An editable cell, shaded across its whole area. The shading is the affordance
-- that says "you can type here"; on a tall row a one-line-high field floating
-- in a three-line-high cell reads as a gap between fields rather than as the
-- field itself.
--
-- Shade the CELL, not the widget.
--
-- Growing the widget's own frame to fill the cell was the first attempt, and
-- it could not be made to land: the frame reaches its height through
-- FramePadding, which is applied above and below in whole pixels, so on some
-- row heights it fell a pixel short of the border and on others it spilled
-- past. TableSetBgColor paints the cell rectangle ImGui already computed, so
-- the edges are exact at every row height by construction, and there is no
-- geometry here to get wrong.
--
-- The field then draws its text only. All three frame colours go transparent:
-- with the whole cell shaded, an inset hover box would read as the field
-- shrinking under the cursor. The caret and the selection highlight still
-- appear on click, which is where the feedback actually matters.
local FIELD_COLOURS = { 'Col_FrameBg', 'Col_FrameBgHovered', 'Col_FrameBgActive' }

local function PushFilledField(key, row_h)
  im.TableSetBgColor(ctx, im.TableBgTarget_CellBg,
                     im.GetStyleColor(ctx, im.Col_FrameBg), -1)
  for _, name in ipairs(FIELD_COLOURS) do
    im.PushStyleColor(ctx, im[name], 0x00000000)
    colour_depth = colour_depth + 1
  end
  -- Now that the shading is the cell itself, the text inside can honour the
  -- column's own vertical alignment like every other cell does.
  AlignCell(key, row_h, im.GetFrameHeight(ctx))
  im.SetNextItemWidth(ctx, -1)
end

local function PopFilledField()
  im.PopStyleColor(ctx, #FIELD_COLOURS)
  colour_depth = colour_depth - #FIELD_COLOURS
end

-- The header menu.
--
-- BeginPopupContextItem is not used. TableHeader opens ImGui's OWN column menu
-- on right-click as soon as the table is Reorderable, and two popups cannot be
-- open at one level. Opening ours explicitly in the same frame, AFTER
-- TableHeader has opened ImGui's, replaces it — which is the behaviour wanted:
-- the built-in menu offers only column visibility, which this window does not
-- support.
local function DrawHeaderMenu(c)
  local popup_id = "hdr_" .. c.key
  if im.IsItemClicked(ctx, 1) then im.OpenPopup(ctx, popup_id) end
  if not im.BeginPopup(ctx, popup_id) then return end

  local col = ColumnView(c.key)

  if im.BeginMenu(ctx, "Vertical align") then
    for _, a in ipairs(view.ALIGNS) do
      local label = a:sub(1, 1):upper() .. a:sub(2)
      if im.MenuItem(ctx, label, nil, col.align == a) then
        SetColumnView(c.key, "align", a)
      end
    end
    im.EndMenu(ctx)
  end

  if im.MenuItem(ctx, "Word wrap", nil, col.wrap) then
    SetColumnView(c.key, "wrap", not col.wrap)
  end

  if im.BeginMenu(ctx, "Font size") then
    for _, f in ipairs(view.FONT_KEYS) do
      local label = f:sub(1, 1):upper() .. f:sub(2)
      local size  = state.view.sizes[f] or view.FONT_DEFAULTS[f]
      if im.MenuItem(ctx, string.format("%s (%d)", label, size), nil, col.font == f) then
        SetColumnView(c.key, "font", f)
      end
    end
    im.EndMenu(ctx)
  end

  im.EndPopup(ctx)
end

local function DrawTableBody()
  for _, c in ipairs(COLUMNS) do
    im.TableSetupColumn(ctx, c.label, im.TableColumnFlags_WidthFixed, c.width)
  end
  im.TableSetupScrollFreeze(ctx, 0, 1)
  -- Headers drawn by hand rather than with TableHeadersRow, which draws them
  -- all in one call and leaves nothing to hang a per-column tooltip on. The
  -- explanation of a column belongs on its header, read once, not under the
  -- cursor on every row of the table.
  if HEADER_ROW_FLAGS then
    im.TableNextRow(ctx, HEADER_ROW_FLAGS)
    for i, c in ipairs(COLUMNS) do
      im.TableSetColumnIndex(ctx, i - 1)
      im.TableHeader(ctx, c.label)
      if c.tip and im.IsItemHovered(ctx) then im.SetTooltip(ctx, c.tip) end
      -- The TableHeadersRow fallback below gets no menu: that branch only runs
      -- on a binding too old to expose TableRowFlags_Headers, and there is no
      -- per-column item there to hang a popup on.
      DrawHeaderMenu(c)
    end
  else
    im.TableHeadersRow(ctx)
  end

  if #state.visible == 0 then
    im.TableNextRow(ctx)
    im.TableSetColumnIndex(ctx, 0)
    im.TextDisabled(ctx, #state.overview == 0
      and "Nothing to show yet. Load a script CSV, or transcribe a recording in ajsfx VO Sources."
      or  "No rows match the current filters.")
    return
  end

  -- Every row is emitted; ImGui's own table clipping keeps off-screen rows out
  -- of the draw list. ListClipper is deliberately NOT used: ReaImGui rejects it
  -- here as excessive creation of short-lived resources, which is why
  -- ScriptMatch dropped it from its preview table too.
  for i, row in ipairs(state.visible) do
    -- No min_row_height: ImGui already sizes the row from its tallest cell,
    -- and row_h is the measurement of that from last frame.
    local row_h = RowHeight(row)
    BeginRowMeasure(row)
    im.TableNextRow(ctx)
    im.PushID(ctx, i)
    id_depth = id_depth + 1

    -- Verified ------------------------------------------------------------
    im.TableSetColumnIndex(ctx, 0)
    CellWidget("verify", row_h)
    local checked = row.user_status == "verified"
    local hit, now = im.Checkbox(ctx, "##ok", checked)
    if hit then pending_action = function() SetStatus(row, now and "verified" or nil) end end

    -- Status --------------------------------------------------------------
    im.TableSetColumnIndex(ctx, 1)
    -- Drawn first in the row and spanning it, so a click anywhere that is not a
    -- widget navigates. AllowOverlap lets the inputs drawn afterwards win.
    -- Given the row's full height so a click anywhere in a TALL row still
    -- selects, rather than only in its top FrameHeight pixels.
    local sel_flags = im.SelectableFlags_SpanAllColumns
    local overlap = Api('SelectableFlags_AllowOverlap')
    if overlap then sel_flags = sel_flags | overlap end
    local style = STATUS_STYLE[row.status]
    if im.Selectable(ctx, "##row", state.selection[row.uid] == true, sel_flags, 0, row_h) then
      -- Read the modifiers now, inside the frame that saw the click; by the time
      -- the deferred action runs the key could already be up.
      local captured = ReadModifiers()
      local at = i
      pending_action = function() ClickRow(row, at, captured) end
    end
    if im.IsItemHovered(ctx) and not row.item then
      im.SetTooltip(ctx, row.status == "missing"
        and "This line has no audio in the project yet."
        or  "The audio for this row is not in this project.")
    end
    im.SameLine(ctx)
    -- SameLine returns the caret to the TOP of the tall selectable, so the
    -- status word needs its own offset.
    local sf = PushCellFont("status")
    AlignCell("status", row_h, im.GetTextLineHeight(ctx))
    if row.user_status == "flagged" then
      im.TextColored(ctx, 0xDD6666FF, "Flagged")
    elseif style then
      im.TextColored(ctx, style.colour, style.label)
    end
    PopCellFont(sf)

    -- Select --------------------------------------------------------------
    im.TableSetColumnIndex(ctx, 2)
    if row.status ~= "missing" and row.status ~= "orphan" and (row.take_count or 0) > 0 then
      CellWidget("select", row_h)
      local hit, now = im.Checkbox(ctx, "##sel", row.user_select == true)
      if hit then pending_action = function() SetSelect(row, now) end end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, (row.take_count > 1)
          and "Mark this take as the select."
          or  "The only take of this line.")
      end
    end

    im.TableSetColumnIndex(ctx, 3)
    CellText(row, "character", 3, row_h, row.character, "plain")

    -- Filename ------------------------------------------------------------
    im.TableSetColumnIndex(ctx, 4)
    -- The live take name where there is a take, so a rename made anywhere else
    -- in REAPER shows up here too. The project file's override is the fallback, so a
    -- name chosen for a line whose audio is not loaded is not lost.
    local shown = row.take_name or row.name_override or row.asset or ""
    if row.status == "missing" then
      -- Nothing to rename: there is no take at all.
      CellText(row, "item_name", 4, row_h, shown, "disabled")
      TooltipEvenWhenDisabled("This line has no take yet, so there is no item to name.")
    else
      PushFilledField("item_name", row_h)
      local fchanged, fname = im.InputText(ctx, "##fn", shown,
                                           im.InputTextFlags_EnterReturnsTrue)
      PopFilledField()
      -- Committed on Enter or on losing focus after an edit, never per
      -- keystroke: each commit is its own undo point in the project.
      if fchanged or im.IsItemDeactivatedAfterEdit(ctx) then
        if fname ~= shown then
          local captured = fname
          pending_action = function() Rename(row, captured) end
        end
      end
    end

    -- CSV filename ---------------------------------------------------------
    -- Read-only on purpose: this is the script's own name for the line, and the
    -- reason a rename can never leave the user wondering what it used to be.
    im.TableSetColumnIndex(ctx, 5)
    local csv_name = row.asset or ""
    CellText(row, "asset", 5, row_h, csv_name, "disabled")
    -- No per-cell tooltip: the explanation belongs on the header, where it is
    -- read once, not under the cursor on every row. An explicit popup ID is
    -- what lets a plain Text item own a context menu.
    if csv_name ~= "" and im.BeginPopupContextItem(ctx, "##csv_menu") then
      if im.MenuItem(ctx, "Copy") then Copy(csv_name) end
      local can_reset = row.status ~= "missing" and shown ~= csv_name
      if im.MenuItem(ctx, "Reset item name", nil, nil, can_reset) then
        pending_action = function() ResetName(row) end
      end
      if not can_reset then
        TooltipEvenWhenDisabled("The item is already named " .. csv_name .. ".")
      end
      im.EndPopup(ctx)
    end

    im.TableSetColumnIndex(ctx, 6)
    if (row.take_count or 0) > 1 then
      CellText(row, "take", 6, row_h,
               string.format("%d/%d", row.take_index or 0, row.take_count), "plain")
    elseif row.take_index then
      CellText(row, "take", 6, row_h, "1/1", "disabled")
    end

    im.TableSetColumnIndex(ctx, 7)
    CellText(row, "line_text", 7, row_h, row.line_text, "plain")

    im.TableSetColumnIndex(ctx, 8)
    if row.score and row.status == "review" then
      CellText(row, "transcript", 8, row_h, row.transcript, 0xDDAA33FF)
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, string.format("Match confidence %.0f%%.", row.score * 100))
      end
    else
      CellText(row, "transcript", 8, row_h, row.transcript, "disabled")
    end

    im.TableSetColumnIndex(ctx, 9)
    CellText(row, "source", 9, row_h,
             row.source_path and vo.Basename(row.source_path) or "", "disabled")

    im.TableSetColumnIndex(ctx, 10)
    CellText(row, "time", 10, row_h, FormatTime(row.proj_time), "disabled")

    -- Notes ---------------------------------------------------------------
    im.TableSetColumnIndex(ctx, 11)
    PushFilledField("notes", row_h)
    local nchanged, notes = im.InputText(ctx, "##notes", row.notes or "")
    PopFilledField()
    if nchanged then
      local captured = notes
      pending_action = function() SetNotes(row, captured) end
    end

    im.PopID(ctx)
    id_depth = id_depth - 1
    EndRowMeasure(row)
  end
end

local function DrawTable(height)
  local flags = im.TableFlags_Borders | im.TableFlags_Resizable
              | im.TableFlags_Reorderable
              | im.TableFlags_ScrollY | im.TableFlags_RowBg
  -- With restore off ImGui neither reads nor writes this table's widths and
  -- order, so it opens at the widths COLUMNS declares. ImGui keys table
  -- settings by (table id, column count) anyway, so adding a column in a later
  -- version invalidates a saved layout by itself — which is correct.
  if not state.view.restore then
    local no_saved = Api('TableFlags_NoSavedSettings')
    if no_saved then flags = flags | no_saved end
  end
  if not im.BeginTable(ctx, "vo_overview", #COLUMNS, flags, 0, height) then
    return
  end
  -- The body runs inside pcall for the same reason ScriptMatch's does: an error
  -- escaping between BeginTable and EndTable leaves ImGui's stack corrupted for
  -- every later frame. Nothing here pushes a combo or a disabled scope, but the
  -- per-row PushID has to be unwound by hand — EndTable raises on an unbalanced
  -- ID stack, which would replace the real error with a useless one.
  local ok, err = pcall(DrawTableBody)
  while id_depth > 0 do
    im.PopID(ctx)
    id_depth = id_depth - 1
  end
  while font_depth > 0 do
    im.PopFont(ctx)
    font_depth = font_depth - 1
  end
  while wrap_depth > 0 do
    im.PopTextWrapPos(ctx)
    wrap_depth = wrap_depth - 1
  end
  while colour_depth > 0 do
    im.PopStyleColor(ctx)
    colour_depth = colour_depth - 1
  end
  im.EndTable(ctx)
  if not ok then state.message, state.message_kind = tostring(err), "error" end
end

local function DrawSummary()
  local n = state.summary
  im.Text(ctx, string.format("%d of %d lines recorded", n.delivered or 0, n.lines or 0))
  im.SameLine(ctx)
  im.TextDisabled(ctx, "·")
  im.SameLine(ctx)
  im.TextColored(ctx, 0x66BB66FF, string.format("%d verified", n.verified or 0))
  if (n.review or 0) > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextColored(ctx, 0xDDAA33FF, string.format("%d to review", n.review))
  end
  if (n.missing or 0) > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextColored(ctx, 0xDD6666FF, string.format("%d missing", n.missing))
  end
  if (n.flagged or 0) > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextColored(ctx, 0xDD6666FF, string.format("%d flagged", n.flagged))
  end
  if (n.orphan or 0) > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextDisabled(ctx, string.format("%d orphan", n.orphan))
  end
end

-- -----------------------------------------------------------------------
-- Settings
--
-- A window, not a modal: the point of changing a font size is watching the
-- table change under it.
-- -----------------------------------------------------------------------

local function DrawSettingsWindow()
  if not state.settings_open then return end

  im.SetNextWindowSize(ctx, 400, 320, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'VO Overview Settings', true)
  state.settings_open = open

  -- End is called only when Begin returned visible, matching the main window's
  -- loop. That is ReaImGui's contract, and it differs from upstream Dear ImGui.
  if visible then
    local changed, on = im.Checkbox(ctx, "Restore view settings", state.view.restore)
    if changed then SetRestore(on) end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx,
        "Remember the column widths, the column order, and each column's\n" ..
        "alignment, word wrap and font size, and put them back next time.\n" ..
        "Turning this off clears what is already stored.")
    end

    im.Spacing(ctx)
    -- SeparatorText is not in every 0.9.x binding, and the shim raises on an
    -- unknown field, so `im.SeparatorText and ...` would itself be the crash.
    local SeparatorText = Api('SeparatorText')
    if SeparatorText then SeparatorText(ctx, "Font sizes") else im.Separator(ctx) end
    im.TextDisabled(ctx, "Right-click a column header to pick which one it uses.")

    for _, key in ipairs(view.FONT_KEYS) do
      im.SetNextItemWidth(ctx, 100)
      local label = key:sub(1, 1):upper() .. key:sub(2)
      local hit, size = im.InputInt(ctx, label .. "##font_" .. key,
                                    state.view.sizes[key] or view.FONT_DEFAULTS[key])
      if hit then
        -- Clamped rather than rejected: there is no number a user can type here
        -- that should produce an error message.
        state.view.sizes[key] = view.ClampFontSize(size, view.FONT_DEFAULTS[key])
        view.SaveFontSizes(state.view.sizes)
        fonts_dirty = true
      end
    end

    im.Spacing(ctx)
    if SeparatorText then SeparatorText(ctx, "Columns") else im.Separator(ctx) end

    im.Text(ctx, "Align every column:")
    -- Checked here rather than after the loop, where it would have described
    -- the last button instead of the group.
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Set every column at once, instead of one header at a time.\n" ..
                         "Individual columns can still be changed afterwards.")
    end
    for _, a in ipairs(view.ALIGNS) do
      im.SameLine(ctx)
      local label = a:sub(1, 1):upper() .. a:sub(2)
      if im.Button(ctx, label .. "##align_all_" .. a) then SetAllAlign(a) end
    end

    local mchanged, mon = im.Checkbox(ctx, "Match Transcript to Line text", state.view.mirror)
    if mchanged then SetMirror(mon) end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx,
        "Keep the two columns' alignment, word wrap and font size identical, so\n" ..
        "the script and what was actually said line up while you read across.\n" ..
        "Changing either column changes both. Line text is copied to Transcript\n" ..
        "when this is switched on.\n\n" ..
        "Column WIDTH is not included: ReaImGui gives no way to set a table\n" ..
        "column's width from a script. Drag the two to match by hand.")
    end

    im.End(ctx)
  end
end

-- -----------------------------------------------------------------------
-- Startup and loop
-- -----------------------------------------------------------------------

LoadProjectFile()
LoadCSV(state.script_csv)
ApplyMappingDefaults()
LoadLayoutSettings()
LoadViewSettings()
Reload()

local function loop()
  if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
    ctx = im.CreateContext('VO Overview')
    -- A recreated context has no fonts attached at all.
    fonts, fonts_dirty = {}, true
  end

  -- Between frames, before Begin: attaching during a frame is not guaranteed to
  -- take effect for that frame.
  EnsureFonts()

  -- MaybeRescan is throttled internally; keep drawing every frame regardless.
  MaybeRescan()

  FlushProjectFile(false)
  ApplyFilters()

  im.SetNextWindowSize(ctx, 1180, 720, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'ajsfx VO Overview', true)

  if visible then
    pending_action = nil

    -- Script CSV ----------------------------------------------------------
    im.Text(ctx, "Script:")
    im.SameLine(ctx)
    if state.script_csv == "" then
      im.TextDisabled(ctx, "none chosen")
    else
      im.TextDisabled(ctx, vo.Basename(state.script_csv))
      if im.IsItemHovered(ctx) then im.SetTooltip(ctx, state.script_csv) end
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Choose…") then
      local ok, path = r.GetUserFileNameForRead(state.script_csv, "Select the session script", "csv")
      if ok then
        state.script_csv = path
        LoadCSV(path)
        ApplyMappingDefaults()
        state.dirty = true    -- the Script CSV field in the project file needs saving
        Reload()
      end
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Settings") then state.settings_open = true end

    if state.header_error ~= "" then
      im.TextColored(ctx, 0xDD6666FF, state.header_error)
    elseif state.header and not (state.mapping.asset and state.mapping.text) then
      im.TextColored(ctx, 0xDDAA33FF,
        "This script's Filename and Line Text columns are not mapped, and could not\n" ..
        "be guessed automatically. Rename the CSV's headers to something recognisable\n" ..
        "(e.g. \"Filename\" and \"Line Text\"), or edit the Mapping row of " ..
        vo.Basename(state.project_path or "the project's _vo.csv") .. " directly.")
    end

    im.Separator(ctx)
    DrawSummary()
    im.Spacing(ctx)
    DrawFilters()
    im.Spacing(ctx)
    DrawLayoutBar()
    im.Spacing(ctx)

    -- Reserve room for whatever notices are showing; the table takes the rest.
    local rows = 1                                     -- the count line below
    if state.message ~= ""       then rows = rows + vo.CountLines(state.message, 4) end
    if state.project_error ~= "" then rows = rows + vo.CountLines(state.project_error, 4) end
    if not state.project_path    then rows = rows + 1 end

    -- GetContentRegionAvail returns width first, so height is the SECOND value.
    local _, avail_h = im.GetContentRegionAvail(ctx)
    DrawTable(math.max(120, avail_h - im.GetFrameHeightWithSpacing(ctx) * rows))

    im.TextDisabled(ctx, string.format("%d of %d rows shown.",
      #state.visible, #state.overview))

    if not state.project_path then
      im.TextColored(ctx, 0xDDAA33FF,
        "Save the project to keep verified marks, notes and renames.")
    end
    if state.project_error ~= "" then
      im.TextColored(ctx, 0xDD6666FF, state.project_error .. "\nNothing will be saved until this is fixed.")
    end
    if state.message ~= "" then
      im.TextColored(ctx, state.message_kind == "error" and 0xDD6666FF or 0x66BB66FF,
                     state.message)
    end

    -- Space toggles the selected row, but only when no text field has focus --
    -- otherwise typing a space in Notes would fire it.
    if state.focus_key and not im.IsAnyItemActive(ctx)
       and im.IsWindowFocused(ctx, im.FocusedFlags_RootAndChildWindows)
       and im.IsKeyPressed(ctx, im.Key_Space) then
      for _, row in ipairs(state.visible) do
        if row.uid == state.focus_key then
          SetStatus(row, row.user_status == "verified" and nil or "verified")
          break
        end
      end
    end

    im.End(ctx)

    -- Drawn after the main window's End so it is a sibling, not a child.
    DrawSettingsWindow()

    -- Run after End so ImGui's frame is closed before anything mutates state
    -- or the project. One action per frame is enough: they are all user clicks.
    if pending_action then
      local action = pending_action
      pending_action = nil
      -- Cleared first so a stale success or error from the previous action is
      -- never left sitting under the result of this one.
      state.message, state.message_kind = "", "ok"
      action()
    end
  end

  if open then
    r.defer(loop)
  else
    FlushProjectFile(true)
  end
end

r.defer(loop)
