# VO ScriptMatch — Manual Test Procedure

Everything in `VO/lib/ajsfx_vo.lua`'s pure layer is covered by `tests/test_vo.lua`
(run `./run_tests.sh` for the current count — all passing). This document covers what those
tests **cannot** reach: REAPER itself, real audio, and the actual whisper-cli
binary. Nothing below has been executed yet — see [SPEC.md §10](SPEC.md#10-explicitly-unverified).

Work through it in order. Later sections assume earlier ones passed.

---

## 0. Prerequisites

| Need | How |
|---|---|
| ReaImGui | ReaPack → Browse packages → ReaImGui |
| `whisper-cli` | Build or download [whisper.cpp](https://github.com/ggml-org/whisper.cpp) |
| A ggml model | `ggml-base.bin` is a good start; **never committed to this repo** |

Open **ajsfx VO Settings**, set the whisper-cli path and the model path, and
confirm the panel shows **Backend ready** in green. Press **Save**.

---

## 1. The single highest-value check: does the CSV look like we think?

Everything downstream depends on `whisper-cli -ml 1 -sow -ocsv` writing
`start,end,text` with times in **milliseconds**. This was read from upstream
source, never observed.

Run it by hand on any speech file:

```
whisper-cli -m <model> -f <audio.wav> -of /tmp/probe -ocsv -ml 1 -sow -np
```

Open `/tmp/probe.csv` and confirm:

- [ ] A header row `start,end,text` is present.
- [ ] Each row holds **one word**, not a sentence.
- [ ] Times are **milliseconds** (a word ~2s in should read ~2000, not ~2).
- [ ] Text is quoted, and any literal `"` is doubled.

**If any of these differ, stop.** `vo.ParseWhisperCSV` needs adjusting first, and
its unit tests are the place to encode whatever the real format turns out to be.

Also confirm the DTW flag: rerun with `-dtw base` (matching your model). If
whisper-cli rejects the preset name, `vo.DTW_PRESETS` needs correcting. If it
accepts `base.en` for an `.en` model, that preset can be added — the table is
deliberately conservative today.

---

## 2. Sample dataset

Use `tests/fixtures/vo_sample_script.csv`. It has exactly the three columns the
tool now maps — **Character, Filename, Line Text** — and is deliberately awkward:
two characters, a `TO RECORD` row that must be ignored, quoted commas, an
apostrophe, and a numeral.

The **Ref** column below is *not* in the CSV; it is only a shorthand the steps in
later sections use to name a line. In the tool itself a line is identified by its
**Filename** (which is also what the cut clip is named).

| Ref | Character | Filename | Line Text |
|---|---|---|---|
| NPC_001 | Guard | vo_guard_halt_01 | Halt! Who goes there? |
| NPC_002 | Guard | vo_guard_gate_01 | Open the north gate, quickly. |
| NPC_003 | Guard | vo_guard_bark_01 | Intruder in the courtyard! |
| NPC_004 | Guard | **TO RECORD** | You'll need 3 keys for that door. |
| PLR_001 | Hero | vo_hero_captain_01 | I have business with the captain. |
| PLR_002 | Hero | vo_hero_aside_01 | Stand aside, or I'll move you myself. |

### Record the session

On **one track**, in **one pass**, record yourself reading — deliberately messily:

1. Say "**take one**" as a slate, pause.
2. Read **PLR_002** (out of order on purpose).
3. Pause, say "**sorry, again**" (chatter).
4. Read **NPC_003**.
5. Read **NPC_001**.
6. Read **NPC_001 again** (a second take — this is the repeated line).
7. Read **PLR_001**.
8. Read **NPC_002**.
9. Do **not** read NPC_004. It is `TO RECORD`.

Leave ~1s of silence between takes. Speak normally; do not over-enunciate.

---

## 3. First run — defaults

Run **ajsfx VO ScriptMatch** with nothing selected, then select the recorded item.

- [ ] With nothing selected, the dialog shows `Select the recorded session item(s)
      on a track.` and **Transcribe** is disabled — no popup, no separate step to
      reopen the script.
- [ ] Select the recorded item. The table becomes active immediately, without
      reopening the script.
- [ ] Browse to the sample CSV. Leave the filters blank and all three toggles at
      their defaults (Alts off, suffix off, last take is primary).
- [ ] Press **Transcribe**. The dialog stays open and shows an inline progress
      line while it runs; both **Transcribe** and **Cut and name** are disabled
      for the duration.
- [ ] **The project does not change while it runs — Transcribe only reads the
      audio and builds a plan.**
- [ ] When it finishes, **Transcribe** relabels to **Re-transcribe** and the
      table populates with the plan's results.
- [ ] Press **Cut and name** to apply the plan to the project.

### Expected result

| Track | Contains |
|---|---|
| Selects | `vo_guard_halt_01` ×2, `vo_guard_gate_01`, `vo_guard_bark_01`, `vo_hero_captain_01`, `vo_hero_aside_01` |
| Alts | *(not created — the toggle is off)* |
| Review | `UNMATCHED_take_one`, `UNMATCHED_sorry_again`, plus anything low-confidence |

- [ ] Both takes of NPC_001 are present and **named identically**.
- [ ] The slate and the chatter are on **Review**, not Selects.
- [ ] Nothing is named for NPC_004.
- [ ] Non-speech silence remains on the original track.
- [ ] A `*_vo_report.csv` sits next to the recorded audio source file — written
      when **Transcribe** ran, not only after Cut.

### Check the report

- [ ] One row per clip, with score, margin, take_index and destination.
- [ ] Its trailing **SCRIPT LINES WITH NO MATCH** section lists **NPC_004** and
      nothing that actually got cut.
- [ ] Opening it in a spreadsheet does not mangle the dialogue text.

### Check undo

- [ ] **A single Ctrl+Z** returns the project to exactly its pre-run state:
      one item, one track, no new tracks, no regions.

This is the most important check on the page. If undo takes more than one press,
something is escaping `core.Transaction`.

---

## 4. The eight toggle combinations

Undo between each. Only NPC_001 has two takes, so it is the only line that moves.

| # | Alts | Suffix | Primary | Expected for NPC_001 |
|---|---|---|---|---|
| 1 | off | off | last | Both on Selects, both `vo_guard_halt_01` |
| 2 | off | off | first | Both on Selects, both `vo_guard_halt_01` |
| 3 | off | on | last | Selects: `vo_guard_halt_01_tk01` (1st read) + `vo_guard_halt_01` (2nd) |
| 4 | off | on | first | Selects: `vo_guard_halt_01` (1st) + `vo_guard_halt_01_tk02` (2nd) |
| 5 | on | off | last | Alts: 1st read · Selects: 2nd read, both bare |
| 6 | on | off | first | Selects: 1st read · Alts: 2nd read, both bare |
| 7 | on | on | last | Alts: `..._tk01` (1st) · Selects: `vo_guard_halt_01` (2nd) |
| 8 | on | on | first | Selects: `vo_guard_halt_01` (1st) · Alts: `..._tk02` (2nd) |

- [ ] All eight match. Single-take lines stay on Selects with bare names in every
      combination.

These same eight cases are asserted headlessly in `tests/test_vo.lua`; this
confirms the REAPER-side routing agrees with the plan the tests verify.

---

## 5. Filters

Filtering is now the **Character multi-select** in ScriptMatch (see §13.5 for the
full walkthrough); there is no free-text Speaker/Type filter any more.

- [ ] Uncheck every character except `Guard` → only the three Guard lines are cut.
      The Hero reads land on Review as unmatched, because they are no longer in the
      filtered script.
- [ ] Uncheck **all** characters → "No characters selected", and **nothing is
      changed**.

---

## 6. Regions and delivery

Enable **Create regions over Selects clips** in Settings, then run again.

- [ ] A named region sits over each Selects clip.
- [ ] Region names match the take names.
- [ ] View → Region Render Matrix, tick the track, render.
- [ ] Files come out named per region.
- [ ] **Unverified expectation:** two identically-named regions (the two NPC_001
      takes with suffixing off) produce `-01` / `-02` suffixed files. Record what
      actually happens — SPEC.md §10 flags this as a guess.

---

## 7. Failure handling

Each of these must show a clear inline message (no popup) and change **nothing**:

- [ ] Open the script with no items selected → `Select the recorded session
      item(s) on a track.`, **Transcribe** disabled.
- [ ] Point Settings at a nonexistent whisper-cli → message names the missing path
      and points at Settings.
- [ ] Point Settings at a nonexistent model → same.
- [ ] Point the run dialog at a CSV missing the Filename column → the message
      lists the headers actually found.
- [ ] Point it at a file that is not a CSV at all.
- [ ] Press **Cancel** mid-transcription → inline status reads "Cancelled.
      Nothing in the project was changed.", and the project is untouched.
- [ ] Select a **MIDI** item alongside the audio → it is skipped and named
      inline; the audio still processes.
- [ ] Set an item's playrate to 0.5 → skipped with the playrate named. (The
      time-mapping math handles playrate and is unit-tested; v1 refuses it until
      this test confirms REAPER agrees.)

---

## 8. The cache

- [ ] Transcribe once, then reopen the dialog on the same item(s) → the sidecar
      restores the result instantly, with no whisper run and no progress line.
- [ ] Change **Accept threshold** in Settings and reopen → still instant. This
      is the point of the cache: threshold tuning must be cheap.
- [ ] Tick **Always re-transcribe** and press Transcribe → it transcribes again
      even though a fresh sidecar exists.
- [ ] Change the model and press Transcribe → it transcribes again without being
      asked to.
- [ ] With multiple items selected and only some sidecars stale, press
      **Transcribe** → only the stale/missing sources cost whisper time; sources
      with a fresh sidecar are skipped.

---

## 9. Scale check

Once the above passes, try a real session: a full script and 10+ minutes of audio.

- [ ] Transcription completes within the timeout (raise it in Settings if not).
- [ ] **The whole item is cut, end to end** — clips appear all the way to the last
      line, not just the first stretch. (Regression guard: a zero-length span used to
      make `ApplyPlan` sweep the entire remaining tail onto one track and orphan
      everything after it, so a 24-min take only produced clips for its first ~9 min.
      A degenerate span is now skipped and listed under **Problems** in the summary.)
- [ ] Matching itself is not perceptibly slow after transcription finishes.
- [ ] Spot-check ten clips against the report — do the boundaries sound right, or
      are words clipped at the head?
- [ ] If heads are clipped, raise **Pre-roll**; the padding logic clamps to the
      midpoint between neighbours, so raising it is safe.

---

## 10. Backend & model download (Settings)

Open **ajsfx VO Settings → Speech backend → Download backend & models**.

- [ ] **GPU binary:** with CUDA 12.4 selected, press **Get**. A progress window
      shows downloaded/total and a working **Cancel**.
- [ ] On completion the whisper-cli path field fills in automatically, pointing
      at the extracted `whisper-cli.exe` (under `Resources/whisper-bin/<build>/`).
      Confirm the file exists there.
- [ ] While the binary downloads, its button reads **Downloading…** and is greyed;
      when done, the build shows **[installed]** in the dropdown and the button
      pair becomes **Use downloaded** + **Repair**.
- [ ] **Repair:** press **Repair** on the installed build → it re-downloads and
      re-extracts that build (use this if the folder is corrupted or missing DLLs).
- [ ] **Model:** pick `base`, press **Get**. While downloading, the button reads
      **Downloading…** (it must NOT flip to "Use downloaded" until the download
      actually completes). After it completes the model path fills in and the
      model shows **[installed]**, with **Use downloaded** + **Repair** buttons.
- [ ] **Backend ready** turns green once both are set.
- [ ] No `EndDisabled()` / ImGui stack error appears in the console when clicking
      any Get / Use downloaded / Repair button.

## 11. GPU device check

- [ ] Press **Check device**. Expected: `Device: CUDA — <your GPU>`.
- [ ] If it reads `CPU only` despite the CUDA build, your NVIDIA driver or GPU
      may be too old for the 12.4 runtime — note it in SPEC §9 and try the
      CUDA 11.8 build.

## 12. Download failure handling

- [ ] Press **Cancel** mid-download → "Download cancelled. Nothing was changed",
      and no partial file remains in `whisper-bin/` or `whisper-models/`.
- [ ] Temporarily rename `curl` off PATH (or test on pre-1803 Windows) → a clear
      message, and the browser-download fallback still works.
- [ ] Confirm Cancel cleans up after itself: cancel mid-download and check
      `whisper-bin/`/`whisper-models/` afterward — no partial file remains. Note:
      `ModelIsInstalled` is existence-only, so a partial left by a hard
      interruption (e.g. force-quitting REAPER, not the Cancel button) will read
      as installed and must be deleted manually before re-downloading.

---

## 13. CSV layout, presets & character routing (ScriptMatch)

Covers the CSV column-mapping/preset/filter rework described in
[SPEC-csv-layout-filtering.md](SPEC-csv-layout-filtering.md). The pure logic
(`DistinctCharacters`, `AutoDetectMapping`, serialize/deserialize, `CharacterTrackName`,
the `BuildScriptLines` include-set) is unit-tested in `tests/test_vo.lua`; this section is
the REAPER-side, dialog-and-routing half.

Use `tests/fixtures/vo_sample_script.csv` (§2) for a Character-bearing CSV, and make (or
reuse) a copy with the `Character` column removed/renamed for the no-character-column cases.

There are exactly **three** role dropdowns now — **Character** (optional), **Filename**
(required), **Line Text** (required). There is no LineID or Type field: the **Filename**
is the line's identity (repeated takes of the same line share it).

### 13.1 Header-driven dropdowns

- [ ] Browse to the sample CSV. Each role combo (**Character**, **Filename**,
      **Line Text**) lists the CSV's actual header column names, not hand-typed text.
- [ ] On first load with no remembered layout, the roles are **auto-detected** correctly
      from the sample header (Character → `Character`, Filename → `Filename`,
      Line Text → `Line Text`, all pre-selected).
- [ ] Only **Character** offers a `(none)` entry (it is optional); **Filename** and
      **Line Text** are required and have no `(none)`.
- [ ] Pick `(none)` for **Character** → the **Character filter** section disappears, and
      the dropdown editing marks the Preset combo `(unsaved)`.

### 13.2 Missing required role disables the run

- [ ] Load a CSV whose header lacks a Filename column (rename it in a scratch copy).
      Auto-detect leaves **Filename** unmapped.
- [ ] **Transcribe and cut** is disabled (greyed) and the message reads
      `Map the required column: Filename`.
- [ ] Map any column to it → the button enables and the message clears.

### 13.3 Layout presets — Save / Save As / Load / Delete

- [ ] With the sample CSV mapped, press **Save**. Since no preset is selected yet, a
      REAPER text-input dialog asks for a name — enter `TestGame` and confirm.
- [ ] The **Preset** dropdown now shows `TestGame` selected (not `(unsaved)`).
- [ ] Change the **Character** mapping to `(none)` → the dropdown reverts to `(unsaved)`
      (layout is dirty).
- [ ] Press **Save** again (layout dirty, name still `TestGame` conceptually unset) →
      prompts for a name; **Save As...** always prompts, pre-filled with the current name.
      Save As under the same name `TestGame` → confirmation dialog
      **"A layout preset named 'TestGame' already exists. Overwrite it?"** appears; confirm.
- [ ] Restart the dialog (close and reopen ScriptMatch, or switch the CSV path away and
      back). Select `TestGame` from the **Preset** dropdown → the saved mapping
      (Character = none) is restored.
- [ ] Press **Delete** with `TestGame` selected → confirmation prompt, then the dropdown
      falls back to `(unsaved)` and the mapping stays as it was (not cleared).
- [ ] With no preset selected (`(unsaved)`), **Delete** is disabled (greyed).

### 13.4 Per-`.rpp` restore, including a column that vanished

- [ ] With a layout mapped (no saved preset — `(unsaved)`), close ScriptMatch, save the
      `.rpp`, close and reopen the project, and reopen ScriptMatch. The **CSV path** and
      the **mapping** are restored automatically (the inline per-project layout, §5.3).
- [ ] Now point the CSV path at a copy of the sample with the `Character` column removed
      entirely. The dialog reloads the header: **Character** falls back to `(none)` (its
      remembered column no longer exists), while **Filename** and **Line Text**
      — still present in the new header — keep their prior mappings.
- [ ] Repeat with a named preset selected instead of inline: save `.rpp`, reopen, confirm
      the preset name is still selected and its mapping (re-intersected against whatever
      header is currently loaded) is applied.

### 13.5 Character multi-select narrows the run

- [ ] With Character mapped to the `Character` column on the sample CSV, the
      **Character filter** section lists `Guard` and `Hero`, both checked.
- [ ] Uncheck **Hero**, run. Only the Guard lines (NPC_001/002/003) are cut; the Hero
      reads land on Review as unmatched (same as the free-text filter's old behavior,
      §5).
- [ ] Uncheck **both** Guard and Hero → **Transcribe and cut** proceeds only as far as
      showing **"No characters selected."** in the message area; nothing runs.

### 13.6 Default (nothing excluded) still processes blank-character rows

This is the item verified as part of Task 6's review fix — confirm it directly:

- [ ] Add one row to a scratch copy of the sample CSV with a **blank Character cell**
      (blank Character, some Filename/Line Text, and record that line in the session
      audio too).
- [ ] Map Character to the `Character` column. Leave **every character checked** (the
      default — nothing excluded).
- [ ] Run. The blank-Character row is **still processed**: it is matched/cut like any
      other line, and it lands on a **plain** track (`Selects`/`Alts`/`Review`, not a
      `<Character>_...` track), because a row with no character never gets a per-character
      destination.
- [ ] Now uncheck any one real character (e.g. Hero) and run again. The blank-Character
      row is **dropped** this time — once the filter is actually active (something
      excluded), a row with no character key fails the include-set test. This confirms the
      filter is inert until the user excludes at least one character, and only then treats
      a blank cell as "not in the include-set."

### 13.7 Per-character track routing

- [ ] With Character mapped and both Guard and Hero checked, run the full sample. Confirm
      tracks named exactly `Guard_Selects` and `Hero_Selects` are created (not a shared
      `Selects`), each holding only that character's matched clips.
- [ ] If a low-confidence Guard line lands on Review, confirm the track is
      `Guard_Review`, not plain `Review`.
- [ ] A character with **no clips routed to Alts** this run → no `<Character>_Alts` track
      is created at all (tracks are created lazily, only when actually populated).

### 13.8 No character column → plain tracks

- [ ] Load a CSV with no Character-like column at all (or map Character to `(none)`).
      The **Character filter** section is hidden entirely.
- [ ] Run. All matched clips land on the plain `Selects`/`Alts`/`Review` tracks (today's
      pre-feature behavior) — no per-character tracks appear anywhere.

### 13.9 Unmatched slate → plain Review

- [ ] Even with Character mapped and routing active, an unmatched span (the slate /
      chatter, which never had a script line and therefore never had a character) still
      lands on plain `Review`, not `<something>_Review`. Confirm this in both the §13.6
      and §13.7 runs above — no `UNMATCHED_...` clip ever appears on a per-character track.

### Known minor (not a bug to chase)

- A **comma** typed into a preset name via **Save**/**Save As...** is truncated by
  REAPER's `GetUserInputs` (it treats commas as its own field separator). Use a preset
  name without commas; `ValidatePresetName` does not special-case this because the
  dialog itself never delivers the comma to Lua.

---

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

---

## VO Overview

Needs a project with **two** recordings that already have sidecars (finish the
section above first), a script CSV covering both, and at least one script line
that was never recorded.

### Reading the session

1. Open **ajsfx VO Overview**. One table lists both recordings' spans plus every
   script line, regardless of what is selected in the arrange view.
2. A line the script has but neither recording matched shows **Missing**.
3. Audio that matched no script line shows **Orphan**, listed after everything else.
4. The summary line counts *lines*, not takes: five takes of one line still reads
   as one line delivered.
5. Set the status filter to **Missing**. Only missing lines remain; the summary
   does not change.
6. Type part of a line's text into the search box. Rows filter as you type.

### Navigating

7. Click a row from the first recording. The edit cursor moves to it and the item
   is selected. Click one from the second recording — same, on the other item.
8. Click a Missing row. Nothing moves, the row is dimmed, and hovering explains why.
9. A line with several takes shows sibling rows numbered `1/3`, `2/3`, `3/3`, with
   the last carrying the Sel radio. Click Sel on take 1 — it moves, and take 3
   clears.

### Marking work

10. Tick **OK** on a few rows. Select a row and press `Space` — it toggles.
    Click into Notes, type a space — the row does *not* toggle.
11. Type a note containing a comma and a quote. Close the window, reopen it: the
    note is intact.
12. Open `<project>_vo_tracker.csv` in Excel. It is legible, and holds only the
    rows you actually marked.

### Renaming

13. Edit a Filename cell and press Enter. The take name changes in the arrange
    view and an amber `*` appears on the row.
14. `Ctrl+Z` once. The take name reverts — one edit is one undo step.
15. Type a name of only illegal characters (`///`). An inline error appears and
    nothing is renamed.

### The acceptance test

16. **Re-transcribe one of the two recordings in ScriptMatch.** Return to
    Overview and press **Refresh**. Every verified mark, note and rename on that
    recording is still there, and the other recording is untouched.
17. **Cut** in ScriptMatch, then Refresh Overview. Row → item navigation still
    lands correctly on the now-split items.
18. Move the project and its audio to another folder, reopen, Refresh. The marks
    are still found by basename.

### Degrading safely

19. Corrupt the tracker (delete its first line) and reopen. The window opens, an
    inline error names the file, and **nothing is saved** until it is fixed —
    confirm the file on disk is not overwritten.
20. Corrupt one sidecar. The window opens, names that file inline, and the other
    recording's rows still load.
21. Open Overview in an unsaved project. It warns that marks cannot be saved and
    otherwise works.

---

## Overview: selection and Sort on timeline

Use a project with **two** recordings, a matched script CSV, and audio already
cut into one item per line.

### Selection

22. Click a row, then Ctrl-click two others. All three stay lit, and the three
    matching items are selected in the arrange view. Shift-click a fourth row —
    the whole range from the last-clicked row fills in.
23. With several rows selected, change the status filter so some of them are
    hidden. The hidden ones leave the selection; the count beside the **Sort**
    button drops to match.
24. Select a fifty-row range. The edit cursor moves once, to the row you clicked
    — not once per row.

### Sorting

25. Select nothing. Set **Record order · Fixed gap · 2.00 s between items ·
    60.00 s between recordings** and press **Sort**. Confirm: a new track named
    `<source> sorted 1` appears **nested as a child under** the track the audio
    came from, all the sorted items are on it, items sit 2 s apart end-to-start,
    the two recordings are 60 s apart with the older file first, and a single
    Ctrl+Z puts the tracks *and* the positions back together.
26. Look at the tracks **below** the new folder. Their indent level did not
    change — nesting the child must not re-indent the rest of the project.
27. Sort again without undoing. A second set named `sorted 2` appears; the
    `sorted 1` tracks are still sitting there untouched.
28. **Crossfade two adjacent takes**, then Sort. The crossfade is still intact,
    the pair moved together as one unit, and both landed on the same new track.
29. Trim a word out of the middle of a take and crossfade the join; Sort. The
    repair survives.
30. **Group two items that sit on different tracks** (select both, `G`), then
    Sort. Both moved by the same amount, they kept their spacing relative to
    each other, and each landed on the child of *its own* source track — not
    collapsed together onto one.
31. Switch to **Script order**. The spacing droplist greys out, and hovering it
    explains why. Sort — items now follow the CSV row order, and any orphan
    (audio matching no script line) lands after the last sorted item.
32. Back to **Record order · Original spacing**. Sort. The gaps from the original
    recording return. If anything had to slide forward to avoid an overlap, the
    status line says how many.
33. Select six rows from the middle of one recording and Sort. Only those items
    move; everything else stays where it was, on its original track.
34. **Lock** one item and Sort. Its cluster is skipped and the status line
    reports how many were left alone — in the normal colour, not red: the sort
    still succeeded.
35. Close and reopen the window. The order, spacing and both gap values are as
    you left them.
36. *(Windows without js_ReaScriptAPI only)* Sort by record order across two
    recordings. The status line says file dates were unavailable and that the
    ordering fell back to filename.
37. Filter to one character, click one of its lines, then Shift-click a line of
    the same character further down with **another character's lines in
    between**. Only the rows between the two clicks are selected. Nothing
    belonging to the other character lights up beyond that range — including
    lines with no audio yet, which used to select as a block.
38. Type a new name into **Item name** and press Enter. The item in the arrange
    view shows the new name immediately, without clicking anything else. The
    **CSV filename** beside it still shows the script's original name, greyed
    and not editable. Hover it to see both names.
39. Rename the same item in REAPER itself (F2 on the item). The Item name column
    catches up within a second or two, without a Refresh.

---

## Recording results

Note anything that differs from the expectations above directly in
[SPEC.md §10](SPEC.md#10-explicitly-unverified) — that section exists precisely to
be converted from "unverified" into "verified, on this date" as these checks are
completed.

## Overview — view settings (2026-08-01)

1. Drag a column header sideways. The column moves and its cells move with it.
   Close and reopen the script: the order is kept.
2. Settings → untick "Restore view settings". Close and reopen: columns are back
   at their declared widths and order, and every header menu reads Middle /
   wrap off / Medium — except Line text, which is wrap on.
3. Re-tick it, set Character to Large, reopen: Large is kept.
4. Right-click any header. The menu shows Vertical align, Word wrap and Font
   size — NOT ImGui's column-visibility list.
5. Turn Word wrap on for Line text. A long line grows its row. The OK checkbox
   stays vertically centred; set the OK column to Top and it moves to the top.
6. Click the empty right-hand end of a tall row: the row still selects, and the
   edit cursor moves.
7. Drag the Line text column narrower. Rows grow taller within a frame, without
   flicker.
8. Settings → set Large to 24. The columns using Large grow on the next frame;
   the toolbar does not move.
9. Settings → type 999 into Small. It clamps to 48 with no error message.
10. Confirm no red "This ReaImGui build did not accept the font sizes" message
    appears. If it does, the 0.9.3 shim is not adapting the 0.10 font rework and
    `PushCellFont` has correctly fallen back to the default font.
