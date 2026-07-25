# ajsfx VO — Backend & Model Acquisition — Design Spec

**Status:** Draft for review · **Version:** 0.1 · **Date:** 2026-07-22

Add in-Settings acquisition of the speech backend to **ajsfx VO ScriptMatch**: download a
GPU-capable `whisper-cli` binary and the ggml model weights directly from the settings
panel, and report whether the backend is actually running on the GPU. Today the user must
find, download, and wire up both by hand (`VO/MANUAL_TEST.md` §0); this closes that gap
without weakening the tool's local-only privacy guarantee.

This spec extends `VO/SPEC.md`; it does not replace it. Terms and layers (pure vs
REAPER-coupled) are used as defined there.

---

## 1. Goals and non-goals

### Goals

- Download a **GPU (CUDA) `whisper-cli` build** from within Settings and wire `whisper_bin`
  to the extracted executable automatically.
- Download a **ggml model** from within Settings and wire `whisper_model` automatically.
- **Report the active compute backend** (CUDA + device name, or CPU) so the user can
  confirm the GPU is engaged rather than silently falling back to CPU.
- Keep everything local-only in spirit: the only network traffic is *outbound GET* of
  public binaries/weights. **No audio and no dialogue text is ever transmitted**, and the
  matching path stays free of network code (unchanged from `VO/SPEC.md` §11).
- Restrict choices to a small, appropriate, verified set.

### Non-goals (this iteration)

- **Building whisper.cpp from source.** The prebuilt CUDA binary is downloaded as-is. Users
  who want a binary linked against a specific CUDA toolkit build their own and use **Browse**
  (unchanged).
- **Installing or updating the NVIDIA driver.** Out of scope; the tool detects and reports,
  it does not manage drivers.
- **Matching the user's system CUDA toolkit.** Prebuilt cublas binaries bundle their own CUDA
  runtime DLLs and depend only on the NVIDIA driver — see §3. The system toolkit is not used.
- **CPU/BLAS/Vulkan/Metal backends, or non-Windows binary download.** The binary downloader
  targets Windows + NVIDIA CUDA only. Model download is cross-platform. Non-Windows users
  keep the existing Browse flow for the binary.
- **English-only (`.en`) models.** Excluded because their `-dtw` presets are unverified
  (`VO/SPEC.md` §10) and this tool depends on sharp word boundaries for cutting.

---

## 2. Verified facts this design rests on

Confirmed during design (2026-07-22), not assumed:

1. **GPU support in whisper.cpp is compile-time, not runtime.** A CPU build cannot be made to
   use the GPU by any flag or by installing the CUDA toolkit. GPU comes from a CUDA-compiled
   `whisper-cli.exe`. Ref: whisper.cpp issue #2857 (CUDA toolkit installed, `CUBLAS = 0`,
   because the binary was CPU-only).
2. **Prebuilt cublas binaries bundle their CUDA runtime DLLs** next to the exe and depend only
   on a sufficiently new **NVIDIA driver** (drivers are forward-compatible: a newer driver runs
   an older CUDA runtime). The system CUDA toolkit is irrelevant to running them.
3. **Model `.bin` files are backend-agnostic.** The same `ggml-base.bin` runs on CPU or GPU;
   the binary, not the model, determines device use.
4. **Real release assets** (whisper.cpp `v1.9.1`, verified via GitHub API):
   - `whisper-cublas-12.4.0-bin-x64.zip` — **677,887,125 bytes** —
     `https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-cublas-12.4.0-bin-x64.zip`
   - `whisper-cublas-11.8.0-bin-x64.zip` — **278,557,654 bytes** —
     `https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-cublas-11.8.0-bin-x64.zip`
5. **Model download base** (HuggingFace `ggerganov/whisper.cpp`, same repo the panel already
   links to): `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-<name>.bin`.

---

## 3. Decisions (settled)

- **GPU acquisition:** download the **prebuilt CUDA 12.4 build** (`v1.9.1`). It uses its
  bundled runtime + the user's driver; no source build, no toolkit dependency.
- **Binary lineup:** CUDA **12.4** (default) and CUDA **11.8** (lighter fallback for older
  drivers). Both from the pinned release.
- **Release pin:** **`v1.9.1`**, hard-coded in the catalog. Not "latest" — a silent asset
  rename in a future release would break the download; bumping the pin is a deliberate,
  testable change.
- **Model lineup:** multilingual, DTW-verified only — `base`, `small`, `medium`, `large-v3`.
- **Storage:** under the plugin's own folder — `<Scripts>/<repo>/Resources/`, with
  binaries in `whisper-bin/` and models in `whisper-models/`. The repo folder is
  derived from the VO script's install path (never hardcoded), mirroring how PVX
  locates its venv. Keeps downloads contained and uninstalling with the package.
