# VO Multiple Script CSVs & the Append Column — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a REAPER project hold several script CSVs at once, each with its own column mapping, and give every duplicate delivered filename one user-typed fix — an Append column, with clashes shown in red until they are separated.

**Architecture:** The pure layer in `VO/lib/ajsfx_vo.lua` grows a merge/resolve pipeline (`LoadScripts` → `MergeScriptLines` → `ResolveNames`) that both GUI windows call instead of their private `LoadCSV`. The project file's single `Script CSV` + `Mapping` preamble rows become repeated `Script` rows plus `Append` rows, with the old rows still read for backward compatibility. Overview replaces its `Columns…` panel with a Script manager panel and gains two table columns.

**Tech Stack:** Lua 5.4, ReaImGui, REAPER API. Tests are plain Lua asserts in `tests/test_vo.lua` against `tests/mock_reaper.lua`.

**Spec:** `VO/SPEC-multi-script.md`. Read it before starting.

## Global Constraints

- **Lua 5.4, no external libraries.** The pure layer must run headless under `lua tests/test_vo.lua` with only `tests/mock_reaper.lua` installed.
- **Pure/coupled split** (`VO/SPEC.md`): anything that reads a file, touches ImGui or calls a REAPER API stays out of the pure layer. `vo.LoadScripts` takes an injected `read_fn` for exactly this reason.
- **`vo.PROJECT_VERSION` stays `1`.** The project-file change is additive; bumping it would make existing projects unreadable.
- **No filename is ever renamed automatically.** No prefill, no suggested Append, no CSV-name suffix. The user types.
- **No separator is inserted** between filename and Append. `line_042` + `_ch2` = `line_042_ch2`.
- **Run `./run_tests.sh` before every commit.** CI gates the ReaPack index rebuild on it.
- Commit messages: lowercase `type(VO): subject` in the imperative, matching recent history (`fix(VO): a shared filename is a note, not an error`). End every commit message with:
  ```
  Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
  ```
- **Do not bump `@version` or `@changelog` until Task 9.** A version bump mid-plan publishes a half-finished feature.

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `VO/lib/ajsfx_vo.lua` | Pure layer: labels, keys, merge, resolve, clash detection, shared loader; project-file serialize/parse | 1–5 |
| `tests/test_vo.lua` | All pure-layer tests | 1–5 |
| `VO/ajsfx_VO_Overview.lua` | Script list state, Script panel, Append + Script columns, red highlighting | 6–8 |
| `VO/ajsfx_VO_Cut.lua` | Drop its private `LoadCSV`, use the shared loader | 8 |
| `VO/MANUAL_TEST.md` | In-REAPER test steps | 9 |

---

### Task 1: `ScriptLabel` and `AppendKey`

The two smallest pure functions, and everything else depends on them.

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (add after `vo.DuplicateAssets`, which ends around line 351)
- Test: `tests/test_vo.lua` (add a section after the existing `DuplicateAssets` section, around line 229)

**Interfaces:**
- Consumes: `vo.SanitizeName(s, max_len)` — existing, at `VO/lib/ajsfx_vo.lua:1405`. Strips characters a filesystem rejects.
- Produces:
  - `vo.ScriptLabel(path) -> string` — basename, extension stripped, sanitized. `""` for nil/empty.
  - `vo.AppendKey(script_label, asset, nth) -> string` — `label .. "|" .. asset .. "|" .. nth`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua` immediately after the `DuplicateAssets` section (after the `"lines with no filename are not duplicates of each other"` test, before the `Normalize` section):

```lua
--------------------------------
-- ScriptLabel / AppendKey
--------------------------------
print("\nScriptLabel:")

test("a windows path becomes its basename without the extension", function()
  assert(vo.ScriptLabel("D:/game/Chapter2_Script.csv") == "Chapter2_Script",
    "Got " .. tostring(vo.ScriptLabel("D:/game/Chapter2_Script.csv")))
end)

test("backslashes are separators too", function()
  assert(vo.ScriptLabel("D:\\game\\Chapter5.csv") == "Chapter5",
    "Got " .. tostring(vo.ScriptLabel("D:\\game\\Chapter5.csv")))
end)

test("a label a filesystem would reject is sanitized", function()
  local got = vo.ScriptLabel("D:/game/Act 1: Pickups.csv")
  assert(not got:find("[:]"), "Colon survived: " .. got)
  assert(got ~= "", "Sanitizing must not empty a real name")
end)

test("no path is the empty label", function()
  assert(vo.ScriptLabel(nil) == "", "nil should give an empty label")
  assert(vo.ScriptLabel("") == "", "empty should give an empty label")
end)

test("a name with no extension is left alone", function()
  assert(vo.ScriptLabel("D:/game/script") == "script",
    "Got " .. tostring(vo.ScriptLabel("D:/game/script")))
end)

print("\nAppendKey:")

test("the same line keys the same way twice", function()
  assert(vo.AppendKey("Ch2", "line_042", 1) == vo.AppendKey("Ch2", "line_042", 1),
    "The key must be deterministic")
end)

test("two occurrences of one filename in one script key differently", function()
  assert(vo.AppendKey("Ch2", "line_042", 1) ~= vo.AppendKey("Ch2", "line_042", 2),
    "Occurrence must be part of the key")
end)

test("one filename in two scripts keys differently", function()
  assert(vo.AppendKey("Ch2", "line_042", 1) ~= vo.AppendKey("Ch5", "line_042", 1),
    "Script must be part of the key")
end)
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
./run_tests.sh
```

Expected: FAIL, with messages like `attempt to call a nil value (field 'ScriptLabel')`.

- [ ] **Step 3: Implement**

Add to `VO/lib/ajsfx_vo.lua` directly after the end of `vo.DuplicateAssets`:

```lua
-- A script's short name, used in the Overview's Script column and as part of an
-- Append's storage key. Sanitized because it is displayed beside filenames and
-- must not carry anything a path would choke on.
function vo.ScriptLabel(path)
  if type(path) ~= "string" or path == "" then return "" end
  local base = path:match("([^/\\]+)$") or path
  local stem = base:match("^(.*)%.[^.]*$") or base
  return vo.SanitizeName(stem)
end

-- A script line's identity for the Append it carries. The parts are NEVER
-- joined for storage -- a filename containing the separator would make the
-- split ambiguous -- so this is a lookup key only, built from parts the project
-- file keeps apart. `nth` is the 1-based occurrence of `asset` WITHIN its own
-- script, chosen over the CSV row number so that inserting a line at the top of
-- a script does not orphan every Append below it.
function vo.AppendKey(script_label, asset, nth)
  return tostring(script_label or "") .. "|" .. tostring(asset or "")
       .. "|" .. tostring(nth or 1)
end
```

`vo.SanitizeName` is defined at line 1405, *below* this insertion point. That is fine: both are fields on the `vo` table and `ScriptLabel` only resolves `vo.SanitizeName` when it is called, long after the module has finished loading.

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
./run_tests.sh
```

Expected: PASS, with the new test names printed and the failure count at 0.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "feat(VO): a script has a label and a line has an append key"
```

---

### Task 2: `MergeScriptLines`

Flattens several scripts' lines into the one ordered list every downstream consumer already expects. Renames nothing.

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (add after `vo.AppendKey`)
- Test: `tests/test_vo.lua` (add after the `AppendKey` section)

**Interfaces:**
- Consumes: `vo.AppendKey` (Task 1).
- Produces: `vo.MergeScriptLines(scripts) -> lines`
  - `scripts` = `{ { label = <string>, enabled = <boolean>, lines = { <BuildScriptLines output> } }, … }`
  - Returns one flat array. Each line keeps every field `vo.BuildScriptLines` gave it (`text`, `asset`, `speaker`, `row`) and gains `script` (the label), `append_nth` (the occurrence integer) and `append_key`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua` after the `AppendKey` section:

```lua
--------------------------------
-- MergeScriptLines
--------------------------------
print("\nMergeScriptLines:")

local function script(label, enabled, assets)
  local lines = {}
  for i, a in ipairs(assets) do
    lines[i] = { asset = a, text = "line " .. a, row = i }
  end
  return { label = label, enabled = enabled, lines = lines }
end

test("lines come out in script order then row order", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "a", "b" }),
    script("Ch5", true, { "c" }),
  })
  assert(#merged == 3, "Expected 3 lines, got " .. #merged)
  assert(merged[1].asset == "a" and merged[2].asset == "b" and merged[3].asset == "c",
    "Order is script-then-row")
end)

test("each line knows which script it came from", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "a" }),
    script("Ch5", true, { "c" }),
  })
  assert(merged[1].script == "Ch2", "Got " .. tostring(merged[1].script))
  assert(merged[2].script == "Ch5", "Got " .. tostring(merged[2].script))
end)

test("a disabled script contributes nothing", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true,  { "a" }),
    script("Ch5", false, { "c" }),
  })
  assert(#merged == 1 and merged[1].asset == "a",
    "A disabled script must contribute no lines")
end)

test("no filename is modified by merging", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "line_042" }),
    script("Ch5", true, { "line_042" }),
  })
  assert(merged[1].asset == "line_042" and merged[2].asset == "line_042",
    "Merging must never rename anything")
end)

test("a clash across scripts gets two distinct append keys", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "line_042" }),
    script("Ch5", true, { "line_042" }),
  })
  assert(merged[1].append_key ~= merged[2].append_key,
    "Two scripts' identical filenames are still two different lines")
end)

test("two lines sharing a filename inside one script get distinct keys", function()
  local merged = vo.MergeScriptLines({ script("Ch2", true, { "dup", "dup" }) })
  assert(merged[1].append_key ~= merged[2].append_key,
    "Occurrence index must separate them")
end)

test("occurrence counting is per script, not global", function()
  local merged = vo.MergeScriptLines({
    script("Ch2", true, { "shared" }),
    script("Ch5", true, { "shared" }),
  })
  assert(merged[1].append_key == vo.AppendKey("Ch2", "shared", 1), "Ch2 line is its 1st")
  assert(merged[2].append_key == vo.AppendKey("Ch5", "shared", 1), "Ch5 line is its 1st too")
end)

test("enabled defaults to true when the field is absent", function()
  local merged = vo.MergeScriptLines({ { label = "Ch2",
    lines = { { asset = "a", text = "t", row = 1 } } } })
  assert(#merged == 1, "A script with no enabled field is enabled")
end)
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
./run_tests.sh
```

