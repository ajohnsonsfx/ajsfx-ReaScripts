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

-- The paths the two combos were last synced FROM. Both combos used to open on
-- entry 1 no matter what was configured, so they named a build and a model the
-- run was not using -- and the Get / Use downloaded buttons beside them acted
-- on that wrong entry. Synced whenever the configured path changes (load,
-- Reload, Reset, a download, a Browse), and left alone in between so the user
-- can still scroll the combo to pick something to download.
local synced_bin, synced_model = nil, nil

local function SyncCatalogChoices()
  if cfg.whisper_model ~= synced_model then
    synced_model = cfg.whisper_model
    local i = vo.ModelCatalogIndex(cfg.whisper_model)
    if i then model_choice = i - 1 end
  end
  if cfg.whisper_bin ~= synced_bin then
    synced_bin = cfg.whisper_bin
    local i = vo.BinaryCatalogIndex(cfg.whisper_bin)
    if i then bin_choice = i - 1 end
  end
end
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
  -- Read back by the Overview's LoadScripts (handed to vo.BuildScriptLines
  -- as filters.skip_values); an empty list there means "use the default".
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
  SyncCatalogChoices()

  -- Which engine writes the transcript sidecars. Verify and the audit stay
  -- whisper either way: Qwen's LLM decoder auto-corrects flubs toward
  -- expected text, which is the one bias a verifier must not have.
  local ENGINES = { "whisper", "qwen" }
  local eng_idx = (cfg.transcribe_engine == "qwen") and 2 or 1
  local ehit
  ehit, eng_idx = im.Combo(ctx, "Transcription engine", eng_idx - 1,
                           "whisper (whisper.cpp)\0qwen (Qwen3-ASR + forced aligner)\0")
  if ehit then cfg.transcribe_engine = ENGINES[eng_idx + 1] end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx,
      "whisper: the whisper.cpp binary below; word stamps corrected by DTW\n" ..
      "anchors where the model has a preset.\n" ..
      "qwen: Qwen3-ASR-1.7B with its forced aligner, run from a local\n" ..
      "python venv -- true per-word start/end times, CPU or GPU. Verify\n" ..
      "and re-listen keep using whisper regardless.")
  end
  if cfg.transcribe_engine == "qwen" then
    local DEVICES = { "auto", "cuda", "cpu" }
    local d_idx = 1
    for i, d in ipairs(DEVICES) do
      if cfg.qwen_device == d then d_idx = i end
    end
    local dhit
    dhit, d_idx = im.Combo(ctx, "Qwen device", d_idx - 1,
                           "auto (try GPU, fall back)\0cuda\0cpu\0")
    if dhit then cfg.qwen_device = DEVICES[d_idx + 1] end
    local qready, qwhy = vo.QwenReady(cfg)
    if qready then
      im.TextColored(ctx, 0x66DD66FF, "Qwen venv ready")
    else
      im.TextColored(ctx, 0xDD6666FF, qwhy)
    end
    im.Spacing(ctx)
  end

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
  im.SameLine(ctx)
  -- "4" is a number with no story attached, and nothing in the panel said
  -- whether this machine wants more or fewer. Read the machine and say so.
  local cores = vo.CPUCoreCount()
  local want  = cores and vo.SuggestThreads(cores)
  if im.Button(ctx, "Detect##threads") then
    if want then
      cfg.whisper_threads = want
      status = string.format(
        "%d logical cores detected — using %d threads (whisper scales with " ..
        "physical cores, and leaves the rest for REAPER).", cores, want)
    else
      status = "Could not read the core count on this machine; leaving Threads alone."
    end
  end
  if want then
    im.SameLine(ctx)
    im.TextDisabled(ctx, string.format("(%d cores → %d)", cores, want))
  end

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
    local in_use_bin = vo.BinaryCatalogIndex(cfg.whisper_bin)
    local bin_labels = {}
    for i, b in ipairs(vo.BINARY_CATALOG) do
      local mark = (i == in_use_bin) and "  [in use]"
        or (binary_installed_path(b.key) and "  [installed]" or "")
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
  local in_use_model = vo.ModelCatalogIndex(cfg.whisper_model)
  local model_labels = {}
  for i, mm in ipairs(vo.MODEL_CATALOG) do
    local mark = (i == in_use_model) and "  [in use]"
      or (model_ready(mm.name) and "  [installed]" or "")
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