- **Exe resolution:** after extraction, **glob** the target dir for `whisper-cli.exe` rather
  than hard-coding a path inside the zip (the internal name/layout is confirmed on first run,
  not guessed — see §9).
- **GPU report:** a pure log parser plus a "Check device" probe button; the readout is shown
  in the backend section.

---

## 4. Architecture

Follows `VO/SPEC.md`'s split: a **pure layer** (unit-testable, no REAPER, no network) and a
thin **REAPER-coupled layer** (subprocess, extraction, ImGui). All new pure functions live in
`VO/lib/ajsfx_vo.lua` and are covered by `tests/test_vo.lua`.

### 4.1 Pure layer (new)

| Function | Purpose |
|---|---|
| `vo.MODEL_CATALOG` | Ordered list; each: `name`, `filename` (`ggml-<name>.bin`), `label`, `approx_size`, `expected_bytes`, `dtw` preset. Single source of truth; stays consistent with `vo.DTW_PRESETS` by construction (a unit test asserts every catalog model has a preset). |
| `vo.BINARY_CATALOG` | Ordered list of the two cublas builds: `key`, `release_tag`, `asset`, `url`, `expected_bytes`, `label`. |
| `vo.ModelDownloadURL(name)` | → HuggingFace resolve URL (§2.5). |
| `vo.BinaryDownloadURL(key)` | → GitHub release asset URL (§2.4). |
| `vo.PluginResourceRoot(script_dir)` | → `<Scripts>/<repo>/Resources` from the VO script dir (repo name not hardcoded). |
| `vo.ResolveModelsDir(root)` | → `<root>/whisper-models` (path only; creation is REAPER-side). |
| `vo.ResolveBinDir(root)` | → `<root>/whisper-bin`. |
| `vo.ModelIsInstalled(dir, name)` | File exists and passes the size floor. |
| `vo.VerifyDownloadSize(path, expected)` | True when actual ≥ ~95% of `expected` — catches truncated pulls and HTML error pages saved as `.bin`/`.zip`. |
| `vo.LocateWhisperCliExe(entries)` | Given a flat list of extracted file paths, return the `whisper-cli.exe` path (case-insensitive), or nil. Pure over an injected listing so it is unit-testable. |
| `vo.ParseBackendFromLog(text)` | → `{device="CUDA", name="NVIDIA ..."}` or `{device="CPU"}`. Pattern set confirmed against real output on first run (§9). |
| `vo.FormatBytes(n)` | Human-readable sizes for the UI. |

### 4.2 REAPER-coupled layer (new)

- **`vo.RunDownloadAsync(cfg, url, dest_path, expected_bytes, on_done, on_cancel, on_error)`** —
  detached `curl -L --fail -o <dest>` via the **same two-file launch pattern** as
  `vo.RunWhisperAsync` (`.bat` + `.vbs` on Windows), with an ImGui progress window (spinner,
  label, elapsed, working **Cancel** that kills `curl`) and the same done-file polling. Shared
  by both the model and binary downloads. **Deliberately parallel to `RunWhisperAsync`, not a
  refactor of it** — `VO/SPEC.md` §11 defers extracting a shared runner until both paths are
  exercised in REAPER; cloning the proven pattern honors that.
- **`vo.ExtractZip(zip_path, dest_dir)`** — `tar -xf` (Windows 10+ bundles bsdtar, which reads
  zip) with a PowerShell `Expand-Archive` fallback. Returns the extracted file listing for
  `LocateWhisperCliExe`.
- **`vo.ProbeBackendDevice(cfg, on_result)`** — whisper.cpp only initializes its compute
  device when a model loads for inference, so there is no reliable "list devices" mode to call.
  The probe therefore runs a **real but tiny** transcription: the configured model over a
  short generated silent WAV (written to the scratch dir), captured log parsed by
  `ParseBackendFromLog`. It **requires a model to be installed** (surfaced in the UI — see §5).
  The same parse is also applied automatically to the log of the first *real* transcription
  run, so a normal session updates the Device readout without an explicit probe.

### 4.3 Flows

**Binary:** pick build → confirm (size + one-time note) → `RunDownloadAsync` zip into
`whisper-bin/` → `VerifyDownloadSize` → `ExtractZip` → `LocateWhisperCliExe` → set
`cfg.whisper_bin`, save → `ProbeBackendDevice` → show **Device:** result.

**Model:** pick model → if present, button reads **"Use downloaded"** (just set
`cfg.whisper_model`); else **"Download"** → `RunDownloadAsync` into `whisper-models/` →
`VerifyDownloadSize` → set `cfg.whisper_model`, save. Existing **Backend ready** indicator
flips green once both paths are valid.

---

## 5. UI (`ajsfx_VO_Settings.lua`, in `DrawBackend`)

New "Backend & models" block below the existing path fields, above the browser link:

- **GPU binary:** dropdown (`vo.BINARY_CATALOG`, default CUDA 12.4, size in label) + **Get**.
  Disabled on non-Windows with a one-line explanation (use Browse).
