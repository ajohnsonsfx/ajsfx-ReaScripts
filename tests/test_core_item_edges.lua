-- Unit tests for item-edge query helpers in lib/ajsfx_core.lua
-- Run with: lua tests/test_core_item_edges.lua (from the repository root)
-- Uses tests/mock_reaper.lua for the shared REAPER API mock.

local passed = 0
local failed = 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
        print("  PASS: " .. name)
    else
        failed = failed + 1
        print("  FAIL: " .. name .. " - " .. tostring(err))
    end
end

package.path = "lib/?.lua;tests/?.lua;" .. package.path
local mock = require("mock_reaper")
mock.reset()
local core = require("ajsfx_core")

print("\n=== ajsfx_core.lua Item-Edge Helper Tests ===\n")

-- --- GetLastItemEnd Tests ---
print("GetLastItemEnd:")

test("returns pos+len of the rightmost item across two tracks", function()
    local track1 = mock.make_track({ items = {
        mock.make_item({ position = 0, length = 2 }),
    }})
    local track2 = mock.make_track({ items = {
        mock.make_item({ position = 5, length = 3 }), -- ends at 8
    }})
    local result = core.GetLastItemEnd({ track1, track2 })
    assert(result == 8, "Expected 8, got " .. tostring(result))
end)

test("unmuted_only=true skips a muted item that ends later", function()
    local track = mock.make_track({ items = {
        mock.make_item({ position = 0, length = 2 }),      -- ends at 2
        mock.make_item({ position = 10, length = 5, muted = true }), -- ends at 15, muted
    }})
    local result = core.GetLastItemEnd({ track }, true)
    assert(result == 2, "Expected 2, got " .. tostring(result))
end)

test("returns nil for tracks with no items / empty track list", function()
    local track = mock.make_track({ items = {} })
    assert(core.GetLastItemEnd({ track }) == nil, "Expected nil for track with no items")
    assert(core.GetLastItemEnd({}) == nil, "Expected nil for empty track list")
end)

test("unmuted_only=true returns nil when ALL items are muted", function()
    local track = mock.make_track({ items = {
        mock.make_item({ position = 0, length = 2, muted = true }),
        mock.make_item({ position = 5, length = 1, muted = true }),
    }})
    local result = core.GetLastItemEnd({ track }, true)
    assert(result == nil, "Expected nil, got " .. tostring(result))
end)

-- --- GetFirstItemStart Tests ---
print("\nGetFirstItemStart:")

test("returns the leftmost start across tracks", function()
    local track1 = mock.make_track({ items = {
        mock.make_item({ position = 4, length = 2 }),
    }})
    local track2 = mock.make_track({ items = {
        mock.make_item({ position = 1, length = 3 }),
    }})
    local result = core.GetFirstItemStart({ track1, track2 })
    assert(result == 1, "Expected 1, got " .. tostring(result))
end)

test("unmuted_only=true skips an earlier muted item", function()
    local track = mock.make_track({ items = {
        mock.make_item({ position = 0, length = 1, muted = true }), -- earliest, but muted
        mock.make_item({ position = 3, length = 1 }),
    }})
    local result = core.GetFirstItemStart({ track }, true)
    assert(result == 3, "Expected 3, got " .. tostring(result))
end)

test("returns nil when no qualifying items", function()
    local track = mock.make_track({ items = {
        mock.make_item({ position = 0, length = 1, muted = true }),
    }})
    assert(core.GetFirstItemStart({ track }, true) == nil, "Expected nil when all items muted")
    assert(core.GetFirstItemStart({}) == nil, "Expected nil for empty track list")
end)

-- --- GetSelectedTracksList Tests ---
print("\nGetSelectedTracksList:")

test("returns selected tracks in order", function()
    mock.reset()
    local t1 = mock.make_track()
    local t2 = mock.make_track()
    mock.selected_tracks = { t1, t2 }
    local result = core.GetSelectedTracksList()
    assert(#result == 2, "Expected 2 tracks, got " .. #result)
    assert(result[1] == t1, "Expected first track to be t1")
    assert(result[2] == t2, "Expected second track to be t2")
end)

test("returns empty list when none selected", function()
    mock.reset()
    local result = core.GetSelectedTracksList()
    assert(#result == 0, "Expected empty list, got " .. #result)
end)

-- --- Summary ---
print(string.format("\n=== Results: %d passed, %d failed ===\n", passed, failed))
if failed > 0 then
    os.exit(1)
end