-- The keys this panel owns, in the order they are drawn. Used by the section's
-- own Reset, so a boundary experiment can be undone without throwing away the
-- backend paths and the substitution table too.
local BOUNDARY_KEYS = {
  "snap_boundaries", "snap_gate_auto", "snap_gate_db", "snap_min_silence",
  "snap_floor_offset", "snap_floor_window",
  "snap_head_room", "pre_pad", "trim_head_slack",
  "snap_tail_room", "post_pad", "trim_tail_slack",
}

-- One number, with its default one gesture away.
--
-- Double-click resets to the default; ImGui's DragDouble does not use the
-- double-click itself (ctrl+click is what opens the text field), so the gesture
-- is free. The default is also shown in the tooltip -- knowing what you drifted
-- FROM is most of what "reset" is for.
local function Drag(key, label, speed, lo, hi, fmt, extra)
  local changed, v = im.DragDouble(ctx, label, cfg[key], speed, lo, hi, fmt)
  if changed then cfg[key] = v end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, (extra and (extra .. "\n\n") or "") ..
      string.format("Default %s. Double-click to reset.",
                    string.format(fmt, vo.DEFAULTS[key])))
  end
  if im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, im.MouseButton_Left) then
    cfg[key] = vo.DEFAULTS[key]
    status = label .. " reset to its default."
  end
end

-- The gate preview: what Dynamic Split's "display gate threshold in media
-- items" shows, drawn here instead.
--
-- REAPER's own overlay is core code painting into the arrange item, which no
-- script can reach, so the waveform comes here to the setting rather than the
-- setting going to the waveform. Same information: the envelope of the selected
-- item, the gate as a horizontal line, and everything under the gate dimmed --
-- what is dim is what the tool will treat as silence.
--
-- Sampled once per selected item and cached. 480 RMS windows is a fifth of a
-- second of work; doing it per frame while a slider is being dragged would make
-- the drag stutter, and the picture does not change when the gate moves -- only
-- the line does, and that is redrawn free.
local PREVIEW_COLS   = 480
local PREVIEW_TOP_DB = -72.0  -- the top of the strip; below this is unreadable

local preview = { key = nil, cols = nil, note = "No item read yet." }
local preview_seen = nil   -- the window seen last frame, for the settle check

-- What the strip should be showing: the selected item, narrowed to the time
-- selection when there is one.
--
-- A whole recording is the wrong picture. 28 minutes across 480 columns is
-- three and a half seconds per column, which averages speech and room together
-- and shows neither -- and spot-checking a gate is exactly what a time
-- selection is for, the same way you would zoom in before trusting Dynamic
-- Split. Returns nil when there is nothing to draw.
local function PreviewWindow()
  local item = r.GetSelectedMediaItem(0, 0)
  if not item then return nil, "Select an item in REAPER (and, ideally, a time range)." end

  local pos = r.GetMediaItemInfo_Value(item, "D_POSITION")
  local len = r.GetMediaItemInfo_Value(item, "D_LENGTH")
  local from, to = pos, pos + len

  local ts0, ts1 = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local ranged = false
  if ts1 and ts0 and ts1 > ts0 then
    local lo, hi = math.max(from, ts0), math.min(to, ts1)
    if hi <= lo then
      return nil, "The time selection does not overlap the selected item."
    end
    from, to, ranged = lo, hi, true
  end
  if to <= from then return nil, "That item has no length." end
  return { item = item, from = from, to = to, ranged = ranged }
end

local function WindowKey(win)
  if not win then return nil end
  return string.format("%s|%.3f|%.3f", tostring(win.item), win.from, win.to)
end

