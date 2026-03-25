#!/usr/bin/env bash
# Run all Lua tests for ajsfx-Scripts.
# Finds lua.exe from PATH or common install locations.

LUA=""

if command -v lua &>/dev/null; then
    LUA="lua"
else
    for candidate in \
        "$LOCALAPPDATA/Programs/Lua/bin/lua.exe" \
        "$PROGRAMFILES/Lua/bin/lua.exe" \
        "/usr/bin/lua" \
        "/usr/local/bin/lua"
    do
        if [ -x "$candidate" ]; then
            LUA="$candidate"
            break
        fi
    done
fi

if [ -z "$LUA" ]; then
    echo "ERROR: lua not found. Install it with: winget install DEVCOM.Lua"
    exit 1
fi

cd "$(dirname "$0")"

FAILED=0
for test_file in tests/test_*.lua; do
    echo "Running $test_file..."
    "$LUA" "$test_file" || FAILED=1
done

exit $FAILED
