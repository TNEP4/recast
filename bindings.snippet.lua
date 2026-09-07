-- Recast keybindings — append to ~/.config/hypr/bindings.lua after installing the plugin
--   omarchy plugin add https://github.com/TNEP4/recast.git --enable
--
-- SUPER+I: transform the current selection. SUPER+SHIFT+I: open empty for a direct chat.
-- The launcher grabs the primary selection + active window and summons the plugin over IPC.
local recast_dir = os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.tnep4.recast/bin"
local recast = recast_dir .. "/recast-launch"
o.bind("SUPER + I", "Recast selection", { launch = recast })
o.bind("SUPER + SHIFT + I", "Recast chat", { launch = recast .. " --chat" })

-- SUPER+BACKSPACE is Omarchy's "toggle window transparency". Hyprland keybinds fire before
-- any surface, so Recast can't receive that chord on its own. Route it: while Recast is open,
-- SUPER+BACKSPACE (Cmd/Super+Delete on a Mac keyboard) wipes the current input line; otherwise
-- it keeps the normal transparency toggle. The wrapper does the check.
hl.unbind("SUPER + BACKSPACE")
o.bind("SUPER + BACKSPACE", "Toggle transparency (wipe line in Recast)", recast_dir .. "/recast-super-backspace")