Expected: FAIL with `attempt to call a nil value (field 'MergeScriptLines')`.

- [ ] **Step 3: Implement**

Add to `VO/lib/ajsfx_vo.lua` after `vo.AppendKey`:

```lua
-- Several scripts' lines, flattened into the one ordered list the matcher, the
-- overview and the cut all already expect. NOTHING is renamed here: two scripts
-- delivering one filename produce two ordinary lines that happen to share a
-- name, and the Append column is what separates them. Merging's only job is to
-- record which script each line came from and to give it a stable key.
--
-- scripts: { { label, enabled, lines = <BuildScriptLines output> }, ... }
function vo.MergeScriptLines(scripts)
  local out = {}
  for _, sc in ipairs(scripts or {}) do
    if sc.enabled ~= false then
      -- Occurrence is counted WITHIN a script, so a filename appearing once in
      -- each of two scripts is the 1st in both. Counting globally would make an
      -- Append depend on which other scripts happened to be loaded.
      local nth = {}
      for _, l in ipairs(sc.lines or {}) do
        local line = vo.ShallowCopy(l)
        local n = (nth[l.asset] or 0) + 1
        nth[l.asset] = n
        line.script     = sc.label
        line.append_nth = n
        line.append_key = vo.AppendKey(sc.label, l.asset, n)
        out[#out + 1] = line
      end
    end
  end
  return out
end
```

`vo.ShallowCopy` exists at `VO/lib/ajsfx_vo.lua:46`. Copying rather than mutating keeps `BuildScriptLines`' output reusable, which the tests rely on.

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
./run_tests.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "feat(VO): merge several scripts into one line list"
```

---

### Task 3: `AppendMap`, `SetAppend`, `ResolveNames`

The Append store and the name resolution it feeds.

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (add after `vo.MergeScriptLines`)
- Test: `tests/test_vo.lua` (add after the `MergeScriptLines` section)

**Interfaces:**
- Consumes: `vo.AppendKey` (Task 1), `line.append_key` (Task 2).
- Produces:
  - `vo.AppendMap(append_rows) -> { [key] = text }`
  - `vo.SetAppend(append_rows, script, asset, nth, text) -> append_rows` (mutates and returns)
  - `vo.ResolveNames(lines, appends) -> lines` (sets `line.deliver` on each, returns the same array)
- Append record shape: `{ script = <label>, asset = <filename>, nth = <integer>, text = <string> }`

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua` after the `MergeScriptLines` section:

```lua
--------------------------------
-- AppendMap / SetAppend / ResolveNames
--------------------------------
print("\nAppendMap and SetAppend:")

test("records fold into a key-to-text map", function()
  local m = vo.AppendMap({ { script = "Ch2", asset = "a", nth = 1, text = "_x" } })
  assert(m[vo.AppendKey("Ch2", "a", 1)] == "_x", "Lookup failed")
end)

test("setting a new append adds one record", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "_x")
  assert(#rows == 1 and rows[1].text == "_x", "Expected one record")
end)

test("setting an existing append replaces it in place", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "_x")
  vo.SetAppend(rows, "Ch2", "a", 1, "_y")
  assert(#rows == 1, "Expected one record, got " .. #rows)
  assert(rows[1].text == "_y", "Got " .. tostring(rows[1].text))
end)

test("setting an append to empty removes the record", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "_x")
  vo.SetAppend(rows, "Ch2", "a", 1, "")
  assert(#rows == 0, "An empty append is not a judgement; it is the absence of one")
end)

test("whitespace-only counts as empty", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "   ")
  assert(#rows == 0, "Whitespace-only must remove the record")
end)

test("appends for other lines are untouched", function()
  local rows = vo.SetAppend({}, "Ch2", "a", 1, "_x")
  vo.SetAppend(rows, "Ch5", "a", 1, "_y")
  vo.SetAppend(rows, "Ch2", "a", 1, "")
  assert(#rows == 1 and rows[1].script == "Ch5", "Only the named record may change")
end)

print("\nResolveNames:")

test("no append leaves the filename alone", function()
  local lines = { { asset = "a", append_key = vo.AppendKey("Ch2", "a", 1) } }
  vo.ResolveNames(lines, {})
  assert(lines[1].deliver == "a", "Got " .. tostring(lines[1].deliver))
end)

test("an append is concatenated with no separator", function()
  local lines = { { asset = "line_042", append_key = vo.AppendKey("Ch2", "line_042", 1) } }
  vo.ResolveNames(lines, vo.AppendMap({
    { script = "Ch2", asset = "line_042", nth = 1, text = "_ch2" } }))
  assert(lines[1].deliver == "line_042_ch2", "Got " .. tostring(lines[1].deliver))
end)

test("a whitespace-only append resolves to the bare filename", function()
  local lines = { { asset = "a", append_key = vo.AppendKey("Ch2", "a", 1) } }
  vo.ResolveNames(lines, { [vo.AppendKey("Ch2", "a", 1)] = "   " })
  assert(lines[1].deliver == "a", "Got " .. tostring(lines[1].deliver))
end)

test("a line with no append key still resolves", function()
  local lines = { { asset = "a" } }
  vo.ResolveNames(lines, {})
  assert(lines[1].deliver == "a", "A key-less line must not error")
end)
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
./run_tests.sh
```

Expected: FAIL with `attempt to call a nil value (field 'AppendMap')`.

- [ ] **Step 3: Implement**

Add to `VO/lib/ajsfx_vo.lua` after `vo.MergeScriptLines`:

```lua
-- Appends are held as an ARRAY of records, never as a map keyed by the joined
-- string: splitting "label|asset|nth" back into three parts would be ambiguous
-- the moment a filename contained the separator. The array is what the project
-- file round-trips; the map below is built for lookup and thrown away.
-- Record: { script = <label>, asset = <filename>, nth = <integer>, text = <string> }
function vo.AppendMap(append_rows)
  local m = {}
  for _, a in ipairs(append_rows or {}) do
    m[vo.AppendKey(a.script, a.asset, a.nth)] = a.text or ""
  end
  return m
end

-- The one mutator. Setting an append to empty REMOVES its record rather than
-- storing "": the project file holds judgements, and "no append" is the absence
-- of one -- the same rule SerializeProjectFile already applies to entry rows.
function vo.SetAppend(append_rows, script, asset, nth, text)
  append_rows = append_rows or {}
  local clean = trim(tostring(text or ""))

  for i, a in ipairs(append_rows) do
    if a.script == script and a.asset == asset and a.nth == nth then
      if clean == "" then
        table.remove(append_rows, i)
      else
        a.text = clean
      end
      return append_rows
    end
  end

  if clean ~= "" then
    append_rows[#append_rows + 1] =
      { script = script, asset = asset, nth = nth, text = clean }
  end
  return append_rows
end

-- The delivered name a script line asks for, before any per-take override.
-- No separator is inserted: a user who wants "line_042_ch2" types "_ch2". That
-- is the whole point -- nothing here renames anything the user did not spell.
function vo.ResolveNames(lines, appends)
  appends = appends or {}
  for _, l in ipairs(lines or {}) do
    local extra = l.append_key and appends[l.append_key] or nil
    extra = extra and trim(extra) or ""
    l.deliver = (l.asset or "") .. extra
  end
  return lines
end
```

`trim` is the module-local helper at `VO/lib/ajsfx_vo.lua:19` — already in scope.

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
./run_tests.sh
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "feat(VO): an append column decides the delivered name"
```

---

### Task 4: Clash detection — `DuplicateAssets` change and `DuplicateNames`

Two checks, because Append is per line and `name_override` is per take.

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua:331` (`vo.DuplicateAssets`), then add `vo.DuplicateNames` after it
- Test: `tests/test_vo.lua` (extend the existing `DuplicateAssets` section, add a `DuplicateNames` section)

