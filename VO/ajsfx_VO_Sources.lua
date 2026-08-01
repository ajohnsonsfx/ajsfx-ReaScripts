-- @noindex
-- Provided by the ajsfx VO package; see ajsfx_VO_Overview.lua's @provides.
--
-- ajsfx VO Sources — one row per recorded source file in the project, and
-- whether it has been transcribed.
--
-- This script owns transcription and nothing else. It does not read the script
-- CSV, does not match, and does not cut: a transcript is a fact about a wav
-- file, and this is the window where that fact gets made.
-- See VO/SPEC-sources.md.

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
local KEY_RSUPER     = Api('Key_RightSuper')

-- Needed to draw the header row by hand; without it the table falls back to
-- TableHeadersRow and simply has no header tooltips.
local HEADER_ROW_FLAGS = Api('TableRowFlags_Headers')

-- vo.TranscriptState and vo.IsBackendReady both stat the filesystem, so both
-- are gated behind a throttle rather than run every frame (CLAUDE.md: use
-- GetProjectStateChangeCount(0) for cache invalidation).
local RELOAD_THROTTLE        = 1.0  -- seconds between row rescans
local BACKEND_CHECK_INTERVAL = 2.0  -- seconds between backend readiness checks

local STATUS_STYLE = {
  yes   = { label = "Yes",   colour = 0x66BB66FF },
  no    = { label = "No",    colour = nil },        -- neutral: default text colour
  stale = { label = "Stale", colour = 0xDDAA33FF },
  error = { label = "Error", colour = 0xDD6666FF },
}

local COLUMNS = {
  { key = "file",        label = "File",        width = 260 },
  { key = "transcribed",  label = "Transcribed", width = 100 },
  { key = "words",       label = "Words",       width =  70 },
  { key = "model",       label = "Model",       width = 160 },
  { key = "items",       label = "Items",       width =  60 },
}

local state = {
  rows      = {},     -- { path, name, status, transcript, words, length, items, reason }
  selected  = {},     -- [path] = true
  anchor    = nil,     -- path a shift-range extends from
  filter    = "",      -- narrows the row list by filename
  scanned_at = -1,     -- GetProjectStateChangeCount when rows were built
  last_rescan = 0,
  message   = nil,     -- { text, tone = "info"|"warn"|"error" }
  running   = false,
  progress  = nil,
  run_started = nil,
  write_fails = {},
  detail    = nil,     -- path of the row whose detail panel is open (Task 9)
  detail_paragraph = 1, -- index into that transcript's paragraphs whose words are shown
  cfg       = vo.LoadConfig(),
  backend   = nil,     -- { ready = bool, reason = string }
  backend_check_t = 0,
}

-- -----------------------------------------------------------------------
-- Rows
-- -----------------------------------------------------------------------

local function BuildRows()
  local items = vo.CollectProjectSpans()
  local counts = {}
  for _, it in ipairs(items) do
    if it.path then counts[it.path] = (counts[it.path] or 0) + 1 end
  end

  local rows = {}
  for _, path in ipairs(vo.ProjectSourcePaths(items)) do
    local status, parsed, why = vo.TranscriptState(path)
    rows[#rows + 1] = {
      path       = path,
      name       = path:match("([^\\/]+)$") or path,
      status     = status,
      transcript = parsed,
      words      = parsed and #parsed.words or 0,
      model      = parsed and parsed.model or "",
      items      = counts[path] or 0,
      reason     = why,
    }
  end
  table.sort(rows, function(a, b) return a.name:lower() < b.name:lower() end)
  return rows
end

-- Rebuild rows when the project-state counter moves, throttled so a drag
-- gesture (which can move the counter every frame) cannot force a
-- vo.TranscriptState stat of every source file on every frame. A caller that
-- needs an IMMEDIATE rescan (a transcript just landed on disk) sets
-- state.scanned_at = -1, which always wins over the throttle.
local function MaybeRescan()
  local count = r.GetProjectStateChangeCount(0)
  if count == state.scanned_at then return end
  if state.scanned_at ~= -1
     and (r.time_precise() - state.last_rescan) < RELOAD_THROTTLE then
    return
  end

  state.scanned_at  = count
  state.last_rescan = r.time_precise()
  state.rows = BuildRows()

  -- Selection survives a rescan for paths that still exist; a source removed
  -- from the project (or renamed on disk) drops out on its own.
  local present = {}
  for _, row in ipairs(state.rows) do present[row.path] = true end
  local kept = {}
  for path in pairs(state.selected) do
    if present[path] then kept[path] = true end
  end
  state.selected = kept
  if state.anchor and not present[state.anchor] then state.anchor = nil end
