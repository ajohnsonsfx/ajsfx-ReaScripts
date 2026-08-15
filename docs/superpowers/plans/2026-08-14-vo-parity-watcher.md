# VO Parity Watcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One parity engine that keeps marker name = item name = sheet assignment (and marker bounds ≈ item edges) automatically, with a queue for anything it refuses to guess about — replacing eight repair buttons and three follower checkboxes.

**Architecture:** Pure planners in `VO/lib/ajsfx_vo.lua` (`vo.ParityDiff`, `vo.ParityAttribute`) decide *what disagrees* and *who moved*; the Overview script's existing settle-watcher grows name and marker snapshots and dispatches the existing verbs (`Trim.update`, `Trim.fix_names_from_transcript`, `Trim.adopt_track_marks`) as automatic syncs; an "Out of sync" panel lists the refusals with per-row "Fix from …" actions.

**Tech Stack:** Lua 5.x, REAPER API, ReaImGui, mock-REAPER test harness (`tests/mock_reaper.lua`, `./run_tests.sh`).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-14-vo-parity-watcher-design.md`.
- `VO/ajsfx_VO_Overview.lua` is at Lua's 200-local cap: **no new top-level `local function`** — hang new functions off `Trim`, `Parity` (a new table stored on an existing local), or pass opts. Run `luac -p VO/ajsfx_VO_Overview.lua` after every edit; green tests do not prove the file parses.
- The watcher adds **no chunk reads of its own**: marker state comes from `state.take_markers` (rebuilt by `Reload` → `vo.CollectTakeMarkers`), item name via `GetSetMediaItemTakeInfo_String` (cheap), edges/track via `GetMediaItemInfo_Value` (cheap).
- The tool never guesses: unattributable changes queue, they are never synced.
- No backwards compatibility: no migration of the three old follower ExtState keys, no leniency for historical drift — the queue is how the existing project gets fixed.
- Naming: user-facing actions are "Fix from Transcript / Marker / Item / Sheet"; the switch is "Keep the session in sync".
- Every commit: run `./run_tests.sh` (all pass) and `luac -p` on touched Lua files first; `rm -f luac.out` after luac.
- Commit messages follow repo style: `VO: <what changed, stated as a fact>` + `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: `vo.ParityDiff` — what disagrees

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (append near `vo.PlanUpdatePass`, ~line 1976)
- Test: `tests/test_vo_parity.lua` (new)
- Modify: `run_tests.sh` (add the new test file if the runner lists files explicitly; check first — if it globs `tests/test_*.lua`, no edit)

**Interfaces:**
- Consumes: nothing new — takes plain tables.
- Produces: `vo.ParityDiff(takes, opts) -> divergences` where each element of `takes` is:
  ```lua
  {
    key          = <opaque, echoed back>,
    marker       = { asset = "IWinBig_02", start = 1.25, stop = 3.5 } | nil,
    marker_count = <number of tool markers on the item>,
    item         = { name = "IWinBig_02", from = 1.25, to = 3.5 } | nil,  -- from/to in SOURCE time (coverage)
    sheet        = { asset = "IWinBig_02" } | nil,
  }
  ```
  and each divergence is:
  ```lua
  { key = <echoed>, fields = { "name" | "edges", ... }, detail = "<one sentence>" }
  ```
  `opts.eps` (default `0.005` s) is the edge tolerance.

Rules (each is a test):
- All elements agree → no divergence.
- `marker_count > 1` → recording: **geometry is never compared** (spec §3.2 / refusal law); name is not compared either (an uncut recording has no one name). Emit `{ fields = {"duplicates"}, detail = ... }` **only** when the same item is not merely a recording but was flagged upstream — NOT this function's job; ParityDiff emits nothing for `marker_count > 1`. (Duplicate clusters reach the queue from `Trim.update`'s `several` refusal, Task 5.)
- `marker.asset ~= item.name` (both present, item.name non-empty) → `"name"` divergence. Item names that are conventional alt names of the marker's asset are NOT divergent: use `vo.IsConventionalAltName` if present (check it exists; if its signature needs the pattern, accept `opts.alt_pattern` and pass it through) — an alt on the Alts track legitimately wears `IWinBig_02_alt01` over a marker that says `IWinBig_02`.
- `marker` present, `sheet.asset` present, `marker.asset ~= sheet.asset` → `"name"` divergence (the sheet reads the marker, so this should be rare — it means the sheet row resolved differently).
- `|marker.start - item.from| > eps` or `|marker.stop - item.to| > eps` (single marker, both present) → `"edges"` divergence.
- `marker == nil`, `item` present with a name that is not empty → no divergence (an unmarked item is Match's business, not parity's).
- `takes == nil` → `{}`, not an error.

- [ ] **Step 1: Write the failing tests**

