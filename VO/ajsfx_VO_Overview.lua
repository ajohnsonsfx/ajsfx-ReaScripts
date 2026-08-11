-- @description ajsfx VO Overview
-- @author ajsfx
-- @version 0.15beta6
-- @changelog PRE-RELEASE: the toolbar is three tabs -- Setup, Edit and Settings -- and a tab never does anything: it only decides which buttons you are looking at, while every button under it acts. Edit leads with "Run the whole pass" (match, cut, pick, pull, in one undo step) above one row per step of the same name -- Match, Cut, Pick, Pull -- plus Check, the phase the batch button cannot run for you. EVERY verb now acts on the selection -- rows picked in the sheet, items picked in REAPER, or both -- and a line under the hero says what the next press will act on. Selecting an uncut recording selects every take inside it, so one rule reads correctly before and after the cut. The per-panel "Selected rows only" checkboxes are gone. "Find lines in items", "Assign items to lines" and "Adopt this whole session" are ONE button, "Identify the lines in these items": they differed only in what shape the audio was in, which the tool now counts for itself -- an item holding one take is marked at your own edges and named for its line, an item holding several gets a marker per take and no name. A take marker is now what the cut WILL be: Identify writes markers through the same speech-bounds and padding pass Cut uses, and Cut cuts TO the marker instead of skipping any span a marker overlapped -- which would have made Identify followed by Cut cut nothing at all. A marker you drag is honoured the same way; "Re-cut from the transcript" throws marker edges away and derives them from the words again. New: "Trim items to their markers" sets each item's edges to the take marker inside it -- the manual half of "the marker is what the cut will be" -- with a per-row form in the take menu beside "Snap marker to item". Also new: "Build the destination tracks" makes Selects/Alts/Review under each recording without moving anything, so they exist before the first pull. "Cut recording into takes" cuts on the press; its panel is now the report the run opens by itself. "Auto-pick selects" and "Auto-name the alts" join "Auto-adjust head and tail" as the Auto- family: each is the batch form of a per-row sheet gesture. Auto-adjust now moves the take marker with the edges it trims. Buttons wrap rather than running off a narrow window, and the ribbon holds one height so the sheet no longer jumps when you click between tabs. "Start over..." in Setup deletes this project's VO data, behind a confirm that names what goes and what stays. The blank sheet now asks for the two things it needs -- a script and a transcript -- with a button for each.
--   "Not on the script" is a queue instead of a dead end: right-click any orphan to hand it to a script line (best guesses first, scored against what was actually said) or dismiss it as junk, which is remembered and leaves the count -- so "0 orphans" now means every span has been looked at. Each orphan says why it is one. Matching ranks candidates by tokens of agreement rather than by score, so a short line matched perfectly no longer takes the words out of the middle of a long one. A transcript is drawn in one colour with the EXTRA words -- what the reader said that the line does not contain -- in amber; the colour used to encode a match threshold nobody could see. Notes are gone from the cards. A reader going again is no longer reported as a transcriber loop. In Sources: single-click opens a file's detail, "Copy report" puts everything on the clipboard, reported timecodes are clickable links that move the edit cursor, and a transcript can be deleted from the panel. "Find lines in items" honours the REAPER selection. Fixed: a race that reported "whisper-cli exited with code -1" on runs that had barely started.
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
  -- A take added by hand before its audio exists (see vo.PlannedKey): a place
  -- to hang notes and marks until an item is linked to it.
  planned  = { label = "Planned",  colour = 0x7FA0C0FF },
}

-- Words the take has that its line does not. Amber, not red: an extra word is
-- something to look at, not an error, and red is spoken for.
local EXTRA_WORD = 0xDDAA33FF

-- Which script lines an orphan's words could be, memoized on the words.
-- Declared here, far from its one reader (OrphanLineHits), because Rebuild
-- must be able to CLEAR it: the answer depends on the loaded script lines,
-- and a memo keyed only on the words would keep offering hits from a script
-- that has since been swapped out.
local orphan_hits_memo = {}

