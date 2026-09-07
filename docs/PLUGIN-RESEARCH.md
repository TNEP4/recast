# Recast → Omarchy plugin: research & plan

Sources: <https://plugins.omarchy.org/develop.html>, <https://plugins.omarchy.org/publish.html>
(read 2026-09-07).

## How the Omarchy plugin system actually works

Plugins are **QML components hosted inside the long-running Omarchy shell (Quickshell)**
process — not standalone apps. Key facts:

- A plugin is a Git repo with a **`manifest.json` in the root** plus its QML entry files,
  a `README.md`, and a `LICENSE`.
- It declares one or more **`kinds`**, each mapped to a QML **entry point**:

  | kind | entryPoint key | file | purpose |
  |------|----------------|------|---------|
  | `bar-widget` | `barWidget` | `BarWidget.qml` | item in the bar |
  | `panel` | `panel` | `Panel.qml` | floating surface |
  | `overlay` | `overlay` | `Overlay.qml` | fullscreen surface |
  | `menu` | `menu` | `Menu.qml` | summoned menu |
  | `service` | `service` | `Service.qml` | headless singleton |
  | `bar` | `bar` | `Bar.qml` | full bar replacement |

- Install: `omarchy plugin add https://github.com/user/plugin.git --enable`; files land in
  `~/.config/omarchy/plugins/{id}/`.
- Dev loop: `omarchy plugin clone <id> --edit`, auto-reload, `omarchy-shell shell rescanPlugins`.
- Validate before submit: `omarchy plugin validate "$PLUGIN_DIR"` (checks: manifest parses,
  kind/entryPoint agree, every referenced file exists, no forbidden id or symlink) and
  `qmllint -I "$OMARCHY_PATH/shell" "$PLUGIN_DIR/<entry>.qml"`.
- **Plugins run UNSANDBOXED, in-process, with the user's permissions.** "Never start a second
  Quickshell process for a plugin." You are responsible for all code/deps.
- IDs: reverse-domain for published plugins, e.g. `com.lunchsofts.recast`. The
  `omarchy.*` namespace is reserved. Remove any dev-only `omarchy.clonedFrom` before publishing.

### Example manifest (from the docs)
```json
{
  "schemaVersion": 1,
  "id": "yourname.plugintype",
  "name": "Display Name",
  "version": "1.0.0",
  "author": "Your name",
  "license": "MIT",
  "description": "Brief description",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "BarWidget.qml" }
}
```

## Publishing

- Requirements: **public GitHub repo**, valid `manifest.json` in root, `README` + `LICENSE`,
  and **safe install & removal**.
- Submit via a **GitHub issue form** (repo link, category, tags).
- The marketplace **"validates listings, not plugin security"** — reviewers are not vetting
  our code; we carry full responsibility. (The published docs do not state preview-image
  dimensions, secret-handling rules, or a formal update flow — to confirm at submission time.)

## The mismatch, and the two paths

Recast today is a **standalone GTK4/Python popup** launched by a keybinding — none of the
plugin `kinds` is "a separate app." So "a proper plugin" is one of:

### Path A — Native QML rewrite (the real plugin)
- UI as an **`overlay`** (fullscreen surface summoned by a key) or **`panel`**, plus a
  **`service`** singleton holding the OpenRouter streaming + state, exposed over IPC.
- Pros: a first-class marketplace plugin; installs/removes cleanly via `omarchy plugin add`;
  no external binary; matches the model reviewers expect.
- Cons: full rewrite from Python/GTK to QML/JS (Quickshell). Re-implement streaming (SSE),
  the model/effort pickers, multi-line editing, clipboard, keyring access (shell out to
  `secret-tool` from QML `Process`), theming. Estimate ~2–4 focused days.

### Path B — Wrapper plugin (bridge)
- A tiny **`service`** (+ optional `bar-widget` icon) whose QML shells out via Quickshell
  `Process` to launch the existing `~/.local/bin/recast` GTK app; the plugin also carries the
  keybinding/window rule.
- Pros: hours, not days; reuses all the working Python.
- Cons: not really "a shell plugin" — the real app is an external binary the plugin installs
  and launches; more awkward to install/remove cleanly; weaker marketplace fit. Good as an
  interim listing while Path A is built.

**Recommendation:** keep the working GTK app in `legacy/` (done) as the reference and the
interim tool; build **Path A** as `recast/` proper. If we want a listing sooner, ship **Path B**
first and replace it with the QML build under the same id.

## API key handling — policy (already correct, keep it)

- The OpenRouter key is **never** stored in the repo or in `config.json`. It lives in the
  **system keyring (Secret Service / gnome-keyring)**, or is read from `OPENROUTER_API_KEY`.
  Lookup order: env var → keyring → (legacy) file, migrated to keyring on first run.
- Audit of the current code + snapshot: no real key, no email, no machine paths — the only
  `sk-or-` string is the input placeholder. `config.snapshot.json` has no `api_key`.
- For the plugin: namespace the keyring entry to the plugin (service `recast`), ship **no**
  default key, and make the settings UI write to the keyring. `.gitignore` already blocks
  `config.json`, `.env`, `*.key`, `secrets/`.
- Because plugins run unsandboxed in the shell process, the key is readable by the shell like
  any Secret Service client — document this and never log the key.

## Naming (proposed, confirm)
- id: `com.lunchsofts.recast` · name: `Recast` · author/brand: `Lunchsofts` · license: MIT.
- Window class / keyring service / config dir get renamed from `ai-transform` → `recast`
  during the rebuild (the legacy copy still uses `ai-transform` internally).