**Interfaces:**
- Consumes: `line.deliver` (Task 3).
- Produces:
  - `vo.DuplicateAssets(lines)` — unchanged signature and return shape (`{ { asset, rows, texts }, … }`), now comparing `deliver or asset`.
  - `vo.DuplicateNames(rows) -> { [name] = true }` — `rows` are overview rows carrying `line_key`, `deliver` and optionally `name_override`. A name is in the set when rows from **two or more different `line_key`s** resolve to it.

- [ ] **Step 1: Write the failing tests**

Append to the existing `DuplicateAssets` section in `tests/test_vo.lua` (after the `"lines with no filename…"` test, before the `ScriptLabel` section added in Task 1):

```lua
test("the resolved name is what collides, not the raw filename", function()
  local lines = { { asset = "dup", deliver = "dup_a",  text = "A", row = 1 },
                  { asset = "dup", deliver = "dup_b",  text = "B", row = 2 } }
  assert(#vo.DuplicateAssets(lines) == 0,
    "Appends that separate the names must clear the clash")
end)

test("two scripts delivering one name collide like two rows of one script", function()
  local lines = { { asset = "dup", deliver = "dup", text = "A", row = 1, script = "Ch2" },
                  { asset = "dup", deliver = "dup", text = "B", row = 1, script = "Ch5" } }
  local d = vo.DuplicateAssets(lines)
  assert(#d == 1 and #d[1].rows == 2, "Expected one group of two")
  assert(d[1].asset == "dup", "The group is named by the resolved name")
end)

test("a line with no deliver falls back to its filename", function()
  local lines = { { asset = "dup", text = "A", row = 1 },
                  { asset = "dup", text = "B", row = 2 } }
  assert(#vo.DuplicateAssets(lines) == 1, "The fallback must still detect the clash")
end)
```

Then add a new section after the `ResolveNames` section:

```lua
--------------------------------
-- DuplicateNames
--------------------------------
print("\nDuplicateNames:")

test("two lines resolving to one name are flagged", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "dup" },
    { line_key = "k2", deliver = "dup" },
  })
  assert(dupes["dup"] == true, "Expected dup to be flagged")
end)

test("two takes of ONE line never flag each other", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "dup" },
    { line_key = "k1", deliver = "dup" },
  })
  assert(next(dupes) == nil, "Takes of one line share a name by design")
end)

test("an override that separates a clash clears it", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "dup", name_override = "dup_a" },
    { line_key = "k2", deliver = "dup" },
  })
  assert(next(dupes) == nil, "The override separated them")
end)

test("an override that recreates a clash is flagged", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "alpha", name_override = "bravo" },
    { line_key = "k2", deliver = "bravo" },
  })
  assert(dupes["bravo"] == true, "An override can create a clash too")
end)

test("an empty override is ignored", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "dup", name_override = "" },
    { line_key = "k2", deliver = "dup" },
  })
  assert(dupes["dup"] == true, "An empty override is not a rename")
end)

test("rows with no line are skipped", function()
  local dupes = vo.DuplicateNames({
    { deliver = "orphan" },
    { deliver = "orphan" },
  })
  assert(next(dupes) == nil, "Audio matching no script line has no name to clash")
end)

test("an empty name is never a clash", function()
  local dupes = vo.DuplicateNames({
    { line_key = "k1", deliver = "" },
    { line_key = "k2", deliver = "" },
  })
  assert(next(dupes) == nil, "Empty names are not a collision")
end)
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
./run_tests.sh
```

Expected: FAIL — the `DuplicateAssets` additions fail on the resolved-name comparison, and `DuplicateNames` fails as a nil value.

- [ ] **Step 3: Implement**

In `VO/lib/ajsfx_vo.lua`, change the loop body of `vo.DuplicateAssets` (starting line 332) so it groups on the resolved name. Replace:

```lua
  for _, l in ipairs(lines or {}) do
    if l.asset and l.asset ~= "" then
      local g = seen[l.asset]
      if not g then
        g = { asset = l.asset, rows = {}, texts = {} }
        seen[l.asset] = g
        order[#order + 1] = g
      end
```

with:

```lua
  for _, l in ipairs(lines or {}) do
    -- The RESOLVED name, so an Append that separates two lines clears the
    -- clash and an Append that does not still shows it. `asset` is the fallback
    -- for callers that never ran ResolveNames (tests, older entry points).
    local name = l.deliver
    if name == nil or name == "" then name = l.asset end
    if name and name ~= "" then
      local g = seen[name]
      if not g then
        g = { asset = name, rows = {}, texts = {} }
        seen[name] = g
        order[#order + 1] = g
      end
```

Also update the doc comment above `vo.DuplicateAssets` — change the first sentence to:

```lua
-- Script lines that two or more rows want DELIVERED under the same name, after
-- each line's Append has been applied. The overview can still keep their takes
-- apart -- it groups by script line -- but the delivered files cannot be kept
```

Then add after `vo.DuplicateAssets`:

```lua
-- Row-level clash detection, for the red highlight in ajsfx VO Overview.
--
-- This exists alongside DuplicateAssets because the two questions differ. An
-- Append belongs to a script LINE; a name override belongs to a single TAKE. So
-- an override can separate a clash the line-level check still sees, or create
-- one it cannot see at all. Takes of a single line resolving to the same name is
-- normal and must never be flagged -- Cut is what numbers them apart.
--
-- rows: overview rows carrying line_key, deliver and optionally name_override.
-- Returns a set of the names claimed by two or more DIFFERENT script lines.
function vo.DuplicateNames(rows)
  local owners = {}
  for _, row in ipairs(rows or {}) do
    if row.line_key then
      local name = row.name_override
      if name == nil or name == "" then name = row.deliver end
      if name and name ~= "" then
        local o = owners[name]
        if not o then
          owners[name] = { row.line_key }
        elseif o[1] ~= row.line_key and o[2] == nil then
          o[2] = row.line_key
        end
      end
    end
  end

  local dupes = {}
  for name, o in pairs(owners) do
    if o[2] then dupes[name] = true end
  end
  return dupes
end
```

- [ ] **Step 4: Run the tests and confirm they pass**

```bash
./run_tests.sh
```

Expected: PASS. The four pre-existing `DuplicateAssets` tests must still pass — they pass lines with no `deliver`, which take the fallback.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "feat(VO): a clash is between delivered names, not filenames"
```

---

### Task 5: Project file — `Script` and `Append` rows, and the shared loader

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua:2437` (`vo.SerializeProjectFile`), `:2492` (`vo.ParseProjectFile`); add `vo.LoadScripts` after `vo.ResolveNames`
- Test: `tests/test_vo.lua` (new section after `DuplicateNames`)

**Interfaces:**
- Consumes: `vo.ScriptLabel`, `vo.MergeScriptLines`, `vo.AppendMap`, `vo.ResolveNames`, `encode_mapping`/`decode_mapping` (module-locals at lines 2104/2113).
- Produces:
  - `SerializeProjectFile(entries, meta)` — `meta` gains `scripts` (array of `{ path, mapping, enabled }`) and `appends` (array of Append records). `meta.script_csv` and `meta.mapping` are no longer written.
  - `ParseProjectFile(text)` — returns `parsed.scripts` (always an array, possibly empty) and `parsed.appends` (array). `parsed.script_csv` / `parsed.mapping` are **removed**; the old rows fold into `parsed.scripts`.
  - `vo.LoadScripts(entries, read_fn) -> { scripts = …, lines = … }`
    - `entries` = `{ { path, mapping, enabled }, … }`
    - `read_fn(path) -> text|nil`
    - Each returned script: `{ path, label, mapping, enabled, header, rows, lines, error }`
    - `lines` is the merged list, with `script` and `append_key` set but **not** `deliver` — the caller runs `vo.ResolveNames` once it knows the project's appends.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua` after the `DuplicateNames` section:

