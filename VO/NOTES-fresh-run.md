# Fresh-run notes — 2026-08-10

A running list from driving the tool through a whole session from scratch
(Grumbar reset to one recording, no transcript, no sidecar). Each item is
something the run showed should be done, written while it was still annoying.

Status: **open** unless marked.

---

## Toolbar

- [x] **FIXED — the Match button says "match".** Now
      `Match transcript to script`, in the Edit tab's Match row.
      ORIGINAL NOTE: Asked how to make the engine match transcript to script, the
      answer is "Sheet → Update sheet to match items", which nobody would
      guess: the match is recomputed live and that button re-reads everything
      first. The old `Refresh` at least said "identify the lines again from
      scratch" in its tooltip. Folding it in was right on mechanics and wrong
      on vocabulary. Either the button says it (`Re-match and update the
      sheet`?) or the Transcribe/Script tab carries an explicit
      **Match transcript to script** that runs the same path.

- [~] SUPERSEDED — went the other way: five tabs collapsed to
      Setup / Edit / Settings, with dim group labels (Match / Items /
      Tracking) doing the dividing. Revisit only when the domains are known.
      ORIGINAL NOTE: Proposed layout:
      `[Script] [Transcribe] [Sheet] [Items] [Fix a line] … [Settings]`, with
      Script holding **Add script…** and Transcribe holding **Sources and
      transcripts…** plus an explicit match action. Two different jobs share
      the Setup tab today, and the one people look for most (transcribe) is
      the one buried behind a generic name.

- [~] ANSWERED, no code — adding the same CSV twice with a different character
      already does this and needs no new UI. It is also how you would give the
      two speakers different settings later, so the second entry is not a
      workaround for a missing multi-select; it is the better shape. Build
      selection only if adding twice turns out to be annoying in practice.
      SUPERSEDED IN SPIRIT by the note below: binding the CHARACTER to the
      SOURCE is the same want, expressed on the axis where the fact actually
      lives.