```lua
-- tests/test_vo_parity.lua
package.path = "tests/?.lua;VO/lib/?.lua;lib/?.lua;" .. package.path
local t  = require("test_harness")   -- match the require pattern of tests/test_vo_tidy.lua exactly; copy its header
local vo = require("ajsfx_vo")

local function take(over)
  local base = {
    key = "k1",
    marker = { asset = "IWinBig_02", start = 1.25, stop = 3.50 },
    marker_count = 1,
    item = { name = "IWinBig_02", from = 1.25, to = 3.50 },
    sheet = { asset = "IWinBig_02" },
  }
  for k, v in pairs(over or {}) do base[k] = v end
  return base
end

t.test("agreement diffs to nothing", function()
  t.eq(#vo.ParityDiff({ take() }), 0)
end)

t.test("a renamed item is a name divergence", function()
  local d = vo.ParityDiff({ take({ item = { name = "IWinLittle_01", from = 1.25, to = 3.50 } }) })
  t.eq(#d, 1)
  t.eq(d[1].key, "k1")
  t.eq(d[1].fields[1], "name")
end)

t.test("a conventional alt name is not a divergence", function()
  local d = vo.ParityDiff(
    { take({ item = { name = "IWinBig_02_alt01", from = 1.25, to = 3.50 } }) },
    { alt_pattern = "_alt%02d" })
  t.eq(#d, 0)
end)

t.test("edges past eps diverge, inside eps do not", function()
  t.eq(#vo.ParityDiff({ take({ item = { name = "IWinBig_02", from = 1.30, to = 3.50 } }) }), 1)
  t.eq(#vo.ParityDiff({ take({ item = { name = "IWinBig_02", from = 1.2501, to = 3.50 } }) }), 0)
end)

t.test("a recording is never compared", function()
  t.eq(#vo.ParityDiff({ take({ marker_count = 3,
    item = { name = "whatever", from = 0, to = 99 } }) }), 0)
end)

t.test("no marker, no divergence -- that is Match's business", function()
  t.eq(#vo.ParityDiff({ take({ marker = nil, marker_count = 0 }) }), 0)
end)

t.test("sheet disagreeing with marker is a name divergence", function()
  local d = vo.ParityDiff({ take({ sheet = { asset = "IWinLittle_01" } }) })
  t.eq(#d, 1)
  t.eq(d[1].fields[1], "name")
end)

t.test("nil takes is empty, not an error", function()
  t.eq(#vo.ParityDiff(nil), 0)
end)

t.done()
```

Before writing, open `tests/test_vo_tidy.lua` and copy its exact harness header/footer idiom (require path, assert helpers, result reporting) — the block above assumes `t.test/t.eq/t.done`; adapt to whatever the real harness exposes, keeping the cases identical.

- [ ] **Step 2: Run to verify failure** — `./run_tests.sh` → new file fails with "ParityDiff: attempt to call a nil value".

- [ ] **Step 3: Implement `vo.ParityDiff`** in `VO/lib/ajsfx_vo.lua`, directly after `vo.PlanUpdatePass`:

```lua
-- Parity: does one take's marker, item and sheet row still tell one story?
-- Pure -- the caller assembles the elements, this only compares. A recording
-- (several markers) is never compared: it has no one name and no one range,
-- and Cut is what turns it into takes. An unmarked item is Match's business.
-- See docs/superpowers/specs/2026-08-14-vo-parity-watcher-design.md §3.
function vo.ParityDiff(takes, opts)
  opts = opts or {}
  local eps = opts.eps or 0.005
  local out = {}
  for _, tk in ipairs(takes or {}) do
    if tk.marker and (tk.marker_count or 0) == 1 then
      local fields, detail = {}, nil
      local iname = tk.item and tk.item.name
      if iname and iname ~= "" and iname ~= tk.marker.asset
         and not vo.IsConventionalAltName(iname, tk.marker.asset, opts.alt_pattern) then
        fields[#fields + 1] = "name"
        detail = string.format("marker says %s, item says %s",
                               tostring(tk.marker.asset), iname)
      end
      if tk.sheet and tk.sheet.asset and tk.sheet.asset ~= tk.marker.asset then
        if #fields == 0 or fields[#fields] ~= "name" then
          fields[#fields + 1] = "name"
        end
        detail = detail or string.format("marker says %s, sheet says %s",
                 tostring(tk.marker.asset), tostring(tk.sheet.asset))
      end
      if tk.item and tk.item.from
         and (math.abs(tk.marker.start - tk.item.from) > eps
              or math.abs(tk.marker.stop - tk.item.to) > eps) then
        fields[#fields + 1] = "edges"
        detail = detail or string.format(
          "marker %.3f-%.3f, item %.3f-%.3f",
          tk.marker.start, tk.marker.stop, tk.item.from, tk.item.to)
      end
      if #fields > 0 then
        out[#out + 1] = { key = tk.key, fields = fields, detail = detail }
      end
    end
  end
  return out
end
```

**Check `vo.IsConventionalAltName`'s real signature first** (it exists — see `Trim.fix_names_from_sheet`'s comment). If it takes different arguments, adapt the call and the test, not the rule.

- [ ] **Step 4: Run tests** — `./run_tests.sh` → all pass. `luac -p VO/lib/ajsfx_vo.lua && rm -f luac.out`.

