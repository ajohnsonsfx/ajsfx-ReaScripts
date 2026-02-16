-- @description Gentle Normalizer
-- @author ajsfx
-- @version 1.0
-- @about Normalizes selected items to a target level with a strength percentage.
-- @provides
--   [main] .

local r = reaper

local success, im = pcall(function()
    package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
    return require('imgui')('0.9.3')
end)

if not success then
    r.MB("This script requires the 'imgui' library, which is included with REAPER.\nIf you are seeing this, your installation may be unusual.", "Library not found", 0)
    return
end

-- --- CONSTANTS & SETTINGS ---
local ctx = im.CreateContext('Gentle Normalizer')
local WINDOW_FLAGS = im.WindowFlags_AlwaysAutoResize

local METERING_TYPES = { "LUFS-I", "RMS-I", "Peak", "True Peak", "LUFS-M Max", "LUFS-S Max" }
local MODES = { "Manual Value", "Average of Selection", "Loudest Item in Selection" }

-- State
local settings = {
    target_db = -23.0,
    metering_type = 0, -- Index into METERING_TYPES
    strength = 100.0, -- Percent
    mode = 0 -- Index into MODES
}

-- --- LOGIC ---

-- Calculates the current level of an item for the specified metering type.
-- Determines the level by calculating the gain required to reach a 0dB reference.
local function CalculateItemLevel(item, meter_type)
    local take = r.GetActiveTake(item)
    if not take then return nil end
    
    local ref_target = 0.0
    local gain_adjust_linear = r.CalculateNormalization(r.GetMediaItemTake_Source(take), meter_type, ref_target, 0, 0)
    
    if gain_adjust_linear <= 0 then return nil end
    
    local gain_adjust_db = 20 * math.log(gain_adjust_linear, 10)
    local current_level = ref_target - gain_adjust_db
    
    return current_level
end

local function Process()
    local selected_count = r.CountSelectedMediaItems(0)
    if selected_count == 0 then
        r.MB("No items selected.", "Error", 0)
        return
    end
    
    local items = {}
    for i = 0, selected_count - 1 do
        table.insert(items, r.GetSelectedMediaItem(0, i))
    end
    
    local target_level = settings.target_db
    
    -- Dynamic Target Calculation
    if settings.mode == 1 then -- Average
        local sum = 0
        local count = 0
        for _, item in ipairs(items) do
            local l = CalculateItemLevel(item, settings.metering_type)
            if l then
                sum = sum + l
                count = count + 1
            end
        end
        if count > 0 then 
            target_level = sum / count 
        else
            r.MB("Could not calculate loudness for selected items.", "Error", 0)
            return
        end
        
    elseif settings.mode == 2 then -- Loudest
        local max_l = -math.huge
        for _, item in ipairs(items) do
            local l = CalculateItemLevel(item, settings.metering_type)
            if l and l > max_l then max_l = l end
        end
        if max_l > -math.huge then
            target_level = max_l
        else
            r.MB("Could not calculate loudness for selected items.", "Error", 0)
            return
        end
    end
    
    -- Apply Normalization
    r.Undo_BeginBlock()
    
    local changes = 0
    for _, item in ipairs(items) do
        local take = r.GetActiveTake(item)
        if take then
            local gain_adjust_linear = r.CalculateNormalization(r.GetMediaItemTake_Source(take), settings.metering_type, target_level, 0, 0)
            
            if gain_adjust_linear > 0 then
                -- Apply strength scaling to the required gain adjustment
                local gain_adjust_db = 20 * math.log(gain_adjust_linear, 10)
                local apply_db = gain_adjust_db * (settings.strength / 100.0)
                local apply_linear = 10 ^ (apply_db / 20)
                
                local old_vol = r.GetMediaItemTakeInfo_Value(take, "D_VOL")
                r.SetMediaItemTakeInfo_Value(take, "D_VOL", old_vol * apply_linear)
                changes = changes + 1
            end
        end
    end
    
    r.UpdateArrange()
    
    local mode_str = "Manual"
    if settings.mode == 1 then mode_str = "Average" end
    if settings.mode == 2 then mode_str = "Loudest" end
    
    r.Undo_EndBlock("Gentle Normalize (" .. math.floor(settings.strength) .. "%, " .. mode_str .. ")", -1)
end

-- --- GUI ---

local function Loop()
    -- Ensure context is valid
    if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
        ctx = im.CreateContext('Gentle Normalizer')
    end
    
    local open = true
    if im.Begin(ctx, 'Gentle Normalizer', true, WINDOW_FLAGS) then
        
        -- Metering Type
        if im.BeginCombo(ctx, 'Metering', METERING_TYPES[settings.metering_type + 1]) then
            for i, type_name in ipairs(METERING_TYPES) do
                local is_selected = (settings.metering_type == i - 1)
                if im.Selectable(ctx, type_name, is_selected) then
                    settings.metering_type = i - 1
                end
                if is_selected then im.SetItemDefaultFocus(ctx) end
            end
            im.EndCombo(ctx)
        end
        
        -- Target Mode
        if im.BeginCombo(ctx, 'Target Mode', MODES[settings.mode + 1]) then
            for i, mode_name in ipairs(MODES) do
                local is_selected = (settings.mode == i - 1)
                if im.Selectable(ctx, mode_name, is_selected) then
                    settings.mode = i - 1
                end
                if is_selected then im.SetItemDefaultFocus(ctx) end
            end
            im.EndCombo(ctx)
        end
        
        -- Target DB Input (Disabled if not Manual)
        im.BeginDisabled(ctx, settings.mode ~= 0)
        local rv, new_val = im.InputDouble(ctx, 'Target Level (dB/LUFS)', settings.target_db, 0.1, 1.0, "%.2f")
        if rv then settings.target_db = new_val end
        im.EndDisabled(ctx)
        
        -- Strength Slider
        local rv_s, new_strength = im.SliderDouble(ctx, 'Strength %', settings.strength, 0.0, 100.0, "%.1f%%")
        if rv_s then settings.strength = new_strength end
        
        im.Separator(ctx)
        
        -- Process Button
        if im.Button(ctx, "Normalize Selected Items", -1, 0) then
            Process()
        end
        
        im.End(ctx)
    else
        open = false
    end
    
    if open then
        r.defer(Loop)
    end
end

-- Start
r.defer(Loop)
