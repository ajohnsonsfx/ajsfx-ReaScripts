# Range-True Transcripts + Apply Cut Fades — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A take marker's row shows only the words spoken inside that marker's range, on every rebuild, and a new toolbar button applies the standard cut fades to the selected items.

**Architecture:** `vo.TranscriptForRange` gains a word-list parameter and derives its text by midpoint-filtering that list, falling back to today's span-concatenation when no words are supplied. `vo.BuildOverview` accepts `input.transcripts` (the `{path, words}` list the Overview already builds for `vo.BuildMatch`) and hands each marker row its source's words. Separately, a toolbar verb writes `cut_fade_in`/`cut_fade_out` onto selected items in one undo step.

**Tech Stack:** Lua 5.4, REAPER ReaScript API, ReaImGui, plain-assert test harness in `tests/test_vo.lua` over `tests/mock_reaper.lua`.

## Global Constraints

- Spec: `VO/SPEC-range-transcript.md`. Read it before Task 1.
- Word inclusion rule is the **midpoint**: a word counts when `(w.t0 + w.t1) / 2` lies inside `[from, to]`. Not `t0`, not `t1`.
- Text is joined with a single space, matching `s.transcript = table.concat(text, " ")` in `vo.BuildMatch`.
- The score and `in_sequence` returns keep today's behaviour exactly: the single `match`/`review` span with the greatest overlap.
- A range that yields no text returns `nil`, never `""`.
- Backward compatibility is a requirement, not a nicety: `vo.TranscriptForRange(flat, path, from, to)` with no fifth argument must behave exactly as it does today. Existing tests at `tests/test_vo.lua:1567-1619` must pass unmodified.
- Run the whole suite with `./run_tests.sh` (bash, not PowerShell). Never claim a pass without pasting the output.
- Do not bump `@version` or write `@changelog` in this plan's tasks. Versioning is a release decision made separately.
- Comment style in this codebase explains *why*, in full sentences, often several lines. Match it. Do not add comments that restate the code.

---

### Task 1: `TranscriptForRange` derives text from words

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua:1838-1863` (`vo.TranscriptForRange`)
- Test: `tests/test_vo.lua` — append to the `TranscriptForRange` block that ends at line 1619

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `vo.TranscriptForRange(flat, path, from, to, words)` → `text, score, in_sequence`.
  - `flat`: unchanged — the flattened `{ span = ..., source_path = ... }` list.
  - `words`: optional array of `{ t0 = number, t1 = number, text = string }`, already restricted to this source. `nil` selects the legacy span-concatenation path.
  - Returns are unchanged in type and meaning.

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_vo.lua` immediately after the `"audio nothing matched still reports what was heard"` test (currently ending line 1619):

```lua
-- The word list a range can be cut out of. Deliberately overlapping the TFR
-- spans above so the two paths can be compared on the same fixture.
local TFR_WORDS = {
  { t0 = 0.0, t1 = 0.4, text = "open" },
  { t0 = 0.5, t1 = 0.9, text = "the" },
  { t0 = 1.0, t1 = 1.9, text = "gate" },
  { t0 = 3.0, t1 = 3.5, text = "and" },
  { t0 = 3.6, t1 = 4.9, text = "hurry" },
}

test("with words, a range reads only the words inside it", function()
  -- The span says "open the gate"; the range holds two of its three words.
  local text = vo.TranscriptForRange(TFR, "a.wav", 0, 0.95, TFR_WORDS)
  assert(text == "open the", "Got: " .. tostring(text))
end)

test("a range across two spans no longer reads both spans in full", function()
  -- The old path returned "open the gate and hurry" for this range. Midpoints:
  -- open 0.2, the 0.7, gate 1.45, and 3.25, hurry 4.25 -- so 1.4-3.4 holds
  -- exactly the two in the middle, one from each span.
  local text = vo.TranscriptForRange(TFR, "a.wav", 1.4, 3.4, TFR_WORDS)
  assert(text == "gate and", "Got: " .. tostring(text))
end)

test("a word counts by its midpoint, not by either edge", function()
  -- "gate" runs 1.0-1.9, midpoint 1.45. A range starting at 1.2 holds its
  -- midpoint and keeps it; one starting at 1.5 does not and drops it, even
  -- though the word's tail is inside either way.
  assert(vo.TranscriptForRange(TFR, "a.wav", 1.2, 2.0, TFR_WORDS) == "gate",
         "midpoint inside was dropped")
  local text = vo.TranscriptForRange(TFR, "a.wav", 1.5, 2.0, TFR_WORDS)
  assert(text == nil, "midpoint outside was kept: " .. tostring(text))
end)

test("the score still comes from the greatest-overlap span, whatever the words", function()
  local _, score, seq = vo.TranscriptForRange(TFR, "a.wav", 0, 1.9, TFR_WORDS)
  assert(near(score, 0.9), "Got: " .. tostring(score))
  assert(seq == true, "in_sequence not carried")
end)

test("words present but the range holds none is nil, not empty", function()
  assert(vo.TranscriptForRange(TFR, "a.wav", 2.0, 2.9, TFR_WORDS) == nil,
         "a silent gap returned text")
end)

test("no word list falls back to the span text", function()
  assert(vo.TranscriptForRange(TFR, "a.wav", 0, 5) == "open the gate and hurry",
         "the legacy path changed")
  assert(vo.TranscriptForRange(TFR, "a.wav", 0, 5, {}) == "open the gate and hurry",
         "an EMPTY word list must fall back, not report silence")
end)
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
./run_tests.sh
```

