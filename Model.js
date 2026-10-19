.pragma library

// Pure helpers for Omacus: formatting, sorting and the rules that decide what
// needs attention. Nothing here starts a process or touches QML objects, so
// tests/model-test.mjs can load it in Node.

// The CPU graph covers the last 15 minutes, one point about every 30 seconds.
var HISTORY_WINDOW_MS = 15 * 60 * 1000
var MAX_HISTORY = 60
var BACKGROUND_STATS_MS = 30000
// A graph point averages CPU over at least this long, so the faster samples
// taken while the panel is open don't add noisy, bunched-up points.
var HISTORY_STEP_MS = 25000
var INSTANCE_RE = /^[A-Za-z0-9][A-Za-z0-9-]{0,62}$/
var NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$/
var IMAGE_RE = /^[A-Za-z0-9][A-Za-z0-9._:\/@-]{0,199}$/
var IP_RE = /^[0-9A-Fa-f:.]{2,45}$/
var HTTPS_RE = /^https:\/\/[A-Za-z0-9.\-]+(:[0-9]{1,5})?\/?$|^https:\/\/\[[0-9A-Fa-f:]+\](:[0-9]{1,5})?\/?$/

function glyph(codepoint) { return String.fromCodePoint(codepoint) }

var readmeSettingsUrl = "https://github.com/dmkenney/omacus#settings"

var glyphs = {
  incus: glyph(0xF01A7),      // cube outline
  container: glyph(0xF01A7),
  vm: glyph(0xF0379),         // monitor
  server: glyph(0xF048B),
  alert: glyph(0xF0026),
  play: glyph(0xF040A),
  stop: glyph(0xF04DB),
  restart: glyph(0xF0709),
  pause: glyph(0xF03E4),
  snapshot: glyph(0xF0100),   // camera
  shell: glyph(0xF018D),      // console
  console: glyph(0xF0379),
  copy: glyph(0xF018F),
  web: glyph(0xF059F),
  plus: glyph(0xF0415),
  download: glyph(0xF01DA),
  pool: glyph(0xF01BC),       // database
  refresh: glyph(0xF0450),
  eye: glyph(0xF0208),
  eyeOff: glyph(0xF0209),
  cog: glyph(0xF0493),
  chevronDown: glyph(0xF0140),
  chevronRight: glyph(0xF0142),
  task: glyph(0xF0150)        // clock outline
}

// Strip what the shell's own components could read as markup, plus control
// and bidi characters, for text handed to a tooltip, a hero title or a
// notification whose text format the plugin cannot set.
function plain(value, cap) {
  var text = String(value === undefined || value === null ? "" : value)
  text = text.replace(/[<>&]/g, "").replace(/[\u0000-\u001f\u007f-\u009f‪-‮⁦-⁩]/g, " ")
  var limit = cap || 200
  return text.length > limit ? text.substring(0, limit - 1) + "…" : text
}

function finite(value) {
  return typeof value === "number" && isFinite(value) && value >= 0 ? value : null
}

function formatBytes(value) {
  var n = finite(value)
  if (n === null) return ""
  var units = ["B", "KiB", "MiB", "GiB", "TiB", "PiB"]
  var i = 0
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
  var digits = n >= 100 || i === 0 ? 0 : 1
  return n.toFixed(digits) + " " + units[i]
}

function formatPercent(value) {
  var n = finite(value)
  if (n === null) return ""
  return (n >= 10 ? Math.round(n) : Math.round(n * 10) / 10) + "%"
}

// "3d", "5h", "12m", "40s": the largest unit that is at least one.
function formatAge(seconds) {
  var s = finite(seconds)
  if (s === null) return ""
  if (s >= 86400) return Math.floor(s / 86400) + "d"
  if (s >= 3600) return Math.floor(s / 3600) + "h"
  if (s >= 60) return Math.floor(s / 60) + "m"
  return Math.floor(s) + "s"
}

function parseTime(text) {
  if (typeof text !== "string" || text === "") return null
  var ms = Date.parse(text)
  return isFinite(ms) ? ms : null
}

function secondsSince(text, nowMs) {
  var ms = parseTime(text)
  if (ms === null) return null
  return Math.max(0, ((nowMs || Date.now()) - ms) / 1000)
}

