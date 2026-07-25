-- @description ajsfx VO ScriptMatch
-- @author ajsfx
-- @version 0.7
-- @changelog Run dialog rebuilt around a live preview table: columns are mapped in the table header, the body shows exactly the lines that will run, and layout and session options collapse out of the way; character filtering is now single-select
-- @about Cut a recorded VO session into one clip per script line and name each
--        clip with its delivery asset name. Reads a CSV script, transcribes the
--        selected items locally with whisper.cpp, matches spoken spans against
--        the script, and routes the results to Selects / Alts / Review tracks.
--        Low-confidence matches are flagged for review, never guessed. Unmatched
--        audio is left untouched on the source track and flagged in the report.
--        Configure the backend in "ajsfx VO Settings". See VO/SPEC.md.
-- @provides
--   [main] .
--   [main] ajsfx_VO_Settings.lua
--   lib/ajsfx_vo.lua
--   ../lib/ajsfx_core.lua > lib/ajsfx_core.lua

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path
local core = require("lib.ajsfx_core")
local vo   = require("lib.ajsfx_vo")

local PROJ_SECTION = "ajsfx_vo"

-- -----------------------------------------------------------------------
-- Preconditions — checked before anything is drawn or launched
-- -----------------------------------------------------------------------

local cfg = vo.LoadConfig()

if r.CountSelectedMediaItems(0) == 0 then
  r.MB("Select the recorded session item(s) on a track first.",
       "ajsfx VO ScriptMatch", 0)
  return
end

local ready, ready_msg = vo.IsBackendReady(cfg)
if not ready then
  r.MB(ready_msg .. "\n\nRun \"ajsfx VO Settings\" to configure the speech backend.",
       "ajsfx VO ScriptMatch", 0)
  return
end

local success, im = pcall(function()
  package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
  return require('imgui')('0.9.3')
end)

if not success then
  r.MB("This script requires the 'imgui' library (ReaImGui).\n" ..
       "Install it via ReaPack: Extensions → ReaPack → Browse packages → ReaImGui.",
       "ReaImGui not found", 0)
  return
end

-- -----------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------

local function ProjectDir()
  local _, proj = r.EnumProjects(-1, "")
  if proj and proj ~= "" then
    return proj:match("^(.*)[/\\][^/\\]*$"), proj:match("([^/\\]+)%.[Rr][Pp][Pp]$")
  end
  return nil, nil
end

local function ReportPath()
  local dir, name = ProjectDir()
  if dir then return dir .. "/" .. (name or "session") .. "_vo_report.csv" end
  return vo.ResolveScratchDir(cfg) .. "/vo_report.csv"
end

