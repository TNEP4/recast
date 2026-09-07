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
  property string model: "moonshotai/kimi-k3"   // step 3 makes this a picker + config

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
    var map = {
      "moonshotai/kimi-k3": "Kimi K3", "anthropic/claude-sonnet-5": "Claude Sonnet 5",
      "anthropic/claude-opus-5": "Claude Opus 5", "openai/gpt-5.6-luna": "GPT-5.6 Luna",
      "google/gemini-3.8-flash": "Gemini 3.8 Flash"
    }
    return map[id] || id
  }
  function isTerminal(cls) { return root.terminalClasses.indexOf(cls) !== -1 }

  // ---- lifecycle hooks the host calls -------------------------------------------------
  function open(payloadJson) {
    var p = ({})
    try { p = JSON.parse(payloadJson || "{}") } catch (e) { p = ({}) }
    root.selection = p.selection || ""
    root.sourceApp = p.app || ""
    root.sourceAddr = p.addr || ""
    root.sourceClass = p.class || ""
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
    var body = JSON.stringify({ model: root.model, messages: root.messages, stream: true })
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
    root.close()
    insertProc.command = ["bash", "-c",
      "hyprctl dispatch focuswindow address:" + root.sourceAddr +
      "; sleep 0.06; hyprctl dispatch sendshortcut " + mods + ",v,address:" + root.sourceAddr]
    insertProc.running = true
  }

  function scrollToBottom() { flick.contentY = Math.max(0, flick.contentHeight - flick.height) }

  Process {
    id: keyProc
    command: ["secret-tool", "lookup", "service", "openrouter", "app", "ai-transform"]
    stdout: SplitParser { onRead: function (data) { if (!root.apiKey) root.apiKey = data.replace(/^\s+|\s+$/g, "") } }
  }
  Process {
    id: streamProc
    stdout: SplitParser { onRead: function (line) { root.onSseLine(line) } }
    onExited: function (exitCode, exitStatus) { root.onStreamDone(exitCode) }
  }
  Process { id: copyProc }
  Process { id: insertProc }

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
      height: Math.min(content.implicitHeight, root.maxHeight)
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((panel.height - height) / 2))
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: Math.max(1, Style.space(2))
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent }   // swallow clicks so the scrim close doesn't fire

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
            Text {
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right; anchors.rightMargin: 20
              text: root.modelLabel(root.model)
              color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body
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
              Keys.onReturnPressed: root.send()
              Keys.onEnterPressed: root.send()
              Keys.onEscapePressed: root.close()
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
