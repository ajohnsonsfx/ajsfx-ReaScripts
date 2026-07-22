-- @description ajsfx VO Settings
-- @author ajsfx
-- @version 0.1
-- @changelog Initial release: settings panel for VO ScriptMatch
-- @about Settings panel for ajsfx VO ScriptMatch. Configure the speech backend,
--        matching thresholds, destination tracks, script CSV column mapping and
--        the substitution table. See VO/SPEC.md for the design.
-- @provides
--   [main] .
--   lib/ajsfx_vo.lua
--   ../lib/ajsfx_core.lua > lib/ajsfx_core.lua

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path
local vo = require("lib.ajsfx_vo")

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
-- State
-- -----------------------------------------------------------------------

local ctx = im.CreateContext('VO Settings')

local cfg       = vo.LoadConfig()
local subs_text = vo.FormatSubstitutionText(cfg.substitutions)
local skip_text = table.concat(cfg.skip_values, "\n")
local status    = ""

-- Whisper models live here; this is the only URL the tool knows about.
local MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/tree/main"

local function OpenURL(url)
  if r.CF_ShellExecute then
    r.CF_ShellExecute(url)
  elseif vo.IsWindows() then
    os.execute('start "" "' .. url .. '"')
  else
    os.execute('open "' .. url .. '" 2>/dev/null || xdg-open "' .. url .. '"')
  end
end