end

-- -----------------------------------------------------------------------
-- Filtering and selection
-- -----------------------------------------------------------------------

local function VisibleRows()
  if state.filter == "" then return state.rows end
  local needle = state.filter:lower()
  local out = {}
  for _, row in ipairs(state.rows) do
    if row.name:lower():find(needle, 1, true) then out[#out + 1] = row end
  end
  return out
end

local function SelectedPaths()
  local out = {}
  for _, row in ipairs(state.rows) do
    if state.selected[row.path] then out[#out + 1] = row end
  end
  return out
end

-- "Re-transcribe" only when EVERY selected row is already current. A stale row
-- is not "already transcribed": its timings are exactly what needs redoing.
local function TranscribeLabel(rows)
  if #rows == 0 then return "Transcribe" end
  for _, row in ipairs(rows) do
    if row.status ~= "yes" then return "Transcribe" end
  end
  return "Re-transcribe"
end

local function SelectAll()
  local sel = {}
  for _, row in ipairs(VisibleRows()) do sel[row.path] = true end
  state.selected = sel
end

local function SelectUntranscribed()
  local sel = {}
  for _, row in ipairs(VisibleRows()) do
    if row.status ~= "yes" then sel[row.path] = true end
  end
  state.selected = sel
end

-- Spreadsheet rules: click replaces, ctrl/cmd-click toggles, shift-click takes
-- the range from the anchor. `visible` is the list the click happened in, so a
-- shift-click selects what the user can actually see between the two rows
-- they clicked (matches Overview's ClickRow idiom).
local function ClickRow(row, index, mods, visible)
  local ctrl  = mods.shortcut == true
  local shift = mods.shift == true

  local anchor_index
  for i, other in ipairs(visible) do
    if other.path == state.anchor then anchor_index = i; break end
  end

  if shift and anchor_index then
    state.selected = {}
    local from, to = anchor_index, index
    if from > to then from, to = to, from end
    for i = from, to do
      local other = visible[i]
      if other then state.selected[other.path] = true end
    end
  elseif ctrl then
    state.selected[row.path] = (not state.selected[row.path]) or nil
    state.anchor = row.path
  else
    state.selected = { [row.path] = true }
    state.anchor = row.path
  end
end

-- -----------------------------------------------------------------------
-- Backend readiness
-- -----------------------------------------------------------------------

-- Fields vo.IsBackendReady actually reads. Only these are refreshed from disk
-- on the throttle, mirroring ajsfx_VO_ScriptMatch.lua's RefreshBackendError.
local BACKEND_CFG_KEYS = { "whisper_bin", "whisper_model", "whisper_threads",
                            "whisper_language", "scratch_dir", "timeout_s" }

local function RefreshBackend()
  local now = r.time_precise()
  if state.backend and (now - state.backend_check_t) < BACKEND_CHECK_INTERVAL then return end
  state.backend_check_t = now

  local fresh = vo.LoadConfig()
  for _, key in ipairs(BACKEND_CFG_KEYS) do state.cfg[key] = fresh[key] end

  local ready, reason = vo.IsBackendReady(state.cfg)
  state.backend = { ready = ready, reason = reason }
end

-- -----------------------------------------------------------------------
-- Transcribing
-- -----------------------------------------------------------------------

local function RunTranscribe(rows, force)
  local sources, size_of = {}, {}
  for _, row in ipairs(rows) do
    local size = vo.FileSize(row.path) or 0
    size_of[row.path] = size
    sources[#sources + 1] = { path = row.path, size = size }
  end
  if #sources == 0 then return end

  local cfg = vo.ShallowCopy(state.cfg)
  cfg.force_retranscribe = force

  state.running     = true
  state.progress     = { done = 0, total = #sources, current = nil }
  state.run_started  = r.time_precise()
  state.write_fails  = {}

  vo.TranscribeSources(cfg, sources, {
    -- Written per file, as each finishes. A cancel at file 40 of 47 must not
    -- discard 39 completed whisper runs.
    on_source = function(path, words, i, total)
      local meta = vo.TranscriptMeta(path, {
        backend  = "whisper.cpp",
        model    = cfg.whisper_model or "",
        language = cfg.whisper_language or "",
      })
      local ok, why = vo.WriteTranscript(path, words, meta)
      if not ok then
        state.write_fails[#state.write_fails + 1] = (path .. ": " .. tostring(why))
      end
      state.progress = { done = i, total = total, current = path }
      state.scanned_at = -1   -- rescan so the row's column flips as it lands
    end,

    on_done = function(results, failures)
      state.running    = false
      state.progress   = nil
      state.scanned_at = -1
      local done = 0
      for _ in pairs(results) do done = done + 1 end

      local lines = { string.format("Transcribed %d of %d file(s).", done, #sources) }
      for _, f in ipairs(failures or {}) do
        lines[#lines + 1] = (f.path:match("([^\\/]+)$") or f.path) .. ": " .. f.reason
      end
      for _, w in ipairs(state.write_fails) do lines[#lines + 1] = w end

      local tone = "info"
      if #(failures or {}) > 0 or #state.write_fails > 0 then tone = "warn" end
      state.message = { text = table.concat(lines, "\n"), tone = tone }
    end,

    on_cancel = function()
      state.running  = false
      state.progress = nil
      state.scanned_at = -1
      state.message = { text = "Cancelled. Files already transcribed were kept.",
                        tone = "info" }
    end,

    on_error = function(err)
      state.running  = false
      state.progress = nil
      state.message  = { text = err, tone = "error" }
    end,
  })
end

-- Already-transcribed rows are skipped unless the run is a re-transcribe (see
-- TranscribeLabel), so re-running a batch after fixing two files costs two
-- files, not fifty.
local function PressTranscribe()
  if state.running then return end
  local rows = SelectedPaths()
  if #rows == 0 then return end
  RunTranscribe(rows, TranscribeLabel(rows) == "Re-transcribe")
end

-- -----------------------------------------------------------------------
-- Drawing
--
-- Everything below uses ctx, which is why it sits here rather than with the
-- logic above: a function written above this local would bind the GLOBAL ctx,
-- which is nil (see ajsfx_VO_Overview.lua for the same note).
-- -----------------------------------------------------------------------

local ctx = im.CreateContext('VO Sources')

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

-- A hovered tooltip that still works on a disabled widget, so a greyed-out
-- Transcribe button can explain WHY it is greyed out.
local function TooltipEvenWhenDisabled(text)
  local flags = Api('HoveredFlags_AllowWhenDisabled') or 0
  if im.IsItemHovered(ctx, flags) then im.SetTooltip(ctx, text) end
end

local pending_action = nil   -- deferred so nothing mutates mid-table

local id_depth = 0

local function DrawTableBody(visible)
  if HEADER_ROW_FLAGS then
    im.TableNextRow(ctx, HEADER_ROW_FLAGS)
    for i, c in ipairs(COLUMNS) do
      im.TableSetColumnIndex(ctx, i - 1)
      im.TableHeader(ctx, c.label)
    end
  else
    im.TableHeadersRow(ctx)
  end

  if #visible == 0 then
    im.TableNextRow(ctx)
    im.TableSetColumnIndex(ctx, 0)
    im.TextDisabled(ctx, #state.rows == 0
      and "No recorded audio in this project yet."
      or  "No files match the filter.")
    return
  end

  local overlap = Api('SelectableFlags_AllowOverlap')
  local sel_flags = im.SelectableFlags_SpanAllColumns
  if overlap then sel_flags = sel_flags | overlap end

  for i, row in ipairs(visible) do
    im.TableNextRow(ctx)
    im.PushID(ctx, i)
    id_depth = id_depth + 1

    -- Highlight the row the batch is currently working on.
    if state.running and state.progress and state.progress.current == row.path then
      im.TableSetBgColor(ctx, im.TableBgTarget_RowBg1, 0x3E6FA355)
    end

    -- File ------------------------------------------------------------
    im.TableSetColumnIndex(ctx, 0)
    if im.Selectable(ctx, row.name, state.selected[row.path] == true, sel_flags) then
      -- Read the modifiers now, inside the frame that saw the click; by the
      -- time the deferred action runs the key could already be up.
      local captured = ReadModifiers()
      local at = i
      pending_action = function() ClickRow(row, at, captured, visible) end
    end
    -- Double-click toggles the per-file detail panel: a second double-click on
    -- the same row that opened it closes it again.
    if im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, im.MouseButton_Left) then
      local target = row.path
      pending_action = function()
        if state.detail == target then
          state.detail = nil
        else
          state.detail = target
          state.detail_paragraph = 1
        end
      end
    end

    -- Transcribed -------------------------------------------------------
    im.TableSetColumnIndex(ctx, 1)
    local style = STATUS_STYLE[row.status]
    if style and style.colour then
      im.TextColored(ctx, style.colour, style.label)
    else
      im.Text(ctx, style and style.label or row.status)
    end
    if row.status == "error" and im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, row.reason or "Could not parse the transcript.")
    end

    -- Words ---------------------------------------------------------------
    im.TableSetColumnIndex(ctx, 2)
    im.Text(ctx, row.words > 0 and tostring(row.words) or "")

    -- Model -----------------------------------------------------------
    im.TableSetColumnIndex(ctx, 3)
    im.TextDisabled(ctx, row.model or "")

    -- Items -----------------------------------------------------------------
    im.TableSetColumnIndex(ctx, 4)
    im.Text(ctx, tostring(row.items))

    im.PopID(ctx)
    id_depth = id_depth - 1
  end
end

local function DrawTable(height, visible)
  local flags = im.TableFlags_Borders | im.TableFlags_Resizable
              | im.TableFlags_Reorderable
              | im.TableFlags_ScrollY | im.TableFlags_RowBg
  if not im.BeginTable(ctx, "vo_sources", #COLUMNS, flags, 0, height) then
    return
  end
  for _, c in ipairs(COLUMNS) do
    im.TableSetupColumn(ctx, c.label, im.TableColumnFlags_WidthFixed, c.width)
  end
  im.TableSetupScrollFreeze(ctx, 0, 1)

  -- Run inside pcall for the reason ScriptMatch and Overview both do: an
  -- error escaping between BeginTable and EndTable leaves ImGui's ID stack
  -- corrupted for every later frame.
  local ok, err = pcall(DrawTableBody, visible)
  while id_depth > 0 do
    im.PopID(ctx)
    id_depth = id_depth - 1
  end
  im.EndTable(ctx)
  if not ok then state.message = { text = tostring(err), tone = "error" } end
end

local function DrawToolbar()
  if im.Button(ctx, "Select all") then pending_action = SelectAll end
  im.SameLine(ctx)
  if im.Button(ctx, "Select untranscribed") then pending_action = SelectUntranscribed end
  im.SameLine(ctx)

  im.SetNextItemWidth(ctx, 220)
  local changed, text = im.InputTextWithHint(ctx, "##filter", "Filter by filename…", state.filter)
  if changed then state.filter = text end

  im.SameLine(ctx)
  local selected = SelectedPaths()
  local label = TranscribeLabel(selected)
  if #selected > 0 then
    label = string.format("%s %d file%s", label, #selected, #selected == 1 and "" or "s")
  end

  local backend_ready = state.backend and state.backend.ready == true
  local disabled = (#selected == 0) or state.running or not backend_ready
  if disabled then im.BeginDisabled(ctx, true) end
  local pressed = im.Button(ctx, label)
  if disabled then im.EndDisabled(ctx) end
  if pressed and not disabled then pending_action = PressTranscribe end

  if #selected == 0 then
    TooltipEvenWhenDisabled("Select one or more files first.")
  elseif state.running then
    TooltipEvenWhenDisabled("A transcription is already running.")
  elseif not backend_ready then
    TooltipEvenWhenDisabled(state.backend and state.backend.reason
      or "The speech backend is not ready.")
  end
end

local function DrawBackendLine()
  if not state.backend or state.backend.ready then return end
  im.TextColored(ctx, 0xDD6666FF, state.backend.reason or "The speech backend is not ready.")
  im.SameLine(ctx)
  if im.Button(ctx, "Settings…") then
    vo.LaunchSibling("ajsfx_VO_Settings.lua")
  end
end

local function DrawProgress()
  if not state.progress then return end
  local p = state.progress
  local elapsed = state.run_started and (r.time_precise() - state.run_started) or 0
  local name = p.current and (p.current:match("([^\\/]+)$") or p.current) or ""
  im.TextColored(ctx, 0x66AADDFF, string.format(
    "Transcribing %d of %d — %s (%.0fs elapsed)", p.done, p.total, name, elapsed))
end

local MESSAGE_COLOUR = { info = 0x66BB66FF, warn = 0xDDAA33FF, error = 0xDD6666FF }

local function DrawMessage()
  if not state.message then return end
  im.TextColored(ctx, MESSAGE_COLOUR[state.message.tone] or 0x66BB66FF, state.message.text)
end

-- -----------------------------------------------------------------------
-- Detail panel (Task 9)
--
-- The list screen's second screen: everything known about ONE source file,
-- reached by double-clicking its row. It owns no state of its own beyond
-- which row is open and which paragraph's words are currently interactive —
-- everything else it draws comes straight off row.transcript.
-- -----------------------------------------------------------------------

-- Move the edit cursor to a word's position in the arrange view. `t` is
-- SOURCE time (as stored in the transcript); the first project item that
-- plays this source converts it to project time. A source with no item left
-- in the project (trimmed out, or the item deleted) has nothing to seek to.
local function GoToWord(source_path, t)
  for _, it in ipairs(vo.CollectProjectSpans()) do
    if it.path == source_path then
      r.SetEditCurPos(vo.SourceTimeToProject(t, it), true, false)
      return true
    end
  end
  return false
end

local function DetailRow()
  if not state.detail then return nil end
  for _, row in ipairs(state.rows) do
    if row.path == state.detail then return row end
  end
  return nil
end

-- The focused paragraph's words, one im.SmallButton each, wrapped onto
-- multiple lines by hand: SameLine is skipped whenever the next word would not
-- fit in what is left of the current line.
local function DrawFocusedWords(row, paragraph_words, index)
  local words = paragraph_words[index]
  if not words or #words == 0 then return end

  im.Spacing(ctx)
  im.TextDisabled(ctx, "Click a word to move the edit cursor there:")

  local avail_w = im.GetContentRegionAvail(ctx)
  local line_used = 0
  for wi, w in ipairs(words) do
    local text_w = im.CalcTextSize(ctx, w.text)
    local item_w = text_w + 14  -- rough SmallButton frame padding

    if wi > 1 then
      if line_used + item_w <= avail_w then
        im.SameLine(ctx)
      else
        line_used = 0
      end
    end

    im.PushID(ctx, wi)
    if im.SmallButton(ctx, w.text) then
      GoToWord(row.path, w.t0)
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, string.format("%.3f \226\128\147 %.3f s", w.t0, w.t1))
    end
    im.PopID(ctx)

    line_used = line_used + item_w
  end
end

-- Everything a "yes" or "stale" row shows: the identity preamble, the
-- reassembled prose, the focused paragraph's clickable words, and the
-- re-transcribe action. A "stale" row gets the same panel plus a warning line
-- — its transcript is still readable, just no longer current.
local function DrawTranscriptDetail(row)
  local t = row.transcript

  im.Text(ctx, row.name)
  if row.status == "stale" then
    im.TextColored(ctx, STATUS_STYLE.stale.colour,
      "Stale \226\128\148 the source audio has changed since this transcript was made.")
  end

  im.Text(ctx, "Source: " .. (t.source or ""))
  im.Text(ctx, "Source bytes: " .. tostring(t.source_bytes or 0))
  im.Text(ctx, "Source hash: " .. (t.source_hash or ""))
  im.Text(ctx, "Backend: " .. (t.backend or ""))
  im.Text(ctx, "Model: " .. (t.model or ""))
  im.Text(ctx, "Language: " .. (t.language or ""))
  im.Text(ctx, "Words: " .. tostring(#t.words))
  im.Spacing(ctx)

  local paragraph_words = vo.ParagraphWords(t.words)
  local paragraphs      = vo.Paragraphs(t.words)

  if #paragraphs == 0 then
    im.TextDisabled(ctx, "No words in this transcript.")
  else
    -- Clamp: a re-transcribe can shrink the word list out from under whatever
    -- paragraph index was focused before it landed.
    if not state.detail_paragraph or state.detail_paragraph > #paragraphs then
      state.detail_paragraph = 1
    end
    for i, text in ipairs(paragraphs) do
      im.PushID(ctx, i)
      im.TextWrapped(ctx, text)
      if im.IsItemClicked(ctx, im.MouseButton_Left) then
        state.detail_paragraph = i
      end
      im.PopID(ctx)
    end
    DrawFocusedWords(row, paragraph_words, state.detail_paragraph)
  end

  im.Spacing(ctx)
  local backend_ready = state.backend and state.backend.ready == true
  local disabled = state.running or not backend_ready
  if disabled then im.BeginDisabled(ctx, true) end
  if im.Button(ctx, "Re-transcribe this file") then
    pending_action = function() RunTranscribe({ row }, true) end
  end
  if disabled then im.EndDisabled(ctx) end
  if state.running then
    TooltipEvenWhenDisabled("A transcription is already running.")
  elseif not backend_ready then
    TooltipEvenWhenDisabled(state.backend and state.backend.reason
      or "The speech backend is not ready.")
  end
end

-- A "no" row has nothing to show but its name and a way to transcribe it.
local function DrawUntranscribedDetail(row)
  im.Text(ctx, row.name)
  im.Spacing(ctx)
  local backend_ready = state.backend and state.backend.ready == true
  local disabled = state.running or not backend_ready
  if disabled then im.BeginDisabled(ctx, true) end
  if im.Button(ctx, "Transcribe") then
    pending_action = function() RunTranscribe({ row }, false) end
  end
  if disabled then im.EndDisabled(ctx) end
  if state.running then
    TooltipEvenWhenDisabled("A transcription is already running.")
  elseif not backend_ready then
    TooltipEvenWhenDisabled(state.backend and state.backend.reason
      or "The speech backend is not ready.")
  end
end

-- An "error" row's transcript could not be parsed; name the reason and the
-- file so the user can go delete it rather than guess.
local function DrawErrorDetail(row)
  im.Text(ctx, row.name)
  im.TextColored(ctx, STATUS_STYLE.error.colour,
    row.reason or "Could not parse the transcript.")
  im.TextDisabled(ctx, vo.TranscriptPath(row.path) or row.path)
end

local function DrawDetailPanel()
  if not state.detail then return end

  local visible = im.BeginChild(ctx, "detail", 0, 0, im.ChildFlags_Border)
  if visible then
    local row = DetailRow()
    if not row then
      im.TextDisabled(ctx, "This file is no longer in the list.")
    elseif row.status == "no" then
      DrawUntranscribedDetail(row)
    elseif row.status == "error" then
      DrawErrorDetail(row)
    else
      DrawTranscriptDetail(row)
    end

    im.Spacing(ctx)
    if im.Button(ctx, "Close") then
      pending_action = function() state.detail = nil end
    end
  end
  im.EndChild(ctx)
end

-- -----------------------------------------------------------------------
-- Main loop
-- -----------------------------------------------------------------------

local function loop()
  -- RefreshBackend is throttled internally, so this call is cheap every frame.
  RefreshBackend()

  -- MaybeRescan is throttled internally too; keep drawing while a batch runs
  -- so the per-file progress line and row highlight update every frame, the
  -- same way ScriptMatch keeps its own window alive during a run.
  MaybeRescan()

  im.SetNextWindowSize(ctx, 900, 560, im.Cond_FirstUseEver)
  local visible_win, open = im.Begin(ctx, 'ajsfx VO Sources', true)

  if visible_win then
    pending_action = nil

    DrawToolbar()
    DrawBackendLine()
    im.Spacing(ctx)

    local rows = VisibleRows()

    -- Reserve room for whatever notices are showing; the table takes the rest.
    local reserve_rows = 1  -- the row-count line below
    if state.progress then reserve_rows = reserve_rows + 1 end
    if state.message  then reserve_rows = reserve_rows + vo.CountLines(state.message.text, 8) end

    local _, avail_h = im.GetContentRegionAvail(ctx)
    local table_h = avail_h - im.GetFrameHeightWithSpacing(ctx) * reserve_rows
    -- With the detail panel open, give it most of what's left rather than
    -- letting the table claim it all: the panel fills whatever remains below
    -- the row-count/progress/message lines (im.BeginChild's 0-height autosizes
    -- to that), so the table only needs enough room to stay usable.
    if state.detail then table_h = math.min(table_h, avail_h * 0.4) end
    DrawTable(math.max(120, table_h), rows)

    im.TextDisabled(ctx, string.format("%d of %d file%s shown.",
      #rows, #state.rows, #state.rows == 1 and "" or "s"))

    DrawProgress()
    DrawMessage()
    DrawDetailPanel()

    im.End(ctx)

    -- Run after End so ImGui's frame is closed before anything mutates state.
    -- One action per frame is enough: they are all user clicks.
    if pending_action then
      local action = pending_action
      pending_action = nil
      action()
    end
  end

  if open then
    r.defer(loop)
  end
end

r.defer(loop)
