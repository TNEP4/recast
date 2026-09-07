# Build log — AI Transform

Chronological record of how the tool was built and the decisions/fixes along the way.
Dates from the session on 2026-09-07.

## 1. Initial build
- GTK4/libadwaita popup bound to `SUPER+I`. Reads the primary selection via
  `wl-paste`, streams an OpenRouter completion, copies to clipboard, keeps a
  conversation for follow-ups. Settings page for API key, model, system prompt.
- Model list built from OpenRouter's live `/models` endpoint (verified IDs).
- Window rule: floating, centered.

## 2. "Make it Omarchy" (drop libadwaita)
- Rewrote in plain GTK4: undecorated window (Hyprland draws the border), zero corner
  radius, JetBrainsMono Nerd Font, theme colors from Omarchy's `colors.toml`.
- Menu bar with a Menu popover and a Model radio list; model name on the far right.

## 3. Simpler, content-hugging layout (Wispr Flow philosophy)
- Full-width rows separated by 1px lines, one thing per row.
- Window sizes to its content and grows with it, capped at 85% of screen height.
- Settings page made full-width, underline-only fields.

## 4. Bug: typing showed one char then vanished
- Cause: deferred `grab_focus` was handed to `GLib.idle_add`; `grab_focus` returns
  True, so idle re-ran it forever (~1M calls in 2s, one full core), resetting the IME
  each keystroke. Fixed to grab once.
- Also fixed: window didn't quit on close (now quits on every close path); the
  clipboard helper captured `wl-copy`'s output (wl-copy leaves that pipe open as a
  server → 2s stall + false failure); now runs detached, ~70ms.

## 5. Window only grew, never shrank when leaving settings
- GTK grows a mapped window when its min size grows but never shrinks it. Added a
  Hyprland resize dispatch to shrink; guarded stale measurements during page switches.

## 6. Multi-line input + Super+Return line break
- Input became a wrapping GtkTextView. Enter sends; Shift/Super+Return insert a
  newline. `SUPER+Return` is Omarchy's terminal shortcut, so a window-aware Lua bind
  forwards it (as Shift+Return) only inside the transform window.

## 7. Placeholder alignment + Regenerate + Insert
- Fixed placeholder vertical centering and a doubled bottom border.
- Added **Regenerate** (drop last answer, re-ask same prompt/model) and
  **Insert in <App>** (focus the source window by address, paste via Ctrl+V, or
  Ctrl+Shift+V for terminals; friendly app names, Omarchy web-app host names).

## 8. Secure key storage
- Key was wiped during testing (config overwritten with a placeholder, then blanked).
  Moved storage to the system keyring (gnome-keyring / Secret Service). config.json
  no longer holds the key; old file keys are migrated to the keyring on launch.
  Lookup order: env var → keyring → file.

## 9. Window ballooned on leaving settings / on errors
- The transform page reported a bogus height while hidden; leaving settings grew the
  window to the cap and nothing shrank it. Drove sizing from the measured content
  height, ignored the first ~250ms of a freshly shown page, shrink via Hyprland.

## 10. Error state ballooned with a huge empty gap
- While rows were swapped, `list.measure()` briefly returned ~623px (the red error
  text wrapped at near-zero width). Debounced the fit so it measures only after row
  changes settle. Error state now compact (~279px).

## 11. Multi-line editing shortcuts
- `Alt/Option+Backspace` deletes the previous word; `Super+Backspace` wipes the
  current logical line (collapsing neighbors). `SUPER+Backspace` is Omarchy's
  transparency toggle, so a window-aware Lua bind forwards it (as Ctrl+Shift+Backspace)
  only inside the transform window.

## 12. Caret not visible on open
- A GtkTextView focused programmatically does not paint its caret under this
  compositor until a real input event (click/keystroke). Pure-GTK tricks (re-grab,
  cursor toggle, redraw, disable blink, focus dance) did not help. Fix: on open and
  when a follow-up input appears, the app delivers a self-cancelling key pair
  (space then backspace) to its own window via `hyprctl`, arming the caret while
  leaving the field empty. NOTE: not visually confirmed in the build environment
  (grim does not capture the caret); pending user confirmation.

