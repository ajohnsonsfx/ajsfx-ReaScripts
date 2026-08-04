-- @noindex
-- Provided by the ajsfx VO package; see ajsfx_VO_Overview.lua's @provides.
--
-- ajsfx VO Settings — the speech backend, the matching thresholds, the clip
-- boundaries, the destination tracks and the substitution table.
--
-- Script CSV column mapping and character filtering are not here: they belong
-- to a script, not to the user, so they live in ajsfx VO Overview and are saved
-- in the project file. See VO/SPEC.md for the design.
--
-- Not its own ReaPack package: it ships as one of the [main] actions of
-- ajsfx_VO_Overview.lua. Only one package may provide lib/ajsfx_vo.lua, and two
-- packages claiming it made reapack-index drop one of them silently.

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

local bin_choice    = 0       -- 0-based index into vo.BINARY_CATALOG (im.Combo)
local model_choice  = 0       -- 0-based index into vo.MODEL_CATALOG
local device_text   = "unknown — run Check"
local busy          = false   -- guards against concurrent downloads
local busy_kind     = nil     -- "bin" | "model" while a download runs (for the button label)
local busy_id       = nil     -- key/name being downloaded (label + install-state suppression)

-- ExtState section holding the resolved whisper-cli.exe path per binary build,
-- written on a successful install so "installed" can be detected cheaply
-- without walking the folder every frame.
local BSTATE = "ajsfx_vo_backend"

local function describe_device(d)
  if d.device == "CUDA" then return "CUDA — " .. (d.name or "NVIDIA GPU")
  elseif d.device == "CPU" then return "CPU only"
  else return "unknown (probe failed)" end
end

-- Resolved whisper-cli.exe for an installed binary build, or nil. Cheap: reads
-- the persisted path and confirms the file still exists (catches a deleted or
-- partially-removed install, which the Repair button then re-fetches).
local function binary_installed_path(key)
  local p = r.GetExtState(BSTATE, "exe_" .. key)
  if p ~= "" and vo.FileExists(p) then return p end
  return nil
end

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

-- Reveal a download folder in the OS file manager. Creates it first so the
-- open succeeds even before anything has been downloaded there.
local function OpenFolder(path)
  r.RecursiveCreateDirectory(path, 0)
  if r.CF_ShellExecute then
    r.CF_ShellExecute(path)
  elseif vo.IsWindows() then
    os.execute('start "" "' .. path:gsub("/", "\\") .. '"')
  else
    os.execute('open "' .. path .. '" 2>/dev/null || xdg-open "' .. path .. '"')
  end
end

