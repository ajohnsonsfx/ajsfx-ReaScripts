# VO Source Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `ajsfx_VO_ScriptMatch.lua` into three windows — Sources (transcribe), Overview (judge), Cut (act) — with transcription stored per-wav as word-level CSV, matching computed live, and clip boundaries snapped to silence.

**Architecture:** The pure layer in `VO/lib/ajsfx_vo.lua` gains three new file formats and a matcher that takes parsed words instead of running whisper. Everything persisted is either words (beside the audio) or judgements (beside the project); the match itself is recomputed and never written. Boundary placement becomes a search bounded by neighbouring word timestamps, with amplitude read through an injected probe function so it stays unit-testable.

**Tech Stack:** Lua 5.x, REAPER ReaScript API, ReaImGui 0.9.3, whisper.cpp CLI, ReaPack.

**Spec:** `docs/superpowers/specs/2026-08-01-vo-source-manager-design.md`. Read it before Task 1.

**Branch:** `feature/vo-source-manager` (already created).

## Global Constraints

- **No backwards compatibility.** Old `<audio>_vo_report.csv` and `<project>_vo_tracker.csv` are neither read nor migrated. Delete the code that produced them; do not leave fallbacks.
- **Lua 5.x only.** No external libraries. No JSON. CSV is parsed with the existing `vo.ParseCSV`.
- **The pure layer must not call `reaper.*`** except in the sections already marked "Coupled layer". Anything under test lives above that line.
- **Every parser returns `nil, reason` and never raises.** A malformed file beside the audio must not stop a window opening.
- **Times in files are source-relative seconds, 3 decimals** (`string.format("%.3f", t)`).
- **Run `./run_tests.sh` from the repo root** after every implementation step. All tests must pass before commit.
- **Wrap project mutations in `core.Transaction("Name", function() ... end)`** for undo (CLAUDE.md).
- **When bumping `@version`, update `@changelog` in the same header** (CLAUDE.md). Only Task 14 touches versions.
- **`index.xml` is never hand-edited.** CI rebuilds it on merge to `main`.
- Existing test count is the floor: `tests/test_vo.lua` currently passes. Tests deleted in Task 6 are the only permitted reduction.

---

## File Structure

| File | Responsibility | Tasks |
|---|---|---|
| `VO/lib/ajsfx_vo.lua` | All pure logic + coupled REAPER helpers. Existing file, ~3538 lines. | 1–7 |
| `VO/lib/ajsfx_vo_view.lua` | Shared ImGui table presentation. Unchanged. | — |
| `VO/ajsfx_VO_Sources.lua` | **New.** File list, transcribe, per-file detail. | 8, 9 |
| `VO/ajsfx_VO_Overview.lua` | Existing. Rewired to project file + live match. | 10, 11 |
| `VO/ajsfx_VO_Cut.lua` | **New.** Run dialog, padding/snapping, `ApplyPlan`. | 12 |
| `VO/ajsfx_VO_Settings.lua` | Existing. Gains snap knobs. | 13 |
| `VO/ajsfx_VO_ScriptMatch.lua` | **Deleted.** | 14 |
| `tests/test_vo.lua` | Existing suite. Added to in 1–5, pruned in 6. | 1–6 |

`ajsfx_vo.lua` is already large. Do not split it in this plan — the pure/coupled boundary inside it is load-bearing and well-commented, and a split is a separate change. Add new pure functions immediately after the section they belong to, marked with the existing `--------------------------------` section comment style.

---

## Task 1: Transcript sidecar format

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — add after `vo.SourceCoverageRanges` (currently ends line 1689), before the `-- Pure layer: the overview tracker` section header
- Test: `tests/test_vo.lua` — append a new section before the final summary print

