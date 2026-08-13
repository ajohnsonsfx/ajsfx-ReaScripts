# VO Verify Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `VO/SPEC-verify.md` — the fingerprinted Vetted stamp, the Verify pass (fresh span decode → verdict → action), and the Suspects panel.

**Architecture:** All judgment logic is pure functions in `VO/lib/ajsfx_vo.lua`, TDD'd against the mock. `VO/ajsfx_VO_Overview.lua` gains one namespace table `Verify` holding the queue state machine, the fourth checkbox, the context-menu entry, and the Suspects panel. Whisper runs through the existing `BuildWhisperArgv(span)` + `RunWhisperAsync` machinery.

**Tech Stack:** Lua 5.x, REAPER API via `tests/mock_reaper.lua` in tests, ReaImGui in Overview, whisper-cli.

## Global Constraints

- Work on branch `feature/vo-verify` off `main`. Merge → main releases via CI.
- `VO/ajsfx_VO_Overview.lua` is at Lua's 200-local cap: **no new top-level `local` of any kind except the single `local Verify = {}`**. Everything else hangs off `Verify` or existing tables. After every Overview edit run `luac -p VO/ajsfx_VO_Overview.lua` (or `"$LUA"c -p`); green tests alone are not proof it loads.
- The word "verified" is taken: `row.user_status == "verified"` means **Lock**. All new identifiers use **vetted** (`row.vetted_state`, `vo.VettedFingerprint`, `P_EXT:ajsfx_vo_vetted`). UI copy may say "verified by the machine"; identifiers may not.
- Never write any convention into a take-marker asset — the marker names the line, nothing else.
- Spans are the item's **source-coverage window** (`source_start`/`source_stop` on the row), never sheet rows.
- No auto-rename, ever. Wrong-line verdicts move + suggest only.
- Locked rows (`row.user_status == "verified"`) are never moved by Verify.
- Floats in fingerprints print `%.4f`. Fingerprint is compared as a whole string; it is never parsed.
- Tests: append to `tests/test_vo.lua`; run with `./run_tests.sh`. Mock must be `mock.reset()` before `require("ajsfx_vo")` (already true at file top).
- Commit after every green task with the repo's `VO:` prefix style.

---

### Task 1: Branch, mock P_EXT support, fingerprint + accessors

