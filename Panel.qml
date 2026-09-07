// Recast — Omarchy panel plugin (Path A: native QML rewrite).
//
// A summoned floating surface. The host (omarchy-shell) mounts this root Item and calls the
// lifecycle hooks; the plugin owns its layer-shell PanelWindow. The Hyprland keybind summons
// with a JSON payload carrying the primary selection and the source window:
//   omarchy-shell shell toggle io.github.tnep4.recast '{"selection":"…","app":"Firefox","addr":"0x..","class":"firefox","mode":"transform"}'
//
// Streams OpenRouter completions (curl -N SSE) into a scrolling conversation, with follow-ups,
// copy, regenerate, and insert-into-source-app.
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // ---- config / constants -------------------------------------------------------------
  readonly property string apiUrl: "https://openrouter.ai/api/v1/chat/completions"
  readonly property string transformPrompt:
    "You transform text. The user gives an instruction and a piece of text. Apply the " +
    "instruction to the text and reply with ONLY the transformed text: no preamble, no " +
    "explanation, no quotes, no markdown fences, unless the instruction explicitly asks for " +
    "them. Preserve the original language unless asked to translate. For follow-up " +
    "instructions, refine your previous answer."
  readonly property string chatPrompt:
    "You are Recast, a helpful, concise assistant. Answer the user directly and clearly. " +
    "Keep formatting light (plain text; the answer is shown in a simple text view)."
  readonly property string spinnerFrames: "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
  readonly property var terminalClasses: ["org.omarchy.terminal", "Alacritty", "kitty", "foot",
    "org.codeberg.dnkl.foot", "com.mitchellh.ghostty"]

  // (id, label, reasoning) — reasoning=false models reject an OpenRouter reasoning request.
  readonly property var models: [
    { id: "anthropic/claude-fable-5.1", label: "Claude Fable 5.1", reasoning: true },
    { id: "anthropic/claude-opus-5", label: "Claude Opus 5", reasoning: true },
    { id: "anthropic/claude-sonnet-5", label: "Claude Sonnet 5", reasoning: true },
    { id: "openai/gpt-6-astra", label: "GPT-6 Astra", reasoning: true },
    { id: "openai/gpt-5.6-sol", label: "GPT-5.6 Sol", reasoning: true },
    { id: "openai/gpt-5.6-terra", label: "GPT-5.6 Terra", reasoning: true },
    { id: "openai/gpt-5.6-luna", label: "GPT-5.6 Luna", reasoning: true },
    { id: "google/gemini-3.8-flash", label: "Gemini 3.8 Flash", reasoning: true },
    { id: "meta/muse-spark-1.3", label: "Meta Muse Spark 1.3", reasoning: true },
    { id: "meta-llama/llama-4-maverick", label: "Meta Llama 4 Maverick", reasoning: false },
    { id: "x-ai/grok-4.6", label: "Grok 4.6", reasoning: true },
    { id: "deepseek/deepseek-v4-pro", label: "DeepSeek V4 Pro", reasoning: true },
    { id: "qwen/qwen3.8-max-0902", label: "Qwen 3.8 Max", reasoning: true },
    { id: "moonshotai/kimi-k3", label: "Kimi K3", reasoning: true },
    { id: "mistralai/mistral-large-2512", label: "Mistral Large 3", reasoning: false }
  ]
  readonly property var efforts: [
    { id: "default", label: "Default" }, { id: "minimal", label: "Minimal" }, { id: "low", label: "Low" },
    { id: "medium", label: "Medium" }, { id: "high", label: "High" }, { id: "max", label: "Max" }
  ]
  property string model: "moonshotai/kimi-k3"
  property string effort: "default"
  property bool autoCopy: true
  property bool renderMarkdown: true     // light markdown in answers (toggle in settings)
  property string userSystemPrompt: ""   // empty = use the built-in transformPrompt
  readonly property string configPath: Quickshell.env("HOME") + "/.config/recast/config.json"

  property bool settingsOpen: false
  // dropdown state (shared by the left Menu and the model/effort pickers)
  property string pickerKind: ""   // "" | "menu" | "model" | "effort"
  property int pickerIndex: 0
  property string pickerFilter: ""       // type-to-filter within the model/effort dropdown
  readonly property bool pickerFilterable: pickerKind === "model" || pickerKind === "effort"
  readonly property var menuItems: [{ id: "new", label: "New" }, { id: "settings", label: "Settings" }]
  readonly property var pickerOptions: {
    var base = pickerKind === "model" ? root.models
      : (pickerKind === "effort" ? root.efforts
      : (pickerKind === "menu" ? root.menuItems : []))
    if (!root.pickerFilterable || root.pickerFilter === "") return base
    var f = root.pickerFilter.toLowerCase(), out = []
    for (var i = 0; i < base.length; i++) if (base[i].label.toLowerCase().indexOf(f) !== -1) out.push(base[i])
    return out
  }

  // padding scales with the theme font size (Style.space multiplies by the font scale)
  readonly property int padH: Style.space(20)
  readonly property int padV: Style.space(15)
  readonly property int barFont: Style.font.subtitle   // one consistent top-bar font size

  // the input owns the caret only when no dropdown/settings/action-nav is active
  readonly property bool inputActive: input.activeFocus && root.pickerKind === ""
    && root.actionFocus < 0 && !root.settingsOpen && !root.busy

  // virtual keyboard focus into the action rows below the input (-1 = the input itself)
  property int actionFocus: -1
  readonly property var actionsList: {
    if (root.busy || root.lastAnswer === "") return []
    var a = ["copy", "regenerate"]
    if (root.sourceAddr !== "") a.push("insert")
    return a
  }

  // ---- runtime state ------------------------------------------------------------------
  property string apiKey: Quickshell.env("OPENROUTER_API_KEY")
  property bool opened: false
  property string selection: ""
  property string sourceApp: ""
  property string sourceAddr: ""
  property string sourceClass: ""
  property string mode: "transform"        // "transform" (has selection) | "chat"

  property var messages: []                // API messages (system + wrapped user + assistant)
  property var history: []                 // display turns: [{role:"user"|"assistant", text, isError}]
  property string pendingUser: ""          // last user instruction (for regenerate)
  property bool busy: false
  property bool streaming: false           // true once the first content token arrives
  property string answer: ""               // in-progress assistant text
  property string errorText: ""
  property string lastAnswer: ""
  property string copiedHint: ""
  property int spinIndex: 0

  readonly property int maxHeight: Math.round((panel.height > 0 ? panel.height : 1000) * 0.82)

  function modelLabel(id) {
    for (var i = 0; i < root.models.length; i++) if (root.models[i].id === id) return root.models[i].label
    return id
  }
  function modelReasoning(id) {
    for (var i = 0; i < root.models.length; i++) if (root.models[i].id === id) return root.models[i].reasoning
    return true   // unknown/custom: assume yes, let the API decide
  }
  function effortLabel(id) {
    for (var i = 0; i < root.efforts.length; i++) if (root.efforts[i].id === id) return root.efforts[i].label
    return id
  }
  function isTerminal(cls) { return root.terminalClasses.indexOf(cls) !== -1 }
  function appName(cls) {
    if (!cls) return ""
    var map = {
      "org.omarchy.terminal": "Terminal", "Alacritty": "Alacritty", "kitty": "Kitty",
      "foot": "Foot", "com.mitchellh.ghostty": "Ghostty", "firefox": "Firefox",
      "chromium": "Chromium", "google-chrome": "Chrome", "code": "VS Code", "Code": "VS Code",
      "cursor": "Cursor", "obsidian": "Obsidian", "Slack": "Slack", "discord": "Discord",
      "org.gnome.Nautilus": "Files", "org.telegram.desktop": "Telegram"
    }
    if (map[cls]) return map[cls]
    if (cls.indexOf("chrome-") === 0) {                 // Omarchy web apps: chrome-<host>__…
      var host = cls.substring(7).split("__")[0].split("-Default")[0].replace(/^www\./, "").split(".")[0]
      return host.charAt(0).toUpperCase() + host.slice(1)
    }
    var n = cls.split(".").pop().replace(/-/g, " ")
    return n.charAt(0).toUpperCase() + n.slice(1)
  }

  // ---- lifecycle hooks the host calls -------------------------------------------------
  function open(payloadJson) {
    var p = ({})
    try { p = JSON.parse(payloadJson || "{}") } catch (e) { p = ({}) }
    root.selection = p.selection || ""
    root.sourceClass = p.class || ""
    root.sourceAddr = p.addr || ""
    root.sourceApp = p.app || root.appName(root.sourceClass)
    root.mode = (p.mode === "chat" || !root.selection) ? "chat" : "transform"
    root.messages = []
    root.history = []
    root.pendingUser = ""
    root.answer = ""
    root.errorText = ""
    root.lastAnswer = ""
    root.copiedHint = ""
    root.busy = false
    root.streaming = false
    root.actionFocus = -1
    root.pickerKind = ""
    root.settingsOpen = false
    root.opened = true
    if (!root.apiKey) keyProc.running = true
    Qt.callLater(function () { input.forceActiveFocus() })
  }
  function close() {
    root.opened = false
    if (streamProc.running) streamProc.running = false
    input.text = ""
  }
  function refresh() { return "ok" }
  function ping() { return "ok" }
  // IPC hook for scripting/testing: set the instruction and send.
  function sendText(t) { input.text = t; root.send(); return "ok" }

  // ---- OpenRouter streaming -----------------------------------------------------------
  function send() {
    var instruction = input.text.replace(/^\s+|\s+$/g, "")
    if (root.busy || instruction === "") return
    if (!root.apiKey) { root.errorText = "No API key. Set OPENROUTER_API_KEY or store it in the keyring."; return }

    if (root.messages.length === 0) {
      if (root.selection !== "") {
        root.messages = [
          { role: "system", content: root.userSystemPrompt !== "" ? root.userSystemPrompt : root.transformPrompt },
          { role: "user", content: "Instruction: " + instruction + "\n\nText:\n" + root.selection }
        ]
      } else {
        root.messages = [
          { role: "system", content: root.chatPrompt },
          { role: "user", content: instruction }
        ]
      }
    } else {
      root.messages = root.messages.concat([{ role: "user", content: instruction }])
    }
    root.history = root.history.concat([{ role: "user", text: instruction, isError: false }])
    root.pendingUser = instruction

    input.text = ""
    root.answer = ""
    root.errorText = ""
    root.copiedHint = ""
    root.actionFocus = -1
    root.busy = true
    root.streaming = false
    startStream()
  }

  function startStream() {
    var payload = { model: root.model, messages: root.messages, stream: true }
    if (root.effort !== "default" && root.modelReasoning(root.model))
      payload.reasoning = { effort: root.effort }
    var body = JSON.stringify(payload)
    streamProc.command = [
      "curl", "-sN", "-X", "POST", root.apiUrl,
      "-H", "Authorization: Bearer " + root.apiKey,
      "-H", "Content-Type: application/json",
      "-H", "HTTP-Referer: https://omarchy.org",
      "-H", "X-Title: Recast",
      "-d", body
    ]
    streamProc.running = true
  }

  // SplitParser can hand us a chunk holding one SSE line (often with a leading newline from
  // the blank line between events) or several at once — normalize and scan every line.
  function onSseLine(data) {
    var lines = String(data).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i].replace(/^\s+|\s+$/g, "")
      if (line.indexOf("data:") !== 0) continue    // skip ": OPENROUTER PROCESSING" keep-alives, blanks
      var payload = line.substring(5).replace(/^\s+|\s+$/g, "")
      if (payload === "" || payload === "[DONE]") continue
      var chunk
      try { chunk = JSON.parse(payload) } catch (e) { continue }
      if (chunk.error) { root.errorText = "Error: " + (chunk.error.message || JSON.stringify(chunk.error)); continue }
      var ch = chunk.choices && chunk.choices[0]
      var delta = ch && ch.delta && ch.delta.content
      if (delta) { root.streaming = true; root.answer += delta }
    }
  }

  function onStreamDone(exitCode) {
    root.busy = false
    root.streaming = false
    if (root.answer !== "") {
      root.messages = root.messages.concat([{ role: "assistant", content: root.answer }])
      root.history = root.history.concat([{ role: "assistant", text: root.answer, isError: false }])
      root.lastAnswer = root.answer
      if (root.autoCopy) { copyText(root.answer); root.copiedHint = "copied to clipboard" }
      root.answer = ""
    } else {
      var msg = root.errorText !== "" ? root.errorText
        : ((exitCode && exitCode !== 0) ? "Request failed (curl exit " + exitCode + ")" : "No response from the model.")
      // drop the failed user turn from the API history and prefill the input so a retry is clean
      if (root.messages.length > 0 && root.messages[root.messages.length - 1].role === "user")
        root.messages = root.messages.slice(0, root.messages.length - 1)
      root.history = root.history.concat([{ role: "assistant", text: msg, isError: true }])
      root.errorText = ""
      input.text = root.pendingUser
    }
    Qt.callLater(function () { input.forceActiveFocus(); scrollToBottom() })
  }

  // ---- actions ------------------------------------------------------------------------
  function copyText(t) { copyProc.command = ["wl-copy", "--", t]; copyProc.running = true }
  function openLink(url) { linkProc.command = ["xdg-open", String(url)]; linkProc.running = true }
  function copyLast() { if (root.lastAnswer !== "") { copyText(root.lastAnswer); root.copiedHint = "copied ✓" } }
  function regenerate() {
    if (root.busy || root.lastAnswer === "") return
    // drop the last assistant turn from both histories, then re-stream
    if (root.messages.length > 0 && root.messages[root.messages.length - 1].role === "assistant")
      root.messages = root.messages.slice(0, root.messages.length - 1)
    if (root.history.length > 0 && root.history[root.history.length - 1].role === "assistant")
      root.history = root.history.slice(0, root.history.length - 1)
    root.lastAnswer = ""
    root.answer = ""
    root.copiedHint = ""
    root.actionFocus = -1
    root.busy = true
    root.streaming = false
    startStream()
  }
  function insertIntoSource() {
    if (root.sourceAddr === "" || root.lastAnswer === "") return
    copyText(root.lastAnswer)
    var mods = root.isTerminal(root.sourceClass) ? "CTRL SHIFT" : "CTRL"
    var w = "address:" + root.sourceAddr
    root.close()
    // Omarchy's Hyprland uses Lua dispatchers (hl.dsp.*), not the stock focuswindow/sendshortcut.
    insertProc.command = ["bash", "-c",
      "hyprctl dispatch 'hl.dsp.focus({ window = \"" + w + "\" })'" +
      "; sleep 0.08; " +
      "hyprctl dispatch 'hl.dsp.send_shortcut({ mods = \"" + mods + "\", key = \"v\", window = \"" + w + "\" })'"]
    insertProc.running = true
  }

  function scrollToBottom() { flick.contentY = Math.max(0, flick.contentHeight - flick.height) }

  // ---- model / effort pickers + config persistence ------------------------------------
  function indexOfId(list, id) { for (var i = 0; i < list.length; i++) if (list[i].id === id) return i; return 0 }
  function togglePicker(kind) {
    root.pickerFilter = ""
    if (root.pickerKind === kind) { root.pickerKind = ""; return }
    root.pickerKind = kind
    root.pickerIndex = (kind === "model") ? root.indexOfId(root.models, root.model)
      : (kind === "effort" ? root.indexOfId(root.efforts, root.effort) : 0)
  }
  function closePicker() { root.pickerKind = ""; root.pickerFilter = "" }
  function pickerMove(d) {
    var n = root.pickerOptions.length
    if (n > 0) root.pickerIndex = (root.pickerIndex + d + n) % n
  }
  function pickerType(ch) {   // type-to-filter
    if (!root.pickerFilterable) return
    root.pickerFilter += ch
    root.pickerIndex = 0
  }
  function pickerBackspace() {
    if (root.pickerFilter.length > 0) { root.pickerFilter = root.pickerFilter.slice(0, -1); root.pickerIndex = 0 }
  }
  function pickerCommit() {
    var opt = root.pickerOptions[root.pickerIndex]
    if (opt) {
      if (root.pickerKind === "model") root.setModel(opt.id)
      else if (root.pickerKind === "effort") root.setEffort(opt.id)
      else if (root.pickerKind === "menu") root.runMenu(opt.id)
    }
    root.pickerKind = ""; root.pickerFilter = ""
  }
  function runMenu(id) {
    if (id === "settings") root.openSettings()
    else if (id === "new") root.newConversation()
  }
  function newConversation() {
    if (streamProc.running) streamProc.running = false
    root.messages = []; root.history = []
    root.answer = ""; root.errorText = ""; root.lastAnswer = ""; root.copiedHint = ""
    root.pendingUser = ""; root.actionFocus = -1
    root.busy = false; root.streaming = false
    input.text = ""
    Qt.callLater(function () { input.forceActiveFocus() })
  }

  // ---- action-row keyboard nav (Copy / Regenerate / Insert) ---------------------------
  function actionMove(d) {
    var n = root.actionsList.length
    if (n === 0) return
    if (root.actionFocus < 0) { root.actionFocus = (d > 0) ? 0 : n - 1; return }
    var i = root.actionFocus + d
    if (i < 0) { root.actionFocus = -1; input.forceActiveFocus(); return }   // back up into the input
    root.actionFocus = Math.min(i, n - 1)
  }
  function actionTrigger() {
    if (root.actionFocus < 0 || root.actionFocus >= root.actionsList.length) return
    var id = root.actionsList[root.actionFocus]
    if (id === "copy") root.copyLast()
    else if (id === "regenerate") root.regenerate()
    else if (id === "insert") root.insertIntoSource()
  }

  // ---- input editing (multi-line) -----------------------------------------------------
  function atLastLine() { return input.text.indexOf("\n", input.cursorPosition) < 0 }
  function deleteWordBack() {
    var t = input.text, c = input.cursorPosition
    if (c === 0) return
    var i = c
    while (i > 0 && /\s/.test(t.charAt(i - 1))) i--   // eat the run of spaces before the cursor
    while (i > 0 && !/\s/.test(t.charAt(i - 1))) i--  // then the word
    input.text = t.slice(0, i) + t.slice(c)
    input.cursorPosition = i
  }
  function wipeLine() {
    var t = input.text, c = input.cursorPosition
    var start = t.lastIndexOf("\n", c - 1) + 1
    var end = t.indexOf("\n", c); if (end < 0) end = t.length
    input.text = t.slice(0, start) + t.slice(end)
    input.cursorPosition = start
  }

  function onInputKey(event) {
    var ctrl = event.modifiers & Qt.ControlModifier
    var shift = event.modifiers & Qt.ShiftModifier
    var meta = event.modifiers & Qt.MetaModifier
    var alt = event.modifiers & Qt.AltModifier

    if (ctrl && event.key === Qt.Key_M) { root.togglePicker("model"); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_E && root.modelReasoning(root.model)) { root.togglePicker("effort"); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_Comma) { root.openSettings(); event.accepted = true; return }
    if (ctrl && shift && event.key === Qt.Key_C) { root.copyLast(); event.accepted = true; return }

    if (root.pickerKind !== "") {   // a dropdown is open: drive it (type-to-filter), swallow the rest
      if (event.key === Qt.Key_Up) root.pickerMove(-1)
      else if (event.key === Qt.Key_Down) root.pickerMove(1)
      else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.pickerCommit()
      else if (event.key === Qt.Key_Escape) root.closePicker()
      else if (event.key === Qt.Key_Backspace) root.pickerBackspace()
      else if (root.pickerFilterable && event.text.length === 1 && event.text.charCodeAt(0) >= 0x20) root.pickerType(event.text)
      event.accepted = true
      return
    }

    if (root.actionFocus >= 0) {     // navigating the action rows
      if (event.key === Qt.Key_Up) { root.actionMove(-1); event.accepted = true; return }
      if (event.key === Qt.Key_Down) { root.actionMove(1); event.accepted = true; return }
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.actionTrigger(); event.accepted = true; return }
      if (event.key === Qt.Key_Escape) { root.actionFocus = -1; event.accepted = true; return }
      root.actionFocus = -1   // any other key drops back to typing in the input
    }

    if (ctrl && event.key === Qt.Key_A) { input.selectAll(); event.accepted = true; return }
    if ((alt || ctrl) && event.key === Qt.Key_Backspace) { root.deleteWordBack(); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_W) { root.deleteWordBack(); event.accepted = true; return }
    if (ctrl && event.key === Qt.Key_U) { root.wipeLine(); event.accepted = true; return }

    if (event.key === Qt.Key_Down && root.actionsList.length > 0 && root.atLastLine()) {
      root.actionFocus = 0; event.accepted = true; return
    }

    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
      if (shift || meta) return    // Shift/Super+Return: let TextEdit insert a newline
      root.send(); event.accepted = true; return
    }
    if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true; return }
  }
  function setModel(id) { root.model = id; saveConfig() }
  function setEffort(id) { root.effort = id; saveConfig() }
  function saveConfig() {
    cfgFile.setText(JSON.stringify({
      model: root.model, effort: root.effort, autoCopy: root.autoCopy,
      renderMarkdown: root.renderMarkdown, systemPrompt: root.userSystemPrompt
    }, null, 2) + "\n")
  }
  function openSettings() {
    modelField.text = root.model
    sysEdit.text = root.userSystemPrompt !== "" ? root.userSystemPrompt : root.transformPrompt
    root.settingsOpen = true
    Qt.callLater(function () { keyField.forceActiveFocus() })
  }
  function closeSettings() {
    var m = modelField.text.replace(/^\s+|\s+$/g, "")
    if (m !== "" && m !== root.model) root.model = m
    root.userSystemPrompt = (sysEdit.text === root.transformPrompt) ? "" : sysEdit.text
    saveConfig()
    root.settingsOpen = false; keyField.text = ""
    Qt.callLater(function () { input.forceActiveFocus() })
  }
  function toggleAutoCopy() { root.autoCopy = !root.autoCopy; saveConfig() }
  function toggleMarkdown() { root.renderMarkdown = !root.renderMarkdown; saveConfig() }
  function resetSystemPrompt() { sysEdit.text = root.transformPrompt }

  FileView {
    id: cfgFile
    path: root.configPath
    watchChanges: false
    printErrors: false
    atomicWrites: true
    onLoaded: {
      try {
        var c = JSON.parse(text() || "{}")
        if (c.model) root.model = c.model
        if (c.effort) root.effort = c.effort
        if (c.autoCopy !== undefined) root.autoCopy = !!c.autoCopy
        if (c.renderMarkdown !== undefined) root.renderMarkdown = !!c.renderMarkdown
        if (c.systemPrompt !== undefined) root.userSystemPrompt = String(c.systemPrompt || "")
      } catch (e) {}
    }
  }

  Process {
    id: keyProc
    // prefer the recast-namespaced keyring entry; fall back to the legacy ai-transform one
    command: ["bash", "-c",
      "secret-tool lookup service openrouter app recast 2>/dev/null || secret-tool lookup service openrouter app ai-transform 2>/dev/null"]
    stdout: SplitParser { onRead: function (data) { if (!root.apiKey) root.apiKey = data.replace(/^\s+|\s+$/g, "") } }
  }
  Process { id: keyStoreProc }
  function storeKey(k) {
    root.apiKey = k
    keyStoreProc.command = ["bash", "-c",
      "printf %s \"$1\" | secret-tool store --label='Recast (OpenRouter)' service openrouter app recast",
      "--", k]
    keyStoreProc.running = true
  }
  Process {
    id: streamProc
    stdout: SplitParser { onRead: function (line) { root.onSseLine(line) } }
    onExited: function (exitCode, exitStatus) { root.onStreamDone(exitCode) }
  }
  Process { id: copyProc }
  Process { id: insertProc }
  Process { id: linkProc }
  Process { id: mkdirProc; command: ["mkdir", "-p", Quickshell.env("HOME") + "/.config/recast"] }
  Component.onCompleted: mkdirProc.running = true

  Timer {
    interval: 90; repeat: true; running: root.busy && !root.streaming
    onTriggered: root.spinIndex = (root.spinIndex + 1) % root.spinnerFrames.length
  }
  // keep the newest content in view as it streams / rows are added
  onAnswerChanged: if (root.streaming) scrollToBottom()

  // ---- UI -----------------------------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "recast"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: Color.menu.scrim }
    MouseArea { anchors.fill: parent; onClicked: root.close() }

    Rectangle {
      id: card
      width: 640
      height: Math.min(root.settingsOpen ? settingsView.implicitHeight : content.implicitHeight, root.maxHeight)
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((panel.height - height) / 2))
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: Math.max(1, Style.space(2))
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent }   // swallow clicks so the scrim close doesn't fire

      // settings overlay (Ctrl+,) — key, model, auto-copy, system prompt
      Rectangle {
        id: settingsView
        visible: root.settingsOpen
        z: 20
        anchors.top: parent.top; anchors.left: parent.left
        width: parent.width
        implicitHeight: Math.min(setCol.implicitHeight, root.maxHeight)
        height: implicitHeight
        color: Color.menu.background
        Flickable {
          anchors.fill: parent
          contentHeight: setCol.implicitHeight
          clip: true
          Column {
            id: setCol
            width: parent.width

            // title
            Item {
              width: parent.width; height: 40
              Row {
                anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: root.padH; spacing: 12
                Text { text: "Recast"; color: Color.menu.text; font.bold: true; font.family: Style.font.family; font.pixelSize: Style.font.title }
                Text { text: "Settings"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.title }
              }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
            }

            // API key
            Item {
              width: parent.width; height: keyCol.implicitHeight + root.padV * 2
              Column {
                id: keyCol
                x: root.padH; y: root.padV; width: parent.width - root.padH * 2; spacing: 8
                Text { text: "OpenRouter API key"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
                Rectangle {
                  width: parent.width; height: Style.font.body + 18; color: "transparent"
                  border.color: keyField.activeFocus ? Color.menu.selectedText : Util.alpha(Color.menu.border, 0.5); border.width: 1
                  TextInput {
                    id: keyField
                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter; echoMode: TextInput.Password
                    color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body; clip: true
                    cursorDelegate: Rectangle { width: 2; height: keyField.cursorRectangle.height; color: Color.accent }
                    Text { anchors.verticalCenter: parent.verticalCenter; visible: keyField.text.length === 0; text: "sk-or-…"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body }
                    Keys.onReturnPressed: { if (keyField.text.length > 0) root.storeKey(keyField.text); root.closeSettings() }
                    Keys.onEnterPressed: { if (keyField.text.length > 0) root.storeKey(keyField.text); root.closeSettings() }
                    Keys.onEscapePressed: root.closeSettings()
                  }
                }
                Text { width: parent.width; text: (root.apiKey !== "" ? "A key is set. " : "") + "Stored in the system keyring, never on disk."; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap }
              }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
            }

            // model id (any OpenRouter model; the top-bar picker sets this too)
            Item {
              width: parent.width; height: modelCol.implicitHeight + root.padV * 2
              Column {
                id: modelCol
                x: root.padH; y: root.padV; width: parent.width - root.padH * 2; spacing: 8
                Text { text: "Model id"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
                Rectangle {
                  width: parent.width; height: Style.font.body + 18; color: "transparent"
                  border.color: modelField.activeFocus ? Color.menu.selectedText : Util.alpha(Color.menu.border, 0.5); border.width: 1
                  TextInput {
                    id: modelField
                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                    verticalAlignment: TextInput.AlignVCenter
                    color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body; clip: true
                    cursorDelegate: Rectangle { width: 2; height: modelField.cursorRectangle.height; color: Color.accent }
                    Keys.onReturnPressed: root.closeSettings()
                    Keys.onEnterPressed: root.closeSettings()
                    Keys.onEscapePressed: root.closeSettings()
                  }
                }
              }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
            }

            // auto-copy toggle
            Item {
              width: parent.width; height: Style.font.body + root.padV * 2
              Row {
                x: root.padH; anchors.verticalCenter: parent.verticalCenter; spacing: 12
                Rectangle {
                  width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter
                  color: root.autoCopy ? Color.accent : "transparent"
                  border.color: root.autoCopy ? Color.accent : Util.alpha(Color.menu.border, 0.6); border.width: 1
                  Text { anchors.centerIn: parent; visible: root.autoCopy; text: "✓"; color: Color.menu.background; font.pixelSize: 11; font.family: Style.font.family }
                }
                Text { anchors.verticalCenter: parent.verticalCenter; text: "Copy the answer to the clipboard automatically"; color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body }
              }
              MouseArea { anchors.fill: parent; onClicked: root.toggleAutoCopy() }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
            }

            // render-markdown toggle
            Item {
              width: parent.width; height: Style.font.body + root.padV * 2
              Row {
                x: root.padH; anchors.verticalCenter: parent.verticalCenter; spacing: 12
                Rectangle {
                  width: 16; height: 16; anchors.verticalCenter: parent.verticalCenter
                  color: root.renderMarkdown ? Color.accent : "transparent"
                  border.color: root.renderMarkdown ? Color.accent : Util.alpha(Color.menu.border, 0.6); border.width: 1
                  Text { anchors.centerIn: parent; visible: root.renderMarkdown; text: "✓"; color: Color.menu.background; font.pixelSize: 11; font.family: Style.font.family }
                }
                Text { anchors.verticalCenter: parent.verticalCenter; text: "Render light markdown in answers"; color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body }
              }
              MouseArea { anchors.fill: parent; onClicked: root.toggleMarkdown() }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
            }

            // system prompt (transform mode) + reset
            Item {
              width: parent.width; height: sysCol.implicitHeight + root.padV * 2
              Column {
                id: sysCol
                x: root.padH; y: root.padV; width: parent.width - root.padH * 2; spacing: 8
                Item {
                  width: parent.width; height: sysLbl.implicitHeight
                  Text { id: sysLbl; anchors.left: parent.left; text: "System prompt (transform mode)"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
                  Text {
                    anchors.right: parent.right; text: "Reset"; color: Color.accent; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
                    MouseArea { anchors.fill: parent; onClicked: root.resetSystemPrompt() }
                  }
                }
                Rectangle {
                  width: parent.width; height: Math.min(160, Math.max(84, sysEdit.implicitHeight + 16)); color: "transparent"
                  border.color: sysEdit.activeFocus ? Color.menu.selectedText : Util.alpha(Color.menu.border, 0.5); border.width: 1
                  Flickable {
                    anchors.fill: parent; anchors.margins: 8; clip: true; contentHeight: sysEdit.implicitHeight
                    TextEdit {
                      id: sysEdit
                      width: parent.width
                      color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
                      wrapMode: TextEdit.Wrap; selectByMouse: true
                      selectionColor: Util.alpha(Color.accent, 0.35)
                      cursorDelegate: Rectangle { width: 2; height: sysEdit.cursorRectangle.height; color: Color.accent }
                      Keys.onPressed: function (event) {
                        if ((event.modifiers & Qt.ControlModifier) && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) { root.closeSettings(); event.accepted = true }
                        else if (event.key === Qt.Key_Escape) { root.closeSettings(); event.accepted = true }
                      }
                    }
                  }
                }
                Text { width: parent.width; text: "Ctrl+Enter or Esc to save & close."; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
              }
            }
          }
        }
      }

      // dropdown, floating over the content under the bar: Menu on the left, pickers on the right
      Rectangle {
        id: dropdown
        visible: root.pickerKind !== ""
        z: 10
        width: 240
        x: root.pickerKind === "menu" ? 0 : parent.width - width
        anchors.top: parent.top
        anchors.topMargin: 40
        color: Color.menu.background
        border.color: Color.menu.border
        border.width: Math.max(1, Style.space(2))
        readonly property int headerH: root.pickerFilterable ? 34 : 0
        readonly property int listH: Math.min(pickCol.implicitHeight, (root.maxHeight - 48) - headerH)
        height: headerH + listH
        Column {
          width: parent.width
          // type-to-filter header
          Item {
            width: parent.width; height: dropdown.headerH; visible: root.pickerFilterable
            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left; anchors.leftMargin: 16; anchors.right: parent.right; anchors.rightMargin: 16
              text: root.pickerFilter === "" ? "Type to filter…" : root.pickerFilter
              color: root.pickerFilter === "" ? Color.muted : Color.menu.text
              font.family: Style.font.family; font.pixelSize: root.barFont; elide: Text.ElideRight
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
          }
          Flickable {
            width: parent.width; height: dropdown.listH
            contentHeight: pickCol.implicitHeight
            clip: true
            Column {
              id: pickCol
              width: parent.width
              Repeater {
                model: root.pickerOptions
                delegate: Item {
                  required property var modelData
                  required property int index
                  width: pickCol.width
                  height: 38
                  Rectangle { anchors.fill: parent; color: index === root.pickerIndex ? Color.menu.selectedBackground : "transparent" }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.left: parent.left; anchors.leftMargin: 16; anchors.right: parent.right; anchors.rightMargin: 16
                    text: modelData.label
                    color: index === root.pickerIndex ? Color.menu.selectedText : Color.menu.text
                    font.family: Style.font.family; font.pixelSize: root.barFont
                    elide: Text.ElideRight
                  }
                  MouseArea { anchors.fill: parent; onClicked: { root.pickerIndex = index; root.pickerCommit() } }
                }
              }
              Item { visible: root.pickerOptions.length === 0; width: pickCol.width; height: 38
                Text { anchors.centerIn: parent; text: "No matches"; color: Color.muted; font.family: Style.font.family; font.pixelSize: root.barFont } }
            }
          }
        }
      }

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          width: flick.width

          // ---- top bar: [Menu ⌄] Recast › <app>  ...  [model] [effort] ----
          Item {
            width: parent.width
            height: 40
            Row {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left; anchors.leftMargin: root.padH
              spacing: 12
              TopPicker { label: "Menu"; active: root.pickerKind === "menu"; onClicked: root.togglePicker("menu") }
              Text { text: "Recast"; color: Color.menu.text; font.bold: true; font.family: Style.font.family; font.pixelSize: root.barFont }
              Text { visible: root.mode === "transform" && root.sourceApp !== ""; text: "›"; color: Color.muted; font.family: Style.font.family; font.pixelSize: root.barFont }
              Text { visible: root.mode === "transform" && root.sourceApp !== ""; text: root.sourceApp; color: Color.menu.text; font.family: Style.font.family; font.pixelSize: root.barFont }
            }
            Row {
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right; anchors.rightMargin: root.padH
              spacing: 16
              TopPicker { label: root.modelLabel(root.model); active: root.pickerKind === "model"; onClicked: root.togglePicker("model") }
              TopPicker { visible: root.modelReasoning(root.model); label: root.effortLabel(root.effort); active: root.pickerKind === "effort"; onClicked: root.togglePicker("effort") }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
          }

          // ---- selected text (transform mode) ----
          Item {
            visible: root.mode === "transform" && root.selection !== ""
            width: parent.width
            height: visible ? sel.implicitHeight + root.padV * 2 : 0
            Text {
              id: sel
              x: root.padH; y: root.padV; width: parent.width - root.padH * 2
              text: root.selection
              color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
          }

          // ---- conversation turns ----
          Repeater {
            model: root.history
            delegate: Item {
              required property var modelData
              width: content.width
              implicitHeight: turn.implicitHeight + root.padV * 2
              Column {
                id: turn
                x: root.padH; y: root.padV; width: parent.width - root.padH * 2
                spacing: 6
                // user instruction (deactivated) vs assistant answer
                Row {
                  visible: modelData.role === "user"
                  spacing: 10
                  Text { text: "✓"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body }
                  Text {
                    width: turn.width - 26
                    text: modelData.text
                    color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body
                    wrapMode: Text.WordWrap
                  }
                }
                Text {
                  visible: modelData.role === "assistant"
                  text: root.modelLabel(root.model)
                  color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
                }
                Text {
                  visible: modelData.role === "assistant"
                  width: turn.width
                  text: modelData.text
                  color: modelData.isError ? Color.urgent : Color.menu.text
                  font.family: Style.font.family; font.pixelSize: Style.font.body
                  wrapMode: Text.WordWrap
                  textFormat: (!modelData.isError && root.renderMarkdown) ? Text.MarkdownText : Text.PlainText
                  linkColor: Color.accent
                  onLinkActivated: function (url) { root.openLink(url) }
                }
              }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
            }
          }

          // ---- live (in-progress) answer / spinner ----
          Item {
            visible: root.busy
            width: parent.width
            height: visible ? liveCol.implicitHeight + root.padV * 2 : 0
            Column {
              id: liveCol
              x: root.padH; y: root.padV; width: parent.width - root.padH * 2
              spacing: 6
              Text { text: root.modelLabel(root.model); color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
              Text {
                width: parent.width
                text: root.streaming ? root.answer : root.spinnerFrames.charAt(root.spinIndex)
                color: root.streaming ? Color.menu.text : Color.accent   // themed spinner glyph
                font.family: Style.font.family; font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
                textFormat: (root.streaming && root.renderMarkdown) ? Text.MarkdownText : Text.PlainText
              }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
          }

          // ---- input row (multi-line; only shown when not streaming) ----
          Item {
            id: inputRow
            width: parent.width
            visible: !root.busy
            height: visible ? input.implicitHeight + root.padV * 2 : 0
            TextEdit {
              id: input
              x: root.padH; y: root.padV; width: parent.width - root.padH * 2
              color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body
              wrapMode: TextEdit.Wrap
              selectByMouse: true
              selectionColor: Util.alpha(Color.accent, 0.35)
              // caret shows only when the input truly owns focus (not while a dropdown / settings /
              // action-nav is active), and blinks cleanly.
              cursorVisible: root.inputActive
              cursorDelegate: Rectangle {
                width: 2
                height: input.cursorRectangle.height
                color: Color.accent
                visible: root.inputActive
                SequentialAnimation on opacity {
                  running: root.inputActive
                  loops: Animation.Infinite
                  NumberAnimation { to: 1; duration: 1 }
                  PauseAnimation { duration: 550 }
                  NumberAnimation { to: 0; duration: 1 }
                  PauseAnimation { duration: 550 }
                }
              }
              Text {
                visible: input.text.length === 0
                text: root.history.length > 0 ? "Ask a follow-up…"
                      : (root.mode === "chat" ? "Ask anything…" : "How should I change this?")
                color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body
              }
              Keys.onPressed: function (event) { root.onInputKey(event) }
            }
          }

          // ---- action rows (after a successful answer) ----
          Column {
            id: actionsCol
            width: parent.width
            visible: !root.busy && root.lastAnswer !== ""

            Rectangle { width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
            RecastAction {
              width: parent.width
              label: "Copy output"
              hint: root.copiedHint
              focused: root.actionFocus === 0
              divider: true
              onTriggered: root.copyLast()
            }
            RecastAction {
              width: parent.width
              label: "Regenerate"
              focused: root.actionFocus === 1
              divider: root.sourceAddr !== ""
              onTriggered: root.regenerate()
            }
            RecastAction {
              width: parent.width
              visible: root.sourceAddr !== ""
              label: "Insert in " + (root.sourceApp !== "" ? root.sourceApp : "app")
              focused: root.actionFocus === 2
              onTriggered: root.insertIntoSource()
            }
          }
        }
      }
    }
  }

  // clickable top-bar picker button (label + caret as one baseline-aligned text)
  component TopPicker: Text {
    id: tp
    property string label: ""
    property bool active: false
    signal clicked()
    text: tp.label + "  ⌄"          // ⌄ shares the label's baseline (well-aligned)
    color: tp.active ? Color.menu.selectedText : Color.menu.text
    font.family: Style.font.family
    font.pixelSize: root.barFont
    MouseArea { anchors.fill: parent; onClicked: tp.clicked() }
  }

  // clickable / keyboard-focusable action row
  component RecastAction: Item {
    id: act
    property string label: ""
    property string hint: ""
    property bool focused: false
    property bool divider: false
    signal triggered()
    height: visible ? root.padV * 2 + Style.font.body : 0
    readonly property bool hot: focused || hover.hovered
    Rectangle { anchors.fill: parent; color: act.hot ? Color.menu.selectedBackground : "transparent" }
    Rectangle { visible: act.divider; anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left; anchors.leftMargin: root.padH
      text: act.label
      color: act.hot ? Color.menu.selectedText : Color.menu.text
      font.family: Style.font.family; font.pixelSize: Style.font.body
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right; anchors.rightMargin: root.padH
      text: act.hint
      color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
    }
    HoverHandler { id: hover }
    MouseArea { anchors.fill: parent; onClicked: act.triggered() }
  }
}
