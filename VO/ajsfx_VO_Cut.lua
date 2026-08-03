-- @noindex
-- Provided by the ajsfx VO package; see ajsfx_VO_Overview.lua's @provides.
--
-- ajsfx VO Cut — cut, route and name the takes the user selected in Overview.
--
-- This script owns no data. It re-derives the match from the transcripts and
-- the project file, applies the user's selects, and mutates the project once
-- inside a single undo block. See VO/SPEC-cut.md.

local r = reaper

local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path
local core = require("lib.ajsfx_core")
local vo   = require("lib.ajsfx_vo")

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

-- Rebuilding walks every project item, every transcript and the whole match,
-- so it is throttled the same way ajsfx VO Overview throttles its rescan
-- (CLAUDE.md: use GetProjectStateChangeCount(0) for cache invalidation).
local RELOAD_THROTTLE = 1.5

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

local function ProjectPath()
  local _, path = r.EnumProjects(-1, "")
  return path or ""
end

-- -----------------------------------------------------------------------
-- State
-- -----------------------------------------------------------------------

local state = {
  header        = nil,
  rows          = nil,
  mapping       = {},
  header_error  = "",
  lines         = {},

  items         = {},          -- vo.CollectProjectSpans()
  matches       = {},          -- vo.BuildMatch result
  words_by_path = {},          -- source path -> transcript words (source time)
  stale_sources = {},          -- source paths whose audio changed since transcription

  entries       = {},          -- vo.ParseProjectFile entries
  pins          = {},          -- hand-placed spans; an input to BuildMatch
  project_path  = nil,
  script_csv    = "",
  overview      = {},          -- vo.BuildOverview result

  use_alts_track   = false,    -- session-only toggles; vo.CONFIG_SCHEMA deliberately
  suffix_alt_names = false,    -- excludes them (SPEC.md §4) — no primary_take any more

  gate_message = "",
  gate_blocked = true,

  summary      = {},           -- report lines from vo.FormatCutSummary + extras
  message      = "",
  message_kind = "ok",

  scanned_at  = -1,
  last_rescan = 0,
}

-- -----------------------------------------------------------------------
-- The script side (loaded once at launch, like ajsfx VO Overview)
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

local function LoadProjectFile()
  state.entries = {}
  state.script_csv, state.mapping, state.pins = "", {}, {}

  local proj = ProjectPath()
  state.project_path = (proj ~= "") and vo.ProjectFilePath(proj) or nil
  if not state.project_path then return end

  local text = ReadFile(state.project_path)
  if not text then return end   -- no project file yet is the normal first run

  local parsed, reason = vo.ParseProjectFile(text)
  if parsed then
    state.entries    = parsed.entries
    state.script_csv = parsed.script_csv
    state.mapping    = parsed.mapping
    -- Read here too, and not only in Overview: a pin is an INPUT to matching,
    -- so cutting without it would cut a different placement than the one the
    -- user pinned and is looking at.
    state.pins       = parsed.pins or {}
  else
    state.gate_message = "Cannot read " .. vo.Basename(state.project_path) ..
                          ": " .. tostring(reason)
  end
end

local function ApplyMappingDefaults()
  if state.mapping and next(state.mapping) then return end
  state.mapping = state.header and vo.AutoDetectMapping(state.header) or {}
end

local function ScriptLines()
  if not state.header or not state.rows or state.header_error ~= "" then return {} end
  local cols = vo.MapColumns(state.header, state.mapping)
  if not cols then return {} end
  return vo.BuildScriptLines(state.rows, cols)
end

-- -----------------------------------------------------------------------
-- The audio side
-- -----------------------------------------------------------------------

