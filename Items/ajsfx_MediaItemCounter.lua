-- @description Simple Item Counter
-- @author ajsfx
-- @version 1.3
-- @changelog Moved settings to a separate script
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

local ctx = im.CreateContext('Item Counter')

--------------------------------
-- --- CONSTANTS ---
--------------------------------
local CONFIG_CHECK_INTERVAL = 0.5 -- seconds between config polls
local DPI_SCROLL_SIZE = 15        -- base scrollbar width before DPI scaling
local MIN_TRACK_HEIGHT = 10       -- minimum track height (px) to render counter

local Config = core.LoadMediaCounterConfig()
local LAST_CONFIG_CHECK = r.time_precise()

--------------------------------

local font
local arrange = r.JS_Window_FindChildByID(r.GetMainHwnd(), 0x3E8)
local LEFT, TOP, RIGHT, BOT = 0, 0, 0, 0
local scroll_size = 0
local OLD_VAL = 0

local CachedItemCounts = {}
local LastProjStateCount = -1
local LastDrawTime = 0
local DrawCache = {}

local function RecreateFont()
    if font then im.Detach(ctx, font) end
    font = im.CreateFont(Config.FONT_NAME, Config.FONT_SIZE)
    im.Attach(ctx, font)
end

local function DrawOverArrange()
    local _, DPI_RPR_str = r.get_config_var_string("uiscale")
    local DPI_RPR = tonumber(DPI_RPR_str) or 1
    if DPI_RPR == 0 then DPI_RPR = 1 end
    scroll_size = DPI_SCROLL_SIZE * DPI_RPR
    
    local _, orig_LEFT, orig_TOP, orig_RIGHT, orig_BOT = r.JS_Window_GetRect(arrange)
    local current_val = orig_TOP + orig_BOT + orig_LEFT + orig_RIGHT
    
    if current_val ~= OLD_VAL then
        OLD_VAL = current_val
        LEFT, TOP = im.PointConvertNative(ctx, orig_LEFT, orig_TOP)
        RIGHT, BOT = im.PointConvertNative(ctx, orig_RIGHT, orig_BOT)
    end
end

function loop()
    -- Periodically check for config updates (e.g., from the settings script)
    local current_time = r.time_precise()
    if current_time - LAST_CONFIG_CHECK > CONFIG_CHECK_INTERVAL then
        LAST_CONFIG_CHECK = current_time
        local new_cfg = core.LoadMediaCounterConfig()
        if new_cfg.FONT_SIZE ~= Config.FONT_SIZE or new_cfg.FONT_NAME ~= Config.FONT_NAME then
            Config = new_cfg
            RecreateFont()
        else
            Config = new_cfg
        end
    end

    if not (ctx and im.ValidatePtr(ctx, 'ImGui_Context*')) then
        ctx = im.CreateContext('Item Counter')
        RecreateFont()
    end

    DrawOverArrange()
    
    --------------------------------
    -- COUNTER OVERLAY
    --------------------------------
    im.SetNextWindowPos(ctx, LEFT, TOP)
    im.SetNextWindowSize(ctx, (RIGHT - LEFT) - scroll_size, (BOT - TOP) - scroll_size)
    
    local window_flags = im.WindowFlags_NoTitleBar |
                         im.WindowFlags_NoResize |
                         im.WindowFlags_NoNav |
                         im.WindowFlags_NoScrollbar |
                         im.WindowFlags_NoDecoration |
                         im.WindowFlags_NoDocking |
                         im.WindowFlags_NoBackground |
                         im.WindowFlags_NoMove |
                         im.WindowFlags_NoSavedSettings |
                         im.WindowFlags_NoFocusOnAppearing |
                         im.WindowFlags_NoMouseInputs

    ---@diagnostic disable-next-line: missing-parameter
    im.PushFont(ctx, font)
    local visible, open = im.Begin(ctx, 'Item Counter Display', true, window_flags)
    
    if visible then
        local draw_list = im.GetWindowDrawList(ctx)
        local WX, WY = im.GetWindowPos(ctx)
        
        local retval, screen_scale_str = r.get_config_var_string("uiscale")
        local screen_scale = tonumber(screen_scale_str) or 1
        if screen_scale == 0 then screen_scale = 1 end

        -- Refresh Rate Throttling
        local min_frame_time = 1.0 / (Config.REFRESH_RATE or 30)
        
        if current_time - LastDrawTime >= min_frame_time then
            LastDrawTime = current_time
            DrawCache = {}
            
            local current_proj_state = r.GetProjectStateChangeCount(0)
            if current_proj_state ~= LastProjStateCount then
                LastProjStateCount = current_proj_state
                CachedItemCounts = {} -- invalidate cache
            end

            local track_count = r.CountTracks(0)
            for i = 0, track_count - 1 do
                local track = r.GetTrack(0, i)
                
                if core.IsTrackVisibleInArrangement(track) then
                    local track_y = r.GetMediaTrackInfo_Value(track, "I_TCPY") / screen_scale
                    
                    -- Early exit: stop iterating once we're past the visible bottom
                    if track_y > (BOT - TOP) then break end
                    
                    local track_h = r.GetMediaTrackInfo_Value(track, "I_TCPH") / screen_scale

                    -- Check if track is visible on screen before counting items
                    if track_h > MIN_TRACK_HEIGHT and track_y + track_h > 0 then
                        local item_count = CachedItemCounts[track]
                        if not item_count then
                            item_count = r.CountTrackMediaItems(track)
                            CachedItemCounts[track] = item_count
                        end
                        
                        if item_count >= 0 then
                            local text = string.format("[%d]", item_count)
                            local text_w, text_h = im.CalcTextSize(ctx, text)
                            
                            table.insert(DrawCache, {
                                text = text,
                                text_w = text_w,
                                text_h = text_h,
                                track_y = track_y,
                                track_h = track_h
                            })
                        end
                    end
                end
            end
        end
        
        -- Draw the cached items
        for _, item in ipairs(DrawCache) do
            -- Calculate position
            local text_x = WX + Config.HORIZONTAL_OFFSET
            
            if Config.H_ALIGN == 1 then -- Middle
                local view_width = RIGHT - LEFT
                text_x = WX + (view_width / 2) - (item.text_w / 2) + Config.HORIZONTAL_OFFSET
            elseif Config.H_ALIGN == 2 then -- Right
                local view_width = RIGHT - LEFT
                text_x = WX + view_width - item.text_w - scroll_size - Config.HORIZONTAL_OFFSET
            end
            
            local text_y = WY + item.track_y + (item.track_h * Config.VERTICAL_ALIGN) - (item.text_h * 0.5)
            
            im.DrawList_AddText(draw_list, text_x, text_y, Config.TEXT_COLOR, item.text)
        end
    end
    
    im.End(ctx)
    im.PopFont(ctx)
    
    if open then
        r.defer(loop)
    end
end

function main()
    RecreateFont()
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
