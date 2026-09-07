// Recast — Omarchy panel plugin (Path A: native QML rewrite, in progress).
//
// A summoned floating surface. The host (omarchy-shell) mounts this root Item and calls the
// lifecycle hooks below; the plugin owns its on-screen surface (a layer-shell PanelWindow).
// The Hyprland keybind summons us with a JSON payload carrying the primary selection and the
// source app:
//   omarchy-shell shell toggle io.github.tnep4.recast '{"selection":"…","app":"Firefox","mode":"transform"}'
//
// Step 2: press Enter to stream an OpenRouter completion (curl -N SSE) into the output row,
// with a spinner until the first token. Pickers/settings, follow-ups, copy/regenerate land next.
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
  property string model: "moonshotai/kimi-k3"   // step 3 makes this a picker + config

  // ---- runtime state ------------------------------------------------------------------
  property string apiKey: Quickshell.env("OPENROUTER_API_KEY")
  property bool opened: false
  property string selection: ""
  property string sourceApp: ""
  property string mode: "transform"   // "transform" (has selection) | "chat"

  property var messages: []
  property bool busy: false
  property bool streaming: false      // true once the first token arrives
  property string answer: ""
  property string errorText: ""
  property int spinIndex: 0

  function modelLabel(id) {
    var map = {
      "moonshotai/kimi-k3": "Kimi K3", "anthropic/claude-sonnet-5": "Claude Sonnet 5",
      "anthropic/claude-opus-5": "Claude Opus 5", "openai/gpt-5.6-luna": "GPT-5.6 Luna",
      "google/gemini-3.8-flash": "Gemini 3.8 Flash"
    }
    return map[id] || id
  }

  // ---- lifecycle hooks the host calls -------------------------------------------------
  function open(payloadJson) {
    var p = ({})
    try { p = JSON.parse(payloadJson || "{}") } catch (e) { p = ({}) }
    root.selection = p.selection || ""
    root.sourceApp = p.app || ""
    root.mode = (p.mode === "chat" || !root.selection) ? "chat" : "transform"
    // fresh conversation each summon
    root.messages = []
    root.answer = ""
    root.errorText = ""
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
  // IPC hook: set the instruction and send (used for scripting/testing via
  //   omarchy-shell shell call io.github.tnep4.recast sendText "…")
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

    input.text = ""
    root.answer = ""
    root.errorText = ""
    root.busy = true
    root.streaming = false

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

  // SplitParser can hand us a chunk that holds one SSE line (often with a leading newline
  // from the blank line between events) or several at once — normalize and scan every line.
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
    if (root.answer !== "")
      root.messages = root.messages.concat([{ role: "assistant", content: root.answer }])
    else if (root.errorText === "")
      root.errorText = (exitCode && exitCode !== 0)
        ? "Request failed (curl exit " + exitCode + ")"
        : "No response from the model."
  }

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

  Timer {
    interval: 90; repeat: true; running: root.busy && !root.streaming
    onTriggered: root.spinIndex = (root.spinIndex + 1) % root.spinnerFrames.length
  }

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
      height: col.height
      anchors.horizontalCenter: parent.horizontalCenter
      y: Math.max(Style.gapsOut, Math.round((panel.height - height) / 2))
      color: Color.menu.background
      border.color: Color.menu.border
      border.width: Math.max(1, Style.space(2))
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent }   // swallow clicks so the scrim close doesn't fire

      Column {
        id: col
        width: parent.width

        // top bar: Recast › <app>
        Item {
          width: parent.width
          height: 40
          Row {
            anchors.verticalCenter: parent.verticalCenter
            anchors.left: parent.left
            anchors.leftMargin: 20
            spacing: 12
            Text { text: "Recast"; color: Color.menu.text; font.bold: true; font.family: Style.font.family; font.pixelSize: Style.font.title }
            Text { visible: root.mode === "transform" && root.sourceApp !== ""; text: "›"; color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.title }
            Text { visible: root.mode === "transform" && root.sourceApp !== ""; text: root.sourceApp; color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.title }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: parent.right
            anchors.rightMargin: 20
            text: root.modelLabel(root.model)
            color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body
          }
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
        }

        // selected text (transform mode only)
        Item {
          visible: root.mode === "transform" && root.selection !== ""
          width: parent.width
          height: visible ? sel.implicitHeight + 28 : 0
          Text {
            id: sel
            x: 20; y: 14
            width: parent.width - 40
            text: root.selection
            color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
          }
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
        }

        // input row
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
              text: root.mode === "chat" ? "Ask anything…" : "How should I change this?"
              color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.body
            }
            Keys.onReturnPressed: root.send()
            Keys.onEnterPressed: root.send()
            Keys.onEscapePressed: root.close()
          }
          Rectangle { visible: outputRow.visible; anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
        }

        // output row (answer / spinner / error)
        Item {
          id: outputRow
          visible: root.busy || root.answer !== "" || root.errorText !== ""
          width: parent.width
          height: visible ? outCol.implicitHeight + 28 : 0
          Column {
            id: outCol
            x: 20; y: 14
            width: parent.width - 40
            spacing: 6
            Text {
              text: root.modelLabel(root.model)
              color: Color.muted; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall
            }
            Text {
              width: parent.width
              visible: root.errorText === ""
              text: (root.busy && !root.streaming)
                    ? root.spinnerFrames.charAt(root.spinIndex)
                    : root.answer
              color: Color.menu.text; font.family: Style.font.family; font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
            Text {
              width: parent.width
              visible: root.errorText !== ""
              text: root.errorText
              color: Color.urgent; font.family: Style.font.family; font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }
          }
        }
      }
    }
  }
}
