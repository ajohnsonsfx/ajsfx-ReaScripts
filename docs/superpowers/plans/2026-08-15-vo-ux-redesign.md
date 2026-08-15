# VO Overview UX Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Overview's surface as pipeline strip (where am I) + inbox rail (what needs me) + contextual verbs (what can I do to THIS), retiring the tab bar, the five Check panels, the four Main rows, and the separate Sources window — three phases, each shipping alone.

**Architecture:** Pure planners in `VO/lib/ajsfx_vo.lua` (`vo.InboxBuild`, `vo.PipelineStages`, `vo.ContextVerbs`) decide what the rail lists, what the strip counts, and what verbs apply; the Overview draws them via at most one new namespace table per phase (`Inbox`, `Strip`, `Verbs`) and dispatches the *existing* verb functions (`Trim.*`, `Verify.*`, `Repair.*`, `Dest.*`, `GoldenPath`). Sources UI is extracted to `VO/lib/ajsfx_vo_sources_ui.lua` so it can be embedded without spending Overview locals.

**Tech Stack:** Lua 5.x, REAPER API, ReaImGui, mock-REAPER test harness (`tests/mock_reaper.lua`, `./run_tests.sh`), MCP live-REAPER harness for GUI verification.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-15-vo-ux-redesign-design.md`. Original exploration: `.../2026-08-15-vo-ux-fresh-take.md`.
- `VO/ajsfx_VO_Overview.lua` has ~196 top-level locals against Lua's 200 cap. **At most ONE new top-level local per phase** (`local Inbox = {}`, `local Strip = {}`, `local Verbs = {}`); every other new function is a method on that table or an existing one (`Trim`, `Repair`, `Verify`, `Dest`, `Line`). Run `luac -p VO/ajsfx_VO_Overview.lua` after every edit; green tests do not prove the file parses. `rm -f luac.out` after.
- No new chunk reads, no new scanners. All data comes from existing state: `state.parity_queue`, `state.reconcile` (`.disagree`, `.unbacked_markers`, `.orphan_marks`), `state.unidentified`, `state.unheard`, `state.suspects`, `state.summary`, `state.check`, `state.rows`.
- Verbs keep their names and their functions. This is re-housing, not behavior change.
- Each phase ends in a beta release: bump `@version` (check the current header AND `git fetch origin` first — releases may have landed), add `@changelog`, run the adversarial-loop skill before release per standing practice, push, **confirm CI green** (`gh run list --limit 1`) and skim the build log for reapack-index warnings.
- An old surface (tab, panel, row, window) is removed only in the same release that ships its replacement.
- Every commit: `./run_tests.sh` all green + `luac -p` on touched Lua files first. Commit style: `VO: <fact>` + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Test files copy the require/header pattern of `tests/test_vo_parity.lua` exactly; if `run_tests.sh` globs `tests/test_*.lua`, no runner edit is needed (check first).

---

## Phase 1 — the Inbox rail

### Task 1: `vo.InboxBuild` — one ranked list

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (append near `vo.ScanSuspects`, ~line 6199)
- Test: `tests/test_vo_inbox.lua` (new)

**Interfaces:**
- Consumes: plain tables mirroring existing Overview state (no REAPER calls).
- Produces:
  ```lua
  vo.InboxBuild(src) -> findings, counts
  -- src = {
  --   parity_queue = { {key=, divergence={detail=}, ...}, ... } | nil,
  --   disagree     = array | nil,   -- state.reconcile.disagree
  --   no_audio     = array | nil,   -- unbacked_markers .. orphan_marks, pre-concatenated by caller
  --   unidentified = array | nil,
  --   undecided    = array | nil,   -- rows recorded but no select picked
  --   suspects     = array | nil,   -- entries may carry .track (string)
  --   unheard      = array | nil,
  --   scanned      = { suspects = bool, unheard = bool },  -- false → emit a "scan" row
  --   selects_track = "Selects",
  -- }
  -- finding = { kind = "suspect_select"|"out_of_sync"|"no_audio"|"unidentified"
  --                  |"undecided"|"suspect"|"unheard"|"scan_suspects"|"scan_unheard",
  --             weight = number, payload = <the source entry, untouched> }
  -- counts  = { total = n, by_kind = { [kind] = n } }
  ```
- Kind weights (spec §Req-2): `suspect_select=10, out_of_sync=20, no_audio=30, unidentified=40, undecided=50, suspect=60, unheard=70`; scan rows weigh the same as the kind they stand in for. Stable within a kind (source order preserved).

- [x] **Step 1: Write the failing tests**

```lua
-- tests/test_vo_inbox.lua  (header copied from tests/test_vo_parity.lua)
package.path = "tests/?.lua;VO/lib/?.lua;lib/?.lua;" .. package.path
local t  = require("test_harness")
local vo = require("ajsfx_vo")

