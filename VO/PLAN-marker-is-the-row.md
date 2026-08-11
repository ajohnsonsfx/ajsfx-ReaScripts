# A marker is a row — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a take exist in the Overview sheet when, and only when, a take
marker says it does — deleting the span→row path, replacing it with `missing` +
`heard`, and giving unmarked audio its own Check panel.

**Architecture:** One branch is removed from `vo.BuildOverview`'s row-assembly
loop (the `elseif g and #g > 0` span branch), its planned-row tail folded into
the `missing` branch. The `missing` row gains `heard = <span count>`. A new pure
function `vo.UnidentifiedSpans(input)` answers "which recorded audio has no
marker on it", and the Overview window grows a Check panel over it. Test
conversion is sequenced *before* the deletion so every task ends green.

**Tech Stack:** Lua 5.x, ReaImGui, hand-rolled test runner (`tests/test_vo.lua`,
`tests/test_vo_markers.lua`), mock REAPER (`tests/mock_reaper.lua`).

**Source spec:** [SPEC-marker-is-the-row.md](VO/SPEC-marker-is-the-row.md)

## Global Constraints

- `vo.UnidentifiedSpans` is **pure** — no `reaper.*` calls, no file I/O. It lives
  in `VO/lib/ajsfx_vo.lua` immediately after `vo.BuildOverview`.
- Coverage rule, exact: a span is covered when a counting marker on the **same
  `source_path`** overlaps **at least half the span's own length** —
  `overlap >= 0.5 * (span.stop - span.start)`. Not the marker's length.
- Spans of kind `match` and `review` only. Any other kind is ignored entirely.
- Orphan spans (no script line matched) are **excluded** from
  `UnidentifiedSpans` — they belong to the existing orphan queue.
- `vo.OverviewKey`, `vo.PlannedKey`, `index_tracker`, `resolve_tracker` are **not
  deleted** in this change. Only the take-row path stops calling them.
- `take_count` on a `missing` row stays `0`. `heard` is a separate field.
- Marker rows keep keying `tkm|<marker id>`. Never change that key format.
- Every task ends with `lua tests/test_vo.lua` and `lua tests/test_vo_markers.lua`
  both fully green (`0 failed`). Run from the repo root.
- No `@version` bump and no ReaPack release in this plan. Publishing is a
  separate decision after live verification in REAPER.

## Decisions taken (flag to AJ if either is wrong)

**D1 — a marker row is always `recorded`, never `review`.** `marker_row` (line
5215) hardcodes `status = "recorded"`. After this change, `status == "review"` is
unreachable on take rows; it survives only on orphan rows via `make_row`. The
spec's §6 lists *"a review span reads as review, not recorded"* under "give
markers", which cannot work as written. **Taken:** that test moves to the
span-side group instead (Task 3) and asserts `missing` + `heard`, because a
marker means a human identified the take — the low-confidence warning was the
matcher's opinion and it dies with the span row. The score/`in_sequence`
warning still reaches marker rows through `vo.TranscriptForRange`, so the
information is not lost, only its status label.

**D2 — converted tests that assert `transcript` need real spans under their
markers.** `marker_row` gets its text from `vo.TranscriptForRange(spans, ...)`,
which matches on `source_path`. So a converted test must give the marker a
`source_path` equal to the match's `path` and a `start`/`stop` overlapping the
span it wants the words of. Tests that assert only structure (counts, ordering,
keys) can omit `source_path`, as `tests/test_vo_markers.lua` already does.

**D3 — the shared-filename regression the spec does not mention. Read this
one.** `takes_by_asset` is keyed by **asset only** (line 5249:
`local mks = takes_by_asset[line.asset]`). Two script lines named `dup` therefore
each receive **all** of that asset's markers. The span path fixes this today via
`line_idx` (`line_row_of`, lines 5089–5093) — and the comment at 5078–5084 records
that this exact bug once showed "eight takes of *Jump right in!*, three of which
were audibly a different line". Deleting the span path brings it back for any
script that names two lines with one filename.

