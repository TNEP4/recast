-- Recast keybindings — append to ~/.config/hypr/bindings.lua after installing the plugin
--   omarchy plugin add https://github.com/TNEP4/recast.git --enable
--
-- SUPER+I: transform the current selection. SUPER+SHIFT+I: open empty for a direct chat.
-- The launcher grabs the primary selection + active window and summons the plugin over IPC.
local recast = os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.tnep4.recast/bin/recast-launch"
o.bind("SUPER + I", "Recast selection", { launch = recast })
o.bind("SUPER + SHIFT + I", "Recast chat", { launch = recast .. " --chat" })