local function BuildPreview()
  local win, why = PreviewWindow()
  if not win then
    preview = { key = nil, cols = nil, note = why }
    return
  end

  local take = r.GetActiveTake(win.item)
  local probe, destroy = vo.MakeTakeProbe(take)
  if not probe then
    if destroy then destroy() end
    preview = { key = nil, cols = nil,
                note = "That item has no audio this tool can read." }
    return
  end

  local len  = win.to - win.from
  local cols = {}
  local step = len / PREVIEW_COLS
  for i = 1, PREVIEW_COLS do
    local t0 = win.from + (i - 1) * step
    cols[i] = probe(t0, t0 + step) or -150.0
  end
  destroy()

  -- An ESTIMATE of what Auto would choose. The real run measures only the gaps
  -- BETWEEN transcribed words; there is no transcript here, so the quiet half
  -- of the strip stands in for those gaps. Said plainly in the readout rather
  -- than presented as the number the cut will use.
  local quiet = {}
  for _, db in ipairs(cols) do quiet[#quiet + 1] = db end
  table.sort(quiet)
  local est
  if #quiet > 0 then
    local half = math.max(1, math.floor(#quiet / 2))
    local at   = math.max(1, math.ceil((cfg.snap_floor_percentile or 0.25) * half))
    est = quiet[math.min(at, #quiet)] + (cfg.snap_floor_offset or 6.0)
  end

  preview = {
    key    = WindowKey(win),
    cols   = cols,
    len    = len,
    step   = step,
    ranged = win.ranged,
    est    = est,
    name   = select(2, r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)),
    note   = nil,
  }
end

-- Follow the item and time selection without redrawing mid-drag.
--
-- Rebuilding is 480 accessor reads, so doing it on every frame of a time-
-- selection drag would make the drag crawl. The window has to look the SAME for
-- two frames running before it is read -- a settled selection, not a moving
-- one. Spot-checking a gate then costs nothing but moving the range.
local function FollowSelection()
  local win = PreviewWindow()
  local key = WindowKey(win)
  if key and key == preview_seen and key ~= preview.key then BuildPreview() end
  preview_seen = key
end

-- The gate this panel is describing, and where it came from.
local function PreviewGate()
  if not cfg.snap_gate_auto then return cfg.snap_gate_db, "fixed" end
  if preview.est then return preview.est, "estimated" end
  return nil, "unmeasured"
end

local function DrawGateStrip()
  local gate, kind = PreviewGate()
  local avail = select(1, im.GetContentRegionAvail(ctx))
  local w, h = math.max(240, avail), 130
  local x0, y0 = im.GetCursorScreenPos(ctx)
  local dl = im.GetWindowDrawList(ctx)

  im.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, 0x14181CFF)
  im.DrawList_AddRect(dl, x0, y0, x0 + w, y0 + h, 0x3A4048FF)

  local mid = y0 + h / 2
  local function db_to_half(db)
    if not db then return 0 end
    local t = (db - PREVIEW_TOP_DB) / (0.0 - PREVIEW_TOP_DB)
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    return t * (h / 2 - 2)
  end

  if preview.cols and #preview.cols > 0 then
    local n = #preview.cols
    for i = 1, n do
      local db = preview.cols[i]
      local x  = x0 + (i - 0.5) * (w / n)
      local a  = db_to_half(db)
      -- Under the gate is dim: dim IS what the tool calls silence, so the
      -- picture answers "what will it cut" without any further reading.
      local col = (gate and db > gate) and 0x7FD4A0FF or 0x3C4A52FF
      im.DrawList_AddLine(dl, x, mid - a, x, mid + a, col, 1.0)
    end
  else
    im.DrawList_AddLine(dl, x0 + 6, mid, x0 + w - 6, mid, 0x3C4A52FF, 1.0)
  end

  if gate then
    local g = db_to_half(gate)
    for _, y in ipairs({ mid - g, mid + g }) do
      im.DrawList_AddLine(dl, x0, y, x0 + w, y, 0xFFA94DFF, 1.0)
    end
  end

  im.Dummy(ctx, w, h)
  if preview.note then
    im.TextDisabled(ctx, preview.note)
  else
    im.TextDisabled(ctx, string.format(
      "%s  —  %s, %.2fs%s.  Gate %s: %s",
      (preview.name ~= "" and preview.name) or "selected item",
      preview.ranged and "time selection" or "whole item",
      preview.len or 0,
      preview.step and string.format(" (%.0f ms per column)", preview.step * 1000) or "",
      (kind == "fixed") and "(typed in)"
        or (kind == "estimated" and "(Auto, estimated here)" or "(unavailable)"),
      gate and string.format("%.1f dB", gate) or "no reading"))
  end
  -- A column coarser than the minimum silence cannot show a pause at all: the
  -- window it averages is longer than the thing being looked for. Say so
  -- rather than let a smooth, useless picture read as a clean recording.
  if preview.step and preview.step > (cfg.snap_min_silence or 0.06) then
    im.TextDisabled(ctx, "Too coarse to judge — each column is longer than the minimum\n" ..
                         "silence, so pauses are averaged away. Make a time selection\n" ..
                         "over a line or two.")
  end
  if kind == "estimated" then
    im.TextDisabled(ctx, "Auto measures the real gate between the transcript's words at\n" ..
                         "run time, so the cut's number can differ a little from this.")
  end
end

local function DrawBoundaries()
  local changed
  changed, cfg.snap_boundaries =
    im.Checkbox(ctx, "Snap clip edges to silence", cfg.snap_boundaries)
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Off: head and tail below are applied as fixed amounts from the\n" ..
                       "transcript's word times, and nothing on this panel is measured.")
  end

  -- Three sections, because there are three things to decide: where the words
  -- are, how much room to keep in front, and how much behind. Everything that
  -- QUALIFIES one of those -- a travel ceiling, an Auto-adjust tolerance --
  -- now sits under the number it qualifies instead of in a section of its own.
  -- Head room, maximum head room and head slack were three controls in three
  -- places, and nothing said they were the same edge.

  ---------------------------------------------------------------- 1. silence
  im.Spacing(ctx)
  im.SeparatorText(ctx, "1. Silence detection")
  im.BeginDisabled(ctx, not cfg.snap_boundaries)

  changed, cfg.snap_gate_auto =
    im.Checkbox(ctx, "Measure the gate from the room (Auto)", cfg.snap_gate_auto)
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "On: the room tone in this recording's own pauses sets the gate,\n" ..
                       "plus the headroom below. Right by default on any recording --\n" ..
                       "a fixed number is too low for a noisy room and too high for a\n" ..
                       "clean one.\n\nOff: you type the threshold in, like Dynamic Split.")
  end

  if cfg.snap_gate_auto then
    Drag("snap_floor_offset", "Gate above the room (dB)", 0.1, 0.0, 24.0, "%.1f",
         "How far above the measured room tone the gate sits. Louder than\n" ..
         "this is speech; quieter is silence.")
  else
    Drag("snap_gate_db", "Threshold (dB)", 0.2, -90.0, 0.0, "%.1f",
         "The gate, in dBFS -- the same number Dynamic Split calls Threshold.\n" ..
         "Louder than this is speech; quieter is silence.")
  end
  Drag("snap_min_silence", "Minimum silence (s)", 0.005, 0.01, 0.5, "%.3f",
       "A quiet patch shorter than this is not a silence -- it is the gap\n" ..
       "inside a word. The same idea as Dynamic Split's minimum silence.")

  im.Spacing(ctx)
  FollowSelection()
  DrawGateStrip()
  if im.Button(ctx, "Refresh") then
    BuildPreview()
    status = preview.note or "Read the selection."
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "The strip follows the selected item and the TIME SELECTION, and\n" ..
                       "redraws once the range settles -- so you spot-check a gate by\n" ..
                       "dragging a range over a line or two, the way you would zoom in\n" ..
                       "before trusting Dynamic Split. No time selection means the whole\n" ..
                       "item, which on a 28-minute recording shows nothing useful.\n\n" ..
                       "REAPER's own overlay is core code painting into the arrange\n" ..
                       "item, which a script cannot reach -- so the waveform comes to\n" ..
                       "the setting instead.")
  end
  im.SameLine(ctx)
  if im.Button(ctx, "Clear##preview") then
    preview = { key = nil, cols = nil, note = "No item read yet." }
    preview_seen = nil
  end

  if im.TreeNode(ctx, "How the room is measured##floor") then
    Drag("snap_floor_window", "Measurement window (s)", 0.01, 0.1, 2.0, "%.3f",
         "How much of each pause is sampled when Auto measures the room.")
    im.TreePop(ctx)
  end
  im.EndDisabled(ctx)

  ------------------------------------------------------------------- 2. head
  im.Spacing(ctx)
  im.SeparatorText(ctx, "2. Head")
  Drag("snap_head_room", "Room before the line (s)", 0.005, 0.0, 2.0, "%.3f",
       "Measured from where the SOUND starts -- the first moment above the\n" ..
       "gate, not the transcript's word time. This is the number that places\n" ..
       "a take marker's left edge.")
  if im.TreeNode(ctx, "Limits##head") then
    Drag("pre_pad", "Never travel more than (s)", 0.01, 0.0, 2.0, "%.3f",
         "A hard ceiling on how far the left edge may move from the\n" ..
         "transcript's own start, and the FIXED pad when snapping is off.\n" ..
         "Raised automatically if you set the room above it.")
    Drag("trim_head_slack", "Auto-adjust slack (s)", 0.01, 0.0, 2.0, "%.3f",
         "Auto-adjust pulls an edge in only once it sits further out than\n" ..
         "the room above PLUS this. Stops it fussing over near-misses.")
    im.TreePop(ctx)
  end

  ------------------------------------------------------------------- 3. tail
  im.Spacing(ctx)
  im.SeparatorText(ctx, "3. Tail")
  Drag("snap_tail_room", "Room after the line (s)", 0.005, 0.0, 2.0, "%.3f",
       "Measured from where the SOUND stops -- the last moment above the\n" ..
       "gate, which is past the last word's timestamp whenever the read\n" ..
       "trails off into something whisper did not transcribe.")
  if im.TreeNode(ctx, "Limits##tail") then
    Drag("post_pad", "Never travel more than (s)", 0.01, 0.0, 2.0, "%.3f",
         "A hard ceiling on how far the right edge may move, and the FIXED\n" ..
         "pad when snapping is off.")
    Drag("trim_tail_slack", "Auto-adjust slack (s)", 0.01, 0.0, 2.0, "%.3f",
         "The same tolerance at the other end.")
    im.TreePop(ctx)
  end

  -- A ceiling below its room silently caps it, which is the trap this panel
  -- used to be. Raise rather than warn: the ceiling is a guard rail, not a
  -- choice anyone came here to make.
  if cfg.pre_pad  < cfg.snap_head_room then cfg.pre_pad  = cfg.snap_head_room end
  if cfg.post_pad < cfg.snap_tail_room then cfg.post_pad = cfg.snap_tail_room end

  im.Spacing(ctx)
  if im.Button(ctx, "Reset boundaries to defaults") then
    for _, k in ipairs(BOUNDARY_KEYS) do cfg[k] = vo.DEFAULTS[k] end
    status = "Boundary settings restored — press Save to keep them."
  end

  im.Spacing(ctx)
  im.TextDisabled(ctx, "Head and tail are measured from the SOUND, found by the gate --\n" ..
                       "never from the word timestamps, which absorb the pause around\n" ..
                       "each take. No edge may pass the neighbouring word, so no amount\n" ..
                       "of room can reach another line.\n\n" ..
                       "After saving, press \"Identify lines in audio and update\n" ..
                       "markers\" in the Overview's Setup tab to move the markers a\n" ..
                       "session already has. They keep their id, so Sel, Keep and\n" ..
                       "notes stay put -- only the edges move.")