Expected: failures in the new tests — the fifth argument is ignored, so `"with words, a range reads only the words inside it"` returns `"open the gate"` instead of `"open the"`.

- [ ] **Step 3: Implement**

Replace the body of `vo.TranscriptForRange` in `VO/lib/ajsfx_vo.lua`. Keep the existing doc comment above it and extend it; add the word path:

```lua
function vo.TranscriptForRange(flat, path, from, to, words)
  if not (path and from and to and to > from) then return nil end
  local hits, best, best_overlap = {}, nil, 0
  for _, rec in ipairs(flat or {}) do
    local s = rec.span
    if rec.source_path == path and s and s.start and s.stop then
      local overlap = math.min(s.stop, to) - math.max(s.start, from)
      if overlap > 0 then
        hits[#hits + 1] = s
        if (s.kind == "match" or s.kind == "review") and overlap > best_overlap then
          best, best_overlap = s, overlap
        end
      end
    end
  end
  if #hits == 0 then return nil end

  -- The words themselves when the caller has them: a span is a whole matched
  -- stretch, and a marker inside one holds only part of it. Concatenating
  -- overlapping spans reported a dozen words the take does not contain, which
  -- is the whole reason this argument exists.
  --
  -- A word counts by its MIDPOINT. Whisper pads word ends into the silence
  -- that follows, so testing t1 pulls in a word the range does not really
  -- hold; testing t0 keeps a word whose audio is mostly outside. The midpoint
  -- is right at both edges.
  local text = {}
  for _, w in ipairs(words or {}) do
    if w.t0 and w.t1 and w.text and w.text ~= "" then
      local mid = (w.t0 + w.t1) * 0.5
      if mid >= from and mid <= to then text[#text + 1] = w.text end
    end
  end
  if #text > 0 then
    return table.concat(text, " "), best and best.score or nil,
           best and best.in_sequence or nil
  end
  -- No words to offer -- either the caller passed none, or this range really
  -- is silent. Only the first case may fall back to the spans: a range the
  -- words say is empty must read as empty, not as its neighbours' text.
  if words and #words > 0 then return nil end

  table.sort(hits, function(a, b) return (a.start or 0) < (b.start or 0) end)
  local span_text = {}
  for _, s in ipairs(hits) do
    if s.transcript and s.transcript ~= "" then span_text[#span_text + 1] = s.transcript end
  end
  if #span_text == 0 then return nil end
  return table.concat(span_text, " "), best and best.score or nil,
         best and best.in_sequence or nil
end
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
./run_tests.sh
```

Expected: PASS, including the six pre-existing `TranscriptForRange` tests, unmodified.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "VO: a marker's range reads the words in it, not the spans over it"
```

---

### Task 2: `BuildOverview` hands marker rows their words

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua:4770-4977` (`vo.BuildOverview`: add the `transcripts` lookup near the top, use it in `marker_row`)
- Test: `tests/test_vo.lua` — append to the `BuildOverview` block that starts at line 5119

**Interfaces:**
- Consumes: `vo.TranscriptForRange(flat, path, from, to, words)` from Task 1.
- Produces: `vo.BuildOverview(input)` accepts a new optional `input.transcripts` — an array of `{ path = string, words = { {t0, t1, text}, ... } }`. Absent means today's behaviour. Row shape is unchanged.

