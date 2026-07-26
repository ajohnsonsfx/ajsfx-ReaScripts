-- @description ajsfx VO ScriptMatch
-- @author ajsfx
-- @version 0.8
-- @changelog Transcribe and cut are now two buttons at the bottom right: Transcribe reads the audio and builds the plan without touching the project, and Cut applies it. Once a plan exists the button becomes Re-transcribe and bypasses the transcript cache. The preview table gains a Status column showing matched / review / no match per line once a transcription has run. Changing the CSV, mapping, filters or skip tokens discards a plan built before the change. Layout presets no longer load the moment you pick one from the droplist: choosing a preset only selects it, Load applies it, and Save writes the current layout back over the selected preset after a confirmation. Editing a mapping keeps the preset name so it can be updated without retyping it
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
  layout_name      = "",         -- preset the current layout came from ("" = inline)
  layout_dirty     = false,      -- mapping edited away from the named preset
  layout_sel       = "",         -- name highlighted in the preset droplist, not
                                 -- necessarily loaded: Load/Save/Delete act on it
  character        = nil,        -- folded character key to keep, nil = all (R3)
  distinct         = nil,        -- vo.DistinctCharacters for the mapped speaker column
  preview          = nil,        -- cached BuildScriptLines result (R4)
  preview_dirty    = true,       -- recompute the preview on the next frame
  plan             = nil,        -- transcribed plan awaiting Cut, nil = none
  plan_saved       = false,      -- true when state.plan is backed by sidecars on
                                 -- disk (loaded from / successfully written to
                                 -- disk); false when it is live from a
                                 -- transcription that has not been durably
                                 -- persisted yet
  plan_lines       = nil,        -- the script lines that plan was built from
  line_status      = nil,        -- asset -> STATUS key, from the current plan
  status           = "",         -- neutral progress note, distinct from message
  sidecar_warning  = "",         -- non-empty when a sidecar write failed (warning only)
  stale_sources    = {},         -- FULL PATHS whose audio changed since transcription
                                 -- (paths, not base names: two selected sources
                                 -- can share a filename in different folders,
                                 -- and one must never mark the other stale --
                                 -- basenames are derived only for display)
  script_mismatch  = "",         -- sidecar's script CSV path when it differs
  mismatch_sources = {},         -- {source_path, csv_path} for every mismatching
                                 -- sidecar, so a partial re-transcription can
                                 -- clear only the entries it re-ran
  orphan_count     = 0,          -- spans naming a Filename absent from the script
  dropped_count    = 0,          -- spans falling outside the current items
  dropped_by_source = {},        -- source path -> how many of dropped_count it
                                 -- contributed, same partial-clear reason
  use_alts_track   = cfg.use_alts_track or false,
  suffix_alt_names = cfg.suffix_alt_names or false,
  primary_last     = true,
  message          = "",
  running          = false,
  source_key       = nil,
  selection_key    = nil,
}

-- Session options feed BuildPlan, AssignNames and ApplyPlan, so they are pushed
-- into cfg at each step rather than once: a checkbox toggled between Transcribe
-- and Cut still takes effect on the cut.
-- Defined up here, immediately after `state`, because LoadSidecars needs it too
-- (it re-derives naming over the loaded union) and Lua resolves these flat
-- locals by definition order.
local function ApplyCfg()
  cfg.use_alts_track   = state.use_alts_track
  cfg.suffix_alt_names = state.suffix_alt_names
  cfg.primary_take     = state.primary_last and "last" or "first"
end

-- The selection is read every frame, not frozen at launch: the dialog follows
-- whatever the user clicks. The expensive part -- CollectSourceSpans, which
-- resolves each item's take and source file -- only runs when a cheap probe
-- (item count + pointers) says the selection itself changed; dragging an item
-- or picking a second item from an already-collected source costs nothing.
local items, skipped, usable = {}, {}, {}

