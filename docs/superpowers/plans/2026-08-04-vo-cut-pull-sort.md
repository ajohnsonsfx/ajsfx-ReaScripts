# VO Cut, Pull and Sort Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split ajsfx VO's one cut-and-route operation into three tools — Cut and
Name, Pull, Sort — where Pull and Sort identify items by NAME rather than by the
transcript match, so they work equally on takes cut from a session recording and
on rendered wav files someone else delivered.

**Architecture:** Every decision lands in the pure layer of `VO/lib/ajsfx_vo.lua`
as a function of plain tables, tested headlessly by `tests/test_vo.lua`. The
REAPER-coupled layer stays thin: split an item, move an item, make a track. The
three tools become inline panels in `VO/ajsfx_VO_Overview.lua`, replacing the
separate `ajsfx_VO_Cut.lua` window and the inline layout bar.

**Tech Stack:** Lua 5.4, REAPER API, ReaImGui 0.9.x, ReaPack. Tests are plain
Lua against `tests/mock_reaper.lua`.

**Spec:** `docs/superpowers/specs/2026-08-04-vo-cut-pull-sort-design.md`

## Global Constraints

- **Pure layer first.** Anything that decides something goes in `VO/lib/ajsfx_vo.lua`
  above the "Coupled layer" comment and is unit-tested. Functions that touch
  `reaper` go below it and are checked by `VO/MANUAL_TEST.md`.
- **Nothing is ever renamed automatically.** Names change only where the user
  typed them or pressed a button that says it renames.
- **No project-file version bump.** `vo.PROJECT_VERSION` stays 1. New preamble
  keys are additive; unknown keys are already skipped by `vo.ParseProjectFile`.
- **Project-file `Select` field** carries `yes` (select), `alt` (alt), or empty.
  A file written before this reads `yes` as select, anything else as unmarked.
- **Track names:** `<CHARACTER>_Selects`, `_Alts`, `_Outs`, `_Review`, built by
  `vo.CharacterTrackName(character, base)`; bases come from
  `cfg.track_selects` / `track_alts` / `track_outs` / `track_review`.
- **Undo:** every project mutation runs inside `core.Transaction("...", fn)`.
- **Commit style:** conventional commits, `feat(VO):` / `refactor(VO):` /
  `test(VO):`, body in prose explaining WHY. Sign off with
  `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- **Run `./run_tests.sh` before every commit.** It must end `0 failed`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `VO/lib/ajsfx_vo.lua` | pure decisions + thin REAPER apply | modify |
| `tests/test_vo.lua` | the pure layer's tests | modify |
| `VO/ajsfx_VO_Overview.lua` | the one window: table, panels, toolbar | modify |
| `VO/ajsfx_VO_Cut.lua` | the old cut window | **delete** (Task 9) |
| `VO/SPEC-overview.md`, `VO/SPEC.md` | the specs these change | modify (Task 9) |
| `VO/MANUAL_TEST.md` | REAPER-side checks | modify (Tasks 6, 7, 8) |

Order matters: Tasks 1–4 are pure and independent of the UI; 5 is the one new
coupled helper; 6–8 build the three panels on top; 9 does the toolbar, the
deletions and the docs.

---

### Task 1: Resolve an item's name to a script line

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (pure layer, beside `vo.ResolveNames` at ~line 489)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.ResolveNames(lines, appends)` sets `line.deliver`; each line has
  `asset`, `deliver`, `index` (position across the merged list).
- Produces:
  - `vo.NormalizeItemName(name) -> string` — lowercased, trimmed, extension removed
  - `vo.BuildNameIndex(lines) -> index` — opaque table
  - `vo.ResolveItemName(index, name) -> line_index | nil, reason`
    where `reason` is `nil` on a hit, `"unknown"` when nothing matches, and
    `"ambiguous"` when two lines claim the key.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua`, immediately after the `MergeScriptLines` block
(after the `no filename is modified by merging` test, ~line 380):

```lua
--------------------------------
-- Name resolution
--------------------------------
print("\nResolveItemName:")

local function name_lines(...)
  local lines = {}
  for i, a in ipairs({...}) do
    lines[i] = { asset = a, deliver = a, index = i, text = "line " .. a }
  end
  return lines
end

test("case, padding and extension are not part of a name", function()
  assert(vo.NormalizeItemName("Line_042.wav") == "line_042",
    "Got " .. vo.NormalizeItemName("Line_042.wav"))
  assert(vo.NormalizeItemName("  line_042  ") == "line_042", "whitespace")
  assert(vo.NormalizeItemName("line_042") == "line_042", "already clean")
end)

test("only a trailing extension is removed, never part of the name", function()
  -- A filename may legitimately contain dots; only the last short suffix goes.
  assert(vo.NormalizeItemName("vo.guard.halt.wav") == "vo.guard.halt",
    "Got " .. vo.NormalizeItemName("vo.guard.halt.wav"))
  assert(vo.NormalizeItemName("line_042_v1.2") == "line_042_v1.2",
    "A numeric tail is not an extension: " .. vo.NormalizeItemName("line_042_v1.2"))
end)

test("an item resolves to the line that names it", function()
  local idx = vo.BuildNameIndex(name_lines("line_041", "line_042"))
  assert(vo.ResolveItemName(idx, "line_042.WAV") == 2, "should resolve to line 2")
  assert(vo.ResolveItemName(idx, "line_041") == 1, "should resolve to line 1")
end)

test("an item resolves through the delivered name too", function()
  -- What Pull renamed on a previous run must still be recognisable, or a second
  -- Pull would see its own output as unknown audio.
  local lines = name_lines("line_042")
  lines[1].deliver = "line_042_ch2"
  local idx = vo.BuildNameIndex(lines)
  assert(vo.ResolveItemName(idx, "line_042_ch2") == 1, "delivered name")
  assert(vo.ResolveItemName(idx, "line_042") == 1, "plain name still works")
end)

