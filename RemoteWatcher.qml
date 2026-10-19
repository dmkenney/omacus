import QtQuick

// Keeps one Incus remote current: a full read when it starts, then one
// `incus monitor` stream whose lifecycle events trigger a re-read. Only
// instance stats are polled (Incus sends no event for CPU or memory use).
Item {
  id: root

  required property string remoteName
  required property var service

  readonly property bool snapshotBusy: fullRun.running || statsRun.running

  property bool _fullPending: false
  property bool _instancesPending: false
  property int _monitorFailures: 0
  property int _snapshotFailures: 0
  property double _monitorStartedMs: 0

  function helperArgs(rest) {
    return service.helperCommand(rest)
  }

  function project() {
    return service.remoteProject(remoteName)
  }

  // Coalesce bursts: an image launch emits a dozen events in a second.
  function scheduleRefresh(full) {
    if (full) _fullPending = true
    else _instancesPending = true
    debounce.restart()
  }

  function refreshNow(full) {
    if (full) {
      if (fullRun.start(helperArgs(["snapshot", remoteName, project()]))) {
        _fullPending = false
        _instancesPending = false
      } else {
        _fullPending = true
        debounce.restart()
      }
      return
    }
    if (fullRun.running || statsRun.running) {
      _instancesPending = true
      debounce.restart()
      return
    }
    if (statsRun.start(helperArgs(["snapshot", remoteName, project(), "--instances-only"]))) _instancesPending = false
  }

  function sampleStats() {
    if (!fullRun.running && !statsRun.running && service.isConnected(remoteName))
      statsRun.start(helperArgs(["snapshot", remoteName, project(), "--instances-only"]))
  }

  function startMonitor() {
    if (monitor.running) return
    _monitorStartedMs = Date.now()
    monitor.start(helperArgs(["monitor", remoteName]))
  }

  // 2s, 4s, 8s ... capped at five minutes, so a server that is off for the
  // night costs a handful of attempts an hour.
  function backoffMs(failures) {
    return Math.min(300000, 2000 * Math.pow(2, Math.min(failures, 8)))
  }

  Component.onCompleted: {
    service.markConnecting(remoteName)
    refreshNow(true)
    startMonitor()
  }

  Timer {
    id: debounce
    interval: 400
    repeat: false
    onTriggered: {
      if (root._fullPending) root.refreshNow(true)
      else if (root._instancesPending) root.refreshNow(false)
    }
  }

  Timer {
    id: monitorRetry
    repeat: false
    onTriggered: root.startMonitor()
  }

  Timer {
    id: snapshotRetry
    repeat: false
    onTriggered: root.refreshNow(true)
  }

  HelperRun {
    id: fullRun
    onDone: function(doc) {
      if (doc.ok) {
        root._snapshotFailures = 0
        root.service.applySnapshot(root.remoteName, doc, true)
      } else {
        root._snapshotFailures++
        root.service.applyFailure(root.remoteName, doc)
        // The monitor's reconnect also re-reads, so only retry on our own
        // when the stream is up and the read itself failed.
        if (monitor.running) {
          snapshotRetry.interval = root.backoffMs(root._snapshotFailures)
          snapshotRetry.restart()
        }
      }
      if (root._fullPending || root._instancesPending) debounce.restart()
    }
  }

  HelperRun {
    id: statsRun
    timeoutMs: 30000
    onDone: function(doc) {
      if (doc.ok) root.service.applySnapshot(root.remoteName, doc, false)
      if (root._fullPending || root._instancesPending) debounce.restart()
    }
  }

  HelperStream {
    id: monitor
    onEvent: function(doc) {
      if (doc.t === "up") return
      if (doc.t === "down") {
        root.service.applyFailure(root.remoteName, { ok: false, unreachable: doc.unreachable === true, error: String(doc.error || "") })
        return
      }
      if (doc.t === "resync") {
        root.scheduleRefresh(true)
        return
      }
      if (doc.t === "op" || doc.t === "opdone") {
        root.service.applyOperation(root.remoteName, doc)
        if (doc.t === "opdone") root.scheduleRefresh(true)
        return
      }
      if (doc.t === "life") {
        root.service.applyLifecycle(root.remoteName, doc)
        const action = String(doc.action || "")
        root.scheduleRefresh(action.indexOf("instance-") !== 0 || action === "instance-created" || action === "instance-deleted")
      }
    }
    onStopped: {
      // A stream that ran for a while was healthy: start over from 2s.
      if (Date.now() - root._monitorStartedMs > 60000) root._monitorFailures = 0
      else root._monitorFailures++
      if (!root.service || root.service.shuttingDown) return
      monitorRetry.interval = root.backoffMs(root._monitorFailures)
      monitorRetry.restart()
      // Whatever happened while the stream was down, it was not seen.
      snapshotRetry.interval = monitorRetry.interval + 500
      snapshotRetry.restart()
    }
  }

  Connections {
    target: root.service
    function onStatsTick() { root.sampleStats() }
    function onRefreshAllRequested() { root.scheduleRefresh(true) }
  }
}
