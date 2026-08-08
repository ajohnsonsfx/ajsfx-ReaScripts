# VO Overview Nested Rows Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Overview's 18-column flat table with a two-level tree — parent rows per script line, take rows nested beneath — per `docs/superpowers/specs/2026-08-08-vo-overview-nested-rows-design.md`.

**Architecture:** All grouping/rollup/filter logic is pure Lua added to `VO/lib/ajsfx_vo.lua` and unit-tested against the mock REAPER. The script `VO/ajsfx_VO_Overview.lua` consumes the pure layer: `ApplyFilters` builds a typed draw list (character headers, line parents, take children, orphan section) and the table loop renders node kinds instead of uniform rows. Display sorting is deleted outright.

**Tech Stack:** Lua 5.x, REAPER API (mocked in tests), ReaImGui 0.9.3 via the `Api()` guard pattern, ReaPack.

## Global Constraints

- Work on a feature branch: `git checkout -b feature/vo-overview-nested-rows` before Task 1. Merging to `main` publishes; do not merge — that is the user's call after live testing.
- Tests: `./run_tests.sh` from repo root (bash). All existing tests must stay green in every task.
- Pure logic goes in `VO/lib/ajsfx_vo.lua` (loadable without ImGui), never in the script. UI code cannot be unit-tested; verify it by reading + the final live-REAPER check.
- ImGui discipline in `ajsfx_VO_Overview.lua`: optional bindings only through `Api(name)`; anything drawn between `BeginTable`/`EndTable` runs under the existing `pcall` + depth-counter unwind (`id_depth`, `wrap_depth`, `colour_depth`, `font_depth`); widget mutations go through `pending_action = function() ... end`, never inline.
- The spec's row/column semantics are authoritative: 6 question-columns (#, State, Text, Name, Where, Notes), State = dot + Sel/Keep/Lock checkboxes, sub-header row once per expanded line, character group headers, orphan section last, always script order.
- `@version`/`@changelog` are touched ONLY in the final task (`0.15beta1` — pre-release, letter versions reach opt-in users only).
- Commit after every task (message style: `feat:`/`refactor:`/`docs:` as in recent history).

---

### Task 1: Pure grouping — `vo.GroupOverview`

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (append near `vo.BuildOverview`, ~line 3638)
- Test: `tests/test_vo.lua` (append a new print section at the end, before the summary)

**Interfaces:**
- Consumes: overview rows as `vo.BuildOverview` + the script's adoption pass produce them: fields `status` ("recorded"|"review"|"missing"|"orphan"), `character`, `script`, `asset`, `deliver`, `line_text`, `script_row`, `user_select`, `user_status`, `take_index`.
- Produces: `vo.GroupOverview(rows) -> nodes` where each node is one of:
  - `{ kind = "character", name = <string> }`
  - `{ kind = "line", rep = <first row of the line>, takes = { <rows with audio> }, rollup = { status, got, has_sel, locks, take_count } }`
  - `{ kind = "orphans", takes = { <orphan rows> } }` (at most one, last)

  `rollup.status` is `"missing"` when `takes` is empty, else `"review"` if any take's status is review, else `"recorded"`. `rollup.got` is left `nil` here (the script fills it from `DELIVERY`, which needs live project state). `rep` is the line's first row whether or not it carries audio — parents read line-side fields (`line_text`, `asset`, `deliver`, `script`, `script_row`, `character`, `append`, `line_key`, `append_key`, `key`, `uid`) from it.

- [ ] **Step 1: Write the failing tests** (append to `tests/test_vo.lua`):

