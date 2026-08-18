# SPEC: what the five boxes mean

Status: AJ's own words, 2026-08-17. This is the governing model. Where code
disagrees with this page, the code is wrong.

The take row carries five checkboxes: **Lock, Keep, Sel, Vet, OK**. They are
not five degrees of one thing. They answer three unrelated questions, and
confusing them is what produced a run of bugs in one afternoon.

## In AJ's words

- **OK** -- "I have listened to it, and yes it is a take, and yes it is placed
  in the right line."
- **Keep** -- "We are gonna ship it, either as a select or an alt."
- **Sel** -- "This is the select."
- **Lock** -- "I haven't been using this yet."
- **Vet** -- "Haven't needed to use it."

> "So if something is OK and NOT Keep, that's how I know that I've listened to
> it, it's logged in the sheet, but it's not going to be delivered for whatever
> reason. Bad read, too many takes, whatever."

## The three questions

**1. Is this real, and is it filed correctly? -- OK (and Vet)**

OK is the HUMAN's verdict on the READ: it exists, it is a take, and it belongs
to this line. Vet is the MACHINE's verdict on the same question. They are two
boxes because they can disagree, and a disagreement is worth seeing.

Both are stored as a fingerprint of what was witnessed (`vo.CONFIRMED_EXT`,
`vo.VETTED_EXT`) so they can withdraw themselves -- but they witness DIFFERENT
things, because they are different claims:

- **Vet** is a verdict about WORDS IN A WINDOW, so every edge is in its
  fingerprint. Move an edge and the window it judged is gone.
- **OK** is a verdict about IDENTITY -- "this is a take, and it is this
  line" -- so only the audio it comes from and the name that assigns it to a
  line are in its fingerprint (`vo.ConfirmedFingerprint`). Trimming the head
  off a take does not make it a different read. It used to clear on any trim,
  which cost more than the mark was worth and silently withdrew marks AJ had
  already made -- 11 lines of them on one live session.

Track placement is in neither: moving a take between role tracks does not
un-listen to it, which is what lets a take dropped to Outs keep its OK.
Stamps written in the older format are still honoured (`vo.ConfirmedMatches`).

**2. Are we shipping it? -- Keep, and Sel**

Keep says the take ships. Sel says it ships as THE delivery, under the line's
plain name; everything else kept ships beside it as an alt.

Sel is the NARROWER claim, so Sel implies Keep. Ticking Sel ticks Keep;
unticking Keep drops Sel with it. Unticking Sel deliberately leaves Keep on --
that is what lets the select move between takes without re-ticking anything.

The role tracks are this pair, made visible:

    Selects   Sel (and therefore Keep)
    Alts      Keep, not Sel
    Outs      an explicit NO to Keep -- decided against
    Review    nobody has decided yet

**3. Should rematching leave it alone? -- Lock**

Lock pins a take where it is. Neither a verdict nor a shipping decision.

## The law this page exists to state

**OK AND KEEP ARE INDEPENDENT AXES.** Every combination is meaningful:

    OK + Keep       listened to, and shipping
    OK + not Keep   listened to, logged, and NOT delivered -- a bad read, or
                    one take too many. THE POINT of having two boxes.
    not OK + Keep   we mean to ship it, nobody has listened yet
    neither         untouched

Therefore, and these are testable requirements:

- Ticking OK must never tick Keep, and unticking Keep must never clear OK.
  A take dropped to Outs keeps its OK: you still listened to it.
- "Have I listened to this line?" is answered by OK (or Vet) on EVERY tracked
  take -- never by Lock, and never by Keep. A take that is not a read gets
  untracked, so one still sitting there without an OK is one not yet heard,
  whether it ships or not.
- A take on the Selects track is never judged on Keep: Sel already implies it.
  Measuring Keep against the Alts track alone reported every properly-made
  select as out of sync (fixed 2026-08-17).

## OK absorbed Lock (2026-08-17)

AJ: "I feel like OK and Lock have a lot of crossover at this point." They
did, and the crossover was one-sided. Lock protected a take from being
CHANGED -- it pinned the match (`state.pins`, which is the only thing
rematching consults) and made bulk verbs skip the line. OK only bought
silence from the suspect scanner. So a take confirmed by ear was still fair
game for the next Match run or bulk pick, which is not what "I listened and
this is right" can be allowed to mean.

**OK now pins the match and confers the same protection**: `Verify.Confirm`
writes the pin, `Verify.Unconfirm` removes it, and every place that skipped
a locked line skips an OK.d one. The Lock CHECKBOX is retired -- four boxes,
not five. The pin survives where OK cannot reach: right-click **Lock to time
selection** forces a match the matcher got wrong, which needs no correct take
to exist and so can never be expressed by confirming one.

Note the asymmetry that remains, and is correct: an OK self-clears on any
edit to the take, so its protection goes with it. A take you changed is a
take you have not yet listened to in its new form.

## Lock alone settles the Todo ladder's Needs select rung (deliberate)

Lock is "neither a verdict nor a shipping decision" (above), but `vo.LineStage`
treats a locked line (`g.locked`) as past Needs select even with nothing
picked -- the same rung a real Sel clears. This is a deliberate legacy
exception, not a reintroduction of Lock-as-listening: a line someone forced a
match on by hand (right-click **Lock to time selection**) has had its "which
take" question answered by that override, so the ladder must not keep
demanding a pick it will never get. It still stops at Unverified rather than
Done -- locking is not listening, so the OK/Vet question stays open. Asserted
by `tests/test_vo_inbox.lua`, "a Lock alone settles the pick but never the
verdict" (~line 379).

## Vet is unused

AJ uses neither. Two consequences worth stating rather than discovering:

- Any count that means "has this been listened to" and reads `user_status ==
  "verified"` is reading the LOCK box, and will read zero forever. The stage
  ladder's Unverified rung had this bug; the pipeline strip's Verified meter
  (`vo.SummarizeOverview`, `n.verified`) had it too and is now fixed to match
  -- it counts a row with `vetted_state == "ok"` or `confirmed_state == "ok"`,
  the same read as the stage ladder, so its tooltip's promise ("the machine's
  stamp or yours", i.e. Vet or OK) is finally what it counts.
- Neither box may become load-bearing. A workflow that only works once the
  user starts ticking Lock is a workflow that does not work.