test("a name no line claims resolves to nothing, and says why", function()
  local idx = vo.BuildNameIndex(name_lines("line_042"))
  local hit, why = vo.ResolveItemName(idx, "RIVA_session_take3")
  assert(hit == nil, "must not resolve")
  assert(why == "unknown", "Got " .. tostring(why))
end)

test("a name two lines claim resolves to nothing rather than guessing", function()
  local idx = vo.BuildNameIndex(name_lines("line_042", "line_042"))
  local hit, why = vo.ResolveItemName(idx, "line_042")
  assert(hit == nil, "an ambiguous name must not pick one")
  assert(why == "ambiguous", "Got " .. tostring(why))
end)

test("a line whose Append separates it from its twin resolves again", function()
  local lines = name_lines("line_042", "line_042")
  lines[2].deliver = "line_042_ch2"
  local idx = vo.BuildNameIndex(lines)
  assert(vo.ResolveItemName(idx, "line_042_ch2") == 2, "the appended one is unambiguous")
  assert(vo.ResolveItemName(idx, "line_042") == nil, "the bare name is still shared")
end)

test("an empty or missing name resolves to nothing", function()
  local idx = vo.BuildNameIndex(name_lines("line_042"))
  assert(vo.ResolveItemName(idx, "") == nil, "empty")
  assert(vo.ResolveItemName(idx, nil) == nil, "nil")
end)
```

- [ ] **Step 2: Run them and watch them fail**

```bash
./run_tests.sh
```

Expected: `FAIL: ... attempt to call a nil value (field 'NormalizeItemName')`.

- [ ] **Step 3: Implement**

Insert into `VO/lib/ajsfx_vo.lua` directly after `vo.ResolveNames` ends
(~line 495, before the `-- Pure layer: script loading` comment):

```lua
--------------------------------
-- Pure layer: name resolution
--------------------------------

-- What identifies an item is its NAME, not the transcript. Two cases need
-- serving with one mechanism: takes this session cut out of a long recording,
-- and rendered files delivered by someone else with no transcript at all. Both
-- carry the script's filename, so both resolve the same way.

-- A file extension is a delivery detail, not part of the name. Only a SHORT
-- ALPHABETIC tail counts as one: "line_042_v1.2" ends in a number, which is
-- part of what the file is called, and stripping it would merge two deliveries.
function vo.NormalizeItemName(name)
  local s = trim(tostring(name or "")):lower()
  return (s:gsub("%.(%a%a?%a?%a?)$", ""))
end

-- Two keys per line: the script's own filename, and the DELIVERED name (that
-- filename plus its Append, or the user's override). The delivered name is one
-- this tool wrote, so recognising it is reading our own output back, not a
-- guess -- it is what lets a second Pull see what the first one renamed.
--
-- A key two lines claim is deliberately POISONED rather than assigned to the
-- first: that clash is what the Append column exists to fix, and picking one
-- would put one line's audio under the other's name.
function vo.BuildNameIndex(lines)
  local index = {}
  local function add(key, line_index)
    if key == "" then return end
    if index[key] == nil then
      index[key] = line_index
    elseif index[key] ~= line_index then
      index[key] = false           -- false means "claimed twice"
    end
  end

  for i, l in ipairs(lines or {}) do
    local at = l.index or i
    add(vo.NormalizeItemName(l.asset), at)
    if l.deliver and l.deliver ~= l.asset then
      add(vo.NormalizeItemName(l.deliver), at)
    end
  end
  return index
end

-- Returns the line index, or nil plus "unknown" / "ambiguous". An item that
-- resolves to nothing is never touched by Pull or Sort -- an uncut recording
-- carries the recording's name, which is not a script filename, and that is
-- what keeps both tools off audio they were not asked to move.
function vo.ResolveItemName(index, name)
  local key = vo.NormalizeItemName(name)
  if key == "" then return nil, "unknown" end
  local at = (index or {})[key]
  if at == nil then return nil, "unknown" end
  if at == false then return nil, "ambiguous" end
  return at
end
```

`trim` is already a local at the top of the file; no new helper is needed.

- [ ] **Step 4: Run the tests**

```bash
./run_tests.sh
```

Expected: every new test PASS, `0 failed` overall.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "feat(VO): resolve an item to a script line by its name"
```

---

### Task 2: The Select column becomes three-state

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — `vo.SerializeProjectFile` (~2719), `vo.ParseProjectFile` (~2815), `vo.ProjectEntriesFromRows` (~3145), `vo.BuildOverview` (~3030, 3083)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Produces: an entry's `select` field is now the string `"select"`, `"alt"`, or
  `nil` — never a boolean. Overview rows carry `row.user_mark` with the same
  three values. `row.user_select` is gone; every reader uses
  `row.user_mark == "select"`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua` in the `SerializeProjectFile / ParseProjectFile`
block, after the `a full entry survives the round trip` test:

```lua
test("a select and an alt round-trip as distinct marks", function()
  local out = round_trip({
    { key = "A.wav|1000", asset = "line_042", select = "select" },
    { key = "A.wav|2000", asset = "line_042", select = "alt" },
    { key = "A.wav|3000", asset = "line_042", notes = "spare" },
  })
  assert(out.entries[1].select == "select", "Got " .. tostring(out.entries[1].select))
  assert(out.entries[2].select == "alt", "Got " .. tostring(out.entries[2].select))
  assert(out.entries[3].select == nil, "An unmarked take carries no mark")
end)