-- Every transcript for every source referenced by a project item, plus which
-- of them the audio has outgrown since it was transcribed.
local function CollectMatches(cfg)
  local paths = vo.ProjectSourcePaths(state.items)
  local transcripts, words_by_path, stale = {}, {}, {}

  for _, path in ipairs(paths) do
    local tstate, parsed = vo.TranscriptState(path)
    if tstate == "stale" then stale[#stale + 1] = path end
    if parsed then
      transcripts[#transcripts + 1] = { path = path, words = parsed.words }
      words_by_path[path] = parsed.words
    end
  end

  state.words_by_path = words_by_path
  state.stale_sources = stale
  return vo.BuildMatch(transcripts, state.lines or {}, cfg, state.pins)
end

-- Re-derive items/matches/overview and re-check the gate. Cheap enough for a
-- Refresh button; throttled against the per-frame path the same way Overview
-- throttles its own rescan.
local function Reload()
  state.items = vo.CollectProjectSpans()

  local cfg = vo.LoadConfig()
  state.matches = CollectMatches(cfg)

  state.overview = vo.BuildOverview({
    lines   = state.lines,
    matches = state.matches,
    entries = state.entries,
  })

  -- Gate: refuse to run, with the reason inline (see the Cut task brief).
  state.gate_message = ""

  if #state.stale_sources > 0 then
    local names = {}
    for _, p in ipairs(state.stale_sources) do names[#names + 1] = vo.Basename(p) end
    table.sort(names)
    state.gate_message = "Audio changed since it was transcribed — re-transcribe in " ..
      "ajsfx VO Sources before cutting:\n" .. table.concat(names, ", ")
  else
    local any_selected = false
    for _, row in ipairs(state.overview) do
      if row.user_select then any_selected = true; break end
    end

    if not any_selected then
      state.gate_message = "Nothing is selected. Tick Select in Overview on the takes you want cut."
    else
      -- Every asset with more than one take must have exactly the kind of
      -- decision Select exists to record; a group with none is unresolved.
      local by_asset = {}
      for _, row in ipairs(state.overview) do
        if row.status ~= "orphan" and row.status ~= "missing" and row.asset then
          local b = by_asset[row.asset]
          if not b then b = { count = 0, selected = false }; by_asset[row.asset] = b end
          b.count = b.count + 1
          if row.user_select then b.selected = true end
        end
      end

      local unresolved, names = 0, {}
      for asset, b in pairs(by_asset) do
        if b.count > 1 and not b.selected then
          unresolved = unresolved + 1
          names[#names + 1] = asset
        end
      end

      if unresolved > 0 then
        table.sort(names)
        state.gate_message = string.format("%d lines have several takes and no select yet.",
          unresolved) .. "\n" .. table.concat(names, ", ")
      end
    end
  end

  state.gate_blocked = state.gate_message ~= ""

  state.scanned_at  = r.GetProjectStateChangeCount(0)
  state.last_rescan = r.time_precise()
end

-- How long a gate verdict may stand without being re-checked against disk.
local GATE_RECHECK = 2.0

local function MaybeRescan()
  local age   = r.time_precise() - state.last_rescan
  local count = r.GetProjectStateChangeCount(0)

  -- The staleness gate reads FILES, and re-transcribing in Sources rewrites a
  -- transcript without touching anything REAPER counts. Watching the project
  -- state alone, a green gate would stay green for as long as the window sat
  -- open -- and Cut would apply the old word timings to re-recorded audio. So
  -- the clock forces the re-check the counter never will.
  if count == state.scanned_at and age < GATE_RECHECK then return end
  if state.scanned_at ~= -1 and age < RELOAD_THROTTLE then return end
  Reload()
end

local function CountSelected()
  local n = 0
  for _, row in ipairs(state.overview) do
    if row.user_select then n = n + 1 end
  end
  return n
end

-- -----------------------------------------------------------------------
-- The cut itself
-- -----------------------------------------------------------------------

-- One Selects/Alts/Review track normally. Only a genuine name collision splits
-- it, because a track per source when there is nothing to disambiguate is just
-- clutter.
local function DestTrackName(base, source_path, collided)
  if not collided then return base end
  return base .. " — " .. (source_path:match("([^\\/]+)$") or source_path)
end

local function DoCut()
  if state.gate_blocked then return end

  local cfg = vo.LoadConfig()
  cfg.use_alts_track   = state.use_alts_track
  cfg.suffix_alt_names = state.suffix_alt_names

  -- Every span from every source, tagged with the source path it came from.
  local all_spans = {}
  for _, m in ipairs(state.matches) do
    for _, s in ipairs(m.spans) do
      s.source_path = m.path
      all_spans[#all_spans + 1] = s
    end
  end

  -- The overview row is what carries the user's tick; the span is what gets
  -- cut. vo.AssignNames picks the primary from span.select, so the flag has
  -- to make the crossing here, once, before naming.
  for _, row in ipairs(state.overview) do
    if row.source_path and row.source_start ~= nil then
      for _, s in ipairs(all_spans) do
        if s.source_path == row.source_path
           and math.abs((s.start or 0) - row.source_start) < 1e-6
           and (row.source_stop == nil
                or math.abs((s.stop or 0) - (row.source_stop or 0)) < 1e-6) then
          s.select = row.user_select == true
          break
        end
      end
    end
  end

  -- Assets with a resolved primary, for the alts-track sibling pull below.
  local selected_assets = {}
  for _, row in ipairs(state.overview) do
    if row.user_select and row.asset then selected_assets[row.asset] = true end
  end

  -- The spans this run tries to cut: every take the user selected, every
  -- sibling take of a resolved line when Use alts track is on, and every
  -- review span (always flagged, never guessed — SPEC.md §4).
  local candidates = {}
  for _, s in ipairs(all_spans) do
    if s.kind == "match" then
      if s.select or (cfg.use_alts_track and s.asset and selected_assets[s.asset]) then
        candidates[#candidates + 1] = s
      end
    elseif s.kind == "review" then
      candidates[#candidates + 1] = s
    end
  end

  -- Name BEFORE converting anything. vo.AssignNames sorts each asset's takes by
  -- `start` to number them, and the conversion below only moves candidates into
  -- project time -- naming after it would sort a group holding both bases
  -- against each other and could hand _tk01 to the wrong take. Source time is
  -- the one base every span is guaranteed to share. Padding does not affect a
  -- name, so nothing is lost by doing this first.
  vo.AssignNames(all_spans, cfg)

  -- Convert: resolve each candidate against the live item that plays it and
  -- move it into project time. A span no current item covers any more (the
  -- item was trimmed since transcription) is dropped and counted rather than
  -- cut against silence — vo.ResolveSourceTime is what applies
  -- vo.SourceCoverageRanges to make that call.
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

  -- Snap: per take, pad outward from the recognized words, snapping to
  -- silence when configured and measurable.
  local pad_fallbacks = 0
  for _, g in pairs(by_item) do
    table.sort(g.spans, function(a, b) return (a.start or 0) < (b.start or 0) end)

    local take = r.GetActiveTake(g.item)
    local probe, destroy = vo.MakeTakeProbe(take)
    local ok, err = pcall(function()
      -- Only the words this ITEM covers. A source already split across several
      -- items -- the ordinary state of a re-cut session -- has words belonging
      -- to its siblings, and mapping those through this item's own
      -- pos/start_offs/playrate points the probe outside the take entirely. The
      -- accessor answers silence out there, which drags the measured floor down
      -- and quietly costs us the snapping this window exists to do.
      local covered = vo.SourceCoverageRanges({ g.info })[1]
      local words = {}
      for _, w in ipairs(state.words_by_path[g.info.path] or {}) do
        if w.t1 >= covered.from and w.t0 <= covered.to then words[#words + 1] = w end
      end

      -- Everything below works in PROJECT time, because that is what the probe
      -- and the spans speak. Convert the words once, here, rather than at each
      -- of the two places that consume them.
      local proj_words = {}
      for _, w in ipairs(words) do
        proj_words[#proj_words + 1] = {
          t0   = vo.SourceTimeToProject(w.t0, g.info),
          t1   = vo.SourceTimeToProject(w.t1, g.info),
          text = w.text,
        }
      end

      local floor = vo.MeasureNoiseFloor(vo.InterWordGaps(proj_words), probe, cfg)
      -- proj_words again, as the boundary bound: an edge may not travel into a
      -- word this cut did not select, not just one it did.
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

  -- Collide: a delivered name held by spans from more than one source path
  -- gets per-source destination tracks instead of overwriting one source's
  -- clip with another's.
  local name_sources = {}
  for _, g in pairs(by_item) do
    for _, s in ipairs(g.spans) do
      if s.kind == "match" and s.name then
        name_sources[s.name] = name_sources[s.name] or {}
        name_sources[s.name][s.source_path] = true
      end
    end
  end

  local collided, collisions = {}, {}
  for name, srcset in pairs(name_sources) do
    local paths = {}
    for p in pairs(srcset) do paths[#paths + 1] = p end
    if #paths > 1 then
      table.sort(paths)
      collided[name] = true
      collisions[#collisions + 1] = string.format(
        "%s selected from %d sources (%s) — split onto per-source tracks.",
        name, #paths, table.concat(paths, ", "))
    end
  end

  local base_names = {
    selects = cfg.track_selects or "Selects",
    alts    = cfg.track_alts    or "Alts",
    review  = cfg.track_review  or "Review",
  }

  -- Group the spans actually being applied by (source track, destination,
  -- per-source override). vo.ApplyPlan takes a single source_track, so every
  -- distinct track needs its own call; a collision splits a track further.
  local apply_groups, order = {}, {}
  for _, g in pairs(by_item) do
    for _, s in ipairs(g.spans) do
      local base     = base_names[s.dest] or base_names.review
      local override = DestTrackName(base, s.source_path, collided[s.name])
      local key       = tostring(g.info.track) .. "|" .. s.dest .. "|" .. override
      local grp = apply_groups[key]
      if not grp then
        grp = { track = g.info.track, dest = s.dest, override = override, spans = {} }
        apply_groups[key] = grp
        order[#order + 1] = key
      end
      grp.spans[#grp.spans + 1] = s
    end
  end

  -- Apply: one core.Transaction around every split/move/rename, so the whole
  -- run is one undo step (CLAUDE.md).
  local applied, failures = 0, {}
  core.Transaction("VO Cut", function()
    for _, key in ipairs(order) do
      local grp = apply_groups[key]
      local cfg_copy = vo.ShallowCopy(cfg)
      if grp.dest == "alts" then
        cfg_copy.track_alts = grp.override
      elseif grp.dest == "review" then
        cfg_copy.track_review = grp.override
      else
        cfg_copy.track_selects = grp.override
      end
      local a, f = vo.ApplyPlan(grp.spans, cfg_copy, grp.track)
      applied = applied + a
      for _, msg in ipairs(f) do failures[#failures + 1] = msg end
    end
  end)

  -- Report: vo.FormatCutSummary describes the whole match (how much of the
  -- script has audio at all); applied/failures describe what THIS run did.
  local summary = vo.FormatCutSummary(all_spans, applied, skipped_msgs, failures)
  for _, msg in ipairs(collisions) do
    summary[#summary + 1] = { text = msg, warn = true }
  end
  if pad_fallbacks > 0 then
    summary[#summary + 1] = {
      text = string.format(
        "%d clip edges fell back to the fixed pad — no silence found in the gap.",
        pad_fallbacks),
      warn = true,
    }
  end

  state.summary = summary
  state.message, state.message_kind =
    string.format("Cut applied: %d clip(s).", applied), "ok"
end

-- -----------------------------------------------------------------------
-- Drawing
-- -----------------------------------------------------------------------

local ctx = im.CreateContext('VO Cut')

local function Draw()
  im.SetNextWindowSize(ctx, 560, 420, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'ajsfx VO Cut', true)

  if visible then
    MaybeRescan()

    im.TextWrapped(ctx,
      "Cuts every take ticked Select in ajsfx VO Overview onto the Selects, " ..
      "Alts and Review tracks, snapping clip edges to silence where possible.")
    im.Spacing(ctx)

    local changed
    changed, state.use_alts_track = im.Checkbox(ctx, "Use alts track", state.use_alts_track)
    im.SameLine(ctx)
    changed, state.suffix_alt_names = im.Checkbox(ctx, "Suffix alt names", state.suffix_alt_names)

    im.Spacing(ctx)
    im.Separator(ctx)
    im.Spacing(ctx)

    -- Ahead of the gate, because this one is not about the takes: two script
    -- rows sharing a filename means whichever cuts second overwrites the first,
    -- and the delivered folder ends up quietly one line short.
    local dupes = vo.DuplicateAssets(state.lines or {})
    if #dupes > 0 then
      im.TextColored(ctx, 0xDD6666FF, string.format(
        "%d filename%s used by more than one script line — cutting would deliver " ..
        "one line over the other. Fix the script.",
        #dupes, #dupes == 1 and " is" or "s are"))
      for i, d in ipairs(dupes) do
        if i > 5 then
          im.TextDisabled(ctx, string.format("... and %d more", #dupes - 5))
          break
        end
        im.TextDisabled(ctx, string.format("    %s  (rows %s)",
          d.asset, table.concat(d.rows, ", ")))
      end
      im.Spacing(ctx)
    end

    if state.gate_blocked then
      im.TextColored(ctx, 0xDD6666FF, state.gate_message)
    else
      im.TextColored(ctx, 0x66BB66FF,
        string.format("%d take(s) selected and ready to cut.", CountSelected()))
    end

    im.Spacing(ctx)
    if state.gate_blocked then im.BeginDisabled(ctx, true) end
    if im.Button(ctx, "Cut", 120, 0) then
      local ok, err = pcall(DoCut)
      if not ok then
        state.message, state.message_kind = tostring(err), "error"
      end
      Reload()
    end
    if state.gate_blocked then im.EndDisabled(ctx) end

    im.SameLine(ctx)
    if im.Button(ctx, "Refresh") then Reload() end

    if state.message ~= "" then
      im.Spacing(ctx)
      im.TextColored(ctx, state.message_kind == "error" and 0xDD6666FF or 0x66BB66FF,
        state.message)
    end

    if #state.summary > 0 then
      im.Spacing(ctx)
      im.Separator(ctx)
      for _, line in ipairs(state.summary) do
        if line.warn then
          im.TextColored(ctx, 0xDDAA33FF, line.text)
        else
          im.Text(ctx, line.text)
        end
      end
    end
  end

  im.End(ctx)

  if open then r.defer(Draw) end
end

LoadProjectFile()
LoadCSV(state.script_csv)
ApplyMappingDefaults()
state.lines = ScriptLines()
Reload()
Draw()