## 13. Super+A select all
- Plain `SUPER+A` is unbound in Omarchy, so handled directly in the input:
  selects the whole buffer. Verified via buffer content (select → type replaces all).

## 14. Spinner + tight streaming growth
- Added a braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`, accent color, 90ms) shown until the first
  token.
- Streaming growth was laggy because of the debounce from step 10. While streaming,
  only text is appended to one text view, so the scroller's laid-out `upper` is
  exact — the window now sizes straight to it per content change (snappy, tied to the
  text). The settled measure is kept only for row changes, preserving the step-10 fix.

## 15. Glitch on the streaming→done transition
- When streaming finished, the window briefly showed a broken frame before the final
  layout. Cause: `_add_followup` appended the follow-up input + action rows, then
  scheduled a *debounced* (120ms) fit while immediately scrolling to the bottom. For
  ~120ms the window stayed at the streaming height while the taller final content
  (with the new rows) already existed and was scrolled to the bottom — the answer
  jumped out of view, then snapped back when the delayed fit grew the window.
- Fix: `_settle_after_stream` runs in one `PRIORITY_HIGH_IDLE` step right after the
  rows are appended — grows the window to the full content first, then scrolls only if
  the content overflows the height cap. No debounce lag, no premature scroll.
- Verified deterministically (fake stream: height climbs 303→457px in a single step at
  done, no dip) and end-to-end with a live OpenRouter stream (clean final state).

## 16. Reasoning-effort picker + GPT-5.6 Luna
- Added `openai/gpt-5.6-luna` to the model list.
- Added a reasoning-effort picker to the top bar, right of the model picker, same
  style (a frameless MenuButton + `app.effort` stateful action, persisted in config).
  Levels from OpenRouter's `reasoning.effort` scale: Default / Minimal / Low / Medium /
  High / Max. `Default` omits the `reasoning` field entirely.
- The request adds `"reasoning": {"effort": <level>}` only when the level isn't Default
  *and* the model supports reasoning — OpenRouter rejects a reasoning request to models
  that don't (verified via each model's `supported_parameters`; in our list only Llama 4
  Maverick and Mistral Large 3 lack it). For those the picker greys out ("No reasoning").
- Verified: payload gating unit test (7 cases), widget sensitivity across model swaps,
  and a live request with effort=high accepted by the API.

## 17. Keyboard-drivable model & effort pickers
- Goal: open the model/effort selectors from the keyboard and navigate ↑/↓ + Enter.
- Found a hard limit: under this compositor a `GtkPopoverMenu` (what a `GtkMenuButton`
  opens) cannot take keyboard focus — `grab_focus()` on its items returns False even when
  the popup holds a real keyboard grab (Escape reaches it, but arrows never focus an item).
  Same class of limitation as the caret. Verified injected keys reach the *main window*
  input fine, so the fix lives there.
- Replaced both top-bar selectors with a custom in-window **overlay** picker (a bordered
  panel anchored top-right, one label per row, current row highlighted). It's driven by a
  capture-phase key controller on the window: ↑/↓ move a highlighted index (wrapping),
  Enter/Space commit, Esc or a click on the scrim closes; every key is swallowed while open
  so nothing leaks into the input. Mouse: click the button to open, click a row to pick.
- Shortcuts: `Ctrl+M` model, `Ctrl+E` effort (effort inert on non-reasoning models). The
  buttons became plain `Gtk.Button`s (with a `⌄` caret) that open the same overlay.
- The picker grows the window to fit and caps at the screen fraction, then scrolls.
- Verified end-to-end with real injected keys through the compositor: Ctrl+M → Down×2 →
  Enter selects the expected model and closes; Ctrl+E → Down → Enter changes effort; Escape
  leaves it unchanged; Ctrl+E is inert on Maverick; and normal typing is unaffected when the
  picker is closed.

## 18. Floating dropdown (window stays tight) + toggle + effort hide
- The step-17 overlay grew the window to fit the list. Reworked the picker into a
  floating `Gtk.Popover(autohide=False)` anchored under the selector: it's its own
  surface, so the **window height never changes** when it opens; a list taller than ~90%
  of the screen scrolls inside the popover. `autohide=False` is the key — the popover does
  not grab the keyboard, so the window keeps focus and the same capture-phase handler
  still drives ↑/↓ / Enter / Esc (a `GtkPopoverMenu`, which grabs, is what broke keyboard
  nav in step 17's investigation).
- The top-bar buttons are right-aligned with a spacer and sized to their text, so the
  dropdown lands under the actual selector.
- `Ctrl+M` / `Ctrl+E` now toggle (same key opens and closes); handled entirely in the
  capture controller, and the app-level accelerators for them were removed so they don't
  double-fire and cancel the toggle.
- The effort selector is now **hidden entirely** for models without reasoning (was greyed
  "No reasoning") and reappears for reasoning models; an open effort picker closes if the
  model changes out from under it.
- Verified end-to-end with injected keys: window height unchanged on open/close, Ctrl+M
  toggles, ↑/↓+Enter selects, Esc closes the picker (not the window), typing works before
  and after, and the effort button vanishes/reappears with model capability. Screenshots
  confirm both dropdowns float under their selectors with the window tight.

## 19. Tight, consistent output area during the follow-up spinner
- On a follow-up, the new answer area grew too tall while the spinner waited for the first
  token, leaving a dead grey band — inconsistent with the first response.
- Cause: the `busy` branch of `_on_content_changed` sized from `adj.get_upper()`, which is
  right only while streaming (append-only). At a send's start the rows just changed
  (`deactivate()` drops the input + Copy/Regenerate/Insert rows, a fresh OutputRow is
  appended), so `upper` was stale/tall and the window didn't shrink to the real content.
- Fix: a `self._streaming` flag, False during the spinner and set True on the first token.
  While `busy and not streaming`, size via the settled `fit()` (the same natural-measure
  path row changes already use) so the window hugs the content; only once tokens stream do
  we use the tight, snappy `upper` path. `_send` also calls `schedule_fit()` right after
  starting the spinner.
- Verified: excess (window − bar − content) is 0 across spinner, streaming, and done for a
  follow-up, and a screenshot shows the spinner state tight with no dead band.

## 20. Top-bar title + source-app breadcrumb
- Added, right of the Menu button: the app title **Recast** (plain bold text, not a
  button) then a breadcrumb `› <source app>` naming the app the selection came from
  (via `app_name(source_win)`), e.g. `Recast › Firefox`, with a 12px gap between parts.
- The breadcrumb (separator + name) is shown only when a source window was detected;
  otherwise just "Recast" appears. Separator is muted; title bold.

## 21. Direct-chat mode (selection optional)
- Recast can now open without selected text and act as a plain assistant, reusing all the
  existing machinery (streaming, spinner, follow-ups, Copy/Regenerate/Insert, sizing).
- `_build_main` only adds the source-text row when there is a selection; otherwise the
  input row is the conversation. `_send`'s first turn branches: with source text →
  transform (`Instruction: …\n\nText: …`, transform system prompt); without → chat (the
  instruction as-is, new `CHAT_SYSTEM_PROMPT`). The old "Add some text above first" block
  is gone. `_source_text`/`_on_error` guard the now-optional `self.source`.
- The breadcrumb (`Recast › <app>`) shows only in transform mode; chat shows just "Recast".
- New launch flag `--chat` opens empty regardless of any (possibly stale) selection, bound
  to `SUPER+SHIFT+I`; `SUPER+I` still transforms the selection. Both binds verified via
  `hyprctl binds`, no config errors.
- Verified: chat first message carries CHAT_SYSTEM_PROMPT + the bare question, follow-ups
  keep context, actions present; screenshots of both the App path and the real `--chat`
  binary show a tight empty window with no source row and no breadcrumb.

## Open items
- Plain `SUPER+I` still reads the primary selection / clipboard, so it can show stale text
  when nothing is freshly selected; `SUPER+SHIFT+I` is the clean empty entry. Revisit if a
  smarter "fresh selection only" heuristic is wanted.
- Confirm the caret is visible on open and in follow-up inputs (step 12).
- If not, draw a cursor indicator manually.
