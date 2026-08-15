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

## 1. The single highest-value check: does the JSON look like we think?

Everything downstream depends on `whisper-cli -ml 1 -sow -ojf` writing
JSON-full with one **segment per word**, `offsets` in **milliseconds**, and
per-token `t_dtw` in **centiseconds** when DTW is on. (Verified live
2026-08-11 against v1.9.1; re-verify whenever `vo.WHISPER_RELEASE` bumps.)

Run it by hand on any speech file — note **`-nfa`**, without which every
`t_dtw` is silently `-1` (flash attention never materialises the attention
matrix DTW reads):

```
whisper-cli -m <model> -f <audio.wav> -of /tmp/probe -ojf -ml 1 -sow -np -dtw <preset> -nfa
```

Open `/tmp/probe.json` and confirm:

- [ ] A `"transcription"` array is present; each entry's `"text"` is **one
      word**, not a sentence.
- [ ] `"offsets"` are **milliseconds** (a word ~2s in reads ~2000, not ~2).
- [ ] Tokens carry `"t_dtw"` values that are NOT all `-1`, and they read as
      **centiseconds** (~2s in ≈ 200).
- [ ] Rerun **without** `-nfa`: every `t_dtw` is `-1`. That asymmetry is why
      `vo.BuildWhisperArgv` pairs the flags.

**If any of these differ, stop.** `vo.ParseWhisperJSON` needs adjusting first,
and its unit tests are the place to encode whatever the real format turns out
to be.

Also confirm the DTW preset name: if whisper-cli rejects it
(`unknown DTW preset`), `vo.DTW_PRESETS` needs correcting. If it accepts
`base.en` for an `.en` model, that preset can be added — the table is
deliberately conservative today.

After the first in-tool transcription, open the `_vo_transcript.csv` sidecar
and confirm the header is `Start,End,Text,Anchor` (version 2) and most rows
carry a fourth value. A v1 sidecar from an older build must read as
**Unsupported transcript version** in Sources, with re-transcribe offered.

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

1. **Select the recording item** (since 2026-08-12 nothing selected means
   nothing acts — the button is greyed and the scope line says so), then press
   **Cut and Name**. Every take the match found is split out of its recording
   and named the plain CSV filename, and every one is STILL on the recording's
   own track. No new track appeared. Lines with no SEL are cut too — cutting
   decides nothing.
2. Two takes of one line both carry the same plain name. That is expected; Pull
   is what separates them.
3. Select a few rows and press it again. Only those rows' takes are affected, and
   the line beside the button says "the selected rows only".
4. Re-record one source so its audio no longer matches its transcript. Cut still
   runs; the summary names that file as skipped and everything else is cut.
5. Undo. One Ctrl+Z puts the recording back as it was.
6. Open the panel and leave it open for a minute. The window stays responsive —
   the staleness check runs on the press, not per frame.

## Pull (2026-08-04)

This is the real workflow, in order. Do it on a session with several takes of
some lines.

1. Cut and Name the session, tick NOTHING, press **Pull**. Everything lands on
   `<CHAR>_Review`, which is a CHILD of the recording's track — collapse the
   recording and it goes with it. Lines with only one take go to
   `<CHAR>_Selects`: there was no decision to make.
2. Work through Review. Tick **Sel** on the take you are delivering and **Keep**
   on any others worth having. Ticking Keep must NOT untick anybody's Sel.
3. Two script lines that share a filename: tick Sel on one. The other line's Sel
   is untouched — they are separate rows in the CSV and separate lines here.
4. Press **Pull** again. The Sel moves to `<CHAR>_Selects`, the Keeps to
   `<CHAR>_Alts`, and everything unticked stays exactly where it is on Review.
5. Press **Pull** a third time with nothing changed. Nothing moves, and NO new
   track appears nested inside `<CHAR>_Review` — that is the check for the
   destination-track recursion.
4. Drop a folder of already-named rendered wavs into the project, with no
   transcripts at all. Pull moves each one to Selects by its filename.
5. An item whose name is not on the script is not moved, and the count line
   says how many were left.
6. Set the alt pattern to `-take{n}`, start 2, digits 2. The preview updates.
   Press **Name them**: every ALT with no name of its own gets one, and the
   **select keeps its plain name** — this is the check that matters.
7. An alt of a line that already has an Append becomes `line_042_ch2_alt1`, not
   `line_042_alt1`.
8. Press **Name them** twice. The second press reports that everything already
   had a name, and nothing is renamed.