```lua
--------------------------------
-- Project file: Script and Append rows
--------------------------------
print("\nProject file scripts and appends:")

test("scripts round-trip with their mapping and enabled flag", function()
  local text = vo.SerializeProjectFile({}, { scripts = {
    { path = "D:/g/Ch2.csv", mapping = { asset = "File", text = "Line" }, enabled = true },
    { path = "D:/g/Ch5.csv", mapping = { asset = "Fn" },                  enabled = false },
  } })
  local p = assert(vo.ParseProjectFile(text), "Should parse")
  assert(#p.scripts == 2, "Expected 2 scripts, got " .. #p.scripts)
  assert(p.scripts[1].path == "D:/g/Ch2.csv", "Got " .. tostring(p.scripts[1].path))
  assert(p.scripts[1].mapping.asset == "File", "Mapping lost")
  assert(p.scripts[1].enabled == true, "Enabled lost")
  assert(p.scripts[2].enabled == false, "Disabled lost")
end)

test("appends round-trip", function()
  local text = vo.SerializeProjectFile({}, {
    scripts = { { path = "D:/g/Ch2.csv", mapping = {}, enabled = true } },
    appends = { { script = "Ch2", asset = "line_042", nth = 2, text = "_take" } },
  })
  local p = assert(vo.ParseProjectFile(text), "Should parse")
  assert(#p.appends == 1, "Expected 1 append, got " .. #p.appends)
  assert(p.appends[1].script == "Ch2", "script lost")
  assert(p.appends[1].asset == "line_042", "asset lost")
  assert(p.appends[1].nth == 2, "nth lost or not a number: " .. tostring(p.appends[1].nth))
  assert(p.appends[1].text == "_take", "text lost")
end)

test("an append naming an absent script survives a rewrite", function()
  local first = vo.SerializeProjectFile({}, {
    scripts = {},
    appends = { { script = "Removed", asset = "a", nth = 1, text = "_x" } },
  })
  local p = assert(vo.ParseProjectFile(first), "Should parse")
  assert(#p.appends == 1, "Removing a script must not lose its appends")
end)

test("a file from the previous version parses into one enabled script", function()
  local old = table.concat({
    vo.FormatCSVRow({ vo.PROJECT_MARKER, "1" }),
    vo.FormatCSVRow({ "Script CSV", "D:/g/Only.csv" }),
    vo.FormatCSVRow({ "Mapping", "asset=Filename;text=Line" }),
    "",
    vo.FormatCSVRow(vo.PROJECT_HEADER),
  }, "\n") .. "\n"
  local p = assert(vo.ParseProjectFile(old), "The old format must still open")
  assert(#p.scripts == 1, "Expected 1 script, got " .. #p.scripts)
  assert(p.scripts[1].path == "D:/g/Only.csv", "Path lost")
  assert(p.scripts[1].mapping.asset == "Filename", "Mapping lost")
  assert(p.scripts[1].enabled == true, "A migrated script is enabled")
end)

test("a new-format file ignores a stray old-format row", function()
  local text = table.concat({
    vo.FormatCSVRow({ vo.PROJECT_MARKER, "1" }),
    vo.FormatCSVRow({ "Script CSV", "D:/g/Stale.csv" }),
    vo.FormatCSVRow({ "Script", "D:/g/Real.csv", "asset=F", "yes" }),
    "",
    vo.FormatCSVRow(vo.PROJECT_HEADER),
  }, "\n") .. "\n"
  local p = assert(vo.ParseProjectFile(text), "Should parse")
  assert(#p.scripts == 1 and p.scripts[1].path == "D:/g/Real.csv",
    "An explicit Script row wins over the legacy fallback")
end)

test("entries still round-trip alongside the new rows", function()
  local text = vo.SerializeProjectFile(
    { { key = "a.wav|1500", source = "D:/a.wav", source_start = 1.5,
        asset = "line_1", select = true } },
    { scripts = { { path = "D:/g/Ch2.csv", mapping = {}, enabled = true } } })
  local p = assert(vo.ParseProjectFile(text), "Should parse")
  assert(#p.entries == 1 and p.entries[1].select == true, "Entry rows must be unharmed")
end)

--------------------------------
-- LoadScripts
--------------------------------
print("\nLoadScripts:")

local CSV_A = "Filename,Line\nline_a,Alpha\nline_b,Bravo\n"
local CSV_B = "Filename,Line\nline_c,Charlie\n"

local function reader(files)
  return function(path) return files[path] end
end

test("two readable scripts merge into one line list", function()
  local got = vo.LoadScripts(
    { { path = "a.csv", mapping = { asset = "Filename", text = "Line" }, enabled = true },
      { path = "b.csv", mapping = { asset = "Filename", text = "Line" }, enabled = true } },
    reader({ ["a.csv"] = CSV_A, ["b.csv"] = CSV_B }))
  assert(#got.lines == 3, "Expected 3 lines, got " .. #got.lines)
  assert(got.lines[3].asset == "line_c", "Order is script-then-row")
end)

test("each script gets a label from its path", function()
  local got = vo.LoadScripts(
    { { path = "D:/g/Ch2.csv", mapping = { asset = "Filename", text = "Line" } } },
    reader({ ["D:/g/Ch2.csv"] = CSV_A }))
  assert(got.scripts[1].label == "Ch2", "Got " .. tostring(got.scripts[1].label))
  assert(got.lines[1].script == "Ch2", "Lines carry the label")
end)

test("an unreadable script errors alone and the rest still load", function()
  local got = vo.LoadScripts(
    { { path = "gone.csv", mapping = { asset = "Filename", text = "Line" } },
      { path = "b.csv",    mapping = { asset = "Filename", text = "Line" } } },
    reader({ ["b.csv"] = CSV_B }))
  assert(got.scripts[1].error ~= nil and got.scripts[1].error ~= "",
    "The missing file must carry a reason")
  assert(#got.lines == 1 and got.lines[1].asset == "line_c",
    "The readable script must still contribute")
end)

test("a script with no mapping errors rather than silently matching nothing", function()
  local got = vo.LoadScripts({ { path = "a.csv", mapping = {} } },
                             reader({ ["a.csv"] = CSV_A }))
  assert(got.scripts[1].error ~= nil and got.scripts[1].error ~= "",
    "An unmapped script must say so")
  assert(#got.lines == 0, "It must contribute no lines")
end)

test("an empty CSV errors", function()
  local got = vo.LoadScripts(
    { { path = "e.csv", mapping = { asset = "Filename", text = "Line" } } },
    reader({ ["e.csv"] = "" }))
  assert(got.scripts[1].error ~= nil and got.scripts[1].error ~= "", "Expected an error")
end)

test("a header-only CSV errors but keeps its header for the column pickers", function()
  local got = vo.LoadScripts(
    { { path = "h.csv", mapping = { asset = "Filename", text = "Line" } } },
    reader({ ["h.csv"] = "Filename,Line\n" }))
  assert(got.scripts[1].error ~= nil and got.scripts[1].error ~= "", "Expected an error")
  assert(got.scripts[1].header and got.scripts[1].header[1] == "Filename",
    "The header must survive so the mapping combos can still be used")
end)

test("a disabled script is loaded but contributes no lines", function()
  local got = vo.LoadScripts(
    { { path = "a.csv", mapping = { asset = "Filename", text = "Line" }, enabled = false } },
    reader({ ["a.csv"] = CSV_A }))
  assert(got.scripts[1].header ~= nil, "A disabled script is still read, so it can be re-enabled")
  assert(#got.lines == 0, "It contributes nothing while off")
end)
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
./run_tests.sh
```

Expected: FAIL on `p.scripts` being nil and `vo.LoadScripts` being a nil value.

- [ ] **Step 3: Implement the serializer and parser**

In `vo.SerializeProjectFile`, replace the `local out = { … }` block (lines 2439–2443) with:

```lua
  meta = meta or {}
  local out = {
    vo.FormatCSVRow({ vo.PROJECT_MARKER, tostring(vo.PROJECT_VERSION) }),
  }

  -- One row per script, in the order the user added them. This replaces the
  -- single "Script CSV" + "Mapping" pair; ParseProjectFile still reads that pair
  -- so a project saved by an older version opens untouched.
  for _, sc in ipairs(meta.scripts or {}) do
    if sc.path and sc.path ~= "" then
      out[#out + 1] = vo.FormatCSVRow({
        "Script", sc.path, encode_mapping(sc.mapping),
        sc.enabled ~= false and "yes" or "",
      })
    end
  end

  -- Appends are keyed by script LINE, not by a stretch of audio, so like Pins
  -- they cannot live in the entry table. An append whose script is no longer in
  -- the list is still written: removing a script and adding it back must not
  -- throw the user's naming away.
  for _, a in ipairs(meta.appends or {}) do
    if a.text and a.text ~= "" then
      out[#out + 1] = vo.FormatCSVRow({
        "Append", a.script or "", a.asset or "",
        tostring(a.nth or 1), a.text,
      })
    end
  end
```

In `vo.ParseProjectFile`, replace the `local parsed = …` initialiser (lines 2507–2508) with:

```lua
  local parsed = { version = version, scripts = {}, appends = {},
                   entries = {}, pins = {} }
  -- The pre-multi-script format, folded in below only if no Script row appears.
  local legacy_path, legacy_mapping = nil, nil
```

Then in the preamble loop, replace the `if key == "Script CSV" …` chain (lines 2514–2515) with:

```lua
    if     key == "Script CSV" then legacy_path    = rows[i][2] or ""
    elseif key == "Mapping"    then legacy_mapping = decode_mapping(rows[i][2])
    elseif key == "Script" then
      local path = rows[i][2] or ""
      if path ~= "" then
        parsed.scripts[#parsed.scripts + 1] = {
          path    = path,
          mapping = decode_mapping(rows[i][3]),
          -- Anything other than an explicit "" reads as enabled, so a row
          -- hand-edited in a spreadsheet does not silently switch a script off.
          enabled = (rows[i][4] or "") ~= "",
        }
      end
    elseif key == "Append" then
      local script, asset = rows[i][2] or "", rows[i][3] or ""
      local nth, text = tonumber(rows[i][4] or ""), rows[i][5] or ""
      if asset ~= "" and nth and text ~= "" then
        parsed.appends[#parsed.appends + 1] =
          { script = script, asset = asset, nth = math.floor(nth), text = text }
      end
    elseif key == "Pin" then
```

(The existing `Pin` branch body stays exactly as it is; only its `if`/`elseif` keyword changes.)

Finally, immediately after the preamble loop ends (`i = i + 1` / `end`) and before the `if not header_at` check, add:

```lua
  -- A project saved before scripts became a list. Folded in only when no Script
  -- row was found, so an explicit list always wins over a stale legacy row.
  if #parsed.scripts == 0 and legacy_path and legacy_path ~= "" then
    parsed.scripts[1] = { path = legacy_path, mapping = legacy_mapping or {},
                          enabled = true }
  end
```

Update the doc comment above `vo.SerializeProjectFile` (line 2434) to:

```lua
-- `meta` carries the script side of a project's VO state:
-- { scripts = { { path, mapping, enabled }, ... }, appends = { ... }, pins = { ... } }.
-- It lives here rather than in ProjExtState so the project file is the WHOLE of
-- a project's VO state.
```

- [ ] **Step 4: Implement `vo.LoadScripts`**

Add to `VO/lib/ajsfx_vo.lua` after `vo.ResolveNames`:

```lua
-- The whole script side of a project, loaded in one call. Both ajsfx VO Overview
-- and ajsfx VO Cut used to keep their own near-identical copy of this; they now
-- share it, so a script that loads in one window cannot fail to load in the
-- other.
--
-- `read_fn(path)` returns the file's text or nil. Injected rather than opened
-- here so the whole thing stays in the pure layer and is testable headlessly.
--
-- entries: { { path, mapping, enabled }, ... }
-- Returns { scripts = { { path, label, mapping, enabled, header, rows, lines,
--                        error }, ... },
--           lines   = <merged, in script-then-row order> }
--
-- `lines` do NOT carry `deliver`: the caller runs vo.ResolveNames once it has
-- read the project's appends.
function vo.LoadScripts(entries, read_fn)
  local scripts = {}

  for _, e in ipairs(entries or {}) do
    local sc = {
      path    = e.path,
      label   = vo.ScriptLabel(e.path),
      mapping = e.mapping or {},
      enabled = e.enabled ~= false,
      lines   = {},
    }
    scripts[#scripts + 1] = sc

    local text = (e.path and e.path ~= "") and read_fn(e.path) or nil
    if not text then
      sc.error = "Cannot read the script CSV:\n" .. tostring(e.path)
    else
      local rows = vo.ParseCSV(text)
      if #rows < 1 then
        sc.error = "The script CSV is empty."
      else
        local header = table.remove(rows, 1)
        local ok, err = vo.ValidateHeaderNames(header)
        if not ok then
          sc.error = err
        else
          -- Kept even on the errors below, because the header is what the
          -- column pickers are built from -- a script the user still has to map
          -- must show them something to pick.
          sc.header, sc.rows = header, rows
          if #rows == 0 then
            sc.error = "The script CSV has no data rows."
          else
            local cols = vo.MapColumns(header, sc.mapping)
            if not cols then
              sc.error = "This script's Filename and Line text columns are not mapped."
            else
              sc.lines = vo.BuildScriptLines(rows, cols)
            end
          end
        end
      end
    end
  end

  return { scripts = scripts, lines = vo.MergeScriptLines(scripts) }
end
```

- [ ] **Step 5: Run the tests and confirm they pass**

```bash
./run_tests.sh
```

Expected: PASS. Existing project-file tests that assert on `parsed.script_csv` will now fail — update them to read `parsed.scripts[1].path` instead. Grep first:

```bash
grep -n "script_csv" tests/test_vo.lua
```

- [ ] **Step 6: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "feat(VO): a project file holds a list of scripts"
```

---

### Task 6: Thread `deliver` and `line_key` to spans and overview rows

Without this the new names never reach a take and the highlight has nothing to key on.

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua:867` (`FindCandidates`), `:1240` (`PinnedSpans`), `:1738` (`AssignNames`), `:2728` (`make_row` inside `BuildOverview`), `:2791` (the missing-row branch)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `line.deliver`, `line.append_key` (Tasks 2–3).
- Produces: spans carry `deliver`; overview rows carry `deliver`, `line_key`, `script`, `append_key`, `append`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua` after the `LoadScripts` section:

```lua
--------------------------------
-- deliver threading
--------------------------------
print("\ndeliver threading:")

test("AssignNames names a take from deliver, not from asset", function()
  local spans = { { kind = "match", asset = "line_042", deliver = "line_042_ch2",
                    start = 0, stop = 1, select = true } }
  vo.AssignNames(spans, {})
  assert(spans[1].name and spans[1].name:find("line_042_ch2", 1, true),
    "Got " .. tostring(spans[1].name))
end)

test("AssignNames falls back to asset when there is no deliver", function()
  local spans = { { kind = "match", asset = "line_042", start = 0, stop = 1,
                    select = true } }
  vo.AssignNames(spans, {})
  assert(spans[1].name and spans[1].name:find("line_042", 1, true),
    "Got " .. tostring(spans[1].name))
end)