**Interfaces:**
- Consumes: `vo.ParseCSV`, `vo.FormatCSVRow`, `vo.EscapeCSVField`, the file-local `strip_ext` (already used by `vo.SidecarPath` at line 1639)
- Produces:
  - `vo.TRANSCRIPT_MARKER = "ajsfx VO Transcript"`, `vo.TRANSCRIPT_VERSION = 1`, `vo.TRANSCRIPT_HEADER = { "Start", "End", "Text" }`
  - `vo.TranscriptPath(source_path) -> string|nil`
  - `vo.SerializeTranscript(words, meta) -> string` where `words` is `{ {t0=number, t1=number, text=string}, ... }` (exactly `vo.ParseWhisperCSV`'s output shape) and `meta` is `{ source=string, source_bytes=number, backend=string, model=string, language=string }`
  - `vo.ParseTranscript(text) -> table|nil, string` returning `{ version, source, source_bytes, backend, model, language, words }`

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo.lua`, before the summary print at the end of the file:

```lua
--------------------------------
-- Transcript sidecar
--------------------------------
print("\nTranscriptPath:")

test("swaps the final extension for _vo_transcript.csv", function()
  assert(vo.TranscriptPath("D:/s/RIVA.wav") == "D:/s/RIVA_vo_transcript.csv",
         "Got: " .. tostring(vo.TranscriptPath("D:/s/RIVA.wav")))
end)

test("a path with no extension just gains the suffix", function()
  assert(vo.TranscriptPath("D:/s/RIVA") == "D:/s/RIVA_vo_transcript.csv",
         "Got: " .. tostring(vo.TranscriptPath("D:/s/RIVA")))
end)

test("a dot in a directory name is not treated as an extension", function()
  local got = vo.TranscriptPath("D:/my.session/RIVA.wav")
  assert(got == "D:/my.session/RIVA_vo_transcript.csv", "Got: " .. tostring(got))
end)

test("nil and empty return nil", function()
  assert(vo.TranscriptPath(nil) == nil, "nil should return nil")
  assert(vo.TranscriptPath("") == nil, "empty should return nil")
end)

print("\nSerializeTranscript / ParseTranscript:")

local function sample_words()
  return {
    { t0 = 12.480, t1 = 12.660, text = "we" },
    { t0 = 12.660, t1 = 12.910, text = "should" },
    { t0 = 12.910, t1 = 13.040, text = "not," },
  }
end

local function sample_meta()
  return { source = "RIVA.wav", source_bytes = 412839104,
           backend = "whisper.cpp", model = "ggml-medium.bin", language = "en" }
end

test("round-trip preserves every word and every preamble field", function()
  local text = vo.SerializeTranscript(sample_words(), sample_meta())
  local got, why = vo.ParseTranscript(text)
  assert(got, "Parse failed: " .. tostring(why))
  assert(got.version == 1, "Version: " .. tostring(got.version))
  assert(got.source == "RIVA.wav", "Source: " .. tostring(got.source))
  assert(got.source_bytes == 412839104, "Bytes: " .. tostring(got.source_bytes))
  assert(got.backend == "whisper.cpp", "Backend: " .. tostring(got.backend))
  assert(got.model == "ggml-medium.bin", "Model: " .. tostring(got.model))
  assert(got.language == "en", "Language: " .. tostring(got.language))
  assert(#got.words == 3, "Word count: " .. #got.words)
  assert(math.abs(got.words[1].t0 - 12.480) < 1e-6, "t0: " .. tostring(got.words[1].t0))
  assert(math.abs(got.words[3].t1 - 13.040) < 1e-6, "t1: " .. tostring(got.words[3].t1))
  assert(got.words[3].text == "not,", "text: " .. tostring(got.words[3].text))
end)

test("a word containing a comma, a quote and a newline survives", function()
  local words = { { t0 = 0, t1 = 1, text = 'he said "go,"\nquietly' } }
  local got = vo.ParseTranscript(vo.SerializeTranscript(words, sample_meta()))
  assert(got, "Parse failed")
  assert(got.words[1].text == 'he said "go,"\nquietly', "Got: " .. tostring(got.words[1].text))
end)

test("times are written to three decimals", function()
  local text = vo.SerializeTranscript({ { t0 = 1.23456, t1 = 2.5, text = "x" } }, sample_meta())
  assert(text:find("1.235,2.500,x", 1, true), "Row not found in:\n" .. text)
end)

test("an empty word list still produces a parseable file", function()
  local got, why = vo.ParseTranscript(vo.SerializeTranscript({}, sample_meta()))
  assert(got, "Parse failed: " .. tostring(why))
  assert(#got.words == 0, "Expected no words, got " .. #got.words)
end)

test("empty text is rejected with a reason", function()
  local got, why = vo.ParseTranscript("")
  assert(got == nil and type(why) == "string", "Expected nil + reason")
end)

test("a foreign file is rejected with a reason", function()
  local got, why = vo.ParseTranscript("Start,End,Text\n1,2,hi\n")
  assert(got == nil and type(why) == "string", "Expected nil + reason")
end)

test("an unknown version is rejected with a reason", function()
  local got, why = vo.ParseTranscript("ajsfx VO Transcript,99\n\nStart,End,Text\n")
  assert(got == nil and type(why) == "string", "Expected nil + reason")
end)

test("a missing word header is rejected with a reason", function()
  local got, why = vo.ParseTranscript("ajsfx VO Transcript,1\nSource,a.wav\n")
  assert(got == nil and type(why) == "string", "Expected nil + reason")
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./run_tests.sh
```

Expected: FAIL — `attempt to call a nil value (field 'TranscriptPath')`.

- [ ] **Step 3: Implement**

Insert into `VO/lib/ajsfx_vo.lua` immediately after `vo.SourceCoverageRanges` ends (line 1689):

```lua
--------------------------------
-- Pure layer: the transcript sidecar
--------------------------------

-- WORDS, not spans. A recording's transcription is a fact about the audio and
-- nothing else: no script, no mapping, no match. Storing whisper's own segment
-- grouping would store its guess at where lines divide, and the script -- not
-- the recogniser -- is what says that. `-ml 1` makes every whisper segment one
-- word anyway, so there is no grouping left to store.

vo.TRANSCRIPT_MARKER  = "ajsfx VO Transcript"
vo.TRANSCRIPT_VERSION = 1
vo.TRANSCRIPT_HEADER  = { "Start", "End", "Text" }

function vo.TranscriptPath(source_path)
  if not source_path or source_path == "" then return nil end
  return strip_ext(source_path) .. "_vo_transcript.csv"
end

-- `words` are in SOURCE time, as vo.ParseWhisperCSV produces them. This
-- function converts nothing, so it cannot silently write project times.
function vo.SerializeTranscript(words, meta)
  meta = meta or {}
  local out = {
    vo.FormatCSVRow({ vo.TRANSCRIPT_MARKER, tostring(vo.TRANSCRIPT_VERSION) }),
    vo.FormatCSVRow({ "Source",       meta.source or "" }),
    vo.FormatCSVRow({ "Source bytes", tostring(meta.source_bytes or 0) }),
    vo.FormatCSVRow({ "Backend",      meta.backend or "" }),
    vo.FormatCSVRow({ "Model",        meta.model or "" }),
    vo.FormatCSVRow({ "Language",     meta.language or "" }),
    "",
    vo.FormatCSVRow(vo.TRANSCRIPT_HEADER),
  }
  for _, w in ipairs(words or {}) do
    out[#out + 1] = vo.FormatCSVRow({
      string.format("%.3f", w.t0 or 0),
      string.format("%.3f", w.t1 or 0),
      w.text or "",
    })
  end
  return table.concat(out, "\n") .. "\n"
end

function vo.ParseTranscript(text)
  if type(text) ~= "string" or text == "" then
    return nil, "The transcript file is empty."
  end

  local rows = vo.ParseCSV(text)
  if not rows[1] or rows[1][1] ~= vo.TRANSCRIPT_MARKER then
    return nil, "Not an " .. vo.TRANSCRIPT_MARKER .. " file."
  end

  local version = tonumber(rows[1][2] or "")
  if version ~= vo.TRANSCRIPT_VERSION then
    return nil, "Unsupported transcript version: " .. tostring(rows[1][2])
  end

  local parsed = { version = version, source = "", source_bytes = 0,
                   backend = "", model = "", language = "", words = {} }

  local i, header_at = 2, nil
  while rows[i] do
    local key = rows[i][1] or ""
    if key == vo.TRANSCRIPT_HEADER[1] then header_at = i; break end
    if     key == "Source"       then parsed.source       = rows[i][2] or ""
    elseif key == "Source bytes" then parsed.source_bytes = tonumber(rows[i][2] or "") or 0
    elseif key == "Backend"      then parsed.backend      = rows[i][2] or ""
    elseif key == "Model"        then parsed.model        = rows[i][2] or ""
    elseif key == "Language"     then parsed.language     = rows[i][2] or ""
    end
    i = i + 1
  end

  if not header_at then
    return nil, "The transcript has no word header row."
  end

  for j = header_at + 1, #rows do
    local row = rows[j]
    local t0, t1 = tonumber(row[1] or ""), tonumber(row[2] or "")
    if t0 and t1 then
      parsed.words[#parsed.words + 1] = { t0 = t0, t1 = t1, text = row[3] or "" }
    end
  end

  return parsed
end
```

Note: `strip_ext` is an existing file-local defined above `vo.SidecarPath`. Do not redefine it.

- [ ] **Step 4: Run tests to verify they pass**

```bash
./run_tests.sh
```

Expected: PASS, with the new `TranscriptPath` and `SerializeTranscript / ParseTranscript` sections listed.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat(VO): word-level transcript sidecar format"
```

---

## Task 2: Project file format

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — the `-- Pure layer: the overview tracker` section (currently lines 1691–1811)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.ParseCSV`, `vo.FormatCSVRow`, the file-locals `strip_ext`, `fold`, and the `encode_mapping` / `decode_mapping` pair currently defined at lines 1292–1308 (they survive Task 6's deletions specifically because this task uses them)
- Produces:
  - `vo.PROJECT_MARKER = "ajsfx VO Project"`, `vo.PROJECT_VERSION = 1`
  - `vo.PROJECT_HEADER = { "Key", "Filename", "Source", "Source start", "Select", "Status", "Name override", "Notes" }`
  - `vo.ProjectFilePath(project_path) -> string|nil`
  - `vo.SerializeProjectFile(entries, meta) -> string` where `entries` is `{ {key, asset, source, source_start, select=boolean, status, name_override, notes}, ... }` and `meta` is `{ script_csv=string, mapping=table }`
  - `vo.ParseProjectFile(text) -> table|nil, string` returning `{ version, script_csv, mapping, entries }`
- `vo.TRACKER_STATUSES`, `vo.TRACKER_REMATCH_TOLERANCE` and `vo.OverviewKey` keep their names and behaviour — only the file wrapper changes.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo.lua`:

```lua
--------------------------------
-- Project file
--------------------------------
print("\nProjectFilePath:")

test("swaps the project extension for _vo.csv", function()
  local got = vo.ProjectFilePath("D:/s/Session.rpp")
  assert(got == "D:/s/Session_vo.csv", "Got: " .. tostring(got))
end)

test("nil and empty return nil", function()
  assert(vo.ProjectFilePath(nil) == nil, "nil should return nil")
  assert(vo.ProjectFilePath("") == nil, "empty should return nil")
end)

print("\nSerializeProjectFile / ParseProjectFile:")

local function sample_entries()
  return {
    { key = "RIVA.wav|12480", asset = "vo_riva_intro_01",
      source = "D:/s/RIVA.wav", source_start = 12.480,
      select = true, status = "verified", notes = "great read" },
    { key = "|vo_riva_deck_03", asset = "vo_riva_deck_03",
      notes = "re-record next session" },
  }
end

local function sample_pmeta()
  return { script_csv = "D:/s/script.csv",
           mapping = { asset = "Filename", text = "Line Text", speaker = "Character" } }
end

test("round-trip preserves entries and the preamble", function()
  local text = vo.SerializeProjectFile(sample_entries(), sample_pmeta())
  local got, why = vo.ParseProjectFile(text)
  assert(got, "Parse failed: " .. tostring(why))
  assert(got.script_csv == "D:/s/script.csv", "Script: " .. tostring(got.script_csv))
  assert(got.mapping.asset == "Filename", "Mapping asset: " .. tostring(got.mapping.asset))
  assert(got.mapping.speaker == "Character", "Mapping speaker: " .. tostring(got.mapping.speaker))
  assert(#got.entries == 2, "Entry count: " .. #got.entries)
  assert(got.entries[1].select == true, "Select should be true")
  assert(got.entries[1].status == "verified", "Status: " .. tostring(got.entries[1].status))
  assert(math.abs(got.entries[1].source_start - 12.480) < 1e-6, "Start wrong")
  assert(got.entries[2].notes == "re-record next session", "Notes: " .. tostring(got.entries[2].notes))
  assert(got.entries[2].source == nil, "A script-line row has no source")
end)

test("a row with no user work is not written", function()
  local text = vo.SerializeProjectFile({
    { key = "RIVA.wav|1000", asset = "a", source = "D:/s/RIVA.wav", source_start = 1.0 },
  }, sample_pmeta())
  local got = vo.ParseProjectFile(text)
  assert(#got.entries == 0, "Expected the blank row to be dropped, got " .. #got.entries)
end)

test("select alone counts as user work", function()
  local text = vo.SerializeProjectFile({
    { key = "RIVA.wav|1000", asset = "a", source = "D:/s/RIVA.wav",
      source_start = 1.0, select = true },
  }, sample_pmeta())
  local got = vo.ParseProjectFile(text)
  assert(#got.entries == 1, "Expected the row to be kept, got " .. #got.entries)
  assert(got.entries[1].select == true, "Select lost in round-trip")
end)

test("an unrecognised status is dropped rather than carried", function()
  local text = vo.SerializeProjectFile({
    { key = "k", asset = "a", source = "D:/s/RIVA.wav", source_start = 1.0,
      status = "banana", notes = "x" },
  }, sample_pmeta())
  local got = vo.ParseProjectFile(text)
  assert(got.entries[1].status == nil, "Status should be nil, got " .. tostring(got.entries[1].status))
end)

test("notes containing commas and quotes survive", function()
  local text = vo.SerializeProjectFile({
    { key = "k", asset = "a", source = "D:/s/RIVA.wav", source_start = 1.0,
      notes = 'take 2, but "flat"' },
  }, sample_pmeta())
  local got = vo.ParseProjectFile(text)
  assert(got.entries[1].notes == 'take 2, but "flat"', "Got: " .. tostring(got.entries[1].notes))
end)

test("empty, foreign, bad-version and header-less input each return nil plus a reason", function()
  for _, bad in ipairs({
    "",
    "Key,Filename\nx,y\n",
    "ajsfx VO Project,99\n\nKey,Filename\n",
    "ajsfx VO Project,1\nScript CSV,x\n",
  }) do
    local got, why = vo.ParseProjectFile(bad)
    assert(got == nil and type(why) == "string",
           "Expected nil + reason for: " .. bad:sub(1, 30))
  end
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./run_tests.sh
```

Expected: FAIL — `attempt to call a nil value (field 'ProjectFilePath')`.

- [ ] **Step 3: Implement**

In `VO/lib/ajsfx_vo.lua`, replace `vo.TrackerPath` (lines 1644–1651) with:

```lua
-- The project file lives beside the project: Session.rpp -> Session_vo.csv.
-- One per project, not one per source: it holds the user's own work (selects,
-- verified marks, notes, renames) plus the script it is all about. Unlike a
-- transcript it is never regenerated from audio.
function vo.ProjectFilePath(project_path)
  if not project_path or project_path == "" then return nil end
  return strip_ext(project_path) .. "_vo.csv"
end
```

Then replace the header block and both tracker serialisers. Change lines 1702–1708 to:

```lua
vo.PROJECT_MARKER  = "ajsfx VO Project"
vo.PROJECT_VERSION = 1

vo.PROJECT_HEADER = {
  "Key", "Filename", "Source", "Source start", "Select", "Status",
  "Name override", "Notes",
}
```

Leave `vo.TRACKER_STATUSES`, `vo.TRACKER_REMATCH_TOLERANCE` and `vo.OverviewKey` exactly as they are.

Replace `vo.SerializeTracker` (line 1732 through its `end`) with:

```lua
-- `meta` carries the script this project's judgements are about:
-- { script_csv, mapping }. It moves out of ProjExtState and in here so the
-- project file is the WHOLE of a project's VO state.
function vo.SerializeProjectFile(entries, meta)
  meta = meta or {}
  local out = {
    vo.FormatCSVRow({ vo.PROJECT_MARKER, tostring(vo.PROJECT_VERSION) }),
    vo.FormatCSVRow({ "Script CSV", meta.script_csv or "" }),
    vo.FormatCSVRow({ "Mapping",    encode_mapping(meta.mapping) }),
    "",
    vo.FormatCSVRow(vo.PROJECT_HEADER),
  }

  for _, e in ipairs(entries or {}) do
    -- Only rows carrying actual user work are written. Without this the file
    -- would grow a line per script line per session and the signal would drown.
    local has_work = (e.select == true)
                  or (e.status and e.status ~= "")
                  or (e.name_override and e.name_override ~= "")
                  or (e.notes and e.notes ~= "")
    if has_work then
      out[#out + 1] = vo.FormatCSVRow({
        e.key or "",
        e.asset or "",
        e.source or "",
        e.source_start and string.format("%.3f", e.source_start) or "",
        e.select and "yes" or "",
        e.status or "",
        e.name_override or "",
        e.notes or "",
      })
    end
  end

  return table.concat(out, "\n") .. "\n"
end
```

Replace `vo.ParseTracker` (lines 1766–1811) with:

```lua
function vo.ParseProjectFile(text)
  if type(text) ~= "string" or text == "" then
    return nil, "The project file is empty."
  end

  local rows = vo.ParseCSV(text)
  if not rows[1] or rows[1][1] ~= vo.PROJECT_MARKER then
    return nil, "Not an " .. vo.PROJECT_MARKER .. " file."
  end

  local version = tonumber(rows[1][2] or "")
  if version ~= vo.PROJECT_VERSION then
    return nil, "Unsupported project file version: " .. tostring(rows[1][2])
  end

  local parsed = { version = version, script_csv = "", mapping = {}, entries = {} }

  local i, header_at = 2, nil
  while rows[i] do
    local key = rows[i][1] or ""
    if key == vo.PROJECT_HEADER[1] then header_at = i; break end
    if     key == "Script CSV" then parsed.script_csv = rows[i][2] or ""
    elseif key == "Mapping"    then parsed.mapping    = decode_mapping(rows[i][2])
    end
    i = i + 1
  end

  if not header_at then
    return nil, "The project file has no header row."
  end

  for j = header_at + 1, #rows do
    local row = rows[j]
    local key = row[1] or ""
    if key ~= "" then
      local status = fold(row[6] or "")
      parsed.entries[#parsed.entries + 1] = {
        key           = key,
        asset         = row[2] ~= "" and row[2] or nil,
        source        = row[3] ~= "" and row[3] or nil,
        source_start  = tonumber(row[4] or ""),
        select        = fold(row[5] or "") == "yes",
        -- An unrecognised status is dropped rather than carried: it would
        -- otherwise render as an unknown badge with no way to clear it.
        status        = vo.TRACKER_STATUSES[status] and status or nil,
        name_override = row[7] ~= "" and row[7] or nil,
        notes         = row[8] ~= "" and row[8] or nil,
      }
    end
  end

  return parsed
end
```

`encode_mapping` and `decode_mapping` are file-locals defined at line 1292, above this point in the file — they are in scope. `fold` is an existing file-local.

Finally, update `index_tracker` (line 1817) and `resolve_tracker` (line 1848) only where they read `e.primary` — there is no `primary` field any more. Search for `primary` in that region and replace nothing else; `resolve_tracker` does not read it, and `index_tracker` does not either, so this is expected to be a no-op check. Confirm with:

```bash
grep -n "primary" VO/lib/ajsfx_vo.lua
```

Any hit inside `SerializeProjectFile`/`ParseProjectFile`/`index_tracker`/`resolve_tracker` is a bug; hits inside `vo.AssignNames`, `vo.DEFAULTS` and `vo.BuildOverview` are expected and handled in Tasks 5 and 10.

- [ ] **Step 4: Run tests**

```bash
./run_tests.sh
```

Expected: the new sections PASS. Existing `SerializeTracker`/`ParseTracker` tests now FAIL with `attempt to call a nil value` — that is expected and is resolved in Task 6. If you would rather keep the suite green between tasks, delete those specific tests now; Task 6 checks they are gone either way.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat(VO): project file replaces the tracker, carrying script and selects"
```

---

## Task 3: BuildMatch — matching from stored words

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — replace `vo.BuildPlan` (lines 1229–1257)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.BuildWordTokens`, `vo.BuildIndex`, `vo.FindCandidates`, `vo.SelectSpans`, `vo.FindGaps` — all unchanged
- Produces: `vo.BuildMatch(transcripts, lines, cfg) -> { {path=string, spans=array}, ... }`
  - `transcripts` is `{ {path=string, words=<vo.ParseTranscript words>}, ... }`
  - each returned `spans` array is in **source time**, sorted by `start`, and carries `kind`, `asset`, `score`, `margin`, `character`, `transcript`, `i0`, `i1`
  - **no padding and no names.** `vo.ApplyPadding` and `vo.AssignNames` are the caller's job (Task 12), because padding needs sample access and take numbering needs every source at once.
- `vo.BuildPlan` is deleted in this task, not Task 6, because `BuildMatch` replaces it directly.

- [ ] **Step 1: Write the failing tests**

Find the existing `BuildPlan:` section in `tests/test_vo.lua` (search for `print("BuildPlan` or `vo.BuildPlan`). Add a new section after it:

```lua
--------------------------------
-- BuildMatch
--------------------------------
print("\nBuildMatch:")

local function match_lines()
  return vo.BuildScriptLines(
    { { "Filename", "Character", "Line Text" },
      { "vo_a_01", "RIVA", "we should not have come" },
      { "vo_b_01", "RIVA", "seal it nobody goes below" } },
    { asset = "Filename", speaker = "Character", text = "Line Text" })
end

local function words_from(text, t0)
  local words, t = {}, t0 or 0
  for w in text:gmatch("%S+") do
    words[#words + 1] = { t0 = t, t1 = t + 0.2, text = w }
    t = t + 0.25
  end
  return words
end

test("one source produces one entry keyed by its path", function()
  local got = vo.BuildMatch(
    { { path = "D:/s/A.wav", words = words_from("we should not have come") } },
    match_lines(), {})
  assert(#got == 1, "Expected 1 result, got " .. #got)
  assert(got[1].path == "D:/s/A.wav", "Path: " .. tostring(got[1].path))
end)

test("the spoken line matches its script line", function()
  local got = vo.BuildMatch(
    { { path = "D:/s/A.wav", words = words_from("we should not have come") } },
    match_lines(), {})
  local found = false
  for _, s in ipairs(got[1].spans) do
    if s.kind == "match" and s.asset == "vo_a_01" then found = true end
  end
  assert(found, "vo_a_01 was not matched")
end)

test("two sources speaking the same line each get their own span", function()
  local got = vo.BuildMatch({
    { path = "D:/s/A.wav", words = words_from("we should not have come") },
    { path = "D:/s/B.wav", words = words_from("we should not have come") },
  }, match_lines(), {})
  assert(#got == 2, "Expected 2 results, got " .. #got)
  for _, entry in ipairs(got) do
    local hits = 0
    for _, s in ipairs(entry.spans) do
      if s.kind == "match" and s.asset == "vo_a_01" then hits = hits + 1 end
    end
    assert(hits == 1, entry.path .. " produced " .. hits .. " matches, expected 1")
  end
end)

test("spans come back sorted by start and carry their transcript", function()
  local got = vo.BuildMatch(
    { { path = "D:/s/A.wav", words = words_from("we should not have come") } },
    match_lines(), {})
  local last = -math.huge
  for _, s in ipairs(got[1].spans) do
    assert(s.start >= last, "Spans out of order")
    last = s.start
    assert(type(s.transcript) == "string", "Span has no transcript")
  end
end)

test("no padding is applied -- start equals the first word's own time", function()
  local words = words_from("we should not have come", 5.0)
  local got = vo.BuildMatch({ { path = "D:/s/A.wav", words = words } },
                            match_lines(), { pre_pad = 1.0, post_pad = 1.0 })
  for _, s in ipairs(got[1].spans) do
    if s.kind == "match" then
      assert(s.start >= 5.0 - 1e-6,
             "Padding leaked into BuildMatch: start=" .. tostring(s.start))
    end
  end
end)

test("no names are assigned -- that is the cutter's job", function()
  local got = vo.BuildMatch(
    { { path = "D:/s/A.wav", words = words_from("we should not have come") } },
    match_lines(), {})
  for _, s in ipairs(got[1].spans) do
    assert(s.name == nil, "Span already named: " .. tostring(s.name))
    assert(s.dest == nil, "Span already routed: " .. tostring(s.dest))
  end
end)

test("an empty transcript list returns an empty result", function()
  local got = vo.BuildMatch({}, match_lines(), {})
  assert(#got == 0, "Expected no results, got " .. #got)
end)

test("a source with no words still returns an entry with no spans", function()
  local got = vo.BuildMatch({ { path = "D:/s/A.wav", words = {} } }, match_lines(), {})
  assert(#got == 1, "Expected 1 result, got " .. #got)
  assert(#got[1].spans == 0, "Expected no spans, got " .. #got[1].spans)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./run_tests.sh
```

Expected: FAIL — `attempt to call a nil value (field 'BuildMatch')`.

- [ ] **Step 3: Implement**

Replace `vo.BuildPlan` (lines 1229–1257) entirely with:

```lua
-- Match stored words against the script, one source file at a time.
--
-- Per-source rather than pooled, deliberately: two recordings' words occupy
-- overlapping time ranges in their own files, so pooling them would let the
-- matcher build a span that starts in one recording and ends in another.
-- The index is built once and shared -- it depends only on the script.
--
-- Padding and naming are NOT done here. Padding needs sample access to snap to
-- silence (vo.ApplyPadding + vo.SnapBoundary), and take numbering needs every
-- source at once (vo.BuildOverview). Both are the caller's, and keeping this
-- function free of them is what lets Overview call it on every script change
-- without touching audio.
function vo.BuildMatch(transcripts, lines, cfg)
  local index = vo.BuildIndex(lines, cfg)
  local out = {}

  for _, t in ipairs(transcripts or {}) do
    local tokens     = vo.BuildWordTokens(t.words, cfg)
    local candidates = vo.FindCandidates(tokens, lines, index, cfg)
    local spans      = vo.SelectSpans(candidates, cfg)
    local gaps       = vo.FindGaps(tokens, spans)

    local plan = {}
    for _, s in ipairs(spans) do plan[#plan + 1] = s end
    for _, g in ipairs(gaps)  do plan[#plan + 1] = g end
    table.sort(plan, function(a, b)
      if a.i0 ~= b.i0 then return a.i0 < b.i0 end
      return a.i1 < b.i1
    end)

    for _, s in ipairs(plan) do
      if not s.transcript then
        local text = {}
        for k = s.i0, s.i1 do text[#text + 1] = tokens[k].text end
        s.transcript = table.concat(text, " ")
      end
    end

    out[#out + 1] = { path = t.path, spans = plan }
  end

  return out
end
```

The existing sort is by token index, which for a single source is start order; the test asserting sorted `start` passes because tokens carry monotonic times within one file. Do not add a second sort.

- [ ] **Step 4: Run tests**

```bash
./run_tests.sh
```

Expected: the new `BuildMatch` section PASSES. Existing `BuildPlan` tests FAIL — expected, removed in Task 6.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat(VO): BuildMatch replaces BuildPlan, matching from stored words"
```

---

## Task 4: Silence detection primitives

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — add a new section immediately before `vo.ApplyPadding` (line 892)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.Opt`, `vo.DEFAULTS`
- Produces:
  - `vo.InterWordGaps(words) -> { {from=number, to=number}, ... }`
  - `vo.MeasureNoiseFloor(gaps, probe, cfg) -> number|nil` — dBFS, or `nil` when nothing could be measured
  - `vo.SnapBoundary(from, limit, direction, floor_db, probe, cfg) -> number, "silence"|"pad"`
  - New `vo.DEFAULTS` keys: `snap_boundaries = true`, `snap_min_silence = 0.060`, `snap_floor_offset = 6.0`, `snap_floor_window = 0.500`
- `probe` is always `function(t0, t1) -> number|nil` returning RMS in dBFS for `[t0, t1)`. It is injected so this whole task is pure and testable; the REAPER implementation arrives in Task 7.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo.lua`:

```lua
--------------------------------
-- Silence detection
--------------------------------
print("\nInterWordGaps:")

test("gaps sit between consecutive words", function()
  local gaps = vo.InterWordGaps({
    { t0 = 0.0, t1 = 0.5, text = "a" },
    { t0 = 1.0, t1 = 1.5, text = "b" },
    { t0 = 3.0, t1 = 3.5, text = "c" },
  })
  assert(#gaps == 2, "Expected 2 gaps, got " .. #gaps)
  assert(math.abs(gaps[1].from - 0.5) < 1e-9, "gap 1 from: " .. gaps[1].from)
  assert(math.abs(gaps[1].to   - 1.0) < 1e-9, "gap 1 to: " .. gaps[1].to)
  assert(math.abs(gaps[2].to   - 3.0) < 1e-9, "gap 2 to: " .. gaps[2].to)
end)

test("overlapping or touching words produce no gap", function()
  local gaps = vo.InterWordGaps({
    { t0 = 0.0, t1 = 1.0, text = "a" },
    { t0 = 1.0, t1 = 2.0, text = "b" },
    { t0 = 1.5, t1 = 2.5, text = "c" },
  })
  assert(#gaps == 0, "Expected no gaps, got " .. #gaps)
end)

test("fewer than two words means no gaps", function()
  assert(#vo.InterWordGaps({}) == 0, "empty")
  assert(#vo.InterWordGaps({ { t0 = 0, t1 = 1, text = "a" } }) == 0, "single")
end)

print("\nMeasureNoiseFloor:")

test("the floor is the quietest measurable gap plus the offset", function()
  local gaps = { { from = 0, to = 2 }, { from = 5, to = 7 } }
  local probe = function(t0, _) return t0 < 3 and -50.0 or -70.0 end
  local floor = vo.MeasureNoiseFloor(gaps, probe, { snap_floor_offset = 6.0 })
  assert(floor and math.abs(floor - (-64.0)) < 1e-9, "Floor: " .. tostring(floor))
end)

test("gaps shorter than the window are ignored", function()
  local gaps = { { from = 0, to = 0.01 } }
  local floor = vo.MeasureNoiseFloor(gaps, function() return -70 end,
                                     { snap_floor_window = 0.5 })
  assert(floor == nil, "Expected nil, got " .. tostring(floor))
end)

test("no probe means no floor", function()
  assert(vo.MeasureNoiseFloor({ { from = 0, to = 5 } }, nil, {}) == nil, "Expected nil")
end)

test("a probe that cannot read returns nil rather than a bogus floor", function()
  local floor = vo.MeasureNoiseFloor({ { from = 0, to = 5 } }, function() return nil end, {})
  assert(floor == nil, "Expected nil, got " .. tostring(floor))
end)

print("\nSnapBoundary:")

-- A probe describing one loud region [1.0, 2.0]; everything else is silent.
local function loud_between(a, b)
  return function(t0, t1)
    if t1 > a and t0 < b then return -10.0 end
    return -80.0
  end
end

test("a start boundary walks back into silence and stops there", function()
  local cfg = { snap_min_silence = 0.05 }
  local t, how = vo.SnapBoundary(1.0, 0.5, -1, -60.0, loud_between(1.0, 2.0), cfg)
  assert(how == "silence", "How: " .. tostring(how))
  assert(math.abs(t - 0.95) < 1e-9, "Boundary: " .. tostring(t))
end)

test("a stop boundary walks forward into silence and stops there", function()
  local cfg = { snap_min_silence = 0.05 }
  local t, how = vo.SnapBoundary(2.0, 2.5, 1, -60.0, loud_between(1.0, 2.0), cfg)
  assert(how == "silence", "How: " .. tostring(how))
  assert(math.abs(t - 2.05) < 1e-9, "Boundary: " .. tostring(t))
end)

test("no silence in the window falls back to the limit and says so", function()
  local cfg = { snap_min_silence = 0.05 }
  local t, how = vo.SnapBoundary(2.0, 2.2, 1, -60.0, loud_between(0.0, 10.0), cfg)
  assert(how == "pad", "How: " .. tostring(how))
  assert(math.abs(t - 2.2) < 1e-9, "Boundary: " .. tostring(t))
end)

test("a window shorter than the minimum silence falls back immediately", function()
  local cfg = { snap_min_silence = 0.5 }
  local t, how = vo.SnapBoundary(2.0, 2.1, 1, -60.0, loud_between(0, 0), cfg)
  assert(how == "pad" and math.abs(t - 2.1) < 1e-9, "Got " .. t .. " / " .. how)
end)

test("no probe falls back to the limit", function()
  local t, how = vo.SnapBoundary(2.0, 2.5, 1, -60.0, nil, {})
  assert(how == "pad" and math.abs(t - 2.5) < 1e-9, "Got " .. t .. " / " .. how)
end)

test("the result never crosses the limit, in either direction", function()
  local cfg = { snap_min_silence = 0.05 }
  local quiet = function() return -80.0 end
  local a = vo.SnapBoundary(1.0, 0.5, -1, -60.0, quiet, cfg)
  assert(a >= 0.5 - 1e-9 and a <= 1.0 + 1e-9, "Backward escaped: " .. a)
  local b = vo.SnapBoundary(1.0, 1.5, 1, -60.0, quiet, cfg)
  assert(b >= 1.0 - 1e-9 and b <= 1.5 + 1e-9, "Forward escaped: " .. b)
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./run_tests.sh
```

Expected: FAIL — `attempt to call a nil value (field 'InterWordGaps')`.

- [ ] **Step 3: Implement**

Add these four keys to `vo.DEFAULTS` (line 502), directly after `post_pad`:

```lua
  -- Boundary snapping. pre_pad/post_pad above become the MAXIMUM reach of the
  -- search rather than a fixed amount; the search itself is bounded by the
  -- neighbouring word's timestamp, which is what makes it structurally
  -- impossible for a clip to eat a syllable of the next line.
  snap_boundaries   = true,
  snap_min_silence  = 0.060, -- seconds below the floor needed to place a boundary
  snap_floor_offset = 6.0,   -- dB above the measured noise floor
  snap_floor_window = 0.500, -- seconds of the quietest gap used to measure it
```

Insert a new section immediately before `vo.ApplyPadding` (line 892):

```lua
--------------------------------
-- Pure layer: silence detection
--------------------------------

-- Every function here takes its amplitude readings through an injected
-- `probe(t0, t1) -> dBFS or nil`. Nothing in this section touches REAPER, so
-- the placement rules are unit-testable against a synthetic amplitude curve;
-- the real probe is vo.MakeTakeProbe in the coupled layer.

-- The stretches between consecutive words -- where a boundary is allowed to go.
-- Words that touch or overlap yield nothing: there is no gap to search.
function vo.InterWordGaps(words)
  local out = {}
  for i = 2, #(words or {}) do
    local from, to = words[i - 1].t1 or 0, words[i].t0 or 0
    if to > from then out[#out + 1] = { from = from, to = to } end
  end
  return out
end

-- The room's noise floor, measured rather than assumed: a fixed -60 dBFS is
-- wrong on a noisy room and wrong in the other direction on a clean one.
-- One window is sampled from the middle of each gap long enough to hold it,
-- and the quietest reading plus the offset is the floor.
-- Returns nil when nothing could be measured, which the caller must read as
-- "snapping is unavailable" rather than as a floor of zero.
function vo.MeasureNoiseFloor(gaps, probe, cfg)
  if not probe then return nil end
  local window = vo.Opt(cfg, "snap_floor_window")
  local quietest = nil
  for _, g in ipairs(gaps or {}) do
    if (g.to - g.from) >= window then
      local mid = (g.from + g.to) / 2
      local db  = probe(mid - window / 2, mid + window / 2)
      if db and (not quietest or db < quietest) then quietest = db end
    end
  end
  if not quietest then return nil end
  return quietest + vo.Opt(cfg, "snap_floor_offset")
end

-- Place one boundary between a word edge and a hard limit.
--
--   from      -- the word's own edge, in the same time base as `probe`
--   limit     -- how far the boundary may travel: the neighbouring word's edge,
--                or the pad, whichever is nearer. NEVER exceeded.
--   direction -- -1 searching backwards (a span start), +1 forwards (a stop)
--   floor_db  -- from vo.MeasureNoiseFloor
--   probe     -- amplitude reader, or nil
--
-- Steps outward from the word in `snap_min_silence` windows and stops at the
-- far edge of the first window that is entirely below the floor, so the clip
-- keeps that much silence as head or tail. Falls back to `limit` when there is
-- no probe, no floor, no room, or no silence -- reported as "pad" so the run
-- summary can say why an edge sits where it does.
function vo.SnapBoundary(from, limit, direction, floor_db, probe, cfg)
  local min_sil = vo.Opt(cfg, "snap_min_silence")
  if not probe or not floor_db or min_sil <= 0 then return limit, "pad" end

  local reach = math.abs(limit - from)
  if reach < min_sil then return limit, "pad" end

  local travelled = 0
  while travelled + min_sil <= reach + 1e-9 do
    local near = from + direction * travelled
    local a    = (direction < 0) and (near - min_sil) or near
    local db   = probe(a, a + min_sil)
    if db and db <= floor_db then
      return (direction < 0) and a or (a + min_sil), "silence"
    end
    travelled = travelled + min_sil
  end

  return limit, "pad"
end
```

- [ ] **Step 4: Run tests**

```bash
./run_tests.sh
```

Expected: PASS, including all three new sections.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat(VO): silence detection primitives for boundary snapping"
```

---

## Task 5: Wire snapping into ApplyPadding

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — `vo.ApplyPadding` (line 892, now shifted down by Task 4's insertion) and `vo.AssignNames` (line 974)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.SnapBoundary`, `vo.Opt`
- Produces: `vo.ApplyPadding(spans, cfg, bounds, probe, floor_db)` — two new **optional** trailing parameters. With either absent, behaviour is byte-for-byte what it is today, which is why every existing padding test stays green. With both present and `cfg.snap_boundaries` true, each span gains `snapped = "silence"|"pad"`.
- `vo.AssignNames(spans, cfg)` stops reading `cfg.primary_take` and reads `span.select` instead.
- `vo.DEFAULTS.primary_take` is removed.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo.lua`:

```lua
--------------------------------
-- ApplyPadding with snapping
--------------------------------
print("\nApplyPadding (snapping):")

local function span(a, b) return { start = a, stop = b, kind = "match", asset = "x" } end

test("without a probe the fixed pads are applied exactly as before", function()
  local spans = { span(2.0, 3.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.1, post_pad = 0.2 })
  assert(math.abs(spans[1].start - 1.9) < 1e-9, "start: " .. spans[1].start)
  assert(math.abs(spans[1].stop  - 3.2) < 1e-9, "stop: " .. spans[1].stop)
  assert(spans[1].snapped == nil, "snapped should not be set without a probe")
end)

test("with a probe the boundary lands in silence inside the pad", function()
  local spans = { span(2.0, 3.0) }
  local probe = function(t0, t1) if t1 > 2.0 and t0 < 3.0 then return -10 end return -80 end
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5, snap_min_silence = 0.05 },
                  nil, probe, -60)
  assert(math.abs(spans[1].start - 1.95) < 1e-9, "start: " .. spans[1].start)
  assert(math.abs(spans[1].stop  - 3.05) < 1e-9, "stop: " .. spans[1].stop)
  assert(spans[1].snapped == "silence", "snapped: " .. tostring(spans[1].snapped))
end)

test("a boundary never crosses into the neighbouring word's span", function()
  local spans = { span(2.0, 3.0), span(3.1, 4.0) }
  local probe = function() return -80 end  -- silent everywhere: maximum temptation
  vo.ApplyPadding(spans, { pre_pad = 1.0, post_pad = 1.0, snap_min_silence = 0.02 },
                  nil, probe, -60)
  assert(spans[1].stop <= 3.1 + 1e-9, "span 1 stop ate into span 2: " .. spans[1].stop)
  assert(spans[2].start >= 3.0 - 1e-9, "span 2 start ate into span 1: " .. spans[2].start)
  assert(spans[1].stop <= spans[2].start + 1e-9, "spans overlap after snapping")
end)

test("no silence found is reported as pad, not silence", function()
  local spans = { span(2.0, 3.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.2, post_pad = 0.2, snap_min_silence = 0.05 },
                  nil, function() return -10 end, -60)
  assert(spans[1].snapped == "pad", "snapped: " .. tostring(spans[1].snapped))
  assert(math.abs(spans[1].stop - 3.2) < 1e-9, "stop should fall back to the pad")
end)

test("snap_boundaries = false ignores the probe entirely", function()
  local spans = { span(2.0, 3.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.5, snap_boundaries = false },
                  nil, function() return -80 end, -60)
  assert(math.abs(spans[1].start - 1.5) < 1e-9, "start: " .. spans[1].start)
  assert(spans[1].snapped == nil, "snapped should not be set when disabled")
end)

test("bounds still clamp a snapped boundary", function()
  local spans = { span(0.1, 1.0) }
  vo.ApplyPadding(spans, { pre_pad = 0.5, post_pad = 0.1, snap_min_silence = 0.02 },
                  { start = 0.0, stop = 10.0 }, function() return -80 end, -60)
  assert(spans[1].start >= 0.0 - 1e-9, "start escaped bounds: " .. spans[1].start)
end)

print("\nAssignNames (select-driven):")

test("the selected take is primary and carries the bare asset name", function()
  local spans = {
    { start = 1, stop = 2, kind = "match", asset = "vo_a", transcript = "x" },
    { start = 3, stop = 4, kind = "match", asset = "vo_a", transcript = "y", select = true },
  }
  vo.AssignNames(spans, { suffix_alt_names = true })
  assert(spans[2].primary == true, "The selected span should be primary")
  assert(spans[2].name == "vo_a", "Primary name: " .. tostring(spans[2].name))
  assert(spans[1].primary ~= true, "The unselected span should not be primary")
  assert(spans[1].name ~= "vo_a", "Non-primary should be suffixed, got " .. tostring(spans[1].name))
end)

test("with no select, no take of that line is primary", function()
  local spans = {
    { start = 1, stop = 2, kind = "match", asset = "vo_a", transcript = "x" },
    { start = 3, stop = 4, kind = "match", asset = "vo_a", transcript = "y" },
  }
  vo.AssignNames(spans, {})
  assert(spans[1].primary ~= true and spans[2].primary ~= true,
         "Nothing should be primary without a select")
end)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
./run_tests.sh
```

Expected: the snapping tests FAIL (`snapped` is nil, boundaries at the fixed pad), and the `AssignNames` tests FAIL (`primary` still comes from `primary_take`).

- [ ] **Step 3: Implement**

In `vo.ApplyPadding`, replace the signature and the first loop. The current body is:

```lua
function vo.ApplyPadding(spans, cfg, bounds)
  local pre  = vo.Opt(cfg, "pre_pad")
  local post = vo.Opt(cfg, "post_pad")

  for _, s in ipairs(spans) do
    s.raw_start, s.raw_stop = s.start, s.stop
    s.start = s.start - pre
    s.stop  = s.stop + post
  end
```

Replace exactly that portion with:

```lua
function vo.ApplyPadding(spans, cfg, bounds, probe, floor_db)
  local pre  = vo.Opt(cfg, "pre_pad")
  local post = vo.Opt(cfg, "post_pad")
  local snap = vo.Opt(cfg, "snap_boundaries") and probe and floor_db

  for _, s in ipairs(spans) do s.raw_start, s.raw_stop = s.start, s.stop end

  for i, s in ipairs(spans) do
    if snap then
      -- The search window is bounded by the NEIGHBOURING WORD, not by the
      -- neighbour's already-padded edge: raw boundaries are the only ones that
      -- describe where audio actually is. This bound is what makes it
      -- structurally impossible for a clip to contain a syllable of the next
      -- line, whatever the amplitude does inside the window.
      local start_limit = s.raw_start - pre
      if spans[i - 1] then start_limit = math.max(start_limit, spans[i - 1].raw_stop) end
      local stop_limit = s.raw_stop + post
      if spans[i + 1] then stop_limit = math.min(stop_limit, spans[i + 1].raw_start) end

      local a, how_a = vo.SnapBoundary(s.raw_start, start_limit, -1, floor_db, probe, cfg)
      local b, how_b = vo.SnapBoundary(s.raw_stop,  stop_limit,   1, floor_db, probe, cfg)
      s.start, s.stop = a, b
      s.snapped = (how_a == "silence" and how_b == "silence") and "silence" or "pad"
    else
      s.start = s.raw_start - pre
      s.stop  = s.raw_stop + post
    end
  end
```

Everything below that point — the neighbour midpoint clamp, `clamp_to_bounds`, and the degenerate fallback — stays exactly as it is. It is harmless for snapped spans (which already respect their neighbours) and it is the tested safety net for the unsnapped path.

Next, in `vo.AssignNames` (line 974), remove the `primary_take` read:

```lua
  local primary_take     = vo.Opt(cfg, "primary_take")
```

Delete that line. Then find where the primary is chosen within each asset group — search for `primary_take` in the function body — and replace the "first or last" selection with:

```lua
    -- The user's explicit Select IS the primary. Guessing "first" or "last" is
    -- what the Select column exists to stop; a group with no select simply has
    -- no primary, and Cut reports it as needing a decision.
    local primary = nil
    for _, s in ipairs(group) do
      if s.select == true then primary = s; break end
    end
    for _, s in ipairs(group) do s.primary = (s == primary) end
```

Adapt the surrounding variable names to whatever the existing loop uses (`group` here stands for the per-asset span list the function already builds). Keep the existing total-order sort and the existing take numbering — only the primary choice changes.

Finally, remove `primary_take = "last",` from `vo.DEFAULTS` (line 515) and delete the `{ key = "primary_take", ... }` entry from the config field list near line 2468.

- [ ] **Step 4: Run tests**

```bash
./run_tests.sh
```

Expected: PASS. Existing `AssignNames` tests that set `cfg.primary_take` will fail — update them to set `span.select` instead. Do not add a `primary_take` fallback to make them pass.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat(VO): snap clip boundaries to silence, bounded by neighbouring words"
```

---

## Task 6: Delete the superseded formats

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua`
- Modify: `tests/test_vo.lua`

**Interfaces:**
- Consumes: nothing
- Produces: nothing. This task only removes.

Delete these functions and their constants entirely:

| Symbol | Location (pre-Task-1 line numbers) |
|---|---|
| `vo.SIDECAR_MARKER`, `vo.SIDECAR_VERSION`, `vo.SIDECAR_HEADER`, `vo.SIDECAR_TAIL_MARKER` | 1279–1288 |
| `vo.SerializeSidecar` | 1314 |
| `vo.ParseSidecar` | 1370 |
| `vo.PartitionPlanBySource` | 1434 |
| `vo.SpansBySourcePath` | 1460 |
| `vo.MergeSidecarSpans` | 1497 |
| `vo.SidecarPath` | 1639 |
| `vo.TRACKER_MARKER`, `vo.TRACKER_VERSION`, `vo.TRACKER_HEADER` | 1702–1708 |

**Keep:** `encode_mapping`, `decode_mapping` (used by Task 2), `strip_ext`, `fold`, `vo.TRACKER_STATUSES`, `vo.TRACKER_REMATCH_TOLERANCE`, `vo.OverviewKey`, `index_tracker`, `resolve_tracker`, `vo.SourceCoverageRanges`, `vo.ProjectTimeToSource`, `vo.SourceTimeToProject`.

`vo.SourceCoverageRanges` loses its only caller here but is kept: Task 12 uses it to decide which spans a given item can actually play.

- [ ] **Step 1: Delete the functions**

Remove each symbol in the table above. After each removal, confirm nothing still references it:

```bash
grep -rn "SerializeSidecar\|ParseSidecar\|PartitionPlanBySource\|SpansBySourcePath\|MergeSidecarSpans\|SidecarPath\|SIDECAR_\|TRACKER_MARKER\|TRACKER_VERSION\|TRACKER_HEADER\|SerializeTracker\|ParseTracker\|TrackerPath\|BuildPlan\|primary_take" VO/ tests/
```

Expected after this step: hits only in `VO/ajsfx_VO_ScriptMatch.lua` and `VO/ajsfx_VO_Overview.lua`, which are rewritten in Tasks 10–14. Zero hits in `VO/lib/ajsfx_vo.lua` and zero in `tests/`.

- [ ] **Step 2: Delete the orphaned tests**

In `tests/test_vo.lua`, delete every `test(...)` block inside these sections: `SerializeSidecar`, `ParseSidecar`, `PartitionPlanBySource`, `SpansBySourcePath`, `MergeSidecarSpans`, `SidecarPath`, `SerializeTracker`, `ParseTracker`, `TrackerPath`, `BuildPlan`. Delete their `print(...)` section headers too.

Do **not** delete: `OverviewKey`, `BuildOverview`, `SourceCoverageRanges`, `ProjectTimeToSource`, `SourceTimeToProject`, `ApplyPadding`, `AssignNames`, or anything about matching.

- [ ] **Step 3: Run tests**

```bash
./run_tests.sh
```

Expected: PASS with no failures and no `nil value` errors.

- [ ] **Step 4: Verify no dead references remain in the library**

```bash
grep -c "Sidecar\|Tracker\|BuildPlan" VO/lib/ajsfx_vo.lua
```

Expected: a small number, all of them inside comments referring to `vo.TRACKER_STATUSES` / `vo.TRACKER_REMATCH_TOLERANCE` / `index_tracker` / `resolve_tracker`. Read each hit and confirm it is not a call.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "refactor(VO): delete the report sidecar and tracker formats"
```

---

## Task 7: Coupled helpers — transcript IO, sibling launch, audio probe

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — the coupled layer, after `vo.TranscribeSources` (line 3126)

**Interfaces:**
- Consumes: `vo.TranscriptPath`, `vo.ParseTranscript`, `vo.SerializeTranscript`, `vo.FileSize`, `vo.FileExists`, `vo.SourceTimeToProject`
- Produces:
  - `vo.ReadTranscript(source_path) -> table|nil, string` — parsed transcript, or `nil, reason`. `reason` distinguishes "no transcript" from "unreadable transcript".
  - `vo.WriteTranscript(source_path, words, meta) -> boolean, string` — `false, reason` on write failure (read-only media directory).
  - `vo.TranscriptState(source_path) -> "yes"|"no"|"stale"|"error", table|nil, string|nil` — the status Sources shows, the parsed transcript when there is one, and a reason when `error`.
  - `vo.LaunchSibling(filename) -> boolean, string` — launches a script in the same directory as `ajsfx_vo.lua`'s parent.
  - `vo.MakeTakeProbe(take) -> probe|nil, destroy` — `probe(t0, t1)` takes **project time** and returns RMS in dBFS, or `nil` when the window is unreadable. Always call `destroy()`.

These are coupled to REAPER and are not unit-tested; they are verified in the manual test list in Task 14.

- [ ] **Step 1: Implement transcript IO**

Add after `vo.TranscribeSources` ends (line 3126):

```lua
--------------------------------
-- Coupled layer: transcript files
--------------------------------

function vo.ReadTranscript(source_path)
  local path = vo.TranscriptPath(source_path)
  if not path then return nil, "No source path." end
  local f = io.open(path, "r")
  if not f then return nil, "no transcript" end
  local text = f:read("a")
  f:close()
  return vo.ParseTranscript(text)
end

-- Returns false plus a reason rather than raising: a read-only or network media
-- directory must leave the session usable, just not persistent.
function vo.WriteTranscript(source_path, words, meta)
  local path = vo.TranscriptPath(source_path)
  if not path then return false, "No source path." end
  local f, err = io.open(path, "w")
  if not f then return false, tostring(err or ("Could not write " .. path)) end
  f:write(vo.SerializeTranscript(words, meta))
  f:close()
  return true, path
end

-- What Sources puts in its Transcribed column.
--   "no"    -- no transcript file beside the audio
--   "error" -- a file is there but could not be parsed; reason says why
--   "stale" -- parsed, but the audio has changed size since it was made
--   "yes"   -- parsed and current
function vo.TranscriptState(source_path)
  local parsed, why = vo.ReadTranscript(source_path)
  if not parsed then
    if why == "no transcript" then return "no" end
    return "error", nil, why
  end
  local size = vo.FileSize(source_path)
  if size and parsed.source_bytes and parsed.source_bytes > 0
     and size ~= parsed.source_bytes then
    return "stale", parsed
  end
  return "yes", parsed
end
```

- [ ] **Step 2: Implement the sibling launcher**

Add immediately after:

```lua
--------------------------------
-- Coupled layer: launching sibling scripts
--------------------------------

-- AddRemoveReaScript is idempotent: it returns the EXISTING command ID when the
-- script is already in the action list, so this both installs and launches. A
-- hardcoded _RS… command ID would be machine-local and is never used.
--
-- `filename` is a sibling of the VO scripts, i.e. one level above lib/.
function vo.LaunchSibling(filename)
  local here = debug.getinfo(1, "S").source:match("@?(.*[\\/])")
  if not here then return false, "Could not resolve the script directory." end
  local path = here .. "../" .. filename
  local id = r.AddRemoveReaScript(true, 0, path, true)
  if not id or id == 0 then
    return false, "Could not register " .. filename .. " as an action."
  end
  r.Main_OnCommand(id, 0)
  return true, path
end
```

- [ ] **Step 3: Implement the audio probe**

Add immediately after:

```lua
--------------------------------
-- Coupled layer: amplitude probing
--------------------------------

vo.PROBE_FLOOR_DB = -150.0  -- what digital silence reports as, instead of -inf

-- An amplitude reader over one take, for vo.SnapBoundary and
-- vo.MeasureNoiseFloor. Times are PROJECT time, matching the accessor's own
-- base -- convert source times with vo.SourceTimeToProject before probing.
--
-- Returns the probe and a destroy function. ALWAYS call destroy, including on
-- the error path: an undestroyed accessor holds the media file open.
function vo.MakeTakeProbe(take)
  if not take or not r.CreateTakeAudioAccessor then return nil, function() end end
  local acc = r.CreateTakeAudioAccessor(take)
  if not acc then return nil, function() end end

  local source = r.GetMediaItemTake_Source(take)
  local rate   = source and r.GetMediaSourceSampleRate(source) or 48000
  if not rate or rate <= 0 then rate = 48000 end
  local chans  = source and r.GetMediaSourceNumChannels(source) or 1
  if not chans or chans < 1 then chans = 1 end

  local function probe(t0, t1)
    local n = math.floor((t1 - t0) * rate)
    if n < 1 then return nil end
    -- Cap the read so a pathological window cannot allocate without bound.
    if n > 65536 then n = 65536 end
    local buf = r.new_array(n * chans)
    buf.clear()
    local ok = r.GetAudioAccessorSamples(acc, rate, chans, t0, n, buf)
    if ok ~= 1 then return nil end
    local sum = 0.0
    for i = 1, n * chans do
      local v = buf[i] or 0.0
      sum = sum + v * v
    end
    local rms = math.sqrt(sum / (n * chans))
    if rms <= 0 then return vo.PROBE_FLOOR_DB end
    return 20.0 * math.log(rms, 10)
  end

  return probe, function() r.DestroyAudioAccessor(acc) end
end
```

- [ ] **Step 4: Syntax-check the library**

```bash
luac -p VO/lib/ajsfx_vo.lua || lua -e "assert(loadfile('VO/lib/ajsfx_vo.lua'))"
```

Expected: no output (success).

- [ ] **Step 5: Run tests and commit**

```bash
./run_tests.sh
```

Expected: PASS — these functions have no unit tests, but the module must still load cleanly under the mock.

```bash
git add VO/lib/ajsfx_vo.lua && git commit -m "feat(VO): transcript IO, sibling launch and take amplitude probe"
```

---

## Task 8: VO Sources — the file list

**Files:**
- Create: `VO/ajsfx_VO_Sources.lua`

**Interfaces:**
- Consumes: `vo.CollectProjectSpans`, `vo.ProjectSourcePaths`, `vo.TranscriptState`, `vo.WriteTranscript`, `vo.TranscribeSources`, `vo.IsBackendReady`, `vo.LoadConfig`, `vo.FileSize`, `vo.LaunchSibling`, `view` (`lib/ajsfx_vo_view.lua`)
- Produces: a `[main]` script. Task 9 adds the detail panel to it; Task 11 relies on it honouring `ExtState("ajsfx_vo", "focus_source")`.

- [ ] **Step 1: Write the script**

Model the file's skeleton on `VO/ajsfx_VO_Overview.lua` lines 1–60: the same `@noindex` header, the same `package.path` bootstrap, the same ReaImGui `pcall` guard and `Api()` accessor. Copy that block verbatim, changing only the description comment.

Header:

```lua
-- @noindex
-- Provided by the ajsfx VO package; see ajsfx_VO_Overview.lua's @provides.
--
-- ajsfx VO Sources — one row per recorded source file in the project, and
-- whether it has been transcribed.
--
-- This script owns transcription and nothing else. It does not read the script
-- CSV, does not match, and does not cut: a transcript is a fact about a wav
-- file, and this is the window where that fact gets made.
-- See VO/SPEC-sources.md.
```

State and frame loop:

```lua
local PROJ_SECTION = "ajsfx_vo"

local state = {
  rows      = {},     -- { path, name, status, transcript, words, length, items, reason }
  selected  = {},     -- [path] = true
  scanned_at = -1,    -- GetProjectStateChangeCount when rows were built
  message   = nil,    -- { text, tone = "info"|"warn"|"error" }
  running   = false,
  progress  = nil,
  detail    = nil,    -- path of the row whose detail panel is open (Task 9)
  cfg       = vo.LoadConfig(),
  backend   = nil,    -- { ready = bool, reason = string }
}
```

Rebuild rows when `r.GetProjectStateChangeCount(0)` differs from `state.scanned_at` (CLAUDE.md: this is the cache-invalidation signal). Building a row:

```lua
local function BuildRows()
  local items = vo.CollectProjectSpans()
  local counts = {}
  for _, it in ipairs(items) do
    if it.path then counts[it.path] = (counts[it.path] or 0) + 1 end
  end

  local rows = {}
  for _, path in ipairs(vo.ProjectSourcePaths(items)) do
    local status, parsed, why = vo.TranscriptState(path)
    rows[#rows + 1] = {
      path       = path,
      name       = path:match("([^\\/]+)$") or path,
      status     = status,
      transcript = parsed,
      words      = parsed and #parsed.words or 0,
      model      = parsed and parsed.model or "",
      items      = counts[path] or 0,
      reason     = why,
    }
  end
  table.sort(rows, function(a, b) return a.name:lower() < b.name:lower() end)
  return rows
end
```

`vo.TranscriptState` stats a file on disk, so gate `BuildRows` on the project-change count — never call it per frame.

Columns, drawn with `im.BeginTable` and the existing `view` helper: **File**, **Transcribed**, **Words**, **Model**, **Items**. Colour the Transcribed cell: `yes` green, `no` neutral, `stale` amber, `error` red with the reason on hover.

Row selection: click toggles `state.selected[path]`; `im.Selectable` with `im.SelectableFlags_SpanAllColumns()`. Shift-click extends, matching Overview's existing selection idiom.

The Transcribe button:

```lua
local function SelectedPaths()
  local out = {}
  for _, row in ipairs(state.rows) do
    if state.selected[row.path] then out[#out + 1] = row end
  end
  return out
end

-- "Re-transcribe" only when EVERY selected row is already current. A stale row
-- is not "already transcribed": its timings are exactly what needs redoing.
local function TranscribeLabel(rows)
  if #rows == 0 then return "Transcribe" end
  for _, row in ipairs(rows) do
    if row.status ~= "yes" then return "Transcribe" end
  end
  return "Re-transcribe"
end
```

**Batch is the normal case, not the exception.** A project where every line was
recorded to its own file means 50+ rows, so the list must make a large run easy
to start and safe to interrupt:

- **Select all** and **Select untranscribed** buttons above the table, plus a
  text filter box that narrows by filename. Shift-click extends a range;
  Ctrl/Cmd-click toggles one row.
- The Transcribe button names the count: `Transcribe 47 files`.
- **Progress is per file**: `Transcribing 12 of 47 — RIVA_line_012.wav`, with
  the elapsed count visible. The row being worked on is highlighted.
- **Each transcript is written the moment its file finishes**, via
  `vo.TranscribeSources`'s `on_source` callback (`ajsfx_vo.lua`). Never
  accumulate and write at the end — a cancel at file 40 would throw away 39
  completed whisper runs.
- **One bad file does not stop the batch.** `vo.TranscribeSources` collects
  failures and continues; `on_done(results, failures)` reports them together.
  List the failed filenames inline with their reasons, and leave every other
  row transcribed.
- **Cancel stops the run** and keeps everything already written.
- Already-transcribed rows are skipped unless the run is a re-transcribe, so
  re-running a batch after fixing two files costs two files, not fifty.

Running a transcription:

```lua
local function RunTranscribe(rows, force)
  local sources, size_of = {}, {}
  for _, row in ipairs(rows) do
    local size = vo.FileSize(row.path) or 0
    size_of[row.path] = size
    sources[#sources + 1] = { path = row.path, size = size }
  end
  if #sources == 0 then return end

  local cfg = {}
  for k, v in pairs(state.cfg) do cfg[k] = v end
  cfg.force_retranscribe = force

  state.running   = true
  state.progress  = { done = 0, total = #sources, current = nil }
  state.write_fails = {}

  vo.TranscribeSources(cfg, sources, {
    -- Written per file, as each finishes. A cancel at file 40 of 47 must not
    -- discard 39 completed whisper runs.
    on_source = function(path, words, i, total)
      local ok, why = vo.WriteTranscript(path, words, {
        source       = path:match("([^\\/]+)$") or path,
        source_bytes = size_of[path] or 0,
        backend      = "whisper.cpp",
        model        = cfg.whisper_model or "",
        language     = cfg.whisper_language or "",
      })
      if not ok then
        state.write_fails[#state.write_fails + 1] = (path .. ": " .. tostring(why))
      end
      state.progress = { done = i, total = total, current = path }
      state.scanned_at = -1   -- rescan so the row's column flips as it lands
    end,

    on_done = function(results, failures)
      state.running    = false
      state.progress   = nil
      state.scanned_at = -1
      local done = 0
      for _ in pairs(results) do done = done + 1 end

      local lines = { string.format("Transcribed %d of %d file(s).", done, #sources) }
      for _, f in ipairs(failures or {}) do
        lines[#lines + 1] = (f.path:match("([^\\/]+)$") or f.path) .. ": " .. f.reason
      end
      for _, w in ipairs(state.write_fails) do lines[#lines + 1] = w end

      local tone = "info"
      if #(failures or {}) > 0 or #state.write_fails > 0 then tone = "warn" end
      state.message = { text = table.concat(lines, "\n"), tone = tone }
    end,

    on_cancel = function()
      state.running  = false
      state.progress = nil
      state.scanned_at = -1
      state.message = { text = "Cancelled. Files already transcribed were kept.",
                        tone = "info" }
    end,

    on_error = function(err)
      state.running  = false
      state.progress = nil
      state.message  = { text = err, tone = "error" }
    end,
  })
end
```

Note the callback table: `vo.TranscribeSources(cfg, sources, cb)` takes one
table, not four positional functions. Per-source failures arrive through
`on_done`'s second argument, never through `on_error`.

Backend readiness: re-evaluate `vo.IsBackendReady(state.cfg)` on a throttle, not per frame — copy the throttle pattern from `ajsfx_VO_ScriptMatch.lua` (search for `IsBackendReady` there). When not ready, disable Transcribe and draw an inline red line with the reason plus a `Settings…` button calling `vo.LaunchSibling("ajsfx_VO_Settings.lua")`.

**No message boxes anywhere in this script** except the ReaImGui-missing guard at the top, which has nowhere else to go.

- [ ] **Step 2: Syntax-check**

```bash
lua -e "assert(loadfile('VO/ajsfx_VO_Sources.lua'))"
```

Expected: no output.

- [ ] **Step 3: Manual test in REAPER**

1. Open a project with two recorded wavs, neither transcribed. Run the script from the Actions list.
2. Confirm two rows, both `no`, with the correct item counts.
3. Select one, press Transcribe. Confirm progress appears, then `<audio>_vo_transcript.csv` exists beside the wav and the row flips to `yes` with a non-zero word count.
4. Select the transcribed row alone; confirm the button reads `Re-transcribe`.
5. Select both; confirm it reads `Transcribe`.
6. Re-record over the transcribed wav so its size changes; confirm the row reads `stale`.
7. **Batch:** open a project with 50+ one-line-per-file wavs. Press
   `Select untranscribed`, then Transcribe. Confirm the progress line counts
   `n of N` and names the current file, and that transcript files appear
   beside the audio *as the run proceeds*, not all at the end.
8. **Batch cancel:** cancel a 50-file run partway. Confirm the files already
   done keep their transcripts and their rows read `yes`, and re-running
   transcribes only the remainder.
9. **Batch with a bad file:** put an unreadable/zero-byte wav in the middle of
   the selection. Confirm the run completes, that file is listed by name with
   its reason, and every other file still transcribed.

- [ ] **Step 4: Commit**

```bash
git add VO/ajsfx_VO_Sources.lua && git commit -m "feat(VO): Sources window lists project audio and its transcription state"
```

---

## Task 9: VO Sources — the per-file detail panel

**Files:**
- Modify: `VO/ajsfx_VO_Sources.lua`

**Interfaces:**
- Consumes: `state.rows` from Task 8, `vo.CollectProjectSpans`, `vo.SourceTimeToProject`
- Produces: `state.detail` is honoured; the panel is what `focus_source` (Task 11) opens onto.

- [ ] **Step 1: Add double-click detection**

On the row's `im.Selectable`, after the click handling:

```lua
if im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, 0) then
  state.detail = (state.detail == row.path) and nil or row.path
end
```

- [ ] **Step 2: Add the panel**

Draw below the table, inside `im.BeginChild(ctx, "detail", 0, 0, 1)`, when `state.detail` names a row:

- **Preamble block:** Source, Source bytes, Backend, Model, Language, word count — one `im.Text` line each, from `row.transcript`.
- **Transcript text:** reassemble words per the spec's display rule:

```lua
-- Display only. Nothing here is stored, and matching never sees it: `-ml 1`
-- destroyed whisper's own sentence grouping, and the SCRIPT is what says where
-- lines divide anyway.
local function Paragraphs(words)
  local paras, current = {}, {}
  for _, w in ipairs(words or {}) do
    current[#current + 1] = w.text
    if w.text:match("[%.%?%!]['\"]?$") then
      paras[#paras + 1] = table.concat(current, " ")
      current = {}
    end
  end
  if #current > 0 then paras[#paras + 1] = table.concat(current, " ") end
  return paras
end
```

Draw each paragraph with `im.TextWrapped`.

- **Per-word interaction:** draw the words of the focused paragraph as individual `im.Selectable` / `im.SmallButton` items on a wrapped line (`im.SameLine` + width check). Hovering shows `im.SetTooltip(ctx, string.format("%.3f – %.3f s", w.t0, w.t1))`. Clicking moves the edit cursor:

```lua
local function GoToWord(source_path, t)
  for _, it in ipairs(vo.CollectProjectSpans()) do
    if it.path == source_path then
      r.SetEditCurPos(vo.SourceTimeToProject(t, it), true, false)
      return true
    end
  end
  return false
end
```

The first item referencing the source is used. `SetEditCurPos(pos, moveview, seekplay)` with `moveview = true` scrolls the arrange view to it.

- **`Re-transcribe this file` button** calling `RunTranscribe({ row }, true)`.
- **Close button** setting `state.detail = nil`.

For a `no` row the panel shows only the filename and the Transcribe button. For an `error` row it shows the parse reason in red and the path of the offending file, so the user can go delete it.

- [ ] **Step 3: Syntax-check**

```bash
lua -e "assert(loadfile('VO/ajsfx_VO_Sources.lua'))"
```

- [ ] **Step 4: Manual test in REAPER**

1. Double-click a transcribed row; confirm the panel opens with the preamble and readable prose broken into sentences.
2. Hover a word; confirm the timing tooltip.
3. Click a word; confirm the edit cursor lands on that word in the arrange view and the view scrolls to it.
4. Press `Re-transcribe this file`; confirm whisper actually re-runs (it must not hit the scratch cache) and the panel refreshes.
5. Double-click the same row again; confirm the panel closes.
6. Hand-corrupt a transcript file (delete its first line) and reopen; confirm the row reads `error`, the panel names the reason, and no window failed to open.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Sources.lua && git commit -m "feat(VO): per-file transcript detail panel in Sources"
```

---

## Task 10: Overview — project file and live matching

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`
- Modify: `VO/lib/ajsfx_vo.lua` — `vo.BuildOverview` input field rename and primary handling

**Interfaces:**
- Consumes: `vo.BuildMatch`, `vo.ReadTranscript`, `vo.ParseProjectFile`, `vo.SerializeProjectFile`, `vo.ProjectFilePath`, `vo.BuildScriptLines`
- Produces: Overview reads and writes `<project>_vo.csv`; the `Select` column; `vo.BuildOverview(input)` where `input.matches` replaces `input.sidecars` and `input.tracker` becomes `input.entries`.

- [ ] **Step 1: Rename BuildOverview's inputs**

In `vo.BuildOverview` (line 1924), rename:
- `input.sidecars` → `input.matches` (same shape: `{ {path, spans}, ... }`)
- `input.tracker` → `input.entries` (the `entries` array from `vo.ParseProjectFile`)

Replace the `first_is_primary` logic with the `select` flag: a row's `primary` is `true` when its resolved project-file entry has `select == true`. Remove the `vo.Opt(input.cfg, "primary_take")` read entirely.

Update the existing `BuildOverview` tests in `tests/test_vo.lua` for the renamed fields and the select-driven primary. Run:

```bash
./run_tests.sh
```

Expected: PASS.

- [ ] **Step 2: Replace sidecar loading with transcript loading + matching**

In `ajsfx_VO_Overview.lua`, find where it loads sidecars (search for `ParseSidecar`). Replace with:

```lua
-- Matching is DERIVED, never stored. It is recomputed when the script, the
-- mapping, or the set of transcripts changes -- and memoised on exactly those
-- inputs, because it is linear in the project's whole word count and the frame
-- loop must not pay for it.
local function MatchKey(paths, script_csv, mapping)
  local parts = { script_csv or "", vo.SerializeLayout(mapping or {}) }
  for _, p in ipairs(paths) do
    parts[#parts + 1] = p .. ":" .. tostring(vo.FileSize(p) or 0)
  end
  return table.concat(parts, "|")
end

local function LoadMatches()
  local items = vo.CollectProjectSpans()
  local paths = vo.ProjectSourcePaths(items)
  local key   = MatchKey(paths, state.script_csv, state.mapping)
  if key == state.match_key then return state.matches end

  local transcripts = {}
  for _, path in ipairs(paths) do
    local parsed = vo.ReadTranscript(path)
    if parsed then transcripts[#transcripts + 1] = { path = path, words = parsed.words } end
  end

  state.matches   = vo.BuildMatch(transcripts, state.lines or {}, state.cfg)
  state.match_key = key
  return state.matches
end
```

`vo.FileSize` is in the key so a re-transcription invalidates it without any staleness bookkeeping in this window.

- [ ] **Step 3: Replace tracker IO with project-file IO**

Find every `vo.TrackerPath` / `vo.ParseTracker` / `vo.SerializeTracker` call and replace with the project-file equivalents. The load path additionally sets `state.script_csv` and `state.mapping` from the parsed preamble, replacing the `ProjExtState` reads at lines 53–55 and 234.

Save path:

```lua
local function SaveProjectFile()
  if state.parse_failed then
    state.message = { text = "The project file could not be read, so it will not be "
                             .. "overwritten. Fix or delete it first:\n" .. tostring(state.project_path),
                      tone = "error" }
    return false
  end
  local path = vo.ProjectFilePath(ProjectPath())
  if not path then
    state.message = { text = "Save the project before marking anything — the VO project "
                             .. "file lives beside it.", tone = "warn" }
    return false
  end
  local f, err = io.open(path, "w")
  if not f then
    state.message = { text = tostring(err), tone = "error" }
    return false
  end
  f:write(vo.SerializeProjectFile(vo.TrackerEntriesFromRows(state.rows),
                                  { script_csv = state.script_csv, mapping = state.mapping }))
  f:close()
  return true
end
```

`state.parse_failed` is set when `vo.ParseProjectFile` returned `nil` — refusing to save over unreadable user work is the rule from `SPEC-overview.md` §2, and it now also protects the script path and mapping.

Update `vo.TrackerEntriesFromRows` (line 2065) to emit the new entry shape: `select` instead of `primary`, and keep `status`, `name_override`, `notes`, `key`, `asset`, `source`, `source_start`.

`ProjectPath()` is the existing helper in Overview that returns the `.rpp` path; if it does not exist, add it using `r.GetProjectPath` / `r.EnumProjects(-1, "")`.

- [ ] **Step 4: Add the Select column**

Add `{ key = "select", label = "Select", width = 60 }` to the column list at line 88, replacing the existing `primary` column entry. Draw it as `im.Checkbox`; toggling sets `row.select` and marks the state dirty so the autosave path writes it.

Keep the existing Status column (verified / flagged) exactly as it is.

- [ ] **Step 5: Manual test in REAPER**

1. Open Overview on a project with two transcribed wavs and a script CSV loaded. Confirm statuses populate with no whisper run.
2. Load a *different* script CSV. Confirm statuses re-derive immediately, still no whisper run, no staleness warning.
3. Tick Select on a take, close and reopen Overview. Confirm the tick survives and `<project>_vo.csv` contains the row.
4. Add a note to a **Missing** line (one with no audio). Confirm it saves and returns, with an empty Source cell.
5. Hand-corrupt `<project>_vo.csv`; confirm Overview opens, says it cannot read the file, and refuses to save.

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "feat(VO): Overview derives matches live and owns the project file"
```

---

## Task 11: Overview — Sources and Cut entry points

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`
- Modify: `VO/ajsfx_VO_Sources.lua`

**Interfaces:**
- Consumes: `vo.LaunchSibling`
- Produces: the `focus_source` handoff contract, consumed by Sources

- [ ] **Step 1: Add the top-bar buttons**

In Overview's top bar, beside the existing Settings button:

```lua
if im.Button(ctx, "Sources…") then
  local ok, why = vo.LaunchSibling("ajsfx_VO_Sources.lua")
  if not ok then state.message = { text = why, tone = "error" } end
end
im.SameLine(ctx)
if im.Button(ctx, "Cut…") then
  local ok, why = vo.LaunchSibling("ajsfx_VO_Cut.lua")
  if not ok then state.message = { text = why, tone = "error" } end
end
```

- [ ] **Step 2: Add the Source-cell double-click**

Where the `source` column cell is drawn, after the text:

```lua
if im.IsItemHovered(ctx) and im.IsMouseDoubleClicked(ctx, 0) and row.source_path then
  -- Written before the launch and read every frame by Sources, so an ALREADY
  -- OPEN Sources window picks it up too rather than only a freshly launched one.
  r.SetExtState(PROJ_SECTION, "focus_source", row.source_path, false)
  local ok, why = vo.LaunchSibling("ajsfx_VO_Sources.lua")
  if not ok then state.message = { text = why, tone = "error" } end
end
```

The cell needs to be an item for `IsItemHovered` to work — wrap the text in `im.Selectable` with `im.SelectableFlags_AllowDoubleClick()` if it is currently plain `im.Text`.

- [ ] **Step 3: Consume it in Sources**

In `ajsfx_VO_Sources.lua`'s frame loop, before drawing:

```lua
-- Read every frame, not once at launch: Overview may hand off to a Sources
-- window that is already open.
local focus = r.GetExtState(PROJ_SECTION, "focus_source")
if focus ~= "" then
  r.DeleteExtState(PROJ_SECTION, "focus_source", false)
  for _, row in ipairs(state.rows) do
    if row.path == focus then
      state.selected = { [focus] = true }
      state.detail   = focus
      state.scroll_to = focus
      break
    end
  end
end
```

When `state.scroll_to` matches the row being drawn, call `im.SetScrollHereY(ctx, 0.5)` and clear it.

- [ ] **Step 4: Manual test in REAPER**

1. From Overview press `Sources…`; confirm the Sources window opens.
2. Press it again with Sources already open; confirm nothing breaks and no duplicate action is registered (check the Actions list contains one `ajsfx_VO_Sources` entry).
3. Double-click a Source cell in Overview; confirm Sources opens with that row selected, scrolled into view, and its detail panel open.
4. With Sources already open, double-click a *different* Source cell in Overview; confirm the open window switches rows.
5. Press `Cut…`; confirm the Cut window opens (it exists after Task 12 — until then confirm the error line names the missing file rather than crashing).

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua VO/ajsfx_VO_Sources.lua && git commit -m "feat(VO): Overview opens Sources and Cut, and focuses a source on double-click"
```

---

## Task 12: VO Cut

**Files:**
- Create: `VO/ajsfx_VO_Cut.lua`

**Interfaces:**
- Consumes: `vo.BuildMatch`, `vo.ReadTranscript`, `vo.ParseProjectFile`, `vo.BuildOverview`, `vo.SourceTimeToProject`, `vo.MakeTakeProbe`, `vo.InterWordGaps`, `vo.MeasureNoiseFloor`, `vo.ApplyPadding`, `vo.AssignNames`, `vo.ApplyPlan`, `vo.EnsureTrackBelow`, `vo.FormatCutSummary`, `vo.TranscriptState`, `core.Transaction`
- Produces: a `[main]` script. Terminal — nothing consumes it.

- [ ] **Step 1: Write the script**

Same bootstrap block as Task 8. Header:

```lua
-- @noindex
-- Provided by the ajsfx VO package; see ajsfx_VO_Overview.lua's @provides.
--
-- ajsfx VO Cut — cut, route and name the takes the user selected in Overview.
--
-- This script owns no data. It re-derives the match from the transcripts and
-- the project file, applies the user's selects, and mutates the project once
-- inside a single undo block. See VO/SPEC-cut.md.
```

The run, in order:

1. **Load.** Read `<project>_vo.csv`; read every source's transcript; `vo.BuildMatch`; `vo.BuildOverview` to get take numbering and the resolved selects across sources.
2. **Gate.** Refuse to run, with the reason inline, when:
   - any source's `vo.TranscriptState` is `stale` — name the file
   - no row is selected — `Nothing is selected. Tick Select in Overview on the takes you want cut.`
   - a line has several takes and no select — list them: `3 lines have several takes and no select yet.`
3. **Convert.** For each selected span, find the item playing that source-time position and convert to project time with `vo.SourceTimeToProject`. Use `vo.SourceCoverageRanges` to skip spans no current item can play, and count them for the summary.
4. **Snap.** Per take:

```lua
local probe, destroy = vo.MakeTakeProbe(take)
local ok, err = pcall(function()
  local gaps = {}
  for _, g in ipairs(vo.InterWordGaps(words)) do
    gaps[#gaps + 1] = { from = vo.SourceTimeToProject(g.from, item),
                        to   = vo.SourceTimeToProject(g.to,   item) }
  end
  local floor = vo.MeasureNoiseFloor(gaps, probe, cfg)
  vo.ApplyPadding(spans_for_this_item, cfg,
                  { start = item.pos, stop = item.pos + item.length },
                  probe, floor)
end)
destroy()   -- ALWAYS, including on the error path: the accessor holds the file open
if not ok then error(err) end
```

5. **Name.** First copy the user's choice onto the spans — `vo.AssignNames` reads `span.select`, and `select` lives on the *overview row*, not on the span:

```lua
-- The overview row is what carries the user's tick; the span is what gets cut.
-- AssignNames picks the primary from span.select, so the flag has to make the
-- crossing here, once, before naming.
for _, row in ipairs(overview_rows) do
  if row.span then row.span.select = (row.select == true) end
end
```

Then `vo.AssignNames(all_spans, cfg)` over the union of every source's spans at once — that is what makes two takes of one line, recorded in two sessions, number as takes 1 and 2 rather than 1 and 1.
6. **Collide.** Group `match` spans by final `name`. Any name held by spans from more than one source path gets per-source destination tracks:

```lua
-- One Selects track normally. Only a genuine name collision splits it, because
-- a track per source when there is nothing to disambiguate is just clutter.
local function DestTrackName(base, source_path, collided)
  if not collided then return base end
  return base .. " — " .. (source_path:match("([^\\/]+)$") or source_path)
end
```

Report the collision inline naming the asset and both files.

7. **Apply.** One `core.Transaction("VO Cut", function() ... end)` around `vo.EnsureTrackBelow` + `vo.ApplyPlan`, so the whole run is one undo step.
8. **Report.** `vo.FormatCutSummary` inline. Add a line for spans whose `snapped == "pad"`: `4 clip edges fell back to the fixed pad — no silence found in the gap.`

Toggles in the dialog: `use_alts_track` and `suffix_alt_names` only. **No `primary_take`** — it does not exist any more.

- [ ] **Step 2: Syntax-check**

```bash
lua -e "assert(loadfile('VO/ajsfx_VO_Cut.lua'))"
```

- [ ] **Step 3: Manual test in REAPER**

1. Select takes in Overview, open Cut, press Cut. Confirm clips land named and routed, and one Ctrl+Z undoes the whole run.
2. Confirm clip edges sit in silence — zoom in on three boundaries and check none contains a syllable of the neighbouring line.
3. Turn `snap_boundaries` off in Settings; re-run; confirm the fixed 150/250 ms pads return.
4. Make a wav stale (re-record over it); confirm Cut is disabled and names the file.
5. Select nothing; confirm the inline message rather than a run.
6. Have two sources both select the same Filename; confirm two `Selects — <name>` tracks appear and the collision is reported.
7. Leave a multi-take line with no select; confirm it is listed as needing a decision and is not cut.

- [ ] **Step 4: Commit**

```bash
git add VO/ajsfx_VO_Cut.lua && git commit -m "feat(VO): Cut window applies selects with silence-snapped boundaries"
```

---

## Task 13: Settings — snapping controls

**Files:**
- Modify: `VO/ajsfx_VO_Settings.lua`

**Interfaces:**
- Consumes: `vo.DEFAULTS` keys added in Task 4
- Produces: nothing new

- [ ] **Step 1: Add the controls**

Add a `Boundaries` section to the settings window with:

| Control | Key | Widget |
|---|---|---|
| Snap clip edges to silence | `snap_boundaries` | `im.Checkbox` |
| Maximum head room | `pre_pad` | `im.DragDouble`, 0–2 s, 0.01 step |
| Maximum tail | `post_pad` | `im.DragDouble`, 0–2 s, 0.01 step |
| Minimum silence | `snap_min_silence` | `im.DragDouble`, 0.01–0.5 s |
| Noise floor headroom | `snap_floor_offset` | `im.DragDouble`, 0–24 dB |
| Floor measurement window | `snap_floor_window` | `im.DragDouble`, 0.1–2 s |

Grey out the last three when `snap_boundaries` is off. Put this on each pad's tooltip: `With snapping on this is the furthest the edge may travel, not a fixed amount.`

Remove any `primary_take` control if one exists (`grep -n primary_take VO/ajsfx_VO_Settings.lua`).

- [ ] **Step 2: Syntax-check and manual test**

```bash
lua -e "assert(loadfile('VO/ajsfx_VO_Settings.lua'))"
```

In REAPER: change each value, close and reopen Settings, confirm each persisted; confirm Cut's behaviour changes accordingly.

- [ ] **Step 3: Commit**

```bash
git add VO/ajsfx_VO_Settings.lua && git commit -m "feat(VO): snapping controls in Settings"
```

---

## Task 14: Retire ScriptMatch, repackage, document

**Files:**
- Delete: `VO/ajsfx_VO_ScriptMatch.lua`
- Modify: `VO/ajsfx_VO_Overview.lua` — becomes the package main file
- Modify: `VO/SPEC.md`, `VO/SPEC-overview.md`, `VO/MANUAL_TEST.md`
- Create: `VO/SPEC-sources.md`, `VO/SPEC-cut.md`

**Interfaces:**
- Consumes: everything
- Produces: the shipped package

- [ ] **Step 1: Delete ScriptMatch and confirm nothing references it**

```bash
git rm VO/ajsfx_VO_ScriptMatch.lua
grep -rn "ScriptMatch" VO/ tests/ docs/ CLAUDE.md .agents/ 2>/dev/null
```

Every remaining hit must be either a historical spec note or something you fix in Step 3.

- [ ] **Step 2: Make Overview the package main file**

Replace `ajsfx_VO_Overview.lua`'s `@noindex` header with a full ReaPack header:

```lua
-- @description ajsfx VO Overview
-- @author ajsfx
-- @version 0.12
-- @changelog The VO tools are now three windows instead of one. "ajsfx VO Sources" lists every recorded file in the project and whether it has been transcribed; double-click a file to read its transcript, hear where each word sits, and re-transcribe just that file. "ajsfx VO Overview" is now the front door: it derives the match from the stored transcripts every time, so swapping the script CSV re-matches instantly with no re-transcription, and a new Select column records which take you are delivering. "ajsfx VO Cut" does the cutting, and it now places clip edges by looking for silence in the gap between the words either side, so an edge can never contain a syllable of the neighbouring line; the old fixed 150/250 ms pads become the furthest an edge may travel and the noise floor is measured from the recording rather than assumed. Transcription is now stored per wav file as word-level timings in "<audio>_vo_transcript.csv", so copying a recording and its sidecar to another project carries the transcription with it. Your selects, verified marks, notes and renames live in "<project>_vo.csv" beside the project. NOTE: this replaces "ajsfx VO ScriptMatch", which has been removed — reinstall from ReaPack, and re-transcribe your recordings, as the old report files are not read.
-- @about ajsfx VO — script-matched cut-and-name for game VO and dialogue
--        delivery. Transcribe your recordings once in "ajsfx VO Sources", see
--        every script line and every take in "ajsfx VO Overview", tick the
--        takes you are delivering, and cut them in "ajsfx VO Cut". Runs fully
--        locally with whisper.cpp; configure the backend in "ajsfx VO
--        Settings". See VO/SPEC.md.
-- @provides
--   [main] .
--   [main] ajsfx_VO_Sources.lua
--   [main] ajsfx_VO_Cut.lua
--   [main] ajsfx_VO_Settings.lua
--   lib/ajsfx_vo.lua
--   lib/ajsfx_vo_view.lua
--   ../lib/ajsfx_core.lua > lib/ajsfx_core.lua
```

`ajsfx_VO_Sources.lua` and `ajsfx_VO_Cut.lua` keep `@noindex` and are pulled in by this `@provides`, matching how `ajsfx_VO_Settings.lua` is handled today.

- [ ] **Step 3: Update the specs**

- `VO/SPEC.md` — retitle to cover the three-window design; replace §4's sidecar description with the transcript sidecar; delete the `primary_take` row from the toggle table; point at the new spec files.
- `VO/SPEC-overview.md` — §2's three-layer table becomes two files; the tracker becomes the project file; `Primary` becomes `Select`.
- `VO/SPEC-sources.md` (new) — lift §6.1 of the design spec.
- `VO/SPEC-cut.md` (new) — lift §6.3 and §7 of the design spec.
- `VO/MANUAL_TEST.md` — replace the ScriptMatch sections with the manual tests from Tasks 8–13, plus these two from the design spec's §8 that no single task covers:
  1. Copy a wav and its transcript sidecar to a fresh project; Overview shows the lines with zero marks and no whisper run.
  2. Make the audio directory read-only; the transcript write failure is an inline warning and the session stays usable.

- [ ] **Step 4: Full verification**

```bash
./run_tests.sh
```

Expected: PASS, zero failures.

```bash
for f in VO/*.lua VO/lib/*.lua; do lua -e "assert(loadfile('$f'))" || echo "SYNTAX: $f"; done
```

Expected: no `SYNTAX:` lines.

```bash
grep -rn "ScriptMatch\|_vo_report\|_vo_tracker\|primary_take\|BuildPlan\|ParseSidecar\|SerializeTracker" VO/ tests/
```

Expected: no hits outside historical prose in `VO/SPEC.md`.

- [ ] **Step 5: Commit and push**

```bash
git add -A && git commit -m "feat(VO): retire ScriptMatch, ship Sources/Overview/Cut as one package"
git push -u origin feature/vo-source-manager
```

- [ ] **Step 6: Confirm CI is green**

```bash
gh run list --limit 1
```

Per CLAUDE.md: a failed run publishes nothing and says nothing. Also skim the build log — `reapack-index` reports packaging mistakes as **warnings**, so the index can build "successfully" while silently omitting a package. Confirm the log mentions `ajsfx_VO_Overview.lua` and does not warn about the deleted `ajsfx_VO_ScriptMatch.lua`.

```bash
gh run view --log | grep -i "warn\|VO"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §3 Scripts table | 8, 12, 14 |
| §3.1 Launching a sibling | 7 |
| §3.2 `focus_source` handoff | 11 |
| §4.1 Transcript sidecar | 1, 7 |
| §4.2 Project file | 2, 10 |
| §4.3 Row identity (unchanged) | 2 (preserved), 10 |
| §5 Matching, live | 3, 10 |
| §6.1 VO Sources | 8, 9 |
| §6.2 VO Overview | 10, 11 |
| §6.3 VO Cut | 12 |
| §7 Boundary snapping | 4, 5, 7, 12, 13 |
| §8 Testing | 1–6 (unit), 8–13 (manual), 14 (consolidated) |
| §9 Accepted consequences | 6 (deletions), 14 (repackage) |
| §10 Future work | not built, by design |

**Known ordering hazard:** Tasks 2, 3 and 5 each leave `tests/test_vo.lua` with failures that Task 6 clears. This is called out in each task's Step 4. If you prefer a green suite at every commit, delete the superseded tests as you go rather than in Task 6; Task 6 verifies they are gone either way.

**Type consistency check:** `words` is `{t0, t1, text}` everywhere (Tasks 1, 3, 4, 7, 9, 12). `spans` carry `start`/`stop` (not `t0`/`t1`) everywhere. `vo.BuildMatch` returns `{path, spans}` which is exactly `vo.BuildOverview`'s renamed `input.matches` (Tasks 3, 10). Project-file entries use `select` (boolean) and `status` (string) — never `primary`, which is a *derived* field on an overview row, set from `select` in Task 10 and read by `vo.AssignNames` in Task 5.
