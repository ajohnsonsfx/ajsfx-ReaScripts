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

Use `tests/fixtures/vo_sample_script.csv`. It is deliberately awkward: two
speakers, a `TO RECORD` row that must be ignored, quoted commas, an apostrophe,
and a numeral.

| LineID | Speaker | Type | Text | AudioAsset |
|---|---|---|---|---|
| NPC_001 | Guard | Dialogue | Halt! Who goes there? | vo_guard_halt_01 |
| NPC_002 | Guard | Dialogue | Open the north gate, quickly. | vo_guard_gate_01 |
| NPC_003 | Guard | Barks | Intruder in the courtyard! | vo_guard_bark_01 |
| NPC_004 | Guard | Dialogue | You'll need 3 keys for that door. | **TO RECORD** |
| PLR_001 | Hero | Dialogue | I have business with the captain. | vo_hero_captain_01 |
| PLR_002 | Hero | Dialogue | Stand aside, or I'll move you myself. | vo_hero_aside_01 |

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
- [ ] A `*_vo_report.csv` sits next to the project.

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

- [ ] Speaker `Guard` → only the three NPC lines are cut. The Hero reads land on
      Review as unmatched, because they are no longer in the filtered script.
- [ ] Type `Barks` → only NPC_003 is cut.
- [ ] A speaker that does not exist → "No script lines survived the filters", and
      **nothing is changed**.

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
- [ ] Point the run dialog at a CSV missing the AudioAsset column → the message
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
      at the extracted `whisper-cli.exe`. Confirm the file exists there.
- [ ] **Model:** pick `base`, press **Get**. After it completes the model path
      fills in and the model shows **[installed]** in the dropdown.
- [ ] Re-open the model dropdown: the button now reads **Use downloaded**;
      pressing it just sets the path with no download.
- [ ] **Backend ready** turns green once both are set.

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

## Recording results

Note anything that differs from the expectations above directly in
[SPEC.md §10](SPEC.md#10-explicitly-unverified) — that section exists precisely to
be converted from "unverified" into "verified, on this date" as these checks are
completed.
