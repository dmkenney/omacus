import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.dmkenney.omacus"
  ipcTarget: "io.github.dmkenney.omacus"
  manageIpc: false

  // Items inside the lazily built panel content, null until it first opens.
  readonly property Item panelFlick: panel.loadedContent ? panel.loadedContent.panelFlick : null
  readonly property Item searchField: panel.loadedContent ? panel.loadedContent.searchField : null
  readonly property Item imageField: panel.loadedContent ? panel.loadedContent.imageField : null

  // The shell loads the service once and hands it to every monitor's widget.
  // Under a replacement bar with no service lookup, run a private copy.
  property var sharedService: null
  property int lookupAttempts: 0
  readonly property var omacus: sharedService || (localService.item ? localService.item : idle)
  readonly property string widgetToken: String(root)

  property string selectedRemote: ""
  property string query: ""
  property bool searchActive: false
  property bool editing: false
  property string expandedKey: ""
  property int actionIndex: 0
  property string confirmKey: ""
  property string confirmVerb: ""
  property bool launchOpen: false
  property bool launchVm: false
  property string launchImage: "images:debian/13"
  property string launchName: ""
  property string launchError: ""
  property bool settingsOpen: false
  property bool cursorActive: false
  property string cursorKey: ""
  property var rowItems: ({})

  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color accent: Commons.Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Commons.Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Commons.Color.accent) : "transparent"

  readonly property string barLabel: ["running", "running-total", "none"].indexOf(String(setting("barLabel", "running"))) !== -1 ? String(setting("barLabel", "running")) : "running"
  readonly property var widgetRemotes: Model.parseList(setting("remotes", ""))
  readonly property var visibleRemotes: {
    var out = []
    var list = omacus.remoteList || []
    for (var i = 0; i < list.length; i++) {
      if (widgetRemotes.length === 0 || widgetRemotes.indexOf(list[i].name) !== -1) out.push(list[i])
    }
    return out
  }
  readonly property var shownRemotes: {
    if (selectedRemote === "") return visibleRemotes
    for (var i = 0; i < visibleRemotes.length; i++) if (visibleRemotes[i].name === selectedRemote) return [visibleRemotes[i]]
    return visibleRemotes
  }
  readonly property var counts: {
    var running = 0, total = 0, stopped = 0, other = 0
    for (var i = 0; i < visibleRemotes.length; i++) {
      var list = visibleRemotes[i].instances || []
      for (var j = 0; j < list.length; j++) {
        total++
        if (Model.isRunning(list[j])) running++
        else if (Model.isStopped(list[j])) stopped++
        else other++
      }
    }
    return { running: running, total: total, stopped: stopped, other: other }
  }
  readonly property var attentionList: {
    var names = {}
    for (var i = 0; i < visibleRemotes.length; i++) names[visibleRemotes[i].name] = true
    return (omacus.attentionItems || []).filter(function(item) { return names[item.remote] === true }).slice(0, 12)
  }
  readonly property bool barUrgent: {
    for (var i = 0; i < attentionList.length; i++) if (attentionList[i].severity === "urgent") return true
    return false
  }
  readonly property bool connecting: {
    for (var i = 0; i < visibleRemotes.length; i++) if (visibleRemotes[i].status === "connecting") return true
    return false
  }
  readonly property var instanceRows: buildInstanceRows()
  readonly property var hostRemotes: shownRemotes.filter(function(r) { return r.status === "ok" })
  readonly property var cursorKeys: buildCursorKeys()
  readonly property string heroMeta: {
    if (!omacus.checked) return strings.t("hero.checking")
    if (!omacus.installed) return strings.t("hero.notInstalled")
    if (visibleRemotes.length === 0) return strings.t("hero.noRemotes")
    if (counts.total === 0 && connecting) return strings.t("hero.connecting")
    var parts = [strings.tn("hero.running", counts.running).arg(counts.running)]
    if (counts.stopped > 0) parts.push(strings.tn("hero.stopped", counts.stopped).arg(counts.stopped))
    if (visibleRemotes.length > 1) parts.push(strings.tn("hero.servers", visibleRemotes.length).arg(visibleRemotes.length))
    return parts.join(" · ")
  }
  readonly property string tooltipSummary: {
    if (!omacus.installed) return "Omacus: " + strings.t("hero.notInstalled")
    var text = "Omacus: " + strings.tn("hero.running", counts.running).arg(counts.running)
    if (attentionList.length > 0) text += " · " + strings.tn("tooltip.attention", attentionList.length).arg(attentionList.length)
    return Model.plain(text, 160)
  }

  function findService() {
    if (sharedService) return
    if (bar && bar.shell && typeof bar.shell.serviceFor === "function") {
      var found = bar.shell.serviceFor(moduleName)
      if (found) sharedService = found
    }
    if (!sharedService) lookupAttempts++
  }

  function pushSettings() {
    if (omacus && typeof omacus.registerWidget === "function") omacus.registerWidget(widgetToken, root.settings)
  }

  function saveSetting(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    entry[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function toggleWatch(remote, inst) {
    var list = Model.parseList(setting("watched", ""))
    var key = Model.watchKey(remote, inst.name)
    var at = list.indexOf(key)
    if (at === -1) list.push(key)
    else list.splice(at, 1)
    saveSetting("watched", list.join(","))
  }

  function buildInstanceRows() {
    var rows = []
    var groupByRemote = shownRemotes.length > 1
    for (var r = 0; r < shownRemotes.length; r++) {
      var rs = shownRemotes[r]
      var list = (rs.instances || []).filter(function(inst) { return Model.matchesQuery(inst, root.query) })
      var projects = {}
      for (var p = 0; p < list.length; p++) projects[list[p].project] = true
      var multiProject = Object.keys(projects).length > 1
      if (groupByRemote) rows.push({ kind: "remote", remote: rs.name, status: rs.status, error: rs.error || "", count: list.length })
      else if (rs.status !== "ok") rows.push({ kind: "remote", remote: rs.name, status: rs.status, error: rs.error || "", count: list.length })
      var byProject = Model.sortInstances(list, multiProject)
      var lastProject = ""
      for (var i = 0; i < byProject.length; i++) {
        var inst = byProject[i]
        if (multiProject && inst.project !== lastProject) {
          rows.push({ kind: "project", remote: rs.name, project: inst.project })
          lastProject = inst.project
        }
        rows.push({ kind: "instance", remote: rs.name, inst: inst, key: Model.instanceKey(rs.name, inst) })
      }
    }
    return rows
  }

  function buildCursorKeys() {
    var keys = []
    for (var a = 0; a < attentionList.length; a++) keys.push("att:" + attentionList[a].key)
    if (visibleRemotes.length > 1) keys.push("tabs")
    for (var i = 0; i < instanceRows.length; i++) if (instanceRows[i].kind === "instance") keys.push("inst:" + instanceRows[i].key)
    if (omacus.installed && !omacus.readOnly && visibleRemotes.length > 0) keys.push("launch")
    for (var w = 0; w < hostRemotes.length; w++) {
      var info = omacus.remoteInfo(hostRemotes[w].name)
      if (info && Model.webUiUrl(info.addr) !== "") keys.push("web:" + hostRemotes[w].name)
    }
    keys.push("settings")
    return keys
  }

  function hasCursor(key) { return cursorActive && cursorKey === key }

  function setCursor(key) {
    cursorActive = true
    if (cursorKey !== key) actionIndex = 0
    cursorKey = key
  }

  function ensureCursor() {
    if (cursorKeys.indexOf(cursorKey) === -1) cursorKey = cursorKeys.length > 0 ? cursorKeys[0] : ""
  }

  function moveCursor(dx, dy) {
    if (!cursorActive) { cursorActive = true; ensureCursor(); scrollCursorIntoView(); return }
    ensureCursor()
    if (dx !== 0) {
      moveSideways(dx)
      return
    }
    var at = cursorKeys.indexOf(cursorKey)
    var next = Math.max(0, Math.min(cursorKeys.length - 1, at + dy))
    if (next !== at) {
      cursorKey = cursorKeys[next]
      actionIndex = 0
      scrollCursorIntoView()
    }
  }

  function moveSideways(dx) {
    if (cursorKey === "tabs") {
      var names = [""]
      for (var i = 0; i < visibleRemotes.length; i++) names.push(visibleRemotes[i].name)
      var at = Math.max(0, names.indexOf(selectedRemote))
      selectedRemote = names[(at + dx + names.length) % names.length]
      return
    }
    var row = selectedInstanceRow()
    if (row && expandedKey === row.key) {
      var actions = instanceActions(row.remote, row.inst)
      actionIndex = Math.max(0, Math.min(actions.length - 1, actionIndex + dx))
      return
    }
    if (row && dx > 0) { expandedKey = row.key; actionIndex = 0 }
    else if (row && dx < 0 && expandedKey === row.key) expandedKey = ""
  }

  function selectedInstanceRow() {
    if (cursorKey.indexOf("inst:") !== 0) return null
    var key = cursorKey.substring(5)
    for (var i = 0; i < instanceRows.length; i++) if (instanceRows[i].kind === "instance" && instanceRows[i].key === key) return instanceRows[i]
    return null
  }

  function activateCursor() {
    ensureCursor()
    if (cursorKey.indexOf("att:") === 0) {
      var key = cursorKey.substring(4)
      for (var a = 0; a < attentionList.length; a++) if (attentionList[a].key === key) focusAttention(attentionList[a])
      return
    }
    if (cursorKey === "tabs") { moveSideways(1); return }
    var row = selectedInstanceRow()
    if (row) {
      if (expandedKey === row.key) {
        var actions = instanceActions(row.remote, row.inst)
        if (actions.length > 0) runInstanceAction(row.remote, row.inst, actions[Math.min(actionIndex, actions.length - 1)].id)
      } else {
        expandedKey = row.key
        actionIndex = 0
      }
      return
    }
    if (cursorKey === "launch") { toggleLaunch(); return }
    if (cursorKey.indexOf("web:") === 0) { omacus.openWebUi(cursorKey.substring(4)); close(); return }
    if (cursorKey === "settings") settingsOpen = !settingsOpen
  }

  function focusAttention(item) {
    if (item.kind === "error" || item.kind === "watched" || item.kind === "snapshot") {
      selectedRemote = visibleRemotes.length > 1 ? item.remote : ""
      query = ""
      searchActive = false
      var key = item.remote + "/" + item.project + "/" + item.name
      expandedKey = key
      cursorKey = "inst:" + key
      cursorActive = true
      Qt.callLater(scrollCursorIntoView)
    } else if (visibleRemotes.length > 1) {
      selectedRemote = item.remote
    }
  }

  function registerRow(key, item) {
    var next = rowItems
    next[key] = item
    rowItems = next
  }

  function unregisterRow(key, item) {
    if (rowItems[key] === item) delete rowItems[key]
  }

  function scrollCursorIntoView() {
    var item = rowItems[cursorKey]
    if (!panelFlick || !item) return
    Qt.callLater(function() {
      if (!item || !panelFlick) return
      var margin = Style.space(6)
      var point = item.mapToItem(panelFlick.contentItem, 0, 0)
      var top = point.y
      var bottom = top + item.height
      var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
      if (top < panelFlick.contentY + margin) panelFlick.contentY = Math.max(0, top - margin)
      else if (bottom > panelFlick.contentY + panelFlick.height - margin) panelFlick.contentY = Math.min(maxY, bottom + margin - panelFlick.height)
    })
  }

  // The buttons an expanded instance offers, in the order they show.
  function instanceActions(remote, inst) {
    var list = []
    var running = Model.isRunning(inst)
    var frozen = Model.isFrozen(inst)
    if (!omacus.readOnly) {
      if (frozen) list.push({ id: "start", glyph: Model.glyphs.play, tip: strings.t("action.resume") })
      else if (!running) list.push({ id: "start", glyph: Model.glyphs.play, tip: strings.t("action.start") })
      if (running) {
        list.push({ id: "stop", glyph: Model.glyphs.stop, tip: strings.t("action.stop"), confirm: true })
        list.push({ id: "restart", glyph: Model.glyphs.restart, tip: strings.t("action.restart"), confirm: true })
        list.push({ id: "pause", glyph: Model.glyphs.pause, tip: strings.t("action.pause"), confirm: true })
      }
      if (running || frozen) list.push({ id: "force-stop", glyph: Model.glyphs.stop, tip: strings.t("action.forceStop"), confirm: true, danger: true })
      list.push({ id: "snapshot", glyph: Model.glyphs.snapshot, tip: strings.t("action.snapshot") })
      if (running && !Model.isWindows(inst) && !Model.agentMissing(inst)) list.push({ id: "shell", glyph: Model.glyphs.shell, tip: strings.t("action.shell") })
      if (running) list.push({ id: "console", glyph: Model.glyphs.console, tip: inst.type === "vm" ? strings.t("action.screen") : strings.t("action.console") })
    }
    if ((inst.ipv4 || []).length > 0) list.push({ id: "copy", glyph: Model.glyphs.copy, tip: strings.t("action.copyIp").arg(inst.ipv4[0]) })
    var isWatched = Model.isWatched(omacus.watched || [], remote, inst.name)
    list.push({ id: "watch", glyph: isWatched ? Model.glyphs.eyeOff : Model.glyphs.eye, tip: isWatched ? strings.t("action.unwatch") : strings.t("action.watch") })
    return list
  }

  function runInstanceAction(remote, inst, id) {
    var key = Model.instanceKey(remote, inst)
    var actions = instanceActions(remote, inst)
    var action = null
    for (var i = 0; i < actions.length; i++) if (actions[i].id === id) action = actions[i]
    if (!action) return
    if (action.confirm && !(confirmKey === key && confirmVerb === id)) {
      confirmKey = key
      confirmVerb = id
      confirmTimer.restart()
      return
    }
    confirmKey = ""
    confirmVerb = ""
    if (id === "copy") omacus.copyText(inst.ipv4[0])
    else if (id === "watch") toggleWatch(remote, inst)
    else if (id === "shell") { omacus.openShell(remote, inst); close() }
    else if (id === "console") { omacus.openConsole(remote, inst); close() }
    else omacus.runAction(id, remote, inst)
  }

  function startSearch() {
    searchActive = true
    Qt.callLater(function() { if (searchField) searchField.forceActiveFocus() })
  }

  function endSearch(clear) {
    if (clear) query = ""
    if (query === "") searchActive = false
    if (panel.loadedContent) panel.loadedContent.forceActiveFocus()
  }

  function toggleLaunch() {
    launchOpen = !launchOpen
    launchError = ""
    if (launchOpen) Qt.callLater(function() { if (imageField) imageField.forceActiveFocus() })
  }

  function launchRemote() {
    if (selectedRemote !== "") return selectedRemote
    if (omacus.defaultRemote && visibleRemotes.some(function(r) { return r.name === omacus.defaultRemote })) return omacus.defaultRemote
    return visibleRemotes.length > 0 ? visibleRemotes[0].name : ""
  }

  function submitLaunch() {
    var remote = launchRemote()
    var image = String(launchImage || "").trim()
    var name = String(launchName || "").trim()
    if (!Model.validImage(image)) { launchError = strings.t("launch.badImage"); return }
    if (!Model.validInstanceName(name)) { launchError = strings.t("launch.badName"); return }
    var project = omacus.remoteProject(remote) || "default"
    if (omacus.launchInstance(remote, project, image, name, launchVm)) {
      launchOpen = false
      launchName = ""
      launchError = ""
      close()
    }
  }

  function statusColor(inst) {
    if (Model.isError(inst)) return urgent
    if (Model.isRunning(inst)) return foreground
    if (Model.isFrozen(inst)) return accent
    return dim
  }

  function statusLabel(inst) {
    if (Model.isRunning(inst)) return strings.t("status.running")
    if (Model.isStopped(inst)) return strings.t("status.stopped")
    if (Model.isFrozen(inst)) return strings.t("status.frozen")
    if (Model.isError(inst)) return strings.t("status.error")
    return Model.plain(inst.status, 20)
  }

  function busyLabel(verb) {
    var map = { "start": "busy.starting", "stop": "busy.stopping", "force-stop": "busy.stopping", "restart": "busy.restarting", "pause": "busy.pausing", "snapshot": "busy.snapshotting" }
    return map[verb] ? strings.t(map[verb]) : ""
  }

  function instanceSummary(remote, inst) {
    var parts = []
    var busyVerb = omacus.busy ? omacus.busy[Model.instanceKey(remote, inst)] : undefined
    if (busyVerb) parts.push(busyLabel(busyVerb))
    else if (!Model.isRunning(inst)) parts.push(statusLabel(inst))
    if ((inst.ipv4 || []).length > 0) parts.push(inst.ipv4[0])
    else if (Model.agentMissing(inst)) parts.push(strings.t("detail.noAgentShort"))
    if (Model.isRunning(inst)) {
      var up = Model.secondsSince(inst.startedAt || inst.lastUsedAt)
      if (up !== null) parts.push(strings.t("detail.up").arg(Model.formatAge(up)))
    }
    var os = [inst.imageOs, inst.imageRelease].filter(function(s) { return s }).join(" ")
    if (os !== "") parts.push(os)
    return parts.join(" · ")
  }

  function usageText(remote, inst) {
    if (!Model.isRunning(inst)) return ""
    var parts = []
    var cpu = omacus.cpuNow ? omacus.cpuNow[Model.instanceKey(remote, inst)] : undefined
    if (cpu !== undefined) parts.push(strings.t("usage.cpu").arg(Model.formatPercent(cpu)))
    var mem = Model.memPercent(inst)
    if (mem !== null && inst.memUsage > 0) parts.push(strings.t("usage.mem").arg(Model.formatPercent(mem)))
    return parts.join("  ")
  }

  function detailLines(remote, inst) {
    var lines = []
    function add(label, value, warn) { if (value !== "" && value !== null && value !== undefined) lines.push({ label: label, value: String(value), warn: warn === true }) }
    if (inst.description) add(strings.t("detail.description"), inst.description)
    add(strings.t("detail.type"), inst.type === "vm" ? strings.t("detail.vm") : strings.t("detail.container"))
    if (inst.project !== "default") add(strings.t("detail.project"), inst.project)
    add(strings.t("detail.status"), statusLabel(inst), Model.isError(inst))
    var addresses = (inst.ipv4 || []).concat(inst.ipv6 || [])
    if (addresses.length > 0) add(strings.t("detail.addresses"), addresses.join(", "))
    if (Model.agentMissing(inst)) add(strings.t("detail.agent"), strings.t("detail.noAgent"), true)
    if (inst.memUsage > 0 || inst.memTotal) {
      var mem = Model.formatBytes(inst.memUsage)
      if (inst.memTotal) mem += " / " + Model.formatBytes(inst.memTotal)
      add(strings.t("detail.memory"), mem)
    }
    if (inst.limitsCpu) add(strings.t("detail.cpuLimit"), inst.limitsCpu)
    if (inst.diskUsage !== null && inst.diskUsage !== undefined) {
      var disk = Model.formatBytes(inst.diskUsage)
      if (inst.diskTotal) disk += " / " + Model.formatBytes(inst.diskTotal)
      add(strings.t("detail.disk"), disk)
    }
    if (Model.isRunning(inst) && (inst.rx > 0 || inst.tx > 0)) add(strings.t("detail.network"), strings.t("detail.rxtx").arg(Model.formatBytes(inst.rx)).arg(Model.formatBytes(inst.tx)))
    var image = [inst.imageOs, inst.imageRelease].filter(function(s) { return s }).join(" ")
    var imageAge = Model.imageAgeDays(inst.imageSerial)
    if (image !== "") add(strings.t("detail.image"), imageAge !== null ? strings.t("detail.imageAge").arg(image).arg(strings.tn("detail.days", imageAge).arg(imageAge)) : image)
    var snapAge = Model.snapshotAgeDays(inst)
    var snapText = inst.snapshots === 0 ? strings.t("detail.noSnapshots") : strings.tn("detail.snapshotCount", inst.snapshots).arg(inst.snapshots)
    if (snapAge !== null) snapText += " · " + strings.t("detail.newest").arg(strings.tn("detail.daysAgo", snapAge).arg(snapAge))
    if (inst.snapshotSchedule) snapText += " · " + strings.t("detail.schedule").arg(inst.snapshotSchedule)
    add(strings.t("detail.snapshots"), snapText, Model.snapshotStale(inst, omacus.snapshotWarnDays))
    if (inst.backups > 0) {
      var backupAge = Model.secondsSince(inst.newestBackup)
      add(strings.t("detail.backups"), strings.tn("detail.backupCount", inst.backups).arg(inst.backups) + (backupAge !== null ? " · " + strings.t("detail.newest").arg(strings.tn("detail.daysAgo", Math.floor(backupAge / 86400)).arg(Math.floor(backupAge / 86400))) : ""))
    }
    if ((inst.ports || []).length > 0) add(strings.t("detail.ports"), inst.ports.join(", "))
    if ((inst.profiles || []).length > 0) add(strings.t("detail.profiles"), inst.profiles.join(", "))
    if (inst.location) add(strings.t("detail.location"), inst.location)
    if (inst.autostart) add(strings.t("detail.autostart"), strings.t("detail.yes"))
    return lines
  }

  function attentionText(item) {
    if (item.kind === "remote") return strings.t("attention.remote").arg(item.remote)
    if (item.kind === "error") return strings.t("attention.error").arg(item.name)
    if (item.kind === "watched") return strings.t("attention.watched").arg(item.name)
    if (item.kind === "snapshot") return strings.t("attention.snapshot").arg(item.name).arg(strings.tn("detail.days", item.days).arg(item.days))
    if (item.kind === "pool") return strings.t("attention.pool").arg(item.name).arg(Model.formatPercent(item.percent))
    if (item.kind === "member") return strings.t("attention.member").arg(item.name).arg(item.text)
    if (item.kind === "warnings") return strings.tn("attention.warnings", item.count).arg(item.count)
    return ""
  }

  function attentionDetail(item) {
    var parts = []
    if (visibleRemotes.length > 1 || item.kind === "remote") parts.push(item.remote)
    if (item.kind === "remote" && item.text) parts.push(item.text)
    return parts.join(" · ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorKey = ""
      actionIndex = 0
      if (panelFlick) panelFlick.contentY = 0
      omacus.panelOpened()
      Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
    } else {
      omacus.panelClosed()
      confirmKey = ""
      editing = false
    }
  }
  onCursorKeysChanged: if (cursorActive) ensureCursor()
  onSettingsChanged: pushSettings()
  onOmacusChanged: pushSettings()
  onBarChanged: findService()
  Component.onCompleted: { findService(); pushSettings() }
  Component.onDestruction: {
    if (root.opened && omacus) omacus.panelClosed()
    if (omacus && typeof omacus.unregisterWidget === "function") omacus.unregisterWidget(widgetToken)
  }

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  Timer {
    interval: 1000
    repeat: true
    running: root.sharedService === null && root.lookupAttempts < 5
    onTriggered: root.findService()
  }

  Loader {
    id: localService
    active: root.sharedService === null && root.lookupAttempts >= 5
    sourceComponent: Component { Service {} }
  }

  // Stands in until a service is available, so every binding has something
  // to read.
  QtObject {
    id: idle
    property bool checked: false
    property bool installed: false
    property bool readOnly: true
    property var remoteList: []
    property var attentionItems: []
    property var watched: []
    property var busy: ({})
    property var cpuNow: ({})
    property var history: ({})
    property var operations: ({})
    property string actionError: ""
    property string setupError: ""
    property string incusVersion: ""
    property string defaultRemote: ""
    property int snapshotWarnDays: 7
    property int poolWarnPercent: 85
    property string notifications: "all"
    function registerWidget() {}
    function unregisterWidget() {}
    function panelOpened() {}
    function panelClosed() {}
    function refresh() {}
    function remoteInfo() { return null }
    function remoteProject() { return "" }
  }

  Timer {
    id: confirmTimer
    interval: 4000
    repeat: false
    onTriggered: { root.confirmKey = ""; root.confirmVerb = "" }
  }

  ShellIpc {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.omacus.refresh(); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.glyphs.incus
    labelText: {
      if (!root.omacus.installed || root.vertical || root.barLabel === "none" || root.visibleRemotes.length === 0) return ""
      if (root.barLabel === "running-total") return root.counts.running + "/" + root.counts.total
      return String(root.counts.running)
    }
    slotSize: Style.bar.iconSlot + (labelText !== "" ? labelMetrics.advanceWidth + Style.space(4) : 0)
    active: root.barUrgent
    dimmed: !root.omacus.installed || (root.counts.running === 0 && !root.barUrgent)
    tooltipText: root.tooltipSummary
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton || buttonCode === Qt.RightButton) root.omacus.refresh()
      else root.toggle()
    }

    TextMetrics {
      id: labelMetrics
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      text: button.labelText
    }
  }

  readonly property bool vertical: bar ? bar.vertical === true : false

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight, Style.space(640))

    content: PanelKeyCatcher {
      id: keyCatcher
      property alias panelFlick: panelFlick
      property alias searchField: searchField
      property alias imageField: imageField
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      blocked: root.editing
      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: {
        if (root.expandedKey !== "") root.expandedKey = ""
        else if (root.query !== "") root.endSearch(true)
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var row = root.selectedInstanceRow()
        if (t === "/") root.startSearch()
        else if (t === "r" || t === "R") root.omacus.refresh()
        else if (t === "n" || t === "N") { if (!root.omacus.readOnly && root.omacus.installed) { root.launchOpen = false; root.toggleLaunch() } }
        else if (row && (t === "s" || t === "S")) root.runInstanceAction(row.remote, row.inst, "shell")
        else if (row && (t === "c" || t === "C")) root.runInstanceAction(row.remote, row.inst, "copy")
        else if (row && (t === "w" || t === "W")) root.runInstanceAction(row.remote, row.inst, "watch")
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            id: hero
            width: parent.width
            title: "Incus"
            meta: Model.plain(root.heroMeta, 120)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.counts.running > 0 ? 1.0 : 0.5
            iconComponent: Component {
              PlainText {
                text: Model.glyphs.incus
                color: root.barUrgent ? root.urgent : root.foreground
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: Model.glyphs.refresh
                tooltipText: Model.plain(strings.t("action.refresh"), 40)
                foreground: root.foreground
                fontFamily: root.fontFamily
                visible: root.omacus.installed
                onClicked: root.omacus.refresh()
              }
            }
          }

          PlainText {
            visible: text !== ""
            width: parent.width
            text: root.omacus.actionError || root.omacus.setupError || ""
            color: root.urgent
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // Setup help when there is nothing to show yet.
          Column {
            visible: root.omacus.checked && (!root.omacus.installed || root.visibleRemotes.length === 0)
            width: parent.width
            spacing: Style.space(8)

            PlainText {
              width: parent.width
              text: !root.omacus.installed ? strings.t("setup.install") : strings.t("setup.addRemote")
              color: root.foreground
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: !root.omacus.installed
                ? ["omarchy pkg add incus"]
                : ["incus config trust add laptop", "incus remote add homelab <token>"]
              CommandLine {
                required property var modelData
                width: column.width
                command: String(modelData)
              }
            }

            PlainText {
              width: parent.width
              visible: root.omacus.installed
              text: strings.t("setup.addRemoteNote")
              color: root.dim
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // Attention
          Column {
            visible: root.attentionList.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: strings.t("section.attention")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.attentionList
              ListRow {
                required property var modelData
                width: column.width
                rowKey: "att:" + modelData.key
                glyph: modelData.kind === "pool" ? Model.glyphs.pool : (modelData.kind === "remote" || modelData.kind === "member" ? Model.glyphs.server : (modelData.kind === "snapshot" ? Model.glyphs.snapshot : Model.glyphs.alert))
                glyphColor: modelData.severity === "urgent" ? root.urgent : root.accent
                title: root.attentionText(modelData)
                detail: root.attentionDetail(modelData)
                onChosen: root.focusAttention(modelData)
              }
            }
          }

          // Server tabs
          Item {
            id: tabsRow
            visible: root.visibleRemotes.length > 1
            width: parent.width
            implicitHeight: tabs.implicitHeight
            Component.onCompleted: root.registerRow("tabs", tabsRow)
            Component.onDestruction: root.unregisterRow("tabs", tabsRow)

            ButtonGroup {
              id: tabs
              foreground: root.foreground
              fontFamily: root.fontFamily
              focusable: false
              cursorIndex: root.hasCursor("tabs") ? Math.max(0, root.visibleRemotes.map(function(r) { return r.name }).indexOf(root.selectedRemote) + 1) : -1
              value: root.selectedRemote === "" ? "*" : root.selectedRemote
              options: {
                var list = [{ value: "*", label: Model.plain(strings.t("tabs.all"), 30) }]
                for (var i = 0; i < root.visibleRemotes.length; i++) {
                  var r = root.visibleRemotes[i]
                  list.push({ value: r.name, label: Model.plain(r.name, 30), icon: r.status === "ok" ? "" : Model.glyphs.alert })
                }
                return list
              }
              onChanged: function(value) { root.selectedRemote = value === "*" ? "" : value }
              onHovered: function(index, isHovered) { if (isHovered) root.setCursor("tabs") }
            }
          }

          // Search
          TextField {
            id: searchField
            visible: root.searchActive || root.query !== ""
            width: parent.width
            foreground: root.foreground
            placeholderText: strings.t("search.placeholder")
            maximumLength: 80
            text: root.query
            onTextChanged: root.query = text
            onActiveFocusChanged: root.editing = activeFocus || imageField.activeFocus || nameField.activeFocus
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) { root.endSearch(true); event.accepted = true; return }
              if (event.key === Qt.Key_Down || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.endSearch(false)
                root.cursorActive = true
                var first = root.cursorKeys.filter(function(k) { return k.indexOf("inst:") === 0 })[0]
                if (first) root.cursorKey = first
                event.accepted = true
              }
            }
          }

          // Instances
          Column {
            visible: root.visibleRemotes.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: strings.t("section.instances")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            PlainText {
              visible: root.instanceRows.length === 0
              width: parent.width
              text: root.connecting ? strings.t("hero.connecting") : (root.query !== "" ? strings.t("search.none") : strings.t("instances.none"))
              color: root.dim
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Repeater {
              model: root.instanceRows
              Loader {
                required property var modelData
                width: column.width
                sourceComponent: modelData.kind === "instance" ? instanceComponent : groupComponent
                onLoaded: item.row = modelData
                onModelDataChanged: if (item) item.row = modelData
              }
            }
          }

          // Hosts: storage, cluster, warnings and running tasks
          Repeater {
            model: root.hostRemotes
            HostSection {
              required property var modelData
              width: column.width
              rs: modelData
            }
          }

          // New instance
          Column {
            visible: root.omacus.installed && !root.omacus.readOnly && root.visibleRemotes.length > 0
            width: parent.width
            spacing: Style.space(6)

            ListRow {
              width: parent.width
              rowKey: "launch"
              glyph: Model.glyphs.plus
              title: strings.t("launch.title")
              detail: root.launchOpen ? strings.t("launch.on").arg(root.launchRemote()) : strings.t("launch.hint")
              onChosen: root.toggleLaunch()
            }

            Column {
              visible: root.launchOpen
              width: parent.width
              spacing: Style.space(6)

              TextField {
                id: imageField
                width: parent.width
                foreground: root.foreground
                placeholderText: strings.t("launch.imagePlaceholder")
                maximumLength: 200
                text: root.launchImage
                onTextChanged: root.launchImage = text
                onActiveFocusChanged: root.editing = activeFocus || nameField.activeFocus || searchField.activeFocus
                onAccepted: nameField.forceActiveFocus()
                Keys.onEscapePressed: { root.launchOpen = false; root.endSearch(false) }
              }

              TextField {
                id: nameField
                width: parent.width
                foreground: root.foreground
                placeholderText: strings.t("launch.namePlaceholder")
                maximumLength: 63
                text: root.launchName
                onTextChanged: root.launchName = text
                onActiveFocusChanged: root.editing = activeFocus || imageField.activeFocus || searchField.activeFocus
                onAccepted: root.submitLaunch()
                Keys.onEscapePressed: { root.launchOpen = false; root.endSearch(false) }
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(10)

                ToggleSwitch {
                  checked: root.launchVm
                  foreground: root.foreground
                  onToggled: root.launchVm = !root.launchVm
                }

                PlainText {
                  Layout.fillWidth: true
                  text: strings.t("launch.vm")
                  color: root.foreground
                  font.pixelSize: Style.font.body
                }

                Button {
                  text: Model.plain(strings.t("launch.go"), 30)
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  bordered: true
                  onClicked: root.submitLaunch()
                }
              }

              PlainText {
                visible: root.launchError !== ""
                width: parent.width
                text: root.launchError
                color: root.urgent
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          // Web UI links
          Repeater {
            model: root.hostRemotes.filter(function(r) {
              var info = root.omacus.remoteInfo(r.name)
              return info && Model.webUiUrl(info.addr) !== ""
            })
            ListRow {
              required property var modelData
              width: column.width
              rowKey: "web:" + modelData.name
              glyph: Model.glyphs.web
              title: strings.t("web.open").arg(modelData.name)
              detail: Model.webUiUrl((root.omacus.remoteInfo(modelData.name) || {}).addr).replace(/^https:\/\//, "")
              onChosen: { root.omacus.openWebUi(modelData.name); root.close() }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // Settings
          Column {
            width: parent.width
            spacing: Style.space(8)

            ListRow {
              width: parent.width
              rowKey: "settings"
              glyph: Model.glyphs.cog
              title: strings.t("settings.title")
              detail: root.omacus.incusVersion !== "" ? strings.t("settings.version").arg(root.omacus.incusVersion) : ""
              onChosen: root.settingsOpen = !root.settingsOpen
            }

            GridLayout {
              visible: root.settingsOpen
              width: parent.width
              columns: 2
              columnSpacing: Style.space(12)
              rowSpacing: Style.space(8)

              PlainText {
                text: strings.t("settings.readOnly")
                color: root.foreground
                font.pixelSize: Style.font.body
                Layout.fillWidth: true
              }
              ToggleSwitch {
                checked: root.setting("readOnly", false) === true
                foreground: root.foreground
                onToggled: root.saveSetting("readOnly", !(root.setting("readOnly", false) === true))
              }

              PlainText {
                text: strings.t("settings.notifications")
                color: root.foreground
                font.pixelSize: Style.font.body
                Layout.fillWidth: true
              }
              ButtonGroup {
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                focusable: false
                value: root.omacus.notifications || "all"
                options: [
                  { value: "all", label: Model.plain(strings.t("settings.notifyAll"), 30) },
                  { value: "watched", label: Model.plain(strings.t("settings.notifyWatched"), 30) },
                  { value: "off", label: Model.plain(strings.t("settings.notifyOff"), 30) }
                ]
                onChanged: function(value) { root.saveSetting("notifications", value) }
              }

              PlainText {
                text: strings.t("settings.barLabel")
                color: root.foreground
                font.pixelSize: Style.font.body
                Layout.fillWidth: true
              }
              ButtonGroup {
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                focusable: false
                value: root.barLabel
                options: [
                  { value: "running", label: "3" },
                  { value: "running-total", label: "3/5" },
                  { value: "none", label: Model.plain(strings.t("settings.labelNone"), 30) }
                ]
                onChanged: function(value) { root.saveSetting("barLabel", value) }
              }

              PlainText {
                Layout.columnSpan: 2
                Layout.fillWidth: true
                text: strings.t("settings.more")
                color: root.dim
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }
    }
  }

  Component {
    id: groupComponent
    Item {
      id: groupItem
      property var row: null
      readonly property bool isRemote: !!row && row.kind === "remote"
      readonly property bool remoteDown: isRemote && row.status !== "ok" && row.status !== "connecting"
      implicitHeight: groupColumn.implicitHeight + Style.space(4)

      Column {
        id: groupColumn
        width: parent.width
        y: Style.space(4)
        spacing: Style.space(2)

        PlainText {
          width: parent.width
          text: !groupItem.row ? "" : (groupItem.isRemote
            ? Model.glyphs.server + "  " + groupItem.row.remote
            : strings.t("group.project").arg(groupItem.row.project))
          color: groupItem.remoteDown ? root.urgent : root.dim
          font.pixelSize: Style.font.caption
          font.bold: groupItem.isRemote
          elide: Text.ElideRight
        }

        PlainText {
          width: parent.width
          visible: text !== ""
          text: {
            if (!groupItem.isRemote) return ""
            if (groupItem.row.status === "connecting") return strings.t("remote.connecting")
            if (groupItem.remoteDown) return groupItem.row.error || strings.t("remote.unreachable")
            return ""
          }
          color: root.dim
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          maximumLineCount: 3
          elide: Text.ElideRight
        }
      }
    }
  }

  Component {
    id: instanceComponent
    InstanceRow {}
  }

  component PlainText: Text {
    textFormat: Text.PlainText
    font.family: root.fontFamily
  }

  // A command shown in a box with a copy button.
  component CommandLine: CursorSurface {
    id: commandLine
    property string command: ""
    foreground: root.foreground
    implicitHeight: Math.max(commandText.implicitHeight, copyCommand.implicitHeight) + Style.space(10)

    PlainText {
      id: commandText
      anchors.left: parent.left
      anchors.right: copyCommand.left
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      text: commandLine.command
      color: root.foreground
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    PanelActionButton {
      id: copyCommand
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      iconText: Model.glyphs.copy
      tooltipText: Model.plain(strings.t("action.copy"), 30)
      foreground: root.foreground
      fontFamily: root.fontFamily
      onClicked: root.omacus.copyText(commandLine.command)
    }
  }

  // A clickable row: glyph, title and an optional detail line.
  component ListRow: CursorSurface {
    id: listRow
    signal chosen()
    property string rowKey: ""
    property string glyph: ""
    property color glyphColor: root.foreground
    property string title: ""
    property string detail: ""

    hasCursor: root.hasCursor(rowKey)
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: listInner.implicitHeight + Style.spacing.xl
    Component.onCompleted: root.registerRow(rowKey, listRow)
    Component.onDestruction: root.unregisterRow(rowKey, listRow)

    RowLayout {
      id: listInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      PlainText {
        text: listRow.glyph
        color: listRow.glyphColor
        font.pixelSize: Style.font.icon
        Layout.preferredWidth: Style.space(20)
        horizontalAlignment: Text.AlignHCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(1)

        PlainText {
          Layout.fillWidth: true
          text: listRow.title
          color: root.foreground
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        PlainText {
          Layout.fillWidth: true
          visible: text !== ""
          text: listRow.detail
          color: root.dim
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(listRow.rowKey)
      onClicked: listRow.chosen()
    }
  }

  component InstanceRow: CursorSurface {
    id: instRow
    property var row: null
    readonly property var inst: row ? row.inst : null
    readonly property string remote: row ? row.remote : ""
    readonly property string key: row ? row.key : ""
    readonly property string rowKey: "inst:" + key
    readonly property bool expanded: root.expandedKey === key && key !== ""
    readonly property var actions: inst && expanded ? root.instanceActions(remote, inst) : []
    readonly property var hist: root.omacus.history ? root.omacus.history[key] : undefined
    readonly property bool watchedInst: inst ? Model.isWatched(root.omacus.watched || [], remote, inst.name) : false

    hasCursor: root.hasCursor(rowKey)
    current: expanded
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: instColumn.implicitHeight + Style.space(14)
    onRowKeyChanged: root.registerRow(rowKey, instRow)
    Component.onDestruction: root.unregisterRow(rowKey, instRow)

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(instRow.rowKey)
      onClicked: {
        root.setCursor(instRow.rowKey)
        root.expandedKey = instRow.expanded ? "" : instRow.key
      }
    }

    Column {
      id: instColumn
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(7)
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(6)

      RowLayout {
        width: parent.width
        spacing: Style.space(10)

        PlainText {
          text: instRow.inst && instRow.inst.type === "vm" ? Model.glyphs.vm : Model.glyphs.container
          color: instRow.inst ? root.statusColor(instRow.inst) : root.dim
          font.pixelSize: Style.font.icon
          Layout.preferredWidth: Style.space(20)
          horizontalAlignment: Text.AlignHCenter
          opacity: instRow.inst && root.omacus.busy && root.omacus.busy[instRow.key] ? 0.45 : 1.0

          SequentialAnimation on opacity {
            running: !!(instRow.inst && root.omacus.busy && root.omacus.busy[instRow.key])
            loops: Animation.Infinite
            NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
          }
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            PlainText {
              Layout.fillWidth: true
              text: instRow.inst ? instRow.inst.name : ""
              color: instRow.inst && Model.isRunning(instRow.inst) ? root.foreground : root.statusColor(instRow.inst || {})
              font.pixelSize: Style.font.body
              font.bold: instRow.expanded
              elide: Text.ElideRight
            }

            PlainText {
              visible: instRow.watchedInst
              text: Model.glyphs.eye
              color: root.dim
              font.pixelSize: Style.font.caption
            }

            PlainText {
              text: instRow.inst ? root.usageText(instRow.remote, instRow.inst) : ""
              color: root.dim
              font.pixelSize: Style.font.caption
            }

            Sparkline {
              visible: !!(instRow.hist && instRow.hist.cpu && instRow.hist.cpu.length > 1)
              Layout.preferredWidth: Style.space(44)
              Layout.preferredHeight: Style.space(14)
              values: instRow.hist ? instRow.hist.cpu : []
              lineColor: root.foreground
            }
          }

          PlainText {
            Layout.fillWidth: true
            text: instRow.inst ? root.instanceSummary(instRow.remote, instRow.inst) : ""
            color: root.dim
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }

      // Details
      GridLayout {
        visible: instRow.expanded
        width: parent.width
        columns: 2
        columnSpacing: Style.space(10)
        rowSpacing: Style.space(3)

        Repeater {
          model: instRow.expanded && instRow.inst ? root.detailLines(instRow.remote, instRow.inst) : []
          delegate: PlainText {
            required property var modelData
            required property int index
            Layout.row: index
            Layout.column: 0
            Layout.alignment: Qt.AlignTop
            text: modelData.label
            color: root.dim
            font.pixelSize: Style.font.caption
          }
        }

        Repeater {
          model: instRow.expanded && instRow.inst ? root.detailLines(instRow.remote, instRow.inst) : []
          delegate: PlainText {
            required property var modelData
            required property int index
            Layout.row: index
            Layout.column: 1
            Layout.fillWidth: true
            text: modelData.value
            color: modelData.warn ? root.accent : root.foreground
            font.pixelSize: Style.font.caption
            wrapMode: Text.WrapAnywhere
          }
        }
      }

      // Actions
      Flow {
        visible: instRow.expanded && instRow.actions.length > 0
        width: parent.width
        spacing: Style.space(4)

        Repeater {
          model: instRow.actions
          PanelActionButton {
            required property var modelData
            required property int index
            readonly property bool confirming: root.confirmKey === instRow.key && root.confirmVerb === modelData.id
            iconText: modelData.glyph
            tooltipText: Model.plain(confirming ? strings.t("action.confirm").arg(modelData.tip) : modelData.tip, 80)
            foreground: confirming || modelData.danger ? root.urgent : root.foreground
            fontFamily: root.fontFamily
            bordered: confirming
            hasCursor: instRow.hasCursor && root.actionIndex === index
            enabled: !(root.omacus.busy && root.omacus.busy[instRow.key])
            onClicked: root.runInstanceAction(instRow.remote, instRow.inst, modelData.id)
            onHovered: function(isHovered) { if (isHovered) { root.setCursor(instRow.rowKey); root.actionIndex = index } }
          }
        }
      }

      PlainText {
        visible: instRow.expanded && root.confirmKey === instRow.key
        width: parent.width
        text: strings.t("action.confirmHint")
        color: root.urgent
        font.pixelSize: Style.font.caption
      }
    }
  }

  component HostSection: Column {
    id: hostSection
    property var rs: null
    readonly property var host: rs ? rs.host : null
    readonly property var ops: rs && root.omacus.operations ? (root.omacus.operations[rs.name] || []) : []
    spacing: Style.space(6)

    PanelSectionHeader {
      text: root.shownRemotes.length > 1 || root.visibleRemotes.length > 1
        ? Model.plain(strings.t("section.server").arg(hostSection.rs ? hostSection.rs.name : ""), 60)
        : strings.t("section.host")
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    PlainText {
      visible: !!hostSection.host
      width: parent.width
      text: {
        var h = hostSection.host
        if (!h) return ""
        var parts = []
        if (h.name) parts.push(h.name)
        if (h.version) parts.push("Incus " + h.version)
        if (h.cpuThreads) parts.push(strings.tn("host.threads", h.cpuThreads).arg(h.cpuThreads))
        if (h.load1 !== null && h.load1 !== undefined) parts.push(strings.t("host.load").arg(Commons.I18n.formatNumber(h.load1, 2)))
        return parts.join(" · ")
      }
      color: root.dim
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Meter {
      visible: !!(hostSection.host && hostSection.host.memTotal)
      width: parent.width
      label: strings.t("host.memory")
      value: hostSection.host && hostSection.host.memTotal ? hostSection.host.memUsed / hostSection.host.memTotal * 100 : 0
      detail: hostSection.host ? Model.formatBytes(hostSection.host.memUsed) + " / " + Model.formatBytes(hostSection.host.memTotal) : ""
    }

    Repeater {
      model: hostSection.rs ? (hostSection.rs.pools || []) : []
      Meter {
        required property var modelData
        width: hostSection.width
        label: Model.glyphs.pool + "  " + modelData.name
        value: Model.poolPercent(modelData) || 0
        detail: modelData.total ? Model.formatBytes(modelData.used) + " / " + Model.formatBytes(modelData.total) + " · " + modelData.driver : modelData.driver
        warn: (Model.poolPercent(modelData) || 0) >= root.omacus.poolWarnPercent
      }
    }

    Repeater {
      model: hostSection.rs ? (hostSection.rs.members || []) : []
      PlainText {
        required property var modelData
        width: hostSection.width
        text: Model.glyphs.server + "  " + modelData.name + " · " + modelData.status + (modelData.message && modelData.status !== "Online" ? " · " + modelData.message : "")
        color: modelData.status === "Online" ? root.dim : root.urgent
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    Repeater {
      model: hostSection.ops
      Meter {
        required property var modelData
        width: hostSection.width
        label: Model.glyphs.task + "  " + modelData.description
        value: modelData.percent !== null && modelData.percent !== undefined ? modelData.percent : 0
        detail: modelData.percent !== null && modelData.percent !== undefined ? Model.formatPercent(modelData.percent) : (modelData.stage || modelData.status)
      }
    }

    Repeater {
      model: hostSection.rs ? (hostSection.rs.warnings || []).slice(0, 5) : []
      PlainText {
        required property var modelData
        width: hostSection.width
        text: Model.glyphs.alert + "  " + modelData.message + (modelData.count > 1 ? " (×" + modelData.count + ")" : "")
        color: root.accent
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
    }
  }

  // A labeled bar for pools, memory and task progress.
  component Meter: Column {
    id: meter
    property string label: ""
    property string detail: ""
    property real value: 0
    property bool warn: false
    spacing: Style.space(3)

    RowLayout {
      width: parent.width
      spacing: Style.space(8)

      PlainText {
        Layout.fillWidth: true
        text: meter.label
        color: root.foreground
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      PlainText {
        text: meter.detail
        color: meter.warn ? root.accent : root.dim
        font.pixelSize: Style.font.caption
      }
    }

    Rectangle {
      width: parent.width
      height: Math.max(3, Style.space(4))
      radius: height / 2
      color: Util.alpha(root.foreground, 0.12)

      Rectangle {
        width: parent.width * Math.max(0, Math.min(100, meter.value)) / 100
        height: parent.height
        radius: parent.radius
        color: meter.warn ? root.accent : root.foreground
        opacity: meter.warn ? 1.0 : 0.7
      }
    }
  }

  // A small CPU history line, drawn only while the panel is open.
  component Sparkline: Canvas {
    id: spark
    property var values: []
    property color lineColor: root.foreground
    onValuesChanged: requestPaint()
    onLineColorChanged: requestPaint()
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var list = values || []
      if (list.length < 2) return
      ctx.strokeStyle = lineColor
      ctx.globalAlpha = 0.8
      ctx.lineWidth = 1.2
      ctx.beginPath()
      for (var i = 0; i < list.length; i++) {
        var x = i / (list.length - 1) * (width - 1)
        var v = Math.max(0, Math.min(100, Number(list[i]) || 0))
        var y = height - 1 - v / 100 * (height - 2)
        if (i === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.stroke()
    }
  }
}
