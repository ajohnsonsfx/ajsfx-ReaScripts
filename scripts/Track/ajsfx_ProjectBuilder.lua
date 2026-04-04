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
local EXT_SECTION = "ajsfx_ProjectBuilder"
local PRESETS_SECTION = "ajsfx_ProjectBuilder_Presets"
local MAX_PRESETS = 50
local MAX_GROUPS = 64
local MAX_AUX = 8
local MAX_CONTENT = 64
local MAX_SECTIONS = 16

local DEFAULT_PRESETS = {
    {
        name = "Standard Asset",
        delimiter = "_",
        sections = {
            { type = "shared", label = "Character" },
            { type = "input",  label = "Action" },
            { type = "shared", label = "Date" },
        }
    },
    {
        name = "VO Asset",
        delimiter = "_",
        sections = {
            { type = "shared", label = "Prefix" },
            { type = "input",  label = "Character" },
            { type = "shared", label = "Date" },
        }
    },
    {
        name = "Blank",
        delimiter = "_",
        sections = {
            { type = "input", label = "Name" },
        }
    },
}

--------------------------------
-- --- WILDCARD RESOLUTION ---
--------------------------------
local function resolve_wildcards(str)
    local proj_name = r.GetProjectName(0, "")
    proj_name = proj_name:match("(.+)%.[^.]+$") or proj_name -- strip extension

    -- Ordered longest-first to prevent $month matching inside $monthname
    local replacements = {
        { "monthname", os.date("%B") },
        { "computer",  os.getenv("COMPUTERNAME") or "" },
        { "project",   proj_name },
        { "author",    select(2, r.GetSetProjectAuthor(0, false, "")) or "" },
        { "minute",    os.date("%M") },
        { "hour12",    os.date("%I") },
        { "year2",     os.date("%y") },
        { "month",     os.date("%m") },
        { "year",      os.date("%Y") },
        { "hour",      os.date("%H") },
        { "user",      os.getenv("USERNAME") or os.getenv("USER") or "" },
        { "day",       os.date("%d") },
    }

    for _, rep in ipairs(replacements) do
        local pattern = "%$" .. rep[1]
        local escaped_value = rep[2]:gsub("%%", "%%%%")
        str = str:gsub(pattern, escaped_value)
    end
    return str
end