- [ ] **Step 1: Write the failing test**

Append to `tests/test_vo.lua` at the end of the `BuildOverview` block (after the last `BuildOverview` test, currently near line 5270 — put it before the next `print("\n...")` section header):

```lua
test("a marker row reads the words inside its range, not the whole span", function()
  local lines = { { asset = "VO_01", text = "open the gate and hurry", index = 1 } }
  local matches = { { path = "a.wav", spans = {
    { start = 0, stop = 5, asset = "VO_01", kind = "match", score = 0.9,
      line_idx = 1, transcript = "open the gate and hurry" },
  } } }
  local transcripts = { { path = "a.wav", words = {
    { t0 = 0.0, t1 = 0.4, text = "open" },
    { t0 = 0.5, t1 = 0.9, text = "the" },
    { t0 = 1.0, t1 = 1.9, text = "gate" },
    { t0 = 3.0, t1 = 3.5, text = "and" },
    { t0 = 3.6, t1 = 4.9, text = "hurry" },
  } } }
  local takes_by_asset = { VO_01 = {
    { id = 7, asset = "VO_01", start = 0, stop = 2.0, source_path = "a.wav" },
  } }

  local rows = vo.BuildOverview({
    lines = lines, matches = matches, entries = {},
    takes_by_asset = takes_by_asset, transcripts = transcripts,
  })
  local row
  for _, rw in ipairs(rows) do if rw.marker_id == 7 then row = rw end end
  assert(row, "no marker row was built")
  assert(row.transcript == "open the gate",
         "Got: " .. tostring(row.transcript))
  assert(near(row.score, 0.9), "score lost: " .. tostring(row.score))
end)

test("a marker row without transcripts keeps the span text", function()
  local lines = { { asset = "VO_01", text = "open the gate and hurry", index = 1 } }
  local matches = { { path = "a.wav", spans = {
    { start = 0, stop = 5, asset = "VO_01", kind = "match", score = 0.9,
      line_idx = 1, transcript = "open the gate and hurry" },
  } } }
  local takes_by_asset = { VO_01 = {
    { id = 7, asset = "VO_01", start = 0, stop = 2.0, source_path = "a.wav" },
  } }
  local rows = vo.BuildOverview({
    lines = lines, matches = matches, entries = {},
    takes_by_asset = takes_by_asset,
  })
  local row
  for _, rw in ipairs(rows) do if rw.marker_id == 7 then row = rw end end
  assert(row, "no marker row was built")
  assert(row.transcript == "open the gate and hurry",
         "Got: " .. tostring(row.transcript))
end)
```

- [ ] **Step 2: Run the tests to verify the first one fails**

```bash
./run_tests.sh
```

Expected: `"a marker row reads the words inside its range"` FAILS with `Got: open the gate and hurry` — `input.transcripts` is ignored. The second test passes already; that is correct, it is the regression guard.

- [ ] **Step 3: Implement**

In `vo.BuildOverview`, after the `takes_by_asset` local is read (around line 4778), add the lookup:

```lua
  -- The per-source word lists, when the caller has them. A marker row's text
  -- is the words INSIDE its range, and only the caller (which already read
  -- the transcripts to build the match) can supply them; a caller that does
  -- not falls back to span text inside vo.TranscriptForRange.
  local words_by_source = {}
  for _, t in ipairs(input.transcripts or {}) do
    if t.path then words_by_source[t.path] = t.words or {} end
  end
```

Then in `marker_row` (around line 4946), pass them through:

```lua
    local said, score, in_seq =
      vo.TranscriptForRange(spans, mk.source_path, mk.start, mk.stop,
                            words_by_source[mk.source_path])
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
./run_tests.sh
```

Expected: PASS, whole suite.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "VO: BuildOverview hands each marker row its source's words"
```

---

### Task 3: The Overview passes its transcripts through

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua:619-644` (`LoadMatches` — cache the list on `state`)
- Modify: `VO/ajsfx_VO_Overview.lua:696-702` (the `vo.BuildOverview` call)
- Modify: `VO/ajsfx_VO_Overview.lua` state table near line 274 (declare the new field beside `overview`)

**Interfaces:**
- Consumes: `input.transcripts` from Task 2.
- Produces: `state.transcripts` — the same `{ path, words }` array `LoadMatches` builds, surviving `LoadMatches`'s memoised early return.