end

local function DrawOutput()
  local changed
  -- The three tracks Pull routes to. Selects and Alts are delivered; Review
  -- holds everything untouched -- undecided, unwanted, or not listened to yet.
  changed, cfg.track_selects = im.InputText(ctx, "Selects track", cfg.track_selects)
  changed, cfg.track_alts    = im.InputText(ctx, "Alts track",    cfg.track_alts)
  changed, cfg.track_review  = im.InputText(ctx, "Review track",  cfg.track_review)
  changed, cfg.track_outs    = im.InputText(ctx, "Outs track",    cfg.track_outs)
  im.TextDisabled(ctx, "Outs is where rejected takes are parked BY HAND. Pull\n" ..
                       "leaves them there, the sheet keeps their transcript,\n" ..
                       "and their marks read as an explicit no.")
  im.Spacing(ctx)
  changed, cfg.review_prefix    = im.InputText(ctx, "Review prefix",    cfg.review_prefix)
  changed, cfg.unmatched_prefix = im.InputText(ctx, "Unmatched prefix", cfg.unmatched_prefix)
  im.TextDisabled(ctx, "Unmatched audio is left untouched on the source track, so the\n" ..
                       "unmatched prefix labels its rows in the report rather than\n" ..
                       "naming a clip.")
end

local function DrawScript()
  -- The substitution box moved to the Overview, into the project.
  --
  -- It was here and it was GLOBAL, so a table built for one reader followed you
  -- into every other project you opened -- and the words a transcriber mishears
  -- are a fact about one reader on one day. It also sat two windows away from
  -- the sheet, which is the only place a mishearing is ever noticed.
  --
  -- This panel is left in place, saying where it went, rather than removed: a
  -- section that vanishes reads as a feature that vanished.
  im.TextWrapped(ctx,
    "Word substitutions have moved into the project, and are edited in the " ..
    "VO Overview -- Main -> Match -> Word substitutions.")
  im.Spacing(ctx)
  im.TextDisabled(ctx,
    "They were global, so one reader's misheard words followed you into\n" ..
    "every other project. They now travel with the project that needs them,\n" ..
    "beside the sheet where you notice one.\n\n" ..
    "Substitutions already entered here were copied into this project the\n" ..
    "first time it was opened; nothing was lost.")

  im.Spacing(ctx)
  im.Separator(ctx)
  im.Spacing(ctx)
  im.Text(ctx, "Skip values")
  local changed, text = im.InputTextMultiline(ctx, "##skip_values", skip_text,
                                              420, 80)
  if changed then skip_text = text end
  im.TextDisabled(ctx,
    "One per line. A script row whose asset cell reads one of these is not\n" ..
    "a line to record. Blank falls back to the default: TO RECORD.\n" ..
    "Applies when the Overview next reloads its scripts.")
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

  im.Spacing(ctx)
  changed, cfg.recut_ignore_rate =
    im.Checkbox(ctx, "Ignore item pitch/playrate when re-cutting", cfg.recut_ignore_rate)
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "\"Re-cut selected takes\" normally refuses a clump whose clips\n" ..
                       "have different playrates or pitch: healing them into one clip\n" ..
                       "would change how the audio sounds.\n\n" ..
                       "On: it proceeds anyway. The surviving clip takes the LONGEST\n" ..
                       "item's rate and pitch, and a REVIEW note marker records what\n" ..
                       "was dropped -- the override is never silent.")
  end
