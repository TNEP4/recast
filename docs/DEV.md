# Developing the Recast plugin

## Test loop (local, no GitHub)

Install the working tree straight into the shell's plugin dir and summon it:

```bash
ID=io.github.tnep4.recast
DEST=~/.config/omarchy/plugins/$ID
mkdir -p "$DEST" && cp manifest.json Panel.qml "$DEST/"
omarchy plugin enable $ID                 # first time only
omarchy-shell shell summon $ID '{"selection":"Hello world","app":"Firefox","mode":"transform"}'
omarchy-shell shell hide $ID
```

- Payload fields: `selection` (text to transform), `app` (source-app name for the breadcrumb),
  `mode` (`"transform"` or `"chat"`). Empty `selection` ⇒ chat mode.
- Validate: `omarchy plugin validate "$PWD"` and
  `/usr/lib/qt6/bin/qmllint -I "$OMARCHY_PATH/shell" Panel.qml` (qmllint warns that it can't
  resolve the `qs.*` alias / `PanelWindow` outside the shell runtime — expected; the built-in
  plugins import the same way).

## ⚠️ Reload caveat

Quickshell's live hot-reload does **not** reliably re-instantiate a `keepLoaded` third-party
panel after structural QML edits — it keeps the cached instance (you'll see stale binding-loop
warnings and your new `console.warn`s won't fire). After editing `Panel.qml`, force a clean
load with **`omarchy-restart-shell`** (restarts the shell/bar/overlays, not your app windows),
then summon again. Trivial edits sometimes reload on save; structural ones need the restart.

## Gotchas found while building

- **Hot-reload caches keepLoaded panels** — restart the shell after structural edits (above).
- **SSE lines arrive with a leading newline** from `SplitParser`, mixed with
  `: OPENROUTER PROCESSING` keep-alives — normalize/trim and scan every line.
- **Reasoning models** (e.g. Kimi K3) stream `delta.reasoning` with empty `delta.content`
  first; only append `content`, and keep the spinner until the first content token.
- **Omarchy's Hyprland uses Lua dispatchers** (`hl.dsp.focus`, `hl.dsp.send_shortcut`), NOT the
  stock `focuswindow` / `sendshortcut` (which it rejects: "dispatch in lua is a shorthand for
  hl.dispatch(...)"). Insert uses `hyprctl dispatch 'hl.dsp.send_shortcut({ mods=…, key="v",
  window="address:…" })'`.

## Logs

Plugin output goes to the shell's journal:

```bash
journalctl --user --since "1 min ago" | grep -iE "recast|Panel.qml"
```

`console.warn(...)` shows as `WARN qml:`; `console.log`/`console.debug` are lower level and may
be filtered — use `console.warn` when you need to see it.

## Contract (see docs/PLUGIN-RESEARCH.md for the full picture)

`Panel.qml` is a root `Item` the host mounts; it owns a layer-shell `PanelWindow`
(`visible: root.opened`, `keyboardFocus: Exclusive`). The host calls `open(payloadJson)` on
summon and `close()` on hide, and injects `shell`/`manifest`. Theme via `qs.Commons`
`Style`/`Color`/`Util`.
