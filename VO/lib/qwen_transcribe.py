# ajsfx VO: transcribe one audio file with Qwen3-ASR + Qwen3-ForcedAligner,
# writing a word-level JSON sidecar the Lua side parses (vo.ParseQwenJSON).
#
# Run from the asr-qwen venv (vo.QwenPython resolves it):
#   python qwen_transcribe.py --audio <wav> --out <json>
#       [--device auto|cuda|cpu] [--language English]
#
# Contract with the Lua side:
# - stdout carries whisper-style "progress = NN%" lines so the existing log
#   tail (vo.RunWhisperAsync / vo.ParseWhisperProgressLine) keeps working.
# - The JSON is written only on full success; a failed run leaves no file.
# - Exit code 0 = success, anything else = the log tail is the error.
#
# WHY BURSTS, NOT THE WHOLE FILE (verified on ChristianBrently_Grumbar,
# 2026-08-15): a VO source is the same line read again and again, and on a
# minutes-long window that repetition defeats the aligner -- the decode
# carries the repeats but their timestamps collapse into zero-width words
# piled on one instant (825 of 1654 words on the first full-file run), with
# phrases landing on the wrong take. On pause-separated clips the same
# models were flawless against hand-approved cut edges. So the runner finds
# speech bursts by energy, decodes and aligns each burst on its own, and
# offsets the times -- the burst IS the unit this engine is good at.
#
# Device policy (the spec's `auto`): try CUDA, and on ANY cuda failure --
# import, load, or out-of-memory mid-run (the GPU is shared with ComfyUI) --
# reload on CPU and start the file over. CPU is a real mode.
import argparse
import json
import os
import subprocess
import sys
import time

import numpy as np

SR = 16000
FRAME_S = 0.05      # RMS frame
FLOOR_DB = -45.0    # below this is silence (matches the tool's Tighten floor)
JOIN_GAP_S = 0.4    # bursts closer than this merge into one. Deliberately
                    # SHORT: a VO source is the same line read back to back,
                    # and two reads sharing one burst invites the LLM decoder
                    # to dedup the repeat -- a read's words then land on its
                    # neighbour and one take span comes back empty (found
                    # live: Can/Can_alt1 1s apart, one decoded). A mid-phrase
                    # pause splitting a sentence costs nothing: each half
                    # aligns correctly on its own.
PAD_S = 0.25        # context kept around each burst
MIN_BURST_S = 0.25  # shorter than this is a click, not speech
MAX_BURST_S = 25.0  # longer bursts split at their quietest point
BATCH = 8           # bursts per transcribe() call; progress between batches
MIN_WORD_S = 0.02   # a "word" narrower than the alignment grid is collapse
                    # residue, dropped and counted

# SMEAR DEFENSE (found live on ChristianBrently_Grumbar, 2026-08-15, with
# script context on): when the decode emits text the burst's audio does not
# hold -- context hallucination is the usual source -- the aligner has no
# acoustics to pin it to and falls back to distributing the words EVENLY,
# sometimes past the burst's end into neighbouring takes' time ranges. Real
# speech is never metronomic, so uniformity IS the fingerprint: runs of
# words with near-identical durations or near-identical start gaps are
# alignment fiction, and anything past the burst's real length is spill.
SMEAR_TOL_S = 0.015     # "identical" duration/gap tolerance
SMEAR_DUR_RUN = 3       # >= this many equal-duration words (each >= 0.7s)
# Thresholds tuned against real Grumbar failures AND real Grumbar speech:
# a repeating actor rides the aligner's grid (4 words at a uniform 0.32s is
# a legitimate "That is my work"), and a SLOW read has uniform near-second
# START gaps ("Master want stone" at 0.88/0.88) -- so start-gap uniformity
# only convicts LONG runs. Equal DURATIONS are the strong signal: real
# aligned words vary in length; three-plus words of identical >= 0.7s
# duration ("want stone Old book" at 1.27s x4) are alignment fiction.
SMEAR_GAP_RUN = 6       # >= this many equal-START-gap words (gap >= 0.24s)
BURST_SLACK_S = 0.3     # words may overhang a burst by at most this


