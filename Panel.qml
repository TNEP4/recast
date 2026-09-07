// Recast — Omarchy panel plugin (Path A: native QML rewrite, in progress).
//
// A summoned floating surface. The host (omarchy-shell) mounts this root Item and calls the
// lifecycle hooks below; the plugin owns its on-screen surface (a layer-shell PanelWindow).
// The Hyprland keybind summons us with a JSON payload carrying the primary selection and the
// source app:
//   omarchy-shell shell toggle io.github.tnep4.recast '{"selection":"…","app":"Firefox","mode":"transform"}'
//
// Step 1 of the rebuild: render the themed shell (top bar, selection, input), centered and
// keyboard-focused, Esc/scrim to close. Streaming, pickers, follow-ups land in later steps.
import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons

Item {
  id: root

  // Injected by omarchy-shell.
  property var shell: null
  property var manifest: null
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")

  property bool opened: false
  property string selection: ""
  property string sourceApp: ""
  property string mode: "transform"   // "transform" (has selection) | "chat"

  // ---- lifecycle hooks the host calls -------------------------------------------------
  function open(payloadJson) {
    var p = ({})
    try { p = JSON.parse(payloadJson || "{}") } catch (e) { p = ({}) }
    root.selection = p.selection || ""
    root.sourceApp = p.app || ""
    root.mode = (p.mode === "chat" || !root.selection) ? "chat" : "transform"
    root.opened = true
    Qt.callLater(function () { input.forceActiveFocus() })
  }
  function close() { root.opened = false; input.text = "" }
  function refresh() { return "ok" }
  function ping() { return "ok" }

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

      // swallow clicks on the card so they don't reach the scrim's close handler
      MouseArea { anchors.fill: parent }

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
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Util.alpha(Color.menu.border, 0.4) }
        }

        // selected text (transform mode only)
        Item {
          visible: root.mode === "transform" && root.selection !== ""
          width: parent.width
          height: visible ? sel.implicitHeight + 28 : 0
          Text {
            id: sel
            x: 20
            y: 14
            width: parent.width - 40
            text: root.selection
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
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
            anchors.leftMargin: 20
            anchors.rightMargin: 20
            verticalAlignment: TextInput.AlignVCenter
            color: Color.menu.text
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            clip: true
            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: input.text.length === 0
              text: root.mode === "chat" ? "Ask anything…" : "How should I change this?"
              color: Color.muted
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }
            Keys.onEscapePressed: root.close()
          }
        }
      }
    }
  }
}
