-- Unit tests for the Qwen engine's pure parts: argv builder, JSON parser,
-- venv resolution, config schema defaults.
-- Run with: lua tests/test_vo_qwen_engine.lua (from the repository root)

local passed = 0
local failed = 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  PASS: " .. name)
  else
    failed = failed + 1
    print("  FAIL: " .. name .. " - " .. tostring(err))
  end
end

package.path = package.path .. ";VO/lib/?.lua;tests/?.lua"
local mock = require("mock_reaper")
mock.reset()
local vo = require("ajsfx_vo")

print("\n=== ajsfx_vo.lua Qwen Engine Unit Tests ===\n")

print("BuildQwenArgv:")

test("argv carries runner, audio, out and device", function()
  local argv = vo.BuildQwenArgv({ qwen_device = "cuda" }, "python.exe",
                                "in.wav", "out.json")
  assert(argv[1] == "python.exe")
  assert(argv[2]:find("qwen_transcribe%.py$"), "runner path missing")
  local flat = table.concat(argv, " ")
  assert(flat:find("--audio in.wav", 1, true), "audio missing")
  assert(flat:find("--out out.json", 1, true), "out missing")
  assert(flat:find("--device cuda", 1, true), "device missing")
end)

test("device defaults to auto", function()
  local argv = vo.BuildQwenArgv({}, "py", "a.wav", "o.json")
  assert(table.concat(argv, " "):find("--device auto", 1, true))
end)

test("a context file is passed through; none means no flag", function()
  local with = vo.BuildQwenArgv({}, "py", "a.wav", "o.json", "ctx.txt")
  assert(table.concat(with, " "):find("--context-file ctx.txt", 1, true))
  local without = vo.BuildQwenArgv({}, "py", "a.wav", "o.json", nil)
  assert(not table.concat(without, " "):find("--context-file", 1, true))
end)

test("WriteQwenContext dedupes lines and round-trips; empty removes", function()
  local cfg = { scratch_dir = "tests" }
  local path = vo.WriteQwenContext(cfg, {
    { text = " Master want stone. " },
    { text = "Master want stone." },      -- duplicate after trim
    { text = "Tower loud." },
    { text = "" },
  })
  assert(path, "no path returned")
  local f = assert(io.open(path, "r"))
  local body = f:read("a")
  f:close()
  assert(body == "Master want stone.\nTower loud.", "got: " .. body)
  assert(vo.WriteQwenContext(cfg, {}) == nil, "empty lines must return nil")
  assert(io.open(path, "r") == nil, "empty lines must remove the file")
end)

test("the 'en' code is NOT passed through as a language", function()
  -- qwen-asr validates full names ("English"); the whisper default "en"
  -- would be a hard error, so it means "engine default" here.
  local argv = vo.BuildQwenArgv({ whisper_language = "en" }, "py", "a", "o")
  assert(not table.concat(argv, " "):find("--language", 1, true),
         "passed 'en' through")
end)

test("a full language name is passed through", function()
  local argv = vo.BuildQwenArgv({ whisper_language = "German" }, "py", "a", "o")
  assert(table.concat(argv, " "):find("--language German", 1, true))
end)

print("ParseQwenJSON:")

