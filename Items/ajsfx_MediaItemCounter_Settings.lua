-- @description Media Item Counter Settings
-- @author ajsfx
-- @version 1.2
-- @about Settings panel for ajsfx_MediaItemCounter
-- @provides
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

local ctx = im.CreateContext('Item Counter Settings')

--------------------------------
-- --- CONSTANTS & DEFAULTS ---
--------------------------------
local EXT_SECTION = "ajsfx_MediaItemCounter"
local PRESETS_SECTION = "ajsfx_MediaItemCounter_Presets"
local DEFAULT_CONFIG = core.MEDIA_COUNTER_DEFAULTS

--------------------------------
-- --- CONFIG & PRESETS ---
--------------------------------
local function CloneConfig(src)
    return {
        FONT_SIZE = src.FONT_SIZE,
        FONT_NAME = src.FONT_NAME,
        TEXT_COLOR = src.TEXT_COLOR,
        HORIZONTAL_OFFSET = src.HORIZONTAL_OFFSET,
        VERTICAL_ALIGN = src.VERTICAL_ALIGN,
        H_ALIGN = src.H_ALIGN or 0,
        REFRESH_RATE = src.REFRESH_RATE or 30
    }
end

local function SaveConfig(cfg)
    r.SetExtState(EXT_SECTION, "FONT_SIZE", tostring(cfg.FONT_SIZE), true)
    r.SetExtState(EXT_SECTION, "TEXT_COLOR", tostring(cfg.TEXT_COLOR), true)
    r.SetExtState(EXT_SECTION, "HORIZONTAL_OFFSET", tostring(cfg.HORIZONTAL_OFFSET), true)
    r.SetExtState(EXT_SECTION, "VERTICAL_ALIGN", tostring(cfg.VERTICAL_ALIGN), true)
    r.SetExtState(EXT_SECTION, "H_ALIGN", tostring(cfg.H_ALIGN), true)
    r.SetExtState(EXT_SECTION, "REFRESH_RATE", tostring(cfg.REFRESH_RATE), true)
end

local Config = core.LoadMediaCounterConfig()

-- PRESETS
local preset_names = {"Default"}
local custom_presets = {} -- {name: {config}}
local current_preset_idx = 0
local new_preset_name = ""

local MAX_PRESETS = 100 -- Safety limit to prevent runaway loading

local function LoadPresets()
    preset_names = {"Default"}
    custom_presets = {}

    if r.HasExtState(PRESETS_SECTION, "LIST") then
        local list_str = r.GetExtState(PRESETS_SECTION, "LIST")
        for name in list_str:gmatch("[^|]+") do
            if name ~= "" and name ~= "Default" then
                if #preset_names >= MAX_PRESETS then
                    core.Print("Warning: Preset limit reached (" .. MAX_PRESETS .. "), skipping remaining presets.")
                    break
                end

                local ok, preset = pcall(function()
                    local data_str = r.GetExtState(PRESETS_SECTION, "P_" .. name)
                    if not data_str or data_str == "" then return nil end

                    local p_fs, p_tc, p_ho, p_va, p_ha, p_rr = data_str:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
                    if not p_rr then
                        p_fs, p_tc, p_ho, p_va, p_ha = data_str:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
                        p_rr = "30"
                    end
                    if not p_ha then -- fallback for older presets
                        p_fs, p_tc, p_ho, p_va = data_str:match("([^,]+),([^,]+),([^,]+),([^,]+)")
                        p_ha = "0"
                        p_rr = "30"
                    end
                    if not (p_fs and p_tc and p_ho and p_va and p_ha and p_rr) then return nil end

                    local fs = tonumber(p_fs)
                    local tc = tonumber(p_tc)
                    local ho = tonumber(p_ho)
                    local va = tonumber(p_va)
                    local ha = tonumber(p_ha)
                    local rr = tonumber(p_rr)
                    if not (fs and tc and ho and va and ha and rr) then return nil end

                    return {
                        FONT_SIZE = fs,
                        FONT_NAME = DEFAULT_CONFIG.FONT_NAME,
                        TEXT_COLOR = tc,
                        HORIZONTAL_OFFSET = ho,
                        VERTICAL_ALIGN = va,
                        H_ALIGN = ha,
                        REFRESH_RATE = rr
                    }
                end)

                if ok and preset then
                    custom_presets[name] = preset
                    table.insert(preset_names, name)
                elseif not ok then
                    core.Print("Warning: Failed to load preset '" .. name .. "': " .. tostring(preset))
                end
            end
        end
    end
end

local function SavePresetsList()
    local list_str = "Default|"
    for _, name in ipairs(preset_names) do
        if name ~= "Default" then
            list_str = list_str .. name .. "|"
        end
    end
    r.SetExtState(PRESETS_SECTION, "LIST", list_str, true)
end

local function SavePreset(name, cfg)
    if name == "Default" or name == "" then return end
    
    if not custom_presets[name] then
        table.insert(preset_names, name)
    end
    
    custom_presets[name] = CloneConfig(cfg)
    local data_str = string.format("%d,%d,%d,%f,%d,%d", cfg.FONT_SIZE, cfg.TEXT_COLOR, cfg.HORIZONTAL_OFFSET, cfg.VERTICAL_ALIGN, cfg.H_ALIGN, cfg.REFRESH_RATE)
    r.SetExtState(PRESETS_SECTION, "P_" .. name, data_str, true)
    
    SavePresetsList()
    
    -- find new index
    for i, p_name in ipairs(preset_names) do
        if p_name == name then
            current_preset_idx = i - 1
            break
        end
    end
end

