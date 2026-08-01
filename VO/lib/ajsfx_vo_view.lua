-- @noindex
-- Presentation settings for the ajsfx VO Overview table.
--
-- Everything here is pure but for ExtState: no ImGui, no project state. The
-- window's LOOK — which column wraps, how tall its rows sit, what size it draws
-- at — is a property of the user, not of the session, so it lives in ExtState
-- and is shared by every project.
--
-- Deliberately NOT part of vo.CONFIG_SCHEMA: that schema drives the ScriptMatch
-- Settings dialog and describes matching. Nothing in this file affects a match.

local r = reaper

local view = {}

-- Shared with ajsfx_vo.lua's EXT_SECTION. Repeated rather than required so this
-- module stays loadable on its own, which is what makes it testable.
view.SECTION = "ajsfx_vo"

view.ALIGNS    = { "top", "middle", "bottom" }
view.ALIGN_SET = { top = true, middle = true, bottom = true }

view.FONT_KEYS = { "small", "medium", "large" }
view.FONT_SET  = { small = true, medium = true, large = true }

-- 6 is the smallest size that still renders legibly at 100% scaling; 48 is well
-- past any use for a table and stops a typo turning one row into a screenful.
view.FONT_MIN, view.FONT_MAX = 6, 48

-- Medium is 13 because that is what the table already draws at, so a user who
-- never opens Settings sees no change.
view.FONT_DEFAULTS = { small = 11, medium = 13, large = 16 }

view.DEFAULT_ALIGN = "middle"
view.DEFAULT_FONT  = "medium"

-- The one column long enough to be worth wrapping out of the box. Everything
-- else is a name, a number or a status and reads better clipped to one line.
view.WRAP_DEFAULTS = { line_text = true }

local ALIGN_FACTOR = { top = 0, middle = 0.5, bottom = 1 }

-- -----------------------------------------------------------------------
-- Pure helpers
-- -----------------------------------------------------------------------

-- ExtState hands back strings, and a user can type anything into the size
-- fields, so this accepts both and never errors.
function view.ClampFontSize(n, fallback)
  local size = tonumber(n)
  if not size then return fallback end
  size = math.floor(size)
  if size < view.FONT_MIN then return view.FONT_MIN end
  if size > view.FONT_MAX then return view.FONT_MAX end
  return size
end

-- How far down a cell of height `cell_h` sits in a row of height `row_h`.
-- Clamped at zero: a cell taller than its row (a wrapped cell that decided the
-- row height in the first place) must not be pushed above the row's top.
function view.AlignOffset(row_h, cell_h, align)
  local factor = ALIGN_FACTOR[align]
  if not factor then factor = ALIGN_FACTOR[view.DEFAULT_ALIGN] end
  local slack = (row_h or 0) - (cell_h or 0)
  if slack <= 0 then return 0 end
  return math.floor(slack * factor)
end

-- A column's settings with every unrecognised value replaced by its default.
-- `raw` may be nil, partial, or hand-edited nonsense from ExtState.
function view.NormalizeColumn(key, raw)
  raw = raw or {}
  local wrap
  if raw.wrap == nil then
    wrap = view.WRAP_DEFAULTS[key] == true
  else
    wrap = raw.wrap == true
  end
  return {
    align = view.ALIGN_SET[raw.align] and raw.align or view.DEFAULT_ALIGN,
    wrap  = wrap,
    font  = view.FONT_SET[raw.font] and raw.font or view.DEFAULT_FONT,
  }
end

-- -----------------------------------------------------------------------
-- Persistence
-- -----------------------------------------------------------------------

local function Get(key)
  local v = r.GetExtState(view.SECTION, key)
  if v == "" then return nil end
  return v
end

local function Set(key, value)
  r.SetExtState(view.SECTION, key, tostring(value), true)
end

local function ColumnKey(key, field) return "view_col_" .. key .. "_" .. field end

function view.LoadColumn(key)
  -- nil (never saved) is not the same as "0" (saved as off): only the second
  -- may override a wrapping default. Written out rather than as
  -- `saved and (raw == "1") or nil`, which is the classic Lua and/or trap —
  -- that collapses a stored false back to nil and loses the distinction.
  local wrap_raw = Get(ColumnKey(key, "wrap"))
  local wrap = nil
  if wrap_raw ~= nil then wrap = (wrap_raw == "1") end

  return view.NormalizeColumn(key, {
    align = Get(ColumnKey(key, "align")),
    wrap  = wrap,
    font  = Get(ColumnKey(key, "font")),
  })
end

function view.SaveColumn(key, col)
  local c = view.NormalizeColumn(key, col)
  Set(ColumnKey(key, "align"), c.align)
  Set(ColumnKey(key, "wrap"), c.wrap and "1" or "0")
  Set(ColumnKey(key, "font"), c.font)
end

function view.ClearColumns(keys)
  for _, key in ipairs(keys or {}) do
    for _, field in ipairs({ "align", "wrap", "font" }) do
      r.DeleteExtState(view.SECTION, ColumnKey(key, field), true)
    end
  end
end

function view.LoadRestore()
  -- Absent means on. Remembering a layout is the behaviour a user expects
  -- without asking for it, so the box starts ticked.
  return Get("view_restore") ~= "0"
end

function view.SaveRestore(on)
  Set("view_restore", on and "1" or "0")
end

-- Line text and Transcript pinned to one another. Off by default: it is a
-- reading aid for people who compare the two, not something to spring on
-- someone who has set the columns up differently on purpose.
function view.LoadMirror()
  return Get("view_mirror_text") == "1"
end

function view.SaveMirror(on)
  Set("view_mirror_text", on and "1" or "0")
end

function view.LoadFontSizes()
  local out = {}
  for _, k in ipairs(view.FONT_KEYS) do
    out[k] = view.ClampFontSize(Get("view_font_" .. k), view.FONT_DEFAULTS[k])
  end
  return out
end

function view.SaveFontSizes(sizes)
  sizes = sizes or {}
  for _, k in ipairs(view.FONT_KEYS) do
    Set("view_font_" .. k, view.ClampFontSize(sizes[k], view.FONT_DEFAULTS[k]))
  end
end

return view