def log(msg):
    print(msg, flush=True)


def read_audio_16k(path):
    p = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-ac", "1", "-ar", str(SR),
         "-f", "f32le", "-"],
        capture_output=True, check=True)
    return np.frombuffer(p.stdout, dtype=np.float32)


def frame_db(x):
    hop = int(SR * FRAME_S)
    n = len(x) // hop
    if n == 0:
        return np.full(1, -150.0), hop
    frames = x[: n * hop].reshape(n, hop)
    rms = np.sqrt((frames * frames).mean(axis=1))
    return 20.0 * np.log10(rms + 1e-10), hop


def split_long(x, s, e, db, hop, out):
    if (e - s) <= MAX_BURST_S * SR:
        out.append((s, e))
        return
    # Split at the quietest frame in the middle half, recursing on both
    # sides -- never mid-word if any pause exists there at all.
    fs, fe = int(s / hop), int(e / hop)
    mid_lo = fs + (fe - fs) * 1 // 4
    mid_hi = fs + (fe - fs) * 3 // 4
    cut_f = mid_lo + int(np.argmin(db[mid_lo:mid_hi]))
    cut = cut_f * hop
    split_long(x, s, cut, db, hop, out)
    split_long(x, cut, e, db, hop, out)


def find_bursts(x):
    db, hop = frame_db(x)
    speech = db > FLOOR_DB
    spans = []
    start = None
    for i, on in enumerate(speech):
        if on and start is None:
            start = i
        elif not on and start is not None:
            spans.append((start * hop, i * hop))
            start = None
    if start is not None:
        spans.append((start * hop, len(x)))

    merged = []
    for s, e in spans:
        if merged and (s - merged[-1][1]) < JOIN_GAP_S * SR:
            merged[-1] = (merged[-1][0], e)
        else:
            merged.append((s, e))

    pad = int(PAD_S * SR)
    out = []
    for s, e in merged:
        if (e - s) < MIN_BURST_S * SR:
            continue
        split_long(x, max(0, s - pad), min(len(x), e + pad), db, hop, out)
    return out


def load_model(device):
    import torch
    from qwen_asr import Qwen3ASRModel

    dtype = torch.bfloat16
    log(f"loading Qwen3-ASR-1.7B + ForcedAligner-0.6B on {device}...")
    t0 = time.time()
    model = Qwen3ASRModel.from_pretrained(
        "Qwen/Qwen3-ASR-1.7B",
        dtype=dtype,
        device_map=device,
        max_new_tokens=448,
        forced_aligner="Qwen/Qwen3-ForcedAligner-0.6B",
        forced_aligner_kwargs={"dtype": dtype, "device_map": device},
    )
    log(f"loaded in {time.time() - t0:.1f}s")
    return model


def strip_smears(items, burst_dur):
    """items: [(t0, t1, text)] local to one burst, time-ordered.
    Returns (kept, n_dropped): spill past the burst and uniform-cadence
    runs removed."""
    items = [it for it in items
             if it[0] <= burst_dur + BURST_SLACK_S]
    items = [(t0, min(t1, burst_dur + BURST_SLACK_S), tx)
             for t0, t1, tx in items]
    n = len(items)
    bad = [False] * n

    i = 0
    while i < n:                     # equal-duration runs of long words
        j = i
        d0 = items[i][1] - items[i][0]
        while j + 1 < n and abs((items[j + 1][1] - items[j + 1][0]) - d0) < SMEAR_TOL_S:
            j += 1
        if (j - i + 1) >= SMEAR_DUR_RUN and d0 >= 0.7:
            for k in range(i, j + 1):
                bad[k] = True
        i = j + 1

    i = 0
    while i + 1 < n:                 # equal-gap runs
        g0 = items[i + 1][0] - items[i][0]
        j = i
        while j + 1 < n and abs((items[j + 1][0] - items[j][0]) - g0) < SMEAR_TOL_S:
            j += 1
        run = j - i + 1
        if run >= SMEAR_GAP_RUN and g0 >= 0.24:
            for k in range(i, j + 1):
                bad[k] = True
        i = max(j, i + 1)

    kept = [it for k, it in enumerate(items) if not bad[k]]
    return kept, (n - len(kept))