local function Apply()
  cfg.substitutions = vo.ParseSubstitutionText(subs_text)
  cfg.skip_values = {}
  for v in skip_text:gmatch("[^\n]+") do
    local trimmed = v:match("^%s*(.-)%s*$")
    if trimmed ~= "" then cfg.skip_values[#cfg.skip_values + 1] = trimmed end
  end
  vo.SaveConfig(cfg)
  status = "Saved."
end

-- -----------------------------------------------------------------------
-- UI
-- -----------------------------------------------------------------------

local function DrawBackend()
  local changed

  changed, cfg.whisper_bin = im.InputText(ctx, "whisper-cli path", cfg.whisper_bin)
  im.SameLine(ctx)
  if im.Button(ctx, "Browse##bin") then
    local ok, path = r.GetUserFileNameForRead(cfg.whisper_bin, "Locate whisper-cli", "")
    if ok then cfg.whisper_bin = path end
  end

  changed, cfg.whisper_model = im.InputText(ctx, "Model (.bin)", cfg.whisper_model)
  im.SameLine(ctx)
  if im.Button(ctx, "Browse##model") then
    local ok, path = r.GetUserFileNameForRead(cfg.whisper_model, "Locate ggml model", "bin")
    if ok then cfg.whisper_model = path end
  end

  changed, cfg.whisper_threads  = im.InputInt(ctx, "Threads", cfg.whisper_threads)
  changed, cfg.whisper_language = im.InputText(ctx, "Language", cfg.whisper_language)

  local preset = vo.DTWPresetForModel(cfg.whisper_model)
  if preset then
    im.TextDisabled(ctx, "DTW preset: " .. preset .. " (sharper word boundaries)")
  else
    im.TextDisabled(ctx, "DTW preset: none for this model — timestamps will be coarser")
  end

  im.Spacing(ctx)
  local ready, message = vo.IsBackendReady(cfg)
  if ready then
    im.TextColored(ctx, 0x66DD66FF, "Backend ready")
  else
    im.TextColored(ctx, 0xDD6666FF, message)
  end

  im.Spacing(ctx)
  if im.Button(ctx, "Open model downloads in browser") then
    OpenURL(MODEL_URL)
    status = "Opened the model download page in your browser."
  end
  im.TextDisabled(ctx, "Network: opens huggingface.co in your browser so you can\n" ..
                       "download a model manually. No dialogue text or audio ever\n" ..
                       "leaves this machine, and matching contains no network code.")
end

local function DrawMatching()
  local changed
  changed, cfg.accept_threshold = im.InputDouble(ctx, "Accept threshold", cfg.accept_threshold, 0.01, 0.05, "%.2f")
  changed, cfg.review_floor     = im.InputDouble(ctx, "Review floor",     cfg.review_floor,     0.01, 0.05, "%.2f")
  changed, cfg.margin_threshold = im.InputDouble(ctx, "Margin threshold", cfg.margin_threshold, 0.01, 0.05, "%.2f")
  changed, cfg.anchor_count     = im.InputInt(ctx,    "Anchor tokens",    cfg.anchor_count)
  im.Spacing(ctx)
  changed, cfg.pre_pad  = im.InputDouble(ctx, "Pre-roll (s)",  cfg.pre_pad,  0.01, 0.05, "%.3f")
  changed, cfg.post_pad = im.InputDouble(ctx, "Post-roll (s)", cfg.post_pad, 0.01, 0.05, "%.3f")

  im.Spacing(ctx)
  im.TextDisabled(ctx, "Score is textual agreement with the script — never a\n" ..
                       "judgement of the performance. Margin is the lead over the\n" ..
                       "next-best script line, which catches near-duplicate lines.")
end

local function DrawOutput()
  local changed
  changed, cfg.track_selects = im.InputText(ctx, "Selects track", cfg.track_selects)
  changed, cfg.track_alts    = im.InputText(ctx, "Alts track",    cfg.track_alts)
  changed, cfg.track_review  = im.InputText(ctx, "Review track",  cfg.track_review)
  im.Spacing(ctx)
  changed, cfg.review_prefix    = im.InputText(ctx, "Review prefix",    cfg.review_prefix)
  changed, cfg.unmatched_prefix = im.InputText(ctx, "Unmatched prefix", cfg.unmatched_prefix)
  im.Spacing(ctx)
  changed, cfg.create_regions = im.Checkbox(ctx, "Create regions over Selects clips", cfg.create_regions)
  im.TextDisabled(ctx, "For Region Render Matrix delivery. Off by default.")
end

local function DrawScript()
  local changed
  im.TextDisabled(ctx, "Column names as they appear in your script CSV header.")
  changed, cfg.column_mapping.line_id = im.InputText(ctx, "LineID column",     cfg.column_mapping.line_id)
  changed, cfg.column_mapping.text    = im.InputText(ctx, "Text column",       cfg.column_mapping.text)
  changed, cfg.column_mapping.asset   = im.InputText(ctx, "AudioAsset column", cfg.column_mapping.asset)
  changed, cfg.column_mapping.speaker = im.InputText(ctx, "Speaker column",    cfg.column_mapping.speaker)
  changed, cfg.column_mapping.type    = im.InputText(ctx, "Type column",       cfg.column_mapping.type)

  im.Spacing(ctx)
  im.SeparatorText(ctx, "Skip values")
  im.TextDisabled(ctx, "One per line. Rows whose AudioAsset matches are not yet\nrecorded and are excluded from matching.")
  changed, skip_text = im.InputTextMultiline(ctx, "##skip", skip_text, 380, 60)

  im.Spacing(ctx)
  im.SeparatorText(ctx, "Substitutions")
  im.TextDisabled(ctx, "One \"from = to\" per line, applied to both the script and the\n" ..
                       "transcript. Use this to fix any reading the matcher gets wrong,\n" ..
                       "e.g. \"1999 = nineteen ninety nine\" or \"hp = hit points\".")
  changed, subs_text = im.InputTextMultiline(ctx, "##subs", subs_text, 380, 100)
end

local function DrawAdvanced()
  local changed
  changed, cfg.scratch_dir = im.InputText(ctx, "Scratch dir", cfg.scratch_dir)
  im.TextDisabled(ctx, "Blank = a vo_scratch folder beside the project.")
  im.TextDisabled(ctx, "Resolved: " .. vo.ResolveScratchDir(cfg))
  im.Spacing(ctx)
  changed, cfg.timeout_s = im.InputInt(ctx, "Transcription timeout (s)", cfg.timeout_s)
  changed, cfg.force_retranscribe = im.Checkbox(ctx, "Always re-transcribe (ignore cache)", cfg.force_retranscribe)
  im.TextDisabled(ctx, "Transcripts are cached by source file, size and model, so\nre-running after a threshold change is instant.")
end

local function loop()
  if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
    ctx = im.CreateContext('VO Settings')
  end

  im.SetNextWindowSize(ctx, 520, 620, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'ajsfx VO Settings', true)

  if visible then
    if im.CollapsingHeader(ctx, 'Speech backend', nil, im.TreeNodeFlags_DefaultOpen) then
      DrawBackend()
    end
    if im.CollapsingHeader(ctx, 'Matching') then DrawMatching() end
    if im.CollapsingHeader(ctx, 'Output')   then DrawOutput()   end
    if im.CollapsingHeader(ctx, 'Script CSV') then DrawScript()  end
    if im.CollapsingHeader(ctx, 'Advanced') then DrawAdvanced() end

    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)

    if im.Button(ctx, "Save") then Apply() end
    im.SameLine(ctx)
    if im.Button(ctx, "Reload") then
      cfg       = vo.LoadConfig()
      subs_text = vo.FormatSubstitutionText(cfg.substitutions)
      skip_text = table.concat(cfg.skip_values, "\n")
      status    = "Reloaded from saved settings."
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Reset to defaults") then
      local fresh = {}
      for _, field in ipairs(vo.CONFIG_SCHEMA) do fresh[field.key] = field.default end
      fresh.column_mapping = {}
      for field, name in pairs(vo.DEFAULT_COLUMN_MAPPING) do fresh.column_mapping[field] = name end
      fresh.skip_values   = { table.unpack(vo.DEFAULT_SKIP_VALUES) }
      fresh.substitutions = {}
      cfg       = fresh
      subs_text = ""
      skip_text = table.concat(cfg.skip_values, "\n")
      status    = "Defaults restored — press Save to keep them."
    end

    if status ~= "" then
      im.Spacing(ctx)
      im.TextDisabled(ctx, status)
    end
  end

  -- Always End after Begin; skipping it corrupts ImGui's push/pop stack.
  im.End(ctx)

  if open then r.defer(loop) end
end

r.defer(loop)
