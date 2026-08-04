# VO Manual Test Procedure

Everything in `VO/lib/ajsfx_vo.lua`'s pure layer is covered by `tests/test_vo.lua`
and `tests/test_vo_view.lua` (run `./run_tests.sh` for the current count — all
passing). This document covers what those tests **cannot** reach: REAPER
itself, real audio, and the actual whisper-cli binary, across the three
windows — **ajsfx VO Sources**, **ajsfx VO Overview** and **ajsfx VO Cut** —
plus **ajsfx VO Settings**. Nothing below has been executed yet — see
[SPEC.md §10](SPEC.md#10-explicitly-unverified).

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
Ideally record a **second** session (even a short one re-reading NPC_001 and
NPC_002) on a second track: several later sections need two recordings.

---

## 3. ajsfx VO Sources — transcribing

Open **ajsfx VO Sources** with a project holding two recorded, untranscribed
wavs.

1. Confirm two rows, both reading `No`, with the correct **Items** count for
   each.
2. Select one, press **Transcribe**. Confirm progress appears, then
   `<audio>_vo_transcript.csv` exists beside the wav and the row flips to
   `Yes` with a non-zero **Words** count.
3. Select the transcribed row alone; confirm the button reads
   **Re-transcribe**.
4. Select both rows; confirm the button reads **Transcribe** (one of the two
   still needs it).
5. Re-record over the transcribed wav so its size changes; confirm the row
   reads `Stale`.
6. Double-click a transcribed row; confirm the detail panel opens with the
   preamble and readable prose broken into paragraphs.
7. Hover a word in the focused paragraph; confirm the source-time tooltip.
8. Click a word; confirm the edit cursor lands on that word in the arrange
   view and the view scrolls to it.
9. Press **Re-transcribe this file**; confirm whisper actually re-runs (it
   must not hit the scratch cache) and the panel refreshes.
10. Double-click the same row again; confirm the panel closes.
11. Hand-corrupt a transcript file (delete its first line) and reopen the
    window; confirm the row reads `Error`, the detail panel names the reason,
    and no window failed to open.

### Batch behaviour

Use a project with 50+ one-line-per-file wavs for these.

12. Press **Select untranscribed**, then **Transcribe**. Confirm the progress
    line counts `n of N` and names the current file, and that transcript
    files appear beside the audio *as the run proceeds*, not all at the end.
13. Cancel a run partway through. Confirm the files already done keep their
    transcripts and their rows read `Yes`, and re-running transcribes only
    the remainder.
14. Put an unreadable or zero-byte wav in the middle of the selection. Confirm
    the run completes, that file is listed by name with its reason, and every
    other file still transcribed.

---

## 4. ajsfx VO Overview — matching and judgement

Needs a project with **two** transcribed wavs (finish §3 first) and the sample
script CSV.

1. Open **ajsfx VO Overview**. Choose the sample script CSV. Confirm statuses
   populate immediately, with no whisper run.
2. Load a **different** script CSV, then load the sample CSV back. Confirm
   statuses re-derive immediately both times — still no whisper run, no
   staleness warning.
3. A line the script has but no recording matched shows **Missing**.
4. Audio that matched no script line shows **Orphan**, listed after
   everything else.
5. Tick **Select** on a take, close and reopen Overview. Confirm the tick
   survives and `<project>_vo.csv` contains the row.
6. Add a note to a **Missing** line (one with no audio). Confirm it saves and
   returns, with an empty Source cell.
7. Hand-corrupt `<project>_vo.csv` (delete its first line); confirm Overview
   opens, says it cannot read the file, and refuses to save.

### Opening the sibling windows

8. From Overview press **Sources…**; confirm the Sources window opens.
9. Press it again with Sources already open; confirm nothing breaks and no
   duplicate action is registered (check the Actions list contains one
   `ajsfx_VO_Sources` entry).
10. Double-click a Source cell in Overview; confirm Sources opens with that
    row selected, scrolled into view, and its detail panel open.
11. With Sources already open, double-click a *different* Source cell in
    Overview; confirm the open window switches rows.
12. Press **Cut…**; confirm the Cut window opens.

### Navigating and marking work

13. Click a row from the first recording. The edit cursor moves to it and the
    item is selected. Click one from the second recording — same, on the
    other item.
14. Click a Missing row. Nothing moves, the row is dimmed, and hovering
    explains why.
15. A line with several takes shows sibling rows. Tick **Select** on one —
    the others of the same asset clear automatically.
16. Tick **OK** on a few rows. Select a row and press `Space` — it toggles.
    Click into Notes, type a space — the row does *not* toggle.
17. Type a note containing a comma and a quote. Close the window, reopen it:
    the note is intact.
18. Open `<project>_vo.csv` in Excel. It is legible, and holds only the rows
    you actually marked.

### Renaming

19. Edit an Item name cell and press Enter. The take name changes in the
    arrange view and the project file records the override.
20. `Ctrl+Z` once. The take name reverts — one edit is one undo step.
21. Type a name of only illegal characters (`///`). An inline error appears
    and nothing is renamed.
22. Rename the same item in REAPER itself (F2 on the item). The Item name
    column catches up within a second or two, without pressing Refresh.

### The acceptance test

23. **Re-transcribe one of the two recordings in Sources.** Return to Overview
    and press **Refresh**. Every verified mark, note and rename on that
    recording is still there, and the other recording is untouched.
24. **Cut** in Cut (§5), then Refresh Overview. Row → item navigation still
    lands correctly on the now-split items.
25. Move the project and its audio to another folder, reopen, Refresh. The
    marks are still found by basename.

### Degrading safely

26. Corrupt the project file (delete its first line) and reopen. The window
    opens, an inline error names the file, and **nothing is saved** until it
    is fixed — confirm the file on disk is not overwritten.
27. Corrupt one transcript sidecar. The Sources row for it reads `Error`;
    Overview still loads the other recording's rows normally.
28. Open Overview in an unsaved project. It warns that marks cannot be saved
    and otherwise works.

---

## 5. ajsfx VO Overview — selection and Sort on timeline

Use a project with **two** recordings, a matched script CSV, and audio already
cut into one item per line (finish §6 first for the cut items, or use any
project with existing per-line items).

### Selection

29. Click a row, then Ctrl-click two others. All three stay lit, and the
    three matching items are selected in the arrange view. Shift-click a
    fourth row — the whole range from the last-clicked row fills in.
30. With several rows selected, change the status filter so some of them are
    hidden. The hidden ones leave the selection; the count beside the **Sort**
    button drops to match.
31. Select a fifty-row range. The edit cursor moves once, to the row you
    clicked — not once per row.
32. Filter to one character, click one of its lines, then Shift-click a line
    of the same character further down with **another character's lines in
    between**. Only the rows between the two clicks are selected.

### Sorting

33. Select nothing. Set **Record order · Fixed gap · 2.00 s between items ·
    60.00 s between recordings** and press **Sort**. Confirm: a new track
    named `<source> sorted 1` appears **nested as a child under** the track
    the audio came from, all the sorted items are on it, items sit 2 s apart
    end-to-start, the two recordings are 60 s apart with the older file
    first, and a single Ctrl+Z puts the tracks *and* the positions back
    together.
34. Look at the tracks **below** the new folder. Their indent level did not
    change — nesting the child must not re-indent the rest of the project.
35. Sort again without undoing. A second set named `sorted 2` appears; the
    `sorted 1` tracks are still sitting there untouched.
36. **Crossfade two adjacent takes**, then Sort. The crossfade is still
    intact, the pair moved together as one unit, and both landed on the same
    new track.
37. **Group two items that sit on different tracks** (select both, `G`), then
    Sort. Both moved by the same amount, they kept their spacing relative to
    each other, and each landed on the child of *its own* source track — not
    collapsed together onto one.
38. Switch to **Script order**. The spacing droplist greys out, and hovering
    it explains why. Sort — items now follow the CSV row order, and any
    orphan (audio matching no script line) lands after the last sorted item.
39. Back to **Record order · Original spacing**. Sort. The gaps from the
    original recording return. If anything had to slide forward to avoid an
    overlap, the status line says how many.
40. Select six rows from the middle of one recording and Sort. Only those
    items move; everything else stays where it was, on its original track.
41. **Lock** one item and Sort. Its cluster is skipped and the status line
    reports how many were left alone — in the normal colour, not red: the
    sort still succeeded.
42. Close and reopen the window. The order, spacing and both gap values are
    as you left them.
43. *(Windows without js_ReaScriptAPI only)* Sort by record order across two
    recordings. The status line says file dates were unavailable and that the
    ordering fell back to filename.

---

## 6. ajsfx VO Cut — cutting

Needs a project with transcribed audio, a matched script CSV loaded in
Overview, and at least one line ticked **Select**.

1. Select takes in Overview, open Cut, press **Cut**. Confirm clips land
   named and routed, and one Ctrl+Z undoes the whole run.
2. Confirm clip edges sit in silence — zoom in on three boundaries and check
   none contains a syllable of the neighbouring line.
3. Turn `snap_boundaries` off in Settings (§7); re-run Cut; confirm the fixed
   150/250 ms pads return instead of silence-searching.
4. Re-record over a wav referenced by a loaded transcript so it changes size;
   confirm Cut is disabled and names the stale file.
5. Deselect every take in Overview; confirm Cut shows the inline "Nothing is
   selected" message rather than running.
6. Leave a multi-take line with no select; confirm it is listed as needing a
   decision and is not cut.
7. Have two sources both select the same Filename; confirm two
   `Selects — <name>` tracks appear and the collision is reported inline.
8. Turn on **Use alts track**; cut a line with two takes, one selected.
   Confirm the non-selected take lands on Alts.
9. Turn on **Suffix alt names**; confirm the non-selected take from the
   previous step is now named with a `_tk0N` suffix while the selected take
   keeps the bare name.

### Regions

10. Enable **Create regions over Selects clips** in Settings, then Cut again.
    Confirm a named region sits over each Selects clip and the names match
    the take names.

---

## 7. ajsfx VO Settings — snapping controls

1. Open **ajsfx VO Settings**. Confirm a **Boundaries** section is present
   with: Snap clip edges to silence, Maximum head room, Maximum tail, Minimum
   silence, Noise floor headroom, Floor measurement window.
2. With **Snap clip edges to silence** off, confirm the other five controls
   grey out.
3. Change each value, close and reopen Settings, confirm each persisted.
4. Confirm Cut's behaviour changes accordingly (§6.2–6.3): raising Maximum
   head room widens how far a start boundary may search; lowering Minimum
   silence makes a boundary easier to place inside a short gap.
5. Hover a padding control's tooltip; confirm it explains the value is now a
   *maximum* reach, not a fixed amount.

---

## 8. Backend & model download (Settings)

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

### GPU device check

- [ ] Press **Check device**. Expected: `Device: CUDA — <your GPU>`.
- [ ] If it reads `CPU only` despite the CUDA build, your NVIDIA driver or GPU
      may be too old for the 12.4 runtime — note it in SPEC §10 and try the
      CUDA 11.8 build.

### Download failure handling

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

## 9. Two scenarios no single window's tests cover

### Portability: a wav travels without its project

1. In a **different, fresh** project, copy a recording that already has a
   `<audio>_vo_transcript.csv` sidecar (from an earlier section) into the new
   project's media, plus the sidecar file itself, and add the wav to a track.
2. Load the same script CSV in Overview.
3. Confirm the matching lines show up immediately, with zero marks (no
   Select, no Status, no notes — this is a fresh project file) and **no
   whisper run** — the transcript travelled with the wav, the judgements did
   not, exactly as `VO/SPEC.md` §4 describes.

### Read-only audio directory

4. Make the directory holding a recorded wav **read-only** at the filesystem
   level.
5. In Sources, select that file and press Transcribe (or Re-transcribe).
6. Confirm whisper still runs (it only reads the audio) but writing
   `<audio>_vo_transcript.csv` fails.
7. Confirm the failure appears as an **inline warning** naming the file and
   the reason, not a message box, and that the Sources window stays open and
   usable — other files in the same batch that are writable still succeed
   (§3, batch behaviour).
8. Restore write access and re-transcribe the file; confirm the sidecar is
   now written and the row reads `Yes`.

---

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

## Overview — align-all and the text mirror (2026-08-01)

1. Settings → "Align every column: Middle". Every header menu now reads Middle,
   and every cell in a tall row is vertically centred.
2. Set one column back to Top by hand. Only that column moves; the rest stay.
3. Settings → tick "Match Transcript to Line text". Transcript immediately takes
   Line text's alignment, word wrap and font size.
4. Right-click the Transcript header, set Font size → Large. Line text follows.
5. Right-click Line text, turn Word wrap off. Transcript follows.
6. Untick the mirror, change one column: the other no longer follows.
7. Re-tick it, close and reopen the script: the two are still in step.

## Several scripts, and the Append column (2026-08-02)

1. Open **ajsfx VO Overview** on a project saved by the previous version. Its one
   script is listed under **Script**, still mapped, and the table is unchanged.
2. Press **Script** → **Add script…** and choose a second CSV. Both scripts' lines
   appear; the **Script** column tells them apart.
3. Add the same CSV again. It is refused with a message and the list is unchanged.
4. Untick a script. Its lines vanish and the match re-runs — with no
   re-transcription and no progress bar.
5. Remove a script and add it back. Anything typed in its Append column is still
   there.
6. Point a script's **Filename** combo at the wrong column. That script alone shows
   an error; the other script's lines are still matched.
7. Load two scripts that deliver the same filename. Both lines show a **red
   filename** and a **red Append cell**, on every take.
8. Type `_ch2` in one line's Append. Both lines go back to normal, and the Item
   name column shows `<filename>_ch2`.
9. Two lines *inside one script* sharing a filename behave identically.
10. Instead of an Append, rename one of two clashing lines with the Item name
    field. The red clears. Rename it back to the other's name — the red returns.
11. Run **ajsfx VO Cut**. The clips carry the appended names, and a script that
    failed to load is reported in the Cut window too.

## The script list: layout, multi-add, order (2026-08-04)

1. With two scripts whose names differ a lot in length, the column pickers and
   **Remove** of both rows sit on the same columns — the longer name does not push
   its own row's widgets right of the other's.
2. Press **Add script…** with js_ReaScriptAPI installed and select two CSVs at once.
   Both are added, one reload. Without the extension the dialog takes one file, as
   before.
3. Select two CSVs where one is already listed. The new one is added; the message
   names only the one skipped.
4. Press **▼** on the first script. It moves down, and the `#` column renumbers so
   the now-first script's lines come first. The arrows are greyed at the ends.
5. Save, close and reopen the project. The order you left is the order you get.

## Cut and Name (2026-08-04)

1. Click a take's Select cell until it reads **SEL**, then press **Cut and Name**.
   The take is split out of the recording, named the plain CSV filename, and is
   STILL on the recording's own track. No new track appeared.
2. Two takes of one line, one SEL and one ALT. Both are cut, both carry the same
   plain name. That is expected — Pull is what separates them.
3. A third take of that line, unmarked, is cut too: it is what Pull puts on Outs.
4. A line with several takes and none marked SEL: the panel says so and the
   button is greyed.
5. Re-transcribe a source in ajsfx VO Sources, then reopen the panel. It refuses
   until the audio and its transcript agree again.
6. Undo. One Ctrl+Z puts the recording back as it was.

## Filters are remembered (2026-08-04)

1. Pick a character, set the status filter, type in the search box, open **Filters**
   and type in a column box. Close the window and reopen it: everything is as you
   left it, and the table shows the same rows.
2. Reopen with **Filters** having been off. The filter row is still off, and any
   needles you had typed are still there when you switch it back on.
3. With a character filter set, remove the script (or unmap its Character column)
   and reopen. The filter is dropped and the full table shows — not an empty one.
4. Open a *different* project. Its own filters apply; this project's do not follow.
5. Open the project file in a text editor. `View` rows appear only for what is
   actually set; clearing every filter removes them again.

---

## Recording results

Note anything that differs from the expectations above directly in
[SPEC.md §10](SPEC.md#10-explicitly-unverified) — that section exists precisely to
be converted from "unverified" into "verified, on this date" as these checks are
completed.