There is no automated test for this task: it is UI wiring in a file the harness does not load. The verification is the manual REAPER check in Task 5. Keep the change this small so that is honest.

- [ ] **Step 1: Cache the list on state**

`LoadMatches` returns early when the match key is unchanged, so the local `transcripts` table it builds does not survive to the next call. Store it. In `VO/ajsfx_VO_Overview.lua`, change:

```lua
  local transcripts = {}
  for _, path in ipairs(paths) do
    local parsed = vo.ReadTranscript(path)
    if parsed then transcripts[#transcripts + 1] = { path = path, words = parsed.words } end
  end

  state.matches   = vo.BuildMatch(transcripts, state.lines or {}, cfg, state.pins)
  state.match_key = key
```

to:

```lua
  local transcripts = {}
  for _, path in ipairs(paths) do
    local parsed = vo.ReadTranscript(path)
    if parsed then transcripts[#transcripts + 1] = { path = path, words = parsed.words } end
  end

  -- Kept on state, not just handed to BuildMatch: this function is memoised on
  -- the match key and returns early on a hit, so a local would be gone by the
  -- time the rebuild after it needs the words for the marker rows.
  state.transcripts = transcripts
  state.matches     = vo.BuildMatch(transcripts, state.lines or {}, cfg, state.pins)
  state.match_key   = key
```

- [ ] **Step 2: Declare the field**

In the `state` table (beside `overview = {}, -- vo.BuildOverview result`, around line 274), add:

```lua
  transcripts   = {},         -- { path, words } per source, for marker row text
```

- [ ] **Step 3: Pass it to BuildOverview**

`LoadMatches` must run before the table is built, since it is what fills `state.transcripts`. Change the `Rebuild` call to hoist it:

```lua
  local matches = LoadMatches(cfg)
  state.overview = vo.BuildOverview({
    lines   = state.lines,
    matches = matches,
    entries = state.entries,
    cfg     = cfg,
    takes_by_asset = takes_by_asset,
    -- LoadMatches is hoisted above the constructor because it is what FILLS
    -- state.transcripts, and the order a table constructor evaluates its
    -- fields in is not something to rely on.
    transcripts = state.transcripts,
  })
```

- [ ] **Step 4: Verify the script still loads**

```bash
./run_tests.sh
```

Expected: PASS (unchanged — this file is not under test). Then check the syntax explicitly, since the harness would not catch a parse error here:

```bash
luac -p VO/ajsfx_VO_Overview.lua 2>&1 || lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))"
```