- [ ] **Step 5: Commit** — `git add -A tests VO/lib run_tests.sh && git commit -m "VO: ParityDiff says what disagrees, and refuses recordings"`

---

### Task 2: `vo.ParityAttribute` — who moved

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` (directly after `vo.ParityDiff`)
- Test: `tests/test_vo_parity.lua` (append)

**Interfaces:**
- Produces: `vo.ParityAttribute(changed) -> authority | nil` where `changed` is `{ edge = bool, name = bool, marker = bool, track = bool }` (what moved since the baseline, for one item) and the result is `"item" | "name" | "marker" | "sheet" | nil`:
  - exactly `edge` → `"item"` (edges are the truth; snap the marker)
  - exactly `name` → `"name"` (the typed name is the truth; the marker asset follows)
  - exactly `marker` → `"marker"` (the dragged/renamed marker is the truth; trim + rename the item)
  - exactly `track` → `"sheet"` (track placement is a statement about the marks)
  - `track` + `edge` from ONE gesture cannot happen (a move between tracks does not change length; position alone is not an edge — see Step 3) — any other combination of two or more → `nil`
  - nothing moved → `nil`

- [ ] **Step 1: Append the failing tests**

```lua
t.test("one element moved names the authority", function()
  t.eq(vo.ParityAttribute({ edge = true }),   "item")
  t.eq(vo.ParityAttribute({ name = true }),   "name")
  t.eq(vo.ParityAttribute({ marker = true }), "marker")
  t.eq(vo.ParityAttribute({ track = true }),  "sheet")
end)

t.test("two elements moved is nobody's authority", function()
  t.eq(vo.ParityAttribute({ edge = true, marker = true }), nil)
  t.eq(vo.ParityAttribute({ name = true, track = true }),  nil)
end)

t.test("nothing moved, nil, and nil input is not an error", function()
  t.eq(vo.ParityAttribute({}),  nil)
  t.eq(vo.ParityAttribute(nil), nil)
end)
```

- [ ] **Step 2: Run to verify failure** — `./run_tests.sh`.

- [ ] **Step 3: Implement**

```lua
-- Which single element did the user edit? The watcher hands in what changed
-- since the baseline; exactly one changed element IS the authority, anything
-- else is nil -- the tool acts on knowledge or it asks (spec §4.2).
--
-- "edge" means LENGTH or the source window changed, not position alone: a
-- track move keeps an item's length, and treating position as an edge would
-- turn every vertical drag into two changed elements and queue every one.
-- The caller (Trim.changes_since_last_look) is responsible for that
-- distinction; here four booleans go in and one name comes out.
function vo.ParityAttribute(changed)
  if not changed then return nil end
  local map = { edge = "item", name = "name", marker = "marker", track = "sheet" }
  local hit = nil
  for k, authority in pairs(map) do
    if changed[k] then
      if hit then return nil end
      hit = authority
    end
  end
  return hit
end
```

- [ ] **Step 4: Run tests, luac** — `./run_tests.sh` green; `luac -p VO/lib/ajsfx_vo.lua && rm -f luac.out`.

- [ ] **Step 5: Commit** — `git commit -am "VO: ParityAttribute -- one moved element is the authority, two is a question"`

---

### Task 3: The snapshot grows names and markers

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — `Trim.changes_since_last_look` (line ~1917) and its callers (line ~12973)
- Test: manual (REAPER writes); the pure attribution is already tested. Add checks to `VO/MANUAL_TEST.md`.

**Interfaces:**
- Consumes: `vo.ParityAttribute` (Task 2), `state.take_markers` (rebuilt by `Reload`).
- Produces: `Trim.changes_since_last_look() -> attributed, n_at, queued, n_q` **replacing** the old `retracked, n_re, edited, n_ed` return. `attributed` is `{ [item] = "item"|"name"|"marker"|"sheet" }`; `queued` is `{ [item] = true }` for items whose change could not be attributed. **Update the caller in the same commit** — the defer-loop block at ~12973 is the only caller (verify with grep before assuming).

- [ ] **Step 1: Extend the snapshot.** In `Trim.changes_since_last_look`, the per-item record grows two fields and the change sets are rebuilt on attribution:

```lua
-- Inside the loop, replacing the current snap/was logic. The marker
-- signature reads state.take_markers -- collected at the last Reload from
-- the item chunks -- NOT the chunk itself: this function runs on every
-- change tick, and chunk reads here would double the per-rescan tax the
-- take markers already charge. The consequence is one tick of lag (the
-- Reload between ticks refreshes the collection), which the settle window
-- already absorbs.
local track = r.GetMediaItem_Track(item)
local pos   = r.GetMediaItemInfo_Value(item, "D_POSITION")
local len   = r.GetMediaItemInfo_Value(item, "D_LENGTH")
local take  = r.GetActiveTake(item)
local _, nm = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
local offs  = take and r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS") or 0
-- LENGTH and source window are an edge; POSITION alone is a slide or a
-- track move and must not read as an edit of the take's extent.
local edge  = string.format("%.5f|%.5f", len, offs)
local msig  = Trim.marker_sig(item)          -- new helper, below
snap[item] = { track = track, edge = edge, name = nm or "", msig = msig,
               pos = string.format("%.5f", pos) }
