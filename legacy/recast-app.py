#!/usr/bin/env python3
"""ai-transform: select text, press a shortcut, describe the transformation, get the result.

Reads the primary selection (or clipboard), asks an OpenRouter model to transform it
according to your instruction, streams the answer into the window and copies it to the
clipboard. Follow-up instructions keep the conversation context.

Usage:  ai-transform            # open with the current selection
        ai-transform --settings # open straight to settings
"""
import json
import os
import subprocess
import sys
import threading
import tomllib
import urllib.error
import urllib.request

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Gdk", "4.0")
from gi.repository import Gdk, Gio, GLib, Gtk  # noqa: E402

APP_ID = "org.local.AiTransform"
CONFIG_DIR = os.environ.get("AI_TRANSFORM_CONFIG_DIR") or os.path.expanduser("~/.config/ai-transform")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
THEME_COLORS = os.path.expanduser("~/.local/state/omarchy/current/theme/colors.toml")
SHELL_TOML = os.path.expanduser("~/.config/omarchy/shell.toml")
API_URL = "https://openrouter.ai/api/v1/chat/completions"
WIDTH = 900          # logical px
MAX_SCREEN_FRAC = 0.85

# (OpenRouter model id, label). Ids verified against https://openrouter.ai/api/v1/models
# (id, label, supports_reasoning). The reasoning flag comes from OpenRouter's
# `supported_parameters` for each model — sending a reasoning/effort request to a model
# that lacks it is rejected, so the effort picker is gated on this.
MODELS = [
    ("anthropic/claude-fable-5.1", "Claude Fable 5.1", True),
    ("anthropic/claude-opus-5", "Claude Opus 5", True),
    ("anthropic/claude-sonnet-5", "Claude Sonnet 5", True),
    ("openai/gpt-6-astra", "GPT-6 Astra", True),
    ("openai/gpt-5.6-sol", "GPT-5.6 Sol", True),
    ("openai/gpt-5.6-terra", "GPT-5.6 Terra", True),
    ("openai/gpt-5.6-luna", "GPT-5.6 Luna", True),
    ("google/gemini-3.8-flash", "Gemini 3.8 Flash", True),
    ("meta/muse-spark-1.3", "Meta Muse Spark 1.3", True),
    ("meta-llama/llama-4-maverick", "Meta Llama 4 Maverick", False),
    ("x-ai/grok-4.6", "Grok 4.6", True),
    ("deepseek/deepseek-v4-pro", "DeepSeek V4 Pro", True),
    ("qwen/qwen3.8-max-0902", "Qwen 3.8 Max", True),
    ("moonshotai/kimi-k3", "Kimi K3", True),
    ("mistralai/mistral-large-2512", "Mistral Large 3", False),
]
MODEL_IDS = [m for m, *_ in MODELS]

# Reasoning effort, from OpenRouter's `reasoning.effort` scale. "default" omits the field
# entirely (the model uses its own default); the rest map straight to the API value.
EFFORTS = [
    ("default", "Default"),
    ("minimal", "Minimal"),
    ("low", "Low"),
    ("medium", "Medium"),
    ("high", "High"),
    ("max", "Max"),
]
EFFORT_IDS = [e for e, _ in EFFORTS]

DEFAULT_SYSTEM_PROMPT = (
    "You transform text. The user gives an instruction and a piece of text. "
    "Apply the instruction to the text and reply with ONLY the transformed text: "
    "no preamble, no explanation, no quotes, no markdown fences, unless the "
    "instruction explicitly asks for them. Preserve the original language unless "
    "asked to translate. For follow-up instructions, refine your previous answer."
)

# Used when Recast is opened without selected text (direct chat, no text to transform).
CHAT_SYSTEM_PROMPT = (
    "You are Recast, a helpful, concise assistant. Answer the user directly and clearly. "
    "Keep formatting light (plain text; the answer is shown in a simple text view)."
)

DEFAULT_CONFIG = {
    "api_key": "",
    "model": "anthropic/claude-sonnet-5",
    "effort": "default",
    "system_prompt": DEFAULT_SYSTEM_PROMPT,
    "auto_copy": True,
}


# ----------------------------------------------------------------------------- helpers
def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_FILE) as f:
            cfg.update(json.load(f))
    except (OSError, ValueError):
        pass
    return cfg


def save_config(cfg):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = CONFIG_FILE + ".tmp"
    data = {k: v for k, v in cfg.items() if not k.startswith("_")}
    if cfg.get("_key_store") == "keyring":
        data.pop("api_key", None)
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG_FILE)


# ----------------------------------------------------------------------------- API key storage
# Order: OPENROUTER_API_KEY env var > system keyring (Secret Service, e.g. gnome-keyring)
# > config.json with mode 0600 (only when no keyring is available, or AI_TRANSFORM_KEY_STORE=file).
KEY_STORE = os.environ.get("AI_TRANSFORM_KEY_STORE", "keyring")
KEY_ATTRS = {"service": "openrouter", "app": "ai-transform"}
_schema = None


def _secret():
    global _schema
    gi.require_version("Secret", "1")
    from gi.repository import Secret
    if _schema is None:
        _schema = Secret.Schema.new("org.local.AiTransform", Secret.SchemaFlags.NONE,
                                    {"service": Secret.SchemaAttributeType.STRING,
                                     "app": Secret.SchemaAttributeType.STRING})
    return Secret, _schema


def keyring_get():
    """Key from the keyring; '' if none stored; None if no keyring is usable."""
    try:
        Secret, schema = _secret()
        return Secret.password_lookup_sync(schema, KEY_ATTRS, None) or ""
    except Exception:
        return None


def keyring_set(key):
    try:
        Secret, schema = _secret()
        if key:
            return Secret.password_store_sync(schema, KEY_ATTRS, Secret.COLLECTION_DEFAULT,
                                              "OpenRouter API key (ai-transform)", key, None)
        return Secret.password_clear_sync(schema, KEY_ATTRS, None) or True
    except Exception:
        return False


def resolve_api_key(cfg):
    """Fill cfg['api_key'] and cfg['_key_store'] ('keyring' or 'file'); migrate file -> keyring."""
    cfg["_key_store"] = "file"
    if KEY_STORE == "keyring":
        stored = keyring_get()
        if stored is not None:
            cfg["_key_store"] = "keyring"
            file_key = (cfg.get("api_key") or "").strip()
            if file_key and not stored and keyring_set(file_key):
                stored = file_key            # migrated from an older config.json
            cfg["api_key"] = stored
            if file_key:
                save_config(cfg)             # strips the key from disk
    return cfg


def store_api_key(cfg, key):
    cfg["api_key"] = key.strip()
    if cfg.get("_key_store") == "keyring" and keyring_set(cfg["api_key"]):
        return
    cfg["_key_store"] = "file"
    save_config(cfg)


