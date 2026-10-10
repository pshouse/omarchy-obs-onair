import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Display-only ON AIR pill. State comes from OBS via bin/obs-onair-status
// (polled every 2s); viewer counts from bin/obs-onair-viewers (while live).
// Hidden whenever OBS isn't streaming.
BarWidget {
  id: root
  moduleName: "io.github.pshouse.obs-onair"

  readonly property string statusScript: localPath("bin/obs-onair-status")
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
  property bool reconnecting: false
  property string scene: ""
  property real durationMs: 0
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

  readonly property bool brb: active && brbScenes.indexOf(scene) !== -1
  readonly property string mode: !active ? "off" : reconnecting ? "reconnecting" : brb ? "brb" : "live"
  readonly property real elapsedMs: active ? durationMs + Math.max(0, now - polledAt) : 0
  readonly property string label: mode === "reconnecting" ? "RECONNECTING" : mode === "brb" ? "BRB" : "ON AIR"

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
    return "Scene: " + (scene || "?") +
      "\nElapsed: " + formatDuration(elapsedMs) +
      "\nBitrate: " + bitrateKbps + " kb/s" +
      "\nDropped: " + skipped + " frames (" + dropPct + "%)" +
      (hasCount(youtube) ? "\nYouTube viewers: " + youtube : "") +
      (hasCount(twitch) ? "\nTwitch viewers: " + twitch : "")
  }

  function refresh() {
    if (!statusProc.running) statusProc.running = true
  }

  function applyStatus(output) {
    var data
    try { data = JSON.parse(String(output || "").trim()) } catch (e) { return }
    var wasActive = active
    active = data.active === true
    if (!active) {
      if (wasActive) resetProc.running = true
      reconnecting = false; scene = ""; durationMs = 0; lastBytes = -1
      bitrateKbps = 0; youtube = null; twitch = null; viewers = null
      return
    }
    var t = Date.now()
    if (lastBytes >= 0 && data.bytes >= lastBytes && t > lastBytesAt)
      bitrateKbps = Math.round((data.bytes - lastBytes) * 8 / (t - lastBytesAt))
    lastBytes = data.bytes; lastBytesAt = t
    reconnecting = data.reconnecting === true
    scene = data.scene || ""
    durationMs = data.durationMs || 0
    polledAt = t; now = t
    skipped = data.skipped || 0
    totalFrames = data.total || 0
    if (!wasActive) refreshViewers()
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
    command: ["bash", root.statusScript]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
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
    running: root.active && root.showViewers
    repeat: true
    onTriggered: root.refreshViewers()
  }

  // Ticks the clock between polls; also keeps an open tooltip current.
  Timer {
    interval: 1000
    running: root.active
    repeat: true
    onTriggered: {
      root.now = Date.now()
      if (root.hovered && root.bar) root.bar.showTooltip(root, root.tooltipText())
    }
  }

  Rectangle {
    id: pill
    anchors.centerIn: parent
    height: Math.round(root.barSize * 0.72)
    width: root.vertical ? height : content.implicitWidth + Style.spacing.lg * 2
    radius: height / 2
    color: root.mode === "live" ? root.liveColor : root.brbColor

    // Reconnecting blinks the whole pill.
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
          running: root.mode === "live"
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
          (root.showViewers && root.hasCount(root.viewers) ? "  󰈈 " + root.viewers : "")
        color: Color.background
        font.family: root.bar ? root.bar.fontFamily : "monospace"
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    onEntered: {
      root.hovered = true
      if (root.bar) root.bar.showTooltip(root, root.tooltipText())
    }
    onExited: root.hovered = false
  }
}
