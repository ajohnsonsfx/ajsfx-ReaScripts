# VO ScriptMatch — Manual Test Procedure

Everything in `VO/lib/ajsfx_vo.lua`'s pure layer is covered by `tests/test_vo.lua`
(198 automated tests, run by `./run_tests.sh`). This document covers what those
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

Select the recorded item. Run **ajsfx VO ScriptMatch**.

- [ ] The run dialog opens and shows `1 item(s) selected, 0 skipped`.
- [ ] Browse to the sample CSV. Leave the filters blank and all three toggles at
      their defaults (Alts off, suffix off, last take is primary).
- [ ] Press **Transcribe and cut**. A progress window appears with a working
      elapsed counter.
- [ ] **The project does not change while it runs.**

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
- [ ] A `*_vo_report.csv` sits next to the recorded audio source file.

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

Each of these must show a clear message and change **nothing**:

- [ ] Run with no items selected.
- [ ] Point Settings at a nonexistent whisper-cli → message names the missing path
      and points at Settings.
- [ ] Point Settings at a nonexistent model → same.
- [ ] Point the run dialog at a CSV missing the Filename column → the message
      lists the headers actually found.
- [ ] Point it at a file that is not a CSV at all.
- [ ] Press **Cancel** mid-transcription → "Nothing in the project was changed",
      and the project is untouched.
- [ ] Select a **MIDI** item alongside the audio → it is skipped and named in the
      summary; the audio still processes.
- [ ] Set an item's playrate to 0.5 → skipped with the playrate named. (The
      time-mapping math handles playrate and is unit-tested; v1 refuses it until
      this test confirms REAPER agrees.)

---

## 8. The cache

- [ ] Run once, then run again → the second run reaches the results almost
      instantly, with no transcription window.
- [ ] Change **Accept threshold** in Settings and run again → still instant. This
      is the point of the cache: threshold tuning must be cheap.
- [ ] Tick **Always re-transcribe** → it transcribes again.
- [ ] Change the model → it transcribes again without being asked to.

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

## Recording results

Note anything that differs from the expectations above directly in
[SPEC.md §10](SPEC.md#10-explicitly-unverified) — that section exists precisely to
be converted from "unverified" into "verified, on this date" as these checks are
completed.
