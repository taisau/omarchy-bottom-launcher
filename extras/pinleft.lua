-- pinleft.lua: hold pinned windows in their recorded column on Hyprland's
-- scrolling layout.
--
-- A pin is a window tag recording the column from the nearer edge:
--   pinl<N> = N-th column from the left, pinr<N> = N-th from the right (0-based).
-- (legacy "pinleft" = pinl0). The bottom launcher's right-click "Pin" sets it.
-- Install: copy to ~/.config/hypr/pinleft.lua and add `require("hypr.pinleft")`
-- to ~/.config/hypr/hyprland.lua (after the looknfeel line). Manual tagging:
--   hyprctl dispatch 'hl.dsp.window.tag({ tag = "+pinl0", window = "address:0x..." })'

local DEBOUNCE_MS = 120

-- Returns side ("l"/"r") and slot for a window's pin tag, or nil.
local function pin_of(w)
  local t = w.tags
  if type(t) == "string" then t = { t } end
  if type(t) ~= "table" then return nil end
  for _, v in pairs(t) do
    local tag = tostring(v):gsub("%*$", "")
    if tag == "pinleft" then return "l", 0 end
    local side, n = tag:match("^pin([lr])(%d+)$")
    if side then return side, tonumber(n) end
  end
  return nil
end

local function pos_x(w)
  local at = w.at
  if type(at) == "table" then return at.x or at[1] or 0 end
  return 0
end

local function ws_id(w)
  return w.workspace and w.workspace.id or nil
end

local busy = false
local pending = false

local function enforce()
  busy = true
  local active = hl.get_active_window()
  local active_addr = active and active.address or nil
  -- focus dispatches warp the cursor to the window centre; remember and restore it
  local cursor = hl.get_cursor_pos()

  -- Tiled, mapped windows per regular workspace.
  local by_ws = {}
  for _, w in ipairs(hl.get_windows({ mapped = true, floating = false })) do
    local id = ws_id(w)
    if id and id > 0 and not w.hidden then
      by_ws[id] = by_ws[id] or {}
      table.insert(by_ws[id], w)
    end
  end

  for _, wins in pairs(by_ws) do
    -- Columns = distinct x positions, left to right.
    local cols, seen = {}, {}
    for _, w in ipairs(wins) do
      local x = pos_x(w)
      local c = seen[x]
      if not c then
        c = { x = x, pinned = nil, first = w }
        seen[x] = c
        table.insert(cols, c)
      end
      if pin_of(w) and not c.pinned then c.pinned = w end
    end
    table.sort(cols, function(a, b) return a.x < b.x end)

    -- Desired final order: pinned columns at their slots (left slots from
    -- the left edge, right slots from the right edge, collisions bumped
    -- inward), the rest in their current order.
    local n = #cols
    local pins = {}
    for i, c in ipairs(cols) do
      if c.pinned then
        local side, slot = pin_of(c.pinned)
        table.insert(pins, { col = c, side = side, slot = slot, i = i })
      end
    end
    local desired, taken = {}, {}
    local function place(p, t, step)
      while t >= 1 and t <= n and desired[t] do t = t + step end
      if t >= 1 and t <= n then desired[t] = p.col; taken[p.col] = true end
    end
    local lefts, rights = {}, {}
    for _, p in ipairs(pins) do table.insert(p.side == "l" and lefts or rights, p) end
    table.sort(lefts, function(a, b) return a.slot < b.slot or (a.slot == b.slot and a.i < b.i) end)
    table.sort(rights, function(a, b) return a.slot < b.slot or (a.slot == b.slot and a.i > b.i) end)
    for _, p in ipairs(lefts) do place(p, math.min(p.slot + 1, n), 1) end
    for _, p in ipairs(rights) do place(p, math.max(n - p.slot, 1), -1) end
    local rest = {}
    for _, c in ipairs(cols) do if not taken[c] then table.insert(rest, c) end end
    local r = 1
    for t = 1, n do
      if not desired[t] then desired[t] = rest[r]; r = r + 1 end
    end

    -- Selection pass: bring desired[t] to position t with swapcol steps.
    for t = 1, n do
      local j
      for k = t, n do if cols[k] == desired[t] then j = k break end end
      if j and j > t then
        local w = desired[t].pinned or desired[t].first
        hl.dispatch(hl.dsp.focus({ window = "address:" .. w.address }))
        for _ = 1, j - t do hl.dispatch(hl.dsp.layout("swapcol l")) end
        table.remove(cols, j)
        table.insert(cols, t, desired[t])
      end
    end
  end

  if active_addr then
    hl.dispatch(hl.dsp.focus({ window = "address:" .. active_addr }))
  end
  if cursor then
    hl.dispatch(hl.dsp.cursor.move({ x = cursor.x, y = cursor.y }))
  end
  busy = false
end

local function schedule()
  if busy or pending then return end
  pending = true
  hl.timer(function()
    pending = false
    enforce()
  end, { timeout = DEBOUNCE_MS, type = "oneshot" })
end

hl.on("window.open", schedule)
hl.on("window.move_to_workspace", schedule)
hl.on("window.update_rules", schedule)
hl.on("window.close", schedule)

-- Exposed so other scripts (e.g. after a tag toggle) can request enforcement:
-- pinleft_enforce() is debounced, pinleft_enforce_now() runs immediately.
pinleft_enforce = schedule
pinleft_enforce_now = enforce