def api_key(cfg):
    return (os.environ.get("OPENROUTER_API_KEY") or cfg.get("api_key") or "").strip()


def run(args, **kw):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=2, **kw)
    except (OSError, subprocess.TimeoutExpired):
        return None


def read_selection():
    """Primary selection first (what you highlighted), then the clipboard."""
    for args in (["wl-paste", "-p", "-n"], ["wl-paste", "-n"]):
        out = run(args)
        if out and out.returncode == 0 and out.stdout.strip():
            return out.stdout.strip("\n")
    return ""


def copy_to_clipboard(text):
    # wl-copy forks a background server that keeps stdout open: never capture its output
    try:
        return subprocess.run(["wl-copy"], input=text, text=True, timeout=2,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def model_label(model_id):
    for mid, name, *_ in MODELS:
        if mid == model_id:
            return name
    return model_id


def model_supports_reasoning(model_id):
    for mid, _, *rest in MODELS:
        if mid == model_id:
            return rest[0] if rest else True
    return True   # custom / unknown id: assume it does and let the API decide


def effort_label(effort):
    for eid, name in EFFORTS:
        if eid == effort:
            return name
    return effort


# ----------------------------------------------------------------------------- source window
TERMINAL_CLASSES = {"org.omarchy.terminal", "org.omarchy.bash", "Alacritty", "kitty", "foot",
                    "org.codeberg.dnkl.foot", "com.mitchellh.ghostty"}
APP_NAMES = {"org.omarchy.terminal": "Terminal", "org.omarchy.bash": "Terminal", "Alacritty": "Alacritty",
             "kitty": "Kitty", "foot": "Foot", "com.mitchellh.ghostty": "Ghostty", "chromium": "Chromium",
             "google-chrome": "Chrome", "firefox": "Firefox", "code": "VS Code", "Code": "VS Code",
             "cursor": "Cursor", "obsidian": "Obsidian", "Slack": "Slack", "discord": "Discord",
             "signal": "Signal", "org.gnome.Nautilus": "Files", "org.telegram.desktop": "Telegram"}


def source_window():
    """The window that had focus when we were launched, i.e. where the selection came from."""
    out = run(["hyprctl", "activewindow", "-j"])
    if not out or out.returncode != 0:
        return None
    try:
        win = json.loads(out.stdout)
    except ValueError:
        return None
    if not win.get("address") or win.get("class") in ("", APP_ID):
        return None
    return {"address": win["address"], "class": win.get("class", ""), "title": win.get("title", "")}


def app_name(win):
    cls = win["class"]
    if cls in APP_NAMES:
        return APP_NAMES[cls]
    if cls.startswith("chrome-"):  # Omarchy web apps: chrome-<host>__<path>-Default
        host = cls[len("chrome-"):].split("__")[0].split("-Default")[0]
        return host.removeprefix("www.").split(".")[0].capitalize()
    name = cls.split(".")[-1].replace("-", " ")
    return name[:1].upper() + name[1:]   # keep the app's own casing (VSCodium, HelperTarget)


def hypr(cmd):
    """Run one Hyprland Lua dispatcher synchronously."""
    return run(["hyprctl", "dispatch", cmd])


# ----------------------------------------------------------------------------- theme
def load_theme():
    """Colours from the current Omarchy theme, font from Omarchy's font setting."""
    t = {"bg": "#1a1b26", "fg": "#c0caf5", "accent": "#7aa2f7", "red": "#f7768e",
         "font": "monospace", "size": 14}
    try:
        with open(THEME_COLORS, "rb") as f:
            c = tomllib.load(f)
        t["bg"] = c.get("background", t["bg"])
        t["fg"] = c.get("foreground", t["fg"])
        t["accent"] = c.get("accent", c.get("blue", t["accent"]))
        t["red"] = c.get("red", t["red"])
    except (OSError, ValueError):
        pass
    out = run(["omarchy-font-current"])
    if out and out.returncode == 0 and out.stdout.strip():
        t["font"] = out.stdout.strip()
    try:
        with open(SHELL_TOML, "rb") as f:
            t["size"] = int(tomllib.load(f).get("font", {}).get("base-size", 14))
    except (OSError, ValueError, TypeError):
        pass
    return t


def build_css(t):
    bg, fg, accent, red, font, size = t["bg"], t["fg"], t["accent"], t["red"], t["font"], t["size"]
    return f"""
    * {{ border-radius: 0; font-family: "{font}", monospace; font-size: {size}px; outline: none; }}
    window {{ background-color: {bg}; color: {fg}; }}
    label, textview, textview text, entry, entry text {{ color: {fg}; }}
    .muted {{ color: alpha({fg}, 0.55); }}
    .placeholder {{ color: alpha({fg}, 0.4); }}
    .error, .error text {{ color: {red}; }}
    .spinner, .spinner text {{ color: {accent}; }}

    /* full-width rows separated by lines */
    .row {{ padding: 14px 20px; border-bottom: 1px solid alpha({fg}, 0.4); }}
    .row.option {{ padding: 12px 20px; background: none; }}
    .row:focus-within, .row.option:hover, .row.option:focus {{ background-color: alpha({fg}, 0.08); }}
    .row.option:focus label, .row.option:hover label {{ color: {accent}; }}
    .row.option:focus label.muted, .row.option:hover label.muted {{ color: alpha({accent}, 0.7); }}
    .list > .row:last-child, .list > *:last-child > .row:last-child {{ border-bottom: none; }}

    entry {{ background: none; border: none; box-shadow: none; padding: 0; min-height: 0; caret-color: {accent}; }}
    entry > text > placeholder {{ color: alpha({fg}, 0.4); }}
    entry > text {{ background: none; }}
    textview, textview text {{ background: none; caret-color: {accent}; }}
    selection, textview text selection, entry selection {{ background-color: alpha({accent}, 0.35); color: {fg}; }}

    button {{ background: none; border: 1px solid alpha({fg}, 0.4); box-shadow: none; padding: 3px 14px;
              min-height: 0; color: {fg}; text-shadow: none; -gtk-icon-shadow: none; }}
    button:hover {{ background-color: alpha({fg}, 0.08); color: {accent}; }}
    button:focus {{ border-color: {accent}; }}
    button.flat {{ border: none; padding: 0; }}

    /* menu bar */
    .menubar {{ border-bottom: 1px solid alpha({fg}, 0.4); }}
    .menubar button {{ border: none; padding: 8px 20px; }}
    .crumbs {{ margin-left: 4px; }}
    .crumbs .title {{ font-weight: bold; }}
    .crumbs .crumb-sep {{ color: alpha({fg}, 0.4); }}
    .menubar button:hover, .menubar button:checked {{ background-color: alpha({fg}, 0.08); color: {accent}; }}
    .menubar button:checked label {{ color: {accent}; }}
    popover {{ background: none; }}
    popover > contents {{ background-color: {bg}; border: 2px solid {fg}; box-shadow: none; padding: 8px 0; margin: 0; }}
    popover modelbutton {{ padding: 10px 20px; min-height: 0; }}
    popover modelbutton:hover, popover modelbutton:focus {{ background-color: alpha({fg}, 0.08); color: {accent}; }}
    popover separator {{ background: alpha({fg}, 0.25); margin: 4px 0; min-height: 1px; }}
    popover listview row {{ padding: 10px 20px; }}
    popover listview row:hover, popover listview row:selected {{ background-color: alpha({fg}, 0.08); color: {accent}; }}

    /* floating dropdown picker (top-bar model / effort) */
    popover.picker > contents {{ min-width: 240px; padding: 6px 0; }}
    .picker-row {{ padding: 10px 20px; }}
    .picker-row.sel {{ background-color: alpha({fg}, 0.08); color: {accent}; }}

    /* settings: full width, underline only */
    .field {{ border-bottom: 1px solid alpha({fg}, 0.4); padding: 6px 0; }}
    .field:focus-within {{ border-bottom-color: {accent}; }}
    dropdown > button {{ border: none; padding: 0; }}
    dropdown > button:hover {{ background: none; }}
    radio, check {{ background: none; border: 1px solid alpha({fg}, 0.5); box-shadow: none; -gtk-icon-source: none;
                    min-width: 12px; min-height: 12px; color: {bg}; }}
    radio:checked, check:checked {{ background-color: {accent}; border-color: {accent}; }}
    checkbutton {{ padding: 0; }}
    scrollbar {{ background: none; }}
    scrollbar slider {{ background-color: alpha({fg}, 0.3); min-width: 4px; margin: 0; }}
    """


# ----------------------------------------------------------------------------- streaming
def stream_completion(cfg, messages, on_delta, on_done, on_error):
    """Run in a worker thread; callbacks are marshalled onto the GTK main loop."""
    payload = {"model": cfg["model"], "messages": messages, "stream": True}
    effort = cfg.get("effort", "default")
    if effort != "default" and model_supports_reasoning(cfg["model"]):
        payload["reasoning"] = {"effort": effort}   # OpenRouter reasoning-effort scale
    body = json.dumps(payload).encode()
    req = urllib.request.Request(
        API_URL,
        data=body,
        headers={
            "Authorization": f"Bearer {api_key(cfg)}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://omarchy.org",
            "X-Title": "ai-transform",
        },
    )
    full = []
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except ValueError:
                    continue
                if "error" in chunk:
                    raise RuntimeError(chunk["error"].get("message", str(chunk["error"])))
                for choice in chunk.get("choices", []):
                    delta = choice.get("delta", {}).get("content")
                    if delta:
                        full.append(delta)
                        GLib.idle_add(on_delta, delta)
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read().decode()).get("error", {}).get("message", "")
        except Exception:
            detail = ""
        GLib.idle_add(on_error, f"HTTP {e.code}: {detail or e.reason}")
        return
    except Exception as e:  # network errors, API errors
        GLib.idle_add(on_error, str(e))
        return
    GLib.idle_add(on_done, "".join(full))


