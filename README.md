# Recast

A fast, minimal AI text tool for [Omarchy](https://omarchy.org) — a native shell plugin.
Select text anywhere and press **SUPER+I** to transform it with an LLM (via
[OpenRouter](https://openrouter.ai)); the answer streams into a centered panel and is copied
to your clipboard. Follow up to refine, regenerate, or insert the result back into the app you
came from. Or press **SUPER+SHIFT+I** to open it empty and just chat.

![Recast](preview.png)

## Install

```bash
omarchy plugin add https://github.com/TNEP4/recast.git --enable
```

Then add the keybindings — append [`bindings.snippet.lua`](bindings.snippet.lua) to
`~/.config/hypr/bindings.lua` and `hyprctl reload`:

```lua
local recast = os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.tnep4.recast/bin/recast-launch"
o.bind("SUPER + I", "Recast selection", { launch = recast })
o.bind("SUPER + SHIFT + I", "Recast chat", { launch = recast .. " --chat" })
```

Set your OpenRouter API key: open Recast, press **Ctrl+,**, paste the key, Enter. It is stored
in the system keyring (never on disk). You can also export `OPENROUTER_API_KEY` instead.

Dependencies (all in Omarchy's base): `curl`, `jq`, `wl-clipboard`, `libsecret` (`secret-tool`),
plus `hyprctl` and the `omarchy-shell`.

## Using it

- **SUPER+I** — transform the current selection. Type an instruction, `Enter` to send. A spinner
  shows until the first token, then the answer streams in and is auto‑copied.
- **SUPER+SHIFT+I** — open empty for a direct chat (no selection).
- After an answer: **Copy output**, **Regenerate**, **Insert in <app>** (pastes into the window
  the selection came from). Type a follow‑up to keep refining — the conversation is kept.
- The top bar has a **model** picker and a **reasoning‑effort** picker.

### Keyboard

| Keys | Action |
|---|---|
| `Enter` | Send |
| `Ctrl+M` / `Ctrl+E` | Open the model / effort picker (↑/↓ to move, `Enter` to pick) |
| `Ctrl+,` | Settings (API key) |
| `Esc` | Close (a picker/settings first, then the panel) |

## Models & effort

Fifteen frontier models (Claude, GPT, Gemini, Grok, DeepSeek, Qwen, Kimi, Mistral, Meta). The
effort picker maps to OpenRouter's `reasoning.effort` and is sent only when it isn't *Default*
and the model supports reasoning; it's hidden for models that don't. Model and effort persist
to `~/.config/recast/config.json`.

## How it works

Recast is a summoned Omarchy `panel` plugin (a layer‑shell surface hosted by `omarchy-shell`).
The keybind runs `bin/recast-launch`, which grabs the primary selection and active window and
summons the panel over shell IPC with a JSON payload. Streaming is `curl -N` against
OpenRouter's SSE endpoint; the key is read via `secret-tool`. See
[`docs/PLUGIN-RESEARCH.md`](docs/PLUGIN-RESEARCH.md) and [`docs/DEV.md`](docs/DEV.md).

The original standalone GTK4/Python version is preserved in [`legacy/`](legacy/).

## License

MIT — see [LICENSE](LICENSE).