// Image serials look like 20260901_05:24. Returns days since the build, or
// null when the image does not say.
function imageAgeDays(serial, nowMs) {
  var m = /^(\d{4})(\d{2})(\d{2})/.exec(String(serial || ""))
  if (!m) return null
  var ms = Date.UTC(parseInt(m[1], 10), parseInt(m[2], 10) - 1, parseInt(m[3], 10))
  if (!isFinite(ms)) return null
  return Math.max(0, Math.floor(((nowMs || Date.now()) - ms) / 86400000))
}

function instanceKey(remote, inst) {
  return remote + "/" + inst.project + "/" + inst.name
}

function isRunning(inst) { return inst && inst.status === "Running" }
function isFrozen(inst) { return inst && inst.status === "Frozen" }
function isStopped(inst) { return inst && inst.status === "Stopped" }
function isError(inst) { return inst && inst.status === "Error" }

var STATUS_RANK = { "Error": 0, "Running": 1, "Frozen": 2, "Stopped": 3 }

// Errors first, then running, paused and stopped, then by name. With
// byProject, instances are grouped by project before that.
function sortInstances(list, byProject) {
  return list.slice().sort(function(a, b) {
    if (byProject && a.project !== b.project) return a.project < b.project ? -1 : 1
    var ra = STATUS_RANK[a.status] !== undefined ? STATUS_RANK[a.status] : 4
    var rb = STATUS_RANK[b.status] !== undefined ? STATUS_RANK[b.status] : 4
    if (ra !== rb) return ra - rb
    if (a.project !== b.project) return a.project < b.project ? -1 : 1
    return a.name < b.name ? -1 : (a.name > b.name ? 1 : 0)
  })
}

function matchesQuery(inst, query) {
  var q = String(query || "").trim().toLowerCase()
  if (q === "") return true
  var hay = [inst.name, inst.project, inst.status, inst.type, inst.description, inst.imageOs, inst.imageRelease]
    .concat(inst.ipv4 || []).concat(inst.profiles || []).join(" ").toLowerCase()
  var words = q.split(/\s+/)
  for (var i = 0; i < words.length; i++) if (hay.indexOf(words[i]) === -1) return false
  return true
}

// CPU use between two samples of the same instance, as a percentage of what it
// may use: allocated_time is the CPU time it is allowed per second, so a
// container limited to two cores at full load reads 100%.
function cpuPercent(prev, cur, hostThreads) {
  if (!prev || !cur) return null
  var a = finite(prev.cpuUsage)
  var b = finite(cur.cpuUsage)
  var dt = cur.at - prev.at
  if (a === null || b === null || !(dt > 0) || b < a) return null
  var perSecond = finite(cur.cpuAllocated) || (finite(hostThreads) ? hostThreads * 1e9 : null)
  if (!perSecond) return null
  return Math.min(100, ((b - a) / (dt / 1000)) / perSecond * 100)
}

function memPercent(inst) {
  var used = finite(inst.memUsage)
  var total = finite(inst.memTotal)
  if (used === null || !total) return null
  return Math.min(100, used / total * 100)
}

function diskPercent(inst) {
  var used = finite(inst.diskUsage)
  var total = finite(inst.diskTotal)
  if (used === null || !total) return null
  return Math.min(100, used / total * 100)
}

function poolPercent(pool) {
  var used = finite(pool.used)
  var total = finite(pool.total)
  if (used === null || !total) return null
  return Math.min(100, used / total * 100)
}

// A running VM without incus-agent reports no addresses and no process count,
// so its IP and memory are unknown rather than empty.
function agentMissing(inst) {
  return inst.type === "vm" && isRunning(inst) && (inst.ipv4 || []).length === 0 && (inst.ipv6 || []).length === 0 && inst.processes <= 0
}

function isWindows(inst) {
  return /windows/i.test(String(inst.imageOs || ""))
}

function snapshotAgeDays(inst, nowMs) {
  var seconds = secondsSince(inst.newestSnapshot, nowMs)
  return seconds === null ? null : Math.floor(seconds / 86400)
}

// A snapshot is stale when the instance takes snapshots (it has some, or a
// schedule) and the newest is older than the limit. An instance that never
// had one is a choice, not a fault.
function snapshotStale(inst, warnDays, nowMs) {
  if (!(warnDays > 0)) return false
  var age = snapshotAgeDays(inst, nowMs)
  if (age === null) return inst.snapshotSchedule !== "" && inst.snapshots === 0
  return age > warnDays
}