end

-- The inbox rail's keys (the Overview's "Needs you" walk). Stored as key
-- NAMES: one letter or digit, or Enter / Space. A blank disables that
-- binding; two bindings on one key means one silently never fires, so
-- clashes are shown right here rather than discovered by pressing.
local KEY_BINDINGS = {
  { key = "key_inbox_next",  label = "Next finding" },
  { key = "key_inbox_prev",  label = "Previous finding" },
  { key = "key_inbox_jump",  label = "Jump to it" },
  { key = "key_inbox_verb1", label = "First verb" },
  { key = "key_inbox_verb2", label = "Second verb" },
}

local function DrawKeyboard()
  im.TextDisabled(ctx, "The Overview's inbox rail: walk the findings and press their\n" ..
                       "verbs without the mouse. One letter or digit, or Enter or\n" ..
                       "Space. Blank disables a binding.")
  im.Spacing(ctx)
  for _, b in ipairs(KEY_BINDINGS) do
    im.SetNextItemWidth(ctx, 120)
    local changed, v = im.InputText(ctx, b.label, cfg[b.key] or "")
    if changed then cfg[b.key] = v end
  end
  local clashes = vo.KeyBindingClashes(cfg)
  if #clashes > 0 then
    local names = {}
    for _, lbl in ipairs(KEY_BINDINGS) do names[lbl.key] = lbl.label end
    for _, c in ipairs(clashes) do
      im.TextColored(ctx, 0xDDAA33FF, string.format(
        '"%s" and "%s" share a key -- the second never fires.',
        names[c[1]] or c[1], names[c[2]] or c[2]))
    end
  end
  im.Spacing(ctx)
  if im.Button(ctx, "Reset keys to defaults") then
    for _, field in ipairs(vo.CONFIG_SCHEMA) do
      if field.key:find("^key_inbox_") then cfg[field.key] = field.default end
    end
  end
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
    if im.CollapsingHeader(ctx, 'Keyboard') then DrawKeyboard() end
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
