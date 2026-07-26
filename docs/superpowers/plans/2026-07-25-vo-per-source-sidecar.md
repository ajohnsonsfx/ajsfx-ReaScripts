# VO ScriptMatch Per-Source Sidecar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the VO ScriptMatch run report from one write-only file per project to one loadable file per media source file, and make the dialog follow the item selection instead of freezing it at launch.

**Architecture:** Five pure functions are added to `VO/lib/ajsfx_vo.lua` (path derivation, project↔source time conversion, serialize, parse, partition-by-source) and unit-tested in isolation. The dialog `VO/ajsfx_VO_ScriptMatch.lua` is then rewired on top of them in four independent passes: write on transcribe, live selection, load with verification, and popup removal. The in-memory model stays a single plan throughout — sidecars are partitioned only at write time and unioned at read time.

**Tech Stack:** Lua 5.4, REAPER ReaScript API, ReaImGui 0.9.3. Tests are plain Lua with a hand-rolled `test(name, fn)` harness in `tests/test_vo.lua`; no framework.

## Global Constraints

- The spec is `docs/superpowers/specs/2026-07-25-vo-scriptmatch-per-source-sidecar-design.md`. Read it before starting. Requirement IDs (R1–R9) below refer to it.
- Sidecar filename is exactly `<base>_vo_report.csv` beside the audio file, stripping only the final extension.
- Sidecar format marker is the literal string `ajsfx VO ScriptMatch`, version `1`.
- Sidecar span times are **source-file time**, never project time.
- Popups may ask, never tell. A modal is allowed only when its answer changes what happens next. Retained: preset overwrite confirm, preset delete confirm, `Save As…` name prompt, and the missing-ReaImGui message at script top. Everything else becomes inline dialog text.
- Tests run with `./run_tests.sh` **via the Bash tool** — `bash` is not on PATH from PowerShell. Syntax-check with `luac -p <file>` via PowerShell.
- Baseline is 232 passing tests at commit `ef29152`. Every task must leave the suite green.
- Role order everywhere is `{ "asset", "text", "speaker" }`, matching `vo.SerializeLayout`.
- `@version` bumps in a script header require an `@changelog` line in the same header (AGENTS.md). The branch is `feature/vo-scriptmatch-ui-regroup`, already at `@version 0.8` unreleased — amend that changelog rather than bumping again.
- Do not merge to `main`. Merging rebuilds `index.xml` and cuts a ReaPack release, and is gated on manual REAPER verification by the user.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `VO/lib/ajsfx_vo.lua` | Pure logic + REAPER-coupled helpers. Already ~2200 lines and organised in labelled sections. | Add 5 pure functions to the pure layer; delete `vo.BuildReport`. |
| `VO/ajsfx_VO_ScriptMatch.lua` | The run dialog. | Rewire persistence, selection, gating, and messaging. |
| `tests/test_vo.lua` | Unit tests for the library. | Add 4 sections; rewrite the `BuildReport` section. |

No new files. The library is large but sectioned and consistently organised; splitting it is out of scope for this work and would obscure the diff.

---

### Task 1: Path derivation and time conversion

