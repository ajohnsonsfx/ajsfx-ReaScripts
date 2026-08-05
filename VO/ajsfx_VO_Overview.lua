-- @description ajsfx VO Overview
-- @author ajsfx
-- @version 0.13
-- @changelog Cutting and routing were one operation; they are now three, and they live in ajsfx VO Overview beside the table they act on -- the separate "ajsfx VO Cut" window is gone, so reinstall from ReaPack to clear it. The workflow is: Cut and Name, then Pull, then listen and tick, then Pull again. "Cut and Name" splits every take the match found out of its recording and names it the script's own filename. It moves nothing and decides nothing, so it no longer refuses to run because some line is undecided -- slicing the recording is the first step of the job and has to happen before there is anything to decide about. With nothing selected it works on every row on show. The only thing it skips is a recording whose audio has changed since it was transcribed, and that is skipped per file rather than stopping the run. "Pull" moves items onto Selects, Alts and Review tracks, which are now CHILDREN of the recording they came from rather than siblings, so collapsing the recording folds the whole session away with it. On a fresh session nothing is ticked, so the first Pull puts everything on Review -- that is the pile you work through. "Sort" lays them out on the timeline as before. The important change is how Pull and Sort decide what an item is: they read the NAME it carries and look that up in the script, and never consult the transcript at all. A folder of rendered wav files someone else delivered -- no transcripts, never cut here -- now pulls and sorts exactly as well as a session you cut yourself. It also means neither tool can touch audio it was not asked to: an uncut recording carries the recording's name, which is not a script filename, so it resolves to nothing and is left where it is, and the count line says how many were left. A name two script lines both claim resolves to nothing rather than to the first of them. The Select column is now two independent checkboxes, Sel and Keep. Sel is the take you are delivering, one per line. Keep is a read worth keeping, any number per line, and Pull delivers a kept take that is not the Sel as an alt. Ticking Keep steals nothing from anybody -- the single cycling mark this replaces made you pass through Sel to reach Alt, which took the select off whichever take already had it. Sel's exclusivity is now keyed by SCRIPT ROW rather than by filename, so two CSV rows that ask for the same filename are two lines again and ticking one no longer unticks the other; they were separate rows in the script and they stay separate here. An alt needs a filename of its own, so "Name alts" in the Pull panel gives every alt that has none one, built on the line's delivered name -- the pattern, the first number and the zero padding are all yours to set, {n} marks where the number goes, and a preview shows the result before you press it. The name is held against the take, so the select keeps the plain delivery. A name you chose is never overwritten. The "use alts track" toggle is gone, and so are the six filter presets -- the Status column's own filter box already matches Recorded, Review, Missing, Orphan and Flagged, and Lock covers verified. The toolbar is one row of six: Script, Sources, Cut and Name, Pull, Sort, Settings, with one panel open at a time.
-- @about ajsfx VO — script-matched cut-and-name for game VO and dialogue
--        delivery. Transcribe your recordings once in "ajsfx VO Sources", see
--        every script line and every take in "ajsfx VO Overview", tick the
--        takes you are delivering, then Cut and Name, Pull and Sort them from
--        the same window. Runs fully locally with whisper.cpp; configure the
--        backend in "ajsfx VO Settings". See VO/SPEC.md.
-- @provides
--   [main] .
--   [main] ajsfx_VO_Sources.lua
--   [main] ajsfx_VO_Settings.lua
--   lib/ajsfx_vo.lua
--   lib/ajsfx_vo_view.lua
--   ../lib/ajsfx_core.lua > lib/ajsfx_core.lua
--
-- ajsfx VO Overview — a project-wide picture of the dialogue in a session.
--
-- Every line the script says should exist, every span a LIVE match against
-- each source's transcript says does exist, in one table across every
-- recording in the project. This script does not transcribe (ajsfx VO
-- Sources): it reads the per-source transcripts plus
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

-- Header-click sorting. Absent on an older binding, in which case the table
-- simply stays in script order and the headers do nothing when clicked.
local SORT_SPECS  = Api('TableGetColumnSortSpecs')
local NEED_SORT   = Api('TableNeedSort')
local SORT_DESC   = Api('SortDirection_Descending')

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

-- Defined here rather than beside the other UI helpers because the column
-- accessors below need it.
local function FormatTime(t)
  if not t then return "" end
  local m = math.floor(t / 60)
  return string.format("%d:%06.3f", m, t - m * 60)
end

local SORT_RANK = { missing = 1, review = 2, orphan = 3, recorded = 4 }

local function StatusLabel(row)
  if row.user_status == "flagged" then return "Flagged" end
  local s = STATUS_STYLE[row.status]
  return s and s.label or (row.status or "")
end

local function ItemName(row)
  return row.take_name or row.name_override or row.deliver or row.asset or ""
end

-- Sorting and filtering are one mechanism across every column, driven by two
-- optional accessors rather than a switch statement per feature.
--   text  what a column's filter box matches against, and what an alphabetical
--         sort compares. A column without it is neither sorted nor filtered:
--         there is nothing there a user could have meant.
--   num   overrides text for columns that are really numbers, so Time sorts
--         9:59 before 10:00 and # sorts 2 before 10.
-- Either may return nil or "" for a row that has no value; such rows sort last
-- in BOTH directions, because reversing a sort should not fill the top of the
-- table with blanks.
-- Forward-declared: the column accessors below close over it, and `state` is
-- not built until after this table. Assigned once state exists.
local DELIVERY

local COLUMNS = {
  { key = "order",      label = "#",          width =  36, nofilter = true,
    num  = function(row) return row.order end,
    text = function(row) return tostring(row.order or "") end,
    tip = "Position in the script CSV. Sort by this column to put the\n" ..
          "table back into script order." },
  { key = "verify",     label = "Lock",       width =  40,
    text = function(row) return row.user_status == "verified" and "yes" or "no" end,
    tip = "A locked line keeps the placement it has.\nRematching leaves it alone." },
  { key = "status",     label = "Status",     width =  74,
    num  = function(row) return SORT_RANK[row.status] or 9 end,
    text = StatusLabel },
  -- Answered from the project's item names, not from the match: this is the
  -- "have I got everything" column, and it is true whether the take was cut
  -- here, comped by hand, or delivered by somebody else.
  { key = "delivered",  label = "Got",        width =  56,
    num  = function(row)
      local rec = row.script_row and DELIVERY(row.script_row)
      return rec and rec.count or 0
    end,
    text = function(row)
      local rec = row.script_row and DELIVERY(row.script_row)
      if not rec then return "no" end
      return tostring(rec.count)
    end,
    tip = "How many items in the project carry this line's name.\n" ..
          "Read from the names themselves, so it counts takes this tool\n" ..
          "never cut. Hover a cell for the tracks they sit on." },
  { key = "select",     label = "Sel",        width =  40,
    text = function(row)
      if row.status == "missing" or row.status == "orphan" then return "" end
      return row.user_select and "yes" or "no"
    end },
  -- Two independent ticks, not one cycling mark. Marking a take as an alt used
  -- to mean passing through "select" on the way, which stole the select from
  -- whichever take already had it.
  { key = "keep",       label = "Keep",       width =  46,
    text = function(row)
      if row.status == "missing" or row.status == "orphan" then return "" end
      return row.user_keep and "yes" or "no"
    end },
  { key = "character",  label = "Character",  width =  90,
    text = function(row) return row.character or "" end },
  { key = "script",     label = "Script",     width =  90,
    text = function(row) return row.script or "" end,
    tip = "Which script CSV this line came from." },
  -- Two names, deliberately. "Item name" is what the user is changing and what
  -- REAPER's render patterns read; "CSV filename" is the script's own name for
  -- the line, kept visible and read-only so a rename never loses the original.
  { key = "item_name",  label = "Item name",  width = 190,
    text = ItemName,
    tip = "The take's name in REAPER. Editable, and what the stock render\n" ..
          "patterns read. Nothing here renames a file on disk." },
  { key = "asset",      label = "CSV filename", width = 160,
    text = function(row) return row.asset or "" end,
    tip = "The filename from the script CSV. Not editable.\n" ..
          "Right-click a cell to copy it or to put it back on the item." },
  { key = "append",     label = "Append",     width = 110,
    text = function(row) return row.append or "" end,
    tip = "Added to the end of the CSV filename to make the delivered name.\n" ..
          "No separator is inserted -- type the one you want. Use it to tell\n" ..
          "apart two lines that ask for the same filename." },
  { key = "take",       label = "Take",       width =  44,
    num  = function(row) return row.take_index end,
    text = function(row)
      if not row.take_index then return "" end
      return string.format("%d/%d", row.take_index, row.take_count or 1)
    end },
  { key = "line_text",  label = "Line text",  width = 240,
    text = function(row) return row.line_text or "" end },
  { key = "transcript", label = "Transcript", width = 240,
    text = function(row) return row.transcript or "" end },
  { key = "source",     label = "Source",     width = 120,
    text = function(row)
      return row.source_path and vo.Basename(row.source_path) or ""
    end },
  { key = "time",       label = "Time",       width =  76,
    num  = function(row) return row.proj_time end,
    text = function(row) return FormatTime(row.proj_time) end },
  { key = "notes",      label = "Notes",      width = 200,
    text = function(row) return row.notes or "" end },
}

local COLUMN_BY_KEY = {}
for _, c in ipairs(COLUMNS) do COLUMN_BY_KEY[c.key] = c end

-- Column index by key, 0-based for ImGui. DrawTableBody addresses cells through
-- this rather than by literal number, so inserting a column is one edit to
-- COLUMNS instead of a renumbering of every call site below.
local CI = {}
for i, c in ipairs(COLUMNS) do CI[c.key] = i - 1 end

-- Every column key, in declaration order. Used to load, save and clear the
-- per-column settings without anything having to restate the list.
local function ColumnKeys()
  local keys = {}
  for i, c in ipairs(COLUMNS) do keys[i] = c.key end
  return keys
end

local TAKE_PICKS = {
  { key = "last",  label = "Last" },
  { key = "first", label = "First" },
}

local LAYOUT_ORDERS = {
  { key = "script", label = "Script order" },
  { key = "record", label = "Record order" },
}

local LAYOUT_SPACINGS = {
  { key = "fixed",    label = "Fixed gap" },
  { key = "original", label = "Original spacing" },
}

local state = {
  -- The scripts this project reads, in the order they were added. This is the
  -- PERSISTED shape: { path, mapping, enabled }. state.loaded below is what
  -- reading them produced, and is rebuilt whenever this changes.
  scripts       = {},
  loaded        = { scripts = {}, lines = {} },
  -- Which inline panel is open, or nil for none. One at a time: they all draw
  -- in the same space above the table, and two at once would push it off the
  -- window. "script" opens itself when a script fails to load.
  panel         = nil,        -- "script" | "cut" | "pull" | "sort"
  -- Whether the tools narrow to the table's selection. Off by default: see
  -- AffectedRows for why selection makes a poor default scope here.
  selection_only = false,
  cut_summary   = {},         -- what the last Cut and Name run did
  -- The Cut panel's stage counts, memoised. Worked out from the same code the
  -- run uses, so what it says and what it does cannot drift apart.
  cut_result     = nil,       -- what the last run said, shown in the panel
  pull_result    = nil,       -- the same, for the Pull panel
  pull_result_kind = "ok",
  cut_result_kind = "ok",
  cut_count_key = nil,
  cut_counts    = { spans = 0, cuttable = 0, in_range = 0, stale = 0, candidates = 0 },
  -- The Pull panel's count line, memoised: working it out reads a take name per
  -- item. Keyed on the project-state counter and the selection size.
  pull_count_key = nil,
  pull_count     = { selects = 0, alts = 0, review = 0,
                     unknown = 0, ambiguous = 0 },
  -- The Sort panel's count line, memoised for the same reason.
  layout_count_key = nil,
  layout_count     = { items = 0, unresolved = 0, scope = "" },
  appends       = {},         -- vo.SetAppend records, per script line
  dupe_names    = {},         -- vo.DuplicateNames set, for the red highlight
  -- vo.CheckCoverage over the project's item names: which script lines have an
  -- item carrying their name. Derived every rebuild, never stored.
  check         = { by_line = {}, delivered = 0, missing = 0, extra = {}, ambiguous = 0 },
  lines         = {},         -- the merged, resolved script lines

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

  -- nil means script order. ImGui owns the header clicks and the arrow; these
  -- two fields are all we keep of the spec it hands back.
  sort_col      = nil,        -- a COLUMNS key
  sort_desc     = false,

  auto_select_take = "last",  -- which take "Select takes" marks; from the config

  filter_row    = false,      -- the per-column filter boxes under the header
  col_filters   = {},         -- column key -> needle

  candidates      = {},       -- Find candidates results, one group per row asked about
  candidates_open = false,

  -- Placements made by hand: { asset, source, start, stop }. Unlike everything
  -- else in the project file these are an INPUT to matching, not a note about
  -- its output, so changing one has to re-run the match.
  pins            = {},

  character     = nil,
  search        = "",
  -- Set when a character filter is restored from the project file, cleared by
  -- the first check against the rows. See CheckRestoredCharacter.
  check_character = false,

  message       = "",
  message_kind  = "ok",

  -- Presentation. Loaded once at startup and written through on every change;
  -- nothing reads ExtState per frame.
  view          = { restore = true, mirror = false, sizes = {}, cols = {} },
  settings_open = false,
}

-- Now that `state` exists, give the Got column its accessor.
DELIVERY = function(line_index)
  return state.check and state.check.by_line[line_index] or nil
end


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

-- The active tab's project handle and file path. The handle is what tells a
-- TAB SWITCH (different project) apart from a SAVE-AS (same project, new
-- path); the two need opposite handling below.
local function CurrentProject()
  local proj, path = r.EnumProjects(-1, "")
  return proj, path or ""
end

local function ProjectPath()
  local _, path = CurrentProject()
  return path
end

-- Whole file to a temp name, then renamed into place, so a crash mid-write
-- leaves either the old file or the new one -- never a truncated one that
-- trips the parse-failed lockout and blocks saving until hand-repair.
local function WriteFileAtomic(path, text)
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "wb")
  if not f then return false end
  f:write(text)
  f:close()
  os.remove(path)
  return os.rename(tmp, path) == true
end

-- -----------------------------------------------------------------------
-- The script side
-- -----------------------------------------------------------------------

-- Read every script the project names, merge their lines, and apply the
-- Appends. state.scripts is the persisted list; state.loaded is what reading it
-- produced, including per-script errors and headers for the column pickers.
--
-- Skip values are not part of the project file (vo.PROJECT_HEADER carries only
-- the mapping); the default skip list (vo.DEFAULT_SKIP_VALUES) is what
-- vo.BuildScriptLines falls back to when none is supplied.
local function LoadScripts()
  state.loaded = vo.LoadScripts(state.scripts, ReadFile)
  -- A script whose columns were never mapped gets the header's own suggestion,
  -- so a freshly added CSV usually just works. Auto-detection knows the usual
  -- header names and no more; when it comes up short the panel that fixes it
  -- opens itself rather than waiting to be found.
  local guessed = false
  for i, sc in ipairs(state.loaded.scripts) do
    local persisted = state.scripts[i]
    if sc.header and not (persisted.mapping and next(persisted.mapping)) then
      persisted.mapping = vo.AutoDetectMapping(sc.header) or {}
      guessed = true
    end
  end
  if guessed then state.loaded = vo.LoadScripts(state.scripts, ReadFile) end

  for _, sc in ipairs(state.loaded.scripts) do
    if sc.error and sc.error ~= "" then state.panel = "script" end
  end

  vo.ResolveNames(state.loaded.lines, vo.AppendMap(state.appends))

  -- An Append that no loaded line answers to detaches silently -- a renamed
  -- or re-exported script CSV is enough -- and the clash it used to clear
  -- comes back on the next cut. Surfaced, not repaired: which line it should
  -- attach to is the user's call.
  state.orphan_appends = vo.OrphanAppends(state.appends, state.loaded.lines)
end

-- The script lines this project expects, after skip tokens and with every
-- Append applied. Returns an empty list (never nil) so callers need no special
-- case.
local function ScriptLines()
  return state.loaded.lines or {}
end

-- How many scripts could not be read or mapped, for the banner.
local function BadScriptCount()
  local n = 0
  for _, sc in ipairs(state.loaded.scripts or {}) do
    if sc.error and sc.error ~= "" then n = n + 1 end
  end
  return n
end

-- -----------------------------------------------------------------------
-- The audio side
-- -----------------------------------------------------------------------

local function LoadProjectFile()
  state.entries, state.project_error, state.parse_failed = {}, "", false
  state.scripts, state.appends, state.pins = {}, {}, {}
  -- Everything below describes the PREVIOUS project. A message like "Pulled 27
  -- select" surviving a tab switch reads as a claim about the new project.
  state.message, state.message_kind = nil, nil
  state.cut_result, state.cut_result_kind, state.cut_summary = nil, nil, nil
  state.pull_result, state.pull_result_kind = nil, nil
  state.name_baseline, state.name_drift = nil, {}

  local proj_handle, proj = CurrentProject()
  -- Which tab this state was loaded from, so the frame loop can notice the
  -- user landing on a different one.
  state.tab_proj, state.tab_path = proj_handle, proj
  state.project_path = (proj ~= "") and vo.ProjectFilePath(proj) or nil
  if not state.project_path then return end

  local text = ReadFile(state.project_path)
  if not text then return end          -- no project file yet is the normal first run

  local parsed, reason = vo.ParseProjectFile(text)
  if parsed then
    state.entries = parsed.entries
    state.scripts = parsed.scripts or {}
    state.appends = parsed.appends or {}
    state.pins    = parsed.pins or {}

    -- The table is handed back the way it was left. A stored status or column
    -- this version no longer has is dropped rather than carried: it would filter
    -- by something with no control to clear it. The character is checked later,
    -- against the rows -- see CheckRestoredCharacter. The sort is not here:
    -- ImGui restores that itself, from its own ini.
    local v = parsed.view or {}
    state.character   = v.character
    state.search      = v.search or ""
    state.filter_row  = v.filter_row or false
    state.col_filters = {}
    for key, needle in pairs(v.col_filters or {}) do
      if COLUMN_BY_KEY[key] then state.col_filters[key] = needle end
    end
    state.check_character = (v.character ~= nil)
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

  -- The path the state was LOADED from, not the active tab's: a flush that
  -- fires just after a tab switch must land in the project the marks belong
  -- to. Deriving fresh is only for a project that was unsaved at load time
  -- and has been saved since.
  local path = state.project_path or vo.ProjectFilePath(ProjectPath())
  if not path then
    state.message, state.message_kind =
      "Save the project before marking anything — the VO project file lives beside it.",
      "error"
    return false
  end
  state.project_path = path

  local ok = WriteFileAtomic(path, vo.SerializeProjectFile(
    vo.ProjectEntriesFromRows(state.overview),
    { scripts = state.scripts, appends = state.appends, pins = state.pins,
      view = {
        character   = state.character,
        search      = state.search,
        filter_row  = state.filter_row,
        col_filters = state.col_filters,
      } }))
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