function parseList(value) {
  var out = []
  var parts = String(value || "").split(",")
  for (var i = 0; i < parts.length && out.length < 200; i++) {
    var item = parts[i].trim()
    if (item !== "" && item.length <= 130 && out.indexOf(item) === -1) out.push(item)
  }
  return out
}

function watchKey(remote, name) { return remote + ":" + name }

function isWatched(watched, remote, name) {
  return watched.indexOf(watchKey(remote, name)) !== -1
}

// Everything worth a second look, most urgent first. Each item carries a
// severity of "urgent" or "warning", and a stable key so notifications fire
// once per problem.
function attention(remoteStates, opts) {
  var items = []
  var now = opts.nowMs || Date.now()
  for (var r = 0; r < remoteStates.length; r++) {
    var rs = remoteStates[r]
    if (rs.status === "unreachable" || rs.status === "error") {
      items.push({ key: "remote:" + rs.name, severity: "urgent", kind: "remote", remote: rs.name, text: rs.error || "" })
      continue
    }
    var instances = rs.instances || []
    for (var i = 0; i < instances.length; i++) {
      var inst = instances[i]
      if (isError(inst)) items.push({ key: "error:" + instanceKey(rs.name, inst), severity: "urgent", kind: "error", remote: rs.name, name: inst.name, project: inst.project })
      else if (!isRunning(inst) && !isFrozen(inst) && isWatched(opts.watched || [], rs.name, inst.name))
        items.push({ key: "watched:" + instanceKey(rs.name, inst), severity: "urgent", kind: "watched", remote: rs.name, name: inst.name, project: inst.project })
      else if (isRunning(inst) && snapshotStale(inst, opts.snapshotWarnDays, now))
        items.push({ key: "snapshot:" + instanceKey(rs.name, inst), severity: "warning", kind: "snapshot", remote: rs.name, name: inst.name, project: inst.project, days: snapshotAgeDays(inst, now) })
    }
    var pools = rs.pools || []
    for (var p = 0; p < pools.length; p++) {
      var pct = poolPercent(pools[p])
      if (pct !== null && pct >= opts.poolWarnPercent)
        items.push({ key: "pool:" + rs.name + "/" + pools[p].name, severity: pct >= 95 ? "urgent" : "warning", kind: "pool", remote: rs.name, name: pools[p].name, percent: pct })
    }
    var members = rs.members || []
    for (var m = 0; m < members.length; m++) {
      if (members[m].status && members[m].status !== "Online")
        items.push({ key: "member:" + rs.name + "/" + members[m].name, severity: "urgent", kind: "member", remote: rs.name, name: members[m].name, text: members[m].status })
    }
    if ((rs.warningCount || 0) > 0)
      items.push({ key: "warnings:" + rs.name, severity: "warning", kind: "warnings", remote: rs.name, count: rs.warningCount })
  }
  items.sort(function(a, b) { return (a.severity === "urgent" ? 0 : 1) - (b.severity === "urgent" ? 0 : 1) })
  return items
}

// History entries are { t: ms, v: percent }, oldest first.
function pushHistory(history, value, at) {
  var since = at - HISTORY_WINDOW_MS
  var next = (history || []).filter(function(p) { return p.t > since }).slice(-(MAX_HISTORY - 1))
  next.push({ t: at, v: value === null || value === undefined ? 0 : value })
  return next
}

// Top of the graph: the window's peak, but at least 1% so near-zero noise
// stays flat. The CPU figure beside the graph gives the real level.
function historyScale(history) {
  var peak = 1
  for (var i = 0; i < (history || []).length; i++) peak = Math.max(peak, Number(history[i].v) || 0)
  return Math.min(100, peak)
}

function validInstanceName(name) { return INSTANCE_RE.test(String(name || "")) }
function validName(name) { return NAME_RE.test(String(name || "")) && name !== "." && name !== ".." }
function validImage(image) { return IMAGE_RE.test(String(image || "")) }
function validIp(ip) { return IP_RE.test(String(ip || "")) }

// The web UI lives at /ui/ on the remote's HTTPS address.
function webUiUrl(addr) {
  var text = String(addr || "")
  if (!HTTPS_RE.test(text)) return ""
  return text.replace(/\/$/, "") + "/ui/"
}
