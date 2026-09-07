// Recast — Omarchy panel plugin (Path A: native QML rewrite, in progress).
//
// A summoned floating surface. The host (omarchy-shell) owns the window and calls the
// lifecycle hooks below; the Hyprland keybind summons us with a JSON payload carrying the
// primary selection and the source app:
//   omarchy-shell shell toggle io.github.tnep4.recast '{"selection":"…","app":"Firefox","mode":"transform"}'
//
// This is step 1 of the rebuild: it summons, parses the payload, and shows the shell so the
// plugin/IPC/theming path is proven. Streaming, pickers, follow-ups, etc. land in later steps.
import QtQuick
import Quickshell

Item {
  id: root

  // Injected by omarchy-shell when the plugin is summoned.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  // Parsed from the summon payload.
  property string selection: ""
  property string sourceApp: ""
  property string mode: "transform"   // "transform" (has selection) | "chat"

  implicitWidth: 560
  implicitHeight: card.implicitHeight

  // ---- lifecycle hooks the host calls -------------------------------------------------
  function open(payloadJson) {
    var p = ({})
    try { p = JSON.parse(payloadJson || "{}") } catch (e) { p = ({}) }
    root.selection = p.selection || ""
    root.sourceApp = p.app || ""
    root.mode = (p.mode === "chat" || !root.selection) ? "chat" : "transform"
    input.forceActiveFocus()
  }
  function close() { input.text = "" }
  function refresh() { return "ok" }
  function ping() { return "ok" }

  Rectangle {
    id: card
    anchors.fill: parent
    color: "#1a1b26"
    border.color: "#c0caf5"
    border.width: 2
    radius: 0
    implicitHeight: col.implicitHeight

    Column {
      id: col
      width: parent.width

      // top bar: Menu · Recast › <app>
      Item {
        width: parent.width
        height: 40
        Row {
          anchors.verticalCenter: parent.verticalCenter
          anchors.left: parent.left
          anchors.leftMargin: 20
          spacing: 12
          Text { text: "Recast"; color: "#c0caf5"; font.bold: true; font.family: "monospace"; font.pixelSize: 14 }
          Text { visible: root.mode === "transform" && root.sourceApp !== ""; text: "›"; color: "#6b7089"; font.family: "monospace"; font.pixelSize: 14 }
          Text { visible: root.mode === "transform" && root.sourceApp !== ""; text: root.sourceApp; color: "#c0caf5"; font.family: "monospace"; font.pixelSize: 14 }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#33c0caf5" }
      }

      // selected text (transform mode only)
      Item {
        visible: root.mode === "transform" && root.selection !== ""
        width: parent.width
        height: visible ? selText.implicitHeight + 28 : 0
        Text {
          id: selText
          anchors.fill: parent
          anchors.margins: 14
          anchors.leftMargin: 20; anchors.rightMargin: 20
          text: root.selection
          color: "#c0caf5"; font.family: "monospace"; font.pixelSize: 14
          wrapMode: Text.WordWrap
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: "#33c0caf5" }
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
          color: "#c0caf5"; font.family: "monospace"; font.pixelSize: 14
          clip: true
          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: input.text.length === 0
            text: root.mode === "chat" ? "Ask anything…" : "How should I change this?"
            color: "#6b7089"; font.family: "monospace"; font.pixelSize: 14
          }
          Keys.onEscapePressed: root.close()
        }
      }
    }
  }
}
