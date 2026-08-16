# Spec: Qwen3-ASR as the VO transcription engine

**Goal:** the Sources stage can transcribe with Qwen3-ASR + its forced
aligner instead of whisper, producing sidecars whose per-word timestamps
are true aligned times — ending the displaced-window/DTW patch layer for
newly transcribed sources.

**Deliverable(s):** `VO/lib/qwen_transcribe.py` (venv runner),
`vo.BuildQwenArgv` + engine plumbing in `VO/lib/ajsfx_vo.lua`, Sources UI
engine selection, Settings readiness panel, released as a 0.15 beta.

## Decisions (verified 2026-08-15)

1. **Models:** `Qwen/Qwen3-ASR-1.7B` + `Qwen/Qwen3-ForcedAligner-0.6B`
   (both Apache-2.0, already cached in `Resources/asr-qwen/venv`).
   `transcribe(..., language="English", return_time_stamps=True)` returns
   per-WORD `start_time`/`end_time` in seconds. Verified against AJ's own
   cut edges on 30 Grumbar takes: first words +0.02..+0.10s inside his cut
   start, ends inside his tails, zero clipped word heads
   (`qwen_edge_bench.py`). Internal chunking: 20 min ASR / 3 min align —
   full sources need no windowing on our side.
2. **Sidecar format unchanged** (`t0,t1,word,anchor`, header version 2):
   t0=start, t1=end, anchor=start. Every consumer (matcher, cutter, sheet,
   judges) keeps working unmodified; for Qwen sidecars the stamps and the
   anchor agree by construction.
3. **The envelope keeps the edge.** Aligner times are planning input, as
   whisper's were; Tighten/boundary measurement stays the cut authority
   (vo-measured-cut-offsets still governs).
4. **Verify/re-listen stays whisper.** Qwen's LLM decoder drifts toward
   fluent expected text ("sentinels" for *sentence*, "Elpid" for *help* in
   the benchmark) — good for assignment, wrong for verification. The
   engine setting affects sidecar transcription ONLY.
5. **Device:** config `qwen_device` = `auto | cuda | cpu`, default auto =
   try CUDA, fall back to CPU on any failure (incl. OOM — the GPU is
   shared with ComfyUI; ~5 GB needed in bf16). CPU is a real mode, not a
   degraded one: ~1.6 s/take resident, minutes per session, zero VRAM.
6. **One process per run, models loaded once.** The runner loads models
   once per source, writes the JSON and whisper-style progress lines to
   stdout so vo.RunWhisperAsync's log tail keeps working — never one
   process per take (the model reload tax is whisper-server's documented
   disease).
6a. **Burst segmentation, not whole-file decode** (found live 2026-08-15):
   a VO source is the same line read repeatedly, and on minutes-long
   windows that repetition defeats the forced aligner — the first
   full-file run collapsed 825 of 1654 words to zero width on one
   timestamp, with phrases on the wrong take. The runner therefore finds
   speech bursts by energy (-45 dB floor, 1 s join, 0.25 s pad, 25 s max
   with quietest-point splits) and decodes+aligns per burst, offsetting
   times — the clip-sized regime where the engine benchmarked flawless.
   Zero-width residue words are dropped and counted in the JSON.
7. **Engine choice** `transcribe_engine` = `whisper | qwen`, default
   **whisper** for now — Qwen becomes default only after a full Grumbar
   re-transcription is judged good. Per-source re-transcribe is the
   migration; changed words clear Vet/OK fingerprints by themselves.
8. **Venv resolution** follows the PVX pattern: path derived from the
   installed lib location, no hardcoded repo name; missing venv/package →
   readiness message in Settings, engine falls back to whisper with a
   visible message, never silently.

**Success criteria**
- [ ] A source transcribed with engine=qwen yields a sidecar the sheet,
      matcher and cutter consume with no code changes downstream.
- [ ] Anchored words display for takes whose spans have words (the
      MasterWantStone hole class disappears on re-transcription).
- [ ] Words in the sidecar carry end > start, monotonically ordered.
- [ ] Engine=whisper path byte-identical behavior to 0.15beta40.
- [ ] CUDA unavailable/OOM falls back to CPU with a message, run succeeds.
- [ ] `qwen_edge_bench.py` re-run against the new sidecars: no word head
      before AJ's item start on non-bleed takes.
- [ ] Tests cover the pure parts (argv/plan/parse) in `tests/`.

**Edge cases**
- Words the aligner drops (it aligns decoded text; a dropped token leaves
  a gap) → gap shows as hole, unheard scan still guards it.
- Non-English config → language passed through; only "English" validated
  for now.
- Sidecar written only on full success; partial runs leave the old file.

**Out of scope**
- Installer automation for the venv (follow-up; AJ's machine has it).
- Whisper server revival; streaming; flipping the default engine.
- Any change to Verify, suspects, or the audit stack.

**Assumptions**
- [assumed] Sources UI's progress protocol can host a second backend
  without UI redesign (it already abstracts the backend acquisition).
