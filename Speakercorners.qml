import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Workspaces.js" as WorkspaceModel
import "IconModel.js" as IconModel

// Speaker Corners — the bottom-right hot corner and its floating workspace
// switcher, in one plugin.
//
// One always-mapped fullscreen Overlay window holds:
//   * embedded hot-corner recognition (bottom-right only)
//   * the floating workspace switcher strip (bottom-right)
// The window's `mask` only admits input where something interactive lives,
// so the desktop stays fully click-through everywhere else.
//
// Configuration lives in shell.json in the plugin's own entry:
//   "plugins": [
//     { "id": "speakercorners",
//       "dwellMs": 139, "targetSize": 8,
//       "bottomRightAction": "command","bottomRightCommand": "omarchy-shell workspace-overview toggle" }
//   ]
Item {
  id: root

  // Injected by the shell panel loader.
  property var shell: null
  property var manifest: null
  property var barWidgetRegistry: null
  property var pluginRegistry: null
  property string omarchyPath: ""

  // ---- Per-surface open state -------------------------------------------
  property bool workspacesOpened: false

  readonly property bool anyOpen: root.workspacesOpened
  // The shell's isPluginOpen() reads `opened` off the loaded item; keep it in
  // sync so `omarchy-shell shell toggle speakercorners` round-trips cleanly.
  readonly property bool opened: root.anyOpen

  readonly property var appLibrary: root.shell ? root.shell.appLibrary : null

  // ---- Hot-corner settings (read from the plugins[] entry) ---------------
  property var pluginSettings: ({})
  property bool configLoaded: false
  property int dwellMs: 139
  property int targetSize: 8
  property bool cornersEnabled: true

  function setting(key, fallback) {
    var value = root.pluginSettings[key]
    return value === undefined || value === null ? fallback : value
  }

  function actionFor(edge) {
    if (edge === "bottom-right") return String(setting("bottomRightAction", "command"))
    return "none"
  }

  function commandFor(edge) {
    if (edge === "bottom-right") return String(setting("bottomRightCommand", "omarchy-shell workspace-overview toggle"))
    return ""
  }

  function readConfig() {
    var cfg = ({})
    var list = root.userShellConfig.plugins
    if (!Array.isArray(list) && shell && shell.shellConfig && Array.isArray(shell.shellConfig.plugins))
      list = shell.shellConfig.plugins
    if (Array.isArray(list)) {
      for (var i = 0; i < list.length; i++) {
        if (list[i] && String(list[i].id) === "speakercorners") { cfg = list[i]; break }
      }
    }
    root.pluginSettings = cfg
    root.dwellMs = Math.max(120, Math.min(3000, Number(setting("dwellMs", 139) || 139)))
    root.targetSize = Math.max(4, Math.min(120, Number(setting("targetSize", 8) || 8)))
    root.cornersEnabled = setting("enabled", true) !== false
    root.configLoaded = true
  }

  // Reads the plugin's own entry straight from ~/.config/omarchy/shell.json.
  // The injected shell facade has no shell.shellConfig, so without this the
  // plugin would only ever see defaults.
  readonly property string userConfigPath: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
  property var userShellConfig: ({})
  function parseUserConfig(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      return Util.isPlainObject(parsed) ? parsed : ({})
    } catch (e) { return ({}) }
  }
  FileView {
    id: userShellFile
    path: root.userConfigPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var str = String(text() || "")
      root.userShellConfig = root.parseUserConfig(str)
      if (root.configLoaded) root.readConfig()
    }
    onLoadFailed: root.userShellConfig = ({})
  }

  // Notification history toggle state (reused by the "notifications" action).
  property bool historyShown: false
  Timer {
    id: historyReset
    interval: 12000
    repeat: false
    onTriggered: root.historyShown = false
  }

  // Run a corner action. Commands that target this plugin's own surfaces are
  // dispatched straight to the matching toggle (no subprocess); everything
  // else falls back to `sh -lc`.
  function run(cmd) {
    var text = String(cmd || "").trim()
    if (text.length === 0) return
    if (root.internalCommand(text)) return
    Quickshell.execDetached(["sh", "-lc", text])
  }

  function internalCommand(cmd) {
    var tokens = String(cmd || "").split(/\s+/)
    if (tokens[0] !== "omarchy-shell") return false
    var target = tokens[1]
    var method = tokens[2]
    if (target === "workspace-overview") {
      if (method === "toggle") { root.toggleWorkspaces() } else if (method === "open") { root.showWorkspaces() } else if (method === "close") { root.hideWorkspaces() } else return false
      return true
    }
    if (target === "speakercorners") {
      switch (method) {
      case "toggle": root.toggle(); break
      case "open": root.open(""); break
      case "close": root.close(); break
      default: return false
      }
      return true
    }
    return false
  }

  function trigger(action, command, edge) {
    switch (String(action)) {
    case "menu":
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.menu", '{"menu":"root"}'])
      break
    case "notifications":
      if (root.historyShown) {
        Quickshell.execDetached(["omarchy-shell", "notifications", "dismissAll"])
        root.historyShown = false
        historyReset.stop()
      } else {
        Quickshell.execDetached(["omarchy-shell", "notifications", "showHistory"])
        root.historyShown = true
        historyReset.restart()
      }
      break
    case "dnd":
      Quickshell.execDetached(["omarchy-shell", "notifications", "toggleDnd"])
      break
    case "clipboard":
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.clipboard", "{}"])
      break
    case "emojis":
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", "omarchy.emojis", "{}"])
      break
    case "lock":
      Quickshell.execDetached(["omarchy-shell", "lock", "lock"])
      break
    case "screen-off":
      Quickshell.execDetached(["sh", "-lc",
        "hyprctl dispatch 'hl.dsp.dpms({ state = \"off\" })' >/dev/null 2>&1"
        + " || hyprctl dispatch dpms off"])
      break
    case "command":
      root.run(command)
      break
    case "none":
    default:
      break
    }
  }

  function triggerCorner(edge) {
    root.readConfig()
    if (!root.cornersEnabled) return
    root.trigger(root.actionFor(edge), root.commandFor(edge), edge)
  }

  // ---- Shared look tokens -------------------------------------------------
  readonly property int cornerRadius: Style.cornerRadius
  readonly property string fontFamily: Style.font.family

  // Reactive: focused monitor for the window.
  readonly property var activeScreen: {
    var mon = Hyprland.focusedMonitor
    var name = mon ? String(mon.name || "") : ""
    var screens = Quickshell.screens
    if (name.length > 0) {
      for (var i = 0; i < screens.length; i++) {
        if (String(screens[i].name || "") === name) return screens[i]
      }
    }
    return screens.length > 0 ? screens[0] : null
  }

  // ========================================================================
  //  WORKSPACES FLOAT STRIP (bottom-right)
  // ========================================================================
  property int wsDuration: 1300
  property int wsCardWidth: Style.space(112)
  property int wsCardGap: Style.space(10)
  property int wsOuterPad: Style.space(10)
  property int wsPanelMargin: Style.space(44)
  property bool wsEdgeEnabled: false
  property int wsEdgeHeight: Style.space(6)
  property var workspaces: []
  property bool ready: false
  property bool modelDirty: true
  property bool geometryRefreshPending: false
  property bool geometryRefreshInFlight: false
  property var desktopEntries: []

  readonly property int effectiveWsCardWidth: {
    var n = Math.max(1, root.workspaces.length + (root.workspaces.length > 0 ? 1 : 0))
    var screen = root.activeScreen
    var avail = screen ? screen.width : 1920
    var maxW = Math.floor((avail - root.wsPanelMargin * 2 - root.wsCardGap * (n - 1) - root.wsOuterPad * 2 - 4) / n)
    return Math.max(64, Math.min(root.wsCardWidth, maxW))
  }

  // The strip always sits centered at the bottom of the focused screen.
  readonly property int wsBorderWidth: Math.max(1, Style.space(2))
  readonly property int stripW: {
    var n = root.workspaces.length
    var cards = Math.max(1, n) + (n > 0 ? 1 : 0)
    var gaps = Math.max(0, cards - 1)
    return root.effectiveWsCardWidth * cards
      + root.wsCardGap * gaps
      + root.wsOuterPad * 2 + root.wsBorderWidth * 2
  }
  readonly property int stripH: {
    return root.wsCardPreviewH + root.wsCardLabelH + root.wsOuterPad * 2 + root.wsBorderWidth * 2
  }
  readonly property int wsCardPreviewH: Math.round(root.effectiveWsCardWidth * 9 / 16)
  readonly property int wsCardLabelH: Math.max(Style.space(12), Style.font.caption + Style.space(4))
  readonly property int stripX: Math.max(0, Math.floor((panel.width - root.stripW) / 2))
  readonly property int stripY: Math.max(0, panel.height - root.stripH - root.cardBottomMargin)

  // Bar-aware bottom margin so the strip never sits under a bottom bar.
  readonly property real cardBottomMargin: {
    var bar = shell ? shell.bar : null
    if (bar && bar.position === "bottom" && !bar.barHidden) {
      return wsPanelMargin + Number(bar.barSize || 0)
    }
    return wsPanelMargin
  }

  Timer {
    id: readyTimer
    interval: 1500
    onTriggered: root.ready = true
  }

  Component.onCompleted: {
    root.readyTimerStart()
    root.readConfig()
    root.refreshDesktopEntries()
  }
  function readyTimerStart() { readyTimer.start() }

  function showWorkspaces() {
    var rebuilt = root.modelDirty
    root.ready = true
    if (rebuilt) root.refreshMainModel()
    if (root.workspaces.length === 0) {
      if (root.workspacesOpened) root.hideWorkspaces()
      return
    }
    root.workspacesOpened = true
    root.restartWorkspacesHideTimer()
  }

  function hideWorkspaces() {
    wsHideTimer.stop()
    wsSettleTimer.stop()
    root.workspacesOpened = false
  }

  function toggleWorkspaces() { root.workspacesOpened ? root.hideWorkspaces() : root.showWorkspaces() }

  function refreshDesktopEntries() {
    var next = []
    try {
      var values = DesktopEntries.applications.values || []
      for (var i = 0; i < values.length; i++) {
        if (values[i]) next.push(values[i])
      }
    } catch (error) {}
    root.desktopEntries = next
  }

  function refreshMainModel() {
    root.workspaces = WorkspaceModel.buildWorkspaces()
    root.modelDirty = false
    if (root.workspacesOpened && root.workspaces.length === 0) root.hideWorkspaces()
  }

  function requestGeometryRefresh() {
    root.geometryRefreshPending = true
    if (root.geometryRefreshInFlight) return
    root.geometryRefreshInFlight = true
    Hyprland.refreshToplevels()
    wsGeometryTimer.restart()
  }

  function restartWorkspacesHideTimer() {
    if (stripHover.hovered) wsHideTimer.stop()
    else wsHideTimer.restart()
  }

  // Escape a value as a single-line Lua string literal so it can be embedded
  // in a hyprctl Lua dispatcher expression.
  function luaStringLiteral(value) {
    return String(value || "").replace(/[\\"\x00-\x1f\x7f]/g, function(ch) {
      if (ch === "\\") return "\\\\"
      if (ch === '"') return '\\"'
      var decimal = ch.charCodeAt(0).toString()
      return "\\" + ("000" + decimal).slice(-3)
    })
  }

  // Switch to the workspace behind a clicked card. Omarchy runs Hyprland in
  // Lua mode, so workspace focus goes through the Lua dispatcher expression
  // rather than the plain "workspace <id>" dispatcher (which errors under
  // hl.dispatch wrap).
  function focusWorkspace(ws) {
    if (!ws) return
    var target = (ws.name && String(ws.name).length > 0) ? String(ws.name) : String(ws.id)
    var expr = 'hl.dsp.focus({ workspace = "' + root.luaStringLiteral(target) + '" })'
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
  }

  // Open the first empty workspace after the last used one. "Used" means a
  // workspace that has at least one window. The new workspace gets the first
  // free numeric ID above the highest occupied one.
  function openNewWorkspace() {
    var maxUsed = 0
    for (var i = 0; i < root.workspaces.length; i++) {
      var w = root.workspaces[i]
      if (w && w.windowCount > 0) {
        var id = Number(w.id)
        if (isFinite(id) && id > maxUsed) maxUsed = id
      }
    }
    var target = maxUsed + 1
    var expr = 'hl.dsp.focus({ workspace = "' + root.luaStringLiteral(String(target)) + '" })'
    Quickshell.execDetached(["hyprctl", "dispatch", expr])
    root.hideWorkspaces()
  }

  Timer {
    id: wsHideTimer
    interval: root.wsDuration
    onTriggered: root.hideWorkspaces()
  }

  Timer {
    id: wsGeometryTimer
    interval: 100
    onTriggered: {
      root.geometryRefreshInFlight = false
      if (!root.geometryRefreshPending) return
      root.geometryRefreshPending = false
      root.refreshMainModel()
      if (root.workspaces.length === 0) return
      if (root.workspacesOpened) root.restartWorkspacesHideTimer()
    }
  }

  Timer {
    id: wsSettleTimer
    interval: 40
    onTriggered: root.showWorkspaces()
  }

  Connections {
    target: Hyprland

    function onFocusedWorkspaceChanged() {
      if (root.ready) root.showWorkspaces()
    }

    function onRawEvent(event) {
      var name = String(event && event.name ? event.name : "")
      if (!root.ready) return
      var geometryEvent = ["movewindow", "moveworkspace", "openwindow", "closewindow", "changefloatingmode", "fullscreen", "pin", "minimize"].indexOf(name) !== -1
      var modelEvent = geometryEvent || name === "renameworkspace" || name === "urgent"
      if (!modelEvent) return

      root.modelDirty = true
      if (geometryEvent) root.requestGeometryRefresh()
      else if (root.workspacesOpened) wsSettleTimer.restart()
    }
  }

  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { root.refreshDesktopEntries() }
  }

  readonly property var focusedWorkspaceId: {
    var ws = Hyprland.focusedWorkspace
    return ws ? ws.id : null
  }

  // ========================================================================
  //  Shell panel contract + legacy IPC targets
  // ========================================================================
  function open(payloadJson) {
    // Generic summon opens the workspace switcher surface.
    root.showWorkspaces()
    return "ok"
  }
  function close() {
    root.hideWorkspaces()
    return "ok"
  }
  function toggle() { root.anyOpen ? root.close() : root.open("") }
  function refresh() { root.readConfig(); return "ok" }
  function ping() { return "ok" }

  function stateString() {
    return (root.anyOpen ? "open" : "closed")
      + " ws=" + (root.workspacesOpened ? "1" : "0")
  }

  IpcHandler {
    target: "speakercorners"
    function open(): string { root.open(""); return "ok" }
    function close(): string { root.close(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
    function state(): string { return root.stateString() }
  }

  IpcHandler {
    target: "workspace-overview"
    function open(): string { root.showWorkspaces(); return "ok" }
    function close(): string { root.hideWorkspaces(); return "ok" }
    function toggle(): string { root.toggleWorkspaces(); return "ok" }
    function state(): string { return root.workspacesOpened ? "open" : "closed" }
  }

  // ========================================================================
  //  Component: one hot-corner recognition zone
  // ========================================================================
  component CornerZone: Item {
    id: zone
    required property string edge

    readonly property bool armed: root.cornersEnabled
    // Fired latches until the pointer leaves, so resting in the corner opens
    // once instead of hammering the toggle on every dwell pass.
    property bool fired: false

    width: root.targetSize
    height: root.targetSize
    visible: root.cornersEnabled

    Timer {
      id: dwell
      interval: root.dwellMs
      repeat: false
      onTriggered: {
        root.triggerCorner(zone.edge)
        zone.fired = true
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onEntered: {
        zone.fired = false
        if (zone.armed) dwell.restart()
      }
      onExited: {
        dwell.stop()
        zone.fired = false
      }
    }
  }

  // ========================================================================
  //  The single masked window
  // ========================================================================
  PanelWindow {
    id: panel
    screen: root.activeScreen
    visible: true
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-speakercorners"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore

    // Input is restricted to what is actually interactive, so everything else
    // on screen keeps receiving the pointer. Always-on: the bottom-right
    // corner hot zone. The workspace strip keeps its clicks while showing.
    mask: Region {
      // bottom-right corner square
      Region { x: panel.width - root.targetSize; y: panel.height - root.targetSize; width: root.cornersEnabled ? root.targetSize : 0; height: root.targetSize }
      // workspace strip clicks (and null while it is hidden)
      Region { x: root.stripX; y: root.stripY; width: root.workspacesOpened ? root.stripW : 0; height: root.workspacesOpened ? root.stripH : 0 }
      // optional bottom edge (opt-in)
      Region { x: 0; y: root.wsEdgeEnabled ? panel.height - root.wsEdgeHeight : panel.height; width: root.wsEdgeEnabled ? panel.width : 0; height: root.wsEdgeEnabled ? root.wsEdgeHeight : 0 }
    }

    // ---- Workspaces float strip (bottom-right) ----
    BorderSurface {
      id: strip
      z: 4
      visible: root.workspacesOpened
      x: root.stripX
      y: root.stripY
      width: root.stripW
      height: root.stripH
      radius: root.cornerRadius
      color: Util.alpha(Color.popups.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

      Behavior on opacity {
        NumberAnimation { duration: root.cornerRadius > 0 ? 120 : 0; easing.type: Easing.OutCubic }
      }

      // Keep the overview open while the pointer is over it, so a click can
      // land; the auto-hide countdown resumes once the pointer leaves.
      HoverHandler {
        id: stripHover
        onHoveredChanged: {
          if (hovered) wsHideTimer.stop()
          else if (root.workspacesOpened) wsHideTimer.restart()
        }
      }

      Row {
        anchors.top: parent.top
        anchors.topMargin: root.wsOuterPad
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: root.wsCardGap

        Repeater {
          model: root.workspaces

          WorkspaceCard {
            required property var modelData

            width: root.effectiveWsCardWidth

            ws: modelData
            shell: root.shell
            desktopEntries: root.desktopEntries
            focused: root.focusedWorkspaceId !== null
              && Number(root.focusedWorkspaceId) === Number(modelData.id)
            onActivate: function(ws) { root.focusWorkspace(ws) }
          }
        }

        Item {
          width: root.effectiveWsCardWidth
          height: root.wsCardPreviewH + root.wsCardLabelH
          visible: root.workspaces.length > 0

          Rectangle {
            anchors.centerIn: parent
            width: root.effectiveWsCardWidth
            height: root.wsCardPreviewH
            radius: root.cornerRadius
            color: newWorkspaceArea.containsMouse
              ? Util.alpha(Color.popups.text, 0.12)
              : Util.alpha(Color.popups.text, 0.06)
            border.width: Math.max(1, Style.space(1))
            border.color: Util.alpha(Color.popups.text, 0.15)

            Text {
              anchors.centerIn: parent
              text: "+"
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              color: Util.alpha(Color.popups.text, 0.5)
            }

            MouseArea {
              id: newWorkspaceArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openNewWorkspace()
            }
          }
        }
      }
    }

    // ---- Optional bottom edge (opt-in) ----
    Item {
      visible: root.wsEdgeEnabled
      anchors.bottom: parent.bottom
      anchors.left: parent.left
      anchors.right: parent.right
      height: root.wsEdgeHeight
      HoverHandler {
        onHoveredChanged: if (hovered && root.ready) root.showWorkspaces()
      }
    }

    // ---- Hot-corner recognition zone ----
    CornerZone {
      z: 10
      anchors.bottom: parent.bottom
      anchors.right: parent.right
      edge: "bottom-right"
    }
  }

  component WorkspaceCard: Item {
    id: wcard

    required property var ws
    property var shell: null
    property var desktopEntries: []
    property bool focused: false

    signal activate(var ws)

    readonly property real previewHeight: Math.round(wcard.width * 9 / 16)
    readonly property real labelHeight: Math.max(Style.space(12), Style.font.caption + Style.space(4))

    readonly property color focusedBorder: Color.accent
    readonly property color idleBorder: "transparent"
    readonly property color borderColor: wcard.focused ? focusedBorder : idleBorder
    readonly property int borderWidth: Math.max(2, Style.space(2))

    readonly property string label: wcard.ws ? String(wcard.ws.label || wcard.ws.id) : ""

    readonly property color previewBackground: wcard.focused ? Color.foreground : Color.background
    readonly property color previewForeground: wcard.focused ? Color.background : Color.popups.text
    readonly property color imageTint: {
      var tint = IconModel.fallbackIconTint(wcard.previewForeground, wcard.previewBackground)
      return Qt.rgba(tint.r, tint.g, tint.b, tint.a)
    }

    readonly property int iconMaxSize: Style.space(24)
    readonly property int iconGap: Style.space(4)
    readonly property int iconPad: Style.space(5)

    readonly property var appList: wcard.buildAppList(wcard.ws)
    readonly property int appCount: wcard.appList.length

    readonly property int iconColumns: {
      var n = wcard.appCount
      if (n <= 0) return 1
      var w = Math.max(1, wcardPreview.width - wcard.iconPad * 2)
      var h = Math.max(1, wcardPreview.height - wcard.iconPad * 2)
      return Math.max(1, Math.ceil(Math.sqrt(n * (w / h))))
    }

    readonly property int iconSize: {
      var n = wcard.appCount
      if (n <= 0) return 0
      var w = Math.max(1, wcardPreview.width - wcard.iconPad * 2)
      var h = Math.max(1, wcardPreview.height - wcard.iconPad * 2)
      var cols = wcard.iconColumns
      var rows = Math.max(1, Math.ceil(n / cols))
      var size = Math.floor(Math.min(
        (w - (cols - 1) * wcard.iconGap) / cols,
        (h - (rows - 1) * wcard.iconGap) / rows
      ))
      return Math.max(10, Math.min(wcard.iconMaxSize, size))
    }

    function buildAppList(ws) {
      var out = []
      var seen = {}
      if (!ws || !ws.windows) return out

      for (var i = 0; i < ws.windows.length; i++) {
        var w = ws.windows[i]
        if (!w) continue
        var id = (typeof w.appId === "string") ? w.appId.trim() : ""
        if (id.length === 0 && w.wayland && typeof w.wayland.appId === "string") {
          id = w.wayland.appId.trim()
        }

        var key = id.toLowerCase()
        if (seen[key]) continue
        seen[key] = true

        out.push({
          appId: id,
          member: {
            title: typeof w.title === "string" ? w.title : "",
            initialTitle: typeof w.title === "string" ? w.title : "",
            className: id,
            initialClass: id,
            iconCandidates: id.length > 0 ? [id] : []
          }
        })
      }
      return out
    }

    function genericIconSource() {
      return String(Quickshell.iconPath("application-x-executable", true) || "")
    }

    function desktopEntry(member) {
      var entry = IconModel.matchDesktopEntry(member, wcard.desktopEntries)
      var candidates = member && Array.isArray(member.iconCandidates)
        ? member.iconCandidates
        : []

      if (!entry) {
        for (var i = 0; i < candidates.length && !entry; i++) {
          var candidate = String(candidates[i] || "").trim()
          if (!candidate) continue

          try {
            entry = DesktopEntries.byId(candidate)
              || DesktopEntries.byId(candidate + ".desktop")
              || DesktopEntries.heuristicLookup(candidate)
          } catch (error) {}
        }
      }

      return entry
    }

    function actualIcon(source, genericSource) {
      var value = String(source || "")
      return value.length > 0 && value !== genericSource ? source : ""
    }

    function iconSource(member, entry) {
      if (entry === undefined) entry = wcard.desktopEntry(member)
      var candidates = member && Array.isArray(member.iconCandidates)
        ? member.iconCandidates
        : []
      var genericSource = wcard.genericIconSource()

      if (entry && entry.icon) {
        if (wcard.shell && wcard.shell.appLibrary
            && typeof wcard.shell.appLibrary.iconSource === "function") {
          var libraryIcon = wcard.actualIcon(
            wcard.shell.appLibrary.iconSource(entry.icon),
            genericSource
          )
          if (libraryIcon) return libraryIcon
        }

        var entryIcon = wcard.actualIcon(Quickshell.iconPath(String(entry.icon), true), genericSource)
        if (entryIcon) return entryIcon
      }

      for (var j = 0; j < candidates.length; j++) {
        var classIconCandidate = String(candidates[j] || "").trim()
        if (!classIconCandidate) continue
        var classIcon = wcard.actualIcon(Quickshell.iconPath(classIconCandidate, true), genericSource)
        if (classIcon) return classIcon
      }

      return ""
    }

    implicitHeight: wcard.previewHeight + wcard.labelHeight + wcard.borderWidth * 2
    implicitWidth: wcard.width

    BorderSurface {
      id: wcardBorder
      anchors.top: parent.top
      anchors.horizontalCenter: parent.horizontalCenter
      width: wcard.width
      height: wcard.previewHeight + wcard.labelHeight + wcard.borderWidth * 2
      radius: Style.cornerRadius
      color: Util.alpha(Color.background, 0.6)
      borderSpec: Border.flat(wcard.borderColor, wcard.borderWidth)
      clip: true

      Item {
        id: wcardPreview
        anchors.top: parent.top
        anchors.topMargin: wcardBorder.contentTopInset
        anchors.left: parent.left
        anchors.leftMargin: wcardBorder.contentLeftInset
        width: wcardBorder.width - wcardBorder.contentLeftInset - wcardBorder.contentRightInset
        height: wcard.previewHeight
        clip: true

        Rectangle {
          anchors.fill: parent
          color: wcard.previewBackground
        }

        GridLayout {
          anchors.centerIn: parent
          columns: wcard.iconColumns
          columnSpacing: wcard.iconGap
          rowSpacing: wcard.iconGap

          Repeater {
            model: wcard.appList

            delegate: Item {
              id: appIcon
              required property var modelData
              readonly property var member: modelData.member
              readonly property var entry: wcard.desktopEntry(member)
              readonly property string mappedGlyph: IconModel.appGlyph(member, entry)
              readonly property var imageSource: mappedGlyph.length === 0
                ? wcard.iconSource(member, entry)
                : ""
              readonly property bool imageUnavailable: mappedGlyph.length === 0
                && (String(imageSource).length === 0 || appImage.status === Image.Error)
              readonly property string glyph: mappedGlyph.length > 0
                ? mappedGlyph
                : (imageUnavailable ? IconModel.genericAppGlyph() : "")
              readonly property int iconPixelRatio: Math.max(1, Math.round(Screen.devicePixelRatio))

              width: wcard.iconSize
              height: wcard.iconSize

              OpticalGlyph {
                anchors.centerIn: parent
                width: parent.width
                height: parent.height
                visible: appIcon.glyph.length > 0
                text: appIcon.glyph
                color: wcard.previewForeground
                fontFamily: "JetBrainsMono Nerd Font"
                fontSize: appIcon.height
              }

              Image {
                id: appImage
                anchors.fill: parent
                visible: appIcon.glyph.length === 0
                fillMode: Image.PreserveAspectFit
                sourceSize.width: Math.max(1, Math.round(width * appIcon.iconPixelRatio))
                sourceSize.height: Math.max(1, Math.round(height * appIcon.iconPixelRatio))
                asynchronous: true
                smooth: true
                source: appIcon.imageSource
                layer.enabled: visible
                layer.effect: MultiEffect {
                  colorization: 1.0
                  colorizationColor: wcard.imageTint
                }
              }
            }
          }
        }
      }

      RowLayout {
        anchors.top: wcardPreview.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: Style.space(1)
        spacing: Style.space(4)

        Text {
          text: wcard.label
          textFormat: Text.PlainText
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.bold: wcard.focused
          color: wcard.focused ? Color.accent : Util.alpha(Color.popups.text, 0.7)
        }

        Rectangle {
          visible: wcard.ws && wcard.ws.urgent
          width: Style.space(5)
          height: Style.space(5)
          radius: width / 2
          color: Color.urgent
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: wcard.activate(wcard.ws)
      }
    }
  }
}