local was = prev and prev[item]
if was then
  local changed = {
    track  = (was.track ~= track) or nil,
    edge   = (was.edge ~= edge and Trim.has_marker(item)) or nil,
    name   = (was.name ~= (nm or "")) or nil,
    marker = (was.msig ~= msig) or nil,
  }
  -- A pure slide (position moved, same track, same length/offs) is a
  -- deliberate placement, not a parity edit: project position does not
  -- appear in the invariant (markers live in SOURCE time). Ignored.
  local who = vo.ParityAttribute(changed)
  if who then
    attributed[item] = who; n_at = n_at + 1
  elseif next(changed) ~= nil then
    queued[item] = true; n_q = n_q + 1
  end
end
```

with `Trim.marker_sig` hung off `Trim` (no new top-level local):

```lua
-- One string per item summarising its tool markers, from the LAST RELOAD's
-- collection (state.take_markers), so comparing two of these asks "did a
-- marker move or change its line since the baseline" without reading a
-- chunk. Items are matched by pointer via the collection's info records.
function Trim.marker_sig(item)
  for _, group in pairs(state.take_markers or {}) do
    for _, entry in ipairs(group) do
      if entry.info and entry.info.item == item then
        local parts = {}
        for _, m in ipairs(entry.markers or {}) do
          local asset, id = vo.ParseMarkerName(m.name or "")
          if id then
            parts[#parts + 1] = string.format("%s|%s|%.5f|%.5f",
              id, tostring(asset), m.pos or 0, m.length or 0)
          end
        end
        table.sort(parts)
        return table.concat(parts, ";")
      end
    end
  end
  return ""
end
```

Keep the existing project-identity guard, the liveness check, and the first-look-is-a-baseline rule **exactly as they are** — first look still returns empty sets.

- [ ] **Step 2: The undo guard.** An automatic sync's own undo must not read as a fresh edit (spec §7). At the TOP of the settle-dispatch block (before acting on `attributed`), add:

```lua
-- Ctrl+Z after an automatic sync bumps the change counter and moves the
-- very elements the sync moved -- which would read as a user edit and
-- redo what the undo undid, forever. The top of the REDO stack names the
-- transaction that was just undone; if it is one of ours, this change is
-- an undo, and the only correct response is to adopt it as the new
-- baseline and stay quiet.
local redo = r.Undo_CanRedo2 and r.Undo_CanRedo2(0)
if redo and redo:find("^VO Overview") then
  state.pending_attributed, state.pending_queued = nil, nil
end
```

- [ ] **Step 3: Rewire the caller.** In the defer-loop watcher block (~12973): replace `retracked/edited` plumbing with `attributed/queued`:

```lua
local attributed, n_at, queued, n_q = Trim.changes_since_last_look()
if n_at > 0 then state.pending_attributed = MergeSets(state.pending_attributed, attributed) end
if n_q  > 0 then state.pending_queued    = MergeSets(state.pending_queued, queued)   end
```

`MergeSets` must not be a new top-level local — inline it (`for k,v in pairs(new) do old[k]=v end`) or hang it off `Trim`. Dispatch happens in Task 4; for THIS commit, keep behavior equivalent by translating the old dispatch inline: items attributed `"sheet"` feed the old `pending_retracked` path, items attributed `"item"` feed the old `pending_edited` path, and `"name"`/`"marker"`/queued are collected but unused. The three checkboxes still gate as before. This keeps the commit shippable.

- [ ] **Step 4: Verify** — `./run_tests.sh` green; `luac -p VO/ajsfx_VO_Overview.lua && rm -f luac.out`. Grep for other callers of `changes_since_last_look` (there is one more: the re-baseline call at ~13072, which discards returns — confirm it still parses).

- [ ] **Step 5: Commit** — `git commit -am "VO: the snapshot now sees names and markers, and attributes each change"`

---

### Task 4: Auto-sync dispatch and the one switch

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — settle dispatch (~12998–13039), `FOLLOW_KEYS` (~4253), the three checkboxes in the Fix row (~12384–12453), Settings load of follow keys (grep `SetFollowSetting` and the state init that reads the ExtState keys)
- Modify: `VO/MANUAL_TEST.md` (new section)

**Interfaces:**
- Consumes: `state.pending_attributed` / `state.pending_queued` (Task 3), `Trim.update(dir, opts)`, `Trim.fix_names_from_transcript(opts)`, `Trim.adopt_track_marks(moved)`, `ApplyAltNames()`, and the marker-retarget helper found near `vo.AddMarkerToItem` (lib ~9002, "Move ONE marker to another line") — **read it first and use its real name**.
- Produces: `state.session_sync` (boolean, ExtState key `"session_sync"`, default **true**), `Trim.sync_dispatch(attributed)` — the authority → waterfall router the queue panel reuses in Task 5.

- [ ] **Step 1: Replace the three settings with one.**
  - `FOLLOW_KEYS`: drop `"marks_follow_tracks", "tracking_follows_edit", "alt_names_follow_tracks"`, add `"session_sync"`.
  - Wherever those three are loaded into state (grep each name; there is an init that reads ExtState — line ~4254's list is the save side), load `session_sync` instead, defaulting to **true when the key is absent** (`r.GetExtState(...) ~= "false"`).
  - Delete the three checkboxes in the Fix row (lines ~12384–12453) — Task 6 rebuilds the row anyway, but the dead state reads must go now so the file never references removed keys. Add the one checkbox in their place:

```lua
Sep("Keep the session in sync")
local hit, v = im.Checkbox(ctx, "Keep the session in sync",
                           state.session_sync == true)