local function ReadFile(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local text = f:read("a")
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

-- Keep every span inside the item it came from, so a split can never be
-- attempted across a gap in the session.
local function ClampSpansToItems(plan, items)
  for _, span in ipairs(plan) do
    local midpoint = ((span.raw_start or span.start) + (span.raw_stop or span.stop)) / 2
    for _, item in ipairs(items) do
      if item.path and midpoint >= item.pos and midpoint <= item.pos + item.length then
        local item_end = item.pos + item.length
        if span.start < item.pos then span.start, span.clamped = item.pos, true end
        if span.stop  > item_end  then span.stop,  span.clamped = item_end, true end
        break
      end
    end
  end
end

-- -----------------------------------------------------------------------
-- Run dialog state
-- -----------------------------------------------------------------------

local ctx = im.CreateContext('VO ScriptMatch')

local _, remembered = r.GetProjExtState(0, PROJ_SECTION, "script_csv")
local state = {
  csv_path         = remembered or "",
  loaded_path      = nil,        -- path last read into header/rows (nil = none yet)
  restored         = false,      -- first successful load restored §5.3 precedence
  header           = nil,        -- array of column-name strings from the CSV header
  rows             = nil,        -- data rows (header removed)
  header_error     = "",         -- unreadable / no data / bad header -> run disabled
  mapping          = {},         -- role -> header column name
  skip_text        = "",         -- skip tokens, one per line (part of the layout)
  layout_name      = "",         -- selected preset name ("" = unsaved/inline)
  layout_dirty     = false,      -- mapping edited away from the named preset
  character        = nil,        -- folded character key to keep, nil = all (R3)
  distinct         = nil,        -- vo.DistinctCharacters for the mapped speaker column
  preview          = nil,        -- cached BuildScriptLines result (R4)
  preview_dirty    = true,       -- recompute the preview on the next frame
  use_alts_track   = cfg.use_alts_track or false,
  suffix_alt_names = cfg.suffix_alt_names or false,
  primary_last     = true,
  message          = "",
  running          = false,
}

local items = vo.CollectSourceSpans()

local skipped = {}
for _, item in ipairs(items) do
  if item.skip then
    skipped[#skipped + 1] = string.format("item at %.3fs: %s", item.pos, item.skip)
  end
end

local usable = {}
for _, item in ipairs(items) do
  if not item.skip then usable[#usable + 1] = item end
end

if #usable == 0 then
  r.MB("None of the selected items can be transcribed:\n\n" ..
       table.concat(skipped, "\n"), "ajsfx VO ScriptMatch", 0)
  return
end

-- -----------------------------------------------------------------------
-- Layout / CSV dialog helpers
-- -----------------------------------------------------------------------

local ALL_ROLES = { "asset", "text", "speaker" }

local ROLE_LABEL = {
  asset   = "Filename",
  text    = "Line Text",
  speaker = "Character",
}

-- The preview table is driven by this ordered list, not hardcoded columns.
-- kind = "mapped" -> a column selector in the header, body values from the CSV.
-- kind = "computed" is reserved for future columns whose header is a static
-- label and whose body comes from a render function (Result, Take). Nothing in
-- the drawing code may assume every column is mapped.
local COLUMNS = {
  { key = "speaker", label = "Character", kind = "mapped", role = "speaker",
    optional = true, filter = "character", init_width = 200 },
  { key = "asset",   label = "Filename",  kind = "mapped", role = "asset",
    required = true, init_width = 180 },
  { key = "text",    label = "Line Text", kind = "mapped", role = "text",
    required = true, init_width = 280 },
}

-- Skip-tokens box -> trimmed, non-empty token list (mirrors Settings' Apply()).
local function ParseSkipLines(text)
  local out = {}
  for v in tostring(text or ""):gmatch("[^\n]+") do
    local t = v:match("^%s*(.-)%s*$")
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end

-- Resolve a remembered column name to the actual header entry (exact first, then
-- case/space-insensitive), or nil when the column is absent from this header.
local function HeaderMatch(colname)
  if not colname or colname == "" then return nil end
  local header = state.header or {}
  for _, h in ipairs(header) do if h == colname then return h end end
  local want = tostring(colname):lower():gsub("^%s*(.-)%s*$", "%1")
  for _, h in ipairs(header) do
    if h:lower():gsub("^%s*(.-)%s*$", "%1") == want then return h end
  end
  return nil
end

-- (Re)build the character list from the mapped speaker column. A selection that
-- still exists in the new column survives; one that does not resets to "all".
local function RebuildDistinct()
  local spk = state.mapping.speaker
  local idx
  if spk then
    for i, h in ipairs(state.header or {}) do if h == spk then idx = i; break end end
  end
  if not idx then
    state.distinct  = nil
    state.character = nil
    return
  end
  state.distinct = vo.DistinctCharacters(state.rows or {}, idx)
  if state.character then
    local still_there = false
    for _, d in ipairs(state.distinct) do
      if d.key == state.character then still_there = true; break end
    end
    if not still_there then state.character = nil end
  end
end

-- The character filter as BuildScriptLines arguments. Canonicalization applies
-- whenever a character column carries values; the include-set is nil (inert ->
-- keep every row, blank-character rows included) until a character is chosen,
-- at which point it is a set of exactly one (R3).
local function CharacterFilter()
  if not (state.distinct and #state.distinct > 0) then return nil, nil end
  local canon = vo.CanonicalizeMap(state.distinct)
  if not state.character then return nil, canon end
  return { [state.character] = true }, canon
end

-- Adopt a layout table (mapping + skip_values) against the current header: a
-- remembered column present in the header is selected, an absent one unmapped.
local function ApplyLayoutTable(layout)
  local m = {}
  for _, role in ipairs(ALL_ROLES) do
    m[role] = HeaderMatch(layout.mapping and layout.mapping[role])
  end
  state.mapping   = m
  state.skip_text = table.concat(layout.skip_values or vo.DEFAULT_SKIP_VALUES, "\n")
end

-- Re-intersect the current mapping against a freshly loaded header (CSV swap):
-- keep columns that still exist, drop those that vanished. Skip tokens are kept.
local function ReintersectMapping()
  local m = {}
  for _, role in ipairs(ALL_ROLES) do
    m[role] = HeaderMatch(state.mapping and state.mapping[role])
  end
  state.mapping = m
end

-- Restore the layout on open by SPEC §5.3 precedence: named preset (if it still
-- exists) -> inline per-.rpp layout -> auto-detect from the header.
local function RestoreLayoutFromMemory()
  local layout, name
  local _, ln = r.GetProjExtState(0, PROJ_SECTION, "layout_name")
  if ln and ln ~= "" then
    local preset = vo.LoadLayoutPreset(ln)
    if preset then layout, name = preset, ln end
  end
  if not layout then
    local _, inline = r.GetProjExtState(0, PROJ_SECTION, "layout")
    if inline and inline ~= "" then layout, name = vo.DeserializeLayout(inline), "" end
  end
  if not layout then
    layout, name = { mapping = vo.AutoDetectMapping(state.header) }, ""
  end
  ApplyLayoutTable(layout)
  state.layout_name  = name
  state.layout_dirty = false
end

-- Read, parse and header-validate a CSV path into dialog state. `restore` true
-- on the first successful load (apply §5.3 precedence); false on a mid-session
-- path change (keep the current mapping, dropping columns the new header lacks).
local function LoadCSV(path, restore)
  state.loaded_path  = path
  state.header       = nil
  state.rows         = nil
  state.header_error = ""
  state.distinct     = nil

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
  if #rows == 0 then
    state.header_error = "The script CSV has no data rows."
  end

  if restore then RestoreLayoutFromMemory() else ReintersectMapping() end
  RebuildDistinct()
  state.restored      = true
  state.preview_dirty = true
end

-- The current dialog mapping + skip tokens as a layout table for save/persist.
local function CurrentLayout()
  local mapping = {}
  for _, role in ipairs(ALL_ROLES) do mapping[role] = state.mapping[role] end
  return { mapping = mapping, skip_values = ParseSkipLines(state.skip_text) }
end

-- Save the current layout under `name`, confirming an overwrite first.
local function DoSave(name)
  local ok, reason = vo.ValidatePresetName(name)
  if not ok then state.message = reason; return end
  local exists = false
  for _, n in ipairs(vo.ListLayoutPresets()) do if n == name then exists = true; break end end
  if exists and r.MB("A layout preset named \"" .. name .. "\" already exists.\n" ..
                     "Overwrite it?", "Overwrite layout preset", 4) ~= 6 then
    return
  end
  if vo.SaveLayoutPreset(name, CurrentLayout()) then
    state.layout_name, state.layout_dirty = name, false
    state.message = "Saved layout preset \"" .. name .. "\"."
  else
    state.message = "Could not save the layout preset."
  end
end

-- Load a named preset into the dialog (mapping + skip + character list).
local function LoadPresetByName(name)
  local layout = vo.LoadLayoutPreset(name)
  if not layout then state.message = "Preset not found: " .. name; return end
  ApplyLayoutTable(layout)
  state.layout_name, state.layout_dirty = name, false
  RebuildDistinct()
  state.preview_dirty = true
end

-- Any mapping/skip edit deviates from the named preset -> mark unsaved.
local function MarkDirty()
  state.layout_dirty = true
  state.layout_name  = ""
end

-- One column selector. The label lives inside the control as the preview text,
-- so the table header does not need a separate label column. Options are the
-- header columns; optional roles lead with (none). Editing marks the layout
-- unsaved and rebuilds the character list when the speaker column moves.
local function RoleCombo(role, optional, width)
  local mapped  = state.mapping[role]
  local preview = mapped or (optional and "(none)" or "Column…")

  im.SetNextItemWidth(ctx, width or im.GetContentRegionAvail(ctx))
  if im.BeginCombo(ctx, "##" .. role .. "_col", preview) then
    if optional then
      if im.Selectable(ctx, "(none)", mapped == nil) and mapped ~= nil then
        state.mapping[role] = nil
        MarkDirty()
        state.preview_dirty = true
        if role == "speaker" then RebuildDistinct() end
      end
    end
    for _, h in ipairs(state.header or {}) do
      if im.Selectable(ctx, h, h == mapped) and h ~= mapped then
        state.mapping[role] = h
        MarkDirty()
        state.preview_dirty = true
        if role == "speaker" then RebuildDistinct() end
      end
    end
    im.EndCombo(ctx)
  end
end

-- The "which character" selector, drawn beside the character column selector.
-- Per-run only: it is not saved into a layout preset and does not mark dirty.
local function CharacterCombo(width)
  local has = state.distinct and #state.distinct > 0
  local preview = "(all characters)"
  if has and state.character then
    for _, d in ipairs(state.distinct) do
      if d.key == state.character then preview = d.display; break end
    end
  end

  if not has then im.BeginDisabled(ctx) end
  im.SetNextItemWidth(ctx, width or im.GetContentRegionAvail(ctx))
  if im.BeginCombo(ctx, "##character", preview) then
    if im.Selectable(ctx, "(all characters)", state.character == nil)
       and state.character ~= nil then
      state.character = nil
      state.preview_dirty = true
    end
    for _, d in ipairs(state.distinct or {}) do
      if im.Selectable(ctx, d.display, d.key == state.character)
         and d.key ~= state.character then
        state.character = d.key
        state.preview_dirty = true
      end
    end
    im.EndCombo(ctx)
  end
  if not has then im.EndDisabled(ctx) end
end

-- Recompute the will-run set. This is the same call Run() makes with the same
-- arguments, so the table cannot drift from actual run behaviour (R4). Leaves
-- state.preview nil (not an empty list) when the mapping is incomplete, which
-- the table distinguishes from "mapped but nothing survives".
local function RefreshPreview()
  state.preview_dirty = false
  state.preview = nil
  if not state.header or state.header_error ~= "" or not state.rows then return end

  local cols = vo.MapColumns(state.header, state.mapping)
  if not cols then return end

  local speakers, canon = CharacterFilter()
  state.preview = vo.BuildScriptLines(state.rows, cols, {
    skip_values  = ParseSkipLines(state.skip_text),
    speakers     = speakers,
    canonicalize = canon,
  })
end

-- The table is the interface: columns are mapped in its header, and the body is
-- the list of lines that will actually run. Rows excluded by a skip token, the
-- character filter, or an empty required cell are hidden, not dimmed (R4).
local function DrawTable(height)
  local flags = im.TableFlags_Borders | im.TableFlags_Resizable
              | im.TableFlags_ScrollY | im.TableFlags_RowBg
  if not im.BeginTable(ctx, "script_preview", #COLUMNS, flags, 0, height) then
    return
  end

  for _, c in ipairs(COLUMNS) do
    im.TableSetupColumn(ctx, c.label, im.TableColumnFlags_WidthFixed, c.init_width)
  end
  im.TableSetupScrollFreeze(ctx, 0, 2)

  -- Header row 1: static labels. A required column that is unmapped shows its
  -- label in the warning colour, so what blocks the run is visible in place.
  im.TableNextRow(ctx, im.TableRowFlags_Headers)
  for i, c in ipairs(COLUMNS) do
    im.TableSetColumnIndex(ctx, i - 1)
    if c.required and not state.mapping[c.role] then
      im.TextColored(ctx, 0xDDAA33FF, c.label)
    else
      im.Text(ctx, c.label)
    end
  end

  -- Header row 2: the selectors. The Character cell holds two combos side by
  -- side so its header is no taller than the others.
  im.TableNextRow(ctx)
  for i, c in ipairs(COLUMNS) do
    im.TableSetColumnIndex(ctx, i - 1)
    if c.kind == "mapped" then
      if c.filter == "character" then
        local half = math.max(60, (im.GetContentRegionAvail(ctx) - 8) / 2)
        RoleCombo(c.role, c.optional, half)
        im.SameLine(ctx)
        CharacterCombo(half)
      else
        RoleCombo(c.role, c.optional)
      end
    end
  end

  local lines = state.preview
  if lines and #lines > 0 then
    local clipper = im.CreateListClipper(ctx)
    im.ListClipper_Begin(clipper, #lines)
    while im.ListClipper_Step(clipper) do
      local first, last = im.ListClipper_GetDisplayRange(clipper)
      for n = first, last - 1 do
        local line = lines[n + 1]
        im.TableNextRow(ctx)
        for i, c in ipairs(COLUMNS) do
          im.TableSetColumnIndex(ctx, i - 1)
          if c.kind == "mapped" then
            im.Text(ctx, line[c.key] or "")
          end
        end
      end
    end
  else
    im.TableNextRow(ctx)
    im.TableSetColumnIndex(ctx, 0)
    im.TextDisabled(ctx, lines and "No script lines survive the current filters."
                               or  "Choose the Filename and Line Text columns above.")
  end

  im.EndTable(ctx)
end

-- Persist per-.rpp: CSV path, the inline layout, and the selected preset name
-- (empty while the mapping is unsaved) — SPEC §5.3. Called both on Run and on
-- dialog close so mapping a layout and closing without transcribing is not
-- lost (§13.4).
local function PersistProjectMemory()
  r.SetProjExtState(0, PROJ_SECTION, "script_csv", state.csv_path)
  r.SetProjExtState(0, PROJ_SECTION, "layout", vo.SerializeLayout(CurrentLayout()))
  r.SetProjExtState(0, PROJ_SECTION, "layout_name",
                    state.layout_dirty and "" or (state.layout_name or ""))
end

-- -----------------------------------------------------------------------
-- The run itself
-- -----------------------------------------------------------------------

local function Finish(plan, lines)
  local applied, failures = 0, {}

  core.Transaction("VO ScriptMatch", function()
    applied, failures = vo.ApplyPlan(plan, cfg, usable[1].track)
  end)

  local report = vo.BuildReport(plan, lines)
  local path   = ReportPath()
  local wrote  = WriteFile(path, report)

  local summary = {}
  local counts  = { match = 0, review = 0, unmatched = 0 }
  for _, span in ipairs(plan) do counts[span.kind] = (counts[span.kind] or 0) + 1 end

  summary[#summary + 1] = string.format(
    "%d matched, %d for review, %d unmatched (left untouched on the source track).",
    counts.match, counts.review, counts.unmatched)
  summary[#summary + 1] = string.format("%d clips cut and named.", applied)
  if #skipped > 0 then
    summary[#summary + 1] = "\nItems skipped:\n" .. table.concat(skipped, "\n")
  end
  if #failures > 0 then
    summary[#summary + 1] = "\nProblems:\n" .. table.concat(failures, "\n")
  end
  summary[#summary + 1] = wrote and ("\nReport: " .. path)
                                or ("\nCould not write the report to " .. path)

  r.MB(table.concat(summary, "\n"), "ajsfx VO ScriptMatch", 0)
end

local function Run()
  if not state.header then
    state.message = (state.header_error ~= "" and state.header_error)
                    or "Load a script CSV first."
    return
  end
  if state.header_error ~= "" then
    state.message = state.header_error
    return
  end

  local cols, err = vo.MapColumns(state.header, state.mapping)
  if not cols then state.message = err; return end

  local speakers, canon = CharacterFilter()

  local lines = vo.BuildScriptLines(state.rows, cols, {
    skip_values  = ParseSkipLines(state.skip_text),
    speakers     = speakers,
    canonicalize = canon,
  })
  if #lines == 0 then
    state.message = "No script lines survived the filters."
    return
  end

  PersistProjectMemory()

  cfg.use_alts_track   = state.use_alts_track
  cfg.suffix_alt_names = state.suffix_alt_names
  cfg.primary_take     = state.primary_last and "last" or "first"

  -- One transcription per unique source file, however many items use it.
  local seen, sources = {}, {}
  for _, item in ipairs(usable) do
    if not seen[item.path] then
      seen[item.path] = true
      sources[#sources + 1] = { path = item.path, size = vo.FileSize(item.path) or 0 }
    end
  end

  state.running = true

  vo.TranscribeSources(cfg, sources,
    function(transcripts)
      -- Everything below is still read-only until core.Transaction runs.
      local words = {}
      for _, item in ipairs(usable) do
        for _, word in ipairs(vo.MapWordsToProject(transcripts[item.path] or {}, item)) do
          words[#words + 1] = word
        end
      end
      table.sort(words, function(a, b) return a.t0 < b.t0 end)

      if #words == 0 then
        state.running = false
        r.MB("The transcription produced no words, so there is nothing to match.\n" ..
             "Check that the selected items contain speech.",
             "ajsfx VO ScriptMatch", 0)
        return
      end

      local plan = vo.BuildPlan(lines, words, cfg)
      ClampSpansToItems(plan, usable)

      state.running = false
      Finish(plan, lines)
    end,
    function()
      state.running = false
      r.MB("Cancelled. Nothing in the project was changed.", "ajsfx VO ScriptMatch", 0)
    end,
    function(message)
      state.running = false
      r.MB(message .. "\n\nNothing in the project was changed.",
           "ajsfx VO ScriptMatch", 0)
    end)
end

-- -----------------------------------------------------------------------
-- Run dialog
-- -----------------------------------------------------------------------

local function loop()
  if state.running then return end -- the transcription window has the floor

  if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
    ctx = im.CreateContext('VO ScriptMatch')
  end

  im.SetNextWindowSize(ctx, 760, 720, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'ajsfx VO ScriptMatch', true)

  local pressed_run = false

  if visible then
    im.TextDisabled(ctx, string.format("%d item(s) selected, %d skipped.", #usable, #skipped))
    im.Spacing(ctx)

    -- Script CSV path. A change (typed or browsed) reloads the header + rows;
    -- the first successful load restores the layout by §5.3 precedence, later
    -- loads keep the current mapping against the new header.
    state.csv_path = select(2, im.InputText(ctx, "Script CSV", state.csv_path))
    im.SameLine(ctx)
    if im.Button(ctx, "Browse") then
      local ok, path = r.GetUserFileNameForRead(state.csv_path, "Select the session script", "csv")
      if ok then state.csv_path = path end
    end
    if state.csv_path ~= state.loaded_path then
      LoadCSV(state.csv_path, not state.restored)
    end

    if state.header then
      -- Layout & presets ---------------------------------------------------
      im.Spacing(ctx)
      if im.CollapsingHeader(ctx, "Layout & presets") then
        local preset_names = vo.ListLayoutPresets()
        local preset_items = { "(unsaved)" }
        for _, n in ipairs(preset_names) do preset_items[#preset_items + 1] = n end
        local preset_cur = 0
        if state.layout_name ~= "" and not state.layout_dirty then
          for i, n in ipairs(preset_names) do
            if n == state.layout_name then preset_cur = i; break end
          end
        end
        local pchanged, psel = im.Combo(ctx, "Preset", preset_cur,
          table.concat(preset_items, "\0") .. "\0\0")
        if pchanged and psel ~= preset_cur then
          if psel == 0 then
            state.layout_name, state.layout_dirty = "", true
          else
            LoadPresetByName(preset_names[psel])
          end
        end

        if im.Button(ctx, "Save") then
          if state.layout_name ~= "" then
            DoSave(state.layout_name)
          else
            local ok, name = r.GetUserInputs("Save layout preset", 1,
              "Preset name:,extrawidth=180", "")
            if ok then DoSave(name) end
          end
        end
        im.SameLine(ctx)
        if im.Button(ctx, "Save As...") then
          local ok, name = r.GetUserInputs("Save layout preset as", 1,
            "Preset name:,extrawidth=180", state.layout_name)
          if ok then DoSave(name) end
        end
        im.SameLine(ctx)
        -- Capture the disabled state BEFORE the button: Delete clears layout_name
        -- in this same frame, so gating EndDisabled on a re-read would unbalance
        -- the ImGui stack (see Settings dis_bin/dis_model/dis_check).
        local dis_del = (state.layout_name == "")
        if dis_del then im.BeginDisabled(ctx) end
        if im.Button(ctx, "Delete") then
          local nm = state.layout_name
          if nm ~= "" and r.MB("Delete layout preset \"" .. nm .. "\"?",
                               "Delete layout preset", 4) == 6 then
            vo.DeleteLayoutPreset(nm)
            state.layout_name, state.layout_dirty = "", true
            state.message = "Deleted layout preset \"" .. nm .. "\"."
          end
        end
        if dis_del then im.EndDisabled(ctx) end

        -- Skip tokens live with the presets because they are saved into one.
        im.Spacing(ctx)
        im.TextDisabled(ctx, "Skip tokens — one per line. A row whose Filename cell\n" ..
                             "matches is not yet recorded and is excluded.")
        local skchanged
        skchanged, state.skip_text = im.InputTextMultiline(ctx, "##skip", state.skip_text, 380, 54)
        if skchanged then
          MarkDirty()
          state.preview_dirty = true
        end
      end -- CollapsingHeader "Layout & presets"

    elseif state.header_error ~= "" then
      im.Spacing(ctx)
      im.TextColored(ctx, 0xDD6666FF, state.header_error)
    else
      im.Spacing(ctx)
      im.TextDisabled(ctx, "Choose a script CSV to map its columns.")
    end

    -- Session options -----------------------------------------------------
    im.Spacing(ctx)
    if im.CollapsingHeader(ctx, "Session options") then
      local sch
      sch, state.suffix_alt_names = im.Checkbox(ctx, "Suffix non-primary takes (_tk01, _tk02…)", state.suffix_alt_names)
      sch, state.use_alts_track   = im.Checkbox(ctx, "Send non-primary takes to the Alts track", state.use_alts_track)
      sch, state.primary_last     = im.Checkbox(ctx, "The last take of a line is the primary", state.primary_last)
      im.TextDisabled(ctx, "Uncheck the last box if the first read is usually the keeper.")
    end

    -- The table is the interface (R4). Columns are mapped in its header and the
    -- body is exactly the set of lines that will run.
    if state.preview_dirty then RefreshPreview() end

    if state.header and state.header_error == "" then
      im.Spacing(ctx)
      -- Reserve room for the count line and the run button row below it; the
      -- table takes whatever height is left.
      local reserve = im.GetFrameHeightWithSpacing(ctx) * 3
      DrawTable(math.max(120, im.GetContentRegionAvail(ctx) - reserve))

      im.TextDisabled(ctx, string.format("%d of %d rows will run.",
        state.preview and #state.preview or 0, state.rows and #state.rows or 0))
    end

    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)

    -- Run is blocked until the CSV is valid and every required role is mapped.
    local run_error
    if not state.header then
      run_error = (state.header_error ~= "" and state.header_error) or "Load a script CSV."
    elseif state.header_error ~= "" then
      run_error = state.header_error
    else
      for _, role in ipairs({ "asset", "text" }) do
        if not state.mapping[role] then
          run_error = "Map the required column: " .. ROLE_LABEL[role]
          break
        end
      end
    end

    local dis_run = (run_error ~= nil)
    if dis_run then im.BeginDisabled(ctx) end
    pressed_run = im.Button(ctx, "Transcribe and cut")
    if dis_run then im.EndDisabled(ctx) end
    im.SameLine(ctx)
    im.TextDisabled(ctx, "Nothing changes until transcription finishes.")

    if run_error then
      im.Spacing(ctx)
      im.TextColored(ctx, 0xDDAA33FF, run_error)
    end

    if state.message ~= "" then
      im.Spacing(ctx)
      im.TextColored(ctx, 0xDD6666FF, state.message)
    end
  end

  -- Always End after Begin; skipping it corrupts ImGui's push/pop stack.
  im.End(ctx)

  if pressed_run then
    state.message = ""
    Run()
    if state.running then return end -- hand off to the transcription window
  end

  if open then
    r.defer(loop)
  else
    -- Dialog is closing. Persist whatever is currently mapped so a user who
    -- edited the layout and closed without running doesn't lose it (§13.4).
    PersistProjectMemory()
  end
end

-- Load any remembered CSV once up front so the first frame shows its columns.
LoadCSV(state.csv_path, true)

r.defer(loop)
