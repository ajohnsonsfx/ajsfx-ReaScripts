# Todo-by-line Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Kill the Todo rail; each line card carries its own Todo strip (stage + errors), the sheet filters to lines with work, and the session is done when the filtered sheet is empty. Spec: `VO/SPEC-todo-by-line.md`.

**Architecture:** Pure layer first (widened `SelectConflicts`, `contested_select` findings, suppression in `InboxBuild`, new `LineStage`/`ErrorHome`/`TodoBuild`), then the UI rewire in `ajsfx_VO_Overview.lua` (rail deleted, card strips + Session card drawn from `TodoBuild` output). TDD for every pure function; `luac -p` after every Overview edit.

**Tech Stack:** Lua 5.4, mock REAPER tests (`tests/mock_reaper.lua`), ReaImGui UI.

## Global Constraints

- **Branch:** all work on `feature/todo-by-line`; merge to `main` releases (CI rebuilds index).
- **`VO/ajsfx_VO_Overview.lua` is at Lua's 200-local cap.** NO new top-level `local function` or `local` table — extend the existing `Inbox`, `Strip`, `Trim` tables. Verify with `luac -p VO/ajsfx_VO_Overview.lua` after EVERY edit to that file; green tests do not prove it compiles.
- **Copy rule (AJ):** the conflict count reads "N lines with multiple selects" everywhere (not "two selects").
- **Verb law (AJ):** a Todo row offers a button only for a fix that is already a button somewhere else. Stage rows are jump-only.
- **Edit-boundary law:** every multi-step mutation is one `core.Transaction`/`Batch`. Feed identity checks in `Inbox.MaybeAssemble` are the refresh gate — do not add timers.
- **Tests:** `./run_tests.sh` (or `bash run_tests.sh` on Windows). All existing tests must stay green.
- **Do not bump `@version` until the final task.**

## File Structure

- `VO/lib/ajsfx_vo.lua` — all new pure logic: `SelectConflicts` (widened), `INBOX_WEIGHT.contested_select`, `INBOX_SUPPRESS` behavior inside `InboxBuild`, `TODO_STAGES`/`TODO_STAGE_LABEL`, `LineStage`, `ErrorHome`, `TodoBuild`.
- `VO/ajsfx_VO_Overview.lua` — UI rewire: `Inbox.MaybeAssemble` feeds `TodoBuild`; rail drawing deleted; `Inbox.DrawStrip` (per-card) and `Inbox.DrawSession` (pinned card) added; layout split removed; filter + toggle + copy.
- `tests/test_vo_tidy.lua` — widened `SelectConflicts` tests.
- `tests/test_vo_inbox.lua` — `contested_select`, suppression, `LineStage`, `ErrorHome`, `TodoBuild` tests.

---

### Task 1: Widen `vo.SelectConflicts` — parked on Selects counts as a claimant

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (`vo.SelectConflicts`, ~line 2366)
- Test: `tests/test_vo_tidy.lua`

