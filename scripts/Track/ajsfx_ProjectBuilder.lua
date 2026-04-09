-- @description Project Builder
-- @author ajsfx
-- @version 1.0
-- @about Scaffold multi-group track architectures from a GUI — folder tracks with FX aux routing and section-based naming.
-- @provides
--   [main] .
--   [nomain] ../lib/ajsfx_core.lua

local r = reaper

-- Load core library
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path
local core = require("lib.ajsfx_core")

local success, im = pcall(function()
    package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
    return require('imgui')('0.9.3')
end)

if not success then
    r.MB("This script requires the 'imgui' library, which is included with REAPER.\nIf you are seeing this, your installation may be unusual.", "Library not found", 0)
    return
end

--------------------------------
-- --- CONSTANTS ---
--------------------------------
local EXT_SECTION     = "ajsfx_ProjectBuilder"
local PRESETS_SECTION = "ajsfx_ProjectBuilder_Presets"
local MAX_GROUPS      = 64
local MAX_AUX         = 8
local MAX_CONTENT     = 64
local MAX_SECTIONS    = 16

local DEFAULT_PRESETS = {
  {
    name     = "Standard Asset",
    sections = {
      { type = "shared", label = "Character" },
      { type = "input",  label = "Action" },
      { type = "shared", label = "Date" },
    }
  },
  {
    name     = "VO Asset",
    sections = {
      { type = "shared", label = "Prefix" },
      { type = "input",  label = "Character" },
      { type = "shared", label = "Date" },
    }
  },
  {
    name     = "Blank",
    sections = {
      { type = "input", label = "Name" },
    }
  },
}