9. Pull twice. The second run recognises the items it renamed and does not
   double-move them.
10. **With no transcripts at all**: open a project holding only rendered wavs
    named after script lines. The table is all Missing plus orphans, and Pull
    still moves each file to Selects by its name. This is the case that has no
    rows, so it is the one that proves Pull reads items and not rows.

## Sort by name (2026-08-04)

1. A project of rendered wavs, no transcripts, names matching the script.
   **Sort** in script order lays them out in the script's order.
2. An uncut recording is NOT moved, and the count line reads "N not on the
   script". With nothing else in range, Sort refuses and says to cut first.
3. Sort a Selects track that Pull already renamed with Appends. It still sorts:
   the delivered name resolves too.
4. Sort twice. The second run makes a fresh set of "sorted N" tracks and the
   first set is untouched.
5. Switch to **record order**. The uncut recording is a member again — record
   order asks where audio sat in a recording, which needs no name.

## "Have I got everything?" (2026-08-04)

The checker reads the project's ITEM NAMES and nothing else — no transcript,
no match, no stored mapping — so these checks are about names, not matching.

1. Fresh project, script loaded, nothing cut. The header reads
   `0 of N lines in the project`, and every row's **Got** cell is a red `no`.
2. **Cut and Name**. The header count jumps and the Got cells turn green with
   a count. Hover one: it names the track each take sits on.
3. Rename an item in REAPER by hand to something off-script. The header gains
   `1 name(s) not on the script`, and that line's Got count drops by one.
4. Rename it back. Everything returns. Nothing had to be re-matched or
   re-transcribed — the count is re-read from the names each rebuild.
5. Drop a rendered wav named for a script line into the project, with no
   transcript at all. Its line reads Got 1. This is the case that proves the
   checker is not reading the match.
6. Two script lines sharing a filename: the header reports them as
   `named for two lines at once`, and neither line claims the item.

## Assign an item to a line (2026-08-04)

1. Select an item in REAPER. Right-click the line's row → **Assign selected
   item to this line**. The item takes that line's delivered name, and the
   line's Got cell goes green immediately. No time selection was involved.
2. Comp four takes into four items, select all four, assign. They become the
   line, then `_alt1`, `_alt2`, `_alt3` using the Pull panel's alt pattern.
3. With nothing selected in REAPER, the menu item is greyed and says so.

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

## The table follows the timeline (2026-08-04)

1. With takes cut and the window open, click a take in the ARRANGE view. Its
   row lights in the table and scrolls into view. The edit cursor does NOT
   move — you clicked the timeline, the timeline is where you are.
2. Ctrl-click a second take on another track. Both rows are lit.
3. Click a row in the TABLE. The item selects in the arrange view as before,
   and the table does not fight itself (no scroll bounce on the next frame).
4. Select an item the table has no row for (a remainder chunk). The table
   selection is left exactly as it was.
5. Scroll the table away from the followed row. It stays where you scrolled —
   the follow is consumed once, not reasserted per frame.

## Drift and orphan warnings (2026-08-04)

1. Rename a cut take in REAPER with F2. The header gains
   "1 name(s) changed outside this window"; hovering lists old -> new.
   Rename it back — the entry stays (it re-arms only when THIS window
   renames something, or on Refresh of a fresh project load).
2. Cut and Name: the counter does not fire for the tool's own renames.
3. Hand-edit the project `_vo.csv`: change an Append row's script name to one
   that is not loaded. Reopen — the header shows a red
   "1 Append(s) match no loaded line" naming it.
4. A fresh uncut project shows "0 of N" with NO "name(s) not on the script" —
   the recording's own item no longer counts as a stray.
5. Name alts, then check the header: `_alt` names count as takes of their
   line, not as strays.
6. Open the Cut and Name panel on a project with two lines sharing a filename
   and no Appends: the panel warns before the cut, in amber.

---

## Tighten (2026-08-04)

1. Cut and pull a session, then drag a few Selects' edges outward so they have
   over a second of head or tail room. Select them (since 2026-08-12 an empty
   selection acts on nothing) and press Tighten: the message names how many
   items moved, and each loose edge now sits at the standard room (60ms head /
   150ms tail by default).