**Taken:** ship the change with the regression documented and the test asserting
the new behaviour, because the fix belongs to whatever *writes* markers, not to
`BuildOverview` — a marker's name carries an asset and an id, so the marker
itself cannot say which of two same-named lines it belongs to. Fixing it means
extending the marker name format, which is its own spec. **If AJ's current
script has no duplicate filenames, this costs nothing today.** Task 3 step 1
includes a test that pins the behaviour so it cannot regress silently, and
Task 6 step 0 checks the live script for duplicates before anything ships.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `VO/lib/ajsfx_vo.lua` | Pure model layer | Modify `vo.BuildOverview` (5024–5357); add `vo.UnidentifiedSpans` after it |
| `tests/test_vo.lua` | Main suite, 30 `BuildOverview` call sites | Convert ~28; add new cases |
| `tests/test_vo_markers.lua` | Marker suite, 4 call sites | Convert 1 case |
| `VO/ajsfx_VO_Overview.lua` | ReaImGui window | Add `DrawUnidentifiedPanel` + Check button; add `heard` chip to the missing row |

---

### Task 1: Convert the take-behaviour tests to markers

These 8 tests assert how **takes** behave. Today they get takes from spans; after
this task they get them from `takes_by_asset`. They pass **before and after** the
`BuildOverview` change, which is why they go first — a green run here proves the
conversion is faithful while the old path still exists.

**Files:**
- Modify: `tests/test_vo.lua` (the `BuildOverview:` block, from line 5172)

**Interfaces:**
- Consumes: `vo.BuildOverview{ lines, matches, entries, takes_by_asset }`.
  Marker shape: `{ id = <string>, start = <sec>, stop = <sec>, source_path = <string?> }`.
  `asset` on the marker is not read by `marker_row` — the line owns the asset —
  but include it for realism.
- Produces: a `mk(id, start, stop, path)` helper the later tasks reuse.

- [ ] **Step 1: Add the marker helper beside `span`**

In `tests/test_vo.lua`, immediately after the `local function span(...)`
definition (around line 5178):

```lua
-- A counting marker, the shape vo.CountingMarkers emits and BuildOverview
-- consumes. `path` is only needed when the test asserts transcript text:
-- vo.TranscriptForRange matches spans on source_path.
local function mk(id, start, stop, path)
  return { id = id, start = start, stop = stop, source_path = path }
end
```

- [ ] **Step 2: Convert the 8 take-behaviour tests**

Each keeps its existing assertions. Add a `takes_by_asset` entry whose markers
sit over the same time ranges as the spans the test already declares. By name:

1. `multiple takes become sibling rows, numbered chronologically`
2. `with no select recorded, no take is the primary`
3. `an explicit select in the project file names the primary`
4. `two transcripts fold into one list, takes numbered across both`
5. `rows follow script order, not audio order`
6. `a span with no line index still groups by filename`
7. Any remaining test in this block whose subject is take numbering, ordering,
   or primary selection

**Explicitly NOT in this list:** `two script lines sharing a filename keep their
own takes apart` and `a review span reads as review, not recorded`. Both are
span-side subjects — the first tests `line_idx` disambiguation, which markers do
not do (`takes_by_asset` is keyed by asset, so two lines named `dup` would each
show both markers); the second is D1. They are handled in Task 3.

Worked example — `multiple takes become sibling rows, numbered
chronologically`:

```lua
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(1, 2, "match", "a", "first read", 0.9),
      span(5, 6, "match", "a", "second read", 0.9),
    } } },
    takes_by_asset = { a = { mk("m1", 1, 2, "s.wav"), mk("m2", 5, 6, "s.wav") } },
  })
  -- Existing assertions stand: two rows, take_index 1 and 2, chronological.
  -- New: keys are now marker keys.
  assert(rows[1].key == "tkm|m1", "key: " .. tostring(rows[1].key))
```

- [ ] **Step 3: Run both suites**

```bash
lua tests/test_vo.lua
```

Expected: `0 failed`. If a converted test fails, the marker range does not
overlap the span it needs words from — check `source_path` matches the match's
`path` (see D2).

- [ ] **Step 4: Run the marker suite too**

```bash
lua tests/test_vo_markers.lua
```

Expected: `57 passed, 0 failed` — unchanged, this task did not touch it.

