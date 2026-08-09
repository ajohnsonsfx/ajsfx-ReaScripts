# VO Ranged Take Markers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recorded-take tracking moves onto ranged take markers — one visible, natively-editable, authoritative marker per performance — replacing the GUID-anchor mechanism before anything is pushed.

**Architecture:** Pure string layer parses and rewrites the undocumented `TKM <srcpos> <name> <color> <length>` chunk lines. `vo.BuildOverview` gains a `markers` input; a line with markers builds its take rows from them and ignores the match. Kickstart writes markers then cuts at their bounds; split propagation delivers each piece its identity. The coverage rule (a marker counts only where its range intersects its item's window) absorbs split residue.

**Tech Stack:** Lua 5.4, REAPER API (`Get/SetItemStateChunk`), ReaImGui 0.9.3. Pure logic tested against `tests/mock_reaper.lua`.

Design spec: [`docs/superpowers/specs/2026-08-09-vo-take-markers-design.md`](../specs/2026-08-09-vo-take-markers-design.md)

## Global Constraints

- Marker name = `<asset> ~<id>`, id = 2–3 base36 chars, unique per project. The `~` splits display-name from id; assets never contain `~` followed by a trailing base36 token by accident (verified against the Grumbar asset list — all end in words).
- Chunk name tokens containing whitespace are quoted; REAPER accepts `"`, `'`, or backtick as the delimiter. The parser must accept all three; the serializer picks the first that does not occur in the name.
- v1 handles single-take items only: a chunk containing a second `TAKE` block is left unpatched and reported. The VO session shape is single-take throughout.
- Times in markers are SOURCE seconds. Item coverage comes from `vo.SourceCoverageRanges`.
- Run `./run_tests.sh` before each commit; every file must end `0 failed`.
- `@version` stays `0.15beta3` (unpushed, unpublished); Task 8 rewrites its changelog.
- The anchor retirement (Task 3) must leave every remaining test green — anchors were shipped to `main` locally but never pushed, so removal is free.

---

## File Structure

| File | Change |
|---|---|
| `VO/lib/ajsfx_vo.lua` | New pure section "take markers"; `BuildOverview` markers input; anchor code removed |
| `VO/ajsfx_VO_Overview.lua` | Marker collection in `Rebuild`; kickstart/Cut rewiring; verbs; repair rewiring; anchor UI removed |
| `tests/test_vo_markers.lua` | Create — all pure marker tests |
| `tests/test_vo_identity.lua` | Anchor sections removed; tri-state/track/reconcile sections stay |
| `VO/SPEC-overview.md`, `VO/MANUAL_TEST.md` | Take-identity section rewritten for markers |

**Phasing:** Tasks 1–4 make markers readable end to end (sheet driven by markers where they exist). Tasks 5–6 make them writable (kickstart, migration, verbs). Task 7 rewires repair. Task 8 documents and finalizes.

---

### Task 1: Pure TKM chunk layer

**Files:** Modify `VO/lib/ajsfx_vo.lua` (new section after the anchors section), create `tests/test_vo_markers.lua`.

**Interfaces produced:**
- `vo.ParseTKMChunk(chunk) -> array of { pos, name, color, length }`
- `vo.FormatTKMLine(marker) -> string`
- `vo.PatchTKMChunk(chunk, markers) -> new_chunk, ok` (ok=false: multi-take, unchanged)
- `vo.FormatMarkerName(asset, id)` / `vo.ParseMarkerName(name) -> asset, id|nil`

- [ ] **Step 1: Write the failing tests** — create `tests/test_vo_markers.lua` with the standard harness header (copy the `test`/`passed`/`failed` scaffold from `tests/test_vo_identity.lua`, require mock + vo), then:

```lua
print("ParseTKMChunk:")

local CHUNK = table.concat({
  "<ITEM", "POSITION 1", "LENGTH 10", "NAME plain",
  "<SOURCE WAVE", 'FILE "a.wav"', ">", ">",
}, "\n")

local function with_tkm(lines)
  return (CHUNK:gsub("<SOURCE", table.concat(lines, "\n") .. "\n<SOURCE", 1))
end

test("a bare-name ranged line parses", function()
  local m = vo.ParseTKMChunk(with_tkm({ "TKM 2 RTEST 0 4" }))
  assert(#m == 1, "count: " .. #m)
  assert(m[1].pos == 2 and m[1].length == 4 and m[1].name == "RTEST")
end)

test("a quoted name with spaces parses, any delimiter", function()
  for _, q in ipairs({ '"', "'", "`" }) do
    local m = vo.ParseTKMChunk(with_tkm({
      "TKM 1.5 " .. q .. "DBP_Book ~k7" .. q .. " 0 3.25" }))
    assert(#m == 1, q .. " count: " .. #m)
    assert(m[1].name == "DBP_Book ~k7", q .. " name: " .. tostring(m[1].name))
    assert(math.abs(m[1].length - 3.25) < 1e-9, q .. " length lost")
  end
end)

test("a point marker parses with length 0", function()
  local m = vo.ParseTKMChunk(with_tkm({ "TKM 7 POINT 0 0" }))
  assert(m[1].length == 0)
end)

test("a legacy line with no fourth field parses with length 0", function()
  local m = vo.ParseTKMChunk(with_tkm({ "TKM 7 OLD 0" }))
  assert(#m == 1 and m[1].length == 0)
end)

print("FormatTKMLine:")

test("a name with spaces is quoted and round-trips", function()
  local line = vo.FormatTKMLine({ pos = 2, name = "DBP_Book ~k7", color = 0, length = 4 })
  local m = vo.ParseTKMChunk(with_tkm({ line }))
  assert(m[1].name == "DBP_Book ~k7", "round trip: " .. tostring(m[1].name))
  assert(m[1].length == 4)
end)

test("a name containing a double quote picks another delimiter", function()
  local line = vo.FormatTKMLine({ pos = 1, name = 'say "no" ~a1', color = 0, length = 2 })
  assert(not line:find('^TKM 1 "say'), "used a delimiter the name contains")
  local m = vo.ParseTKMChunk(with_tkm({ line }))
  assert(m[1].name == 'say "no" ~a1', "round trip: " .. tostring(m[1].name))
end)

print("PatchTKMChunk:")

test("patching replaces existing TKM lines wholesale", function()
  local c1 = with_tkm({ "TKM 2 OLD 0 4", "TKM 5 OLD2 0 1" })
  local c2, ok = vo.PatchTKMChunk(c1, { { pos = 3, name = "NEW ~x1", color = 0, length = 2 } })
  assert(ok, "patch refused")
  local m = vo.ParseTKMChunk(c2)
  assert(#m == 1 and m[1].name == "NEW ~x1", "old lines survived or new missing")
end)

test("patching a chunk with no TKM lines inserts before SOURCE", function()
  local c2, ok = vo.PatchTKMChunk(CHUNK, { { pos = 1, name = "A ~b2", color = 0, length = 3 } })
  assert(ok)
  local m = vo.ParseTKMChunk(c2)
  assert(#m == 1, "insert failed")
  assert(c2:find("TKM") < c2:find("<SOURCE"), "TKM landed after the SOURCE block")
end)

test("an empty marker list strips all TKM lines", function()
  local c2 = vo.PatchTKMChunk(with_tkm({ "TKM 2 OLD 0 4" }), {})
  assert(#vo.ParseTKMChunk(c2) == 0, "TKM lines survived a clear")
end)

test("a multi-take chunk is refused unchanged", function()
  local multi = CHUNK:gsub(">%s*$", 'TAKE\nNAME "second"\n>')
  local c2, ok = vo.PatchTKMChunk(multi, { { pos = 1, name = "A ~c3", color = 0, length = 1 } })
  assert(ok == false, "multi-take chunk was patched")
  assert(c2 == multi, "chunk changed despite refusal")
end)

print("Marker names:")

test("FormatMarkerName and ParseMarkerName round-trip", function()
  local asset, id = vo.ParseMarkerName(vo.FormatMarkerName("DBP_Grumbar_Book", "k7"))
  assert(asset == "DBP_Grumbar_Book" and id == "k7")
end)

test("a name with no id parses as asset only", function()
  local asset, id = vo.ParseMarkerName("DBP_Grumbar_Book")
  assert(asset == "DBP_Grumbar_Book" and id == nil)
end)

test("a tilde inside the asset does not fake an id", function()
  local asset, id = vo.ParseMarkerName("weird~name here")
  assert(id == nil, "invented id: " .. tostring(id))
  assert(asset == "weird~name here")
end)
```

- [ ] **Step 2: Run to verify failure** — `lua tests/test_vo_markers.lua`, expect nil-call failures.
- [ ] **Step 3: Implement** in a new pure section directly below the anchors section:

```lua
--------------------------------
-- Pure layer: ranged take markers
--------------------------------

-- The item state chunk stores take markers as `TKM <srcpos> <name> <color>
-- <length>` -- the fourth field is UNDOCUMENTED and API-invisible, but REAPER
-- renders it as a range, native mouse gestures edit it (drag moves the start
-- with length intact, alt-drag moves the end), and API edits leave it alone.
-- Verified in v7.78, 2026-08-09; see SoundDesignDocs
-- Workflow/reaper-session-automation.md §4. All range I/O is chunk I/O, so
-- this whole layer is string work and unit-testable.

function vo.ParseTKMChunk(chunk)
  local out = {}
  for line in tostring(chunk or ""):gmatch("[^\n]+") do
    local body = line:match("^%s*TKM%s+(.*)$")
    if body then
      local pos_s, rest = body:match("^(%S+)%s+(.*)$")
      local pos = tonumber(pos_s)
      if pos and rest then
        local name, tail
        local q = rest:sub(1, 1)
        if q == '"' or q == "'" or q == "`" then
          name, tail = rest:match("^" .. q .. "(.-)" .. q .. "%s*(.*)$")
        else
          name, tail = rest:match("^(%S+)%s*(.*)$")
        end
        if name then
          local color_s, len_s = (tail or ""):match("^(%S*)%s*(%S*)")
          out[#out + 1] = {
            pos    = pos,
            name   = name,
            color  = tonumber(color_s) or 0,
            length = tonumber(len_s) or 0,
          }
        end
      end
    end
  end
  return out
end

-- REAPER's chunk quoting: bare when the token has no whitespace or quotes,
-- else wrapped in whichever of " ' ` the token does not contain.
local function tkm_quote(name)
  name = tostring(name or "")
  if name ~= "" and not name:find("[%s\"'`]") then return name end
  for _, q in ipairs({ '"', "'", "`" }) do
    if not name:find(q, 1, true) then return q .. name .. q end
  end
  return '"' .. name:gsub('"', "'") .. '"'
end

function vo.FormatTKMLine(m)
  return string.format("TKM %.14g %s %d %.14g",
    m.pos or 0, tkm_quote(m.name), math.floor(m.color or 0), m.length or 0)
end

-- Replace ALL TKM lines in an item chunk with `markers`. Existing lines are
-- stripped; new ones are inserted where the old ones sat, or before the
-- take's <SOURCE block when there were none. v1 refuses multi-take items
-- (second TAKE block): the VO session shape is single-take, and guessing
-- which take owns which line is exactly the ambiguity this tool is built to
-- avoid. Returns the (possibly unchanged) chunk and whether it patched.
function vo.PatchTKMChunk(chunk, markers)
  chunk = tostring(chunk or "")
  if chunk:find("\n%s*TAKE%s*\n") or chunk:find("\n%s*TAKE%s+%S") then
    return chunk, false
  end

  local lines, insert_at = {}, nil
  for line in chunk:gmatch("[^\n]+") do
    if line:match("^%s*TKM%s") then
      insert_at = insert_at or (#lines + 1)
    else
      if not insert_at and line:match("^%s*<SOURCE") then
        insert_at = #lines + 1
      end
      lines[#lines + 1] = line
    end
  end
  insert_at = insert_at or #lines  -- last resort: before the closing '>'

  local add = {}
  for _, m in ipairs(markers or {}) do add[#add + 1] = vo.FormatTKMLine(m) end
  for i = #add, 1, -1 do table.insert(lines, insert_at, add[i]) end
  return table.concat(lines, "\n"), true
end

-- Marker names are `<asset> ~<id>`: the visible half says which script line,
-- the id is what the project file keys marks on, so a drag can never detach
-- them. The id is strictly ` ~` + base36 at the END of the name -- a tilde
-- anywhere else is just a character in an asset.
function vo.FormatMarkerName(asset, id)
  return tostring(asset or "") .. " ~" .. tostring(id or "")
end

function vo.ParseMarkerName(name)
  name = tostring(name or "")
  local asset, id = name:match("^(.-)%s+~([%w]+)$")
  if asset and id and id:match("^[0-9a-z]+$") and #id <= 4 then
    return asset, id
  end
  return name, nil
end
```

- [ ] **Step 4: Verify pass** — `lua tests/test_vo_markers.lua` then `./run_tests.sh`, all green.
- [ ] **Step 5: Commit** — `git add tests/test_vo_markers.lua VO/lib/ajsfx_vo.lua && git commit -m "VO: pure TKM chunk layer -- ranged take markers as strings"`

---

### Task 2: Pure coverage rule and marker→take assembly

**Files:** Modify `VO/lib/ajsfx_vo.lua`, test in `tests/test_vo_markers.lua`.

**Interfaces produced:**
- `vo.CountingMarkers(per_item) -> array of { id, asset, start, stop, item_index }` where `per_item` is an array of `{ coverage = {from,to}, markers = <ParseTKMChunk result> }`. Applies the coverage rule, dedupes by id (best-covering item wins), and drops id-less markers (not ours).
- `vo.BuildOverview` gains `input.takes_by_asset`: `{ [asset] = array of { id, start, stop, item_index } }`. A line whose asset appears there builds its take rows from these (key `tkm|<id>`, status `"recorded"`, ordered by start) and **ignores its match group**; planned takes still append after.

- [ ] **Step 1: Write the failing tests** (append to `tests/test_vo_markers.lua`):

```lua
print("CountingMarkers:")

local function pi(from, to, markers)
  return { coverage = { from = from, to = to }, markers = markers }
end
local function mk(pos, asset, id, len)
  return { pos = pos, name = vo.FormatMarkerName(asset, id), color = 0, length = len }
end

test("a marker counts where its range intersects the item window", function()
  local out = vo.CountingMarkers({ pi(0, 10, { mk(2, "A", "k1", 3) }) })
  assert(#out == 1, "count: " .. #out)
  assert(out[1].id == "k1" and out[1].start == 2 and out[1].stop == 5)
end)

test("split residue is ignored: off-window copies do not count", function()
  local out = vo.CountingMarkers({
    pi(0, 6,  { mk(2, "A", "k1", 3) }),   -- covers the span: counts
    pi(6, 10, { mk(2, "A", "k1", 3) }),   -- residue: range 2-5 misses 6-10
  })
  assert(#out == 1, "residue counted: " .. #out)
  assert(out[1].item_index == 1)
end)

test("two items covering one marker: the better-covering one wins", function()
  local out = vo.CountingMarkers({
    pi(0, 4,  { mk(2, "A", "k1", 4) }),   -- covers 2-4 of 2-6
    pi(0, 10, { mk(2, "A", "k1", 4) }),   -- covers all of it
  })
  assert(#out == 1 and out[1].item_index == 2, "wrong winner")
end)

test("markers without our id suffix are not ours and are ignored", function()
  local out = vo.CountingMarkers({ pi(0, 10, {
    { pos = 1, name = "user note", color = 0, length = 0 } } ) })
  assert(#out == 0, "claimed a foreign marker")
end)

print("BuildOverview with markers:")

local MK_LINES = {
  { asset = "grum_01", text = "Hello.", speaker = "Grumbar", index = 1 },
}

test("a line with markers builds its takes from them, not the match", function()
  local rows = vo.BuildOverview({
    lines = MK_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 90.0, stop = 92.0, line_idx = 1 },
    } } },
    entries = {},
    takes_by_asset = { grum_01 = {
      { id = "k1", start = 10.0, stop = 12.5, item_index = 3 },
      { id = "k2", start = 20.0, stop = 22.0, item_index = 7 },
    } },
  })
  local takes = {}
  for _, row in ipairs(rows) do
    if row.take_index and row.asset == "grum_01" then takes[#takes + 1] = row end
  end
  assert(#takes == 2, "takes: " .. #takes)
  assert(takes[1].key == "tkm|k1", "key: " .. tostring(takes[1].key))
  assert(takes[1].source_start == 10.0, "marker start lost")
  assert(takes[2].take_index == 2, "ordering broken")
  for _, row in ipairs(rows) do
    assert(row.source_start ~= 90.0, "a match row leaked through")
  end
end)

test("marker takes attach their stored marks by tkm key", function()
  local rows = vo.BuildOverview({
    lines = MK_LINES, matches = {},
    entries = { { key = "tkm|k1", asset = "grum_01", notes = "the good one" } },
    takes_by_asset = { grum_01 = { { id = "k1", start = 10.0, stop = 12.5 } } },
  })
  local found
  for _, row in ipairs(rows) do
    if row.key == "tkm|k1" then found = row end
  end
  assert(found, "marker row missing")
  assert(found.notes == "the good one", "marks did not attach")
end)

test("a line with no markers still builds from the match", function()
  local rows = vo.BuildOverview({
    lines = MK_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 90.0, stop = 92.0, line_idx = 1 },
    } } },
    entries = {}, takes_by_asset = {},
  })
  local found
  for _, row in ipairs(rows) do
    if row.source_start == 90.0 then found = row end
  end
  assert(found, "match fallback lost")
end)
```

- [ ] **Step 2: Verify failure**, then **Step 3: Implement.** `CountingMarkers` in the markers section:

```lua
-- The COVERAGE RULE: a marker counts only where its range intersects the
-- source window of the item holding it. Split copies land everywhere, but
-- after a cut only the piece covering the span keeps an intersecting window
-- -- so this one rule absorbs split residue without bookkeeping. When two
-- items genuinely cover one marker (overlaps, comps), the one covering more
-- of the range wins; ids make "same take seen twice" unambiguous.
-- Markers without our ` ~id` suffix belong to the user, not the tool.
function vo.CountingMarkers(per_item)
  local best = {}
  for idx, rec in ipairs(per_item or {}) do
    local cov = rec.coverage
    if cov then
      for _, m in ipairs(rec.markers or {}) do
        local asset, id = vo.ParseMarkerName(m.name)
        if id then
          local start, stop = m.pos, m.pos + (m.length or 0)
          local overlap = math.min(stop, cov.to) - math.max(start, cov.from)
          if overlap > 0 then
            local cur = best[id]
            if not cur or overlap > cur.overlap then
              best[id] = { id = id, asset = asset, start = start, stop = stop,
                           item_index = idx, overlap = overlap }
            end
          end
        end
      end
    end
  end
  local out = {}
  for _, rec in pairs(best) do
    rec.overlap = nil
    out[#out + 1] = rec
  end
  table.sort(out, function(a, b)
    if a.start ~= b.start then return a.start < b.start end
    return tostring(a.id) < tostring(b.id)
  end)
  return out
end
```

In `vo.BuildOverview`: read `local takes_by_asset = input.takes_by_asset or {}` at the top. Add a row builder near `planned_row`:

```lua
  -- A take defined by its MARKER: the marker is the truth, so the row carries
  -- the marker's own span and keys its marks by the marker id -- a key no
  -- drag can move, which is the whole point.
  local function marker_row(mk, line, take_index, take_count)
    local t = by_key and by_key["tkm|" .. mk.id] or nil
    return {
      key           = "tkm|" .. mk.id,
      marker_id     = mk.id,
      status        = "recorded",
      asset         = line.asset,
      deliver       = line.deliver or line.asset,
      script        = line.script,
      append_key    = line.append_key,
      append_nth    = line.append_nth,
      line_key      = line.append_key,
      character     = line.speaker,
      line_text     = line.text,
      source_start  = mk.start,
      source_stop   = mk.stop,
      take_index    = take_index,
      take_count    = take_count,
      script_row    = line.index or line.row,
      user_status   = t and t.status or nil,
      name_override = t and t.name_override or nil,
      notes         = t and t.notes or nil,
      is_primary    = false,
      mark_select   = t and t.select,
      mark_keep     = t and t.keep,
      user_select   = (t and t.select) == true,
      user_keep     = (t and t.keep) == true,
    }
  end
```

`by_key` is a new plain lookup built beside `index_tracker`: `local by_key = {}; for _, e in ipairs(entries or {}) do if e.key then by_key[e.key] = e end end`. In the per-line loop, branch FIRST on markers:

```lua
  for line_row, line in ipairs(lines) do
    local mks = takes_by_asset[line.asset]
    if mks and #mks > 0 then
      -- Markers are the truth: the match's opinion of this line is ignored.
      for i, mk in ipairs(mks) do
        rows[#rows + 1] = marker_row(mk, line, i, #mks)
      end
      local p = planned_by_row[line_row]
      if p then
        for i, e in ipairs(p) do
          rows[#rows + 1] = planned_row(e, line, #mks + i, #mks + #p)
        end
      end
    else
      -- (existing g / missing-line branches unchanged, indented under this else)
    end
  end
```

`takes_by_asset` entries are assumed pre-sorted by `CountingMarkers`; sort defensively by `start` at the top of the branch. Choose a Sel primary the same way the match branch does (scan for `user_select`).

- [ ] **Step 4: Verify pass**, whole suite green (`test_vo.lua` exercises BuildOverview heavily — regressions here are real).
- [ ] **Step 5: Commit** — `"VO: coverage rule and marker-built take rows"`

---

### Task 3: Retire GUID anchors

**Files:** `VO/lib/ajsfx_vo.lua`, `VO/ajsfx_VO_Overview.lua`, `tests/test_vo_identity.lua`.

Everything anchor-shaped goes, in one commit, keeping the suite green throughout:

- [ ] **Step 1 (lib):** Remove from `vo.PROJECT_HEADER` the three `Anchor*` columns; remove `anchor`/`anchor_start`/`anchor_stop` writes from `SerializeProjectFile` (and the `e.anchor` clause in `has_work`), reads from `ParseProjectFile`, and the fields from `make_row`, the missing-line branch, `planned_row`, and `ProjectEntriesFromRows`. Remove `vo.ANCHOR_EDIT_TOLERANCE` and `vo.IsEditedAnchor` (the section comment block stays as the home of the marker layer if Task 1 placed it there — retitle to match).
- [ ] **Step 2 (Overview):** Remove the `by_guid` anchor-resolution block in `Rebuild`; the `row.edited` computation; the anchor-writing block and `anchors` plumbing in `DoCut` and `vo.ApplyPlan` (revert its return to `applied, failures`); `AnchorRowToSelection` and both take-row menu items (Task 6 replaces them); the `edited` skip in `CutCandidates` and the *Re-cut anyway* button (Task 5 re-adds both, marker-based); `state.cut_skipped_edited`/`state.force_recut` stay (reused by Task 5).
- [ ] **Step 3 (tests):** In `tests/test_vo_identity.lua` delete the "Project file — anchors", "IsEditedAnchor", and anchor-carrying "Row model" tests (`mark_select` tri-state row tests stay); in `PlanReconcile` tests delete the `missing_anchor`/`doubled` cases (Task 7 rewrites those categories). Keep every tri-state, `MarkFromTrack`, `EffectiveMarks` test untouched.
- [ ] **Step 4:** `DrawRepairPanel`: comment out (do not delete) the `missing_anchor` and `doubled` sections with a `-- Task 7 rewires these to markers` note; `vo.PlanReconcile` drops those two categories for now (return keeps empty arrays so the panel code compiles).
- [ ] **Step 5:** Parse both scripts, `./run_tests.sh` all green, commit — `"VO: retire GUID anchors -- markers own take identity now"`.

---

### Task 4: Read markers in Rebuild

**Files:** `VO/ajsfx_VO_Overview.lua` (`Rebuild`), `VO/lib/ajsfx_vo.lua` (coupled helper).

**Interfaces produced:** `vo.CollectTakeMarkers(items) -> per_item` (coupled: walks `info.item` chunks via `GetItemStateChunk`, pairs each with `vo.SourceCoverageRanges({info})[1]`, groups by `info.path`); rows built from markers resolve `row.item` directly.

- [ ] **Step 1 (lib, coupled layer near `vo.CollectProjectSpans`):**

```lua
-- Read every item's take markers, paired with the item's source coverage --
-- the input shape vo.CountingMarkers wants. Chunk reads are the only way at
-- the ranges (the API cannot see the length); ~456 items x a few KB at the
-- rebuild throttle is fine, and the result is grouped per source path so
-- markers from one recording can never claim a line in another.
-- UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.CollectTakeMarkers(items)
  local by_path = {}
  for _, info in ipairs(items or {}) do
    if info.item and info.path and not info.skip then
      local ok, chunk = r.GetItemStateChunk(info.item, "", false)
      if ok then
        local group = by_path[info.path]
        if not group then group = {}; by_path[info.path] = group end
        group[#group + 1] = {
          coverage = vo.SourceCoverageRanges({ info })[1],
          markers  = vo.ParseTKMChunk(chunk),
          info     = info,
        }
      end
    end
  end
  return by_path
end
```

- [ ] **Step 2 (Rebuild):** after `state.items = vo.CollectProjectSpans()`, compute:

```lua
  -- Markers are the truth: whatever they say a line's takes are, the sheet
  -- shows. Collected before BuildOverview so marker rows are first-class.
  state.take_markers = vo.CollectTakeMarkers(state.items)
  local takes_by_asset, marker_info = {}, {}
  for _, group in pairs(state.take_markers) do
    for _, mk in ipairs(vo.CountingMarkers(group)) do
      takes_by_asset[mk.asset] = takes_by_asset[mk.asset] or {}
      table.insert(takes_by_asset[mk.asset], mk)
      marker_info[mk.id] = group[mk.item_index] and group[mk.item_index].info
    end
  end
```

Pass `takes_by_asset = takes_by_asset` into the `vo.BuildOverview` call. After BuildOverview returns, resolve marker rows straight to their items (before the name-adoption block):

```lua
  for _, row in ipairs(state.overview) do
    if row.marker_id then
      local info = marker_info[row.marker_id]
      if info then
        row.item, row.item_info, row.source_path = info.item, info, info.path
      end
    end
  end
```

- [ ] **Step 3:** Parse, full suite, commit — `"VO: the sheet reads take markers -- markers drive rows where they exist"`.

---

### Task 5: Kickstart — generation, Cut at marker bounds, marker-overlap skip

**Files:** `VO/ajsfx_VO_Overview.lua` (`DoCut`, `CutCandidates`, Cut panel), `VO/lib/ajsfx_vo.lua` (coupled writer + id mint).

- [ ] **Step 1 (lib):** the writer and the id mint:

```lua
-- Mint a marker id: 2-3 base36 chars, unique against `taken`. Entropy comes
-- from os.clock and a counter, and uniqueness from the check, not the source.
function vo.MintMarkerId(taken)
  local chars = "0123456789abcdefghijklmnopqrstuvwxyz"
  local seed = math.floor((os.clock() * 1e6) % 46656)
  for tries = 0, 46655 do
    local v = (seed + tries * 7 + 13) % 46656
    local id = chars:sub(math.floor(v / 1296) + 1, math.floor(v / 1296) + 1)
             .. chars:sub(math.floor(v / 36) % 36 + 1, math.floor(v / 36) % 36 + 1)
             .. chars:sub(v % 36 + 1, v % 36 + 1)
    if not (taken and taken[id]) then
      if taken then taken[id] = true end
      return id
    end
  end
  return nil
end

-- Write `markers` (source-time {start, stop, asset, id}) into the item's
-- take, replacing the tool's previous lines but PRESERVING the user's own
-- markers (no ` ~id` suffix). UNVERIFIED outside REAPER — see SPEC.md §10.
function vo.WriteTakeMarkers(item, markers)
  local ok, chunk = r.GetItemStateChunk(item, "", false)
  if not ok then return false, "cannot read item chunk" end
  local keep = {}
  for _, m in ipairs(vo.ParseTKMChunk(chunk)) do
    local _, id = vo.ParseMarkerName(m.name)
    if not id then keep[#keep + 1] = m end
  end
  for _, mk in ipairs(markers or {}) do
    keep[#keep + 1] = {
      pos    = mk.start,
      name   = vo.FormatMarkerName(mk.asset, mk.id),
      color  = 0,
      length = (mk.stop or mk.start) - mk.start,
    }
  end
  local patched, did = vo.PatchTKMChunk(chunk, keep)
  if not did then return false, "item has multiple takes" end
  r.SetItemStateChunk(item, patched, false)
  return true
end
```

- [ ] **Step 2 (DoCut):** immediately before the `core.Transaction` that applies the plan, write markers for every span about to be cut. The span still carries the row via `s.row_key` machinery's predecessor — reuse the `by_item` grouping: for each group `g`, mint ids (collect `taken` from `state.take_markers` first), build `{ start = span.start, stop = span.stop, asset = span.asset, id = <minted> }` for each span in `g.spans` whose `dest ~= vo.DEST_IN_PLACE`, and call `vo.WriteTakeMarkers(g.info.item, list)` inside the same transaction, BEFORE `vo.ApplyPlan` splits — split propagation then carries each marker into its piece. Report write failures alongside cut failures.
- [ ] **Step 3 (CutCandidates):** replace the retired edited-skip with the marker rule, same position in the chain:

```lua
        -- Markers own this audio: a span overlapping a counting marker is a
        -- take the user is already tracking, and cutting it would overwrite
        -- their work. Re-cut anyway deletes those markers first, explicitly.
        if overlaps_marker(s) and not state.force_recut then
          counts.edited = counts.edited + 1
          edited_names[#edited_names + 1] = s.deliver or s.asset or "(unnamed)"
```

with `overlaps_marker` built once above the loop from `state.take_markers`: flatten `vo.CountingMarkers` per source group into per-path sorted arrays; a span overlaps when any counting marker on `s.source_path` has `start < s.stop and stop > s.start`.
- [ ] **Step 4 (panel):** *Re-cut anyway*'s action becomes: for each skipped span's overlapping markers, rewrite the owning item's chunk without them (`vo.WriteTakeMarkers` with the survivor list), set `state.force_recut = true`, re-run `DoCut`. Summary line wording: `"%d take(s) skipped -- their markers own that audio"`.
- [ ] **Step 5:** Parse, suite, commit — `"VO: kickstart writes markers, cuts at their bounds, and skips marker-owned audio"`.

---

### Task 6: Migration and the tracking verbs

**Files:** `VO/ajsfx_VO_Overview.lua`, take-row menu + toolbar.

- [ ] **Step 1: `MarkTakesFromSession()`** — the migration. For every take row currently resolving to an item and not yet marker-keyed: mint an id, write a marker onto `row.item` spanning the item's current source coverage (`vo.SourceCoverageRanges({row.item_info})[1]` — hand-fixed edges become truth); move the row's entry marks onto the `tkm|<id>` key (find entry by `row.key`, rewrite its `key`). For match rows with no item, write the marker onto the recording-track item covering the span (resolve via `vo.ResolveSourceSpanForCut`). One transaction, one report: `"Marked N take(s); M rows had no audio to mark."`. Toolbar home: a button inside the Repair panel plus the Cut panel, label **"Mark takes"**, tooltip stating it banks current state as marker truth.
- [ ] **Step 2: take-row menu verbs** (in `DrawTakeRowMenu`, where the anchor items were):
  - **"Add take marker from selected item"** (enabled when 1 item selected): mint id, `vo.WriteTakeMarkers(sel_item, {existing tool markers on it + new})` spanning its coverage, asset = the row's line; retire the planned-take entry if the row was planned (same retire-and-rekey as `LinkPlannedTake`, which now routes here).
  - **"Snap marker to item"** (enabled when `row.item` and `row.marker_id`): set that marker's start/stop to the item's coverage — the user's trim-the-head fix. Implements the stated rule by construction: the row's own marker is by definition the earliest counting marker in the item.
  - **"Delete take marker"** (enabled when `row.marker_id`): rewrite the owning item's chunk without it.
- [ ] **Step 3: "Clean stray take markers"** — button beside "Mark takes": for every item, drop tool markers whose range does not intersect that item's coverage; report the count. Pure core: the filter is `vo.CountingMarkers`'s complement per item — implement inline with `ParseTKMChunk`/`PatchTKMChunk`.
- [ ] **Step 4:** Parse, suite, commit — `"VO: Mark takes migration, marker verbs on the take row, stray-marker cleanup"`.

---

### Task 7: Repair panel rewired to markers

**Files:** `VO/lib/ajsfx_vo.lua` (`PlanReconcile`), `VO/ajsfx_VO_Overview.lua` (`DrawRepairPanel`), `tests/test_vo_identity.lua`.

- [ ] **Step 1: tests** — replace the deleted category tests: a row with `marker_id` but no `item` lands in `unbacked_markers` ("marker with no audio under it"); marks keyed `tkm|<id>` with no such marker in `rows` land in `orphan_marks` (already covered — extend the fixture with a `tkm|` key); `disagree` unchanged.
- [ ] **Step 2:** `vo.PlanReconcile` gains `unbacked_markers` (rows where `row.marker_id and not row.item_guid and not row.item`), replacing `missing_anchor`; `doubled` is deleted outright — ids are minted unique and the coverage rule already picks one item, so the category has nothing left to catch.
- [ ] **Step 3:** `DrawRepairPanel`: un-comment and rewrite the section — list `unbacked_markers` with **Relink** (routes to "Add take marker from selected item") and **Forget** (delete the entry's marks); delete the doubled section. `orphan_marks` copy: "usually a deleted marker" replaces the rematch-window text. Add the **Mark takes** and **Clean stray take markers** buttons here (Task 6 built them).
- [ ] **Step 4:** Parse, suite, commit — `"VO: repair panel speaks markers"`.

---

### Task 8: Docs, manual tests, changelog

**Files:** `VO/SPEC-overview.md`, `VO/MANUAL_TEST.md`, both script headers.

- [ ] **Step 1:** `SPEC-overview.md` — rewrite the "Take identity" section: the TKM substrate (cite the SoundDesignDocs verification), the model (name/id/range), the coverage rule, kickstart-writes-markers, the verbs, what the project file stores (`tkm|<id>` keys; anchors gone). Keep the track-is-the-decision and tri-state prose.
- [ ] **Step 2:** `MANUAL_TEST.md` — replace the "Take identity and repair" checklist: (1) markers visible after Cut with correct names/ranges on each piece; (2) drag a marker → sheet row follows on next rebuild, marks intact; (3) alt-drag an end → span updates; (4) split an item by hand → residue ignored, Clean removes it; (5) Cut re-run skips marker-owned audio, Re-cut anyway deletes and re-cuts; (6) Mark takes on the Grumbar session banks 24 hand-fixed edges — spot-check the worst three (`DoNotTellMaster`, `NowYesIsNot`, `WordsTooBig`); (7) delete a marker → row gone, marks surface in repair; (8) Add take marker from selected item links a planned take.
- [ ] **Step 3:** lib `@version 0.7` changelog rewritten to name markers instead of anchors; Overview stays `@version 0.15beta3` with the changelog's identity paragraph rewritten: ranged take markers, visible and draggable, are the take identity now; Cut skips marker-owned audio; "Mark takes" banks an existing session's edits. Remove the anchor sentences entirely — no published version ever had them.
- [ ] **Step 4:** Full suite + both parses + placeholder scan of changed docs. Commit — `"VO: document take markers, rewrite the beta3 changelog"`.

---

## Self-review notes (already applied)

- `PatchTKMChunk` insertion point: before `<SOURCE`, because every audio take has one; falls back to before the trailing `>` so a sourceless chunk cannot lose lines.
- `marker_row` reads entries via a plain `by_key` map, NOT `index_tracker` — tkm keys have no source bucket and must not enter `by_asset` (same shadowing hazard the planned-take work hit).
- `WriteTakeMarkers` preserves user markers (no ` ~id`) on every rewrite — the tool never deletes what it didn't write, except in the explicitly-named Clean action, which still only touches tool markers.
- Task 5 writes markers inside the same transaction as the splits so one undo reverts both.
