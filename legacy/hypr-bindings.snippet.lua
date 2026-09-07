-- Recast: select text, then press SUPER+I to transform it with an LLM (OpenRouter).
o.bind("SUPER + I", "Recast selection", { launch = os.getenv("HOME") .. "/.local/bin/ai-transform" })
-- SUPER+SHIFT+I opens Recast empty for a direct chat (no selection needed).
o.bind("SUPER + SHIFT + I", "Recast chat", { launch = os.getenv("HOME") .. "/.local/bin/ai-transform --chat" })

-- SUPER+RETURN is Omarchy's terminal shortcut. Inside the AI transform window it should
-- insert a line break instead, so forward it there as Shift+Return; elsewhere keep the terminal.
hl.unbind("SUPER + RETURN")
hl.bind("SUPER + RETURN", function()
  local win = hl.get_active_window()
  if win and win.class == "org.local.AiTransform" then
    hl.dispatch(hl.dsp.send_shortcut({ mods = "SHIFT", key = "Return", window = "pid:" .. win.pid }))
  else
    hl.exec_cmd("omarchy-launch-terminal")
  end
end, { description = "Terminal (line break in AI transform)" })

-- SUPER+BACKSPACE toggles window transparency, but inside the AI transform window it should
-- wipe the current input line. Forward it there as Ctrl+Shift+Backspace; elsewhere keep the toggle.
hl.unbind("SUPER + BACKSPACE")
hl.bind("SUPER + BACKSPACE", function()
  local win = hl.get_active_window()
  if win and win.class == "org.local.AiTransform" then
    hl.dispatch(hl.dsp.send_shortcut({ mods = "CTRL SHIFT", key = "BackSpace", window = "pid:" .. win.pid }))
  else
    hl.exec_cmd("omarchy-hyprland-window-transparency-toggle")
  end
end, { description = "Toggle transparency (wipe line in AI transform)" })