Expected: no output. If `luac` is unavailable, the `lua -e` fallback prints nothing on success.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: the Overview hands its word lists to the sheet build"
```

---

### Task 4: The "Apply the cut fades" toolbar verb

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — add `ApplyCutFades` beside `TightenItems` (which ends before line 1930's comment block; place the new function immediately after `TightenItems` finishes)
- Modify: `VO/ajsfx_VO_Overview.lua:7224-7231` — add the button after the "Auto-adjust head and tail" block

**Interfaces:**
- Consumes: `vo.Opt(cfg, "cut_fade_in")` / `vo.Opt(cfg, "cut_fade_out")` — seconds, already used by `vo.ApplyPlan` and `TightenItems`.
- Produces: nothing later tasks depend on.

**Do not add a file-level `local`.** The main chunk of this file is at Lua's 200-local ceiling — a new file local is a LOAD-time error that stops the whole script from parsing. Hang the function off the existing `Trim` table as `Trim.fades`, the same dodge `Trim` itself documents at line 1172.

- [ ] **Step 1: Write the function**

Add immediately after `TightenItems` ends in `VO/ajsfx_VO_Overview.lua`:

```lua
-- Put the standard cut fades back on the selected items. The fades a cut
-- writes are short and protective -- shorter in than out, inside the head and
-- tail room -- and an item that has been comped, re-trimmed or dragged in by
-- hand has whatever fades that gesture left it.
--
-- Note what this ALSO does: default fades are how "nobody touched this by
-- hand" is recorded. TightenItems ("Auto-adjust head and tail") skips any item
-- whose fades differ from the cut defaults, which is what protects a
-- hand-trimmed item from being measured and moved. Pressing this re-enrols
-- that item into Auto-adjust. That is the right reading of the gesture --
-- "this one is finished and standard again" -- but it is not free, and the
-- tooltip says so.
function Trim.fades()
  local cfg = vo.LoadConfig()
  local fade_in  = vo.Opt(cfg, "cut_fade_in")
  local fade_out = vo.Opt(cfg, "cut_fade_out")

  local pool = {}
  for i = 0, r.CountSelectedMediaItems(0) - 1 do
    pool[#pool + 1] = r.GetSelectedMediaItem(0, i)
  end
  if #pool == 0 then
    state.message, state.message_kind =
      "Select the items in REAPER first.", "warn"
    return
  end

  -- An item already carrying the defaults is not a write and is not counted:
  -- a press over a tidy session should say so rather than claim work.
  local changed = 0
  core.Transaction("VO Overview: apply the cut fades", function()
    for _, item in ipairs(pool) do
      local was_in  = r.GetMediaItemInfo_Value(item, "D_FADEINLEN")
      local was_out = r.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
      if math.abs(was_in - fade_in) > 0.0005
         or math.abs(was_out - fade_out) > 0.0005 then
        r.SetMediaItemInfo_Value(item, "D_FADEINLEN",  fade_in)
        r.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", fade_out)
        changed = changed + 1
      end
    end
  end)
  r.UpdateArrange()

  state.message, state.message_kind = (changed > 0)
    and string.format("Applied the cut fades to %d item(s) (%.0f ms in, %.0f ms out).",
                      changed, fade_in * 1000, fade_out * 1000)
    or  string.format("All %d selected item(s) already carry the cut fades.", #pool),
    "ok"
end
```

- [ ] **Step 2: Add the button**

In the Edit tab, immediately after the "Auto-adjust head and tail" `Tip(...)` block (currently ending line 7231):

```lua
      Flow("Apply the cut fades")
      if im.Button(ctx, "Apply the cut fades") then pending_action = Trim.fades end
      Tip("Put the standard short fades (Settings) back on the selected\n" ..
          "items -- the ones a cut writes, and the ones a comp, a re-trim\n" ..
          "or a hand-drawn crossfade replaces.\n\n" ..
          "It also re-enrols the item into \"Auto-adjust head and tail\":\n" ..
          "custom fades are how a hand-trimmed item is recognised and left\n" ..
          "alone, so an item with the defaults back is one Auto-adjust is\n" ..
          "willing to measure and move again.\n\n" ..
          "Acts on the REAPER selection.")
```

- [ ] **Step 3: Verify the script still loads**

```bash
lua -e "assert(loadfile('VO/ajsfx_VO_Overview.lua'))"
```

Expected: no output. A `function at line N has more than 200 local variables` error here means Step 1 introduced a file-level `local` — it must be `function Trim.fades()`, not `local function`.

- [ ] **Step 4: Run the suite**

```bash
./run_tests.sh
```

Expected: PASS, unchanged.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: a verb that puts the cut fades back"
```

---

### Task 5: Verify in REAPER, and record the result

**Files:**
- Modify: `VO/MANUAL_TEST.md` — append a section for these two changes

**Interfaces:**
- Consumes: everything from Tasks 1-4.
- Produces: nothing.

Tasks 1-3 change what the sheet *shows*, and no automated test covers the ReaImGui layer. This task is where the work is actually confirmed. Do not skip it and do not report the feature as working before it is done.

- [ ] **Step 1: Reload and open**

In REAPER, re-run `ajsfx_VO_Overview.lua` on a project that has take markers and transcripts.

- [ ] **Step 2: Check the transcript narrows**

Find a take whose marker sits inside a longer matched span. Drag the marker's end inward in the arrange view, then let the Overview rebuild.

Expected: the grey transcript under that take loses the words the marker no longer covers, and the extra-word colouring narrows with it. The take stays on the same script line — nothing is reassigned.

- [ ] **Step 3: Check the score did not move**

Same row, same drag. Expected: the score is unchanged, because it still comes from the greatest-overlap span.

- [ ] **Step 4: Check the fades verb**

Select two items — one with the cut fades, one you have hand-faded. Press **Apply the cut fades** in Edit.

Expected: the message reports `1 item(s)`, not 2. Press again: it reports all 2 already carry them. One Ctrl+Z restores both.

- [ ] **Step 5: Write down what happened**

Append a dated section to `VO/MANUAL_TEST.md` recording the four checks and their real outcomes — including anything that did not behave as expected. A checklist of ticks nobody performed is worse than no checklist.

- [ ] **Step 6: Commit**

```bash
git add VO/MANUAL_TEST.md
git commit -m "VO: manual test notes for range-true transcripts and the fades verb"
```