if hit then SetFollowSetting("session_sync", v) end
TooltipEvenWhenDisabled(
  "Edit one thing and the rest catches up by itself. The watcher sees\n" ..
  "which single element you changed and syncs the others FROM it:\n\n" ..
  "  trimmed the item     ->  the marker snaps to the new edges\n" ..
  "  dragged the marker   ->  the item trims and renames onto it\n" ..
  "  renamed the item     ->  the marker follows the new line\n" ..
  "  moved between tracks ->  the sheet's Sel / Keep follow, then alt names\n\n" ..
  "It waits for the drag to finish, acts once, and each sync is its own\n" ..
  "undo step. Anything it cannot pin on ONE element -- a split, a paste,\n" ..
  "two edits in one gesture -- goes to \"Out of sync\" instead of being\n" ..
  "guessed at. Off: nothing runs by itself and \"Out of sync\" collects\n" ..
  "everything.")
```

  (`SetFollowSetting` — grep it; if it validates against `FOLLOW_KEYS` the new key is already covered by the list edit.)

- [ ] **Step 2: The dispatcher.** Replace the two-branch settle dispatch (~12998) with one consumer of `state.pending_attributed`:

```lua
if (state.edit_settle or 0) >= 15 and not pending_action then
  if state.pending_attributed and next(state.pending_attributed) then
    local batch = state.pending_attributed
    state.pending_attributed = nil
    pending_action = function() Trim.sync_dispatch(batch) end
  end
  if state.pending_queued and next(state.pending_queued) then
    for item in pairs(state.pending_queued) do
      state.parity_queue_manual = state.parity_queue_manual or {}
      state.parity_queue_manual[item] = true
    end
    state.pending_queued = nil
  end
end
```

with the router hung off `Trim`:

```lua
-- The authority -> waterfall router, used by the watcher's automatic pass
-- and by the queue panel's "Fix from ..." buttons alike, so a hand-picked
-- fix and an automatic one cannot drift apart. `attributed` maps item ->
-- authority. Ordering inside one settle batch: sheet adoptions first
-- (marks), then geometry/name syncs, then alt names -- the same
-- marks-before-names rule the old followers enforced.
function Trim.sync_dispatch(attributed)
  local by = { item = {}, name = {}, marker = {}, sheet = {} }
  local n  = { item = 0,  name = 0,  marker = 0,  sheet = 0 }
  for item, who in pairs(attributed or {}) do
    by[who][item] = true; n[who] = n[who] + 1
  end
  if n.sheet > 0 then
    local adopted = Trim.adopt_track_marks(by.sheet)
    if adopted > 0 and state.session_sync then ApplyAltNames() end
  end
  if n.item > 0 then
    Trim.update("item", { picked = by.item })
    Trim.fix_names_from_transcript({ picked = by.item,
                                     no_reload = true, quiet = true })
  end
  if n.marker > 0 then
    Trim.update("marker", { picked = by.marker })
  end
  if n.name > 0 then
    Trim.retarget_from_names(by.name)   -- Step 3
  end
end
```

Gate the whole watcher block on `state.session_sync` instead of the three old flags (the block's opening `if` at ~12973 and the re-baseline `if` at ~13070). **When `session_sync` is off**, the snapshot must still run (the queue needs the diffs) but `pending_attributed` items are routed into `state.parity_queue_manual` instead of dispatched — one `if state.session_sync` around the dispatch branch.

- [ ] **Step 3: Renamed items retarget their marker.** Read the lib's move-marker-to-line helper (~9002) for its real name and signature; then:

```lua
-- The user typed a line's name onto an item: the name IS the assignment
-- (the governing rule), so the marker follows it. Only names that RESOLVE
-- to a script line count -- "great one, keep" is a note, not a
-- reassignment, and the marker it does not resolve to stays. Unresolvable
-- renames queue instead, with the evidence.
function Trim.retarget_from_names(items)
  local index = vo.BuildNameIndex(state.lines)
  for item in pairs(items or {}) do
    local take = r.GetActiveTake(item)
    local _, nm = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
    local line = nm and index and index[vo.NormalizeName and vo.NormalizeName(nm) or nm]
    -- ^ check how BuildNameIndex keys its entries (grep its body) and use
    --   the same lookup the rest of the file uses -- do not invent one.
    if line then
      -- <call the real move-marker helper here, one marker, keep id>
    else
      state.parity_queue_manual = state.parity_queue_manual or {}
      state.parity_queue_manual[item] = true
    end
  end
  Reload()