test("overview rows carry the line's identity and delivered name", function()
  local lines = { { asset = "line_a", text = "Alpha", row = 1,
                    script = "Ch2", append_key = "Ch2|line_a|1",
                    deliver = "line_a_x" } }
  local rows = vo.BuildOverview({ lines = lines, matches = {}, entries = {} })
  assert(#rows == 1, "Expected 1 row, got " .. #rows)
  assert(rows[1].line_key == "Ch2|line_a|1", "Got " .. tostring(rows[1].line_key))
  assert(rows[1].deliver == "line_a_x", "Got " .. tostring(rows[1].deliver))
  assert(rows[1].script == "Ch2", "Got " .. tostring(rows[1].script))
end)

test("a row with no matching line carries no line key", function()
  local rows = vo.BuildOverview({ lines = {}, matches = {}, entries = {} })
  for _, row in ipairs(rows) do
    assert(row.line_key == nil, "An orphan must not claim a script line")
  end
end)
```

- [ ] **Step 2: Run the tests and confirm they fail**

```bash
./run_tests.sh
```

Expected: FAIL on `rows[1].line_key` being nil and on the `AssignNames` deliver test.

- [ ] **Step 3: Thread `deliver` onto spans**

Two sites set `asset` from a line. Find them:

```bash
grep -n "character = lines\[line_idx\].speaker" VO/lib/ajsfx_vo.lua
```

At each (currently `VO/lib/ajsfx_vo.lua:868` in `FindCandidates` and `:1241` in `PinnedSpans`), add a `deliver` field beside `asset`, so the pair reads:

```lua
              asset     = lines[line_idx].asset,
              deliver   = lines[line_idx].deliver,
              character = lines[line_idx].speaker,
```

(Match the surrounding indentation at each site — it differs between the two.)

- [ ] **Step 4: Name from `deliver` in `AssignNames`**

In `vo.AssignNames`, the grouping loop at line 1726 keys on `s.asset` and must **keep doing so** — grouping is by script line, not by delivered name. Only the naming changes. Find where the group's name is composed from `asset` (inside the `for _, asset in ipairs(order) do` loop, below the `s.primary` assignment at line 1766) and change the base name it builds from to:

```lua
    -- The delivered name, which is the filename plus whatever the user typed in
    -- the Append column. Grouping above still keys on the raw asset: two lines
    -- that share a filename are still two lines, and numbering their takes
    -- together would be wrong.
    local base = g[1].deliver
    if base == nil or base == "" then base = asset end
```

then use `base` wherever that loop currently uses `asset` to build `s.name`. Read the loop before editing — it applies `review_prefix`, `suffix_alt_names` and `max_len` around the base name, and all of that behaviour is unchanged.

- [ ] **Step 5: Carry the identity into overview rows**

In `vo.BuildOverview`'s `make_row` (line 2728), add to the returned table, beside `asset = s.asset`:

```lua
      deliver       = (line and line.deliver) or s.deliver or s.asset,
      script        = line and line.script or nil,
      append_key    = line and line.append_key or nil,
      append_nth    = line and line.append_nth or nil,
      -- The line's identity for clash detection. Orphans have none: audio that
      -- matched no script line has no delivered name to collide with.
      line_key      = line and line.append_key or nil,
```

In the missing-line branch (line 2791), add beside `asset = line.asset`:

```lua
        deliver       = line.deliver or line.asset,
        script        = line.script,
        append_key    = line.append_key,
        append_nth    = line.append_nth,
        line_key      = line.append_key,
```

- [ ] **Step 6: Run the tests and confirm they pass**

```bash
./run_tests.sh
```

Expected: PASS, including every pre-existing `AssignNames` and `BuildOverview` test.

- [ ] **Step 7: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "feat(VO): a take is named by what the script delivers"
```

---

### Task 7: Overview — script list state and the Script panel

The first coupled task. There is no headless test for ImGui code; verification is by reading and by the manual pass in Task 9.

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — `state` (line 209), `LoadCSV` (309), `ApplyMappingDefaults` (342), `ScriptLines` (356), `LoadProjectFile` (367), `SaveProjectFile` (394), `MatchKey` (464), `Rebuild` (510), `DrawMapping` (1561), the toolbar (2623), startup (2593)

**Interfaces:**
- Consumes: `vo.LoadScripts`, `vo.ResolveNames`, `vo.AppendMap`, `vo.SetAppend`, `vo.DuplicateAssets` (Tasks 3–5).
- Produces: `state.scripts` (array of `{ path, mapping, enabled }` — the *persisted* shape), `state.loaded` (the `vo.LoadScripts` result), `state.appends` (array of Append records), `DrawScriptPanel()`.

- [ ] **Step 1: Replace the script-side state**

In `state` (line 209), delete `script_csv`, `header`, `rows`, `mapping`, `mapping_open`, `header_error` and replace with:

```lua
  -- The scripts this project reads, in the order they were added. This is the
  -- PERSISTED shape: { path, mapping, enabled }. state.loaded below is what
  -- reading them produced, and is rebuilt whenever this changes.
  scripts       = {},
  loaded        = { scripts = {}, lines = {} },
  scripts_open  = false,      -- the Script panel; opens itself when a script fails
  appends       = {},         -- vo.SetAppend records, per script line
  dupe_names    = {},         -- vo.DuplicateNames set, for the red highlight
```

Keep `lines = {}` as it is — it stays the merged, resolved list.

- [ ] **Step 2: Replace `LoadCSV`, `ApplyMappingDefaults` and `ScriptLines`**

Delete all three (lines 309–361) and put in their place:

```lua
-- Read every script the project names, merge their lines, and apply the
-- Appends. state.scripts is the persisted list; state.loaded is what reading it
-- produced, including per-script errors and headers for the column pickers.
local function LoadScripts()
  state.loaded = vo.LoadScripts(state.scripts, ReadFile)
  -- A script whose columns were never mapped gets the header's own suggestion,
  -- so a freshly added CSV usually just works. Auto-detection knows the usual
  -- header names and no more; when it comes up short the panel that fixes it
  -- opens itself rather than waiting to be found.
  local guessed = false
  for i, sc in ipairs(state.loaded.scripts) do
    local persisted = state.scripts[i]
    if sc.header and not (persisted.mapping and next(persisted.mapping)) then
      persisted.mapping = vo.AutoDetectMapping(sc.header) or {}
      guessed = true
    end
  end
  if guessed then state.loaded = vo.LoadScripts(state.scripts, ReadFile) end

  for _, sc in ipairs(state.loaded.scripts) do
    if sc.error and sc.error ~= "" then state.scripts_open = true end
  end

  vo.ResolveNames(state.loaded.lines, vo.AppendMap(state.appends))
end

-- The script lines this project expects, after skip tokens and with every
-- Append applied. Returns an empty list (never nil) so callers need no special
-- case.
local function ScriptLines()
  return state.loaded.lines or {}
end

-- How many scripts could not be read or mapped, for the banner.
local function BadScriptCount()
  local n = 0
  for _, sc in ipairs(state.loaded.scripts or {}) do
    if sc.error and sc.error ~= "" then n = n + 1 end
  end
  return n
end
```

`ReadFile` is defined at line 284, above this point — no reordering needed.

- [ ] **Step 3: Update project-file load and save**

In `LoadProjectFile` (line 367), replace the reset line and the two assignments:

```lua
  state.entries, state.project_error, state.parse_failed = {}, "", false
  state.scripts, state.appends, state.pins = {}, {}, {}
```

and inside `if parsed then`:

```lua
    state.entries = parsed.entries
    state.scripts = parsed.scripts or {}
    state.appends = parsed.appends or {}
    state.pins    = parsed.pins or {}
```

In `SaveProjectFile` (line 411), replace the `meta` argument:

```lua
  local ok = WriteFile(path, vo.SerializeProjectFile(
    vo.ProjectEntriesFromRows(state.overview),
    { scripts = state.scripts, appends = state.appends, pins = state.pins }))
```

- [ ] **Step 4: Update the match key**

Replace `MatchKey`'s signature and its first line (lines 464–465):

```lua
local function MatchKey(paths, scripts, cfg)
  local parts = { CfgKey(cfg) }
  -- Every script, in order: adding one, removing one, remapping a column or
  -- switching one off all change which audio matches which line. Appends are
  -- deliberately NOT here -- they change only the delivered name, so a rename
  -- must not cost a re-match.
  for _, sc in ipairs(scripts or {}) do
    parts[#parts + 1] = "script:" .. (sc.path or "") .. ":"
      .. vo.SerializeLayout({ mapping = sc.mapping })
      .. ":" .. (sc.enabled ~= false and "1" or "0")
  end
```

and its caller in `LoadMatches` (line 481):

```lua
  local key   = MatchKey(paths, state.scripts, cfg)
```

- [ ] **Step 5: Update `Rebuild`**

In `Rebuild` (line 510), replace the `state.lines` / `state.dupe_assets` lines:

```lua
  state.items = vo.CollectProjectSpans()
  LoadScripts()
  state.lines = ScriptLines()
  -- A delivered name two script lines both claim. The clips cut fine -- two
  -- items in REAPER may share a name -- but the collision becomes real when
  -- they are rendered to files, so it is reported, and the table shows it in
  -- red until the user separates them with an Append.
  state.dupe_assets = vo.DuplicateAssets(state.lines)
```

and, after `state.summary = vo.SummarizeOverview(state.overview)` (line 528), add:

```lua
  -- Row-level, so a per-take name override can clear a clash or create one.
  state.dupe_names = vo.DuplicateNames(state.overview)
```

- [ ] **Step 6: Replace `DrawMapping` with `DrawScriptPanel`**

Delete `DrawMapping` (lines 1561–1607) and put in its place:

```lua
-- The Script panel: every CSV this project reads, with its own column mapping
-- and its own on/off switch. Drawn inline above the table, like the mapping
-- panel it replaces.
local function DrawScriptPanel()
  im.Separator(ctx)
  im.Text(ctx, "Scripts")
  im.SameLine(ctx)
  if im.Button(ctx, "Add script…") then
    -- With no script yet, start in the project's own folder rather than
    -- wherever REAPER defaults to (its resource path).
    local dir = ProjectPath():match("^(.*[\\/])")
    local start_at = dir and (dir .. "*.csv") or ""
    local ok, path = r.GetUserFileNameForRead(start_at, "Add a script CSV", "csv")
    if ok then
      local already = false
      for _, sc in ipairs(state.scripts) do
        if sc.path == path then already = true; break end
      end
      if already then
        state.message, state.message_kind =
          vo.Basename(path) .. " is already in the list.", "error"
      else
        state.scripts[#state.scripts + 1] =
          { path = path, mapping = {}, enabled = true }
        state.dirty = true
        Reload()
      end
    end
  end
  im.SameLine(ctx)
  if im.Button(ctx, "Close##scripts") then state.scripts_open = false end

  local remove_at = nil
  for i, sc in ipairs(state.loaded.scripts or {}) do
    local persisted = state.scripts[i]
    im.PushID(ctx, "script_" .. i)

    local changed, on = im.Checkbox(ctx, "##on", persisted.enabled ~= false)
    if changed then
      persisted.enabled = on
      state.dirty = true
      Reload()
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "A script that is off stays in the list but contributes\n" ..
                         "no lines and takes no part in matching.")
    end

    im.SameLine(ctx)
    im.Text(ctx, vo.Basename(sc.path or ""))
    if im.IsItemHovered(ctx) then im.SetTooltip(ctx, sc.path or "") end

    if sc.header then
      for _, spec in ipairs(MAP_ROLES) do
        im.SameLine(ctx)
        local mapped  = persisted.mapping[spec.role]
        local preview = mapped or (spec.optional and "(none)" or "Column…")
        im.SetNextItemWidth(ctx, 140)
        if im.BeginCombo(ctx, "##map_" .. spec.role, preview) then
          -- A change of mapping changes what every row means, so it re-derives
          -- the match rather than editing rows in place. The match cache keys on
          -- the mapping, so Reload is enough -- see MatchKey. Called directly,
          -- not deferred: this panel draws above the table, not inside it.
          if spec.optional and im.Selectable(ctx, "(none)", mapped == nil)
             and mapped ~= nil then
            persisted.mapping[spec.role] = nil
            state.dirty = true
            Reload()
          end
          for _, h in ipairs(sc.header) do
            if im.Selectable(ctx, h, h == mapped) and h ~= mapped then
              persisted.mapping[spec.role] = h
              state.dirty = true
              Reload()
            end
          end
          im.EndCombo(ctx)
        end
        if im.IsItemHovered(ctx) then im.SetTooltip(ctx, spec.label .. ": " .. spec.hint) end
      end
    end

    im.SameLine(ctx)
    if im.Button(ctx, "Remove") then remove_at = i end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Takes the script out of the list.\n" ..
                         "Anything typed in its Append column is kept.")
    end

    if sc.error and sc.error ~= "" then
      im.TextColored(ctx, 0xDD6666FF, "    " .. sc.error)
    elseif sc.enabled then
      im.TextDisabled(ctx, string.format("    %d script line%s.",
        #sc.lines, #sc.lines == 1 and "" or "s"))
    end

    im.PopID(ctx)
  end

  if #(state.loaded.scripts or {}) == 0 then
    im.TextDisabled(ctx, "No scripts yet. Press Add script… to choose one.")
  end

  -- Removed after the loop: mutating the list mid-draw would shift every index
  -- under the widgets still to be drawn.
  if remove_at then
    table.remove(state.scripts, remove_at)
    state.dirty = true
    Reload()
  end

  im.Separator(ctx)
end
```

`MAP_ROLES` already exists in this file — check its `role`/`label`/`optional`/`hint` fields still match this usage before running.

- [ ] **Step 7: Update the toolbar**

Replace the toolbar block (lines 2623–2684) with:

```lua
    -- Scripts -------------------------------------------------------------
    im.Text(ctx, "Script:")
    im.SameLine(ctx)
    local n_scripts = #state.scripts
    if n_scripts == 0 then
      im.TextDisabled(ctx, "none chosen")
    else
      local label = vo.Basename(state.scripts[1].path or "")
      if n_scripts > 1 then label = label .. string.format(" +%d more", n_scripts - 1) end
      im.TextDisabled(ctx, label)
      if im.IsItemHovered(ctx) then
        local all = {}
        for _, sc in ipairs(state.scripts) do all[#all + 1] = sc.path end
        im.SetTooltip(ctx, table.concat(all, "\n"))
      end
    end

    im.SameLine(ctx)
    if im.Button(ctx, "Script") then state.scripts_open = not state.scripts_open end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "The script CSVs this project reads, and which column of\n" ..
                         "each holds the filename, the line and the character.")
    end
    im.SameLine(ctx)
    -- The other two windows of the set. Overview is where a session is read, so
    -- it is also where the user reaches for the window that makes the words and
    -- the window that makes the clips.
    if im.Button(ctx, "Sources…") then
      local ok, why = vo.LaunchSibling("ajsfx_VO_Sources.lua")
      if not ok then state.message, state.message_kind = tostring(why), "error" end
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Cut…") then
      local ok, why = vo.LaunchSibling("ajsfx_VO_Cut.lua")
      if not ok then state.message, state.message_kind = tostring(why), "error" end
    end
    im.SameLine(ctx)
    if im.Button(ctx, "Settings") then state.settings_open = true end

    if state.scripts_open then DrawScriptPanel() end

    local bad = BadScriptCount()
    if bad > 0 then
      im.TextColored(ctx, 0xDDAA33FF, string.format(
        "%d of %d script%s is not usable, so its lines are missing.",
        bad, n_scripts, n_scripts == 1 and "" or "s"))
      im.SameLine(ctx)
      if im.Button(ctx, "Script##warn") then state.scripts_open = true end
    end
```

- [ ] **Step 8: Update startup**

Replace lines 2593–2595:

```lua
LoadProjectFile()
LoadLayoutSettings()
LoadViewSettings()
Reload()
```

`Reload` calls `Rebuild`, which now calls `LoadScripts` itself, so the explicit startup load is gone.

- [ ] **Step 9: Check nothing still references the deleted state**

```bash
grep -n "state.script_csv\|state.mapping\|state.header\b\|state.header_error\|mapping_open\|DrawMapping" VO/ajsfx_VO_Overview.lua
```

Expected: no matches. Fix any that remain.

- [ ] **Step 10: Verify it loads**

```bash
luac -p VO/ajsfx_VO_Overview.lua && echo "syntax OK"
```

(If `luac` is unavailable, `lua -e "loadfile('VO/ajsfx_VO_Overview.lua')"` does the same check.)

Then open the window in REAPER: it should show `Script: none chosen` on a fresh project, and a project saved by the previous version should open with its one script listed and mapped.

- [ ] **Step 11: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "feat(VO): a project reads as many scripts as it needs"
```

---

### Task 8: Overview — the Append and Script columns, and the red highlight

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — `COLUMNS` (122), `DrawTableBody` (2054–2325), `SetNotes` neighbourhood (616)

**Interfaces:**
- Consumes: `state.dupe_names` (Task 7), `row.deliver` / `row.line_key` / `row.append_key` (Task 6), `vo.SetAppend` (Task 3).
- Produces: a `CI` key→index map, `SetAppend(row, text)`.

- [ ] **Step 1: Replace hardcoded column indices with a lookup**

`DrawTableBody` addresses columns by literal index (`im.TableSetColumnIndex(ctx, 7)`), so inserting a column means renumbering a dozen call sites by hand. Do this first, on its own, so the insert that follows cannot silently shift a cell into the wrong column.

After `COLUMN_BY_KEY` (line 173), add:

```lua
-- Column index by key, 0-based for ImGui. DrawTableBody addresses cells through
-- this rather than by literal number, so inserting a column is one edit to
-- COLUMNS instead of a renumbering of every call site below.
local CI = {}
for i, c in ipairs(COLUMNS) do CI[c.key] = i - 1 end
```

Then in `DrawTableBody`, replace every `im.TableSetColumnIndex(ctx, <n>)` with the keyed form, and every `CellText(row, "<key>", <n>, …)` third argument likewise:

| Was | Becomes |
|---|---|
| `im.TableSetColumnIndex(ctx, 0)` | `im.TableSetColumnIndex(ctx, CI.order)` |
| `..., 1)` | `CI.verify` |
| `..., 2)` | `CI.status` |
| `..., 3)` | `CI.select` |
| `..., 4)` | `CI.character` |
| `..., 5)` | `CI.item_name` |
| `..., 6)` | `CI.asset` |
| `..., 7)` | `CI.take` |
| `..., 8)` | `CI.line_text` |
| `..., 9)` | `CI.transcript` |
| `..., 10)` | `CI.source` |
| `..., 11)` | `CI.time` |
| `..., 12)` | `CI.notes` |

`CellText(row, "character", 4, …)` becomes `CellText(row, "character", CI.character, …)`, and so on for every `CellText` call — its third parameter is the same column index.

Verify none are left:

```bash
grep -n "TableSetColumnIndex(ctx, [0-9]" VO/ajsfx_VO_Overview.lua
```

Expected: no matches. Then open the window in REAPER and confirm the table is unchanged — this step must be behaviour-neutral.

- [ ] **Step 2: Commit the refactor on its own**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "refactor(VO): address table columns by name, not by number"
```