**Interfaces:**
- Produces: `vo.SelectConflicts(rows, cfg)` → array of `{ key, label, count, claimants = {rows} }`. `cfg` optional (nil → `MarkFromTrack` defaults). A row claims when `user_select == true` OR `vo.MarkFromTrack(row.track_name, cfg) == "select"`, excluding `status == "orphan"` and `status == "missing"`.

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feature/todo-by-line
```

- [ ] **Step 2: Write the failing tests** — append to the `SelectConflicts:` section of `tests/test_vo_tidy.lua` (before the `ResolveScope:` print):

```lua
test("one ticked + one parked on Selects = contested (the originating bug)", function()
  local rows = {
    { script_row = "s1", asset = "line_a", deliver = "line_a",
      user_select = true, track_name = "Alts" },
    { script_row = "s1", asset = "line_a", deliver = "line_a",
      track_name = "Selects" },
  }
  local c = vo.SelectConflicts(rows)
  assert(#c == 1, "expected 1 conflict, got " .. #c)
  assert(c[1].count == 2, "count: " .. tostring(c[1].count))
  assert(#c[1].claimants == 2, "claimants ride the entry")
end)

test("one ticked + one on Alts = not contested", function()
  local rows = {
    { script_row = "s1", asset = "line_a", user_select = true, track_name = "Selects" },
    { script_row = "s1", asset = "line_a", track_name = "Alts" },
  }
  assert(#vo.SelectConflicts(rows) == 0)
end)

test("custom Selects track name honoured through cfg", function()
  local rows = {
    { script_row = "s1", asset = "line_a", track_name = "MyPicks" },
    { script_row = "s1", asset = "line_a", track_name = "MyPicks" },
  }
  assert(#vo.SelectConflicts(rows) == 0, "default cfg: MyPicks is not Selects")
  local c = vo.SelectConflicts(rows, { track_selects = "MyPicks" })
  assert(#c == 1, "cfg names the track: contested")
end)

test("missing rows never claim", function()
  local rows = {
    { script_row = "s1", asset = "line_a", user_select = true, track_name = "Selects" },
    { script_row = "s1", asset = "line_a", status = "missing", track_name = "Selects" },
  }
  assert(#vo.SelectConflicts(rows) == 0)
end)
```

- [ ] **Step 3: Run to verify the new tests fail**

Run: `bash run_tests.sh 2>&1 | grep -A2 "FAIL"`
Expected: the parked-on-Selects and cfg tests FAIL (count 0, no `claimants` field).

- [ ] **Step 4: Implement** — replace the body of `vo.SelectConflicts`:

```lua
-- Lines with more than one CLAIMANT for the select. A take claims when it is
-- ticked Sel OR merely parked on the Selects track (EffectiveMarks rule 2
-- would tick it on the next rebuild anyway) -- counting only the ticks let a
-- line with one tick and one parked take read as settled when it was not
-- (SPEC-todo-by-line.md). Not an error state to be prevented -- dragging
-- legitimately creates it -- but a decision the user still has to make.
-- Orphans are not lines and missing rows have nothing on any track.
function vo.SelectConflicts(rows, cfg)
  local by_key, order = {}, {}
  for _, row in ipairs(rows or {}) do
    local claims = row.status ~= "orphan" and row.status ~= "missing"
      and (row.user_select == true
           or vo.MarkFromTrack(row.track_name, cfg) == "select")
    if claims then
      local key = vo.LineKey(row)
      local got = by_key[key]
      if not got then
        got = { key = key, label = row.deliver or row.asset or "(unnamed)",
                count = 0, claimants = {} }
        by_key[key] = got
        order[#order + 1] = got
      end
      got.count = got.count + 1
      got.claimants[#got.claimants + 1] = row
    end
  end
  local out = {}
  for _, c in ipairs(order) do
    if c.count >= 2 then out[#out + 1] = c end
  end
  return out
end
```

- [ ] **Step 5: Run the full suite**

Run: `bash run_tests.sh`
Expected: all PASS (the pre-existing `SelectConflicts` tests use ticked rows with no `track_name`, so they still pass unchanged).

- [ ] **Step 6: Update the two callers and the copy** in `VO/ajsfx_VO_Overview.lua`:

At ~line 1145 (`Rebuild`): `state.conflicts = vo.SelectConflicts(state.overview)` →

```lua
state.conflicts = vo.SelectConflicts(state.overview, cfg)
```

(A `cfg` local from `vo.LoadConfig()` is in scope in `Rebuild`; if the surrounding function has none, use `vo.LoadConfig()` directly.)

At ~line 8202 (Tidy): same change. Then the copy at ~8221:

```lua
    bits[#bits + 1] = #conflicts .. " line(s) with multiple selects -- pick one"
```

and at ~8288:

```lua
    parts[#parts + 1] = string.format(
      "%d line(s) with multiple selects -- pick one.", #conflicts)
```

Also widen the Sel-checkbox ring at ~11855: a parked-but-unticked claimant should ring too. Replace the `contested` condition:

```lua
    local contested = row.status ~= "orphan"
                      and (row.user_select == true
                           or vo.MarkFromTrack(row.track_name, state.cfg or vo.LoadConfig()) == "select")
                      and state.conflict_keys
                      and state.conflict_keys[vo.LineKey(row)]
```

(If there is no `state.cfg`, call `vo.LoadConfig()`; it is cached internally per tick elsewhere — match whatever the surrounding card code already uses for cfg.)

And in the contested tooltip at ~11886, change "THIS LINE HAS %d" wording only if it still says "two": leave the body, it already counts.

- [ ] **Step 7: Compile check + tests**

Run: `luac -p VO/ajsfx_VO_Overview.lua && bash run_tests.sh`
Expected: no output from luac; all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add VO/lib/ajsfx_vo.lua VO/ajsfx_VO_Overview.lua tests/test_vo_tidy.lua
git commit -m "SelectConflicts: a take parked on Selects claims the select"
```

---

### Task 2: `contested_select` findings enter `vo.InboxBuild`

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (`vo.INBOX_WEIGHT` ~6724, `vo.InboxBuild` ~6730)
- Test: `tests/test_vo_inbox.lua`

**Interfaces:**
- Consumes: `vo.SelectConflicts` output (Task 1) passed as `src.contested`.
- Produces: findings of `kind = "contested_select"`, `weight = 15`, `payload = <the conflict entry {key,label,count,claimants}>`.

- [ ] **Step 1: Write the failing test** — append to `tests/test_vo_inbox.lua`:

```lua
test("contested_select ranks above out_of_sync, below suspect_select", function()
  local f = vo.InboxBuild({
    parity_queue = { { item = "i1" } },
    contested    = { { key = "s1", label = "line_a", count = 2, claimants = {} } },
    suspects     = { { track = "Selects", row = {} } },
    selects_track = "Selects",
  })
  assert(f[1].kind == "suspect_select", "1st: " .. f[1].kind)
  assert(f[2].kind == "contested_select", "2nd: " .. f[2].kind)
  assert(f[3].kind == "out_of_sync", "3rd: " .. f[3].kind)
  assert(f[2].payload.label == "line_a", "payload is the conflict entry")
end)
```

- [ ] **Step 2: Run to verify it fails**

Run: `bash run_tests.sh 2>&1 | grep -B1 -A2 FAIL`
Expected: FAIL — `contested_select` never emitted.

- [ ] **Step 3: Implement** — add to `vo.INBOX_WEIGHT`:

```lua
vo.INBOX_WEIGHT = {
  suspect_select = 10, contested_select = 15, out_of_sync = 20, no_audio = 30,
  unidentified = 40, undecided = 50, suspect = 60, unheard = 70,
  scan_suspects = 60, scan_unheard = 70,
}
```

and in `vo.InboxBuild`, after the suspects loop:

```lua
  for _, c in ipairs(src.contested or {}) do add("contested_select", c) end
```

- [ ] **Step 4: Run tests** — `bash run_tests.sh` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo_inbox.lua
git commit -m "InboxBuild: contested_select findings, weight 15"
```

---

### Task 3: Causal suppression inside `vo.InboxBuild`

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (`vo.InboxBuild`)
- Test: `tests/test_vo_inbox.lua`

**Interfaces:**
- Produces: `vo.InboxBuild` drops (a) `out_of_sync` findings whose `payload.row` is on a contested line AND whose `payload.detail` names the track; (b) `thin`/`no_words` triggers from suspect findings whose `payload.row` also has a `no_audio` finding — the whole suspect finding when no trigger survives. Dropped findings are absent from the array and from `counts`.

- [ ] **Step 1: Write the failing tests:**

```lua
test("contested line swallows its track-placement out_of_sync", function()
  local row = { script_row = "s1", asset = "line_a" }
  local f, c = vo.InboxBuild({
    contested = { { key = "s1", label = "line_a", count = 2, claimants = {} } },
    disagree  = { { row = row, detail = "on the Selects track but not ticked Sel" },
                  { row = row, detail = "something else entirely" } },
  })
  local kinds = {}
  for _, x in ipairs(f) do kinds[#kinds + 1] = x.kind .. ":" .. tostring((x.payload or {}).detail) end
  assert(c.total == 2, "contested + surviving oos; got " .. c.total
         .. " [" .. table.concat(kinds, ", ") .. "]")
  assert(c.by_kind.out_of_sync == 1, "non-placement out_of_sync survives")
end)

test("uncontested line keeps its track-placement finding", function()
  local f, c = vo.InboxBuild({
    disagree = { { row = { script_row = "s2" },
                   detail = "ticked Sel but the item is not on the Selects track" } },
  })
  assert(c.by_kind.out_of_sync == 1)
end)

test("no_audio swallows thin and no_words on the same row; name_mismatch survives", function()
  local row = { script_row = "s3", asset = "line_c" }
  local f, c = vo.InboxBuild({
    no_audio = { { row = row, why = "unbacked" } },
    suspects = { { row = row, triggers = { thin = true, no_words = true, name_mismatch = true } },
                 { row = { script_row = "s4" }, triggers = { thin = true } } },
  })
  assert(c.by_kind.no_audio == 1)
  assert(c.by_kind.suspect == 2, "s3 suspect survives (name_mismatch), s4 untouched")
  for _, x in ipairs(f) do
    if x.kind == "suspect" and x.payload.row == row then
      assert(not x.payload.triggers.thin and not x.payload.triggers.no_words,
             "thin/no_words gone")
      assert(x.payload.triggers.name_mismatch, "name_mismatch kept")
    end
  end
end)

test("no_audio swallows a suspect whose only triggers were thin/no_words", function()
  local row = { script_row = "s5" }
  local f, c = vo.InboxBuild({
    no_audio = { { row = row } },
    suspects = { { row = row, triggers = { thin = true } } },
  })
  assert(c.by_kind.suspect == nil, "nothing left to say")
  assert(c.total == 1, "just the no_audio")
end)
```

- [ ] **Step 2: Run to verify they fail** — `bash run_tests.sh 2>&1 | grep -A2 FAIL`

- [ ] **Step 3: Implement** — in `vo.InboxBuild`, BEFORE the `add` loops, filter the sources. Insert after `local sel = src.selects_track`:

```lua
  -- CAUSAL SUPPRESSION (SPEC-todo-by-line.md Req-3): a finding that is the
  -- downstream shadow of another on the same line is deleted -- not counted,
  -- not drawn. It returns by itself when the root clears, because scanners
  -- rerun each rebuild. Rule of admission: if clearing the root would not
  -- make the symptom vanish on the next rebuild, it is not a symptom.
  local contested_keys = {}
  for _, c in ipairs(src.contested or {}) do contested_keys[c.key] = true end
  local disagree = {}
  for _, d in ipairs(src.disagree or {}) do
    -- "On the Selects track but not ticked Sel" is the arithmetic of the
    -- contest, not news. Same placement test the OK-stamp bypass uses.
    local placement = d.detail and d.detail:find("track", 1, true)
    local swallowed = placement and d.row and contested_keys[vo.LineKey(d.row)]
    if not swallowed then disagree[#disagree + 1] = d end
  end

  local no_audio_rows = {}
  for _, e in ipairs(src.no_audio or {}) do
    if e.row then no_audio_rows[e.row] = true end
  end
  local suspects = {}
  for _, s in ipairs(src.suspects or {}) do
    if s.row and no_audio_rows[s.row]
       and (s.triggers or {}).thin ~= nil or s.row and no_audio_rows[s.row]
       and (s.triggers or {}).no_words ~= nil then
      -- thin / no_words on a row whose marker has no audio reports that no
      -- words were found in audio that is not there. Triggers about the
      -- MARKS (name_mismatch, unmarked, stamp) survive -- the marks exist.
      local kept = {}
      for t in pairs(s.triggers or {}) do
        if t ~= "thin" and t ~= "no_words" then kept[t] = true end
      end
      if next(kept) then
        local copy = {}
        for k2, v2 in pairs(s) do copy[k2] = v2 end
        copy.triggers = kept
        suspects[#suspects + 1] = copy
      end
    else
      suspects[#suspects + 1] = s
    end
  end
```

**Careful with the condition above** — Lua's `and`/`or` precedence makes the draft wrong; write it as:

```lua
    local shadowed = s.row and no_audio_rows[s.row]
      and ((s.triggers or {}).thin or (s.triggers or {}).no_words)
    if shadowed then
      ... (the kept/copy block)
    else
      suspects[#suspects + 1] = s
    end
```

Then change the two `add` loops to iterate the filtered `disagree` and `suspects` locals instead of `src.disagree` / `src.suspects`. The suspect copy (not mutation) matters: `src.suspects` entries are `state.suspects` rows the UI still owns.

- [ ] **Step 4: Run the full suite** — `bash run_tests.sh` — all PASS (existing inbox tests unaffected: none pass both `no_audio` and `suspects` sharing a row).

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo_inbox.lua
git commit -m "InboxBuild: causal suppression -- contested swallows placement, no_audio swallows the words"
```

---

### Task 4: The stage ladder — `vo.LineStage` and `vo.ErrorHome`

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (new functions, place directly after `vo.InboxBuild`)
- Test: `tests/test_vo_inbox.lua`

**Interfaces:**
- Produces:
  - `vo.TODO_STAGES = { "not_scanned", "not_found", "needs_edit", "needs_select", "unverified", "done" }` (ordered) and `vo.TODO_STAGE_LABEL` (id → display string: "Not Scanned", "Not Found", "Needs edit", "Needs select", "Unverified", "Done").
  - `vo.StageIndex(id)` → 1..6.
  - `vo.LineStage(g)` → stage id, from a gather `g = { has_takes, any_item, any_uncut, picked, verified, scanned }`.
  - `vo.ErrorHome(finding)` → stage id or nil (nil = not an error: `undecided`, `unheard`, `scan_*`, `unidentified`).

- [ ] **Step 1: Write the failing tests:**

```lua
print("\nLineStage / ErrorHome:")

test("the ladder in order", function()
  assert(vo.LineStage({ has_takes = true, any_item = true, scanned = false }) == "not_scanned")
  assert(vo.LineStage({ has_takes = false, scanned = true }) == "not_found")
  assert(vo.LineStage({ has_takes = true, any_item = false, scanned = true }) == "not_found",
         "takes whose audio left the project are Not Found")
  assert(vo.LineStage({ has_takes = true, any_item = true, any_uncut = true,
                        scanned = true }) == "needs_edit")
  assert(vo.LineStage({ has_takes = true, any_item = true, scanned = true }) == "needs_select")
  assert(vo.LineStage({ has_takes = true, any_item = true, picked = true,
                        scanned = true }) == "unverified")
  assert(vo.LineStage({ has_takes = true, any_item = true, picked = true,
                        verified = true, scanned = true }) == "done")
end)

test("a line with nothing recorded is Not Found even before a scan", function()
  assert(vo.LineStage({ has_takes = false, scanned = false }) == "not_found",
         "nothing to scan -- Not Scanned is only for lines a scanner would judge")
end)

test("error homes match the AJ-approved mapping", function()
  assert(vo.ErrorHome({ kind = "no_audio", payload = {} }) == "not_found")
  assert(vo.ErrorHome({ kind = "out_of_sync",
                        payload = { divergence = { fields = {} } } }) == "needs_edit")
  assert(vo.ErrorHome({ kind = "out_of_sync", payload = { row = {} } }) == "needs_select",
         "marks vs track is a select question")
  assert(vo.ErrorHome({ kind = "contested_select", payload = {} }) == "needs_select")
  assert(vo.ErrorHome({ kind = "suspect",
                        payload = { triggers = { name_mismatch = true } } }) == "unverified")
  assert(vo.ErrorHome({ kind = "suspect",
                        payload = { triggers = { unmarked = true, stamp = true } } }) == "needs_edit",
         "earliest home among a suspect's triggers wins")
  assert(vo.ErrorHome({ kind = "suspect_select",
                        payload = { triggers = { stamp = true } } }) == "unverified")
  assert(vo.ErrorHome({ kind = "undecided", payload = {} }) == nil,
         "undecided is a stage, not an error")
  assert(vo.ErrorHome({ kind = "unheard", payload = {} }) == nil)
end)
```

- [ ] **Step 2: Run to verify they fail** — `bash run_tests.sh 2>&1 | grep -A2 FAIL`

- [ ] **Step 3: Implement:**

```lua
-- THE STAGE LADDER (SPEC-todo-by-line.md, AJ's names): a line has exactly ONE
-- stage -- its place in the pipeline -- and shows the earliest unmet rung.
vo.TODO_STAGES = { "not_scanned", "not_found", "needs_edit",
                   "needs_select", "unverified", "done" }
vo.TODO_STAGE_LABEL = {
  not_scanned = "Not Scanned", not_found = "Not Found",
  needs_edit = "Needs edit", needs_select = "Needs select",
  unverified = "Unverified", done = "Done",
}

local STAGE_INDEX = {}
for i, id in ipairs(vo.TODO_STAGES) do STAGE_INDEX[id] = i end
function vo.StageIndex(id) return STAGE_INDEX[id] end

-- g: has_takes (a row with take_index > 0 and not missing), any_item (a row
-- with a live item), any_uncut (an item still holding >1 counting marker),
-- picked (user_select somewhere), verified (user_status "verified"
-- somewhere), scanned (the suspects scan ran this session).
function vo.LineStage(g)
  g = g or {}
  -- Not Scanned only for lines a scanner would judge: delivered audio. A
  -- line with nothing recorded is Not Found no matter what has not run.
  if not g.has_takes or not g.any_item then return "not_found" end
  if not g.scanned then return "not_scanned" end
  if g.any_uncut then return "needs_edit" end
  if not g.picked and not g.verified then return "needs_select" end
  if not g.verified then return "unverified" end
  return "done"
end
```

**NOTE the ordering subtlety vs the test:** the test asserts `not_scanned` for `{has_takes=true, any_item=true, scanned=false}` and `not_found` for `{has_takes=false, scanned=false}` — the implementation above satisfies both because Not Found is checked first. AJ's ladder lists Not Scanned first, but a line that does not exist in the audio cannot be scanned; the DISPLAY order (Not Scanned first) is about lines that have audio. Keep the comment.

```lua
-- Which stage's work fixes each error kind (AJ-approved mapping,
-- SPEC-todo-by-line.md Req-1). nil = the finding is not an error: it is a
-- stage (`undecided`), a session-level row (`unheard`), or already
-- dissolved into the ladder (`scan_*`).
local SUSPECT_HOME = { unmarked = "needs_edit", name_mismatch = "unverified",
                       stamp = "unverified", thin = "unverified",
                       no_words = "unverified" }
function vo.ErrorHome(f)
  local k = f and f.kind
  local p = (f and f.payload) or {}
  if k == "no_audio" then return "not_found" end
  if k == "contested_select" then return "needs_select" end
  if k == "out_of_sync" then
    -- Parity divergences (name/edges vs marker) are edit work; the
    -- PlanReconcile flavour (marks vs track) is a select question.
    return p.divergence and "needs_edit" or "needs_select"
  end
  if k == "suspect" or k == "suspect_select" then
    local best
    for t in pairs(p.triggers or {}) do
      local h = SUSPECT_HOME[t]
      if h and (not best or STAGE_INDEX[h] < STAGE_INDEX[best]) then best = h end
    end
    return best or "unverified"
  end
  return nil
end
```

`SUSPECT_HOME` and `STAGE_INDEX` are file-locals — `ajsfx_vo.lua` is nowhere near the local cap (that constraint is the Overview's).

- [ ] **Step 4: Run tests** — `bash run_tests.sh` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo_inbox.lua
git commit -m "Pure layer: the stage ladder (LineStage) and error home stages (ErrorHome)"
```

---

### Task 5: `vo.TodoBuild` — the per-line collapse

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (new function after `vo.ErrorHome`)
- Test: `tests/test_vo_inbox.lua`

**Interfaces:**
- Consumes: `vo.InboxBuild` output, `vo.LineKey`, `vo.LineStage`, `vo.ErrorHome`, `vo.StageIndex`.
- Produces:

```lua
-- todo, counts = vo.TodoBuild{
--   findings    = <vo.InboxBuild output>,
--   rows        = <state.overview>,
--   uncut       = { [item] = true },   -- items still holding >1 counting marker
--   scanned     = <bool: suspects scan ran>,
--   row_of_item = { [item] = row },    -- resolve item-only findings to lines
-- }
-- todo = {
--   lines   = { entry, ... },          -- ONLY lines with work, sheet order
--   by_key  = { [line key] = entry },  -- the sheet filter's lookup
--   session = { finding, ... },        -- line-less findings (unheard)
-- }
-- entry = { key, label, stage = <id>, stage_label = <display>,
--           conflict = <bool: any errors>, errors = { finding, ... } }
-- counts = { total = #lines + #session, lines = #lines, session = #session }
```

- [ ] **Step 1: Write the failing tests:**

```lua
print("\nTodoBuild:")

local function tb(src) return vo.TodoBuild(src) end

test("three findings across two takes of one line collapse to one entry", function()
  local r1 = { script_row = "s1", asset = "line_a", deliver = "line_a",
               take_index = 1, item = "i1" }
  local r2 = { script_row = "s1", asset = "line_a", deliver = "line_a",
               take_index = 2, item = "i2" }
  local findings = vo.InboxBuild({
    disagree = { { row = r1, detail = "something" },
                 { row = r2, detail = "something else" } },
    suspects = { { row = r2, triggers = { name_mismatch = true } } },
  })
  local todo, counts = tb({ findings = findings, rows = { r1, r2 }, scanned = true })
  assert(counts.lines == 1, "one LINE, got " .. counts.lines)
  assert(counts.total == 1)
  assert(#todo.lines[1].errors == 3, "all three findings ride the entry")
end)

test("errors pull the stage back to their home, never forward", function()
  local r1 = { script_row = "s1", asset = "line_a", take_index = 1, item = "i1",
               user_select = true, user_status = "verified" }
  local findings = vo.InboxBuild({
    contested = { { key = "s1", label = "line_a", count = 2, claimants = { r1 } } },
  })
  local todo = tb({ findings = findings, rows = { r1 }, scanned = true })
  local e = todo.lines[1]
  assert(e.stage == "needs_select", "verified line dropped back: " .. tostring(e.stage))
  assert(e.conflict == true)
  assert(e.stage_label == "Needs select")
end)

test("a clean unfinished line is stage-only work, no errors", function()
  local r1 = { script_row = "s1", asset = "line_a", take_index = 1, item = "i1" }
  local todo, counts = tb({ findings = {}, rows = { r1 }, scanned = true })
  local e = todo.lines[1]
  assert(e.stage == "needs_select" and e.conflict == false and #e.errors == 0)
  assert(counts.total == 1)
end)

test("a done line is absent", function()
  local r1 = { script_row = "s1", asset = "line_a", take_index = 1, item = "i1",
               user_select = true, user_status = "verified" }
  local todo, counts = tb({ findings = {}, rows = { r1 }, scanned = true })
  assert(counts.total == 0, "got " .. counts.total)
  assert(todo.by_key["s1"] == nil)
end)

test("scanner not run: delivered lines sit at Not Scanned", function()
  local r1 = { script_row = "s1", asset = "line_a", take_index = 1, item = "i1" }
  local r2 = { script_row = "s2", asset = "line_b", status = "missing" }
  local todo = tb({ findings = {}, rows = { r1, r2 }, scanned = false })
  assert(todo.by_key["s1"].stage == "not_scanned")
  assert(todo.by_key["s2"].stage == "not_found",
         "nothing recorded is Not Found regardless of scan state")
end)

test("uncut items put the line at Needs edit", function()
  local r1 = { script_row = "s1", asset = "line_a", take_index = 1, item = "rec" }
  local todo = tb({ findings = {}, rows = { r1 }, scanned = true,
                    uncut = { rec = true } })
  assert(todo.by_key["s1"].stage == "needs_edit")
end)

test("item-only findings resolve to their line through row_of_item", function()
  local r1 = { script_row = "s1", asset = "line_a", take_index = 1, item = "i1" }
  local findings = vo.InboxBuild({
    parity_queue = { { item = "i1", divergence = { fields = { "name" } } } },
  })
  local todo, counts = tb({ findings = findings, rows = { r1 }, scanned = true,
                            row_of_item = { i1 = r1 } })
  assert(counts.lines == 1, "merged into the line, not a stray")
  assert(#todo.lines[1].errors == 1)
end)

test("line-less findings land on the session list", function()
  local findings = vo.InboxBuild({
    unheard = { { source_path = "a.wav", start = 1, stop = 2 } },
  })
  local todo, counts = tb({ findings = findings, rows = {}, scanned = true })
  assert(counts.session == 1 and counts.lines == 0 and counts.total == 1)
  assert(todo.session[1].kind == "unheard")
end)

test("orphan rows are not lines", function()
  local r1 = { asset = "junk", status = "orphan", take_index = 1, item = "i1" }
  local todo, counts = tb({ findings = {}, rows = { r1 }, scanned = true })
  assert(counts.total == 0)
end)
```

- [ ] **Step 2: Run to verify they fail** — `bash run_tests.sh 2>&1 | grep -A2 FAIL`

- [ ] **Step 3: Implement:**

```lua
-- THE COLLAPSE (SPEC-todo-by-line.md): findings and rows in, one entry per
-- LINE with work out. An entry's stage is the earliest of its ladder rung
-- (vo.LineStage) and any live error's home stage -- a verified line that
-- grows a second select drops back to Needs select, because picking the
-- select is the work you now have to redo. Done lines are simply absent:
-- the sheet's Todo filter drains as work completes.
function vo.TodoBuild(src)
  src = src or {}
  local uncut = src.uncut or {}
  local row_of_item = src.row_of_item or {}

  -- Gather per line, in sheet (rows) order.
  local by_key, order = {}, {}
  local function line_of(key, label)
    local g = by_key[key]
    if not g then
      g = { key = key, label = label or "(unnamed)", errors = {},
            gather = { scanned = src.scanned == true } }
      by_key[key] = g
      order[#order + 1] = g
    end
    return g
  end
  for _, row in ipairs(src.rows or {}) do
    if row.status ~= "orphan" then
      local g = line_of(vo.LineKey(row), row.deliver or row.asset)
      local ga = g.gather
      if row.status ~= "missing" and (row.take_index or 0) > 0 then
        ga.has_takes = true
        if row.item then ga.any_item = true end
      end
      if row.item and uncut[row.item] then ga.any_uncut = true end
      if row.user_select then ga.picked = true end
      if row.user_status == "verified" then ga.verified = true end
    end
  end

  -- Attach errors; line-less findings go to the session list.
  local session = {}
  for _, f in ipairs(src.findings or {}) do
    local home = vo.ErrorHome(f)
    if home then
      local p = f.payload or {}
      local row = p.row or (p.item and row_of_item[p.item]) or nil
      local key = (f.kind == "contested_select" and p.key)
                  or (row and vo.LineKey(row)) or nil
      if key then
        local g = line_of(key, p.label or (row and (row.deliver or row.asset)))
        g.errors[#g.errors + 1] = f
        local h = vo.StageIndex(home)
        if not g.err_stage or h < g.err_stage then g.err_stage = h end
      else
        -- An error that resolves to no line at all (item gone, no row):
        -- session-level, still visible, never silently dropped.
        session[#session + 1] = f
      end
    elseif f.kind == "unheard" then
      session[#session + 1] = f
    end
    -- undecided / scan_* / unidentified: dissolved into the ladder; skip.
  end

  -- Resolve stages, keep only lines with work.
  local lines, out_by_key = {}, {}
  for _, g in ipairs(order) do
    local ladder = vo.StageIndex(vo.LineStage(g.gather))
    local at = g.err_stage and math.min(g.err_stage, ladder) or ladder
    local id = vo.TODO_STAGES[at]
    if id ~= "done" or #g.errors > 0 then
      local entry = { key = g.key, label = g.label, stage = id,
                      stage_label = vo.TODO_STAGE_LABEL[id],
                      conflict = #g.errors > 0, errors = g.errors }
      lines[#lines + 1] = entry
      out_by_key[g.key] = entry
    end
  end

  local counts = { lines = #lines, session = #session,
                   total = #lines + #session }
  return { lines = lines, by_key = out_by_key, session = session }, counts
end
```

Note the `id ~= "done" or #errors > 0` guard: error homes are all earlier than `done`, so an entry with errors can never compute `done` — the guard is belt-and-braces, keep it (Done requires ladder cleared AND zero errors; the invariant should not depend on the mapping table staying that way).

- [ ] **Step 4: Run the full suite** — `bash run_tests.sh` — all PASS.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo_inbox.lua
git commit -m "TodoBuild: findings + rows collapse to one entry per line with work"
```

---

### Task 6: UI rewire — feed `TodoBuild`, delete the rail, draw card strips + Session card

This is the big Overview edit. **`luac -p VO/ajsfx_VO_Overview.lua` after every sub-step** — the file is at the 200-local cap; every new function must hang off the existing `Inbox` table.

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`:
  - `Inbox.MaybeAssemble` (~9650)
  - `Inbox.Draw` (~10114) — body replaced
  - the Todo count button (~10551–10572)
  - the layout split (~14197–14333)
  - the card draw (locate: the per-take marks row is at ~11845; the card's line-header block is above it — grep `state.conflict_keys` and walk up to where one CARD begins/ends)

**Interfaces:**
- Consumes: `vo.TodoBuild` (Task 5 shape), `Inbox.Parts`, `Inbox.RowVerbs`, `Inbox.Jump`, `Inbox.FixVerbs` — all kept.
- Produces: `state.todo` (the `todo` table), `state.inbox_counts` (the `counts`), `state.todo_hidden` (strip visibility, ExtState-persisted), `Inbox.DrawStrip(entry, indent)`, `Inbox.DrawSession()`.

- [ ] **Step 1: Rewire `Inbox.MaybeAssemble`.** Add `state.conflicts` to the staleness identity check (new pair `state.inbox_seen_conf == state.conflicts`), and after the existing `vo.InboxBuild` call (which gains `contested = state.conflicts` and LOSES the `undecided` and `scanned` feeds — delete the `groups/seen/undecided` block above it and the `scanned = {...}` line):

```lua
  state.inbox, _ = vo.InboxBuild({
    parity_queue = queue,
    disagree     = disagree,
    no_audio     = no_audio,
    contested    = state.conflicts,
    suspects     = state.suspects,
    unheard      = state.unheard,
    selects_track = cfg.track_selects or "Selects",
  })
  -- Item-only findings (parity divergences) resolve to their line through
  -- the overview, not the take-name stem -- the reconciled project state is
  -- the authority (AJ, spec Req-5).
  local by_item = {}
  for _, row in ipairs(state.overview or {}) do
    if row.item then by_item[row.item] = row end
  end
  state.todo, state.inbox_counts = vo.TodoBuild({
    findings    = state.inbox,
    rows        = state.overview,
    uncut       = Strip.uncut,
    scanned     = state.suspects ~= nil,
    row_of_item = by_item,
  })
```

Delete the "DISPLAY ORDER IS WALK ORDER" reshuffle block below it entirely (buckets/by_key/ordered) — `TodoBuild` owns grouping now. Keep the `state.inbox_sel` clamp but clamp against `#state.todo.lines`.

**Ordering hazard:** `Strip.uncut` is computed in the strip's refresh (~10362); confirm it runs before `Inbox.MaybeAssemble` in the frame (`MaybeAssemble` is called at ~13876 and from the seam at ~13067). If the strip refresh runs later, hoist the `uncut` computation into `Rebuild` or read `state.take_markers` directly in `MaybeAssemble` using the same `vo.CountingMarkers` loop — copy the loop, do not move `Strip`'s.

- [ ] **Step 2: Replace `Inbox.Draw` with the two new drawers.** Delete the whole rail body (the `BeginChild`/group loop). New functions on the same table:

```lua
-- One line's Todo strip, drawn INSIDE its card (SPEC-todo-by-line.md):
-- the stage header ("Needs select · Conflict"), then one amber row per
-- error with its evidence and verbs. Stage rows are jump-only -- a Todo
-- row offers a button only for a fix that is already a button somewhere
-- else (AJ's verb law).
function Inbox.DrawStrip(entry, indent)
  im.SetCursorPosX(ctx, im.GetCursorPosX(ctx) + (indent or 14))
  local head = entry.stage_label
  if entry.conflict then head = head .. " \194\183 Conflict" end
  im.PushStyleColor(ctx, im.Col_Text, 0xDDAA33FF)
  im.Text(ctx, head)
  im.PopStyleColor(ctx)
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, "The next work on this line. Clears on its own\n" ..
                       "when the state that caused it is fixed.")
  end
  for i, f in ipairs(entry.errors) do
    local parts = Inbox.Parts(f)
    local cat = parts.cat
    if parts.take and parts.take ~= "" then cat = cat .. " " .. parts.take end
    im.SetCursorPosX(ctx, im.GetCursorPosX(ctx) + (indent or 14) + 8)
    im.PushStyleColor(ctx, im.Col_Text, 0xDDAA33FF)
    if im.SmallButton(ctx, Inbox.Clip(cat, 34) .. "##tds" .. entry.key .. i) then
      Inbox.Jump(f)
    end
    im.PopStyleColor(ctx)
    if im.IsItemHovered(ctx) then
      local label, detail = Inbox.Label(f)
      im.SetTooltip(ctx, label .. (detail and ("\n\n" .. detail) or "") ..
        "\n\nClick: select it in REAPER / the sheet and move\nthe edit cursor to it.")
    end
    local verbs, fold = Inbox.RowVerbs(f)
    if fold then
      im.SameLine(ctx)
      if im.SmallButton(ctx, fold .. "##tdf" .. entry.key .. i) then
        im.OpenPopup(ctx, "##tdp" .. entry.key .. i)
      end
      if im.BeginPopup(ctx, "##tdp" .. entry.key .. i) then
        for _, v in ipairs(verbs) do
          if im.Selectable(ctx, "Fix from " .. v.label) then v.fn() end
          if im.IsItemHovered(ctx) then im.SetTooltip(ctx, v.tip) end
        end
        im.EndPopup(ctx)
      end
    else
      for vi, v in ipairs(verbs) do
        im.SameLine(ctx)
        if im.SmallButton(ctx, v.label .. "##tdv" .. entry.key .. i .. "_" .. vi) then
          v.fn()
        end
        if im.IsItemHovered(ctx) and v.tip then im.SetTooltip(ctx, v.tip) end
      end
    end
  end
end
```

`Inbox.RowVerbs` needs its `undecided` branch deleted (the kind no longer exists in the feed) — its pick-first/pick-last buttons violate the verb law anyway. `Inbox.PickTake` becomes dead: delete it.

```lua
-- Line-less findings -- unheard sound -- and the batch verbs, on one card
-- pinned above the sheet. Drawn only when there is something to say.
function Inbox.DrawSession()
  local todo = state.todo or {}
  local sess = todo.session or {}
  local queue, dis = Inbox.queue or {}, Inbox.disagree or {}
  if #sess == 0 and #queue <= 1 and #dis <= 1 then return end
  im.TextDisabled(ctx, "Session")
  for i, f in ipairs(sess) do
    local parts = Inbox.Parts(f)
    im.SetCursorPosX(ctx, im.GetCursorPosX(ctx) + 14)
    im.PushStyleColor(ctx, im.Col_Text, 0xDDAA33FF)
    if im.SmallButton(ctx, Inbox.Clip(parts.cat .. " \194\183 " .. parts.group, 46)
                           .. "##tsess" .. i) then
      Inbox.Jump(f)
    end
    im.PopStyleColor(ctx)
    if im.IsItemHovered(ctx) then
      local label, detail = Inbox.Label(f)
      im.SetTooltip(ctx, label .. (detail and ("\n\n" .. detail) or ""))
    end
  end
  -- (batch verbs -- move the "Fix N out of sync…" and "Adopt timeline for
  -- N" blocks from the old Inbox.Draw here VERBATIM, including their
  -- popups; they act on Inbox.queue / Inbox.disagree exactly as before)
  im.Separator(ctx)
end
```

Move the two batch-verb blocks (old `Inbox.Draw` ~10203–10330, `BatchHeader`, queue popup, adopt-timeline loop) into `DrawSession` unchanged.

- [ ] **Step 3: Draw the strip inside each card.** In the sheet's card draw, after the card's take rows (find the end of one line-card's block — the per-take rows containing the `##sel` checkbox at ~11847 sit inside it), insert:

```lua
    -- The line's Todo, in the card (SPEC-todo-by-line.md): stage + errors.
    if not state.todo_hidden then
      local entry = state.todo and state.todo.by_key
                    and state.todo.by_key[vo.LineKey(row)]
      if entry then Inbox.DrawStrip(entry) end
    end
```

The exact anchor depends on the card function's shape — place it where the card's own content ends, INSIDE the card's visual group, using a first-take row's `row` (any row of the line gives the same `vo.LineKey`). If the card draw iterates takes, emit after the loop using the line's first row.

- [ ] **Step 4: Pin the Session card.** At the top of the sheet draw (before the first line card is emitted), call `Inbox.DrawSession()`.

- [ ] **Step 5: Re-target the toggle.** The Todo count button (~10551–10572): rename the persisted key and state:

```lua
  local inb = state.inbox_counts or { total = 0 }
  if im.SmallButton(ctx, string.format("Todo (%d)", inb.total)) then
    state.todo_hidden = not state.todo_hidden
    r.SetExtState(vo.EXT_SECTION, "todo_hidden",
                  tostring(state.todo_hidden), true)
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, state.todo_hidden
      and "Show each line's Todo strip. The count keeps counting\nwhile they are hidden."
      or  "Hide the Todo strips; the count stays here, still honest.")
  end
```

Initialize once where `rail_hidden` was initialized (~14200):

```lua
    if state.todo_hidden == nil then
      state.todo_hidden = r.GetExtState(vo.EXT_SECTION, "todo_hidden") == "true"
    end
```

Delete all `rail_hidden` reads/writes. The old persisted `rail_hidden` pref is orphaned — acceptable; note it in the changelog.

- [ ] **Step 6: Delete the layout split.** At ~14197–14333: remove `rail_w`, the 0.38 share, the `Inbox.Draw(rail_w, ...)` call and its `BeginChild` wrapper; the sheet takes the full width. Keep the log fold. Change the guard at ~14333 to:

```lua
    if not state.todo_hidden then Inbox.HandleKeys() end
```

- [ ] **Step 7: Re-point the walk.** In `Inbox.HandleKeys` and `Inbox.GoTo`-related code: `n = #((state.todo or {}).lines or {})`; J/K move `state.inbox_sel` over `state.todo.lines`; jump goes to the entry's line:

```lua
  -- state.inbox_sel indexes state.todo.lines. Jump: select the line's
  -- sheet row; verbs: the entry's first error's verbs.
  local entry = (state.todo.lines or {})[state.inbox_sel]
  -- jump key:
  if entry then
    local f = entry.errors[1]
    if f then Inbox.Jump(f)
    else
      -- stage-only entry: go to the line's first row on the sheet
      for _, row in ipairs(state.overview or {}) do
        if vo.LineKey(row) == entry.key then Inbox.GoTo(row) break end
      end
    end
  end
  -- verb keys: Inbox.RowVerbs(entry.errors[1]) when present, else nothing
```

Adapt the existing key-dispatch to that shape; keep the popup/active-widget guards and the config re-read tick untouched. Draw the `state.inbox_sel` highlight in `Inbox.DrawStrip` — when the drawn entry is the selected one, prefix the stage header with the existing `▸` glyph (`im.TextColored(ctx, 0x3E6FA3FF, "\226\150\184")` + `SameLine`), so the walk stays visible in the cards.

- [ ] **Step 8: The seam verb.** The remote seam (`elseif verb == "todo"` ~13064) prints per-finding labels from `state.inbox`. Re-point it at the collapsed shape:

```lua
  elseif verb == "todo" then
    Inbox.MaybeAssemble()
    local out = {}
    for _, e in ipairs((state.todo or {}).lines or {}) do
      out[#out + 1] = string.format("%s: %s%s", e.label, e.stage_label,
        e.conflict and (" (" .. #e.errors .. " error(s))") or "")
    end
    for _, f in ipairs((state.todo or {}).session or {}) do
      local lab = Inbox.Label(f)
      out[#out + 1] = "session: " .. lab
    end
    local c = state.inbox_counts or { total = 0 }
    out[#out + 1] = string.format("todo %d", c.total)
    return table.concat(out, "\n")
  end
```

(Match the seam's existing return conventions — look at the neighbouring verbs.)

- [ ] **Step 9: Compile + full suite**

Run: `luac -p VO/ajsfx_VO_Overview.lua && bash run_tests.sh`
Expected: clean compile, all PASS.

- [ ] **Step 10: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "Overview: the rail becomes per-card Todo strips + a Session card"
```

---

### Task 7: The Todo filter

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (`Strip.RowPasses` ~10436, the stage-strip click handling ~10490–10520)

**Interfaces:**
- Consumes: `state.todo.by_key` (Task 6).
- Produces: `state.stage_filter == "todo"` shows only lines with work.

- [ ] **Step 1: Add the filter branch** in `Strip.RowPasses`:

```lua
  elseif f == "todo" then
    -- Only lines with work left (SPEC-todo-by-line.md): the sheet drains
    -- as Todo clears; empty sheet = session done.
    return state.todo ~= nil and state.todo.by_key[vo.LineKey(row)] ~= nil
```

- [ ] **Step 2: Give it a control.** Beside the Todo count button (Task 6 Step 5), add:

```lua
  im.SameLine(ctx)
  local filtering = state.stage_filter == "todo"
  if im.SmallButton(ctx, filtering and "All lines" or "Only todo") then
    state.stage_filter = filtering and nil or "todo"
  end
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, filtering
      and "Show every line again."
      or  "Only lines with work left. Finish a line's Todo and it\nleaves the sheet -- empty sheet, session done.")
  end
```

(Terse copy per the UI-copy law; if the strip's stage buttons already offer a cleaner slot for this, use that instead — but the filter must be reachable in one click from the Todo count.)

- [ ] **Step 3: Verify the seam.** `state.stage_filter` is settable from the seam (`stage=` verb ~13062) — `stage todo` now works with no extra code. Confirm by reading that branch.

- [ ] **Step 4: Compile + suite** — `luac -p VO/ajsfx_VO_Overview.lua && bash run_tests.sh`

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "Sheet: the Todo filter -- work until the sheet is clear"
```

---

### Task 8: Live check, version bump, release prep

- [ ] **Step 1: Manual smoke in REAPER** (use the MCP harness per `vo-mcp-test-harness` memory, or hand-check): open the Grumbar session; confirm (a) the line that read "Marks vs track B" now shows `Needs select · Conflict` with no marks-vs-track row; (b) settling the select by drag or tick clears it at mouse-release with no flash; (c) the Todo filter drains; (d) strips hide/show and the count persists; (e) J/K walks lines.

- [ ] **Step 2: Bump the version** in the `VO/ajsfx_VO_Overview.lua` header: `@version 0.15beta59`, and REPLACE the `@changelog` body (keeping the rolling `(betaNN: ...)` tail convention — read the existing entry first):

```
-- @changelog PRE-RELEASE: THE TODO LIST IS A LIST OF LINES, AND IT LIVES IN THE SHEET. [describe: rail deleted, per-card stage+error strips, stage ladder Not Scanned/Not Found/Needs edit/Needs select/Unverified/Done, errors re-open their home stage, contested selects (a take parked on Selects claims the select), causal suppression, the Todo filter that drains the sheet, edit-boundary refresh. Note: the rail-hidden preference is retired; the strip toggle starts visible.]
```

Write the real prose in the file, not this placeholder — follow the voice of beta58's entry.

- [ ] **Step 3: Final gate**

```bash
luac -p VO/ajsfx_VO_Overview.lua && luac -p VO/lib/ajsfx_vo.lua && bash run_tests.sh
```

- [ ] **Step 4: Commit + push the branch**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO 0.15beta59: the Todo list is a list of lines, living in the sheet"
git push -u origin feature/todo-by-line
```

- [ ] **Step 5: STOP.** Run the adversarial-loop review before merging (AJ's release gate, per memory). Merging to `main` is the release; that is AJ's call after the review and the live check.

---

## Self-review notes (already applied)

- Spec coverage: Req-1 (Tasks 4–6), Req-2 (Tasks 6–7), Req-3 (Task 3), Req-4 (Tasks 1–2), Req-5 (Tasks 5–6: `row_of_item`, Session card, Not Scanned stage), Req-6 (Task 6 Step 7), edit-boundary law (Task 6 Step 1: feed identity checks kept, no timers added), copy law (Task 1 Step 6), deletions (Task 6 Steps 2/6).
- The `undecided` and `scan_*` feeds are removed rather than suppressed — the ladder replaces them (spec: "stage suppression is structural").
- Type consistency: `entry.key/label/stage/stage_label/conflict/errors` used identically in Tasks 5, 6, 7; `counts.total/lines/session` in Tasks 5, 6.