**Files:**
- Modify: `tests/mock_reaper.lua` (add `GetSetMediaItemInfo_String`)
- Modify: `VO/lib/ajsfx_vo.lua` (add near the other item helpers, ~5580 region)
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `vo.WordsHash(words, from, to) -> string` — djb2 hex over words whose midpoint lies in `[from, to]`.
  - `vo.VettedFingerprint(fp) -> string` — `fp = { source_path, start_offs, length, playrate, take_name, mk_pos, mk_len, words }` (mk fields nil-able; `words` is the source's full word list; span is derived internally as `from = start_offs`, `to = start_offs + length * playrate`).
  - `vo.ReadVetted(item) -> string|nil`, `vo.WriteVetted(item, fp_string)`.
  - Mock: `reaper.GetSetMediaItemInfo_String(item, "P_EXT:<k>", v, set)` emulation.

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feature/vo-verify
```

- [ ] **Step 2: Add P_EXT emulation to the mock**

In `tests/mock_reaper.lua`, next to `GetSetMediaItemTakeInfo_String`:

```lua
function reaper.GetSetMediaItemInfo_String(item, param, value, set)
  if type(param) == "string" and param:sub(1, 6) == "P_EXT:" then
    item.ext = item.ext or {}
    local key = param:sub(7)
    if set then item.ext[key] = value return true, value end
    local got = item.ext[key]
    return got ~= nil and got ~= "", got or ""
  end
  return false, ""
end
```

- [ ] **Step 3: Write the failing tests**

Append to `tests/test_vo.lua`:

```lua
test("WordsHash: stable, span-scoped, order of outside words irrelevant", function()
  local words = {
    { t0 = 1.0, t1 = 1.4, text = "chain" },
    { t0 = 1.5, t1 = 1.9, text = "is" },
    { t0 = 9.0, t1 = 9.5, text = "elsewhere" },
  }
  local h1 = vo.WordsHash(words, 0.5, 2.0)
  assert(type(h1) == "string" and #h1 > 0, "hash is a non-empty string")
  assert(h1 == vo.WordsHash(words, 0.5, 2.0), "deterministic")
  local without = { words[1], words[2] }
  assert(h1 == vo.WordsHash(without, 0.5, 2.0), "words outside the span do not matter")
  local edited = { { t0 = 1.0, t1 = 1.4, text = "brain" }, words[2] }
  assert(h1 ~= vo.WordsHash(edited, 0.5, 2.0), "text change changes the hash")
end)

test("VettedFingerprint: every judged field moves the string", function()
  local base = {
    source_path = "D:\\Audio\\Take01.wav", start_offs = 12.34567, length = 3.2,
    playrate = 1.0, take_name = "ChainIsChain",
    mk_pos = 12.5, mk_len = 2.9,
    words = { { t0 = 12.6, t1 = 13.0, text = "chain" } },
  }
  local fp = vo.VettedFingerprint(base)
  assert(fp:sub(1, 3) == "v1|", "versioned")
  assert(fp:find("12.3457", 1, true), "start_offs quantised %.4f")
  assert(fp:find("d:/audio/take01.wav", 1, true), "path folded + slash-normalised")
  local function differs(mut)
    local c = {}
    for k, v in pairs(base) do c[k] = v end
    for k, v in pairs(mut) do c[k] = v end
    assert(vo.VettedFingerprint(c) ~= fp, "expected change for " .. next(mut))
  end
  differs{ start_offs = 12.4 }              -- trimmed edge
  differs{ length = 3.5 }                   -- resized
  differs{ take_name = "EvenIfYouSmile" }   -- reassigned
  differs{ mk_pos = 12.6 }                  -- marker moved
  differs{ words = { { t0 = 12.6, t1 = 13.0, text = "brain" } } } -- words changed
  local c = {}
  for k, v in pairs(base) do c[k] = v end
  c.mk_pos, c.mk_len = nil, nil
  assert(vo.VettedFingerprint(c):find("|-|-|", 1, true), "no marker prints -|-")
end)

test("ReadVetted/WriteVetted round-trip on the mock item", function()
  local item = { info = {} }
  assert(vo.ReadVetted(item) == nil, "empty item reads nil")
  vo.WriteVetted(item, "v1|abc")
  assert(vo.ReadVetted(item) == "v1|abc", "round trip")
end)
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
./run_tests.sh
```

Expected: the three new tests FAIL (`WordsHash` nil).

- [ ] **Step 5: Implement in `VO/lib/ajsfx_vo.lua`**

Near `vo.SourceCoverageRanges` (~5612):

```lua
-- djb2 over the words whose midpoint falls inside [from, to]. The hash keys
-- the Vetted fingerprint to the transcript content under one item, so a
-- gap-repair merge elsewhere in the file cannot invalidate this item.
function vo.WordsHash(words, from, to)
  local h = 5381
  for _, w in ipairs(words or {}) do
    local mid = ((w.t0 or 0) + (w.t1 or 0)) / 2
    if mid >= from - 1e-6 and mid <= to + 1e-6 then
      local s = string.format("%s@%.2f", w.text or "", w.t0 or 0)
      for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    end
  end
  return string.format("%08x", h)
end

-- The stamp value: everything the machine judged, quantised so float
-- formatting cannot fake a mismatch. Compared whole, never parsed.
function vo.VettedFingerprint(fp)
  local rate = fp.playrate or 1.0
  if rate <= 0 then rate = 1.0 end
  local from = fp.start_offs or 0
  local to = from + (fp.length or 0) * rate
  local q = function(x) return x and string.format("%.4f", x) or "-" end
  local path = (fp.source_path or ""):lower():gsub("\\", "/")
  return table.concat({
    "v1", path, q(from), q(fp.length), q(rate),
    fp.take_name or "", q(fp.mk_pos), q(fp.mk_len),
    vo.WordsHash(fp.words, from, to),
  }, "|")
end

vo.VETTED_EXT = "P_EXT:ajsfx_vo_vetted"

function vo.ReadVetted(item)
  local ok, v = r.GetSetMediaItemInfo_String(item, vo.VETTED_EXT, "", false)
  if ok and v ~= "" then return v end
  return nil
end

function vo.WriteVetted(item, fp_string)
  r.GetSetMediaItemInfo_String(item, vo.VETTED_EXT, fp_string or "", true)
end
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
./run_tests.sh
```

Expected: PASS, no prior test broken.

- [ ] **Step 7: Commit**

```bash
git add tests/mock_reaper.lua tests/test_vo.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: vetted fingerprint -- the stamp stores what was judged"
```

---

### Task 2: Word comparison + thresholds table

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua`
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `vo.VERIFY_THRESH = { stale_ratio = 0.20, match = 0.72, reject = 0.45, margin = 0.15, pad = 0.25, thin_cover = 0.40 }` — every Verify tunable, one table.
  - `vo.NormalizeTokens(words) -> string[]` — case-folded, punctuation-stripped, empties dropped.
  - `vo.CompareWords(fresh, stored, thresh) -> { same = bool, ratio = number }` — token edit distance / max length; `same` when ratio <= `thresh.stale_ratio`. Both-empty is `same = true, ratio = 0`; one-empty is `same = false, ratio = 1`.

- [ ] **Step 1: Write the failing tests**

```lua
test("CompareWords: jitter passes, real edits fail", function()
  local T = vo.VERIFY_THRESH
  local a = {
    { text = "Chain" }, { text = "is" }, { text = "chain." },
    { text = "Even" }, { text = "if" }, { text = "you" }, { text = "smile." },
  }
  local same = vo.CompareWords(a, a, T)
  assert(same.same and same.ratio == 0, "identical is same")
  local jitter = { { text = "chain" }, { text = "is" }, { text = "chain" },
    { text = "even" }, { text = "if" }, { text = "you" }, { text = "smile" } }
  assert(vo.CompareWords(a, jitter, T).same, "case/punctuation jitter is not staleness")
  local edited = { { text = "Chain" }, { text = "is" }, { text = "chain." } }
  local res = vo.CompareWords(a, edited, T)
  assert(not res.same, "audio halved = stale")
  assert(vo.CompareWords({}, {}, T).same, "both empty: nothing to disagree about")
  assert(not vo.CompareWords(a, {}, T).same, "stored empty, fresh speech = stale")
end)
```

- [ ] **Step 2: Run to verify failure** — `./run_tests.sh`, expect FAIL (`VERIFY_THRESH` nil).

- [ ] **Step 3: Implement**

```lua
-- Every Verify tunable in one place, so tuning is one edit.
vo.VERIFY_THRESH = {
  stale_ratio = 0.20, -- CompareWords: edit-distance ratio above this = stale
  match       = 0.72, -- JudgeLine: named-line score at/above this = match
  reject      = 0.45, -- JudgeLine: named-line score below this may lose to a rival
  margin      = 0.15, -- JudgeLine: rival must beat the named line by this much
  pad         = 0.25, -- PlanVerify: seconds of span padding for edge words
  thin_cover  = 0.40, -- ScanSuspects: word coverage below this fraction = thin
}

function vo.NormalizeTokens(words)
  local out = {}
  for _, w in ipairs(words or {}) do
    local t = (w.text or ""):lower():gsub("[^%w']", "")
    if t ~= "" then out[#out + 1] = t end
  end
  return out
end

function vo.CompareWords(fresh, stored, thresh)
  local a, b = vo.NormalizeTokens(fresh), vo.NormalizeTokens(stored)
  if #a == 0 and #b == 0 then return { same = true, ratio = 0 } end
  if #a == 0 or #b == 0 then return { same = false, ratio = 1 } end
  -- Token-level Levenshtein, same shape as the char-level one FindSpanLines uses.
  local prev = {}
  for j = 0, #b do prev[j] = j end
  for i = 1, #a do
    local cur = { [0] = i }
    for j = 1, #b do
      local cost = (a[i] == b[j]) and 0 or 1
      cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
    end
    prev = cur
  end
  local ratio = prev[#b] / math.max(#a, #b)
  return { same = ratio <= (thresh or vo.VERIFY_THRESH).stale_ratio, ratio = ratio }
end
```

- [ ] **Step 4: Run to verify pass** — `./run_tests.sh`.

- [ ] **Step 5: Commit**

```bash
git add tests/test_vo.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: CompareWords -- whisper jitter is not staleness"
```

---

### Task 3: Line judgment

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua`
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: `vo.FindSpanLines(lines, text, cfg, opts)` (`VO/lib/ajsfx_vo.lua:3950`) — returns `{ { line_idx, score, asset, deliver, text, speaker }, ... }` sorted by score desc; `opts.floor` (default 0.25), `opts.limit`.
- Produces: `vo.JudgeLine(fresh_words, lines, named_asset, cfg, thresh) -> { verdict = "match"|"wrong"|"unsure", named_score = n, best = hit|nil }` where `best` is the winning rival hit (only set for `"wrong"`).

Rules (from SPEC §2): `match` when named-line score ≥ `thresh.match`. `wrong` only when the named score < `thresh.reject` AND some *other* line scores ≥ `thresh.match` AND beats the named score by ≥ `thresh.margin`. Everything else `unsure`. A `named_asset` that is not in `lines` at all scores 0.

- [ ] **Step 1: Write the failing tests**

```lua
test("JudgeLine: match / wrong / unsure bands", function()
  local lines = {
    { asset = "ChainIsChain",   text = "Chain is chain." },
    { asset = "EvenIfYouSmile", text = "Even if you smile." },
  }
  local cfg, T = {}, vo.VERIFY_THRESH
  local said_chain = { { text = "chain" }, { text = "is" }, { text = "chain" } }
  local v = vo.JudgeLine(said_chain, lines, "ChainIsChain", cfg, T)
  assert(v.verdict == "match", "right words, right name: " .. v.verdict)

  local v2 = vo.JudgeLine(said_chain, lines, "EvenIfYouSmile", cfg, T)
  assert(v2.verdict == "wrong", "clearly says the other line: " .. v2.verdict)
  assert(v2.best and v2.best.asset == "ChainIsChain", "suggestion is the winner")

  local mumble = { { text = "chai" }, { text = "if" }, { text = "smi" } }
  local v3 = vo.JudgeLine(mumble, lines, "ChainIsChain", cfg, T)
  assert(v3.verdict == "unsure", "nothing convincing: " .. v3.verdict)

  local v4 = vo.JudgeLine(said_chain, lines, "NoSuchLine", cfg, T)
  assert(v4.verdict == "wrong" and v4.best.asset == "ChainIsChain",
         "unknown name loses to a clear winner")
end)
```

- [ ] **Step 2: Run to verify failure** — `./run_tests.sh`.

- [ ] **Step 3: Implement**

```lua
-- Which line do these words actually say? Verify's second comparison.
-- "wrong" needs a clear rival: a low named score alone is only "unsure",
-- because moving an item on a hunch is worse than leaving a flag.
function vo.JudgeLine(fresh_words, lines, named_asset, cfg, thresh)
  local T = thresh or vo.VERIFY_THRESH
  local toks = vo.NormalizeTokens(fresh_words)
  local text = table.concat(toks, " ")
  local hits = vo.FindSpanLines(lines or {}, text, cfg or {}, { floor = 0, limit = 8 })
  local named_score, best_other = 0, nil
  for _, h in ipairs(hits) do
    if h.asset == named_asset then
      if h.score > named_score then named_score = h.score end
    elseif not best_other or h.score > best_other.score then
      best_other = h
    end
  end
  if named_score >= T.match then return { verdict = "match", named_score = named_score } end
  if best_other and best_other.score >= T.match
     and named_score < T.reject
     and best_other.score - named_score >= T.margin then
    return { verdict = "wrong", named_score = named_score, best = best_other }
  end
  return { verdict = "unsure", named_score = named_score }
end
```

- [ ] **Step 4: Run to verify pass** — `./run_tests.sh`. If the `unsure` case lands in the wrong band, tune the *test's* mumble words, not the thresholds — the thresholds are the spec's contract.

- [ ] **Step 5: Commit**

```bash
git add tests/test_vo.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: JudgeLine -- wrong needs a clear rival, not just a low score"
```

---

### Task 4: Verify planning + suspect scan

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua`
- Test: `tests/test_vo.lua`

**Interfaces:**
- Consumes: row fields as Overview builds them (`~:780`): `row.uid`, `row.asset`, `row.item`, `row.take_name`, `row.source_path`, `row.source_start`, `row.source_stop`, `row.marker_id`, `row.status`, `row.user_status`. Task 2/3 functions. `transcripts` = `{ { path, words }, ... }` (shape of `state.transcripts`, `ajsfx_VO_Overview.lua:694`).
- Produces:
  - `vo.PlanVerify(rows, thresh) -> { { uid, asset, item, take_name, source_path, span = {from, to}, mk_pos, mk_len, locked }, ... }` — one entry per row with an item and a source span; span padded ±`thresh.pad`, `from` clamped ≥ 0; ordered by `source_path` then `from`; orphan rows and rows without `source_path` skipped. `mk_pos`/`mk_len` are passed through from `row.marker_pos`/`row.marker_len` (nil-able) — Task 6's `Verify.Stamp` reads them off the entry.
  - `vo.ScanSuspects(rows, transcripts, lines, cfg, thresh) -> { { row, triggers = { name_mismatch=?, thin=?, unmarked=?, stamp=? } }, ... }` — a row appears once with every fired trigger; rows with no item or no source are skipped. `stamp` fires when `row.vetted_state == "mismatch"` (computed by the Overview driver in Task 5).

- [ ] **Step 1: Write the failing tests**

```lua
test("PlanVerify: pads, clamps, orders, skips", function()
  local rows = {
    { uid = "b#1", asset = "B", item = {}, take_name = "B", source_path = "z.wav",
      source_start = 5.0, source_stop = 7.0, status = "ok" },
    { uid = "a#1", asset = "A", item = {}, take_name = "A", source_path = "a.wav",
      source_start = 0.1, source_stop = 1.0, status = "ok", user_status = "verified" },
    { uid = "orphan#1", asset = "", status = "orphan" },
    { uid = "nosrc#1", asset = "C", item = {}, status = "ok" },
  }
  local plan = vo.PlanVerify(rows, vo.VERIFY_THRESH)
  assert(#plan == 2, "orphan and sourceless skipped, got " .. #plan)
  assert(plan[1].source_path == "a.wav" and plan[2].source_path == "z.wav", "ordered by source")
  assert(plan[1].span.from == 0, "pad clamped at zero")
  assert(math.abs(plan[1].span.to - 1.25) < 1e-9, "padded stop")
  assert(plan[1].locked == true and not plan[2].locked, "lock travels with the entry")
end)

test("ScanSuspects: each trigger fires alone", function()
  local lines = {
    { asset = "ChainIsChain",   text = "Chain is chain." },
    { asset = "EvenIfYouSmile", text = "Even if you smile." },
  }
  local words = {
    { t0 = 0.1, t1 = 0.5, text = "chain" }, { t0 = 0.5, t1 = 0.7, text = "is" },
    { t0 = 0.7, t1 = 1.2, text = "chain" },
  }
  local transcripts = { { path = "a.wav", words = words } }
  local function mkrow(o)
    o.item = o.item or {}
    o.source_path = o.source_path or "a.wav"
    o.status = o.status or "ok"
    return o
  end
  local rows = {
    mkrow{ uid = "good", asset = "ChainIsChain", take_name = "ChainIsChain",
           source_start = 0.0, source_stop = 1.3, marker_id = 7 },
    mkrow{ uid = "misnamed", asset = "EvenIfYouSmile", take_name = "EvenIfYouSmile",
           source_start = 0.0, source_stop = 1.3, marker_id = 8 },
    mkrow{ uid = "thin", asset = "ChainIsChain", take_name = "ChainIsChain",
           source_start = 0.0, source_stop = 10.0, marker_id = 9 },
    mkrow{ uid = "unmarked", asset = "ChainIsChain", take_name = "ChainIsChain",
           source_start = 0.0, source_stop = 1.3 },
    mkrow{ uid = "moved", asset = "ChainIsChain", take_name = "ChainIsChain",
           source_start = 0.0, source_stop = 1.3, marker_id = 10, vetted_state = "mismatch" },
  }
  local sus = vo.ScanSuspects(rows, transcripts, lines, {}, vo.VERIFY_THRESH)
  local by = {}
  for _, s in ipairs(sus) do by[s.row.uid] = s.triggers end
  assert(by.good == nil, "clean row is not a suspect")
  assert(by.misnamed and by.misnamed.name_mismatch, "stored words disagree with the name")
  assert(by.thin and by.thin.thin, "words cover a sliver of a 10s window")
  assert(by.unmarked and by.unmarked.unmarked, "no take marker claims it")
  assert(by.moved and by.moved.stamp, "vetted fingerprint no longer matches")
end)
```

- [ ] **Step 2: Run to verify failure** — `./run_tests.sh`.

- [ ] **Step 3: Implement**

```lua
-- What the Verify queue will decode: one entry per deliverable row, span
-- padded so edge words are not clipped, grouped per source file.
function vo.PlanVerify(rows, thresh)
  local T = thresh or vo.VERIFY_THRESH
  local out = {}
  for _, row in ipairs(rows or {}) do
    if row.status ~= "orphan" and row.item and row.source_path
       and row.source_start and row.source_stop then
      out[#out + 1] = {
        uid = row.uid, asset = row.asset, item = row.item,
        take_name = row.take_name, source_path = row.source_path,
        span = { from = math.max(0, row.source_start - T.pad),
                 to = row.source_stop + T.pad },
        mk_pos = row.marker_pos, mk_len = row.marker_len,
        locked = row.user_status == "verified",  -- Lock; the machine may not move it
      }
    end
  end
  table.sort(out, function(a, b)
    if a.source_path ~= b.source_path then return a.source_path < b.source_path end
    return a.span.from < b.span.from
  end)
  return out
end

local function words_within(words, from, to)
  local out = {}
  for _, w in ipairs(words or {}) do
    local mid = ((w.t0 or 0) + (w.t1 or 0)) / 2
    if mid >= from - 1e-6 and mid <= to + 1e-6 then out[#out + 1] = w end
  end
  return out
end

-- The free hunt: no whisper, stored data only. Report-only by contract --
-- the caller decides what to do with the list.
function vo.ScanSuspects(rows, transcripts, lines, cfg, thresh)
  local T = thresh or vo.VERIFY_THRESH
  local by_path = {}
  for _, t in ipairs(transcripts or {}) do by_path[t.path] = t.words end
  local out = {}
  for _, row in ipairs(rows or {}) do
    if row.status ~= "orphan" and row.item and row.source_path
       and row.source_start and row.source_stop then
      local trig = {}
      local words = words_within(by_path[row.source_path],
                                 row.source_start, row.source_stop)
      local span = row.source_stop - row.source_start
      local covered = 0
      for _, w in ipairs(words) do covered = covered + ((w.t1 or 0) - (w.t0 or 0)) end
      if span > 0 and covered / span < T.thin_cover then
        trig.thin = true
      elseif #words > 0 then
        local v = vo.JudgeLine(words, lines, row.asset, cfg, T)
        if v.verdict ~= "match" then trig.name_mismatch = true end
      end
      if not row.marker_id then trig.unmarked = true end
      if row.vetted_state == "mismatch" then trig.stamp = true end
      if next(trig) then out[#out + 1] = { row = row, triggers = trig } end
    end
  end
  return out
end
```

- [ ] **Step 4: Run to verify pass** — `./run_tests.sh`.

- [ ] **Step 5: Commit**

```bash
git add tests/test_vo.lua VO/lib/ajsfx_vo.lua
git commit -m "VO: PlanVerify + ScanSuspects -- the queue and the free hunt"
```

---

### Task 5: Overview — vetted state per row + the fourth checkbox

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`

**Interfaces:**
- Consumes: `vo.ReadVetted`, `vo.VettedFingerprint` (Task 1); row build site (~`:780`–`:1072`) where `row.item`, `row.item_info`, `row.take_name`, `row.source_path` are set; `state.transcripts` (`:694`); marks row (`:8259`–`:8290`, offsets `z.marks + 0/34/68`); `MarkTargets()` (`:8240`); `pending_action` (`:1134`, flushed `:11221`).
- Produces:
  - `local Verify = { queue = {}, active = nil, report = {}, warned_model = false }` — **the one new top-level local**, declared near `local Repair = {}` (`:7275`).
  - `Verify.Enqueue(rows)` — appends `vo.PlanVerify(rows)` entries to `Verify.queue`, de-duplicated by `uid` against queued + active.
  - `row.vetted_state` = `"ok" | "mismatch" | nil` computed at rebuild.
  - The fourth checkbox at `z.marks + 102`.

- [ ] **Step 1: Declare the namespace + enqueue**

Next to `local Repair = {}`:

```lua
-- Verify: the machine listens so you don't have to (SPEC-verify.md).
-- One table, because the file is at the 200-local cap.
local Verify = { queue = {}, active = nil, report = {}, warned_model = false }

function Verify.Enqueue(rows)
  local seen = {}
  for _, e in ipairs(Verify.queue) do seen[e.uid] = true end
  if Verify.active then seen[Verify.active.uid] = true end
  for _, e in ipairs(vo.PlanVerify(rows)) do
    if not seen[e.uid] then
      seen[e.uid] = true
      Verify.queue[#Verify.queue + 1] = e
    end
  end
end
```

- [ ] **Step 2: Compute `row.vetted_state` at rebuild**

At the row-build site, where a row already has `item`, `item_info`, `take_name`, `source_path` (after the block that sets `row.source_start`/`row.source_stop`), using the transcript words already loaded for the row's source (`state.transcripts` lookup — build a `path → words` map once per rebuild, not per row):

```lua
local stamp = row.item and vo.ReadVetted(row.item)
if stamp then
  local ii = row.item_info or {}
  local now = vo.VettedFingerprint{
    source_path = row.source_path, start_offs = ii.start_offs,
    length = ii.length, playrate = ii.playrate,
    take_name = row.take_name, mk_pos = row.marker_pos, mk_len = row.marker_len,
    words = words_by_path[row.source_path],
  }
  row.vetted_state = (stamp == now) and "ok" or "mismatch"
end
```

If `row.marker_pos`/`row.marker_len` do not exist as row fields, populate them where `row.marker_id` is set, from the same marker record. Field names must match what Task 6 writes after a successful verify.

- [ ] **Step 3: Draw the checkbox**

After the Sel checkbox block (`:8290`ff, inside the non-orphan branch), fourth shared offset:

```lua
im.SameLine(ctx)
im.SetCursorScreenPos(ctx, rx + z.marks + 102, ry)
local vet = row.vetted_state == "ok"
local vhit = false
if Verify.active and Verify.active.uid == row.uid then
  im.BeginDisabled(ctx, true)
  im.Checkbox(ctx, "##vetted", false)
  im.EndDisabled(ctx)
  if im.IsItemHovered(ctx) then im.SetTooltip(ctx, "Verifying\u{2026}") end
else
  vhit = im.Checkbox(ctx, "##vetted", vet)
  if im.IsItemHovered(ctx) then
    im.SetTooltip(ctx, vet
      and ("Vetted: audio, transcript and line name agreed when the\n" ..
           "machine last listened. Any edit to the item, marker, name\n" ..
           "or words clears this. Click to re-verify.")
      or  ("Not vetted. Click: the machine re-listens to this take and\n" ..
           "checks the transcript and the line name against the audio."))
  end
end
if vhit then
  local targets = MarkTargets()
  pending_action = function() Verify.Enqueue(targets) end
end
```

The checkbox result (`vhit`) is deliberately not written back — the machine owns the state; a click is a request, not an edit.

- [ ] **Step 4: Syntax + tests**

```bash
luac -p VO/ajsfx_VO_Overview.lua
./run_tests.sh
```

Expected: both clean. If `luac -p` reports the local cap, a stray local crept in — fold it into `Verify`.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: the vetted checkbox -- machine-owned, click means re-check"
```

---

### Task 6: Overview — the Verify queue state machine

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`

**Interfaces:**
- Consumes: `vo.BuildWhisperArgv(cfg, audio, out_prefix, span)` (`:5011`; span → `-ot`/`-d`); `vo.RunWhisperAsync(cfg, argv, scratch, on_done, on_cancel, on_error, opts)` (`:7799`; `on_done(code, log)`); `vo.ParseWhisperJSON` on `out_prefix .. ".json"` (idiom at `:8378`–`:8390`); `vo.CompareWords`, `vo.JudgeLine`, `vo.MergeRepairWords(words, repairs)` (`:3124`, repairs = `{ { span = {from,to}, words }, ... }`); `vo.ReadTranscript`/`vo.WriteTranscript(source_path, words, meta)` (`:8634`); `vo.WriteVetted`, `vo.VettedFingerprint`; `vo.EnsureChildTrack(parent, base.review)` + the restore-missing move idiom (`:6117`–`:6137`); `vo.DTWPresetForModel(cfg.whisper_model)` (`:4992`); `core.Transaction` (idiom at `:1232`); the scratch dir the transcribe path already uses.
- Produces: `Verify.Tick()` (called once per frame in the defer loop, before the `pending_action` flush at `:11221`); `Verify.Cancel()`; `Verify.moves` + `Verify.ApplyMoves()`; per-run `Verify.report` entries `{ uid, asset, verdict, note }`.

- [ ] **Step 1: The state machine**

```lua
-- One whisper at a time; verdicts as each decode lands; project mutations
-- (moves) deferred to queue drain so the run is ONE undo point. Stamps and
-- sidecar merges are written per item: the sidecar is a file (not undoable
-- anyway, same as gap repair), and a stamp on an unmoved item is harmless.
function Verify.Tick()
  if Verify.active or #Verify.queue == 0 then return end
  local entry = table.remove(Verify.queue, 1)
  local cfg = vo.LoadConfig()
  if not Verify.warned_model and not tostring(cfg.whisper_model or ""):lower():find("large%-v3") then
    Verify.warned_model = true
    state.message = "Verify: model is not large-v3 -- verdicts may be weaker."
    state.message_kind = "warn"
  end
  Verify.active = entry
  local out = scratch_prefix("verify")   -- same scratch-dir helper the transcribe path uses
  local argv = vo.BuildWhisperArgv(cfg, entry.source_path, out, entry.span)
  vo.RunWhisperAsync(cfg, argv, scratch_dir(), function(code, log)
    local fresh = nil
    if code == 0 then
      local fh = io.open(out .. ".json", "r")
      if fh then
        local body = fh:read("*a") fh:close()
        local parsed = vo.ParseWhisperJSON(body)
        fresh = parsed and parsed.words
      end
    end
    Verify.Judge(entry, fresh)
    Verify.active = nil
    if #Verify.queue == 0 then Verify.ApplyMoves() end
  end, function()
    Verify.active = nil
    Verify.queue = {}
    Verify.ApplyMoves()   -- act on what finished before the cancel
  end, function(msg)
    Verify.report[#Verify.report + 1] =
      { uid = entry.uid, asset = entry.asset, verdict = "error", note = msg }
    Verify.active = nil
  end, { duration = entry.span.to - entry.span.from })
end
```

`scratch_prefix`/`scratch_dir` above are whatever the existing transcribe path in this file calls its scratch-dir helpers — reuse those names verbatim; do not add new locals for them. Wire `Verify.Tick()` into the defer loop next to the `pending_action` flush (`:11221`).

- [ ] **Step 2: The verdict**

```lua
function Verify.Judge(entry, fresh)
  if not fresh then
    Verify.report[#Verify.report + 1] =
      { uid = entry.uid, asset = entry.asset, verdict = "error", note = "decode failed" }
    return
  end
  local T = vo.VERIFY_THRESH
  local cfg = vo.LoadConfig()
  local tpath = vo.TranscriptPath(entry.source_path)
  local parsed = vo.ReadTranscript(tpath)
  local stored_all = parsed and parsed.words or {}
  local stored = {}
  for _, w in ipairs(stored_all) do
    local mid = ((w.t0 or 0) + (w.t1 or 0)) / 2
    if mid >= entry.span.from and mid <= entry.span.to then stored[#stored + 1] = w end
  end
  local cmp = vo.CompareWords(fresh, stored, T)
  local line = vo.JudgeLine(fresh, state.lines or {}, entry.asset, cfg, T)

  if line.verdict == "match" then
    local words_now = stored_all
    if not cmp.same then
      -- Stale but right line: bring the sidecar up to date, stamp against
      -- the MERGED words. The item does not move -- the delivery was right.
      words_now = vo.MergeRepairWords(stored_all, { { span = entry.span, words = fresh } })
      vo.WriteTranscript(entry.source_path, words_now, parsed and parsed.meta)
    end
    Verify.Stamp(entry, words_now)
    Verify.report[#Verify.report + 1] = { uid = entry.uid, asset = entry.asset,
      verdict = cmp.same and "clear" or "refreshed",
      note = cmp.same and "" or string.format("transcript updated (%.0f%% drift)", cmp.ratio * 100) }
  elseif entry.locked then
    -- Lock outranks the machine: flag, never move.
    Verify.report[#Verify.report + 1] = { uid = entry.uid, asset = entry.asset,
      verdict = "flagged", note = line.verdict == "wrong"
        and ("locked; audio says " .. (line.best and line.best.asset or "?"))
        or  "locked; could not confirm the line" }
  else
    Verify.moves = Verify.moves or {}
    Verify.moves[#Verify.moves + 1] = { entry = entry,
      suggest = line.verdict == "wrong" and line.best or nil }
    Verify.report[#Verify.report + 1] = { uid = entry.uid, asset = entry.asset,
      verdict = line.verdict == "wrong" and "wrong-line" or "unsure",
      note = line.best and ("audio says " .. line.best.asset) or "no convincing line" }
  end
end

function Verify.Stamp(entry, words)
  -- Re-read geometry at stamp time: the user may have edited during decode,
  -- in which case the stamp self-invalidates on the next rebuild -- correct.
  local item, take = entry.item, entry.item and r.GetActiveTake(entry.item)
  if not take then return end
  vo.WriteVetted(entry.item, vo.VettedFingerprint{
    source_path = entry.source_path,
    start_offs = r.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS"),
    length = r.GetMediaItemInfo_Value(item, "D_LENGTH"),
    playrate = r.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE"),
    take_name = select(2, r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)),
    mk_pos = entry.mk_pos, mk_len = entry.mk_len,   -- passed through by vo.PlanVerify from row.marker_pos/len
    words = words,
  })
end
```

- [ ] **Step 3: Apply the moves — one undo point per run**

```lua
function Verify.ApplyMoves()
  local moves = Verify.moves or {}
  Verify.moves = nil
  if #moves == 0 then return end
  core.Transaction("VO Overview: verify", function()
    for _, m in ipairs(moves) do
      local item = m.entry.item
      if item and r.ValidatePtr(item, "MediaItem*") then
        -- Same walk restore_missing uses (:6117): recording track -> its
        -- Review child, created if missing.
        local track = r.GetMediaItem_Track(item)
        local parent = FindRecordingParent(track)   -- the existing helper restore_missing uses; reuse, do not reinvent
        local review = parent and vo.EnsureChildTrack(parent, Dest.names().review)
        if review then r.MoveMediaItemToTrack(item, review) end
        if m.suggest then
          -- Surface through the orphan machinery: the row re-rebuilds as a
          -- flagged/unassigned take; seed its candidate memo so "This is
          -- line..." leads with the machine's suggestion.
          orphan_hits_memo_seed(item, m.suggest)
        end
      end
    end
  end)
  state.dirty = true   -- whatever flag this file uses to force a rebuild; match the existing idiom
end
```

Two names above are deliberate stand-ins for existing code to be found at implementation time, both with a stated fallback: (a) `FindRecordingParent` — restore_missing's parent walk at `:6117`–`:6137`; if it is inline there rather than a named function, extract the walk into `Verify.RecordingParent(track)` (hangs off the table, no new local). (b) `orphan_hits_memo_seed` — the memo at `:4426` is keyed by text; seeding means inserting the suggestion's hit at rank 1 for the moved item's transcript text. If the memo shape makes that awkward, skip seeding and let `FindSpanLines` re-derive — the suggestion also survives in `Verify.report`, which is what the user reads first. Neither fallback changes any interface.

- [ ] **Step 4: The report + cancel button**

Where the transcribe path shows its progress line (status strip), add when `Verify.active or #Verify.queue > 0`: `Verifying <asset> -- k of n` plus a small Cancel button calling the cancel file mechanism `RunWhisperAsync` already honors (same as transcription cancel). After a run, if `#Verify.report > 0`, show a collapsible "Verify report (n)" list — one `im.Text` line per entry, `verdict .. "  " .. asset .. "  " .. note`, with a Clear button that empties `Verify.report`. Reuse the Log tab's list styling; report-only, no buttons per row.

- [ ] **Step 5: Syntax + tests + live smoke**

```bash
luac -p VO/ajsfx_VO_Overview.lua
./run_tests.sh
```

Then live, via the MCP harness (memory: `vo-mcp-test-harness`): build the fixture project, click the vetted checkbox on one row, watch the queue decode, confirm (a) a clean row gets checked, (b) trimming its edge unchecks it on the next rebuild, (c) a deliberately misnamed row lands on Review with a report line.

- [ ] **Step 6: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: the Verify queue -- decode, judge, stamp; moves are one undo"
```

---

### Task 7: Overview — context-menu entry + Suspects panel

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua`

**Interfaces:**
- Consumes: `DrawTakeRowMenu` targets idiom (`:7860`–`:7866`); `PanelButton(key, label, tip)` (`:10203`); Check group (`:10848`, panel row `:10878`, body dispatch `:10937`); `Repair` panel shape (`:7349`); `vo.ScanSuspects`; `Verify.Enqueue`.
- Produces: menu entry "Verify against audio"; `state.suspects`; `Repair.Suspects()`; panel key `"suspects"`.

- [ ] **Step 1: Menu entry**

In `DrawTakeRowMenu`, after the "Find candidates" block (`:7866`ff), same idiom:

```lua
local vlabel = #targets > 1
  and string.format("Verify %d lines against audio", #targets)
  or  "Verify against audio"
if im.MenuItem(ctx, vlabel) then
  pending_action = function() Verify.Enqueue(targets) end
end
if im.IsItemHovered(ctx) then
  im.SetTooltip(ctx, "The machine re-listens: fresh decode of exactly this\n" ..
                     "audio, checked against the transcript and the line name.\n" ..
                     "Stale transcript: fixed. Wrong line: moved to Review.")
end
```

- [ ] **Step 2: The scan, on request**

Like Unheard, scan when the panel opens, not per rebuild (the scan Levenshteins every row). In `PanelButton`'s click path the panel key flips; compute lazily in the drawer:

```lua
function Repair.Suspects()
  if not state.suspects then
    state.suspects = vo.ScanSuspects(state.visible, state.transcripts or {},
                                     state.lines or {}, vo.LoadConfig(), vo.VERIFY_THRESH)
  end
  local list = state.suspects
  if #list == 0 then im.TextDisabled(ctx, "No suspects. The sheet and the audio agree.") return end
  if im.Button(ctx, string.format("Verify %d suspects", #list)) then
    local rows = {}
    for _, s in ipairs(list) do rows[#rows + 1] = s.row end
    pending_action = function() Verify.Enqueue(rows) end
  end
  im.SameLine(ctx)
  im.TextDisabled(ctx, "report only below this line")
  local NAMES = { name_mismatch = "name vs words", thin = "thin coverage",
                  unmarked = "no marker", stamp = "was vetted, changed since" }
  for _, s in ipairs(list) do
    local why = {}
    for k in pairs(s.triggers) do why[#why + 1] = NAMES[k] or k end
    table.sort(why)
    im.Text(ctx, string.format("%-30s %s", s.row.asset or "?", table.concat(why, ", ")))
  end
end
```

Invalidate `state.suspects = nil` wherever the other panel caches are invalidated on rebuild (where `state.unheard`/`state.unidentified` are reset).

- [ ] **Step 3: Panel wiring**

In the Check group (`:10878` pattern):

```lua
local n_sus = state.suspects and tostring(#state.suspects) or "?"
Flow(string.format("Suspects (%s)", n_sus))
PanelButton("suspects", string.format("Suspects (%s)", n_sus),
  "Everything worth verifying, found for free from stored data:\n" ..
  "names that disagree with the words under them, windows whisper\n" ..
  "barely covered, takes no marker claims, and vetted stamps that\n" ..
  "no longer match. One button feeds them all to Verify.")
```

And in the body dispatch (`:10937`): `elseif state.panel == "suspects" then Repair.Suspects()`.

- [ ] **Step 4: Syntax + tests + live smoke**

```bash
luac -p VO/ajsfx_VO_Overview.lua
./run_tests.sh
```

Live: open Suspects on the fixture, confirm the misnamed row lists "name vs words", the trimmed-after-vetting row lists "was vetted, changed since", and the button fills the queue.

- [ ] **Step 5: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua
git commit -m "VO: Suspects panel -- the free hunt, one button to the queue"
```

---

### Task 8: Version, changelog, manual test, release prep

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` (header `@version`, `@changelog`)
- Modify: `VO/MANUAL_TEST.md`
- Modify: `VO/SPEC-verify.md` (status line)

**Interfaces:** none new.

- [ ] **Step 1: Bump the header**

`@version 0.15beta12` (letters = pre-release, opt-in users only; beta11 was taken by the review-fixes commit that preceded this branch). `@changelog`:

```
Verify: right-click lines (or click the new fourth checkbox) and the
machine re-listens -- fresh decode of exactly that audio, checked against
the transcript and the line name. Stale transcripts are fixed in place;
wrong-line takes move to Review with a suggestion. The check survives as
a vetted stamp that clears itself the moment you edit the item, marker,
name or words. New Suspects panel on the Check row hunts all of this for
free from stored data.
```

- [ ] **Step 2: Manual test additions**

Append to `VO/MANUAL_TEST.md` a Verify section: (1) vet a clean row → checkbox ticks; (2) trim its edge → unticks, Suspects lists it under "was vetted, changed since"; (3) rename two takes to each other's lines, Verify both → both to Review, report says which line each actually is; (4) cancel mid-queue → finished verdicts kept, moves applied, no orphaned whisper process; (5) locked misnamed row → flagged in report, not moved; (6) undo after a run → all moves revert in one step.

- [ ] **Step 3: Spec status**

`SPEC-verify.md` header: `**Status:** Implemented · **Date:** ...`.

- [ ] **Step 4: Full gate**

```bash
./run_tests.sh
luac -p VO/ajsfx_VO_Overview.lua
```

Then run the MANUAL_TEST Verify section live. All six must pass before merge.

- [ ] **Step 5: Commit and hand off for merge**

```bash
git add -A
git commit -m "VO 0.15beta12: Verify -- the machine listens so you don't have to"
```

Merge is the release (feature/vo-verify → main, CI rebuilds index). Per house rules: after pushing main, `gh run list --limit 1` must show green, and skim the build log for reapack-index warnings. Run the adversarial-loop review skill before merging (standing user preference for releases).
