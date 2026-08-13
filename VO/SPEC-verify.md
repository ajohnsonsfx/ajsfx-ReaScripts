# ajsfx VO — Verify: the machine listens so you don't have to

**Status:** Implemented (0.15beta12); manual pass pending · **Date:** 2026-08-13

The most tedious part of VO editing is re-listening. The sheet shows a
transcript and a name, but neither is proof: the transcript may be stale
(audio re-edited since whisper ran), and the name may be wrong (the item is
not the line it claims to be). Today the only way to know is ears.

Verify makes the machine do that listen: re-decode exactly the audio under
an item, fresh, and compare what was actually said against (a) the stored
transcript and (b) the script line the item is named for. The result is a
**stamp** the user can see and cannot fake — and that un-stamps itself the
moment the thing it judged changes.

Three pieces, one engine:

1. **The Vetted stamp** — a fourth, machine-owned checkbox on the take row.
2. **The Verify pass** — right-click selected rows → *Verify against audio*
   (or click the checkbox itself). Fresh whisper on each item's span,
   verdict, action.
3. **The Hunt** — a fifth Check panel, *Suspects*: a free scan (no whisper)
   that lists every take worth verifying, with one button to feed them all
   into the Verify queue.

---

## 1. The Vetted stamp

### Naming

`user_status == "verified"` is **already taken** — it is how Lock is stored
(`ajsfx_VO_Overview.lua:8260`). The new state is called **vetted**
everywhere in code: `row.vetted`, `vo.VettedFingerprint`, `P_EXT` key
below. UI copy may say "verified by the machine"; identifiers may not.

### Storage

`GetSetMediaItemInfo_String(item, "P_EXT:ajsfx_vo_vetted", value, true)`.
Project-persisted, invisible in the arrange view, travels with the item,
dies with the item. No ExtState, no sidecar field, no take-marker
convention (the marker asset names the line and nothing else — standing
rule).

The value is a **fingerprint** of exactly what the machine judged:

```
v1|<source_path>|<startoffs>|<length>|<playrate>|<take_name>|<mk_pos>|<mk_len>|<words_hash>
```

- `source_path` — the take's source file (case-folded, slash-normalised).
- `startoffs`, `length`, `playrate` — the item's source-coverage window,
  each printed `%.4f` so float formatting can't cause phantom mismatches.
- `take_name` — the assignment that was verified, verbatim.
- `mk_pos`, `mk_len` — the owning take marker's position and range length,
  `%.4f`; both `-` when the item has no marker.
- `words_hash` — a hash (simple djb2 over the concatenated word texts +
  quantised times is enough) of the **stored sidecar words inside the
  span**. Not the whole sidecar: a gap-repair merge elsewhere in the file
  must not invalidate this item.

### Display is computed, never trusted

The checkbox is checked iff the stamp exists **and** a freshly recomputed
fingerprint equals it, string-for-string. There is no invalidation pass and
no cleanup hook:

- trim an edge → `startoffs`/`length` change → unchecked
- move or resize the take marker → unchecked
- rename the take (reassign the line) → unchecked
- change the words under it (re-transcribe, merge) → unchecked
- split the item → both halves inherit the chunk's stamp, both mismatch
  their own new geometry → both unchecked, no special case

A mismatched stamp is left in place until the next successful Verify
overwrites it. Nothing reads a stale stamp — the comparison IS the read —
so leaving it costs nothing and avoids write-traffic on every rebuild.

This is why the stamp does not violate the no-cache rule
(`vo-name-is-the-assignment`): it stores no mapping and no judgment that
can drift. It stores "the machine checked *this exact state*"; any drift
falsifies the equality and the display degrades to the truthful answer,
"not vetted".

### The checkbox

Fourth box on the marks row, after Lock/Keep/Sel (next shared offset,
`z.marks + 102`). Machine-owned:

- The user cannot set or clear it by clicking.
- Clicking it — checked or not — **enqueues that row for Verify**. On a
  checked row that is a deliberate re-verify.
- While the row is queued/decoding, the box renders disabled with a
  tooltip showing queue position or decode progress.
- Multi-select works like the other marks: clicking the box of a selected
  row targets all selected non-orphan rows (`MarkTargets` pattern,
  `ajsfx_VO_Overview.lua:8240`).

Tooltip (unchecked): "Not vetted. Click: the machine re-listens to this
take and checks the transcript and the line name against the audio."
Tooltip (checked): "Vetted: audio, transcript and line name agreed when
the machine last listened. Any edit to the item, marker, name or words
clears this."

---

## 2. The Verify pass

### Entry points

- Row context menu: **"Verify against audio"** / **"Verify N lines against
  audio"** — same selection rule as every other verb (`targets` from
  `DrawTakeRowMenu`, `ajsfx_VO_Overview.lua:7862`).
- The Vetted checkbox (single row or selection, above).
- The Suspects panel's **"Verify N suspects"** button (§3).

All three converge on one queue.

### The queue

Sequential, one whisper process at a time, reusing the async machinery
that already exists:

- Span decode: `vo.BuildWhisperArgv(cfg, audio, out_prefix, span)` already
  takes `span = {from, to}` (`lib/ajsfx_vo.lua:5011`) — the mechanism gap
  repair uses. The span is the item's **source-coverage window** (never
  sheet rows — standing rule), padded ±0.25 s for edge words.
- Launch/progress: `vo.RunWhisperAsync` + `vo.LatestWhisperProgress`,
  unchanged.
- Model: the transcription model from Settings, but Verify **warns once
  per queue** if it is not `large-v3`, and always passes `-nfa` (flash
  attention silently kills DTW word anchors — standing rule). Verdicts
  from a lesser model are still allowed; the warning exists because
  transcript quality dominates matching quality.
- Cancellable between items; cancelling mid-decode kills the process and
  leaves the current row un-stamped. Queue survives nothing: it is
  session state, rebuilt from user action only.
- Rough cost is decode-speed-bound; the UI shows per-item progress and
  "k of n" so the user can walk away.

### The two comparisons

For each item, with fresh words `F`, stored sidecar words under the span
`S`, and the script line text `L` for the item's take name:

1. **Staleness** — `F` vs `S`, word-level. Normalised (case-folded,
   punctuation-stripped) token comparison; a small edit distance
   tolerance absorbs whisper's run-to-run jitter (thresholds live in one
   table, `vo.VERIFY_THRESH`, so tuning is one edit).
2. **Line identity** — `F` vs `L`, scored by the **same scorer the orphan
   candidate menu uses** (`OrphanLineHits` scoring path). Two thresholds
   partition the score into match / uncertain / non-match. Additionally,
   `F` is scored against all *other* script lines: a non-match only
   becomes "wrong line" (with a suggestion) when some other line clearly
   wins; otherwise it is "can't tell".

### Verdicts and actions

| Verdict | Condition | Action |
| --- | --- | --- |
| **Clear** | `F`≈`S`, `F` matches `L` | Write stamp. Nothing else. |
| **Stale, right line** | `F`≉`S`, `F` matches `L` | Merge `F` into the sidecar for the span (`vo.MergeRepairWords` path, same as gap repair), then stamp **against the merged words**. Item does not move — the delivery was right, only the metadata was behind. |
| **Wrong line** | `F` matches some other line clearly better than `L` | Move item to its recording's **Review** track. Attach the winning line as a suggestion surfaced through the existing orphan "This is line…" menu. **No auto-rename**: the name is a fact the user states; the machine only guesses. No stamp. |
| **Can't tell** | `F` matches nothing convincingly | Move to Review, flagged, no suggestion, no stamp. |