Three small pure functions with no dependencies. Grouped into one task because each is a few lines and none is independently reviewable in a meaningful way.

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — add after `vo.CacheKey` (~line 1283, end of the "pure layer" region)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `vo.SidecarPath(source_path) -> string|nil`
  - `vo.ProjectTimeToSource(t, item) -> number`
  - `vo.SourceTimeToProject(t, item) -> number`
  - `item` is the shape returned by `vo.CollectSourceSpans`: `{ pos, length, start_offs, playrate, path, track, item }`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua`, immediately before the final `print(string.format("\n=== Results: ...` line. Note `near` and the `item_at` helper already exist in this file — `item_at(pos, length, start_offs, playrate)` is defined at the `MapWordsToProject` section (~line 1520) and is in scope here.

```lua
--------------------------------
-- SidecarPath
--------------------------------
print("\nSidecarPath:")

test("the final extension is replaced with the sidecar suffix", function()
  assert(vo.SidecarPath("D:/audio/RIVA_session.wav") == "D:/audio/RIVA_session_vo_report.csv",
    "Got: " .. tostring(vo.SidecarPath("D:/audio/RIVA_session.wav")))
end)

test("a path with no extension just gains the suffix", function()
  assert(vo.SidecarPath("D:/audio/RIVA") == "D:/audio/RIVA_vo_report.csv",
    "Got: " .. tostring(vo.SidecarPath("D:/audio/RIVA")))
end)

test("a dot in a directory name is not mistaken for an extension", function()
  assert(vo.SidecarPath("D:/my.session/RIVA") == "D:/my.session/RIVA_vo_report.csv",
    "Got: " .. tostring(vo.SidecarPath("D:/my.session/RIVA")))
end)

test("a backslash path is handled", function()
  assert(vo.SidecarPath("D:\\audio\\RIVA.wav") == "D:\\audio\\RIVA_vo_report.csv",
    "Got: " .. tostring(vo.SidecarPath("D:\\audio\\RIVA.wav")))
end)

test("nil and empty input return nil", function()
  assert(vo.SidecarPath(nil) == nil, "nil should return nil")
  assert(vo.SidecarPath("") == nil, "empty should return nil")
end)

--------------------------------
-- Project/source time conversion
--------------------------------
print("\nProject/source time conversion:")

test("project time converts to source time through position and offset", function()
  -- item at 10s, source starts at 5s: project 12s is source 7s
  assert(near(vo.ProjectTimeToSource(12.0, item_at(10, 4, 5.0)), 7.0),
    "Got: " .. vo.ProjectTimeToSource(12.0, item_at(10, 4, 5.0)))
end)

test("source time converts back to project time", function()
  assert(near(vo.SourceTimeToProject(7.0, item_at(10, 4, 5.0)), 12.0),
    "Got: " .. vo.SourceTimeToProject(7.0, item_at(10, 4, 5.0)))
end)

test("the conversions round-trip at unity playrate", function()
  local it = item_at(10, 4, 5.0)
  local back = vo.SourceTimeToProject(vo.ProjectTimeToSource(12.345, it), it)
  assert(near(back, 12.345), "Got: " .. back)
end)

test("the conversions round-trip at a non-unity playrate", function()
  local it = item_at(10, 4, 5.0, 2.0)
  local back = vo.SourceTimeToProject(vo.ProjectTimeToSource(12.345, it), it)
  assert(near(back, 12.345), "Got: " .. back)
end)

test("playrate scales the source interval, matching MapWordsToProject", function()
  -- MapWordsToProject maps source t to pos + (t - start_offs) / playrate.
  -- At playrate 2.0 with start_offs 0, source 4.0s lands at project 10 + 2 = 12.
  assert(near(vo.SourceTimeToProject(4.0, item_at(10, 4, 0, 2.0)), 12.0),
    "Got: " .. vo.SourceTimeToProject(4.0, item_at(10, 4, 0, 2.0)))
  assert(near(vo.ProjectTimeToSource(12.0, item_at(10, 4, 0, 2.0)), 4.0),
    "Got: " .. vo.ProjectTimeToSource(12.0, item_at(10, 4, 0, 2.0)))
end)

test("a playrate of zero or less is treated as 1.0", function()
  assert(near(vo.ProjectTimeToSource(12.0, item_at(10, 4, 0, 0)), 2.0),
    "Got: " .. vo.ProjectTimeToSource(12.0, item_at(10, 4, 0, 0)))
  assert(near(vo.SourceTimeToProject(2.0, item_at(10, 4, 0, -1)), 12.0),
    "Got: " .. vo.SourceTimeToProject(2.0, item_at(10, 4, 0, -1)))
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (Bash tool): `./run_tests.sh 2>&1 | tail -20`
Expected: FAIL lines reading `attempt to call a nil value (field 'SidecarPath')` and the same for the two conversion functions.

- [ ] **Step 3: Implement**

Add to `VO/lib/ajsfx_vo.lua` after `vo.CacheKey`:

```lua
--------------------------------
-- Pure layer: sidecar paths and time base
--------------------------------

-- The sidecar for a media source lives beside it: RIVA.wav -> RIVA_vo_report.csv.
-- Only the final extension is stripped, and the character class excludes path
-- separators so a dot in a directory name cannot be mistaken for one.
function vo.SidecarPath(source_path)
  if not source_path or source_path == "" then return nil end
  local base = tostring(source_path):gsub("%.[^%.\\/]*$", "")
  return base .. "_vo_report.csv"
end

-- Exact inverses of the arithmetic in vo.MapWordsToProject. A sidecar lives next
-- to the audio, so it must store times the audio file itself can vouch for; the
-- item's position, trim and playrate belong to the project, not the recording.
local function safe_playrate(item)
  local pr = item and item.playrate or 1.0
  if pr <= 0 then pr = 1.0 end
  return pr
end

function vo.ProjectTimeToSource(t, item)
  return (t - ((item and item.pos) or 0)) * safe_playrate(item)
       + ((item and item.start_offs) or 0)
end

function vo.SourceTimeToProject(t, item)
  return ((item and item.pos) or 0)
       + (t - ((item and item.start_offs) or 0)) / safe_playrate(item)
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (Bash tool): `./run_tests.sh 2>&1 | tail -5`
Expected: `=== Results: 243 passed, 0 failed ===` (232 baseline + 11 new).

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat(VO): sidecar path and project/source time conversion"
```

---

### Task 2: Sidecar serialize and parse

Replaces `vo.BuildReport` with a round-trippable format. This is the largest library task and the one a reviewer would most want to gate on its own.

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — replace `vo.REPORT_HEADER` and `vo.BuildReport` (~lines 1209–1255)
- Test: `tests/test_vo.lua` — rewrite the `BuildReport:` section (~lines 1277–1342)

**Interfaces:**
- Consumes: `vo.FormatCSVRow(fields) -> string` and `vo.ParseCSV(text) -> rows` (both existing).
- Produces:
  - `vo.SIDECAR_MARKER` = `"ajsfx VO ScriptMatch"`, `vo.SIDECAR_VERSION` = `1`
  - `vo.SerializeSidecar(spans, lines, meta) -> string`, where `meta` is `{ source, source_bytes, script_csv, mapping }` and `mapping` is a role→column table. `spans` are already in source time.
  - `vo.ParseSidecar(text) -> table|nil, string` returning `{ version, source, source_bytes, script_csv, mapping, spans }` or `nil, reason`.
  - Parsed spans carry `start`, `stop` (source time, numbers), `kind`, `asset`, `character`, `score`, `margin`, `take_index`, `dest`, `name`, `transcript`.

- [ ] **Step 1: Write the failing tests**

Delete the entire `BuildReport:` section in `tests/test_vo.lua` (from `print("\nBuildReport:")` through the test ending with the `SCRIPT LINES WITH NO MATCH` match, ~lines 1277–1342) and replace it with:

```lua
--------------------------------
-- Sidecar serialize / parse
--------------------------------
print("\nSidecar serialize/parse:")

local SIDECAR_META = {
  source       = "RIVA_session.wav",
  source_bytes = 412839104,
  script_csv   = "D:/proj/script.csv",
  mapping      = { asset = "Filename", text = "Line Text", speaker = "Character" },
}

local function sample_spans()
  return {
    { start = 12.48, stop = 15.22, kind = "match", asset = "vo_riva_intro_01",
      character = "RIVA", score = 0.9821, margin = 0.441, take_index = 1,
      dest = "Selects", name = "vo_riva_intro_01", transcript = "we should not have come" },
    { start = 20.00, stop = 22.50, kind = "review", asset = "vo_riva_intro_02",
      character = "RIVA", score = 0.6, margin = 0.05, take_index = 2,
      dest = "Review", name = "vo_riva_intro_02_tk02", transcript = "quiet, something is wrong" },
  }
end

test("the sidecar starts with the format marker and version", function()
  local text = vo.SerializeSidecar({}, {}, SIDECAR_META)
  local rows = vo.ParseCSV(text)
  assert(rows[1][1] == vo.SIDECAR_MARKER, "Marker: " .. tostring(rows[1][1]))
  assert(tonumber(rows[1][2]) == vo.SIDECAR_VERSION, "Version: " .. tostring(rows[1][2]))
end)

test("the preamble carries source, size, script path and mapping", function()
  local parsed = vo.ParseSidecar(vo.SerializeSidecar({}, {}, SIDECAR_META))
  assert(parsed, "Parse returned nil")
  assert(parsed.source == "RIVA_session.wav", "source: " .. tostring(parsed.source))
  assert(parsed.source_bytes == 412839104, "bytes: " .. tostring(parsed.source_bytes))
  assert(parsed.script_csv == "D:/proj/script.csv", "csv: " .. tostring(parsed.script_csv))
  assert(parsed.mapping.asset == "Filename", "asset: " .. tostring(parsed.mapping.asset))
  assert(parsed.mapping.speaker == "Character", "speaker: " .. tostring(parsed.mapping.speaker))
  assert(parsed.mapping.text == "Line Text", "text: " .. tostring(parsed.mapping.text))
end)

test("every span field round-trips", function()
  local parsed = vo.ParseSidecar(vo.SerializeSidecar(sample_spans(), {}, SIDECAR_META))
  assert(#parsed.spans == 2, "Expected 2 spans, got " .. #parsed.spans)
  local s = parsed.spans[1]
  assert(near(s.start, 12.48), "start: " .. tostring(s.start))
  assert(near(s.stop, 15.22), "stop: " .. tostring(s.stop))
  assert(s.kind == "match", "kind: " .. tostring(s.kind))
  assert(s.asset == "vo_riva_intro_01", "asset: " .. tostring(s.asset))
  assert(s.character == "RIVA", "character: " .. tostring(s.character))
  assert(near(s.score, 0.9821), "score: " .. tostring(s.score))
  assert(near(s.margin, 0.441), "margin: " .. tostring(s.margin))
  assert(s.take_index == 1, "take_index: " .. tostring(s.take_index))
  assert(s.dest == "Selects", "dest: " .. tostring(s.dest))
  assert(s.name == "vo_riva_intro_01", "name: " .. tostring(s.name))
  assert(s.transcript == "we should not have come", "transcript: " .. tostring(s.transcript))
end)

test("fields containing commas, quotes and newlines survive the round-trip", function()
  local spans = { { start = 0, stop = 1, kind = "match", asset = "a",
                    transcript = 'he said "go, now"\nand left' } }
  local parsed = vo.ParseSidecar(vo.SerializeSidecar(spans, {}, SIDECAR_META))
  assert(parsed.spans[1].transcript == 'he said "go, now"\nand left',
    "Got: " .. tostring(parsed.spans[1].transcript))
end)

test("the trailing no-match section lists unmatched script lines", function()
  local lines = {
    { asset = "vo_riva_intro_01", speaker = "RIVA", text = "We should not have come." },
    { asset = "vo_riva_deck_03",  speaker = "RIVA", text = "Seal it." },
  }
  local text = vo.SerializeSidecar(sample_spans(), lines, SIDECAR_META)
  local tail = text:match("SCRIPT LINES WITH NO MATCH(.*)$")
  assert(tail, "No trailing section")
  assert(tail:find("vo_riva_deck_03", 1, true), "Unmatched line missing from tail")
  assert(not tail:find("vo_riva_intro_01", 1, true), "Matched line should not be in tail")
end)

test("the trailing no-match section is ignored on load", function()
  local lines = { { asset = "vo_riva_deck_03", speaker = "RIVA", text = "Seal it." } }
  local parsed = vo.ParseSidecar(vo.SerializeSidecar(sample_spans(), lines, SIDECAR_META))
  assert(#parsed.spans == 2, "Tail section leaked into spans: got " .. #parsed.spans)
end)

test("a review span still counts as unmatched in the tail", function()
  local lines = { { asset = "vo_riva_intro_02", speaker = "RIVA", text = "Quiet." } }
  local tail = vo.SerializeSidecar(sample_spans(), lines, SIDECAR_META)
                 :match("SCRIPT LINES WITH NO MATCH(.*)$")
  assert(tail:find("vo_riva_intro_02", 1, true), "Review-only line should be listed as unmatched")
end)

print("\nSidecar parse rejection:")

test("empty text is rejected with a reason", function()
  local parsed, reason = vo.ParseSidecar("")
  assert(parsed == nil, "Empty text should not parse")
  assert(type(reason) == "string" and reason ~= "", "Expected a reason string")
end)

test("nil text is rejected without erroring", function()
  local parsed, reason = vo.ParseSidecar(nil)
  assert(parsed == nil, "nil should not parse")
  assert(type(reason) == "string", "Expected a reason string")
end)

test("a file that is not a sidecar is rejected", function()
  local parsed, reason = vo.ParseSidecar("name,age\nalice,30\n")
  assert(parsed == nil, "Arbitrary CSV should not parse as a sidecar")
  assert(reason:find("ajsfx VO ScriptMatch", 1, true), "Reason should name the marker: " .. reason)
end)

test("an unrecognised version is rejected", function()
  local text = vo.SerializeSidecar({}, {}, SIDECAR_META):gsub("^(.-),1\n", "%1,99\n", 1)
  local parsed, reason = vo.ParseSidecar(text)
  assert(parsed == nil, "Version 99 should not parse")
  assert(reason:find("99", 1, true), "Reason should name the version: " .. reason)
end)

test("a sidecar with no span header row is rejected", function()
  local text = vo.SIDECAR_MARKER .. ",1\nSource,RIVA.wav\n"
  local parsed, reason = vo.ParseSidecar(text)
  assert(parsed == nil, "Missing span header should not parse")
  assert(type(reason) == "string" and reason ~= "", "Expected a reason string")
end)

test("a sidecar with a header but no span rows parses to zero spans", function()
  local parsed = vo.ParseSidecar(vo.SerializeSidecar({}, {}, SIDECAR_META))
  assert(parsed, "Should parse")
  assert(#parsed.spans == 0, "Expected 0 spans, got " .. #parsed.spans)
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (Bash tool): `./run_tests.sh 2>&1 | tail -20`
Expected: FAIL lines reading `attempt to call a nil value (field 'SerializeSidecar')`.

- [ ] **Step 3: Implement**

In `VO/lib/ajsfx_vo.lua`, delete `vo.REPORT_HEADER` and the whole of `vo.BuildReport` (~lines 1209–1255) and put this in their place:

```lua
vo.SIDECAR_MARKER  = "ajsfx VO ScriptMatch"
vo.SIDECAR_VERSION = 1

vo.SIDECAR_HEADER = {
  "Source start", "Source stop", "Kind", "Filename", "Character", "Score",
  "Margin", "Take", "Dest", "Name", "Transcript", "Line text", "Clamped",
}

vo.SIDECAR_TAIL_MARKER = "SCRIPT LINES WITH NO MATCH"

-- role=column pairs joined by ";". Kept human-legible because the sidecar is
-- opened in spreadsheets; the role order matches vo.SerializeLayout.
local function encode_mapping(mapping)
  local out = {}
  for _, role in ipairs({ "asset", "text", "speaker" }) do
    local col = mapping and mapping[role]
    if col and col ~= "" then out[#out + 1] = role .. "=" .. col end
  end
  return table.concat(out, ";")
end

local function decode_mapping(text)
  local mapping = {}
  for pair in tostring(text or ""):gmatch("[^;]+") do
    local role, col = pair:match("^%s*([^=]+)=(.*)$")
    if role then mapping[role:match("^%s*(.-)%s*$")] = col end
  end
  return mapping
end

-- Serialize a plan to its sidecar. `spans` must already be in SOURCE time (see
-- vo.PartitionPlanBySource); this function does no conversion, so it cannot
-- silently write project times. `lines` supplies script text for the readable
-- columns and the trailing unmatched section, and may be empty.
function vo.SerializeSidecar(spans, lines, meta)
  meta = meta or {}
  local by_asset = {}
  for _, l in ipairs(lines or {}) do by_asset[l.asset] = l end

  local out = {
    vo.FormatCSVRow({ vo.SIDECAR_MARKER, tostring(vo.SIDECAR_VERSION) }),
    vo.FormatCSVRow({ "Source",      meta.source or "" }),
    vo.FormatCSVRow({ "Source bytes", tostring(meta.source_bytes or 0) }),
    vo.FormatCSVRow({ "Script CSV",  meta.script_csv or "" }),
    vo.FormatCSVRow({ "Mapping",     encode_mapping(meta.mapping) }),
    "",
    vo.FormatCSVRow(vo.SIDECAR_HEADER),
  }

  local matched = {}
  for _, s in ipairs(spans or {}) do
    if s.kind == "match" and s.asset then matched[s.asset] = true end
    local line = s.asset and by_asset[s.asset] or nil
    out[#out + 1] = vo.FormatCSVRow({
      string.format("%.3f", s.start or 0),
      string.format("%.3f", s.stop or 0),
      s.kind or "",
      s.asset or "",
      s.character or "",
      s.score  and string.format("%.4f", s.score)  or "",
      s.margin and string.format("%.4f", s.margin) or "",
      s.take_index and tostring(s.take_index) or "",
      s.dest or "",
      s.name or "",
      s.transcript or "",
      line and line.text or "",
      s.clamped and "yes" or "",
    })
  end

  -- Readable only. ParseSidecar stops at this marker, so it can never become a
  -- second source of truth that disagrees with the spans above it.
  out[#out + 1] = ""
  out[#out + 1] = vo.FormatCSVRow({ vo.SIDECAR_TAIL_MARKER })
  out[#out + 1] = vo.FormatCSVRow({ "Filename", "Character", "Text" })
  for _, l in ipairs(lines or {}) do
    if not matched[l.asset] then
      out[#out + 1] = vo.FormatCSVRow({ l.asset, l.speaker or "", l.text })
    end
  end

  return table.concat(out, "\n") .. "\n"
end

-- Returns the parsed sidecar, or nil plus a reason. A malformed file beside the
-- audio must never stop the dialog opening, so nothing here raises.
function vo.ParseSidecar(text)
  if type(text) ~= "string" or text == "" then
    return nil, "The sidecar file is empty."
  end

  local rows = vo.ParseCSV(text)
  if not rows[1] or rows[1][1] ~= vo.SIDECAR_MARKER then
    return nil, "Not an " .. vo.SIDECAR_MARKER .. " file."
  end

  local version = tonumber(rows[1][2] or "")
  if version ~= vo.SIDECAR_VERSION then
    return nil, "Unsupported sidecar version: " .. tostring(rows[1][2])
  end

  local parsed = { version = version, source = "", source_bytes = 0,
                   script_csv = "", mapping = {}, spans = {} }

  -- Walk the preamble until the span header row, then read spans until the
  -- readable tail marker.
  local i, header_at = 2, nil
  while rows[i] do
    local key = rows[i][1] or ""
    if key == vo.SIDECAR_HEADER[1] then header_at = i; break end
    if     key == "Source"       then parsed.source       = rows[i][2] or ""
    elseif key == "Source bytes" then parsed.source_bytes = tonumber(rows[i][2] or "") or 0
    elseif key == "Script CSV"   then parsed.script_csv   = rows[i][2] or ""
    elseif key == "Mapping"      then parsed.mapping      = decode_mapping(rows[i][2])
    end
    i = i + 1
  end

  if not header_at then
    return nil, "The sidecar has no span header row."
  end

  for j = header_at + 1, #rows do
    local row = rows[j]
    local first = row[1] or ""
    if first == vo.SIDECAR_TAIL_MARKER then break end
    if first ~= "" and tonumber(first) then
      parsed.spans[#parsed.spans + 1] = {
        start      = tonumber(row[1]) or 0,
        stop       = tonumber(row[2]) or 0,
        kind       = row[3] ~= "" and row[3] or nil,
        asset      = row[4] ~= "" and row[4] or nil,
        character  = row[5] ~= "" and row[5] or nil,
        score      = tonumber(row[6] or ""),
        margin     = tonumber(row[7] or ""),
        take_index = tonumber(row[8] or ""),
        dest       = row[9] ~= "" and row[9] or nil,
        name       = row[10] ~= "" and row[10] or nil,
        transcript = row[11] ~= "" and row[11] or nil,
      }
    end
  end

  return parsed
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (Bash tool): `./run_tests.sh 2>&1 | tail -5`
Expected: `=== Results: 250 passed, 0 failed ===` (243 from Task 1, minus the 6 deleted `BuildReport` tests, plus 13 new).

If any test outside these sections fails, `vo.BuildReport` still has a caller. Only `VO/ajsfx_VO_ScriptMatch.lua:593` should reference it, and that is fixed in Task 4 — a *dialog* reference does not break the test suite, so a failure here means a real regression in the library.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat(VO): replace BuildReport with round-trippable sidecar serialize/parse"
```

---

### Task 3: Partition a plan by source file

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — add after `vo.ParseSidecar`
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.ProjectTimeToSource(t, item)` from Task 1.
- Produces: `vo.PartitionPlanBySource(plan, items) -> { [source_path] = { spans… } }`. Returned spans are **copies** with `start`/`stop` in source time; the input plan is not mutated.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo.lua`, before the final results line:

```lua
--------------------------------
-- PartitionPlanBySource
--------------------------------
print("\nPartitionPlanBySource:")

-- Two items on the timeline, drawn from two different source files.
local function two_source_items()
  return {
    { path = "A.wav", pos = 0,  length = 10, start_offs = 0, playrate = 1.0 },
    { path = "B.wav", pos = 20, length = 10, start_offs = 0, playrate = 1.0 },
  }
end

test("spans are grouped by the source of the item containing them", function()
  local plan = {
    { start = 1, stop = 2,  kind = "match", asset = "a" },
    { start = 21, stop = 22, kind = "match", asset = "b" },
  }
  local by_source = vo.PartitionPlanBySource(plan, two_source_items())
  assert(#by_source["A.wav"] == 1, "A.wav: " .. #(by_source["A.wav"] or {}))
  assert(#by_source["B.wav"] == 1, "B.wav: " .. #(by_source["B.wav"] or {}))
  assert(by_source["A.wav"][1].asset == "a", "Wrong span in A.wav")
  assert(by_source["B.wav"][1].asset == "b", "Wrong span in B.wav")
end)

test("partitioned spans are converted to source time", function()
  local plan = { { start = 21, stop = 22, kind = "match", asset = "b" } }
  local by_source = vo.PartitionPlanBySource(plan, two_source_items())
  -- Item B sits at project 20s with no offset, so project 21s is source 1s.
  assert(near(by_source["B.wav"][1].start, 1.0), "start: " .. by_source["B.wav"][1].start)
  assert(near(by_source["B.wav"][1].stop, 2.0), "stop: " .. by_source["B.wav"][1].stop)
end)

test("the input plan is not mutated", function()
  local plan = { { start = 21, stop = 22, kind = "match", asset = "b" } }
  vo.PartitionPlanBySource(plan, two_source_items())
  assert(near(plan[1].start, 21), "Input span was mutated: " .. plan[1].start)
end)

test("a span inside no item is omitted", function()
  local plan = { { start = 15, stop = 16, kind = "match", asset = "gap" } }
  local by_source = vo.PartitionPlanBySource(plan, two_source_items())
  assert(by_source["A.wav"] == nil, "A.wav should have no entry")
  assert(by_source["B.wav"] == nil, "B.wav should have no entry")
end)

test("two items sharing one source produce one group", function()
  local items = {
    { path = "A.wav", pos = 0,  length = 10, start_offs = 0,  playrate = 1.0 },
    { path = "A.wav", pos = 20, length = 10, start_offs = 30, playrate = 1.0 },
  }
  local plan = {
    { start = 1,  stop = 2,  kind = "match", asset = "a" },
    { start = 21, stop = 22, kind = "match", asset = "b" },
  }
  local by_source = vo.PartitionPlanBySource(plan, items)
  assert(#by_source["A.wav"] == 2, "Expected 2 spans in A.wav, got " .. #by_source["A.wav"])
  -- The second item plays the source from 30s, so project 21s is source 31s.
  assert(near(by_source["A.wav"][2].start, 31.0), "start: " .. by_source["A.wav"][2].start)
end)

test("assignment uses the span midpoint, matching ClampSpansToItems", function()
  -- A span starting before item A but centred inside it belongs to A.
  local plan = { { start = -1, stop = 3, kind = "match", asset = "a" } }
  local by_source = vo.PartitionPlanBySource(plan, two_source_items())
  assert(by_source["A.wav"] and #by_source["A.wav"] == 1, "Midpoint 1.0s should land in A.wav")
end)

test("items with no path are skipped", function()
  local items = { { pos = 0, length = 10, start_offs = 0, playrate = 1.0 } }
  local by_source = vo.PartitionPlanBySource({ { start = 1, stop = 2 } }, items)
  assert(next(by_source) == nil, "A pathless item should produce no groups")
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (Bash tool): `./run_tests.sh 2>&1 | tail -20`
Expected: FAIL lines reading `attempt to call a nil value (field 'PartitionPlanBySource')`.

- [ ] **Step 3: Implement**

Add to `VO/lib/ajsfx_vo.lua` after `vo.ParseSidecar`:

```lua
-- Split a project-time plan into one source-time span list per source file.
-- The midpoint decides which item a span belongs to, matching how the dialog's
-- ClampSpansToItems already assigns them, so the two cannot disagree.
-- Spans matching no item (gaps between items) are omitted.
function vo.PartitionPlanBySource(plan, items)
  local by_source = {}
  for _, span in ipairs(plan or {}) do
    local midpoint = ((span.raw_start or span.start or 0)
                    + (span.raw_stop  or span.stop  or 0)) / 2
    for _, item in ipairs(items or {}) do
      if item.path and midpoint >= item.pos and midpoint <= item.pos + (item.length or 0) then
        local copy = {}
        for k, v in pairs(span) do copy[k] = v end
        copy.start = vo.ProjectTimeToSource(span.start or 0, item)
        copy.stop  = vo.ProjectTimeToSource(span.stop  or 0, item)
        by_source[item.path] = by_source[item.path] or {}
        table.insert(by_source[item.path], copy)
        break
      end
    end
  end
  return by_source
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run (Bash tool): `./run_tests.sh 2>&1 | tail -5`
Expected: `=== Results: 257 passed, 0 failed ===`.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat(VO): partition a plan into per-source span lists"
```

---

### Task 4: Write sidecars on transcribe

The library is now complete. This is the first dialog task and it removes the last `vo.BuildReport` caller, so the script becomes loadable again.

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua` — delete `ProjectDir` and `ReportPath` (lines 63–75); rewrite the report half of `Finish` (~lines 593–614); add a write call in `Run`'s success callback.

**Interfaces:**
- Consumes: `vo.SidecarPath`, `vo.PartitionPlanBySource`, `vo.SerializeSidecar`, `vo.FileSize` (existing).
- Produces: `WriteSidecars(plan, lines) -> written_count, failures` — a dialog-local function, where `failures` is an array of `{ path, reason }`.

- [ ] **Step 1: Delete the per-project report path**

Remove `ProjectDir()` (lines 63–69) and `ReportPath()` (lines 71–75) from `VO/ajsfx_VO_ScriptMatch.lua`. Both become unreferenced by the end of this task.

- [ ] **Step 2: Add the sidecar writer**

Insert after `WriteFile` (~line 91):

```lua
-- Write one sidecar per source file the plan touches. Called after transcription
-- (so a session that is never cut still persists) and again after a cut, since
-- ApplyPlan can clamp spans and the file should reflect what was applied.
-- Returns how many were written, and a list of {path, reason} for those that
-- were not: a read-only media folder is a warning, never a failed run.
local function WriteSidecars(plan, lines)
  local by_source = vo.PartitionPlanBySource(plan, usable)
  local written, failures = 0, {}
  for source_path, spans in pairs(by_source) do
    local path = vo.SidecarPath(source_path)
    if not path then
      failures[#failures + 1] = { path = source_path, reason = "no sidecar path" }
    else
      local text = vo.SerializeSidecar(spans, lines, {
        source       = source_path:match("([^/\\]+)$") or source_path,
        source_bytes = vo.FileSize(source_path) or 0,
        script_csv   = state.csv_path or "",
        mapping      = state.mapping,
      })
      if WriteFile(path, text) then
        written = written + 1
      else
        failures[#failures + 1] = { path = path, reason = "could not write" }
      end
    end
  end
  return written, failures
end
```

Note: `WriteSidecars` reads the module-level `usable` and `state`. Both are declared before it in file order once `state` is moved up — verify by running the script; if `luac -p` passes but REAPER reports a nil index on `state`, move the `WriteSidecars` definition below the `state` table.

- [ ] **Step 3: Call it after transcription**

In `Run`'s success callback, immediately after `state.line_status = by_asset` and before the `counts` block, add:

```lua
          -- Persist beside each recording now, not at cut time: a session where
          -- the user transcribes, inspects and never cuts still leaves a result.
          local written, sc_failures = WriteSidecars(plan, lines)
          state.sidecar_warning = ""
          if #sc_failures > 0 then
            state.sidecar_warning = string.format(
              "Could not write %d sidecar file(s): %s",
              #sc_failures, sc_failures[1].path)
          end
```

Add `sidecar_warning = ""` to the `state` table alongside `status`.

- [ ] **Step 4: Rewrite the report half of `Finish`**

In `Finish`, replace the `vo.BuildReport` / `ReportPath` / `WriteFile` block and the `Report:` line of the summary with:

```lua
  local written, sc_failures = WriteSidecars(plan, lines)
  if #sc_failures > 0 then
    state.sidecar_warning = string.format(
      "Could not write %d sidecar file(s): %s", #sc_failures, sc_failures[1].path)
  else
    state.sidecar_warning = ""
  end
```

Leave the rest of `Finish`'s summary assembly alone for now — the message box itself is removed in Task 8.

- [ ] **Step 5: Verify**

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```
Expected: no output. Then confirm no stale references remain:

```bash
grep -n "BuildReport\|ReportPath\|ProjectDir" VO/ajsfx_VO_ScriptMatch.lua VO/lib/ajsfx_vo.lua
```
Expected: no matches.

Run (Bash tool): `./run_tests.sh 2>&1 | tail -5` — expected `257 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua && git commit -m "feat(VO): write a sidecar per source file on transcribe and cut"
```

---

### Task 5: Live selection

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua` — the module-level `items`/`skipped`/`usable` block (~lines 144–166) and the top of the frame loop.

**Interfaces:**
- Consumes: `vo.CollectSourceSpans()` (existing).
- Produces: `RefreshSelection() -> boolean` (true when the source set changed); module-level `items`, `skipped`, `usable` become mutable upvalues rather than launch-time constants; `state.source_key` holds the sorted, concatenated source-path key.

- [ ] **Step 1: Make the selection mutable and remove the launch precondition**

Replace the block at ~lines 144–166 (the `local items = vo.CollectSourceSpans()` through the `if #usable == 0 then r.MB(...)` early exit) with:

```lua
-- The selection is read every frame, not frozen at launch: the dialog follows
-- whatever the user clicks. CollectSourceSpans is only re-run when the SET of
-- source files changes, so dragging an item costs nothing.
local items, skipped, usable = {}, {}, {}

local function SourceKey(list)
  local paths = {}
  for _, it in ipairs(list) do
    if it.path then paths[#paths + 1] = it.path end
  end
  table.sort(paths)
  return table.concat(paths, "\31")
end

-- Returns true when the set of selected source files changed this frame.
local function RefreshSelection()
  local fresh = vo.CollectSourceSpans()
  local key   = SourceKey(fresh)

  items = fresh
  skipped, usable = {}, {}
  for _, item in ipairs(items) do
    if item.skip then
      skipped[#skipped + 1] = string.format("item at %.3fs: %s", item.pos, item.skip)
    else
      usable[#usable + 1] = item
    end
  end

  if key == state.source_key then return false end
  state.source_key = key
  return true
end
```

Add `source_key = nil` to the `state` table. Note `RefreshSelection` reads `state`, so it must be defined *after* the `state` table — move it below if `luac -p` or REAPER complains.

The `r.MB("None of the selected items can be transcribed…")` early exit and its `return` are deleted outright. An unusable selection is now a dialog state, not a launch failure.

- [ ] **Step 2: Call it each frame**

At the very top of the `loop` function, before `im.Begin`, add:

```lua
  -- A changed source set invalidates any plan built from the old one.
  if RefreshSelection() then
    state.plan, state.plan_lines, state.line_status = nil, nil, nil
    state.status, state.sidecar_warning = "", ""
  end
```

- [ ] **Step 3: Add the empty-selection state**

In the run-gating block (~line 895, where `run_error` is computed), add the selection check as the **first** condition, before the header checks:

```lua
        local run_error
        if #usable == 0 then
          run_error = (#skipped > 0)
            and ("None of the selected items can be transcribed:\n" .. table.concat(skipped, "\n"))
            or  "Select the recorded session item(s) on a track."
        elseif not state.header then
```

(the existing `if not state.header then` becomes this `elseif`).

- [ ] **Step 4: Verify**

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```
Expected: no output.

Run (Bash tool): `./run_tests.sh 2>&1 | tail -5` — expected `257 passed, 0 failed` (unchanged; this task touches no library code).

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua && git commit -m "feat(VO): follow the item selection live instead of freezing it at launch"
```

---

### Task 6: Load sidecars with verification

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua` — add `LoadSidecars()`; call it from the selection-change branch added in Task 5.

**Interfaces:**
- Consumes: `vo.SidecarPath`, `vo.ParseSidecar`, `vo.SourceTimeToProject`, `vo.FileExists`, `vo.FileSize` (all existing or from Tasks 1–2); `RefreshSelection` from Task 5.
- Produces: `LoadSidecars()`, which sets `state.plan`, `state.plan_lines`, `state.line_status`, `state.stale_sources` (array of file names), `state.script_mismatch` (string or `""`), `state.orphan_count`, `state.dropped_count`.

- [ ] **Step 1: Add the loader**

Insert after `WriteSidecars`:

```lua
-- Load every sidecar for the currently selected sources into ONE plan. N files
-- in, one plan out: the Status column folds several spans per line by rank, so
-- a line matched in one recording and absent from another still reads matched.
local function LoadSidecars()
  local plan            = {}
  local stale           = {}
  local script_mismatch = ""
  local dropped         = 0

  -- Distinct sources, each with the items that currently reference it.
  local by_source = {}
  for _, item in ipairs(usable) do
    if item.path then
      by_source[item.path] = by_source[item.path] or {}
      table.insert(by_source[item.path], item)
    end
  end

  for source_path, its in pairs(by_source) do
    local path = vo.SidecarPath(source_path)
    if path and vo.FileExists(path) then
      local parsed = vo.ParseSidecar(ReadFile(path))
      if parsed then
        -- The audio-changed check is file-level: if the recording differs, every
        -- span's timing in this file is suspect at once, so Cut is blocked
        -- rather than a per-line status being invented.
        if parsed.source_bytes ~= (vo.FileSize(source_path) or 0) then
          stale[#stale + 1] = source_path:match("([^/\\]+)$") or source_path
        end
        if parsed.script_csv ~= "" and state.csv_path ~= ""
           and parsed.script_csv ~= state.csv_path then
          script_mismatch = parsed.script_csv
        end

        for _, span in ipairs(parsed.spans) do
          -- Place the span against whichever item currently plays that region.
          -- An item trimmed since transcription leaves spans with no audio
          -- behind them; those are dropped and counted, never clamped.
          local placed = false
          for _, item in ipairs(its) do
            local src_end = (item.start_offs or 0) + (item.length or 0) * (item.playrate or 1.0)
            local mid = (span.start + span.stop) / 2
            if mid >= (item.start_offs or 0) and mid <= src_end then
              local copy = {}
              for k, v in pairs(span) do copy[k] = v end
              copy.start = vo.SourceTimeToProject(span.start, item)
              copy.stop  = vo.SourceTimeToProject(span.stop,  item)
              plan[#plan + 1] = copy
              placed = true
              break
            end
          end
          if not placed then dropped = dropped + 1 end
        end
      end
    end
  end

  state.stale_sources   = stale
  state.script_mismatch = script_mismatch
  state.dropped_count   = dropped

  if #plan == 0 then
    state.plan, state.plan_lines, state.line_status = nil, nil, nil
    state.orphan_count = 0
    return
  end

  table.sort(plan, function(a, b) return (a.start or 0) < (b.start or 0) end)
  state.plan       = plan
  state.plan_lines = state.preview or {}
  state.line_status, state.orphan_count = FoldStatuses(plan, state.plan_lines)
  state.status = string.format("Loaded %d transcribed span(s) from disk.", #plan)
end
```

- [ ] **Step 2: Extract the status fold so load and transcribe share it**

The span-folding block currently lives inline in `Run`'s success callback. Lift it to a named function defined **above** `LoadSidecars`, and have both call it. Insert:

```lua
-- Fold a plan's spans to one status per script line. A line can produce several
-- spans (one per take), so the best outcome wins. Also returns how many spans
-- name a Filename that is not in the current script — an orphan, which the
-- table cannot show because the table is driven by script lines.
local function FoldStatuses(plan, lines)
  local in_script = {}
  for _, line in ipairs(lines or {}) do
    if line.asset then in_script[line.asset] = true end
  end

  local by_asset, orphans = {}, 0
  for _, span in ipairs(plan or {}) do
    local s = STATUS[span.kind]
    if span.asset and s then
      if not in_script[span.asset] then
        orphans = orphans + 1
      else
        local cur = STATUS[by_asset[span.asset]]
        if not cur or s.rank > cur.rank then by_asset[span.asset] = span.kind end
      end
    end
  end

  -- A line the plan never mentions produced no audio at all.
  for _, line in ipairs(lines or {}) do
    if line.asset and not by_asset[line.asset] then by_asset[line.asset] = "unmatched" end
  end

  return by_asset, orphans
end
```

Then in `Run`'s success callback, replace the inline `by_asset` block with:

```lua
          state.line_status, state.orphan_count = FoldStatuses(plan, lines)
```

Note `FoldStatuses` counts an orphan once per *span*, so a line with three orphan takes counts three. That matches the message wording in Step 4 ("transcribed lines"), which is close enough to be useful and avoids a second dedup pass; if the count reads oddly in practice, dedup by asset.

- [ ] **Step 3: Load on selection change**

Extend the Task 5 frame-loop branch:

```lua
  if RefreshSelection() then
    state.plan, state.plan_lines, state.line_status = nil, nil, nil
    state.status, state.sidecar_warning = "", ""
    state.stale_sources, state.script_mismatch = {}, ""
    state.orphan_count, state.dropped_count = 0, 0
    LoadSidecars()
  end
```

`LoadSidecars` depends on `state.preview` for the line list, which `RefreshPreview` fills. Also call `LoadSidecars()` at the end of `RefreshPreview` when `state.plan` is nil, so loading a CSV after selecting an item still picks up the statuses.

Add to the `state` table:

```lua
  stale_sources    = {},        -- base names whose audio changed since transcription
  script_mismatch  = "",        -- sidecar's script CSV path when it differs
  orphan_count     = 0,         -- spans naming a Filename absent from the script
  dropped_count    = 0,         -- spans falling outside the current items
```

- [ ] **Step 4: Show the verification results and block Cut when stale**

In the message block below the table, after `state.status`, add:

```lua
        if #state.stale_sources > 0 then
          im.TextColored(ctx, 0xDDAA33FF, string.format(
            "%s has changed since it was transcribed — Re-transcribe to refresh.",
            table.concat(state.stale_sources, ", ")))
        end
        if state.script_mismatch ~= "" then
          im.TextColored(ctx, 0xDDAA33FF,
            "Transcribed against a different script: " .. state.script_mismatch)
        end
        if state.orphan_count > 0 then
          im.TextDisabled(ctx, string.format(
            "%d transcribed line(s) are not in this script.", state.orphan_count))
        end
        if state.dropped_count > 0 then
          im.TextDisabled(ctx, string.format(
            "%d transcribed span(s) fall outside the selected items.", state.dropped_count))
        end
        if state.sidecar_warning ~= "" then
          im.TextColored(ctx, 0xDDAA33FF, state.sidecar_warning)
        end
```

These lines are conditional, so extend the counted reserve that sizes the table — the `local rows = 2` block. Add one row per line that will render:

```lua
          local rows = 2 -- count line + button row
          if state.status ~= ""          then rows = rows + 1 end
          if #state.stale_sources > 0    then rows = rows + 1 end
          if state.script_mismatch ~= "" then rows = rows + 1 end
          if state.orphan_count > 0      then rows = rows + 1 end
          if state.dropped_count > 0     then rows = rows + 1 end
          if state.sidecar_warning ~= "" then rows = rows + 1 end
          if run_error                   then rows = rows + 1 end
          if state.message ~= ""         then rows = rows + 1 end
```

Change the Cut button's disabled condition from `state.plan == nil` to:

```lua
        local dis_cut = (state.plan == nil) or (#state.stale_sources > 0)
```

and extend its tooltip:

```lua
        if im.IsItemHovered(ctx) then
          im.SetTooltip(ctx,
            (#state.stale_sources > 0) and "The audio has changed since it was transcribed. Re-transcribe first."
            or dis_cut and "Transcribe first — there is no plan to apply."
            or "Split and name the clips from the transcribed plan.")
        end
```

- [ ] **Step 5: Verify**

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```
Expected: no output. Run (Bash tool): `./run_tests.sh 2>&1 | tail -5` — expected `257 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua && git commit -m "feat(VO): load sidecars on selection change, verify audio and script"
```

---

### Task 7: Transcribe / Re-transcribe gating

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua` — `Run()` and the transcribe button.

**Interfaces:**
- Consumes: `state.plan`, `state.stale_sources` from Task 6.
- Produces: `SourcesNeedingTranscription() -> array of source paths`.

- [ ] **Step 1: Add the helper**

Insert after `LoadSidecars`:

```lua
-- A source counts as already transcribed only if its sidecar loaded cleanly AND
-- the audio still matches. A stale sidecar must NOT count: its timings are why
-- Cut is disabled, so skipping it would strand the user with no way forward.
local function SourcesNeedingTranscription()
  local stale = {}
  for _, name in ipairs(state.stale_sources or {}) do stale[name] = true end

  local have = {}
  for _, span in ipairs(state.plan or {}) do
    if span.asset then have[span.asset] = true end
  end
  local has_plan = next(have) ~= nil

  local need, seen = {}, {}
  for _, item in ipairs(usable) do
    local base = item.path and (item.path:match("([^/\\]+)$") or item.path)
    if item.path and not seen[item.path] then
      seen[item.path] = true
      if not has_plan or stale[base] then need[#need + 1] = item.path end
    end
  end
  return need
end
```

- [ ] **Step 2: Label the button by what it will do**

Replace the `relabel` line:

```lua
      local needing = SourcesNeedingTranscription()
      local relabel = (#needing == 0) and "Re-transcribe" or "Transcribe"
      RightAlign({ relabel, "Cut and name" })
```

and the tooltip:

```lua
        if im.IsItemHovered(ctx) then
          im.SetTooltip(ctx, (#needing == 0)
            and "Every selected recording is already transcribed.\nThis discards those results and runs again from scratch."
            or  string.format("Transcribe %d recording(s).\nNothing in the project changes.", #needing))
        end
```

- [ ] **Step 3: Force re-transcription only when nothing needs it**

In `Run`, the source list is built at lines 647–654 and `force_retranscribe` is set at line 660. Replace that whole span — from the `-- One transcription per unique source file` comment through `cfg.force_retranscribe = (state.plan ~= nil)` — with:

```lua
  -- One transcription per unique source file, however many items use it, and
  -- only those that need it: a source whose sidecar loaded cleanly and still
  -- matches its audio is skipped.
  local needing = SourcesNeedingTranscription()
  local wanted  = {}
  for _, path in ipairs(needing) do wanted[path] = true end

  local seen, sources = {}, {}
  for _, item in ipairs(usable) do
    if item.path and not seen[item.path] and (#needing == 0 or wanted[item.path]) then
      seen[item.path] = true
      sources[#sources + 1] = { path = item.path, size = vo.FileSize(item.path) or 0 }
    end
  end

  -- Nothing needs transcribing, so this press is a deliberate re-run: bypass
  -- both the sidecar and the scratch-dir transcript cache. The cache key already
  -- covers backend settings, so only the audio itself can have changed under it.
  cfg.force_retranscribe = (#needing == 0)
```

When `#needing == 0` the `wanted` filter is bypassed and every source is transcribed, which is what Re-transcribe means.

- [ ] **Step 4: Verify**

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```
Expected: no output. Run (Bash tool): `./run_tests.sh 2>&1 | tail -5` — expected `257 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua && git commit -m "feat(VO): transcribe only sources lacking a usable result"
```

---

### Task 8: Popups ask, never tell

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua` — lines 42, 159 (already gone after Task 5), 614, 681, 720, 724.

**Interfaces:**
- Consumes: `state.message`, `state.status` (existing inline message channels).
- Produces: `state.summary` — an array of result lines shown inline after a cut.

- [ ] **Step 1: Convert the backend-not-ready launch check**

The check at line 42 currently calls `r.MB` and returns before the dialog opens. Replace the early exit with a state flag:

```lua
local backend_error = ""
local ready, ready_msg = vo.IsBackendReady(cfg)
if not ready then
  backend_error = ready_msg .. "\nRun \"ajsfx VO Settings\" to configure the speech backend."
end
```

Add `backend_error` to the run-gating chain in Task 5's Step 3, as the condition after `#usable == 0`:

```lua
        elseif backend_error ~= "" then
          run_error = backend_error
```

- [ ] **Step 2: Replace the run summary message box**

In `Finish`, the summary is assembled into a `summary` table and shown with
`r.MB(table.concat(summary, "\n"), "ajsfx VO ScriptMatch", 0)`. Delete the `r.MB` call and keep the table:

```lua
  state.summary = summary
```

Add `summary = {}` to the `state` table. Render it below the table, after `state.status`:

```lua
        for _, line in ipairs(state.summary) do
          im.TextDisabled(ctx, line)
        end
```

and add `rows = rows + #state.summary` to the counted reserve block from Task 6.

Clear it at the top of `Run` and in `RefreshPreview`, alongside `state.status = ""`:

```lua
  state.summary = {}
```

- [ ] **Step 3: Convert the three transcription-outcome message boxes**

| Line | Current | Replace with |
|---|---|---|
| ~681 | `r.MB("The transcription produced no words…")` | `state.message = "The transcription produced no words, so there is nothing to match."` |
| ~720 | `r.MB("Cancelled. Nothing in the project was changed.")` | `state.status = "Cancelled. Nothing in the project was changed."` |
| ~724 | `r.MB(message .. "\n\nNothing in the project was changed.")` | `state.message = message .. " Nothing in the project was changed."` |

In each case also set `state.running = false` if the existing code did so; do not remove any state handling, only the message box.

- [ ] **Step 4: Confirm only the three intended popups remain**

```bash
grep -n "r\.MB(\|GetUserInputs" VO/ajsfx_VO_ScriptMatch.lua
```
Expected: exactly four matches — the missing-ReaImGui message near line 53, the preset overwrite confirm in `DoSave`, the `Save As…` name prompt, and the preset delete confirm. Any other match is a miss.

- [ ] **Step 5: Verify**

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```
Expected: no output. Run (Bash tool): `./run_tests.sh 2>&1 | tail -5` — expected `257 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_ScriptMatch.lua && git commit -m "feat(VO): report status inline instead of in focus-stealing message boxes"
```

---

### Task 9: Documentation and changelog

**Files:**
- Modify: `VO/ajsfx_VO_ScriptMatch.lua` — the `@changelog` line in the header
- Modify: `VO/SPEC.md` — the section describing the run report
- Modify: `VO/MANUAL_TEST.md` — add the manual verification steps

- [ ] **Step 1: Amend the changelog**

The header is at `@version 0.8`, unreleased on this branch. Append to the existing `@changelog` line (it is one long single line — do not add a second `@changelog`):

```
 The run report is now written next to each recording as <audio>_vo_report.csv instead of once per project, and it is written when you transcribe rather than only when you cut. Reopening the dialog on a recording that already has one restores its result without re-transcribing. The dialog now follows the item selection while it is open, so it no longer refuses to start when nothing is selected. Status, results and errors are reported in the dialog instead of in message boxes that steal focus.
```

- [ ] **Step 2: Update SPEC.md**

Four places in `VO/SPEC.md` reference the report. Update each, keeping the `### Report` heading text so existing cross-references still resolve:

| Line | Current | Change to |
|---|---|---|
| ~199 | The dataflow diagram ends `ApplyPlan() [REAPER]    report CSV` | `ApplyPlan() [REAPER]    sidecar CSV (per source)` |
| ~249 | Function table row `` `vo.BuildReport(plan, lines)` `` → `Report CSV string` | Two rows: `` `vo.SerializeSidecar(spans, lines, meta)` `` → `Sidecar CSV string (source-time spans)`, and `` `vo.ParseSidecar(text)` `` → `Parsed sidecar table, or nil plus a reason` |
| ~389 | The `### Report` section body, describing one CSV per project written at cut time | Rewrite: one `<audio>_vo_report.csv` per media source file, written beside the audio on transcribe and rewritten on cut; span times are source-relative so the file survives the item moving; the file is read back on open to restore a transcription without re-running whisper |
| ~503 | `…with the run dialog, per-project CSV memory, and report.` | `…with the run dialog, per-project CSV memory, and a per-source sidecar.` |

Line 127 (`They are still listed in the report`) and line 387 (`noted in the report`) stay accurate as written — the sidecar still lists both — so leave them.

- [ ] **Step 3: Add the manual test steps**

Append to `VO/MANUAL_TEST.md`, as a new numbered section following the existing style:

```markdown
## Per-source sidecar

1. Open the script with nothing selected. No message box appears; the dialog shows
   `Select the recorded session item(s) on a track.` and Transcribe is disabled.
2. Select an item. The table becomes active without reopening the script.
3. Transcribe. `<audio>_vo_report.csv` appears beside the audio file, and the Status
   column populates.
4. Close and reopen with the same item selected. Statuses return with no whisper run.
5. Select a different recording that has its own sidecar. The table switches to it.
6. Select both recordings at once. Both sidecars load and the statuses union.
7. Drag the item along the timeline, then reopen. Spans still align with the audio.
8. Re-record over the .wav so its size changes. An amber line names the file and
   Cut is disabled; Re-transcribe clears it.
9. Load a different script CSV. The mismatch line appears and Cut stays enabled.
10. Press Re-transcribe. Whisper actually re-runs and the sidecar is rewritten.
11. Cut. The summary appears inline; no message box takes focus.
12. Make the audio directory read-only and transcribe. An inline warning names the
    path and the session remains usable.
```

- [ ] **Step 4: Verify and commit**

```bash
luac -p VO/ajsfx_VO_ScriptMatch.lua
```
Expected: no output.

```bash
git add VO/ajsfx_VO_ScriptMatch.lua VO/SPEC.md VO/MANUAL_TEST.md && git commit -m "docs(VO): per-source sidecar in spec, manual tests and changelog"
```

- [ ] **Step 5: Hand back for REAPER verification**

Do **not** merge to `main`. Report to the user that the branch is ready and list the 12 manual steps above. Seven commits from earlier work on this branch are also still unverified in REAPER.

---

## Notes for the implementer

**Definition order in the dialog.** `VO/ajsfx_VO_ScriptMatch.lua` is a single flat file of `local function` declarations, so every function must be defined after everything it references. Tasks 4–7 add functions that read the module-level `state` and `usable` tables. If `luac -p` passes but REAPER reports `attempt to index a nil value (upvalue 'state')`, the definition is above the table — move it down.

**`ClampSpansToItems` still applies to loaded plans.** It is called in `Run` after `BuildPlan`. Loaded spans are already placed against current items by `LoadSidecars`, so they do not need it, but a cut applies `vo.ApplyPlan` to whatever is in `state.plan` regardless of origin. Leave the existing call where it is.

**The `Clamped` column is written and ignored.** It records what happened at the original cut, for a human reading the file. Clamping is re-derived from current items on load, so parsing it back would be a second source of truth.