```lua
--------------------------------
-- GroupOverview
--------------------------------
print("GroupOverview:")

local function mkrow(o)
  -- Minimal overview row; callers override what the test cares about.
  local row = {
    status = "recorded", character = "GRUMBAR", script = "main.csv",
    asset = "grum_01", deliver = "grum_01", line_text = "Get off my bridge!",
    script_row = 1, take_index = 1, user_select = false, user_status = nil,
  }
  for k, v in pairs(o) do row[k] = v end
  return row
end

test("takes group under one line node per script_row", function()
  local nodes = vo.GroupOverview({
    mkrow({ script_row = 1, take_index = 1 }),
    mkrow({ script_row = 1, take_index = 2 }),
    mkrow({ script_row = 2, asset = "grum_02", take_index = 1 }),
  })
  -- character header + two line nodes
  assert(#nodes == 3, "Expected 3 nodes, got " .. #nodes)
  assert(nodes[1].kind == "character" and nodes[1].name == "GRUMBAR")
  assert(nodes[2].kind == "line" and #nodes[2].takes == 2)
  assert(nodes[3].kind == "line" and #nodes[3].takes == 1)
end)

test("a missing line has no takes and rollup.status missing", function()
  local nodes = vo.GroupOverview({ mkrow({ status = "missing" }) })
  local line = nodes[2]
  assert(line.kind == "line" and #line.takes == 0, "missing line must be childless")
  assert(line.rollup.status == "missing")
  assert(line.rep ~= nil, "rep must still carry the line fields")
end)

test("any review take makes the line rollup review", function()
  local nodes = vo.GroupOverview({
    mkrow({ take_index = 1 }),
    mkrow({ take_index = 2, status = "review" }),
  })
  assert(nodes[2].rollup.status == "review")
end)

test("rollup counts sel and locks", function()
  local nodes = vo.GroupOverview({
    mkrow({ take_index = 1, user_select = true, user_status = "verified" }),
    mkrow({ take_index = 2 }),
  })
  local rl = nodes[2].rollup
  assert(rl.has_sel == true and rl.locks == 1 and rl.take_count == 2)
end)

test("character header inserted on change, in row order", function()
  local nodes = vo.GroupOverview({
    mkrow({ script_row = 1 }),
    mkrow({ script_row = 2, character = "VERA", asset = "vera_01" }),
  })
  assert(nodes[1].kind == "character" and nodes[1].name == "GRUMBAR")
  assert(nodes[3].kind == "character" and nodes[3].name == "VERA")
  assert(#nodes == 4)
end)

test("orphans collect into one trailing section", function()
  local nodes = vo.GroupOverview({
    mkrow({ status = "orphan", script_row = nil, asset = nil, character = nil }),
    mkrow({ script_row = 1 }),
    mkrow({ status = "orphan", script_row = nil, asset = nil, character = nil }),
  })
  local last = nodes[#nodes]
  assert(last.kind == "orphans" and #last.takes == 2)
  -- and no character header was emitted for the orphans' nil character
  for _, n in ipairs(nodes) do
    assert(not (n.kind == "character" and n.name == ""), "no blank character header")
  end
end)

test("lines without script_row group by asset", function()
  local nodes = vo.GroupOverview({
    mkrow({ script_row = nil, asset = "loose_01" }),
    mkrow({ script_row = nil, asset = "loose_01", take_index = 2 }),
  })
  assert(nodes[2].kind == "line" and #nodes[2].takes == 2)
end)
```

- [ ] **Step 2: Run to verify failure**

Run: `./run_tests.sh` (or `lua tests/test_vo.lua`)
Expected: the new tests FAIL with "attempt to call a nil value (field 'GroupOverview')".

- [ ] **Step 3: Implement** (append to `VO/lib/ajsfx_vo.lua` after `vo.BuildOverview`):

```lua
-- The Overview table's draw list. Flat overview rows (already in script
-- order, adopted/extra rows already inserted beside their lines) become a
-- typed node list: character headers, line parents with their takes nested,
-- and one trailing section for orphans. Pure, so the shape the window draws
-- is testable without ImGui.
--
-- rollup.got is NOT computed here: it reads the live project's item names
-- (DELIVERY in the window), which this layer must not touch.
function vo.GroupOverview(rows)
  local nodes, orphans = {}, {}
  local current_char, open_line = nil, nil

  local function line_key_of(row)
    return row.script_row or ("asset:" .. tostring(row.asset))
  end

  for _, row in ipairs(rows or {}) do
    if row.status == "orphan" then
      orphans[#orphans + 1] = row
    else
      local key = line_key_of(row)
      if not (open_line and open_line._key == key) then
        local char = row.character or ""
        if char ~= "" and char ~= current_char then
          nodes[#nodes + 1] = { kind = "character", name = char }
          current_char = char
        end
        open_line = { kind = "line", _key = key, rep = row, takes = {},
                      rollup = { status = "missing", has_sel = false,
                                 locks = 0, take_count = 0 } }
        nodes[#nodes + 1] = open_line
      end
      -- A row with no take_index is a line that matched nothing: it IS the
      -- parent and contributes no child. Everything else is a take.
      if row.take_index and row.status ~= "missing" then
        local t = open_line.takes
        t[#t + 1] = row
        local rl = open_line.rollup
        rl.take_count = #t
        if row.status == "review" then
          rl.status = "review"
        elseif rl.status ~= "review" then
          rl.status = "recorded"
        end
        if row.user_select then rl.has_sel = true end
        if row.user_status == "verified" then rl.locks = rl.locks + 1 end
      end
    end
  end

  if #orphans > 0 then
    nodes[#nodes + 1] = { kind = "orphans", takes = orphans }
  end
  return nodes
end
```

- [ ] **Step 4: Run tests to verify pass** — `./run_tests.sh`, all green.
- [ ] **Step 5: Commit** — `git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat: pure GroupOverview for nested Overview rows"`

---

### Task 2: Pure line-level filtering — `vo.FilterGroups`

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (directly under `vo.GroupOverview`)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.GroupOverview` nodes.
- Produces: `vo.FilterGroups(nodes, match) -> nodes` — `match(row) -> boolean` is applied to every take AND to each line's `rep`; a line survives when its rep or ANY take matches, and survives **whole** (all takes kept — the spec: filters select lines, takes come along). Character headers survive only when a following line survives; the orphan section filters its takes individually.

- [ ] **Step 1: Write the failing tests:**

```lua
print("FilterGroups:")