t.test("empty src builds empty inbox", function()
  local f, c = vo.InboxBuild({})
  t.eq(#f, 0); t.eq(c.total, 0)
end)

t.test("selects-track suspects outrank everything", function()
  local f = vo.InboxBuild({
    unheard  = { { at = 1 } },
    suspects = { { name = "a" }, { name = "b", track = "Selects" } },
    parity_queue = { { key = "k" } },
    scanned  = { suspects = true, unheard = true },
    selects_track = "Selects",
  })
  t.eq(f[1].kind, "suspect_select"); t.eq(f[1].payload.name, "b")
  t.eq(f[2].kind, "out_of_sync")
  t.eq(f[3].kind, "suspect");        t.eq(f[3].payload.name, "a")
  t.eq(f[4].kind, "unheard")
end)

t.test("stale scanners emit one scan row each, at their kind's slot", function()
  local f = vo.InboxBuild({ scanned = { suspects = false, unheard = false } })
  t.eq(#f, 2)
  t.eq(f[1].kind, "scan_suspects")  -- weight 60 < 70
  t.eq(f[2].kind, "scan_unheard")
end)

t.test("order within a kind is source order", function()
  local f = vo.InboxBuild({
    undecided = { { asset = "A_01" }, { asset = "A_02" } },
    scanned = { suspects = true, unheard = true },
  })
  t.eq(f[1].payload.asset, "A_01"); t.eq(f[2].payload.asset, "A_02")
end)

t.test("counts tally by kind", function()
  local _, c = vo.InboxBuild({
    disagree = { {}, {} }, no_audio = { {} },
    scanned = { suspects = true, unheard = true },
  })
  t.eq(c.total, 3); t.eq(c.by_kind.out_of_sync, 2); t.eq(c.by_kind.no_audio, 1)
end)

t.report()
```

- [x] **Step 2: Run to verify failure** — `./run_tests.sh`; expect "attempt to call a nil value (field 'InboxBuild')".

- [x] **Step 3: Implement**

```lua
-- VO/lib/ajsfx_vo.lua, after vo.ScanSuspects
local INBOX_WEIGHT = {
  suspect_select = 10, out_of_sync = 20, no_audio = 30, unidentified = 40,
  undecided = 50, suspect = 60, unheard = 70,
  scan_suspects = 60, scan_unheard = 70,
}

function vo.InboxBuild(src)
  src = src or {}
  local findings, counts = {}, { total = 0, by_kind = {} }
  local seq = 0
  local function add(kind, payload)
    seq = seq + 1
    findings[#findings + 1] = { kind = kind, weight = INBOX_WEIGHT[kind], payload = payload, _seq = seq }
    counts.total = counts.total + 1
    counts.by_kind[kind] = (counts.by_kind[kind] or 0) + 1
  end
  local sel = src.selects_track
  for _, s in ipairs(src.suspects or {}) do
    add((sel and s.track == sel) and "suspect_select" or "suspect", s)
  end
  for _, q in ipairs(src.parity_queue or {}) do add("out_of_sync", q) end
  for _, d in ipairs(src.disagree or {})     do add("out_of_sync", d) end
  for _, e in ipairs(src.no_audio or {})     do add("no_audio", e) end
  for _, e in ipairs(src.unidentified or {}) do add("unidentified", e) end
  for _, e in ipairs(src.undecided or {})    do add("undecided", e) end
  for _, e in ipairs(src.unheard or {})      do add("unheard", e) end
  local scanned = src.scanned or {}
  if scanned.suspects == false then add("scan_suspects", {}) end
  if scanned.unheard  == false then add("scan_unheard", {}) end
  table.sort(findings, function(a, b)
    if a.weight ~= b.weight then return a.weight < b.weight end
    return a._seq < b._seq
  end)
  return findings, counts
end
```

- [x] **Step 4: Run to verify pass** — `./run_tests.sh` all green; `luac -p VO/lib/ajsfx_vo.lua && rm -f luac.out`.
- [x] **Step 5: Commit** — `VO: vo.InboxBuild merges every scanner's findings into one ranked list`

---

### Task 2: The rail — draw, jump, verbs; Check tab retires

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (one new top-level local: `local Inbox = {}` next to `local Repair = {}` at ~8627)

**Interfaces:**
- Consumes: `vo.InboxBuild` (Task 1); existing verb functions — `Trim.sync_dispatch`, `Trim.fix_from_transcript`, `Repair.NoAudio`'s row actions, `Verify.KickSelection`, `Repair.ScanUnheard`, the suspects scan at ~9229, `JumpTo(item)`, `GoTo(row)`; existing panel bodies for reference: `DrawOutOfSyncPanel` 8454–8621, `Repair.*` 9227–9548.
- Produces: `Inbox.Assemble()` (state → `vo.InboxBuild` src), `Inbox.Draw(ctx, width)`, `Inbox.RowVerbs(f) -> { {label, fn}, ... }`, `state.inbox` (findings), `state.inbox_sel` (walk cursor, Task 3). Later tasks rely on these exact names.

- [x] **Step 1: Add `Inbox.Assemble` + `Inbox.RowVerbs`**

```lua
local Inbox = {}

function Inbox.Assemble()
  local rec = state.reconcile or {}
  local no_audio = {}
  for _, e in ipairs(rec.unbacked_markers or {}) do no_audio[#no_audio + 1] = e end
  for _, e in ipairs(rec.orphan_marks or {})     do no_audio[#no_audio + 1] = e end
  local undecided = {}
  for _, row in ipairs(state.rows or {}) do
    if row.recorded and not row.select then undecided[#undecided + 1] = row end
  end
  state.inbox, state.inbox_counts = vo.InboxBuild({
    parity_queue = state.parity_queue, disagree = rec.disagree,
    no_audio = no_audio, unidentified = state.unidentified,
    undecided = undecided, suspects = state.suspects, unheard = state.unheard,
    scanned = { suspects = state.suspects ~= nil, unheard = state.unheard ~= nil },
    selects_track = cfg.track_selects,
  })
end
```

`Inbox.RowVerbs(f)` returns per-kind verb lists that call the SAME functions the panels call today (read each panel body and lift its per-row buttons verbatim — e.g. out_of_sync rows get the `FixButtons` authorities via `Trim.sync_dispatch`; suspects get Verify/OK; undecided get the pick verbs; `scan_*` rows get one "Scan" verb calling `Repair.ScanUnheard` / the suspects scan). Do not re-implement any verb.

**Note on field names:** `row.recorded` / `row.select` above are illustrative — before coding, read `vo.SummarizeOverview` (lib ~7691) to see the real per-row flags it counts as `recorded`/`review`, and use those exact fields so the rail's "undecided" equals the summary's "to review".

- [x] **Step 2: Add `Inbox.Draw`** — right rail as a child region, evidence-row pattern lifted from `DrawOutOfSyncPanel`:

```lua
function Inbox.Draw(ctx, width)
  im.BeginChild(ctx, "##inbox", width, 0)
  local c = state.inbox_counts or { total = 0 }
  im.SeparatorText(ctx, ("Needs you (%d)"):format(c.total))
  if c.total == 0 then
    im.TextDisabled(ctx, "Nothing needs you.")
  end
  for i, f in ipairs(state.inbox or {}) do
    local hot = (state.inbox_sel == i)
    im.Bullet(ctx)
    im.SameLine(ctx)
    if hot then im.PushStyleColor(ctx, im.Col_Button, 0x3E6FA3FF) end
    if im.SmallButton(ctx, (Inbox.Evidence(f)) .. "##inbox" .. i) then
      state.inbox_sel = i
      Inbox.Jump(f)
    end
    if hot then im.PopStyleColor(ctx) end
    for _, v in ipairs(Inbox.RowVerbs(f)) do
      im.SameLine(ctx)
      if im.SmallButton(ctx, v.label .. "##inbox" .. i) then v.fn(f.payload) end
    end
  end
  im.EndChild(ctx)
end
```

`Inbox.Evidence(f)` formats per kind (out_of_sync → `payload.divergence.detail`; suspects → the judged words — reuse whatever `Repair.Suspects` prints; undecided → the line's asset + take count). `Inbox.Jump(f)` calls `JumpTo`/`GoTo` per payload shape, same as the panels do.

- [x] **Step 3: Wire into `loop()`** — split the content area into sheet + rail (`im.GetContentRegionAvail` → sheet gets `avail - RAIL_W`); call `Inbox.Assemble()` where `state.reconcile`/`state.summary` refresh (near line 980's `CheckCoverage` call — assemble AFTER all sources refresh, once per reload, not per frame); call `Inbox.Draw` after the sheet. Store `RAIL_W` on `Inbox` (e.g. `Inbox.WIDTH = 340`), not a new local.
- [x] **Step 4: Retire the Check tab** — remove `check` from `TOOLBAR_TABS` (249–252), the `elseif state.tab == "check" then` body (13085–13181), and the five `PanelButton`s' entries in the panel dispatch (13224–13232). KEEP the panel body functions that the rail's verbs still reference (`Repair.ScanUnheard`, `Verify.*`); delete only bodies nothing calls anymore (`DrawOutOfSyncPanel`, `Repair.NoAudio/Unidentified/Unheard/Suspects` list-rendering) once `Inbox.RowVerbs` has absorbed their per-row actions. Move the "Verify items (N)" button (13098) and "Keep the session in sync" checkbox (12976) to the toolbar for now (phase 3 re-homes them).
- [x] **Step 5: Parse + tests** — `luac -p VO/ajsfx_VO_Overview.lua && rm -f luac.out`; `./run_tests.sh`.
- [x] **Step 6: Live check** — MCP harness (per `vo-mcp-test-harness` memory): load the fixture project, open Overview, confirm the rail lists findings ranked Selects-first, a jump selects the item in REAPER, one verb round-trips, and the empty-project fixture shows "Nothing needs you."
- [x] **Step 7: Commit** — `VO: the inbox rail — every finding in one ranked list, Check tab retired`

---

### Task 3: Keyboard — J/K walk, one-key verbs, remappable

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (`vo.CONFIG_SCHEMA`, 8106–8165)
- Modify: `VO/ajsfx_VO_Overview.lua` (methods on `Inbox`)
- Modify: `VO/ajsfx_VO_Settings.lua` (new `DrawKeyboard` section)
- Test: `tests/test_vo_inbox.lua` (extend)

**Interfaces:**
- Consumes: `state.inbox`, `state.inbox_sel`, `Inbox.RowVerbs`, `Inbox.Jump` (Task 2).
- Produces: schema keys `key_inbox_next` ("J"), `key_inbox_prev` ("K"), `key_inbox_jump` ("Enter"), `key_inbox_verb1` ("1"), `key_inbox_verb2` ("2"); `vo.KeyBindingClashes(cfg) -> { {a, b}, ... }`; `Inbox.HandleKeys(ctx)`.

- [x] **Step 1: Failing test for clash detection**

```lua
t.test("duplicate key bindings are reported as clashes", function()
  local clashes = vo.KeyBindingClashes({ key_inbox_next = "J", key_inbox_prev = "J" })
  t.eq(#clashes, 1)
  t.eq(clashes[1][1], "key_inbox_next"); t.eq(clashes[1][2], "key_inbox_prev")
end)
t.test("distinct bindings report no clashes", function()
  t.eq(#vo.KeyBindingClashes({ key_inbox_next = "J", key_inbox_prev = "K" }), 0)
end)
```

- [x] **Step 2: Run to verify failure**, then implement: add the five entries to `CONFIG_SCHEMA` (`kind = "string"` with the defaults above) and

```lua
function vo.KeyBindingClashes(cfg)
  local seen, clashes = {}, {}
  local keys = { "key_inbox_next", "key_inbox_prev", "key_inbox_jump",
                 "key_inbox_verb1", "key_inbox_verb2" }
  for _, k in ipairs(keys) do
    local v = cfg[k]
    if v and v ~= "" then
      if seen[v] then clashes[#clashes + 1] = { seen[v], k } else seen[v] = k end
    end
  end
  return clashes
end
```

- [x] **Step 3: `Inbox.HandleKeys`** — map binding names to ImGui keycodes with a table on `Inbox` (`Inbox.KEYS = { J = im.Key_J, K = im.Key_K, Enter = im.Key_Enter, ["1"] = im.Key_1, ... }` — cover A–Z, 0–9, Enter, Space); in `loop()` call it once per frame **only when no text input is active** (`not im.IsAnyItemActive(ctx)` guard, or typing "j" in search walks the rail):

```lua
function Inbox.HandleKeys(ctx)
  if im.IsAnyItemActive(ctx) then return end
  local n = #(state.inbox or {})
  if n == 0 then return end
  local function pressed(name) local k = Inbox.KEYS[cfg[name]]; return k and im.IsKeyPressed(ctx, k) end
  if pressed("key_inbox_next") then state.inbox_sel = math.min((state.inbox_sel or 0) + 1, n) end
  if pressed("key_inbox_prev") then state.inbox_sel = math.max((state.inbox_sel or 2) - 1, 1) end
  local f = state.inbox[state.inbox_sel]
  if not f then return end
  if pressed("key_inbox_jump") then Inbox.Jump(f) end
  local verbs = Inbox.RowVerbs(f)
  if pressed("key_inbox_verb1") and verbs[1] then verbs[1].fn(f.payload) end
  if pressed("key_inbox_verb2") and verbs[2] then verbs[2].fn(f.payload) end
end
```

- [x] **Step 4: Settings section** — `DrawKeyboard` beside `DrawMatching` (Settings 371): one `im.InputText` per binding (single char or "Enter"/"Space"), a reset-to-defaults button, and a warning line listing `vo.KeyBindingClashes(cfg)` results in the warn color. Persist via the existing `vo.SaveConfig` path (schema entries make this automatic).
- [x] **Step 5: Tests + parse** — `./run_tests.sh`; `luac -p` on all three touched files.
- [x] **Step 6: Live check** — J/K moves the highlight, Enter jumps, 1 fires the first verb; remap next→"N" in Settings and confirm N walks; typing in the search box does NOT walk.
- [x] **Step 7: Commit** — `VO: inbox is keyboard-walkable — J/K/Enter/1/2, remappable in Settings`

---

### Task 4: Log strip in the rail; Log tab retires; ship phase 1

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`

**Interfaces:**
- Consumes: `state.log` (rendered today by the log tab body, 13182–13216), `Inbox.Draw`.
- Produces: `Inbox.DrawLog(ctx)`; the phase-1 release.

- [x] **Step 1: `Inbox.DrawLog`** — bottom section of the rail child (reserve ~30% of rail height with a second `BeginChild`): newest-first lines from `state.log`, plus the existing "Copy log" / "Clear" small-buttons lifted from the log tab body. Then remove `log` from `TOOLBAR_TABS`, delete the `elseif state.tab == "log"` body, and drop the `state.tab ~= "log"` guard on `DrawSummary` (13251).
- [x] **Step 2: Parse + tests + live check** — actions still write log lines and they appear in the strip, newest first.
- [x] **Step 3: Release** — `git fetch origin` and read the current `@version`; bump to the next beta (e.g. `0.15beta34`) with `@changelog: The inbox — one ranked "Needs you" rail replaces the five Check panels; J/K-walkable, keys remappable; the Log lives under it.` Run the adversarial-loop review, then push and **confirm CI green** + no reapack-index warnings.
- [x] **Step 4: Commit/merge** — feature branch → `main` per repo workflow.

---

## Phase 2 — the Pipeline strip

### Task 5: `vo.PipelineStages` — honest meters

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (append near `vo.SummarizeOverview`, ~7691)
- Test: `tests/test_vo_pipeline.lua` (new)

**Interfaces:**
- Consumes: plain tables shaped like `state.summary` (`{lines, recorded, verified, review, delivered, ...}`), `state.check` (`{delivered, missing, ...}`), plus `{cut_done, cut_total}` and `{sources_done, sources_total, sources_running}` supplied by the caller.
- Produces:
  ```lua
  vo.PipelineStages(s) -> stages
  -- stage = { id = "sources"|"matched"|"cut"|"decided"|"verified"|"delivered",
  --           label = "Decided",  done = 180, total = 195,
  --           text = "Decided 180/195",  state = "done"|"partial"|"todo"|"running" }
  -- rules: total==0 → "todo", text = label .. " —"
  --        done==total>0 → "done",  text = label .. " ✓"
  --        else "partial", text = "label done/total" ("verified" formats as %)
  --        sources_running=true forces "running" regardless of counts
  ```

- [x] **Step 1: Failing tests**

```lua
-- tests/test_vo_pipeline.lua (same header as test_vo_inbox.lua)
t.test("complete stage renders a check", function()
  local st = vo.PipelineStages({ matched_done = 5, matched_total = 5 })
  local m; for _, s in ipairs(st) do if s.id == "matched" then m = s end end
  t.eq(m.state, "done"); t.eq(m.text, "Matched ✓")
end)
t.test("partial stage renders n/m", function()
  local st = vo.PipelineStages({ decided_done = 180, decided_total = 195 })
  local d; for _, s in ipairs(st) do if s.id == "decided" then d = s end end
  t.eq(d.state, "partial"); t.eq(d.text, "Decided 180/195")
end)
t.test("verified formats as percent", function()
  local st = vo.PipelineStages({ verified_done = 61, verified_total = 100 })
  local v; for _, s in ipairs(st) do if s.id == "verified" then v = s end end
  t.eq(v.text, "Verified 61%")
end)
t.test("empty stage is a dash", function()
  local st = vo.PipelineStages({})
  t.eq(st[6].id, "delivered"); t.eq(st[6].state, "todo"); t.eq(st[6].text, "Delivered —")
end)
t.test("running sources override", function()
  local st = vo.PipelineStages({ sources_done = 2, sources_total = 6, sources_running = true })
  t.eq(st[1].state, "running")
end)
t.test("always six stages in pipeline order", function()
  local st = vo.PipelineStages({})
  t.eq(#st, 6); t.eq(st[1].id, "sources"); t.eq(st[6].id, "delivered")
end)
```

- [x] **Step 2: Run to verify failure**, then implement:

```lua
local STAGE_DEFS = {
  { id = "sources",   label = "Sources"   },
  { id = "matched",   label = "Matched"   },
  { id = "cut",       label = "Cut"       },
  { id = "decided",   label = "Decided"   },
  { id = "verified",  label = "Verified", pct = true },
  { id = "delivered", label = "Delivered" },
}

function vo.PipelineStages(s)
  s = s or {}
  local out = {}
  for _, d in ipairs(STAGE_DEFS) do
    local done  = s[d.id .. "_done"]  or 0
    local total = s[d.id .. "_total"] or 0
    local st, text
    if d.id == "sources" and s.sources_running then
      st, text = "running", ("%s %d/%d…"):format(d.label, done, total)
    elseif total == 0 then
      st, text = "todo", d.label .. " —"
    elseif done >= total then
      st, text = "done", d.label .. " ✓"
    elseif d.pct then
      st, text = "partial", ("%s %d%%"):format(d.label, math.floor(done * 100 / total))
    else
      st, text = "partial", ("%s %d/%d"):format(d.label, done, total)
    end
    out[#out + 1] = { id = d.id, label = d.label, done = done, total = total, state = st, text = text }
  end
  return out
end
```

- [x] **Step 3: Run to verify pass**; `luac -p`; commit — `VO: vo.PipelineStages — six honest meters from the counters we already keep`

---

### Task 6: The strip — draw + stage filters

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (one new top-level local: `local Strip = {}`)

**Interfaces:**
- Consumes: `vo.PipelineStages`; `state.summary` (set ~850), `state.check` (~980), cut counts (derive from `state.take_markers`/rows: a line is "cut" when its takes carry markers — read `SummarizeOverview` for the field to reuse), transcription progress (Task 7's module exposes it; until then pass `sources_done/total` from the transcript list the Overview already reads).
- Produces: `Strip.Assemble()` (state → `vo.PipelineStages` arg), `Strip.Draw(ctx)`, `Strip.RowPasses(row) -> bool`, `state.stage_filter` (stage id or nil). Task 8 relies on `Strip.Draw` hosting the hero; phase 3 relies on `state.stage_filter` for verb context.

- [x] **Step 1: `Strip.Assemble` + `Strip.Draw`** — assemble alongside `Inbox.Assemble()`. Draw: one horizontal row of `im.Button`s under the toolbar, active-filter highlighted (`Col_ButtonActive`), "done" stages in `TextDisabled` styling, click toggles:

```lua
function Strip.Draw(ctx)
  for i, s in ipairs(state.stages or {}) do
    if i > 1 then im.SameLine(ctx) end
    local active = (state.stage_filter == s.id)
    if active then im.PushStyleColor(ctx, im.Col_Button, 0x3E6FA3FF) end
    if im.Button(ctx, s.text .. "##stage_" .. s.id) then
      state.stage_filter = (not active) and s.id or nil
    end
    if active then im.PopStyleColor(ctx) end
  end
end
```

- [x] **Step 2: `Strip.RowPasses(row)`** — nil filter → true; `matched` → rows not yet matched; `cut` → matched rows whose takes lack markers; `decided` → recorded rows without a select; `verified` → rows with unverified takes; `delivered` → rows not yet delivered; `sources` → sheet unfiltered (the stage body is the Sources view, Task 8). Reuse the SAME per-row predicates `SummarizeOverview` counts with, so strip numbers and filtered row counts can never disagree. Gate the sheet's card loop with it.
- [x] **Step 3: Parse, tests, live check** — counts match the `DrawSummary` line for the same project; clicking "Decided 180/195" shows exactly 15 cards; clicking again clears.
- [x] **Step 4: Commit** — `VO: the pipeline strip — each stage a meter and a filter`

---

### Task 7: Extract Sources UI into a module

**Files:**
- Create: `VO/lib/ajsfx_vo_sources_ui.lua`
- Modify: `VO/ajsfx_VO_Sources.lua` (becomes a thin host)

**Interfaces:**
- Consumes: everything `ajsfx_VO_Sources.lua` holds today (BuildRows 98, MaybeRescan 131, RunTranscribe 256, PressTranscribe 357, RefreshBackend 240, DrawTable 510, DrawToolbar 534, DrawBackendLine 568, DrawProgress 577, DrawDetailPanel 932 and its sub-panels).
- Produces:
  ```lua
  local sources_ui = require("ajsfx_vo_sources_ui")
  sources_ui.NewState() -> st          -- the module's own state table
  sources_ui.Draw(ctx, im, st, cfg)    -- full Sources UI into the current window/child
  sources_ui.Tick(st)                  -- background transcribe pump (call every frame)
  sources_ui.Progress(st) -> done, total, running   -- feeds the Sources stage meter
  ```

- [x] **Step 1: Move, don't rewrite** — cut the body of `ajsfx_VO_Sources.lua` (everything between the header and `loop()`) into the new module wholesale; convert file-locals it needs per-instance into fields on `st`; module-level constants stay module-locals (a fresh file has its own 200 budget). The `im` handle and `cfg` are passed in, not re-required.
- [x] **Step 2: Thin host** — `ajsfx_VO_Sources.lua` keeps only its header, `require`, `NewState`, and a `loop()` of `Begin → sources_ui.Tick → sources_ui.Draw → End`. **Behavior identical** — this release changes nothing user-visible.
- [x] **Step 3: Update `@provides`** — the Overview package's `@provides` must ship `VO/lib/ajsfx_vo_sources_ui.lua` (follow how `ajsfx_vo_view.lua` is provided today — copy that stanza's shape exactly).
- [x] **Step 4: Parse both files + tests + live check** — standalone Sources window still scans and transcribes.
- [x] **Step 5: Commit** — `VO: Sources UI extracted to a module — same window, movable innards`

---

### Task 8: Embed Sources, retire the window and the tab bar; ship phase 2

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`
- Delete: `VO/ajsfx_VO_Sources.lua`

**Interfaces:**
- Consumes: `sources_ui` (Task 7), `Strip.Draw` (Task 6), `GoldenPath` (8225), Setup-tab pieces (script picker `DrawScriptPanel` 5624, "Start over…" 12598).
- Produces: the tab-less window: strip on top (hero leftmost inside it), sheet + rail below; `state.stage_filter == "sources"` renders `sources_ui.Draw` in place of the sheet.

- [x] **Step 1: Embed** — Overview requires `ajsfx_vo_sources_ui`, keeps `st = sources_ui.NewState()` on `Strip` (`Strip.sources = ...`); call `sources_ui.Tick` each frame; when `state.stage_filter == "sources"`, draw `sources_ui.Draw` where the sheet goes (rail stays). Feed `sources_ui.Progress` into `Strip.Assemble`.
- [x] **Step 2: Fold Setup in** — "Choose script…" and "Sources and transcripts" live at the top of the Sources stage body; "Start over…" (destructive, with its confirm popup 12607–12632) moves beside Settings in the toolbar. Remove the `setup` tab body (12563–12633).
- [x] **Step 3: Kill the tab bar** — remove `TOOLBAR_TABS`, the `BeginTabBar` block (12395–12432), and `state.tab` branches; the Settings tab-button becomes a toolbar button. The hero (12636–12676) moves into `Strip.Draw` as the leftmost element, same `GoldenPath` dispatch, same blue.
- [x] **Step 4: Delete `VO/ajsfx_VO_Sources.lua`** — also remove its launch button ("Sources and transcripts…" now IS the stage) and any `vo.LaunchSibling` reference to it. ReaPack treats this as a removed package; CI's `reapack-index` handles it (recent history shows prior removals) — still skim the build log line for it.
- [x] **Step 5: Parse + tests + live check** — full workflow in one window: pick script, scan sources, transcribe (meter shows running), match, and the strip advances as stages complete.
- [x] **Step 6: Release** — bump `@version` (fetch first), `@changelog: The pipeline strip is the window — six stages, each a meter and a filter; Sources lives inside; the tab bar is gone.` Adversarial-loop, push, CI green, log skimmed.

---

## Phase 3 — Contextual verbs

### Task 9: `vo.ContextVerbs` — what applies to THIS

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua`
- Test: `tests/test_vo_context_verbs.lua` (new)

**Interfaces:**
- Consumes: a selection summary the Overview computes: `{ recordings = n, takes = n, lines = n }` plus `stage_filter`.
- Produces:
  ```lua
  vo.ContextVerbs(sel) -> { "match", "cut", ... }   -- verb ids, ordered
  -- recordings only → { "match", "cut", "untrack" }
  -- takes only      → { "fix_from", "verify", "ok", "recut", "untrack" }
  -- lines only      → { "pick_first", "pick_last", "name_alts" }
  -- mixed           → intersection, same order ({} if none)
  -- nothing         → {} (caller draws the hint line)
  ```

- [x] **Step 1: Failing tests**

```lua
t.test("recordings get match and cut", function()
  local v = vo.ContextVerbs({ recordings = 1 })
  t.eq(v[1], "match"); t.eq(v[2], "cut")
end)
t.test("takes get the fix and judge verbs", function()
  local v = vo.ContextVerbs({ takes = 3 })
  t.eq(v[1], "fix_from"); t.eq(v[2], "verify")
end)
t.test("mixed selection intersects", function()
  local v = vo.ContextVerbs({ recordings = 1, takes = 2 })
  t.eq(#v, 1); t.eq(v[1], "untrack")
end)
t.test("empty selection is empty", function()
  t.eq(#vo.ContextVerbs({}), 0)
end)
```

- [x] **Step 2: Verify failure**, implement:

```lua
local CONTEXT_VERBS = {
  recordings = { "match", "cut", "untrack" },
  takes      = { "fix_from", "verify", "ok", "recut", "untrack" },
  lines      = { "pick_first", "pick_last", "name_alts" },
}

function vo.ContextVerbs(sel)
  sel = sel or {}
  local active = {}
  for _, ctx in ipairs({ "recordings", "takes", "lines" }) do
    if (sel[ctx] or 0) > 0 then active[#active + 1] = CONTEXT_VERBS[ctx] end
  end
  if #active == 0 then return {} end
  local out = {}
  for _, verb in ipairs(active[1]) do
    local everywhere = true
    for i = 2, #active do
      local found = false
      for _, v in ipairs(active[i]) do if v == verb then found = true end end
      if not found then everywhere = false break end
    end
    if everywhere then out[#out + 1] = verb end
  end
  return out
end
```

- [x] **Step 3: Verify pass, `luac -p`, commit** — `VO: vo.ContextVerbs — the selection decides the verbs`

---

### Task 10: The verb bar; Main rows retire; ship phase 3

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (one new top-level local: `local Verbs = {}`)

**Interfaces:**
- Consumes: `vo.ContextVerbs`; the verb inventory of the four Group rows (12692–13083) and their exact dispatch targets: `match → MatchTakes({mark=true})` 7886, `cut → RunCut` 6647, `untrack → Trim.untrack` 1764 (confirm popup preserved), `fix_from → Trim.sync_dispatch` authorities, `verify → Verify.KickSelection` 9117, `ok →` the OK/vet verb the suspects panel used, `recut → Trim.recut` 8008, `pick_first/pick_last → AutoSelectTakes` 4516, `name_alts → ApplyAltNames` 7693; pull-side verbs (`Dest.pull_all` 7657, `Dest.build` 7273, `DrawPullPanel` 8330, `DrawLayoutBar` 9724) home on the **Delivered stage**, not the selection bar.
- Produces: `Verbs.Selection()` (REAPER selection + sheet selection → `vo.ContextVerbs` arg), `Verbs.Draw(ctx)` — the fixed bar between strip and sheet.

- [x] **Step 1: `Verbs.Selection`** — count selected items by classification the tool already has (recording = multi-marker item, take = single-marker/cut item — reuse the same distinction `Trim.update`/parity use via `state.take_markers`) and selected sheet line cards (`state` selection fields used by `ClickRow` 4157).
- [x] **Step 2: `Verbs.Draw`** — fixed bar, always present:

```lua
Verbs.DEFS = {
  match      = { label = "Match takes to script", fn = function() MatchTakes({ mark = true }) end },
  cut        = { label = "Cut from markers",      fn = function() RunCut() end },
  -- ... one entry per verb id, wrapping the EXACT existing calls, tooltips lifted verbatim
}
function Verbs.Draw(ctx)
  local ids = vo.ContextVerbs(Verbs.Selection())
  if #ids == 0 then
    im.TextDisabled(ctx, "Select a recording, takes, or a line — its verbs appear here.")
    return
  end
  for i, id in ipairs(ids) do
    if i > 1 then im.SameLine(ctx) end
    local d = Verbs.DEFS[id]
    if im.Button(ctx, d.label .. "##verb_" .. id) then d.fn() end
  end
end
```

- [x] **Step 3: Stage verbs** — when `state.stage_filter` is set, append that stage's stage-level verbs after a separator (Delivered → Pull / Build tracks / Lay out; Verified → Verify items; Decided → the auto-pick pair). This is where the Pull row's macros land.
- [x] **Step 4: Retire the rows** — delete the four `Group` rows (12692–13083) and the `Group` helper if unused; verify with the **verb inventory checklist**: list every button in today's Main tab from the explore map, and check each has a home (selection bar / stage verbs / strip hero / toolbar / Settings). Zero orphans before the delete lands.
- [x] **Step 5: Parse + tests + live check** — select a recording → Match/Cut appear; a cut take → Fix from…/Verify/OK/Re-cut; a line card → pick verbs; nothing → hint line; mixed recording+take → Untrack only. Full golden-path session end-to-end in the fixture project.
- [x] **Step 6: Release** — bump `@version` (fetch first), `@changelog: Verbs live on the selection now — the four button rows retire; the window is strip, sheet, rail.` Adversarial-loop, push, CI green, log skimmed.
- [x] **Step 7: Update docs** — mark `2026-08-15-vo-ux-fresh-take.md` Status as "Implemented via 2026-08-15-vo-ux-redesign"; refresh the VO notes in SoundDesignDocs if the workflow write-ups reference tabs/panels.

---

## Self-review notes

- Spec Req-1..7 → Tasks 1–4; Req-8..11 → Tasks 5–8; Req-12..14 → Tasks 9–10.
- Local-cap budget: phase 1 adds `Inbox` (1), phase 2 adds `Strip` (1), phase 3 adds `Verbs` (1) — 3 new locals against ~4 headroom; module extraction (Task 7) and any body deletions only free pressure. If headroom proves tighter than counted, hang `Strip`/`Verbs` as fields on `Inbox` instead — plan names stay (`Inbox.Strip.Draw` etc.).
- Names used across tasks: `Inbox.Assemble/Draw/DrawLog/RowVerbs/Jump/Evidence/HandleKeys`, `Strip.Assemble/Draw/RowPasses/sources`, `Verbs.Selection/Draw/DEFS`, `state.inbox/inbox_sel/inbox_counts/stages/stage_filter` — consistent above.
- Line numbers are from the 2026-08-15 explore of the file at commit 13a4500; re-locate by function name if the file has moved on.
