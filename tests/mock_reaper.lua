-- Reusable REAPER API mock for unit tests
-- Usage: local mock = require("mock_reaper")
--        mock.reset()
--        -- configure mock state, then run tests

local mock = {}

-- State tables (reset between tests)
mock.console = {}
mock.msgbox = {}
mock.extstate = {}
mock.tracks = {}        -- list of track objects for CountTracks/GetTrack
mock.selected_tracks = {} -- list of track objects for CountSelectedTracks/GetSelectedTrack
mock.selected_items = {}  -- list of item objects for CountSelectedMediaItems/GetSelectedMediaItem

function mock.reset()
    mock.console = {}
    mock.msgbox = {}
    mock.extstate = {}
    mock.tracks = {}
    mock.selected_tracks = {}
    mock.selected_items = {}

    reaper = {
        ShowConsoleMsg = function(msg) table.insert(mock.console, msg) end,
        ShowMessageBox = function(msg, title, typ) table.insert(mock.msgbox, {msg=msg, title=title}) end,
        MB = function(msg, title, typ) table.insert(mock.msgbox, {msg=msg, title=title}) end,

        -- Track hierarchy
        GetParentTrack = function(track)
            if track and track.parent then return track.parent end
            return nil
        end,
        GetMediaTrackInfo_Value = function(track, key)
            if not track or not track.info then return 0 end
            return track.info[key] or 0
        end,
        SetMediaTrackInfo_Value = function(track, key, val)
            if track then
                if not track.info then track.info = {} end
                track.info[key] = val
            end
        end,
        GetSetMediaTrackInfo_String = function(track, key, val, set)
            if track and track.razor then
                return true, track.razor
            end
            return false, ""
        end,

        -- Track enumeration
        CountSelectedTracks = function() return #mock.selected_tracks end,
        GetSelectedTrack = function(proj, i) return mock.selected_tracks[i + 1] end,
        CountTracks = function() return #mock.tracks end,
        GetTrack = function(proj, i) return mock.tracks[i + 1] end,

        -- Item enumeration
        CountSelectedMediaItems = function() return #mock.selected_items end,
        GetSelectedMediaItem = function(proj, i) return mock.selected_items[i + 1] end,
        CountTrackMediaItems = function(track)
            if track and track.items then return #track.items end
            return 0
        end,
        GetTrackMediaItem = function(track, i)
            if track and track.items then return track.items[i + 1] end
            return nil
        end,

        -- Item info
        GetMediaItemInfo_Value = function(item, key)
            if item and item.info then return item.info[key] or 0 end
            return 0
        end,
        SetMediaItemInfo_Value = function(item, key, val)
            if item then
                if not item.info then item.info = {} end
                item.info[key] = val
            end
        end,

        -- Take / normalization
        GetActiveTake = function(item)
            if item and item.take then return item.take end
            return nil
        end,
        GetMediaItemTake_Source = function(take)
            if take and take.source then return take.source end
            return "mock_source"
        end,
        GetMediaItemTakeInfo_Value = function(take, key)
            if take and take.info then return take.info[key] or 0 end
            return 0
        end,
        SetMediaItemTakeInfo_Value = function(take, key, val)
            if take then
                if not take.info then take.info = {} end
                take.info[key] = val
            end
        end,
        CalculateNormalization = function(source, meter_type, target, start_t, end_t)
            -- Mock: return a configurable linear gain value
            if source and type(source) == "table" and source.norm_gain then
                return source.norm_gain
            end
            return 1.0 -- unity gain by default
        end,

        -- Undo / UI
        Undo_BeginBlock = function() end,
        Undo_EndBlock = function() end,
        PreventUIRefresh = function() end,
        UpdateArrange = function() end,

        -- ExtState
        HasExtState = function(section, key)
            return mock.extstate[section] and mock.extstate[section][key] ~= nil
        end,
        GetExtState = function(section, key)
            if mock.extstate[section] then return mock.extstate[section][key] or "" end
            return ""
        end,
        SetExtState = function(section, key, val, persist)
            if not mock.extstate[section] then mock.extstate[section] = {} end
            mock.extstate[section][key] = val
        end,
        DeleteExtState = function(section, key, persist)
            if mock.extstate[section] then mock.extstate[section][key] = nil end
        end,
    }
end

-- Helper to create a track object
function mock.make_track(opts)
    opts = opts or {}
    return {
        info = {
            B_SHOWINTCP = opts.visible ~= false and 1 or 0,
            I_FOLDERCOMPACT = opts.folder_compact or 0,
            B_MUTE = opts.muted and 1 or 0,
        },
        parent = opts.parent or nil,
        razor = opts.razor or nil,
        items = opts.items or nil,
    }
end

-- Helper to create a media item object
function mock.make_item(opts)
    opts = opts or {}
    local take = nil
    if opts.has_take ~= false then
        take = {
            info = { D_VOL = opts.volume or 1.0 },
            source = opts.source or { norm_gain = opts.norm_gain or 1.0 },
        }
    end
    return {
        info = {
            B_MUTE = opts.muted and 1 or 0,
            D_POSITION = opts.position or 0,
            D_LENGTH = opts.length or 1,
        },
        take = take,
    }
end

return mock