-- vo.ExtraWords is an LCS over two token streams: cheap per row, and not free
-- across five hundred of them every frame.
--
-- Cached ON THE ROW, not in a table keyed by the texts. The keyed version cost a
-- string concat and a hash of the whole line-plus-transcript for every row of
-- every frame -- five hundred fresh strings sixty times a second, which is
-- garbage the collector then has to chase. The row is already the right
-- lifetime: a rebuild makes new rows, so the cache clears exactly when the
-- answer could have changed.
--
-- `_extra_clean` is the fast path's flag, computed once here rather than
-- re-scanned per frame: true when nothing in this take is extra, which is most
-- takes, and lets the drawing side stay one wrapped Text call.
local function ExtraRuns(row)
  local hit = row._extra_runs
  if not hit then
    hit = vo.ExtraWords(row.line_text or "", row.transcript or "")
    local clean, text = true, {}
    for _, run in ipairs(hit) do
      if run.extra then clean = false end
      text[#text + 1] = run.text
    end
    -- The fast path draws one string, and it has to be the SAME string the
    -- slow path would have drawn word by word -- ExtraWords re-spells paired
    -- words with the line's capitalisation, so row.transcript is no longer it.
    row._extra_runs, row._extra_clean = hit, clean
    row._extra_text = table.concat(text, " ")
  end
  return hit
end

-- Defined here rather than beside the other UI helpers because the column
-- accessors below need it.
local function FormatTime(t)
  if not t then return "" end
  local m = math.floor(t / 60)
  return string.format("%d:%06.3f", m, t - m * 60)
end

-- Six questions across the top; the parent row answers each for the LINE and
-- the take rows answer it for the TAKE, so every cell is correlated with the
-- cell above it. State is one visual group over four physical columns: the
-- status dot plus the Lock/Sel/Alt checkboxes, labelled once per expanded
-- line by a slim sub-header row rather than in the frozen header.
--
--   text  what a column's filter box (and the search) matches against. It sees
--         take rows and line reps alike, so it folds both levels' fields.
--         A column without it has no filter box: there is nothing there a
--         user could have meant.
-- Display sorting is gone on purpose: the table is always in script order,
-- and the timeline is arranged by the Sort tool, not by the display.
-- Forward-declared: accessors close over it; assigned once state exists.
local DELIVERY

local COLUMNS = {
  { key = "order", label = "#",     width =  48, nofilter = true,
    tip = "Line: its position in the script, and the arrow that folds its\n" ..
          "takes. Take: the take number." },
  { key = "state", label = "State", width =  24, nofilter = true,
    tip = "Line: status dot, delivered count, and what still needs deciding.\n" ..
          "Take: status dot. Hover any dot for the words." },
  { key = "sel",   label = "",      width =  30, nofilter = true },
  { key = "keep",  label = "",      width =  30, nofilter = true },
  { key = "lock",  label = "",      width =  30, nofilter = true },
  { key = "text",  label = "Text",  width = 260, stretch = 2.0,
    text = function(row) return (row.line_text or "") .. " " .. (row.transcript or "") end,
    tip = "Line: what the script says. Take: what was actually said,\n" ..
          "directly beneath it for comparison." },
  { key = "name",  label = "Name",  width = 190,
    text = function(row)
      return (row.take_name or row.name_override or "") .. " "
          .. (row.deliver or row.asset or "")
    end,
    tip = "Line: the delivered name (CSV filename + Append, dimmed).\n" ..
          "Take: the item's own name. Editable on takes; right-click the\n" ..
          "line's name to edit its Append." },
  { key = "where", label = "Where", width = 140,
    text = function(row)
      return (row.script or "") .. " "
          .. (row.source_path and vo.Basename(row.source_path) or "")
    end,
    tip = "Line: which script CSV, and its row.\nTake: which recording, and when." },
}

local COLUMN_BY_KEY = {}
for _, c in ipairs(COLUMNS) do COLUMN_BY_KEY[c.key] = c end

-- Every column key, in declaration order. Used to load, save and clear the
-- per-column settings without anything having to restate the list.
local function ColumnKeys()
  local keys = {}
  for i, c in ipairs(COLUMNS) do keys[i] = c.key end
  return keys
end

-- The toolbar's groups. A tab decides which buttons are on screen and does
-- nothing else; the buttons under it do the work.
--
-- TWO tabs, deliberately, and Edit is crowded. Sheet / Items / Fix a line were
-- three tabs drawn along a domain boundary nobody has found yet, and the cost
-- landed on the work: matching, cutting and fixing happen in one breath, and
-- every guess at the boundary put a tab switch in the middle of it. One full
-- row you can read beats three tidy ones you have to page through. Split it
-- again when the domains are known, not before.
local TOOLBAR_TABS = {
  { key = "setup", label = "Setup" },
  { key = "edit",  label = "Edit" },
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
  -- Which toolbar tab's buttons are showing. Items is the default because it
  -- is where the work happens; Setup is a once-per-project errand.
  tab           = "edit",     -- see TOOLBAR_TABS
  tab_sync      = 4,          -- frames left to push state.tab into the tab bar
  cut_summary   = {},         -- what the last Cut and Name run did
  -- The Cut panel's stage counts, memoised. Worked out from the same code the
  -- run uses, so what it says and what it does cannot drift apart.
  cut_result     = nil,       -- what the last run said, shown in the panel
  pull_result    = nil,       -- the same, for the Pull panel
  pull_result_kind = "ok",
  cut_result_kind = "ok",
  -- Takes the last Cut refused to touch because their items had been
  -- hand-edited, by delivered name. Non-empty is what puts the Re-cut anyway
  -- button on screen; force_recut is the one-shot override it arms.
  cut_skipped_edited = {},
  force_recut   = false,
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
  transcripts   = {},         -- { path, words } per source, for marker row text
  visible       = {},         -- after filters
  summary       = {},

  scanned_at    = -1,         -- GetProjectStateChangeCount when rows were built
  last_rescan   = 0,

  selection     = {},         -- set of row UIDs, spreadsheet-style
  focus_key     = nil,        -- the row the caret is on
  anchor        = nil,        -- row UID a shift-range extends from

  -- How the sheet follows clicks in the ARRANGE view (the Follow menu).
  -- Loaded from ExtState below; these are user preferences, not project state.
  follow_scroll = true,       -- bring the selected take on screen
  follow_unfold = true,       -- unfold the line that holds it
  follow_fold   = false,      -- fold it back again once deselected
  -- Which lines the FOLLOW unfolded (vs the user), keyed by line key: the
  -- auto-fold option folds only these, so a card the user opened by hand is
  -- never snapped shut under them.
  auto_unfolded = {},
  -- How many more frames the scroll-to may fire. Two, not one: the frame that
  -- unfolds a line draws its rows at fallback heights, so a scroll computed
  -- then can land a little off; the second frame corrects against measured
  -- heights, and is a no-op when the first already got it right.
  scroll_to_frames = 0,

  layout_order   = "script",  -- "script" | "record"
  layout_spacing = "fixed",   -- "fixed"  | "original"
  layout_gap     = 2.0,
  layout_src_gap = 60.0,

  auto_select_take = "last",  -- which take "Select takes" marks; from the config

  -- Lines unfolded OPEN, keyed by LineNodeKey -- folded is the default, so
  -- the sheet opens as a tidy list of title bands. Persisted in the project
  -- file's view section: a reopened project looks the way it was left.
  expanded      = {},
  nodes         = {},         -- the filtered draw list: vo.FilterGroups output
  filtered      = {},         -- every take the filters admit; tool scope

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
  view          = { restore = true, sizes = {}, cols = {} },
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
    if sc.error and sc.error ~= "" then
      state.tab, state.panel, state.tab_sync = "setup", "script", 4
    end
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
  state.expanded = {}
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
    state.expanded = {}
    for _, k in ipairs(v.expanded or {}) do state.expanded[k] = true end
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

  local entries = vo.ProjectEntriesFromRows(state.overview)
  local ok = WriteFileAtomic(path, vo.SerializeProjectFile(
    entries,
    { scripts = state.scripts, appends = state.appends, pins = state.pins,
      view = {
        character   = state.character,
        search      = state.search,
        filter_row  = state.filter_row,
        col_filters = state.col_filters,
        expanded    = (function()
          local out = {}
          for k in pairs(state.expanded or {}) do out[#out + 1] = k end
          table.sort(out)
          return out
        end)(),
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

  -- Kept on state, not just handed to BuildMatch: this function is memoised on
  -- the match key and returns early on a hit, so a local would be gone by the
  -- time the rebuild after it needs the words for its marker rows.
  state.transcripts = transcripts
  state.matches     = vo.BuildMatch(transcripts, state.lines or {}, cfg, state.pins)
  state.match_key   = key

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
  -- The cards paint their chrome from LAST frame's measured heights, but a
  -- rebuild replaces every row object -- and with them the measurements. Every
  -- rebuild then repainted the whole sheet one frame at guessed heights before
  -- snapping back: a visible flicker on every project edit, once per throttle
  -- window, for as long as the user worked. Snapshot the measurements here and
  -- restore them onto the new rows below; uids are stable across rebuilds, so
  -- each row gets its own height back and the repaint is seamless.
  local old_h = {}
  for _, row in ipairs(state.overview or {}) do
    if row.uid then
      old_h[row.uid] = { row._card_h, row._band_h, row._card_full_h }
    end
  end

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

  -- Markers are the truth: whatever they say a line's takes are, the sheet
  -- shows, and the match's opinion of that line is ignored. Collected before
  -- BuildOverview so marker rows are first-class.
  state.take_markers = vo.CollectTakeMarkers(state.items)
  local takes_by_asset, marker_info = {}, {}
  for path, group in pairs(state.take_markers) do
    for _, mk in ipairs(vo.CountingMarkers(group)) do
      -- The path the markers were collected under, carried onto the marker so
      -- BuildOverview can ask the match what was said in that range. A marker
      -- is a position and a name; the words live in the transcript.
      mk.source_path = path
      takes_by_asset[mk.asset] = takes_by_asset[mk.asset] or {}
      table.insert(takes_by_asset[mk.asset], mk)
      marker_info[mk.id] = group[mk.item_index] and group[mk.item_index].info
    end
  end
  state.marker_info = marker_info

  local matches = LoadMatches(cfg)
  state.overview = vo.BuildOverview({
    lines   = state.lines,
    matches = matches,
    entries = state.entries,
    cfg     = cfg,
    takes_by_asset = takes_by_asset,
    -- LoadMatches is hoisted above the constructor because it is what FILLS
    -- state.transcripts, and the order a table constructor evaluates its
    -- fields in is not something to rely on.
    transcripts = state.transcripts,
  })

  -- Marker rows resolve straight to the item holding their counting marker:
  -- no occupancy guessing, which is the point. Before the adoption pass so an
  -- already-resolved row never adopts a name-match it does not need.
  for _, row in ipairs(state.overview) do
    if row.marker_id then
      local info = marker_info[row.marker_id]
      if info then
        row.item        = info.item
        row.item_info   = info
        row.source_path = info.path
      end
    end
  end
  state.summary = vo.SummarizeOverview(state.overview)

  -- Two answers the header row was recomputing from all five hundred rows on
  -- every frame: the character droplist (a full scan, a set, and a SORT) and
  -- the select conflicts. Neither can change without a rebuild -- a tick goes
  -- through Mutate, which rebuilds -- so they are computed here, once, with the
  -- rest of the derived state.
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
  state.characters = chars
  -- The orphan right-click's hits depend on the script lines, which a rebuild
  -- can have changed; stale hits would offer lines from a swapped-out script.
  orphan_hits_memo = {}

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

        -- The copy takes the line's SHAPE, never the template's DECISIONS.
        -- Copying the marks meant that whenever the template happened to be the
        -- line's Sel, every adopted item was born ticked -- and Pull, reading
        -- the mark, sent them all to Selects under the one delivered name. Two
        -- items cannot both be the delivery; this row is an unidentified take
        -- until somebody says otherwise.
        row.user_select, row.user_keep, row.is_primary = false, false, false
        row.user_status, row.name_override, row.notes = nil, nil, nil

        -- And its own key, keyed to the ITEM, so a tick put on it later is
        -- stored against this take rather than written over the one it was
        -- copied from. A row with no span cannot be keyed by source time.
        local got, guid = r.GetSetMediaItemInfo_String(extra_item, "GUID", "", false)
        if got and guid ~= "" then row.key = "|" .. (row.asset or "") .. "|" .. guid end

        table.insert(state.overview, at + 1, row)
      end
    end
  end

  -- Where each row's item actually sits, and what that says about its marks.
  --
  -- Runs last, after every path that can give a row an item (anchor, span,
  -- name adoption, extra rows), so no row is judged on a track it has not been
  -- resolved onto yet.
  local track_name_of = {}
  for _, row in ipairs(state.overview) do
    if row.item then
      local gok, gguid = r.GetSetMediaItemInfo_String(row.item, "GUID", "", false)
      if gok and gguid ~= "" then row.item_guid = gguid end
      local track = r.GetMediaItem_Track(row.item)
      if track then
        local cached = track_name_of[track]
        if cached == nil then
          local _, tname = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
          cached = tname or ""
          track_name_of[track] = cached
        end
        row.track_name = cached
      end
    end
    local marks = vo.EffectiveMarks(
      { select = row.mark_select, keep = row.mark_keep }, row.track_name, cfg)
    row.user_select, row.user_keep = marks.select, marks.keep
  end

  -- Derived AFTER the marks and track names above, because both read them --
  -- conflicts through user_select, the reconcile plan through track_name.
  -- Computed here rather than per frame: the toolbar shows their counts, and
  -- nothing can change either without coming back through Rebuild.
  state.conflicts = vo.SelectConflicts(state.overview)
  state.reconcile = vo.PlanReconcile(state.overview, cfg)

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

    local h = old_h[row.uid]
    if h then
      row._card_h, row._band_h, row._card_full_h = h[1], h[2], h[3]
    end
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
  -- No `select = false` here. Marks are tri-state now: false is an explicit NO
  -- the user typed, and a fresh entry has no opinion at all -- being born with
  -- one would stop the item's own track from ever speaking for it
  -- (vo.EffectiveMarks), which is the whole self-healing mechanism.
  local e = {
    key = row.key, source = row.source_path, source_start = row.source_start,
    asset = row.asset,
  }
  state.entries[#state.entries + 1] = e
  return e
end

-- Rebuild() is the whole sheet: every source re-matched, every row rebuilt.
-- One write deserves one rebuild, but a BULK action writing a mark per line
-- was paying for a rebuild per line -- a few hundred of them over five hundred
-- rows for one press of "Pick a take for each line", which is why it crawled.
-- Batch() collects the writes and rebuilds once at the end.
local batch_depth = 0

local function Mutate(row, fn)
  fn(EntryFor(row))
  state.dirty = true
  if batch_depth == 0 then Rebuild() end
end

-- Run `fn` with rebuilds deferred, then rebuild once. Nestable, and a rebuild
-- still happens if `fn` throws: the entries have already been written by then,
-- so leaving the sheet stale would show the user the state BEFORE a change
-- that did land.
local function Batch(fn)
  batch_depth = batch_depth + 1
  local ok, err = pcall(fn)
  batch_depth = batch_depth - 1
  if batch_depth == 0 then Rebuild() end
  if not ok then error(err, 0) end
end

-- All marker ids currently in the project, so minting can never collide.
local function TakenMarkerIds()
  local taken = {}
  for _, group in pairs(state.take_markers or {}) do
    for _, rec in ipairs(group) do
      for _, m in ipairs(rec.markers or {}) do
        local _, id = vo.ParseMarkerName(m.name)
        if id then taken[id] = true end
      end
    end
  end
  return taken
end

-- Write a take marker for this row's line onto the item selected in REAPER,
-- spanning that item's current source coverage. The manual counterpart to the
-- markers kickstart writes: for audio this tool did not create -- a hand-comp,
-- a rendered file, a re-record -- and the repair panel's Relink.
--
-- If the row was marker-keyed or planned, its marks move onto the new marker's
-- key so nothing the user decided is lost in the transfer.
--
-- Defined HERE, beside EntryFor rather than beside the take-row menu that calls
-- it, because the repair panel calls it too and sits above that menu in the
-- file. A local declared below its caller resolves as a nil GLOBAL, and the
-- failure would surface only on the button press.
local function AddTakeMarkerFromSelection(row)
  if r.CountSelectedMediaItems(0) ~= 1 then
    state.message, state.message_kind =
      "Select exactly one item in REAPER to mark this take on.", "warn"
    return
  end
  local item = r.GetSelectedMediaItem(0, 0)
  local take = r.GetActiveTake(item)
  local info = {
    start_offs = take and r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0,
    length     = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
    playrate   = take and r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1.0,
  }
  local range = vo.SourceCoverageRanges({ info })[1]
  if not range then
    state.message, state.message_kind = "That item has no source coverage to span.", "error"
    return
  end

  local id = vo.MintMarkerId(TakenMarkerIds())
  local ok, why = vo.WriteTakeMarkers(item, {
    { start = range.from, stop = range.to, asset = row.asset, id = id },
  })
  if not ok then
    state.message, state.message_kind = "Could not write the marker: " .. tostring(why), "error"
    return
  end

  -- Move the row's marks onto the marker's key, so a planned take's notes or
  -- an orphaned row's decisions ride along rather than being stranded.
  for _, e in ipairs(state.entries) do
    if e.key == row.key then e.key = "tkm|" .. id end
  end
  state.dirty = true
  Reload()
  state.message, state.message_kind = string.format(
    "Marked %s on the selected item.", row.deliver or row.asset or "take"), "ok"
end

-- Rewrite ONE tool marker on the item that owns it. `mutate(mk)` edits the
-- { start, stop, asset, id } in place; returning false drops the marker.
-- Every other tool marker on the item rides along unchanged, and user markers
-- are preserved by vo.WriteTakeMarkers itself.
local function RewriteMarker(row, mutate)
  local info = state.marker_info and state.marker_info[row.marker_id]
  local item = (info and info.item) or row.item
  if not item then return false end
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok then return false end
  local list, hit = {}, false
  for _, m in ipairs(vo.ParseTKMChunk(chunk)) do
    local asset, id = vo.ParseMarkerName(m.name)
    if id then
      local mk = { start = m.pos, stop = m.pos + (m.length or 0),
                   asset = asset, id = id }
      if id == row.marker_id then
        hit = true
        if mutate(mk) ~= false then list[#list + 1] = mk end
      else
        list[#list + 1] = mk
      end
    end
  end
  if not hit then return false end
  return vo.WriteTakeMarkers(item, list)
end

-- The items selected in REAPER, as a set, for scope resolution.
local function SelectedItemSet()
  local set = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    set[r.GetSelectedMediaItem(0, i)] = true
  end
  return set
end

-- Trimming an item to the take marker inside it: the other direction from
-- SnapMarkerToItem, and the manual half of "the marker is what the cut will
-- be". Drag the marker to where the clip should start and end, then trim the
-- item onto it -- no re-cut, no re-match, no split.
--
-- A table rather than file locals: the main chunk is at Lua's 200-local
-- ceiling, which is a LOAD-time error, so a new local here would stop the
-- whole script from parsing.
local Trim = {}

-- This item's own tool markers that its window actually shows.
function Trim.markers_in(info)
  local out = {}
  local cov = info and info.item and vo.SourceCoverageRanges({ info })[1]
  if not cov then return out end
  -- NOT `cov and r.GetItemStateChunk(...)`: an `and` expression is adjusted to
  -- ONE value, so the second return -- the chunk itself -- silently became nil
  -- and every item read as holding no markers.
  local ok, chunk = r.GetItemStateChunk(info.item, "", false)
  if not ok then return out end
  for _, m in ipairs(vo.ParseTKMChunk(chunk)) do
    local asset, id = vo.ParseMarkerName(m.name)
    local from, to = m.pos, m.pos + (m.length or 0)
    if id and to > from and from < cov.to and to > cov.from then
      out[#out + 1] = { start = from, stop = to, asset = asset, id = id }
    end
  end
  table.sort(out, function(a, b) return a.start < b.start end)
  return out
end

-- Set one item's edges to one marker's bounds. Returns true when it moved.
function Trim.apply(info, mk)
  local plan = vo.PlanTrimToRange(info, mk.start, mk.stop)
  local take = plan and info.item and r.GetActiveTake(info.item)
  if not (plan and take) then return false end
  r.SetMediaItemInfo_Value(info.item, "D_POSITION", plan.pos)
  r.SetMediaItemInfo_Value(info.item, "D_LENGTH",   plan.length)
  r.SetMediaItemTakeInfo_Value(take,  "D_STARTOFFS", plan.start_offs)
  return true
end

-- Set one marker's bounds to its item's edges. The other direction from
-- Trim.apply, and the batch form of SnapMarkerToItem. Returns true when it
-- moved -- a marker already at the edges is not a write, so a press over a
-- tidy session reports honestly instead of claiming work.
--
-- Every OTHER tool marker on the item rides along unchanged, the same as
-- RewriteMarker: the caller has already established this item holds one, but
-- the write is a whole-list write and a stray must not be dropped by it.
function Trim.snap_apply(info, mk)
  local cov = info and info.item and vo.SourceCoverageRanges({ info })[1]
  if not cov then return false end
  if math.abs(cov.from - mk.start) < 1e-9 and math.abs(cov.to - mk.stop) < 1e-9 then
    return false
  end
  local ok, chunk = r.GetItemStateChunk(info.item, "", false)
  if not ok then return false end
  local list, hit = {}, false
  for _, m in ipairs(vo.ParseTKMChunk(chunk)) do
    local asset, id = vo.ParseMarkerName(m.name)
    if id then
      local e = { start = m.pos, stop = m.pos + (m.length or 0), asset = asset, id = id }
      if id == mk.id then
        hit = true
        e.start, e.stop = cov.from, cov.to
      end
      list[#list + 1] = e
    end
  end
  if not hit then return false end
  return vo.WriteTakeMarkers(info.item, list) and true or false
end

-- The two batch verbs. Scope is the selection, like everything else.
--
-- An item holding SEVERAL markers is left alone and reported: it is a
-- recording, not a take, and there is no one marker to pair it with. Cut is
-- what turns that into takes.
--
-- `dir` is "item" (edges follow the marker) or "marker" (marker follows the
-- edges). One function because the scoping, the counting and the report are
-- the whole verb and are identical either way; only the write differs, and
-- two copies of this drifted apart is exactly how the per-row pair used to
-- disagree with the batch one.
function Trim.run(dir)
  dir = dir or "item"
  local to_marker = (dir == "item")
  Reload()
  local picked = SelectedItemSet()
  local scoped = next(picked) ~= nil

  local jobs, several, none = {}, 0, 0
  for _, info in ipairs(state.items or {}) do
    local item = info.item
    if item and not info.skip and ((not scoped) or picked[item]) then
      local mks = Trim.markers_in(info)
      if #mks == 1 then jobs[#jobs + 1] = { info = info, mk = mks[1] }
      elseif #mks > 1 then several = several + 1
      else none = none + 1 end
    end
  end

  if #jobs == 0 then
    state.message, state.message_kind = string.format(
      "Nothing to %s. %d item(s) hold several takes (Cut splits those), " ..
      "%d hold no take marker.",
      to_marker and "trim" or "snap", several, none), "warn"
    return
  end

  local moved = 0
  core.Transaction(to_marker and "VO Overview: trim items to their markers"
                              or "VO Overview: snap markers to items", function()
    for _, j in ipairs(jobs) do
      local hit = to_marker and Trim.apply(j.info, j.mk)
                             or Trim.snap_apply(j.info, j.mk)
      if hit then moved = moved + 1 end
    end
  end)
  -- Marker bounds are VO data; item edges are REAPER's. Only one of the two
  -- directions has anything for the project file to hold onto.
  if not to_marker then state.dirty = true end
  r.UpdateArrange()
  Reload()

  local parts = { to_marker
    and string.format("Trimmed %d item(s) to their take marker.", moved)
    or  string.format("Snapped %d marker(s) to their item.", moved) }
  if several > 0 then
    parts[#parts + 1] = string.format(
      "%d hold several takes and were left alone.", several)
  end
  if none > 0 then
    parts[#parts + 1] = string.format("%d have no take marker.", none)
  end
  state.message, state.message_kind = table.concat(parts, " "), "ok"
end

-- Two lines both claiming one stretch of audio: the words decide which is
-- right, and the loser's marker goes.
--
-- Where this comes from: identification can hand two script lines the same
-- range, and the result is a clip that reads as a take of both. Every verb
-- that needs "the one marker in this item" -- Trim, Snap -- then skips it as a
-- recording, and Tidy cannot help, because Tidy dedupes by marker ID and these
-- are two different ids arguing about one range.
--
-- The safety is entirely in vo.ClusterMarkerRanges: only markers overlapping
-- by 80% of the shorter are ever compared, so an uncut recording -- one marker
-- per take, no overlap -- has no clusters and nothing to lose. The planner
-- then refuses whenever the words do not clearly pick a winner, and the
-- refusals are reported by name.
--
-- The gather-and-decide half only. It writes nothing and reads no chunk twice,
-- so both verbs that need it can run it inside their own transaction and
-- report in their own words. Returns plan, drop_by_item.
function Trim.dupe_plan(scope)
  local cfg = vo.LoadConfig()
  local picked = scope
  local scoped = picked ~= nil

  local words = {}
  for _, t in ipairs(state.transcripts or {}) do
    if t.path then words[t.path] = t.words or {} end
  end

  -- Counting markers only: the coverage rule has already thrown out the copies
  -- a split scattered onto neighbouring items, which are Tidy's business and
  -- would otherwise cluster with everything they were copied from.
  local markers, owner = {}, {}
  for path, group in pairs(state.take_markers or {}) do
    for _, mk in ipairs(vo.CountingMarkers(group)) do
      local rec  = group[mk.item_index]
      local item = rec and rec.info and rec.info.item
      if item and ((not scoped) or picked[item]) then
        mk.source_path = path
        markers[#markers + 1] = mk
        owner[mk.id] = item
      end
    end
  end

  local plan = vo.PlanDuplicateMarkers({
    markers = markers, lines = state.lines or {}, words = words, cfg = cfg })

  local drop_by_item = {}
  for _, d in ipairs(plan.deletes) do
    local item = owner[d.id]
    if item then
      drop_by_item[item] = drop_by_item[item] or {}
      drop_by_item[item][d.id] = true
    end
  end
  return plan, drop_by_item
end

-- The write half. Caller supplies the transaction. Returns how many markers
-- actually left the chunks.
function Trim.drop_dupes(drop_by_item)
  local removed = 0
  for item, drop in pairs(drop_by_item or {}) do
    local ok, chunk = r.GetItemStateChunk(item, "", false)
    if ok then
      -- A whole-list write, so every marker the item holds has to be carried
      -- across; user markers are preserved by vo.WriteTakeMarkers itself.
      local list, hit = {}, 0
      for _, m in ipairs(vo.ParseTKMChunk(chunk)) do
        local asset, id = vo.ParseMarkerName(m.name)
        if id then
          if drop[id] then
            hit = hit + 1
          else
            list[#list + 1] = { start = m.pos, stop = m.pos + (m.length or 0),
                                asset = asset, id = id }
          end
        end
      end
      if hit > 0 and vo.WriteTakeMarkers(item, list) then removed = removed + hit end
    end
  end
  return removed
end

-- The duplicate half of a report, as sentences. Shared so the two verbs that
-- run this step cannot describe it differently.
function Trim.dupe_report(plan, removed)
  local parts = {}
  if removed > 0 then
    local named = {}
    for _, d in ipairs(plan.deletes) do
      named[#named + 1] = string.format("%s (%.2f) lost to %s (%.2f)",
        d.asset or "?", d.score or 0, d.lost_to or "?", d.lost_to_score or 0)
    end
    parts[#parts + 1] = string.format("Removed %d duplicate marker(s): %s.",
      removed, table.concat(named, ", "))
  end
  for _, s in ipairs(plan.skipped) do
    local named = {}
    for _, m in ipairs(s.markers) do
      named[#named + 1] = string.format("%s %.2f", m.asset or "?", m.score or 0)
    end
    parts[#parts + 1] = string.format("Left alone -- %s (%s).",
      s.why, table.concat(named, " vs "))
  end
  return parts
end

-- The user's rule for "I trimmed the head past the marker start": the row's
-- own marker snaps to its item's current source coverage. That row's marker
-- is by construction the counting marker of that item, so this IS the
-- earliest-intersecting-marker rule from the design.
local function SnapMarkerToItem(row)
  local span = row.item_info and vo.SourceCoverageRanges({ row.item_info })[1]
  if not span then
    state.message, state.message_kind = "No item coverage to snap to.", "warn"
    return
  end
  if RewriteMarker(row, function(mk) mk.start, mk.stop = span.from, span.to end) then
    state.dirty = true
    Reload()
    state.message, state.message_kind = string.format(
      "Marker snapped to the item (%.2fs-%.2fs).", span.from, span.to), "ok"
  else
    state.message, state.message_kind = "Could not rewrite that marker.", "error"
  end
end

local function DeleteTakeMarker(row)
  if RewriteMarker(row, function() return false end) then
    state.dirty = true
    Reload()
    state.message, state.message_kind =
      "Marker deleted. The take left the sheet; any marks surface in\n" ..
      "Check -> Takes without audio.", "ok"
  else
    state.message, state.message_kind = "Could not delete that marker.", "error"
  end
end

-- One take, one marker, in the clip that IS that take: rewrite every item's
-- tool markers as the ones its own window covers, dropping the rest. The
-- canonical copy is the one the coverage rule already counts -- the copy the
-- user can see and drag -- and this is what absorbs REAPER's split residue
-- (which duplicates the whole set into both halves) and stale copies after a
-- drag. User markers are never touched.
--
-- Deliberately explicit, never run per-frame: a rebuild that rewrote chunks
-- while a marker drag was in flight would snap the marker out of the user's
-- hand. Cut, Adopt and Mark selected keep their own single undo points, so
-- the mirror refresh stays its own press and its own undo step.
-- The write half, without the reloads or the transaction, so a caller that is
-- already inside both can prune as part of its own job. Returns touched, canon.
--
-- `picked`, when given, is the set of items the write is allowed to touch. The
-- PLAN is still computed over the whole group either way: which copy of a
-- marker is canonical is a fact about every item covering it, and deciding it
-- from a subset would promote a residue copy the moment a user selected one
-- item and not its neighbour.
--
-- `plan_fn` is vo.PlanMarkerMirror or vo.PlanMarkerPrune. Cut's post-split
-- tidy keeps the mirror it has always used; the Edit-tab verbs prune, because
-- a marker written before its clip was trimmed can straddle two items and the
-- mirror hands a copy to both -- which is a clip with two markers, which every
-- verb needing "the one marker here" then refuses.
local function MirrorTakeMarkers(picked, plan_fn)
  plan_fn = plan_fn or vo.PlanMarkerMirror
  local touched, canonical = 0, 0
  for _, group in pairs(state.take_markers or {}) do
    local rewrites, canon = plan_fn(group)
    canonical = canonical + canon
    for _, rw in ipairs(rewrites) do
      local rec = group[rw.item_index]
      local item = rec and rec.info and rec.info.item
      if item and ((not picked) or picked[item]) then
        if vo.WriteTakeMarkers(item, rw.markers) then
          touched = touched + 1
        end
      end
    end
  end
  return touched, canonical
end

local function SyncTakeMarkers()
  Reload()
  local touched, canonical = 0, 0
  core.Transaction("VO Overview: sync take markers", function()
    touched, canonical = MirrorTakeMarkers()
  end)
  Reload()
  state.message, state.message_kind = (touched > 0)
    and string.format(
      "Tidied the take markers on %d item(s). %d take(s) in the session, one " ..
      "marker each, in the clip it belongs to.", touched, canonical)
    or "Every item already carries just its own take.", "ok"
end

-- Everything on an item that is not its own take marker, in one step.
--
-- Two different kinds of extra, which is why this is one verb rather than two
-- buttons the user has to know the difference between:
--
--   1. DUPLICATES -- two lines claiming the same stretch of audio. Resolved by
--      the words (vo.PlanDuplicateMarkers), and refused when they do not
--      clearly decide.
--   2. LEFTOVERS -- markers this clip does not own: the copies REAPER's split
--      leaves in both halves, and any marker whose audio mostly lives in a
--      neighbouring item. Dropped by vo.PlanMarkerPrune.
--
-- Prune, NOT vo.PlanMarkerMirror. The mirror gives an item every canonical
-- marker INTERSECTING its window, so a marker written from the transcript
-- before the clip was trimmed -- starting inside this item, ending well into
-- the next -- is handed to both. That turned a clip with one marker into a
-- clip with two, and the snap below then refused it as a recording. Removing
-- extras must never add one.
--
-- Order matters. Duplicates go first: the mirror pass decides which COPY of a
-- marker id is canonical, and running it first would faithfully preserve a
-- duplicate that the words are about to delete.
--
-- Caller supplies the Reload and the transaction. Returns removed, dropped,
-- plan -- so the wrapping verb writes its own report.
function Trim.extras(picked)
  local plan, drop_by_item = Trim.dupe_plan(picked)
  local removed = Trim.drop_dupes(drop_by_item)
  -- The mirror pass reads state.take_markers, which the drop above has just
  -- made stale for the items it touched. Re-collect rather than trust it: a
  -- plan built from pre-delete chunks would write the deleted markers back.
  if removed > 0 then state.take_markers = vo.CollectTakeMarkers(state.items) end
  local dropped = MirrorTakeMarkers(picked, vo.PlanMarkerPrune)
  return removed, dropped, plan
end

-- The scope every verb here shares: the items picked in REAPER, or nil for
-- "everything", which is what the collectors already mean by no filter.
--
-- On the Trim table, not a file local: the main chunk sits at Lua's 200-local
-- ceiling and one more would be a LOAD-time error for the whole script.
function Trim.scope()
  local picked = SelectedItemSet()
  return (next(picked) ~= nil) and picked or nil
end

function Trim.remove_extras()
  Reload()
  local picked = Trim.scope()
  local removed, dropped, plan = 0, 0, nil
  core.Transaction("VO Overview: remove extra take markers", function()
    removed, dropped, plan = Trim.extras(picked)
  end)
  state.dirty = true
  r.UpdateArrange()
  Reload()

  local parts = Trim.dupe_report(plan, removed)
  if dropped > 0 then
    parts[#parts + 1] = string.format(
      "Dropped the leftover markers from %d clip(s).", dropped)
  end
  if #parts == 0 then
    parts[1] = "Nothing extra: every clip already carries just its own take."
  end
  state.message, state.message_kind = table.concat(parts, " "),
    (#plan.skipped > 0 and removed == 0) and "warn" or "ok"
end

-- The button for "I have just trimmed this clip by hand, make it right again".
--
-- Remove the extras, then bring what is left up to date with the audio the
-- item now shows: the surviving marker follows the item's edges, and an edge
-- left raw by the trim gets the standard fade back.
--
-- Fades are filled per SIDE, never overwritten. A trim leaves the edge it cut
-- at zero and the other edge's fade intact, so filling only the zeros restores
-- exactly what the trim removed -- and a fade drawn by hand, on either side,
-- survives a press of this. That also keeps the hand-trimmed sentinel that
-- TightenItems reads (custom fades mean "leave this alone") meaningful.
function Trim.tidy_take()
  Reload()
  local cfg = vo.LoadConfig()
  local fade_in  = vo.Opt(cfg, "cut_fade_in")
  local fade_out = vo.Opt(cfg, "cut_fade_out")
  local picked = Trim.scope()

  local removed, dropped, plan = 0, 0, nil
  local snapped, faded, several = 0, 0, 0

  core.Transaction("VO Overview: tidy up take", function()
    removed, dropped, plan = Trim.extras(picked)

    for _, info in ipairs(state.items or {}) do
      local item = info.item
      if item and not info.skip and ((not picked) or picked[item]) then
        -- Re-read per item: markers_in goes back to the chunk, so it sees the
        -- deletes this transaction has already made rather than the collection
        -- from before them.
        local mks = Trim.markers_in(info)
        if #mks == 1 then
          if Trim.snap_apply(info, mks[1]) then snapped = snapped + 1 end
        elseif #mks > 1 then
          -- Still contested, because the words refused to choose. Snapping one
          -- of several markers to the whole item would be a guess.
          several = several + 1
        end

        local was_in  = r.GetMediaItemInfo_Value(item, "D_FADEINLEN")
        local was_out = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
        local hit = false
        if was_in <= 0 and fade_in and fade_in > 0 then
          r.SetMediaItemInfo_Value(item, "D_FADEINLEN", fade_in)
          hit = true
        end
        if was_out <= 0 and fade_out and fade_out > 0 then
          r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fade_out)
          hit = true
        end
        if hit then faded = faded + 1 end
      end
    end
  end)
  state.dirty = true
  r.UpdateArrange()
  Reload()

  local parts = Trim.dupe_report(plan, removed)
  if dropped > 0 then
    parts[#parts + 1] = string.format(
      "Dropped the leftover markers from %d clip(s).", dropped)
  end
  parts[#parts + 1] = string.format(
    "Snapped %d marker(s) to their item; filled the missing fades on %d.",
    snapped, faded)
  if several > 0 then
    parts[#parts + 1] = string.format(
      "%d clip(s) still hold several markers and were not snapped.", several)
  end
  state.message, state.message_kind = table.concat(parts, " "),
    (several > 0) and "warn" or "ok"
end

-- The edges a cut WOULD produce, for spans in one item.
--
-- A take marker is a promise about where the clip will land, so it has to be
-- written at the edges the cut will actually use -- not at the raw whisper word
-- times, which sit a pause-width outside the speech at both ends. Identify used
-- to write the raw bounds, so the markers you inspected and the clips you got
-- were different edges, and the marker taught you nothing about the cut.
--
-- This is the same speech-bounds → pad → snap-to-silence pass DoCut runs, at
-- the same settings, through the same probe. One function, so the preview and
-- the cut cannot drift apart: if this is wrong, it is wrong in both places and
-- shows up in the clip.
--
-- `spans` are SOURCE-time { start, stop, ... } and are returned as a parallel
-- list of SOURCE-time { start, stop }, since markers live in source time.
-- Falls back to the input edges if the audio cannot be probed -- padding is a
-- refinement, and losing it is worth far less than losing the marker.
local function SnapSpansToCut(info, spans, cfg, words)
  local out = {}
  for i, s in ipairs(spans) do out[i] = { start = s.start, stop = s.stop } end
  if #out == 0 or not info or not info.item then return out end

  local take = r.GetActiveTake(info.item)
  local probe, destroy = vo.MakeTakeProbe(take)
  local ok = pcall(function()
    if not probe then error("no audio accessor") end
    local covered = vo.SourceCoverageRanges({ info })[1]
    if not covered then error("no source coverage") end

    -- Only the words this ITEM covers: probing outside the take answers
    -- silence, which drags the measured floor down.
    local proj_words = {}
    for _, w in ipairs(words or {}) do
      if w.t1 >= covered.from and w.t0 <= covered.to then
        proj_words[#proj_words + 1] = {
          t0 = vo.SourceTimeToProject(w.t0, info),
          t1 = vo.SourceTimeToProject(w.t1, info),
          text = w.text,
        }
      end
    end

    local proj = {}
    for i, s in ipairs(spans) do
      proj[i] = { start = vo.SourceTimeToProject(s.start, info),
                  stop  = vo.SourceTimeToProject(s.stop,  info) }
    end
    table.sort(proj, function(a, b) return a.start < b.start end)

    local floor_ = vo.MeasureNoiseFloor(vo.InterWordGaps(proj_words), probe, cfg)
    vo.ApplyPadding(proj, cfg,
      { start = info.pos, stop = info.pos + info.length }, probe, floor_, proj_words)

    -- Back to source time, matched to the input by order: ApplyPadding sorts
    -- and the caller's list may not have been sorted, so both are ordered by
    -- start before pairing.
    local order = {}
    for i = 1, #spans do order[i] = i end
    table.sort(order, function(a, b) return spans[a].start < spans[b].start end)
    for k, idx in ipairs(order) do
      local p = proj[k]
      if p then
        out[idx] = { start = vo.ProjectTimeToSource(p.start, info),
                     stop  = vo.ProjectTimeToSource(p.stop,  info) }
      end
    end
  end)
  if destroy then destroy() end
  if not ok then
    for i, s in ipairs(spans) do out[i] = { start = s.start, stop = s.stop } end
  end
  return out
end

-- Work out what script lines are in the audio, and write it down.
--
-- ONE verb where there were three. "Find lines in items", "Assign items to
-- lines" and "Adopt this whole session" differed only in what SHAPE the audio
-- was in -- a recording holding many takes, a clip holding one, a session
-- someone else had already cut -- and the tool can see that for itself
-- (vo.PlanItemIdentity). Making the user classify their own audio before
-- pressing anything was asking them to know the tool's internals, and choosing
-- wrong did the wrong thing silently.
--
-- Scope is the selection, like everything else: the items picked in REAPER, or
-- every item when nothing is picked.
local function IdentifyItems()
  Reload()
  local cfg   = vo.LoadConfig()
  local floor = vo.Opt(cfg, "mark_item_min_span")
  local taken = TakenMarkerIds()
  local index = vo.BuildNameIndex(state.lines)

  -- Scope: the items picked in REAPER, else every item in the project.
  local picked = SelectedItemSet()
  local scoped = next(picked) ~= nil

  local spans_by_path = {}
  for _, m in ipairs(state.matches or {}) do spans_by_path[m.path] = m.spans end

  -- The transcript's words, for the silence probe that decides where the cut
  -- edges will fall. Read on the press, not held in state: this is a button,
  -- not a frame.
  local words_by_path = {}
  for _, m in ipairs(state.matches or {}) do
    local parsed = vo.ReadTranscript(m.path)
    words_by_path[m.path] = parsed and parsed.words or {}
  end

  -- Rows keyed by where their audio starts, so a span can find the row whose
  -- marks must ride onto the new marker's key.
  local rows_by_start = {}
  local function start_key(path, at)
    return tostring(path) .. "|" .. string.format("%.4f", at or 0)
  end
  for _, row in ipairs(state.overview) do
    if row.source_path and row.source_start ~= nil then
      rows_by_start[start_key(row.source_path, row.source_start)] = row
    end
  end

  -- Which spans already have a marker. Per SPAN, not per item: an item can
  -- hold four hundred takes with all but one of them already marked, and that
  -- must not read as a single-take item.
  local marked_span = {}
  for _, row in ipairs(state.overview) do
    if row.marker_id and row.source_path and row.source_start ~= nil then
      marked_span[start_key(row.source_path, row.source_start)] = true
    end
  end

  local items, by_key, unusable = {}, {}, 0
  for _, info in ipairs(state.items or {}) do
    local item = info.item
    if item and not info.skip and ((not scoped) or picked[item]) then
      local cov = vo.SourceCoverageRanges({ info })[1]
      if cov then
        local spans = {}
        for _, sp in ipairs(spans_by_path[info.path] or {}) do
          if (sp.kind == "match" or sp.kind == "review") and sp.asset then
            spans[#spans + 1] = {
              start = sp.start, stop = sp.stop,
              asset = sp.asset, deliver = sp.deliver or sp.asset,
              marked = marked_span[start_key(info.path, sp.start)] or nil,
              path = info.path,
            }
          end
        end
        local key = tostring(item)
        by_key[key] = { item = item, info = info }
        items[#items + 1] =
          { key = key, from = cov.from, to = cov.to, spans = spans }
      else
        unusable = unusable + 1
      end
    elseif item and info.skip and scoped and picked[item] then
      unusable = unusable + 1
    end
  end

  if #items == 0 then
    state.message, state.message_kind = scoped
      and "Nothing usable in the selection: those item(s) have no audio this tool can read."
      or  "No audio in this project to identify.", "warn"
    return
  end

  local plans, counts = vo.PlanItemIdentity(items, { floor = floor })

  local wrote, named, rekey = 0, 0, {}
  local anything = false
  for _, plan in ipairs(plans) do
    if #plan.markers > 0 or plan.name then anything = true break end
  end
  if not anything then
    state.message, state.message_kind = string.format(
      "Everything in scope is already identified: %d take(s), %d recording(s), " ..
      "%d item(s) matching no line.", counts.one, counts.many, counts.none), "info"
    return
  end

  state.name_baseline = nil
  core.Transaction("VO Overview: identify takes", function()
    for _, plan in ipairs(plans) do
      local rec = by_key[plan.key]
      local item = rec and rec.item
      if item and #plan.markers > 0 then
        -- The marker is a PROMISE about where the clip will land, so it is
        -- written at the edges the cut will use. A single-take item keeps the
        -- user's own edges (the item IS the take -- their trim is the truth);
        -- spans inside a recording get the cut's speech-bounds-and-pad pass,
        -- because their raw whisper bounds sit a pause outside the speech at
        -- both ends and would promise a clip nobody is going to get.
        local edges = plan.markers
        if plan.kind == "many" then
          edges = SnapSpansToCut(rec.info, plan.markers, cfg,
                                 words_by_path[rec.info.path])
        end

        -- Existing tool markers ride along: WriteTakeMarkers replaces the
        -- tool's whole set, and dropping them would orphan every take in this
        -- item that was already identified.
        local list = {}
        for i, mk in ipairs(plan.markers) do
          local id = vo.MintMarkerId(taken)
          local e = edges[i] or mk
          list[#list + 1] = { start = e.start, stop = e.stop,
                              asset = mk.asset, id = id }
          local at = (plan.kind == "one") and plan.span or mk.span
          local row = at and rows_by_start[start_key(rec.info.path, at.start)]
          if row and row.key then rekey[row.key] = "tkm|" .. id end
        end
        local ok0, chunk0 = r.GetItemStateChunk(item, "", false)
        if ok0 then
          for _, m in ipairs(vo.ParseTKMChunk(chunk0)) do
            local a0, i0 = vo.ParseMarkerName(m.name)
            if i0 then
              list[#list + 1] = { start = m.pos, stop = m.pos + (m.length or 0),
                                  asset = a0, id = i0 }
            end
          end
        end
        if vo.WriteTakeMarkers(item, list) then wrote = wrote + #plan.markers end
      end

      -- Naming is independent of marking, so a session identified by an
      -- earlier run still gets its names. vo.PlanAdopt never overwrites a name
      -- that already resolves to a line, which is what makes re-running safe.
      if item and plan.name then
        local take = r.GetActiveTake(item)
        if take then
          local _, cur = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
          local renames = vo.PlanAdopt(
            { { item = item, name = cur or "", deliver = plan.name } },
            index, { alt_pattern = cfg.alt_append_pattern })
          if #renames == 1 then
            r.GetSetMediaItemTakeInfo_String(take, "P_NAME", renames[1].name, true)
            named = named + 1
          end
        end
      end
    end
  end)

  -- The marks ride along: each rekeyed entry now lives under its marker id,
  -- which no drag can move.
  for _, e in ipairs(state.entries) do
    if e.key and rekey[e.key] then e.key = rekey[e.key] end
  end
  state.dirty = true
  Reload()

  local parts = { string.format("Identified %d item(s)%s: marked %d take(s), named %d.",
    #items, scoped and " in the selection" or "", wrote, named) }
  if counts.many > 0 then
    parts[#parts + 1] = string.format(
      "%d held several takes and were left unnamed -- Cut splits them.", counts.many)
  end
  if counts.none > 0 then
    parts[#parts + 1] = string.format("%d matched no script line.", counts.none)
  end
  if unusable > 0 then
    parts[#parts + 1] = string.format("%d had no usable audio.", unusable)
  end
  state.message, state.message_kind = table.concat(parts, " "), "ok"
end

local function SetStatus(row, status)
  Mutate(row, function(e) e.status = status end)
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
-- below. The key rule itself lives in the lib (vo.LineKey) so the sheet,
-- Tidy's conflict count and the card badge cannot drift apart.
local function LineKeyOf(row)
  return vo.LineKey(row)
end

-- Exactly one take of a line may be the SELECT, so ticking one clears the rest
-- of its group. Without this the project file could hold two selected rows for
-- one line and BuildOverview would silently pick whichever the build order put
-- first (see vo.BuildOverview's "no first/last fallback").
local function SetSelect(row, on)
  local cfg = vo.LoadConfig()
  if on then
    local mine = LineKeyOf(row)
    for _, other in ipairs(state.overview) do
      if other ~= row and other.status ~= "orphan" and other.user_select
         and LineKeyOf(other) == mine then
        -- An explicit NO where the sibling's own track would otherwise speak
        -- for it. Clearing to nil was right when nil simply meant unticked,
        -- but a sibling sitting on the Selects track would now re-tick itself
        -- on the very next rebuild -- two Sels on one line, which is the exact
        -- state this exclusivity exists to prevent.
        local sibling = other
        Mutate(sibling, function(e)
          if vo.MarkFromTrack(sibling.track_name, cfg) == "select" then
            e.select = false
          else
            e.select = nil
          end
        end)
      end
    end
  end
  -- Ticking stores yes. UN-ticking stores an explicit NO when the item's track
  -- would otherwise re-tick it (vo.EffectiveMarks rule 2), and nothing at all
  -- when it would not -- so files do not grow rows that say nothing.
  Mutate(row, function(e)
    if on then
      e.select = true
    elseif vo.MarkFromTrack(row.track_name, cfg) == "select" then
      e.select = false
    else
      e.select = nil
    end
  end)
end

-- Any number of takes may be KEPT, so this has no exclusivity at all. A keep
-- is an extra delivery, not a competing answer to which take the delivery is.
local function SetKeep(row, on)
  -- Same tri-state rule as SetSelect: an explicit no only where the track
  -- would otherwise speak for this mark.
  local cfg = vo.LoadConfig()
  Mutate(row, function(e)
    if on then
      e.keep = true
    elseif vo.MarkFromTrack(row.track_name, cfg) == "keep" then
      e.keep = false
    else
      e.keep = nil
    end
  end)
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
        -- One full profile, read from both ends. EffectiveRoom sees through
        -- a neighbour take's onset clamped inside the edge (speech, dead
        -- air, foreign blip) where a first-hot-window scan calls it tight.
        local step = 0.010
        local windows = {}
        for k = 0, math.floor(len / step) - 1 do
          windows[#windows + 1] =
            probe(pos + k * step, math.min(pos + (k + 1) * step, pos + len))
            or -150.0
        end
        destroy()
        if #windows > 0 then
          local from_end = {}
          for k = #windows, 1, -1 do from_end[#from_end + 1] = windows[k] end
          local ropts = { floor_db = TIGHTEN_FLOOR_DB }
          measured[#measured + 1] = {
            name = nm,
            head_room = vo.EffectiveRoom(windows, step, ropts),
            tail_room = vo.EffectiveRoom(from_end, step, ropts),
            user_touched = touched,
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

  local markers_followed = 0
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

        -- The take's marker follows the new edges. The marker is the take's
        -- identity and Cut wrote it at the OLD edges; leaving it there after
        -- a deliberate trim leaves the marker owning silence the item no
        -- longer shows -- a sheet-vs-timeline disagreement created by the
        -- tool's own finishing pass, which is exactly what Fix a line would
        -- then report. CLAMPED to the new window rather than snapped to it,
        -- so on the rare item holding more than one marker, each keeps its
        -- own place and only sheds what was trimmed away.
        if e.head > 0 or e.tail > 0 then
          local cov = vo.SourceCoverageRanges({ {
            start_offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
            length     = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
            playrate   = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
          } })[1]
          local ok_c, chunk = r.GetItemStateChunk(item, "", false)
          if cov and ok_c then
            local list, changed = {}, false
            for _, m in ipairs(vo.ParseTKMChunk(chunk)) do
              local asset0, id0 = vo.ParseMarkerName(m.name)
              if id0 then
                local from = math.max(m.pos, cov.from)
                local to   = math.min(m.pos + (m.length or 0), cov.to)
                if to > from then
                  if from ~= m.pos or to ~= m.pos + (m.length or 0) then
                    changed = true
                  end
                  list[#list + 1] = { start = from, stop = to,
                                      asset = asset0, id = id0 }
                else
                  -- Wholly outside the trimmed window: stray residue, not
                  -- this pass's business. Kept as it was; Tidy handles it.
                  list[#list + 1] = { start = m.pos,
                                      stop = m.pos + (m.length or 0),
                                      asset = asset0, id = id0 }
                end
              end
            end
            if changed and vo.WriteTakeMarkers(item, list) then
              markers_followed = markers_followed + 1
            end
          end
        end
      end
    end
    r.UpdateArrange()
  end)
  state.message, state.message_kind = string.format(
    "Tightened %d of %d item(s) to %dms head / %dms tail room.%s",
    #edits, #measured,
    math.floor(vo.Opt(cfg, "snap_head_room") * 1000 + 0.5),
    math.floor(vo.Opt(cfg, "snap_tail_room") * 1000 + 0.5),
    markers_followed > 0
      and string.format(" %d take marker(s) followed the new edges.", markers_followed)
      or ""), "ok"
end

-- Put the standard cut fades back on the selected items. The fades a cut
-- writes are short and protective -- shorter in than out, sitting inside the
-- head and tail room -- and an item that has been comped, re-trimmed or
-- dragged in by hand carries whatever fades that gesture left it.
--
-- Note what this ALSO does. Default fades are how "nobody touched this by
-- hand" is recorded: TightenItems above skips any item whose fades differ from
-- the cut defaults, and that is the whole protection a hand-trimmed item has
-- against being measured and moved. Pressing this re-enrols such an item into
-- Auto-adjust. That is the right reading of the gesture -- "this one is
-- finished and standard again" -- but it is not free, and the tooltip says so.
--
-- On the Trim table rather than a file local: the main chunk is at Lua's
-- 200-local ceiling, which is a LOAD-time error, so a new local here would
-- stop the whole script from parsing.
function Trim.fades()
  local cfg = vo.LoadConfig()
  local fade_in  = vo.Opt(cfg, "cut_fade_in")
  local fade_out = vo.Opt(cfg, "cut_fade_out")

  local pool = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    pool[#pool + 1] = r.GetSelectedMediaItem(0, i)
  end
  if #pool == 0 then
    state.message, state.message_kind =
      "Select the items in REAPER first.", "warn"
    return
  end

  -- An item already carrying the defaults is not a write and is not counted:
  -- a press over a tidy session should say so rather than claim work.
  local changed = 0
  core.Transaction("VO Overview: apply the cut fades", function()
    for _, item in ipairs(pool) do
      local was_in  = r.GetMediaItemInfo_Value(item, "D_FADEINLEN")
      local was_out = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
      if math.abs(was_in - fade_in) > 0.0005
         or math.abs(was_out - fade_out) > 0.0005 then
        r.SetMediaItemInfo_Value(item, "D_FADEINLEN",  fade_in)
        r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fade_out)
        changed = changed + 1
      end
    end
  end)
  r.UpdateArrange()

  state.message, state.message_kind = (changed > 0)
    and string.format("Applied the cut fades to %d item(s) (%.0f ms in, %.0f ms out).",
                      changed, fade_in * 1000, fade_out * 1000)
    or  string.format("All %d selected item(s) already carry the cut fades.", #pool),
    "ok"
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
  --
  -- Matched against FILTERED, not visible: the clicked take may sit inside a
  -- folded card, whose rows are exactly the ones missing from state.visible.
  -- Matching only what was on screen meant a timeline click on a folded line
  -- selected nothing, scrolled nowhere and outlined nothing -- the one case
  -- this follow exists for.
  local found, first = {}, nil
  for _, row in ipairs(state.filtered or {}) do
    if row.item and selected[row.item] then
      found[row.uid] = true
      first = first or row.uid
    end
  end

  -- Which lines hold a selected take now -- the unit both fold options work
  -- in, because folding is per line, not per take.
  local lines_with_sel = {}
  if next(found) then
    for _, node in ipairs(state.nodes or {}) do
      if node.kind == "line" then
        for _, t in ipairs(node.takes) do
          if found[t.uid] then
            lines_with_sel[tostring(node._key)] = true
            break
          end
        end
      end
    end
  end

  -- Unfold the lines holding the matches, so the row the user just asked
  -- about is actually on screen to be outlined and scrolled to. What THIS
  -- follow opened is remembered in auto_unfolded, which is the whole of what
  -- auto-fold below is allowed to close.
  if state.follow_unfold then
    for k in pairs(lines_with_sel) do
      if not state.expanded[k] then
        state.expanded[k] = true
        state.auto_unfolded[k] = true
        state.dirty = true
      end
    end
  end

  -- Fold back what the follow itself opened once its take is deselected --
  -- and ONLY that. A card the user unfolded by hand is their decision, and
  -- snapping it shut because they clicked elsewhere in the arrange view would
  -- be the tool fighting them. Selecting another take of the same line keeps
  -- the line in lines_with_sel, so it never flaps.
  if state.follow_fold then
    for k in pairs(state.auto_unfolded) do
      if not lines_with_sel[k] then
        if state.expanded[k] then
          state.expanded[k] = nil
          state.dirty = true
        end
        state.auto_unfolded[k] = nil
      end
    end
  end

  state.selection = found
  if first then
    state.focus_key  = first
    state.anchor_key = first
    if state.follow_scroll then
      state.scroll_to_uid    = first
      state.scroll_to_frames = 2
    end
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
              .. (row.transcript or "")):lower()
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

local function LineNodeKey(node)
  return tostring(node.rep.script_row or ("asset:" .. tostring(node.rep.asset)))
end

local function ApplyFilters()
  CheckRestoredCharacter()
  for i, row in ipairs(state.overview) do row.order = i end

  state.nodes = vo.FilterGroups(vo.GroupOverview(state.overview), Matches)

  -- Two flat take lists, deliberately distinct:
  --   state.filtered  every take of every line the FILTERS admit. Tool scope
  --                   (AffectedRows) reads this: folding a line shut is
  --                   tidiness, and must not silently shrink what Cut acts on.
  --   state.visible   what the eye can actually see -- filtered minus the
  --                   takes of folded lines. Selection, ranges and the
  --                   timeline follow read this, so a shift-range matches the
  --                   screen and the selection never outlives visibility.
  -- Parents and headers are in neither: only takes are selectable/actionable.
  local filtered, out = {}, {}
  for _, node in ipairs(state.nodes) do
    if node.kind == "line" then
      local open = state.expanded[LineNodeKey(node)] == true
      for _, t in ipairs(node.takes) do
        filtered[#filtered + 1] = t
        if open then out[#out + 1] = t end
      end
    elseif node.kind == "orphans" then
      for _, t in ipairs(node.takes) do
        filtered[#filtered + 1] = t
        out[#out + 1] = t
      end
    end
  end

  state.filtered = filtered
  state.visible = out
  -- Position-in-the-sheet lookup, built here rather than per frame: it is a
  -- table of one entry per visible row, and the draw loop was allocating a
  -- fresh one sixty times a second for a list that only changes here.
  local flat = {}
  for i, row in ipairs(out) do flat[row.uid] = i end
  state.flat_index = flat

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

-- The Follow menu's toggles: user preferences like the layout settings above,
-- so ExtState, not the project file.
local FOLLOW_KEYS = { "follow_scroll", "follow_unfold", "follow_fold" }

local function LoadFollowSettings()
  for _, key in ipairs(FOLLOW_KEYS) do
    local raw = r.GetExtState(vo.EXT_SECTION, key)
    if raw == "1" then state[key] = true
    elseif raw == "0" then state[key] = false end
  end
end

local function SetFollowSetting(key, value)
  state[key] = value
  r.SetExtState(vo.EXT_SECTION, key, value and "1" or "0", true)
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
  state.view.sizes   = view.LoadFontSizes()
  state.view.cols    = {}
  for _, key in ipairs(ColumnKeys()) do
    -- With restore off the stored per-column settings are ignored AND cleared
    -- (see SetRestore), so this branch only ever sees an empty store. Reading
    -- the defaults explicitly keeps that true even if a key survives somehow.
    state.view.cols[key] = state.view.restore and view.LoadColumn(key)
                           or view.NormalizeColumn(key, nil)
  end
end

local function ColumnView(key)
  return state.view.cols[key] or view.NormalizeColumn(key, nil)
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
-- `rule` ("last"/"first") overrides the remembered choice for this run and is
-- then remembered as it: two explicit buttons replaced the rule combo, and the
-- hero's batch run should pick the way the user last picked.
local function AutoSelectTakes(rows, rule)
  if rule then
    state.auto_select_take = rule
    local cfg = vo.LoadConfig()
    cfg.auto_select_take = rule
    vo.SaveConfig(cfg)
  end

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
  -- One rebuild for the whole pass, not one per line. SetSelect also clears
  -- each sibling it displaces, so the naive cost was two rebuilds per line.
  Batch(function()
    for _, row in pairs(best) do
      -- An alt is not an answer to "which take is the delivery", so a line
      -- whose only mark is an alt still has one to make and this fills it in.
      if not row.user_select then
        SetSelect(row, true)
        changed = changed + 1
      end
    end
  end)

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

-- -----------------------------------------------------------------------
-- Resolving one orphan
--
-- "Not on the script" was a dead end: a pile of unknown audio with nothing
-- offered to do about any single entry, and a session does not feel finished
-- while it is sitting there. It should be a QUEUE -- every span gets looked at
-- and decided, one of three ways, and then it leaves.
--
--   Try again    -- match this span alone, at a threshold a sweep would not
--                   dare use. A person looking at one span can accept weaker
--                   evidence than a pass over sixteen hundred words should: the
--                   risk that makes the global setting conservative is a wrong
--                   name written silently across the session.
--   This is line -- hand it to a line. The name is the assignment, so this is
--                   a marker or a rename underneath, but the user is picking a
--                   LINE, not typing a filename.
--   This is junk -- slate, chatter, a cough, a false start. Persisted, since it
--                   is a judgement about audio and belongs with the marks, and
--                   out of the count.
-- -----------------------------------------------------------------------

-- Slate, chatter, a cough. Stored as the row's status, which is the same
-- mechanism Lock and Flag use, so it rides in the project file with the marks
-- and survives a rematch.
local function DismissOrphan(row, junk)
  SetStatus(row, junk and "junk" or nil)
  state.message, state.message_kind = junk
    and "Dismissed. It no longer counts against \"not on the script\"."
    or  "Back in the queue.", "ok"
end

-- Which script lines this span could be, memoized on the words themselves: the
-- menu asks every frame it is open, and the answer cannot change while it is.
-- (The memo lives at the top of the file so Rebuild can clear it.)
local function OrphanLineHits(row)
  local text = row.transcript or ""
  local hit = orphan_hits_memo[text]
  if not hit then
    hit = vo.FindSpanLines(state.lines or {}, text, vo.LoadConfig(), { limit = 8 })
    orphan_hits_memo[text] = hit
  end
  return hit
end

-- Hand this span to a line.
--
-- Two shapes, because an orphan may or may not have been cut out yet. If it has
-- an item of its own, the item is renamed -- that IS the assignment. If it is
-- still a stretch inside a longer recording, a ranged take marker is written
-- where the span is, which is the same thing Cut would later act on.
local function AssignOrphanToLine(row, hit)
  local name = hit.deliver or hit.asset
  if not name or name == "" then
    state.message, state.message_kind =
      "That script line has no filename to name the audio after.", "error"
    return
  end

  if row.item then
    local take = r.GetActiveTake(row.item)
    if not take then
      state.message, state.message_kind = "That item has no take to name.", "error"
      return
    end
    state.name_baseline = nil
    core.Transaction("VO Overview: assign orphan to line", function()
      r.GetSetMediaItemTakeInfo_String(take, "P_NAME", vo.SanitizeName(name), true)
    end)
    r.UpdateArrange()
    Reload()
    state.message, state.message_kind = "Named that item " .. name .. ".", "ok"
    return
  end

  local item = row.source_path and row.source_start and row.source_stop
    and vo.ResolveSourceSpanForCut(row.source_path, row.source_start,
                                   row.source_stop, state.items)
  if not item then
    state.message, state.message_kind =
      "That audio is not in the project any more, so there is nothing to mark.", "error"
    return
  end

  local id = vo.MintMarkerId(TakenMarkerIds())
  local list = { { start = row.source_start, stop = row.source_stop,
                   asset = hit.asset, id = id } }
  -- Existing tool markers ride along: WriteTakeMarkers replaces the tool's set
  -- wholesale, and dropping them would orphan every other take in this item.
  local ok0, chunk0 = r.GetItemStateChunk(item, "", false)
  if ok0 then
    for _, m in ipairs(vo.ParseTKMChunk(chunk0)) do
      local asset0, id0 = vo.ParseMarkerName(m.name)
      if id0 then
        list[#list + 1] = { start = m.pos, stop = m.pos + (m.length or 0),
                            asset = asset0, id = id0 }
      end
    end
  end

  local wrote, why
  core.Transaction("VO Overview: assign orphan to line", function()
    wrote, why = vo.WriteTakeMarkers(item, list)
  end)
  if not wrote then
    state.message, state.message_kind =
      "Could not write the marker: " .. tostring(why), "error"
    return
  end

  -- The row's decisions ride onto the marker's key rather than being stranded
  -- on a span that no longer exists.
  for _, e in ipairs(state.entries) do
    if e.key == row.key then e.key = "tkm|" .. id end
  end
  state.dirty = true
  Reload()
  state.message, state.message_kind = string.format(
    "Marked that stretch as %s. Cut will split it out.", name), "ok"
end

-- Link a real item to a PLANNED take: the rename IS the link (the name is the
-- assignment), and the planned row has served its purpose -- it is removed in
-- the same stroke, and the named item's own row takes its place on the next
-- rebuild. Notes on the planned row go with it; they described the intention,
-- and the recorded take's row has a Note field of its own.
local function LinkPlannedTake(row)
  if r.CountSelectedMediaItems(0) == 0 then
    state.message, state.message_kind =
      "Select the item in REAPER first, then press + again.", "warn"
    return
  end
  for i, e in ipairs(state.entries) do
    if e.key == row.key then table.remove(state.entries, i) break end
  end
  state.dirty = true
  AssignSelectedItems(row, row.deliver or row.asset)
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
-- What the next press acts on: the selection, made either way, else everything
-- the filters are showing.
--
-- No toggle. "Selected rows only" was a checkbox deciding whether the sheet's
-- selection counted, defaulting to OFF because clicking a row to audition it
-- also selects its item -- so the tool protected itself from its own selection
-- by ignoring it. The honest fix is the opposite: honour the selection always
-- and SHOW what it resolved to (DrawScopeLine), so narrowing is visible rather
-- than defended against.
--
-- Filtered, not visible: a line folded shut is still in scope. Folding is how
-- the sheet is tidied, not how a run is narrowed.
local function AffectedRows()
  return vo.ResolveScope(state.filtered, state.selection, SelectedItemSet())
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
  -- Both selections count, and REAPER's is taken as given rather than mapped
  -- through the sheet: Pull and Sort serve folders of rendered files that have
  -- no rows at all, so an item selected in the arrange must be actionable even
  -- when nothing in the sheet knows about it.
  local chosen = SelectedItemSet()
  local from_reaper = next(chosen) ~= nil
  local from_rows = false
  for _, row in ipairs(SelectedRows()) do
    if row.item then
      chosen[row.item] = true
      from_rows = true
    end
  end

  local scope = "every item in the project"
  if from_reaper and from_rows then scope = "the selected items and rows"
  elseif from_reaper           then scope = "the items selected in REAPER"
  elseif from_rows             then scope = "the items behind the selected rows" end
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
-- What the next press will act on, always on screen.
--
-- This replaced the "Selected rows only" checkbox, and it is the safety the
-- checkbox was pretending to be. Every verb is selection-driven now, and the
-- hazard that made the old default OFF is real -- clicking a row to audition it
-- selects its item, so listening can narrow the next run. The answer is not to
-- ignore the selection; it is to never let the scope be a surprise. If this
-- line says "3 takes", nothing can act on 169.
local function DrawScopeLine()
  local rows, narrowed = AffectedRows()
  local n = #rows
  if not narrowed then
    im.TextDisabled(ctx, string.format(
      "Acting on all %d row(s) in view \226\128\148 select rows here, or items in " ..
      "REAPER, to narrow.", n))
    return
  end
  if n == 0 then
    im.TextColored(ctx, 0xDDAA33FF,
      "Nothing selected is in view \226\128\148 the filters are hiding it. " ..
      "Clear the filters, or select something showing here.")
    return
  end
  im.TextColored(ctx, 0x7FA0C0FF, string.format(
    "Acting on %d selected row(s).", n))
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Every button below acts on this, not on the whole\n" ..
                       "session. Deselect everything to act on all of it.\n\n" ..
                       "Selecting a recording that has not been cut yet selects\n" ..
                       "every take inside it.")
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
  local counts = { spans = #all_spans, cuttable = 0, in_range = 0, stale = 0, edited = 0 }
  local candidates = {}
  local edited_names = {}

  -- The counting markers per source, so a span can ask "does a marker already
  -- own this audio?" Markers are the user's tracked takes; Cut re-slicing one
  -- would overwrite their work, so those spans are skipped (below) unless the
  -- run is a deliberate Re-cut anyway.
  local markers_by_path = {}
  for path, group in pairs(state.take_markers or {}) do
    markers_by_path[path] = vo.CountingMarkers(group)
  end
  local function marker_owning(s)
    for _, mk in ipairs(markers_by_path[s.source_path] or {}) do
      if mk.start < (s.stop or 0) and mk.stop > (s.start or 0) then return mk end
    end
    return nil
  end
  for _, s in ipairs(all_spans) do
    local key = start_key(s.source_path, s.start)
    local row = by_start[key]
    if row then s.select = row.user_select == true end

    if s.kind == "match" or s.kind == "review" then
      counts.cuttable = counts.cuttable + 1
      if in_range[key] then
        counts.in_range = counts.in_range + 1
        local mk = (not state.force_recut) and marker_owning(s) or nil
        -- A marker is what the cut WILL be, so the cut follows it.
        --
        -- This used to SKIP the span: a marker meant "the user is tracking
        -- this take, do not overwrite their work". That was defensible while
        -- markers were only ever put down by hand -- and fatal once Identify
        -- started writing them, because Identify then Cut skipped every take
        -- it had just marked and the session cut nothing.
        --
        -- Honouring the marker serves both cases better. A marker the user
        -- dragged is their edit and the clip lands on it; a marker Identify
        -- wrote is the cut's own plan and the clip lands where the preview
        -- said. Nothing is silently overwritten either way, because the
        -- marker decides. "Re-cut anyway" still exists to throw the markers
        -- away and re-derive the edges from the transcript.
        if mk then
          counts.edited = counts.edited + 1
          s.marker_start, s.marker_stop = mk.start, mk.stop
        end
        -- Cutting to word timings the audio no longer matches would put the
        -- edges in the wrong places, so a stale source is skipped -- per
        -- source, so one re-recorded file cannot stop the others. A marker
        -- is exempt: its edges were decided against the audio as it is now,
        -- not against the transcript, so a stale source cannot invalidate it.
        if stale_paths[s.source_path] and not mk then
          counts.stale = counts.stale + 1
        else
          s.in_range = true
          candidates[#candidates + 1] = s
        end
      end
    end
  end
  counts.candidates = #candidates

  return candidates, all_spans, stale_names, counts, edited_names
end

local function DoCut()
  -- A fresh look first: the per-frame rescan is throttled, and cutting
  -- against items collected seconds ago is how stale pointers get split.
  Reload()
  state.name_baseline = nil
  local cfg = vo.LoadConfig()
  local candidates, all_spans, stale_names, _counts, edited_names = CutCandidates()
  state.cut_skipped_edited = edited_names or {}
  -- The override is consumed by the run it was armed for, never the next one.
  state.force_recut = false

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
      -- A marker decides this take's edges: they were already snapped (by
      -- Identify) or set by hand (by a drag), so they are the answer and the
      -- padding pass must not move them again.
      if s.marker_start and s.marker_stop then
        c.start = vo.SourceTimeToProject(s.marker_start, info)
        c.stop  = vo.SourceTimeToProject(s.marker_stop,  info)
        c.from_marker = true
      end
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

      -- Only the spans whose edges are still open. A span carrying marker
      -- bounds has already been decided -- by Identify's preview, or by the
      -- user dragging the marker -- and re-padding it would move the clip off
      -- the marker that promised it.
      local open = {}
      for _, s in ipairs(g.spans) do
        if not s.from_marker then open[#open + 1] = s end
      end
      if #open > 0 then
        local floor = vo.MeasureNoiseFloor(vo.InterWordGaps(proj_words), probe, cfg)
        vo.ApplyPadding(open, cfg,
          { start = g.info.pos, stop = g.info.pos + g.info.length },
          probe, floor, proj_words)
      end
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
  local applied, failures, pruned = 0, {}, 0
  core.Transaction("VO Overview: cut and name", function()
    -- MARKERS FIRST, then the splits at their bounds: split propagation
    -- carries each marker into the piece cut for it, so every clip is born
    -- knowing which performance it is. Same transaction, so one undo reverts
    -- markers and splits together.
    local taken = TakenMarkerIds()
    local marker_fails = 0
    for _, g in pairs(by_item) do
      local list = {}
      -- Existing tool markers on this item (takes cut earlier, or skipped
      -- this run) ride along: WriteTakeMarkers replaces the tool's lines
      -- wholesale, and dropping them would orphan those takes.
      local ok0, chunk0 = r.GetItemStateChunk(g.item, "", false)
      if ok0 then
        for _, m in ipairs(vo.ParseTKMChunk(chunk0)) do
          local asset0, id0 = vo.ParseMarkerName(m.name)
          if id0 then
            list[#list + 1] = { start = m.pos, stop = m.pos + (m.length or 0),
                                asset = asset0, id = id0 }
          end
        end
      end
      -- The spans hold PROJECT time after resolution and padding; markers
      -- live in SOURCE time, so each converts back through its own item.
      for _, span in ipairs(g.spans) do
        -- A span that came from a marker ALREADY HAS one -- the ride-along
        -- above just copied it. Minting a second at the same bounds is how
        -- this doubled every marker the moment Cut started honouring them
        -- instead of skipping them, and it would have been worse than
        -- cosmetic: the marks are keyed `tkm|<id>`, so a fresh id would
        -- strand the take's Sel and Keep on a marker nothing points at.
        if span.dest ~= vo.DEST_IN_PLACE and not span.from_marker then
          local from = vo.ProjectTimeToSource(span.start, g.info)
          local to   = vo.ProjectTimeToSource(span.stop,  g.info)
          if to > from then
            list[#list + 1] = { start = from, stop = to,
                                asset = span.asset or span.deliver or span.name,
                                id = vo.MintMarkerId(taken) }
          end
        end
      end
      if #list > 0 then
        local okw = vo.WriteTakeMarkers(g.item, list)
        if not okw then marker_fails = marker_fails + 1 end
      end
    end
    if marker_fails > 0 then
      failures[#failures + 1] = string.format(
        "%d item(s): take markers could not be written", marker_fails)
    end

    for _, g in pairs(by_item) do
      local a, f = vo.ApplyPlan(g.spans, g.info.track)
      applied = applied + a
      for _, msg in ipairs(f) do failures[#failures + 1] = msg end
    end

    -- Cut cleans up after itself, in the same undo step.
    --
    -- REAPER's split copies the WHOLE take-marker set into BOTH halves, so
    -- cutting one recording into 451 clips left every clip carrying all 409 of
    -- the session's markers: 184,000 marker lines and 24MB of item chunk for
    -- 409 real takes. Nothing looked wrong, because the coverage rule in
    -- vo.CountingMarkers ignores residue -- it just cost 566ms to READ all that
    -- chunk on every rescan before throwing 99.8% of it away, and a rescan
    -- fires whenever the project changes, which includes clicking between
    -- items. That is the stall.
    --
    -- The tidy pass already knew how to collapse it; it was simply never run
    -- unless the user pressed "Sync take markers", which nothing told them to
    -- do. The Reload is what makes the freshly split items visible to it.
    Reload()
    pruned = MirrorTakeMarkers()
  end)

  state.cut_summary = vo.FormatCutSummary(all_spans, applied, skipped_msgs, failures)
  if pruned > 0 then
    state.cut_summary[#state.cut_summary + 1] = {
      text = string.format(
        "Tidied the take markers REAPER's split copied onto %d clip(s).", pruned),
    }
  end

  if #state.cut_skipped_edited > 0 then
    table.insert(state.cut_summary, {
      text = string.format(
        "%d take(s) skipped -- their markers own that audio: %s",
        #state.cut_skipped_edited,
        table.concat(state.cut_skipped_edited, ", ")),
      warn = true,
    })
  end

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

-- Cut, wrapped. An error in the cut path used to escape into the defer loop,
-- which stops the script dead and looks exactly like the button doing nothing.
-- Whatever went wrong belongs on screen.
local function RunCut()
  local ok, err = pcall(DoCut)
  if not ok then
    state.message, state.message_kind = "Cut failed: " .. tostring(err), "error"
    state.cut_result, state.cut_result_kind = state.message, "error"
    r.ShowConsoleMsg("ajsfx VO — Cut FAILED\n" .. tostring(err) .. "\n\n")
  end
  -- The report opens itself. Cut is the one verb whose result needs more than
  -- a message line: which stage lost spans, what was skipped and why.
  state.panel = "cut"
end

-- The REPORT, not the controls. This panel used to carry a "Cut and Name"
-- button (a second copy of the toolbar button that opened it), a "Selected
-- rows only" checkbox, and a live pre-flight counter that existed to show what
-- that checkbox would do. The toolbar button now cuts on the press and the
-- scope line above says what it will act on, so all three are gone and what is
-- left is what the run did.
local function DrawCutPanel()
  im.Separator(ctx)
  -- Only after a run that actually skipped something: the override discards
  -- hand-edits, so it must never be a button standing permanently ready.
  if #(state.cut_skipped_edited or {}) > 0 then
    if im.Button(ctx, "Re-cut anyway") then
      pending_action = function()
        -- Delete the markers of exactly the skipped takes -- by delivered
        -- name, the same identity the skip reported -- so their audio is
        -- unowned again and the re-run cuts it fresh with new markers. Takes
        -- the run did not skip keep theirs untouched.
        local doomed = {}
        for _, name in ipairs(state.cut_skipped_edited) do doomed[name] = true end
        core.Transaction("VO Overview: delete take markers for re-cut", function()
          for _, group in pairs(state.take_markers or {}) do
            for _, rec in ipairs(group) do
              local survivors, changed = {}, false
              for _, m in ipairs(vo.ParseTKMChunk(select(2,
                  r.GetItemStateChunk(rec.info.item, "", false)) or "")) do
                local asset, id = vo.ParseMarkerName(m.name)
                if id and doomed[asset] then
                  changed = true
                else
                  if id then
                    survivors[#survivors + 1] = { start = m.pos,
                      stop = m.pos + (m.length or 0), asset = asset, id = id }
                  end
                end
              end
              if changed then vo.WriteTakeMarkers(rec.info.item, survivors) end
            end
          end
        end)
        state.force_recut = true
        RunCut()
      end
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Throw those takes' markers away and work the edges out\n" ..
                         "from the transcript again. For when a marker is in the\n" ..
                         "wrong place; the same thing as deleting the markers by\n" ..
                         "hand, then Cut.")
    end
  end

  if im.Button(ctx, "Close##cut") then state.panel = nil end

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


-- Pull's destinations: naming them, finding what they nest under, and building
-- them. One table rather than three file locals -- the main chunk sits at Lua's
-- 200-local ceiling, so related helpers share a namespace instead of each
-- taking a slot.
local Dest = {}

-- The destination track names, from config.
function Dest.names()
  local cfg = vo.LoadConfig()
  return { selects = cfg.track_selects or "Selects",
           alts    = cfg.track_alts    or "Alts",
           review  = cfg.track_review  or "Review" }
end

-- The recording an item came out of: the track it sits on, or the nearest
-- ancestor that is not itself a destination.
--
-- Pull runs more than once -- that is the whole workflow -- so by the second
-- pass an item is sitting on "<CHAR>_Review", and nesting its new destination
-- under THAT would bury a track inside a track on every run.
function Dest.recording_of(item, bases)
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

-- Selects / Alts / Review, nested under each recording, without moving
-- anything.
--
-- Pull creates these as a side effect of having somewhere to put an item, so
-- until the first successful pull there is nowhere to drag a take by hand and
-- no way to see the shape the session is heading for. Making it its own verb
-- costs nothing -- the folder work already existed inside Pull, and now both
-- call the same two helpers -- and it means the destinations can exist before
-- anything is decided.
--
-- Scope is the selection, like everything else: the recordings behind the
-- selected items, or every recording when nothing is selected.
function Dest.build()
  Reload()
  local base  = Dest.names()
  local bases = { base.selects, base.alts, base.review }

  local picked = SelectedItemSet()
  local scoped = next(picked) ~= nil

  -- One entry per recording track, in track order so the report is stable and
  -- the folders are built top-down.
  local parents, seen = {}, {}
  for _, info in ipairs(state.items or {}) do
    local item = info.item
    if item and not info.skip and ((not scoped) or picked[item]) then
      local parent = Dest.recording_of(item, bases)
      if parent and not seen[parent] then
        seen[parent] = true
        parents[#parents + 1] = parent
      end
    end
  end

  if #parents == 0 then
    state.message, state.message_kind = scoped
      and "Nothing selected sits on a recording track."
      or  "No audio in this project to build destinations under.", "warn"
    return
  end

  table.sort(parents, function(a, b)
    return r.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER")
         < r.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")
  end)

  local made = 0
  core.Transaction("VO Overview: build pull tracks", function()
    for _, parent in ipairs(parents) do
      -- Created in REVERSE so they read Selects / Alts / Review top to bottom:
      -- EnsureChildTrack inserts directly below the parent, so each new one
      -- pushes the earlier ones down.
      for _, cat in ipairs({ "review", "alts", "selects" }) do
        local before = r.CountTracks(0)
        vo.EnsureChildTrack(parent, base[cat])
        if r.CountTracks(0) > before then made = made + 1 end
      end
    end
  end)
  r.UpdateArrange()
  Reload()

  state.message, state.message_kind = (made > 0)
    and string.format("Built %d track(s) under %d recording(s): %s, %s, %s.",
          made, #parents, base.selects, base.alts, base.review)
    or  string.format("Every one of the %d recording(s) already has its %s, %s and %s.",
          #parents, base.selects, base.alts, base.review), "ok"
end

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
  local base = Dest.names()

  local by_id = {}
  for _, it in ipairs(items) do by_id[it.id] = it end

  local bases = { base.selects, base.alts, base.review }

  core.Transaction("VO Overview: pull", function()
    local tracks = {}

    -- The trio reads Selects / Alts / Review top to bottom. EnsureChildTrack
    -- inserts directly below the parent, so they are created in REVERSE --
    -- each new one pushes the earlier ones down.
    local seen_parents = {}
    for _, move in ipairs(moves) do
      local parent = Dest.recording_of(move.id, bases)
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
          local p = Dest.recording_of(it.id, bases)
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
      local parent = Dest.recording_of(item, bases)
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

-- The whole of Pull, in one press: build the tracks, file the items onto them,
-- lay them out on the timeline.
--
-- These three are almost never wanted apart. Building without pulling is for
-- seeing the shape before the first pull; laying out without pulling sorts
-- items that are still sitting on their recording. The normal case is all
-- three, and until now that was three presses and three undo steps.
--
-- The three steps keep their own transactions, and this wraps them in one
-- more: REAPER collapses nested undo blocks into the outermost, so the press
-- is a single point in the undo history rather than three.
--
-- Each step reports through state.message as usual, so the messages are
-- captured as they go and read back as one line. A step with nothing to do
-- says so and the next one still runs -- the same "tidy up what it can" rule
-- the marker verbs follow. Nothing here aborts the rest.
function Dest.deliver()
  local parts = {}
  local worst = "ok"
  local function step(fn)
    state.message, state.message_kind = nil, nil
    fn()
    if state.message and state.message ~= "" then
      parts[#parts + 1] = state.message
      -- "error" here means "this step found nothing to do", not a failure of
      -- the press: the run continues and the colour only has to carry that
      -- SOMETHING wants looking at.
      if state.message_kind ~= "ok" and worst == "ok" then worst = "warn" end
    end
  end

  core.Transaction("VO Overview: deliver", function()
    step(Dest.build)
    step(Pull)
    step(SortOnTimeline)
  end)

  r.UpdateArrange()
  Reload()
  state.message, state.message_kind = table.concat(parts, " "), worst
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
  -- confusion: the button names alts, and an alt is a row with Alt ticked and
  -- Sel not. (Alt is the label; the stored mark is still `keep`.)
  local why = ""
  if named == 0 and skipped == 0 then
    local keeps, sels = 0, 0
    for _, row in ipairs(rows) do
      if row.user_keep then keeps = keeps + 1 end
      if row.user_select then sels = sels + 1 end
    end
    why = string.format(
      " No alts in range: %d row(s) shown, %d with Alt ticked, %d with Sel. " ..
      "An alt is Alt ticked and Sel not.", #rows, keeps, sels)
  end

  state.message, state.message_kind = string.format(
    "Named %d alt%s.%s%s", named, named == 1 and "" or "s",
    skipped > 0 and string.format(" %d already had a name and were left alone.", skipped) or "",
    why),
    (named > 0) and "ok" or "error"
  state.pull_result, state.pull_result_kind = state.message, state.message_kind
end

-- The Sheet tab's one action (SPEC-toolbar.md section 4): re-read every
-- transcript, identify the lines again from scratch, and make the timeline's
-- word on marks explicit.
--
-- It changes NOTHING but the sheet. It used to carry two opt-ins that named
-- takes and pulled them, which put item surgery behind a Sheet button and
-- broke the one rule the toolbar is built on. Both jobs already live in the
-- Items tab, where a button that changes audio belongs.
local function TidyPass()
  local cfg = vo.LoadConfig()
  Reload()
  local refreshed = #state.overview

  -- The timeline's word on marks, made explicit -- the same write Repair's
  -- "Adopt timeline" does, without the panel trip.
  local plan = vo.PlanReconcile(state.overview, cfg)
  local adopted = #plan.disagree
  for _, f in ipairs(plan.disagree) do
    local want = vo.MarkFromTrack(f.row.track_name, cfg)
    Mutate(f.row, function(e)
      e.select = (want == "select") or nil
      e.keep   = (want == "keep")   or nil
    end)
  end

  local conflicts = vo.SelectConflicts(state.overview)
  local bits = { string.format("%d line%s refreshed", refreshed,
                               refreshed == 1 and "" or "s") }
  if adopted > 0 then bits[#bits + 1] = adopted .. " mark(s) adopted from the timeline" end
  if #conflicts > 0 then
    bits[#bits + 1] = #conflicts .. " line(s) with two selects -- pick one"
  end
  state.message = "Sheet: " .. table.concat(bits, ", ") .. "."
  state.message_kind = (#conflicts > 0) and "warn" or "ok"
  state.dirty = true
end

-- Delete this project's VO data so the session can be processed again from
-- scratch. Testing needs this constantly, and doing it by hand means quitting
-- REAPER first: the Overview holds its own copy of the project file and
-- flushes it on the way out, so a sidecar deleted from Explorer with the
-- window open simply comes back. That is also why this lives HERE rather than
-- in the Settings window -- only the process holding the file can drop it and
-- forget what it was holding.
--
-- It never touches audio. Items, take names and take markers are REAPER's, and
-- undo is what reverses those.
local function ResetProject(also_transcripts)
  local removed, failed = {}, {}
  local function drop(path)
    if not path or path == "" then return end
    local f = io.open(path, "r")
    if not f then return end                 -- nothing there is not a failure
    f:close()
    local ok = os.remove(path)
    if ok then removed[#removed + 1] = vo.Basename(path)
    else failed[#failed + 1] = vo.Basename(path) end
  end

  drop(state.project_path or vo.ProjectFilePath(ProjectPath()))
  if also_transcripts then
    for _, path in ipairs(vo.ProjectSourcePaths(state.items) or {}) do
      drop(vo.TranscriptPath(path))
    end
  end

  -- Forget everything read from those files BEFORE anything can save again,
  -- or the in-memory copy writes the sidecar straight back.
  state.entries, state.scripts, state.appends, state.pins = {}, {}, {}, {}
  state.loaded = { scripts = {}, lines = {} }
  state.selection, state.expanded = {}, {}
  state.name_baseline, state.project_error = nil, ""
  state.dirty = false
  state.scanned_at = nil
  Reload()

  local bits = {}
  if #removed > 0 then bits[#bits + 1] = "deleted " .. table.concat(removed, ", ") end
  if #failed  > 0 then bits[#bits + 1] = "COULD NOT delete " .. table.concat(failed, ", ") end
  if #bits == 0 then bits[1] = "nothing to delete -- this project had no VO data" end
  state.message = "Start over: " .. table.concat(bits, "; ") .. ". Audio untouched."
  state.message_kind = (#failed > 0) and "error" or "ok"
end

-- The golden path: what a session does the first time, in order, on one press.
--
-- Match, cut, pick a take per line, pull to the tracks. Each of these is its
-- own button because each is worth running alone -- but a new session runs all
-- four, in this order, every time, and making the user rediscover that order
-- is making them learn the tool before they can use it.
--
-- The order is load-bearing. Cut needs the match to know where takes are; the
-- pick needs the takes to exist; Pull routes by the marks the pick just made.
--
-- Everything that touches items runs inside ONE transaction, so the whole pass
-- is a single undo. The match is sheet-only and sits outside it: undoing the
-- audio should not throw away tracking that is still true.
local function GoldenPath()
  TidyPass()
  local matched = state.message or ""

  local cut_err
  core.Transaction("VO Overview: run the whole pass", function()
    local ok, err = pcall(DoCut)
    if not ok then
      cut_err = tostring(err)
      return          -- a failed cut leaves nothing to pick or pull
    end
    Reload()
    AutoSelectTakes(AffectedRows())
    Pull()
  end)

  state.name_baseline = nil
  Reload()

  if cut_err then
    state.message, state.message_kind =
      "Stopped at the cut, so nothing was picked or pulled: " .. cut_err, "error"
    r.ShowConsoleMsg("ajsfx VO -- whole pass FAILED at the cut\n" .. cut_err .. "\n\n")
    return
  end

  -- Each step already wrote its own report; the last one standing is Pull's,
  -- which is the one that says whether audio reached its tracks. Lead with the
  -- match so the pass reads in the order it ran.
  state.message = matched .. "  |  " .. (state.pull_result or "Pulled.")
  state.message_kind = state.pull_result_kind or "ok"
  state.dirty = true
end

local function DrawPullPanel()
  im.Separator(ctx)
  im.TextWrapped(ctx,
    "Moves items onto Selects, Alts and Review tracks nested under the recording " ..
    "they came from. Sel is the delivery, Alt is delivered alongside it as an " ..
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
  -- The old toolbar's "Place": the same verb at a different scope, so it
  -- belongs beside Pull rather than a button away from it.
  if im.Button(ctx, "Pull the selected item(s) only") then
    pending_action = PlaceSelectedItems
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "File the item(s) selected in REAPER where their NAME says they\n" ..
                       "belong: a plain delivered name goes to Selects, an alt-patterned\n" ..
                       "one to Alts. Rename first, press this, the sheet follows.")
  end
  im.SameLine(ctx)
  if im.Button(ctx, "Close##pull") then state.panel = nil end
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

-- Reconciliation, not repair-by-magic: two sources of truth for what a take is
-- and where it belongs, and a button for each direction. Nothing here acts
-- without a press, and every finding can be clicked to go and look at it.
local REPAIR_LIST_CAP = 12

-- "Fix a line" was one panel holding three different problems, and the button
-- name said none of them. It is now two panels, split by REMEDY rather than by
-- diagnosis: disagreements have batch fixes (adopt one side or the other),
-- while a take whose audio is gone can only be relinked or cleared by hand --
-- two lists that were three sections, since unbacked markers and orphaned
-- marks always shared the same Relink. Each button wears its count, so the
-- Check row reads as state, not as navigation.

local function DrawDisagreePanel()
  local cfg  = vo.LoadConfig()
  local plan = state.reconcile or vo.PlanReconcile(state.overview, cfg)

  if #plan.disagree == 0 then
    im.TextColored(ctx, 0x66BB66FF,
      "Every take's marks agree with the track its item sits on.")
    im.Separator(ctx)
    return
  end

  -- Bring a finding's row into view and select it.
  local function GoTo(row)
    state.selection        = { [row.uid] = true }
    state.focus_key        = row.uid
    state.scroll_to_uid    = row.uid
    state.scroll_to_frames = 2
  end
  do
    im.TextColored(ctx, 0xDDAA33FF, string.format(
      "%d take(s) disagree with where their item sits:", #plan.disagree))
    for i, f in ipairs(plan.disagree) do
      if i > REPAIR_LIST_CAP then
        im.TextDisabled(ctx, string.format("   ...and %d more",
          #plan.disagree - REPAIR_LIST_CAP))
        break
      end
      im.Bullet(ctx)
      im.SameLine(ctx)
      if im.SmallButton(ctx, string.format("%s -- %s##dis%d",
          f.row.deliver or f.row.asset or "(unnamed)", f.detail, i)) then
        local captured = f.row
        pending_action = function() GoTo(captured) end
      end
    end
    if im.Button(ctx, "Adopt timeline") then
      local findings = plan.disagree
      pending_action = function()
        -- The tracks win: write the mark each item's placement implies as an
        -- EXPLICIT decision, so the result is stable and not re-inferred.
        for _, f in ipairs(findings) do
          local want = vo.MarkFromTrack(f.row.track_name, cfg)
          Mutate(f.row, function(e)
            e.select = (want == "select") or nil
            e.keep   = (want == "keep")   or nil
          end)
        end
        state.message, state.message_kind = string.format(
          "Adopted the timeline for %d take(s).", #findings), "ok"
      end
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Set each take's Sel/Alt to match the track its item is on.")
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Adopt sheet") then
      state.tab, state.panel, state.tab_sync = "edit", "pull", 4
      state.message, state.message_kind =
        "The marks are right -- run Pull to move the items to match them.", "info"
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "The marks are right; the items are in the wrong place.\n" ..
                         "Opens the Pull panel, which is what moves them.")
    end
    im.Separator(ctx)
  end
end

local function DrawNoAudioPanel()
  local plan = state.reconcile
               or vo.PlanReconcile(state.overview, vo.LoadConfig())

  if #plan.unbacked_markers + #plan.orphan_marks == 0 then
    im.TextColored(ctx, 0x66BB66FF,
      "Every marker and every mark has audio under it.")
    im.Separator(ctx)
    return
  end

  -- Markers whose audio is gone.
  if #plan.unbacked_markers > 0 then
    im.TextColored(ctx, 0xDD6666FF, string.format(
      "%d take marker(s) with no audio under them:", #plan.unbacked_markers))
    for i, f in ipairs(plan.unbacked_markers) do
      if i > REPAIR_LIST_CAP then
        im.TextDisabled(ctx, string.format("   ...and %d more",
          #plan.unbacked_markers - REPAIR_LIST_CAP))
        break
      end
      im.Bullet(ctx)
      im.SameLine(ctx)
      im.TextDisabled(ctx, f.row.deliver or f.row.asset or "(unnamed)")
      im.SameLine(ctx)
      if im.SmallButton(ctx, "Relink##unb" .. i) then
        local captured = f.row
        pending_action = function() AddTakeMarkerFromSelection(captured) end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, "Write this take's marker onto the item selected in REAPER.")
      end
    end
    im.TextDisabled(ctx,
      "The item this marker lived in was deleted or trimmed past it. Relink\n" ..
      "to the right item, or Remove Extra Take Markers to drop the leftovers.")
    im.Separator(ctx)
  end

  -- Marks with nothing to attach to.
  if #plan.orphan_marks > 0 then
    im.TextColored(ctx, 0xDDAA33FF, string.format(
      "%d take(s) carry marks but have no audio in this project:",
      #plan.orphan_marks))
    for i, f in ipairs(plan.orphan_marks) do
      if i > REPAIR_LIST_CAP then
        im.TextDisabled(ctx, string.format("   ...and %d more",
          #plan.orphan_marks - REPAIR_LIST_CAP))
        break
      end
      im.Bullet(ctx)
      im.SameLine(ctx)
      im.TextDisabled(ctx, f.row.deliver or f.row.asset or "(unnamed)")
      im.SameLine(ctx)
      if im.SmallButton(ctx, "Relink##orph" .. i) then
        local captured = f.row
        pending_action = function() AddTakeMarkerFromSelection(captured) end
      end
    end
    im.TextDisabled(ctx,
      "These are usually a deleted take marker, or marks from before markers\n" ..
      "existed. Relink one to the item it belongs to, or clear its marks on\n" ..
      "the row itself.")
    im.Separator(ctx)
  end

  im.Separator(ctx)
end

local function DrawFilters()
  -- Every control here writes state.dirty: the filters are stored in the project
  -- file so the table opens the way it was left. The flush is throttled, so a
  -- filter box being typed into does not write a file per keystroke.

  -- Characters come from the rows, not the CSV: an orphan can carry a character
  -- the current script filter excludes, and hiding it from the droplist would
  -- make that row unreachable. Built in Rebuild, not here -- see the note there.
  local chars = state.characters or { { key = "__all__", label = "(all characters)" } }

  -- Search first: it is the row's highest-frequency control (SPEC-toolbar.md
  -- section 3), and this whole row only changes what is LOOKED AT -- every
  -- control that acts on the session lives on row 1.
  im.SetNextItemWidth(ctx, 200)
  local s_changed, s_text = im.InputTextWithHint(ctx, "##search", "Search…", state.search)
  if s_changed then state.search = s_text; state.dirty = true end
  im.SameLine(ctx)

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
    im.SetTooltip(ctx, "Show a box per field, to narrow the sheet by what a\n" ..
                       "field contains. Filters pick LINES: a match on any take\n" ..
                       "keeps its whole card.")
  end
  if filtering then
    im.SameLine(ctx)
    if im.Button(ctx, "Clear filters") then
      state.col_filters = {}
      state.dirty = true
    end
  end
  im.SameLine(ctx)

  -- Fold every line at once. Folding is per line and persisted; these two
  -- are just the bulk versions of clicking every arrow.
  if im.Button(ctx, "Unfold all") then
    for _, node in ipairs(vo.GroupOverview(state.overview)) do
      if node.kind == "line" then
        state.expanded[LineNodeKey(node)] = true
      end
    end
    state.dirty = true
  end
  im.SameLine(ctx)
  if im.Button(ctx, "Fold all") then
    state.expanded = {}
    state.dirty = true
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Fold every line down to its title band.")
  end
  im.SameLine(ctx)

  -- How the sheet follows the ARRANGE view. Three independent toggles, all
  -- user preferences (ExtState), none project state.
  if im.Button(ctx, "Follow") then im.OpenPopup(ctx, "##follow_menu") end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "What the sheet does when you select items in the arrange view.")
  end
  if im.BeginPopup(ctx, "##follow_menu") then
    local hit, v = im.Checkbox(ctx, "Auto scroll to the selected take", state.follow_scroll)
    if hit then SetFollowSetting("follow_scroll", v) end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Scrolls only when the line is off screen, and only the\n" ..
                         "minimum: a line below lands at the bottom edge, a line\n" ..
                         "above at the top, so the direction tells you which way\n" ..
                         "the sheet went. Brings the WHOLE line card on screen\n" ..
                         "when it fits; only a card taller than the view narrows\n" ..
                         "to the selected take.")
    end
    hit, v = im.Checkbox(ctx, "Auto unfold the selected take's line", state.follow_unfold)
    if hit then SetFollowSetting("follow_unfold", v) end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "A folded line shows no take rows, so without this a\n" ..
                         "timeline click can only outline the card itself.")
    end
    hit, v = im.Checkbox(ctx, "Auto fold it again when deselected", state.follow_fold)
    if hit then SetFollowSetting("follow_fold", v) end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Only folds lines the follow itself unfolded -- never one\n" ..
                         "you opened by hand. Selecting another take of the same\n" ..
                         "line keeps it open.")
    end
    im.EndPopup(ctx)
  end

  -- The per-field boxes, on their own line under the toolbar. In the sheet
  -- these lived under the column headers; cards have no headers to live
  -- under, so each box wears its field's name as its hint.
  if state.filter_row then
    local first = true
    for _, c in ipairs(COLUMNS) do
      if c.text and not c.nofilter then
        if first then first = false else im.SameLine(ctx) end
        im.PushID(ctx, "flt_" .. c.key)
        im.SetNextItemWidth(ctx, 150)
        local fchanged, ftext = im.InputTextWithHint(ctx, "##f", c.label,
                                                     state.col_filters[c.key] or "")
        if fchanged then state.col_filters[c.key] = ftext; state.dirty = true end
        if im.IsItemHovered(ctx) and c.tip then im.SetTooltip(ctx, c.tip) end
        im.PopID(ctx)
      end
    end
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

  im.Separator(ctx)
end

-- Depth of the row ID stack, so an error thrown mid-row can be unwound. ImGui
-- does NOT balance PushID for us at EndTable: it raises "Mismatching
-- PushID/PopID" instead, which buries the real error under a second one.
local id_depth = 0

-- Depth of the text-wrap stack, unwound by DrawCards for the same reason the ID
-- and font stacks are.
local wrap_depth = 0

-- The take row's right-click menu, shared by every renderer that draws take
-- rows. Assumes it is called between BeginPopupContextItem and EndPopup.
-- Right-click acts on the whole selection when this row is part of it, and
-- on this row alone when it is not -- so right-clicking somewhere else never
-- silently operates on rows you had selected earlier.
-- The three verbs an orphan needs, at the top of its own menu: the rest of this
-- menu is about a take that already knows which line it is.
local function DrawOrphanMenu(row)
  local hits = OrphanLineHits(row)

  if im.BeginMenu(ctx, "This is line\226\128\166", #hits > 0) then
    for _, hit in ipairs(hits) do
      local label = string.format("%3d%%  %s", math.floor(hit.score * 100 + 0.5),
        (hit.text or ""):sub(1, 70))
      if im.MenuItem(ctx, label) then
        local captured_row, captured_hit = row, hit
        pending_action = function() AssignOrphanToLine(captured_row, captured_hit) end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, (hit.deliver or hit.asset or "") .. "\n\n" .. (hit.text or ""))
      end
    end
    im.EndMenu(ctx)
  end
  if #hits == 0 and im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "No script line resembles these words closely enough to\n" ..
                       "offer. Either they are not in the script, or the transcript\n" ..
                       "got them badly wrong -- listen, then dismiss or re-transcribe.")
  elseif im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Hand this audio to a script line. The best guesses first,\n" ..
                       "scored against what was said. Looser than the batch pass on\n" ..
                       "purpose: you are looking at ONE span and can judge it.")
  end

  local junk = row.user_status == "junk"
  if im.MenuItem(ctx, junk and "Bring it back into the queue"
                            or "This is junk (slate, chatter, a false start)") then
    local captured = row
    pending_action = function() DismissOrphan(captured, not junk) end
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, junk
      and "Count it again as audio still to be identified."
      or  "Decided and out of the way: it stops counting against\n" ..
          "\"not on the script\", so that number reaching zero means\n" ..
          "every span has been looked at. Nothing is deleted.")
  end

  im.Separator(ctx)
end

local function DrawTakeRowMenu(row)
  if row.status == "orphan" then DrawOrphanMenu(row) end
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

  local n_sel = r.CountSelectedMediaItems(0)
  if im.MenuItem(ctx, "Add take marker from selected item", nil, nil, n_sel == 1) then
    local captured = row
    pending_action = function() AddTakeMarkerFromSelection(captured) end
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, n_sel == 1
      and ("Writes this line's ranged take marker onto the item selected in\n" ..
           "REAPER, spanning it. The marker is the take's identity: visible in\n" ..
           "the arrange view, draggable, and Cut leaves its audio alone.")
      or  "Select exactly one item in REAPER first.")
  end
  if im.MenuItem(ctx, "Snap marker to item", nil, nil,
                 row.marker_id ~= nil and row.item ~= nil) then
    local captured = row
    pending_action = function() SnapMarkerToItem(captured) end
  end
  if im.MenuItem(ctx, "Trim item to marker", nil, nil,
                 row.marker_id ~= nil and row.item_info ~= nil) then
    local captured = row
    pending_action = function()
      local mk
      for _, m in ipairs(Trim.markers_in(captured.item_info)) do
        if m.id == captured.marker_id then mk = m break end
      end
      if not mk then
        state.message, state.message_kind =
          "That marker is not inside this item any more.", "warn"
        return
      end
      local moved = false
      core.Transaction("VO Overview: trim item to marker", function()
        moved = Trim.apply(captured.item_info, mk)
      end)
      r.UpdateArrange()
      Reload()
      state.message, state.message_kind = moved
        and "Trimmed the item to its take marker."
        or  "Could not trim that item.", moved and "ok" or "error"
    end
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "The other direction: set the ITEM's edges to this\n" ..
                       "take's marker. The audio does not move.")
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Set this take's marker to the item's current edges --\n" ..
                       "the fix for trimming the head past the marker start.")
  end
  if im.MenuItem(ctx, "Delete take marker", nil, nil, row.marker_id ~= nil) then
    local captured = row
    pending_action = function() DeleteTakeMarker(captured) end
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "The take leaves the sheet with the marker; native\n" ..
                       "gestures (drag the marker, alt-drag its end) edit it.")
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
end

-- -----------------------------------------------------------------------
-- Cards (prototype renderer)
--
-- The same node list the table drew, drawn as one CARD per script line
-- instead: a header band answering for the LINE, take rows beneath
-- answering for the TAKE. No ImGui table -- alignment is shared x-offsets
-- (the ZONES below), and the card chrome, not cell borders, says where a
-- line begins and ends. Vertical correlation survives: transcript sits in
-- the same zone as the line text above it, the item name under the
-- delivered name, the recording position under the script origin.
--
-- Heights are measured, never predicted, exactly like the table rows: a
-- card paints its background from LAST frame's measurement, so a card's
-- first frame paints slightly short and settles on the next -- invisible
-- at frame rate, and the price the table already paid for the same answer.
-- -----------------------------------------------------------------------

local CARD_BG      = 0x26262CFF
local CARD_OUTLINE = 0x3A3A44FF
local BAND_BG      = 0x31313CFF
-- Take rows sit on their own colour, cooler and darker than the band, so
-- parent and child can never be mistaken for one another.
local TAKE_BG      = 0x1B2026FF
local CARD_ROUND   = 4.0
local CARD_MARGIN  = 5.0   -- vertical space between cards
local CARD_PAD     = 6.0   -- inner padding
-- The outline a selected row earns, at BOTH levels: the take row itself and
-- the card that holds it. The card-level copy is what makes a timeline click
-- findable in the sheet at all -- the selected take may sit inside a FOLDED
-- card, where the row (and its highlight) simply does not draw.
local SEL_OUTLINE  = 0x8FBBE8FF

-- The first of this node's takes that is a selected row, or nil. Selection
-- lives on take rows (state.selection is keyed by row uid); the card has no
-- uid of its own, so "is this card selected" is asked of its children.
local function SelectedTakeOf(node)
  for _, t in ipairs(node.takes or {}) do
    if state.selection[t.uid] then return t end
  end
  return nil
end

-- Scroll the cards child the MINIMUM needed to put [y0, y1] fully on screen
-- -- and not at all when it already is. The direction is the information: a
-- target below lands at the BOTTOM edge (the sheet visibly scrolled down to
-- find it), a target above lands at the TOP edge, and a target already visible
-- does not move the sheet under the user's eyes.
--
-- The range is the whole CARD, not the selected take: the reason the user is
-- being brought here is "what is this line, and what other takes does it
-- have", and a lone take row with its band off screen answers neither. Only
-- when the card is taller than the view -- when "the whole line" is not on
-- offer -- does the target narrow to [fy0, fy1], the selected take itself.
local function ScrollRangeMinimally(y0, y1, fy0, fy1)
  local wy = select(2, im.GetWindowPos(ctx))
  local wh = im.GetWindowHeight(ctx)
  if (y1 - y0) > wh and fy0 then
    y0, y1 = fy0, fy1
  end
  if y1 > wy + wh then
    im.SetScrollFromPosY(ctx, y1 - wy, 1.0)
  elseif y0 < wy then
    im.SetScrollFromPosY(ctx, y0 - wy, 0.0)
  end
end

-- The scroll-to target burns down over frames rather than firing once: see
-- scroll_to_frames in the state table.
local function ConsumeScrollTo()
  state.scroll_to_frames = (state.scroll_to_frames or 1) - 1
  if state.scroll_to_frames <= 0 then state.scroll_to_uid = nil end
end

-- Shared x-offsets, computed once per frame from the available width. Every
-- zone is used by band and take rows alike, which is what keeps the two
-- levels correlated without a table's grid.
local function CardZones(w)
  local z = { lead = 0, marks = 78, text = 186 }
  -- Two zones carry the whole card now, and both are things the user acts on:
  -- the text being read, and the name it will be exported under. What went:
  --   Notes -- a free-text box the tool cannot act on, a third of the width.
  --   Item  -- which recording and when. That is the project bay's job; here
  --            it was reading room the exported name wanted.
  local name_w = math.min(340, math.max(200, math.floor(w * 0.26)))
  local fixed  = z.text + name_w + CARD_PAD * 2
  z.text_w  = math.max(160, w - fixed)
  z.name    = z.text + z.text_w + 6
  z.name_w  = name_w
  return z
end

-- The take's transcript, wrapped, with the words the line does not contain in
-- amber.
--
-- Word by word with manual wrapping rather than one PushTextWrapPos call,
-- because the colour changes mid-paragraph: ImGui wraps an ITEM, and a wrapped
-- item that starts mid-line continues at its own left edge, which puts a hanging
-- indent wherever a colour run happens to break. One word per item cannot wrap
-- internally, so the only wrapping is the one done here.
--
-- ONLY when there is something to colour. A word per item multiplies this
-- sheet's ImGui items by roughly eight, and the cards are all drawn every frame,
-- so five hundred rows went from five hundred items to several thousand and
-- REAPER started to feel like it was pausing. A take whose words are all in its
-- line takes the old path -- one wrapped Text -- which is most takes.
--
-- Drawn through the cursor (not the draw list) so the enclosing group still
-- measures the height the card is laid out from.
local function DrawTranscriptRuns(runs, x, y, wrap_w)
  local space  = im.CalcTextSize(ctx, " ")
  local line_h = im.GetTextLineHeight(ctx)
  local cx, cy = 0, 0
  for _, run in ipairs(runs) do
    for word in run.text:gmatch("%S+") do
      local ww = im.CalcTextSize(ctx, word)
      if cx > 0 and cx + ww > wrap_w then cx, cy = 0, cy + line_h end
      im.SetCursorScreenPos(ctx, x + cx, y + cy)
      if run.extra then im.TextColored(ctx, EXTRA_WORD, word)
      else im.TextDisabled(ctx, word) end
      cx = cx + ww + space
    end
  end
  if cx == 0 and cy == 0 then
    -- Nothing drawn: still claim one line, so a take with no transcript is the
    -- same height as one with.
    im.SetCursorScreenPos(ctx, x, y)
    im.TextDisabled(ctx, "")
  end
end

-- A dot with the status behind it. `words` is the tooltip.
local function CardDot(colour, words)
  im.TextColored(ctx, colour, "●")
  if words and words ~= "" and im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, words)
  end
end

-- One take row inside a card. The row spans the card, a click anywhere that
-- is not a widget selects, and the widgets sit at the zone offsets.
local function DrawCardTakeRow(row, z, vis_index, x0, inner_w)
  local dl = im.GetWindowDrawList(ctx)
  local row_h = row._card_h or im.GetFrameHeight(ctx)
  local rx, ry = im.GetCursorScreenPos(ctx)

  -- The child's own colour, behind everything: parent band and take rows
  -- must never read as the same kind of thing.
  im.DrawList_AddRectFilled(dl, rx + 12, ry - 1,
    rx + (inner_w or 600), ry + row_h + 1, TAKE_BG, 3.0)

  -- The spanning selectable first, so widgets drawn after it win the click.
  local sel_flags = 0
  local overlap = Api('SelectableFlags_AllowOverlap')
  if overlap then sel_flags = overlap end
  if im.Selectable(ctx, "##take", state.selection[row.uid] == true, sel_flags, 0, row_h) then
    local captured = ReadModifiers()
    local at = vis_index
    pending_action = function() ClickRow(row, at, captured) end
  end
  -- Where this row sits this frame, for the card-level scroll: the scroll-to
  -- itself is handled by the CARD (DrawLineCard / DrawOrphanCard), which
  -- targets the whole line and needs the take's own rect only as the
  -- fallback for a card taller than the view.
  row._card_y = ry
  if im.IsItemHovered(ctx) and not row.item then
    im.SetTooltip(ctx, "The audio for this row is not in this project.")
  end
  if im.BeginPopupContextItem(ctx, "##take_menu") then
    DrawTakeRowMenu(row)
    im.EndPopup(ctx)
  end

  -- Now the content, drawn back at the row's own top.
  im.SetCursorScreenPos(ctx, rx, ry)
  im.BeginGroup(ctx)

  -- Lead: take letter, dim, then the status dot.
  im.SetCursorScreenPos(ctx, rx + 18, ry)
  im.TextDisabled(ctx, vo.TakeLetter and vo.TakeLetter(row._take_no or 0) or "")
  im.SameLine(ctx)
  local style = STATUS_STYLE[row.status]
  local words = row.user_status == "flagged" and "Flagged" or (style and style.label or "")
  if row.score and row.status == "review" then
    words = string.format("%s -- match confidence %.0f%%", words, row.score * 100)
    if row.in_sequence == false then
      words = words .. "\nAnd it does not sit where the rest of the read says\nthis line should be."
    end
  end
  CardDot(row.user_status == "flagged" and 0xDD6666FF or (style and style.colour or 0x9999AAFF), words)

  -- Marks: three checkboxes on the shared offsets.
  local orphan = row.status == "orphan"
  if orphan then
    -- Why this one is here. "Not on the script" covers at least three different
    -- situations and the fix differs by case, so the row says which rather than
    -- leaving the whole list looking like one undifferentiated pile.
    local short_, long_
    if row.user_status == "junk" then
      short_, long_ = "dismissed", "You decided this is not a line: slate, chatter,\n" ..
        "a cough or a false start. It no longer counts against\n" ..
        "\"not on the script\". Right-click to bring it back."
    elseif row.asset and row.asset ~= "" then
      short_, long_ = "no such line",
        "This audio is named \"" .. row.asset .. "\", which is not in any\n" ..
        "script this project has loaded. Either the wrong script is\n" ..
        "loaded, or the name is from somewhere else."
    else
      short_, long_ = "unmatched",
        "No script line scored high enough against these words.\n" ..
        "Right-click: the guesses the batch pass would not take are\n" ..
        "listed there, best first."
    end
    im.SetCursorScreenPos(ctx, rx + z.marks, ry)
    im.TextDisabled(ctx, short_)
    if im.IsItemHovered(ctx) then im.SetTooltip(ctx, long_) end
  else
    local function MarkTargets()
      if not state.selection[row.uid] then return { row } end
      local out = {}
      for _, r2 in ipairs(SelectedRows()) do
        if r2.status ~= "orphan" then out[#out + 1] = r2 end
      end
      return out
    end
    -- Lock, Sel, Alt -- in that order, matching DrawTakeHeaderRow. The two
    -- ticks that decide DELIVERY sit together on the right: a take is shipped
    -- when either is on, as the select or as an alt, and everything untouched
    -- waits on Review.
    --
    -- "Alt" is the label; `user_keep` / `mark_keep` / the project file's ninth
    -- column are still `keep`. The mark always meant "deliver this alongside
    -- the select", so only the NAME was wrong -- it described the mechanism
    -- rather than the outcome -- and renaming the field would touch Pull,
    -- reconcile, the track-to-mark map and the stored file for no gain.
    im.SetCursorScreenPos(ctx, rx + z.marks, ry)
    local checked = row.user_status == "verified"
    local lhit, lnow = im.Checkbox(ctx, "##lock", checked)
    if lhit then pending_action = function() SetLock(row, lnow) end end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, checked and "Locked here. Rematching will not move it."
                                  or "Lock: rematching leaves this take where it is.")
    end
    im.SameLine(ctx)
    im.SetCursorScreenPos(ctx, rx + z.marks + 34, ry)
    local hit, now = im.Checkbox(ctx, "##sel", row.user_select == true)
    if hit then
      local targets = MarkTargets()
      pending_action = function()
        for _, r2 in ipairs(targets) do SetSelect(r2, now) end
      end
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Sel: the take you are delivering. One per line.\n" ..
                         "On a highlighted row, every highlighted row follows.")
    end
    im.SameLine(ctx)
    im.SetCursorScreenPos(ctx, rx + z.marks + 68, ry)
    local khit, know = im.Checkbox(ctx, "##keep", row.user_keep == true)
    if khit then
      local targets = MarkTargets()
      pending_action = function()
        for _, r2 in ipairs(targets) do SetKeep(r2, know) end
      end
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Alt: ship this one too, beside the select.\n" ..
                         "Independent of Sel. Any number per line.\n\n" ..
                         "Sel or Alt means it is delivered; neither means it\n" ..
                         "waits on Review.")
    end
  end

  -- Text: the transcript, wrapped inside its zone, extra words in amber.
  --
  -- The colour used to mean `status == "review"` -- i.e. the match score fell
  -- below a threshold -- which put a number nobody could see in charge of a
  -- whole paragraph's colour, and from the outside read as random. Now it marks
  -- the words themselves: what the reader said that the line does not contain.
  -- Non-blocking, and deliberately so: a take with extra words is still a take
  -- the user may want, and Lock/Sel/Alt is where that gets decided.
  local runs = ExtraRuns(row)
  im.SetCursorScreenPos(ctx, rx + z.text, ry)
  if row._extra_clean then
    im.PushTextWrapPos(ctx, im.GetCursorPosX(ctx) + z.text_w)
    wrap_depth = wrap_depth + 1
    im.TextDisabled(ctx, row._extra_text or row.transcript or "")
    im.PopTextWrapPos(ctx)
    wrap_depth = wrap_depth - 1
  else
    DrawTranscriptRuns(runs, rx + z.text, ry, z.text_w)
  end

  -- The link affordance of a PLANNED row. It used to live in the Item zone;
  -- with that gone it sits beside the name, where it always did on a narrow
  -- window.
  local function DrawLinkButton()
    if im.SmallButton(ctx, "+##link") then
      local captured = row
      pending_action = function() LinkPlannedTake(captured) end
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Link the item selected in REAPER to this take:\n" ..
                         "names it for this line and retires the planned row.")
    end
  end

  -- Name: the item's own name, editable.
  im.SetCursorScreenPos(ctx, rx + z.name, ry)
  local shown = row.take_name or row.name_override or row.deliver or row.asset or ""
  if row.planned and not row.item then
    im.TextDisabled(ctx, "(planned)")
    TooltipEvenWhenDisabled(
      "An empty take added by hand -- no audio is linked yet.\n" ..
      "Select the item in REAPER, then press its + button.")
    im.SameLine(ctx)
    DrawLinkButton()
  elseif not row.item then
    im.TextDisabled(ctx, "(no item)")
    TooltipEvenWhenDisabled(
      "This take matched the transcript, but no item in this project plays\n" ..
      "that stretch of " .. vo.Basename(row.source_path or "the source") .. ".")
  else
    im.SetNextItemWidth(ctx, z.name_w)
    local fchanged, fname = im.InputText(ctx, "##fn", shown,
                                         im.InputTextFlags_EnterReturnsTrue)
    if fchanged or im.IsItemDeactivatedAfterEdit(ctx) then
      if fname ~= shown then
        local captured = fname
        pending_action = function() Rename(row, captured) end
      end
    end
    if im.BeginPopupContextItem(ctx, "##take_name_menu") then
      if im.MenuItem(ctx, "Copy") then Copy(shown) end
      local can_reset = shown ~= (row.deliver or row.asset or "")
      if im.MenuItem(ctx, "Reset item name", nil, nil, can_reset) then
        pending_action = function() ResetName(row) end
      end
      im.EndPopup(ctx)
    end
  end

  im.EndGroup(ctx)
  local _, gh = im.GetItemRectSize(ctx)
  row._card_h = math.max(gh, im.GetFrameHeight(ctx))

  -- The child half of the selection outline, over the content so the
  -- Selectable's own fill cannot swallow it.
  if state.selection[row.uid] then
    im.DrawList_AddRect(dl, rx + 12, ry - 1,
      rx + (inner_w or 600), ry + row._card_h + 1, SEL_OUTLINE, 3.0, 0, 1.5)
  end
end

-- The card's header band: the line's TITLE, three stacked rows --
--   who:   fold arrow, line number, status dot, speaker chip, badges right
--   file:  the delivered name, full width, clash-red, Append on right-click
--   said:  the line text, bright, wrapped to the card
-- Everything noisy (script name, line note) lives behind the fold; the band
-- stays a clean answer to "which line is this and where does it stand".
local function DrawCardBand(node, z, key, open, x0, band_w)
  local rep = node.rep
  local dl = im.GetWindowDrawList(ctx)
  local rx, ry = im.GetCursorScreenPos(ctx)
  local line_h = im.GetTextLineHeightWithSpacing(ctx)
  local band_h = rep._band_h or (line_h * 3)
  local inner_w = band_w - CARD_PAD * 2

  im.DrawList_AddRectFilled(dl, rx - CARD_PAD, ry - 3,
    rx - CARD_PAD + band_w, ry + band_h + 3, BAND_BG, CARD_ROUND)

  -- The hover surface spans the card's inner width, and the WHOLE band is
  -- the fold control -- the arrow is an indicator, not the only target.
  local overlap = Api('SelectableFlags_AllowOverlap')
  if im.Selectable(ctx, "##band", false, overlap or 0, inner_w, band_h) then
    if state.expanded[key] then state.expanded[key] = nil
    else state.expanded[key] = true end
    state.dirty = true
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, #node.takes > 0
      and string.format("%d take%s. Click to %s.",
            #node.takes, #node.takes == 1 and "" or "s",
            open and "fold" or "unfold")
      or  ("Click to " .. (open and "fold" or "unfold") .. " the line's details."))
  end

  im.SetCursorScreenPos(ctx, rx, ry)
  im.BeginGroup(ctx)

  -- Row 1: delivered count, number, dot, speaker, line.
  --
  -- The count takes the far-left corner the fold arrow used to hold. The
  -- whole band folds on click, so the arrow was an indicator sitting in the
  -- best seat on the card -- and "is this line delivered, and how many
  -- times" is the thing worth reading first.
  local rec = rep.script_row and DELIVERY(rep.script_row)
  if rep.script_row then
    if rec then im.TextColored(ctx, 0x66BB66FF, "✓" .. tostring(rec.count))
    else im.TextColored(ctx, 0xDD6666FF, "–") end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, rec
        and string.format("%d item%s in the project named %s.\n" ..
              "Read from the item names, so a take cut by hand or delivered\n" ..
              "as a rendered file counts just the same.",
              rec.count, rec.count == 1 and "" or "s", rep.deliver or rep.asset or "?")
        or  string.format("No item in the project is named %s yet.\n" ..
              "Cut and Name, or name an item yourself.",
              rep.deliver or rep.asset or "?"))
    end
  end
  im.SetCursorScreenPos(ctx, rx + 40, ry)
  im.TextDisabled(ctx, tostring(rep.order or ""))
  im.SameLine(ctx)

  local style = STATUS_STYLE[node.rollup.status] or STATUS_STYLE.missing
  local bits = { style.label }
  bits[#bits + 1] = rec and (tostring(rec.count) .. " delivered") or "Nothing delivered yet."
  if node.rollup.take_count > 0 and not node.rollup.has_sel then
    bits[#bits + 1] = "No Sel chosen yet."
  end
  if node.rollup.locks > 0 then bits[#bits + 1] = node.rollup.locks .. " locked." end
  CardDot(style.colour, table.concat(bits, "\n"))

  -- Speaker chip, then the LINE TEXT: the words are the main piece of
  -- information on the card, so they read in the same glance as who says them
  -- rather than two rows down.
  --
  -- The line starts at the TRANSCRIPT zone, not wherever the speaker's name
  -- happened to end. That puts the line as WRITTEN directly above the same
  -- line as READ on every take row below it, which is the comparison the
  -- window exists to make -- a ragged start made the eye do the work.
  local said_x = rx + z.text
  if rep.character and rep.character ~= "" then
    im.SameLine(ctx)
    im.SetCursorScreenPos(ctx, rx + z.marks, ry)
    -- Clipped: a long speaker name must not run into the line it introduces.
    im.PushClipRect(ctx, rx + z.marks, ry, said_x - 6, ry + line_h, true)
    im.TextColored(ctx, 0x9FB4C8FF, rep.character)
    im.PopClipRect(ctx)
    if im.IsItemHovered(ctx) then im.SetTooltip(ctx, rep.character) end
  end
  if rep.line_text and rep.line_text ~= "" then
    im.SetCursorScreenPos(ctx, said_x, ry)
    -- Wraps before the filename column, which shares this row.
    im.PushTextWrapPos(ctx, im.GetCursorPosX(ctx) + (rx + z.name - 8 - said_x))
    wrap_depth = wrap_depth + 1
    im.Text(ctx, '"' .. rep.line_text .. '"')
    im.PopTextWrapPos(ctx)
    wrap_depth = wrap_depth - 1
  end
  -- Where the header row actually ended: the line text wraps, so row 2 starts
  -- below whichever is lower, the wrapped words or the fixed row height.
  local y2 = math.max(select(2, im.GetCursorScreenPos(ctx)), ry + line_h) + 2

  -- The one badge still worth the right edge: nothing is ticked for delivery.
  im.SetCursorScreenPos(ctx, rx + inner_w - 20, ry)
  if node.rollup.take_count > 0 and not node.rollup.has_sel then
    im.TextColored(ctx, 0xDDAA33FF, " !")
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "No Sel chosen yet: no take is ticked as the delivery.")
    end
  end

  -- Still row 1, in the Item name COLUMN: the delivered filename, directly
  -- above the names the items carry now. That is the comparison being made --
  -- what this file WILL be called against what it IS called -- and it only
  -- works if the two line up. No "Filename:" label: a label would push the
  -- name out of its column.
  --
  -- It shares the top row with the badge, the speaker and the line because
  -- those are one horizontal sentence about the line, and that sentence is
  -- the whole of a FOLDED card.
  local base = rep.asset or ""
  local shown = rep.deliver or base
  local clash = rep.line_key ~= nil and shown ~= ""
                and state.dupe_names[shown] == true
  im.SetCursorScreenPos(ctx, rx + z.name, ry)
  im.PushClipRect(ctx, rx + z.name, ry, rx + z.name + z.name_w, ry + line_h, true)
  if clash then im.TextColored(ctx, 0xDD6666FF, shown)
  else im.TextDisabled(ctx, shown) end
  im.PopClipRect(ctx)
  if clash and im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Another script line is delivered under this same name.\n" ..
                       "Edit the Append (right-click) to tell them apart.")
  end
  local open_append = false
  if rep.line_key and im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, 0) then
    open_append = true
  end
  if base ~= "" and im.BeginPopupContextItem(ctx, "##band_name_menu") then
    if im.MenuItem(ctx, "Copy") then Copy(shown) end
    if im.MenuItem(ctx, "Edit Append", nil, nil, rep.line_key ~= nil) then
      open_append = true
    end
    im.EndPopup(ctx)
  end
  if open_append then im.OpenPopup(ctx, "##append_edit") end
  if im.BeginPopup(ctx, "##append_edit") then
    im.Text(ctx, "Append to " .. base .. ":")
    im.SetNextItemWidth(ctx, 200)
    local achanged, atext = im.InputText(ctx, "##append", rep.append or "")
    if achanged then
      local captured = atext
      pending_action = function() SetAppend(rep, captured) end
    end
    im.EndPopup(ctx)
  end

  -- ROW 2 IS UNFOLD-ONLY. A folded card is one horizontal row and nothing
  -- else; open one and the second row appears with the provenance and with
  -- what still stands between this line and done.
  if open then
    im.SetCursorScreenPos(ctx, rx + 22, y2)
    local script_name = (rep.script and rep.script ~= "")
                        and (vo.Basename(rep.script):gsub("%.%w+$", "")) or "—"
    im.TextDisabled(ctx, "Script: " .. script_name)
    if rep.script and rep.script ~= "" and im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, rep.script)
    end

    -- Two Sels on one line is a decision still pending, not an error -- track
    -- placement legitimately creates it (two items of the line on the Selects
    -- track both read as Sel) -- so it says so here, and counts into the
    -- summary line whether the card is open or not.
    local sels = 0
    for _, t in ipairs(node.takes) do
      if t.user_select then sels = sels + 1 end
    end
    if sels >= 2 then
      im.SameLine(ctx)
      im.TextColored(ctx, 0xDDAA33FF,
        string.format("   %d selects -- pick one", sels))
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, "More than one take of this line is marked Sel.\n" ..
                           "Untick all but one, or drag the extra item off Selects\n" ..
                           "and press Update sheet to match items.")
      end
    end
  end

  im.EndGroup(ctx)
  local _, gh = im.GetItemRectSize(ctx)
  rep._band_h = math.max(gh, open and line_h * 2 or line_h)
end

-- (The old fold-only drawer is gone: its whole content -- the script name and
-- the line note -- now lives on the band's fourth row, visible without
-- unfolding. See DrawCardBand.)

-- Column labels for the take list, drawn once per open card, directly above
-- the inputs they name.
local function DrawTakeHeaderRow(z, rx)
  local _, y = im.GetCursorScreenPos(ctx)
  local sf = PushCellFont("state")
  -- Lock, Sel, Alt -- reading order matches the decision order: lock it down,
  -- then say what it IS. "Alt" replaced "Keep", which named the mechanism (a
  -- mark that survives) rather than the outcome (it ships as an alt). The
  -- stored field is still `keep`; see DrawCardTakeRow.
  for i, l in ipairs({ "Lock", "Sel", "Alt" }) do
    im.SetCursorScreenPos(ctx, rx + z.marks + (i - 1) * 34 - 2, y)
    im.TextDisabled(ctx, l)
  end
  im.SetCursorScreenPos(ctx, rx + z.text, y)
  im.TextDisabled(ctx, "Transcript")
  im.SetCursorScreenPos(ctx, rx + z.name, y)
  im.TextDisabled(ctx, "Item name")
  PopCellFont(sf)
end

-- "This line has another take": with items selected in REAPER, names them for
-- the line -- the name is the assignment. With nothing selected, adds a
-- PLANNED row (vo.PlannedKey): an empty take to hang notes and marks on,
-- linked to a real item later via the + in its Item column.
local function AddPlannedTake(rep)
  local id = (r.genGuid and r.genGuid("")) or tostring(r.time_precise())
  state.entries[#state.entries + 1] = {
    key = vo.PlannedKey(rep.asset, id), asset = rep.asset,
  }
  state.dirty = true
  Rebuild()
end

local function DrawAddTakeRow(rep, rx)
  local _, y = im.GetCursorScreenPos(ctx)
  im.SetCursorScreenPos(ctx, rx + 22, y + 2)
  if not (rep.asset and rep.asset ~= "") then
    im.TextDisabled(ctx, "+ Add Take")
    TooltipEvenWhenDisabled("This line has no filename to deliver under,\n" ..
                            "so a take cannot be named for it.")
    return
  end

  local n_sel = r.CountSelectedMediaItems(0)
  local label = (n_sel > 1) and string.format("+ Add %d Takes", n_sel) or "+ Add Take"
  if im.SmallButton(ctx, label) then
    if n_sel > 0 then
      local target, name = rep, (rep.deliver or rep.asset)
      pending_action = function() AssignSelectedItems(target, name) end
    else
      local target = rep
      pending_action = function() AddPlannedTake(target) end
    end
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, n_sel > 0
      and ("Names the selected item(s) for this line. Several at\n" ..
           "once are numbered with the alt pattern.")
      or  ("Adds an empty planned take -- nothing is selected in REAPER.\n" ..
           "Link an item to it later with the + in its Item column."))
  end
end

-- Cards outside the view are not drawn at all.
--
-- Every card was built every frame whether or not it was on screen, so a
-- 169-line sheet with a few cards unfolded paid for hundreds of widgets nobody
-- could see -- and REAPER is single-threaded, so that time comes out of the
-- editing you are trying to do. Off-screen cards now leave a spacer of the
-- height they had last frame, which is the same measurement the chrome is
-- already drawn from.
--
-- Stale height is not a risk: a card cannot change height while it is off
-- screen, since nothing edits it there, and the frame it scrolls back in it
-- draws for real and re-measures. Culling is skipped entirely while a scroll-to
-- is pending, because a card that is not drawn cannot report where it is, which
-- is exactly what the scroll needs to know.
local IS_RECT_VISIBLE = Api('IsRectVisible')
local function CardIsVisible(w, h)
  if not IS_RECT_VISIBLE or state.scroll_to_uid then return true end
  return IS_RECT_VISIBLE(ctx, w, h)
end

-- One card: chrome from last frame's height, band, then (open) the drawer,
-- the take list under its header, and the add-take affordance.
local function DrawLineCard(node, z, flat_index, avail_w)
  local rep = node.rep
  local key = LineNodeKey(node)
  local open = state.expanded[key] == true
  local dl = im.GetWindowDrawList(ctx)
  local cx, cy = im.GetCursorScreenPos(ctx)
  local card_h = rep._card_full_h or (im.GetFrameHeight(ctx) + CARD_PAD * 2)

  -- The remembered height is only usable if it was measured in the fold state
  -- the card is in NOW. "Unfold all" changes every card at once, including the
  -- ones off screen, and culling those at their folded height would put the
  -- scroll extent badly wrong until each was scrolled to.
  if rep._card_h_open == open and not CardIsVisible(avail_w, card_h + CARD_MARGIN) then
    im.Dummy(ctx, 1, card_h + CARD_MARGIN)
    return
  end
  rep._card_h_open = open

  im.DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + card_h, CARD_BG, CARD_ROUND)
  im.DrawList_AddRect(dl, cx, cy, cx + avail_w, cy + card_h, CARD_OUTLINE, CARD_ROUND)

  im.SetCursorScreenPos(ctx, cx + CARD_PAD, cy + CARD_PAD)
  im.BeginGroup(ctx)
  DrawCardBand(node, z, key, open, cx + CARD_PAD, avail_w)

  if open then
    if #node.takes > 0 then
      DrawTakeHeaderRow(z, cx + CARD_PAD)
      for ti, t in ipairs(node.takes) do
        t._take_no = ti
        im.PushID(ctx, ti)
        id_depth = id_depth + 1
        DrawCardTakeRow(t, z, flat_index[t.uid], cx + CARD_PAD, avail_w - CARD_PAD * 2)
        im.PopID(ctx)
        id_depth = id_depth - 1
      end
    end
    DrawAddTakeRow(rep, cx + CARD_PAD)
  end
  im.EndGroup(ctx)
  local _, gh = im.GetItemRectSize(ctx)
  rep._card_full_h = gh + CARD_PAD * 2

  -- The parent half of the selection outline, drawn LAST: the band's own
  -- background spans the card's full width, so an outline drawn with the
  -- chrome had its sides painted over and read as no outline at all.
  if SelectedTakeOf(node) then
    im.DrawList_AddRect(dl, cx, cy, cx + avail_w, cy + rep._card_full_h,
      SEL_OUTLINE, CARD_ROUND, 0, 2.0)
  end

  -- The scroll-to, at CARD level so the whole outlined line comes on screen,
  -- not just the one take (the context being sought is "what is this line,
  -- and what other takes does it have"). Works folded too -- with auto-unfold
  -- off, the band itself is the whole of what there is to show. The take's
  -- own rect, remembered by DrawCardTakeRow this frame, is the fallback for a
  -- card taller than the view.
  if state.scroll_to_uid then
    for _, t in ipairs(node.takes) do
      if t.uid == state.scroll_to_uid then
        local fy0 = open and t._card_y or nil
        ScrollRangeMinimally(cy - 2, cy + rep._card_full_h + 2,
          fy0, fy0 and (fy0 + (t._card_h or im.GetFrameHeight(ctx)) + 2) or nil)
        ConsumeScrollTo()
        break
      end
    end
  end

  -- The card's footprint is a real ITEM, not a bare cursor move: ImGui only
  -- grows the scrolling child from submitted items, and EndChild raises if
  -- the last thing before it was a SetCursorScreenPos.
  im.SetCursorScreenPos(ctx, cx, cy)
  im.Dummy(ctx, 1, rep._card_full_h + CARD_MARGIN)
end


-- The orphan section is one card of its own: audio the script cannot name.
local function DrawOrphanCard(node, z, flat_index, avail_w)
  local dl = im.GetWindowDrawList(ctx)
  local cx, cy = im.GetCursorScreenPos(ctx)
  local card_h = state._orphan_card_h or (im.GetFrameHeight(ctx) + CARD_PAD * 2)

  -- Worth more here than anywhere: this one card holds EVERY unidentified take
  -- in the session, so it is routinely the tallest thing in the sheet and is
  -- usually scrolled past.
  if not CardIsVisible(avail_w, card_h + CARD_MARGIN) then
    im.Dummy(ctx, 1, card_h + CARD_MARGIN)
    return
  end

  im.DrawList_AddRectFilled(dl, cx, cy, cx + avail_w, cy + card_h, 0x2C2228FF, CARD_ROUND)
  im.DrawList_AddRect(dl, cx, cy, cx + avail_w, cy + card_h, 0x55404AFF, CARD_ROUND)

  im.SetCursorScreenPos(ctx, cx + CARD_PAD, cy + CARD_PAD)
  im.BeginGroup(ctx)
  im.TextDisabled(ctx, "Not on the script")
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Recorded audio whose transcript matches no script line.")
  end
  for ti, t in ipairs(node.takes) do
    t._take_no = ti
    im.PushID(ctx, ti)
    id_depth = id_depth + 1
    DrawCardTakeRow(t, z, flat_index[t.uid], cx + CARD_PAD, avail_w - CARD_PAD * 2)
    im.PopID(ctx)
    id_depth = id_depth - 1
  end
  im.EndGroup(ctx)
  local _, gh = im.GetItemRectSize(ctx)
  state._orphan_card_h = gh + CARD_PAD * 2

  -- Same late accent outline as DrawLineCard, for the same reason.
  if SelectedTakeOf(node) then
    im.DrawList_AddRect(dl, cx, cy, cx + avail_w, cy + state._orphan_card_h,
      SEL_OUTLINE, CARD_ROUND, 0, 2.0)
  end

  -- Same card-level scroll-to as DrawLineCard. The orphan card holds every
  -- unrecognised take at once and is routinely taller than the view, so the
  -- take-row fallback is the common case here rather than the exception.
  if state.scroll_to_uid then
    for _, t in ipairs(node.takes) do
      if t.uid == state.scroll_to_uid then
        local fy0 = t._card_y
        ScrollRangeMinimally(cy - 2, cy + state._orphan_card_h + 2,
          fy0, fy0 and (fy0 + (t._card_h or im.GetFrameHeight(ctx)) + 2) or nil)
        ConsumeScrollTo()
        break
      end
    end
  end

  im.SetCursorScreenPos(ctx, cx, cy)
  im.Dummy(ctx, 1, state._orphan_card_h + CARD_MARGIN)
end

local function DrawCardsBody(avail_w)
  local z = CardZones(avail_w)
  if #state.nodes == 0 then
    if #state.overview > 0 then
      im.TextDisabled(ctx, "No rows match the current filters.")
      return
    end
    -- The emptiest screen is the one that most needs to say what to do next.
    -- It used to say only that there was nothing to show, leaving the two
    -- things it needs to be found in a tab. They are offered here instead, in
    -- the order they are done, with the one still outstanding first.
    im.Spacing(ctx)
    im.Text(ctx, "Nothing to show yet. This window needs two things:")
    im.Spacing(ctx)

    local have_script = #state.scripts > 0
    im.Text(ctx, have_script and "\226\156\147  1." or "    1.")
    im.SameLine(ctx)
    if have_script then
      im.TextDisabled(ctx, "A script -- " .. vo.Basename(state.scripts[1].path or ""))
    else
      if im.Button(ctx, "Choose script\226\128\166##empty") then
        state.tab, state.panel, state.tab_sync = "setup", "script", 4
      end
      im.SameLine(ctx)
      im.TextDisabled(ctx, "a CSV of filenames and lines: what was meant to be read.")
    end

    im.Text(ctx, "    2.")
    im.SameLine(ctx)
    if im.Button(ctx, "Transcribe\226\128\166##empty") then
      local ok, why = vo.LaunchSibling("ajsfx_VO_Sources.lua")
      if not ok then state.message, state.message_kind = tostring(why), "error" end
    end
    im.SameLine(ctx)
    im.TextDisabled(ctx, "the recordings in this project: what was actually read.")

    im.Spacing(ctx)
    im.TextDisabled(ctx, "With both, Edit \226\134\146 Run the whole pass does the rest.")
    return
  end
  local flat_index = state.flat_index or {}
  for ni, node in ipairs(state.nodes) do
    if node.kind == "line" or node.kind == "orphans" then
      im.PushID(ctx, ni)
      id_depth = id_depth + 1
      if node.kind == "line" then
        DrawLineCard(node, z, flat_index, avail_w)
      else
        DrawOrphanCard(node, z, flat_index, avail_w)
      end
      im.PopID(ctx)
      id_depth = id_depth - 1
    end
    -- Character nodes draw nothing: the character rides each band's Where
    -- zone instead of spending a row.
  end
end

local function DrawCards(height)
  if not im.BeginChild(ctx, "vo_cards", 0, height) then return end
  local avail_w = select(1, im.GetContentRegionAvail(ctx)) - 2
  local ok, err = pcall(DrawCardsBody, avail_w)
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
  im.EndChild(ctx)
  if not ok then state.message, state.message_kind = tostring(err), "error" end
end

local function DrawSummary()
  local n = state.summary
  local c = state.check or {}
  local total = #(state.lines or {})

  local first = true
  local function seg(colour, text, tip)
    if first then first = false
    else im.SameLine(ctx); im.TextDisabled(ctx, "·"); im.SameLine(ctx) end
    if colour then im.TextColored(ctx, colour, text)
    else im.TextDisabled(ctx, text) end
    if tip and im.IsItemHovered(ctx) then im.SetTooltip(ctx, tip) end
  end

  local got = c.delivered or 0
  seg((got >= total and total > 0) and 0x66BB66FF or 0xDDAA33FF,
    string.format("%d of %d lines in the project", got, total),
    "Script lines with at least one item named for them.\n" ..
    "Counted from the item names, so a take you cut by hand\n" ..
    "or were sent as a rendered file counts just the same.")
  seg(nil, string.format("%d recorded", n.delivered or 0),
    "Lines the transcript match found audio for.")
  seg(0x66BB66FF, string.format("%d verified", n.verified or 0),
    "Takes locked in place. Rematching leaves them alone.")
  if (n.review or 0) > 0 then
    seg(0xDDAA33FF, string.format("%d to review", n.review))
  end
  if (n.flagged or 0) > 0 then
    seg(0xDD6666FF, string.format("%d flagged", n.flagged))
  end
  local conflicts = state.conflicts or {}
  if #conflicts > 0 then
    seg(0xDDAA33FF, string.format("%d line(s) need a select chosen", #conflicts),
      "Lines carrying more than one Sel. Each card says which takes;\n" ..
      "untick all but one.")
  end
  if (n.orphan or 0) > 0 then
    seg(nil, string.format("%d orphan", n.orphan),
      "Recorded audio whose transcript matches no script line.\n" ..
      "Listed in the card at the bottom of the sheet. Right-click one:\n" ..
      "hand it to a line, or dismiss it as junk. This number reaching\n" ..
      "zero means every span has been looked at.")
  elseif (n.junk or 0) > 0 then
    -- Only worth saying once the queue is empty: that is the moment the number
    -- above means something, and it is worth being told it was earned.
    seg(0x66BB66FF, "every span accounted for",
      "Nothing unidentified is left: each one is either on a line or\n" ..
      "dismissed by hand.")
  end
  if (n.junk or 0) > 0 then
    seg(nil, string.format("%d dismissed", n.junk),
      "Spans you marked as junk -- slate, chatter, a false start.\n" ..
      "Still in the project and still in the sheet; just decided.")
  end

  if #(c.extra or {}) > 0 then
    seg(0xDDAA33FF, string.format("%d name(s) not on the script", #c.extra))
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
    seg(0xDDAA33FF, string.format("%d item(s) named for two lines at once", c.ambiguous))
  end
  if #(state.name_drift or {}) > 0 then
    seg(0xDDAA33FF, string.format("%d name(s) changed outside this window", #state.name_drift))
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
    seg(0xDD6666FF, string.format("%d Append(s) match no loaded line", #state.orphan_appends))
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
  local dupes = state.dupe_assets
  if dupes and #dupes > 0 then
    seg(0xDDAA33FF, string.format(
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

  -- Filter feedback, in LINES (cards), shown only while something is hidden
  -- -- this replaces the old always-on "rows shown" line under the sheet.
  local shown = 0
  for _, node in ipairs(state.nodes or {}) do
    if node.kind == "line" then shown = shown + 1 end
  end
  if total > 0 and shown < total then
    seg(0xDDAA33FF, string.format("showing %d of %d", shown, total),
      "Filters are hiding the rest: clear the search, the character\n" ..
      "combo or the filter boxes to see every line.")
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
  "status | rematch | cut | identify | " ..
  "sync_markers | build_tracks | pull | name_alts | sort script|record | " ..
  "dupes | append script|asset|nth|text | " ..
  "rows [needle] | spans <needle> | missing | boundaries | verify | " ..
  "make_select <takename> | place | tighten | trim_to_markers"

local function RemoteStatus()
  local c, parts = state.check or {}, {}
  parts[#parts + 1] = string.format("%d of %d lines in the project",
    c.delivered or 0, #(state.lines or {}))
  parts[#parts + 1] = string.format("missing=%d", c.missing or 0)
  parts[#parts + 1] = string.format("extra=%d", #(c.extra or {}))
  parts[#parts + 1] = string.format("rows=%d", #(state.overview or {}))
  parts[#parts + 1] = string.format("scripts=%d", #(state.scripts or {}))
  local scoped, narrowed = AffectedRows()
  parts[#parts + 1] = string.format("scope=%s",
    narrowed and (#scoped .. " selected") or "all")
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
  elseif verb == "identify" or verb == "adopt" or verb == "mark_takes"
      or verb == "mark_selected" then
    -- One verb now. The three old names are kept as aliases: they name the
    -- three SHAPES of audio this used to make the user classify by hand, and
    -- harness scripts were written against them.
    IdentifyItems()
    return state.message or "identify ran with no result string"
  elseif verb == "sync_markers" then
    SyncTakeMarkers()
    return state.message or "sync_markers ran with no result string"
  elseif verb == "build_tracks" then
    Dest.build()
    return state.message or "build_tracks ran with no result string"
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
  elseif verb == "rows" then
    -- The sheet, as the window actually holds it: one line per row, with the
    -- mark, the take number and the item it resolved to.
    --
    -- Exists because diagnosing a routing fault from outside meant rebuilding
    -- the sheet through the pure layer and comparing -- which answers a
    -- DIFFERENT question the moment the two disagree, and that disagreement was
    -- the bug both times. A window that can state its own contents is one call
    -- instead of an afternoon. `rest` filters by asset; bare `rows` counts.
    local shown, sel, keep, no_item, sel_no_item, undelivered, out =
      0, 0, 0, 0, 0, 0, {}
    for _, row in ipairs(state.overview or {}) do
      local asset = row.asset or ""
      if rest == "" or asset:find(rest, 1, true) then
        shown = shown + 1
        if row.user_select then sel = sel + 1 end
        if row.user_keep then keep = keep + 1 end
        if not row.item then
          no_item = no_item + 1
          -- The number that matters on its own: a Sel with no item is a line
          -- that says it has been decided and has no audio to deliver.
          if row.user_select then sel_no_item = sel_no_item + 1 end
        elseif row.user_select then
          -- And the number nothing was watching: a line ticked for delivery
          -- whose audio is NOT on the Selects track. Two lines sat like that
          -- through three passes of this session, silent, because every check
          -- there was looked for duplicates -- a loud symptom -- and nothing
          -- compared the ticks against what actually landed.
          local tr = r.GetMediaItem_Track(row.item)
          local tname = ""
          if tr then _, tname = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false) end
          if tname ~= (vo.LoadConfig().track_selects or "Selects") then
            undelivered = undelivered + 1
          end
        end
        if rest ~= "" and #out < 60 then
          local track = ""
          if row.item then
            local tr = r.GetMediaItem_Track(row.item)
            if tr then _, track = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false) end
          end
          -- The transcript too: it is what the take SAYS, the one column a
          -- person reads to tell two takes apart, and its absence on
          -- marker-owned rows was invisible from out here.
          out[#out + 1] = string.format("%s take %s/%s %s%s%s src=%.3f item=%s %s | %s",
            asset, tostring(row.take_index or 0), tostring(row.take_count or 0),
            row.status or "?",
            row.user_select and " SEL" or "", row.user_keep and " KEEP" or "",
            row.source_start or -1,
            row.item and "yes" or "NONE", track,
            (row.transcript and row.transcript ~= "")
              and ("\"" .. row.transcript:sub(1, 60) .. "\"") or "(no transcript)")
        end
      end
    end
    local head = string.format(
      "%d row(s), %d Sel, %d Alt, %d with no item (%d of them Sel), %d Sel not on Selects",
      shown, sel, keep, no_item, sel_no_item, undelivered)
    if #out == 0 then return head end
    return head .. "\n" .. table.concat(out, "\n")

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
  elseif verb == "trim_to_markers" then
    Trim.run()
    return state.message or "trim_to_markers ran with no result string"
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
LoadFollowSettings()
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

    -- The toolbar is a TAB BAR over an ACTION ROW, and the split is the whole
    -- point (SPEC-toolbar.md section 1): a tab never does anything, it only
    -- decides which buttons you are looking at; a button always does
    -- something. The old row mixed the two -- "Sort" opened a panel while
    -- "Place" beside it moved audio on the press -- and that is what made it
    -- unreadable. Names are long on purpose: the button says what it does so
    -- the tooltip does not have to.
    local n_scripts = #state.scripts

    if im.BeginTabBar(ctx, "##toolbar") then
      -- ImGui selects the FIRST tab until told otherwise, which on frame one
      -- silently moved the tool to Setup. state.tab_sync is a frame budget,
      -- set whenever the TOOL decides which tab you should be on -- window
      -- open, a script that failed to load, "Adopt sheet" sending you to
      -- Pull -- and it pushes that decision into the bar.
      --
      -- `want` is read ONCE, before the loop: during a sync the bar reports
      -- the outgoing tab as selected too, and writing state.tab from inside
      -- the loop overwrote the very target the later tabs compare against.
      -- So while syncing, what the bar reports is ignored entirely.
      local want = (state.tab_sync or 0) > 0 and state.tab or nil
      local reported = nil
      for _, t in ipairs(TOOLBAR_TABS) do
        local flags = (want == t.key) and im.TabItemFlags_SetSelected or 0
        if im.BeginTabItem(ctx, t.label, nil, flags) then
          reported = t.key
          if not want and state.tab ~= t.key then
            -- A panel belongs to the tab that opened it; leaving the tab
            -- closes it rather than leaving it hanging under a bar that
            -- cannot close it.
            state.panel = nil
            state.tab = t.key
          end
          im.EndTabItem(ctx)
        end
      end
      if want then
        -- Done as soon as the bar agrees, and in any case bounded, so a
        -- flag the bar never honours cannot freeze the tabs.
        state.tab_sync = (reported == want) and 0 or (state.tab_sync - 1)
      end
      -- Settings is a window, not a group of buttons, so it is a tab-SHAPED
      -- button parked on the right rather than a tab.
      if im.TabItemButton(ctx, "Settings", im.TabItemFlags_Trailing) then
        state.settings_open = true
      end
      im.EndTabBar(ctx)
    end

    -- The ribbon holds ONE height: the tallest a tab has been at this width.
    --
    -- Each tab's row of buttons is as tall as its own contents, so switching
    -- tabs moved the whole sheet up or down under the cursor -- you click
    -- Setup and the card you were reading jumps. Reserving the tallest means
    -- the cards never move when you click around the toolbar.
    --
    -- Measured rather than declared, because the buttons wrap: the same tab is
    -- two rows on a wide window and four on a narrow one, so a constant would
    -- be wrong at every width but one. The measurement is discarded when the
    -- width changes, so a window made wider does not keep the tall reservation
    -- it needed when it was narrow.
    local ribbon_w = select(1, im.GetContentRegionAvail(ctx))
    if state.ribbon_w ~= ribbon_w then
      state.ribbon_w, state.ribbon_h = ribbon_w, 0
    end
    im.BeginGroup(ctx)

    -- The Edit row carries every verb in the tool and a narrow window cannot
    -- hold it on one line, so it WRAPS: continue beside the last widget when
    -- the next one still fits, otherwise start a row.
    --
    -- Measured, not guessed: ImGui has no flow layout, and a fixed break would
    -- be wrong at every width except the one it was chosen at. Sizing from the
    -- label means renaming a button cannot silently push the last one off the
    -- edge -- which is exactly how they went off screen.
    local frame_pad = im.GetStyleVar(ctx, im.StyleVar_FramePadding)
    local item_gap  = im.GetStyleVar(ctx, im.StyleVar_ItemSpacing)
    local row_left  = im.GetCursorPosX(ctx)
    local row_right = row_left + select(1, im.GetContentRegionAvail(ctx))

    -- Each GROUP gets its own row, and the rows share a gutter so the first
    -- button of each lines up under the others: three labelled rows read as a
    -- table, where one wrapped paragraph of buttons reads as a pile. Inside a
    -- group the buttons still wrap when the window is too narrow.
    local GROUPS = { "Match:", "Cut:", "Pick:", "Pull:", "Check:" }
    local gutter = 0
    for _, g in ipairs(GROUPS) do
      local w = im.CalcTextSize(ctx, g)
      if w > gutter then gutter = w end
    end
    gutter = gutter + item_gap * 2
    local body_left = row_left + gutter
    local started = false

    -- `extra` covers anything drawn after the label on the same run: an arrow
    -- button, a combo, a trailing readout.
    local function Flow(label, extra)
      im.SameLine(ctx)
      local w = im.CalcTextSize(ctx, label) + frame_pad * 2 + (extra or 0)
      if im.GetCursorPosX(ctx) + w > row_right then
        im.NewLine(ctx)
        im.SetCursorPosX(ctx, body_left)
      end
    end

    -- Start a labelled group on a row of its own.
    local function Group(label)
      if started then im.NewLine(ctx) end
      started = true
      im.SetCursorPosX(ctx, row_left)
      im.TextDisabled(ctx, label)
      im.SameLine(ctx)
      im.SetCursorPosX(ctx, body_left)
    end

    -- One button per detail panel, the open one held down.
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

    local function Tip(text)
      if im.IsItemHovered(ctx) then im.SetTooltip(ctx, text) end
      im.SameLine(ctx)
    end

    if state.tab == "setup" then
      PanelButton("script", "Choose script…",
        "The script CSVs this project reads, and which column of each\n" ..
        "holds the filename, the line and the character.")

      if im.Button(ctx, "Sources and transcripts…") then
        local ok, why = vo.LaunchSibling("ajsfx_VO_Sources.lua")
        if not ok then state.message, state.message_kind = tostring(why), "error" end
      end
      Tip("The recordings this project reads, and their transcripts.")

      -- Parked at the end of the Setup row, red, behind a confirm that names
      -- the files: it is the only button in the tool that destroys work.
      im.PushStyleColor(ctx, im.Col_Button,        0x8C3A3AFF)
      im.PushStyleColor(ctx, im.Col_ButtonHovered, 0xA84A4AFF)
      if im.Button(ctx, "Start over…") then im.OpenPopup(ctx, "##reset_confirm") end
      im.PopStyleColor(ctx, 2)
      Tip("Delete this project's VO data so the session can be processed\n" ..
          "again from scratch. Audio is never touched.")

      if im.BeginPopup(ctx, "##reset_confirm") then
        im.Text(ctx, "Delete this project's VO data?")
        im.Spacing(ctx)
        im.TextDisabled(ctx, "Goes:")
        im.TextWrapped(ctx, "  " .. (state.project_path
          and vo.Basename(state.project_path) or "(no project file yet)") ..
          "  -- every Lock, Sel, Alt, rename, Append, pin, and the script list.")
        im.TextDisabled(ctx, "Stays:")
        im.TextWrapped(ctx, "  Every item, take name and take marker in the " ..
          "project. This deletes the tool's notes, not your audio -- and Cut " ..
          "is undone with undo, not with this.")
        im.Spacing(ctx)
        local hit, v = im.Checkbox(ctx, "Also delete the transcripts (whisper must run again)",
                                   state.reset_transcripts == true)
        if hit then state.reset_transcripts = v or nil end
        im.Spacing(ctx)
        im.PushStyleColor(ctx, im.Col_Button, 0x8C3A3AFF)
        if im.Button(ctx, "Delete") then
          local also = state.reset_transcripts == true
          pending_action = function() ResetProject(also) end
          im.CloseCurrentPopup(ctx)
        end
        im.PopStyleColor(ctx)
        im.SameLine(ctx)
        if im.Button(ctx, "Cancel") then im.CloseCurrentPopup(ctx) end
        im.EndPopup(ctx)
      end
      im.SameLine(ctx)

      im.TextDisabled(ctx, "  Script: ")
      im.SameLine(ctx, 0, 0)
      if n_scripts == 0 then
        im.TextDisabled(ctx, "(none chosen)")
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

    elseif state.tab == "edit" then
      -- The hero, on its own row above the parts it is made of: a new session
      -- runs these four in this order every time, and the row below shows
      -- exactly which four, so the button teaches the path instead of hiding
      -- it.
      im.SetCursorPosX(ctx, row_left)
      im.PushStyleColor(ctx, im.Col_Button,        0x3E6FA3FF)
      im.PushStyleColor(ctx, im.Col_ButtonHovered, 0x4E86C0FF)
      if im.Button(ctx, "Run the whole pass") then pending_action = GoldenPath end
      im.PopStyleColor(ctx, 2)
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx,
          "The usual first pass, in order, in one undo step:\n\n" ..
          "  1. match the transcript to the script\n" ..
          "  2. cut the recording into takes\n" ..
          "  3. pick a take for each line\n" ..
          "  4. pull the items to their tracks\n\n" ..
          "Each step is the row of the same name below, for when you want\n" ..
          "just one. This CHANGES ITEMS: it cuts, names and moves audio.\n\n" ..
          "Acts on the selection, like every button below: the line under\n" ..
          "this one says what that is right now.\n\n" ..
          "Step 3 picks each line's " ..
          ((state.auto_select_take == "first") and "FIRST" or "LAST") ..
          " take -- whichever of the two\nAuto-pick buttons you used last.")
      end
      im.SameLine(ctx)
      im.TextDisabled(ctx, "  match \226\134\146 cut \226\134\146 pick \226\134\146 pull")

      -- Directly under the hero and above every row: the scope is the one
      -- thing that changes what all of these do, so it is never more than a
      -- glance away from the button being pressed.
      im.NewLine(ctx)
      im.SetCursorPosX(ctx, row_left)
      DrawScopeLine()
      started = true

      -- The rows below are the hero's own words -- match, cut, pick, pull --
      -- in the same order, plus Check: the one phase the batch button cannot
      -- run for you. Rows are WORK PHASES, not object categories: finding a
      -- button costs one question, "which part of the job am I doing?", and
      -- the answer is the same whether you pressed the hero or are walking
      -- the steps by hand.
      Group("Match:")
      if im.Button(ctx, "Match transcript to script") then TidyPass() end
      Tip("Re-read every transcript and identify the lines again from scratch,\n" ..
          "then write down what the timeline shows: a take whose item sits on\n" ..
          "Selects is marked Sel. Lines left carrying two selects are counted\n" ..
          "so you can pick one.\n\n" ..
          "Sheet only -- no item is touched. Run it after transcribing, or\n" ..
          "after editing the script.")

      -- The per-item forms of matching, as three plain buttons. They lived in
      -- an "Identify line from item ▾" menu, which hid three distinct
      -- situations behind one generic name and an extra click; each button
      -- now names its situation itself.
      Flow("Identify the lines in these items")
      if im.Button(ctx, "Identify the lines in these items") then
        pending_action = IdentifyItems
      end
      Tip("Work out which script lines are in the audio, and write it down.\n\n" ..
          "It sees for itself what shape each item is in. An item holding ONE\n" ..
          "take becomes that take -- marked at your own edges, named for its\n" ..
          "line. An item holding SEVERAL gets a marker per take and no name,\n" ..
          "because it has no one line to be named after; Cut splits those.\n\n" ..
          "This was three buttons -- Find lines in items, Assign items to\n" ..
          "lines, Adopt this whole session -- which differed only in the shape\n" ..
          "of the audio, and choosing wrong did the wrong thing. Safe to\n" ..
          "re-run: a name that already means a line is never overwritten.")

      Group("Cut:")
      -- First in the row, before the single-step verbs it is built out of:
      -- this position is the row's MACRO slot -- the one press that does the
      -- whole job, with the steps behind it for when it guesses wrong.
      if im.Button(ctx, "Tidy Up Take") then pending_action = Trim.tidy_take end
      Tip("The button for \"I just trimmed this clip by hand -- make it right\n" ..
          "again\". In one undo step:\n\n" ..
          "1. Remove Extra Take Markers (below), then\n" ..
          "2. snap the surviving marker to the item's new edges, then\n" ..
          "3. put the standard fade on any edge left at zero.\n\n" ..
          "Fades are FILLED, never overwritten: a trim leaves the edge it cut\n" ..
          "raw and the other edge's fade intact, so only the raw one is\n" ..
          "restored and a fade you drew by hand survives.\n\n" ..
          "A clip still holding several markers -- because the words refused\n" ..
          "to choose between them -- is not snapped, and is reported.\n\n" ..
          "Acts on the selection, or everything when nothing is selected.")

      Flow("Cut recording into takes")
      if im.Button(ctx, "Cut recording into takes") then
        pending_action = RunCut
      end
      Tip("Splits every take in scope out of its recording and names it the\n" ..
          "script's filename. Nothing moves and nothing is decided -- Pull is\n" ..
          "where a take's fate is settled.\n\n" ..
          "Select a recording to cut all of it, or rows to cut just those.\n" ..
          "The line above the rows says which.")

      Flow("Trim items to their markers")
      if im.Button(ctx, "Trim items to their markers") then
        pending_action = function() Trim.run("item") end
      end
      Tip("Set each item's edges to the take marker inside it -- no re-cut,\n" ..
          "no re-match, no split. The manual half of \"the marker is what\n" ..
          "the cut will be\": drag a marker to where the clip should start\n" ..
          "and end, then trim the item onto it.\n\n" ..
          "The audio does not move: the same sample stays at the same\n" ..
          "project time. An item holding SEVERAL markers is a recording,\n" ..
          "not a take, and is left alone -- Cut is what splits those.")

      Flow("Snap markers to items")
      if im.Button(ctx, "Snap markers to items") then
        pending_action = function() Trim.run("marker") end
      end
      Tip("Set each take marker to the edges of the item it sits in -- the\n" ..
          "other direction from Trim, and the batch form of \"Snap marker\n" ..
          "to item\" in a take's menu.\n\n" ..
          "This is what to press after adjusting a head or tail by hand:\n" ..
          "the item is now the truth and the marker is stale. (Auto-adjust\n" ..
          "head and tail already moves the marker for you; only a drag\n" ..
          "leaves the two disagreeing.)\n\n" ..
          "An item holding SEVERAL markers is a recording, not a take, and\n" ..
          "is left alone -- there is no one marker to snap.")

      Flow("Auto-adjust head and tail")
      if im.Button(ctx, "Auto-adjust head and tail") then pending_action = TightenItems end
      Tip("Measure where the audio really is in each item and set its edges\n" ..
          "to the standard head and tail room. Inward only, so speech is\n" ..
          "never lost; hand-trimmed items (custom fades) are left alone. The\n" ..
          "take's marker follows the new edges. Works on the REAPER\n" ..
          "selection, or everything on Selects + Alts when nothing is\n" ..
          "selected.")

      Flow("Remove Extra Take Markers")
      if im.Button(ctx, "Remove Extra Take Markers") then
        pending_action = Trim.remove_extras
      end
      Tip("Everything on a clip that is not its own take marker:\n\n" ..
          "DUPLICATES -- two script lines that have both claimed the same\n" ..
          "stretch of audio. The words spoken there decide which is right\n" ..
          "and the loser's marker is deleted. Only OVERLAPPING markers are\n" ..
          "ever compared, so an uncut recording -- one marker per take, none\n" ..
          "overlapping -- has nothing to lose here. It refuses whenever the\n" ..
          "words do not clearly pick a winner (no transcript, nothing\n" ..
          "matching well, or two lines too close to call) and reports those\n" ..
          "by name.\n\n" ..
          "LEFTOVERS -- markers before and after this clip's own audio, which\n" ..
          "is what REAPER's split leaves behind when it copies the whole\n" ..
          "marker set into both halves.\n\n" ..
          "Acts on the selection, or everything when nothing is selected.")

      Flow("Apply the cut fades")
      if im.Button(ctx, "Apply the cut fades") then pending_action = Trim.fades end
      Tip("Put the standard short fades (Settings) back on the selected\n" ..
          "items -- the ones a cut writes, and the ones a comp, a re-trim\n" ..
          "or a hand-drawn crossfade replaces.\n\n" ..
          "It also re-enrols the item into \"Auto-adjust head and tail\":\n" ..
          "custom fades are how a hand-trimmed item is recognised and left\n" ..
          "alone, so an item with the defaults back is one Auto-adjust is\n" ..
          "willing to measure and move again.\n\n" ..
          "Acts on the REAPER selection.")

      -- Two buttons, not a button and a rule combo. The combo was the one
      -- control on the toolbar that did nothing when clicked -- it set state
      -- for a LATER press, which is exactly the tab-like behaviour the rest
      -- of the row forbids. With two rules there is no menu to justify:
      -- each button says its whole rule and acts on the press. Whichever
      -- was pressed last is the rule the hero's batch run uses.
      Group("Pick:")
      if im.Button(ctx, "Auto-pick selects: last take") then
        AutoSelectTakes(AffectedRows(), "last")
      end
      Tip("Mark each line's LAST take as the select -- the reader kept going\n" ..
          "until they had it, so the last read is usually the keeper.\n\n" ..
          "Locked lines are left alone, and any Sel you ticked by hand\n" ..
          "stands. The sheet's Sel boxes are the per-line version of this.")

      Flow("Auto-pick selects: first take")
      if im.Button(ctx, "Auto-pick selects: first take") then
        AutoSelectTakes(AffectedRows(), "first")
      end
      Tip("The same pass, picking each line's FIRST take instead.")

      Flow("Auto-name the alts")
      if im.Button(ctx, "Auto-name the alts") then pending_action = ApplyAltNames end
      Tip("Give every take marked Alt its own numbered alt name (the\n" ..
          "pattern in Settings), so it can ship beside the select. The\n" ..
          "select keeps the plain name; a take that already has its own\n" ..
          "name is left alone.")

      Group("Pull:")
      -- The row's MACRO slot, same as Tidy Up Take leads Cut: one press for
      -- the whole job, with the steps still behind it.
      if im.Button(ctx, "Deliver") then pending_action = Dest.deliver end
      Tip("The whole of Pull in one press, one undo step:\n\n" ..
          "1. Build the destination tracks, then\n" ..
          "2. Pull items to their tracks, then\n" ..
          "3. Lay items out in script order.\n\n" ..
          "These three are almost never wanted apart -- this is what you\n" ..
          "press once the takes are picked.\n\n" ..
          "A step with nothing to do says so and the next one still runs;\n" ..
          "the message reads back what each of the three found. Safe to\n" ..
          "re-run: all three already are.")

      Flow("Pull items to their tracks")
      PanelButton("pull", "Pull items to their tracks",
        "Moves items onto Selects, Alts, Outs and Review tracks nested under\n" ..
        "the recording they came from, matched to the script by name.")

      Flow("Build the destination tracks")
      if im.Button(ctx, "Build the destination tracks") then
        pending_action = Dest.build
      end
      Tip("Make the Selects / Alts / Review tracks under each recording\n" ..
          "without moving anything.\n\n" ..
          "Pull builds them as a side effect of having somewhere to put an\n" ..
          "item, so until the first pull there is nowhere to drag a take by\n" ..
          "hand and no way to see the shape the session is heading for.\n" ..
          "Safe to re-run: a track that already exists is left alone.")

      Flow("Lay items out in script order")
      PanelButton("sort", "Lay items out in script order",
        "Lays the items out on the timeline in script order or record order,\n" ..
        "on fresh child tracks so nothing lands on anything.")

      -- Check: does the sheet agree with the timeline, and is the leftover
      -- state accounted for. The phase the hero cannot run, because its
      -- verbs need a person deciding. The first two buttons wear their
      -- counts, so this row reads as state before anything is clicked --
      -- "(0)" everywhere means the session agrees with itself.
      Group("Check:")
      local rec = state.reconcile
                  or { disagree = {}, unbacked_markers = {}, orphan_marks = {} }
      local n_dis  = #rec.disagree
      local n_gone = #rec.unbacked_markers + #rec.orphan_marks

      PanelButton("disagree", string.format("Marks vs tracks (%d)", n_dis),
        "Takes whose Sel/Alt marks contradict the track their item sits\n" ..
        "on. The panel lists each one and fixes them as a batch: adopt the\n" ..
        "timeline (the tracks are right) or adopt the sheet (the marks are\n" ..
        "right -- Pull moves the items to match).")

      Flow(string.format("Takes without audio (%d)", n_gone))
      PanelButton("noaudio", string.format("Takes without audio (%d)", n_gone),
        "Markers and marks whose audio is no longer in the project -- the\n" ..
        "item was deleted, or trimmed past them. Relink each to the item\n" ..
        "it belongs to, or clear its marks on the row itself.")

    end

    im.EndGroup(ctx)
    local _, ribbon_h = im.GetItemRectSize(ctx)
    if ribbon_h > (state.ribbon_h or 0) then state.ribbon_h = ribbon_h end
    if ribbon_h < state.ribbon_h then im.Dummy(ctx, 1, state.ribbon_h - ribbon_h) end

    if     state.panel == "disagree" then DrawDisagreePanel()
    elseif state.panel == "noaudio"  then DrawNoAudioPanel()
    elseif state.panel == "script" then DrawScriptPanel()
    elseif state.panel == "cut"    then DrawCutPanel()
    elseif state.panel == "pull"   then DrawPullPanel()
    elseif state.panel == "sort"   then DrawLayoutBar() end

    local bad = BadScriptCount()
    if bad > 0 then
      im.TextColored(ctx, 0xDDAA33FF, string.format(
        "%d of %d script%s is not usable, so its lines are missing.",
        bad, n_scripts, n_scripts == 1 and "" or "s"))
      im.SameLine(ctx)
      if im.Button(ctx, "Choose script…##warn") then
        state.tab, state.panel, state.tab_sync = "setup", "script", 4
      end
    end

    im.Separator(ctx)
    DrawSummary()
    im.Spacing(ctx)
    DrawFilters()
    im.Spacing(ctx)

    -- Reserve room for whatever notices are showing; the table takes the rest.
    local rows = 0
    if state.message ~= ""       then rows = rows + vo.CountLines(state.message, 4) end
    if state.project_error ~= "" then rows = rows + vo.CountLines(state.project_error, 4) end
    if not state.project_path    then rows = rows + 1 end

    -- GetContentRegionAvail returns width first, so height is the SECOND value.
    local _, avail_h = im.GetContentRegionAvail(ctx)
    DrawCards(math.max(120, avail_h - im.GetFrameHeightWithSpacing(ctx) * rows))

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
