-- Spaces plugin key bindings.
--
-- Loaded via a marked `dofile` block that install.sh adds to
-- ~/.config/hypr/bindings.lua. Safe to load more than once.
--
-- A "space" N flips every monitor together: workspace N + i*OFFSET on the
-- i-th monitor. SUPER+arrow moves window focus, SUPER+CTRL+arrow moves spaces.
--   SUPER + 1..0          switch to space 1..10
--   SUPER + SHIFT + 1..0  move the active window to space 1..10
--   SUPER + CTRL + LEFT / RIGHT   previous / next space
--   SUPER + CTRL + DOWN           open the graphical Spaces overlay

local home = os.getenv("HOME")
local scripts = home .. "/.config/omarchy/plugins/joshj.spaces/scripts"
local space_switch = scripts .. "/space-switch"
local space_move = scripts .. "/space-move"
local space_cycle = scripts .. "/space-cycle"

-- Every monitor flips together on the number row.
for i = 1, 10 do
  local key = "SUPER + code:" .. tostring(i + 9)
  local shift_key = "SUPER + SHIFT + code:" .. tostring(i + 9)
  hl.unbind(key)
  hl.unbind(shift_key)
  o.bind(key, "Switch to space " .. i, space_switch .. " " .. i)
  o.bind(shift_key, "Move window to space " .. i, space_move .. " " .. i)
end

-- SUPER+CTRL+arrow = spaces, mirroring SUPER+arrow = window focus.
-- Replaces Omarchy's "move grouped window focus" on LEFT/RIGHT (SUPER+ALT+arrow
-- still handles window groups).
hl.unbind("SUPER + CTRL + LEFT")
hl.unbind("SUPER + CTRL + RIGHT")
hl.unbind("SUPER + CTRL + DOWN")
o.bind("SUPER + CTRL + LEFT", "Previous space", space_cycle .. " prev")
o.bind("SUPER + CTRL + RIGHT", "Next space", space_cycle .. " next")
o.bind("SUPER + CTRL + DOWN", "Show spaces overlay", "omarchy-shell shell toggle joshj.spaces")