- [ ] **Bind a character to a source file: `source + script + character = what
      to expect from this file`.** (AJ, 2026-08-10, while running the tool in
      order.) Two mics, two actors, one script: say which actor is on which
      wav, and matching a source considers only that character's lines.

      This is a better axis than script-side speaker selection, and it is worth
      being clear about why: **the mic is the fact.** One wav holds one actor,
      and that is true of the recording no matter how the script is organised —
      one CSV for the whole cast, one per character, or the same CSV added
      twice. A binding made on the source survives every one of those choices,
      where a binding made on the script entry has to be redone whenever the
      script list changes.

      What it buys, in order of value:
      1. **Halves the candidate pool per source.** Every wrong match this tool
         makes is a line stealing another line's words, and the worst offenders
         are short lines that match everywhere. A one-word line of the OTHER
         actor can no longer take this actor's audio at all — not scored lower,
         gone. That is a constraint, not a threshold, and constraints are what
         short lines have always needed.
      2. **Makes "not on the script" mean something narrower.** Audio on this
         mic that matches no line OF THIS CHARACTER is a much sharper statement
         than audio matching no line at all.
      3. **Catches the setup mistake.** A file bound to the wrong actor would
         match almost nothing, loudly and immediately, instead of matching a
         plausible-looking third of the script.

      Where it lives: `<project>_vo.csv`, beside the script list. It is a
      judgement about a recording, not a fact derived from one, so it belongs
      in the user's file — and it must survive re-transcribing, which rewrites
      the sidecar wholesale. Where it is SET is Overview's Setup tab, next to
      the script list: Sources deliberately cannot see the script (SPEC-sources
      §1), and this needs both to be meaningful.

      Design question to settle first: is an unbound source **unconstrained**
      (matches everything, today's behaviour) or **unusable**? Unconstrained,
      certainly — a one-actor session must keep working with no setup at all,
      and that is the common case. So the binding is an optional narrowing,
      never a requirement.

- [~] DECIDED against, for now — most of it already exists and the rest should
      not be automatic. `vo.ResidualPass` already re-matches the lines nobody
      placed against the audio nobody claimed, repeating until a pass adds
      nothing, so the batch "come back for the leftovers" is done. What was
      really being asked for is the LOWER THRESHOLD, and that is exactly what
      should not run unsupervised: the risk that keeps the global setting
      conservative is a wrong name written silently across five hundred takes.
      The orphan right-click is that same looser search, one span at a time,
      with a person looking at it — which is what makes the loosening safe.
      Revisit if a real session leaves a pile the right-click is too slow to
      work through.
      ORIGINAL NOTE: Same idea as the orphan right-click above, applied to
      everything at once: re-run matching at a lower threshold over spans
      nothing claimed. May be made redundant by the scoring and island-boundary
      work — worth deciding after those, not before.

- [x] **FIXED — the Edit row wraps instead of running off screen.** It carries
      every verb in the tool, and ImGui has no flow layout, so buttons simply
      left the window. It now measures each label and starts a new row when the
      next one will not fit — correct at any width, and renaming a button
      cannot push the last one off the edge.

- [x] **FIXED — the tab ribbon holds one height.**
      It reserves the tallest a tab has taken AT THIS WIDTH, measured rather
      than declared: the buttons wrap, so the same tab is two rows wide and
      four narrow, and a constant would be wrong at every width but one. The
      reservation is dropped when the width changes, so a window made wider
      does not keep what it needed when it was narrow.
      ORIGINAL NOTE: Each tab's button row is
      whatever tall its own contents are, so switching tabs shifts the whole
      sheet up or down under the cursor. The ribbon should reserve one
      height — the tallest tab's — and every tab draw into it, so the cards
      never move when you click around the toolbar.

## Sources / transcribe

- [x] **FIXED — Copy report.** A run reported two problems and neither could be
      copied out of the window; the only way to quote it was a screenshot. The
      detail panel's facts — identity, backend, model, any problems, and the
      whole transcript — go to the clipboard as text on one button. Selecting
      individual words on screen would have meant a read-only text box, which
      loses the colour that makes the problems findable in the first place.

- [x] **FIXED — the timecode is the link.** Underlined, blue, hand cursor; a
      click moves the edit cursor, and it says so if no item in the project
      plays that source. On the loop warning, which is the only trouble report
      that names a time.
      ORIGINAL NOTE: Every
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

- [x] **FIXED — the loop detector cried wolf on a real performance.** It reported
      8:48–9:01 as the transcriber looping — "Do not repeat that." four times,
      "whatever was said in those 0:13 is not in this transcript, so no line
      from that stretch can match. Re-transcribe." Listening says otherwise:
      the actor read it four times, and the script has the line
      (`DBP_Grumbar_Grumbar_DoNotRepeatThat`, "Do not repeat that.").
      Four takes of a short line is NORMAL — it is what the whole tool is for.

      Fixed without needing the script, which the Sources window cannot see: a
      decoder emitting one phrase over and over does not BREATHE, and a reader
      going again does. Repeats separated by `vo.LOOP_MAX_PAUSE` (0.35s) or
      more no longer extend a run, so the four reads above count as two cycles
      and stay silent. The gap is checked everywhere inside the added stretch,
      not just at the block junction — an offset phrase otherwise hides the
      pause mid-block, which is how the first attempt still flagged twelve
      re-reads.

      Accepted false negative: a real loop straddling a pause reads as two
      shorter runs. That is the right way to be wrong — a missed loop costs a
      re-run, crying wolf costs a good transcript the user was told to bin.

- [x] **FIXED — the detail panel implied sentences the data does not have.**
      It broke the transcript into paragraphs at `.`/`?`/`!`, so four reads of
      one line showed as `Do not tell master, not do tell master, do not tell
      master.` — one long "sentence" that looks like a transcription failure
      and is actually a reader going again. It now breaks where the reader
      PAUSED (`vo.PARAGRAPH_PAUSE`, 0.35s), which is the only boundary in this
      data that came from the performance rather than the recognizer.

- [x] **DONE — Delete transcript…, behind a confirm that names the file and
      says what goes and what stays.** Offered on an unreadable sidecar too,
      which is the row most likely to want removing. STILL TO VERIFY BY HAND,
      which is what the note asked for: delete a transcript on a session that
      has been cut and pulled, and confirm marks, names and take markers all
      survive. The argument that they will is below, and it rests on where each
      thing is stored rather than on having tried it.
      ORIGINAL NOTE: Transcribing
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

- [x] **FIXED — ranked by tokens of agreement, not by score.** vo.Agreement is
      score x window length: 0.89 of nine tokens is eight tokens landing in a
      row, which is what cannot be an accident, where 1.0 of four tokens is
      four. It ranks the backbone pool and each tier of SelectSpans, and reads
      `effective`, so an out-of-order candidate carries its penalty into the
      comparison rather than around it. The gates (accept, margin, review
      floor) are unchanged — this decides who goes FIRST among the eligible.
      ORIGINAL NOTE:
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

## The two item verbs, in the user's words

Both already exist; what was missing was the names and, in one case, the
scope. Renamed in the Items tab's menu:

- **Assign items to lines** (`MarkSelectedItems`) — one or more already-split
  items are selected; work out which line each one is, mark it at its CURRENT
  edges, name it, log it in the sheet. Bidirectional and non-destructive: it
  gets things STARTED, it does not decide Sel/Keep and it does not trim.
- **Find lines in items** (`MarkTakesFromSession`) — one or more LONG items
  are selected that hold several takes; find them all and write a marker per
  take inside the item. Splits nothing.

- [x] **FIXED — "Find lines in items" honours the REAPER selection**, and
      nothing selected still means everything. Judged on the RESOLVED item, not
      row.item, since a row whose audio is found by source time has no item of
      its own until that point. "Adopt this whole session" is exempt: its name
      is its scope.
      ORIGINAL NOTE: It walks every matched take in the project. When the user
      has picked the two long items they want dealt with, it should do those.
      The per-item scoping is the same want as the orphan right-click's "try
      again": run the matcher over ONE span, deliberately, at a threshold a
      batch pass would not dare.

- [~] DECIDED — keep the tabs, do not move Sources. Two things changed the case
      since the note was written: the empty sheet now offers **Transcribe**
      directly, which is when a first pass actually reaches for it, and **Run
      the whole pass** removed the other reason to live in the toolbar. Sources
      is a once-or-twice-per-FILE errand, which is what Setup is for. Revisit
      if a real session still finds the trip annoying — but not before, because
      this would be the third reorganisation and the layout should settle.

## "Not on the script" must be a QUEUE, not a dead end

- [x] **DONE — every orphan has a right-click that resolves it.**
      *This is line…* lists the script lines those words could be, best first
      (vo.FindSpanLines: the matcher backwards, looser than the batch pass on
      purpose), and assigning renames the item, or writes a ranged take marker
      where the span is if it has not been cut out yet. *This is junk* is
      persisted as the row's status, so it rides with the marks and survives a
      rematch, and it LEAVES the orphan count — which is what makes "not on the
      script: 0" mean the session is finished. The summary says so when it gets
      there.
      NOT built as a separate verb: *Try again*. The looser retry IS that menu;
      it shows the guesses the batch pass would not take rather than applying
      one. A button that pre-picks the top entry of a list you are already
      looking at is a third control where two do the job.
      ORIGINAL NOTE: The list reads as
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

- [x] **DONE — each orphan says why it is one:** *dismissed*, *no such line*
      (named for a line no loaded script has), or *unmatched*. Told from what
      the row already carries, so it costs nothing. The fourth case the note
      imagined — "a line matched but another span won it" — is not
      distinguishable without re-running the match, and the right-click answers
      it better anyway by showing what each line scores against this span.
      ORIGINAL NOTE: "Not on the script" covers at least
      three different things — no line scored high enough, a line matched but
      another span won it, or the words genuinely are not in the script — and
      the fix differs by case. The list should name which.

## The sheet

- [x] **FIXED — the transcript colour marks extra words.** vo.ExtraWords aligns
      line and take by longest common subsequence and returns drawable runs, so
      what is amber is the words the reader said that the line does not
      contain. The tie goes to the LATER occurrence, so a false start is marked
      rather than the read that followed it. Non-blocking, as the note
      required.
      ORIGINAL NOTE: Today a
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

- [x] **FIXED — the blank sheet asks for the two things it needs**, with a
      button for each and a tick against the one already done.
      ORIGINAL NOTE: On a project
      with no script and no transcript, the large empty area where the cards
      go says nothing. It should prompt for **Choose script…** and
      **Transcribe**, as the two next actions, rather than leaving the user to
      find them in the Setup tab. The emptiest screen is the one that most
      needs to say what to do next.