# ----------------------------------------------------------------------------- widgets
def focus_later(widget):
    """grab_focus() returns True, which would make GLib.idle_add repeat it forever."""
    GLib.idle_add(lambda: widget.grab_focus() and False)


def label(text, css=(), **kw):
    kw.setdefault("xalign", 0)
    return Gtk.Label(label=text, css_classes=list(css), **kw)


class PromptRows(Gtk.Box):
    """A multi-line input row (text view + Send) and, for follow-ups, a 'Copy output' row.

    Enter sends; Shift+Return or Super+Return inserts a line break. Down from the last
    line moves to the copy row, Up from the copy row returns to the input. After sending,
    everything collapses into a single inert row that shows only the message.
    """

    def __init__(self, on_send, actions=(), placeholder="Ask anything…", on_change=None):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, css_classes=["options"])
        self.on_send = on_send
        self.on_change = on_change
        self.input = Gtk.Box(spacing=12, css_classes=["row"])

        self.entry = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR, hexpand=True, accepts_tab=False,
                                  halign=Gtk.Align.FILL, valign=Gtk.Align.CENTER)
        self.buf = self.entry.get_buffer()
        self.buf.connect("changed", self._on_buf_changed)
        # placeholder sits *behind* the (transparent) text view so the caret paints on top;
        # the text view fills the whole row so the caret sits at the row's left edge
        self.placeholder = label(placeholder, ["placeholder"], can_target=False,
                                 halign=Gtk.Align.START, valign=Gtk.Align.CENTER)
        overlay = Gtk.Overlay(child=self.placeholder, hexpand=True, valign=Gtk.Align.CENTER)
        overlay.add_overlay(self.entry)
        overlay.set_measure_overlay(self.entry, True)
        overlay.set_clip_overlay(self.entry, False)
        keys = Gtk.EventControllerKey(propagation_phase=Gtk.PropagationPhase.CAPTURE)
        keys.connect("key-pressed", self._on_entry_key)
        self.entry.add_controller(keys)

        self.send = Gtk.Button(label="Send", can_focus=False, valign=Gtk.Align.CENTER)
        self.send.connect("clicked", lambda *_: on_send(self))
        self.input.append(overlay)
        self.input.append(self.send)
        self.append(self.input)

        self.options, self.hints = [], []
        for text, callback in actions:
            btn = Gtk.Button(css_classes=["row", "option"], hexpand=True)
            inner = Gtk.Box(spacing=12)
            inner.append(label(text, hexpand=True))
            hint = label("", ["muted"], xalign=1)
            inner.append(hint)
            btn.set_child(inner)
            btn.connect("clicked", lambda _b, cb=callback: cb(self))
            self.append(btn)
            self.options.append(btn)
            self.hints.append(hint)

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key)
        self.add_controller(keys)

    NEWLINE_MODS = Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.META_MASK

    def _on_entry_key(self, _c, keyval, _code, state):
        if keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_ISO_Enter):
            if state & self.NEWLINE_MODS:
                self.buf.insert_at_cursor("\n")
            else:
                self.on_send(self)
            return True
        # Super/Command+A selects all the text (Ctrl+A is GTK's native default and still works).
        if keyval in (Gdk.KEY_a, Gdk.KEY_A) and state & (Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.META_MASK):
            self.buf.select_range(self.buf.get_start_iter(), self.buf.get_end_iter())
            return True
        # Wipe the current line: Super+Backspace (Hyprland forwards it as Ctrl+Shift+Backspace,
        # since Super+Backspace is a compositor binding).
        if keyval in (Gdk.KEY_BackSpace, Gdk.KEY_Delete):
            ctrl = state & Gdk.ModifierType.CONTROL_MASK
            shift = state & Gdk.ModifierType.SHIFT_MASK
            alt = state & Gdk.ModifierType.ALT_MASK
            supr = state & (Gdk.ModifierType.SUPER_MASK | Gdk.ModifierType.META_MASK)
            if supr or (ctrl and shift):
                self._delete_line()
                return True
            if alt:                       # Alt/Option+Backspace: delete the previous word
                self._delete_word_back()
                return True
        if keyval == Gdk.KEY_Down and self.options and self._cursor_on_last_line():
            self.options[0].grab_focus()
            return True
        return False

    def _delete_word_back(self):
        it = self.buf.get_iter_at_mark(self.buf.get_insert())
        start = it.copy()
        if start.backward_word_start():   # skips the whitespace before the word, then the word
            self.buf.delete(start, it)
        elif not start.is_start():        # nothing but whitespace before: clear back to line start
            start.set_line_offset(0)
            self.buf.delete(start, it)

    def _delete_line(self):
        """Remove the whole logical line the cursor is on, collapsing the ones around it."""
        it = self.buf.get_iter_at_mark(self.buf.get_insert())
        start = it.copy()
        start.set_line_offset(0)
        end = start.copy()
        if not end.forward_line():        # last line: take it to the buffer end
            end.forward_to_end()
            if start.get_line() > 0:      # not the only line: also eat the preceding newline
                start.backward_char()
        self.buf.delete(start, end)

    def _cursor_on_last_line(self):
        it = self.buf.get_iter_at_mark(self.buf.get_insert())
        return not self.entry.forward_display_line(it)

    def _on_key(self, _c, keyval, _code, _state):
        """Up/Down between the option rows; Up from the first row returns to the input."""
        focused = next((i for i, b in enumerate(self.options) if b.has_focus()), None)
        if focused is None:
            return False
        if keyval == Gdk.KEY_Up:
            (self.options[focused - 1] if focused > 0 else self.entry).grab_focus()
            return True
        if keyval == Gdk.KEY_Down and focused < len(self.options) - 1:
            self.options[focused + 1].grab_focus()
            return True
        return False

    def _on_buf_changed(self, buf):
        self.placeholder.set_visible(buf.get_char_count() == 0)
        if self.on_change:
            self.on_change()

    def text(self):
        return self.buf.get_text(self.buf.get_start_iter(), self.buf.get_end_iter(), True).strip()

    def set_text(self, text):
        self.buf.set_text(text)
        self.buf.place_cursor(self.buf.get_end_iter())

    def set_placeholder(self, text):
        self.placeholder.set_text(text)

    def set_hint(self, index, text):
        if index < len(self.hints):
            self.hints[index].set_text(text)

    def deactivate(self, message):
        self.remove(self.input)
        for btn in self.options:
            self.remove(btn)
        self.options, self.hints = [], []
        self.remove_css_class("options")
        row = Gtk.Box(spacing=12, css_classes=["row"])
        row.append(label("✓", ["muted"], valign=Gtk.Align.START))
        row.append(label(message, wrap=True, hexpand=True))
        self.append(row)