- [ ] **Step 3: Add the two columns**

In `COLUMNS`, insert a `script` entry immediately after `character` (line 140):

```lua
  { key = "script",     label = "Script",     width =  90,
    text = function(row) return row.script or "" end,
    tip = "Which script CSV this line came from." },
```

and an `append` entry immediately after `asset` (line 151):

```lua
  { key = "append",     label = "Append",     width = 110,
    text = function(row) return row.append or "" end,
    tip = "Added to the end of the CSV filename to make the delivered name.\n" ..
          "No separator is inserted -- type the one you want. Use it to tell\n" ..
          "apart two lines that ask for the same filename." },
```

`CI` is built from `COLUMNS`, so every index shifts correctly with no further edits.

- [ ] **Step 4: Give rows their current Append text**

In `Rebuild`, after the `state.dupe_names` line added in Task 7, add:

```lua
  -- The Append cell needs the text to show, and the row is what the cell has.
  local appends = vo.AppendMap(state.appends)
  for _, row in ipairs(state.overview) do
    row.append = row.append_key and appends[row.append_key] or nil
  end
```

- [ ] **Step 5: Add the mutator**

After `SetNotes` (line 618), add:

```lua
-- The Append belongs to the SCRIPT LINE, not to the take, so it is written to
-- state.appends rather than through EntryFor -- and every take of the line picks
-- it up on the next rebuild. Nothing about the match changes, so this does not
-- invalidate the match cache; only the delivered name moves.
local function SetAppend(row, text)
  if not row.append_key then return end
  vo.SetAppend(state.appends, row.script or "", row.asset or "",
               row.append_nth or 1, text)
  state.dirty = true
  Rebuild()
end
```

- [ ] **Step 6: Draw the two cells**

In `DrawTableBody`, after the Character cell, add:

```lua
    im.TableSetColumnIndex(ctx, CI.script)
    CellText(row, "script", CI.script, row_h, row.script, "disabled")
```

After the CSV filename cell's context menu (the `im.EndPopup(ctx)` / `end` around line 2263), add:

```lua
    -- Append --------------------------------------------------------------
    im.TableSetColumnIndex(ctx, CI.append)
    if row.line_key then
      PushFilledField("append", row_h)
      local achanged, atext = im.InputText(ctx, "##append", row.append or "")
      PopFilledField()
      if achanged then
        local captured = atext
        pending_action = function() SetAppend(row, captured) end
      end
      if im.IsItemHovered(ctx) and (row.append or "") == "" then
        im.SetTooltip(ctx, "Type something here to tell this line apart from\n" ..
                           "another that asks for the same filename.")
      end
    end
```

An orphan row has no `line_key` and so gets no Append field — it has no script line to append to.

- [ ] **Step 7: Paint the clash red**

Change the CSV filename cell to colour its text when the row's delivered name is contested. Replace:

```lua
    local csv_name = row.asset or ""
    CellText(row, "asset", CI.asset, row_h, csv_name, "disabled")
```

with:

```lua
    local csv_name = row.asset or ""
    -- Red until this line's delivered name is its own. The name being compared
    -- is the RESOLVED one, so the moment an Append (or a rename) separates the
    -- two lines, both go back to normal.
    local resolved = (row.name_override ~= nil and row.name_override ~= "")
                     and row.name_override or row.deliver
    local clash = row.line_key ~= nil and resolved ~= nil
                  and state.dupe_names[resolved] == true
    CellText(row, "asset", CI.asset, row_h, csv_name, clash and 0xDD6666FF or "disabled")
    if clash and im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Another script line is delivered under this same name.\n" ..
                         "The clips cut fine, but they will overwrite each other\n" ..
                         "when rendered to files. Type something in Append to\n" ..
                         "tell them apart.")
    end
```

`CellText`'s colour parameter already accepts a literal colour — the Transcript cell passes `0xDDAA33FF` at line 2278.

Then in the Append cell added in Step 6, shade the field red when the clash is the Append's to fix. Replace `PushFilledField("append", row_h)` with:

```lua
      PushFilledField("append", row_h)
      -- AFTER PushFilledField, never before: that helper sets this cell's own
      -- background to the editable-field shade, so a red set first would simply
      -- be overwritten.
      --
      -- A row whose name comes from a hand-typed override is not the Append's
      -- problem to fix, so there only the filename goes red.
      if clash and (row.name_override == nil or row.name_override == "") then
        im.TableSetBgColor(ctx, im.TableBgTarget_CellBg, 0x66222240, -1)
      end
```

`clash` is computed in the CSV filename cell, which is drawn earlier in the same row — declare it with `local` there, as written below, so it is in scope here.

- [ ] **Step 8: Update the Item name fallback**

The Item name cell (line 2224) falls back to `row.asset`; it must fall back to the delivered name so a take with an Append shows what it will actually be called. Replace:

```lua
    local shown = row.take_name or row.name_override or row.asset or ""
```

with:

```lua
    local shown = row.take_name or row.name_override or row.deliver or row.asset or ""
```

and the same expression in `ItemName` (line 108):

```lua
local function ItemName(row)
  return row.take_name or row.name_override or row.deliver or row.asset or ""
end
```

and in `ResetName` (line 669), which puts "the script's own name" back — that is now the delivered name:

```lua
  local clean = vo.SanitizeName(row.deliver or row.asset or "")
```

and the `can_reset` comparison in the CSV filename context menu (line 2255):

```lua
      local can_reset = row.status ~= "missing" and shown ~= (row.deliver or csv_name)
```

- [ ] **Step 9: Update Cut to use the shared loader**

In `VO/ajsfx_VO_Cut.lua`, delete `LoadCSV` (lines 91–115), `ApplyMappingDefaults` (143–146) and `ScriptLines` (148–153), and replace with:

```lua
local function ScriptLines()
  local loaded = vo.LoadScripts(state.scripts, ReadFile)
  vo.ResolveNames(loaded.lines, vo.AppendMap(state.appends))
  state.script_errors = {}
  for _, sc in ipairs(loaded.scripts) do
    if sc.error and sc.error ~= "" then
      state.script_errors[#state.script_errors + 1] =
        vo.Basename(sc.path or "") .. ": " .. sc.error
    end
  end
  return loaded.lines
end
```

In `state` (line 58) replace `mapping = {}` and `script_csv = ""` with:

```lua
  scripts       = {},
  appends       = {},
  script_errors = {},
```

In Cut's `LoadProjectFile` (line 117), replace the reset and the two assignments the same way as Overview's:

```lua
  state.entries = {}
  state.scripts, state.appends, state.pins = {}, {}, {}
```
```lua
    state.entries = parsed.entries
    state.scripts = parsed.scripts or {}
    state.appends = parsed.appends or {}
    -- Read here too, and not only in Overview: a pin is an INPUT to matching,
    -- so cutting without it would cut a different placement than the one the
    -- user pinned and is looking at.
    state.pins    = parsed.pins or {}
```

Replace the startup call at line 616 (`LoadCSV(state.script_csv)`) — delete it; `ScriptLines()` now reads the files itself wherever `state.lines` is built. Find that site:

```bash
grep -n "ScriptLines()\|ApplyMappingDefaults" VO/ajsfx_VO_Cut.lua
```

and make sure each remaining call still lines up.

Finally, surface the per-script errors beside the existing duplicate note (line 553). Immediately before the `local dupes = …` line, add:

```lua
    for _, why in ipairs(state.script_errors or {}) do
      im.TextColored(ctx, 0xDD6666FF, why)
    end
```

- [ ] **Step 10: Check both files load**

```bash
luac -p VO/ajsfx_VO_Overview.lua VO/ajsfx_VO_Cut.lua && echo "syntax OK"
```

Then in REAPER: load two CSVs that share a filename, confirm both rows go red on the Filename cell with a red Append cell, type an Append on one, confirm both clear, and confirm Cut names the clip with the Append.

- [ ] **Step 11: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua VO/ajsfx_VO_Cut.lua
git commit -m "feat(VO): an append column separates two lines that share a filename"
```

---

### Task 9: Manual test steps, versions and changelog

**Files:**
- Modify: `VO/MANUAL_TEST.md`, `VO/ajsfx_VO_Overview.lua` (header), `VO/ajsfx_VO_Cut.lua` (header), `VO/lib/ajsfx_vo.lua` (header)

- [ ] **Step 1: Add the manual test section**

Append to `VO/MANUAL_TEST.md`, matching the heading style already in that file:

```markdown
## Several scripts, and the Append column

1. Open **ajsfx VO Overview** on a project saved by the previous version. Its one
   script is listed under **Script**, still mapped, and the table is unchanged.
2. Press **Script** → **Add script…** and choose a second CSV. Both scripts' lines
   appear; the **Script** column tells them apart.
3. Add the same CSV again. It is refused with a message and the list is unchanged.
4. Untick a script. Its lines vanish and the match re-runs — with no
   re-transcription and no progress bar.
5. Remove a script and add it back. Anything typed in its Append column is still
   there.
6. Point a script's **Filename** combo at the wrong column. That script alone shows
   an error; the other script's lines are still matched.
7. Load two scripts that deliver the same filename. Both lines show a **red
   filename** and a **red Append cell**, on every take.
8. Type `_ch2` in one line's Append. Both lines go back to normal, and the Item
   name column shows `<filename>_ch2`.
9. Two lines *inside one script* sharing a filename behave identically.
10. Instead of an Append, rename one of two clashing lines with the Item name
    field. The red clears. Rename it back to the other's name — the red returns.
11. Run **ajsfx VO Cut**. The clips carry the appended names, and a script that
    failed to load is reported in the Cut window too.
```

- [ ] **Step 2: Bump versions and write the changelog**

Read the current `@version` in each header and increment the minor component. Add a `@changelog` entry to `VO/ajsfx_VO_Overview.lua` in the plain-language style the existing entry uses — describing what the user can now do, not what the code does:

> A project can now read more than one script CSV. Press "Script" for the list: add a CSV, switch one off without removing it, and map each script's own Filename, Line text and Character columns — a character who recorded lines from three scripts is one session again. The "Choose…" button is gone; "Script" replaces it, and the Columns… panel now lives inside it, one row per script. A new "Script" column says which CSV a line came from. When two script lines ask to be delivered under the same filename — whether they come from two scripts or from two rows of one — the filename turns red and so does a new "Append" column beside it. Type anything in Append and it goes on the end of the delivered name, with no separator added, so you choose it: type "_ch2" and the line delivers as "line_042_ch2". Both lines go back to normal as soon as their names differ. Renaming a take by hand does the same job, and a rename that recreates a clash turns red too. Nothing is ever renamed for you.

Add a matching, shorter entry to `VO/ajsfx_VO_Cut.lua`'s `@changelog` covering that it reads the project's whole script list and cuts with the appended names.

- [ ] **Step 3: Run the tests one last time**

```bash
./run_tests.sh
```

Expected: PASS, 0 failed.

- [ ] **Step 4: Commit and push**

```bash
git add VO/
git commit -m "docs(VO): version and document the multi-script release"
git push -u origin HEAD
```

- [ ] **Step 5: Confirm CI went green**

```bash
gh run list --limit 1
```

Expected: the most recent run is `completed  success`. A failed run publishes nothing and says nothing. Also skim the build log — `reapack-index` reports packaging mistakes as warnings, so the index can build "successfully" while silently omitting a package:

```bash
gh run view --log | grep -i "warn"
```

---

## Notes for the implementer

**Where the pure/coupled line sits.** `VO/lib/ajsfx_vo.lua` is required by headless tests with only `tests/mock_reaper.lua` for a `reaper` global. Anything you add there that calls `r.` beyond what the module already does will break `./run_tests.sh` immediately — which is the point.

**The `@noindex` lib.** `VO/lib/ajsfx_vo.lua` carries `@noindex`, so it is shipped by the `@provides` block in the indexed scripts rather than published on its own. Bump its `@version` alongside them.

**Why `Rebuild` and not `Reload` after an Append edit.** `Reload` resets the rescan clock; an Append changes no matching input, so `Rebuild` is the correct, cheaper call. `Reload` is right for a mapping or script-list change, because those *do* re-derive the match.

**One action per frame.** Overview defers user actions through `pending_action`, run after `im.End`. Anything that mutates state or the project from inside the table must go through it — see the existing `SetNotes` and `Rename` call sites.
