# Fresh-run notes — 2026-08-10

A running list from driving the tool through a whole session from scratch
(Grumbar reset to one recording, no transcript, no sidecar). Each item is
something the run showed should be done, written while it was still annoying.

Status: **open** unless marked.

---

## Toolbar

- [ ] **Nothing in the toolbar says "match", and matching is what the tool
      does.** Asked how to make the engine match transcript to script, the
      answer is "Sheet → Update sheet to match items", which nobody would
      guess: the match is recomputed live and that button re-reads everything
      first. The old `Refresh` at least said "identify the lines again from
      scratch" in its tooltip. Folding it in was right on mechanics and wrong
      on vocabulary. Either the button says it (`Re-match and update the
      sheet`?) or the Transcribe/Script tab carries an explicit
      **Match transcript to script** that runs the same path.

- [ ] **Split Setup into [Script] and [Transcribe].** Proposed layout:
      `[Script] [Transcribe] [Sheet] [Items] [Fix a line] … [Settings]`, with
      Script holding **Add script…** and Transcribe holding **Sources and
      transcripts…** plus an explicit match action. Two different jobs share
      the Setup tab today, and the one people look for most (transcribe) is
      the one buried behind a generic name.

- [ ] **A script should be able to select which speaker(s) it contributes.**
      Open question from the same design: multi-select on one script entry, or
      add the same CSV twice with a different character each time. Adding it
      twice already works and needs no new UI — worth trying that before
      building selection, since the second entry is also how you would give
      the two speakers different settings later.

- [ ] **A "find what I missed" pass, looser than the batch run.** Same idea as
      the orphan right-click above, applied to everything at once: re-run
      matching at a lower threshold over spans nothing claimed. May be made
      redundant by the scoring and island-boundary work — worth deciding after
      those, not before.

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

- [ ] **Let the user delete a transcript from the Sources panel.** Transcribing
      the wrong file is an ordinary mistake, and the only cure right now is to
      open the project folder, work out which `*_vo_transcript.csv` it is, and
      delete it by hand. The tool wrote the file; the tool should be able to
      remove it. Being opaque about it does not make it safer — it just moves
      the work somewhere the tool cannot check it.

      On whether it breaks anything: mostly no, and for a principled reason.
      What the user DECIDED lives in the project file, take identity lives in
      ranged take markers inside the items, and the delivered name lives on the
      take — none of that is in the transcript. The transcript is the one file
      the tool can rebuild by running whisper again. What is lost is the
      transcript COLUMN and the ability to re-derive matches until it is
      re-run; items already named, pulled and markered keep everything.

      Verify before shipping it, rather than assuming: delete a transcript on a
      session that has been cut and pulled, and confirm marks, names and take
      markers all survive. Ask for confirmation naming the file, and say in the
      dialog what is lost and what is kept.

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

## "Not on the script" must be a QUEUE, not a dead end

- [ ] **Give every orphan a right-click that resolves it.** The list reads as
      a pile of unknown content, and a session does not feel finished while it
      is sitting there — 64 of them on this run. It is the right instinct: some
      of those lines ARE in the script, so the list is a to-do, but the tool
      offers no way to do anything about a single entry.

      The three verbs it needs, on a right-click:

      1. **Try again** — re-match this span alone, at a looser threshold than
         the batch run dares use. A human looking at one span can accept a
         weaker match than a pass over 1600 words should; the risk that makes
         the global setting conservative does not apply to one deliberate act.
      2. **This is line X** — hand it to a line, with the search already
         filtered by what the span says. The name is the assignment, so this
         is a rename underneath, but the user should be picking a LINE, not
         typing a filename.
      3. **This is junk** — slate, chatter, a cough, a false start. Dismissed
         explicitly, PERSISTED (it is a judgement about audio, so it belongs
         in the project file with the marks), and out of the count.

      The last one is what makes the count trustworthy: with it, "not on the
      script: 0" means every span has been looked at and decided, and the
      session really is done. Without it the number can only ever be ignored,
      which is what makes the pile feel like a wall.

- [ ] **Say WHY a span is orphaned.** "Not on the script" covers at least
      three different things — no line scored high enough, a line matched but
      another span won it, or the words genuinely are not in the script — and
      the fix differs by case. The list should name which.

## The sheet

- [ ] **Transcript colour should say something the user can act on.** Today a
      take's transcript is amber when `row.status == "review"` and dim
      otherwise — i.e. the colour encodes the MATCH SCORE, with no legend and
      no number. From the outside it reads as random: `can` amber on one card,
      `book` amber on another, `man walk down and come back wrong` dim on a
      third.

      Proposal: draw every transcript in one colour, and mark the DIFFERENCE
      instead — the words the take has that the line does not, in AMBER (the
      same `0xDDAA33FF` already used for "needs your attention" elsewhere in
      the sheet; red is for errors, and an extra word is not an error). Then
      the colour is about the words on screen rather than about a threshold,
      and it is legible without knowing what "review" means.

      It should stay non-blocking either way. A take with extra words is still
      a take the user may want; Sel/Keep/Lock is where that gets decided, not
      a status the tool assigns.

## Empty state

- [ ] **The blank sheet should ask for the two things it needs.** On a project
      with no script and no transcript, the large empty area where the cards
      go says nothing. It should prompt for **Choose script…** and
      **Transcribe**, as the two next actions, rather than leaving the user to
      find them in the Setup tab. The emptiest screen is the one that most
      needs to say what to do next.