- [ ] **Step 5: Commit**

```bash
git add tests/test_vo.lua && git commit -m "VO tests: take-behaviour tests build from markers"
```

---

### Task 2: Triage the overlay/rematch and round-trip tests

The 9 tests in the `BuildOverview: project-file overlay and rematch:` block
(line 5410 onward) and the 4 `ProjectEntriesFromRows / SummarizeOverview` tests
(5511 onward) test entry re-attachment by source time — a thing that only ever
mattered for span rows. Per spec §6 these are decided **per test, not deleted
wholesale**.

**Files:**
- Modify: `tests/test_vo.lua:5410-5580`

**Interfaces:**
- Consumes: `mk()` from Task 1; `index_tracker` / `resolve_tracker` are file-local
  in `ajsfx_vo.lua` and are **not** directly callable from the test file — they
  are exercised only through `vo.BuildOverview`. Do not try to require them.

- [ ] **Step 1: Classify each of the 13 tests**

For each, answer one question: *does the assertion survive if the row's key is
`tkm|<id>` instead of a time-derived `OverviewKey`?*

- **Yes** (the test is about an entry's fields landing on a row: verified flag,
  notes, name override) → give it markers, and change the `entries` key from
  `vo.OverviewKey(path, start, asset)` to `"tkm|<id>"`.
- **No** (the test is specifically about the 40 ms / 2 s time tolerance, i.e. an
  entry stored at 10.00 attaching to a span now at 10.03) → these guard the
  per-asset and planned-key lookups, which survive. Keep the test, keep the
  spans, and change the assertion subject: the row is now `missing`, and the
  entry lands via `index.by_asset[line.asset]` — assert `row.status == "missing"`
  and that `row.notes` / `row.user_status` still carry.

- [ ] **Step 2: Apply the classification**

Named starting points, from the spec:
- `an exact key match carries the verified flag and notes` → markers, `tkm|` key.
- `a name override is carried but never overwrites the matched filename` →
  markers, `tkm|` key.
- Anything asserting a **tolerance in seconds** → keep spans, assert `missing`.

- [ ] **Step 3: Run both suites**

```bash
lua tests/test_vo.lua
```

Expected: `0 failed`. Still passing against the *unchanged* `BuildOverview` —
that is the point of doing this before the deletion.

- [ ] **Step 4: Commit**

```bash
git add tests/test_vo.lua && git commit -m "VO tests: overlay tests key by marker where the key is the subject"
```

---

### Task 3: Delete the span branch, add `heard` (TDD — red first)

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua:5277-5306` (delete), `:5307-5338` (extend)
- Modify: `tests/test_vo.lua`
- Modify: `tests/test_vo_markers.lua:304-317`

**Interfaces:**
- Produces: a `missing` row now carries `heard = <integer>`, the count of `match`
  or `review` spans that grouped to that line. `take_count` stays `0`.

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua`, at the end of the `BuildOverview:` block:

```lua
test("a line with spans but no markers is missing, and says how much it heard", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(1, 2, "match", "a", "alpha", 0.9),
      span(5, 6, "match", "a", "alpha", 0.9),
    } } },
  })
  assert(#rows == 1, "Expected one row, got " .. #rows)
  assert(rows[1].status == "missing", "got " .. tostring(rows[1].status))
  assert(rows[1].heard == 2, "heard: " .. tostring(rows[1].heard))
  assert(rows[1].take_count == 0, "a heard span is not a take")
end)

test("a line with no audio at all is missing with heard 0", function()
  local rows = vo.BuildOverview({ lines = { line("a", "Alpha", nil, 1) } })
  assert(rows[1].status == "missing" and rows[1].heard == 0,
    "heard: " .. tostring(rows[1].heard))
end)

test("a line with markers ignores its spans entirely, even when spans outnumber them", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(1, 2, "match", "a", "one", 0.9),
      span(5, 6, "match", "a", "two", 0.9),
      span(9, 10, "match", "a", "three", 0.9),
    } } },
    takes_by_asset = { a = { mk("m1", 1, 2, "s.wav") } },
  })
  assert(#rows == 1, "Expected one marker row, got " .. #rows)
  assert(rows[1].key == "tkm|m1", "key: " .. tostring(rows[1].key))
  assert(rows[1].take_count == 1, "take_count: " .. tostring(rows[1].take_count))
end)

test("a planned take appears on a line whose only other content is planned", function()
  local rows = vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    entries = { { key = vo.PlannedKey("a", "p1"), asset = "a" } },
  })
  assert(#rows == 2, "Expected missing + planned, got " .. #rows)
  assert(rows[1].status == "missing" and rows[2].status == "planned",
    "got " .. rows[1].status .. "," .. rows[2].status)
end)

test("a heard-but-unmarked line counts as missing, not recorded", function()
  local n = vo.SummarizeOverview(vo.BuildOverview({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(1, 2, "match", "a", "alpha", 0.9) } } },
  }))
  assert(n.missing == 1, "missing: " .. tostring(n.missing))
  assert((n.delivered or 0) == 0, "delivered: " .. tostring(n.delivered))
end)
```

