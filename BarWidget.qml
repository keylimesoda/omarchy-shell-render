import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

Panel {
  id: root
  moduleName: "ric.shell-render"
  ipcTarget: "ric.shell-render"
  manageIpc: false

  // gpu      = render the bar + menu on the GPU (nvidia driver).
  // software = render on the CPU via Mesa/llvmpipe: resilient while the GPU
  //            is saturated (e.g. by local inference) and driver resource
  //            exhaustion would otherwise corrupt the shell's GL state.
  property string shellRender: "gpu"        // configured: what the next shell start uses
  property string shellRenderApplied: "gpu" // what this running shell was started with
  property string pendingMode: ""           // in-flight selection from the panel
  property bool restartDialogOpen: false

  readonly property bool restartPending: shellRender !== shellRenderApplied

  // The CLI ships inside the plugin (bin/shell-render); the path is resolved
  // relative to this QML file, so no installation step is needed.
  function pluginBin() {
    var u = String(Qt.resolvedUrl("bin/shell-render"))
    if (u.startsWith("file://")) u = u.substring(7)
    return u
  }
  readonly property string cli: pluginBin()

  property string focusSection: "backend"
  property int selectedIndex: 0
  property bool cursorActive: false

  function moveCursor(delta) {
    var next = selectedIndex + delta
    if (next < 0) next = 0
    if (next > 1) next = 1
    selectedIndex = next
  }

  function backendLabel(mode) {
    return mode === "software" ? "CPU (llvmpipe)" : "GPU"
  }

  function activateCursor() {
    selectBackend(selectedIndex === 1 ? "software" : "gpu")
  }

  function stateIpc() {
    return JSON.stringify({
      configured: root.shellRender,
      applied: root.shellRenderApplied,
      restartPending: root.restartPending
    })
  }

  IpcHandler {
    target: "ric.shell-render"

    function state(): string { return root.stateIpc() }
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function show() { root.open() }
    function hide() { root.close() }
  }

  function refresh() {
    if (!stateProc.running) stateProc.running = true
  }

  // Persist the chosen backend, then offer a restart when it differs from the
  // backend of the running shell (a restart is the only way it takes effect).
  function selectBackend(mode) {
    if (mode !== "gpu" && mode !== "software") return
    if (mode === root.shellRender) return
    root.pendingMode = mode
    setProc.command = [root.cli, "set", mode]
    if (!setProc.running) setProc.running = true
  }

  function restartShell() {
    restartProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (opened) {
      refresh()
      root.selectedIndex = root.shellRender === "software" ? 1 : 0
      root.cursorActive = false
    }
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: stateProc
    command: [root.cli, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text || "").trim().split(" ")
        if (parts.length >= 1 && (parts[0] === "gpu" || parts[0] === "software")) {
          root.shellRender = parts[0]
          root.shellRenderApplied = (parts.length >= 2 && parts[1] === "software") ? "software" : "gpu"
        }
      }
    }
  }

  Process {
    id: setProc
    stdout: StdioCollector { waitForEnd: true }
    onRunningChanged: {
      if (running) return
      if (root.pendingMode !== "gpu" && root.pendingMode !== "software") return
      root.shellRender = root.pendingMode
      if (root.shellRender !== root.shellRenderApplied) {
        restartDialog.message = "Switch the shell to " + root.backendLabel(root.shellRender) + "?\n\n"
          + "It takes effect when the shell restarts. Until then the bar and menu keep rendering via "
          + root.backendLabel(root.shellRenderApplied) + ".\n\n"
          + "'Later' keeps the saved setting — restart any time with: omarchy restart shell"
        root.restartDialogOpen = true
      }
      root.pendingMode = ""
    }
  }

  // Replaces this very process. Deliberately no follow-up refresh.
  Process {
    id: restartProc
    command: ["omarchy-restart-shell"]
    stdout: StdioCollector { waitForEnd: true }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.shellRender === "software" ? "CPU" : "GPU"
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: "Shell rendering: " + root.backendLabel(root.shellRender)
      + (root.restartPending ? " — restart pending" : "")
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(460))

    Item {
      id: keyCatcher
      anchors.fill: parent
      z: root.restartDialogOpen ? 20 : 0
      focus: true

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (root.restartDialogOpen) {
          if (restartDialog.handleKey(event)) event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Down || event.text === "j" || event.key === Qt.Key_Right || event.text === "l") {
          root.moveCursor(1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Up || event.text === "k" || event.key === Qt.Key_Left || event.text === "h") {
          root.moveCursor(-1)
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
          root.activateCursor()
          event.accepted = true
          return
        }
        if (event.text === "r") root.refresh()
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: glyph · title/status ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "󱚣"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.display
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              id: heroLabels
              anchors.left: heroIcon.right
              anchors.leftMargin: Style.space(14)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: "Shell Rendering"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                id: heroLabel
                textFormat: Text.PlainText
                text: root.restartPending
                  ? (root.backendLabel(root.shellRenderApplied) + " → " + root.backendLabel(root.shellRender) + " · RESTART PENDING")
                  : "NOW " + root.backendLabel(root.shellRender).toUpperCase()
                color: Qt.darker(root.bar.foreground, 1.4)
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 1.2
                elide: Text.ElideRight
                width: parent.width
              }
            }
          }

          // ---------- Backend ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              id: backendHeader
              text: "BACKEND"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            ButtonGroup {
              id: backendGroup
              options: [
                {
                  value: "gpu",
                  label: "GPU",
                  icon: "󱚣",
                  tooltip: "Render the bar and menu on the GPU (nvidia driver). The default."
                },
                {
                  value: "software",
                  label: "CPU (llvmpipe)",
                  tooltip: "Render on the CPU via Mesa/llvmpipe — resilient while the GPU is saturated (e.g. by local inference)."
                }
              ]
              value: root.shellRender
              cursorIndex: root.cursorActive && root.focusSection === "backend" ? root.selectedIndex : -1
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              onChanged: function(v) { root.selectBackend(v) }
              onHovered: function(index, isHovered) {
                if (!isHovered) return
                root.cursorActive = true
                root.focusSection = "backend"
                root.selectedIndex = index
              }
            }
          }

          // ---------- Status / help ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: "In effect now: " + root.backendLabel(root.shellRenderApplied)
                + (root.restartPending ? " — the saved switch applies on restart" : "")
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: "Applies on shell (re)start. State: ~/.config/omarchy/shell-render.conf"
              color: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Item {
            width: parent.width
            height: Style.space(4)
          }
        }
      }

      ConfirmDialog {
        id: restartDialog
        anchors.fill: parent
        z: 10
        fontFamily: root.bar.fontFamily
        cancelText: "Later"
        confirmText: "Restart now"
        onCanceled: root.restartDialogOpen = false
        onConfirmed: {
          root.restartDialogOpen = false
          root.restartShell()
        }
      }
    }
  }
}