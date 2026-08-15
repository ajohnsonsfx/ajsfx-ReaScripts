-- Unit tests for vo.InboxBuild: every scanner's findings, one ranked list.
-- Run with: lua tests/test_vo_inbox.lua (from the repository root)

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

print("\n=== ajsfx_vo.lua Inbox Unit Tests ===\n")

print("InboxBuild:")

test("empty src builds empty inbox", function()
  local f, c = vo.InboxBuild({})
  assert(#f == 0, "expected no findings, got " .. #f)
  assert(c.total == 0, "expected zero count")
end)

test("nil src builds empty inbox", function()
  local f, c = vo.InboxBuild(nil)
  assert(#f == 0 and c.total == 0, "nil input errored or reported")
end)

test("selects-track suspects outrank everything", function()
  local f = vo.InboxBuild({
    unheard  = { { at = 1 } },
    suspects = { { name = "a" }, { name = "b", track = "Selects" } },
    parity_queue = { { key = "k" } },
    scanned  = { suspects = true, unheard = true },
    selects_track = "Selects",
  })
  assert(f[1].kind == "suspect_select", "expected suspect_select first, got " .. f[1].kind)
  assert(f[1].payload.name == "b", "wrong suspect promoted")
  assert(f[2].kind == "out_of_sync", "expected out_of_sync second, got " .. f[2].kind)
  assert(f[3].kind == "suspect", "expected plain suspect third, got " .. f[3].kind)
  assert(f[3].payload.name == "a", "wrong plain suspect")
  assert(f[4].kind == "unheard", "expected unheard last, got " .. f[4].kind)
end)

test("parity queue and disagreements both read as out_of_sync", function()
  local f, c = vo.InboxBuild({
    parity_queue = { { key = "q1" } },
    disagree     = { { key = "d1" }, { key = "d2" } },
    scanned = { suspects = true, unheard = true },
  })
  assert(c.by_kind.out_of_sync == 3, "expected 3 out_of_sync, got " .. tostring(c.by_kind.out_of_sync))
  assert(f[1].payload.key == "q1", "queue should precede disagreements")
end)

test("stale scanners emit one scan row each, at their kind's slot", function()
  local f = vo.InboxBuild({ scanned = { suspects = false, unheard = false } })
  assert(#f == 2, "expected two scan rows, got " .. #f)
  assert(f[1].kind == "scan_suspects", "suspects scan should come first, got " .. f[1].kind)
  assert(f[2].kind == "scan_unheard", "unheard scan should come last, got " .. f[2].kind)
end)

test("missing scanned table means nothing is stale", function()
  local f = vo.InboxBuild({ no_audio = { {} } })
  assert(#f == 1 and f[1].kind == "no_audio", "scan rows emitted without scanned flags")
end)

test("order within a kind is source order", function()
  local f = vo.InboxBuild({
    undecided = { { asset = "A_01" }, { asset = "A_02" } },
    scanned = { suspects = true, unheard = true },
  })
  assert(f[1].payload.asset == "A_01", "source order not preserved")
  assert(f[2].payload.asset == "A_02", "source order not preserved")
end)

test("full ranking spans every kind in spec order", function()
  local f = vo.InboxBuild({
    unheard = { { u = 1 } },
    undecided = { { asset = "A" } },
    unidentified = { { span = 1 } },
    no_audio = { { m = 1 } },
    disagree = { { d = 1 } },
    suspects = { { name = "s", track = "Selects" }, { name = "p" } },
    scanned = { suspects = true, unheard = true },
    selects_track = "Selects",
  })
  local kinds = {}
  for i, x in ipairs(f) do kinds[i] = x.kind end
  local want = { "suspect_select", "out_of_sync", "no_audio", "unidentified",
                 "undecided", "suspect", "unheard" }
  assert(#kinds == #want, "expected " .. #want .. " findings, got " .. #kinds)
  for i = 1, #want do
    assert(kinds[i] == want[i], ("slot %d: expected %s, got %s"):format(i, want[i], kinds[i]))
  end
end)

test("counts tally by kind", function()
  local _, c = vo.InboxBuild({
    disagree = { {}, {} }, no_audio = { {} },
    scanned = { suspects = true, unheard = true },
  })
  assert(c.total == 3, "expected total 3, got " .. c.total)
  assert(c.by_kind.out_of_sync == 2, "out_of_sync miscounted")
  assert(c.by_kind.no_audio == 1, "no_audio miscounted")
end)

test("payloads pass through untouched", function()
  local entry = { key = "k", divergence = { detail = "names disagree" } }
  local f = vo.InboxBuild({ parity_queue = { entry },
                            scanned = { suspects = true, unheard = true } })
  assert(f[1].payload == entry, "payload was copied or replaced, not passed through")
end)

--------------------------------
print(string.format("\n=== Results: %d passed, %d failed ===", passed, failed))
if failed > 0 then os.exit(1) end