2. Select two items in REAPER and press Tighten: only those two are measured.
3. Hand-trim one item (change its fades while you're at it) and make its edges
   loose again: Tighten reports it measured but leaves it alone — custom fades
   mark it as yours.
4. Butt-joined takes (a cut where one take ends exactly where the next begins)
   whose tail holds the NEXT take's first syllable and a stretch of dead air:
   Tighten trims through the blip to the item's real last word. Play the ends —
   no foreign syllable, no long silence.
5. Press Tighten again immediately: "every edge is already tight."

## Bulk Sel/Keep (2026-08-04)

1. Shift-click a range of rows in the sheet, then tick Keep on one of the
   highlighted rows: every highlighted row's Keep snaps to the same value.
   Untick the same way — all clear together.
2. Tick Keep on a row OUTSIDE the highlight: only that row changes.
3. Tick Sel across a highlight spanning several lines: each line still ends up
   with at most one Sel (exclusivity survives the bulk apply).
4. Pull after marking: kept non-Sel takes land on Alts, unmarked takes on
   Review — the marks are live workflow, not decoration.

---

## Recording results

Note anything that differs from the expectations above directly in
[SPEC.md §10](SPEC.md#10-explicitly-unverified) — that section exists precisely to
be converted from "unverified" into "verified, on this date" as these checks are
completed.

## Ranged take markers (2026-08-09)

Everything here is REAPER-only: chunk I/O, split propagation, and native
marker gestures are exactly what the mock cannot reach.

1. Cut a session. Every cut piece shows its own ranged marker in the arrange
   view, named `<asset> ~<id>`, spanning the take. The recording-track
   remainders may hold off-window copies; they draw nothing.
2. Drag a marker somewhere else in its item, then Refresh: the sheet row's
   source times follow the marker, and its Sel/Keep/note stay attached.
3. Alt-drag a marker's end: the row's span updates the same way.
4. Split a marked item by hand: both halves carry the TKM line; only the half
   whose window intersects the range counts (the sheet shows ONE take). Press
   *Clean stray take markers*: the off-window copy disappears.
5. Re-run Cut on marked audio: "N take(s) skipped -- their markers own that
   audio". *Re-cut anyway* deletes those markers and cuts fresh, with new
   markers, in one undo step each.
6. On the pre-marker Grumbar session, press **Mark takes**: every take gains a
   marker at its item's current edges. Spot-check the three worst hand-fixed
   takes (`DoNotTellMaster`, `NowYesIsNot`, `WordsTooBig`) -- their markers
   must sit at the FIXED edges, not the old match spans.
7. Delete a marker with the take-row verb (or natively): the row leaves the
   sheet; if it carried marks, Repair lists them under "no audio".
8. On a planned take, *Add take marker from selected item*: the planned row
   becomes a marker row and its notes ride along (the entry rekeys to
   `tkm|<id>`).
9. Marker-less lines still resolve through the match, unchanged -- a fresh
   project before any Cut looks exactly as it did.

## Adopt session + gap repair on cut sessions (2026-08-09)

The ingest path for a session that was cut and edited BEFORE this tool
arrived: transcribe, load the script, **Adopt session**, Pull. Verified
headlessly against the Grumbar session on 2026-08-09 (items reset to the
recording's name, sidecars removed, everything re-ingested); the checks
below are the GUI-side confirmations of the same paths.

1. On a project of already-cut items named after the recording, press
   **Adopt session** (Cut panel). Every matched item takes its line's
   delivered name at its CURRENT edges -- no item edge moves, no split
   happens, and the message counts marked / named / already named / left
   alone. One Ctrl+Z reverts the whole adoption.
2. Press it again: "already named" absorbs the previous run, 0 renames.
3. Rename one item by hand to a DIFFERENT script line's name, then Adopt.
   That item is counted "named for another line and left alone" -- the
   match never overwrites an assignment.
4. Pull after Adopt: the named items route to Selects/Review normally.
5. **Gap repair now fires on cut sessions.** Delete a transcript sidecar in
   a project where the recording exists only as clips (no full-length item),
   re-transcribe: the whisper cache answers instantly, and the repair pass
   probes the WHOLE file through a temporary full-length item -- watch the
   track count flicker by one during the scan, and confirm no stray track
   remains after. A swallowed window (the Grumbar 1.4-30s head) comes back
   with its words merged and the Sources message reporting the recovery.
6. Make the source unreadable (rename the wav briefly) and re-run: the
   report says the hole "could not be checked" and names why, instead of
   passing it as silence.
7. The remote seam knows `adopt` and `mark_takes`; `help` lists both.

## Mark selected + the take map travels with the audio (2026-08-09)

1. Select an item that has no take marker (a leftover, or an item cut by
   hand), press **Mark selected** (Cut panel, or Repair panel). The message
   names the line it guessed and the percentage of the take the item covers;
   the marker appears at the item's edges and the item takes the line's
   name. One Ctrl+Z reverts marker and name together.
2. Select an item holding chatter or room tone and press it: "matched no
   line", and if there was a weak candidate the message says what it was and
   why it was refused (under the floor).
3. Select an item that already has a marker: counted as such, untouched.
4. Press **Sync take markers** (Repair panel). Widen any Selects item by a
   few seconds: the neighbouring takes' markers are visible inside the
   revealed audio, labelled with their lines. Widen past the configured
   reach (default 30s): nothing there — press Sync again and the newly
   overlapped takes appear.
5. Drag a take marker somewhere else, then Sync: the copies of that marker
   in neighbouring items move to match the one you dragged — the visible
   copy is the truth, mirrors follow it.
6. Sync twice: the second press says every item already carries the map.
7. The seam knows `mark_selected` and `sync_markers`.

## Toolbar zones + Tidy (0.15beta5)

Setup: any project with a script loaded and a few cut takes.

1. Row 1 reads `Sheet: [Refresh] [Tidy ▾] | Items: [Cut and Name] [Pull] [Sort]
   [Place] [Tighten] [Repair] | [Script] [Sources…] [Settings] <script name>`.
   Row 2 starts with the Search box; Rematch / Select takes / Place / Tighten
   are gone from it.
2. Refresh = old Rematch: message reports lines identified, locked lines skipped.
3. Tidy with both opt-ins OFF: message reports refreshed count; NOTHING moves
   or renames on the timeline (undo history gains no item edit).
4. Drag a second item of one line onto Selects. The card shows the amber
   "2 selects -- pick one" badge (band row 3, next to Script); the summary
   line counts it. Press Tidy: message includes "1 line(s) with two selects".
5. Tidy ▾ → tick both opt-ins (labelled "changes items"). Press Tidy on a
   project with unnamed Sel-ticked takes: takes get named, Pull runs, one
   undo step covers the item edits ("VO Overview: tidy"), Pull's own report
   shows.
6. Tidy ▾ → Select takes + first/last combo still work as before.
7. Untick both opt-ins afterwards; confirm they persist across a window
   close/reopen (config), and Tidy's tooltip returns to "Tracking only".

## Duplicate markers, range-true transcripts, cut fades (unreleased)

Real session, 2026-08-10: `ChristianBrently_Grumbar_2026_0801`, the item at
project `631.4541` (source window `31.4541–34.8700`).

### Verified

1. **Remove duplicate take markers.** The item held two counting markers with
   byte-identical ranges — `IWinLittle ~mkm` and `Book ~mkt`, both
   `31.87 → 34.87` — while the words spoken there are "I only win little."
   One press deleted the Book marker and kept IWinLittle, reporting
   `Book (0.00) lost to IWinLittle (0.75)`. The winning score is 0.75 rather
   than 1.00 because the script line and the transcript differ in wording;
   well clear of both the 0.50 floor and the 0.20 gap.

### Not yet executed

2. Range-true transcripts: drag a marker's end inward on a take whose marker
   sits inside a longer matched span, and confirm the grey transcript loses
   the words the marker no longer covers, that the extra-word colouring
   narrows with it, and that the take stays on the same script line.
3. The score under that same row must NOT move — it still comes from the
   greatest-overlap span.
4. **Apply the cut fades.** Select two items, one hand-faded and one already
   standard. The press should report one item changed, not two; a second
   press should report that all of them already carry the fades; one Ctrl+Z
   should restore both.

### Not yet executed — the merged verbs

5. **Remove Extra Take Markers** (replaces the duplicate-only verb and the old
   project-wide "Tidy up take markers"). On item 12 at `634.870`, which carries
   dead copies of both `31.87` markers from a split: one press should drop the
   leftovers and report the clip count. On an uncut recording it must report
   nothing removed.
6. **Tidy Up Take.** Trim a clip's head by hand, leaving its fade-in at zero
   and its fade-out intact. One press should: remove any extras, snap the
   surviving marker to the new edges, and fill ONLY the fade-in. The fade-out
   must be untouched. One Ctrl+Z reverses the whole thing.
7. Press Tidy Up Take twice: the second press should report zero snapped and
   zero faded.
8. **Deliver** (Pull row, first button). On a session with takes picked but
   nothing pulled: one press should build the tracks, file the items, and lay
   them out, with the message reading back all three steps. **ONE** undo step
   must reverse the whole thing — this relies on REAPER collapsing nested undo
   blocks into the outermost, which is the part to actually check.
9. Press Deliver twice: the second press should report the tracks already
   existing and nothing left to pull, and still lay out without error.

### Verified 2026-08-10, second pass

**Tidy Up Take**, on the item at project `651.6413` (source window
`51.6413–53.9771`) holding one short marker `~mlz` at `52.27–52.96`: one press
left a single marker and extended it to the clip's edges. Covers item 6 above
apart from the fade detail.

This press first failed, and the failure is worth recording. `Trim.extras`
called `vo.PlanMarkerMirror`, which gives an item every canonical marker
**intersecting** its window — and the next take's marker `~mm6` ran
`52.96–59.04`, starting inside this clip. The mirror handed a copy to both
items, so the clip then held two markers and the snap step correctly refused
it as a recording. Removing extras had added one.

Fixed by `vo.PlanMarkerPrune`, which keeps only the markers an item *owns*
(`vo.CountingMarkers`' rule: the item covering most of that id's range) and
structurally cannot add one. `tests/test_vo_markers.lua` carries the live
geometry, including an assertion that `PlanMarkerMirror` *does* add the
straddler — so swapping it back fails loudly.

### Still not executed

- The fade half of Tidy Up Take: trim a clip's head so its fade-in is zero
  while the fade-out is intact, press once, and confirm ONLY the fade-in is
  filled.
- Tidy Up Take pressed twice: the second press should report zero snapped and
  zero faded.
- Range-true transcripts (items 2 and 3 above).
- **Apply the cut fades** (item 4 above).
- **Deliver** (items 8 and 9 above) — in particular that ONE undo reverses all
  three steps.

### Untrack these items — not yet executed

10. Select an uncut recording holding many take markers. **Untrack these
    items…** should offer a confirm naming three counts: markers, stored
    decisions, item names. Cancel must change nothing.
11. Press Untrack. Expect: every tool take marker gone from that item, any
    Lock/Keep/Sel and notes stored against those markers gone from the project
    file, the take name cleared to blank (REAPER then shows the source
    filename). A take marker YOU placed by hand — no ` ~id` suffix — must
    survive.
12. The sheet must NOT go empty: the affected lines still show takes, derived
    from the match, with no marker. Press **Identify the lines in these
    items** and the markers come back.
13. With nothing selected in REAPER, the button's popup must say to select
    items first and offer no Untrack button.

## Update from Item / Update from Marker (unreleased)

`Tidy Up Take` is now **Update from Item**, and it has a mirror. Nothing here
has been executed in REAPER — the routing (`vo.PlanUpdatePass`) is unit-tested,
every write is not. The tab is also renamed `Main`, and `Cut recording into
takes` has moved up into the `Match:` group.

### Layout

1. The second tab reads **Main**, not Edit. Its groups read **Match: / Edit: /
   Pick: / Pull: / Check:** and `Cut recording into takes` is the LAST button
   in Match, after `Untrack these items…`.
2. The ribbon must not jump when switching Setup ↔ Main. The reserved height is
   measured per width, and this change moved a button between rows.

### Update from Item

3. **The missing-marker step.** Delete a take's marker (or Untrack one item),
   leaving audio the matcher recognises. Press **Update from Item**. Expect: a
   marker back at the ITEM's own edges — not the transcript's — the item named
   for its line, and the report saying `Marked 1 item(s) that had no take
   marker and named 1`.
4. Same again on an item whose audio matches no script line. Expect nothing
   written and `1 item(s) match no script line`. It must NOT invent a marker.
5. **An already-marked item is not re-derived.** Drag a marker's edge inward by
   hand, then press. The marker must move OUT to the item's edges (that is the
   snap), never to the transcript's boundary settings — proving `only_unmarked`
   kept the identify pass off it.
6. **The fade half.** Trim a clip's head so its fade-in is zero while the
   fade-out is intact. One press fills ONLY the fade-in. (Carried over from
   Tidy Up Take, still unexecuted.)
7. Press twice. The second press reports zero snapped, zero faded, and writes
   nothing.
8. An uncut recording in the selection is reported as `hold several markers and
   were left alone`, and comes out untouched — no marker moved, no fade added
   to the recording itself.

### Update from Marker

9. Drag a take marker to where the clip should start and end, then press
   **Update from Marker**. Expect: the item's edges land on the marker, and the
   same source sample stays at the same project time (spot-check by ear, or
   read `D_STARTOFFS` before and after with the MCP harness).
10. The item's name: an item with a blank or meaningless name takes the
    marker's line name. An item already named for a real line is left alone
    even if that line is the WRONG one — reassignment is Identify's job.
11. An item with NO take marker is left alone and reported as
    `have no take marker to update from`. Nothing is trimmed to zero length.
12. Two contested markers the words cannot decide: nothing is trimmed, nothing
    is renamed, and the refusal is named in the report.

### One undo

13. **The one that matters.** Both buttons must be ONE undo step. Update from
    Item runs the identify pass inside the macro's own transaction
    (`Trim.bare`, so the step opens no block of its own) — press it on a
    selection that needs marking, snapping AND fading, then press Ctrl+Z once
    and confirm the markers, the edges and the fades all revert together.

## Editing a line (unreleased)

Nothing here is executed. The pure layer is unit-tested (9 tests); the card is
not — the suite cannot load the Overview script.

1. Right-click a line's words. The menu reads Copy / Copy original line /
   ─── / Edit line… / Revert to script line, with **Revert greyed** on an
   unedited line and both Copy items always present.
2. Both Copy items on an unedited line put the same text on the clipboard.
3. **Edit line…** → type different words → the card shows them, and the
   script's own words appear in grey directly BELOW, never above.
4. Fold that card. The grey row stays, because the line is edited.
5. Fold an UNEDITED card. One row only — unchanged from today.
6. Unfold an unedited card. The grey row is there, identical to the line.
7. Press **Match transcript to script**. The edited line now scores against
   the edited words — a take that was missing should find its line. This is
   the whole point of the feature; if only this one works, it was worth it.
8. **Revert to script line**, from the menu and from the popup button. Both
   clear the edit, and the grey row goes on a folded card.
9. Save and reopen the project. The edit survives, as a `Line,` row in the
   project file beside the `Append,` rows.
10. Disable the script in Setup, then re-enable it. The edit is still there —
    a disabled script must not destroy the user's words.
11. Right-click `Script:` → **Copy full path** gives the whole path, not the
    stripped basename shown on the card.
12. A long edited line still wraps before the filename column, and the grey
    row wraps with it.
13. Edit a line that appears TWICE in one script. Only the occurrence you
    edited changes — the records are keyed by occurrence, not by filename.

### Editing the filename (unreleased)

Same gesture as the line, and it REPLACES the Append — that menu item is gone.

14. Right-click a filename: Copy / Copy original filename / ─── / Edit
    filename… / Revert to script filename, with Revert greyed when unedited.
    There must be no **Edit Append** item anywhere.
15. Double-click a filename opens the same Edit filename popup (it used to
    open Edit Append).
16. Type a name → the top row shows it, and the script's own filename appears
    grey in the filename column of the provenance row, beside `Script:` and
    the original line.
17. Items already carrying the old name are NOT renamed, and turn up in Check
    as names not on the script. That is the intended cost of renaming.
18. Cut / Pull / Auto-name write the NEW name onto items.
19. Two lines that clash under one delivered name: renaming one clears the
    amber clash badge on both. This is what the Append used to be for.
20. Open a project saved BEFORE this change whose lines carry Appends. The
    delivered names must be exactly what they were — Append records still
    resolve, they are just no longer editable from the card.
21. Save and reopen. The override survives as a `Name,` row.

## Word anchors and the boundaries they place (2026-08-12)

Covers `SPEC-word-anchors.md` and `SPEC-anchor-boundaries.md`. Anchors are the
DTW timestamps that sit ON a word; whisper's `offsets` are a partition of the
timeline and can miss the word entirely, which is what all of this fixes.

1. **The sidecar is v2.** Transcribe a source and open its
   `*_vo_transcript.csv`: the marker row reads `ajsfx VO Transcript,2`, the
   header is `Start,End,Text,Anchor`, and most rows carry a fourth number.
2. **A v1 sidecar is refused, not silently used.** Point the tool at a
   transcript from before this change: Sources shows it as *Unsupported
   transcript version* and offers to re-transcribe. It must NOT parse.
3. **`-nfa` is doing the work.** Re-run whisper by hand without it (see §1) and
   confirm every `t_dtw` comes back `-1`. With it, they are real. If this ever
   flips, anchors are gone and the transcript quietly returns to §2's failure.
4. **The take reads what it says.** Find a take whose marker was cut at a
   partition edge (Grumbar: source 428.593–429.894, line "You."). Its card must
   show the words actually inside it, not the neighbour's.
5. **The marker check catches the rest.** Remote seam verb `marker_words`, or
   the Check panel: it walks every take marker and reports both sides of a
   boundary tear — the row that LOST a word as `missing`, the neighbour that
   GAINED it as `extra`. On a session mid-edit, expect real flags; they are the
   list to work through, not a failure.
6. **A tear repairs itself on re-Identify.** Take a flagged pair (Grumbar:
   ChainIsChain / EvenIfYouSmile at source 584.9–590.5, boundary at the
   partition edge 586.210), delete their markers, select the item and Identify.
   The new boundary lands in the audible gap (~587.8, in the breath), the
   earlier take keeps its own last word, and both flags clear.
7. **Anchor-less transcripts are unchanged.** A model with no DTW preset writes
   no anchors and everything falls back to the old onset rule — worse, but
   never different from what it always did.

## The selection is the scope (2026-08-12) — VERIFIED 2026-08-12

1. With **nothing** selected in REAPER and no rows selected in the sheet, the
   Edit tab's scope line is amber and says so, and every verb that touches
   audio is greyed: the hero, Identify, Untrack, Cut, the whole Edit and Pick
   rows, Deliver, Build the destination tracks.
2. Hovering a greyed button still shows its tooltip, ending in "Needs a
   selection".
3. Still live, deliberately: **Match transcript to script**, the four Check
   panels, Word substitutions. They have no item scope to narrow.
4. Select one row: the scope line turns blue and counts it, and the buttons
   come back. Press Cut — only that take is cut.
5. Select a row the filters are hiding: the line must say the selection is
   hidden by the filters, NOT "nothing selected". Two different zero states.

---

## Verify and the vetted stamp (2026-08-13) — VERIFIED 2026-08-13 (steps 1-3, 5, 6, via the MCP harness on a TTS speech fixture; step 4's Cancel click and step 3's accept-suggestion menu click are UI-only and still need a human hand — both code paths were confirmed by two independent reviews)

Fixture: a cut, identified session with at least three named takes and a
transcript. All six steps in order; each assumes the one before.

1. **Vet a clean row.** Click the fourth (vetted) checkbox on a take whose
   name and transcript you trust. The decode window opens and closes; the
   report says `clear`; the box is now ticked.
2. **Edits uncheck it.** Trim that item's edge slightly. On the next rebuild
   the box unticks by itself. Open Check → Suspects: the row is listed under
   "was vetted, changed since".
3. **Wrong line moves to Review.** Rename two takes to each other's lines,
   select both rows, right-click → Verify 2 lines against audio. Both land on
   their recording's Review track; the report line for each reads
   `wrong line … audio says <the other line>`.
4. **Cancel keeps what finished.** Queue four rows, press Cancel in the decode
   window during the second. The first row's verdict stands (stamp or move
   applied); the report ends with `cancelled`; no whisper-cli process is left
   in Task Manager.
5. **Lock outranks the machine.** Lock a misnamed take, Verify it: report
   says `flagged … locked; audio says <line>`, and the item has not moved.
6. **One undo.** After a run that moved items, one Ctrl+Z puts every moved
   item back at once (stamps and sidecar merges are not undone — files and
   P_EXT written outside the move transaction survive, by design).

## Dragging a take onto another line (0.15beta18)

The two `vo.*MarkerOnItem` / `vo.*MarkerFromItem` wrappers go through
`GetItemStateChunk` / `SetItemStateChunk`, which `tests/mock_reaper.lua` does
not implement — the same limit `vo.WriteTakeMarkers` and `vo.AddMarkerToItem`
already carry. The rules they enforce are unit-tested in the planners
(`vo.PlanMarkerRetarget`, `vo.PlanMarkerRemove`, `tests/test_vo_markers.lua`);
the write, and the gesture, are verified here.

Needs a session with at least two script lines that have takes, and at least
one UNCUT recording holding several takes as markers in one item.

1. **A take moves.** Unfold two lines. Drag a take row from line A onto line
   B's band. Expect: the row leaves A and appears under B; the item is renamed
   to B's name with the next free alt suffix (not the plain delivered name);
   the item is now on the Review track, which is created at the end of the
   track list if it was not there. One Ctrl+Z puts all of it back.
2. **Sel and Keep are cleared, notes are not.** Before dragging, tick Sel on
   the take and type a note. After the drop: Sel and Keep are clear, the note
   is still there. (The marker keeps its id, which is what carries the note.)
3. **Folded cards take drops.** Fold line B. Drag a take onto its band.
   Expect the same result — the band is the target whether open or shut.
4. **One item, one name.** Drag a take that lives in the uncut multi-take
   item. Expect: the take moves to the new line (its marker is retargeted and
   the row appears under the new card), the item is NOT renamed and does NOT
   move to Review, and the message says so — `... shares an item with N other
   takes, so the item was not renamed or moved -- Cut will split it out.`
   Check the neighbouring takes in that item are still under their own lines.
5. **An orphan is identified.** Drag a row out of "Not on the script" onto a
   line's card. Expect a marker minted over THAT ROW's span — not the whole
   recording — so only that stretch becomes a take of the line, and the other
   takes in the same recording are untouched.
6. **Off the script.** Drag a take onto the "Not on the script" heading.
   Expect: its marker is gone, its item name is cleared (REAPER shows the
   source filename), and the span reappears in the orphan queue. Its stored
   marks are gone with it.
7. **Several at once.** Select three takes (click, then shift-click), drag one
   of them onto a line. All three move, and they get three DIFFERENT alt
   numbers. Then drag an UNSELECTED take: only that one moves.
8. **Refusals.** Lock a take, drag it: it does not move and the message counts
   it. Drag a take onto the line it is already on: nothing happens.
9. **Click still works.** After all of the above, a plain click on a take row
   still auditions it (moves the cursor, selects the item) and right-click
   still opens the take menu. The drag source must not have eaten either.

## Two filter boxes: Script and Transcript (0.15beta18)

1. Press Filters. Expect two boxes where one said "Text": **Script** and
   **Transcript**.
2. Type a word that appears in a script line but not in its take's transcript
   into Script. Expect the line shown. Clear it, type the same word into
   Transcript. Expect it hidden.
3. **The two boxes OR.** Type the same word into both — say `please`, where one
   line's SCRIPT says it and a misfiled take's TRANSCRIPT says it under some
   other line. Expect BOTH cards on screen at once: the line that wants the
   word, and the card holding the take that says it. That pairing is the whole
   point — it is what makes the take draggable onto the line.
4. Filters still AND across different fields: with `please` in Transcript, type
   a script name into Where. Expect the result narrowed, not widened.
5. Open a project saved by 0.15beta17 or earlier that had a Text filter set.
   Expect both boxes empty, and no ghost filtering.

## Parity watcher (0.15beta21)

1. Trim a tracked clip's edge -> within a second the marker snaps to it,
   one undo step, one log line. Ctrl+Z once undoes the sync, twice the
   trim; after both undos nothing re-fires (the redo-stack guard).
2. Drag a take marker inside a clip -> the item trims and renames onto it.
   One undo step.
3. Rename an item to another line's exact name -> the marker follows (same
   id, Keep/Sel survive). Rename it to "asdf" -> nothing changes;
   Out of sync gains a row saying the name resolves to no line.
