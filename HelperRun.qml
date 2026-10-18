import QtQuick
import Quickshell.Io

// One bounded call to helper.py. Collects stdout in raw chunks up to a
// ceiling, then hands the parsed JSON document to done(). The helper enforces
// its own deadlines; the watchdog here only catches a helper that hangs.
Item {
  id: root

  property int maxChars: 2 * 1024 * 1024 + 4096
  property int timeoutMs: 60000
  readonly property bool running: proc.running

  property string _buffer: ""
  property bool _overflow: false

  signal done(var doc)

  function start(argv) {
    if (proc.running) return false
    _buffer = ""
    _overflow = false
    proc.command = argv
    proc.running = true
    watchdog.restart()
    return true
  }

  function stop() {
    if (!proc.running) return
    proc.signal(15)
    killTimer.restart()
  }

  Process {
    id: proc
    running: false
    command: []
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root._overflow) return
        if (root._buffer.length + chunk.length > root.maxChars) {
          root._overflow = true
          root._buffer = ""
          root.stop()
          return
        }
        root._buffer += chunk
      }
    }
    onExited: function(exitCode) {
      watchdog.stop()
      killTimer.stop()
      var text = root._buffer
      root._buffer = ""
      var doc = null
      if (!root._overflow) {
        try { doc = JSON.parse(text) } catch (e) { doc = null }
      }
      if (!doc || typeof doc !== "object") doc = { ok: false, error: root._overflow ? "helper output too large" : "helper failed" }
      root.done(doc)
    }
  }

  Timer {
    id: watchdog
    interval: root.timeoutMs
    repeat: false
    onTriggered: root.stop()
  }

  Timer {
    id: killTimer
    interval: 2000
    repeat: false
    onTriggered: if (proc.running) proc.signal(9)
  }

  Component.onDestruction: if (proc.running) proc.signal(15)
}