local function Apply()
  cfg.substitutions = vo.ParseSubstitutionText(subs_text)
  -- Skip tokens live with the script's own layout, not here; this round-trip
  -- exists only so a config saved before that move is not silently emptied.
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
  im.SeparatorText(ctx, "Download backend & models")

  local res_root  = vo.PluginResourceRoot(script_path)
  local bin_dir   = vo.ResolveBinDir(res_root)
  local model_dir = vo.ResolveModelsDir(res_root)

  -- Each binary build extracts into its own subfolder so switching CUDA
  -- versions can't mix DLLs, and Repair can wipe just that build.
  local function start_bin_dl(b)
    local sub = bin_dir .. "/" .. b.key
    r.RecursiveCreateDirectory(sub, 0)
    local zip = sub .. "/" .. b.asset
    busy = true; busy_kind = "bin"; busy_id = b.key
    status = "Downloading " .. b.label .. "…"
    local function reset() busy = false; busy_kind = nil; busy_id = nil end
    vo.RunDownloadAsync(cfg, vo.BinaryDownloadURL(b.key), zip, b.expected_bytes,
      function()  -- on_done
        local ok, entries = vo.ExtractZip(zip, sub)
        os.remove(zip)
        if not ok then
          status = tostring(entries)  -- on failure, entries holds the error message
        else
          local exe = vo.LocateWhisperCliExe(entries)
          if exe then
            r.SetExtState(BSTATE, "exe_" .. b.key, exe, true)
            cfg.whisper_bin = exe; vo.SaveConfig(cfg)
            if select(1, vo.IsBackendReady(cfg)) then
              status = "Installed " .. b.label .. ". Checking device…"
              vo.ProbeBackendDevice(cfg, function(d) device_text = describe_device(d); status = "" end)
            else
              status = "Installed " .. b.label .. ". Set a model, then press Check device."
            end
          else
            status = "Downloaded, but whisper-cli.exe was not found in the archive."
          end
        end
        reset()
      end,
      function() status = "Download cancelled. Nothing was changed."; reset() end,
      function(msg) status = msg; reset() end)
  end

  local function start_model_dl(m)
    r.RecursiveCreateDirectory(model_dir, 0)
    local dest = model_dir .. "/" .. m.filename
    busy = true; busy_kind = "model"; busy_id = m.name
    status = "Downloading " .. m.label .. "…"
    local function reset() busy = false; busy_kind = nil; busy_id = nil end
    vo.RunDownloadAsync(cfg, vo.ModelDownloadURL(m.name), dest, m.expected_bytes,
      function() cfg.whisper_model = dest; vo.SaveConfig(cfg)
                 status = "Installed " .. m.name .. " model."; reset() end,
      function() status = "Download cancelled. Nothing was changed."; reset() end,
      function(msg) status = msg; reset() end)
  end

  -- A model reads as installed only when its file exists AND it is not the one
  -- currently downloading (curl creates the file up front, so existence alone
  -- would flip the button to "Use downloaded" mid-download).
  local function model_ready(name)
    if busy_kind == "model" and busy_id == name then return false end
    return vo.ModelIsInstalled(model_dir, name)
  end

  -- GPU binary (Windows only)
  if vo.IsWindows() then
    local bin_labels = {}
    for _, b in ipairs(vo.BINARY_CATALOG) do
      local mark = binary_installed_path(b.key) and "  [installed]" or ""
      bin_labels[#bin_labels + 1] = b.label .. mark
    end
    local _cb
    _cb, bin_choice = im.Combo(ctx, "GPU binary", bin_choice,
      table.concat(bin_labels, "\0") .. "\0\0")
    local b = vo.BINARY_CATALOG[bin_choice + 1]
    local b_inst = binary_installed_path(b.key)
    im.SameLine(ctx)
    -- Capture the disabled state BEFORE the buttons: a click flips `busy` true
    -- in this same frame, so re-reading it at EndDisabled would unbalance the
    -- ImGui stack ("EndDisabled too many times").
    local dis_bin = busy
    if dis_bin then im.BeginDisabled(ctx) end
    if busy and busy_kind == "bin" then
      im.Button(ctx, "Downloading…##bin")
    elseif b_inst then
      if im.Button(ctx, "Use downloaded##bin") then
        -- Just point at the install, like the model's Use downloaded. Device
        -- detection is the explicit Check device button, not a side effect of
        -- selection (probing runs whisper-cli and would pop a progress window).
        cfg.whisper_bin = b_inst; vo.SaveConfig(cfg)
        status = "Using " .. b.label .. ". Press Check device to confirm GPU."
      end
      im.SameLine(ctx)
      if im.Button(ctx, "Repair##bin") then start_bin_dl(b) end
    else
      if im.Button(ctx, "Get##bin") then start_bin_dl(b) end
    end
    if dis_bin then im.EndDisabled(ctx) end
  else
    im.TextDisabled(ctx, "GPU binary download is Windows-only. Use Browse above on this OS.")
  end

  -- Model
  local model_labels = {}
  for _, mm in ipairs(vo.MODEL_CATALOG) do
    local mark = model_ready(mm.name) and "  [installed]" or ""
    model_labels[#model_labels + 1] = mm.label .. mark
  end
  local _cm
  _cm, model_choice = im.Combo(ctx, "Model", model_choice,
    table.concat(model_labels, "\0") .. "\0\0")
  local m = vo.MODEL_CATALOG[model_choice + 1]
  local m_inst = model_ready(m.name)
  im.SameLine(ctx)
  local dis_model = busy
  if dis_model then im.BeginDisabled(ctx) end
  if busy and busy_kind == "model" then
    im.Button(ctx, "Downloading…##model")
  elseif m_inst then
    if im.Button(ctx, "Use downloaded##model") then
      cfg.whisper_model = model_dir .. "/" .. m.filename; vo.SaveConfig(cfg)
      status = "Selected " .. m.name .. "."
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Repair##model") then start_model_dl(m) end
  else
    if im.Button(ctx, "Get##model") then start_model_dl(m) end
  end
  if dis_model then im.EndDisabled(ctx) end

  -- Device readout
  im.Spacing(ctx)
  im.Text(ctx, "Device: " .. device_text)
  im.SameLine(ctx)
  local ready = select(1, vo.IsBackendReady(cfg))
  local dis_check = (not ready) or busy
  if dis_check then im.BeginDisabled(ctx) end
  if im.Button(ctx, "Check device") then
    status = "Probing device…"
    vo.ProbeBackendDevice(cfg, function(d) device_text = describe_device(d); status = "" end)
  end
  if dis_check then im.EndDisabled(ctx) end
  if not ready then
    im.TextDisabled(ctx, "Check needs both a whisper-cli binary and a model set.")
  end

  -- Reveal the download folders in the OS file manager for manual management.
  im.Spacing(ctx)
  if im.Button(ctx, "Open models folder") then
    OpenFolder(model_dir)
    status = "Opened the models folder."
  end
  if vo.IsWindows() then
    im.SameLine(ctx)
    if im.Button(ctx, "Open binary folder") then
      OpenFolder(bin_dir)
      status = "Opened the whisper-cli binary folder."
    end
  end

  -- Fallback: manual browser download (for missing curl, or non-Windows binary).
  im.Spacing(ctx)
  if im.Button(ctx, "Open downloads in browser") then
    OpenURL(MODEL_URL)
    status = "Opened the model download page in your browser."
  end

  im.Spacing(ctx)
  im.TextDisabled(ctx, "Downloads contact github.com (whisper-cli) and huggingface.co\n" ..
                       "(model weights) to fetch public files. No audio or dialogue text\n" ..
                       "is ever sent, and matching contains no network code.\n" ..
                       "The GPU build needs a recent NVIDIA driver; a fresh .exe may trip\n" ..
                       "SmartScreen once. Use Check device to confirm CUDA is active.")
end

local function DrawMatching()
  local changed
  changed, cfg.accept_threshold = im.InputDouble(ctx, "Accept threshold", cfg.accept_threshold, 0.01, 0.05, "%.2f")
  changed, cfg.review_floor     = im.InputDouble(ctx, "Review floor",     cfg.review_floor,     0.01, 0.05, "%.2f")
  changed, cfg.margin_threshold = im.InputDouble(ctx, "Margin threshold", cfg.margin_threshold, 0.01, 0.05, "%.2f")
  changed, cfg.anchor_count     = im.InputInt(ctx,    "Anchor tokens",    cfg.anchor_count)
  im.Spacing(ctx)
  im.TextDisabled(ctx, "Score is textual agreement with the script — never a\n" ..
                       "judgement of the performance. Margin is the lead over the\n" ..
                       "next-best script line, which catches near-duplicate lines.")

  im.Spacing(ctx)
  im.Separator(ctx)
  im.Text(ctx, "Read order")
  changed, cfg.backbone_min_tokens = im.InputInt(ctx, "Short line is under",
                                                 cfg.backbone_min_tokens)
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Lines with fewer words than this cannot identify themselves —\n" ..
                       "a line that is just \"You.\" matches every \"you\" in the read.\n" ..
                       "Only these are judged on where they fall.")
  end
  changed, cfg.order_weight = im.InputDouble(ctx, "Out-of-order penalty",
                                             cfg.order_weight, 0.01, 0.05, "%.2f")
  im.Spacing(ctx)
  im.TextDisabled(ctx, "A session is read roughly in script order, so a short line's\n" ..
                       "position says which of its many possible matches is the real\n" ..
                       "one. A short line that contradicts the order is sent to review,\n" ..
                       "never dropped and never silently named. Longer lines are left\n" ..
                       "alone: pickups and per-character passes are normal.")
end

local PAD_TOOLTIP =
  "With snapping on this is the furthest the edge may travel, not a fixed amount."

local function PadTooltip()
  if im.IsItemHovered(ctx) then im.SetTooltip(ctx, PAD_TOOLTIP) end
end

local function DrawBoundaries()
  local changed
  changed, cfg.snap_boundaries =
    im.Checkbox(ctx, "Snap clip edges to silence", cfg.snap_boundaries)

  im.Spacing(ctx)
  changed, cfg.pre_pad =
    im.DragDouble(ctx, "Maximum head room (s)", cfg.pre_pad, 0.01, 0.0, 2.0, "%.3f")
  PadTooltip()
  changed, cfg.post_pad =
    im.DragDouble(ctx, "Maximum tail (s)", cfg.post_pad, 0.01, 0.0, 2.0, "%.3f")
  PadTooltip()

  -- The three measurement controls mean nothing with snapping off: without a
  -- measured floor ApplyPadding takes the plain-padding path and never reads
  -- them. Greyed rather than hidden, so the user can see what snapping buys.
  im.Spacing(ctx)
  im.BeginDisabled(ctx, not cfg.snap_boundaries)
  changed, cfg.snap_min_silence =
    im.DragDouble(ctx, "Minimum silence (s)", cfg.snap_min_silence, 0.005, 0.01, 0.5, "%.3f")
  changed, cfg.snap_floor_offset =
    im.DragDouble(ctx, "Noise floor headroom (dB)", cfg.snap_floor_offset, 0.1, 0.0, 24.0, "%.1f")
  changed, cfg.snap_floor_window =
    im.DragDouble(ctx, "Floor measurement window (s)", cfg.snap_floor_window, 0.01, 0.1, 2.0, "%.3f")
  im.EndDisabled(ctx)

  im.Spacing(ctx)
  im.TextDisabled(ctx, "An edge only moves into audio quieter than the measured noise\n" ..
                       "floor plus the headroom, and never past the neighbouring word.\n" ..
                       "With snapping off, both pads apply as fixed amounts.")
end

local function DrawOutput()
  local changed
  -- The four tracks Pull routes to. Selects and Alts are delivered; Outs holds
  -- the takes kept but not shipped, and Review the lines nothing has decided.
  changed, cfg.track_selects = im.InputText(ctx, "Selects track", cfg.track_selects)
  changed, cfg.track_alts    = im.InputText(ctx, "Alts track",    cfg.track_alts)
  changed, cfg.track_outs    = im.InputText(ctx, "Outs track",    cfg.track_outs)
  changed, cfg.track_review  = im.InputText(ctx, "Review track",  cfg.track_review)
  im.Spacing(ctx)
  changed, cfg.review_prefix    = im.InputText(ctx, "Review prefix",    cfg.review_prefix)
  changed, cfg.unmatched_prefix = im.InputText(ctx, "Unmatched prefix", cfg.unmatched_prefix)
  im.TextDisabled(ctx, "Unmatched audio is left untouched on the source track, so the\n" ..
                       "unmatched prefix labels its rows in the report rather than\n" ..
                       "naming a clip.")
end

local function DrawScript()
  local changed
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
    if im.CollapsingHeader(ctx, 'Matching')   then DrawMatching()   end
    if im.CollapsingHeader(ctx, 'Boundaries') then DrawBoundaries() end
    if im.CollapsingHeader(ctx, 'Output')   then DrawOutput()   end
    if im.CollapsingHeader(ctx, 'Substitutions') then DrawScript()  end
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