test("a file written before alts existed still reads its selects", function()
  -- The old writer put "yes" in this field. Anything else it could have held
  -- was never a mark, so it reads as unmarked rather than as an alt.
  local text = table.concat({
    "ajsfx VO Project,1", "", PF_HEADER,
    "A.wav|1000,line_042,D:\\A.wav,1.000,yes,,,",
    "A.wav|2000,line_042,D:\\A.wav,2.000,,,,x",
  }, "\n")
  local out = vo.ParseProjectFile(text)
  assert(out, "must parse")
  assert(out.entries[1].select == "select", "yes means select")
  assert(out.entries[2].select == nil, "empty means unmarked")
end)
```

- [ ] **Step 2: Run them and watch them fail**

```bash
./run_tests.sh
```

Expected: `FAIL: a select and an alt round-trip as distinct marks` — the writer
still emits `yes` for anything truthy, so the alt comes back as `"select"`.

- [ ] **Step 3: Implement — the pure layer**

In `vo.SerializeProjectFile`, the entry row currently writes
`e.select and "yes" or ""`. Replace with:

```lua
        e.select == "select" and "yes" or (e.select == "alt" and "alt" or ""),
```

And its `has_work` test above it — `(e.select == true)` — becomes:

```lua
    local has_work = (e.select ~= nil)
```

In `vo.ParseProjectFile`, the entry loop's `select = fold(row[5] or "") == "yes"`
becomes:

```lua
        -- Three states in one field. "yes" is what the pre-alts writer emitted,
        -- so it still reads as a select; anything unrecognised is no mark at
        -- all rather than a mark we cannot honour.
        select        = SELECT_MARKS[fold(row[5] or "")] or nil,
```

with, above `vo.ParseProjectFile`:

```lua
local SELECT_MARKS = { yes = "select", select = "select", alt = "alt" }
```

In `vo.ProjectEntriesFromRows`, `select = row.user_select == true` becomes:

```lua
      select        = row.user_mark,
```

In `vo.BuildOverview`, both places that read the entry — `make_row`'s
`user_select = t and t.select == true or false` and the missing-line branch's
identical line — become:

```lua
      user_mark     = t and t.select or nil,
```

and the primary-take loop just above the missing-line branch, which reads

```lua
      for _, row in ipairs(built) do
        if row.user_select then chosen = row; break end
      end
```

becomes

```lua
      for _, row in ipairs(built) do
        if row.user_mark == "select" then chosen = row; break end
      end
```

- [ ] **Step 4: Run the tests**

```bash
./run_tests.sh
```

Expected: both new tests PASS. Existing tests that assert on `user_select` will
fail — fix each by reading `user_mark == "select"`, and set marks in fixtures
with `select = "select"` instead of `select = true`.

- [ ] **Step 5: Fix the Overview callers**

`grep -n "user_select" VO/ajsfx_VO_Overview.lua` lists five sites. Each becomes
`row.user_mark == "select"`. The column accessor at line ~137:

```lua
    text = function(row)
      return row.user_mark == "select" and "select"
          or (row.user_mark == "alt" and "alt" or "")
    end,
```

`SetSelect(row, on)` (~line 693) becomes a cycle, and its exclusivity rule now
applies only to the select mark:

```lua
-- blank -> select -> alt -> blank. Exactly one take of a line may be the
-- SELECT, so marking one clears the rest of its group; any number may be alts,
-- because an alt is an extra delivery rather than the decision about which take
-- the delivery is.
local NEXT_MARK = { [false] = "select", select = "alt", alt = false }

local function CycleMark(row)
  local now = NEXT_MARK[row.user_mark or false]
  if now == "select" then
    for _, other in ipairs(state.overview) do
      if other ~= row and other.asset == row.asset and other.status ~= "orphan"
         and other.user_mark == "select" then
        Mutate(other, function(e) e.select = nil end)
      end
    end
  end
  Mutate(row, function(e) e.select = now or nil end)
end
```

The cell at ~2457 becomes a button rather than a checkbox, since a checkbox
cannot show three states:

```lua
      CellWidget("select", row_h)
      local mark  = row.user_mark
      local label = mark == "select" and "SEL" or (mark == "alt" and "ALT" or "--")
      if im.Button(ctx, label .. "##sel", -1, 0) then
        pending_action = function() CycleMark(row) end
      end
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx,
          "Click to cycle: unmarked -> SEL (the take you deliver)\n" ..
          "-> ALT (delivered as well) -> unmarked.\n" ..
          "One SEL per line; any number of ALTs.")
      end
```

- [ ] **Step 6: Run the tests and syntax-check**

```bash
luac -p VO/ajsfx_VO_Overview.lua VO/lib/ajsfx_vo.lua && ./run_tests.sh
```

Expected: `0 failed`, no syntax errors.

- [ ] **Step 7: Commit**

```bash
git add VO/lib/ajsfx_vo.lua VO/ajsfx_VO_Overview.lua tests/test_vo.lua
git commit -m "feat(VO): a take can be marked an alt as well as the select"
```

---

### Task 3: Decide where each item is pulled

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (pure layer, after Task 1's block)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.ResolveItemName` from Task 1; `user_mark` from Task 2.
- Produces: `vo.PlanPull(items, lines, marks) -> moves, summary`
  - `items`: `{ { id = <any>, name = <string> }, ... }` in timeline order
  - `lines`: the merged script lines (for `vo.BuildNameIndex`)
  - `marks`: `{ [item id] = "select" | "alt" }`
  - `moves`: `{ { id =, line =, dest = "selects"|"alts"|"outs"|"review",
    rename = <string|nil> }, ... }`
  - `summary`: `{ selects =, alts =, outs =, review =, unknown =, ambiguous = }`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo.lua` after Task 1's block:

```lua
--------------------------------
-- PlanPull
--------------------------------
print("\nPlanPull:")

local function pull_items(...)
  local items = {}
  for i, n in ipairs({...}) do items[i] = { id = i, name = n } end
  return items
end

local function dest_of(moves, id)
  for _, m in ipairs(moves) do if m.id == id then return m.dest end end
  return nil