- **Model:** dropdown (`vo.MODEL_CATALOG`, size in label, ✓ when already installed) +
  **Get** / **Use downloaded**.
- **Device:** readout line (`Device: CUDA — <name>` / `Device: CPU` / `Device: unknown —
  run Check`) + **Check device** button. Check is disabled until both a binary and a model are
  set (the probe needs a model to load — see §4.2), with a one-line hint saying so.
- The existing **Browse** fields and **Backend ready** indicator remain unchanged.

Existing ImGui contracts from `.agents/standards.md` apply (always `End` after `Begin`, etc.).

---

## 6. Honesty & caveats shown in-panel

- Network note updated to name both hosts: "Downloads contact github.com (whisper-cli) and
  huggingface.co (model weights) to fetch public files. No audio or dialogue text is ever
  sent, and matching contains no network code."
- GPU note: "The GPU build needs a recent NVIDIA driver. Use **Check device** to confirm CUDA
  is active — if it shows CPU, your driver or GPU may be too old for this build."
- One-time note that a freshly downloaded `.exe` may trip Windows SmartScreen/antivirus once.

---

## 7. Error handling

Every failure shows a clear message and **changes nothing** (no half-set paths):

- `curl` missing (pre-1803 Windows) → message + fall back to the existing "open in browser".
- Download fails / non-zero curl exit → report exit + log tail; leave paths untouched.
- Size verification fails → treat as failed download; delete the partial file; do not set path.
- Extraction fails, or `whisper-cli.exe` not found in the archive → report; leave paths
  untouched.
- **Cancel** mid-download → kill `curl`, remove the partial file, "Nothing was changed."
- `ProbeBackendDevice` returns CPU with a CUDA binary → show it plainly (this is the
  issue-#2857 case) and point at the driver/GPU-arch caveat.

---

## 8. Testing

**Automated (`tests/test_vo.lua`, headless):**
- `MODEL_CATALOG` / `BINARY_CATALOG` integrity — every model has a DTW preset and sizes;
  URLs match the documented patterns; binary `expected_bytes` match §2.4.
- `ModelDownloadURL` / `BinaryDownloadURL` exact output.
- `ResolveModelsDir` / `ResolveBinDir` shape.
- `ModelIsInstalled` / `VerifyDownloadSize` — pass, truncated-fail, HTML-page-fail, missing.
- `LocateWhisperCliExe` — found (mixed case, nested), not found, empty listing.
- `ParseBackendFromLog` — CUDA-with-device, CPU, and ambiguous/empty inputs, using **sample
  log snippets** captured from real output.
- `FormatBytes` — boundaries (B/KB/MB/GB).

**Manual (`VO/MANUAL_TEST.md`, new sections — REAPER + hardware, cannot run headless):**
- Binary download → extract → auto-locate exe → path set.
- **GPU probe on the user's actual card** → Device shows CUDA + name.
- Model download → auto-select → Backend ready green.
- Cancel mid-download leaves nothing changed; truncated file is rejected by the size check.

---

## 9. Explicitly unverified (confirmed on first real run, not guessed)

Same discipline as `VO/SPEC.md` §10:

- **The exe filename/layout inside the `v1.9.1` cublas zip.** Design globs for
  `whisper-cli.exe`; first extraction confirms the name and that DLLs sit beside it.
- **Whether the CUDA 12.4 build supports the user's specific GPU compute architecture.**
  `ProbeBackendDevice` is exactly how this is confirmed after download.
- **The precise backend-detection log strings** `ParseBackendFromLog` keys on. Written against
  real captured output in the first manual run; the parser's unit tests encode whatever that
  turns out to be.
- **`curl` and `tar` availability** on the target machine (both ship with Windows 10 ≥ 1803,
  but the fallbacks in §7 cover their absence).
- **Model `expected_bytes` are approximate** (well-known ggml sizes), used only as the
  truncation floor in `VerifyDownloadSize` (≥ ~95%), and refined against the HTTP
  `Content-Length` on the first successful download. The binary `expected_bytes` are exact
  (§2.4, verified via the GitHub API).

---

## 10. Versioning & release

Per `.agents/standards.md`: bump `@version` and add `@changelog` on the **ScriptMatch**
package (the only indexed script; `Settings` is `@noindex`, shipped via `@provides`) and on the
`@noindex` library header. `index.xml` is never hand-edited; CI rebuilds it on merge to `main`.

---

## 11. References

- whisper.cpp `v1.9.1` releases (asset URLs/sizes in §2.4) — https://github.com/ggml-org/whisper.cpp/releases
- Issue #2857 (CUDA toolkit installed but binary CPU-only) — https://github.com/ggml-org/whisper.cpp/issues/2857
- ggml model weights — https://huggingface.co/ggerganov/whisper.cpp