local function MatchKey(paths, scripts, cfg)
  local parts = { CfgKey(cfg) }
  -- Every script, in order: adding one, removing one, remapping a column or
  -- switching one off all change which audio matches which line. Appends are
  -- deliberately NOT here -- they change only the delivered name, so a rename
  -- must not cost a re-match.
  for _, sc in ipairs(scripts or {}) do
    parts[#parts + 1] = "script:" .. (sc.path or "") .. ":"
      .. vo.SerializeLayout({ mapping = sc.mapping })
      .. ":" .. (sc.enabled ~= false and "1" or "0")
  end
  for _, p in ipairs(paths) do
    local tpath = vo.TranscriptPath(p)
    parts[#parts + 1] = p .. ":" .. tostring(tpath and vo.FileSize(tpath) or 0)
  end
  -- Pins steer matching, so adding or clearing one has to invalidate the cache
  -- exactly the way a script change does.
  for _, pin in ipairs(state.pins or {}) do
    parts[#parts + 1] = string.format("pin:%s@%s:%.3f-%.3f",
      pin.asset or "", pin.source or "", pin.start or 0, pin.stop or 0)
  end
  return table.concat(parts, "|")
end

local function LoadMatches(cfg)
  local paths = vo.ProjectSourcePaths(state.items)
  local key   = MatchKey(paths, state.scripts, cfg)
  if key == state.match_key then return state.matches end

  local transcripts = {}
  for _, path in ipairs(paths) do
    local parsed = vo.ReadTranscript(path)
    if parsed then transcripts[#transcripts + 1] = { path = path, words = parsed.words } end
  end

  state.matches   = vo.BuildMatch(transcripts, state.lines or {}, cfg, state.pins)
  state.match_key = key

  -- A pin that resolves to nothing must say so. Silently doing nothing is the
  -- one behaviour that would make hand-placement untrustworthy.
  local broken = {}
  for _, entry in ipairs(state.matches) do
    for _, u in ipairs(entry.unresolved or {}) do
      broken[#broken + 1] = string.format("%s in %s (%s)",
        u.pin.asset, vo.Basename(u.pin.source), u.why)
    end
  end
  state.broken_pins = broken
  return state.matches
end

-- -----------------------------------------------------------------------
-- Assembly
-- -----------------------------------------------------------------------

local function Rebuild()
  state.items = vo.CollectProjectSpans()
  LoadScripts()
  state.lines = ScriptLines()
  -- A delivered name two script lines both claim. The clips cut fine -- two
  -- items in REAPER may share a name -- but the collision becomes real when
  -- they are rendered to files, so it is reported, and the table shows it in
  -- red until the user separates them with an Append.
  state.dupe_assets = vo.DuplicateAssets(state.lines)
  local cfg   = vo.LoadConfig()
  -- Read here rather than once at startup, so the choice follows the config
  -- like every other setting and survives a Settings change made mid-session.
  state.auto_select_take = cfg.auto_select_take or "last"

  state.overview = vo.BuildOverview({
    lines   = state.lines,
    matches = LoadMatches(cfg),
    entries = state.entries,
    cfg     = cfg,
  })
  state.summary = vo.SummarizeOverview(state.overview)

  -- Row-level, so a per-take name override can clear a clash or create one.
  state.dupe_names = vo.DuplicateNames(state.overview)

  -- The Append cell needs the text to show, and the row is what the cell has.
  local appends = vo.AppendMap(state.appends)
  for _, row in ipairs(state.overview) do
    row.append = row.append_key and appends[row.append_key] or nil
  end

  -- Resolve each row to a live item once per rebuild rather than per frame:
  -- this walks every project item per row and is far too expensive to redo at
  -- frame rate on a long session.
  for _, row in ipairs(state.overview) do
    if row.source_path and row.source_start then
      -- By SPAN, not by instant: trimming an item's head throws away the source
      -- time a take began at, and asking about that one instant answers nothing
      -- even when most of the take is still in the project. `coverage` records
      -- which answer this was, so a partial one can be shown as such and Cut
      -- can refuse it.
      local item, proj_time, _, coverage = vo.ResolveSourceSpan(
        row.source_path, row.source_start, row.source_stop, state.items)
      row.item, row.proj_time, row.coverage = item, proj_time, coverage
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

  -- Coverage: which script lines actually have an item named for them, read
  -- from the project's item names and nothing else. Recomputed here, so it can
  -- never be out of step with the project -- there is no stored copy to drift.
  local named_items = {}
  for _, info in ipairs(state.items or {}) do
    if info.item and not info.skip then
      local take = r.GetActiveTake(info.item)
      local name = ""
      if take then
        local _, got = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        name = got or ""
      end
      local track = ""
      if info.track then
        local _, tname = r.GetSetMediaTrackInfo_String(info.track, "P_NAME", "", false)
        track = tname or ""
      end
      named_items[#named_items + 1] = { name = name, track = track, item = info.item }
    end
  end
  -- Items still wearing their recording's own filename are uncut remainders,
  -- not strays; names the tool's own alt pattern wrote count as takes of
  -- their line. Without both, "names not on the script" never reads zero and
  -- the warning that matters drowns.
  local source_names = {}
  for _, info in ipairs(state.items or {}) do
    if info.path and info.path ~= "" then
      source_names[vo.NormalizeItemName(vo.Basename(info.path))] = true
    end
  end
  state.check = vo.CheckCoverage(named_items, state.lines, {
    source_names = source_names,
    alt_pattern  = cfg.alt_append_pattern,
  })

  -- Name-based fallback for the rows: an item carrying a line's delivered
  -- name IS that line's take, even when the transcript span no longer finds
  -- it -- hand-trimmed edges and renamed comps break the span lookup but not
  -- the name. Rows that resolved nothing adopt unclaimed name-matches, so
  -- the sheet shows what the names already say.
  local claimed = {}
  for _, row in ipairs(state.overview) do
    if row.item then claimed[row.item] = true end
  end
  local pool = {}
  for _, ni in ipairs(named_items) do
    if ni.item and not claimed[ni.item] then
      local stem = vo.StripAltSuffix(ni.name, cfg.alt_append_pattern) or ni.name
      local key = vo.NormalizeItemName(stem)
      if key ~= "" then
        pool[key] = pool[key] or {}
        table.insert(pool[key], ni.item)
      end
    end
  end
  local function adopt(row, item)
    row.item = item
    row.item_by_name = true
    local take = r.GetActiveTake(item)
    if take then
      local _, nm = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      row.take_name = (nm ~= "") and nm or nil
    end
  end
  for _, row in ipairs(state.overview) do
    if not row.item then
      local key = vo.NormalizeItemName(row.deliver or row.asset or "")
      local list = key ~= "" and pool[key] or nil
      if list and #list > 0 then
        adopt(row, table.remove(list, 1))
        -- A Missing line that just gained a named item is not missing: this
        -- is the rendered-file / hand-comped case, real audio with no span.
        if row.status == "missing" then row.status = "recorded" end
      end
    end
  end

  -- Whatever is STILL in the pool has more items than its line has rows --
  -- a take added by hand (comped, rendered, renamed chatter). Real audio
  -- the table must show: it gets a row of its own beside its line.
  for key, list in pairs(pool) do
    for _, extra_item in ipairs(list) do
      local at, template = nil, nil
      for i, row in ipairs(state.overview) do
        if vo.NormalizeItemName(row.deliver or row.asset or "") == key then
          at, template = i, row
        end
      end
      if template then
        local row = vo.ShallowCopy(template)
        adopt(row, extra_item)
        row.status = "recorded"
        row.source_path, row.source_start, row.source_stop = nil, nil, nil
        row.take_index = (template.take_count or 1) + 1
        row.take_count = row.take_index
        table.insert(state.overview, at + 1, row)
      end
    end
  end

  -- Out-of-band rename detection: the name IS the assignment, and anything --
  -- F2, a batch renamer, another script -- can move it silently. The baseline
  -- re-arms whenever this window renames things itself, so what is reported
  -- is only what happened OUTSIDE it.
  local names_now = {}
  for _, ni in ipairs(named_items) do
    local ok, guid = r.GetSetMediaItemInfo_String(ni.item, "GUID", "", false)
    if ok and guid ~= "" then names_now[guid] = ni.name end
  end
  if state.name_baseline then
    local drift = {}
    for guid, old in pairs(state.name_baseline) do
      local new = names_now[guid]
      if new and new ~= old then
        drift[#drift + 1] = string.format("%s -> %s", old, new)
      end
    end
    state.name_drift = drift
  else
    state.name_baseline, state.name_drift = names_now, {}
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

-- The window follows the ACTIVE project tab. Everything in `state` -- entries,
-- scripts, appends, filters, the sidecar path -- belongs to the project it was
-- loaded from, so landing on a different tab flushes what is pending to that
-- project's own file and reloads from the new tab's. A save-as is the same
-- project under a new name (same handle, new path): the state is kept and the
-- sidecar path moves with the project instead.
local function MaybeFollowProject()
  local proj, path = CurrentProject()
  if proj == state.tab_proj and path == state.tab_path then return end

  if proj == state.tab_proj then
    state.tab_path = path
    state.project_path = (path ~= "") and vo.ProjectFilePath(path) or nil
    -- Rewrite at the new location so the sidecar exists beside the new file.
    state.dirty = state.dirty or (state.project_path ~= nil)
    return
  end

  FlushProjectFile(true)
  LoadProjectFile()
  Reload()
end

-- -----------------------------------------------------------------------
-- User edits
-- -----------------------------------------------------------------------

-- Deferred so nothing mutates mid-table: a widget records what to do and the
-- frame runs it after the table is closed. Declared here, above every panel
-- and every cell that assigns to it, so they all see the same local.
local pending_action = nil

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

-- The Append belongs to the SCRIPT LINE, not to the take, so it is written to
-- state.appends rather than through EntryFor -- and every take of the line picks
-- it up on the next rebuild. Nothing about the match changes, so this does not
-- invalidate the match cache; only the delivered name moves.
local function SetAppend(row, text)
  if not row.append_key then return end
  vo.SetAppend(state.appends, row.script or "", row.asset or "",
               row.append_nth or 1, text)
  state.dirty = true
  Rebuild()
end

-- Which takes of a line are the same line's takes, for the Sel exclusivity
-- below. By SCRIPT ROW, never by filename: two CSV rows may ask for the same
-- filename -- that is what the Append column exists to separate -- and keying
-- on the name made ticking one line's Sel clear the other line's, which is a
-- different line entirely.
local function LineKeyOf(row)
  return row.script_row or ("asset:" .. tostring(row.asset))
end

-- Exactly one take of a line may be the SELECT, so ticking one clears the rest
-- of its group. Without this the project file could hold two selected rows for
-- one line and BuildOverview would silently pick whichever the build order put
-- first (see vo.BuildOverview's "no first/last fallback").
local function SetSelect(row, on)
  if on then
    local mine = LineKeyOf(row)
    for _, other in ipairs(state.overview) do
      if other ~= row and other.status ~= "orphan" and other.user_select
         and LineKeyOf(other) == mine then
        Mutate(other, function(e) e.select = nil end)
      end
    end
  end
  Mutate(row, function(e) e.select = on or nil end)
end

-- Any number of takes may be KEPT, so this has no exclusivity at all. A keep
-- is an extra delivery, not a competing answer to which take the delivery is.
local function SetKeep(row, on)
  Mutate(row, function(e) e.keep = on or nil end)
end

-- Renaming is the one edit that reaches into the project. It is recorded in
-- the project file AND applied to the take, so the delivery name survives
-- even if the item is later deleted, and one edit is one undo step.
-- The item a row plays, resolved against the live project rather than the
-- pointer cached on the row. Anything that WRITES to an item must go through
-- this: cutting destroys and recreates every item in a recording and REAPER
-- reuses the pointers, so a row rebuilt before a cut can hold one that now
-- refers to a different item -- and renaming the wrong clip is not recoverable
-- by pressing the button again.
local function LiveItemFor(row)
  if not (row.source_path and row.source_start) then return nil end
  return (vo.ResolveSourceSpan(row.source_path, row.source_start, row.source_stop,
                               vo.CollectProjectSpans()))
end

local function Rename(row, name)
  local clean = vo.SanitizeName(name)
  if clean == "" then
    state.message, state.message_kind =
      "That name has no characters a filesystem will accept.", "error"
    return
  end

  -- The take is written BEFORE the entry, because Mutate rebuilds and the
  -- rebuild reads the take's live name back into the row.
  local item = LiveItemFor(row)
  if item then
    core.Transaction("VO Overview: rename take", function()
      local take = r.GetActiveTake(item)
      if take then
        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", clean, true)
      end
    end)
    -- Transaction holds UI refresh off for its duration, so the arrange view
    -- would otherwise keep showing the old name until something else redrew it.
    r.UpdateArrange()
  end

  state.name_baseline = nil
  Mutate(row, function(e) e.name_override = clean end)
  state.message, state.message_kind = "Renamed to " .. clean .. ".", "ok"
end

-- Putting the script's own name back. The entry's override is CLEARED rather
-- than set to the asset name: an override equal to the script's name is not a
-- judgement about anything, and the project file holds only judgements.
local function ResetName(row)
  local clean = vo.SanitizeName(row.deliver or row.asset or "")
  if clean == "" then return end

  local item = LiveItemFor(row)
  if item then
    core.Transaction("VO Overview: reset take name", function()
      local take = r.GetActiveTake(item)
      if take then
        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", clean, true)
      end
    end)
    r.UpdateArrange()
  end

  state.name_baseline = nil
  Mutate(row, function(e) e.name_override = nil end)
  state.message, state.message_kind = "Reset to " .. clean .. ".", "ok"
end

-- Swap the delivery AFTER a pull: this row's take gets the line's plain
-- delivered name and the Selects track; the take that had it gets the first
-- free alt name and the Alts track. Names first -- the name IS the
-- assignment -- and the tracks follow so the timeline tells the same story.
local function MakeSelect(row)
  local base = vo.SanitizeName(row.deliver or row.asset or "")
  local item = LiveItemFor(row)
  if base == "" or not item then
    state.message, state.message_kind = "This row has no take to promote.", "error"
    return
  end
  local take = r.GetActiveTake(item)
  if not take then return end
  local _, current_name = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if current_name == base then
    state.message, state.message_kind = base .. " is already the Select.", "ok"
    return
  end

  local cfg = vo.LoadConfig()
  -- The take currently delivering under the plain name, and every alt number
  -- already taken, found in one scan.
  local old_sel, used = nil, {}
  for i = 0, r.CountMediaItems(0) - 1 do
    local other = r.GetMediaItem(0, i)
    local tk2 = r.GetActiveTake(other)
    if tk2 and other ~= item then
      local _, nm2 = r.GetSetMediaItemTakeInfo_String(tk2, "P_NAME", "", false)
      if nm2 == base then
        old_sel = other
      elseif vo.StripAltSuffix(nm2, cfg.alt_append_pattern) == base then
        local n2 = tonumber(nm2:match("(%d+)%s*$") or "")
        if n2 then used[n2] = true end
      end
    end
  end

  local function track_named(name)
    for i = 0, r.CountTracks(0) - 1 do
      local t = r.GetTrack(0, i)
      local _, nm2 = r.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
      if nm2 == name then return t end
    end
    return nil
  end
  local t_sel = track_named(cfg.track_selects or "Selects")
  local t_alt = track_named(cfg.track_alts or "Alts")

  local n = math.floor(cfg.alt_append_start or 1)
  while used[n] do n = n + 1 end
  local alt_name = vo.SanitizeName(base ..
    vo.FormatAltAppend(cfg.alt_append_pattern, n, math.floor(cfg.alt_append_digits or 1)))

  state.name_baseline = nil
  core.Transaction("VO Overview: make select", function()
    r.GetSetMediaItemTakeInfo_String(take, "P_NAME", base, true)
    if t_sel and r.GetMediaItem_Track(item) ~= t_sel then
      r.MoveMediaItemToTrack(item, t_sel)
    end
    if old_sel then
      local tk2 = r.GetActiveTake(old_sel)
      if tk2 then r.GetSetMediaItemTakeInfo_String(tk2, "P_NAME", alt_name, true) end
      if t_alt and r.GetMediaItem_Track(old_sel) ~= t_alt then
        r.MoveMediaItemToTrack(old_sel, t_alt)
      end
    end
    r.UpdateArrange()
  end)

  -- The sheet's record follows the same decision.
  for _, r2 in ipairs(state.overview) do
    if r2.line_key and r2.line_key == row.line_key and r2 ~= row then
      EntryFor(r2).select = false
    end
  end
  Mutate(row, function(e) e.select = true end)
  state.message, state.message_kind = string.format("%s is now the Select%s.",
    base, old_sel and (" -- the previous one is " .. alt_name) or ""), "ok"
end

-- Name-driven filing, the inverse of Assign: there the row names the item,
-- here the item's OWN name places it. Rename a take to what it should be --
-- plain delivered name or an alt-patterned one -- select it, press Place:
-- it lands on the right track and the sheet follows on the rebuild.
local function PlaceSelectedItems()
  local n = r.CountSelectedMediaItems(0)
  if n == 0 then
    state.message, state.message_kind = "Select the item(s) in REAPER first.", "error"
    return
  end
  local cfg = vo.LoadConfig()
  local index = vo.BuildNameIndex(state.lines or {})
  local function track_named(name)
    for i = 0, r.CountTracks(0) - 1 do
      local t = r.GetTrack(0, i)
      local _, nm2 = r.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
      if nm2 == name then return t end
    end
    return nil
  end
  local t_sel = track_named(cfg.track_selects or "Selects")
  local t_alt = track_named(cfg.track_alts or "Alts")

  local placed, skipped = 0, {}
  state.name_baseline = nil
  core.Transaction("VO Overview: place selected by name", function()
    for i = 0, n - 1 do
      local item = r.GetSelectedMediaItem(0, i)
      local tk = item and r.GetActiveTake(item)
      if tk then
        local _, nm = r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
        local stem = vo.StripAltSuffix(nm, cfg.alt_append_pattern)
        local at, why = vo.ResolveItemName(index, stem or nm)
        if at then
          local dest = stem and t_alt or t_sel
          if dest and r.GetMediaItem_Track(item) ~= dest then
            r.MoveMediaItemToTrack(item, dest)
          end
          placed = placed + 1
        else
          skipped[#skipped + 1] = string.format("%s (%s)", nm,
            why == "ambiguous" and "claimed by two lines" or "not on the script")
        end
      end
    end
    r.UpdateArrange()
  end)
  Rebuild()
  state.message, state.message_kind = string.format("Placed %d item(s) by name.%s",
    placed, (#skipped > 0)
      and (" Skipped: " .. table.concat(skipped, ", ")) or ""),
    (#skipped > 0) and "error" or "ok"
end

-- The finishing pass. Cutting places edges from the transcript's word
-- timestamps; those carry slop, and re-pulls inherit whatever the span said.
-- Tighten instead measures where the audio actually is inside each delivered
-- item and pulls loose edges in to the standard snap room. Strictly inward,
-- so it can only remove measured silence -- and anything hand-trimmed
-- (fades differ from the cut defaults) is left exactly alone.
local TIGHTEN_FLOOR_DB = -45.0
local function TightenItems()
  local cfg = vo.LoadConfig()
  local function track_named(name)
    for i = 0, r.CountTracks(0) - 1 do
      local t = r.GetTrack(0, i)
      local _, nm2 = r.GetSetMediaTrackInfo_String(t, "P_NAME", "", false)
      if nm2 == name then return t end
    end
    return nil
  end

  -- Selected items if there are any, else everything on Selects + Alts.
  local pool = {}
  if r.CountSelectedMediaItems(0) > 0 then
    for i = 0, r.CountSelectedMediaItems(0) - 1 do
      pool[#pool + 1] = r.GetSelectedMediaItem(0, i)
    end
  else
    for _, tn in ipairs({ cfg.track_selects or "Selects", cfg.track_alts or "Alts" }) do
      local tr = track_named(tn)
      if tr then
        for i = 0, r.CountTrackMediaItems(tr) - 1 do
          pool[#pool + 1] = r.GetTrackMediaItem(tr, i)
        end
      end
    end
  end

  local fade_in  = vo.Opt(cfg, "cut_fade_in")
  local fade_out = vo.Opt(cfg, "cut_fade_out")
  local measured, by_name = {}, {}
  for _, item in ipairs(pool) do
    local take = r.GetActiveTake(item)
    if take and not r.TakeIsMIDI(take) then
      local _, nm = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
      local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
      local touched =
        math.abs(r.GetMediaItemInfo_Value(item, "D_FADEINLEN") - fade_in) > 0.002
        or math.abs(r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN") - fade_out) > 0.002
      local probe, destroy = vo.MakeTakeProbe(take)
      if probe then
        local step = 0.010
        local head, tail
        for k = 0, math.floor(len / step) do
          local db = probe(pos + k * step, math.min(pos + (k + 1) * step, pos + len))
          if db and db > TIGHTEN_FLOOR_DB then head = k * step break end
        end
        for k = 0, math.floor(len / step) do
          local db = probe(math.max(pos, pos + len - (k + 1) * step), pos + len - k * step)
          if db and db > TIGHTEN_FLOOR_DB then tail = k * step break end
        end
        destroy()
        if head and tail then
          measured[#measured + 1] = {
            name = nm, head_room = head, tail_room = tail, user_touched = touched,
          }
          by_name[nm] = item
        end
      end
    end
  end

  local edits = vo.PlanTighten(measured, {
    head_room  = vo.Opt(cfg, "snap_head_room"),
    tail_room  = vo.Opt(cfg, "snap_tail_room"),
    head_slack = vo.Opt(cfg, "trim_head_slack"),
    tail_slack = vo.Opt(cfg, "trim_tail_slack"),
  })
  if #edits == 0 then
    state.message, state.message_kind =
      string.format("Measured %d item(s); every edge is already tight.", #measured), "ok"
    return
  end

  core.Transaction("VO Overview: tighten edges", function()
    for _, e in ipairs(edits) do
      local item = by_name[e.name]
      local take = item and r.GetActiveTake(item)
      if item and take then
        if e.head > 0 then
          r.SetMediaItemInfo_Value(item, "D_POSITION",
            r.GetMediaItemInfo_Value(item, "D_POSITION") + e.head)
          r.SetMediaItemInfo_Value(item, "D_LENGTH",
            r.GetMediaItemInfo_Value(item, "D_LENGTH") - e.head)
          r.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS",
            r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") + e.head)
        end
        if e.tail > 0 then
          r.SetMediaItemInfo_Value(item, "D_LENGTH",
            r.GetMediaItemInfo_Value(item, "D_LENGTH") - e.tail)
        end
      end
    end
    r.UpdateArrange()
  end)
  state.message, state.message_kind = string.format(
    "Tightened %d of %d item(s) to %dms head / %dms tail room.",
    #edits, #measured,
    math.floor(vo.Opt(cfg, "snap_head_room") * 1000 + 0.5),
    math.floor(vo.Opt(cfg, "snap_tail_room") * 1000 + 0.5)), "ok"
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

-- -----------------------------------------------------------------------
-- Find candidates
--
-- A search, not a decision. Given a script line, it shows every place in the
-- session's transcripts that line could sit -- including places the matcher
-- scored too low to consider -- with what was said either side and what
-- already occupies each one. Nothing here changes the match or is written to
-- the project file: the answer to "where did this line go?" is something you
-- confirm by listening, and the tool's job is to take you there.
-- -----------------------------------------------------------------------

local CANDIDATE_LIMIT = 12

-- One search runs a matching pass per line per source file, so a fifty-row
-- selection would lock the window up for a long time. Anything past this is
-- dropped, and said so rather than silently trimmed.
local CANDIDATE_ROW_LIMIT = 12

-- Where the row's line sits in state.lines. Orphans have no index -- they are
-- audio with no line -- and there is nothing to search for.
local function LineIndexForRow(row)
  if not row.script_row then return nil end
  for i, line in ipairs(state.lines or {}) do
    -- Matched on the merged index, not the CSV row: with two scripts loaded the
    -- row number alone would answer with whichever script happened to be first.
    if (line.index or line.row) == row.script_row then return i end
  end
  return nil
end

-- What the current match has put in this stretch of this source, if anything.
local function OccupantAt(source_path, from, to)
  for _, row in ipairs(state.overview) do
    if row.source_path == source_path and row.source_start and row.source_stop
       and from < row.source_stop and row.source_start < to then
      return row
    end
  end
  return nil
end

local function RunCandidateSearch(rows)
  local cfg = vo.LoadConfig()

  -- Read the transcripts fresh. This is a once-per-click action, so there is
  -- nothing to gain from caching them and a stale result would be worse than
  -- useless in a window whose whole purpose is to tell you where audio is.
  local sources = {}
  for _, path in ipairs(vo.ProjectSourcePaths(state.items)) do
    local parsed = vo.ReadTranscript(path)
    if parsed then
      sources[#sources + 1] = {
        path   = path,
        words  = parsed.words,
        tokens = vo.BuildWordTokens(parsed.words, cfg),
      }
    end
  end

  local groups = {}
  local dropped = 0
  for n, row in ipairs(rows) do
    if n > CANDIDATE_ROW_LIMIT then
      dropped = #rows - CANDIDATE_ROW_LIMIT
      break
    end
    local line_idx = LineIndexForRow(row)
    local group = {
      row       = row,
      asset     = row.asset or "(no filename)",
      line_text = row.line_text or "",
      hits      = {},
      why       = nil,
    }
    if not line_idx then
      group.why = "This row has no script line to search for."
    elseif #sources == 0 then
      group.why = "No transcripts. Transcribe the recordings in ajsfx VO Sources first."
    else
      for _, src in ipairs(sources) do
        local hits = vo.FindLineCandidates(state.lines, line_idx, src.tokens, cfg,
          { words = src.words, limit = CANDIDATE_LIMIT })
        for _, h in ipairs(hits) do
          local item, proj_from, info = vo.ResolveSourceTime(src.path, h.start, state.items)
          local _, proj_to = vo.ResolveSourceTime(src.path, h.stop, state.items)
          h.source_path = src.path
          h.item        = item
          h.proj_from   = proj_from
          h.proj_to     = proj_to or (proj_from and info
                            and vo.SourceTimeToProject(h.stop, info)) or nil
          h.occupant    = OccupantAt(src.path, h.start, h.stop)
          group.hits[#group.hits + 1] = h
        end
      end
      table.sort(group.hits, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return (a.proj_from or math.huge) < (b.proj_from or math.huge)
      end)
      while #group.hits > CANDIDATE_LIMIT do table.remove(group.hits) end
      if #group.hits == 0 then
        group.why = "Nothing in any transcript resembles this line."
      end
    end
    groups[#groups + 1] = group
  end

  state.candidates      = groups
  state.candidates_open = true
  if dropped > 0 then
    state.message, state.message_kind = string.format(
      "Searched the first %d lines; %d more were not searched. Select fewer.",
      CANDIDATE_ROW_LIMIT, dropped), "error"
  end
end

-- -----------------------------------------------------------------------
-- Locks: takes placed by hand
--
-- Everything else in the project file records a decision ABOUT the match --
-- a note, a rename. A lock is different: it is an INPUT to matching, a person
-- saying "this stretch of this recording is this take", which identification
-- then has to work around.
--
-- One concept, three gestures, and they differ only in where the range comes
-- from: the Lock box takes the placement the row already has, Find candidates
-- takes the placement you picked, and "Lock to time selection" takes the one
-- you found by ear. Confirming a take and correcting one are the same
-- assertion, so they are the same record.
--
-- A lock belongs to one TAKE, found by where it is rather than only by which
-- line it belongs to, so two takes of a line can be locked independently and
-- neither says anything about the other.
-- -----------------------------------------------------------------------

local function LockAt(asset, source, from)
  for i, p in ipairs(state.pins) do
    if p.asset == asset and p.source == source
       and math.abs((p.start or 0) - (from or 0)) < 1e-6 then
      return p, i
    end
  end
  return nil
end

local function LockOnRow(row)
  if not (row.asset and row.source_path and row.source_start) then return nil end
  return LockAt(row.asset, row.source_path, row.source_start)
end

-- Ticking the box freezes the take where it already is.
--
-- No Reload here, deliberately. The lock records the placement the match just
-- produced, so re-running would change nothing on screen, and a rematch on
-- every tick would make the column unusable for the fifty rows in a row you
-- actually tick it on.
local function SetLock(row, on)
  SetStatus(row, on and "verified" or nil)

  local _, at = LockOnRow(row)
  if not on then
    if at then table.remove(state.pins, at) end
  elseif row.asset and row.asset ~= "" and row.source_path
         and row.source_start and row.source_stop then
    local pin = { asset = row.asset, source = row.source_path,
                  start = row.source_start, stop = row.source_stop }
    if at then state.pins[at] = pin else state.pins[#state.pins + 1] = pin end
  end
  state.dirty = true
end

-- Lock a take to a range it is NOT currently at: the correcting gesture. The
-- row moves, so its old lock (if any) goes with it, and the row that lands on
-- the new range is the one that gets ticked.
local function LockHere(row, source, from, to)
  if not row.asset or row.asset == "" then
    state.message, state.message_kind =
      "This row has no script filename, so there is nothing to lock.", "error"
    return
  end

  local _, at = LockOnRow(row)
  if at then table.remove(state.pins, at) end
  local _, existing = LockAt(row.asset, source, from)
  local pin = { asset = row.asset, source = source, start = from, stop = to }
  if existing then state.pins[existing] = pin
  else state.pins[#state.pins + 1] = pin end

  -- Locks steer matching, so the memoised match has to be thrown away rather
  -- than waited out.
  state.match_key = nil
  state.dirty     = true
  Reload()

  -- Tick the row that now sits there, so the box agrees with the file.
  for _, other in ipairs(state.overview) do
    if other.asset == row.asset and other.source_path == source
       and other.source_start and math.abs(other.source_start - from) < 1e-6 then
      SetStatus(other, "verified")
      break
    end
  end

  state.message, state.message_kind = string.format(
    "Locked %s to %s \226\128\147 %s in %s.",
    row.asset, FormatTime(from), FormatTime(to), vo.Basename(source)), "ok"
end

-- REAPER's time selection, converted back to a position in the recording. The
-- selection is in project time and a pin has to survive the item being moved,
-- trimmed or copied into another session, so it is stored against the SOURCE.
local function TimeSelectionAsSource()
  local from, to = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  if not from or to <= from then
    return nil, "Make a time selection over the audio first."
  end
  for _, info in ipairs(state.items or {}) do
    if info.path and not info.skip then
      local i0 = info.pos
      local i1 = info.pos + info.length
      -- Any overlap counts, and the pin is clipped to the item: dragging the
      -- selection a little wide is normal and should not be an error.
      if from < i1 and i0 < to then
        local a = vo.ProjectTimeToSource(math.max(from, i0), info)
        local b = vo.ProjectTimeToSource(math.min(to, i1), info)
        if b > a then return { source = info.path, start = a, stop = b } end
      end
    end
  end
  return nil, "The time selection does not overlap any recording in this project."
end

-- Put the candidate on screen and under the play cursor. A time selection
-- rather than just a cursor move, so the stretch itself is visible against
-- what surrounds it -- which is the whole point of looking.
local function ShowCandidate(hit)
  if not hit.proj_from then
    state.message, state.message_kind =
      "That stretch of the recording is not in this project's timeline.", "error"
    return
  end
  local to = hit.proj_to or (hit.proj_from + 0.5)
  r.Main_OnCommand(40289, 0)                       -- unselect all items
  if hit.item then r.SetMediaItemSelected(hit.item, true) end
  r.GetSet_LoopTimeRange(true, false, hit.proj_from, to, false)
  r.SetEditCurPos(hit.proj_from, true, true)       -- move and seek playback
  r.UpdateArrange()
end

-- The project selection as a cheap signature, so a frame can ask "did it
-- change since I last looked" without walking every item.
local function TimelineSelSignature()
  local n = r.CountSelectedMediaItems(0)
  local parts = { tostring(n) }
  for i = 0, math.min(n, 8) - 1 do
    parts[#parts + 1] = tostring(r.GetSelectedMediaItem(0, i))
  end
  return table.concat(parts, "|")
end

-- Timeline -> table, the reverse of ClickRow. During a listening pass the
-- user drives from the ARRANGE view -- click a take, play it -- and without
-- this the table sits wherever it was, so they are hearing a line with no
-- idea which script row it is. When the project selection changes on its own,
-- the rows whose items are selected light up and the first scrolls into view.
--
-- The edit cursor is deliberately NOT moved: the user is already where they
-- want to be, and seeking under their playback is the tool fighting them.
-- Table-driven clicks do not bounce back through here: SyncProjectSelection
-- refreshes the signature after it writes the project selection.
local function FollowTimelineSelection()
  local sig = TimelineSelSignature()
  if sig == state.timeline_sig then return end
  state.timeline_sig = sig

  local n = r.CountSelectedMediaItems(0)
  local selected = {}
  for i = 0, n - 1 do selected[r.GetSelectedMediaItem(0, i)] = true end

  -- The MIRROR, not a hint: the table's selection becomes exactly the rows of
  -- the selected items -- and deselecting everything in the arrange view
  -- deselects here too. Rows resolve their items on rebuild; a pointer gone
  -- stale simply misses, which under-selects rather than lighting a wrong row.
  local found, first = {}, nil
  for _, row in ipairs(state.visible or {}) do
    if row.item and selected[row.item] then
      found[row.uid] = true
      first = first or row.uid
    end
  end

  state.selection = found
  if first then
    state.focus_key  = first
    state.anchor_key = first
    state.scroll_to_uid = first
  end
end

-- Push the row selection out to the project. The edit cursor follows the FOCUS
-- row only: seeking once per gesture rather than once per selected row keeps a
-- fifty-row shift-click from thrashing the transport.
-- Selecting rows drives REAPER's own item selection and the edit cursor.
--
-- Items are resolved HERE, against a fresh walk of the project, rather than
-- trusting the pointers cached on the rows. Cutting destroys and recreates
-- every item in a recording, and REAPER reuses those pointers -- a row rebuilt
-- before the cut can hold one that now refers to a different item entirely.
-- Rebuilds are throttled, so whether a click landed on the right item depended
-- on when the last rebuild happened, which is as random as it looked.
--
-- One project walk per click is affordable; this runs on a click, not a frame.
local function SyncProjectSelection()
  local items = vo.CollectProjectSpans()

  local function resolve(row)
    if not (row.source_path and row.source_start) then return nil end
    return vo.ResolveSourceSpan(row.source_path, row.source_start, row.source_stop, items)
  end

  r.Main_OnCommand(40289, 0)                       -- unselect all items
  local seen = {}
  for _, row in ipairs(SelectedRows()) do
    local item = resolve(row)
    if item and not seen[item] then
      seen[item] = true
      r.SetMediaItemSelected(item, true)
    end
  end

  -- The cursor goes to the first WORD of the take, not to the item's edge:
  -- source_start is the transcript's start for this span, and the padding a cut
  -- applies is never part of it.
  for _, row in ipairs(state.visible) do
    if row.uid == state.focus_key then
      local _, proj = resolve(row)
      if proj then r.SetEditCurPos(proj, true, true) end   -- move and seek playback
      break
    end
  end
  r.UpdateArrange()

  -- This write IS the new project selection; refreshing the signature here is
  -- what keeps FollowTimelineSelection from reading it back as the user's.
  state.timeline_sig = TimelineSelSignature()
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
  if state.character and (row.character or "") ~= state.character then return false end

  if state.search ~= "" then
    local needle = state.search:lower()
    local hay = ((row.asset or "") .. " " .. (row.line_text or "") .. " "
              .. (row.transcript or "") .. " " .. (row.notes or "")):lower()
    if not hay:find(needle, 1, true) then return false end
  end

  -- Column filters AND with each other and with everything above: each box
  -- narrows what the ones before it left.
  for key, needle in pairs(state.col_filters) do
    if needle ~= "" then
      local col = COLUMN_BY_KEY[key]
      if col and col.text
         and not col.text(row):lower():find(needle:lower(), 1, true) then
        return false
      end
    end
  end
  return true
end

local function AnyColumnFilter()
  for _, needle in pairs(state.col_filters) do
    if needle ~= "" then return true end
  end
  return false
end

-- nil and "" both mean "this row has no value in this column".
local function Absent(v) return v == nil or v == "" end

-- A character filter restored from the project file names a character the rows
-- had when the file was written. If the script has since changed, or its
-- Character column is no longer mapped, that name is now in nothing -- and an
-- empty table with a name in the combo reads as "the match found nothing"
-- rather than "you are filtering by someone who is not here". So it is dropped,
-- once, as soon as there are rows to check it against.
local function CheckRestoredCharacter()
  if not state.check_character then return end
  if #state.overview == 0 then return end   -- nothing to check against yet
  state.check_character = false
  for _, row in ipairs(state.overview) do
    if row.character == state.character then return end
  end
  state.character = nil
end

local function ApplyFilters()
  CheckRestoredCharacter()
  local out = {}
  for i, row in ipairs(state.overview) do
    row.order = i     -- script position: the # column, and every sort's tiebreak
    if Matches(row) then out[#out + 1] = row end
  end

  local col = state.sort_col and COLUMN_BY_KEY[state.sort_col]
  if col then
    local desc = state.sort_desc
    local key = col.num or function(row) return col.text(row):lower() end
    table.sort(out, function(a, b)
      local ka, kb = key(a), key(b)
      local ma, mb = Absent(ka), Absent(kb)
      -- Valueless rows sink to the bottom in both directions.
      if ma ~= mb then return mb end
      if not ma and ka ~= kb then
        if desc then return kb < ka end
        return ka < kb
      end
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
-- This moves ITEMS, never spans, and never cuts: cutting is the Cut window's
-- job (SPEC-overview.md section 1). An item holding several lines is positioned by
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

-- Throw the memoised match away and identify everything again. The ordinary
-- rebuild is memoised on the script, the transcripts and the settings, which is
-- exactly right for a window that redraws thirty times a second and exactly
-- wrong for a button whose whole job is to say "do it again".
local function Rematch()
  state.match_key = nil
  Reload()
  local locked = #state.pins
  state.message, state.message_kind = string.format(
    "Identified %d line%s again%s.", #state.overview, #state.overview == 1 and "" or "s",
    locked > 0 and string.format(", leaving %d locked line%s alone",
                                 locked, locked == 1 and "" or "s") or ""), "ok"
end

-- Mark one take of every line as the select. Which one is the user's standing
-- choice, not a guess: a session read in takes usually settles on the last, but
-- an actor who leads with their best does the opposite.
local function AutoSelectTakes(rows)
  -- A locked line has been settled by hand; a bulk action does not get to
  -- overrule that.
  local locked_line = {}
  for _, row in ipairs(state.overview) do
    if row.user_status == "verified" and row.asset then locked_line[row.asset] = true end
  end

  local want = (state.auto_select_take == "first") and 1 or nil
  local best, changed = {}, 0
  for _, row in ipairs(rows) do
    if row.asset and row.status ~= "missing" and row.status ~= "orphan"
       and (row.take_index or 0) > 0 and not locked_line[row.asset] then
      local pick = want or (row.take_count or 1)
      if row.take_index == pick then best[row.asset] = row end
    end
  end
  for _, row in pairs(best) do
    -- An alt is not an answer to "which take is the delivery", so a line whose
    -- only mark is an alt still has one to make and this fills it in.
    if not row.user_select then
      SetSelect(row, true)
      changed = changed + 1
    end
  end

  local n = 0
  for _ in pairs(best) do n = n + 1 end
  state.message, state.message_kind = string.format(
    "%s take marked as the select on %d line%s (%d changed)%s.",
    state.auto_select_take == "first" and "First" or "Last",
    n, n == 1 and "" or "s", changed,
    next(locked_line) and ", locked lines skipped" or ""), "ok"
end

-- "This item is that line", stated rather than derived.
--
-- The item's NAME is the assignment -- it is what Pull, Sort and the Got column
-- all read -- so saying so is renaming, and nothing needs to be stored, pinned
-- or kept in sync. It acts on REAPER's own item selection because that is what
-- you already have in your hand after cutting or comping something.
--
-- Several items at once become the line and its alts, numbered with the same
-- pattern the Pull panel uses, so comping four takes of a line and assigning
-- them in one go gives line_042, line_042_alt1, line_042_alt2, line_042_alt3.
local function AssignSelectedItems(row, base_name)
  local n = r.CountSelectedMediaItems(0)
  if n == 0 or not base_name or base_name == "" then return end
  state.name_baseline = nil

  local cfg = vo.LoadConfig()
  local named = 0
  core.Transaction("VO Overview: assign items to line", function()
    for i = 0, n - 1 do
      local item = r.GetSelectedMediaItem(0, i)
      local take = item and r.GetActiveTake(item)
      if take then
        local name = base_name
        if i > 0 then
          name = base_name .. vo.FormatAltAppend(
            cfg.alt_append_pattern,
            math.floor(cfg.alt_append_start or 1) + (i - 1),
            math.floor(cfg.alt_append_digits or 1))
        end
        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", vo.SanitizeName(name), true)
        named = named + 1
      end
    end
  end)
  r.UpdateArrange()

  state.message, state.message_kind = string.format(
    "Named %d item%s for %s.%s", named, named == 1 and "" or "s", base_name,
    named > 1 and " The first is the line; the rest are its alts." or ""), "ok"
  Reload()
end

-- The rows a tool acts on: every row currently visible, unless the user has
-- explicitly asked for the selection.
--
-- Selection is NOT the scope by default, and that is deliberate. Clicking a row
-- is how you audition a take -- it moves the cursor and selects the item -- so
-- by the time you reach for a button there is almost always exactly one row
-- selected, and a tool that quietly narrowed to it would do a fraction of what
-- its label says. The filters are the real scoping tool here; the tick boxes
-- are how you mark individual takes.
local function AffectedRows()
  if state.selection_only then
    local sel = SelectedRows()
    if #sel > 0 then return sel, true end
  end
  return state.visible, false
end

-- The items Pull and Sort may act on, in timeline order, each carrying the name
-- REAPER has for it right now.
--
-- Deliberately NOT the table's rows. A row exists only where the match put a
-- span, so a project of rendered files with no transcripts has no rows at all
-- -- and that is precisely the case these two tools exist to serve. They walk
-- the project's items and let name resolution decide which are theirs; an item
-- the script does not name is skipped, which is also what keeps them off audio
-- they were not asked to touch.
--
-- Scope, narrowest first: the items selected in REAPER, else the items behind
-- the selected rows, else every item in the project.
local function TargetItems()
  -- REAPER's own item selection is NOT consulted: clicking a row to audition
  -- it selects that row's item, so using it as the scope would silently narrow
  -- every run to the last take listened to.
  local chosen, scope = {}, "every item in the project"
  if state.selection_only then
    for _, row in ipairs(SelectedRows()) do
      if row.item then chosen[row.item] = true end
    end
    if next(chosen) then scope = "the items behind the selected rows" end
  end
  local everything = next(chosen) == nil

  -- Marks, characters and per-take names come from the row where one exists.
  -- An item with no row has none of them, which is exactly what a delivered
  -- file looks like. Where several rows share an item, the one carrying SEL
  -- speaks for it.
  local by_item = {}
  for _, row in ipairs(state.overview) do
    if row.item then
      local cur = by_item[row.item]
      if not cur or (row.user_select and not cur.user_select) then
        by_item[row.item] = row
      end
    end
  end

  local items, marks = {}, {}
  for _, info in ipairs(state.items or {}) do
    local item = info.item
    if item and not info.skip and (everything or chosen[item]) then
      local take = r.GetActiveTake(item)
      local name = ""
      if take then
        local _, got = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
        name = got or ""
      end
      local row = by_item[item]
      items[#items + 1] = {
        id        = item,
        name      = name,
        pos       = info.pos or 0,
        character = row and row.character or nil,
        override  = row and row.name_override or nil,
      }
      -- Sel wins over Keep: a take that is both is the delivery, and the keep
      -- is then just saying the obvious.
      if row then
        if row.user_select then marks[item] = "select"
        elseif row.user_keep then marks[item] = "keep" end
      end
    end
  end
  table.sort(items, function(a, b) return a.pos < b.pos end)
  return items, marks, scope
end

-- Clusters worth moving, each tagged with the sort key of its earliest member.
-- Returns the clusters, the number skipped for being locked, and the number
-- left out because their name is not on the script.
local function BuildSortClusters()
  local keys, wanted, unresolved = {}, {}, 0

  if state.layout_order == "script" then
    -- Script order is a question about the SCRIPT, so it is answered by the
    -- name the item CARRIES, from the project's ITEMS rather than the table's
    -- rows -- a project of rendered files has no rows at all. One resolution
    -- per item, so an uncut recording holding forty lines is one skip and not
    -- forty, and so a single item can never end up keyed two different ways.
    local index = vo.BuildNameIndex(state.lines)
    for _, it in ipairs((TargetItems())) do
      local at = vo.ResolveItemName(index, it.name)
      if at then
        wanted[it.id] = true
        keys[it.id] = { script_row = at, source_start = it.pos, orphan = false }
      else
        unresolved = unresolved + 1
      end
    end
  else
    -- Record order asks where an item sat inside a recording, which a name
    -- cannot answer, so it reads the rows the match produced. One key per ITEM,
    -- taken from its earliest recognised line: an uncut item holding five lines
    -- is a single thing you can drag, so the first line in it decides where the
    -- whole thing goes.
    for _, row in ipairs(AffectedRows()) do
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

  return chosen, locked, unresolved
end

local function FormatSpan(seconds)
  seconds = math.max(0, math.floor((seconds or 0) + 0.5))
  return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

local function SortOnTimeline()
  Reload()
  local clusters, locked, unresolved = BuildSortClusters()
  if #clusters == 0 then
    state.message, state.message_kind =
      (locked > 0)
        and "Every item in range is locked; nothing was moved."
        or  (unresolved > 0)
        and string.format(
              "Nothing to lay out: %d item(s) carry a name that is not on the script. " ..
              "Cut and Name them first, or switch to record order.", unresolved)
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

-- Keyboard nav off. With it on ImGui claims the keyboard whenever this window
-- has focus and activates whatever the nav cursor sits on when Space is
-- pressed -- so Space ticked a checkbox instead of starting the transport, in
-- the one window you sit in while listening. Text fields are unaffected: they
-- capture the keyboard while they are being edited, and only then.
local function NewContext()
  local c = im.CreateContext('VO Overview')
  local var, flag = Api('ConfigVar_Flags'), Api('ConfigFlags_NavEnableKeyboard')
  if var and flag then
    im.SetConfigVar(c, var, im.GetConfigVar(c, var) & ~flag)
  end
  return c
end

local ctx = NewContext()

-- The "only the selected rows" switch each panel offers, drawn identically in
-- all of them so the scope rule reads the same wherever it applies.
--
-- Defined HERE, below the context, not up with AffectedRows where it logically
-- belongs: everything above this line runs before `ctx` exists, so a drawing
-- helper placed there would pass a nil context to ImGui and take the frame
-- down with it -- which is exactly what it did.
local function DrawScopeToggle(id)
  local changed, on = im.Checkbox(ctx, "Selected rows only##" .. id, state.selection_only)
  if changed then state.selection_only = on end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, string.format(
      "Off: act on every row the filters are showing (%d).\n" ..
      "On: act on the rows selected in the table (%d).\n\n" ..
      "Off by default because clicking a row to listen to it also selects it.",
      #state.visible, #SelectedRows()))
  end
end

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

-- Which column of the script is which. Nothing matches until Filename and Line
-- Text are known, so this is the one panel a new project cannot skip -- the
-- auto-detection covers the usual header names and no more.
--
-- Roles are the library's: `asset` is the delivered filename, `text` the line,
-- `speaker` the character. Only speaker is optional.
local MAP_ROLES = {
  { role = "asset",   label = "Filename",  optional = false,
    hint = "The name the delivered clip must take." },
  { role = "text",    label = "Line text", optional = false,
    hint = "What the actor says. This is what the transcript is matched against." },
  { role = "speaker", label = "Character", optional = true,
    hint = "Optional. Splits the delivery onto per-character tracks." },
}

-- Adds one CSV to the list. Answers false when the path is already there, so
-- the caller can name every file it skipped in one message rather than one per
-- file. Does not reload: a multi-file add reloads once, at the end.
local function AddScript(path)
  for _, sc in ipairs(state.scripts) do
    if sc.path == path then return false end
  end
  state.scripts[#state.scripts + 1] = { path = path, mapping = {}, enabled = true }
  return true
end

-- Asks for one or more CSVs. js_ReaScriptAPI's browser is the only one REAPER
-- offers that can return a multiple selection; without the extension installed
-- this falls back to the stock single-file dialog rather than refusing to add
-- anything.
local function BrowseForScripts(dir)
  local chosen = {}
  if r.APIExists and r.APIExists("JS_Dialog_BrowseForOpenFiles") then
    local rv, names = r.JS_Dialog_BrowseForOpenFiles(
      "Add script CSVs", dir or "", "", "CSV files (*.csv)\0*.csv\0All files (*.*)\0*.*\0", true)
    if rv and rv > 0 and names and names ~= "" then
      -- One file comes back as a whole path; several come back as the folder
      -- followed by bare filenames, all separated by NULs.
      local parts = {}
      for part in names:gmatch("[^%z]+") do parts[#parts + 1] = part end
      if #parts == 1 then
        chosen[1] = parts[1]
      else
        local folder = parts[1]:gsub("[\\/]$", "")
        local sep = folder:find("\\") and "\\" or "/"
        for i = 2, #parts do chosen[#chosen + 1] = folder .. sep .. parts[i] end
      end
    end
  else
    local start_at = dir and (dir .. "*.csv") or ""
    local ok, path = r.GetUserFileNameForRead(start_at, "Add a script CSV", "csv")
    if ok then chosen[1] = path end
  end
  return chosen
end

-- The Script panel: every CSV this project reads, with its own column mapping
-- and its own on/off switch. Drawn inline above the table, like the mapping
-- panel it replaces.
local function DrawScriptPanel()
  im.Separator(ctx)
  im.Text(ctx, "Scripts")
  im.SameLine(ctx)
  if im.Button(ctx, "Add script…") then
    -- With no script yet, start in the project's own folder rather than
    -- wherever REAPER defaults to (its resource path).
    local dir = ProjectPath():match("^(.*[\\/])")
    local added, skipped = 0, {}
    for _, path in ipairs(BrowseForScripts(dir)) do
      if AddScript(path) then added = added + 1
      else skipped[#skipped + 1] = vo.Basename(path) end
    end
    if #skipped > 0 then
      state.message, state.message_kind =
        table.concat(skipped, ", ") .. (#skipped == 1 and " is" or " are") ..
        " already in the list.", "error"
    end
    if added > 0 then
      state.dirty = true
      Reload()
    end
  end
  im.SameLine(ctx)
  if im.Button(ctx, "Close##scripts") then state.panel = nil end

  -- Every row lines its widgets up on the same columns, whatever the filenames
  -- are: the name column is as wide as the longest name in the list, so adding
  -- a second script cannot shift the first one's combos sideways.
  local sx = im.GetStyleVar(ctx, im.StyleVar_ItemSpacing)
  local name_w = 0
  for _, sc in ipairs(state.loaded.scripts or {}) do
    local w = im.CalcTextSize(ctx, vo.Basename(sc.path or ""))
    if w > name_w then name_w = w end
  end
  local MAP_W  = 140
  local frame  = im.GetFrameHeight(ctx)
  -- The two arrows lead every row, so the name and everything right of it start
  -- at a fixed offset whether or not a given row can move.
  local box_x  = (frame + sx) * 2
  local map_x  = box_x + frame + sx + name_w + sx * 2
  local COL_X  = {}
  for k = 1, #MAP_ROLES do COL_X[k] = map_x + (k - 1) * (MAP_W + sx) end
  local remove_x = map_x + #MAP_ROLES * (MAP_W + sx)

  local n = #(state.loaded.scripts or {})
  local remove_at, move_from, move_to = nil, nil, nil
  for i, sc in ipairs(state.loaded.scripts or {}) do
    local persisted = state.scripts[i]
    im.PushID(ctx, "script_" .. i)

    -- Order is meaning, not decoration: lines are merged script-then-row, so
    -- this list is the answer to "which script's line 1 comes first" for the #
    -- column, for sorting, and for anything downstream that walks lines in
    -- order. See vo.LoadScripts.
    if i == 1 then im.BeginDisabled(ctx, true) end
    if im.ArrowButton(ctx, "up", im.Dir_Up) then move_from, move_to = i, i - 1 end
    if i == 1 then im.EndDisabled(ctx) end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Moves the script up the list. The list is the line order:\n" ..
                         "every line of the first script comes before every line\n" ..
                         "of the second.")
    end

    im.SameLine(ctx)
    if i == n then im.BeginDisabled(ctx, true) end
    if im.ArrowButton(ctx, "down", im.Dir_Down) then move_from, move_to = i, i + 1 end
    if i == n then im.EndDisabled(ctx) end
    if im.IsItemHovered(ctx) then im.SetTooltip(ctx, "Moves the script down the list.") end

    im.SameLine(ctx, box_x)
    local changed, on = im.Checkbox(ctx, "##on", persisted.enabled ~= false)
    if changed then
      persisted.enabled = on
      state.dirty = true
      Reload()
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "A script that is off stays in the list but contributes\n" ..
                         "no lines and takes no part in matching.")
    end

    im.SameLine(ctx)
    im.Text(ctx, vo.Basename(sc.path or ""))
    if im.IsItemHovered(ctx) then im.SetTooltip(ctx, sc.path or "") end

    if sc.header then
      for k, spec in ipairs(MAP_ROLES) do
        im.SameLine(ctx, COL_X[k])
        local mapped  = persisted.mapping[spec.role]
        local preview = mapped or (spec.optional and "(none)" or "Column…")
        im.SetNextItemWidth(ctx, MAP_W)
        if im.BeginCombo(ctx, "##map_" .. spec.role, preview) then
          -- A change of mapping changes what every row means, so it re-derives
          -- the match rather than editing rows in place. The match cache keys on
          -- the mapping, so Reload is enough -- see MatchKey. Called directly,
          -- not deferred: this panel draws above the table, not inside it.
          if spec.optional and im.Selectable(ctx, "(none)", mapped == nil)
             and mapped ~= nil then
            persisted.mapping[spec.role] = nil
            state.dirty = true
            Reload()
          end
          for _, h in ipairs(sc.header) do
            if im.Selectable(ctx, h, h == mapped) and h ~= mapped then
              persisted.mapping[spec.role] = h
              state.dirty = true
              Reload()
            end
          end
          im.EndCombo(ctx)
        end
        if im.IsItemHovered(ctx) then
          im.SetTooltip(ctx, spec.label .. ": " .. spec.hint)
        end
      end
    end

    im.SameLine(ctx, remove_x)
    if im.Button(ctx, "Remove") then remove_at = i end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Takes the script out of the list.\n" ..
                         "Anything typed in its Append column is kept.")
    end

    if sc.error and sc.error ~= "" then
      im.TextColored(ctx, 0xDD6666FF, "    " .. sc.error)
    elseif sc.enabled then
      im.TextDisabled(ctx, string.format("    %d script line%s.",
        #sc.lines, #sc.lines == 1 and "" or "s"))
    end

    im.PopID(ctx)
  end

  if #(state.loaded.scripts or {}) == 0 then
    im.TextDisabled(ctx, "No scripts yet. Press Add script… to choose one.")
  end

  -- Removed and reordered after the loop: mutating the list mid-draw would
  -- shift every index under the widgets still to be drawn.
  if remove_at then
    table.remove(state.scripts, remove_at)
    state.dirty = true
    Reload()
  elseif move_from then
    local moved = table.remove(state.scripts, move_from)
    table.insert(state.scripts, move_to, moved)
    state.dirty = true
    -- The order decides which script's lines come first, so the whole view is
    -- derived again; the match itself keys on the lines, not their position.
    Reload()
  end

  im.Separator(ctx)
end

-- -----------------------------------------------------------------------
-- Cut and Name
--
-- Splits each take out of its recording and names it the script's own
-- filename. It moves nothing: where a take goes is Pull's question, and Pull
-- answers it from the name written here. That is what lets Pull serve a folder
-- of rendered files this window never cut.
-- -----------------------------------------------------------------------

-- There is NO gate on cutting.
--
-- The old one refused to run until every line with several takes had a SEL,
-- which made sense when cutting also routed clips onto Selects and Alts: the
-- run committed to a delivery, so it needed the delivery decided. Cutting now
-- only splits and names, and slicing the recording is the FIRST step of the
-- job -- it has to happen before there is anything to decide about. So it cuts
-- what it can and reports what it could not, rather than refusing the lot
-- because two lines are still undecided.
--
-- The one thing it still will not do is cut to word timings the audio no
-- longer matches. That is skipped per SOURCE, so one re-recorded file cannot
-- stop the others. Reading it is expensive -- a transcript parse and a file
-- fingerprint each -- so it happens on the press, never per frame.
local function StaleSources()
  local stale, names = {}, {}
  for _, path in ipairs(vo.ProjectSourcePaths(state.items) or {}) do
    if vo.TranscriptState(path) == "stale" then
      stale[path] = true
      names[#names + 1] = vo.Basename(path)
    end
  end
  table.sort(names)
  return stale, names
end

-- What a cut would act on. Shared by the run and by the panel's count line, so
-- the number shown and the number cut cannot drift apart -- and so a run that
-- does nothing can be traced to the stage that emptied it.
--
-- Returns the spans to cut, every span, the stale source names, and a table of
-- stage counts for the panel.
local function CutCandidates()
  local stale_paths, stale_names = StaleSources()

  -- Every span from every source, tagged with the path it came from.
  --
  -- in_range is CLEARED here, not just set below: the match is memoised, so
  -- these are the same span tables the last run marked. Cutting a selection and
  -- then cutting again with nothing selected would otherwise cut the union of
  -- the two.
  local all_spans = {}
  for _, m in ipairs(state.matches or {}) do
    for _, s in ipairs(m.spans or {}) do
      s.source_path = m.path
      s.in_range    = nil
      all_spans[#all_spans + 1] = s
    end
  end

  -- The row carries the user's mark; the span is what gets cut. The flag makes
  -- the crossing here, once, before naming.
  --
  -- Rows are indexed by source and start rather than searched per span: with a
  -- thousand rows and a thousand spans the nested loop is a million string
  -- comparisons on every count, which is not something a panel can do.
  local by_start = {}
  local function start_key(path, start)
    return tostring(path) .. "|" .. string.format("%.4f", start or 0)
  end
  for _, row in ipairs(state.overview) do
    if row.source_path and row.source_start ~= nil then
      by_start[start_key(row.source_path, row.source_start)] = row
    end
  end

  local in_range = {}
  for _, row in ipairs(AffectedRows()) do
    if row.source_path and row.source_start ~= nil then
      in_range[start_key(row.source_path, row.source_start)] = true
    end
  end

  -- EVERYTHING the match identified is cut. Not just the SEL, and not only
  -- decided lines: slicing the recording is the first step of the job, and it
  -- has to happen before there is anything to decide about. Cutting commits to
  -- nothing -- it splits and names, and Pull is where a take's fate is settled.
  --
  -- Which rows are in range follows the same rule as every other tool here:
  -- the selected rows if any are selected, otherwise every row on show. So a
  -- filtered table cuts what it is showing, and an untouched one cuts the lot.
  local counts = { spans = #all_spans, cuttable = 0, in_range = 0, stale = 0 }
  local candidates = {}
  for _, s in ipairs(all_spans) do
    local key = start_key(s.source_path, s.start)
    local row = by_start[key]
    if row then s.select = row.user_select == true end

    if s.kind == "match" or s.kind == "review" then
      counts.cuttable = counts.cuttable + 1
      if in_range[key] then
        counts.in_range = counts.in_range + 1
        -- Cutting to word timings the audio no longer matches would put the
        -- edges in the wrong places, so a stale source is skipped -- per
        -- source, so one re-recorded file cannot stop the others.
        if stale_paths[s.source_path] then
          counts.stale = counts.stale + 1
        else
          s.in_range = true
          candidates[#candidates + 1] = s
        end
      end
    end
  end
  counts.candidates = #candidates

  return candidates, all_spans, stale_names, counts
end

local function DoCut()
  -- A fresh look first: the per-frame rescan is throttled, and cutting
  -- against items collected seconds ago is how stale pointers get split.
  Reload()
  state.name_baseline = nil
  local cfg = vo.LoadConfig()
  local candidates, all_spans, stale_names = CutCandidates()

  if #candidates == 0 then
    state.message = "Nothing to cut. The line under the button says which stage came up empty."
    state.message_kind = "error"
    state.cut_result, state.cut_result_kind = state.message, "error"
    state.cut_summary = {}
    return
  end

  -- Name before converting: vo.AssignNames sorts each asset's takes by `start`
  -- to number them, and source time is the one base every span shares.
  -- Deliveries first: the memoised spans hold the delivered names as they were
  -- when the match was built, and an Append typed since then lives only in the
  -- lines. See vo.RefreshSpanDeliveries.
  vo.RefreshSpanDeliveries(all_spans, ScriptLines())
  vo.AssignNames(all_spans, cfg)

  -- Resolve each candidate against the live item that plays it, in project
  -- time. A span no current item covers any more is dropped and counted rather
  -- than cut against silence.
  --
  -- Converted onto a COPY, never onto the span itself. The match is memoised
  -- and the table is built from those same span tables, so rewriting `start`
  -- from source time to project time would leave every row's source_start
  -- holding a project time the moment a cut succeeded -- rows would stop
  -- resolving to their items, statuses would drift, and a second cut would be
  -- working from nonsense.
  local skipped_msgs, by_item = {}, {}
  for _, s in ipairs(candidates) do
    -- By the span's MAJORITY, not the start instant: a re-cut resolves spans
    -- against takes that abut exactly at word boundaries, where an instant
    -- falls on an edge and lands in the wrong item (see
    -- vo.ResolveSourceSpanForCut). The strictness is kept -- a take whose
    -- audio is mostly trimmed away still refuses to resolve, and is reported,
    -- because cutting a truncated line under the full line's name is worse
    -- than not cutting it. Navigation is the lenient one; delivery is not.
    local item, proj_start, info =
      vo.ResolveSourceSpanForCut(s.source_path, s.start, s.stop, state.items)
    if not item then
      skipped_msgs[#skipped_msgs + 1] = string.format("%s: no item covers %.3fs in %s",
        s.name or s.asset or "(unnamed)", s.start or 0, vo.Basename(s.source_path))
    else
      local c = vo.ShallowCopy(s)
      c.start = proj_start
      c.stop  = vo.SourceTimeToProject(s.stop, info)
      local g = by_item[item]
      if not g then
        g = { item = item, info = info, spans = {} }
        by_item[item] = g
      end
      g.spans[#g.spans + 1] = c
    end
  end

  -- Word timings per source, for the silence probe. Read here rather than kept
  -- in state: cutting is a button press, not a frame.
  local words_by_path = {}
  for _, m in ipairs(state.matches or {}) do
    local parsed = vo.ReadTranscript(m.path)
    words_by_path[m.path] = parsed and parsed.words or {}
  end

  -- Pad outward from the recognised words, snapping to silence where it can be
  -- measured.
  --
  -- A failure here is reported and the item is cut anyway, with the pads as
  -- they were proposed. Padding is a refinement -- where an edge sits inside
  -- the silence around a take -- and losing it is worth far less than losing
  -- the cut. This used to raise, which took the whole run with it.
  local pad_fallbacks, pad_errors = 0, {}
  for _, g in pairs(by_item) do
    table.sort(g.spans, function(a, b) return (a.start or 0) < (b.start or 0) end)

    local take = r.GetActiveTake(g.item)
    local probe, destroy = vo.MakeTakeProbe(take)
    local ok, err = pcall(function()
      if not probe then error("no audio accessor for this take") end
      -- Only the words this ITEM covers: a source already split across several
      -- items has words belonging to its siblings, and probing outside the take
      -- answers silence, which drags the measured floor down.
      local covered = vo.SourceCoverageRanges({ g.info })[1]
      local proj_words = {}
      for _, w in ipairs(words_by_path[g.info.path] or {}) do
        if w.t1 >= covered.from and w.t0 <= covered.to then
          proj_words[#proj_words + 1] = {
            t0   = vo.SourceTimeToProject(w.t0, g.info),
            t1   = vo.SourceTimeToProject(w.t1, g.info),
            text = w.text,
          }
        end
      end

      local floor = vo.MeasureNoiseFloor(vo.InterWordGaps(proj_words), probe, cfg)
      vo.ApplyPadding(g.spans, cfg,
        { start = g.info.pos, stop = g.info.pos + g.info.length },
        probe, floor, proj_words)
    end)
    -- ALWAYS, including on the error path: the accessor holds the file open.
    if destroy then destroy() end
    if not ok then
      pad_errors[#pad_errors + 1] = string.format("%s: %s",
        vo.Basename(g.info.path or "(unknown)"), tostring(err))
    end

    for _, s in ipairs(g.spans) do
      if s.snapped == "pad" then pad_fallbacks = pad_fallbacks + 1 end
    end
  end

  -- One transaction around every split and rename, so the run is one undo step.
  local applied, failures = 0, {}
  core.Transaction("VO Overview: cut and name", function()
    for _, g in pairs(by_item) do
      local a, f = vo.ApplyPlan(g.spans, g.info.track)
      applied = applied + a
      for _, msg in ipairs(f) do failures[#failures + 1] = msg end
    end
  end)

  state.cut_summary = vo.FormatCutSummary(all_spans, applied, skipped_msgs, failures)

  -- Where the run actually went, stage by stage. Without this a run that cuts
  -- fewer clips than expected gives no way to tell which stage lost them.
  local grouped = 0
  for _ in pairs(by_item) do grouped = grouped + 1 end
  table.insert(state.cut_summary, 1, {
    text = string.format(
      "%d span(s) to cut -> %d resolved to an item on %d item(s) -> %d cut. " ..
      "%d could not be placed.",
      #candidates, #candidates - #skipped_msgs, grouped, applied, #skipped_msgs),
    warn = applied < (#candidates - #skipped_msgs),
  })
  for _, msg in ipairs(pad_errors) do
    state.cut_summary[#state.cut_summary + 1] = {
      text = "Edge snapping failed, cut with the fixed pads: " .. msg, warn = true }
  end

  if #stale_names > 0 then
    state.cut_summary[#state.cut_summary + 1] = {
      text = string.format(
        "%d recording(s) changed since they were transcribed and were skipped: %s. " ..
        "Re-transcribe them in ajsfx VO Sources.",
        #stale_names, table.concat(stale_names, ", ")),
      warn = true,
    }
  end
  if pad_fallbacks > 0 then
    state.cut_summary[#state.cut_summary + 1] = {
      text = string.format(
        "%d clip edges fell back to the fixed pad — no silence found in the gap.",
        pad_fallbacks),
      warn = true,
    }
  end
  state.message, state.message_kind =
    string.format("Cut and named %d clip(s). Press Pull to route them.", applied),
    (applied > 0) and "ok" or "error"

  -- The message renders at the bottom of the window, under the table, and the
  -- panel is at the top -- so on a tall window a run reports into space the
  -- user is not looking at. Repeated here, where the button is.
  state.cut_result = state.message
  state.cut_result_kind = state.message_kind

  -- A run that did not do what it was asked writes the whole report to the
  -- REAPER console: unmissable, and copy-pasteable when it needs reporting.
  -- A clean run stays quiet.
  local expected = #candidates - #skipped_msgs
  if applied < expected or #failures > 0 or #pad_errors > 0 then
    local out = { "ajsfx VO — Cut and Name report", string.rep("-", 46) }
    for _, line in ipairs(state.cut_summary) do out[#out + 1] = line.text end
    if #skipped_msgs > 0 then
      out[#out + 1] = ""
      out[#out + 1] = "Could not be placed:"
      for i, msg in ipairs(skipped_msgs) do
        if i > 20 then out[#out + 1] = ("  ...and %d more"):format(#skipped_msgs - 20); break end
        out[#out + 1] = "  " .. msg
      end
    end
    if #failures > 0 then
      out[#out + 1] = ""
      out[#out + 1] = "Failed to cut:"
      for i, msg in ipairs(failures) do
        if i > 20 then out[#out + 1] = ("  ...and %d more"):format(#failures - 20); break end
        out[#out + 1] = "  " .. msg
      end
    end
    r.ShowConsoleMsg(table.concat(out, "\n") .. "\n\n")
  end

  Reload()
end

local function DrawCutPanel()
  im.Separator(ctx)
  im.TextWrapped(ctx,
    "Splits every take the match identified out of its recording and names it " ..
    "the script's filename. Nothing moves and nothing is decided: press Pull " ..
    "afterwards to route the takes onto their tracks.")
  im.Spacing(ctx)

  -- "##do" is an ID suffix, not part of the label: the toolbar has a button
  -- reading "Cut and Name" too, and ImGui identifies a widget by its label
  -- within the window. Two buttons with one ID are ONE widget to ImGui, and
  -- the click never reaches this one.
  if im.Button(ctx, "Cut and Name##do") then
    -- Wrapped: an error in the cut path used to escape into the defer loop,
    -- which stops the script dead and looks exactly like the button doing
    -- nothing. Whatever went wrong belongs on screen.
    pending_action = function()
      local ok, err = pcall(DoCut)
      if not ok then
        state.message, state.message_kind = "Cut failed: " .. tostring(err), "error"
        state.cut_result, state.cut_result_kind = state.message, "error"
        r.ShowConsoleMsg("ajsfx VO — Cut and Name FAILED\n" .. tostring(err) .. "\n\n")
      end
    end
  end
  im.SameLine(ctx)
  if im.Button(ctx, "Close##cut") then state.panel = nil end
  im.SameLine(ctx)

  DrawScopeToggle("cut")

  -- The pipeline, stage by stage, from the same code the run uses. A run that
  -- does nothing can then be read off rather than guessed at.
  local key = table.concat({ tostring(state.scanned_at), tostring(#SelectedRows()) }, "|")
  if key ~= state.cut_count_key then
    local _, _, _, counts = CutCandidates()
    state.cut_count_key, state.cut_counts = key, counts
  end
  local c = state.cut_counts
  im.TextDisabled(ctx, string.format(
    "%d spans matched, %d cuttable, %d in range, %d skipped as stale  ->  %d to cut",
    c.spans, c.cuttable, c.in_range, c.stale, c.candidates))

  -- Before the first cut is the moment this is fixable for free: afterwards
  -- the takes of both lines share a name until the Appends land and a re-cut
  -- renames them.
  if #(state.dupe_assets or {}) > 0 then
    im.TextColored(ctx, 0xDDAA33FF, string.format(
      "%d delivered name(s) are claimed by two script lines. Set an Append " ..
      "on each first, or their takes will be cut under one shared name.",
      #state.dupe_assets))
  end

  -- What the last run did, repeated here because the window's own message line
  -- is below the table and this panel is above it.
  if state.cut_result and state.cut_result ~= "" then
    im.TextColored(ctx, state.cut_result_kind == "error" and 0xDD6666FF or 0x66BB66FF,
                   state.cut_result)
  end

  for _, line in ipairs(state.cut_summary or {}) do
    if line.warn then im.TextColored(ctx, 0xDDAA33FF, line.text)
    else im.TextDisabled(ctx, line.text) end
  end

  im.Separator(ctx)
end

-- -----------------------------------------------------------------------
-- Pull
--
-- Moves items onto Selects / Alts / Outs / Review tracks nested under the
-- recording they came from. It identifies an item by its NAME, never by the
-- match, which is what lets it serve a folder of rendered files with no
-- transcripts at all as well as a session this window cut.
-- -----------------------------------------------------------------------


local function Pull()
  Reload()
  state.name_baseline = nil
  local items, marks = TargetItems()
  local moves, summary = vo.PlanPull(items, state.lines, marks)

  if #moves == 0 then
    state.message, state.message_kind = string.format(
      "Nothing to pull. %d item(s) are not on the script; %d name(s) are claimed by two lines.",
      summary.unknown, summary.ambiguous), "error"
    state.pull_result, state.pull_result_kind = state.message, "error"
    return
  end

  local cfg  = vo.LoadConfig()
  local base = { selects = cfg.track_selects or "Selects",
                 alts    = cfg.track_alts    or "Alts",
                 review  = cfg.track_review  or "Review" }

  local by_id = {}
  for _, it in ipairs(items) do by_id[it.id] = it end

  local bases = { base.selects, base.alts, base.review }

  -- The recording an item came out of, which is what its destination nests
  -- under. Pull runs more than once -- that is the whole workflow -- so by the
  -- second pass an item is sitting on "<CHAR>_Review", and nesting its new
  -- destination under THAT would bury a track inside a track on every run.
  local function RecordingTrackOf(item)
    local track = r.GetMediaItem_Track(item)
    while track do
      local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
      if not vo.IsDestTrackName(name, bases) then return track end
      local parent = r.GetParentTrack(track)
      if not parent then return track end
      track = parent
    end
    return track
  end

  core.Transaction("VO Overview: pull", function()
    local tracks = {}

    -- The trio reads Selects / Alts / Review top to bottom. EnsureChildTrack
    -- inserts directly below the parent, so they are created in REVERSE --
    -- each new one pushes the earlier ones down.
    local seen_parents = {}
    for _, move in ipairs(moves) do
      local parent = RecordingTrackOf(move.id)
      if parent and not seen_parents[parent] then
        seen_parents[parent] = true
        for _, cat in ipairs({ "review", "alts", "selects" }) do
          tracks[tostring(parent) .. "|" .. base[cat]] =
            vo.EnsureChildTrack(parent, base[cat])
        end
      end
    end

    -- Leftover chunks that are only floor noise are deleted; anything with
    -- talking in it stays. Self-calibrating rather than thresholded against
    -- a guess: speech rises tens of dB over its own room tone, a chunk of
    -- floor noise has almost no dynamic range. Only UNNAMED remainders on a
    -- recording track are candidates -- named takes and anything on other
    -- tracks are never touched. Recordings are found through the routed
    -- items too, so a re-pull with nothing to move still tidies.
    local cleanup = {}
    for p in pairs(seen_parents) do cleanup[p] = true end
    for _, it in ipairs(items) do
      local tr = r.GetMediaItem_Track(it.id)
      if tr then
        local _, tn = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
        if vo.IsDestTrackName(tn, bases) then
          local p = RecordingTrackOf(it.id)
          if p then cleanup[p] = true end
        end
      end
    end
    local deleted = 0
    for parent in pairs(cleanup) do
      local doomed = {}
      for ii = 0, r.CountTrackMediaItems(parent) - 1 do
        local it2 = r.GetTrackMediaItem(parent, ii)
        local tk2 = r.GetActiveTake(it2)
        if tk2 then
          local _, nm2 = r.GetSetMediaItemTakeInfo_String(tk2, "P_NAME", "", false)
          if nm2 == "" or nm2:find("%.wav$") then
            local pos2 = r.GetMediaItemInfo_Value(it2, "D_POSITION")
            local len2 = r.GetMediaItemInfo_Value(it2, "D_LENGTH")
            -- Too short to be usable audio, whatever is in it.
            if len2 < vo.Opt(cfg, "pull_min_leftover") then
              doomed[#doomed + 1] = it2
            else
            local probe, destroy = vo.MakeTakeProbe(tk2)
            if probe then
              local lo, hi = math.huge, -math.huge
              local t = pos2
              while t < pos2 + len2 - 0.05 do
                local db = probe(t, math.min(t + 0.1, pos2 + len2))
                if db then
                  if db < lo then lo = db end
                  if db > hi then hi = db end
                end
                t = t + 0.1
              end
              destroy()
              -- Quietly uniform AND quiet overall. Both, so neither a soft
              -- distant mutter (range) nor a steady loud hum (level) is lost.
              if hi > -math.huge and (hi - lo) < 12.0 and hi < -35.0 then
                doomed[#doomed + 1] = it2
              end
            end
            end
          end
        end
      end
      for _, d in ipairs(doomed) do r.DeleteTrackMediaItem(parent, d) end
      deleted = deleted + #doomed
    end
    state.pull_deleted = deleted

    for _, move in ipairs(moves) do
      local item   = move.id
      -- Read the track INSIDE the loop: an earlier move may already have taken
      -- this item off the one it started on.
      local parent = RecordingTrackOf(item)
      -- Plain Selects / Alts / Review, no character prefix: a recording is
      -- one performer's session, so its children need no telling apart --
      -- two characters never share a source track, and the separation that
      -- matters is already the per-recording nesting.
      local name   = base[move.dest]
      local key    = tostring(parent) .. "|" .. name
      if not tracks[key] then tracks[key] = vo.EnsureChildTrack(parent, name) end

      -- An item already on its destination is left alone rather than moved to
      -- where it is: the common case on a second pull is "most of these stay on
      -- Review", and a no-op move would still dirty the project.
      local dest = tracks[key]
      if r.GetMediaItem_Track(item) ~= dest then
        r.MoveMediaItemToTrack(item, dest)
      end
      if move.rename then
        local take = r.GetActiveTake(item)
        if take then
          r.GetSetMediaItemTakeInfo_String(take, "P_NAME", move.rename, true)
        end
      end
    end

    -- A kept leftover that ends right where a pulled take begins usually
    -- holds that take's clipped opening -- a spoken lead-in the matcher
    -- couldn't align, stranded when the span started at the first scripted
    -- word. Say so; adopting audio into a take is the user's call.
    local leftovers, takes = {}, {}
    for parent in pairs(cleanup) do
      for ii = 0, r.CountTrackMediaItems(parent) - 1 do
        local it2 = r.GetTrackMediaItem(parent, ii)
        local tk2 = r.GetActiveTake(it2)
        if tk2 then
          local _, nm2 = r.GetSetMediaItemTakeInfo_String(tk2, "P_NAME", "", false)
          if nm2 == "" or nm2:find("%.wav$") then
            local offs2 = r.GetMediaItemTakeInfo_Value(tk2, "D_STARTOFFS")
            leftovers[#leftovers + 1] = {
              pos = r.GetMediaItemInfo_Value(it2, "D_POSITION"),
              src_end = offs2 + r.GetMediaItemInfo_Value(it2, "D_LENGTH"),
            }
          end
        end
      end
    end
    for _, dest in pairs(tracks) do
      for ii = 0, r.CountTrackMediaItems(dest) - 1 do
        local it2 = r.GetTrackMediaItem(dest, ii)
        local tk2 = r.GetActiveTake(it2)
        if tk2 then
          local _, nm2 = r.GetSetMediaItemTakeInfo_String(tk2, "P_NAME", "", false)
          takes[#takes + 1] = {
            name = nm2,
            src_start = r.GetMediaItemTakeInfo_Value(tk2, "D_STARTOFFS"),
          }
        end
      end
    end
    state.pull_clipped = vo.FlagClippedHeads(
      leftovers, takes, vo.Opt(cfg, "clipped_head_gap"))
    r.UpdateArrange()
  end)

  local clipped = ""
  for _, f in ipairs(state.pull_clipped or {}) do
    clipped = clipped .. string.format(
      " Leftover @%.1f may hold the clipped opening of %s.", f.leftover.pos, f.take)
  end
  state.message, state.message_kind = string.format(
    "Pulled %d select, %d alt, %d to review. %d item(s) not on the script.%s%s",
    summary.selects, summary.alts, summary.review,
    summary.unknown + summary.ambiguous,
    (state.pull_deleted or 0) > 0
      and string.format(" %d silent leftover(s) deleted.", state.pull_deleted)
      or "", clipped), (clipped ~= "") and "warn" or "ok"
  state.pull_result, state.pull_result_kind = state.message, state.message_kind
  Reload()
end

-- Names every alt that has none.
--
-- A PER-TAKE name, not an Append: an Append belongs to the script line and
-- would rename the alt's select along with it, leaving the two still colliding.
-- See vo.PlanAltNames.
local function ApplyAltNames()
  Reload()
  state.name_baseline = nil
  local cfg  = vo.LoadConfig()
  local rows = AffectedRows()
  local edits, skipped = vo.PlanAltNames(rows, {
    pattern = cfg.alt_append_pattern,
    start   = cfg.alt_append_start,
    digits  = cfg.alt_append_digits,
  })

  -- One transaction for the lot, so a run of forty alts is one undo step
  -- rather than forty. The entry is written directly rather than through
  -- Mutate, which rebuilds the whole match on every call -- forty rebuilds for
  -- one press, and each one invalidating the rows still to be named.
  local named = 0
  if #edits > 0 then
    -- Resolved once for the whole run, against the live project: the rows'
    -- cached pointers can be stale, and a stale one here writes a name onto
    -- somebody else's clip.
    local items = vo.CollectProjectSpans()
    core.Transaction("VO Overview: name alts", function()
      for _, e in ipairs(edits) do
        local row   = rows[e.index]
        local clean = row and vo.SanitizeName(e.name) or ""
        if clean ~= "" then
          local item = row.source_path and row.source_start
                       and vo.ResolveSourceTime(row.source_path, row.source_start, items)
          if item then
            local take = r.GetActiveTake(item)
            if take then
              r.GetSetMediaItemTakeInfo_String(take, "P_NAME", clean, true)
            end
          end
          EntryFor(row).name_override = clean
          named = named + 1
        end
      end
    end)
    r.UpdateArrange()
    state.dirty = true
    Reload()
  end

  -- Named 0 with nothing skipped means nothing was TICKED, which is the likely
  -- confusion: the button names alts, and an alt is a row with Keep ticked and
  -- Sel not.
  local why = ""
  if named == 0 and skipped == 0 then
    local keeps, sels = 0, 0
    for _, row in ipairs(rows) do
      if row.user_keep then keeps = keeps + 1 end
      if row.user_select then sels = sels + 1 end
    end
    why = string.format(
      " No alts in range: %d row(s) shown, %d with Keep ticked, %d with Sel. " ..
      "An alt is Keep ticked and Sel not.", #rows, keeps, sels)
  end

  state.message, state.message_kind = string.format(
    "Named %d alt%s.%s%s", named, named == 1 and "" or "s",
    skipped > 0 and string.format(" %d already had a name and were left alone.", skipped) or "",
    why),
    (named > 0) and "ok" or "error"
  state.pull_result, state.pull_result_kind = state.message, state.message_kind
end

local function DrawPullPanel()
  im.Separator(ctx)
  im.TextWrapped(ctx,
    "Moves items onto Selects, Alts and Review tracks nested under the recording " ..
    "they came from. Sel is the delivery, Keep is delivered alongside it as an " ..
    "alt, and everything unticked waits on Review. Items are matched to the " ..
    "script by NAME, so this works on rendered files that were never cut here; " ..
    "an item whose name is not on the script is left alone.")
  im.Spacing(ctx)

  -- Alt naming ----------------------------------------------------------
  local cfg = vo.LoadConfig()
  im.Text(ctx, "Name alts:")
  im.SameLine(ctx)
  im.SetNextItemWidth(ctx, 110)
  local changed, pattern = im.InputText(ctx, "pattern##altpat", cfg.alt_append_pattern or "_alt{n}")
  if changed then cfg.alt_append_pattern = pattern; vo.SaveConfig(cfg) end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "{n} is where the number goes. With no {n} it goes on the end.")
  end
  im.SameLine(ctx)
  im.SetNextItemWidth(ctx, 70)
  local schanged, start = im.InputInt(ctx, "start##altstart", math.floor(cfg.alt_append_start or 1))
  if schanged then cfg.alt_append_start = math.max(0, start); vo.SaveConfig(cfg) end
  im.SameLine(ctx)
  im.SetNextItemWidth(ctx, 70)
  local dchanged, digits = im.InputInt(ctx, "digits##altdig", math.floor(cfg.alt_append_digits or 1))
  if dchanged then cfg.alt_append_digits = math.max(1, math.min(4, digits)); vo.SaveConfig(cfg) end
  im.SameLine(ctx)
  if im.Button(ctx, "Name them##altapply") then pending_action = ApplyAltNames end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Fills the Append of every alt that has none.\n" ..
                       "An Append you typed is never overwritten.")
  end

  -- Preview against a real line, so the convention is checked before it lands.
  local sample = (state.visible[1] and state.visible[1].asset) or "line_042"
  local preview = {}
  for i = 0, 2 do
    preview[#preview + 1] = sample ..
      vo.FormatAltAppend(cfg.alt_append_pattern or "_alt{n}",
                         math.floor(cfg.alt_append_start or 1) + i,
                         math.floor(cfg.alt_append_digits or 1))
  end
  im.TextDisabled(ctx, "  " .. table.concat(preview, ", "))
  im.Spacing(ctx)

  -- Pull ----------------------------------------------------------------
  -- ##do: distinct from the toolbar's "Pull". See DrawCutPanel.
  if im.Button(ctx, "Pull##do") then pending_action = Pull end
  im.SameLine(ctx)
  if im.Button(ctx, "Close##pull") then state.panel = nil end
  im.SameLine(ctx)
  DrawScopeToggle("pull")
  im.SameLine(ctx)

  -- Memoised on the project-state counter and the row selection: PullItems
  -- reads a take name per item, which is a REAPER call per item and has no
  -- business running at frame rate. Both inputs move exactly when the answer
  -- would change.
  local key = table.concat({ tostring(state.scanned_at), tostring(#SelectedRows()),
                             tostring(r.CountSelectedMediaItems(0)) }, "|")
  if key ~= state.pull_count_key then
    local items, marks = TargetItems()
    local _, n = vo.PlanPull(items, state.lines, marks)
    state.pull_count_key, state.pull_count = key, n
  end
  local n = state.pull_count
  im.TextDisabled(ctx, string.format(
    "%d select, %d alt, %d review; %d not on the script%s",
    n.selects, n.alts, n.review, n.unknown + n.ambiguous,
    n.ambiguous > 0 and string.format(" (%d name clashes)", n.ambiguous) or ""))

  -- The window's own message line is below the table; this panel is above it.
  if state.pull_result and state.pull_result ~= "" then
    im.TextColored(ctx,
      state.pull_result_kind == "error" and 0xDD6666FF
      or state.pull_result_kind == "warn" and 0xDDAA44FF or 0x66BB66FF,
                   state.pull_result)
  end

  im.Separator(ctx)
end

local function DrawFilters()
  -- Every control here writes state.dirty: the filters are stored in the project
  -- file so the table opens the way it was left. The flush is throttled, so a
  -- filter box being typed into does not write a file per keystroke.

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
        function(k)
          state.character = (k ~= "__all__") and k or nil
          state.dirty = true
        end)
  im.SameLine(ctx)

  local filtering = AnyColumnFilter()
  if im.Button(ctx, filtering and "Filters *" or "Filters") then
    state.filter_row = not state.filter_row
    state.dirty = true
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Show a filter box under each column header.\n" ..
                       "Click a header to sort by that column.")
  end
  if filtering then
    im.SameLine(ctx)
    if im.Button(ctx, "Clear filters") then
      state.col_filters = {}
      state.dirty = true
    end
  end
  im.SameLine(ctx)

  im.SetNextItemWidth(ctx, 200)
  local changed, text = im.InputTextWithHint(ctx, "##search", "Search…", state.search)
  if changed then state.search = text; state.dirty = true end

  im.SameLine(ctx)
  -- Called directly, not deferred: the toolbar draws above the table, so
  -- nothing here runs inside it, and `pending_action` is not in scope yet.
  if im.Button(ctx, "Rematch") then Rematch() end
  if im.IsItemHovered(ctx) then
    local locked = #state.pins
    im.SetTooltip(ctx, string.format(
      "Re-read every transcript and identify the lines again from scratch.\n" ..
      "Locked lines keep the placement they have (%d locked).\n\n" ..
      "Do this after transcribing in ajsfx VO Sources, or after editing\n" ..
      "the script.", locked))
  end

  im.SameLine(ctx)
  if im.Button(ctx, "Select takes") then AutoSelectTakes(AffectedRows()) end
  im.SameLine(ctx)
  Combo("##autoselect", 70, TAKE_PICKS, state.auto_select_take, function(k)
    state.auto_select_take = k
    local cfg = vo.LoadConfig()
    cfg.auto_select_take = k
    vo.SaveConfig(cfg)
  end)
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Which take to mark as the select on a line that was\n" ..
                       "read more than once. Locked lines are left alone.")
  end

  im.SameLine(ctx)
  if im.Button(ctx, "Place") then pending_action = PlaceSelectedItems end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx,
      "File the item(s) selected in REAPER where their NAME says they\n" ..
      "belong: a plain delivered name goes to Selects, an alt-patterned\n" ..
      "one to Alts. Rename first, press this, the sheet follows.")
  end

  im.SameLine(ctx)
  if im.Button(ctx, "Tighten") then pending_action = TightenItems end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx,
      "Finishing pass: measure where the audio really is in each delivered\n" ..
      "item and pull loose edges in to the standard head/tail room. Inward\n" ..
      "only, so speech is never lost; hand-trimmed items (custom fades)\n" ..
      "are left alone. Works on the REAPER selection, or everything on\n" ..
      "Selects + Alts when nothing is selected.")
  end
end

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
  im.Separator(ctx)
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

  -- ##do: distinct from the toolbar's "Sort". See DrawCutPanel.
  if im.Button(ctx, "Sort##do") then
    pending_action = SortOnTimeline
  end

  -- Counted from the rows alone: clustering walks every item in the project and
  -- has no business running at frame rate.
  -- Memoised on everything that could change the answer: working it out reads
  -- a take name per item, which is a REAPER call per item and must not run at
  -- frame rate.
  local key = table.concat({ tostring(state.scanned_at), tostring(#SelectedRows()),
                             tostring(r.CountSelectedMediaItems(0)),
                             state.layout_order }, "|")
  if key ~= state.layout_count_key then
    local items, unresolved, scope = 0, 0, nil
    if state.layout_order == "script" then
      local index = vo.BuildNameIndex(state.lines)
      local list
      list, _, scope = TargetItems()
      for _, it in ipairs(list) do
        if vo.ResolveItemName(index, it.name) then items = items + 1
        else unresolved = unresolved + 1 end
      end
    else
      local rows, from_selection = AffectedRows()
      local seen = {}
      for _, row in ipairs(rows) do
        if row.item and not seen[row.item] then
          seen[row.item] = true
          items = items + 1
        end
      end
      scope = from_selection and "selected rows" or "all shown rows"
    end
    state.layout_count_key = key
    state.layout_count = { items = items, unresolved = unresolved, scope = scope }
  end
  local c = state.layout_count
  im.SameLine(ctx)
  im.TextDisabled(ctx, string.format("%d item%s (%s)%s",
    c.items, c.items == 1 and "" or "s", c.scope or "",
    c.unresolved > 0 and string.format(", %d not on the script", c.unresolved) or ""))
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx,
      "With rows selected, only those items move.\n" ..
      "With nothing selected, every item behind the rows shown here moves.\n" ..
      "Overlapping items on one track always travel together, so crossfades survive.\n\n" ..
      "In script order an item is placed by the NAME it carries, so an uncut\n" ..
      "recording is left where it is. Record order needs no name.")
  end
  im.SameLine(ctx)
  if im.Button(ctx, "Close##sort") then state.panel = nil end
  im.SameLine(ctx)
  DrawScopeToggle("sort")

  im.Separator(ctx)
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

-- ImGui owns the header click, the arrow and the spec; all we do is read which
-- column it settled on. The read has to happen inside the table, which is the
-- only place the spec exists, so the re-sort lands on the NEXT frame — one
-- frame of lag, and in exchange the list is never mutated mid-draw.
local function ReadSortSpec()
  if not (SORT_SPECS and NEED_SORT) then return end
  if not NEED_SORT(ctx) then return end
  local ok, index, _, dir = SORT_SPECS(ctx, 0)
  local c = ok and COLUMNS[(index or 0) + 1] or nil
  -- Tristate: the third click clears the spec, which puts the table back into
  -- script order rather than leaving it wherever the last sort left it.
  state.sort_col  = c and c.key or nil
  state.sort_desc = (dir == SORT_DESC)
end

local function DrawFilterRow()
  im.TableNextRow(ctx)
  for i, c in ipairs(COLUMNS) do
    im.TableSetColumnIndex(ctx, i - 1)
    if c.text and not c.nofilter then
      im.PushID(ctx, "flt_" .. c.key)
      im.SetNextItemWidth(ctx, -1)
      local changed, text = im.InputTextWithHint(ctx, "##f", "filter",
                                                 state.col_filters[c.key] or "")
      if changed then state.col_filters[c.key] = text; state.dirty = true end
      im.PopID(ctx)
    end
  end
end

local function DrawTableBody()
  for _, c in ipairs(COLUMNS) do
    local flags = im.TableColumnFlags_WidthFixed
    -- A column with no accessor has nothing to sort on, so ImGui must not
    -- offer its header as a sort target.
    if not (c.text or c.num) then
      local nosort = Api('TableColumnFlags_NoSort')
      if nosort then flags = flags | nosort end
    end
    im.TableSetupColumn(ctx, c.label, flags, c.width)
  end
  -- Both the header and the filter boxes stay put while the rows scroll.
  im.TableSetupScrollFreeze(ctx, 0, state.filter_row and 2 or 1)
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
  ReadSortSpec()

  if state.filter_row then DrawFilterRow() end

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
  -- here as excessive creation of short-lived resources.
  for i, row in ipairs(state.visible) do
    -- No min_row_height: ImGui already sizes the row from its tallest cell,
    -- and row_h is the measurement of that from last frame.
    local row_h = RowHeight(row)
    BeginRowMeasure(row)
    im.TableNextRow(ctx)
    im.PushID(ctx, i)
    id_depth = id_depth + 1

    -- # ---------------------------------------------------------------------
    -- Script position, not row position: it stays with the line through every
    -- sort and filter, so it is also how a user gets back to where they were.
    im.TableSetColumnIndex(ctx, CI.order)
    CellText(row, "order", CI.order, row_h, tostring(row.order or ""), "disabled")

    -- Verified ------------------------------------------------------------
    im.TableSetColumnIndex(ctx, CI.verify)
    CellWidget("verify", row_h)
    local checked = row.user_status == "verified"
    local hit, now = im.Checkbox(ctx, "##ok", checked)
    if hit then pending_action = function() SetLock(row, now) end end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, checked
        and "Locked here. Rematching will not move it."
        or  "Lock this line where it is, so rematching leaves it alone.")
    end

    -- Status --------------------------------------------------------------
    im.TableSetColumnIndex(ctx, CI.status)
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
    -- The timeline->table follow asked for this row; consumed once, so the
    -- user can scroll away afterwards without the table yanking them back.
    if state.scroll_to_uid == row.uid then
      im.SetScrollHereY(ctx, 0.4)
      state.scroll_to_uid = nil
    end
    if im.IsItemHovered(ctx) and not row.item then
      im.SetTooltip(ctx, row.status == "missing"
        and "This line has no audio in the project yet."
        or  "The audio for this row is not in this project.")
    end
    -- Right-click acts on the whole selection when this row is part of it, and
    -- on this row alone when it is not -- so right-clicking somewhere else
    -- never silently operates on rows you had selected earlier.
    if im.BeginPopupContextItem(ctx, "##row_menu") then
      local targets = state.selection[row.uid] and SelectedRows() or { row }
      local label = (#targets > 1)
        and string.format("Find candidates for %d lines", #targets)
        or  "Find candidates"
      if im.MenuItem(ctx, label) then
        pending_action = function() RunCandidateSearch(targets) end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, "Every place in the transcripts this line could sit,\n" ..
                           "with what is around it. Looks only -- changes nothing.")
      end

      im.Separator(ctx)

      -- Assigning is naming. An item named for a line IS that line's take --
      -- that is what every tool here reads -- so "this item is for that line"
      -- needs no pin, no stored mapping and no time selection. It uses what is
      -- already selected in REAPER, which is what you have in your hand after
      -- cutting or comping something.
      local n_sel = r.CountSelectedMediaItems(0)
      local can_assign = (#targets == 1) and n_sel > 0
                         and row.asset and row.asset ~= ""
      local assign_label = (n_sel > 1)
        and string.format("Assign %d selected items to this line", n_sel)
        or  "Assign selected item to this line"
      if im.MenuItem(ctx, assign_label, nil, nil, can_assign) then
        local target, name = row, (row.deliver or row.asset)
        pending_action = function() AssignSelectedItems(target, name) end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, n_sel > 0
          and ("Names the item(s) selected in REAPER \"" ..
               tostring(row.deliver or row.asset) .. "\".\n\n" ..
               "Several at once are numbered with the alt pattern, so the\n" ..
               "first is the line and the rest are its alts.")
          or  "Select the item in REAPER first.")
      end

      -- Changing your mind after a pull is a SWAP, driven from the sheet:
      -- this take gets the plain name and the Selects track, the old select
      -- gets a free alt name and the Alts track. (Moving items between
      -- tracks by hand decides nothing -- the name is the assignment.)
      local can_make = (#targets == 1) and row.item
                       and row.asset and row.asset ~= ""
      if im.MenuItem(ctx, "Make this take the Select", nil, nil, can_make) then
        local target = row
        pending_action = function() MakeSelect(target) end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx,
          "This take gets the line's delivered name and the Selects track;\n" ..
          "the current select becomes an alt. One undo step.")
      end

      im.Separator(ctx)

      -- Pinning is one line at a time on purpose: a time selection is one
      -- stretch of audio, and it cannot be several lines at once.
      local can_lock = (#targets == 1) and row.asset and row.asset ~= ""
      if im.MenuItem(ctx, "Lock to time selection", nil, nil, can_lock) then
        pending_action = function()
          local at, why = TimeSelectionAsSource()
          if at then
            LockHere(row, at.source, at.start, at.stop)
          else
            state.message, state.message_kind = why, "error"
          end
        end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, #targets > 1
          and "Select one row to lock: a time selection is one stretch of audio."
          or  "Say that THIS stretch of audio is this take, whatever\n" ..
              "identification thinks. Select the audio in REAPER first.\n\n" ..
              "Untick Lock to hand it back.")
      end

      im.EndPopup(ctx)
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

    -- Got ------------------------------------------------------------------
    -- Whether the project actually holds an item named for this line. Green
    -- when it does, red when it does not, and it does not care how the item got
    -- there -- cut here, comped by hand, or delivered by somebody else.
    im.TableSetColumnIndex(ctx, CI.delivered)
    if row.status ~= "orphan" and row.script_row then
      local rec = DELIVERY(row.script_row)
      local gf = PushCellFont("delivered")
      AlignCell("delivered", row_h, im.GetTextLineHeight(ctx))
      if rec then
        im.TextColored(ctx, 0x66BB66FF, tostring(rec.count))
      else
        im.TextColored(ctx, 0xDD6666FF, "no")
      end
      PopCellFont(gf)
      if im.IsItemHovered(ctx) then
        if rec then
          local where = {}
          for track, n in pairs(rec.tracks) do
            where[#where + 1] = string.format("  %s x%d",
              track ~= "" and track or "(unnamed track)", n)
          end
          table.sort(where)
          im.SetTooltip(ctx, string.format(
            "%d item%s in the project named %s:\n%s",
            rec.count, rec.count == 1 and "" or "s",
            row.deliver or row.asset or "?", table.concat(where, "\n")))
        else
          im.SetTooltip(ctx, string.format(
            "No item in the project is named %s.\n\n" ..
            "This is read from the item names, so it stays true however the\n" ..
            "audio got there. Cut and Name, or name an item yourself.",
            row.deliver or row.asset or "?"))
        end
      end
    end

    -- Sel and Keep ---------------------------------------------------------
    local markable = row.status ~= "missing" and row.status ~= "orphan"
                     and (row.take_count or 0) > 0

    im.TableSetColumnIndex(ctx, CI.select)
    if markable then
      CellWidget("select", row_h)
      local hit, now = im.Checkbox(ctx, "##sel", row.user_select == true)
      if hit then pending_action = function() SetSelect(row, now) end end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx,
          "The take you are delivering. One per line —\n" ..
          "ticking this one unticks the line's other takes.")
      end
    end

    im.TableSetColumnIndex(ctx, CI.keep)
    if markable then
      CellWidget("keep", row_h)
      local hit, now = im.Checkbox(ctx, "##keep", row.user_keep == true)
      if hit then pending_action = function() SetKeep(row, now) end end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx,
          "A read worth keeping. Any number per line, and\n" ..
          "independent of Sel — ticking this steals nothing.\n\n" ..
          "Pull delivers a kept take that is not the Sel as an ALT.\n" ..
          "Takes with neither tick stay on the Review track.")
      end
    end

    im.TableSetColumnIndex(ctx, CI.character)
    CellText(row, "character", CI.character, row_h, row.character, "plain")

    im.TableSetColumnIndex(ctx, CI.script)
    CellText(row, "script", CI.script, row_h, row.script, "disabled")

    -- Filename ------------------------------------------------------------
    im.TableSetColumnIndex(ctx, CI.item_name)
    -- The live take name where there is a take, so a rename made anywhere else
    -- in REAPER shows up here too. The project file's override is the fallback, so a
    -- name chosen for a line whose audio is not loaded is not lost.
    local shown = row.take_name or row.name_override or row.deliver or row.asset or ""
    if row.status == "missing" then
      -- Nothing to rename: there is no take at all.
      CellText(row, "item_name", CI.item_name, row_h, shown, "disabled")
      TooltipEvenWhenDisabled("This line has no take yet, so there is no item to name.")
    elseif not row.item then
      -- Matched audio whose item this project does not have -- the source is
      -- not loaded, or the span falls outside what the loaded item covers.
      -- Without this the cell falls back to the DELIVERED name and reads as an
      -- item that exists under that name, when nothing has been cut at all.
      CellText(row, "item_name", CI.item_name, row_h, "(no item)", "disabled")
      TooltipEvenWhenDisabled(
        "This take matched the transcript, but no item in this project plays\n" ..
        "that stretch of " .. vo.Basename(row.source_path or "the source") .. ".\n\n" ..
        "Either the recording is not in the project, or the item has been\n" ..
        "trimmed past this point. Cut and Name will skip it and say so.")
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
    im.TableSetColumnIndex(ctx, CI.asset)
    local csv_name = row.asset or ""
    -- Red until this line's delivered name is its own. The name being compared
    -- is the RESOLVED one, so the moment an Append (or a rename) separates the
    -- two lines, both go back to normal.
    local resolved = (row.name_override ~= nil and row.name_override ~= "")
                     and row.name_override or row.deliver
    local clash = row.line_key ~= nil and resolved ~= nil
                  and state.dupe_names[resolved] == true
    CellText(row, "asset", CI.asset, row_h, csv_name, clash and 0xDD6666FF or "disabled")
    if clash and im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Another script line is delivered under this same name.\n" ..
                         "The clips cut fine, but they will overwrite each other\n" ..
                         "when rendered to files. Type something in Append to\n" ..
                         "tell them apart.")
    end
    -- No per-cell tooltip otherwise: the explanation belongs on the header,
    -- where it is read once, not under the cursor on every row. An explicit
    -- popup ID is what lets a plain Text item own a context menu.
    if csv_name ~= "" and im.BeginPopupContextItem(ctx, "##csv_menu") then
      if im.MenuItem(ctx, "Copy") then Copy(csv_name) end
      local can_reset = row.status ~= "missing" and shown ~= (row.deliver or csv_name)
      if im.MenuItem(ctx, "Reset item name", nil, nil, can_reset) then
        pending_action = function() ResetName(row) end
      end
      if not can_reset then
        TooltipEvenWhenDisabled("The item is already named " .. csv_name .. ".")
      end
      im.EndPopup(ctx)
    end

    -- Append --------------------------------------------------------------
    im.TableSetColumnIndex(ctx, CI.append)
    if row.line_key then
      PushFilledField("append", row_h)
      -- AFTER PushFilledField, never before: that helper sets this cell's own
      -- background to the editable-field shade, so a red set first would simply
      -- be overwritten.
      --
      -- A row whose name comes from a hand-typed override is not the Append's
      -- problem to fix, so there only the filename goes red.
      if clash and (row.name_override == nil or row.name_override == "") then
        im.TableSetBgColor(ctx, im.TableBgTarget_CellBg, 0x66222240, -1)
      end
      local achanged, atext = im.InputText(ctx, "##append", row.append or "")
      PopFilledField()
      if achanged then
        local captured = atext
        pending_action = function() SetAppend(row, captured) end
      end
      if im.IsItemHovered(ctx) and (row.append or "") == "" then
        im.SetTooltip(ctx, "Type something here to tell this line apart from\n" ..
                           "another that asks for the same filename.")
      end
    end

    im.TableSetColumnIndex(ctx, CI.take)
    if (row.take_count or 0) > 1 then
      CellText(row, "take", CI.take, row_h,
               string.format("%d/%d", row.take_index or 0, row.take_count), "plain")
    elseif row.take_index then
      CellText(row, "take", CI.take, row_h, "1/1", "disabled")
    end

    im.TableSetColumnIndex(ctx, CI.line_text)
    CellText(row, "line_text", CI.line_text, row_h, row.line_text, "plain")

    im.TableSetColumnIndex(ctx, CI.transcript)
    if row.score and row.status == "review" then
      CellText(row, "transcript", CI.transcript, row_h, row.transcript, 0xDDAA33FF)
      if im.IsItemHovered(ctx) then
        local why = string.format("Match confidence %.0f%%.", row.score * 100)
        if row.in_sequence == false then
          why = why .. "\n\nBut it does not sit where the rest of the read says\n" ..
                       "this line should be. A line this short matches wherever\n" ..
                       "its words happen to fall, so its position is the only\n" ..
                       "evidence there is."
        end
        im.SetTooltip(ctx, why)
      end
    else
      CellText(row, "transcript", CI.transcript, row_h, row.transcript, "disabled")
    end

    im.TableSetColumnIndex(ctx, CI.source)
    CellText(row, "source", CI.source, row_h,
             row.source_path and vo.Basename(row.source_path) or "", "disabled")
    if row.source_path and im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, 0) then
      local captured = row.source_path
      pending_action = function()
        -- Written BEFORE the launch and read every frame by Sources, so an
        -- already-open Sources window picks the handoff up too, rather than
        -- only a freshly launched one.
        r.SetExtState(vo.EXT_SECTION, "focus_source", captured, false)
        local ok, why = vo.LaunchSibling("ajsfx_VO_Sources.lua")
        if not ok then state.message, state.message_kind = tostring(why), "error" end
      end
    end

    im.TableSetColumnIndex(ctx, CI.time)
    CellText(row, "time", CI.time, row_h, FormatTime(row.proj_time), "disabled")

    -- Notes ---------------------------------------------------------------
    im.TableSetColumnIndex(ctx, CI.notes)
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
  -- Tristate so a third click on a header clears the sort and returns the
  -- table to script order, which is the order the session was written in.
  if SORT_SPECS and NEED_SORT then
    flags = flags | im.TableFlags_Sortable
    local tristate = Api('TableFlags_SortTristate')
    if tristate then flags = flags | tristate end
  end
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
  -- The body runs inside pcall for the reason every table here does: an error
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

  -- The headline is COVERAGE, not matching: how many script lines the project
  -- actually holds an item for. That is the question the job is judged on, and
  -- it is read from the item names, so it stays true no matter how the audio
  -- got there or what the matcher thinks.
  local c = state.check or {}
  local total = #(state.lines or {})
  local got   = c.delivered or 0
  im.TextColored(ctx, (got >= total and total > 0) and 0x66BB66FF or 0xDDAA33FF,
    string.format("%d of %d lines in the project", got, total))
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx,
      "Script lines with at least one item named for them.\n" ..
      "Counted from the item names, so a take you cut by hand\n" ..
      "or were sent as a rendered file counts just the same.")
  end
  if (c.missing or 0) > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextColored(ctx, 0xDD6666FF, string.format("%d not there yet", c.missing))
  end
  if #(c.extra or {}) > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextColored(ctx, 0xDDAA33FF, string.format("%d name(s) not on the script", #c.extra))
    if im.IsItemHovered(ctx) then
      local list = {}
      for i, name in ipairs(c.extra) do
        if i > 30 then list[#list + 1] = ("...and %d more"):format(#c.extra - 30); break end
        list[#list + 1] = name
      end
      im.SetTooltip(ctx, "Items whose name matches no script line:\n" ..
                         table.concat(list, "\n"))
    end
  end
  if (c.ambiguous or 0) > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextColored(ctx, 0xDDAA33FF,
      string.format("%d item(s) named for two lines at once", c.ambiguous))
  end
  if #(state.name_drift or {}) > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextColored(ctx, 0xDDAA33FF,
      string.format("%d name(s) changed outside this window", #state.name_drift))
    if im.IsItemHovered(ctx) then
      local list = {}
      for i, d in ipairs(state.name_drift) do
        if i > 20 then list[#list + 1] = ("...and %d more"):format(#state.name_drift - 20); break end
        list[#list + 1] = d
      end
      im.SetTooltip(ctx,
        "The name on an item IS its assignment, and these moved without\n" ..
        "this window doing it (F2, a batch renamer, another script):\n\n" ..
        table.concat(list, "\n"))
    end
  end
  if #(state.orphan_appends or {}) > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextColored(ctx, 0xDD6666FF,
      string.format("%d Append(s) match no loaded line", #state.orphan_appends))
    if im.IsItemHovered(ctx) then
      local list = {}
      for i, a in ipairs(state.orphan_appends) do
        if i > 20 then list[#list + 1] = ("...and %d more"):format(#state.orphan_appends - 20); break end
        list[#list + 1] = string.format("%s: %s (#%d) %s",
          a.script or "?", a.asset or "?", a.nth or 1, a.text or "")
      end
      im.SetTooltip(ctx,
        "An Append is keyed to its script's filename and the line's position\n" ..
        "in it. Renaming, re-exporting or removing the CSV detaches these --\n" ..
        "and the name clash they used to clear comes back on the next cut:\n\n" ..
        table.concat(list, "\n"))
    end
  end

  im.Spacing(ctx)
  im.TextDisabled(ctx, string.format("%d of %d lines recorded", n.delivered or 0, n.lines or 0))
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

  local dupes = state.dupe_assets
  if dupes and #dupes > 0 then
    im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx)
    im.TextColored(ctx, 0xDDAA33FF, string.format(
      "%d duplicate filename%s", #dupes, #dupes == 1 and "" or "s"))
    if im.IsItemHovered(ctx) then
      local tip = { "These filenames are used by more than one script line.",
                    "Their takes are kept apart, and they cut fine -- two",
                    "items in REAPER may share a name. The clash only bites",
                    "when the clips are rendered to files." }
      for i, d in ipairs(dupes) do
        if i > 5 then
          tip[#tip + 1] = string.format("... and %d more", #dupes - 5)
          break
        end
        tip[#tip + 1] = ""
        tip[#tip + 1] = d.asset
        for k, row in ipairs(d.rows) do
          tip[#tip + 1] = string.format("    row %s   %s",
            tostring(row), (d.texts[k] or ""):sub(1, 60))
        end
      end
      im.SetTooltip(ctx, table.concat(tip, "\n"))
    end
  end
end

-- -----------------------------------------------------------------------
-- Settings
--
-- A window, not a modal: the point of changing a font size is watching the
-- table change under it.
-- -----------------------------------------------------------------------

local function DrawCandidatesWindow()
  if not state.candidates_open then return end

  im.SetNextWindowSize(ctx, 720, 480, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'VO Find candidates', true)
  state.candidates_open = open

  if visible then
    im.TextDisabled(ctx, "Where each line could sit. Click a placement to select it\n" ..
                         "on the timeline and put the play cursor on it. Nothing here\n" ..
                         "changes the match.")
    im.Separator(ctx)

    for gi, group in ipairs(state.candidates) do
      im.PushID(ctx, gi)
      im.Text(ctx, group.asset)
      if group.line_text ~= "" then
        im.SameLine(ctx)
        im.TextDisabled(ctx, "\226\128\148 " .. group.line_text)
      end

      if group.why then
        im.TextDisabled(ctx, group.why)
      end

      for hi, hit in ipairs(group.hits) do
        im.PushID(ctx, hi)

        local when = hit.proj_from and FormatTime(hit.proj_from) or "not in project"
        if im.SmallButton(ctx, string.format("%3.0f%%  %s", hit.score * 100, when)) then
          local captured = hit
          pending_action = function() ShowCandidate(captured) end
        end
        if im.IsItemHovered(ctx) then
          im.SetTooltip(ctx, vo.Basename(hit.source_path or ""))
        end

        im.SameLine(ctx)
        if im.SmallButton(ctx, "Lock here") then
          local target, src = group.row, hit.source_path
          local from, to = hit.start, hit.stop
          pending_action = function() LockHere(target, src, from, to) end
        end
        if im.IsItemHovered(ctx) then
          im.SetTooltip(ctx, "Say that " .. group.asset .. " is HERE.\n" ..
                             "Identification will not move it again.")
        end

        im.SameLine(ctx)
        -- The line's own words in normal text between its surroundings in grey:
        -- the point of looking is what is either side of it.
        if hit.before ~= "" then
          im.TextDisabled(ctx, "\226\128\166 " .. hit.before)
          im.SameLine(ctx)
        end
        im.Text(ctx, hit.text)
        if hit.after ~= "" then
          im.SameLine(ctx)
          im.TextDisabled(ctx, hit.after .. " \226\128\166")
        end

        -- The user's own question: is this spot already spoken for?
        local occ = hit.occupant
        if occ and occ.asset and occ.asset ~= group.asset then
          im.TextColored(ctx, 0xDDAA33FF, "        already matched to " .. occ.asset)
        elseif occ and occ.asset == group.asset then
          im.TextColored(ctx, 0x66BB66FF, "        this is the current match")
        else
          im.TextDisabled(ctx, "        unmatched")
        end

        im.PopID(ctx)
      end

      im.Separator(ctx)
      im.PopID(ctx)
    end

    -- End is called only when Begin returned visible, matching the main
    -- window's loop. That is ReaImGui's contract.
    im.End(ctx)
  end
end

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
-- Remote control
-- -----------------------------------------------------------------------
--
-- A headless seam over the same handlers the buttons call, so the window can
-- be driven from another script -- tests, batch jobs, an automation bridge --
-- without a single click. Write a command, poll the serial, read the result:
--
--   reaper.SetExtState("ajsfx_vo_remote", "command", "cut", false)
--   -- "serial" bumps when the command has run; "result" holds the outcome.
--
-- The seam is these three keys and the command names; everything behind it is
-- the button handlers unchanged, so remote runs exercise the same code the
-- panels do -- including their guards and their status strings.

local REMOTE_SECTION = "ajsfx_vo_remote"
local REMOTE_HELP =
  "status | rematch | cut | pull | name_alts | sort script|record | " ..
  "set selection_only 0|1 | dupes | append script|asset|nth|text"

local function RemoteStatus()
  local c, parts = state.check or {}, {}
  parts[#parts + 1] = string.format("%d of %d lines in the project",
    c.delivered or 0, #(state.lines or {}))
  parts[#parts + 1] = string.format("missing=%d", c.missing or 0)
  parts[#parts + 1] = string.format("extra=%d", #(c.extra or {}))
  parts[#parts + 1] = string.format("rows=%d", #(state.overview or {}))
  parts[#parts + 1] = string.format("scripts=%d", #(state.scripts or {}))
  parts[#parts + 1] = string.format("selection_only=%s",
    state.selection_only and "1" or "0")
  if #(state.dupe_assets or {}) > 0 then
    parts[#parts + 1] = string.format("dupes=%d", #state.dupe_assets)
  end
  if #(state.orphan_appends or {}) > 0 then
    parts[#parts + 1] = string.format("orphan_appends=%d", #state.orphan_appends)
  end
  if #(state.name_drift or {}) > 0 then
    parts[#parts + 1] = string.format("renamed_outside=%d", #state.name_drift)
  end
  if state.message and state.message ~= "" then
    parts[#parts + 1] = "last: " .. state.message
  end
  return table.concat(parts, " | ")
end

local function RunRemoteCommand(command)
  local verb, rest = command:match("^(%S+)%s*(.*)$")

  if verb == "status" then
    return RemoteStatus()
  elseif verb == "rematch" then
    Rematch()
    return "rematched: " .. RemoteStatus()
  elseif verb == "cut" then
    DoCut()
    return state.cut_result or "cut ran with no result string"
  elseif verb == "pull" then
    Pull()
    return state.pull_result or "pull ran with no result string"
  elseif verb == "name_alts" then
    ApplyAltNames()
    return state.pull_result or state.message or "name_alts ran"
  elseif verb == "sort" then
    if rest == "script" or rest == "record" then state.layout_order = rest end
    SortOnTimeline()
    return state.message or "sort ran"
  elseif verb == "set" then
    local key, value = rest:match("^(%S+)%s+(%S+)$")
    if key == "selection_only" then
      state.selection_only = (value == "1")
      return "selection_only=" .. (state.selection_only and "1" or "0")
    end
    return "unknown setting: " .. tostring(key) .. ". Commands: " .. REMOTE_HELP
  elseif verb == "spans" then
    -- Raw memoised span table for any asset containing `rest`, with source
    -- times and lengths. Diagnostic: this is the exact input Cut works from.
    local out = {}
    for _, m in ipairs(state.matches or {}) do
      for _, s in ipairs(m.spans or {}) do
        if rest ~= "" and (s.asset or ""):find(rest, 1, true) then
          out[#out + 1] = string.format("%s k=%s %.3f..%.3f len=%.3f li=%s d=%s",
            s.asset, tostring(s.kind), s.start or -1, s.stop or -1,
            (s.stop or 0) - (s.start or 0), tostring(s.line_idx), tostring(s.deliver))
        end
      end
    end
    return #out .. " span(s)\n" .. table.concat(out, "\n")
  elseif verb == "place" then
    PlaceSelectedItems()
    return state.message or "place ran"
  elseif verb == "tighten" then
    TightenItems()
    return state.message or "tighten ran"
  elseif verb == "make_select" then
    -- Promote the take currently named `rest` to its line's Select.
    for _, row in ipairs(state.overview or {}) do
      if row.take_name == rest then
        MakeSelect(row)
        return state.message or "done"
      end
    end
    return "no row carries the take name: " .. tostring(rest)
  elseif verb == "verify" then
    -- Dialogue check on every delivered item: the words the transcript holds
    -- inside the item's source range, against the text of the line its NAME
    -- claims. No whisper run -- the transcript already knows what was said
    -- where. Catches wrong names, boundary word loss and mis-assigned takes.
    local index = vo.BuildNameIndex(state.lines or {})
    local cfg2 = vo.LoadConfig()
    local words_cache = {}
    local flagged, checked = {}, 0
    for ti = 0, r.CountTracks(0) - 1 do
      local tr = r.GetTrack(0, ti)
      for ii = 0, r.CountTrackMediaItems(tr) - 1 do
        local it = r.GetTrackMediaItem(tr, ii)
        local tk = r.GetActiveTake(it)
        if tk then
          local _, nm = r.GetSetMediaItemTakeInfo_String(tk, "P_NAME", "", false)
          if nm ~= "" and not nm:find("%.wav$") then
            local base = vo.StripAltSuffix(nm, cfg2.alt_append_pattern) or nm
            local at = vo.ResolveItemName(index, base)
            local line = at and (state.lines or {})[at]
            if line and line.text and line.text ~= "" then
              local src = r.GetMediaItemTake_Source(tk)
              local path = src and r.GetMediaSourceFileName(src, "")
              if path and path ~= "" then
                if words_cache[path] == nil then
                  local parsed = vo.ReadTranscript(path)
                  words_cache[path] = parsed and parsed.words or false
                end
                local words = words_cache[path]
                if words then
                  checked = checked + 1
                  local offs = r.GetMediaItemTakeInfo_Value(tk, "D_STARTOFFS")
                  local len  = r.GetMediaItemInfo_Value(it, "D_LENGTH")
                  local rate = r.GetMediaItemTakeInfo_Value(tk, "D_PLAYRATE")
                  if rate <= 0 then rate = 1 end
                  local a, b = offs, offs + len * rate
                  local heard = {}
                  for _, w in ipairs(words) do
                    if w.t0 < b and w.t1 > a then heard[#heard + 1] = w.text end
                  end
                  local want = vo.Tokenize(vo.Normalize(line.text))
                  local got  = vo.Tokenize(vo.Normalize(table.concat(heard, " ")))
                  local got_set, hits = {}, 0
                  for _, t in ipairs(got) do got_set[t] = (got_set[t] or 0) + 1 end
                  for _, t in ipairs(want) do
                    if (got_set[t] or 0) > 0 then
                      got_set[t] = got_set[t] - 1
                      hits = hits + 1
                    end
                  end
                  local score = (#want > 0) and hits / #want or 1
                  if score < 0.8 then
                    flagged[#flagged + 1] = string.format(
                      "%s: %d%% of the line's words heard (said: %s)",
                      nm, math.floor(score * 100 + 0.5),
                      table.concat(heard, " "):sub(1, 70))
                  end
                end
              end
            end
          end
        end
      end
    end
    return string.format("%d item(s) verified, %d flagged%s%s",
      checked, #flagged, (#flagged > 0) and "\n" or "",
      table.concat(flagged, "\n"))
  elseif verb == "missing" then
    -- Why is a line absent? Three different answers hide under "missing":
    -- never read (no match anywhere), read but the audio is not in the
    -- project (trimmed/removed since transcription), or filtered off screen.
    local out = {}
    for _, row in ipairs(state.overview or {}) do
      if row.status == "missing" then
        out[#out + 1] = string.format("NOT MATCHED  %s [%s] \"%s\"",
          row.asset or "?", row.character or "?",
          (row.line_text or ""):sub(1, 60))
      elseif row.status ~= "orphan" and not row.item
             and row.source_path and row.source_start then
        out[#out + 1] = string.format(
          "NO AUDIO     %s [%s] take %s at %.1fs in %s -- transcribed, but no item plays that stretch",
          row.asset or "?", row.character or "?", tostring(row.take_index or "?"),
          row.source_start, vo.Basename(row.source_path))
      end
    end
    return (#out == 0) and "nothing missing" or table.concat(out, "\n")
  elseif verb == "boundaries" then
    -- Cut-off word detector: an item edge landing INSIDE a transcript word
    -- means a syllable was clipped. Checks every row that resolved to an
    -- item, against the words of its own source.
    local words_cache, out, checked = {}, {}, 0
    for _, row in ipairs(state.overview or {}) do
      if row.item and row.source_path
         and r.ValidatePtr2(0, row.item, "MediaItem*") then
        local take = r.GetActiveTake(row.item)
        if take then
          local pos  = r.GetMediaItemInfo_Value(row.item, "D_POSITION")
          local len  = r.GetMediaItemInfo_Value(row.item, "D_LENGTH")
          local offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
          local rate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
          if rate <= 0 then rate = 1 end
          local a, b = offs, offs + len * rate
          if not words_cache[row.source_path] then
            local parsed = vo.ReadTranscript(row.source_path)
            words_cache[row.source_path] = parsed and parsed.words or {}
          end
          checked = checked + 1
          for _, w in ipairs(words_cache[row.source_path]) do
            local EPS = 0.005
            local function inside(t) return t > a + EPS and t < b - EPS end
            if (inside(w.t0) and w.t1 > b + EPS)
               or (inside(w.t1) and w.t0 < a - EPS) then
              -- The transcript says a word crosses this edge -- but whisper
              -- pads word ends into the following silence, so ask the AUDIO:
              -- measure 60ms just inside the edge. Quiet edge = nothing was
              -- audibly clipped, whatever the timestamps claim.
              local edge_src = (w.t0 > a + EPS) and b or a
              local probe, destroy = vo.MakeTakeProbe(take)
              local db = nil
              if probe then
                -- Project time throughout: the probe converts internally.
                local edge_proj = pos + (edge_src - offs) / rate
                local p0 = math.max(pos, math.min(edge_proj - 0.03, pos + len - 0.06))
                db = probe(p0, p0 + 0.06)
              end
              if destroy then destroy() end
              local loud = db and db > -45.0
              out[#out + 1] = string.format(
                "%s%s: \"%s\" at %s edge, %s at the edge",
                loud and "AUDIBLE " or "quiet   ",
                row.asset or "?", w.text or "?",
                (edge_src == a) and "head" or "tail",
                db and string.format("%.1f dB", db) or "unmeasured")
            end
          end
        end
      end
    end
    return string.format("%d item(s) checked, %d cut word(s)%s%s",
      checked, #out, (#out > 0) and "\n" or "", table.concat(out, "\n"))
  elseif verb == "dupes" then
    -- Line-level clashes on the RESOLVED name, script and occurrence included,
    -- so a caller has everything an `append` needs to clear one.
    local out = {}
    for _, l in ipairs(state.lines or {}) do
      for _, g in ipairs(state.dupe_assets or {}) do
        if (l.deliver or l.asset) == g.asset then
          out[#out + 1] = string.format("%s|%s|%d",
            l.script or "", l.asset or "", l.append_nth or 1)
        end
      end
    end
    return (#out == 0) and "no duplicate delivered names"
        or table.concat(out, "\n")
  elseif verb == "append" then
    local script, asset, nth, text = rest:match("^([^|]*)|([^|]*)|([^|]*)|(.*)$")
    if not script or asset == "" then
      return "append needs script|asset|nth|text (text empty to clear)"
    end
    vo.SetAppend(state.appends, script, asset, tonumber(nth) or 1, text)
    state.dirty = true
    Rebuild()
    return string.format("append %s: now %d duplicate delivered name(s)",
      asset, #(state.dupe_assets or {}))
  end

  return "unknown command: " .. tostring(verb) .. ". Commands: " .. REMOTE_HELP
end

local remote_serial = 0

local function PollRemote()
  local command = r.GetExtState(REMOTE_SECTION, "command")
  if command == "" then return end
  -- Cleared BEFORE running, so a command that errors cannot wedge the loop
  -- into retrying it every frame.
  r.DeleteExtState(REMOTE_SECTION, "command", false)

  local ok, result = pcall(RunRemoteCommand, command)
  remote_serial = remote_serial + 1
  r.SetExtState(REMOTE_SECTION, "result",
    ok and tostring(result) or ("ERROR: " .. tostring(result)), false)
  r.SetExtState(REMOTE_SECTION, "serial", tostring(remote_serial), false)
end

-- -----------------------------------------------------------------------
-- Startup and loop
-- -----------------------------------------------------------------------

LoadProjectFile()
LoadLayoutSettings()
LoadViewSettings()
Reload()

-- The action reads as ON while the window runs, and re-running it terminates
-- the instance (REAPER's default for a running ReaScript) -- so the toolbar
-- button behaves as a toggle instead of appearing to do nothing.
do
  local _, _, section_id, cmd_id = r.get_action_context()
  if cmd_id and cmd_id ~= 0 then
    r.SetToggleCommandState(section_id, cmd_id, 1)
    r.RefreshToolbar2(section_id, cmd_id)
    r.atexit(function()
      r.SetToggleCommandState(section_id, cmd_id, 0)
      r.RefreshToolbar2(section_id, cmd_id)
    end)
  end
end

local function loop()
  if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
    ctx = NewContext()
    -- A recreated context has no fonts attached at all.
    fonts, fonts_dirty = {}, true
  end

  -- Between frames, before Begin: attaching during a frame is not guaranteed to
  -- take effect for that frame.
  EnsureFonts()

  -- Project switches are handled before the rescan so a rescan can never
  -- rebuild the old project's rows against the new project's items.
  MaybeFollowProject()

  -- MaybeRescan is throttled internally; keep drawing every frame regardless.
  MaybeRescan()

  -- After the rescan, so a remote command always acts on current rows.
  PollRemote()

  FlushProjectFile(false)
  ApplyFilters()

  -- After the filters, so the follow lights rows the table is actually
  -- showing this frame.
  FollowTimelineSelection()

  im.SetNextWindowSize(ctx, 1180, 720, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'ajsfx VO Overview', true)

  if visible then
    pending_action = nil

    -- Scripts -------------------------------------------------------------
    im.Text(ctx, "Script:")
    im.SameLine(ctx)
    local n_scripts = #state.scripts
    if n_scripts == 0 then
      im.TextDisabled(ctx, "none chosen")
    else
      local label = vo.Basename(state.scripts[1].path or "")
      if n_scripts > 1 then label = label .. string.format(" +%d more", n_scripts - 1) end
      im.TextDisabled(ctx, label)
      if im.IsItemHovered(ctx) then
        local all = {}
        for _, sc in ipairs(state.scripts) do all[#all + 1] = sc.path end
        im.SetTooltip(ctx, table.concat(all, "\n"))
      end
    end

    im.SameLine(ctx)

    -- One button per panel, the open one held down. Sources and Settings are
    -- their own windows and open as they always did.
    local function PanelButton(key, label, tip)
      local on = state.panel == key
      if on then
        im.PushStyleColor(ctx, im.Col_Button, im.GetStyleColor(ctx, im.Col_ButtonActive))
      end
      if im.Button(ctx, label) then state.panel = (not on) and key or nil end
      if on then im.PopStyleColor(ctx) end
      if im.IsItemHovered(ctx) then im.SetTooltip(ctx, tip) end
      im.SameLine(ctx)
    end

    PanelButton("script", "Script",
      "The script CSVs this project reads, and which column of\n" ..
      "each holds the filename, the line and the character.")

    if im.Button(ctx, "Sources…") then
      local ok, why = vo.LaunchSibling("ajsfx_VO_Sources.lua")
      if not ok then state.message, state.message_kind = tostring(why), "error" end
    end
    im.SameLine(ctx)

    PanelButton("cut", "Cut and Name",
      "Splits every take of every decided line out of its recording\n" ..
      "and names it the script's filename. Moves nothing.")

    PanelButton("pull", "Pull",
      "Moves items onto Selects, Alts, Outs and Review tracks nested\n" ..
      "under the recording they came from, matched to the script by name.")

    PanelButton("sort", "Sort",
      "Lays the items out on the timeline in script order or record\n" ..
      "order, on fresh child tracks so nothing lands on anything.")

    if im.Button(ctx, "Settings") then state.settings_open = true end

    if     state.panel == "script" then DrawScriptPanel()
    elseif state.panel == "cut"    then DrawCutPanel()
    elseif state.panel == "pull"   then DrawPullPanel()
    elseif state.panel == "sort"   then DrawLayoutBar() end

    local bad = BadScriptCount()
    if bad > 0 then
      im.TextColored(ctx, 0xDDAA33FF, string.format(
        "%d of %d script%s is not usable, so its lines are missing.",
        bad, n_scripts, n_scripts == 1 and "" or "s"))
      im.SameLine(ctx)
      if im.Button(ctx, "Script##warn") then state.panel = "script" end
    end

    im.Separator(ctx)
    DrawSummary()
    im.Spacing(ctx)
    DrawFilters()
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
    if state.broken_pins and #state.broken_pins > 0 then
      im.TextColored(ctx, 0xDD6666FF, string.format(
        "%d hand-placed pin%s no longer resolves: %s",
        #state.broken_pins, #state.broken_pins == 1 and "" or "s",
        table.concat(state.broken_pins, "; ")))
    end
    if state.project_error ~= "" then
      im.TextColored(ctx, 0xDD6666FF, state.project_error .. "\nNothing will be saved until this is fixed.")
    end
    if state.message ~= "" then
      im.TextColored(ctx,
        state.message_kind == "error" and 0xDD6666FF
        or state.message_kind == "warn" and 0xDDAA44FF or 0x66BB66FF,
                     state.message)
    end

    -- Space is REAPER's. It used to tick the selected row's OK box here, which
    -- meant the transport would not start while this window had focus -- and
    -- this is a window you sit in WHILE listening. Ticking OK is a click.

    im.End(ctx)

    -- Drawn after the main window's End so they are siblings, not children.
    DrawSettingsWindow()
    DrawCandidatesWindow()

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
