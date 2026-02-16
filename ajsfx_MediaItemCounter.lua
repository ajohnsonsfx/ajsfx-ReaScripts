-- @description Simple Item Counter
-- @author Gemini Code Assist
-- @version 1.0
-- @changelog Initial release

local r = reaper

local success, im = pcall(function()
    package.path = r.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
    return require('imgui')('0.9.3')
end)

if not success then
    r.MB("This script requires the 'imgui' library, which is included with REAPER.\nIf you are seeing this, your installation may be unusual.", "Library not found", 0)
    return
end

local ctx = im.CreateContext('Item Counter')

--------------------------------
-- --- SCRIPT SETTINGS ---
--------------------------------
local FONT_SIZE = 12
local FONT_NAME = "Arial"
local TEXT_COLOR = 0x99FFFFFF -- White with 60% alpha (AABBGGRR format)
local HORIZONTAL_OFFSET = 5  -- Pixels from the left edge of the arrange view
local VERTICAL_ALIGN = 0.5   -- 0.0=top, 0.5=center, 1.0=bottom
--------------------------------

local font

-- Finds the arrange view window and prepares the overlay
local arrange = r.JS_Window_FindChildByID(r.GetMainHwnd(), 0x3E8)
local LEFT, TOP, RIGHT, BOT = 0, 0, 0, 0
local WX, WY = 0, 0
local scroll_size = 0
local OLD_VAL = 0

local function DrawOverArrange()
    local _, DPI_RPR = r.get_config_var_string("uiscale")
    scroll_size = 15 * (DPI_RPR or 1)
    
    local _, orig_LEFT, orig_TOP, orig_RIGHT, orig_BOT = r.JS_Window_GetRect(arrange)
    local current_val = orig_TOP + orig_BOT + orig_LEFT + orig_RIGHT
    
    if current_val ~= OLD_VAL then
        OLD_VAL = current_val
        LEFT, TOP = im.PointConvertNative(ctx, orig_LEFT, orig_TOP)
        RIGHT, BOT = im.PointConvertNative(ctx, orig_RIGHT, orig_BOT)
    end
    im.SetNextWindowPos(ctx, LEFT, TOP)
    im.SetNextWindowSize(ctx, (RIGHT - LEFT) - scroll_size, (BOT - TOP) - scroll_size)
end

function loop()
    if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
        ctx = im.CreateContext('Item Counter')
        font = im.CreateFont(FONT_NAME, FONT_SIZE)
        im.Attach(ctx, font)
    end

    DrawOverArrange()
    
    -- Window flags for transparent, non-interactive overlay
    local window_flags = im.WindowFlags_NoTitleBar |
                         im.WindowFlags_NoResize |
                         im.WindowFlags_NoNav |
                         im.WindowFlags_NoScrollbar |
                         im.WindowFlags_NoDecoration |
                         im.WindowFlags_NoDocking |
                         im.WindowFlags_NoBackground |
                         im.WindowFlags_NoInputs |
                         im.WindowFlags_NoMove |
                         im.WindowFlags_NoSavedSettings |
                         im.WindowFlags_NoMouseInputs |
                         im.WindowFlags_NoFocusOnAppearing

    im.PushFont(ctx, font)
    local visible, open = im.Begin(ctx, 'Item Counter Display', true, window_flags)
    
    if visible then
        local draw_list = im.GetWindowDrawList(ctx)
        local WX, WY = im.GetWindowPos(ctx)
        
        local _, screen_scale = r.get_config_var_string("uiscale")
        if screen_scale == 0 then screen_scale = 1 end

        local track_count = r.CountTracks(0)
        for i = 0, track_count - 1 do
            local track = r.GetTrack(0, i)
            
            if r.GetMediaTrackInfo_Value(track, "B_SHOWINTCP") == 1 then
                local item_count = r.CountTrackMediaItems(track)
                
                if item_count > 0 then
                    local track_y = r.GetMediaTrackInfo_Value(track, "I_TCPY") / screen_scale
                    local track_h = r.GetMediaTrackInfo_Value(track, "I_TCPH") / screen_scale
                    
                    if track_h > 10 then
                        local text = string.format("[%d]", item_count)
                        local text_w, text_h = im.CalcTextSize(ctx, text)
                        
                        -- Calculate position
                        local text_x = WX + HORIZONTAL_OFFSET
                        local text_y = WY + track_y + (track_h * VERTICAL_ALIGN) - (text_h * 0.5)
                        
                        im.DrawList_AddText(draw_list, text_x, text_y, TEXT_COLOR, text)
                    end
                end
            end
        end
    end
    
    im.End(ctx)
    im.PopFont(ctx)
    
    if open then
        r.defer(loop)
    end
end

function main()
    font = im.CreateFont(FONT_NAME, FONT_SIZE)
    im.Attach(ctx, font)
    loop()
end

-- Start the script
local _, _, section, cmdID = r.get_action_context()

r.atexit(function()
    if cmdID then
        r.SetToggleCommandState(section, cmdID, 0)
        r.RefreshToolbar2(section, cmdID)
    end
end)

if cmdID then
    r.SetToggleCommandState(section, cmdID, 1)
    r.RefreshToolbar2(section, cmdID)
end

main()