-- Write one sidecar per source file the plan touches. Called after transcription
-- (so a session that is never cut still persists) and again after a cut, since
-- ApplyPlan can clamp spans and the file should reflect what was applied.
-- Returns how many were written, and a list of {path, reason} for those that
-- were not: a read-only media folder is a warning, never a failed run.
local function WriteSidecars(plan, lines)
  local by_source = vo.PartitionPlanBySource(plan, usable)
  local written, failures = 0, {}
  for source_path, spans in pairs(by_source) do
    local path = vo.SidecarPath(source_path)
    if not path then
      failures[#failures + 1] = { path = source_path, reason = "no sidecar path" }
    else
      local text = vo.SerializeSidecar(spans, lines, {
        source       = source_path:match("([^/\\]+)$") or source_path,
        source_bytes = vo.FileSize(source_path) or 0,
        script_csv   = state.csv_path or "",
        mapping      = state.mapping,
      })
      if WriteFile(path, text) then
        written = written + 1
      else
        failures[#failures + 1] = { path = path, reason = "could not write" }
      end
    end
  end
  return written, failures
end

-- A key over the SET of distinct source FILES behind a list of items -- which
-- is what src_changed is supposed to mean everywhere it is used. Duplicates are
-- collapsed and the result is sorted, so the key depends only on WHICH files are
-- involved, never on how many items reference them or in what order they were
-- clicked. Without the de-duplication, shift-clicking a second item on a source
-- that is already selected read as a source-set change and forced an
-- unconditional sidecar reload -- destroying a live, unsaved plan in exactly the
-- case state.plan_saved exists to protect.
local function SourceKey(list)
  local seen, paths = {}, {}
  for _, it in ipairs(list) do
    if it.path and not seen[it.path] then
      seen[it.path] = true
      paths[#paths + 1] = it.path
    end
  end
  table.sort(paths)
  return table.concat(paths, "\31")
end

-- Cheap enough to run every frame: item pointers only, no take or source
-- lookups. A count alone is not enough -- swapping one item for another
-- leaves the count unchanged -- so the pointers themselves are the key.
local function SelectionKey()
  local n, parts = r.CountSelectedMediaItems(0), {}
  for i = 0, n - 1 do parts[#parts + 1] = tostring(r.GetSelectedMediaItem(0, i)) end
  return table.concat(parts, "\31")
end

-- Returns two values: (selection_changed, source_changed). selection_changed
-- is true whenever the set of SELECTED ITEMS changed this frame (a shift-click
-- swapping one item on a source for another counts, even if no source file
-- was added or dropped). source_changed is true only when the underlying set
-- of SOURCE FILES also changed. The two are deliberately not the same thing:
-- a same-source reselect (e.g. picking a different span on the same take)
-- must still reload sidecars for the newly usable items -- that is what
-- "load sidecars on selection change" means -- but it must not blow away a
-- plan the user just transcribed the way an actual source-set change should.
local function RefreshSelection()
  local sel_key = SelectionKey()
  if sel_key == state.selection_key then return false, false end
  state.selection_key = sel_key

  -- The selection itself changed (a cheap fact); only now is it worth paying
  -- for CollectSourceSpans to find out whether the source SET also changed.
  local fresh = vo.CollectSourceSpans()
  local key   = SourceKey(fresh)

  items = fresh
  skipped, usable = {}, {}
  for _, item in ipairs(items) do
    if item.skip then
      skipped[#skipped + 1] = string.format("item at %.3fs: %s", item.pos, item.skip)
    else
      usable[#usable + 1] = item
    end
  end

  local source_changed = key ~= state.source_key
  state.source_key = key
  return true, source_changed
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

-- What a line's spans in the plan add up to. A line can produce several spans
-- (one per take), so the best outcome wins: any confident match makes the line
-- matched, otherwise a partial or low-confidence span makes it review.
local STATUS = {
  match     = { rank = 3, label = "matched",  colour = 0x66BB66FF },
  review    = { rank = 2, label = "review",   colour = 0xDDAA33FF },
  unmatched = { rank = 1, label = "no match", colour = 0x999999FF },
}

-- Fold a plan's spans to one status per script line. A line can produce several
-- spans (one per take), so the best outcome wins. Also returns how many spans
-- name a Filename that is not in the current script — an orphan, which the
-- table cannot show because the table is driven by script lines.
local function FoldStatuses(plan, lines)
  local in_script = {}
  for _, line in ipairs(lines or {}) do
    if line.asset then in_script[line.asset] = true end
  end

  local by_asset, orphans = {}, 0
  for _, span in ipairs(plan or {}) do
    local s = STATUS[span.kind]
    if span.asset and s then
      if not in_script[span.asset] then
        orphans = orphans + 1
      else
        local cur = STATUS[by_asset[span.asset]]
        if not cur or s.rank > cur.rank then by_asset[span.asset] = span.kind end
      end
    end
  end

  -- A line the plan never mentions produced no audio at all.
  for _, line in ipairs(lines or {}) do
    if line.asset and not by_asset[line.asset] then by_asset[line.asset] = "unmatched" end
  end

  return by_asset, orphans
end

-- Load every sidecar for the currently selected sources into ONE plan. N files
-- in, one plan out: the Status column folds several spans per line by rank, so
-- a line matched in one recording and absent from another still reads matched.
--
-- update_status (default true) controls whether a successful load overwrites
-- state.status. A same-source reselect passes false so a lingering message
-- describing the current source set (e.g. "Cut applied.") survives finding
-- exactly the sidecars it already knew about -- see the call site in loop().
local function LoadSidecars(update_status)
  if update_status == nil then update_status = true end
  local plan       = {}
  local stale      = {}
  local mismatches = {}
  local dropped    = 0
  -- Per-source breakdowns, kept alongside the totals so a later PARTIAL
  -- transcription can clear only the warnings belonging to the sources it
  -- actually re-ran. The totals on their own cannot be narrowed, and clearing
  -- them wholesale would hide a skipped source's mismatch/drop (see the merge
  -- in Run's callback).
  local dropped_by_source = {}

  -- Distinct sources, each with the items that currently reference it.
  local by_source = {}
  for _, item in ipairs(usable) do
    if item.path then
      by_source[item.path] = by_source[item.path] or {}
      table.insert(by_source[item.path], item)
    end
  end

  -- Sorted so a source-file name is deterministic across runs on identical
  -- input; pairs() order is not, and it must not decide which mismatching
  -- sidecar gets named when several selected sources disagree with the CSV.
  local source_paths = {}
  for source_path in pairs(by_source) do source_paths[#source_paths + 1] = source_path end
  table.sort(source_paths)

  for _, source_path in ipairs(source_paths) do
    local its  = by_source[source_path]
    local path = vo.SidecarPath(source_path)
    if path and vo.FileExists(path) then
      local parsed = vo.ParseSidecar(ReadFile(path))
      if parsed then
        -- The audio-changed check is file-level: if the recording differs, every
        -- span's timing in this file is suspect at once, so Cut is blocked
        -- rather than a per-line status being invented.
        if parsed.source_bytes ~= (vo.FileSize(source_path) or 0) then
          stale[#stale + 1] = source_path
        end
        if parsed.script_csv ~= "" and state.csv_path ~= ""
           and parsed.script_csv ~= state.csv_path then
          mismatches[#mismatches + 1] = { source_path, parsed.script_csv }
        end

        for _, span in ipairs(parsed.spans) do
          -- Place the span against whichever item currently plays that region.
          -- An item trimmed since transcription leaves spans with no audio
          -- behind them; those are dropped and counted, never clamped.
          local placed = false
          for _, item in ipairs(its) do
            local src_end = (item.start_offs or 0) + (item.length or 0) * (item.playrate or 1.0)
            local mid = (span.start + span.stop) / 2
            if mid >= (item.start_offs or 0) and mid <= src_end then
              local copy = {}
              for k, v in pairs(span) do copy[k] = v end
              copy.start = vo.SourceTimeToProject(span.start, item)
              copy.stop  = vo.SourceTimeToProject(span.stop,  item)
              plan[#plan + 1] = copy
              placed = true
              break
            end
          end
          if not placed then
            dropped = dropped + 1
            dropped_by_source[source_path] = (dropped_by_source[source_path] or 0) + 1
          end
        end
      end
    end
  end

  -- Deterministic even with several mismatching sources: source_paths above is
  -- sorted, so the first entry appended to mismatches is always the same one
  -- for identical input, never whichever pairs() happened to visit last.
  state.stale_sources     = stale
  state.mismatch_sources  = mismatches
  state.dropped_by_source = dropped_by_source
  state.script_mismatch   = mismatches[1] and mismatches[1][2] or ""
  state.dropped_count     = dropped

  if #plan == 0 then
    state.plan, state.plan_lines, state.line_status = nil, nil, nil
    state.orphan_count = 0
    -- Nothing loaded from disk, so there is nothing disk-backed to claim.
    state.plan_saved = false
    return
  end

  table.sort(plan, function(a, b) return (a.start or 0) < (b.start or 0) end)

  -- Same collision as the transcribe/retain merge: each sidecar was written by a
  -- run that had numbered its spans against that source ALONE, so two sources
  -- both holding a read of L001 load as two take-1 primaries named "L001", and
  -- Cut would put both on Selects under one name. Numbering only means anything
  -- across the whole loaded set, so re-derive it here, once, over the union.
  --
  -- Re-named ALWAYS, not only when a duplicate asset is present. The take name
  -- is a function of the three multi-take settings, and those live in the
  -- session, not in the sidecar (SerializeSidecar records the resulting name but
  -- not the settings that produced it). So the sidecar's recorded names are only
  -- authoritative for the settings in force when it was written; the names that
  -- matter are the ones Cut is about to apply, and Cut runs under `cfg` now.
  -- Renaming only on collision would produce the worse outcome of a plan half
  -- named under old settings and half under new. Re-deriving also restores
  -- `primary`, which the sidecar format does not persist at all.
  ApplyCfg()
  vo.AssignNames(plan, cfg)

  state.plan       = plan
  -- Every span above came from a sidecar file, so this plan is, by
  -- definition, backed by what's on disk right now.
  state.plan_saved = true
  state.plan_lines = state.preview
  if state.plan_lines then
    state.line_status, state.orphan_count = FoldStatuses(plan, state.plan_lines)
  else
    -- No usable script to fold against yet -- no CSV loaded, or a required
    -- column unmapped, so RefreshPreview left state.preview nil. An orphan
    -- count is meaningless without a script to be orphaned FROM: every span
    -- just found on disk must not be miscounted as one just because the
    -- preview hasn't been (re)computed. This is the actual site finding 1
    -- was about -- state.plan_lines is produced HERE, so the guard belongs
    -- here, not at whichever caller happens to run after us.
    state.line_status, state.orphan_count = nil, 0
  end
  if update_status then
    state.status = string.format("Loaded %d transcribed span(s) from disk.", #plan)
  end
end

-- Which selected sources still need transcribing. The decision itself lives in
-- the lib as a pure function of (plan, stale, items) so it can be unit-tested;
-- this is only the binding of the dialog's module locals to it. Purely
-- in-memory, so it stays safe to call from the per-frame loop.
local function SourcesNeedingTranscription()
  return vo.SourcesNeedingTranscription(state.plan, state.stale_sources, usable)
end

-- Base names of the stale sources, for messages. state.stale_sources holds full
-- paths so the skip decision cannot confuse two same-named recordings; only the
-- text the user reads is shortened.
local function StaleSourceNames()
  local names = {}
  for _, path in ipairs(state.stale_sources or {}) do
    names[#names + 1] = path:match("([^/\\]+)$") or path
  end
  return names
end

-- The preview table is driven by this ordered list, not hardcoded columns.
-- kind = "mapped" -> a column selector in the header, body values from the CSV.
-- kind = "computed" -> a static header label and a body from render(line); the
-- cell is blank until something fills state.line_status. Nothing in the drawing
-- code may assume every column is mapped.
local COLUMNS = {
  { key = "speaker", label = "Character", kind = "mapped", role = "speaker",
    optional = true, filter = "character", init_width = 200 },
  { key = "asset",   label = "Filename",  kind = "mapped", role = "asset",
    required = true, init_width = 180 },
  { key = "text",    label = "Line Text", kind = "mapped", role = "text",
    required = true, init_width = 280 },
  { key = "status",  label = "Status",    kind = "computed", init_width = 90 },
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
  state.layout_sel   = name
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
  if exists and r.MB("Overwrite the layout preset \"" .. name .. "\" with the\n" ..
                     "current column mapping and skip tokens?",
                     "Overwrite layout preset", 4) ~= 6 then
    return
  end
  if vo.SaveLayoutPreset(name, CurrentLayout()) then
    state.layout_name, state.layout_dirty = name, false
    -- Saving also makes this the droplist selection, so a second Save updates
    -- the same preset rather than falling back to a name prompt.
    state.layout_sel = name
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
  state.layout_sel = name
  RebuildDistinct()
  state.preview_dirty = true
end

-- Any mapping/skip edit deviates from the named preset -> mark unsaved. The
-- name is deliberately kept: it is what Save writes back to, which is the whole
-- point of editing a preset. PersistProjectMemory already refuses to persist a
-- dirty layout_name, so §5.3 restore precedence is unaffected.
local function MarkDirty()
  state.layout_dirty = true
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

-- Reset the whole group of fields that describe a plan/report, in one place,
-- so a caller invalidating one of them (because the will-run set changed, or
-- the script became unusable) can't leave the others describing a plan that
-- no longer exists. Before this helper, dropped_count, script_mismatch and
-- stale_sources survived RefreshPreview's early returns while plan/plan_lines/
-- orphan_count did not -- see finding 4.
--
-- A live, unsaved plan (state.plan_saved == false) is real work -- minutes of
-- whisper transcription that exists nowhere on disk if the sidecar write
-- failed -- and must survive a script-side reset by default. Only a
-- disk-backed plan (or no plan at all) is safe to drop unconditionally; a
-- caller that must invalidate a live plan too -- the source set changed
-- (Run/Cut consumed it, or the plan was just applied) -- passes
-- force_drop_plan = true. See finding: RefreshPreview / :692.
local function ResetVerificationFields(force_drop_plan)
  if force_drop_plan or state.plan_saved then
    state.plan       = nil
    state.plan_saved = false
    state.plan_lines = nil
  end
  state.line_status      = nil
  state.orphan_count     = 0
  state.dropped_count    = 0
  state.stale_sources    = {}
  state.script_mismatch  = ""
  state.mismatch_sources  = {}
  state.dropped_by_source = {}
end

-- Recompute the will-run set. This is the same call Run() makes with the same
-- arguments, so the table cannot drift from actual run behaviour (R4). Leaves
-- state.preview nil (not an empty list) when the mapping is incomplete, which
-- the table distinguishes from "mapped but nothing survives".
local function RefreshPreview()
  state.preview_dirty = false
  state.preview = nil
  -- Anything that changes the will-run set invalidates a plan built from the
  -- old one, so a stale Cut can never be applied. The whole verification-field
  -- group goes with it -- every early-return below leaves that state until
  -- LoadSidecars (at the bottom) recomputes it against a real preview.
  ResetVerificationFields()
  state.status = ""
  if not state.header or state.header_error ~= "" or not state.rows then return end

  local cols = vo.MapColumns(state.header, state.mapping)
  if not cols then return end

  local speakers, canon = CharacterFilter()
  state.preview = vo.BuildScriptLines(state.rows, cols, {
    skip_values  = ParseSkipLines(state.skip_text),
    speakers     = speakers,
    canonicalize = canon,
  })

  if state.plan then
    -- A live plan survived ResetVerificationFields above (it is not yet
    -- disk-backed). Its spans are not script-derived and stay untouched, but
    -- line_status/orphan_count ARE computed against the script, so a mapping
    -- or filter change must refold them against the new line list rather than
    -- leaving them nil'd or describing the old one.
    state.plan_lines = state.preview
    state.line_status, state.orphan_count = FoldStatuses(state.plan, state.preview)
  else
    -- Loading a CSV (or changing its mapping) after the item was already
    -- selected means the sidecar load above ran before state.preview existed;
    -- pick up the statuses now that there is a line list to fold against.
    LoadSidecars()
  end
end

-- The table is the interface: columns are mapped in its header, and the body is
-- the list of lines that will actually run. Rows excluded by a skip token, the
-- character filter, or an empty required cell are hidden, not dimmed (R4).
--
-- The body is drawn inside pcall: an error raised between BeginTable and
-- EndTable would otherwise escape with the table still open and leave ImGui's
-- stack corrupted for every later frame ("Missing EndTable()").
local function DrawTableBody()
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
    -- Every row is emitted; ImGui's own table clipping keeps off-screen rows
    -- from reaching the draw list. ListClipper would cut the per-row Lua calls
    -- too, but ReaImGui treats it as a short-lived resource and rejects it here
    -- ("excessive creation of short-lived resources"), so this is the cost of
    -- staying inside the binding's rules.
    for _, line in ipairs(lines) do
      im.TableNextRow(ctx)
      for i, c in ipairs(COLUMNS) do
        im.TableSetColumnIndex(ctx, i - 1)
        if c.kind == "mapped" then
          im.Text(ctx, line[c.key] or "")
        elseif c.key == "status" then
          -- Blank until a plan exists: no transcription has been run, so there
          -- is nothing to report rather than a status of "not matched".
          local s = STATUS[state.line_status and state.line_status[line.asset]]
          if s then im.TextColored(ctx, s.colour, s.label) end
        end
      end
    end
  else
    im.TableNextRow(ctx)
    im.TableSetColumnIndex(ctx, 0)
    im.TextDisabled(ctx, lines and "No script lines survive the current filters."
                               or  "Choose the Filename and Line Text columns above.")
  end
end

local function DrawTable(height)
  local flags = im.TableFlags_Borders | im.TableFlags_Resizable
              | im.TableFlags_ScrollY | im.TableFlags_RowBg
  if not im.BeginTable(ctx, "script_preview", #COLUMNS, flags, 0, height) then
    return
  end
  local ok, err = pcall(DrawTableBody)
  im.EndTable(ctx)
  if not ok then state.message = tostring(err) end
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

-- The cut half: everything that touches the project. Takes the plan built by
-- the transcribe half, which has been sitting in state until now.
local function Finish(plan, lines)
  local applied, failures = 0, {}
  ApplyCfg()

  core.Transaction("VO ScriptMatch", function()
    applied, failures = vo.ApplyPlan(plan, cfg, usable[1].track)
  end)

  local written, sc_failures = WriteSidecars(plan, lines)
  if #sc_failures > 0 then
    state.sidecar_warning = string.format(
      "Could not write %d sidecar file(s): %s", #sc_failures, sc_failures[1].path)
  else
    state.sidecar_warning = ""
  end

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

  ApplyCfg()

  -- One transcription per unique source file, however many items use it, and
  -- only those that need it: a source whose sidecar loaded cleanly and still
  -- matches its audio is skipped.
  local needing = SourcesNeedingTranscription()
  local wanted  = {}
  for _, path in ipairs(needing) do wanted[path] = true end

  local seen, sources = {}, {}
  local transcribed = {}
  for _, item in ipairs(usable) do
    if item.path and not seen[item.path] and (#needing == 0 or wanted[item.path]) then
      seen[item.path] = true
      transcribed[item.path] = true
      sources[#sources + 1] = { path = item.path, size = vo.FileSize(item.path) or 0 }
    end
  end

  -- What the sources we are NOT re-transcribing already contribute, captured
  -- before the plan is cleared below. Without this a partial run would REPLACE
  -- the plan with only the freshly transcribed source and silently drop the
  -- rest: their lines would lose their status and Cut would apply nothing for
  -- them. These spans stay in PROJECT time (SpansBySourcePath does not convert)
  -- so they can be concatenated with a fresh BuildPlan result, which is also in
  -- project time -- its words came through MapWordsToProject.
  local retained, retained_saved = {}, (state.plan_saved == true)
  do
    local by_path = vo.SpansBySourcePath(state.plan, usable)
    for path, spans in pairs(by_path) do
      if not transcribed[path] then
        for _, span in ipairs(spans) do retained[#retained + 1] = span end
      end
    end
  end

  -- Every exit that ends without a new plan -- cancelled, errored, no words --
  -- puts the retained spans back rather than leaving the user at an empty plan
  -- for sources this run never intended to touch. state.stale_sources is not
  -- restored because nothing cleared it: no skipped source was re-transcribed.
  local function RestoreRetained()
    if #retained == 0 then return end
    local kept = {}
    for i, span in ipairs(retained) do kept[i] = span end
    table.sort(kept, function(a, b) return (a.start or 0) < (b.start or 0) end)
    state.plan       = kept
    state.plan_lines = lines
    state.plan_saved = retained_saved
    state.line_status, state.orphan_count = FoldStatuses(kept, lines)
  end

  -- Nothing needs transcribing, so this press is a deliberate re-run: bypass
  -- both the sidecar and the scratch-dir transcript cache. The cache key already
  -- covers backend settings, so only the audio itself can have changed under it.
  cfg.force_retranscribe = (#needing == 0)

  state.plan        = nil
  state.plan_saved  = false
  state.plan_lines  = nil
  state.line_status = nil
  state.status      = ""
  state.running     = true

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
        RestoreRetained()
        r.MB("The transcription produced no words, so there is nothing to match.\n" ..
             "Check that the selected items contain speech.",
             "ajsfx VO ScriptMatch", 0)
        return
      end

      local plan = vo.BuildPlan(lines, words, cfg)
      ClampSpansToItems(plan, usable)

      -- The plan is the UNION of what was just transcribed and what the skipped
      -- sources already had. Both sides are in project time, so they append
      -- directly; the sort keeps the whole plan ordered the way LoadSidecars
      -- and ApplyPlan expect.
      for _, span in ipairs(retained) do plan[#plan + 1] = span end
      table.sort(plan, function(a, b) return (a.start or 0) < (b.start or 0) end)

      -- Naming has to be re-derived over the UNION, not just the new half.
      -- BuildPlan numbered the freshly transcribed spans while they were the
      -- only spans it could see, and the retained spans carry numbering from
      -- whenever they were last named -- also in isolation. Two sources each
      -- holding a read of L001 would therefore both arrive as take 1, both
      -- primary, both named "L001", and Cut would drop two identically named
      -- items on the Selects track with no _tk suffix and nothing routed to
      -- Alts. AssignNames re-derives take_index/primary/dest/name from
      -- kind/asset/start and is idempotent, so one pass over the whole plan
      -- fixes the collision without disturbing anything already correct.
      -- Deliberately AFTER ClampSpansToItems above: this only writes naming
      -- fields, never start/stop, so the retained spans may stay aliased
      -- (rather than deep-copied) exactly as before.
      vo.AssignNames(plan, cfg)

      state.running       = false
      state.plan          = plan
      state.plan_lines    = lines
      -- A fresh transcription re-derives everything the sidecar loader reported
      -- stale -- but only for the sources actually re-run. A stale source that
      -- this partial run skipped is still stale, and must keep blocking Cut:
      -- clearing the list wholesale would re-enable Cut over unchanged-in-name,
      -- changed-in-fact audio.
      local kept_stale = {}
      for _, path in ipairs(state.stale_sources or {}) do
        if not transcribed[path] then kept_stale[#kept_stale + 1] = path end
      end
      state.stale_sources   = kept_stale

      -- The same partial-run rule for the other two sidecar-derived warnings.
      -- A skipped source whose sidecar was written against a DIFFERENT script
      -- CSV is still transcribed against that other CSV, and a skipped source
      -- whose spans fell outside its trimmed item still lost those spans;
      -- blanking either one here would let the user press Cut with the warning
      -- silently gone. Keep whatever belongs to a source this run did not
      -- re-transcribe, and drop only what it did.
      local kept_mismatch = {}
      for _, m in ipairs(state.mismatch_sources or {}) do
        if not transcribed[m[1]] then kept_mismatch[#kept_mismatch + 1] = m end
      end
      state.mismatch_sources = kept_mismatch
      state.script_mismatch  = kept_mismatch[1] and kept_mismatch[1][2] or ""

      local kept_dropped, kept_dropped_count = {}, 0
      for path, n in pairs(state.dropped_by_source or {}) do
        if not transcribed[path] then
          kept_dropped[path] = n
          kept_dropped_count = kept_dropped_count + n
        end
      end
      state.dropped_by_source = kept_dropped
      state.dropped_count     = kept_dropped_count

      -- Fold the plan's spans down to one status per script line for the table.
      -- A line with several takes keeps the best outcome of any of them.
      state.line_status, state.orphan_count = FoldStatuses(plan, lines)

      -- Persist beside each recording now, not at cut time: a session where
      -- the user transcribes, inspects and never cuts still leaves a result.
      local written, sc_failures = WriteSidecars(plan, lines)
      state.sidecar_warning = ""
      if #sc_failures > 0 then
        state.sidecar_warning = string.format(
          "Could not write %d sidecar file(s): %s",
          #sc_failures, sc_failures[1].path)
      end
      -- Disk-backed only if every source was actually written; a partial
      -- write leaves this plan live-and-unsaved, same as a total failure --
      -- it must not be silently dropped by a later reselect (see loop()).
      -- WriteSidecars was handed the MERGED plan, so the retained sources were
      -- re-persisted too: a clean write means the whole plan is on disk, and a
      -- failed one means it is not, retained half included.
      state.plan_saved = (#sc_failures == 0)

      local counts = { match = 0, review = 0, unmatched = 0 }
      for _, span in ipairs(plan) do counts[span.kind] = (counts[span.kind] or 0) + 1 end
      state.status = string.format(
        "Transcribed: %d matched, %d for review, %d unmatched. Press Cut to apply.",
        counts.match, counts.review, counts.unmatched)
    end,
    function()
      state.running = false
      RestoreRetained()
      r.MB("Cancelled. Nothing in the project was changed.", "ajsfx VO ScriptMatch", 0)
    end,
    function(message)
      state.running = false
      RestoreRetained()
      r.MB(message .. "\n\nNothing in the project was changed.",
           "ajsfx VO ScriptMatch", 0)
    end)
end

-- -----------------------------------------------------------------------
-- Run dialog
-- -----------------------------------------------------------------------

-- Put the cursor on the current line such that buttons with these labels end
-- flush with the right edge. ImGui has no right-align, so the width is measured
-- from the labels and the frame/spacing style values.
local function RightAlign(labels)
  local padx    = im.GetStyleVar(ctx, im.StyleVar_FramePadding)
  local spacing = im.GetStyleVar(ctx, im.StyleVar_ItemSpacing)
  local total   = 0
  for i, label in ipairs(labels) do
    total = total + im.CalcTextSize(ctx, label) + padx * 2
    if i > 1 then total = total + spacing end
  end
  im.SameLine(ctx)
  im.SetCursorPosX(ctx, im.GetCursorPosX(ctx) + im.GetContentRegionAvail(ctx) - total)
end

local function loop()
  -- Keep drawing while a transcription runs. vo.RunWhisperAsync polls the
  -- whisper process headlessly and draws nothing of its own, so a dialog that
  -- stops here leaves the user staring at an empty screen with no sign of
  -- progress -- and because the defer chain ends with this function, stopping
  -- also meant the window never came back.
  --
  -- The selection scan is the one thing skipped while running: the in-flight
  -- callbacks captured `usable`, and rebuilding it underneath them would map
  -- the transcribed words against a different set of items than they came from.
  if not state.running then
    -- The reload rule keys off WHERE the current plan came from
    -- (state.plan_saved), not just whether one exists -- a single boolean
    -- can't distinguish "disk-backed, describes the current selection" from
    -- "live from whisper, not yet written anywhere" (see the finding at the
    -- top of this file's history for why `not state.plan` alone broke this).
    --
    -- * The source set genuinely changed (src_changed): ALWAYS reload. A plan
    --   cannot describe a source set it wasn't built from -- keeping it, even
    --   a live/unsaved one, would let Cut apply RIVA's spans to OTHER's items.
    --   The unsaved-plan-lost case is not silent: sidecar_warning already
    --   surfaced the write failure when it happened.
    -- * Same sources, different items (sel_changed and not src_changed):
    --   reload UNLESS doing so would destroy something. The only thing worth
    --   protecting is a LIVE UNSAVED plan (plan ~= nil and not plan_saved):
    --   minutes of whisper transcription that exists nowhere on disk. No plan
    --   at all is nothing to lose, so load -- otherwise the sidecar Cut itself
    --   just wrote would never come back and the user would be stranded with
    --   an empty Status column and a dead Cut button. A disk-backed plan
    --   round-trips harmlessly, so load -- that is also what lets a shift-click
    --   adding a second item on the same source pick up spans that were
    --   previously out of range, now that src_changed no longer fires there.
    -- * Neither changed: no load, no I/O.
    local sel_changed, src_changed = RefreshSelection()
    local should_reload = src_changed
      or (sel_changed and (state.plan == nil or state.plan_saved))
    if should_reload then
      if src_changed then
        state.status, state.sidecar_warning = "", ""
      end
      LoadSidecars(src_changed)
    end
  end

  if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
    ctx = im.CreateContext('VO ScriptMatch')
  end

  im.SetNextWindowSize(ctx, 760, 720, im.Cond_FirstUseEver)
  local visible, open = im.Begin(ctx, 'ajsfx VO ScriptMatch', true)

  local pressed_run, pressed_cut = false, false

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
        -- The droplist only *selects*; nothing is loaded until Load is pressed.
        -- Selecting is therefore free of consequences, and Save has a target to
        -- write back to without the user retyping the name.
        local preset_names = vo.ListLayoutPresets()
        local preset_items = { "(none)" }
        for _, n in ipairs(preset_names) do preset_items[#preset_items + 1] = n end
        -- The selection is tracked by NAME, not index: Save As inserts into the
        -- sorted list and would silently shift a stored index onto a neighbour.
        local preset_cur = 0
        for i, n in ipairs(preset_names) do
          if n == state.layout_sel then preset_cur = i; break end
        end
        local pchanged, psel = im.Combo(ctx, "Preset", preset_cur,
          table.concat(preset_items, "\0") .. "\0\0")
        if pchanged then
          state.layout_sel = (psel > 0) and preset_names[psel] or ""
        end

        -- Capture every disabled flag BEFORE its button: these buttons mutate
        -- layout_sel in the same frame, so gating EndDisabled on a re-read would
        -- unbalance the ImGui stack (see Settings dis_bin/dis_model/dis_check).
        local no_sel = (state.layout_sel == "")

        if no_sel then im.BeginDisabled(ctx) end
        if im.Button(ctx, "Load") then LoadPresetByName(state.layout_sel) end
        if no_sel then im.EndDisabled(ctx) end
        if im.IsItemHovered(ctx) then
          im.SetTooltip(ctx, no_sel and "Choose a preset above first."
            or "Replace the current mapping and skip tokens with this preset.")
        end

        im.SameLine(ctx)
        if no_sel then im.BeginDisabled(ctx) end
        if im.Button(ctx, "Save") then DoSave(state.layout_sel) end
        if no_sel then im.EndDisabled(ctx) end
        if im.IsItemHovered(ctx) then
          im.SetTooltip(ctx, no_sel and "Choose a preset above, or use Save As…"
            or ("Overwrite \"" .. state.layout_sel .. "\" with the current layout."))
        end

        im.SameLine(ctx)
        if im.Button(ctx, "Save As...") then
          local ok, name = r.GetUserInputs("Save layout preset as", 1,
            "Preset name:,extrawidth=180", state.layout_sel)
          if ok then DoSave(name) end
        end

        im.SameLine(ctx)
        if no_sel then im.BeginDisabled(ctx) end
        if im.Button(ctx, "Delete") then
          local nm = state.layout_sel
          if nm ~= "" and r.MB("Delete layout preset \"" .. nm .. "\"?",
                               "Delete layout preset", 4) == 6 then
            vo.DeleteLayoutPreset(nm)
            state.layout_sel = ""
            -- The mapping in the dialog stays as it is; it just no longer has a
            -- preset behind it, so it persists inline instead.
            if state.layout_name == nm then
              state.layout_name, state.layout_dirty = "", true
            end
            state.message = "Deleted layout preset \"" .. nm .. "\"."
          end
        end
        if no_sel then im.EndDisabled(ctx) end

        -- What the current mapping actually is, which the droplist no longer
        -- says now that selecting and loading are separate.
        if state.layout_name == "" then
          im.TextDisabled(ctx, "Current layout: not saved to a preset.")
        elseif state.layout_dirty then
          im.TextColored(ctx, 0xDDAA33FF,
            "Current layout: " .. state.layout_name .. " (edited, not saved).")
        else
          im.TextDisabled(ctx, "Current layout: " .. state.layout_name .. ".")
        end

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

    -- Run gating. Both required roles must be mapped and the CSV must parse.
    local run_error
    if #usable == 0 then
      run_error = (#skipped > 0)
        and ("None of the selected items can be transcribed:\n" .. table.concat(skipped, "\n"))
        or  "Select the recorded session item(s) on a track."
    elseif not state.header then
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

    if state.header and state.header_error == "" then
      im.Spacing(ctx)
      -- Reserve room for the count line, the button row and whichever status
      -- lines are showing; the table takes whatever height is left. The reserve
      -- is counted rather than fixed so a long error message can't push the
      -- buttons off the bottom of the window — the reason they were moved up
      -- in the first place.
      local rows = 2 -- count line + button row
      if state.running               then rows = rows + 1 end
      if state.status ~= ""           then rows = rows + 1 end
      if #state.stale_sources > 0     then rows = rows + 1 end
      if state.script_mismatch ~= ""  then rows = rows + 1 end
      if state.orphan_count > 0       then rows = rows + 1 end
      if state.dropped_count > 0      then rows = rows + 1 end
      if state.sidecar_warning ~= ""  then rows = rows + 1 end
      if run_error                    then rows = rows + 1 end
      if state.message ~= ""          then rows = rows + 1 end

      -- GetContentRegionAvail returns width first, so the height must come from
      -- the SECOND return value; the first ties table height to window width.
      local _, avail_h = im.GetContentRegionAvail(ctx)
      DrawTable(math.max(120, avail_h - im.GetFrameHeightWithSpacing(ctx) * rows))

      im.TextDisabled(ctx, string.format("%d of %d rows will run.",
        state.preview and #state.preview or 0, state.rows and #state.rows or 0))
    end

    if state.status ~= "" then
      im.TextColored(ctx, 0x66BB66FF, state.status)
    end

    if #state.stale_sources > 0 then
      im.TextColored(ctx, 0xDDAA33FF, string.format(
        "%s has changed since it was transcribed — Re-transcribe to refresh.",
        table.concat(StaleSourceNames(), ", ")))
    end
    if state.script_mismatch ~= "" then
      im.TextColored(ctx, 0xDDAA33FF,
        "Transcribed against a different script: " .. state.script_mismatch)
    end
    if state.orphan_count > 0 then
      im.TextDisabled(ctx, string.format(
        "%d transcribed line(s) are not in this script.", state.orphan_count))
    end
    if state.dropped_count > 0 then
      im.TextDisabled(ctx, string.format(
        "%d transcribed span(s) fall outside the selected items.", state.dropped_count))
    end
    if state.sidecar_warning ~= "" then
      im.TextColored(ctx, 0xDDAA33FF, state.sidecar_warning)
    end

    if run_error then
      im.TextColored(ctx, 0xDDAA33FF, run_error)
    end

    if state.message ~= "" then
      im.TextColored(ctx, 0xDD6666FF, state.message)
    end

    -- The only sign a transcription is under way: whisper is polled headlessly
    -- and reports nothing itself, so without this the dialog looks idle.
    if state.running then
      im.TextColored(ctx, 0x66BB66FF,
        "Transcribing… this can take several minutes. REAPER stays usable.")
    end

    -- Transcribe and Cut, bottom-right. Transcribe reads the audio and builds
    -- the plan; nothing in the project changes until Cut.
    local needing = SourcesNeedingTranscription()
    -- "Nothing left to do" is only a claim worth making about a non-empty
    -- selection: with no usable items #needing is trivially 0, and labelling
    -- that "Re-transcribe" told the user every selected recording was already
    -- transcribed when none were even selected.
    local all_done = (#needing == 0) and (#usable > 0)
    local relabel  = all_done and "Re-transcribe" or "Transcribe"
    RightAlign({ relabel, "Cut and name" })

    -- Both buttons are dead while a transcription is in flight: a second press
    -- would start an overlapping run whose callbacks race the first one's.
    local dis_run = (run_error ~= nil) or state.running
    if dis_run then im.BeginDisabled(ctx) end
    pressed_run = im.Button(ctx, relabel)
    if dis_run then im.EndDisabled(ctx) end
    if im.IsItemHovered(ctx) then
      -- A disabled button must say why it is disabled, the way Cut does below;
      -- run_error is the only thing that disables this one besides a run in
      -- flight, so it outranks any description of what a press would do.
      im.SetTooltip(ctx, state.running and "A transcription is already running."
        or run_error and ("This cannot run yet:\n" .. run_error)
        or all_done
        and "Every selected recording is already transcribed.\nThis discards those results and runs again from scratch."
        or  string.format("Transcribe %d recording(s).\nNothing in the project changes.", #needing))
    end

    im.SameLine(ctx)
    -- run_error also gates Cut. When the script side is unusable -- a required
    -- column unmapped, the CSV unloaded, nothing selected -- RefreshPreview
    -- returns early and leaves a surviving live plan paired with a STALE
    -- plan_lines and no line_status, so the table honestly reads "0 of N rows
    -- will run" while Cut would silently apply the OLD line list. The plan is
    -- still valuable, so it is kept rather than discarded; it just cannot be
    -- applied until the script is mapped again. The tooltip says which.
    local dis_cut = (state.plan == nil) or state.running
      or (#state.stale_sources > 0) or (run_error ~= nil)
    if dis_cut then im.BeginDisabled(ctx) end
    pressed_cut = im.Button(ctx, "Cut and name")
    if dis_cut then im.EndDisabled(ctx) end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx,
        (state.plan == nil) and "Transcribe first — there is no plan to apply."
        or (#state.stale_sources > 0) and "The audio has changed since it was transcribed. Re-transcribe first."
        or state.running and "A transcription is already running."
        or run_error and ("The plan is kept, but it cannot be applied until the script is usable again:\n" .. run_error)
        or "Split and name the clips from the transcribed plan.")
    end
  end

  -- Always End after Begin; skipping it corrupts ImGui's push/pop stack.
  im.End(ctx)

  -- Both actions run after End, because Finish opens a modal. Run must NOT
  -- return early here: the defer that keeps this dialog alive is at the bottom
  -- of this function, so bailing out once state.running was set is what used to
  -- close the window for the whole transcription and never reopen it.
  if pressed_run then
    state.message = ""
    Run()
  elseif pressed_cut and state.plan then
    state.message = ""
    Finish(state.plan, state.plan_lines)
    -- Clear every verification field the plan being applied described, not
    -- just the plan itself -- otherwise "N transcribed span(s) fall outside
    -- the selected items" keeps rendering under "Cut applied." until the next
    -- selection change happens to recompute them. Routed through the same
    -- helper RefreshPreview uses so the two callers can't drift; force the
    -- plan itself to clear regardless of provenance, since Cut just applied
    -- it whether or not it was disk-backed.
    ResetVerificationFields(true)
    state.status = "Cut applied."
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