Item moves are wrapped in `core.Transaction("VO: Verify")` — one undo
point per queue run, not per item. Sidecar merges are file writes and sit
outside the transaction (they are not undoable; the spec accepts this, as
gap repair already does).

Results land in a per-run report (reuse the Log tab's list style): one
line per item, verdict + what changed, so a 40-line batch is auditable
after the fact.

### Interaction with Lock

Lock means "rematching will not move it". Verify's wrong-line action *is*
a move, so: a **locked** item that fails verification is **not moved** —
it is flagged in the report and painted, and the row's disagreement is
left for the user. Lock outranks the machine, by design.

---

## 3. The Hunt: the Suspects panel

Fifth panel on the Check row, after Marks vs tracks / Takes without audio
/ Not yet identified / Unheard audio. Same contract as the other four:
**report-only** — nothing in the panel body changes the project.

The scan is free (no whisper, stored data only) and lists every delivered
item that trips any of:

1. **Name vs stored words** — the stored transcript words under the
   item's window score poorly against the item's named line (same scorer
   and thresholds as §2, run against `S` instead of `F`).
2. **Empty or thin coverage** — the window contains no stored words, or
   words covering well under the window's span (audio whisper never saw,
   or edges moved into un-transcribed territory).
3. **Never identified** — no take marker claims the item (overlaps
   `Repair.Unidentified`, but scoped to delivered items; the panel
   de-duplicates against that panel's list).
4. **Stamp mismatch** — a Vetted stamp exists but no longer matches its
   fingerprint: *was* checked, something moved since. This catches the
   "edges changed since I last verified" case at zero cost.

Each suspect row shows which trigger(s) fired. The panel's one action
button — **"Verify N suspects"** — feeds the list into the §2 queue.
That button is the bridge from report to action, and it lives in the
panel header, not the body, keeping the "Check ends here" rule intact.

---

## 4. Architecture

**Pure logic in `VO/lib/ajsfx_vo.lua`** (all unit-testable against the
mock, no ImGui, no live REAPER beyond what the mock provides):

- `vo.VettedFingerprint(item_info, words)` → string — build §1's value.
- `vo.ReadVetted(item)` / `vo.WriteVetted(item, fp)` — P_EXT accessors.
- `vo.CompareWords(fresh, stored, thresh)` → same/stale + detail.
- `vo.JudgeLine(fresh_words, lines, named_asset, thresh)` → verdict
  (`clear` / `stale` is not its concern; it returns `match` /
  `wrong:<asset>` / `unsure` + scores).
- `vo.PlanVerify(rows)` → ordered queue items (span, source, take ref).
- `vo.ScanSuspects(rows, transcripts, lines, opts)` → suspect list with
  trigger flags.
- `vo.VERIFY_THRESH` — every tunable in one table.

**Driver in `ajsfx_VO_Overview.lua`**: queue state machine (idle →
decoding → judging → acting), checkbox, menu entry, Suspects panel,
report. The file is at Lua's 200-local cap — **no new top-level
`local function`**. All new code hangs off one new table (`local Verify =
{}` costs a single local) or existing tables.

**Tests in `tests/test_vo.lua`**: fingerprint round-trip and each
invalidation trigger; word comparison tolerance edges; verdict table
(all four outcomes); suspect scan triggers; lock-outranks-move. Whisper
is mocked as canned word lists — the queue's async half is exercised by
the existing MCP live-harness instead (`vo-mcp-test-harness`).

---

## 5. Explicitly excluded

- **No persisted judgment without a fingerprint.** No "verified at
  <date>" timestamps, no verdict cache.
- **No auto-rename.** The machine never rewrites a take name, even at
  100% confidence.
- **No ear-check queue.** Machine-only this round; the open ear-check
  idea (`vo-next-session`) stays open and would layer on top of the same
  queue if built.
- **No parallel decodes.** One whisper at a time.
- **No CSV/sheet mutation.** Verify touches items, sidecars and P_EXT
  only.