end
```

The `<call>` placeholder MUST be resolved while implementing — open lib ~9002, use the function found there (it moves one marker to another line in place, keeping every other marker and the id). If no such helper fits, write the marker list via `Trim.markers_in` + `vo.WriteTakeMarkers` with the asset swapped, keeping id/start/stop.

- [ ] **Step 4: Verify** — `./run_tests.sh`; `luac -p VO/ajsfx_VO_Overview.lua && rm -f luac.out`. Grep the file for the three retired setting names: **zero hits** outside comments.

- [ ] **Step 5: Manual test additions.** Append to `VO/MANUAL_TEST.md`:

```markdown
## Parity watcher (0.15beta21)

1. Trim a tracked clip's edge -> within a second the marker snaps to it,
   one undo step, one log line. Ctrl+Z once -> the trim AND the sync are
   two steps; after both undos nothing re-fires.
2. Drag a take marker inside a clip -> the item trims onto it and takes
   its name. One undo step.
3. Rename an item to another line's exact name -> the marker follows.
   Rename it to "asdf" -> nothing happens; Out of sync gains a row.
4. Drag a take from Review to Selects -> Sel ticks itself; alt names run
   after. Off-switch test: untick "Keep the session in sync", repeat ->
   nothing moves, Out of sync gains the row instead.
5. Split a clip -> both halves queue (whole marker set on each), neither
   is renamed automatically.