end

test("one item for a line is the delivery without being marked", function()
  -- One take is not a decision. Requiring a tick here would make Pull useless
  -- on a folder of rendered files, which is half of what it is for.
  local moves, n = vo.PlanPull(pull_items("line_042"), name_lines("line_042"), {})
  assert(#moves == 1 and moves[1].dest == "selects", "Got " .. tostring(moves[1].dest))
  assert(moves[1].rename == "line_042", "renamed to the delivered name")
  assert(n.selects == 1, "counted")
end)

test("a select takes the delivery and the rest go to outs", function()
  local moves = vo.PlanPull(pull_items("line_042", "line_042", "line_042"),
                            name_lines("line_042"), { [2] = "select" })
  assert(dest_of(moves, 2) == "selects", "the marked one delivers")
  assert(dest_of(moves, 1) == "outs" and dest_of(moves, 3) == "outs",
    "the rest are kept, not delivered")
end)

test("an alt is delivered alongside the select", function()
  local moves = vo.PlanPull(pull_items("line_042", "line_042", "line_042"),
                            name_lines("line_042"), { [1] = "select", [2] = "alt" })
  assert(dest_of(moves, 1) == "selects", "select")
  assert(dest_of(moves, 2) == "alts", "alt")
  assert(dest_of(moves, 3) == "outs", "unmarked")
end)

test("several takes with nothing marked are a decision, not a guess", function()
  local moves, n = vo.PlanPull(pull_items("line_042", "line_042"),
                               name_lines("line_042"), {})
  assert(dest_of(moves, 1) == "review" and dest_of(moves, 2) == "review",
    "both go to review")
  assert(n.review == 2, "counted")
end)

test("an alt with no select is half a decision and goes to review", function()
  local moves = vo.PlanPull(pull_items("line_042", "line_042"),
                            name_lines("line_042"), { [1] = "alt" })
  assert(dest_of(moves, 1) == "review" and dest_of(moves, 2) == "review",
    "an alt does not answer which take is the delivery")
end)

test("an item no line claims is left entirely alone", function()
  local moves, n = vo.PlanPull(pull_items("RIVA_session"), name_lines("line_042"), {})
  assert(#moves == 0, "nothing to move")
  assert(n.unknown == 1, "but it is counted, so an empty run is never silent")
end)

test("an ambiguous name is counted apart from an unknown one", function()
  local moves, n = vo.PlanPull(pull_items("line_042"),
                               name_lines("line_042", "line_042"), {})
  assert(#moves == 0, "nothing moves")
  assert(n.ambiguous == 1 and n.unknown == 0, "the user can fix an ambiguity")
end)

test("only delivered items are renamed", function()
  local lines = name_lines("line_042")
  lines[1].deliver = "line_042_ch2"
  local moves = vo.PlanPull(pull_items("line_042", "line_042"), lines,
                            { [1] = "select" })
  assert(dest_of(moves, 1) == "selects", "select")
  for _, m in ipairs(moves) do
    if m.dest == "selects" then
      assert(m.rename == "line_042_ch2", "Got " .. tostring(m.rename))
    else
      assert(m.rename == nil, "a take that is not delivered keeps its name")
    end
  end
end)
```

- [ ] **Step 2: Run them and watch them fail**

```bash
./run_tests.sh
```

Expected: `attempt to call a nil value (field 'PlanPull')`.

- [ ] **Step 3: Implement**

Append to the name-resolution block in `VO/lib/ajsfx_vo.lua`:

```lua
-- Where each item goes, as a pure function of its NAME and its mark. Two of the
-- four destinations are delivered (selects, alts) and two are not (outs,
-- review) -- that is the distinction this exists to make.
--
-- `items` are { id, name } in timeline order; `marks` maps an item id to
-- "select" or "alt". An item whose name resolves to nothing produces no move at
-- all: not moved, not renamed, not an error. It is counted so a run that does
-- nothing can say why.
function vo.PlanPull(items, lines, marks)
  marks = marks or {}
  local index = vo.BuildNameIndex(lines)

  local groups, order = {}, {}
  local summary = { selects = 0, alts = 0, outs = 0, review = 0,
                    unknown = 0, ambiguous = 0 }

  for _, item in ipairs(items or {}) do
    local at, why = vo.ResolveItemName(index, item.name)
    if at then
      if not groups[at] then
        groups[at] = {}
        order[#order + 1] = at
      end
      local g = groups[at]
      g[#g + 1] = item
    else
      summary[why == "ambiguous" and "ambiguous" or "unknown"] =
        summary[why == "ambiguous" and "ambiguous" or "unknown"] + 1
    end
  end

  local moves = {}
  for _, at in ipairs(order) do
    local group = groups[at]
    local line  = lines[at] or {}
    local deliver = line.deliver or line.asset

    local has_select = false
    for _, item in ipairs(group) do
      if marks[item.id] == "select" then has_select = true; break end
    end

    -- One take is not a decision, so a lone item delivers whether or not it is
    -- marked. Several takes with nothing marked ARE a decision, and an alt
    -- without a select is only half of one.
    if #group == 1 then
      moves[#moves + 1] = { id = group[1].id, line = at,
                            dest = "selects", rename = deliver }
      summary.selects = summary.selects + 1
    elseif not has_select then
      for _, item in ipairs(group) do
        moves[#moves + 1] = { id = item.id, line = at, dest = "review" }
        summary.review = summary.review + 1
      end
    else
      for _, item in ipairs(group) do
        local mark = marks[item.id]
        if mark == "select" then
          moves[#moves + 1] = { id = item.id, line = at,
                                dest = "selects", rename = deliver }
          summary.selects = summary.selects + 1
        elseif mark == "alt" then
          moves[#moves + 1] = { id = item.id, line = at,
                                dest = "alts", rename = deliver }
          summary.alts = summary.alts + 1
        else
          moves[#moves + 1] = { id = item.id, line = at, dest = "outs" }
          summary.outs = summary.outs + 1
        end
      end
    end
  end

  return moves, summary
end
```

Note the alt's `rename` is the same `deliver` as the select's: an alt whose
Append the user has not typed yet deliberately clashes, and the red clash
warning in Overview is what says so. Task 4 is the button that fills those
Appends in.

- [ ] **Step 4: Run the tests**

```bash
./run_tests.sh
```

Expected: all eight new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "feat(VO): decide a pull destination from the name and the mark"
```

---

### Task 4: Auto append alts

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (pure layer, after Task 3's block); `vo.CONFIG_SCHEMA` (~3559)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Produces:
  - `vo.FormatAltAppend(pattern, n, digits) -> string`
  - `vo.PlanAltAppends(rows, opts) -> edits, skipped` where `rows` are overview
    rows in timeline order carrying `user_mark`, `script`, `asset`, `append_nth`,
    `append_text`; `edits` are `{ script =, asset =, nth =, text = }` ready for
    `vo.SetAppend`; `skipped` counts rows that already had an Append. The row
    fields are the ones `VO/ajsfx_VO_Overview.lua:584` and `:684` already use:
    `row.script` (the script's label), `row.asset`, `row.append_nth`, and
    `row.append` (the Append text, nil when none).
  - config keys `alt_append_pattern` (default `"_alt{n}"`), `alt_append_start`
    (default `1`), `alt_append_digits` (default `1`).

- [ ] **Step 1: Write the failing tests**

```lua
--------------------------------
-- Alt appends
--------------------------------
print("\nAltAppends:")

test("the number goes where the pattern says", function()
  assert(vo.FormatAltAppend("_alt{n}", 2, 1) == "_alt2", "tail")
  assert(vo.FormatAltAppend("{n}_x", 2, 1) == "2_x", "head")
  assert(vo.FormatAltAppend("_alt", 2, 1) == "_alt2",
    "with no placeholder the number goes on the end")
  assert(vo.FormatAltAppend("_pickup", nil, 1) == "_pickup",
    "a pattern used without a number is left alone")
end)

test("digits pad the number", function()
  assert(vo.FormatAltAppend("_alt{n}", 2, 2) == "_alt02", "two digits")
  assert(vo.FormatAltAppend("_alt{n}", 12, 2) == "_alt12", "no truncation")
end)

local function alt_row(mark, asset, nth, text)
  return { user_mark = mark, script = "Ch2", asset = asset,
           append_nth = nth or 1, append = text }
end

test("alts are numbered per line, from the start value", function()
  local edits = vo.PlanAltAppends({
    alt_row("select", "line_042"), alt_row("alt", "line_042"),
    alt_row("alt", "line_042"),    alt_row("alt", "line_099"),
  }, { pattern = "_alt{n}", start = 1, digits = 1 })
  assert(#edits == 3, "three alts, got " .. #edits)
  assert(edits[1].text == "_alt1" and edits[2].text == "_alt2",
    "numbered in timeline order within their line")
  assert(edits[3].text == "_alt1",
    "a different line starts again: " .. tostring(edits[3].text))
end)

test("the start value moves the first number", function()
  local edits = vo.PlanAltAppends({ alt_row("alt", "line_042") },
    { pattern = "_alt{n}", start = 2, digits = 1 })
  assert(edits[1].text == "_alt2", "Got " .. tostring(edits[1].text))
end)

test("an Append already typed is never overwritten", function()
  local edits, skipped = vo.PlanAltAppends({
    alt_row("alt", "line_042", 1, "_pickup"), alt_row("alt", "line_042", 1),
  }, { pattern = "_alt{n}", start = 1, digits = 1 })
  assert(#edits == 1, "only the blank one is filled, got " .. #edits)
  assert(skipped == 1, "and the other is counted")
  assert(edits[1].text == "_alt2",
    "the skipped alt still consumes its number: " .. tostring(edits[1].text))
end)

test("only alts are touched", function()
  local edits = vo.PlanAltAppends({
    alt_row("select", "line_042"), alt_row(nil, "line_042"),
  }, { pattern = "_alt{n}", start = 1, digits = 1 })
  assert(#edits == 0, "a select and an unmarked take are not alts")
end)
```

- [ ] **Step 2: Run them and watch them fail**

```bash
./run_tests.sh
```

Expected: `attempt to call a nil value (field 'FormatAltAppend')`.

- [ ] **Step 3: Implement**

```lua
-- The alt naming convention belongs to whoever the delivery is for, so it is
-- three fields rather than a hardcoded "_alt2". `{n}` is where the number goes;
-- with no placeholder it goes on the end. A pattern used with no number at all
-- is returned as written -- a single alt may not need a counter.
function vo.FormatAltAppend(pattern, n, digits)
  local text = tostring(pattern or "")
  if not n then return (text:gsub("{n}", "")) end
  local num = string.format("%0" .. math.max(1, math.floor(digits or 1)) .. "d", n)
  if text:find("{n}", 1, true) then
    return (text:gsub("{n}", num))
  end
  return text .. num
end

-- Fills the Append of every alt that has none. Numbering runs per line, in the
-- order the rows are given, and an alt that ALREADY has an Append still
-- consumes its number -- otherwise typing "_pickup" on the second alt would
-- silently renumber the third.
--
-- It never overwrites: this button fills blanks, it does not impose a
-- convention on work already done. Returns the edits and the number skipped.
function vo.PlanAltAppends(rows, opts)
  opts = opts or {}
  local pattern = opts.pattern or "_alt{n}"
  local start   = math.floor(tonumber(opts.start) or 1)
  local digits  = math.floor(tonumber(opts.digits) or 1)

  local edits, skipped, seen = {}, 0, {}
  for _, row in ipairs(rows or {}) do
    if row.user_mark == "alt" and row.asset then
      local key = (row.script or "") .. "\0" .. row.asset
      local n = (seen[key] or start - 1) + 1
      seen[key] = n
      if row.append and trim(row.append) ~= "" then
        skipped = skipped + 1
      else
        edits[#edits + 1] = {
          script = row.script, asset = row.asset, nth = row.append_nth or 1,
          text   = vo.FormatAltAppend(pattern, n, digits),
        }
      end
    end
  end
  return edits, skipped
end
```

Add to `vo.CONFIG_SCHEMA`, beside the track names:

```lua
  { key = "track_outs",         kind = "string", default = "Outs" },
  { key = "alt_append_pattern", kind = "string", default = "_alt{n}" },
  { key = "alt_append_start",   kind = "number", default = 1 },
  { key = "alt_append_digits",  kind = "number", default = 1 },
```

The schema has three kinds only — `string`, `number`, `bool` — and no bounds
field; `vo.PlanAltAppends` floors and clamps its own inputs, which is why the
schema does not need to.

- [ ] **Step 4: Run the tests**

```bash
./run_tests.sh
```

Expected: all six new tests PASS.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "feat(VO): fill in alt Appends from a pattern the user defines"
```

---

### Task 5: A destination track nested under its source

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — coupled layer, beside `vo.EnsureSortChildTracks` (~4655)
- Test: manual (`VO/MANUAL_TEST.md`), plus the existing `vo.FolderDepthForChild` tests

**Interfaces:**
- Consumes: `vo.EnsureTrackBelow(track, name)`, `vo.FolderDepthForChild(depth)`
- Produces: `vo.EnsureChildTrack(parent, name) -> MediaTrack`

- [ ] **Step 1: Implement**

`vo.EnsureSortChildTracks` already does this nesting inline. Lift it so Pull can
use the same code, and have the sort helper call it. Insert directly above
`vo.EnsureSortChildTracks`:

```lua
-- A track named `name`, nested as a CHILD of `parent`. The depth rule turns on
-- what the parent's depth WAS, so it is read before the insert.
--
-- Pull's destinations are children rather than siblings because a session's
-- Selects belong to the recording they came out of: collapsed, the recording
-- and everything cut from it read as one thing.
function vo.EnsureChildTrack(parent, name)
  local parent_depth, child_depth =
    vo.FolderDepthForChild(r.GetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH"))
  local child = vo.EnsureTrackBelow(parent, name)
  r.SetMediaTrackInfo_Value(parent, "I_FOLDERDEPTH", parent_depth)
  r.SetMediaTrackInfo_Value(child, "I_FOLDERDEPTH", child_depth)
  return child
end
```

Then replace those four lines inside `vo.EnsureSortChildTracks`' loop with:

```lua
    dest[track] = vo.EnsureChildTrack(track, child_name(track, run))
```

- [ ] **Step 2: Check nothing regressed**

```bash
luac -p VO/lib/ajsfx_vo.lua && ./run_tests.sh
```

Expected: `0 failed`. `vo.FolderDepthForChild`'s own tests still cover the depth
maths; this task only moves where it is called from.

- [ ] **Step 3: Commit**

```bash
git add VO/lib/ajsfx_vo.lua
git commit -m "refactor(VO): one way to nest a destination track under its source"
```

---

### Task 6: The Cut and Name panel

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`; `VO/lib/ajsfx_vo.lua` — `vo.ApplyCutPlan` (~4720)
- Modify: `VO/MANUAL_TEST.md`

**Interfaces:**
- Consumes: the existing cut planning in `ajsfx_VO_Cut.lua` (spans, gate).
- Produces: `vo.ApplyCutPlan(source_track, plan, cfg) -> applied, failures` with
  the routing removed — it splits and names only.

- [ ] **Step 1: Strip the routing out of the apply**

In `vo.ApplyCutPlan`, delete the `dest_names` table, the `tracks` cache, the
`vo.CharacterTrackName` call, the `MoveMediaItemToTrack` call and the
`create_regions` block. What remains, after the two splits:

```lua
      -- Named where it lies. Moving it is Pull's job, and the name it takes
      -- here is the script's own filename -- no Append, no override, no
      -- uniquing. Two takes of one line SHOULD collide at this stage; which of
      -- them is the delivery is not a question cutting can answer.
      local take = r.GetActiveTake(piece)
      if take then
        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", span.asset or span.name, true)
      end
      applied = applied + 1
```

The `failures` paths (too short, no item) are unchanged.

- [ ] **Step 2: Move the gate and the panel into Overview**

Add `DrawCutPanel()` to `VO/ajsfx_VO_Overview.lua`, modelled exactly on
`DrawScriptPanel`: `im.Separator`, a title, the gate message, a Cut button, a
Close button. Port from `ajsfx_VO_Cut.lua`:

- the gate at its lines 181–220 (nothing selected; lines with several takes and
  no select), reading `row.user_mark == "select"` per Task 2
- the span assembly at its lines 283–330, minus every `use_alts_track` branch
  and minus the sibling pull — Cut acts on the marked takes and the review spans
  only
- the summary lines at its 420–440, minus the track counts

The Cut button runs inside `core.Transaction("VO Overview: cut and name", ...)`.

- [ ] **Step 3: Syntax-check and run the tests**

```bash
luac -p VO/ajsfx_VO_Overview.lua VO/lib/ajsfx_vo.lua && ./run_tests.sh
```

Expected: `0 failed`.

- [ ] **Step 4: Add the manual checks**

Append to `VO/MANUAL_TEST.md`:

```markdown
## Cut and Name (2026-08-04)

1. Mark a take SEL and press **Cut and Name**. The take is split out of the
   recording, named the plain CSV filename, and is STILL on the recording's
   own track. No new track appeared.
2. Two takes of one line, both cut. Both carry the same name. That is expected.
3. A line with several takes and none marked SEL: the panel says so and cuts
   nothing.
4. Undo. One Ctrl+Z puts the recording back as it was.
```

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua VO/lib/ajsfx_vo.lua VO/MANUAL_TEST.md
git commit -m "feat(VO): Cut and Name splits and names, and moves nothing"
```

---

### Task 7: The Pull panel

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`
- Modify: `VO/MANUAL_TEST.md`

**Interfaces:**
- Consumes: `vo.PlanPull` (Task 3), `vo.EnsureChildTrack` (Task 5),
  `vo.PlanAltAppends` (Task 4), `vo.CharacterTrackName`.

- [ ] **Step 1: Build the item list**

In `VO/ajsfx_VO_Overview.lua`, beside `BuildSortClusters`:

```lua
-- Every item behind the affected rows, in timeline order, with the name REAPER
-- currently has for it -- not the name the table thinks it should have. Pull
-- resolves what is actually there.
local function PullItems()
  local rows = AffectedRows()
  local items, marks, seen = {}, {}, {}
  for _, row in ipairs(rows) do
    local item = row.item
    if item and not seen[item] then
      seen[item] = true
      local take = r.GetActiveTake(item)
      local name = take and select(2,
        r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)) or ""
      items[#items + 1] = { id = item, name = name,
                            pos = r.GetMediaItemInfo_Value(item, "D_POSITION"),
                            character = row.character }
      if row.user_mark then marks[item] = row.user_mark end
    end
  end
  table.sort(items, function(a, b) return a.pos < b.pos end)
  return items, marks
end
```

- [ ] **Step 2: Apply the plan**

```lua
local function Pull()
  local items, marks = PullItems()
  local moves, summary = vo.PlanPull(items, state.lines, marks)
  if #moves == 0 then
    state.message, state.message_kind = string.format(
      "Nothing to pull: %d item(s) are not on the script, %d name(s) are shared by two lines.",
      summary.unknown, summary.ambiguous), "error"
    return
  end

  local cfg = vo.LoadConfig()
  local base = { selects = cfg.track_selects or "Selects",
                 alts    = cfg.track_alts    or "Alts",
                 outs    = cfg.track_outs    or "Outs",
                 review  = cfg.track_review  or "Review" }
  local by_id = {}
  for _, it in ipairs(items) do by_id[it.id] = it end

  core.Transaction("VO Overview: pull", function()
    local tracks = {}
    for _, move in ipairs(moves) do
      local item   = move.id
      local parent = r.GetMediaItem_Track(item)
      local name   = vo.CharacterTrackName(by_id[item].character, base[move.dest])
      local key    = tostring(parent) .. "|" .. name
      if not tracks[key] then tracks[key] = vo.EnsureChildTrack(parent, name) end
      if r.MoveMediaItemToTrack(item, tracks[key]) and move.rename then
        local take = r.GetActiveTake(item)
        if take then
          r.GetSetMediaItemTakeInfo_String(take, "P_NAME", move.rename, true)
        end
      end
    end
    r.UpdateArrange()
  end)

  state.message, state.message_kind = string.format(
    "Pulled %d select, %d alt, %d out, %d to review. %d not on the script.",
    summary.selects, summary.alts, summary.outs, summary.review,
    summary.unknown + summary.ambiguous), "ok"
end
```

Read the item's parent track INSIDE the loop, not once at the top: a previous
move may already have taken it off the track it started on.

- [ ] **Step 3: Draw the panel**

`DrawPullPanel()`, again modelled on `DrawScriptPanel`. It holds:

- a live count line from `vo.PlanPull` over the current rows (it is pure and
  cheap, but call it once per frame at most, not per widget)
- the auto-append controls from spec §5.2: an `InputText` for the pattern, two
  `InputInt`s for start and digits, a preview line built with
  `vo.FormatAltAppend`, and an **Apply** button that runs `vo.PlanAltAppends`
  over `AffectedRows()` and feeds each edit to `vo.SetAppend(state.appends, ...)`,
  then sets `state.dirty = true` and calls `Reload()`
- the **Pull** button

Persist the three settings through `vo.SaveConfig` on change, as the Settings
window does.

- [ ] **Step 4: Syntax-check and run the tests**

```bash
luac -p VO/ajsfx_VO_Overview.lua && ./run_tests.sh
```

- [ ] **Step 5: Add the manual checks**

```markdown
## Pull (2026-08-04)

1. Cut two takes of one line, mark one SEL. Press **Pull**. The SEL lands on
   `<CHAR>_Selects`, the other on `<CHAR>_Outs`, and BOTH tracks are children
   of the recording's track — collapse the recording and they go with it.
2. Mark the second take ALT. Pull again: it moves to `<CHAR>_Alts`.
3. Both takes marked ALT and none SEL: both go to `<CHAR>_Review`.
4. Drop a folder of already-named rendered wavs into the project with no
   transcripts at all. Pull moves each to Selects by its filename.
5. An item whose name is not on the script is not moved, and the summary counts it.
6. Set the alt pattern to `-take{n}`, start 2, digits 2. The preview reads
   `-take02`. Press Apply: only alts with an empty Append are filled.
7. Press Apply twice. Nothing changes the second time.
```

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua VO/MANUAL_TEST.md
git commit -m "feat(VO): Pull routes takes to child tracks by name and mark"
```

---

### Task 8: Sort by name

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — `BuildSortClusters` (~1372), `DrawLayoutBar` (~1981)
- Modify: `VO/MANUAL_TEST.md`

**Interfaces:**
- Consumes: `vo.BuildNameIndex` / `vo.ResolveItemName` (Task 1).

- [ ] **Step 1: Key the clusters by resolved name**

In `BuildSortClusters`, the per-item key currently comes from the row's
`script_row`. In script order it now comes from the item's NAME:

```lua
  -- Script order is a question about the SCRIPT, so it is answered by the name
  -- the item carries, not by what the transcript matched. This is what keeps an
  -- uncut recording out of the run: its name is not a script filename, so it
  -- resolves to nothing and is left where it is. Record order is unchanged --
  -- it asks where an item sat in a recording, which a name cannot answer.
  local index = vo.BuildNameIndex(state.lines)
  local unresolved = 0
```

For each item, when `state.layout_order == "script"`, resolve its take name;
a `nil` result increments `unresolved` and the item is skipped entirely. The
key becomes `{ script_row = <resolved index>, source_path =, source_start = }`
so `vo.PlanTimelineLayout` needs no change at all.

- [ ] **Step 2: Report what was skipped**

In `DrawLayoutBar`, extend the existing count line:

```lua
  im.TextDisabled(ctx, string.format("%d item%s from %d recording%s (%s)%s",
    items, items == 1 and "" or "s", sources, sources == 1 and "" or "s",
    from_selection and "selected rows" or "all shown rows",
    unresolved > 0 and string.format(", %d not on the script", unresolved) or ""))
```

- [ ] **Step 3: Syntax-check and run the tests**

```bash
luac -p VO/ajsfx_VO_Overview.lua && ./run_tests.sh
```

- [ ] **Step 4: Add the manual checks**

```markdown
## Sort by name (2026-08-04)

1. A project of rendered wavs, no transcripts, names matching the script.
   **Sort** in script order lays them out in the script's order.
2. An uncut recording is NOT moved, and the count line says "N not on the script".
3. Sort a Selects track that Pull already renamed with Appends. It still sorts:
   the delivered name resolves too.
4. Sort twice. The second run makes a fresh set of "sorted N" tracks and the
   first set is untouched.
5. Record order still works on a cut session and still needs no names.
```

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua VO/MANUAL_TEST.md
git commit -m "feat(VO): Sort orders by the name an item carries"
```

---

### Task 9: The toolbar, and the removals

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — the toolbar (~2913), `DrawFilters` (~1854), `Matches` (~1076), the state table (~285), `LoadProjectFile` (~400), `SaveProjectFile` (~440)
- Delete: `VO/ajsfx_VO_Cut.lua`
- Modify: `VO/SPEC-overview.md`, `VO/SPEC.md`, `VO/MANUAL_TEST.md`

- [ ] **Step 1: One panel open at a time**

Replace the four booleans (`scripts_open`, and the three new ones) with a single
`state.panel` holding `nil` or one of `"script" | "cut" | "pull" | "sort"`.
Each toolbar button toggles it:

```lua
    local function PanelButton(key, label, tip)
      local on = state.panel == key
      if on then im.PushStyleColor(ctx, im.Col_Button,
                                   im.GetStyleColor(ctx, im.Col_ButtonActive)) end
      if im.Button(ctx, label) then state.panel = (not on) and key or nil end
      if on then im.PopStyleColor(ctx) end
      if im.IsItemHovered(ctx) then im.SetTooltip(ctx, tip) end
      im.SameLine(ctx)
    end
```

The row becomes: `Script`, `Sources…`, `Cut and Name`, `Pull`, `Sort`,
`Settings` — `Sources…` and `Settings` keep launching their windows. Then:

```lua
    if     state.panel == "script" then DrawScriptPanel()
    elseif state.panel == "cut"    then DrawCutPanel()
    elseif state.panel == "pull"   then DrawPullPanel()
    elseif state.panel == "sort"   then DrawLayoutBar() end
```

`DrawLayoutBar` moves out of the always-drawn body into the panel switch. The
warning banner's `Script##warn` button sets `state.panel = "script"`.

- [ ] **Step 2: Remove the status presets**

Delete `STATUS_FILTERS`, `STATUS_BY_KEY`, `state.status_filter`, its combo in
`DrawFilters`, its branch in `Matches`, and the `status` field in the project
file's `View` rows (both the write in `SaveProjectFile` and the read in
`LoadProjectFile`). The Status column's own filter box already matches
Recorded / Review / Missing / Orphan / Flagged, and Lock covers verified.

- [ ] **Step 3: Delete the Cut window**

```bash
git rm VO/ajsfx_VO_Cut.lua
```

Remove `[main] ajsfx_VO_Cut.lua` from Overview's `@provides` header, and drop
`ajsfx VO Cut` from the `@about` text and from `VO/SPEC.md`'s window list.

- [ ] **Step 4: Update the specs**

- `VO/SPEC-overview.md`: the toolbar section, the layout section (script order
  is name-resolved), and the project file's `View` rows lose `status`.
- `VO/SPEC.md`: three windows become two; the cut destinations gain Outs; the
  Select column is three-state.
- Bump `@version` to `0.13` in `VO/ajsfx_VO_Overview.lua`, `ajsfx_VO_Sources.lua`
  and `ajsfx_VO_Settings.lua`, and write a `@changelog` covering the whole of
  this plan. CI reads it for the ReaPack changelog.

- [ ] **Step 5: Full check**

```bash
luac -p VO/ajsfx_VO_Overview.lua VO/lib/ajsfx_vo.lua && ./run_tests.sh
```

Expected: `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(VO): one toolbar, four panels, and the Cut window retired"
```

---

## Not in this plan

**The character selection** (spec §7) is a separate plan: it changes matching
rather than the tools, it touches `vo.BuildIndex` and `vo.ResidualPass` rather
than the UI, and it lands cleanly on top of this one. Write it as
`docs/superpowers/plans/2026-08-05-vo-character-selection.md` once this is
merged and checked in REAPER.

**Per-item verification** (spec §10) is not designed yet.