test("words parse with anchor equal to t0", function()
  local words, meta = vo.ParseQwenJSON(
    '{"engine":"qwen3","device":"cpu","language":"English","text":"Hi there",'
    .. '"words":[{"t0":0.5,"t1":0.9,"text":"Hi"},'
    .. '{"t0":1.0,"t1":1.6,"text":"there"}]}')
  assert(#words == 2, "expected 2 words, got " .. #words)
  assert(words[1].t0 == 0.5 and words[1].t1 == 0.9)
  assert(words[1].anchor == 0.5, "anchor should be t0")
  assert(words[2].text == "there")
  assert(meta.device == "cpu" and meta.language == "English")
end)

test("blank and malformed words are dropped", function()
  local words = vo.ParseQwenJSON(
    '{"words":[{"t0":0.1,"t1":0.2,"text":"  "},'
    .. '{"t0":"x","t1":0.2,"text":"bad"},'
    .. '{"t0":0.3,"t1":0.4,"text":"ok"}]}')
  assert(#words == 1 and words[1].text == "ok")
end)

test("not JSON at all returns an empty list", function()
  assert(#vo.ParseQwenJSON("whisper log tail, not json") == 0)
  assert(#vo.ParseQwenJSON(nil) == 0)
end)

print("QwenPython / QwenReady:")

test("explicit cfg.qwen_python wins", function()
  assert(vo.QwenPython({ qwen_python = "C:/x/python.exe" })
         == "C:/x/python.exe")
end)

test("default path resolves under Resources/asr-qwen", function()
  local p = vo.QwenPython({})
  assert(p and p:find("Resources/asr-qwen/venv", 1, true), tostring(p))
end)

test("missing python is reported, not invented", function()
  local ok, why = vo.QwenReady({ qwen_python = "Z:/nope/python.exe" })
  assert(ok == false)
  assert(why:find("Z:/nope/python.exe", 1, true), "reason must name the path")
end)

print("Config schema:")

test("engine defaults to whisper; qwen fields present", function()
  local d = {}
  for _, e in ipairs(vo.CONFIG_SCHEMA) do d[e.key] = e.default end
  assert(d.transcribe_engine == "whisper", "default engine must stay whisper")
  assert(d.qwen_device == "auto")
  assert(d.qwen_python == "")
  assert(d.qwen_context == "script", "context defaults to the script")
end)

print("TranscriptBackendMeta:")

test("whisper stamps whisper.cpp and its model path", function()
  local m = vo.TranscriptBackendMeta({
    whisper_model = "C:/models/ggml-large-v3.bin", whisper_language = "en" })
  assert(m.backend == "whisper.cpp", "backend was " .. tostring(m.backend))
  assert(m.model == "C:/models/ggml-large-v3.bin")
  assert(m.language == "en")
end)

test("no engine set behaves as whisper", function()
  assert(vo.TranscriptBackendMeta({}).backend == "whisper.cpp")
  assert(vo.TranscriptBackendMeta(nil).backend == "whisper.cpp")
end)

test("qwen never borrows whisper's backend or model", function()
  local m = vo.TranscriptBackendMeta({
    transcribe_engine = "qwen",
    whisper_model     = "C:/models/ggml-large-v3.bin",
    whisper_language  = "en",
  })
  assert(m.backend == "qwen-asr", "backend was " .. tostring(m.backend))
  assert(not m.model:find("ggml", 1, true), "qwen must not claim a whisper model")
  assert(m.model:find(tostring(vo.QWEN_RUNNER_VERSION), 1, true),
         "runner version must be recorded")
  assert(m.language == "en")
end)

test("script context is recorded, and its absence too", function()
  local with = vo.TranscriptBackendMeta({ transcribe_engine = "qwen" })
  assert(with.model:find("script%-context"), "default context must be stamped")
  local without = vo.TranscriptBackendMeta({
    transcribe_engine = "qwen", qwen_context = "off" })
  assert(not without.model:find("script%-context"),
         "a blind decode must not claim context")
end)

print("ProjectSourceFingerprint:")

test("track count and sources both matter", function()
  local a = vo.ProjectSourceFingerprint(1, { "a.wav" })
  assert(a ~= vo.ProjectSourceFingerprint(2, { "a.wav" }), "track count ignored")
  assert(a ~= vo.ProjectSourceFingerprint(1, { "b.wav" }), "source ignored")
  assert(a == vo.ProjectSourceFingerprint(1, { "a.wav" }), "not stable")
end)

test("order does not change the fingerprint", function()
  assert(vo.ProjectSourceFingerprint(2, { "a.wav", "b.wav" })
      == vo.ProjectSourceFingerprint(2, { "b.wav", "a.wav" }))
end)

test("an empty project has a fingerprint rather than nil", function()
  assert(type(vo.ProjectSourceFingerprint(0, {})) == "string")
  assert(vo.ProjectSourceFingerprint(0, {}) == vo.ProjectSourceFingerprint(0, nil))
end)

print("IsSaveAs:")

test("same audio, no sidecar at the new path, is a save-as", function()
  local fp = vo.ProjectSourceFingerprint(1, { "a.wav" })
  assert(vo.IsSaveAs(fp, fp, false) == true)
end)

test("different audio is a different project, never a save-as", function()
  local a = vo.ProjectSourceFingerprint(1, { "Carcas_Cleaned.wav" })
  local b = vo.ProjectSourceFingerprint(1, { "Job_Cleaned.wav" })
  assert(vo.IsSaveAs(a, b, false) == false,
         "opening another project into the tab must not carry state")
end)

test("a sidecar already at the new path is never overwritten", function()
  local fp = vo.ProjectSourceFingerprint(1, { "a.wav" })
  assert(vo.IsSaveAs(fp, fp, true) == false,
         "an existing sidecar must be read, not clobbered")
end)

test("an unknown previous fingerprint is not a save-as", function()
  assert(vo.IsSaveAs(nil, vo.ProjectSourceFingerprint(1, { "a.wav" }), false)
         == false)
end)

test("two empty projects are told apart by the sidecar guard", function()
  -- Both fingerprints are the empty-project string, so the audio cannot
  -- separate them; the sidecar existing is what stops the clobber.
  local e = vo.ProjectSourceFingerprint(0, {})
  assert(vo.IsSaveAs(e, e, true) == false)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
