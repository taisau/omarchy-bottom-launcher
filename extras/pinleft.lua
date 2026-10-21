-- pinleft.lua: keep windows tagged "pinleft" in the leftmost columns of their
-- workspace on Hyprland's scrolling layout.
--
-- Install: copy to ~/.config/hypr/pinleft.lua and add `require("hypr.pinleft")`
-- to ~/.config/hypr/hyprland.lua (after the looknfeel line). Tag a window with
--   hyprctl dispatch 'hl.dsp.window.tag({ tag = "pinleft", window = "address:0x..." })'
-- (the bottom launcher's right-click "Pin" does exactly that), or tag by rule:
--   hl.window_rule({ name = "firefox_pinleft", match = { class = "firefox" }, tag = "+pinleft" })

local TAG = "pinleft"
local DEBOUNCE_MS = 120

local function has_tag(w)
  local t = w.tags
  if type(t) == "string" then t = { t } end
  if type(t) ~= "table" then return false end
  for _, v in pairs(t) do
    if tostring(v):gsub("%*$", "") == TAG then return true end
  end
  return false
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
        c = { x = x, pinned = nil }
        seen[x] = c
        table.insert(cols, c)
      end
      if has_tag(w) and not c.pinned then c.pinned = w end
    end
    table.sort(cols, function(a, b) return a.x < b.x end)

    -- Walk left to right; each pinned column moves left to the next free slot.
    local slot = 0
    for i, c in ipairs(cols) do
      if c.pinned then
        local dist = (i - 1) - slot
        if dist > 0 then
          hl.dispatch(hl.dsp.focus({ window = "address:" .. c.pinned.address }))
          for _ = 1, dist do
            hl.dispatch(hl.dsp.layout("swapcol l"))
          end
        end
        slot = slot + 1
      end
    end
  end

  if active_addr then
    hl.dispatch(hl.dsp.focus({ window = "address:" .. active_addr }))
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