4. Drag a take from Review to Selects -> Sel ticks itself, alt names run
   after the marks. Untick "Keep the session in sync", repeat with another
   take -> nothing moves, Out of sync gains the row instead.
5. Split a clip -> both halves change several elements at once, so both
   queue; neither is renamed automatically.
6. Press "Fix from Marker" on a queued row -> that item alone trims and
   names onto its marker, and the row leaves the queue on the next diff.
7. One press, one undo: every automatic sync and every "Fix from ..." is a
   single undo step.
8. Click an Out of sync row's text -> the clip selects in REAPER, the edit
   cursor lands on it, and the sheet's line selects/unfolds/scrolls by
   itself. Same for a marks-vs-tracks row.

## The OK box (0.15beta24)

1. On a take whose transcript disagrees with its name (yellow words), tick
   the OK box (fifth box, after Vet) -> tick appears; tooltip says YOU
   checked it. The transcript text is unchanged. The Vet box is unchanged.
2. Open Suspects -> that take is no longer listed for name mismatch.
3. Run Verify (quick check) over it -> report says "OK'd by you", the OK
   survives, and the Vet box is not stamped by it.
4. Trim the item's edge -> the OK clears itself on the next rebuild
   (fingerprint falsified). Re-tick, rename the item -> same.
5. Click a ticked OK box -> the mark withdraws; the Vet stamp (if any)
   stays.
6. Highlight several rows, tick one OK box -> all highlighted rows OK in
   one press.
7. Re-listen ON, click the VET box of an OK'd take -> whisper decodes and
   its verdict stands. The OK box is its own fact and is not stripped by
   the decode; withdraw it yourself if the decode changes your mind.
8. Layout: the transcript column starts right of the OK box -- no overlap
   at any window width.
