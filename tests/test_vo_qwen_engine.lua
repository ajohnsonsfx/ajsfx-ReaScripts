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
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