Then convert the remaining span-side tests to the new outcome:
- `two script lines sharing a filename keep their own takes apart` (from Task 1)
  → with no markers, both lines are now `missing` with `heard = 1` each. Assert
  that. Then add the D3 companion, which pins the regression so it cannot come
  back silently:

```lua
test("two lines sharing a filename both show every marker of that name", function()
  -- KNOWN AND ACCEPTED (plan D3). A marker names an asset and an id, so it
  -- cannot say WHICH of two same-named script lines it belongs to. The span
  -- path used to separate them by line_idx; markers have no equivalent. Fixing
  -- it means extending the marker name format, which is its own spec.
  local rows = vo.BuildOverview({
    lines = { line("dup", "Jump right in!", nil, 1),
              line("dup", "The nightmares have been getting stronger...", nil, 2) },
    matches = {},
    takes_by_asset = { dup = { mk("m1", 1, 2), mk("m2", 10, 11) } },
  })
  assert(#rows == 4, "Expected both lines to show both markers, got " .. #rows)
  assert(rows[1].take_count == 2 and rows[3].take_count == 2,
    "each line shows both markers")
end)
```

- `a review span reads as review, not recorded` (see D1) → the line is `missing`
  with `heard = 1`. Assert that.
- `a script with no audio at all is entirely missing` → add `heard == 0` to its
  existing loop.
- `one source's missing line and another's audio coexist in one list` → the
  audio-bearing line needs markers to stay recorded; give it markers.
- The two orphan tests (`audio matching no script line becomes an orphan row,
  listed last`, `audio for a line the filters excluded is an orphan, never
  dropped`) are **unchanged** — orphans do not go through the deleted branch.
  Confirm they still pass rather than editing them.

- [ ] **Step 2: Convert the canary test in the marker suite**

`tests/test_vo_markers.lua:304`, currently `a line with no markers still builds
from the match`. Replace wholesale:

```lua
test("a line with no markers is missing, however much audio matched it", function()
  local rows = vo.BuildOverview({
    lines = MK_LINES,
    matches = { { path = "sess.wav", spans = {
      { kind = "match", asset = "grum_01", start = 90.0, stop = 92.0, line_idx = 1 },
    } } },
    entries = {}, takes_by_asset = {},
  })
  local found
  for _, row in ipairs(rows) do
    if row.asset == "grum_01" then found = row end
  end
  assert(found, "line row missing")
  assert(found.status == "missing", "status: " .. tostring(found.status))
  assert(found.heard == 1, "heard: " .. tostring(found.heard))
  for _, row in ipairs(rows) do
    assert(row.source_start ~= 90.0, "a span row survived")
  end
end)
```

- [ ] **Step 3: Run to verify they fail**

```bash
lua tests/test_vo.lua
```

Expected: FAIL on the new cases — `heard: nil`, and `Expected one row, got 2`
(the span branch is still building rows).

- [ ] **Step 4: Delete the span branch**