local function DeletePreset(name)
    if name == "Default" or not custom_presets[name] then return end
    
    custom_presets[name] = nil
    r.DeleteExtState(PRESETS_SECTION, "P_" .. name, true)
    
    for i, p_name in ipairs(preset_names) do
        if p_name == name then
            table.remove(preset_names, i)
            break
        end
    end
    
    SavePresetsList()
    current_preset_idx = 0 -- Reset to Default
end

LoadPresets()

--------------------------------

-- Double Click to Reset Helpers
local function CheckDoubleClickReset(default_val, current_val)
    -- im.IsItemHovered checks the bounding box of the last drawn item (which includes the slider AND label)
    if im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, 0) then
        return true, default_val
    end
    return false, current_val
end

function loop()
    if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
        ctx = im.CreateContext('Item Counter Settings')
    end

    im.SetNextWindowSize(ctx, 350, 360, im.Cond_FirstUseEver)
    local visible, open = im.Begin(ctx, 'Item Counter Settings', true)
    
    if visible then
        local changed = false
        
        -- PRESETS UI
        im.Text(ctx, "Presets:")
        im.SameLine(ctx)
        
        local combo_items = ""
        for _, name in ipairs(preset_names) do
            combo_items = combo_items .. name .. "\0"
        end
        combo_items = combo_items .. "\0"
        
        local preset_changed, new_idx = im.Combo(ctx, "##presets", current_preset_idx, combo_items)
        if preset_changed then
            current_preset_idx = new_idx
            local selected_name = preset_names[current_preset_idx + 1]
            if selected_name == "Default" then
                Config = CloneConfig(DEFAULT_CONFIG)
            elseif custom_presets[selected_name] then
                Config = CloneConfig(custom_presets[selected_name])
            end
            changed = true
        end
        
        local selected_name = preset_names[current_preset_idx + 1]
        
        local rv_input, new_name = im.InputText(ctx, "Name", new_preset_name)
        if rv_input then new_preset_name = new_name end
        
        im.SameLine(ctx)
        if im.Button(ctx, "Save") and new_preset_name ~= "" and new_preset_name ~= "Default" then
            SavePreset(new_preset_name, Config)
            new_preset_name = ""
        end
        
        if selected_name ~= "Default" then
            im.SameLine(ctx)
            if im.Button(ctx, "Delete") then
                DeletePreset(selected_name)
                Config = CloneConfig(DEFAULT_CONFIG)
                changed = true
            end
        end
        
        im.Separator(ctx)
        
        -- SETTINGS UI
        im.TextDisabled(ctx, "(Double-click a slider/color to reset to default)")
        im.Spacing(ctx)
        
        local rv_fs, new_font_size = im.SliderInt(ctx, "Font Size", Config.FONT_SIZE, 8, 36)
        if rv_fs then Config.FONT_SIZE = new_font_size; changed = true end
        local reset_fs, r_val_fs = CheckDoubleClickReset(DEFAULT_CONFIG.FONT_SIZE, Config.FONT_SIZE)
        if reset_fs then Config.FONT_SIZE = r_val_fs; changed = true end
        
        local rv_ho, new_h_offset = im.SliderInt(ctx, "Horizontal Offset", Config.HORIZONTAL_OFFSET, -500, 500)
        if rv_ho then Config.HORIZONTAL_OFFSET = new_h_offset; changed = true end
        local reset_ho, r_val_ho = CheckDoubleClickReset(DEFAULT_CONFIG.HORIZONTAL_OFFSET, Config.HORIZONTAL_OFFSET)
        if reset_ho then Config.HORIZONTAL_OFFSET = r_val_ho; changed = true end
        
        local rv_va, new_v_align = im.SliderDouble(ctx, "Vertical Align", Config.VERTICAL_ALIGN, 0.0, 1.0, "%.2f")
        if rv_va then Config.VERTICAL_ALIGN = new_v_align; changed = true end
        local reset_va, r_val_va = CheckDoubleClickReset(DEFAULT_CONFIG.VERTICAL_ALIGN, Config.VERTICAL_ALIGN)
        if reset_va then Config.VERTICAL_ALIGN = r_val_va; changed = true end
        
        local rv_ha, new_h_align = im.Combo(ctx, "Horizontal Anchor", Config.H_ALIGN, "Left\0Middle\0Right\0\0")
        if rv_ha then Config.H_ALIGN = new_h_align; changed = true end
        local reset_ha, r_val_ha = CheckDoubleClickReset(DEFAULT_CONFIG.H_ALIGN, Config.H_ALIGN)
        if reset_ha then Config.H_ALIGN = r_val_ha; changed = true end
        
        local rv_rr, new_rr = im.SliderInt(ctx, "Refresh Rate (FPS)", Config.REFRESH_RATE, 1, 60)
        if rv_rr then Config.REFRESH_RATE = new_rr; changed = true end
        local reset_rr, r_val_rr = CheckDoubleClickReset(DEFAULT_CONFIG.REFRESH_RATE, Config.REFRESH_RATE)
        if reset_rr then Config.REFRESH_RATE = r_val_rr; changed = true end
        
        local rgba_color = core.ColorToRGBA(Config.TEXT_COLOR)
        local rv_c, new_color = im.ColorEdit4(ctx, "Text Color", rgba_color)
        if rv_c then Config.TEXT_COLOR = core.RGBAToColor(new_color); changed = true end
        local reset_tc, _ = CheckDoubleClickReset(DEFAULT_CONFIG.TEXT_COLOR, Config.TEXT_COLOR)
        if reset_tc then Config.TEXT_COLOR = DEFAULT_CONFIG.TEXT_COLOR; changed = true end
        
        if changed then SaveConfig(Config) end
        im.End(ctx)
    end
    
    if open then
        r.defer(loop)
    end
end

loop()
