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

  // Shell (bar + menu). Applies on shell (re)start via the launcher shim.
  //   gpu      = render on the GPU (nvidia driver).
  //   software = render on the CPU via Mesa/llvmpipe: resilient while the
  //              GPU is saturated (e.g. by local inference) and driver
  //              resource exhaustion would otherwise corrupt the shell's
  //              GL state.
  // Browser (Edge / Chromium). Applies at the browser's next start via the
  // vendor user-flags file (--use-angle=swiftshader).
  //   gpu      = GPU-accelerated (nvidia driver).
  //   software = CPU rendering via SwiftShader.
  property string shellRender: "gpu"         // configured: what the next shell start uses
  property string shellRenderApplied: "gpu"  // what this running shell is rendering with
  property string browserRender: "gpu"       // configured: what the next browser start uses
  property string browserRenderApplied: "gpu"// what the running browser is rendering with
  property string browserProfile: "edge"     // edge | chromium | unsupported
  property bool browserSupported: true
  property string pendingMode: ""            // in-flight selection from the panel
  property string pendingTarget: "shell"     // "shell" | "browser" (last in-flight target)
  property bool restartDialogOpen: false

  readonly property bool restartPending: shellRender !== shellRenderApplied
  readonly property bool browserRestartPending: browserSupported && browserRender !== browserRenderApplied

  // The CLI ships inside the plugin (bin/shell-render); the path is resolved
  // relative to this QML file, so no installation step is needed.
  function pluginBin() {
    var u = String(Qt.resolvedUrl("bin/shell-render"))
    if (u.startsWith("file://")) u = u.substring(7)
    return u
  }
  readonly property string cli: pluginBin()

  property string focusSection: "backend"    // "backend" (shell) | "browser"
  property int selectedIndex: 0              // 0,1 = shell gpu/cpu; 2,3 = browser gpu/cpu
  property bool cursorActive: false

  function moveCursor(delta) {
    var next = selectedIndex + delta
    var max = root.browserSupported ? 3 : 1
    if (next < 0) next = 0
    if (next > max) next = max
    selectedIndex = next
  }

  function backendLabel(mode, isBrowser) {
    if (mode === "software") return isBrowser ? "CPU (SwiftShader)" : "CPU (llvmpipe)"
    return "GPU"
  }

  function browserName() {
    if (root.browserProfile === "chromium") return "Chromium"
    if (root.browserProfile === "edge") return "Microsoft Edge"
    return "the browser"
  }

  function activateCursor() {
    if (root.focusSection === "browser") {
      if (!root.browserSupported) return
      root.selectMode("browser", root.selectedIndex === 3 ? "software" : "gpu")
      return
    }
    root.selectMode("shell", root.selectedIndex === 1 ? "software" : "gpu")
  }

  function stateIpc() {
    return JSON.stringify({
      configured: root.shellRender,
      applied: root.shellRenderApplied,
      restartPending: root.restartPending,
      browser: {
        supported: root.browserSupported,
        profile: root.browserProfile,
        configured: root.browserRender,
        applied: root.browserRenderApplied,
        restartPending: root.browserRestartPending
      }
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

  // Persist the chosen backend for the target; when the running instance
  // differs, offer to restart it (the only way the switch takes effect).
  function selectMode(target, mode) {
    if (mode !== "gpu" && mode !== "software") return
    if (target === "browser" && !root.browserSupported) return
    var configured = (target === "browser") ? root.browserRender : root.shellRender
    if (mode === configured) return
    root.pendingTarget = target
    root.pendingMode = mode
    setProc.command = [root.cli, "set", mode, target]
    if (!setProc.running) setProc.running = true
  }

  function restart() {
    restartProc.command = root.pendingTarget === "browser"
      ? [root.cli, "browser", "restart"]
      : ["omarchy-restart-shell"]
    restartProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    refresh()
    if (!maintainProc.running) maintainProc.running = true
  }

  // "configured applied" pairs for shell + browser + profile in one call.
  // Both sides are verified against the live processes (nvidia/DRM fds,
  // GL env vars / swiftshader flag), so a start that missed the launcher
  // or the flags file can no longer be misreported.
  Process {
    id: stateProc
    command: [root.cli, "status", "both"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        var parts = String(text || "").trim().split(" ")
        if (parts.length >= 2) {
          if (parts[0] === "gpu" || parts[0] === "software") root.shellRender = parts[0]
          if (parts[1] === "software" || parts[1] === "gpu") root.shellRenderApplied = parts[1]
        }
        if (parts.length >= 5) {
          if (parts[2] === "unsupported") {
            root.browserSupported = false
            root.browserProfile = "unsupported"
          } else {
            root.browserSupported = true
            if (parts[4] === "edge" || parts[4] === "chromium") root.browserProfile = parts[4]
            if (parts[2] === "software" || parts[2] === "gpu") root.browserRender = parts[2]
            if (parts[3] === "software" || parts[3] === "gpu") root.browserRenderApplied = parts[3]
          }
        }
      }
    }
  }

  Timer {
    interval: 5000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  // Persists the chosen shell backend. setProc completes before the dialog
  // is offered; the restart (if confirmed) replaces this process, so no
  // follow-up refresh is scheduled.
  Process {
    id: setProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        if (root.pendingMode === "gpu" || root.pendingMode === "software") {
          if (root.pendingTarget === "browser") {
            root.browserRender = root.pendingMode
            if (root.browserRender !== root.browserRenderApplied) {
              restartDialog.message = "Restart " + root.browserName() + "?\n\nIts previous session is restored on relaunch. The "
                + root.backendLabel(root.browserRender, true) + " backend applies."
              root.restartDialogOpen = true
            }
          } else {
            root.shellRender = root.pendingMode
            if (root.shellRender !== root.shellRenderApplied) {
              restartDialog.message = "Switch the shell to " + root.backendLabel(root.shellRender) + "?\n\nThe bar and menu restart, keeping their position on screen. The "
                + root.backendLabel(root.shellRender) + " backend applies."
              root.restartDialogOpen = true
            }
          }
          root.pendingMode = ""
        }
      }
    }
    onRunningChanged: {
      if (running) return
      if (root.pendingMode === "gpu" || root.pendingMode === "software") {
        root.refresh()
      }
      root.pendingMode = ""
    }
  }

  // Restart whatever target is pending: the shell via omarchy-restart-shell
  // (supervised respawn), the browser via omarchy-restart-app (SIGTERM,
  // session restores on relaunch).
  Process {
    id: restartProc
    command: ["omarchy-restart-shell"]
    stdout: StdioCollector { waitForEnd: true }
  }

  // Keeps the launcher wiring alive: the quickshell shim in mise's shims
  // dir (mise regenerates that dir on tool changes and drops hand-added
  // entries) and the managed flag line in the browser's user-flags file
  // (system updates can regenerate it). `status` verifies the live
  // processes, so a loss of the wiring stays visible instead of silent.
  // Runs on load and every 60s; `shell-render maintain` does the same
  // from a terminal.
  Process {
    id: maintainProc
    command: [root.cli, "maintain", "--quiet"]
    stdout: StdioCollector { waitForEnd: true }
  }

  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: {
      if (!maintainProc.running) maintainProc.running = true
    }
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
      + (root.browserSupported ? "\nBrowser: " + root.backendLabel(root.browserRender, true)
          + (root.browserRestartPending ? " — restart pending" : "") : "")
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

          // ---------- Hero: glyph / shell state ----------
          Item {
            width: parent.width
            implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

            Text {
              id: heroIcon
              textFormat: Text.PlainText
              text: "𝬣"
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
                text: "GPU / CPU Rendering"
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

          // ---------- Shell backend ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              id: backendHeader
              text: "SHELL (BAR + MENU)"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            ButtonGroup {
              id: backendGroup
              options: [
                {
                  value: "gpu",
                  label: "GPU",
                  icon: "𝬣",
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
              onChanged: function(v) { root.selectMode("shell", v) }
              onHovered: function(index, isHovered) {
                if (!isHovered) return
                root.cursorActive = true
                root.focusSection = "backend"
                root.selectedIndex = index
              }
            }
          }

          // ---------- Browser backend ----------
          PanelSeparator {
            foreground: root.bar.foreground
          }

          Column {
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              id: browserHeader
              textFormat: Text.PlainText
              text: root.browserSupported
                ? ("BROWSER (" + root.browserName().toUpperCase() + ")")
                : "BROWSER (NOT SUPPORTED)"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
            }

            ButtonGroup {
              id: browserGroup
              enabled: root.browserSupported
              options: [
                {
                  value: "gpu",
                  label: "GPU",
                  icon: "𝬣",
                  tooltip: "Accelerate the browser on the GPU (nvidia driver). The default."
                },
                {
                  value: "software",
                  label: "CPU (SwiftShader)",
                  tooltip: "Render the browser on the CPU via SwiftShader — resilient while the GPU is saturated. Applies at the browser's next start."
                }
              ]
              value: root.browserSupported ? root.browserRender : "gpu"
              cursorIndex: root.cursorActive && root.focusSection === "browser" ? root.selectedIndex - 2 : -1
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.caption
              onChanged: function(v) { root.selectMode("browser", v) }
              onHovered: function(index, isHovered) {
                if (!isHovered || !root.browserSupported) return
                root.cursorActive = true
                root.focusSection = "browser"
                root.selectedIndex = index + 2
              }
            }
          }

          // ---------- Status / help ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            Text {
              textFormat: Text.PlainText
              text: "In effect now — shell: " + root.backendLabel(root.shellRenderApplied)
                + (root.restartPending ? " (→ " + root.backendLabel(root.shellRender) + " pending)" : "")
                + (root.browserSupported
                     ? " · browser: " + root.backendLabel(root.browserRenderApplied, true)
                       + (root.browserRestartPending ? " (→ " + root.backendLabel(root.browserRender, true) + " pending)" : "")
                     : " · browser: not supported")
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: "Shell applies on (re)start via the launcher shim; browser applies at its next start via its user-flags file. State: ~/.config/omarchy/shell-render.conf, browser-render.conf"
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
          root.restart()
        }
      }
    }
  }
}