test("a take match keeps the whole line with all takes", function()
  local nodes = vo.GroupOverview({
    mkrow({ take_index = 1, transcript = "alpha" }),
    mkrow({ take_index = 2, transcript = "bravo" }),
    mkrow({ script_row = 2, asset = "grum_02", transcript = "charlie" }),
  })
  local out = vo.FilterGroups(nodes, function(row)
    return (row.transcript or "") == "bravo"
  end)
  local lines = {}
  for _, n in ipairs(out) do if n.kind == "line" then lines[#lines + 1] = n end end
  assert(#lines == 1, "one line expected, got " .. #lines)
  assert(#lines[1].takes == 2, "the matching line keeps BOTH takes")
end)

test("a rep-only match keeps a childless line", function()
  local nodes = vo.GroupOverview({ mkrow({ status = "missing", line_text = "needle" }) })
  local out = vo.FilterGroups(nodes, function(row)
    return (row.line_text or ""):find("needle", 1, true) ~= nil
  end)
  assert(#out == 2 and out[2].kind == "line")
end)

test("character header dropped when none of its lines survive", function()
  local nodes = vo.GroupOverview({
    mkrow({ script_row = 1 }),
    mkrow({ script_row = 2, character = "VERA", asset = "vera_01", line_text = "pay him" }),
  })
  local out = vo.FilterGroups(nodes, function(row)
    return (row.line_text or ""):find("pay", 1, true) ~= nil
  end)
  assert(#out == 2, "expected VERA header + line, got " .. #out)
  assert(out[1].kind == "character" and out[1].name == "VERA")
end)

test("orphan takes filter individually and empty section vanishes", function()
  local nodes = vo.GroupOverview({
    mkrow({ status = "orphan", script_row = nil, asset = nil, character = nil,
            transcript = "keep me" }),
    mkrow({ status = "orphan", script_row = nil, asset = nil, character = nil,
            transcript = "drop me" }),
  })
  local out = vo.FilterGroups(nodes, function(row)
    return (row.transcript or "") == "keep me"
  end)
  assert(#out == 1 and out[1].kind == "orphans" and #out[1].takes == 1)
  local none = vo.FilterGroups(nodes, function() return false end)
  assert(#none == 0)
end)
```

- [ ] **Step 2: Run to verify failure** — nil-value call on `FilterGroups`.
- [ ] **Step 3: Implement:**

```lua
-- Line-level visibility: filters choose LINES, and a line travels whole.
-- `match` sees take rows and line reps alike -- both are overview rows, so
-- one predicate (character, search, per-column needles) serves both.
function vo.FilterGroups(nodes, match)
  local out, pending_char = {}, nil
  for _, node in ipairs(nodes or {}) do
    if node.kind == "character" then
      pending_char = node
    elseif node.kind == "line" then
      local visible = match(node.rep)
      if not visible then
        for _, t in ipairs(node.takes) do
          if match(t) then visible = true break end
        end
      end
      if visible then
        if pending_char then out[#out + 1] = pending_char; pending_char = nil end
        out[#out + 1] = node
      end
    elseif node.kind == "orphans" then
      local kept = {}
      for _, t in ipairs(node.takes) do
        if match(t) then kept[#kept + 1] = t end
      end
      if #kept > 0 then
        out[#out + 1] = { kind = "orphans", takes = kept }
      end
    end
  end
  return out
end
```

- [ ] **Step 4: Run tests** — green.
- [ ] **Step 5: Commit** — `git commit -am "feat: line-level FilterGroups for nested Overview"`

---

### Task 3: Collapsed-line persistence in the project file

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — `vo.SerializeProjectFile` / `vo.ParseProjectFile` view section (locate with `grep -n "view" VO/lib/ajsfx_vo.lua` around the existing `character`/`search`/`col_filters` handling)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: existing view round-trip (`character`, `search`, `filter_row`, `col_filters`).
- Produces: `view.collapsed` — an array of line-key strings (`script_row` numbers serialize as strings; `asset:`-prefixed keys pass through) that survives a serialize→parse round trip. Absent means empty.

- [ ] **Step 1: Failing test** (mirror however the existing view round-trip test in `tests/test_vo.lua` builds its arguments — copy its serialize call shape exactly, adding `collapsed`):

```lua
print("Collapsed persistence:")

test("view.collapsed round-trips", function()
  local text = vo.SerializeProjectFile({}, {
    scripts = {}, appends = {}, pins = {},
    view = { character = nil, search = "", filter_row = false,
             col_filters = {}, collapsed = { "3", "asset:grum_01" } },
  })
  local parsed = assert(vo.ParseProjectFile(text))
  local got = (parsed.view or {}).collapsed or {}
  assert(#got == 2, "expected 2 collapsed keys, got " .. #got)
  assert(got[1] == "3" and got[2] == "asset:grum_01")
end)

test("absent collapsed parses as nil/empty without error", function()
  local text = vo.SerializeProjectFile({}, { scripts = {}, appends = {}, pins = {}, view = {} })
  local parsed = assert(vo.ParseProjectFile(text))
  local got = (parsed.view or {}).collapsed
  assert(got == nil or #got == 0)
end)
```

- [ ] **Step 2: Run to verify failure.**
- [ ] **Step 3: Implement** in the same style the view section already serializes `col_filters` (read that code first and copy its escaping/format; a simple `collapsed=key1;key2` line in the view block matching the file's existing key=value grammar is expected). Keys must never contain the file's own delimiters — sanitize by rejecting keys containing the delimiter rather than escaping.
- [ ] **Step 4: Run tests** — green, including all pre-existing project-file tests.
- [ ] **Step 5: Commit** — `git commit -am "feat: persist collapsed Overview lines in project file view"`

---### Task 4: View lib re-key — new columns, mirror removed

**Files:**
- Modify: `VO/lib/ajsfx_vo_view.lua`
- Modify: `VO/ajsfx_VO_Overview.lua` (mirror call sites)
- Test: `tests/test_vo_view.lua`

**Interfaces:**
- Produces: `view.WRAP_DEFAULTS = { text = true }` (the shared Text column wraps out of the box; the old `line_text` default is gone). `view.LoadMirror`/`view.SaveMirror` deleted.
- The Overview's new column keys (Task 5) are: `order`, `state`, `sel`, `keep`, `lock`, `text`, `name`, `where`, `notes` — view records are keyed by these; `view.LoadColumn`/`SaveColumn`/`ClearColumns` are key-agnostic and need no change.

- [ ] **Step 1: Update tests** in `tests/test_vo_view.lua`: change any `line_text` wrap-default assertion to `text`; delete mirror tests. Add:

```lua
test("text column wraps by default, transcript key no longer special", function()
  assert(view.NormalizeColumn("text", nil).wrap == true)
  assert(view.NormalizeColumn("line_text", nil).wrap == false)
  assert(view.NormalizeColumn("transcript", nil).wrap == false)
end)

test("mirror API is gone", function()
  assert(view.LoadMirror == nil and view.SaveMirror == nil)
end)
```

- [ ] **Step 2: Run to verify the new tests fail.**
- [ ] **Step 3: Implement** in `ajsfx_vo_view.lua`: set `view.WRAP_DEFAULTS = { text = true }`; delete `view.LoadMirror` and `view.SaveMirror` (lines ~143-152).
- [ ] **Step 4: Strip mirror from the Overview script:** delete `MIRROR_PAIR` and the twin-write in `SetColumnView` (~lines 1863-1876), the mirror sync in the view-load block (~1843-1848), the `mirror` field init in `state.view`, and the "Keep the two columns…" settings checkbox (~line 4651 area — grep `mirror` for every site). `SetColumnView` reduces to a plain `WriteColumnView` call — keep the function so call sites don't churn.
- [ ] **Step 5: Run tests** — green. The script still runs (mirror was self-contained).
- [ ] **Step 6: Commit** — `git commit -am "refactor: re-key view defaults for merged Text column, drop mirror"`

---

### Task 5: New COLUMNS, sorting removed, grouped ApplyFilters

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`

**Interfaces:**
- Consumes: `vo.GroupOverview`, `vo.FilterGroups` (Tasks 1-2), `parsed.view.collapsed` (Task 3).
- Produces (used by Task 6):
  - `COLUMNS` — the 9 physical columns below; `CI` unchanged in mechanism.
  - `state.nodes` — filtered draw list; `state.visible` — flat array of the take rows inside `state.nodes` (parents' takes then orphans), preserving order. Everything that consumed `state.visible` (selection ranges, `SelectedRows`, Cut/Pull/Sort scoping, the remote `rows` command) keeps working against take rows only.
  - `state.collapsed` — set keyed by tostring(line key); `LineNodeKey(node) = tostring(node.rep.script_row or ("asset:" .. tostring(node.rep.asset)))`.

- [ ] **Step 1: Replace `COLUMNS`** (lines 125-206). Filter/`text` accessors keep the filter row and search working; `num` accessors and `tip`s tied to dead columns go:

```lua
local COLUMNS = {
  { key = "order", label = "#",     width =  48, nofilter = true },
  { key = "state", label = "State", width =  24, nofilter = true,
    tip = "Line: status dot, delivered count, and what still needs deciding.\n" ..
          "Take: status dot. Hover any dot for the words." },
  { key = "sel",   label = "",      width =  30, nofilter = true },
  { key = "keep",  label = "",      width =  30, nofilter = true },
  { key = "lock",  label = "",      width =  30, nofilter = true },
  { key = "text",  label = "Text",  width = 260,
    text = function(row) return (row.line_text or "") .. " " .. (row.transcript or "") end,
    tip = "Line: what the script says. Take: what was actually said,\n" ..
          "directly beneath it for comparison." },
  { key = "name",  label = "Name",  width = 190,
    text = function(row)
      return (row.take_name or row.name_override or "") .. " "
          .. (row.deliver or row.asset or "")
    end,
    tip = "Line: the delivered name (CSV filename + Append, dimmed).\n" ..
          "Take: the item's own name. Editable on takes; double-click the\n" ..
          "line's name to edit its Append." },
  { key = "where", label = "Where", width = 140,
    text = function(row)
      return (row.script or "") .. " "
          .. (row.source_path and vo.Basename(row.source_path) or "")
    end,
    tip = "Line: which script CSV, and its row.\nTake: which recording, and when." },
  { key = "notes", label = "Notes", width = 170,
    text = function(row) return row.notes or "" end },
}
```

- [ ] **Step 2: Delete display sorting.** Remove: `SORT_SPECS`/`NEED_SORT`/`SORT_DESC` (lines 72-74), `SORT_RANK` (99), `state.sort_col`/`state.sort_desc` (309-310), `ReadSortSpec` (3846-3855) and its call (3903), the `Sortable`/`SortTristate` flags in `DrawTable` (4331-4337), the `NoSort` flag branch in the column setup (3875-3880), and the whole sort block in `ApplyFilters` (1746-1761). Grep `sort_col|sort_desc|SORT_` afterwards — zero hits outside the timeline-layout code (`layout_order` is a different feature; leave it).

- [ ] **Step 3: Rewrite `ApplyFilters`** (1738-1778):

```lua
local function LineNodeKey(node)
  return tostring(node.rep.script_row or ("asset:" .. tostring(node.rep.asset)))
end

local function ApplyFilters()
  CheckRestoredCharacter()
  for i, row in ipairs(state.overview) do row.order = i end

  state.nodes = vo.FilterGroups(vo.GroupOverview(state.overview), Matches)

  -- The flat take list every existing consumer keeps reading: selection
  -- ranges, SelectedRows, tool scoping, the remote `rows` dump. Parents and
  -- headers are not in it -- only takes are selectable or actionable.
  local flat = {}
  for _, node in ipairs(state.nodes) do
    if node.kind == "line" or node.kind == "orphans" then
      for _, t in ipairs(node.takes) do flat[#flat + 1] = t end
    end
  end
  state.visible = flat

  local kept = {}
  for _, row in ipairs(flat) do
    if state.selection[row.uid] then kept[row.uid] = true end
  end
  state.selection = kept
  local visible_key = {}
  for _, row in ipairs(flat) do visible_key[row.uid] = true end
  if state.focus_key and not visible_key[state.focus_key] then state.focus_key = nil end
  if state.anchor    and not visible_key[state.anchor]    then state.anchor    = nil end
end
```

  `Matches` (1688-1710) itself is untouched — it already works per-row and now serves as the `FilterGroups` predicate. Note it consults `COLUMN_BY_KEY`, which now resolves the new keys; stale `col_filters` under old keys were already dropped at load by the `COLUMN_BY_KEY[key]` guard (line 490).

- [ ] **Step 4: Collapse state.** Add `collapsed = {}` to `state`; in `LoadProjectFile` after `state.check_character = ...` add:

```lua
    state.collapsed = {}
    for _, k in ipairs(v.collapsed or {}) do state.collapsed[k] = true end
```

  In `SaveProjectFile`'s view table add:

```lua
        collapsed   = (function()
          local out = {}
          for k in pairs(state.collapsed or {}) do out[#out + 1] = k end
          table.sort(out)
          return out
        end)(),
```

- [ ] **Step 5: Sanity run.** Launch check is Task 6's job (the draw loop still addresses dead `CI` keys and will error under its pcall) — for now run `./run_tests.sh` (green) and `luac -p VO/ajsfx_VO_Overview.lua` if available (else `lua -e "loadfile('VO/ajsfx_VO_Overview.lua')"` syntax-checks without executing).
- [ ] **Step 6: Commit** — `git commit -am "refactor: grouped ApplyFilters, new column set, display sorting removed"`

---

### Task 6: The draw loop — node-typed rows

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — `DrawTableBody` (3872-4325) and `DrawFilterRow`

**Interfaces:**
- Consumes: `state.nodes`, `state.visible`, `state.collapsed`, `LineNodeKey`, rollups from Task 1; every existing cell helper (`CellText`, `CellWidget`, `PushFilledField`/`PopFilledField`, `AlignCell`, `BeginRowMeasure`/`EndRowMeasure`, `RowHeight`), `DELIVERY`, `STATUS_STYLE`, `MakeSelect`, `SetSelect`, `SetKeep`, `SetLock`, `SetNotes`, `SetAppend`, `Rename`, `ResetName`, `ClickRow`, `SelectedRows`, `Copy`, `TooltipEvenWhenDisabled`.
- Produces: the rendered tree. Structure of the new row loop (replacing lines 3919-4324):

```lua
  -- Take rows carry their index in state.visible so ClickRow's shift-range
  -- arithmetic is unchanged.
  local flat_index = {}
  for i, row in ipairs(state.visible) do flat_index[row.uid] = i end

  for ni, node in ipairs(state.nodes) do
    im.PushID(ctx, ni)
    id_depth = id_depth + 1
    if node.kind == "character" then
      DrawCharacterRow(node)
    elseif node.kind == "orphans" then
      DrawOrphanHeaderRow()
      for ti, t in ipairs(node.takes) do
        DrawTakeRow(t, ti, flat_index[t.uid])
      end
    else
      local key = LineNodeKey(node)
      local open = not state.collapsed[key]
      DrawParentRow(node, key, open)
      if open and #node.takes > 0 then
        DrawSubHeaderRow()
        for ti, t in ipairs(node.takes) do
          DrawTakeRow(t, ti, flat_index[t.uid])
        end
      end
    end
    im.PopID(ctx)
    id_depth = id_depth - 1
  end
```

- [ ] **Step 1: `DrawCharacterRow(node)`** — one row, first cell, name spanning visually via a full-row background:

```lua
local function DrawCharacterRow(node)
  im.TableNextRow(ctx)
  im.TableSetColumnIndex(ctx, CI.order)
  im.TableSetBgColor(ctx, im.TableBgTarget_RowBg0, 0x2A2A33FF)
  im.TableSetColumnIndex(ctx, CI.text)
  im.TextDisabled(ctx, "— " .. node.name .. " —")
end
```

- [ ] **Step 2: `DrawSubHeaderRow()`** — dimmed labels over the checkbox columns, small font:

```lua
local function DrawSubHeaderRow()
  im.TableNextRow(ctx)
  local f = PushCellFont("state")  -- reuse the state column's font slot
  for key, label in pairs({ sel = "Sel", keep = "Keep", lock = "Lock" }) do
    im.TableSetColumnIndex(ctx, CI[key])
    im.TextDisabled(ctx, label)
  end
  PopCellFont(f)
end
```

  (Deterministic order matters for nothing here — each label lands in its own addressed cell.)

- [ ] **Step 3: `DrawParentRow(node, key, open)`** — arrow + line number; State rollup; line text; deliver+append; script·row; line note. The parent is NOT a Selectable row (clicking it does not select takes — see Task 7 step 3 for the deliberate simplification); the arrow toggles collapse:

```lua
local function DrawParentRow(node, key, open)
  local rep = node.rep
  local row_h = RowHeight(rep)
  BeginRowMeasure(rep)
  im.TableNextRow(ctx)

  im.TableSetColumnIndex(ctx, CI.order)
  local arrow = (#node.takes > 0) and (open and "v " or "> ") or "  "
  if im.Selectable(ctx, arrow .. tostring(rep.order or ""), false) then
    if #node.takes > 0 then
      if state.collapsed[key] then state.collapsed[key] = nil
      else state.collapsed[key] = true end
      state.dirty = true
    end
  end

  -- State rollup: dot + got badge + the loudest pending decision.
  im.TableSetColumnIndex(ctx, CI.state)
  local style = STATUS_STYLE[node.rollup.status] or STATUS_STYLE.missing
  local sf = PushCellFont("state")
  AlignCell("state", row_h, im.GetTextLineHeight(ctx))
  im.TextColored(ctx, style.colour, "●")
  PopCellFont(sf)
  if im.IsItemHovered(ctx) then
    local rec = rep.script_row and DELIVERY(rep.script_row)
    local bits = { style.label }
    bits[#bits + 1] = rec and (tostring(rec.count) .. " delivered") or "nothing delivered yet"
    if node.rollup.take_count > 0 and not node.rollup.has_sel then
      bits[#bits + 1] = "no Sel chosen yet"
    end
    if node.rollup.locks > 0 then
      bits[#bits + 1] = tostring(node.rollup.locks) .. " locked"
    end
    im.SetTooltip(ctx, table.concat(bits, "\n"))
  end
  -- The got badge rides in the Sel column on the parent (there is no
  -- checkbox there), keeping the dot column one glyph wide.
  im.TableSetColumnIndex(ctx, CI.sel)
  local rec = rep.script_row and DELIVERY(rep.script_row)
  if rep.status ~= "orphan" and rep.script_row then
    local gf = PushCellFont("sel")
    AlignCell("sel", row_h, im.GetTextLineHeight(ctx))
    if rec then im.TextColored(ctx, 0x66BB66FF, "✓" .. tostring(rec.count))
    else im.TextColored(ctx, 0xDD6666FF, "–") end
    PopCellFont(gf)
  end
  -- "no Sel yet" rollup text in the keep/lock space.
  if node.rollup.take_count > 0 and not node.rollup.has_sel then
    im.TableSetColumnIndex(ctx, CI.keep)
    im.TextColored(ctx, 0xDDAA33FF, "no Sel")
  end

  im.TableSetColumnIndex(ctx, CI.text)
  CellText(rep, "text", CI.text, row_h, rep.line_text, "plain")

  DrawParentNameCell(node, rep, row_h)   -- Step 4

  im.TableSetColumnIndex(ctx, CI.where)
  local origin = (rep.script or "")
  if rep.script_row then origin = origin .. " · " .. tostring(rep.script_row) end
  CellText(rep, "where", CI.where, row_h, origin, "disabled")

  DrawParentNotesCell(node, rep, row_h)  -- Step 5

  EndRowMeasure(rep)
end
```

- [ ] **Step 4: `DrawParentNameCell`** — deliver + dimmed append, red on clash, right-click menu (Copy / edit Append), double-click opens the same Append editor:

```lua
local function DrawParentNameCell(node, rep, row_h)
  im.TableSetColumnIndex(ctx, CI.name)
  local base = rep.asset or ""
  local shown = base .. ((rep.append and rep.append ~= "") and (" " .. rep.append) or "")
  local resolved = rep.deliver
  local clash = rep.line_key ~= nil and resolved ~= nil
                and state.dupe_names[resolved] == true
  CellText(rep, "name", CI.name, row_h, shown, clash and 0xDD6666FF or "disabled")
  if clash and im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "Another script line is delivered under this same name.\n" ..
                       "Type something in Append (right-click) to tell them apart.")
  end
  if rep.line_key and im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, 0) then
    im.OpenPopup(ctx, "##append_edit")
  end
  if base ~= "" and im.BeginPopupContextItem(ctx, "##parent_name_menu") then
    if im.MenuItem(ctx, "Copy") then Copy(base) end
    if rep.line_key and im.MenuItem(ctx, "Edit Append") then
      im.CloseCurrentPopup(ctx)
      pending_action = function() state.append_edit_uid = rep.uid end
    end
    im.EndPopup(ctx)
  end
  -- Inline swap: while this line is being edited the cell is an InputText.
  if state.append_edit_uid == rep.uid then
    PushFilledField("name", row_h)
    im.SetKeyboardFocusHere(ctx)
    local changed, text = im.InputText(ctx, "##append", rep.append or "",
                                       im.InputTextFlags_EnterReturnsTrue)
    PopFilledField()
    if changed then
      local captured = text
      pending_action = function() SetAppend(rep, captured); state.append_edit_uid = nil end
    elseif im.IsItemDeactivated(ctx) then
      state.append_edit_uid = nil
    end
  end
end
```

  (Add `append_edit_uid = nil` to `state`; note `SetAppend` needs `rep.append_key`, which the rep carries.) Simplify during implementation if the double-click popup + inline swap fight each other: the right-click "Edit Append" path alone satisfies the spec's edit-on-demand requirement; keep whichever is stable.

- [ ] **Step 5: `DrawParentNotesCell`** — line-level note. Backing storage: an entry keyed to the line, created through `EntryFor` with a synthetic row (the entry serializer keeps unknown keys happily; `BuildOverview` ignores entries no row claims):

```lua
local function LineNoteRow(rep)
  return { key = "linenote|" .. tostring(rep.script_row or rep.asset or ""),
           source_path = nil, source_start = nil, asset = rep.asset }
end

local function LineNote(rep)
  local key = "linenote|" .. tostring(rep.script_row or rep.asset or "")
  for _, e in ipairs(state.entries) do
    if e.key == key then return e.notes or "" end
  end
  return ""
end

local function DrawParentNotesCell(node, rep, row_h)
  im.TableSetColumnIndex(ctx, CI.notes)
  PushFilledField("notes", row_h)
  local changed, text = im.InputText(ctx, "##linenote", LineNote(rep))
  PopFilledField()
  if changed then
    local captured, target = text, LineNoteRow(rep)
    pending_action = function() SetNotes(target, captured) end
  end
end
```

  Verify `vo.ProjectEntriesFromRows(state.overview)` (used by `SaveProjectFile`) preserves entries that back no row — read it; if it rebuilds entries FROM rows and would drop line notes, extend `SaveProjectFile` to append the `linenote|`-keyed entries from `state.entries` before serializing, and add a `tests/test_vo.lua` round-trip test for an entry with a `linenote|` key surviving `SerializeProjectFile`→`ParseProjectFile`.

- [ ] **Step 6: `DrawTakeRow(row, take_no, vis_index)`** — port of the old body's row loop, reduced to take-side cells. Reuse verbatim from the old code (lines given): the spanning Selectable + right-click row menu (3946-4056) lands in the **state** column; Sel checkbox (4126-4142) → `sel` column; Keep (4144-4162) → `keep`; Lock checkbox (3934-3944) → `lock`; transcript CellText + review tooltip (4276-4291) → `text`; item-name InputText / "(no item)" / missing branches (4170-4204) plus the old CSV-cell context menu's "Reset item name" (4228-4238, fold into the name cell's context menu alongside Copy) → `name`; source+time merged → `where` with the old double-click-to-Sources handoff (4296-4306):

```lua
  im.TableSetColumnIndex(ctx, CI.order)
  CellText(row, "order", CI.order, row_h, tostring(take_no), "disabled")
  ...
  im.TableSetColumnIndex(ctx, CI.state)
  -- spanning Selectable ##row exactly as before (uses vis_index for ClickRow),
  -- then the status dot:
  local style = STATUS_STYLE[row.status]
  im.SameLine(ctx)
  local sf = PushCellFont("state")
  AlignCell("state", row_h, im.GetTextLineHeight(ctx))
  if row.user_status == "flagged" then im.TextColored(ctx, 0xDD6666FF, "●")
  elseif style then im.TextColored(ctx, style.colour, "●") end
  PopCellFont(sf)
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, row.user_status == "flagged" and "Flagged" or (style and style.label or ""))
  end
  ...
  im.TableSetColumnIndex(ctx, CI.where)
  local where = row.source_path
    and (vo.Basename(row.source_path) .. " @ " .. FormatTime(row.proj_time)) or ""
  CellText(row, "where", CI.where, row_h, where, "disabled")
  -- keep the double-click Sources handoff here
```

  The old per-take Notes InputText (4312-4319) moves unchanged to `notes`. The old `markable` guard becomes simply `#row-has-audio` — every take row by construction has audio, so Sel/Keep/Lock draw unconditionally on take rows. `MarkTargets` survives as-is (it reads `SelectedRows()`, which is take-rows-only now by construction).

- [ ] **Step 7: Filter row + header + freeze.** `DrawFilterRow` already skips `nofilter` columns — with the new COLUMNS only text/name/where/notes get boxes; no change needed. Header loop (3889-3899) unchanged. `TableSetupScrollFreeze` unchanged.
- [ ] **Step 8: Launch REAPER and eyeball** (use the VO MCP harness fixture): headers, a character section, expand/collapse, sub-header labels, checkbox ticks writing through, append edit, rename, notes both levels, orphan section, filter boxes, narrow-window behavior. Fix what's broken — this step is where the ImGui details (SameLine after Selectable, popup IDs) get trued up.
- [ ] **Step 9: Commit** — `git commit -am "feat: nested line/take rows in Overview table"`

---

### Task 7: Selection polish + remote/tool audit

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`

**Interfaces:**
- Consumes: everything above.
- Produces: no API; behavioral guarantees for Cut/Pull/Sort scoping and the remote `rows` command.

- [ ] **Step 1: Audit every consumer of `state.visible`** (grep `state.visible`): `SelectedRows` (1299), `ClickRow` ranges (1653+), scroll-follow (`scroll_to_uid`), Cut/Pull/Sort `AffectedRows`/count memos, the remote `rows` dump, the empty-table message (3907). Each must be verified take-rows-only-safe; the empty-state check becomes `#state.nodes == 0`.
- [ ] **Step 2: Shift-click ranges** across collapsed lines: `ClickRow` walks `state.visible` indices — takes of a COLLAPSED line are still in `state.visible` (they are filtered by visibility of the LINE, not by collapse). Decide: exclude collapsed lines' takes from `state.visible` (so ranges match what the eye sees) by skipping `state.collapsed[LineNodeKey(node)]` lines when flattening in `ApplyFilters`. Do that — the spec's principle (selection never outlives visibility, line 1765's comment) demands it. Takes of collapsed lines also drop out of `state.selection` automatically via the existing kept-filter.
- [ ] **Step 3: Parent-selects-takes** (spec: "selecting a parent selects its takes"): implement as — clicking the parent row's State-column area (the parent has no spanning Selectable; add a plain `Selectable` in the parent's state cell) toggles selection of all its takes via `pending_action` looping `state.selection[t.uid] = true`. If it turns out clumsy in live use, note it for the user rather than gold-plating.
- [ ] **Step 4: Expand/collapse all** — two small buttons beside the existing Filters toggle in the toolbar: `[Expand all] [Collapse all]` → `state.collapsed = {}` / set every line key. Straight port of the toolbar button pattern already there.
- [ ] **Step 5: Live check again** (MCP harness): shift-ranges, collapse-then-mark, Cut panel counts with `selection_only`, remote `rows` dump unchanged in shape.
- [ ] **Step 6: Commit** — `git commit -am "feat: selection, collapse-aware ranges, expand/collapse all"`

---

### Task 8: Dead code sweep, docs, version, release prep

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`, `VO/SPEC-overview.md`
- Test: full suite + live REAPER

**Interfaces:** none new.

- [ ] **Step 1: Sweep.** Grep and remove now-unreferenced: `SORT_RANK` remnants, `StatusLabel`/`ItemName` if unreferenced, `FormatTime` stays (Where cell), old column tips, `TAKE_PICKS` stays (config), `HEADER_ROW_FLAGS` stays. `luac -p` / load-check after.
- [ ] **Step 2: Update `VO/SPEC-overview.md`** — rewrite the table-layout section to describe the nested model (crib from the design spec's Row model + column table; keep SPEC voice). Mention: no display sorting, always script order, collapse persistence, line notes.
- [ ] **Step 3: Version.** In the `ajsfx_VO_Overview.lua` header: `-- @version 0.15beta1` and a `@changelog` entry summarizing the redesign in user-facing terms (what changed on screen, that letter-versions are opt-in). Per CLAUDE.md the changelog ships to ReaPack users.
- [ ] **Step 4: Full test run** — `./run_tests.sh` green.
- [ ] **Step 5: Live session check** in REAPER on the real project (Grumbar session): open, mark, rename, cut counts sane, no console errors.
- [ ] **Step 6: Commit** — `git commit -am "feat: VO Overview nested rows — 0.15beta1"` and push the feature branch: `git push -u origin feature/vo-overview-nested-rows`. Confirm CI: `gh run list --limit 1` green, and skim the build log for reapack-index warnings. Do NOT merge to main — that publishes; hand back to the user.

---

## Self-review notes

- Spec coverage: row model (T1), filters (T2), collapse persistence (T3), view re-key/mirror removal (T4), columns + no sorting (T5), draw loop incl. State group, sub-headers, Name/Append, Where, line notes (T6), selection + expand-all (T7), pre-release versioning + SPEC (T8). Sort panel: untouched (explicitly out of scope).
- Known judgment calls deferred to live testing, flagged in their tasks: append double-click vs right-click (T6.4), parent-selects-takes ergonomics (T7.3), got-badge placement in the Sel column (T6.3).
- `vo.ProjectEntriesFromRows` behavior with unclaimed `linenote|` entries is a verification step inside T6.5, with a test required if it drops them.