In `VO/lib/ajsfx_vo.lua`, in `vo.BuildOverview`'s row loop: delete the entire
`elseif g and #g > 0 then ... ` arm — lines 5277 through 5306, i.e. from
`elseif g and #g > 0 then` up to and including the `end` closing its
`planned_by_row` tail, leaving the `if mks and #mks > 0 then` arm followed
directly by `else`.

The `make_row` local (5157) **stays**: orphan rows at 5345–5351 still call it.
The `groups` build (5144–5155) **stays**: `heard` and Task 4 both need it.

- [ ] **Step 5: Add `heard` to the missing row**

In the `else` arm's row table (the one starting at 5310), beside `take_count = 0`:

```lua
        take_count    = 0,
        -- How many match/review spans this line has in the session, with no
        -- marker on any of them. Zero means nothing was recorded; four means
        -- the audio is sitting there and Identify has not been run on it.
        -- "Missing" must never read as "we looked and there is nothing".
        heard         = g and #g or 0,
```

- [ ] **Step 6: Run to verify they pass**

```bash
lua tests/test_vo.lua
```

Expected: `0 failed`.

- [ ] **Step 7: Run the marker suite**

```bash
lua tests/test_vo_markers.lua
```

Expected: `57 passed, 0 failed`.

- [ ] **Step 8: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua tests/test_vo_markers.lua && git commit -m "VO: a take row exists only where a marker says it does"
```

---

### Task 4: `vo.UnidentifiedSpans`

**Files:**
- Modify: `VO/lib/ajsfx_vo.lua` — insert directly after `vo.BuildOverview`'s
  closing `end` (currently line 5357, before the `ProjectEntriesFromRows` comment)
- Modify: `tests/test_vo.lua` — new `UnidentifiedSpans:` block after the
  `BuildOverview:` block

**Interfaces:**
- Produces: `vo.UnidentifiedSpans(input) -> { { source_path, start, stop, asset,
  deliver, score, transcript }, ... }`, sorted by `source_path` then `start`.
  `input` is the same table `vo.BuildOverview` takes (it reads `lines`,
  `matches`, `takes_by_asset`).

- [ ] **Step 1: Write the failing tests**

Add to `tests/test_vo.lua`:

```lua
print("\nUnidentifiedSpans:")

test("a span no marker touches is returned", function()
  local out = vo.UnidentifiedSpans({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(1, 3, "match", "a", "alpha", 0.9) } } },
    takes_by_asset = {},
  })
  assert(#out == 1, "Expected 1, got " .. #out)
  assert(out[1].source_path == "s.wav" and out[1].start == 1, "wrong span returned")
  assert(out[1].transcript == "alpha" and out[1].score == 0.9, "fields lost")
end)

test("a marker covering more than half the span hides it; less than half does not", function()
  local input = {
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(10, 20, "match", "a", "alpha", 0.9) } } },
  }
  -- 6 of 10 seconds covered: identified.
  input.takes_by_asset = { a = { mk("m1", 10, 16, "s.wav") } }
  assert(#vo.UnidentifiedSpans(input) == 0, "a covered span was reported")
  -- 4 of 10: a marker brushing a neighbour does not own this take.
  input.takes_by_asset = { a = { mk("m1", 10, 14, "s.wav") } }
  assert(#vo.UnidentifiedSpans(input) == 1, "a barely-touched span was hidden")
end)

test("a marker on another source never covers this span", function()
  local out = vo.UnidentifiedSpans({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = { span(10, 20, "match", "a", "alpha", 0.9) } } },
    takes_by_asset = { a = { mk("m1", 10, 20, "other.wav") } },
  })
  assert(#out == 1, "a marker on another file covered this span")
end)

