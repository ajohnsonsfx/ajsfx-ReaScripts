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
            if not track then return 0 end
            -- IP_TRACKNUMBER is the track's 1-based position in the project.
            if key == "IP_TRACKNUMBER" then
                for i, t in ipairs(mock.tracks) do if t == track then return i end end
                return 0
            end
            if not track.info then return 0 end
            return track.info[key] or 0
        end,
        SetMediaTrackInfo_Value = function(track, key, val)
            if track then
                if not track.info then track.info = {} end
                track.info[key] = val
            end
        end,
        GetSetMediaTrackInfo_String = function(track, key, val, set)
            -- Track name get/set, used by EnsureTrackBelow.
            if track and key == "P_NAME" then
                if set then track.name = val; return true end
                return true, track.name or ""
            end
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

        -- Item take name (used by ApplyPlan to name cut clips)
        GetSetMediaItemTakeInfo_String = function(take, key, val, set)
            if take then
                if set then take.name = val; return true end
                return true, take.name or ""
            end
            return false, ""
        end,
        GetMediaItem_Track = function(item) return item and item.track or nil end,

        -- Split/move, modelled on REAPER's real behaviour so ApplyPlan can be
        -- unit-tested. SplitMediaItem returns NULL when the position is on or
        -- outside the item's bounds (the boundary no-op that a zero-length span
        -- exploited to move a whole item instead of a slice).
        SplitMediaItem = function(item, pos)
            if not item or not item.info then return nil end
            local p   = item.info.D_POSITION or 0
            local len = item.info.D_LENGTH or 0
            local e   = p + len
            local eps = 1e-9
            if pos <= p + eps or pos >= e - eps then return nil end
            item.info.D_LENGTH = pos - p
            local right = {
                info  = { D_POSITION = pos, D_LENGTH = e - pos },
                take  = { info = {}, source = (item.take and item.take.source) or "mock_source" },
                track = item.track,
            }
            local list = item.track and item.track.items
            if list then
                for i, it in ipairs(list) do
                    if it == item then table.insert(list, i + 1, right); break end
                end
            end
            return right
        end,
        MoveMediaItemToTrack = function(item, track)
            if not item or not track then return false end
            local from = item.track and item.track.items
            if from then
                for i, it in ipairs(from) do
                    if it == item then table.remove(from, i); break end
                end
            end
            if not track.items then track.items = {} end
            track.items[#track.items + 1] = item
            item.track = track
            return true
        end,
        InsertTrackAtIndex = function(idx, wantDefaults)
            -- idx is 0-based; a new empty track lands at that project position.
            table.insert(mock.tracks, idx + 1, { info = {}, items = {}, name = "" })
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
