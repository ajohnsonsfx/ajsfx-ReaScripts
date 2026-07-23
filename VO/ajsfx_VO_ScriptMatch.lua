-- @description ajsfx VO ScriptMatch
-- @author ajsfx
-- @version 0.3
-- @changelog Add in-Settings download of a CUDA whisper-cli binary and models (incl. large-v3-turbo), GPU device detection, per-build install state with Repair, progress labels, and buttons to open the download folders
-- @about Cut a recorded VO session into one clip per script line and name each
--        clip with its delivery asset name. Reads a CSV script, transcribes the
--        selected items locally with whisper.cpp, matches spoken spans against
--        the script, and routes the results to Selects / Alts / Review tracks.
--        Low-confidence and unmatched audio is flagged, never guessed.
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
  speaker          = "",
  type             = "",
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

  summary[#summary + 1] = string.format("%d matched, %d for review, %d unmatched.",
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
  local csv_text = ReadFile(state.csv_path)
  if not csv_text then
    state.message = "Cannot read the script CSV:\n" .. state.csv_path
    return
  end

  local rows = vo.ParseCSV(csv_text)
  if #rows < 2 then
    state.message = "The script CSV has no data rows."
    return
  end

  local header = table.remove(rows, 1)
  local cols, err = vo.MapColumns(header, cfg.column_mapping)
  if not cols then
    state.message = err
    return
  end

  local lines = vo.BuildScriptLines(rows, cols, {
    skip_values = cfg.skip_values,
    speaker     = state.speaker,
    type        = state.type,
  })
  if #lines == 0 then
    state.message = "No script lines survived the filters."
    return
  end

  r.SetProjExtState(0, PROJ_SECTION, "script_csv", state.csv_path)

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

  im.SetNextWindowSize(ctx, 500, 400, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'ajsfx VO ScriptMatch', true)

  local pressed_run = false

  if visible then
    im.TextDisabled(ctx, string.format("%d item(s) selected, %d skipped.", #usable, #skipped))
    im.Spacing(ctx)

    local changed
    changed, state.csv_path = im.InputText(ctx, "Script CSV", state.csv_path)
    im.SameLine(ctx)
    if im.Button(ctx, "Browse") then
      local ok, path = r.GetUserFileNameForRead(state.csv_path, "Select the session script", "csv")
      if ok then state.csv_path = path end
    end

    im.Spacing(ctx)
    im.SeparatorText(ctx, "Filters")
    changed, state.speaker = im.InputText(ctx, "Speaker", state.speaker)
    changed, state.type    = im.InputText(ctx, "Type",    state.type)
    im.TextDisabled(ctx, "Leave blank to use every line in the script.")

    im.Spacing(ctx)
    im.SeparatorText(ctx, "This session")
    changed, state.use_alts_track = im.Checkbox(ctx, "Send non-primary takes to the Alts track", state.use_alts_track)
    changed, state.suffix_alt_names = im.Checkbox(ctx, "Suffix non-primary takes (_tk01, _tk02…)", state.suffix_alt_names)
    changed, state.primary_last = im.Checkbox(ctx, "The last take of a line is the primary", state.primary_last)
    im.TextDisabled(ctx, "Uncheck the last box if the first read is usually the keeper.")

    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)

    pressed_run = im.Button(ctx, "Transcribe and cut")
    im.SameLine(ctx)
    im.TextDisabled(ctx, "Nothing changes until transcription finishes.")

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

  if open then r.defer(loop) end
end

r.defer(loop)