--------------------------------
-- --- BATCH MANAGEMENT ---
--------------------------------
local function deep_copy_sections(sections)
    local copy = {}
    for _, s in ipairs(sections) do
        copy[#copy + 1] = { type = s.type, label = s.label }
    end
    return copy
end

local function create_batch_from_preset(preset)
  local batch = {
    preset_name   = preset.name,
    sections      = deep_copy_sections(preset.sections),
    shared_values = {},
    num_groups    = 1,
    num_aux       = 1,
    num_audio     = 4,
    num_midi      = 0,
    groups        = {},
    layout_preview_open = true,
    batch.save_dialog_name    = "",
  }
  batch.groups[1] = {}
  for _, s in ipairs(batch.sections) do
    if s.type == "input" then
      batch.groups[1][s.label] = ""
    end
  end
  return batch
end

local function sync_batch_groups(batch)
    -- Ensure batch.groups has exactly num_groups entries with all input labels
    local input_labels = {}
    for _, s in ipairs(batch.sections) do
        if s.type == "input" then
            input_labels[#input_labels + 1] = s.label
        end
    end

    while #batch.groups < batch.num_groups do
        local g = {}
        for _, label in ipairs(input_labels) do
            g[label] = ""
        end
        batch.groups[#batch.groups + 1] = g
    end
    while #batch.groups > batch.num_groups do
        batch.groups[#batch.groups] = nil
    end

    -- Ensure all groups have all input labels
    for _, g in ipairs(batch.groups) do
        for _, label in ipairs(input_labels) do
            if g[label] == nil then g[label] = "" end
        end
    end
end

-- Removed sync_batch_aux_names

--------------------------------
-- --- SESSION PERSISTENCE ---
--------------------------------
local function serialize_session(batches)
    -- Simple serialization: one batch per line, fields separated by tab
    -- This is intentionally simple; complex nested data uses a flat encoding
    local lines = {}
    for _, b in ipairs(batches) do
        local parts = {
            "BATCH",
            b.preset_name,
            tostring(b.num_groups),
            tostring(b.num_aux),
            tostring(b.num_audio),
            tostring(b.num_midi),
        }
        lines[#lines + 1] = table.concat(parts, "\t")

        -- Sections
        for _, s in ipairs(b.sections) do
            lines[#lines + 1] = "SEC\t" .. s.type .. "\t" .. s.label
        end

        -- Shared values
        for _, s in ipairs(b.sections) do
            if s.type == "shared" then
                lines[#lines + 1] = "SV\t" .. s.label .. "\t" .. (b.shared_values[s.label] or "")
            end
        end

        -- No standalone Aux names required now

        -- Group input values
        for gi, g in ipairs(b.groups) do
            for _, s in ipairs(b.sections) do
                if s.type == "input" then
                    lines[#lines + 1] = "GRP\t" .. tostring(gi) .. "\t" .. s.label .. "\t" .. (g[s.label] or "")
                end
            end
        end
    end
    return table.concat(lines, "\n")
end

local function deserialize_session(str)
    if not str or str == "" then return nil end
    local batches = {}
    local current = nil

    for line in str:gmatch("[^\n]+") do
        local parts = {}
        for part in line:gmatch("[^\t]*") do
            parts[#parts + 1] = part
        end

        if parts[1] == "BATCH" and #parts >= 5 then
            current = {
                preset_name   = parts[2],
                sections      = {},
                shared_values = {},
                num_groups    = tonumber(parts[3]) or 1,
                num_aux       = tonumber(parts[4]) or 1,
                num_audio     = tonumber(parts[5]) or 4,
                num_midi      = tonumber(parts[6]) or 0,
                groups        = {},
            }
            batches[#batches + 1] = current
        elseif current and parts[1] == "SEC" and #parts >= 3 then
            current.sections[#current.sections + 1] = { type = parts[2], label = parts[3] }
        elseif current and parts[1] == "SV" and #parts >= 3 then
            current.shared_values[parts[2]] = parts[3]
        elseif current and parts[1] == "AUX" and #parts >= 3 then
            -- Legacy support, do nothing.
        elseif current and parts[1] == "GRP" and #parts >= 4 then
            local gi = tonumber(parts[2])
            if gi then
                if not current.groups[gi] then current.groups[gi] = {} end
                current.groups[gi][parts[3]] = parts[4]
            end
        end
    end

    -- Sync each batch
    for _, b in ipairs(batches) do
        sync_batch_groups(b)
    end

    return #batches > 0 and batches or nil
end

local function save_session(batches)
    r.SetExtState(EXT_SECTION, "SESSION", serialize_session(batches), true)
end

local function load_session()
    if r.HasExtState(EXT_SECTION, "SESSION") then
        return deserialize_session(r.GetExtState(EXT_SECTION, "SESSION"))
    end
    return nil
end

--------------------------------
-- --- GENERATION ---
--------------------------------
local function validate_batches(batches)
  local settings = core.settings.Load()
  if #batches == 0 then return false, "No batches configured." end
  for bi, batch in ipairs(batches) do
    if #batch.sections == 0 then
      return false, "Batch " .. bi .. " has no name sections."
    end
    for gi = 1, batch.num_groups do
      local name = core.naming.ResolveGroupName(batch, gi)
      local empty_name = settings.delimiter:rep(#batch.sections - 1)
      if name == "" or name == empty_name then
        return false, "Batch " .. bi .. ", Group " .. gi .. ": name resolves to empty.\nPlease fill in all sections."
      end
    end
  end
  local proj_name = r.GetProjectName(0, "")
  if proj_name == "" then
    for _, batch in ipairs(batches) do
      for _, s in ipairs(batch.sections) do
        local value
        if s.type == "shared" then
          value = batch.shared_values[s.label] or ""
        else
          for gi = 1, batch.num_groups do
            value = (batch.groups[gi] and batch.groups[gi][s.label]) or ""
            if value:find("%$project") then
              return false, "Project is unsaved — $project will resolve to empty.\nPlease save the project first or remove the $project wildcard."
            end
          end
        end
        if value and value:find("%$project") then
          return false, "Project is unsaved — $project will resolve to empty.\nPlease save the project first or remove the $project wildcard."
        end
      end
    end
  end
  return true, nil
end

local function generate_tracks(batches)
    local valid, err = validate_batches(batches)
    if not valid then
        r.MB(err, "Project Builder", 0)
        return false
    end

    core.Transaction("Project Builder: Generate Tracks", function()
        local insert_idx = r.CountTracks(0)

        for _, batch in ipairs(batches) do
            for g = 1, batch.num_groups do
                local group_name = core.naming.ResolveGroupName(batch, g)

                -- Group Master (folder)
                r.InsertTrackAtIndex(insert_idx, true)
                local master = r.GetTrack(0, insert_idx)
                r.GetSetMediaTrackInfo_String(master, "P_NAME", group_name, true)
                r.SetMediaTrackInfo_Value(master, "I_FOLDERDEPTH", 1)
                insert_idx = insert_idx + 1

                -- FX Aux tracks
                local aux_tracks = {}
                for a = 1, batch.num_aux do
                    r.InsertTrackAtIndex(insert_idx, true)
                    local aux = r.GetTrack(0, insert_idx)
                    r.GetSetMediaTrackInfo_String(aux, "P_NAME", "FX_" .. a, true)
                    aux_tracks[#aux_tracks + 1] = aux
                    insert_idx = insert_idx + 1
                end

                -- Content tracks
                local total_children = batch.num_aux + batch.num_audio + batch.num_midi
                for c = 1, batch.num_audio + batch.num_midi do
                    r.InsertTrackAtIndex(insert_idx, true)
                    local content = r.GetTrack(0, insert_idx)

                    -- Close folder on last child
                    if batch.num_aux + c == total_children then
                        r.SetMediaTrackInfo_Value(content, "I_FOLDERDEPTH", -1)
                    end

                    -- Wire sends to all aux tracks
                    for _, aux in ipairs(aux_tracks) do
                        r.CreateTrackSend(content, aux)
                    end
                    insert_idx = insert_idx + 1
                end

                -- Edge case: 0 content tracks, close folder on last aux
                if (batch.num_audio + batch.num_midi) == 0 and batch.num_aux > 0 then
                    local last_aux = r.GetTrack(0, insert_idx - 1)
                    r.SetMediaTrackInfo_Value(last_aux, "I_FOLDERDEPTH", -1)
                end

                -- Edge case: 0 content and 0 aux — empty folder, need a dummy close
                if (batch.num_audio + batch.num_midi) == 0 and batch.num_aux == 0 then
                    -- Close the folder on the master itself (depth goes back to 0)
                    r.SetMediaTrackInfo_Value(master, "I_FOLDERDEPTH", 0)
                end
            end
        end

        r.TrackList_AdjustWindows(false)
    end)
    return true
end

--------------------------------
-- --- GUI STATE ---
--------------------------------
local ctx = im.CreateContext('Project Builder')
local WINDOW_FLAGS = im.WindowFlags_None

local all_presets    = core.naming.LoadAllPresets(PRESETS_SECTION, DEFAULT_PRESETS)
local batches        = load_session() or {}
local selected_batch = #batches > 0 and 1 or 0

-- Input buffers for ImGui (keyed by unique id)
local input_buffers = {}

local function get_buf(id, default)
    if input_buffers[id] == nil then
        input_buffers[id] = default or ""
    end
    return input_buffers[id]
end

--------------------------------
-- --- GUI HELPERS ---
--------------------------------
local function draw_labeled_input_text(ctx, label, buf_id, current_val, input_width, label_width)
    im.Text(ctx, label)
    im.SameLine(ctx, label_width)
    im.SetNextItemWidth(ctx, input_width)
    local rv, val = im.InputText(ctx, "##" .. buf_id, current_val)
    return rv, val
end

local function draw_labeled_input_int(ctx, label, current_val, input_width, label_width, min_val, max_val)
    im.Text(ctx, label)
    im.SameLine(ctx, label_width)
    im.SetNextItemWidth(ctx, input_width)
    local rv, val = im.InputInt(ctx, "##" .. label, current_val, 1, 1)
    if rv then
        val = math.max(min_val, math.min(max_val, val))
    end
    return rv, val
end

--------------------------------
-- --- MAIN GUI ---
--------------------------------
local COLOR_SHARED = 0x88FF88FF -- Light Green
local COLOR_INPUT = 0x88CCFFFF -- Light Blue
local COLOR_DELIM = 0x888888FF -- Grey

local function draw_preset_layout(ctx, sections, delimiter)
    for i, s in ipairs(sections) do
        local color = s.type == "shared" and COLOR_SHARED or COLOR_INPUT
        im.TextColored(ctx, color, "[" .. s.label .. "]")
        if i < #sections then
            im.SameLine(ctx, 0, 0)
            im.TextColored(ctx, COLOR_DELIM, delimiter)
            im.SameLine(ctx, 0, 0)
        end
    end
end

local function draw_batch_config()
    if selected_batch < 1 or selected_batch > #batches then
        im.TextDisabled(ctx, "Select or add a batch to configure.")
        return
    end

    local batch = batches[selected_batch]
    local bid = "b" .. selected_batch .. "_"

    -- ── NAME PRESET ──────────────────────────────────────────────────────────
    im.SeparatorText(ctx, "Name Preset")

    local avail_w = im.GetContentRegionAvail(ctx)
    local btn_w   = 50
    local n_btns  = core.naming.IsDefaultPreset(batch.preset_name, DEFAULT_PRESETS) and 2 or 3
    local combo_w = avail_w - (btn_w * n_btns) - (8 * n_btns)

    im.SetNextItemWidth(ctx, combo_w)
    if im.BeginCombo(ctx, "##PresetCombo", batch.preset_name) then
        for _, p in ipairs(all_presets) do
            local is_selected = batch.preset_name == p.name
            if im.Selectable(ctx, p.name .. "##" .. p.name, is_selected) then
                batch.preset_name   = p.name
                batch.sections      = deep_copy_sections(p.sections)
                batch.shared_values = {}
                for k in pairs(input_buffers) do
                    if k:find("^" .. bid) then input_buffers[k] = nil end
                end
                sync_batch_groups(batch)
            end
        end
        im.EndCombo(ctx)
    end

    im.SameLine(ctx)
    if im.Button(ctx, "Save##preset", btn_w, 0) then
        batch.save_dialog_name = batch.preset_name
        input_buffers["save_name_" .. bid] = batch.preset_name
        im.OpenPopup(ctx, "##save_preset_dialog")
    end

    im.SameLine(ctx)
    if im.Button(ctx, "New##preset", btn_w, 0) then
        -- Find a unique name
        local base_name = "New Preset"
        local new_name  = base_name
        local suffix    = 2
        local name_taken = true
        while name_taken do
            name_taken = false
            for _, p in ipairs(all_presets) do
                if p.name == new_name then name_taken = true; break end
            end
            if name_taken then new_name = base_name .. " " .. suffix; suffix = suffix + 1 end
        end
        local new_p = { name = new_name, sections = { { type = "input", label = "Name" } } }
        all_presets[#all_presets + 1] = new_p
        core.naming.SaveCustomPresets(PRESETS_SECTION, all_presets, DEFAULT_PRESETS)
        batch.preset_name   = new_p.name
        batch.sections      = deep_copy_sections(new_p.sections)
        batch.shared_values = {}
        sync_batch_groups(batch)
    end

    if not core.naming.IsDefaultPreset(batch.preset_name, DEFAULT_PRESETS) then
        im.SameLine(ctx)
        if im.Button(ctx, "Del##preset", btn_w, 0) then
            all_presets = core.naming.DeleteCustomPreset(PRESETS_SECTION, all_presets, batch.preset_name, DEFAULT_PRESETS)
            local p = all_presets[1]
            batch.preset_name   = p.name
            batch.sections      = deep_copy_sections(p.sections)
            batch.shared_values = {}
            sync_batch_groups(batch)
        end
    end

    -- Save dialog popup
    if im.BeginPopup(ctx, "##save_preset_dialog") then
        im.Text(ctx, "Save preset as:")
        im.SetNextItemWidth(ctx, 220)
        local rv, val = im.InputText(ctx, "##save_name", get_buf("save_name_" .. bid, batch.save_dialog_name))
        if rv then
            batch.save_dialog_name = val
            input_buffers["save_name_" .. bid] = val
        end

        local name_exists = false
        for _, p in ipairs(all_presets) do
            if p.name == batch.save_dialog_name then name_exists = true; break end
        end
        local is_default = core.naming.IsDefaultPreset(batch.save_dialog_name, DEFAULT_PRESETS)

        if name_exists then
            im.TextColored(ctx, 0xFFAA44FF, "\xe2\x9a\xa0 \"" .. batch.save_dialog_name .. "\" already exists. Overwrite?")
        end
        im.Spacing(ctx)

        if im.Button(ctx, "Cancel##save", 80, 0) then
            im.CloseCurrentPopup(ctx)
        end
        im.SameLine(ctx)

        local can_save = batch.save_dialog_name ~= "" and not is_default
        if not can_save then im.BeginDisabled(ctx) end
        local confirm_label = name_exists and "Overwrite" or "Save"
        if im.Button(ctx, confirm_label .. "##save_confirm", 80, 0) then
            local found = false
            for idx, p in ipairs(all_presets) do
                if p.name == batch.save_dialog_name then
                    all_presets[idx] = { name = batch.save_dialog_name, sections = deep_copy_sections(batch.sections) }
                    found = true
                    break
                end
            end
            if not found then
                all_presets[#all_presets + 1] = { name = batch.save_dialog_name, sections = deep_copy_sections(batch.sections) }
            end
            batch.preset_name = batch.save_dialog_name
            core.naming.SaveCustomPresets(PRESETS_SECTION, all_presets, DEFAULT_PRESETS)
            im.CloseCurrentPopup(ctx)
        end
        if not can_save then im.EndDisabled(ctx) end
        im.EndPopup(ctx)
    end

    -- ── Inline horizontal preset editor strip ────────────────────────────────
    im.PushStyleColor(ctx, im.Col_ChildBg, 0x1A1A2AFF)
    local strip_visible = im.BeginChild(ctx, "##preset_strip_" .. bid, -1, 34, im.ChildFlags_Border)
    if strip_visible then

    local settings = core.settings.Load()
    im.TextDisabled(ctx, "delim:")
    im.SameLine(ctx, 0, 4)
    im.TextColored(ctx, 0x888888FF, settings.delimiter)
    im.SameLine(ctx, 0, 8)
    im.TextDisabled(ctx, "|")
    im.SameLine(ctx, 0, 8)

    local swap_a, swap_b, remove_idx = nil, nil, nil
    for i, s in ipairs(batch.sections) do
        im.PushID(ctx, bid .. "strip_" .. i)

        local badge_color = s.type == "shared" and 0x1A3A1AFF or 0x1A2A3AFF
        local text_color  = s.type == "shared" and 0x88FF88FF or 0x88CCFFFF
        im.PushStyleColor(ctx, im.Col_Button,        badge_color)
        im.PushStyleColor(ctx, im.Col_ButtonHovered, badge_color + 0x00101000)
        im.PushStyleColor(ctx, im.Col_Text,          text_color)
        if im.SmallButton(ctx, s.type == "shared" and "S" or "I") then
            s.type = s.type == "shared" and "input" or "shared"
            if s.type == "input" then batch.shared_values[s.label] = nil end
            sync_batch_groups(batch)
        end
        im.PopStyleColor(ctx, 3)
        im.SameLine(ctx, 0, 3)

        im.SetNextItemWidth(ctx, 70)
        local buf_id = bid .. "strip_" .. i
        local rv_l, val_l = im.InputText(ctx, "##lbl", get_buf(buf_id, s.label))
        if rv_l then
            local old_label = s.label
            s.label = val_l
            input_buffers[buf_id] = val_l
            if batch.shared_values[old_label] ~= nil then
                batch.shared_values[val_l] = batch.shared_values[old_label]
                batch.shared_values[old_label] = nil
            end
            for _, g in ipairs(batch.groups) do
                if g[old_label] ~= nil then
                    g[val_l] = g[old_label]
                    g[old_label] = nil
                end
            end
        end
        im.SameLine(ctx, 0, 2)

        if i > 1 then
            if im.SmallButton(ctx, "<") then swap_a, swap_b = i, i - 1 end
        else
            im.SmallButton(ctx, " ")
        end
        im.SameLine(ctx, 0, 1)
        if i < #batch.sections then
            if im.SmallButton(ctx, ">") then swap_a, swap_b = i, i + 1 end
        else
            im.SmallButton(ctx, " ")
        end
        im.SameLine(ctx, 0, 2)

        im.PushStyleColor(ctx, im.Col_Text, 0xFF6666FF)
        if im.SmallButton(ctx, "x") then remove_idx = i end
        im.PopStyleColor(ctx)

        if i < #batch.sections then
            im.SameLine(ctx, 0, 4)
            im.TextColored(ctx, 0x666666FF, settings.delimiter)
            im.SameLine(ctx, 0, 4)
        end

        im.PopID(ctx)
    end

    if swap_a and swap_b then
        batch.sections[swap_a], batch.sections[swap_b] = batch.sections[swap_b], batch.sections[swap_a]
        local ba = bid .. "strip_" .. swap_a
        local bb = bid .. "strip_" .. swap_b
        input_buffers[ba], input_buffers[bb] = input_buffers[bb], input_buffers[ba]
    end
    if remove_idx then
        table.remove(batch.sections, remove_idx)
        for i2, s in ipairs(batch.sections) do
            input_buffers[bid .. "strip_" .. i2] = s.label
        end
        sync_batch_groups(batch)
    end

    im.SameLine(ctx, 0, 10)
    local at_limit = #batch.sections >= MAX_SECTIONS
    if at_limit then im.BeginDisabled(ctx) end
    if im.SmallButton(ctx, "+ section") then
        batch.sections[#batch.sections + 1] = { type = "input", label = "Name" }
        input_buffers[bid .. "strip_" .. #batch.sections] = "Name"
        sync_batch_groups(batch)
    end
    if at_limit then im.EndDisabled(ctx) end

    end -- strip_visible
    im.EndChild(ctx)
    im.PopStyleColor(ctx)

    -- ── TRACK LAYOUT ──────────────────────────────────────────────────────────
    im.SeparatorText(ctx, "Track Layout")

    local avail_lw = im.GetContentRegionAvail(ctx)
    local spinner_w = 30

    -- Spinners row
    im.SetNextItemWidth(ctx, spinner_w)
    local rv_g, val_g = im.InputInt(ctx, "##ng", batch.num_groups, 1, 1)
    if rv_g then
        batch.num_groups = math.max(1, math.min(MAX_GROUPS, val_g))
        sync_batch_groups(batch)
    end
    im.SameLine(ctx) im.Text(ctx, "Groups")

    im.SameLine(ctx, 0, 16)
    im.SetNextItemWidth(ctx, spinner_w)
    local rv_a, val_a = im.InputInt(ctx, "##na", batch.num_aux, 1, 1)
    if rv_a then batch.num_aux = math.max(0, math.min(MAX_AUX, val_a)) end
    im.SameLine(ctx) im.Text(ctx, "Aux")

    im.SameLine(ctx, 0, 16)
    im.SetNextItemWidth(ctx, spinner_w)
    local rv_au, val_au = im.InputInt(ctx, "##nau", batch.num_audio, 1, 1)
    if rv_au then batch.num_audio = math.max(0, math.min(MAX_CONTENT, val_au)) end
    im.SameLine(ctx) im.Text(ctx, "Audio")

    im.SameLine(ctx, 0, 16)
    im.SetNextItemWidth(ctx, spinner_w)
    local rv_mi, val_mi = im.InputInt(ctx, "##nmi", batch.num_midi, 1, 1)
    if rv_mi then batch.num_midi = math.max(0, math.min(MAX_CONTENT, val_mi)) end
    im.SameLine(ctx) im.Text(ctx, "MIDI")

    -- Preview toggle (right-aligned)
    local toggle_label = (batch.layout_preview_open ~= false) and "\xe2\x96\xbc Preview" or "\xe2\x96\xb6 Preview"
    im.SameLine(ctx, avail_lw - 60)
    if im.SmallButton(ctx, toggle_label) then
        batch.layout_preview_open = not (batch.layout_preview_open ~= false)
    end

    -- Collapsible diagram
    if batch.layout_preview_open ~= false then
        local COLOR_AUX   = 0xFFCC66FF
        local COLOR_AUDIO = 0x88CCFFFF
        local COLOR_MIDI  = 0xCC88FFFF

        im.PushStyleColor(ctx, im.Col_ChildBg, 0x1A1A2AFF)
        local diag_visible = im.BeginChild(ctx, "##layout_diagram_" .. bid, -1, 0, im.ChildFlags_AutoResizeY | im.ChildFlags_Border)
        if diag_visible then

        local preview_name = core.naming.ResolveGroupName(batch, 1)
        if preview_name == "" then preview_name = "(unnamed)" end

        if batch.num_groups > 1 then
            im.TextDisabled(ctx, "1 of " .. batch.num_groups .. " groups shown")
        end

        im.Text(ctx, "\xf0\x9f\x93\x81 " .. preview_name)

        local total   = batch.num_aux + batch.num_audio + batch.num_midi
        local printed = 0

        if total == 0 then
            im.SameLine(ctx, 0, 0) im.NewLine(ctx)
            im.TextDisabled(ctx, "  (no child tracks configured)")
        end

        for a = 1, batch.num_aux do
            printed = printed + 1
            local is_last = printed == total
            local prefix  = is_last and "\xe2\x94\x94\xe2\x94\x80 " or "\xe2\x94\x9c\xe2\x94\x80 "
            -- SameLine+NewLine: flush pending same-line state and advance cursor row
            im.SameLine(ctx, 0, 0) im.NewLine(ctx)
            im.TextColored(ctx, COLOR_AUX, prefix .. "Aux_" .. a)
        end

        local send_label = ""
        if batch.num_aux > 0 then
            local parts = {}
            for a = 1, math.min(batch.num_aux, 3) do parts[#parts+1] = "Aux_" .. a end
            if batch.num_aux > 3 then parts[#parts+1] = "..." end
            send_label = "  \xe2\x86\x92 " .. table.concat(parts, ", ")
        end

        for c = 1, batch.num_audio + batch.num_midi do
            printed = printed + 1
            local is_last = printed == total
            local prefix  = is_last and "\xe2\x94\x94\xe2\x94\x80 " or "\xe2\x94\x9c\xe2\x94\x80 "
            local color   = c <= batch.num_audio and COLOR_AUDIO or COLOR_MIDI
            local ltype   = c <= batch.num_audio and "Audio " or "MIDI "
            local idx     = c <= batch.num_audio and c or (c - batch.num_audio)
            im.SameLine(ctx, 0, 0) im.NewLine(ctx)
            im.TextColored(ctx, color, prefix .. ltype .. idx)
            if send_label ~= "" then
                im.SameLine(ctx, 0, 0)
                im.TextDisabled(ctx, send_label)
            end
        end

        local track_total = (batch.num_aux + batch.num_audio + batch.num_midi) * batch.num_groups
        local group_word  = batch.num_groups == 1 and "group" or "groups"
        im.Spacing(ctx)
        im.TextDisabled(ctx, "\xc3\x97 " .. batch.num_groups .. " " .. group_word .. " \xc2\xb7 " .. track_total .. " tracks total")

        end -- diag_visible
        im.EndChild(ctx)
        im.PopStyleColor(ctx)
    end

    -- ── GROUPS ─────────────────────────────────────────────────────────────────
    im.SeparatorText(ctx, "Groups")

    local col_count  = 1 + #batch.sections + 1  -- # + sections + Preview
    local tbl_flags  = im.TableFlags_Borders | im.TableFlags_RowBg | im.TableFlags_ScrollY
    local tbl_h      = math.min(batch.num_groups * 26 + 26, 260)
    local settings_l = core.settings.Load()

    if im.BeginTable(ctx, "##groups_" .. bid, col_count, tbl_flags, 0, tbl_h) then

        im.TableSetupColumn(ctx, "#",       im.TableColumnFlags_WidthFixed,   24)
        for _, s in ipairs(batch.sections) do
            im.TableSetupColumn(ctx, s.label, im.TableColumnFlags_WidthFixed, 140)
        end
        im.TableSetupColumn(ctx, "Preview", im.TableColumnFlags_WidthStretch)

        -- Custom header row with colored badges
        im.TableNextRow(ctx, im.TableRowFlags_Headers)
        im.TableNextColumn(ctx)
        im.Text(ctx, "#")
        for _, s in ipairs(batch.sections) do
            im.TableNextColumn(ctx)
            local col = s.type == "shared" and 0x88FF88FF or 0x88CCFFFF
            im.TextColored(ctx, col, s.label)
            im.SameLine(ctx, 0, 4)
            im.PushStyleColor(ctx, im.Col_Text, col)
            im.SmallButton(ctx, s.type == "shared" and "shared" or "input")
            im.PopStyleColor(ctx)
        end
        im.TableNextColumn(ctx)
        im.Text(ctx, "Preview")

        -- Data rows
        for gi = 1, batch.num_groups do
            im.TableNextRow(ctx)
            im.PushID(ctx, gi)

            -- Index column
            im.TableNextColumn(ctx)
            im.TextDisabled(ctx, tostring(gi))

            -- Section columns
            for _, s in ipairs(batch.sections) do
                im.TableNextColumn(ctx)

                if s.type == "shared" then
                    local buf_id = bid .. "sv_" .. s.label
                    local current = batch.shared_values[s.label] or ""
                    im.PushStyleColor(ctx, im.Col_FrameBg, 0x1A2A1AFF)
                    im.SetNextItemWidth(ctx, -1)
                    local rv, val = im.InputText(ctx, "##sv_" .. s.label, get_buf(buf_id, current))
                    if rv then
                        batch.shared_values[s.label] = val
                        input_buffers[buf_id] = val
                    end
                    im.PopStyleColor(ctx)
                else
                    local buf_id = bid .. "grp_" .. gi .. "_" .. s.label
                    im.SetNextItemWidth(ctx, -1)
                    local rv, val = im.InputText(ctx, "##" .. buf_id, get_buf(buf_id, batch.groups[gi][s.label] or ""))
                    if rv then
                        batch.groups[gi][s.label] = val
                        input_buffers[buf_id] = val
                    end
                end
            end

            -- Preview column
            im.TableNextColumn(ctx)
            local preview = core.naming.ResolveGroupName(batch, gi)
            if preview == "" or preview == settings_l.delimiter:rep(#batch.sections - 1) then
                im.TextDisabled(ctx, "(empty)")
            else
                im.TextColored(ctx, 0x4A9EFFFF, preview)
            end

            im.PopID(ctx)
        end

        im.EndTable(ctx)
    end
end

--------------------------------
-- --- MAIN LOOP ---
--------------------------------
local function Loop()
    if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
        ctx = im.CreateContext('Project Builder')
    end

    -- Styling
    im.PushStyleVar(ctx, im.StyleVar_FrameRounding, 4.0)
    im.PushStyleVar(ctx, im.StyleVar_WindowRounding, 8.0)
    im.PushStyleVar(ctx, im.StyleVar_ChildRounding, 4.0)
    im.PushStyleVar(ctx, im.StyleVar_GrabRounding, 4.0)
    im.PushStyleVar(ctx, im.StyleVar_ItemSpacing, 8, 8)
    im.PushStyleVar(ctx, im.StyleVar_FramePadding, 6, 4)

    im.SetNextWindowSize(ctx, 700, 500, im.Cond_FirstUseEver)
    local visible, open = im.Begin(ctx, "ajsfx Project Builder", true, WINDOW_FLAGS)

    if visible then
        -- Tab bar
        if im.BeginTabBar(ctx, "##batches", im.TabBarFlags_None) then
            for i, b in ipairs(batches) do
                local tab_label = "Batch " .. i .. " \xc2\xb7 " .. (b.preset_name ~= "" and b.preset_name or "?") .. "##tab" .. i
                local tab_flags = im.TabItemFlags_None
                local visible_tab, p_tab_open = im.BeginTabItem(ctx, tab_label, true, tab_flags)
                if not p_tab_open then
                    -- User clicked × on this tab — remove the batch
                    table.remove(batches, i)
                    if i < selected_batch then selected_batch = selected_batch - 1 end
                    if selected_batch > #batches then selected_batch = #batches end
                    if selected_batch < 1 then selected_batch = 0 end
                    if visible_tab then im.EndTabItem(ctx) end
                    im.EndTabBar(ctx)
                    goto continue_loop
                end
                if visible_tab then
                    selected_batch = i
                    draw_batch_config()
                    im.EndTabItem(ctx)
                end
            end
            -- Add Batch button as a non-closable tab
            if im.TabItemButton(ctx, "\xe2\x9e\x95 Add Batch", im.TabItemFlags_Trailing) then
                local preset = all_presets[1]
                batches[#batches + 1] = create_batch_from_preset(preset)
                selected_batch = #batches
            end
            im.EndTabBar(ctx)
        end

        -- Temporary buttons (will move to output panel in Task 9)
        im.Spacing(ctx)
        local avail_w = im.GetContentRegionAvail(ctx)
        local btn_w = 100
        im.SetCursorPosX(ctx, im.GetCursorPosX(ctx) + avail_w - (btn_w * 2 + 10))
        if im.Button(ctx, "Cancel", btn_w, 0) then open = false end
        im.SameLine(ctx)
        local can_generate = #batches > 0
        if not can_generate then im.BeginDisabled(ctx) end
        if im.Button(ctx, "Generate", btn_w, 0) then
            if generate_tracks(batches) then
                r.DeleteExtState(EXT_SECTION, "SESSION", true)
                open = false
            end
        end
        if not can_generate then im.EndDisabled(ctx) end

        ::continue_loop::
        im.End(ctx)
    end

    im.PopStyleVar(ctx, 6)

    if open then
        r.defer(Loop)
    else
        save_session(batches)
    end
end

r.defer(Loop)
