# AI Transform

A fast, minimal popup for Omarchy/Hyprland: select text anywhere, press `SUPER+I`,
type an instruction, and an OpenRouter model transforms the selection. The result
streams into the window and is copied to the clipboard.

## Files and where they live

| Purpose | Installed path | Backup in this folder |
|---|---|---|
| The app (GTK4 Python) | `~/.local/bin/ai-transform` | `ai-transform` |
| Keybindings + forwards | appended to `~/.config/hypr/bindings.lua` | `hypr-bindings.snippet.lua` |
| Window rule | appended to `~/.config/hypr/hyprland.lua` | `hypr-windowrule.snippet.lua` |
| Settings (model, prompt, flags) | `~/.config/ai-transform/config.json` | — |
| OpenRouter API key | system keyring (gnome-keyring, Secret Service) | — |

The installed copies are the source of truth. The files here are a preserved
snapshot. To reinstall from this folder: `cp ai-transform ~/.local/bin/`, then
append the two snippets to the matching Hyprland files and run `hyprctl reload`.

## Using it

- Select text in any app, press `SUPER+I`. The popup opens centered, sized to its
  content, with the selection shown and the input focused.
- Or press `SUPER+SHIFT+I` (or run `ai-transform --chat`) to open **empty for a direct
  chat** — no selection needed. There's no source row and the top bar shows just
  "Recast"; type a question and talk to the model, with the same follow-ups, Copy,
  Regenerate, and Insert. (Selecting text is optional: with a selection it transforms
  that text; without one it's a plain chat.)
- Type an instruction, press `Enter` to send. A braille spinner shows until the
  first token, then the answer streams in and the window grows to fit it.
- The top bar has two pickers on the right: the **model**, and a **reasoning effort**
  picker beside it (Default / Minimal / Low / Medium / High / Max). Effort maps to
  OpenRouter's `reasoning.effort`; `Default` omits it so the model uses its own default.
  For models without reasoning support the effort picker greys out ("No reasoning"),
  because OpenRouter rejects a reasoning request to those.
- Open either picker with the mouse (click it) or the keyboard (`Ctrl+M` model,
  `Ctrl+E` effort — the same key toggles it shut), then ↑/↓ to move, Enter to select,
  Esc to dismiss — so the whole tool is keyboard-drivable. The dropdown floats over the
  window without growing it, and scrolls if the list is tall.
- The result is auto-copied. Rows below the answer: **Copy output**, **Regenerate**
  (same prompt and model), **Insert in <App>** (pastes into the window the selection
  came from, then closes). Arrow keys move between these rows.
- Type a follow-up to refine; the conversation is kept.
- `Esc` closes. The window quits when closed.

## Keyboard shortcuts (inside the input)

| Keys | Action |
|---|---|
| `Enter` | Send |
| `Shift+Return` / `Super+Return` | Insert a line break |
| `Super+A` | Select all (Ctrl+A also works) |
| `Alt/Option+Backspace` | Delete the previous word |
| `Super+Backspace` | Wipe the current line |
| `Ctrl+Shift+C` | Copy the last answer |
| `Ctrl+M` | Toggle the model picker (↑/↓ to move, Enter to select, Esc to dismiss) |
| `Ctrl+E` | Toggle the reasoning-effort picker (hidden for non-reasoning models) |
| `Ctrl+,` | Settings · `Ctrl+T` back · `Ctrl+Q` quit |

`Super+Return` and `Super+Backspace` are Omarchy bindings (terminal, transparency
toggle). The Hyprland snippet makes them window-aware: inside the AI transform
window they are forwarded to the app; everywhere else they keep their normal action.

## Settings page (`Ctrl+,`)

OpenRouter API key, model dropdown, custom model id, an auto-copy toggle, and the
editable system prompt. The key is written to the system keyring, not to disk. If an
older `config.json` still holds a key, it is migrated to the keyring on first launch.
Key lookup order: `OPENROUTER_API_KEY` env var, then keyring, then `config.json`.

Verify the stored key with:

```
secret-tool lookup service openrouter app ai-transform
```

## Models offered

Claude Fable 5.1, Claude Opus 5, Claude Sonnet 5, GPT-6 Astra, GPT-5.6 Sol,
GPT-5.6 Terra, GPT-5.6 Luna, Gemini 3.8 Flash, Meta Muse Spark 1.3,
Meta Llama 4 Maverick, Grok 4.6, DeepSeek V4 Pro, Qwen 3.8 Max, Kimi K3,
Mistral Large 3. (Maverick and Mistral Large 3 have no reasoning support.) A custom model
id in settings overrides the list. IDs were checked against OpenRouter's live model
list; a 403 like "requires age confirmation" is an OpenRouter account setting, not a
bug — confirm on openrouter.ai or pick another model.

## Design notes and quirks

- **Plain GTK4, no libadwaita.** Undecorated window; Hyprland draws its 2px accent
  border. Zero corner radius, JetBrainsMono Nerd Font, colors from the current
  Omarchy theme (`~/.local/state/omarchy/current/theme/colors.toml`).
- **Layout:** full-width rows separated by 1px lines, one thing per row. Top bar: the
  Menu button, then the app title **Recast** and a breadcrumb to the app the selection
  came from (`Recast › Firefox`); the clickable model and effort selectors sit on the
  far right. The breadcrumb is omitted when there is no source window.
- **Top-bar pickers are a custom floating `Gtk.Popover(autohide=False)`, not a
  `GtkPopoverMenu`.** Under this compositor a menu popover can't take keyboard focus
  (`grab_focus` returns False, the same class of limitation as the caret), so its items
  can't be arrow-navigated. Because `autohide=False` the popover does *not* grab the
  keyboard, so the window keeps focus and a capture-phase key handler drives the list:
  ↑/↓ move a highlighted index, Enter commits, Esc closes; every key is swallowed while
  open so nothing leaks to the input. It floats as its own surface anchored under the
  selector, so the **window stays tight** (its height never grows for the dropdown); a
  list taller than ~90% of the screen scrolls inside the popover. `Ctrl+M`/`Ctrl+E`
  toggle their picker (same key closes it). The **effort selector is hidden entirely**
  for models without reasoning and reappears when a reasoning model is chosen.
- **Window sizing:** hugs its content, capped at 85% of screen height. While
  streaming, the window sizes straight to the scroller's laid-out content height
  (snappy, tied to the text). Row changes use a short settled/coalesced measure,
  because measuring mid-swap can briefly report a spuriously tall wrapped column.
  GTK never shrinks a mapped window, so shrinking is done via a Hyprland resize
  dispatch.
- **Caret:** under this compositor a programmatically focused GtkTextView does not
  paint its caret until a real input event. On open (and when a follow-up input
  appears) the app delivers one self-cancelling key pair (space then backspace) to
  its own window to arm the caret, leaving the field empty. If the caret still does
  not show, this is the place to revisit.
- **Streaming** uses OpenRouter's SSE endpoint on a worker thread; callbacks are
  marshalled onto the GTK main loop.
