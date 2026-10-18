// Unit tests for Model.js. Run: node tests/model-test.mjs
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import assert from "node:assert/strict"

const source = readFileSync(fileURLToPath(new URL("../Model.js", import.meta.url)), "utf8").replace(/^\.pragma library\s*/, "")
const names = [...source.matchAll(/^(?:function|var) ([A-Za-z_]+)/gm)].map(m => m[1])
const Model = new Function(source + "\nreturn {" + names.join(",") + "}")()

let failures = 0
function test(name, fn) {
  try {
    fn()
    console.log("ok   " + name)
  } catch (e) {
    failures++
    console.log("FAIL " + name + "\n     " + e.message)
  }
}

const NOW = Date.UTC(2026, 9, 18, 12, 0, 0)
const daysAgo = d => new Date(NOW - d * 86400000).toISOString()

function inst(fields) {
  return Object.assign({
    name: "web", project: "default", type: "container", status: "Running", ipv4: [], ipv6: [],
    processes: 10, snapshots: 0, newestSnapshot: "", snapshotSchedule: "", memUsage: 0, memTotal: 0
  }, fields)
}

test("formatBytes uses binary units", () => {
  assert.equal(Model.formatBytes(0), "0 B")
  assert.equal(Model.formatBytes(1536), "1.5 KiB")
  assert.equal(Model.formatBytes(2 * 1024 ** 3), "2.0 GiB")
  assert.equal(Model.formatBytes(150 * 1024 ** 3), "150 GiB")
  assert.equal(Model.formatBytes(-1), "")
  assert.equal(Model.formatBytes(NaN), "")
  assert.equal(Model.formatBytes("12"), "")
})

test("formatAge picks the largest whole unit", () => {
  assert.equal(Model.formatAge(40), "40s")
  assert.equal(Model.formatAge(600), "10m")
  assert.equal(Model.formatAge(7200), "2h")
  assert.equal(Model.formatAge(3 * 86400 + 5), "3d")
})

test("cpuPercent is relative to the instance's allowance", () => {
  const prev = { cpuUsage: 10e9, at: 0 }
  // Two cores allowed, one core busy for 5 s: 50%.
  const cur = { cpuUsage: 15e9, cpuAllocated: 2e9, at: 5000 }
  assert.equal(Math.round(Model.cpuPercent(prev, cur, 16)), 50)
  // No allowance reported: fall back to host threads.
  assert.equal(Math.round(Model.cpuPercent(prev, { cpuUsage: 15e9, at: 5000 }, 4)), 25)
  // A counter that went backwards (restart) is not a reading.
  assert.equal(Model.cpuPercent({ cpuUsage: 20e9, at: 0 }, cur, 4), null)
  assert.equal(Model.cpuPercent(null, cur, 4), null)
  assert.equal(Model.cpuPercent(prev, { cpuUsage: 15e9, at: 0 }, 4), null)
})

test("snapshotStale only flags instances that take snapshots", () => {
  assert.equal(Model.snapshotStale(inst({ snapshots: 2, newestSnapshot: daysAgo(12) }), 7, NOW), true)
  assert.equal(Model.snapshotStale(inst({ snapshots: 2, newestSnapshot: daysAgo(3) }), 7, NOW), false)
  assert.equal(Model.snapshotStale(inst({}), 7, NOW), false)
  assert.equal(Model.snapshotStale(inst({ snapshotSchedule: "@daily" }), 7, NOW), true)
  assert.equal(Model.snapshotStale(inst({ snapshots: 2, newestSnapshot: daysAgo(90) }), 0, NOW), false)
})

test("agentMissing only for running VMs without addresses", () => {
  assert.equal(Model.agentMissing(inst({ type: "vm", processes: -1 })), true)
  assert.equal(Model.agentMissing(inst({ type: "vm", processes: -1, ipv4: ["10.0.0.2"] })), false)
  assert.equal(Model.agentMissing(inst({ type: "container", processes: -1 })), false)
  assert.equal(Model.agentMissing(inst({ type: "vm", status: "Stopped", processes: 0 })), false)
})

test("sortInstances puts errors first, then running, then by name", () => {
  const list = [
    inst({ name: "b", status: "Stopped" }), inst({ name: "c" }), inst({ name: "a" }),
    inst({ name: "z", status: "Error" }), inst({ name: "p", status: "Frozen" }),
  ]
  assert.deepEqual(Model.sortInstances(list).map(i => i.name), ["z", "a", "c", "p", "b"])
  const projects = [inst({ name: "a", project: "media" }), inst({ name: "b", status: "Error" }), inst({ name: "c" })]
  assert.deepEqual(Model.sortInstances(projects, true).map(i => i.name), ["b", "c", "a"])
})

