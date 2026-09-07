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
  readonly property string configPath: Quickshell.env("HOME") + "/.config/recast/config.json"

  property bool settingsOpen: false
  // picker dropdown state
  property string pickerKind: ""   // "" | "model" | "effort"
  property int pickerIndex: 0
  readonly property var pickerOptions: pickerKind === "model" ? root.models
    : (pickerKind === "effort" ? root.efforts : [])

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
          { role: "system", content: root.transformPrompt },
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
      copyText(root.answer)          // auto-copy the result
      root.copiedHint = "copied to clipboard"
      root.answer = ""
    } else {
      var msg = root.errorText !== "" ? root.errorText
        : ((exitCode && exitCode !== 0) ? "Request failed (curl exit " + exitCode + ")" : "No response from the model.")
      // drop the failed user turn from the API history so a retry is clean
      if (root.messages.length > 0 && root.messages[root.messages.length - 1].role === "user")
        root.messages = root.messages.slice(0, root.messages.length - 1)
      root.history = root.history.concat([{ role: "assistant", text: msg, isError: true }])
      root.errorText = ""
    }
    Qt.callLater(function () { input.forceActiveFocus(); scrollToBottom() })
  }

  // ---- actions ------------------------------------------------------------------------
  function copyText(t) { copyProc.command = ["wl-copy", "--", t]; copyProc.running = true }
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
    if (root.pickerKind === kind) { root.pickerKind = ""; return }
    root.pickerKind = kind
    root.pickerIndex = (kind === "model") ? root.indexOfId(root.models, root.model)
                                          : root.indexOfId(root.efforts, root.effort)
  }
  function closePicker() { root.pickerKind = "" }
  function pickerMove(d) {
    var n = root.pickerOptions.length
    if (n > 0) root.pickerIndex = (root.pickerIndex + d + n) % n
  }
  function pickerCommit() {
    var opt = root.pickerOptions[root.pickerIndex]
    if (opt) { if (root.pickerKind === "model") root.setModel(opt.id); else root.setEffort(opt.id) }
    root.pickerKind = ""
  }
  function setModel(id) { root.model = id; saveConfig() }
  function setEffort(id) { root.effort = id; saveConfig() }
  function saveConfig() { cfgFile.setText(JSON.stringify({ model: root.model, effort: root.effort }, null, 2) + "\n") }
  function openSettings() { root.settingsOpen = true; Qt.callLater(function () { keyField.forceActiveFocus() }) }
  function closeSettings() { root.settingsOpen = false; keyField.text = ""; Qt.callLater(function () { input.forceActiveFocus() }) }

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
      width: 560
      height: Math.min(root.settingsOpen ? settingsView.implicitHeight : content.implicitHeight, root.maxHeight)
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((panel.height - height) / 2))
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: Math.max(1, Style.space(2))
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent }   // swallow clicks so the scrim close doesn't fire

      // settings overlay (Ctrl+,) — enter the OpenRouter API key
      Rectangle {
        id: settingsView
        visible: root.settingsOpen
        z: 20
        anchors.top: parent.top; anchors.left: parent.left
        width: parent.width
        implicitHeight: setCol.implicitHeight
        height: implicitHeight
        color: Color.menu.background
        Column {
          id: setCol
          width: parent.width
          Item {
            width: parent.width; height: 40
            Row {
              anchors.verticalCenter: parent.verticalCenter; anchors.left: parent.left; anchors.leftMargin: 20; spacing: 12
              Text { text: "Recast"; color: Color.menu.text; font.bold: true; font.family: Style.font.family; font.pixelSize: Style.font.title }
              Text { text: "Settings"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.title }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
          }
          Item {
            width: parent.width
            height: keyCol.implicitHeight + 36
            Column {
              id: keyCol
              x: 20; y: 18; width: parent.width - 40; spacing: 8
              Text { text: "OpenRouter API key"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
              Rectangle {
                width: parent.width; height: 34; color: "transparent"
                border.color: keyField.activeFocus ? Color.menu.selectedText : Util.alpha(Color.menu.border, 0.5)
                border.width: 1
                TextInput {
                  id: keyField
                  anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                  verticalAlignment: TextInput.AlignVCenter
                  echoMode: TextInput.Password
                  color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body; clip: true
                  Text { anchors.verticalCenter: parent.verticalCenter; visible: keyField.text.length === 0; text: "sk-or-…"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body }
                  Keys.onReturnPressed: { if (keyField.text.length > 0) root.storeKey(keyField.text); root.closeSettings() }
                  Keys.onEnterPressed: { if (keyField.text.length > 0) root.storeKey(keyField.text); root.closeSettings() }
                  Keys.onEscapePressed: root.closeSettings()
                }
              }
              Text {
                width: parent.width
                text: (root.apiKey !== "" ? "A key is set. " : "") +
                      "Stored in the system keyring, never written to disk. Enter to save · Esc to close."
                color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      // model / effort dropdown, floating over the content (top-right, under the bar)
      Rectangle {
        id: dropdown
        visible: root.pickerKind !== ""
        z: 10
        width: 240
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: 40
        color: Color.menu.background
        border.color: Color.menu.border
        border.width: Math.max(1, Style.space(2))
        height: Math.min(pickCol.implicitHeight, root.maxHeight - 48)
        Flickable {
          anchors.fill: parent
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
                height: 40
                Rectangle { anchors.fill: parent; color: index === root.pickerIndex ? Color.menu.selectedBackground : "transparent" }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left; anchors.leftMargin: 16; anchors.right: parent.right; anchors.rightMargin: 16
                  text: modelData.label
                  color: index === root.pickerIndex ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.family; font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                MouseArea { anchors.fill: parent; onClicked: { root.pickerIndex = index; root.pickerCommit() } }
              }
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

          // ---- top bar: Recast › <app>  ·  model ----
          Item {
            width: parent.width
            height: 40
            Row {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left; anchors.leftMargin: 20
              spacing: 12
              Text { text: "Recast"; color: Color.menu.text; font.bold: true; font.family: Style.font.family; font.pixelSize: Style.font.title }
              Text { visible: root.mode === "transform" && root.sourceApp !== ""; text: "›"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.title }
              Text { visible: root.mode === "transform" && root.sourceApp !== ""; text: root.sourceApp; color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.title }
            }
            Row {
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right; anchors.rightMargin: 20
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
            height: visible ? sel.implicitHeight + 28 : 0
            Text {
              id: sel
              x: 20; y: 14; width: parent.width - 40
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
              implicitHeight: turn.implicitHeight + 24
              Column {
                id: turn
                x: 20; y: 12; width: parent.width - 40
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
                }
              }
              Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
            }
          }

          // ---- live (in-progress) answer / spinner ----
          Item {
            visible: root.busy
            width: parent.width
            height: visible ? liveCol.implicitHeight + 24 : 0
            Column {
              id: liveCol
              x: 20; y: 12; width: parent.width - 40
              spacing: 6
              Text { text: root.modelLabel(root.model); color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
              Text {
                width: parent.width
                text: root.streaming ? root.answer : root.spinnerFrames.charAt(root.spinIndex)
                color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
          }

          // ---- input row (first prompt / follow-up) ----
          Item {
            width: parent.width
            height: 48
            TextInput {
              id: input
              anchors.fill: parent
              anchors.leftMargin: 20; anchors.rightMargin: 20
              verticalAlignment: TextInput.AlignVCenter
              color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body
              clip: true
              enabled: !root.busy
              Text {
                anchors.verticalCenter: parent.verticalCenter
                visible: input.text.length === 0
                text: root.history.length > 0 ? "Ask a follow-up…"
                      : (root.mode === "chat" ? "Ask anything…" : "How should I change this?")
                color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body
              }
              Keys.onPressed: function (event) {
                if (event.modifiers & Qt.ControlModifier) {
                  if (event.key === Qt.Key_M) { root.togglePicker("model"); event.accepted = true; return }
                  if (event.key === Qt.Key_E && root.modelReasoning(root.model)) { root.togglePicker("effort"); event.accepted = true; return }
                  if (event.key === Qt.Key_Comma) { root.openSettings(); event.accepted = true; return }
                }
                if (root.pickerKind !== "") {   // picker open: arrows/enter/esc drive it, swallow the rest
                  if (event.key === Qt.Key_Up) root.pickerMove(-1)
                  else if (event.key === Qt.Key_Down) root.pickerMove(1)
                  else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.pickerCommit()
                  else if (event.key === Qt.Key_Escape) root.closePicker()
                  event.accepted = true
                  return
                }
                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.send(); event.accepted = true }
                else if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true }
              }
            }
          }

          // ---- action rows (after an answer) ----
          Column {
            width: parent.width
            visible: !root.busy && root.lastAnswer !== ""

            Rectangle { width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
            RecastAction {
              width: parent.width
              label: "Copy output"
              hint: root.copiedHint
              onTriggered: root.copyLast()
            }
            RecastAction {
              width: parent.width
              label: "Regenerate"
              onTriggered: root.regenerate()
            }
            RecastAction {
              width: parent.width
              visible: root.sourceAddr !== ""
              label: "Insert in " + (root.sourceApp !== "" ? root.sourceApp : "app")
              onTriggered: root.insertIntoSource()
            }
          }
        }
      }
    }
  }

  // clickable top-bar picker button (label + caret)
  component TopPicker: Item {
    id: tp
    property string label: ""
    property bool active: false
    signal clicked()
    implicitWidth: tprow.implicitWidth
    implicitHeight: 40
    Row {
      id: tprow
      anchors.centerIn: parent
      spacing: 6
      Text { text: tp.label; color: tp.active ? Color.menu.selectedText : Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body }
      Text { text: "⌄"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body }
    }
    MouseArea { anchors.fill: parent; onClicked: tp.clicked() }
  }

  // small clickable action row
  component RecastAction: Item {
    id: act
    property string label: ""
    property string hint: ""
    signal triggered()
    height: visible ? 44 : 0
    Rectangle { anchors.fill: parent; color: hover.hovered ? Color.menu.selectedBackground : "transparent" }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left; anchors.leftMargin: 20
      text: act.label
      color: hover.hovered ? Color.menu.selectedText : Color.menu.text
      font.family: Style.font.family; font.pixelSize: Style.font.body
    }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      anchors.right: parent.right; anchors.rightMargin: 20
      text: act.hint
      color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
    }
    HoverHandler { id: hover }
    MouseArea { anchors.fill: parent; onClicked: act.triggered() }
  }
}
