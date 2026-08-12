# VO Line Edits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user type the words that were actually said over a script line, so the matcher scores against those — with the script's own words kept visible in grey and always one right-click from the clipboard.

**Architecture:** Line edits reuse Append's machinery whole — the same
`script|asset|nth` key, the same array-of-records, the same project file
preamble row, the same "empty means absent" rule. The override is applied at
ONE point (beside `vo.ResolveNames` in the Overview's script-load path) by
restoring `line.text` from `line.text_original` and then overwriting it with
the edit; every consumer downstream reads `line.text` and is untouched.

**Tech Stack:** Lua 5.x, ReaImGui, REAPER ReaScript API. Tests run against the
mock REAPER in `tests/` via `./run_tests.sh`.

## Global Constraints

- Spec: `VO/SPEC-line-edits.md`. Every requirement below is from it.
- **The Overview's main chunk is AT Lua's 200-local ceiling.** A new file-level
  `local` in `VO/ajsfx_VO_Overview.lua` is a LOAD-time error for the whole
  script. New helpers go on an existing table (`Trim`, `Dest`, …) or inside a
  function. Verify with `lua -e "loadfile('VO/ajsfx_VO_Overview.lua')"`.
- **Setting an edit to empty REMOVES the record.** "No edit" is the absence of
  one — `vo.SetAppend`'s rule, applied unchanged.
- **An edit equal to the original is still stored.** It is a judgement.
- Records are an ARRAY, never a map keyed on the joined string: splitting
  `label|asset|nth` back apart is ambiguous once a filename contains `|`.
- No `core.Transaction`: this writes no items and no markers. It marks the
  project file dirty, exactly as `SetAppend` does.
- Project writes from an ImGui frame go through `pending_action`.
- Run `./run_tests.sh` before every commit; it must report 0 failures.
- No `@version` / `@changelog` bump — nothing on this branch publishes yet.

---

### Task 1: The pure layer

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — after `vo.OrphanAppends` (ends ~line 606)
- Test: `tests/test_vo.lua` — beside the existing Append tests

**Interfaces:**
- Consumes: `vo.AppendKey(script_label, asset, nth)` (existing, line 409)
- Produces:
  - `vo.LineEditMap(rows) -> { [append_key] = text }`
  - `vo.SetLineEdit(rows, script, asset, nth, text)` — mutates `rows` in place
  - `vo.OrphanLineEdits(edits, lines) -> { record, ... }`
  - `vo.ApplyLineEdits(lines, edit_map)` — sets `line.text`,
    `line.text_original`, `line.text_edited` on every line
  - Record shape: `{ script = <label>, asset = <filename>, nth = <int>, text = <string> }`

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua`, immediately after the Append test block:

```lua
print("\nLine edits:")

test("SetLineEdit stores, replaces, and empty removes", function()
  local rows = {}
  vo.SetLineEdit(rows, "S", "a.wav", 1, "Bolvd no speak")
  assert(#rows == 1 and rows[1].text == "Bolvd no speak", "not stored")
  vo.SetLineEdit(rows, "S", "a.wav", 1, "Bolvd will not speak")
  assert(#rows == 1 and rows[1].text == "Bolvd will not speak", "not replaced")
  vo.SetLineEdit(rows, "S", "a.wav", 1, "   ")
  assert(#rows == 0, "empty did not remove the record")
end)

test("an edit equal to the original is still stored", function()
  -- Deciding the line is right as written is a judgement worth keeping.
  local rows = {}
  vo.SetLineEdit(rows, "S", "a.wav", 1, "Adon no speak")
  assert(#rows == 1, "dropped an edit for matching the original")
end)

test("LineEditMap keys by script, asset and occurrence", function()
  local m = vo.LineEditMap({
    { script = "S1", asset = "a.wav", nth = 1, text = "one" },
    { script = "S2", asset = "a.wav", nth = 1, text = "two" },
    { script = "S1", asset = "a.wav", nth = 2, text = "three" },
  })
  assert(m[vo.AppendKey("S1", "a.wav", 1)] == "one", "S1 nth1")
  assert(m[vo.AppendKey("S2", "a.wav", 1)] == "two", "same file, other script")
  assert(m[vo.AppendKey("S1", "a.wav", 2)] == "three", "second occurrence")
end)

test("ApplyLineEdits overrides the text and keeps the original", function()
  local lines = {
    { asset = "a.wav", text = "Adon no speak",
      append_key = vo.AppendKey("S", "a.wav", 1) },
    { asset = "b.wav", text = "untouched",
      append_key = vo.AppendKey("S", "b.wav", 1) },
  }
  vo.ApplyLineEdits(lines, { [vo.AppendKey("S", "a.wav", 1)] = "Bolvd no speak" })
  assert(lines[1].text == "Bolvd no speak", "text: " .. lines[1].text)
  assert(lines[1].text_original == "Adon no speak", "original lost")
  assert(lines[1].text_edited == true, "not flagged as edited")
  assert(lines[2].text == "untouched", "disturbed an unedited line")
  assert(lines[2].text_original == "untouched", "original not set when unedited")
  assert(not lines[2].text_edited, "unedited line flagged as edited")
end)

test("ApplyLineEdits is idempotent, and reverts when the edit goes", function()
  -- Called on every script load, on the SAME table. Without this, a second
  -- pass would record the edited text as the original and the script's own
  -- words would be gone for good.
  local lines = { { asset = "a.wav", text = "Adon",
                    append_key = vo.AppendKey("S", "a.wav", 1) } }
  local key = vo.AppendKey("S", "a.wav", 1)
  vo.ApplyLineEdits(lines, { [key] = "Bolvd" })
  vo.ApplyLineEdits(lines, { [key] = "Bolvd" })
  assert(lines[1].text_original == "Adon", "original overwritten on re-apply")
  vo.ApplyLineEdits(lines, { [key] = "Grumbar" })
  assert(lines[1].text == "Grumbar" and lines[1].text_original == "Adon",
         "changing the edit lost the original")
  vo.ApplyLineEdits(lines, {})
  assert(lines[1].text == "Adon", "revert did not restore the script line")
  assert(not lines[1].text_edited, "still flagged as edited after revert")
end)

test("OrphanLineEdits reports an edit whose line is gone", function()
  local edits = {
    { script = "S", asset = "gone.wav", nth = 1, text = "x" },
    { script = "S", asset = "here.wav", nth = 1, text = "y" },
  }
  local lines = { { script = "S", asset = "here.wav", append_nth = 1 } }
  local orphans = vo.OrphanLineEdits(edits, lines)
  assert(#orphans == 1 and orphans[1].asset == "gone.wav",
         "orphans: " .. #orphans)
end)
```

- [ ] **Step 2: Run to verify they fail**

Run: `lua tests/test_vo.lua 2>&1 | grep -E "FAIL|passed,"`
Expected: 6 FAILs, all `attempt to call a nil value (field 'SetLineEdit')` etc.

- [ ] **Step 3: Implement**

Add to `VO/lib/ajsfx_vo.lua` after `vo.OrphanAppends`:

```lua
-- A LINE EDIT is what was actually said, where the script says something else.
--
-- The same record as an Append, keyed the same way, for the same reason: it is
-- a judgement about ONE line of ONE script, made by hand, that the CSV does not
-- know about. The script CSV is the author's and is never written to; this is
-- the project's opinion of it.
--
-- Not the substitution table. That is global -- one entry per misheard word,
-- correct only when the word is wrong everywhere. A line the director changed
-- on the day is not a transcription problem, and `bolvd=adon` would rewrite
-- every other line that says Bolvd.
--
-- Record: { script = <label>, asset = <filename>, nth = <integer>, text = <string> }
function vo.LineEditMap(edit_rows)
  local m = {}
  for _, e in ipairs(edit_rows or {}) do
    m[vo.AppendKey(e.script, e.asset, e.nth)] = e.text or ""
  end
  return m
end

-- The one mutator. Empty REMOVES the record: "no edit" is the absence of one,
-- the rule vo.SetAppend and SerializeProjectFile already share. That also makes
-- "Revert to script line" and "clear the field" the same operation, so they
-- cannot disagree.
--
-- An edit equal to the original is still stored. Deciding a line is right as
-- written is a judgement, and dropping it would make the grey original row
-- flicker away and back as the user typed toward what the script says.
function vo.SetLineEdit(edit_rows, script, asset, nth, text)
  edit_rows = edit_rows or {}
  local clean = trim(tostring(text or ""))

  for i, e in ipairs(edit_rows) do
    if e.script == script and e.asset == asset and e.nth == nth then
      if clean == "" then table.remove(edit_rows, i) else e.text = clean end
      return edit_rows
    end
  end
  if clean ~= "" then
    edit_rows[#edit_rows + 1] =
      { script = script, asset = asset, nth = nth, text = clean }
  end
  return edit_rows
end

-- Edits no loaded line answers to -- a renamed or re-exported CSV is enough.
-- Surfaced, not repaired, exactly as vo.OrphanAppends is: which line it should
-- attach to is the user's call.
function vo.OrphanLineEdits(edits, lines)
  local live = {}
  for _, l in ipairs(lines or {}) do
    live[vo.AppendKey(l.script, l.asset, l.append_nth)] = true
  end
  local orphans = {}
  for _, e in ipairs(edits or {}) do
    if e.text and e.text ~= ""
       and not live[vo.AppendKey(e.script, e.asset, e.nth)] then
      orphans[#orphans + 1] = e
    end
  end
  return orphans
end

-- Put the edited words where every reader of a line already looks.
--
-- ONE override point. The matcher reads `l.text` (text_for[l.asset]),
-- ExtraWords colours against it, BuildOverview copies it into row.line_text,
-- and search puts it in the haystack -- so overriding here reaches all of them
-- and none of them needs to know this feature exists. A second code path is
-- how the sheet and the matcher would come to disagree about what a line says.
--
-- Called on every script load, on the SAME line tables, so it must be
-- idempotent: `text_original` is written once and `text` is always rebuilt
-- FROM it. Without that, the second pass would record the edited words as the
-- original and the script's own words would be gone for good.
function vo.ApplyLineEdits(lines, edit_map)
  edit_map = edit_map or {}
  for _, l in ipairs(lines or {}) do
    if l.text_original == nil then l.text_original = l.text end
    local e = l.append_key and edit_map[l.append_key] or nil
    l.text        = (e ~= nil and e ~= "") and e or l.text_original
    l.text_edited = (e ~= nil and e ~= "") or nil
  end
  return lines
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `./run_tests.sh 2>&1 | grep -cE "^  FAIL"`
Expected: `0`

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "VO: line edits, the pure layer"
```

---

### Task 2: Project file round-trip

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua:5119-5127` (serialize, the `Append` loop) and
  `:5252-5259` (parse, the `elseif key == "Append"` branch)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.SetLineEdit` record shape from Task 1
- Produces: `parsed.line_edits` on `vo.ParseProjectFile`, and a `Line` row from
  `vo.SerializeProjectFile(entries, meta)` where `meta.line_edits` is the array

- [ ] **Step 1: Write the failing test**

```lua
test("a line edit round-trips through the project file", function()
  local text = vo.SerializeProjectFile({}, {
    line_edits = { { script = "S", asset = "a.wav", nth = 2,
                     text = 'Bolvd, "no", speak' } },
  })
  assert(text:find("\nLine,", 1, true) or text:find("^Line,"),
         "no Line row written")
  local parsed = vo.ParseProjectFile(text)
  assert(#parsed.line_edits == 1, "count: " .. #parsed.line_edits)
  local e = parsed.line_edits[1]
  assert(e.script == "S" and e.asset == "a.wav" and e.nth == 2,
         "key did not survive")
  assert(e.text == 'Bolvd, "no", speak', "text: " .. e.text)
end)

test("a Line row for a vanished line is read, not dropped", function()
  -- Disabling a script must not destroy its edits; orphans are REPORTED.
  local parsed = vo.ParseProjectFile(
    vo.SerializeProjectFile({}, {
      line_edits = { { script = "Gone", asset = "x.wav", nth = 1, text = "t" } },
    }))
  assert(#parsed.line_edits == 1, "dropped an edit at parse time")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua tests/test_vo.lua 2>&1 | grep -E "FAIL"`
Expected: FAIL "no Line row written"

- [ ] **Step 3: Implement — serialize**

In `vo.SerializeProjectFile`, immediately after the `meta.appends` loop:

```lua
  -- Line edits sit beside the Appends and for the same reason: both are keyed
  -- by the script LINE, not by a stretch of audio, so neither can live in the
  -- entry table. An edit whose script is no longer in the list is still
  -- written -- removing a script and adding it back must not throw the user's
  -- words away.
  for _, e in ipairs(meta.line_edits or {}) do
    if e.text and e.text ~= "" then
      out[#out + 1] = vo.FormatCSVRow({
        "Line", e.script or "", e.asset or "",
        tostring(e.nth or 1), e.text,
      })
    end
  end
```

- [ ] **Step 4: Implement — parse**

Add `line_edits = {}` to the `parsed` table initialiser (~line 5230, beside
`appends = {}`), then add this branch after the `Append` one:

```lua
    elseif key == "Line" then
      local script, asset = rows[i][2] or "", rows[i][3] or ""
      local nth, text = tonumber(rows[i][4] or ""), rows[i][5] or ""
      if asset ~= "" and nth and text ~= "" then
        parsed.line_edits[#parsed.line_edits + 1] =
          { script = script, asset = asset, nth = math.floor(nth), text = text }
      end
```

- [ ] **Step 5: Run to verify they pass**

Run: `./run_tests.sh 2>&1 | grep -cE "^  FAIL"`
Expected: `0`

- [ ] **Step 6: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "VO: line edits round-trip through the project file"
```

---

### Task 3: Rows carry the original

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — every row constructor in `vo.BuildOverview`
  that sets `line_text` (~lines 5553, 5596, 5651, 5722)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `line.text_original`, `line.text_edited` from Task 1
- Produces: `row.line_original` (string or nil) and `row.line_edited`
  (true or nil) on every overview row that has a line

- [ ] **Step 1: Write the failing test**

```lua
test("an edited line's row carries the script's own words", function()
  local lines = { { asset = "a.wav", text = "Bolvd no speak",
                    text_original = "Adon no speak", text_edited = true,
                    script = "S", append_nth = 1,
                    append_key = vo.AppendKey("S", "a.wav", 1) } }
  local rows = vo.BuildOverview({ lines = lines, matches = {}, entries = {} })
  assert(#rows >= 1, "no rows")
  assert(rows[1].line_text == "Bolvd no speak", "line_text: " ..
         tostring(rows[1].line_text))
  assert(rows[1].line_original == "Adon no speak", "line_original: " ..
         tostring(rows[1].line_original))
  assert(rows[1].line_edited == true, "line_edited not carried")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `lua tests/test_vo.lua 2>&1 | grep -E "FAIL"`
Expected: FAIL "line_original: nil"

- [ ] **Step 3: Implement**

Beside every `line_text = ...` in a row constructor, add the two fields. For
the `line` form:

```lua
      line_text     = line.text,
      line_original = line.text_original or line.text,
      line_edited   = line.text_edited,
```

For the `line and ...` (planned/orphan) form:

```lua
      line_text     = line and line.text or nil,
      line_original = line and (line.text_original or line.text) or nil,
      line_edited   = line and line.text_edited or nil,
```

`line_original` falls back to `line.text` so a row always has something to draw
in grey, even for a line built before `ApplyLineEdits` ran.

- [ ] **Step 4: Run to verify it passes**

Run: `./run_tests.sh 2>&1 | grep -cE "^  FAIL"`
Expected: `0`

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua
git commit -m "VO: overview rows carry the script's own words"
```

---

### Task 4: Wire it into the Overview

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — `state` init (~464), project load (~487),
  project save (~540), the script-load path (~433), reset (~5360), the remote
  seam (~7824 region)

**Interfaces:**
- Consumes: everything from Tasks 1–3
- Produces: `state.line_edits` (array), `state.orphan_line_edits` (array), and
  a `set_line` verb on the remote seam

- [ ] **Step 1: Add the state**

There is no new file-level `local` here — these are fields on the existing
`state` table, so the 200-local ceiling is not touched.

At `:464`, extend the reset:

```lua
  state.scripts, state.appends, state.pins = {}, {}, {}
  state.line_edits = {}
```

At `:487`, beside `state.appends = parsed.appends or {}`:

```lua
    state.line_edits = parsed.line_edits or {}
```

At `:540`, in the meta table passed to the serializer, add
`line_edits = state.line_edits,`.

At `:5360`, add `state.line_edits` to the same `= {}, {}, {}, {}` reset.

- [ ] **Step 2: Apply the edits where Appends are applied**

At `:433`, immediately BEFORE the `vo.ResolveNames` call:

```lua
  -- Before ResolveNames, because a name is derived from the line and the line
  -- is what an edit changes. They touch different fields today, so the order
  -- is insurance rather than a dependency.
  vo.ApplyLineEdits(state.loaded.lines, vo.LineEditMap(state.line_edits))
```

And after the `state.orphan_appends` assignment:

```lua
  state.orphan_line_edits = vo.OrphanLineEdits(state.line_edits,
                                               state.loaded.lines)
```

- [ ] **Step 3: Add the mutator, beside SetAppend**

`SetAppend` is at `:2273`. Add directly below it:

```lua
-- The edited line belongs to the SCRIPT LINE, like the Append, so it is written
-- to state.line_edits rather than through EntryFor -- every take of the line
-- picks it up on the next rebuild.
--
-- This DOES invalidate the match: the matcher scores against these words. The
-- scripts are re-loaded so the sheet shows the new text immediately, and
-- "Match transcript to script" is what re-scores -- the same contract as
-- editing the CSV on disk.
local function SetLineEdit(row, text)
  if not row.line_key then return end
  vo.SetLineEdit(state.line_edits, row.script or "", row.asset or "",
                 row.append_nth or 1, text)
  state.dirty = true
  LoadScripts()
  Rebuild()
end
```

`LoadScripts` (`VO/ajsfx_VO_Overview.lua:411`) is the function holding the
`ApplyLineEdits` / `ResolveNames` calls from step 2, so calling it re-reads the
CSVs and re-applies both. It is a `local function` declared at `:411`, well
above `SetAppend` at `:2273`, so it is in scope here.

- [ ] **Step 4: Add the remote seam verb**

Beside the `append` verb (~`:7824`), for the headless harness:

```lua
  elseif verb == "set_line" then
    -- rest is "<script>|<asset>|<nth>|<text>"
    local script, asset, nth, text = rest:match("^(.-)|(.-)|(%d+)|(.*)$")
    if not asset then return "usage: set_line <script>|<asset>|<nth>|<text>" end
    vo.SetLineEdit(state.line_edits, script, asset, tonumber(nth) or 1, text)
    state.dirty = true
    Reload()
    return "line edit set"
```

- [ ] **Step 5: Verify it loads**

Run: `lua -e "local f,e=loadfile('VO/ajsfx_VO_Overview.lua') print(e or 'PARSE OK')"`
Expected: `PARSE OK` — a failure here is the 200-local ceiling.

Run: `./run_tests.sh 2>&1 | grep -cE "^  FAIL"`
Expected: `0`

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: line edits load, save and reach the matcher"
```

---

### Task 5: The card

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — `DrawCardBand`, the line text (~6790),
  the filename menu (~6838, unchanged), `Script:` (~6862)
- Modify: `VO/MANUAL_TEST.md`

**Interfaces:**
- Consumes: `row.line_original`, `row.line_edited`, `SetLineEdit(row, text)`,
  `Copy(text)` (existing, `:5977`)

- [ ] **Step 1: The right-click menu on the line**

The line text at `:6790` stays `im.Text` — wrapped, unchanged. Wrap it so the
menu can attach, and remember the row's y for the grey line:

```lua
  if rep.line_text and rep.line_text ~= "" then
    im.SetCursorScreenPos(ctx, said_x, ry)
    im.PushTextWrapPos(ctx, im.GetCursorPosX(ctx) + (rx + z.name - 8 - said_x))
    wrap_depth = wrap_depth + 1
    im.Text(ctx, '"' .. rep.line_text .. '"')
    im.PopTextWrapPos(ctx)
    wrap_depth = wrap_depth - 1
    -- Both Copy items are ALWAYS here and never move. Sending someone a line
    -- has nothing to do with whether it was edited, and an item that appears
    -- and disappears makes the user open the menu to find out what is in it.
    -- When there is no edit the two copy the same text, which is the right
    -- answer to both questions.
    if im.BeginPopupContextItem(ctx, "##band_line_menu") then
      if im.MenuItem(ctx, "Copy") then Copy(rep.line_text) end
      if im.MenuItem(ctx, "Copy original line") then
        Copy(rep.line_original or rep.line_text)
      end
      im.Separator(ctx)
      if im.MenuItem(ctx, "Edit line…", nil, nil, rep.line_key ~= nil) then
        open_line_edit = true
      end
      -- Greyed rather than hidden, so it holds its slot instead of pulling
      -- "Edit line…" up under the cursor.
      if im.MenuItem(ctx, "Revert to script line", nil, nil,
                     rep.line_edited == true) then
        local captured = rep
        pending_action = function() SetLineEdit(captured, "") end
      end
      im.EndPopup(ctx)
    end
  end
```

Declare `local open_line_edit = false` inside `DrawCardBand` beside the
existing `local open_append = false` — a function-scope local, not file-scope.

- [ ] **Step 2: The Edit line popup**

Beside the `##append_edit` popup (~`:6846`):

```lua
  if open_line_edit then im.OpenPopup(ctx, "##line_edit") end
  if im.BeginPopup(ctx, "##line_edit") then
    im.Text(ctx, "What was actually said:")
    -- Multiline, because the line already wraps on the card and a single-line
    -- field would scroll a long one sideways. Enter is a newline here, so
    -- Ctrl+Enter commits.
    local lchanged, ltext = im.InputTextMultiline(
      ctx, "##line", rep.line_text or "", 420, 60)
    if lchanged then
      local captured = rep
      local text = ltext
      pending_action = function() SetLineEdit(captured, text) end
    end
    im.Spacing(ctx)
    if im.Button(ctx, "Revert to script line") then
      local captured = rep
      pending_action = function() SetLineEdit(captured, "") end
      im.CloseCurrentPopup(ctx)
    end
    im.SameLine(ctx)
    im.TextDisabled(ctx, "Press Match transcript to script to re-score.")
    im.EndPopup(ctx)
  end
```

- [ ] **Step 3: The grey original row**

The line's own row-2 position is `y2` (computed at `:6801`). Draw the grey
original directly under the line, pushing `y2` down, BEFORE the `if open` block
uses it:

```lua
  -- The script's own words, under the line as it will be matched. Never above:
  -- what the matcher uses reads first, the reference sits beneath it.
  --
  -- Unfolded, always -- an open card has a shape you can rely on, and reading
  -- the same words twice costs less than checking whether a row is missing.
  -- Folded, only when edited, because a folded card is one horizontal row and
  -- nothing else; there the grey row MEANS the line was changed.
  local orig = rep.line_original
  if orig and orig ~= "" and (open or rep.line_edited) then
    im.SetCursorScreenPos(ctx, said_x, y2)
    im.PushTextWrapPos(ctx, im.GetCursorPosX(ctx) + (rx + z.name - 8 - said_x))
    wrap_depth = wrap_depth + 1
    im.TextDisabled(ctx, '"' .. orig .. '"')
    im.PopTextWrapPos(ctx)
    wrap_depth = wrap_depth - 1
    if im.BeginPopupContextItem(ctx, "##band_orig_menu") then
      if im.MenuItem(ctx, "Copy original line") then Copy(orig) end
      im.EndPopup(ctx)
    end
    y2 = math.max(select(2, im.GetCursorScreenPos(ctx)), y2 + line_h) + 2
  end
```

- [ ] **Step 4: Right-click Copy on Script:**

At `:6864`, after the `im.TextDisabled(ctx, "Script: " .. script_name)` and its
tooltip:

```lua
    -- The card shows a basename with its extension stripped, so what is on
    -- screen is not what anyone needs to paste. The tooltip has the full path
    -- and a tooltip cannot be copied out of.
    if rep.script and rep.script ~= ""
       and im.BeginPopupContextItem(ctx, "##band_script_menu") then
      if im.MenuItem(ctx, "Copy full path") then Copy(rep.script) end
      if im.MenuItem(ctx, "Copy script name") then Copy(script_name) end
      im.EndPopup(ctx)
    end
```

- [ ] **Step 5: Verify it loads and the suite is green**

Run: `lua -e "local f,e=loadfile('VO/ajsfx_VO_Overview.lua') print(e or 'PARSE OK')"`
Expected: `PARSE OK`

Run: `./run_tests.sh 2>&1 | grep -cE "^  FAIL"`
Expected: `0`

- [ ] **Step 6: Add the manual checks**

Append to `VO/MANUAL_TEST.md`:

```markdown
## Editing a line (unreleased)

Nothing here is executed. The pure layer is unit-tested; the card is not.

1. Right-click a line's words. The menu reads Copy / Copy original line /
   ─── / Edit line… / Revert to script line, with Revert GREYED on an
   unedited line and the two Copy items always present.
2. Both Copy items on an unedited line put the same text on the clipboard.
3. Edit line… → type different words → the card shows them, and the script's
   own words appear in grey directly BELOW, never above.
4. Fold the card. The grey row stays, because the line is edited.
5. Fold an UNEDITED card. One row only — unchanged from today.
6. Unfold an unedited card. The grey row is there, identical to the line.
7. Press Match transcript to script. The edited line now scores against the
   edited words — a take that was missing should find its line.
8. Revert to script line, from the menu and from the popup button. Both clear
   the edit and the grey row goes on a folded card.
9. Save and reopen the project. The edit survives, as a `Line,` row in the
   project file.
10. Disable the script in Setup, then re-enable it. The edit is still there.
11. Right-click Script: → Copy full path gives the whole path, not the
    stripped basename on the card.
12. A long edited line still wraps before the filename column, and the grey
    row wraps with it.
```

- [ ] **Step 7: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua VO/MANUAL_TEST.md
git commit -m "VO: edit a line on its card, and copy the original"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| §2 data, Append's shape | 1 |
| §2 empty removes / equal-to-original stored | 1 (tested) |
| §2 project file `Line` row | 2 |
| §3 `ApplyLineEdits`, one override point | 1, wired in 4 |
| §3 no staleness badge; popup names the requirement | 5 step 2 |
| §4.1 line stays text | 5 step 1 |
| §4.2 grey original, folded/unfolded rule | 5 step 3 |
| §4.3 right-click menu, fixed items | 5 step 1 |
| §4.4 Edit line popup | 5 step 2 |
| §4.5 Script: copy; filename unchanged | 5 step 4 |
| §5 tests 1–8 | 1 (1–6), 2 (7–8) |

**Known gap, accepted:** spec §5 test 5 ("the matcher scores against the edited
text") is covered indirectly — `ApplyLineEdits` is tested to put the edit in
`line.text`, and the matcher's use of `line.text` is already tested. A direct
end-to-end matcher test would duplicate existing coverage of `text_for`.

**Type consistency:** `line.text_original` / `line.text_edited` (line tables,
Task 1) become `row.line_original` / `row.line_edited` (overview rows, Task 3).
The rename is deliberate — rows use the `line_` prefix for line-derived fields
(`line_text`, `line_key`) — and Task 3 is the only place both names appear.

**Names resolved:** the script-load path is `LoadScripts`
(`VO/ajsfx_VO_Overview.lua:411`) — a `local function` in scope at every call
site this plan adds. No placeholder names remain.
