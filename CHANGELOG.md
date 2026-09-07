# Changelog

All notable changes to Recast are documented here. This project follows
[Semantic Versioning](https://semver.org).

## v0.1.0 - 2026-09-07

First public release.

### Added

- Transform selected text (`SUPER+I`) or open an empty chat (`SUPER+SHIFT+I`) with an LLM
  via OpenRouter; the answer streams into a centered panel and is auto-copied.
- Answer actions: Copy output, Regenerate, and Insert back into the source window.
- Follow-ups that keep the conversation going.
- Model picker with 15 built-in frontier models, plus Custom models: paste any OpenRouter
  model path (`org/slug`) and it joins the picker with a clean auto-generated label. The list
  is type-to-filterable and capped at 10 rows with scrolling.
- Reasoning-effort picker (Default / Minimal / Low / Medium / High / Max), hidden for models
  without reasoning support.
- Dynamic context placeholders, expanded at send time: `{current-date-time}`, `{location}`
  (from `omarchy-weather-location`), and `{currently-opened-app}`. Chat mode uses them by default.
- Light Markdown rendering in answers, with a settings toggle.
- Keyboard-driven throughout: type-to-filter pickers, menu shortcuts (`Ctrl+N` new,
  `Ctrl+,` settings), and input editing (word/line delete, word-jump, select-all).
- `SUPER+BACKSPACE` routed via `bin/recast-super-backspace` to wipe the input line while
  Recast is open, otherwise Omarchy's transparency toggle (opt-in via the bindings snippet).
- Settings: OpenRouter API key (stored in the system keyring, never on disk), model id,
  auto-copy toggle, Markdown toggle, and an editable system prompt.

### Security

- The API key lives only in the system keyring (`secret-tool`) or the `OPENROUTER_API_KEY`
  environment variable. It is never written to disk or committed to the repository.
