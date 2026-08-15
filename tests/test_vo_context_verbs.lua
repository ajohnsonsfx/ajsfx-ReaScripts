-- Unit tests for vo.ContextVerbs: the selection decides the verbs.
-- Run with: lua tests/test_vo_context_verbs.lua (from the repository root)

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

print("\n=== ajsfx_vo.lua Context Verbs Unit Tests ===\n")

print("ContextVerbs:")

local function ids(sel)
  return table.concat(vo.ContextVerbs(sel), ",")
end

test("recordings get match, cut and untrack, in order", function()
  assert(ids({ recordings = 1 }) == "match,cut,untrack",
    "got: " .. ids({ recordings = 1 }))
end)

test("takes get the fix, judge and pick verbs", function()
  assert(ids({ takes = 3 })
           == "fix_from,verify,recut,pick_first,pick_last,name_alts,untrack",
    "got: " .. ids({ takes = 3 }))
end)

test("takes and lines share the pick verbs", function()
  assert(ids({ takes = 1, lines = 1 }) == "pick_first,pick_last,name_alts",
    "got: " .. ids({ takes = 1, lines = 1 }))
end)

test("ok is deliberately NOT a bar verb -- it lives on the take row's box", function()
  for _, v in ipairs(vo.ContextVerbs({ takes = 1 })) do
    assert(v ~= "ok", "ok crept back into the takes context")
  end
end)

test("lines get the pick verbs", function()
  assert(ids({ lines = 2 }) == "pick_first,pick_last,name_alts",
    "got: " .. ids({ lines = 2 }))
end)

test("mixed recording and takes intersect to untrack", function()
  assert(ids({ recordings = 1, takes = 2 }) == "untrack",
    "got: " .. ids({ recordings = 1, takes = 2 }))
end)

test("empty selection is empty", function()
  assert(#vo.ContextVerbs({}) == 0, "empty selection produced verbs")
end)

test("nil selection is empty, not an error", function()
  assert(#vo.ContextVerbs(nil) == 0, "nil selection errored or produced verbs")
end)

test("zero counts are not a context", function()
  assert(ids({ recordings = 0, takes = 2 })
           == "fix_from,verify,recut,pick_first,pick_last,name_alts,untrack",
    "a zero count changed the verbs: " .. ids({ recordings = 0, takes = 2 }))
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