def run(model, x, bursts, language, context):
    words, dropped, smeared = [], 0, 0
    done = 0
    for b0 in range(0, len(bursts), BATCH):
        batch = bursts[b0:b0 + BATCH]
        audio = [(x[s:e], SR) for s, e in batch]
        results = model.transcribe(
            audio=audio, language=language, context=context,
            return_time_stamps=True)
        for (s, e), res in zip(batch, results):
            off = s / SR
            items = []
            for it in res.time_stamps or []:
                text = (it.text or "").strip()
                t0 = float(it.start_time)
                t1 = float(it.end_time)
                if not text:
                    continue
                if (t1 - t0) < MIN_WORD_S:
                    dropped += 1
                    continue
                items.append((t0, t1, text))
            items.sort(key=lambda it: it[0])
            kept, n_smear = strip_smears(items, (e - s) / SR)
            smeared += n_smear
            for t0, t1, text in kept:
                words.append({
                    "t0": round(off + t0, 3),
                    "t1": round(off + t1, 3),
                    "text": text,
                })
        done += len(batch)
        log(f"progress = {int(100 * done / max(1, len(bursts)))}%")
    return words, dropped, smeared


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--device", default="auto",
                    choices=["auto", "cuda", "cpu"])
    ap.add_argument("--language", default="English")
    # The session's script lines, one per line: Qwen3-ASR biases its decode
    # toward this text, recovering invented words and non-fluent register a
    # blind decode auto-corrects. Assignment reads the script; the tool's
    # Verify/audit layers deliberately never pass this.
    ap.add_argument("--context-file", default="")
    args = ap.parse_args()

    if not os.path.isfile(args.audio):
        log(f"error: no such audio file: {args.audio}")
        return 2

    context = ""
    if args.context_file:
        with open(args.context_file, encoding="utf-8") as f:
            context = f.read().strip()
        if len(context) > 12000:
            log(f"context trimmed from {len(context)} to 12000 chars")
            context = context[:12000]
        log(f"script context: {len(context)} chars")

    import torch

    log("progress =   0%")
    x = read_audio_16k(args.audio)
    bursts = find_bursts(x)
    log(f"{len(x) / SR:.1f}s of audio, {len(bursts)} speech burst(s)")
    if not bursts:
        log("error: no speech found above the energy floor")
        return 1

    if args.device == "auto":
        tries = ["cuda", "cpu"] if torch.cuda.is_available() else ["cpu"]
    else:
        tries = [args.device]

    last_err = None
    for device in tries:
        try:
            model = load_model(device)
            t0 = time.time()
            words, dropped, smeared = run(model, x, bursts, args.language,
                                          context)
            log(f"decoded + aligned in {time.time() - t0:.1f}s on {device}"
                + (f", dropped {dropped} zero-width word(s)" if dropped else "")
                + (f", stripped {smeared} smeared word(s)" if smeared else ""))
            doc = {
                "engine": "qwen3-asr-1.7b+forced-aligner-0.6b",
                "device": device,
                "language": args.language,
                "context_chars": len(context),
                "bursts": len(bursts),
                "dropped_zero_width": dropped,
                "stripped_smears": smeared,
                "words": words,
            }
            tmp = args.out + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(doc, f, ensure_ascii=False)
            os.replace(tmp, args.out)
            log("progress = 100%")
            log(f"wrote {len(words)} word(s) to {args.out}")
            return 0
        except Exception as e:  # noqa: BLE001 -- any cuda failure falls back
            last_err = e
            log(f"{device} failed: {type(e).__name__}: {e}")
            if device != tries[-1]:
                log("falling back to cpu")
                try:
                    torch.cuda.empty_cache()
                except Exception:
                    pass
    log(f"error: transcription failed: {last_err}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
