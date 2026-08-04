-- @description ajsfx VO Overview
-- @author ajsfx
-- @version 0.12
-- @changelog The VO tools are now three windows instead of one. "ajsfx VO Sources" lists every recorded file in the project and whether it has been transcribed; double-click a file to read its transcript, hear where each word sits, and re-transcribe just that file. "ajsfx VO Overview" is now the front door: it derives the match from the stored transcripts every time, so swapping the script CSV re-matches instantly with no re-transcription, and a new Select column records which take you are delivering. "ajsfx VO Cut" does the cutting, and it now places clip edges by looking for silence in the gap between the words either side, so an edge can never contain a syllable of the neighbouring line; the old fixed 150/250 ms pads become the furthest an edge may travel and the noise floor is measured from the recording rather than assumed. Transcription is now stored per wav file as word-level timings in "<audio>_vo_transcript.csv", so copying a recording and its sidecar to another project carries the transcription with it. Your selects, verified marks, notes and renames live in "<project>_vo.csv" beside the project. Transcription no longer conditions each window on the text it just decoded, which on a long read could lock the transcriber into repeating one phrase for the rest of the file; if an existing transcript contains such a loop, "ajsfx VO Sources" now flags it and says where it starts. Every column in Overview now sorts on a header click and filters from a box under the header, there is a new "#" column carrying each line's position in the script, and spacebar is REAPER's again -- it starts the transport instead of ticking the selected row. Matching now weighs where a line falls in the read: a line too short to identify itself -- one that is just "You." matches every "you" in the recording -- is sent to review when it contradicts the order the rest of the read was in, rather than being named on the strength of one word. Right-click a row (or a selection of rows) for "Find candidates": every place in the transcripts that line could sit, with what was said either side of it, what already occupies that spot, and a click to select it on the timeline and put the play cursor there. It is a search only -- it changes nothing. When you find a placement yourself you can lock it there: press "Lock here" beside a result in Find candidates, or make a time selection in REAPER over the audio and right-click the row for "Lock to time selection". A lock is stored in "<project>_vo.csv" against the recording rather than the timeline, so it survives the item being moved, and ajsfx VO Cut cuts what you locked. Untick Lock to hand the take back. Matching is substantially more accurate: a window is now scored as it is finally kept rather than as it was proposed (a line could lose its opening words and a quarter of its score when the recogniser fused two words together), placements are considered longest and most confident first so a one-word line can no longer cut a twelve-word line in half, and a second pass gives any line that lost every window a look at the audio nothing claimed. Transcription no longer discards a stretch as non-speech unless it is almost certainly not speech -- the default threshold threw away 29 seconds of a real read, four script lines, at full level and with no error anywhere. The OK column is now Lock: ticking it freezes the take where it is, and a new Rematch button identifies everything again from scratch while leaving locked takes alone -- so you can work through a session settling lines, re-transcribe or edit the script, and keep what you already settled. A lock speaks only for its own take, so locking one take of three leaves the other two where they were. "Select takes" marks one take of every line as the select, last or first, and skips locked lines. NOTE: this replaces "ajsfx VO ScriptMatch", which has been removed — reinstall from ReaPack, and re-transcribe your recordings, as the old report files are not read. Matching now understands that where a word break falls is a spelling decision, not a difference in what was said: a line written "Some day it will be you" and a read heard as "Someday, it'll be you" are now a full match instead of a two-thirds one, and the take keeps its opening word instead of having it trimmed off the front. Takes are grouped by script line rather than by delivered filename, so a script that names two different lines with one filename no longer shows each of them the other's takes; that collision is now reported in Overview's summary and again in ajsfx VO Cut, since the two lines would still be delivered over each other -- only the script can fix it. Cut clips no longer run together. Whisper ends each word exactly where the next one starts, so the pause around a take was carried INSIDE the take's own span -- the first word held the silence before it and the last word the silence after -- and edge snapping, which only ever searched outward, had nowhere to go. Every clip was cut from the previous take's last syllable to the next take's first, tiling the recording with no breaks at all. Each take is now trimmed in to where the sound actually is before the pad is applied outward, so a clip holds its own line with a little air either side. Takes whose word timings are already tight are padded exactly as before. The Choose… button now opens in the project's own folder instead of REAPER's resource folder. A filename shared by two script lines no longer reads as an error: cutting only names items, and two items in REAPER may share a name, so the clips cut fine -- it is noted because the clash becomes real later, when they are rendered to files. ajsfx VO Cut's check that every line with several takes has a select now counts by script line rather than by filename, so a select ticked on one of two lines sharing a name no longer answers for the other, and the alts track no longer pulls one line's spare takes under the other. A project can now read more than one script CSV. Press "Script" for the list: add a CSV, switch one off without removing it, and map each script's own Filename, Line text and Character columns -- a character who recorded lines from three scripts is one session again. The "Choose..." button is gone; "Script" replaces it, and the old Columns... panel now lives inside it, one row per script. A new "Script" column says which CSV a line came from. When two script lines ask to be delivered under the same filename -- whether they come from two scripts or from two rows of one -- the filename turns red and so does a new "Append" column beside it. Type anything in Append and it goes on the end of the delivered name, with no separator added, so you choose it: type "_ch2" and the line delivers as "line_042_ch2". Both lines go back to normal as soon as their names differ. Renaming a take by hand does the same job, and a rename that recreates a clash turns red too. Nothing is ever renamed for you. ajsfx VO Cut reads the whole script list and cuts with the appended names. The script list now lines every row up on the same columns, so a long filename no longer pushes one script's column pickers out of line with another's, and "Add script..." takes several CSVs in one go where js_ReaScriptAPI is installed. Scripts can be reordered with the arrows beside each one, and that order is the line order: every line of the first script comes before every line of the second, so where two scripts could each claim to come first, the list says which does. A line is now identified by its position across the whole list rather than by its row number inside its own CSV, which two scripts can share: with more than one script loaded, "Reorder on timeline" in script order no longer interleaves the two scripts' lines, Find candidates no longer answers with the first script's line of that number, and ajsfx VO Cut no longer groups two different lines together because they sat on the same row of different CSVs. Overview also opens the way you left it: the character filter, the status filter, the search box, the per-column filters and whether the filter row is showing are all stored in the project file, so closing the window no longer throws them away. A character filter that no longer matches anything -- because the script changed -- is dropped rather than leaving you with an empty table and no reason for it.
-- @about ajsfx VO — script-matched cut-and-name for game VO and dialogue
--        delivery. Transcribe your recordings once in "ajsfx VO Sources", see
--        every script line and every take in "ajsfx VO Overview", tick the
--        takes you are delivering, and cut them in "ajsfx VO Cut". Runs fully
--        locally with whisper.cpp; configure the backend in "ajsfx VO
--        Settings". See VO/SPEC.md.
-- @provides
--   [main] .
--   [main] ajsfx_VO_Sources.lua
--   [main] ajsfx_VO_Cut.lua
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
  { key = "select",     label = "Select",     width =  60,
    text = function(row)
      if row.status == "missing" or row.status == "orphan" then return "" end
      -- The filter box matches what the cell says, so the words are the marks
      -- themselves rather than yes/no: filtering for "alt" finds the alts.
      return row.user_mark == "select" and "select"
          or (row.user_mark == "alt" and "alt" or "")
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

local STATUS_FILTERS = {
  { key = "all",       label = "All" },
  { key = "missing",   label = "Missing" },
  { key = "review",    label = "Needs review" },
  { key = "orphan",    label = "Orphans" },
  { key = "unverified",label = "Not yet verified" },
  { key = "verified",  label = "Verified" },
  { key = "flagged",   label = "Flagged" },
}

local STATUS_BY_KEY = {}
for _, f in ipairs(STATUS_FILTERS) do STATUS_BY_KEY[f.key] = f end

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
  cut_summary   = {},         -- what the last Cut and Name run did
  appends       = {},         -- vo.SetAppend records, per script line
  dupe_names    = {},         -- vo.DuplicateNames set, for the red highlight
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

  status_filter = "all",
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

  local proj = ProjectPath()
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
    if v.status and STATUS_BY_KEY[v.status] then state.status_filter = v.status end
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
    { scripts = state.scripts, appends = state.appends, pins = state.pins,
      view = {
        status      = state.status_filter,
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

-- blank -> select -> alt -> blank.
--
-- Exactly one take of a line may be the SELECT, so marking one clears the rest
-- of its group. Without this the project file could hold two selected rows for
-- one filename and BuildOverview would silently pick whichever the build order
-- put first (see vo.BuildOverview's "no first/last fallback").
--
-- Any number may be ALTS: an alt is an extra delivery, not a competing answer
-- to the question of which take the delivery is.
local NEXT_MARK = { [false] = "select", select = "alt", alt = false }

local function SetMark(row, mark)
  if mark == "select" then
    for _, other in ipairs(state.overview) do
      if other ~= row and other.asset == row.asset and other.status ~= "orphan"
         and other.user_mark == "select" then
        Mutate(other, function(e) e.select = nil end)
      end
    end
  end
  Mutate(row, function(e) e.select = mark or nil end)
end

local function CycleMark(row)
  SetMark(row, NEXT_MARK[row.user_mark or false])
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
  local clean = vo.SanitizeName(row.deliver or row.asset or "")
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
    if row.user_mark ~= "select" then
      SetMark(row, "select")
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

-- Why cutting must not run, or "" when it may. Two refusals, both about
-- acting on something the user has not decided or that is no longer true.
local function CutGate()
  local stale = {}
  for _, path in ipairs(vo.ProjectSourcePaths(state.items) or {}) do
    if vo.TranscriptState(path) == "stale" then stale[#stale + 1] = vo.Basename(path) end
  end
  if #stale > 0 then
    table.sort(stale)
    return "Audio changed since it was transcribed — re-transcribe in " ..
           "ajsfx VO Sources before cutting:\n" .. table.concat(stale, ", ")
  end

  -- Every LINE with more than one take needs the decision SEL exists to
  -- record. Keyed by script row, not by filename: a script can name two lines
  -- with one filename, and keying on the name would let a SEL on one line
  -- answer for the other.
  local by_line = {}
  for _, row in ipairs(state.overview) do
    if row.status ~= "orphan" and row.status ~= "missing" and row.asset then
      local key = row.script_row or row.asset
      local b = by_line[key]
      if not b then b = { count = 0, selected = false, asset = row.asset }; by_line[key] = b end
      b.count = b.count + 1
      if row.user_mark == "select" then b.selected = true end
    end
  end

  local any, unresolved, names = false, 0, {}
  for _, b in pairs(by_line) do
    if b.selected then any = true end
    if b.count > 1 and not b.selected then
      unresolved = unresolved + 1
      names[#names + 1] = b.asset
    end
  end

  if not any then
    return "Nothing is marked SEL. Click the Select cell on the takes you want cut."
  end
  if unresolved > 0 then
    table.sort(names)
    return string.format("%d line(s) have several takes and no SEL yet.", unresolved)
        .. "\n" .. table.concat(names, ", ")
  end
  return ""
end

local function DoCut()
  local cfg = vo.LoadConfig()

  -- Every span from every source, tagged with the path it came from.
  local all_spans = {}
  for _, m in ipairs(state.matches or {}) do
    for _, s in ipairs(m.spans or {}) do
      s.source_path = m.path
      all_spans[#all_spans + 1] = s
    end
  end

  -- The row carries the user's mark; the span is what gets cut. The flag makes
  -- the crossing here, once, before naming.
  for _, row in ipairs(state.overview) do
    if row.source_path and row.source_start ~= nil then
      for _, s in ipairs(all_spans) do
        if s.source_path == row.source_path
           and math.abs((s.start or 0) - row.source_start) < 1e-6 then
          s.select = row.user_mark == "select"
          break
        end
      end
    end
  end

  -- Lines the user has decided. EVERY take of such a line is cut, not just the
  -- SEL: the alts are deliveries too, and the takes marked neither are what
  -- Pull puts on Outs. A line nobody has decided is cut by nothing here -- the
  -- gate above already refused the run.
  local decided = {}
  for _, row in ipairs(state.overview) do
    if row.user_mark == "select" and row.asset then
      decided[row.script_row or row.asset] = true
    end
  end
  local function line_key(s)
    local l = s.line_idx and (state.lines or {})[s.line_idx]
    if l and l.asset == s.asset then return l.index or l.row end
    return s.asset
  end

  local candidates = {}
  for _, s in ipairs(all_spans) do
    if s.kind == "match" then
      if s.select or (s.asset and decided[line_key(s)]) then
        candidates[#candidates + 1] = s
      end
    elseif s.kind == "review" then
      candidates[#candidates + 1] = s
    end
  end

  -- Name before converting: vo.AssignNames sorts each asset's takes by `start`
  -- to number them, and source time is the one base every span shares.
  vo.AssignNames(all_spans, cfg)

  -- Resolve each candidate against the live item that plays it, in project
  -- time. A span no current item covers any more is dropped and counted rather
  -- than cut against silence.
  local skipped_msgs, by_item = {}, {}
  for _, s in ipairs(candidates) do
    local item, proj_start, info = vo.ResolveSourceTime(s.source_path, s.start, state.items)
    if not item then
      skipped_msgs[#skipped_msgs + 1] = string.format("%s: no item covers %.3fs in %s",
        s.name or s.asset or "(unnamed)", s.start or 0, vo.Basename(s.source_path))
    else
      s.start = proj_start
      s.stop  = vo.SourceTimeToProject(s.stop, info)
      local g = by_item[item]
      if not g then
        g = { item = item, info = info, spans = {} }
        by_item[item] = g
      end
      g.spans[#g.spans + 1] = s
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
  local pad_fallbacks = 0
  for _, g in pairs(by_item) do
    table.sort(g.spans, function(a, b) return (a.start or 0) < (b.start or 0) end)

    local take = r.GetActiveTake(g.item)
    local probe, destroy = vo.MakeTakeProbe(take)
    local ok, err = pcall(function()
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
    destroy()   -- ALWAYS, including on the error path: the accessor holds the file open
    if not ok then error(err) end

    for _, s in ipairs(g.spans) do
      if s.snapped == "pad" then pad_fallbacks = pad_fallbacks + 1 end
    end
  end

  -- One transaction around every split and rename, so the run is one undo step.
  local applied, failures = 0, {}
  core.Transaction("VO Overview: cut and name", function()
    for _, g in pairs(by_item) do
      local a, f = vo.ApplyPlan(g.spans, cfg, g.info.track)
      applied = applied + a
      for _, msg in ipairs(f) do failures[#failures + 1] = msg end
    end
  end)

  state.cut_summary = vo.FormatCutSummary(all_spans, applied, skipped_msgs, failures)
  if pad_fallbacks > 0 then
    state.cut_summary[#state.cut_summary + 1] = {
      text = string.format(
        "%d clip edges fell back to the fixed pad — no silence found in the gap.",
        pad_fallbacks),
      warn = true,
    }
  end
  state.message, state.message_kind =
    string.format("Cut and named %d clip(s). Press Pull to route them.", applied), "ok"
  Reload()
end

local function DrawCutPanel()
  im.Separator(ctx)
  im.TextWrapped(ctx,
    "Splits every take of every decided line out of its recording and names it " ..
    "the script's filename. Nothing moves: press Pull afterwards to route the " ..
    "takes onto their tracks.")
  im.Spacing(ctx)

  local blocked = CutGate()
  if blocked ~= "" then
    im.TextColored(ctx, 0xDDAA33FF, blocked)
    im.Spacing(ctx)
    im.BeginDisabled(ctx, true)
    im.Button(ctx, "Cut and Name")
    im.EndDisabled(ctx)
  elseif im.Button(ctx, "Cut and Name") then
    pending_action = DoCut
  end
  im.SameLine(ctx)
  if im.Button(ctx, "Close##cut") then state.panel = nil end

  for _, line in ipairs(state.cut_summary or {}) do
    if line.warn then im.TextColored(ctx, 0xDDAA33FF, line.text)
    else im.TextDisabled(ctx, line.text) end
  end

  im.Separator(ctx)
end

local function DrawFilters()
  -- Every control here writes state.dirty: the filters are stored in the project
  -- file so the table opens the way it was left. The flush is throttled, so a
  -- filter box being typed into does not write a file per keystroke.
  Combo("##status", 130, STATUS_FILTERS, state.status_filter,
        function(k) state.status_filter = k; state.dirty = true end)
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

    -- Select --------------------------------------------------------------
    im.TableSetColumnIndex(ctx, CI.select)
    if row.status ~= "missing" and row.status ~= "orphan" and (row.take_count or 0) > 0 then
      CellWidget("select", row_h)
      -- A button, not a checkbox: the mark has three states and a checkbox can
      -- only show two.
      local mark  = row.user_mark
      local label = mark == "select" and "SEL" or (mark == "alt" and "ALT" or "--")
      if im.Button(ctx, label .. "##sel", -1, 0) then
        pending_action = function() CycleMark(row) end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx,
          "Click to cycle: unmarked -> SEL -> ALT -> unmarked.\n\n" ..
          "SEL is the take you are delivering; ALT is delivered as well,\n" ..
          "under its own name. One SEL per line, any number of ALTs.\n" ..
          "Everything unmarked is kept but not delivered.")
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
-- Startup and loop
-- -----------------------------------------------------------------------

LoadProjectFile()
LoadLayoutSettings()
LoadViewSettings()
Reload()

local function loop()
  if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
    ctx = NewContext()
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

    if im.Button(ctx, "Settings") then state.settings_open = true end

    if     state.panel == "script" then DrawScriptPanel()
    elseif state.panel == "cut"    then DrawCutPanel() end

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
      im.TextColored(ctx, state.message_kind == "error" and 0xDD6666FF or 0x66BB66FF,
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