test("orphan spans are the other queue's business", function()
  local out = vo.UnidentifiedSpans({
    lines = { line("a", "Alpha", nil, 1) },
    matches = { { path = "s.wav", spans = {
      span(1, 3, "match", "nosuchline", "who is this", 0.4),
    } } },
    takes_by_asset = {},
  })
  assert(#out == 0, "an orphan leaked into the unidentified list, got " .. #out)
end)

test("results are sorted by source then start", function()
  local out = vo.UnidentifiedSpans({
    lines = { line("a", "Alpha", nil, 1) },
    matches = {
      { path = "z.wav", spans = { span(1, 2, "match", "a", "z one", 0.9) } },
      { path = "a.wav", spans = { span(9, 10, "match", "a", "a two", 0.9),
                                  span(1, 2,  "match", "a", "a one", 0.9) } },
    },
    takes_by_asset = {},
  })
  assert(#out == 3, "count: " .. #out)
  assert(out[1].source_path == "a.wav" and out[1].start == 1, "sort broken at 1")
  assert(out[2].source_path == "a.wav" and out[2].start == 9, "sort broken at 2")
  assert(out[3].source_path == "z.wav", "sort broken at 3")
end)
```

- [ ] **Step 2: Run to verify they fail**

```bash
lua tests/test_vo.lua
```

Expected: FAIL, `attempt to call a nil value (field 'UnidentifiedSpans')`.

- [ ] **Step 3: Implement**

Insert after `vo.BuildOverview`:

```lua
-- Audio the matcher recognised that no marker has claimed.
--
-- Once a marker is the only thing that makes a take, the reads Identify scored
-- too low would simply vanish from the sheet -- exactly the takes most in need
-- of a person. This is where they go: the Check panel's "Not yet identified".
--
-- Covered means a marker on the SAME SOURCE overlaps at least HALF the span.
-- Half, not any: a marker trimmed short still owns its take, and a marker that
-- merely brushes a neighbouring span does not claim it.
--
-- Orphans -- spans matching no script line -- are deliberately absent. "Which
-- line is this?" and "this line's audio is not tracked yet" are two different
-- questions with two different queues.
--
-- Pure: no REAPER calls. Same `input` shape as vo.BuildOverview.
function vo.UnidentifiedSpans(input)
  input = input or {}
  local lines = input.lines or {}

  -- Every counting marker, bucketed by the source it sits in.
  local marks_by_source = {}
  for _, mks in pairs(input.takes_by_asset or {}) do
    for _, mk in ipairs(mks) do
      local p = mk.source_path
      if p and mk.start and mk.stop then
        marks_by_source[p] = marks_by_source[p] or {}
        table.insert(marks_by_source[p], mk)
      end
    end
  end

  -- A span claims a line the same way BuildOverview groups it: its own line
  -- index when that line agrees on the asset, else the first line using it.
  local first_row_using = {}
  for i, l in ipairs(lines) do
    if l.asset and first_row_using[l.asset] == nil then first_row_using[l.asset] = i end
  end

  local out = {}
  for _, sc in ipairs(input.matches or {}) do
    for _, s in ipairs((sc and sc.spans) or {}) do
      local kind_ok = (s.kind == "match" or s.kind == "review")
      local li = s.line_idx
      local line = (li and lines[li] and lines[li].asset == s.asset) and lines[li]
                   or (s.asset and lines[first_row_using[s.asset] or 0]) or nil
      if kind_ok and line and s.start and s.stop and s.stop > s.start then
        local need = (s.stop - s.start) * 0.5
        local covered = false
        for _, mk in ipairs(marks_by_source[sc.path] or {}) do
          local overlap = math.min(mk.stop, s.stop) - math.max(mk.start, s.start)
          if overlap >= need then covered = true break end
        end
        if not covered then
          out[#out + 1] = {
            source_path = sc.path,
            start       = s.start,
            stop        = s.stop,
            asset       = s.asset,
            deliver     = line.deliver or s.deliver or s.asset,
            score       = s.score,
            transcript  = s.transcript,
          }
        end
      end
    end
  end

  table.sort(out, function(a, b)
    if a.source_path ~= b.source_path then
      return tostring(a.source_path) < tostring(b.source_path)
    end
    return (a.start or 0) < (b.start or 0)
  end)
  return out
end
```

- [ ] **Step 4: Run to verify they pass**

```bash
lua tests/test_vo.lua
```

Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add VO/lib/ajsfx_vo.lua tests/test_vo.lua && git commit -m "VO: UnidentifiedSpans -- recognised audio no marker claims"
```

---

### Task 5: The Check panel and the `heard` chip

No unit test — this is ReaImGui draw code, which the suite does not cover.
Verification is live in REAPER.

**Files:**
- Modify: `VO/ajsfx_VO_Overview.lua` — new `DrawUnidentifiedPanel` beside
  `DrawNoAudioPanel` (line 5364); Check group button (near line 7936); panel
  dispatch (line 7950); `heard` chip in the take-row draw (near line 6115)
- Modify: `VO/ajsfx_VO_Overview.lua:702` — stash the input for the panel

**Interfaces:**
- Consumes: `vo.UnidentifiedSpans(input)` from Task 4; `state.overview`,
  `state.lines`, `takes_by_asset` (local at line 687).

- [ ] **Step 1: Stash the panel's input at build time**

`takes_by_asset` is a local inside the rebuild function. The panel needs it, so
capture the whole input rather than recomputing. At line 702, replace the inline
constructor with a named table:

```lua
  local overview_input = {
    lines   = state.lines,
    matches = matches,
    entries = state.entries,
    cfg     = cfg,
    takes_by_asset = takes_by_asset,
    -- LoadMatches is hoisted above the constructor because it is what FILLS
    -- state.transcripts, and the order a table constructor evaluates its
    -- fields in is not something to rely on.
    transcripts = state.transcripts,
  }
  state.overview = vo.BuildOverview(overview_input)
  -- The Check panel asks the same question of the same input: which recognised
  -- audio has no marker on it. Recomputed on rebuild, never cached stale.
  state.unidentified = vo.UnidentifiedSpans(overview_input)
```

- [ ] **Step 2: Add the panel**

After `DrawNoAudioPanel`'s closing `end` (line 5431):

```lua
-- Audio the matcher recognised that no marker claims. The verb that acts on a
-- row here is Identify: these are reads waiting to become takes.
local function DrawUnidentifiedPanel()
  local list = state.unidentified or {}
  if #list == 0 then
    im.TextColored(ctx, 0x66BB66FF,
      "Every read the matcher found has a take marker on it.")
    im.Separator(ctx)
    return
  end

  im.TextColored(ctx, 0xDDAA33FF, string.format(
    "%d read(s) matched a script line but have no take marker:", #list))
  for i, s in ipairs(list) do
    if i > REPAIR_LIST_CAP then
      im.TextDisabled(ctx, string.format("   ...and %d more", #list - REPAIR_LIST_CAP))
      break
    end
    im.Bullet(ctx)
    im.SameLine(ctx)
    im.TextDisabled(ctx, (s.source_path or ""):match("[^/\\]+$") or "(unknown)")
    im.SameLine(ctx)
    if im.SmallButton(ctx, string.format("%s##uid%d", vo.FormatTime(s.start), i)) then
      local at = s.start
      pending_action = function() reaper.SetEditCurPos(at, true, false) end
    end
    if im.IsItemHovered(ctx) then
      im.SetTooltip(ctx, "Move the edit cursor here.")
    end
    im.SameLine(ctx)
    im.TextDisabled(ctx, string.format("%s  %.0f%%  %s",
      s.deliver or s.asset or "(unnamed)", (s.score or 0) * 100,
      s.transcript or ""))
  end
  im.TextDisabled(ctx,
    "These reads scored against a script line but nothing has marked them as\n" ..
    "takes, so no verb will act on them. Run Identify, or mark them by hand.")
  im.Separator(ctx)
end
```

If `vo.FormatTime` does not exist, use `string.format("%d:%05.2f", s.start // 60,
s.start % 60)` inline — check with `grep -n "function vo.FormatTime"
VO/lib/ajsfx_vo.lua` before writing the call.

- [ ] **Step 3: Add the Check button**

After the `noaudio` `PanelButton` block (line 7940), inside the same `Group("Check:")`:

```lua
      local n_uid = #(state.unidentified or {})
      Flow(string.format("Not yet identified (%d)", n_uid))
      PanelButton("unidentified", string.format("Not yet identified (%d)", n_uid),
        "Audio the matcher recognised that no take marker claims. A take\n" ..
        "exists in this sheet only where a marker says it does, so these\n" ..
        "reads are heard but not tracked. (0) means every read is marked.")
```

- [ ] **Step 4: Wire the dispatch**

At line 7950, add to the `elseif` chain:

```lua
    elseif state.panel == "unidentified" then DrawUnidentifiedPanel()
```

- [ ] **Step 5: Add the `heard` chip**

In the take-row draw, in the `else` branch that draws the three checkboxes
(line 6115), a `missing` row has no marks worth ticking. Immediately before
`local function MarkTargets()`, add:

```lua
    -- A missing line that the matcher DID hear says so. Not clickable: the
    -- verb that acts on it is Identify, not a checkbox.
    if row.status == "missing" and (row.heard or 0) > 0 then
      im.SetCursorScreenPos(ctx, rx + z.marks + 102, ry)
      im.TextDisabled(ctx, string.format("heard %dx", row.heard))
      if im.IsItemHovered(ctx) then
        im.SetTooltip(ctx, string.format(
          "%d read(s) matched this line, but none is marked as a take.\n" ..
          "Run Identify, or see Check > Not yet identified.", row.heard))
      end
    end
```

Verify `z.marks + 102` clears the third checkbox: the Sel box is drawn at
`z.marks + 68` (line 6165). If it collides, raise the offset — do not move the
checkboxes.

- [ ] **Step 6: Syntax check both files**

```bash
luac -p VO/ajsfx_VO_Overview.lua VO/lib/ajsfx_vo.lua
```

Expected: no output. If `luac` is unavailable, `lua -e "loadfile('VO/ajsfx_VO_Overview.lua')"`.

- [ ] **Step 7: Run both suites**

```bash
lua tests/test_vo.lua
```

Expected: `0 failed`. (The GUI file is not under test; this guards the library.)

- [ ] **Step 8: Commit**

```bash
git add VO/ajsfx_VO_Overview.lua && git commit -m "VO: Not yet identified panel, and the heard hint on a missing line"
```

---

### Task 6: Live verification in REAPER

The project was untracked to 0 markers on 2026-08-11 precisely to verify this
end to end (spec §7). No code change — this task is evidence.

- [ ] **Step 0: Check the live script for duplicate filenames (D3)**

In the Overview's console, or by eye over the loaded CSV: does any filename name
two different script lines? If yes, D3 is live and those lines will show each
other's takes — stop and tell AJ before going further. If no, D3 costs nothing
and the rest of this task proceeds.

- [ ] **Step 1: Open the VO Overview on the untracked project**

Expected: every line reads `missing`. Lines with audio wear `heard Nx`.
Check > `Not yet identified (N)` shows a non-zero N.

- [ ] **Step 2: Run Identify on one line**

Expected: that line's row becomes a take row keyed `tkm|<id>`; the
`Not yet identified` count drops by the number of reads that line had; the
`heard` chip is gone.

- [ ] **Step 3: Run Untrack on that line**

Expected: the row returns to `missing` with its `heard` count back, and the
`Not yet identified` count returns to its previous value. This is the spec's
"Untrack becomes visible" claim, and it is the one worth watching most closely.

- [ ] **Step 4: Report findings, then decide on release**

Do **not** bump `@version` without AJ saying so. If it ships, the bump and
`@changelog` go in `VO/ajsfx_VO_Overview.lua`'s header and CI publishes on merge
to `main`.

---

## Self-review notes

- **Spec coverage:** §1 → Task 3. §1.1 (keep the helpers) → Global Constraints +
  Task 2. §2 → Task 4. §4 tests 1–8 → Tasks 3 and 4 (test 3 = Task 3 step 1
  case 3; tests 5–7 = Task 4; test 8 = Task 3 case 5). §5.1–5.4 → Tasks 3 and 5.
  §6 → Tasks 1–3. §7 → Task 6.
- **Known deviation from the spec:** §6 says `tests/test_vo_markers.lua` needs no
  change. It does — one of its four cases asserts the deleted path (Task 3 step 2).
- **Known deviation:** §6 lists the review-span test under "give markers"; D1
  explains why it moves to the span side instead.
- **Not in scope:** removing `vo.OverviewKey` / `resolve_tracker` / `index_tracker`
  (spec §1.1 defers it), and the "suggest substitutions" tool (spec §7, a
  separate feature).
