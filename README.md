# Recast

A fast, minimal AI text tool for [Omarchy](https://omarchy.org)/Hyprland. Select text
anywhere and transform it with an LLM (via [OpenRouter](https://openrouter.ai)), or open it
empty to chat directly — the answer streams in and is copied to the clipboard, with
follow-ups, regenerate, and insert-back.

> **Status: being rebuilt into a proper Omarchy plugin.** The current, fully working version
> is a standalone GTK4/Python app, preserved in [`legacy/`](legacy/). This repo will grow the
> QML plugin alongside it. See [`docs/PLUGIN-RESEARCH.md`](docs/PLUGIN-RESEARCH.md) for the
> plan and the Omarchy plugin-system findings.

## Layout

| Path | What |
|------|------|
| `legacy/recast-app.py` | the current working GTK4/Python app (verbatim; still uses the old `ai-transform` internal ids) |
| `legacy/hypr-*.snippet.lua` | Hyprland keybindings + window rule for the legacy app |
| `legacy/README.md` | full docs for the legacy app (features, shortcuts, design notes) |
| `docs/PLUGIN-RESEARCH.md` | Omarchy develop/publish research, the QML-vs-wrapper decision, key-handling policy |
| `docs/LEGACY-BUILD-LOG.md` | chronological build history of the legacy app |
| `manifest.draft.json` | **draft** Omarchy plugin manifest — rename to `manifest.json` and finalize once the plugin kind is chosen (its entry `.qml` files don't exist yet) |

## API key & privacy

The OpenRouter API key is stored **only** in the system keyring (Secret Service), or read
from `OPENROUTER_API_KEY` — it is **never** written to this repo or to `config.json`. No key,
email, or machine-specific path is committed (`.gitignore` blocks config/secrets). See the
"API key handling" section of the research doc.

## License

MIT — see [LICENSE](LICENSE).