class OutputRow(Gtk.Box):
    SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"

    def __init__(self, model_id):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8, css_classes=["row"])
        self.append(label(model_label(model_id), ["muted"]))
        self.view = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR, editable=False, cursor_visible=False)
        self.buf = self.view.get_buffer()
        self.append(self.view)
        self._spin_timer = 0
        self._spin_i = 0

    def start_spinner(self):
        """Show a rotating braille glyph until the first token arrives."""
        self.view.add_css_class("spinner")

        def tick():
            self.buf.set_text(self.SPINNER[self._spin_i % len(self.SPINNER)])
            self._spin_i += 1
            return True
        tick()
        self._spin_timer = GLib.timeout_add(90, tick)

    def stop_spinner(self):
        if self._spin_timer:
            GLib.source_remove(self._spin_timer)
            self._spin_timer = 0
            self.view.remove_css_class("spinner")
            self.buf.set_text("")

    def append_text(self, delta):
        self.stop_spinner()
        self.buf.insert(self.buf.get_end_iter(), delta)

    def set_text(self, text, error=False):
        self.stop_spinner()
        self.buf.set_text(text)
        if error:
            self.view.add_css_class("error")


# ----------------------------------------------------------------------------- window
class Window(Gtk.ApplicationWindow):
    def __init__(self, app, cfg, selection, open_settings=False, source=None):
        super().__init__(application=app, title="AI Transform")
        self.cfg = cfg
        self.source_win = source
        self.has_selection = bool(selection)   # transform mode; empty => direct-chat mode
        self.messages = []
        self.busy = False
        self.last_answer = ""
        self.stick_bottom = False
        self.settle_until = 0
        self._fit_timer = 0
        self._caret_kicked = False
        self._streaming = False   # True only once real tokens are arriving (not the spinner)
        self.set_decorated(False)  # Hyprland draws the border; no CSD, no rounding

        self.max_height = 700
        monitors = Gdk.Display.get_default().get_monitors()
        if monitors.get_n_items():
            self.max_height = int(monitors.get_item(0).get_geometry().height * MAX_SCREEN_FRAC)

        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.set_child(self.root)
        self.menubar = self._build_menubar()
        self.root.append(self.menubar)

        self.stack = Gtk.Stack(hhomogeneous=True, vhomogeneous=False)
        self.root.append(self.stack)
        self.stack.add_named(self._build_main(selection), "main")
        self.stack.add_named(self._build_settings(), "settings")
        self._build_picker()

        keys = Gtk.EventControllerKey()
        keys.connect("key-pressed", self._on_key)
        self.add_controller(keys)
        # closing the window (Esc, compositor close) must end the process
        self.connect("close-request", self._on_close)
        # The text caret does not start blinking when focus is grabbed programmatically
        # before the toplevel focus-in; restart it whenever the window becomes active.
        self.connect("notify::is-active", lambda *_: self._kick_caret())
        GLib.timeout_add(250, lambda: self._kick_caret() or False)

        if open_settings or not api_key(cfg):
            self.show_settings()
        else:
            focus_later(self.prompt.entry)
        self.fit()
        # text views only know their height once realized: fit again after mapping
        self.connect("map", lambda *_: self.refit())

    def _on_close(self, *_):
        if self._key_timer:
            self._flush_key()
        self.get_application().quit()
        return True

    # ---- sizing: hug the content, cap at a fraction of the screen
    def schedule_fit(self, delay=120):
        """Coalesce rapid layout changes: run fit once things settle. Measuring mid-change
        can report a text view wrapped at near-zero width (a spuriously tall column)."""
        if self._fit_timer:
            GLib.source_remove(self._fit_timer)
        self._fit_timer = GLib.timeout_add(delay, self._run_scheduled_fit)

    def _run_scheduled_fit(self):
        self._fit_timer = 0
        self.fit()
        return False

    def refit(self):
        """Measure after layout has settled: text views validate their lines in a high
        priority idle, so a low priority idle (plus a delayed retry) sees real heights."""
        # a page shown for the first time is laid out with stale line wrapping for a frame
        # or two; ignore growth signals until it has settled
        self.settle_until = GLib.get_monotonic_time() + 250_000
        GLib.idle_add(self.fit, priority=GLib.PRIORITY_LOW)
        GLib.timeout_add(150, self.fit)
        GLib.timeout_add(300, self.fit)
    def fit(self, *_):
        """Size the window to its content. The measured natural height of the visible page is
        the source of truth; the scroll adjustment's `upper` is unreliable while rows change.
        GTK grows a mapped toplevel on its own but never shrinks it, so shrinking goes through
        Hyprland."""
        _, bar_h, _, _ = self.menubar.measure(Gtk.Orientation.VERTICAL, WIDTH)
        cap = self.max_height - bar_h
        page = self.stack.get_visible_child()
        main = page is self.scroller
        content = self.list if main else page
        _, nat, _, _ = content.measure(Gtk.Orientation.VERTICAL, WIDTH)
        h = min(nat, cap)
        if self.get_mapped() and self._settling() and h > max(self.get_height() - bar_h, 0):
            return False   # a page measured right after being shown can report nonsense
        if main:
            self.scroller.set_min_content_height(h)
        self.set_default_size(WIDTH, h + bar_h)
        if self.get_mapped() and 0 < self.get_height() and self.get_height() - (h + bar_h) > 2:
            self._hypr_resize(h + bar_h)   # GTK won't shrink a mapped window; ask the compositor
        return False

    def _settling(self):
        return GLib.get_monotonic_time() < self.settle_until

    def _on_prompt_changed(self):
        """The input row grows with its text: refit once layout has caught up."""
        self.schedule_fit(60)

    def _hypr_resize(self, height):
        """Ask Hyprland to resize this floating window (the only way to shrink it)."""
        cmd = f'hl.dsp.window.resize({{ window = "pid:{os.getpid()}", x = {WIDTH}, y = {height} }})'
        try:
            subprocess.Popen(["hyprctl", "dispatch", cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError:
            pass

    def _on_content_changed(self, adj):
        """Content height changed. While streaming, the answer is only appended to one text view
        (no rows are added or removed), so the adjustment's laid-out `upper` is exact: size the
        window straight to it, snappy and tied to the text. During row changes `upper` can spike,
        so there we fall back to the settled measure in fit()."""
        if self.stack.get_visible_child() is not self.scroller:
            return
        if self.busy and not self._streaming:
            # Spinner phase: rows just changed (deactivate + new output row), so `upper` is
            # unreliable — size from the settled natural measure like every other row change.
            self.schedule_fit()
            return
        if self.busy:
            _, bar_h, _, _ = self.menubar.measure(Gtk.Orientation.VERTICAL, WIDTH)
            h = min(int(adj.get_upper()), self.max_height - bar_h)
            if h != self.scroller.get_min_content_height():
                self.scroller.set_min_content_height(h)
                self.set_default_size(WIDTH, h + bar_h)
                if self.get_mapped() and 0 < self.get_height() and self.get_height() - (h + bar_h) > 2:
                    self._hypr_resize(h + bar_h)
            adj.set_value(adj.get_upper() - adj.get_page_size())
        else:
            self.schedule_fit()
            if self.stick_bottom:
                adj.set_value(adj.get_upper() - adj.get_page_size())

    def _refit_and_scroll(self):
        self.stick_bottom = True
        self.schedule_fit()
        adj = self.scroller.get_vadjustment()
        adj.set_value(adj.get_upper() - adj.get_page_size())
        GLib.timeout_add(400, self._unstick)
        return False

    def _unstick(self):
        self.stick_bottom = False
        return False

    def _settle_after_stream(self):
        """End-of-stream transition: the follow-up input and action rows were just appended.
        Grow the window to the full content immediately (the rows are laid out by now), then
        keep the input in view only if the content overflows the height cap. Doing the grow
        before the scroll avoids the streaming-height window flashing with taller content."""
        self.fit()
        adj = self.scroller.get_vadjustment()
        if adj.get_upper() - adj.get_page_size() > 1:   # taller than the cap → show the bottom
            adj.set_value(adj.get_upper() - adj.get_page_size())
        return False

    # ---- menu bar: Menu on the left, clickable model on the right
    def _build_menubar(self):
        bar = Gtk.Box(css_classes=["menubar"])

        menu = Gio.Menu()
        menu.append("Transform", "app.main")
        menu.append("Settings", "app.settings")
        menu.append("Quit", "app.quit")
        mb = Gtk.MenuButton(label="Menu", menu_model=menu, has_frame=False, can_focus=False)
        mb.get_popover().set_has_arrow(False)
        bar.append(mb)

        # App title, then (in transform mode) a breadcrumb to the app the selection came from:
        # "Recast › Firefox". In direct-chat mode there is no source text, so just "Recast".
        crumbs = Gtk.Box(spacing=12, valign=Gtk.Align.CENTER, css_classes=["crumbs"])
        crumbs.append(label("Recast", ["title"]))
        if self.has_selection and self.source_win:
            crumbs.append(label("›", ["crumb-sep"]))
            crumbs.append(label(app_name(self.source_win)))
        bar.append(crumbs)

        bar.append(Gtk.Box(hexpand=True))   # spacer pushes the pickers to the right

        # Plain buttons (not GtkMenuButton): the dropdown is a custom floating popover that both
        # a click and the keyboard shortcut open. A GtkPopoverMenu can't take keyboard focus under
        # this compositor, so its items can't be arrow-navigated. Sized to their text so the
        # dropdown lands under the actual selector.
        self.model_btn = Gtk.Button(label=self._picker_btn_label(model_label(self.cfg["model"])),
                                     has_frame=False, can_focus=False)
        self.model_btn.connect("clicked", lambda *_: self.open_model_picker())
        bar.append(self.model_btn)

        self.effort_btn = Gtk.Button(has_frame=False, can_focus=False)
        self.effort_btn.connect("clicked", lambda *_: self.open_effort_picker())
        bar.append(self.effort_btn)
        self._sync_effort_widget()
        return bar

    def _picker_btn_label(self, text):
        return f"{text}  ⌄"

    # ---- main page
    def _build_main(self, selection):
        self.list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, css_classes=["list"])
        self.scroller = Gtk.ScrolledWindow(child=self.list, hscrollbar_policy=Gtk.PolicyType.NEVER,
                                           propagate_natural_height=True, vexpand=True)

        # Transform mode shows the selected text as an editable row; direct-chat mode (no
        # selection) shows no source row at all — the input below is the conversation.
        self.source = None
        if selection:
            src = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8, css_classes=["row"])
            self.source = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR)
            self.source.get_buffer().set_text(selection)
            self.source.get_buffer().connect("changed", self.fit)
            src.append(self.source)
            self.list.append(src)

        placeholder = "Ask anything…" if not selection else "How should I change this?"
        self.prompt = PromptRows(self._send, on_change=self._on_prompt_changed, placeholder=placeholder)
        self.list.append(self.prompt)
        self.scroller.get_vadjustment().connect("changed", self._on_content_changed)
        return self.scroller

    # ---- settings page
    def _build_settings(self):
        page = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=22,
                       margin_top=18, margin_bottom=18, margin_start=20, margin_end=20)

        def section(title, widget):
            box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
            box.append(label(title, ["muted"]))
            box.append(widget)
            page.append(box)

        self.key_entry = Gtk.PasswordEntry(show_peek_icon=True, css_classes=["field"],
                                           placeholder_text="sk-or-…  (or set OPENROUTER_API_KEY)")
        self.key_entry.set_text(self.cfg.get("api_key", ""))
        self._key_timer = 0
        self.key_entry.connect("changed", self._on_key_changed)
        section("OpenRouter API key", self.key_entry)
        where = ("Stored in your system keyring (gnome-keyring), never written to disk"
                 if self.cfg.get("_key_store") == "keyring"
                 else "No keyring available: stored in ~/.config/ai-transform/config.json (mode 600)")
        if os.environ.get("OPENROUTER_API_KEY"):
            where = "OPENROUTER_API_KEY is set in the environment and takes precedence"
        page.append(label(where, ["muted"], wrap=True))

        self.model_drop = Gtk.DropDown.new_from_strings([name for _, name, *_ in MODELS])
        self.model_drop.set_css_classes(["field"])
        self.custom_entry = Gtk.Entry(css_classes=["field"],
                                      placeholder_text="custom model id, overrides the list (e.g. openai/gpt-6-astra-pro)")
        self._sync_model_widgets()
        self.model_drop.connect("notify::selected", self._on_settings_changed)
        self.custom_entry.connect("changed", self._on_settings_changed)
        section("Model", self.model_drop)
        section("Custom model id", self.custom_entry)

        self.copy_check = Gtk.CheckButton(label="Copy output to clipboard automatically")
        self.copy_check.set_active(bool(self.cfg.get("auto_copy", True)))
        self.copy_check.connect("toggled", self._on_settings_changed)
        page.append(self.copy_check)

        self.sys_view = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR, top_margin=4, bottom_margin=8)
        self.sys_view.get_buffer().set_text(self.cfg.get("system_prompt", DEFAULT_SYSTEM_PROMPT))
        self.sys_view.get_buffer().connect("changed", self._on_settings_changed)
        sw = Gtk.ScrolledWindow(child=self.sys_view, css_classes=["field"], min_content_height=100,
                                propagate_natural_height=True, max_content_height=260,
                                hscrollbar_policy=Gtk.PolicyType.NEVER)
        section("System prompt", sw)
        reset = Gtk.Button(label="Reset system prompt", halign=Gtk.Align.START, css_classes=["flat", "muted"])
        reset.connect("clicked", lambda *_: self.sys_view.get_buffer().set_text(DEFAULT_SYSTEM_PROMPT))
        page.append(reset)
        page.append(label("Saved automatically · Esc to go back", ["muted"]))
        return page

    def _sync_model_widgets(self):
        """Reflect cfg['model'] in the dropdown / custom field without triggering saves."""
        self._syncing = True
        model = self.cfg["model"]
        if model in MODEL_IDS:
            self.model_drop.set_selected(MODEL_IDS.index(model))
            self.custom_entry.set_text("")
        else:
            self.custom_entry.set_text(model)
        self._syncing = False

    def _on_key_changed(self, *_):
        """Write the key to the keyring once typing pauses (avoids a store per keystroke)."""
        if self._key_timer:
            GLib.source_remove(self._key_timer)
        self._key_timer = GLib.timeout_add(500, self._flush_key)

    def _flush_key(self):
        self._key_timer = 0
        store_api_key(self.cfg, self.key_entry.get_text())
        return False

    def _on_settings_changed(self, *_):
        if getattr(self, "_syncing", False):
            return
        custom = self.custom_entry.get_text().strip()
        model = custom or MODEL_IDS[self.model_drop.get_selected()]
        buf = self.sys_view.get_buffer()
        self.cfg.update({
            "model": model,
            "system_prompt": buf.get_text(buf.get_start_iter(), buf.get_end_iter(), True).strip() or DEFAULT_SYSTEM_PROMPT,
            "auto_copy": self.copy_check.get_active(),
        })
        save_config(self.cfg)
        self.model_btn.set_label(self._picker_btn_label(model_label(model)))
        self.get_application().lookup_action("model").set_state(GLib.Variant("s", model))
        self._sync_effort_widget()
        self.fit()

    def set_model(self, model):
        """From the model picker."""
        self.cfg["model"] = model
        save_config(self.cfg)
        self.model_btn.set_label(self._picker_btn_label(model_label(model)))
        self.get_application().lookup_action("model").set_state(GLib.Variant("s", model))
        self._sync_effort_widget()
        self._sync_model_widgets()

    def set_effort(self, effort):
        """From the effort picker."""
        self.cfg["effort"] = effort
        save_config(self.cfg)
        self.get_application().lookup_action("effort").set_state(GLib.Variant("s", effort))
        self._sync_effort_widget()

    def _sync_effort_widget(self):
        """Show the effort button only for models that support reasoning (OpenRouter rejects a
        reasoning request to those that don't); it disappears otherwise and reappears when a
        reasoning model is selected."""
        supported = model_supports_reasoning(self.cfg["model"])
        self.effort_btn.set_visible(supported)
        if supported:
            self.effort_btn.set_label(self._picker_btn_label(effort_label(self.cfg.get("effort", "default"))))
        elif getattr(self, "_picker_kind", None) == "effort":
            self._close_picker()   # model changed out from under an open effort picker

    # ---- dropdown picker: a floating popover (its own surface, so the window stays tight) that
    # does NOT grab the keyboard (autohide=False), so the window's capture key controller keeps
    # driving it (Ctrl+M model, Ctrl+E effort to toggle; ↑/↓ move, Enter selects, Esc closes).
    def _build_picker(self):
        self._picker_open = False
        self._picker_kind = None
        self._picker_index = 0
        self._picker_rows = []          # (value, row widget)

        self.picker_list = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.picker_scroll = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER,
                                                propagate_natural_height=True)
        self.picker_scroll.set_child(self.picker_list)
        self.picker_pop = Gtk.Popover(autohide=False, has_arrow=False, css_classes=["picker"])
        self.picker_pop.set_child(self.picker_scroll)
        self.picker_pop.set_position(Gtk.PositionType.BOTTOM)

        kc = Gtk.EventControllerKey()
        kc.set_propagation_phase(Gtk.PropagationPhase.CAPTURE)   # see keys before the focused input
        kc.connect("key-pressed", self._on_picker_key)
        self.add_controller(kc)

    def open_model_picker(self):
        self._open_picker("model", self.model_btn,
                          [(m, model_label(m)) for m, *_ in MODELS], self.cfg["model"])

    def open_effort_picker(self):
        if not model_supports_reasoning(self.cfg["model"]):
            return
        self._open_picker("effort", self.effort_btn, list(EFFORTS), self.cfg.get("effort", "default"))

    def _open_picker(self, kind, anchor, items, current):
        if self._picker_open and self._picker_kind == kind:
            self._close_picker()          # same shortcut again toggles it shut
            return
        if self._picker_open:
            self._close_picker()          # switching between pickers
        child = self.picker_list.get_first_child()
        while child is not None:
            self.picker_list.remove(child)
            child = self.picker_list.get_first_child()
        self._picker_rows = []
        self._picker_index = 0
        for i, (value, text) in enumerate(items):
            row = label(text, ["picker-row"])
            gc = Gtk.GestureClick()
            gc.connect("released", lambda _g, _n, _x, _y, v=value: self._commit_picker(v))
            row.add_controller(gc)
            self.picker_list.append(row)
            self._picker_rows.append((value, row))
            if value == current:
                self._picker_index = i
        # cap the height to a fraction of the screen; taller lists scroll inside the popover
        self.picker_scroll.set_max_content_height(int(self.max_height * 0.9))
        self._picker_kind = kind
        self._picker_open = True
        if self.picker_pop.get_parent() is not anchor:
            if self.picker_pop.get_parent() is not None:
                self.picker_pop.unparent()
            self.picker_pop.set_parent(anchor)
        self._highlight_picker()
        self.picker_pop.popup()
        GLib.idle_add(self._scroll_to_selected)

    def _highlight_picker(self):
        for i, (_v, row) in enumerate(self._picker_rows):
            if i == self._picker_index:
                row.add_css_class("sel")
            else:
                row.remove_css_class("sel")

    def _on_picker_key(self, _ctrl, keyval, _code, state):
        ctrl = state & Gdk.ModifierType.CONTROL_MASK
        # Ctrl+M / Ctrl+E toggle their picker even while one is open (same key closes it).
        if ctrl and keyval in (Gdk.KEY_m, Gdk.KEY_M):
            self.open_model_picker()
            return True
        if ctrl and keyval in (Gdk.KEY_e, Gdk.KEY_E):
            self.open_effort_picker()
            return True
        if not self._picker_open:
            return False
        n = len(self._picker_rows)
        if keyval in (Gdk.KEY_Up, Gdk.KEY_KP_Up):
            self._picker_index = (self._picker_index - 1) % n
            self._highlight_picker()
            self._scroll_to_selected()
        elif keyval in (Gdk.KEY_Down, Gdk.KEY_KP_Down):
            self._picker_index = (self._picker_index + 1) % n
            self._highlight_picker()
            self._scroll_to_selected()
        elif keyval in (Gdk.KEY_Return, Gdk.KEY_KP_Enter, Gdk.KEY_ISO_Enter, Gdk.KEY_space):
            self._commit_picker(self._picker_rows[self._picker_index][0])
        elif keyval == Gdk.KEY_Escape:
            self._close_picker()
        # swallow every key while the picker is open so nothing leaks into the input
        return True

    def _scroll_to_selected(self):
        if not self._picker_rows:
            return False
        _, row = self._picker_rows[self._picker_index]
        ok, r = row.compute_bounds(self.picker_list)
        if ok:
            adj = self.picker_scroll.get_vadjustment()
            top, bottom = r.get_y(), r.get_y() + r.get_height()
            if top < adj.get_value():
                adj.set_value(top)
            elif bottom > adj.get_value() + adj.get_page_size():
                adj.set_value(bottom - adj.get_page_size())
        return False

    def _commit_picker(self, value):
        kind = self._picker_kind
        self._close_picker()
        if kind == "model":
            self.set_model(value)
        else:
            self.set_effort(value)

    def _close_picker(self):
        self._picker_open = False
        self._picker_kind = None
        self.picker_pop.popdown()

    # ---- navigation
    def show_settings(self):
        if self._picker_open:
            self._close_picker()
        self.stack.set_visible_child_name("settings")
        focus_later(self.key_entry)
        self.refit()

    def show_main(self):
        if self._picker_open:
            self._close_picker()
        self.stack.set_visible_child_name("main")
        GLib.idle_add(self._focus_prompt)
        self.refit()

    def _focus_prompt(self):
        child = self.list.get_last_child()
        if isinstance(child, PromptRows):
            child.entry.grab_focus()
        return False

    def _kick_caret(self):
        """Make the input caret appear on open. A text view focused before the toplevel got
        keyboard focus never starts its caret blink, and GTK will not re-run focus-in on a widget
        it already considers focused. Force a real focus-out/in cycle (drop window focus, then
        regrab the input) and invalidate the view so the blinking caret is painted."""
        if self._caret_kicked or not self.is_active() or self.stack.get_visible_child() is not self.scroller:
            return
        child = self.list.get_last_child()
        if not isinstance(child, PromptRows):
            return
        self._caret_kicked = True
        child.entry.grab_focus()
        # Under this compositor a programmatically focused text view does not paint its caret
        # until a real input event arrives (which is why clicking or typing fixes it). Deliver
        # two self-cancelling real key events to our own window (space, then backspace) so the
        # caret arms exactly as it does when you type, while leaving the field unchanged.
        pid = os.getpid()

        def tap(key):
            try:
                subprocess.Popen(
                    ["hyprctl", "dispatch",
                     f'hl.dsp.send_shortcut({{ mods = "", key = "{key}", window = "pid:{pid}" }})'],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                pass

        def arm():
            # A content edit is what reliably repaints the caret when a programmatic focus does
            # not; space then backspace fires ~250ms after the input appears (before any typing),
            # and nets no change (also a no-op at the end of a prefilled follow-up).
            tap("space")
            GLib.timeout_add(30, lambda: tap("BackSpace") or False)
            return False
        GLib.idle_add(arm)

    def _on_key(self, _ctrl, keyval, _code, state):
        ctrl = state & Gdk.ModifierType.CONTROL_MASK
        shift = state & Gdk.ModifierType.SHIFT_MASK
        if keyval == Gdk.KEY_Escape:
            if self.stack.get_visible_child_name() == "settings":
                self.show_main()
            else:
                self.close()
            return True
        if ctrl and shift and keyval in (Gdk.KEY_C, Gdk.KEY_c):
            self.copy_last()
            return True
        return False

    # ---- conversation
    def _source_text(self):
        if self.source is None:
            return ""
        buf = self.source.get_buffer()
        return buf.get_text(buf.get_start_iter(), buf.get_end_iter(), True).strip()

    def _send(self, prompt):
        if self.busy:
            return
        instruction = prompt.text()
        if not instruction:
            return
        if not api_key(self.cfg):
            self.show_settings()
            return
        if not self.messages:
            text = self._source_text()
            if text:   # transform mode: instruction applied to the selected text
                self.messages.append({"role": "system", "content": self.cfg["system_prompt"]})
                self.messages.append({"role": "user", "content": f"Instruction: {instruction}\n\nText:\n{text}"})
                self.source.set_editable(False)
            else:      # direct-chat mode: no source text, just talk to the model
                self.messages.append({"role": "system", "content": CHAT_SYSTEM_PROMPT})
                self.messages.append({"role": "user", "content": instruction})
        else:
            self.messages.append({"role": "user", "content": instruction})

        prompt.deactivate(instruction)
        self.busy = True
        self._streaming = False       # spinner phase: size via the settled measure, not `upper`
        self.output = OutputRow(self.cfg["model"])
        self.list.append(self.output)
        self.output.start_spinner()   # spin until the first token; growth follows the content
        self.schedule_fit()           # tighten to the content now (spinner adds only one line)

        threading.Thread(
            target=stream_completion,
            args=(self.cfg, list(self.messages), self._on_delta, self._on_done, self._on_error),
            daemon=True,
        ).start()

    def _on_delta(self, delta):
        # First real token: switch from the spinner's settled-measure sizing to the tight,
        # append-only `upper` path (see _on_content_changed).
        self._streaming = True
        # Just append; the scroller's content-change hook sizes the window to the laid-out text.
        self.output.append_text(delta)
        return False

    def _add_followup(self, prefill=""):
        self.busy = False
        actions = []
        if self.last_answer:
            actions = [("Copy output", self._on_copy_clicked), ("Regenerate", self._regenerate)]
            if self.source_win:
                actions.append((f"Insert in {app_name(self.source_win)}", self._insert))
        rows = PromptRows(self._send, actions=actions, placeholder="Ask follow up…",
                          on_change=self._on_prompt_changed)
        rows.set_text(prefill)
        self.list.append(rows)
        focus_later(rows.entry)
        self._caret_kicked = False          # the new input needs its caret kicked too
        GLib.timeout_add(120, lambda: self._kick_caret() or False)
        # Grow to include the new rows in one step, before any scroll, so the window
        # never lingers at the streaming height with the taller content already shown.
        GLib.idle_add(self._settle_after_stream, priority=GLib.PRIORITY_HIGH_IDLE)
        return rows

    def _on_done(self, answer):
        answer = answer.strip()
        self.output.set_text(answer)
        self.messages.append({"role": "assistant", "content": answer})
        self.last_answer = answer
        rows = self._add_followup()
        if self.cfg.get("auto_copy", True) and answer and copy_to_clipboard(answer):
            rows.set_hint(0, "copied to clipboard")
        return False

    def _on_error(self, msg):
        self.output.set_text(f"Error: {msg}", error=True)
        failed = self.messages.pop()["content"]  # drop the failed user turn so a retry is clean
        if len(self.messages) == 1:
            self.messages.clear()
            if self.source is not None:
                self.source.set_editable(True)
            failed = failed.split("\n\nText:\n", 1)[0].removeprefix("Instruction: ")
        self._add_followup(prefill=failed)
        return False

    def _on_copy_clicked(self, rows):
        if self.copy_last():
            rows.set_hint(0, "copied ✓")

    def _regenerate(self, rows):
        """Drop the last answer and ask again with the same conversation and model."""
        if self.busy or not self.messages or self.messages[-1]["role"] != "assistant":
            return
        self.messages.pop()
        self.list.remove(rows)
        self.list.remove(self.output)
        self.last_answer = ""
        self.busy = True
        self.output = OutputRow(self.cfg["model"])
        self.list.append(self.output)
        GLib.idle_add(self._refit_and_scroll)
        threading.Thread(
            target=stream_completion,
            args=(self.cfg, list(self.messages), self._on_delta, self._on_done, self._on_error),
            daemon=True,
        ).start()

    def _insert(self, rows):
        """Paste the output into the window the selection came from, then close."""
        if not (self.last_answer and self.source_win) or not copy_to_clipboard(self.last_answer):
            return
        addr = self.source_win["address"]
        mods = "CTRL SHIFT" if self.source_win["class"] in TERMINAL_CLASSES else "CTRL"
        hypr(f'hl.dsp.focus({{ window = "address:{addr}" }})')
        hypr(f'hl.dsp.send_shortcut({{ mods = "{mods}", key = "v", window = "address:{addr}" }})')
        rows.set_hint(2, "inserted")
        GLib.timeout_add(150, self.close)

    def copy_last(self):
        return bool(self.last_answer) and copy_to_clipboard(self.last_answer)


class App(Gtk.Application):
    def __init__(self, selection, open_settings, source=None):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.NON_UNIQUE)
        self.selection = selection
        self.open_settings = open_settings
        self.source = source

    def do_startup(self):
        Gtk.Application.do_startup(self)
        cfg = resolve_api_key(load_config())
        provider = Gtk.CssProvider()
        provider.load_from_string(build_css(load_theme()))
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_USER)

        for name, cb, accel in (
            ("settings", lambda *_: self.win.show_settings(), "<Control>comma"),
            ("main", lambda *_: self.win.show_main(), "<Control>t"),
            ("quit", lambda *_: self.win.close(), "<Control>q"),
        ):
            act = Gio.SimpleAction.new(name, None)
            act.connect("activate", cb)
            self.add_action(act)
            self.set_accels_for_action(f"app.{name}", [accel])

        model = Gio.SimpleAction.new_stateful("model", GLib.VariantType("s"), GLib.Variant("s", cfg["model"]))

        def on_model(action, value):
            action.set_state(value)
            self.win.set_model(value.get_string())

        model.connect("activate", on_model)
        self.add_action(model)

        effort = Gio.SimpleAction.new_stateful(
            "effort", GLib.VariantType("s"), GLib.Variant("s", cfg.get("effort", "default")))

        def on_effort(action, value):
            action.set_state(value)
            self.win.set_effort(value.get_string())

        effort.connect("activate", on_effort)
        self.add_action(effort)
        self.cfg = cfg

    def do_activate(self):
        self.win = Window(self, self.cfg, self.selection, self.open_settings, self.source)
        self.win.present()


def main():
    open_settings = "--settings" in sys.argv
    chat = "--chat" in sys.argv          # open empty for direct chat, ignoring any selection
    selection = "" if (open_settings or chat) else read_selection()
    source = None if open_settings else source_window()   # before our own window exists
    App(selection, open_settings, source).run([])


if __name__ == "__main__":
    main()
