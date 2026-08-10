# Fresh-run notes — 2026-08-10

A running list from driving the tool through a whole session from scratch
(Grumbar reset to one recording, no transcript, no sidecar). Each item is
something the run showed should be done, written while it was still annoying.

Status: **open** unless marked.

---

## Toolbar

- [ ] **The tab ribbon should be a fixed height.** Each tab's button row is
      whatever tall its own contents are, so switching tabs shifts the whole
      sheet up or down under the cursor. The ribbon should reserve one
      height — the tallest tab's — and every tab draw into it, so the cards
      never move when you click around the toolbar.

## Sources / transcribe

- [ ] **The log must be selectable text.** A run reported two problems and
      neither could be copied out of the window — the only way to quote it was
      a screenshot. Whatever is worth printing is worth pasting into a bug
      report.

- [ ] **Take me to the problem — make the timecode itself the link.** Every
      reported trouble spot (an unrepaired gap, a suspected loop) prints a
      timecode; that timecode should be clickable, drawn as a link
      (underlined, blue) — `00:08:48:00` — and move the edit cursor and view
      there. Then the user listens and decides whether it is a real hole or
      the reader genuinely said that. A button beside the message would work;
      the link is better, because the thing you want to go to is the thing
      you click.

- [x] **FIXED — "whisper-cli exited with code -1" was our own race.** Running
      the tool's exact repair command by hand returned exit 0 and recovered the
      whole window (`Can. / Yes. / Can. … I win little. ×4 / Book. / Old
      book.`). The bug was in the poll loop: the Windows launcher does
      `echo %ERRORLEVEL% > done.txt`, which CREATES the file before writing
      into it, and `finished()` did `tonumber(f:read("l")) or -1` — so a poll
      landing in that instant reported exit -1 for a run that had barely
      started. Coin flip per launch, which is why 2 gaps repaired and 1
      "failed" in one session. Now `vo.ParseExitFile` returns nil ("not
      finished") for an unreadable code, with tests, and the same bug is fixed
      in the second async runner that had it copied.

- [ ] **BUG: the loop detector cried wolf on a real performance.** It reported
      8:48–9:01 as the transcriber looping — "Do not repeat that." four times,
      "whatever was said in those 0:13 is not in this transcript, so no line
      from that stretch can match. Re-transcribe." Listening says otherwise:
      the actor read it four times, and the script has the line
      (`DBP_Grumbar_Grumbar_DoNotRepeatThat`, "Do not repeat that.").
      Four takes of a short line is NORMAL — it is what the whole tool is for.

      The detector must consult the script before accusing the transcript: a
      repeat that MATCHES A SCRIPT LINE is a re-read, not a loop. As written
      the message is worse than silence — it tells the user to throw away a
      good transcript and re-run whisper on a 39-minute file, and it will fire
      on every line an actor tries more than twice in a row.

- [x] **FIXED — the detail panel implied sentences the data does not have.**
      It broke the transcript into paragraphs at `.`/`?`/`!`, so four reads of
      one line showed as `Do not tell master, not do tell master, do not tell
      master.` — one long "sentence" that looks like a transcription failure
      and is actually a reader going again. It now breaks where the reader
      PAUSED (`vo.PARAGRAPH_PAUSE`, 0.35s), which is the only boundary in this
      data that came from the performance rather than the recognizer.

## What the transcript's timings actually are

Measured on this run, and it reframes several of the items above:

- **Whisper's word END timestamps are fiction.** 93% of consecutive words have
  EXACTLY zero gap, and whisper claims 1626s of speech in a 1724s file — a 94%
  duty cycle for a session that is takes with pauses between them. Each word's
  end is stretched to the next word's start.
- **So silence is invisible in the transcript.** Splitting the word stream at
  0.3s of "quiet" still yields runs up to 184 seconds. There is nothing to
  split on. This is the mechanical reason long blocks appear.
- **The audio disagrees, cleanly.** Scanning the wav at 20ms and breaking on
  0.3s below room tone + 12dB gives **508 speech islands**, median 2.16s, none
  over 10.5s. The previous full session on this recording had **511 takes**.

- [ ] **DESIGN: give the matcher the audio's island boundaries.** The take
      boundaries the tool is trying to infer from text already exist in the
      audio. Bounding candidate spans by real silence would fix long blocks
      structurally rather than by tuning thresholds — and it is the same probe
      machinery the cutter already uses.

- [ ] **BUG: candidate scoring is length-blind, so short lines eat long ones.**
      `vo.FindCandidates` scores `1 - Levenshtein/max(len)`, and
      `vo.BuildBackbone` picks greedily by score among non-overlapping spans.
      A one-word line (`"Can."`) matching one word scores 1.0 and beats a
      seven-word line at 0.93 — it takes the token and the long line loses its
      match. Length is only a tiebreak AT EQUAL SCORE. Prefer longer lines
      first, or weight score by matched length.

- Already true, verified in the code: the reader is assumed to work mostly in
  order (`vo.BuildBackbone` takes the longest NON-DECREASING subsequence of
  line indices, non-decreasing exactly so retakes count as in order).
  Still unverified: how false starts (half a line, then a restart) are handled.

## Empty state

- [ ] **The blank sheet should ask for the two things it needs.** On a project
      with no script and no transcript, the large empty area where the cards
      go says nothing. It should prompt for **Choose script…** and
      **Transcribe**, as the two next actions, rather than leaving the user to
      find them in the Setup tab. The emptiest screen is the one that most
      needs to say what to do next.
