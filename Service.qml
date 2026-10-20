import QtQuick
import QtQml
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "Model.js" as Model

// Everything Omacus knows about your Incus servers. The shell loads this once
// and hands it to every bar's widget, so there is one event stream per remote
// however many monitors there are. The widget pushes its settings in, and
// tells the service when its panel opens so stats are sampled only then.
Item {
  id: root

  // Injected by the shell for a `service` entry point.
  property var shell: null
  property var manifest: null

  property var _widgetSettings: ({})
  property var _widgetOrder: []
  readonly property var settings: _widgetOrder.length > 0 ? (_widgetSettings[_widgetOrder[0]] || {}) : {}

  property bool shuttingDown: false
  property bool checked: false
  property string incusPath: ""
  property string incusVersion: ""
  property string setupError: ""
  property var remotes: []
  property string defaultRemote: ""
  property var states: ({})
  property var operations: ({})
  property var samples: ({})
  property var cpuNow: ({})
  property var history: ({})
  property var busy: ({})
  property string actionStatus: ""
  property string actionError: ""
  property int openPanels: 0

  property var _pendingStops: ({})
  property var _notified: ({})
  property var _baseline: ({})
  property var _unreachableSince: ({})

  readonly property bool installed: incusPath !== ""
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("helper.py")).replace(/^file:\/\//, ""))
  readonly property bool readOnly: settings.readOnly === true
  readonly property string notifications: ["all", "watched", "off"].indexOf(String(settings.notifications)) !== -1 ? String(settings.notifications) : "all"
  readonly property var watched: Model.parseList(settings.watched)
  readonly property int snapshotWarnDays: intSetting("snapshotWarnDays", 7, 0, 365)
  readonly property int poolWarnPercent: intSetting("poolWarnPercent", 85, 50, 99)
  readonly property int statsIntervalSec: intSetting("statsIntervalSec", 5, 2, 60)
  readonly property bool backgroundStats: settings.backgroundStats !== false
  readonly property string configuredIncusPath: {
    var path = String(settings.incusPath || "")
    return path.charAt(0) === "/" && path.length < 4096 ? path : ""
  }

  // Remotes we watch: every remote the union of widget filters allows. A
  // local remote with no daemon socket is skipped unless asked for by name.
  readonly property var remoteFilter: {
    var all = false
    var names = []
    for (var i = 0; i < _widgetOrder.length; i++) {
      var list = Model.parseList((_widgetSettings[_widgetOrder[i]] || {}).remotes)
      if (list.length === 0) all = true
      for (var j = 0; j < list.length; j++) if (names.indexOf(list[j]) === -1) names.push(list[j])
    }
    return { all: all || _widgetOrder.length === 0, names: names }
  }
  readonly property var watchedRemotes: {
    var out = []
    for (var i = 0; i < remotes.length; i++) {
      var r = remotes[i]
      var named = remoteFilter.names.indexOf(r.name) !== -1
      if (!remoteFilter.all && !named) continue
      if (r.local && !r.present && !named) continue
      out.push(r.name)
    }
    return out
  }
  readonly property var remoteList: {
    var out = []
    for (var i = 0; i < watchedRemotes.length; i++) {
      var name = watchedRemotes[i]
      var st = states[name] || { name: name, status: "connecting" }
      out.push(st)
    }
    return out
  }
  readonly property var attentionItems: Model.attention(remoteList, {
    watched: watched,
    snapshotWarnDays: snapshotWarnDays,
    poolWarnPercent: poolWarnPercent
  })
  readonly property bool urgent: {
    for (var i = 0; i < attentionItems.length; i++) if (attentionItems[i].severity === "urgent") return true
    return false
  }
  readonly property bool warning: attentionItems.length > 0 && !urgent

  signal statsTick()
  signal refreshAllRequested()

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(settings[name] === undefined || settings[name] === null ? fallback : settings[name]), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // Widgets

  function registerWidget(token, widgetSettings) {
    var next = Object.assign({}, _widgetSettings)
    next[token] = widgetSettings || {}
    _widgetSettings = next
    if (_widgetOrder.indexOf(token) === -1) _widgetOrder = _widgetOrder.concat([token])
  }

  function unregisterWidget(token) {
    var next = Object.assign({}, _widgetSettings)
    delete next[token]
    _widgetSettings = next
    _widgetOrder = _widgetOrder.filter(function(t) { return t !== token })
  }

  function panelOpened() {
    openPanels++
    discover()
    refreshAllRequested()
  }

  function panelClosed() {
    openPanels = Math.max(0, openPanels - 1)
    // Without background stats nothing keeps these current while closed.
    if (openPanels === 0 && !backgroundStats) cpuNow = ({})

  }

  // Helper calls

  function helperCommand(rest) {
    var argv = ["/usr/bin/python3", "-I", "-S", helperPath]
    if (configuredIncusPath !== "") argv.push("--incus", configuredIncusPath)
    return argv.concat(rest)
  }

  function discover() {
    if (!probeRun.running && !remotesRun.running) probeRun.start(helperCommand(["probe"]))
  }

  function remoteProject(name) {
    for (var i = 0; i < remotes.length; i++) if (remotes[i].name === name) return remotes[i].project || ""
    return ""
  }

  function remoteInfo(name) {
    for (var i = 0; i < remotes.length; i++) if (remotes[i].name === name) return remotes[i]
    return null
  }

  function isConnected(name) {
    var st = states[name]
    return !!st && st.status === "ok"
  }

  // State updates from the watchers

  function setState(name, patch) {
    var next = Object.assign({}, states)
    next[name] = Object.assign({ name: name }, states[name] || {}, patch)
    states = next
  }

  function markConnecting(name) {
    if (!states[name] || states[name].status !== "ok") setState(name, { status: "connecting", error: "" })
  }

  function applySnapshot(name, doc, full) {
    if (watchedRemotes.indexOf(name) === -1) return
    var previous = states[name] || {}
    var instances = Model.sortInstances(doc.instances || [])
    var patch = { status: "ok", error: "", instances: instances, scope: doc.scope || "all", updatedAt: Date.now() }
    if (full) {
      patch.host = doc.host || null
      patch.pools = doc.pools || []
      patch.warnings = doc.warnings || []
      patch.warningCount = doc.warningCount || 0
      patch.members = doc.members || []
      var ops = Object.assign({}, operations)
      ops[name] = doc.operations || []
      operations = ops
    }
    var wasDown = previous.status === "unreachable" || previous.status === "error"
    setState(name, patch)
    recordSamples(name, instances, (doc.takenAt || Date.now() / 1000) * 1000, patch.host || previous.host)
    if (wasDown && _unreachableSince[name] === -1) notify(Model.glyphs.server, "normal", strings.t("notify.reachableAgain").arg(name), "")
    var since = Object.assign({}, _unreachableSince)
    delete since[name]
    _unreachableSince = since
    checkTransitions(name, previous.instances || [], instances)
  }

  function applyFailure(name, doc) {
    if (watchedRemotes.indexOf(name) === -1) return
    var status = doc.unreachable ? "unreachable" : "error"
    setState(name, { status: status, error: Model.plain(doc.error || "", 300) })
    var since = Object.assign({}, _unreachableSince)
    if (since[name] === undefined) since[name] = Date.now()
    _unreachableSince = since
    unreachableCheck.restart()
  }

  function applyOperation(name, doc) {
    var list = (operations[name] || []).filter(function(op) { return op.id !== doc.id })
    if (doc.t === "op") list = [doc].concat(list).slice(0, 20)
    var next = Object.assign({}, operations)
    next[name] = list
    operations = next
  }

  function applyLifecycle(name, doc) {
    var action = String(doc.action || "")
    if (action !== "instance-stopped" && action !== "instance-shutdown") return
    var key = name + "/" + doc.project + "/" + doc.name
    var pending = _pendingStops[key]
    if (pending && Date.now() - pending < 180000) return
    if (notifications === "watched" && !Model.isWatched(watched, name, doc.name)) return
    var urgency = Model.isWatched(watched, name, doc.name) ? "critical" : "normal"
    notify(Model.glyphs.stop, urgency, strings.t("notify.stopped").arg(doc.name), strings.t("notify.onRemote").arg(name))
  }

  function recordSamples(name, instances, at, host) {
    var threads = host ? host.cpuThreads : null
    var nextSamples = Object.assign({}, samples)
    var nextCpu = Object.assign({}, cpuNow)
    var nextHistory = backgroundStats ? Object.assign({}, history) : history
    var seen = {}
    for (var i = 0; i < instances.length; i++) {
      var inst = instances[i]
      var key = Model.instanceKey(name, inst)
      seen[key] = true
      var sample = { cpuUsage: inst.cpuUsage, cpuAllocated: inst.cpuAllocated, at: at }
      var pct = Model.isRunning(inst) ? Model.cpuPercent(samples[key], sample, threads) : null
      nextSamples[key] = sample
      if (pct !== null) nextCpu[key] = pct
      else if (!Model.isRunning(inst)) delete nextCpu[key]
      if (backgroundStats && Model.isRunning(inst)) {
        var h = nextHistory[key] || { cpu: [], base: null }
        if (!h.base) nextHistory[key] = { cpu: h.cpu, base: sample }
        else if (at - h.base.at >= Model.HISTORY_STEP_MS) {
          var avg = Model.cpuPercent(h.base, sample, threads)
          nextHistory[key] = { cpu: avg === null ? h.cpu : Model.pushHistory(h.cpu, avg, at), base: sample }
        }
      }
    }
    // Forget instances that went away on this remote.
    var prefix = name + "/"
    for (var k in nextSamples) if (k.indexOf(prefix) === 0 && !seen[k]) delete nextSamples[k]
    for (var c in nextCpu) if (c.indexOf(prefix) === 0 && !seen[c]) delete nextCpu[c]
    if (backgroundStats) for (var hk in nextHistory) if (hk.indexOf(prefix) === 0 && !seen[hk]) delete nextHistory[hk]
    samples = nextSamples
    cpuNow = nextCpu
    if (backgroundStats) history = nextHistory
  }

  // Notifications fire on a change, never for what was already true when the
  // remote was first read.
  function checkTransitions(name, before, after) {
    if (!_baseline[name]) {
      var b = Object.assign({}, _baseline)
      b[name] = true
      _baseline = b
      var initial = Object.assign({}, _notified)
      var items = attentionItems
      for (var i = 0; i < items.length; i++) if (items[i].remote === name) initial[items[i].key] = true
      _notified = initial
      return
    }
    var oldStatus = {}
    for (var j = 0; j < before.length; j++) oldStatus[before[j].project + "/" + before[j].name] = before[j].status
    for (var k = 0; k < after.length; k++) {
      var inst = after[k]
      var was = oldStatus[inst.project + "/" + inst.name]
      if (Model.isError(inst) && was !== undefined && was !== "Error")
        notify(Model.glyphs.alert, "critical", strings.t("notify.errorState").arg(inst.name), strings.t("notify.onRemote").arg(name))
    }
    notifyAttention()
  }

  function notifyAttention() {
    var next = {}
    var items = attentionItems
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      next[item.key] = true
      if (_notified[item.key] || !_baseline[item.remote]) continue
      if (item.kind === "pool") notify(Model.glyphs.pool, item.severity === "urgent" ? "critical" : "normal", strings.t("notify.poolFull").arg(item.name).arg(Model.formatPercent(item.percent)), strings.t("notify.onRemote").arg(item.remote))
      else if (item.kind === "member") notify(Model.glyphs.server, "critical", strings.t("notify.memberDown").arg(item.name).arg(item.text), strings.t("notify.onRemote").arg(item.remote))
    }
    // Keep remote keys, which the unreachable timer manages.
    for (var key in _notified) if (key.indexOf("remote:") === 0 && _notified[key]) next[key] = true
    _notified = next
  }

  function notify(glyph, urgency, headline, body) {
    if (notifications === "off") return
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Omacus", "-g", glyph, "-u", urgency,
      "Omacus: " + Model.plain(headline, 120), Model.plain(body, 200)])
  }

  // Actions

  function actionKey(remote, inst) { return Model.instanceKey(remote, inst) }

  function runAction(verb, remote, inst) {
    if (readOnly || !inst) return
    if (!Model.validName(remote) || !Model.validName(inst.project) || !Model.validInstanceName(inst.name)) return
    var key = actionKey(remote, inst)
    if (busy[key]) return
    var b = Object.assign({}, busy)
    b[key] = verb
    busy = b
    if (verb === "stop" || verb === "force-stop" || verb === "restart") {
      var p = Object.assign({}, _pendingStops)
      p[key] = Date.now()
      _pendingStops = p
    }
    actionError = ""
    actionComponent.createObject(root, { verb: verb, remote: remote, inst: inst, key: key })
  }

  function finishAction(key, verb, inst, doc) {
    var b = Object.assign({}, busy)
    delete b[key]
    busy = b
    if (!doc.ok) {
      actionError = strings.t("action.failed").arg(inst.name).arg(Model.plain(doc.error || "", 200))
      actionErrorTimer.restart()
    }
  }

  function terminalCommand(argv) {
    // A constant script: run the command, and if it failed keep the window
    // open so the error stays readable.
    var script = 'printf "\\033]2;Omacus\\007"; "$@"; code=$?; if [ "$code" -ne 0 ] && [ "$code" -ne 130 ]; then printf "\\n[exited with status %s, press Enter to close]" "$code"; read -r _; fi'
    Quickshell.execDetached(["omarchy-launch-terminal", "bash", "-c", script, "omacus"].concat(argv))
  }

  // Omarchy's floating terminal runs one shell string and ends with its own
  // done or failed prompt.
  function presentCommand(argv) {
    var line = argv.map(function(a) { return "'" + String(a).replace(/'/g, "'\\''") + "'" }).join(" ")
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", line])
  }

  function installClient() {
    if (!installed) presentCommand(["omarchy-pkg-add", "incus"])
  }

  function addRemote() {
    if (!installed) return
    // The helper reads the token without echo and passes it to incus on stdin.
    presentCommand(helperCommand(["add-remote"]))
  }

  function openShell(remote, inst) {
    if (readOnly || !installed || !Model.validName(remote) || !Model.validName(inst.project) || !Model.validInstanceName(inst.name)) return
    terminalCommand([incusPath, "exec", "--project", inst.project, remote + ":" + inst.name, "--", "su", "-l"])
  }

  function openConsole(remote, inst) {
    if (readOnly || !installed || !Model.validName(remote) || !Model.validName(inst.project) || !Model.validInstanceName(inst.name)) return
    terminalCommand([incusPath, "console", "--project", inst.project, "--type", inst.type === "vm" ? "vga" : "console", remote + ":" + inst.name])
  }

  function launchInstance(remote, project, image, name, vm) {
    if (readOnly || !installed || !Model.validName(remote) || !Model.validName(project) || !Model.validImage(image) || !Model.validInstanceName(name)) return false
    var argv = [incusPath, "launch", "--project", project]
    if (vm) argv.push("--vm")
    terminalCommand(argv.concat([image, remote + ":" + name]))
    return true
  }

  function openReadme() {
    Quickshell.execDetached(["omarchy-launch-browser", Model.readmeSettingsUrl])
  }

  function copyText(text) {
    var value = String(text || "")
    if (value === "" || value.length > 200) return
    Quickshell.execDetached(["wl-copy", "--", value])
  }

  function openWebUi(remote) {
    var info = remoteInfo(remote)
    var url = info ? Model.webUiUrl(info.addr) : ""
    if (url !== "") Quickshell.execDetached(["omarchy-launch-browser", url])
  }

  function refresh() {
    discover()
    refreshAllRequested()
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Component.onCompleted: discover()
  Component.onDestruction: shuttingDown = true

  // A new client path means new streams: drop the watchers running on the
  // old one, then look again.
  onBackgroundStatsChanged: if (!backgroundStats) history = ({})

  onConfiguredIncusPathChanged: {
    remotes = []
    discover()
  }

  HelperRun {
    id: probeRun
    timeoutMs: 20000
    onDone: function(doc) {
      root.checked = true
      root.incusPath = doc.ok ? String(doc.incus || "") : ""
      root.incusVersion = doc.ok ? Model.plain(doc.version || "", 40) : ""
      if (root.incusPath === "") {
        root.setupError = root.configuredIncusPath !== "" ? strings.t("setup.notFoundAt").arg(root.configuredIncusPath) : ""
        root.remotes = []
        return
      }
      root.setupError = ""
      remotesRun.start(root.helperCommand(["remotes"]))
    }
  }

  HelperRun {
    id: remotesRun
    timeoutMs: 30000
    onDone: function(doc) {
      if (!doc.ok) {
        root.setupError = Model.plain(doc.error || "", 300)
        return
      }
      var list = []
      var input = doc.remotes || []
      for (var i = 0; i < input.length && list.length < 32; i++) {
        var r = input[i]
        if (r && Model.validName(r.name)) list.push(r)
      }
      // Assigning an equal list would restart every watcher; compare first.
      if (JSON.stringify(list) !== JSON.stringify(root.remotes)) root.remotes = list
      root.defaultRemote = Model.validName(doc.default) ? doc.default : ""
    }
  }

  // One watcher per remote. Removing a remote destroys its watcher, which
  // stops its stream.
  Instantiator {
    model: root.watchedRemotes
    delegate: RemoteWatcher {
      required property var modelData
      remoteName: String(modelData)
      service: root
    }
    onObjectRemoved: function(index, object) {
      var name = object.remoteName
      var next = Object.assign({}, root.states)
      delete next[name]
      root.states = next
    }
  }

  // `incus remote add` writes the client config; re-read remotes when it
  // changes. The file is only watched, never read here.
  FileView {
    path: (Quickshell.env("INCUS_CONF") || (Quickshell.env("HOME") + "/.config/incus")) + "/config.yml"
    preload: false
    blockAllReads: true
    watchChanges: true
    onFileChanged: discoverDebounce.restart()
  }

  Timer {
    id: discoverDebounce
    interval: 1000
    repeat: false
    onTriggered: root.discover()
  }

  // Incus sends no event for CPU or memory use, so poll: quickly while a
  // panel is open, and every 30 seconds otherwise to fill the CPU graph.
  Timer {
    interval: root.openPanels > 0 ? root.statsIntervalSec * 1000 : Model.BACKGROUND_STATS_MS
    repeat: true
    running: root.watchedRemotes.length > 0 && (root.openPanels > 0 || root.backgroundStats)
    onTriggered: root.statsTick()
  }

  // A remote that stays down for a minute is worth a notification; a blip is
  // not.
  Timer {
    id: unreachableCheck
    interval: 60000
    repeat: false
    onTriggered: {
      var since = Object.assign({}, root._unreachableSince)
      var now = Date.now()
      for (var name in since) {
        if (since[name] === -1) continue
        if (now - since[name] >= 59000) {
          root.notify(Model.glyphs.server, "critical", strings.t("notify.unreachable").arg(name), Model.plain((root.states[name] || {}).error || "", 200))
          since[name] = -1
        } else {
          unreachableCheck.restart()
        }
      }
      root._unreachableSince = since
    }
  }

  Timer {
    id: actionErrorTimer
    interval: 8000
    repeat: false
    onTriggered: root.actionError = ""
  }

  Component {
    id: actionComponent
    HelperRun {
      id: run
      property string verb: ""
      property string remote: ""
      property var inst: null
      property string key: ""
      timeoutMs: 180000
      Component.onCompleted: start(root.helperCommand(["action", verb, remote, inst.project, inst.name]))
      onDone: function(doc) {
        root.finishAction(key, verb, inst, doc)
        run.destroy()
      }
    }
  }
}
