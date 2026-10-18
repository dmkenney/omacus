import QtQuick
import Quickshell.Io

// A long-running `helper.py monitor`. Splits raw chunks into lines itself so
// one line can never grow past a ceiling, and emits each line as an event.
Item {
  id: root

  property int maxLineChars: 65536
  readonly property bool running: proc.running

  property string _pending: ""

  signal event(var doc)
  signal stopped()

  function start(argv) {
    if (proc.running) return false
    _pending = ""
    proc.command = argv
    proc.running = true
    return true
  }

  function stop() {
    if (!proc.running) return
    proc.signal(15)
    killTimer.restart()
  }

  function _feed(chunk) {
    var text = _pending + chunk
    var lines = text.split("\n")
    _pending = lines.pop()
    if (_pending.length > maxLineChars) _pending = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line === "" || line.length > maxLineChars) continue
      var doc = null
      try { doc = JSON.parse(line) } catch (e) { doc = null }
      if (doc && typeof doc === "object") root.event(doc)
    }
  }

  Process {
    id: proc
    running: false
    command: []
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root._feed(chunk) }
    }
    onExited: {
      killTimer.stop()
      root._pending = ""
      root.stopped()
    }
  }

  Timer {
    id: killTimer
    interval: 2000
    repeat: false
    onTriggered: if (proc.running) proc.signal(9)
  }

  Component.onDestruction: if (proc.running) proc.signal(15)
}
