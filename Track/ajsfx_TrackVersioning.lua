-- @description Track Versioning: Duplicate, Increment Version, and Archive Old
-- @author ajsfx
-- @version 1.0
-- @about Automates track versioning: Duplicates selected tracks, increments version/date on the original, and archives the duplicate in an "Old" folder. Configurable via ExtState.
-- @provides
--   [main] .
--   [nomain] ../lib/ajsfx_core.lua
-- TODO: Create a separate script for adding the initial date and version to tracks that don't have it, so users can easily adopt this workflow on existing projects.
-- TODO: Create a managemenet window that allows the user to define the date format, whether to mute archived tracks, and the name of the archive folder. This would be a more user-friendly way to configure the script than editing ExtState directly.
-- TODO: The user management window should allow the user to enable or disable different steps in the process - maybe they don't want to rename, or maybe they don't want to move the folder automatically. This would make the script more flexible for different workflows.


local r = reaper
local script_path = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
if not script_path then script_path = "" end
package.path = script_path .. "?.lua;" .. script_path .. "../?.lua;" .. package.path

local core = require("lib.ajsfx_core")

-- Configurable settings (stored in ExtState for persistence)
local section = "ajsfx_TrackVersioning"
local folder_name = r.GetExtState(section, "folder_name")
if folder_name == "" then folder_name = "Old" end

local mute_archived = r.GetExtState(section, "mute_archived")
if mute_archived == "" then mute_archived = "true" end
local should_mute_archived = (mute_archived == "true")

local date_format = r.GetExtState(section, "date_format")
if date_format == "" then date_format = "%Y_%m%d" end

-- Helper: Parse track name (assumes format: name_vX_YYYY_MMDD)
local function parse_track_name(name)
    local base, ver = name:match("(.+)_v(%d+)_.*")
    if base then
        return base, tonumber(ver)
    end
    -- If no version string is found, treat the whole name as the base and start at v0.
    return name, 0
end

-- Helper: Generate new name
local function generate_new_name(base, new_ver)
    local today = os.date(date_format)
    return string.format("%s_v%d_%s", base, new_ver, today)
end

-- Helper: Find or create an archive folder at the top of the project.
local function get_or_create_old_folder()
    local num_tracks = r.CountTracks(0)
    for i = 0, num_tracks - 1 do
        local track = r.GetTrack(0, i)
        local _, name = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
        -- Check if it's a top-level folder with the correct name
        if name == folder_name and core.GetTrackDepth(track) == 0 then
            return track
        end
    end
    -- Create at top (index 0)
    local folder = r.InsertTrackAtIndex(0, true)
    r.GetSetMediaTrackInfo_String(folder, "P_NAME", folder_name, true)
    -- Make it a folder track. This makes it a parent for any tracks immediately following it that are indented.
    r.SetMediaTrackInfo_Value(folder, "I_FOLDERDEPTH", 1)
    return folder
end

-- Helper: Offline all FX on a track
local function offline_all_fx(track)
    local num_fx = r.TrackFX_GetCount(track)
    for fx = 0, num_fx - 1 do
        r.TrackFX_SetOffline(track, fx, true)
    end
end

-- Main logic
core.Transaction("Track Versioning", function()
    local num_sel = r.CountSelectedTracks(0)
    if num_sel == 0 then
        r.MB("No tracks selected.", "Error", 0)
        return
    end

    -- 1. Filter Selection: only top-level selected tracks
    local target_tracks = {}
    for i = 0, num_sel - 1 do
        local track = r.GetSelectedTrack(0, i)
        local has_sel_parent = false
        local parent = r.GetParentTrack(track)
        while parent do
            if r.IsTrackSelected(parent) then
                has_sel_parent = true
                break
            end
            parent = r.GetParentTrack(parent)
        end
        if not has_sel_parent then
            table.insert(target_tracks, track)
        end
    end

    -- Ensure Old folder exists before we start shifting things around
    local old_folder = get_or_create_old_folder()

    -- Remove old_folder from targets if user accidentally selected it
    for i = #target_tracks, 1, -1 do
        if target_tracks[i] == old_folder then
            table.remove(target_tracks, i)
        end
    end

    if #target_tracks == 0 then
        r.MB("No valid tracks selected to version.", "Error", 0)
        return
    end

    -- Sort targets by index descending so we process bottom-up
    table.sort(target_tracks, function(a, b)
        return r.GetMediaTrackInfo_Value(a, "IP_TRACKNUMBER") > r.GetMediaTrackInfo_Value(b, "IP_TRACKNUMBER")
    end)

    -- 2. Process Target Tracks
    for _, orig_parent in ipairs(target_tracks) do
        local _, name = r.GetSetMediaTrackInfo_String(orig_parent, "P_NAME", "", false)
        local base, ver = parse_track_name(name)

        if base and ver then
            -- Get current index and depth
            local parent_idx = math.floor(r.GetMediaTrackInfo_Value(orig_parent, "IP_TRACKNUMBER")) - 1
            local parent_depth = core.GetTrackDepth(orig_parent)

            -- Select original parent and all its children to duplicate the whole group
            r.SetOnlyTrackSelected(orig_parent)
            for j = parent_idx + 1, r.CountTracks(0) - 1 do
                local t = r.GetTrack(0, j)
                if core.GetTrackDepth(t) > parent_depth then
                    r.SetTrackSelected(t, true)
                else
                    break
                end
            end

            -- Duplicate the track(s)
            r.Main_OnCommand(40062, 0) -- Track: Duplicate tracks

            -- The duplicated tracks are now selected.
            -- Rename original parent to new version
            local new_name = generate_new_name(base, ver + 1)
            r.GetSetMediaTrackInfo_String(orig_parent, "P_NAME", new_name, true)

            -- Archive duplicates (the current selection)
            local dup_count = r.CountSelectedTracks(0)
            for j = 0, dup_count - 1 do
                local dup_t = r.GetSelectedTrack(0, j)
                offline_all_fx(dup_t)
                if j == 0 and should_mute_archived then
                    r.SetMediaTrackInfo_Value(dup_t, "B_MUTE", 1)
                end
            end

            -- Move duplicated group to "Old" folder
            local old_idx = math.floor(r.GetMediaTrackInfo_Value(old_folder, "IP_TRACKNUMBER")) - 1
            r.ReorderSelectedTracks(old_idx + 1, 0) -- Move to after the folder, with no folder creation

            -- Indent the first of the moved tracks to make the whole group a child of the folder
            local first_moved_track = r.GetTrack(0, old_idx + 1)
            if first_moved_track then
                r.SetMediaTrackInfo_Value(first_moved_track, "I_FOLDERDEPTH", 1)
            end
        else
            core.Print(string.format("Track '%s' does not match expected format. Skipping.", name))
        end
    end

    -- 3. Restore State: Reselect the original target tracks (now the new versions)
    r.Main_OnCommand(40297, 0) -- Track: Unselect all tracks
    for _, track in ipairs(target_tracks) do
        if r.ValidatePtr(track, "MediaTrack*") then
            r.SetTrackSelected(track, true)
        end
    end
end)