--------------------------------
-- --- NAME RESOLUTION ---
--------------------------------
local function resolve_group_name(batch, group_index)
    local parts = {}
    for _, section in ipairs(batch.sections) do
        local value
        if section.type == "shared" then
            value = batch.shared_values[section.label] or ""
        else
            value = (batch.groups[group_index] and batch.groups[group_index][section.label]) or ""
        end
        value = resolve_wildcards(value)
        parts[#parts + 1] = value
    end
    return table.concat(parts, batch.delimiter)
end

--------------------------------
-- --- PRESET PERSISTENCE ---
--------------------------------
local function is_default_preset(name)
    for _, dp in ipairs(DEFAULT_PRESETS) do
        if dp.name == name then return true end
    end
    return false
end

local function serialize_preset(preset)
    -- Format: delimiter|type:label|type:label|...
    local parts = { preset.delimiter }
    for _, s in ipairs(preset.sections) do
        parts[#parts + 1] = s.type .. ":" .. s.label
    end
    return table.concat(parts, "|")
end

local function deserialize_preset(name, str)
    local parts = {}
    for part in str:gmatch("[^|]+") do
        parts[#parts + 1] = part
    end
    if #parts < 1 then return nil end

    local preset = {
        name = name,
        delimiter = parts[1],
        sections = {}
    }
    for i = 2, #parts do
        local stype, label = parts[i]:match("^(%w+):(.+)$")
        if stype and label then
            preset.sections[#preset.sections + 1] = { type = stype, label = label }
        end
    end
    return preset
end

local function load_all_presets()
    local presets = {}
    -- Load defaults first
    for _, dp in ipairs(DEFAULT_PRESETS) do
        presets[#presets + 1] = {
            name = dp.name,
            delimiter = dp.delimiter,
            sections = {}
        }
        for _, s in ipairs(dp.sections) do
            presets[#presets].sections[#presets[#presets].sections + 1] = { type = s.type, label = s.label }
        end
    end

    -- Load custom presets
    if r.HasExtState(PRESETS_SECTION, "LIST") then
        local list_str = r.GetExtState(PRESETS_SECTION, "LIST")
        for name in list_str:gmatch("[^|]+") do
            if name ~= "" and not is_default_preset(name) then
                local key = "P_" .. name
                if r.HasExtState(PRESETS_SECTION, key) then
                    local p = deserialize_preset(name, r.GetExtState(PRESETS_SECTION, key))
                    if p then
                        presets[#presets + 1] = p
                        if #presets >= MAX_PRESETS then break end
                    end
                end
            end
        end
    end
    return presets
end

local function save_custom_presets(presets)
    -- Build list of custom preset names
    local names = {}
    for _, p in ipairs(presets) do
        if not is_default_preset(p.name) then
            names[#names + 1] = p.name
            r.SetExtState(PRESETS_SECTION, "P_" .. p.name, serialize_preset(p), true)
        end
    end
    r.SetExtState(PRESETS_SECTION, "LIST", table.concat(names, "|"), true)
end

local function delete_custom_preset(presets, name)
    if is_default_preset(name) then return presets end
    local new = {}
    for _, p in ipairs(presets) do
        if p.name ~= name then
            new[#new + 1] = p
        end
    end
    r.DeleteExtState(PRESETS_SECTION, "P_" .. name, true)
    save_custom_presets(new)
    return new
end

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
        preset_name = preset.name,
        delimiter = preset.delimiter,
        sections = deep_copy_sections(preset.sections),
        shared_values = {},
        num_groups = 1,
        num_aux = 1,
        num_audio = 4,
        num_midi = 0,
        groups = {},
    }
    -- Initialize groups with empty input values
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
            b.delimiter,
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

        if parts[1] == "BATCH" and #parts >= 6 then
            current = {
                preset_name = parts[2],
                delimiter = parts[3],
                sections = {},
                shared_values = {},
                num_groups = tonumber(parts[4]) or 1,
                num_aux = tonumber(parts[5]) or 1,
                num_audio = tonumber(parts[6]) or 4,
                num_midi = tonumber(parts[7]) or 0,
                groups = {},
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
    if #batches == 0 then return false, "No batches configured." end
    for bi, batch in ipairs(batches) do
        if #batch.sections == 0 then
            return false, "Batch " .. bi .. " has no name sections."
        end
        for gi = 1, batch.num_groups do
            local name = resolve_group_name(batch, gi)
            if name == "" or name == batch.delimiter:rep(#batch.sections - 1) then
                return false, "Batch " .. bi .. ", Group " .. gi .. ": name resolves to empty.\nPlease fill in all sections."
            end
        end
    end

    -- Warn if $project used on unsaved project
    local proj_name = r.GetProjectName(0, "")
    if proj_name == "" then
        for _, batch in ipairs(batches) do
            for _, s in ipairs(batch.sections) do
                local label = s.label
                local value
                if s.type == "shared" then
                    value = batch.shared_values[label] or ""
                else
                    for gi = 1, batch.num_groups do
                        value = (batch.groups[gi] and batch.groups[gi][label]) or ""
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
                local group_name = resolve_group_name(batch, g)

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

local all_presets = load_all_presets()
local batches = load_session() or {}
local selected_batch = #batches > 0 and 1 or 0

-- Preset editor state
local editing_preset = nil -- nil = not editing, table = the preset being edited
local edit_new_preset_name = ""
local edit_is_new = false

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
-- --- PRESET EDITOR UI ---
--------------------------------
local function draw_preset_editor()
    if not editing_preset then return false end

    local open = true
    local title = edit_is_new and "New Preset" or ("Edit Preset: " .. editing_preset.name)

    im.SetNextWindowSize(ctx, 400, 0, im.Cond_Appearing)
    local visible, p_open = im.Begin(ctx, title .. "###preset_editor", true, im.WindowFlags_AlwaysAutoResize)
    if not visible then
        if not p_open then editing_preset = nil end
        return editing_preset ~= nil
    end

    if not p_open then
        editing_preset = nil
        im.End(ctx)
        return false
    end

    -- Preset name (only for new presets)
        if edit_is_new then
            local rv, val = im.InputText(ctx, "Preset Name", get_buf("pe_name", edit_new_preset_name))
            if rv then
                edit_new_preset_name = val
                input_buffers["pe_name"] = val
            end
            im.Spacing(ctx)
        end

        -- Delimiter
        local rv_d, val_d = im.InputText(ctx, "Delimiter", get_buf("pe_delim", editing_preset.delimiter))
        if rv_d then
            editing_preset.delimiter = val_d
            input_buffers["pe_delim"] = val_d
        end

        im.Spacing(ctx)
        im.SeparatorText(ctx, "Sections")

        -- Section list
        local remove_idx = nil
        local swap_a, swap_b = nil, nil

        for i, s in ipairs(editing_preset.sections) do
            im.PushID(ctx, i)

            -- Type dropdown
            im.SetNextItemWidth(ctx, 80)
            if im.BeginCombo(ctx, "##type", s.type) then
                if im.Selectable(ctx, "shared", s.type == "shared") then s.type = "shared" end
                if im.Selectable(ctx, "input", s.type == "input") then s.type = "input" end
                im.EndCombo(ctx)
            end

            im.SameLine(ctx)

            -- Label
            im.SetNextItemWidth(ctx, 150)
            local buf_id = "pe_sec_" .. i
            local rv_l, val_l = im.InputText(ctx, "##label", get_buf(buf_id, s.label))
            if rv_l then
                s.label = val_l
                input_buffers[buf_id] = val_l
            end

            im.SameLine(ctx)

            -- Move up
            if i > 1 then
                if im.SmallButton(ctx, "^") then swap_a, swap_b = i, i - 1 end
            else
                im.SmallButton(ctx, " ")
            end

            im.SameLine(ctx)

            -- Move down
            if i < #editing_preset.sections then
                if im.SmallButton(ctx, "v") then swap_a, swap_b = i, i + 1 end
            else
                im.SmallButton(ctx, " ")
            end

            im.SameLine(ctx)

            -- Delete
            if im.SmallButton(ctx, "x") then remove_idx = i end

            im.PopID(ctx)
        end

        -- Apply moves/removes
        if swap_a and swap_b then
            editing_preset.sections[swap_a], editing_preset.sections[swap_b] =
                editing_preset.sections[swap_b], editing_preset.sections[swap_a]
            -- Swap buffers too
            local ba = "pe_sec_" .. swap_a
            local bb = "pe_sec_" .. swap_b
            input_buffers[ba], input_buffers[bb] = input_buffers[bb], input_buffers[ba]
        end
        if remove_idx then
            table.remove(editing_preset.sections, remove_idx)
            -- Rebuild section buffers
            for i, s in ipairs(editing_preset.sections) do
                input_buffers["pe_sec_" .. i] = s.label
            end
        end

        im.Spacing(ctx)
        if im.Button(ctx, "+ Add Section") and #editing_preset.sections < MAX_SECTIONS then
            editing_preset.sections[#editing_preset.sections + 1] = { type = "shared", label = "" }
            input_buffers["pe_sec_" .. #editing_preset.sections] = ""
        end

        im.Spacing(ctx)
        im.Separator(ctx)
        im.Spacing(ctx)

        -- Save / Cancel
        local can_save = #editing_preset.sections > 0
        if edit_is_new then
            can_save = can_save and edit_new_preset_name ~= "" and not is_default_preset(edit_new_preset_name)
        end

        if not can_save then im.BeginDisabled(ctx) end
        if im.Button(ctx, "Save") then
            if edit_is_new then
                editing_preset.name = edit_new_preset_name
                -- Check for duplicate names
                local dupe = false
                for _, p in ipairs(all_presets) do
                    if p.name == editing_preset.name then dupe = true; break end
                end
                if not dupe then
                    all_presets[#all_presets + 1] = editing_preset
                end
            else
                -- Update existing
                for i, p in ipairs(all_presets) do
                    if p.name == editing_preset.name then
                        all_presets[i] = editing_preset
                        break
                    end
                end
            end
            save_custom_presets(all_presets)
            editing_preset = nil
        end
        if not can_save then im.EndDisabled(ctx) end

        im.SameLine(ctx)
        if im.Button(ctx, "Cancel") then
            editing_preset = nil
        end
    im.End(ctx)
    return editing_preset ~= nil
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

local function draw_batch_list()
    im.BeginChild(ctx, "batch_list", 200, -30, 1)
    im.SeparatorText(ctx, "Batches")

    local remove_idx = nil
    for i, b in ipairs(batches) do
        local display = b.preset_name
        if display == "" then display = "Batch " .. i end

        im.PushID(ctx, i)
        if im.Selectable(ctx, display, selected_batch == i) then
            selected_batch = i
        end
        im.SameLine(ctx)
        if im.SmallButton(ctx, "x") then
            remove_idx = i
        end
        im.PopID(ctx)
    end

    if remove_idx then
        table.remove(batches, remove_idx)
        if selected_batch > #batches then selected_batch = #batches end
        if selected_batch < 1 and #batches > 0 then selected_batch = 1 end
    end

    im.Spacing(ctx)
    if im.Button(ctx, "+ Add Batch", -1, 0) then
        local preset = all_presets[1] -- default to first preset
        batches[#batches + 1] = create_batch_from_preset(preset)
        selected_batch = #batches
    end

    im.EndChild(ctx)
end

local function draw_batch_config()
    im.BeginChild(ctx, "batch_config", 0, -30, 1)

    if selected_batch < 1 or selected_batch > #batches then
        im.TextDisabled(ctx, "Select or add a batch to configure.")
        im.EndChild(ctx)
        return
    end

    local batch = batches[selected_batch]
    local bid = "b" .. selected_batch .. "_"

    -- Preset selector
    im.SeparatorText(ctx, "Name Preset")

    -- Calculate widths for full-width layout
    local avail_w = im.GetContentRegionAvail(ctx)
    local has_delete = not is_default_preset(batch.preset_name)
    local num_btns = has_delete and 3 or 2
    -- Get style items correctly, in reaper-imgui we need to extract them or just hardcode/use reasonable defaults
    local item_spacing_x = 8 -- typical default
    local btn_w = 40
    local btns_total_w = (btn_w * num_btns) + (item_spacing_x * num_btns)
    local combo_w = avail_w - btns_total_w

    im.SetNextItemWidth(ctx, combo_w)
    if im.BeginCombo(ctx, "##PresetCombo", batch.preset_name) then
        for _, p in ipairs(all_presets) do
            local is_selected = batch.preset_name == p.name
            if im.Selectable(ctx, p.name .. "##" .. p.name, is_selected) then
                batch.preset_name = p.name
                batch.delimiter = p.delimiter
                batch.sections = deep_copy_sections(p.sections)
                batch.shared_values = {}
                for k, _ in pairs(input_buffers) do
                    if k:find("^" .. bid) then input_buffers[k] = nil end
                end
                sync_batch_groups(batch)
            end
            
            im.SameLine(ctx, 150)
            draw_preset_layout(ctx, p.sections, p.delimiter)
        end
        im.EndCombo(ctx)
    end

    im.SameLine(ctx)
    if im.Button(ctx, "Edit", btn_w, 0) then
        for _, p in ipairs(all_presets) do
            if p.name == batch.preset_name then
                editing_preset = {
                    name = p.name,
                    delimiter = p.delimiter,
                    sections = deep_copy_sections(p.sections),
                }
                edit_is_new = false
                input_buffers["pe_delim"] = p.delimiter
                for i, s in ipairs(editing_preset.sections) do
                    input_buffers["pe_sec_" .. i] = s.label
                end
                break
            end
        end
    end

    im.SameLine(ctx)
    if im.Button(ctx, "New", btn_w, 0) then
        editing_preset = {
            name = "",
            delimiter = "_",
            sections = { { type = "shared", label = "" } },
        }
        edit_is_new = true
        edit_new_preset_name = ""
        input_buffers["pe_name"] = ""
        input_buffers["pe_delim"] = "_"
        input_buffers["pe_sec_1"] = ""
    end

    if has_delete then
        im.SameLine(ctx)
        if im.Button(ctx, "Delete", btn_w, 0) then
            all_presets = delete_custom_preset(all_presets, batch.preset_name)
            local p = all_presets[1]
            batch.preset_name = p.name
            batch.delimiter = p.delimiter
            batch.sections = deep_copy_sections(p.sections)
            batch.shared_values = {}
            sync_batch_groups(batch)
        end
    end

    im.Spacing(ctx)
    im.Spacing(ctx)
    im.SeparatorText(ctx, "Layout")

    -- Row 1: Root Node (Groups & Naming)
    local draw_list = im.GetWindowDrawList(ctx)
    local root_x, root_y = im.GetCursorScreenPos(ctx)

    im.BeginGroup(ctx)
    -- Align "Format:" with the "Groups" text (Input width 26 + default ItemSpacing 8)
    local c_x = im.GetCursorPosX(ctx)
    im.SetCursorPosX(ctx, c_x + 34)
    im.TextDisabled(ctx, "Format:")
    
    im.SetCursorPosX(ctx, c_x)
    im.SetNextItemWidth(ctx, 26)
    local rv_g, val_g = im.InputInt(ctx, "##num_groups", batch.num_groups, 0, 0)
    if rv_g then
        batch.num_groups = math.max(1, math.min(MAX_GROUPS, val_g))
        sync_batch_groups(batch)
    end
    -- Capture coordinates for the hierarchy line exactly at the vertical center of this InputInt
    local _, root_item_y_min = im.GetItemRectMin(ctx)
    local _, root_item_y_max = im.GetItemRectMax(ctx)
    local root_y_center = (root_item_y_min + root_item_y_max) / 2
    
    im.SameLine(ctx)
    im.Text(ctx, "Groups")
    im.EndGroup(ctx)
    
    im.SameLine(ctx, 0, 30)
    
    for i, s in ipairs(batch.sections) do
        im.PushID(ctx, "fmt_" .. i)
        
        im.BeginGroup(ctx)
        -- Label Row
        local color = s.type == "shared" and COLOR_SHARED or COLOR_INPUT
        im.TextColored(ctx, color, "[" .. s.label .. "]")
        
        -- Input Row
        if s.type == "shared" then
            im.SetNextItemWidth(ctx, 80)
            local buf_id = bid .. "sv_" .. s.label
            local rv, val = im.InputText(ctx, "##" .. s.label, get_buf(buf_id, batch.shared_values[s.label] or ""))
            if rv then
                batch.shared_values[s.label] = val
                input_buffers[buf_id] = val
            end
        else
            -- No input box, just an empty space that aligns with the visual row height
            -- Let's give it a consistent width, and ensure it respects the vertical layout
            im.Dummy(ctx, 70, 22)
        end
        im.EndGroup(ctx)
        
        if i < #batch.sections then
            im.SameLine(ctx, 0, 4)
            im.BeginGroup(ctx)
            im.Dummy(ctx, 1, 22) -- vertical spacer to push character down
            im.TextColored(ctx, COLOR_DELIM, batch.delimiter)
            im.EndGroup(ctx)
            im.SameLine(ctx, 0, 4)
        end
        im.PopID(ctx)
    end

    -- Child Nodes (indented)
    im.Indent(ctx, 30)
    im.Spacing(ctx)
    
    local aux_x, aux_y = im.GetCursorScreenPos(ctx)
    im.SetNextItemWidth(ctx, 26)
    local rv_a, val_a = im.InputInt(ctx, "##num_aux", batch.num_aux, 0, 0)
    if rv_a then batch.num_aux = math.max(0, math.min(MAX_AUX, val_a)) end
    im.SameLine(ctx)
    im.Text(ctx, "FX Aux Tracks")
    local aux_r_min_x, aux_r_min_y = im.GetItemRectMin(ctx)
    local aux_r_max_x, aux_r_max_y = im.GetItemRectMax(ctx)
    
    local aud_x, aud_y = im.GetCursorScreenPos(ctx)
    im.SetNextItemWidth(ctx, 26)
    local rv_au, val_au = im.InputInt(ctx, "##num_audio", batch.num_audio, 0, 0)
    if rv_au then batch.num_audio = math.max(0, math.min(MAX_CONTENT, val_au)) end
    im.SameLine(ctx)
    im.Text(ctx, "Audio Tracks")
    local aud_r_min_x, aud_r_min_y = im.GetItemRectMin(ctx)
    local aud_r_max_x, aud_r_max_y = im.GetItemRectMax(ctx)
    
    local mid_x, mid_y = im.GetCursorScreenPos(ctx)
    im.SetNextItemWidth(ctx, 26)
    local rv_mi, val_mi = im.InputInt(ctx, "##num_midi", batch.num_midi, 0, 0)
    if rv_mi then batch.num_midi = math.max(0, math.min(MAX_CONTENT, val_mi)) end
    im.SameLine(ctx)
    im.Text(ctx, "MIDI Tracks")
    local mid_r_min_x, mid_r_min_y = im.GetItemRectMin(ctx)
    local mid_r_max_x, mid_r_max_y = im.GetItemRectMax(ctx)

    im.Unindent(ctx, 30)

    -- Drawing Custom Hierarchy and Routing Lines
    local HIER_COLOR = 0xFFFFFF88 
    local ROUTE_COLOR = 0xEE77EEAA
    local line_thick = 3.0
    
    -- Node centers
    local h_line_x = aux_x - 15  -- Place the line within the indentation gap
    local h_start_y = root_y_center
    local aux_mid_y = (aux_r_min_y + aux_r_max_y) / 2
    local aud_mid_y = (aud_r_min_y + aud_r_max_y) / 2
    local mid_mid_y = (mid_r_min_y + mid_r_max_y) / 2
    
    -- Main vertical stem and branches
    im.DrawList_AddLine(draw_list, h_line_x, h_start_y, h_line_x, mid_mid_y, HIER_COLOR, line_thick)
    im.DrawList_AddLine(draw_list, h_line_x, aux_mid_y, aux_x - 4, aux_mid_y, HIER_COLOR, line_thick)
    im.DrawList_AddLine(draw_list, h_line_x, aud_mid_y, aud_x - 4, aud_mid_y, HIER_COLOR, line_thick)
    im.DrawList_AddLine(draw_list, h_line_x, mid_mid_y, mid_x - 4, mid_mid_y, HIER_COLOR, line_thick)

    -- Group input sections table
    local input_sections = {}
    for _, s in ipairs(batch.sections) do
        if s.type == "input" then
            input_sections[#input_sections + 1] = s
        end
    end

    if #input_sections > 0 then
        im.Spacing(ctx)
        im.SeparatorText(ctx, "Groups")

        -- Column count: # + input sections + preview
        local col_count = 1 + #input_sections + 1
        if im.BeginTable(ctx, "groups_table", col_count, im.TableFlags_Borders + im.TableFlags_RowBg + im.TableFlags_ScrollY, 0, math.min(batch.num_groups * 28 + 28, 300)) then
            -- Headers
            im.TableSetupColumn(ctx, "#", im.TableColumnFlags_WidthFixed, 30)
            for _, s in ipairs(input_sections) do
                im.TableSetupColumn(ctx, s.label, im.TableColumnFlags_WidthFixed, 160)
            end
            im.TableSetupColumn(ctx, "Preview", im.TableColumnFlags_WidthStretch)
            im.TableHeadersRow(ctx)

            for gi = 1, batch.num_groups do
                im.TableNextRow(ctx)
                im.PushID(ctx, gi)

                -- Index
                im.TableNextColumn(ctx)
                im.Text(ctx, tostring(gi))

                -- Input fields
                for _, s in ipairs(input_sections) do
                    im.TableNextColumn(ctx)
                    local buf_id = bid .. "grp_" .. gi .. "_" .. s.label
                    im.SetNextItemWidth(ctx, -1)
                    local rv, val = im.InputText(ctx, "##" .. s.label, get_buf(buf_id, batch.groups[gi][s.label] or ""))
                    if rv then
                        batch.groups[gi][s.label] = val
                        input_buffers[buf_id] = val
                    end
                end

                -- Preview
                im.TableNextColumn(ctx)
                local preview = resolve_group_name(batch, gi)
                im.TextDisabled(ctx, preview)

                im.PopID(ctx)
            end

            im.EndTable(ctx)
        end
    else
        -- No input sections — just show preview
        im.Spacing(ctx)
        im.SeparatorText(ctx, "Preview")
        for gi = 1, math.min(batch.num_groups, 8) do
            local preview = resolve_group_name(batch, gi)
            im.TextDisabled(ctx, tostring(gi) .. ": " .. preview)
        end
        if batch.num_groups > 8 then
            im.TextDisabled(ctx, "... and " .. (batch.num_groups - 8) .. " more")
        end
    end

    im.EndChild(ctx)
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
        -- Two-column layout
        draw_batch_list()
        im.SameLine(ctx)
        draw_batch_config()

        -- Bottom buttons
        im.Spacing(ctx)
        local avail_w = im.GetContentRegionAvail(ctx)

        -- Right-align buttons
        local btn_w = 100
        local spacing = 10
        im.SetCursorPosX(ctx, im.GetCursorPosX(ctx) + avail_w - (btn_w * 2 + spacing))

        if im.Button(ctx, "Cancel", btn_w, 0) then
            open = false
        end
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
        im.End(ctx)
    end

    -- Draw preset editor (separate window)
    draw_preset_editor()
    
    im.PopStyleVar(ctx, 6)

    if open then
        r.defer(Loop)
    else
        save_session(batches)
    end
end

r.defer(Loop)
