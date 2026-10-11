import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Display-only ON AIR / REC pill with click actions:
// - Left-click: toggle pause / resume recording
// - Right-click: stop recording
BarWidget {
  id: root
  moduleName: "io.github.pshouse.obs-onair"

  readonly property string statusScript: localPath("bin/obs-onair-status")
  readonly property string controlScript: localPath("bin/obs-onair-control")
  readonly property string viewersScript: localPath("bin/obs-onair-viewers")
  readonly property var brbScenes: String(setting("brbScenes", "Be right back, BRB"))
    .split(",").map(function(s) { return s.trim() }).filter(function(s) { return s.length > 0 })
  readonly property bool showViewers: setting("showViewers", true) === true
  readonly property int viewerIntervalSec: Math.max(30, Number(setting("viewerIntervalSec", 60)) || 60)
  readonly property string credentialsFile: String(setting("credentialsFile", ""))
  readonly property var viewersCommand: credentialsFile
    ? ["bash", viewersScript, "--credentials", credentialsFile] : ["bash", viewersScript]
  readonly property color liveColor: Color.urgent
  readonly property color brbColor: "#e0a030"

  property bool active: false
  property bool streaming: false
  property bool recording: false
  property bool recordPaused: false
  property bool reconnecting: false
  property string scene: ""
  property real durationMs: 0
  property real streamDurationMs: 0
  property real recordDurationMs: 0
  property real polledAt: 0
  property real now: Date.now()
  property real skipped: 0
  property real totalFrames: 0
  property real lastBytes: -1
  property real lastBytesAt: 0
  property int bitrateKbps: 0
  property var youtube: null
  property var twitch: null
  property var viewers: null
  property bool hovered: false

  // Click target properties for Bar.qml integration
  property bool interactive: true
  property bool pressable: true
  property real lastActionAt: 0
  property var registeredBar: null

  // WebSocket problems are announced once, and again only after they clear.
  property string websocketProblem: ""
  property int websocketErrorPolls: 0
  // The bar only shows a tooltip while its target reports tooltipHovered.
  readonly property bool tooltipHovered: hovered && active

  readonly property bool brb: active && streaming && brbScenes.indexOf(scene) !== -1
  readonly property string mode: !active ? "off"
    : reconnecting ? "reconnecting"
    : brb ? "brb"
    : (!streaming && recordPaused) ? "paused"
    : (!streaming && recording) ? "rec"
    : "live"

  readonly property real streamElapsedMs: streaming ? streamDurationMs + Math.max(0, now - polledAt) : 0
  readonly property real recordElapsedMs: recording ? recordDurationMs + (recordPaused ? 0 : Math.max(0, now - polledAt)) : 0
  readonly property real elapsedMs: streaming ? streamElapsedMs : recordElapsedMs

  readonly property string label: reconnecting ? (recording ? "RECONNECTING • REC" : "RECONNECTING")
    : brb ? (recording ? "BRB • REC" : "BRB")
    : (streaming && recording) ? (recordPaused ? "ON AIR • PAUSED" : "ON AIR • REC")
    : streaming ? "ON AIR"
    : recordPaused ? "REC PAUSED"
    : "REC"

  function formatDuration(ms) {
    var s = Math.floor(ms / 1000)
    var h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), sec = s % 60
    return h + ":" + (m < 10 ? "0" : "") + m + ":" + (sec < 10 ? "0" : "") + sec
  }

  function localPath(relative) {
    return decodeURIComponent(String(Qt.resolvedUrl(relative)).replace(/^file:\/\//, ""))
  }

  function hasCount(n) { return n !== null && n !== undefined }

  function tooltipText() {
    var dropPct = totalFrames > 0 ? (skipped / totalFrames * 100).toFixed(2) : "0.00"
    var lines = []
    lines.push("Scene: " + (scene || "?"))
    if (streaming && recording) {
      lines.push("State: Streaming & " + (recordPaused ? "Recording (Paused)" : "Recording"))
      lines.push("Stream time: " + formatDuration(streamElapsedMs))
      lines.push("Record time: " + formatDuration(recordElapsedMs))
      lines.push("Bitrate: " + bitrateKbps + " kb/s")
      lines.push("Dropped: " + skipped + " frames (" + dropPct + "%)")
    } else if (streaming) {
      lines.push("State: Streaming")
      lines.push("Stream time: " + formatDuration(streamElapsedMs))
      lines.push("Bitrate: " + bitrateKbps + " kb/s")
      lines.push("Dropped: " + skipped + " frames (" + dropPct + "%)")
    } else if (recording) {
      lines.push("State: " + (recordPaused ? "Recording (Paused)" : "Recording"))
      lines.push("Record time: " + formatDuration(recordElapsedMs))
      if (bitrateKbps > 0) lines.push("Write speed: " + bitrateKbps + " kb/s")
    }
    if (hasCount(youtube)) lines.push("YouTube viewers: " + youtube)
    if (hasCount(twitch)) lines.push("Twitch viewers: " + twitch)
    if (recording) {
      lines.push("—")
      lines.push("Left-click: " + (recordPaused ? "Resume recording" : "Pause recording"))
      lines.push("Right-click: Stop recording")
    }
    return lines.join("\n")
  }

  function togglePauseRecording() {
    controlProc.command = ["python3", "-I", root.controlScript, "toggle-pause"]
    controlProc.running = true
  }

  function stopRecording() {
    controlProc.command = ["python3", "-I", root.controlScript, "stop"]
    controlProc.running = true
  }

  function handleAction(action) {
    var t = Date.now()
    if (t - lastActionAt < 300) return
    lastActionAt = t
    if (action === "stop") {
      stopRecording()
    } else if (action === "toggle-pause") {
      togglePauseRecording()
    }
  }

  function triggerPress(button) {
    if (!root.active) return
    if (button === Qt.RightButton) {
      handleAction("stop")
    } else {
      handleAction("toggle-pause")
    }
  }

  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = root.bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }

  onBarChanged: syncClickRegistration()
  Component.onCompleted: syncClickRegistration()
  Component.onDestruction: if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(output) {
    var data
    try { data = JSON.parse(String(output || "").trim()) } catch (e) { return }
    var wasActive = active
    active = data.active === true
    checkWebsocket(data.websocket || "")
    if (!active) {
      if (wasActive) resetProc.running = true
      streaming = false; recording = false; recordPaused = false
      reconnecting = false; scene = ""; durationMs = 0; lastBytes = -1
      streamDurationMs = 0; recordDurationMs = 0
      bitrateKbps = 0; youtube = null; twitch = null; viewers = null
      return
    }
    var t = Date.now()
    if (lastBytes >= 0 && data.bytes >= lastBytes && t > lastBytesAt)
      bitrateKbps = Math.round((data.bytes - lastBytes) * 8 / (t - lastBytesAt))
    lastBytes = data.bytes; lastBytesAt = t
    streaming = data.streaming === true
    recording = data.recording === true
    recordPaused = data.recordPaused === true
    reconnecting = data.reconnecting === true
    scene = data.scene || ""
    durationMs = data.durationMs || 0
    streamDurationMs = data.streamDurationMs || 0
    recordDurationMs = data.recordDurationMs || 0
    polledAt = t; now = t
    skipped = data.skipped || 0
    totalFrames = data.total || 0
    if (!wasActive && streaming) refreshViewers()
  }

  function checkWebsocket(state) {
    websocketErrorPolls = state === "error" ? websocketErrorPolls + 1 : 0
    var problem = state === "disabled" ? "disabled" : (websocketErrorPolls >= 5 ? "error" : "")
    if (state === "error" && !problem) return
    if (problem && problem !== websocketProblem) {
      var body = problem === "disabled"
        ? "Turn on the WebSocket server in OBS: Tools → WebSocket Server Settings → Enable WebSocket server."
        : "Can't connect to the OBS WebSocket server. Check the port and password in OBS: Tools → WebSocket Server Settings."
      notifyProc.command = ["notify-send", "-a", "OBS On Air", "OBS On Air", body]
      notifyProc.running = true
    }
    websocketProblem = problem
  }

  function refreshViewers() {
    if (showViewers && !viewersProc.running) viewersProc.running = true
  }

  function applyViewers(output) {
    var data
    try { data = JSON.parse(String(output || "").trim()) } catch (e) { return }
    if (!active) return
    youtube = data.youtube; twitch = data.twitch; viewers = data.total
  }

  visible: active
  implicitWidth: active ? pill.width + Style.spacing.sm * 2 : 0
  implicitHeight: barSize

  onHoveredChanged: if (!hovered && bar) bar.hideTooltip(root)

  IpcHandler {
    target: "io.github.pshouse.obs-onair"
    function refresh(): void { root.broadcast("refresh") }
  }

  Process {
    id: statusProc
    command: ["python3", "-I", root.statusScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: controlProc
    onExited: root.refresh()
  }

  Process {
    id: viewersProc
    command: root.viewersCommand
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyViewers(text)
    }
  }

  Process {
    id: notifyProc
  }

  Process {
    id: resetProc
    command: ["bash", root.viewersScript, "--reset"]
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: root.viewerIntervalSec * 1000
    running: root.active && root.streaming && root.showViewers
    repeat: true
    onTriggered: root.refreshViewers()
  }

  Timer {
    interval: 1000
    running: root.active
    repeat: true
    onTriggered: root.now = Date.now()
  }

  Rectangle {
    id: pill
    anchors.centerIn: parent
    height: Math.round(root.barSize * 0.72)
    width: root.vertical ? height : content.implicitWidth + Style.spacing.lg * 2
    radius: height / 2
    color: (root.mode === "live" || root.mode === "rec") ? root.liveColor : root.brbColor

    SequentialAnimation on opacity {
      running: root.mode === "reconnecting"
      loops: Animation.Infinite
      onRunningChanged: if (!running) pill.opacity = 1
      NumberAnimation { to: 0.35; duration: 500 }
      NumberAnimation { to: 1; duration: 500 }
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.spacing.md

      Rectangle {
        id: dot
        anchors.verticalCenter: parent.verticalCenter
        width: Math.round(pill.height * 0.4)
        height: width
        radius: width / 2
        color: Color.background

        SequentialAnimation on opacity {
          running: root.mode === "live" || root.mode === "rec"
          loops: Animation.Infinite
          onRunningChanged: if (!running) dot.opacity = 1
          NumberAnimation { to: 0.2; duration: 700; easing.type: Easing.InOutSine }
          NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
        }
      }

      Text {
        visible: !root.vertical
        anchors.verticalCenter: parent.verticalCenter
        text: root.label + "  " + root.formatDuration(root.elapsedMs) +
          (root.streaming && root.showViewers && root.hasCount(root.viewers) ? "  󰈈 " + root.viewers : "")
        color: Color.background
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  HoverHandler {
    onHoveredChanged: {
      root.hovered = hovered
      if (hovered && root.bar) root.bar.showTooltip(root, root.tooltipText())
    }
  }

  TapHandler {
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    gesturePolicy: TapHandler.WithinBounds
    onTapped: function(eventPoint, button) {
      if (!root.active) return
      if (button === Qt.RightButton) {
        root.handleAction("stop")
      } else {
        root.handleAction("toggle-pause")
      }
    }
  }
}