test("attention lists urgent problems first and keys them stably", () => {
  const items = Model.attention([
    { name: "homelab", status: "ok", warningCount: 2, members: [],
      pools: [{ name: "tank", used: 96, total: 100 }, { name: "fast", used: 50, total: 100 }],
      instances: [inst({ name: "db", snapshots: 1, newestSnapshot: daysAgo(30) }), inst({ name: "mc", status: "Error" }), inst({ name: "web", status: "Stopped" })] },
    { name: "nas", status: "unreachable", error: "no route to host" },
  ], { watched: ["homelab:web"], snapshotWarnDays: 7, poolWarnPercent: 85, nowMs: NOW })
  assert.deepEqual(items.map(i => i.key), [
    "error:homelab/default/mc", "watched:homelab/default/web", "pool:homelab/tank", "remote:nas",
    "snapshot:homelab/default/db", "warnings:homelab",
  ])
  assert.equal(items.find(i => i.kind === "snapshot").days, 30)
})

test("plain strips markup and controls and caps length", () => {
  assert.equal(Model.plain('<img src="http://x/leak.png">'), 'img src="http://x/leak.png"')
  assert.equal(Model.plain("a&b"), "ab")
  assert.equal(Model.plain("line\nbreak‮"), "line break ")
  assert.equal(Model.plain("x".repeat(300), 10).length, 10)
  assert.equal(Model.plain(null), "")
})

test("webUiUrl accepts only HTTPS host addresses", () => {
  assert.equal(Model.webUiUrl("https://homelab.lan:8443"), "https://homelab.lan:8443/ui/")
  assert.equal(Model.webUiUrl("https://[fd00::1]:8443/"), "https://[fd00::1]:8443/ui/")
  assert.equal(Model.webUiUrl("http://homelab.lan:8443"), "")
  assert.equal(Model.webUiUrl("https://evil.example\\@homelab.lan"), "")
  assert.equal(Model.webUiUrl("unix://"), "")
  assert.equal(Model.webUiUrl("https://host/path?x"), "")
})

test("validators refuse option-shaped and traversal values", () => {
  assert.equal(Model.validInstanceName("web-1"), true)
  assert.equal(Model.validInstanceName("-rf"), false)
  assert.equal(Model.validInstanceName("a/b"), false)
  assert.equal(Model.validInstanceName("x".repeat(64)), false)
  assert.equal(Model.validName(".."), false)
  assert.equal(Model.validName("homelab"), true)
  assert.equal(Model.validImage("images:debian/13"), true)
  assert.equal(Model.validImage("--vm"), false)
  assert.equal(Model.validImage("images:debian 13"), false)
  assert.equal(Model.validImage("a;rm"), false)
})

test("imageAgeDays reads the serial date", () => {
  assert.equal(Model.imageAgeDays("20261008_05:24", NOW), 10)
  assert.equal(Model.imageAgeDays("", NOW), null)
  assert.equal(Model.imageAgeDays("latest", NOW), null)
})

test("matchesQuery needs every word", () => {
  const i = inst({ name: "jellyfin", project: "media", ipv4: ["10.10.0.30"], imageOs: "Debian" })
  assert.equal(Model.matchesQuery(i, "jelly media"), true)
  assert.equal(Model.matchesQuery(i, "10.10.0.30"), true)
  assert.equal(Model.matchesQuery(i, "jelly ubuntu"), false)
  assert.equal(Model.matchesQuery(i, "  "), true)
})

test("parseList trims, dedupes and bounds", () => {
  assert.deepEqual(Model.parseList(" homelab:web, nas:db ,homelab:web,,"), ["homelab:web", "nas:db"])
  assert.equal(Model.parseList(Array(500).fill("a").map((a, i) => a + i).join(",")).length, 200)
})

test("pushHistory keeps a bounded window", () => {
  let h = []
  for (let i = 0; i < 100; i++) h = Model.pushHistory(h, i)
  assert.equal(h.length, Model.MAX_HISTORY)
  assert.equal(h[h.length - 1], 99)
})

if (failures > 0) {
  console.log(failures + " failed")
  process.exit(1)
}
console.log("all passed")