```

- [ ] **Step 6: Commit** — `git commit -am "VO: one switch, one dispatcher -- the session keeps itself in sync"`

---

### Task 5: The Out of sync queue

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — new panel drawer beside the existing `disagree` panel (~8040), Check-tab wiring (~12589), queue assembly on Reload
- Test: pure assembly logic in lib + `tests/test_vo_parity.lua`; panel is manual.

**Interfaces:**
- Consumes: `vo.ParityDiff` (Task 1), `state.take_markers`, `state.overview` rows (for sheet assets — same source `PlanReconcile` reads), `state.parity_queue_manual` (Task 4), `Trim.sync_dispatch` (Task 4).
- Produces: `vo.ParityAssemble(collected, rows, opts) -> takes` (pure: shapes `CollectTakeMarkers` output + sheet rows into `ParityDiff` input), `state.parity_queue` (array of `{ item, info, divergence }`), a `PanelButton("outofsync", ...)`.

- [ ] **Step 1: Test the assembler.** The one pure piece: turning a `CollectTakeMarkers`-shaped group + rows into `ParityDiff` takes. Append to `tests/test_vo_parity.lua`:

```lua
t.test("ParityAssemble shapes a collected item into a diffable take", function()
  local collected = { ["src.wav"] = { {
    coverage = { from = 1.25, to = 3.50 },
    markers  = { { pos = 1.25, length = 2.25, name = "IWinBig_02 ~abc" } },
    info     = { item = "ITEM1", take_name = "IWinBig_02" },
  } } }
  local rows = { { item = "ITEM1", asset = "IWinBig_02" } }
  local takes = vo.ParityAssemble(collected, rows)
  t.eq(#takes, 1)
  t.eq(takes[1].key, "ITEM1")
  t.eq(takes[1].marker.asset, "IWinBig_02")
  t.eq(takes[1].marker_count, 1)
  t.eq(takes[1].item.name, "IWinBig_02")
  t.eq(takes[1].item.from, 1.25)
  t.eq(takes[1].sheet.asset, "IWinBig_02")
end)
```

**Check `vo.ParseMarkerName`'s marker-name format** in existing tests (grep `" ~"` in tests/) and use a real formatted name in the fixture, plus the real row field for the sheet's asset (`row.asset` vs `row.deliver` — copy whichever `PlanReconcile`/the sheet actually uses).

- [ ] **Step 2: Run to verify failure**, then implement in lib:

```lua
-- Shape one project's collected take markers + sheet rows into ParityDiff
-- input. Rows are matched to items by the row's resolved item; an item the
-- sheet does not know contributes no sheet element (nil), which ParityDiff
-- treats as nothing to compare -- not a divergence.
function vo.ParityAssemble(collected, rows, opts)
  local sheet_by_item = {}
  for _, row in ipairs(rows or {}) do
    if row.item and row.asset then sheet_by_item[row.item] = { asset = row.asset } end
  end
  local out = {}
  for _, group in pairs(collected or {}) do
    for _, entry in ipairs(group) do
      local tool = {}
      for _, m in ipairs(entry.markers or {}) do
        local asset, id = vo.ParseMarkerName(m.name or "")
        if id and not vo.IsNoteMarker(m.name or "") then
          tool[#tool + 1] = { asset = asset, start = m.pos or 0,
                              stop = (m.pos or 0) + (m.length or 0) }
        end
      end
      local item = entry.info and entry.info.item
      if item then
        out[#out + 1] = {
          key = item,
          marker = tool[1],
          marker_count = #tool,
          item = entry.coverage and {
            name = entry.info.take_name or "",
            from = entry.coverage.from, to = entry.coverage.to } or nil,
          sheet = sheet_by_item[item],
        }
      end
    end
  end
  return out
end
```

(Adapt field names to the fixture reality checked in Step 1 — `info.take_name` vs reading the name elsewhere; whatever `state.items` info records actually carry, mirror it, and make the test fixture match.)

- [ ] **Step 3: Queue assembly in the Overview.** After `state.reconcile = vo.PlanReconcile(...)` (~1113), in the same Reload path:

```lua
-- The parity queue: every divergence the watcher may not fix by itself.
-- Diffed fresh per Reload from the same collections the sheet already
-- paid for; the manual set (splits, pastes, refused syncs) is merged in
-- and survives until its item either agrees or dies.
state.parity_queue = {}
local takes = vo.ParityAssemble(state.take_markers, state.overview,
                                { })
for _, d in ipairs(vo.ParityDiff(takes,
    { alt_pattern = cfg.alt_append_pattern })) do
  state.parity_queue[#state.parity_queue + 1] = { item = d.key, divergence = d }
end
local seen = {}
for _, q in ipairs(state.parity_queue) do seen[q.item] = true end
for item in pairs(state.parity_queue_manual or {}) do
  if Trim.item_alive(item) and not seen[item] then
    state.parity_queue[#state.parity_queue + 1] =
      { item = item, divergence = { fields = { "unattributed" },
        detail = "changed in a way the watcher could not pin on one element" } }
  elseif not Trim.item_alive(item) then
    state.parity_queue_manual[item] = nil
  end
end
```

An item in the manual set whose diff is now clean must ALSO leave the manual set (it was fixed): drop it when `ParityDiff` returns nothing for it and it holds one marker. (One `elseif` on the loop above; recordings stay queued until cut.)

- [ ] **Step 4: The panel.** Clone the structure of the `disagree` panel (~8040–8100) into a new `elseif state.panel == "outofsync"` branch:

```lua
-- Per row: what disagrees, in words, then the four authorities. Each
-- button routes through Trim.sync_dispatch with a one-item map, so a
-- hand-picked fix and an automatic one are the same code path.
for i, q in ipairs(state.parity_queue or {}) do
  im.Text(ctx, string.format("%d.", i))
  im.SameLine(ctx)
  im.TextWrapped(ctx, q.divergence.detail or "out of sync")
  for _, b in ipairs({
      { "Transcript", function(it) Trim.fix_names_from_transcript({
          picked = { [it] = true } }) end },
      { "Marker", function(it) Trim.sync_dispatch({ [it] = "marker" }) end },
      { "Item",   function(it) Trim.sync_dispatch({ [it] = "item" }) end },
      { "Sheet",  function(it) pending_action_row = it end },  -- see note
    }) do
    im.SameLine(ctx)
    if im.SmallButton(ctx, string.format("Fix from %s##oos%d", b[1], i)) then
      local it = q.item
      pending_action = function()
        b[2](it)
        if state.parity_queue_manual then state.parity_queue_manual[it] = nil end
        Reload()
      end
    end
  end
end
```

"Fix from Sheet" per row = `Trim.fix_names_from_sheet` scoped to that item's row. `fix_names_from_sheet` has no `picked` — **add one**: accept `opts.picked` and skip edits whose resolved item is not in it (one `if` beside the existing `claimed[item]` check). Batch buttons above the list: the same four, over every queued item, one `Trim.sync_dispatch` call each (`fix_names_from_sheet` once with the union). Also draw the empty state: `im.TextDisabled(ctx, "(0) -- the session agrees with itself.")`.

- [ ] **Step 5: Check-tab wiring.** In the Check tab (~12589), replace the `disagree` PanelButton with:

```lua
local n_oos = #(state.parity_queue or {})
PanelButton("outofsync", string.format("Out of sync (%d)", n_oos),
  "Takes whose marker, item name, sheet row or edges no longer tell one\n" ..
  "story, plus anything the watcher refused to guess about (splits,\n" ..
  "pastes, two edits in one gesture). Each row says what disagrees and\n" ..
  "takes a \"Fix from ...\" -- the same waterfalls the watcher runs, with\n" ..
  "you naming the authority. (0) means the session agrees with itself.")
```

Keep `unbacked_markers`/`orphan_marks` reporting (the `noaudio` panel) untouched — only the `disagree` panel and its count fold into the queue (`Trim.adopt_track_marks` keeps reading `state.reconcile`, so `PlanReconcile` still runs; only the PANEL retires). Delete the `disagree` panel branch and its PanelButton; grep `"disagree"` for stragglers (the Adopt timeline/Adopt sheet buttons live in that branch — their batch role is replaced by the queue's batch "Fix from Sheet" [adopt sheet] and "Fix from Item"-style adoption of the timeline via sync_dispatch `sheet` routing… **NO** — mark adoption from the TIMELINE is `Trim.sync_dispatch({item="sheet"})`?? Wrong direction. Read carefully: "adopt the timeline" = marks follow tracks = `Trim.adopt_track_marks(items)` = sync authority `sheet`?? The authority named "sheet" in ParityAttribute fires on a TRACK move and *writes the sheet from the track*. So the queue's "Fix from Item"-adjacent action for a marks disagreement is `Trim.sync_dispatch({ [it] = "sheet" })` (timeline wins, marks follow), and "adopt sheet" = `Dest.pull_all` scoped… which is Pull's business, not the queue's. KEEP the two batch buttons "Adopt timeline" / "Adopt sheet" as queue-level batch actions for rows whose divergence is marks-vs-tracks, wired to the existing `Trim.adopt_track_marks(nil)` and the existing adopt-sheet handler from the old panel (~8088). Do not invent new semantics.)

- [ ] **Step 6: Verify** — `./run_tests.sh`; `luac -p VO/ajsfx_VO_Overview.lua && rm -f luac.out`; grep `state.panel == "disagree"` → gone.

- [ ] **Step 7: Commit** — `git commit -am "VO: Out of sync -- every divergence in one place, each with its Fix from"`

---

### Task 6: The Fix row endgame

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — Fix row (~12150–12453)

**Interfaces:**
- Consumes: everything above. No new functions.

- [ ] **Step 1: Rebuild the row** to spec §6:

```
Fix:  [ Fix from Transcript ]  [ Out of sync (n) ]
      [ Cut from markers ]  [ Re-cut selected takes ]
      ── [ Auto-adjust head and tail ]  [ Apply the cut fades ]
      ── [ Restore missing lines ]
      [x] Keep the session in sync
```

- "Fix from Transcript" = `Trim.fix_names_from_transcript` (rename the button at ~12326, move it into the MACRO slot at the row's head, keep its tooltip's substance, first line: `"The TRANSCRIPT is the authority: my edits and names are suspect,\nre-derive who is who from the words."`).
- `Out of sync (n)` = the same PanelButton as the Check tab (both tabs may show it; the panel is one).
- Remove the buttons for: Update from Item (~12160), Trim items to their markers (~12261), Snap markers to items (~12273), Remove Extra Take Markers (~12243), Fix names from the sheet (~12346). **Functions stay** (`Trim.update`, `Trim.run`, `Trim.remove_extras`, `Trim.fix_names_from_sheet`) — the dispatcher and the queue call them.
- The three follower checkboxes are already gone (Task 4).
- Keep: Cut from markers, Re-cut selected takes, Auto-adjust head and tail, Apply the cut fades, Restore missing lines, Untrack (the red destructive band stays where it is).
- Update the Match row's macro tooltip if it names a removed button (grep the tooltips for `"Update from Item"`, `"Remove Extra Take Markers"`, `"Snap markers"` — rewrite those sentences to point at the watcher / Out of sync instead).

- [ ] **Step 2: Verify** — `./run_tests.sh`; `luac -p VO/ajsfx_VO_Overview.lua && rm -f luac.out`; then count: the Fix row draws exactly 8 controls.

- [ ] **Step 3: Commit** — `git commit -am "VO: the Fix row says who the authority is, and little else"`

---

### Task 7: Spec file, version, release

**Files:**
- Create: `VO/SPEC-parity-watcher.md` (condensed from the design doc, repo-spec style: status line, the idea, what runs when, what refuses, testing table — model it on `VO/SPEC-authority-buttons.md`; mark REAPER writes UNVERIFIED until the manual pass)
- Modify: `VO/ajsfx_VO_Overview.lua` header — `@version 0.15beta21`, `@changelog` block listing: the parity watcher, the one sync switch, Out of sync panel, retired buttons.
- Modify: `VO/SPEC-authority-buttons.md` — add a `Superseded by VO/SPEC-parity-watcher.md` line under its Status.

- [ ] **Step 1: Write the SPEC file and the header bump.** Changelog text:

```
@changelog
  The session keeps itself in sync: edit one thing (item edge, marker,
  item name, track placement) and the rest catches up automatically.
  Anything the watcher cannot pin on one element lands in the new
  "Out of sync" panel with Fix from Transcript / Marker / Item / Sheet.
  One switch ("Keep the session in sync") replaces the three follower
  checkboxes; Update from Item, Trim/Snap, Remove Extras and both
  Fix-names buttons fold into the watcher and the queue.
```

- [ ] **Step 2: Full gate** — `./run_tests.sh` all pass; `luac -p` on both touched Lua files; `rm -f luac.out`; `git status` clean of strays.

- [ ] **Step 3: Commit** — `git commit -am "VO Overview 0.15beta21: the session keeps itself in sync"`

- [ ] **Step 4: Merge and confirm.** `git checkout main && git merge --no-ff <branch> && git push origin main`, then `gh run list --limit 1` until green and skim the log for reapack-index warnings (a "successful" index build can silently omit a package).

- [ ] **Step 5: Post-release.** Update memory (`vo-next-session.md`: parity watcher shipped as 0.15beta21, REAPER manual pass pending) and note the MANUAL_TEST checks that still need a live REAPER pass.
