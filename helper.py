#!/usr/bin/python3 -I -S
# Omacus helper.
#
# The shell plugin runs every incus call through this file, so that each call
# has a deadline, a byte ceiling and its own process group, and so the QML only
# ever reads a small JSON document of a fixed shape. Nothing here touches the
# disk, except add-remote pinning a server certificate in the incus client's
# own config: credentials stay there, and every result goes to stdout.
#
#   helper.py [--incus PATH] probe
#   helper.py [--incus PATH] remotes
#   helper.py [--incus PATH] snapshot REMOTE PROJECT [--instances-only]
#   helper.py [--incus PATH] monitor REMOTE
#   helper.py [--incus PATH] action VERB REMOTE PROJECT INSTANCE
#   helper.py [--incus PATH] add-remote          (interactive, in a terminal)

import json
import os
import pwd
import re
import select
import signal
import stat
import subprocess
import sys
import time

QUERY_CAP = 8 * 1024 * 1024  # one incus response
STDERR_CAP = 4096
OUTPUT_CAP = 2 * 1024 * 1024  # one document printed for the shell
EVENT_LINE_CAP = 1024 * 1024  # one monitor event
TEXT_CAP = 200

MAX_REMOTES = 32
MAX_INSTANCES = 500
MAX_POOLS = 16
MAX_WARNINGS = 50
MAX_MEMBERS = 64
MAX_OPERATIONS = 20
MAX_ADDRESSES = 8
MAX_PROFILES = 8
MAX_PORTS = 8

QUERY_TIMEOUT = 20
ACTION_TIMEOUT = 150

NAME_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,62}")
INSTANCE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]{0,62}")
EVENT_ACTION_RE = re.compile(r"[a-z][a-z0-9-]{0,63}")
ADDRESS_RE = re.compile(r"[0-9A-Fa-f:.]{2,45}")
ADDRESS_PORT_RE = re.compile(r"(\[[0-9A-Fa-f:.]{2,45}\]|[A-Za-z0-9.-]{1,253})(:[0-9]{1,5})?")
FINGERPRINT_RE = re.compile(r"[0-9A-Fa-f]{64}")
OPERATION_ID_RE = re.compile(r"[0-9a-f-]{8,64}")
# C0 and C1 controls, and the bidi overrides that can reorder a line.
CONTROL_RE = re.compile("[\x00-\x1f\x7f-\x9f‪-‮⁦-⁩]")

ACTIONS = {
  "start": ["start"],
  "stop": ["stop"],
  "force-stop": ["stop", "--force"],
  "restart": ["restart"],
  "pause": ["pause"],
  "snapshot": ["snapshot", "create"],
}

_children = []
_libc = None


def load_libc():
  global _libc
  try:
    import ctypes
    _libc = ctypes.CDLL("libc.so.6", use_errno=True)
  except Exception:
    _libc = None


def die_with_parent():
  # PR_SET_PDEATHSIG: if the shell goes away, so do we, and so do our children.
  if _libc is not None:
    _libc.prctl(1, signal.SIGKILL)


def kill_group(proc):
  for sig in (signal.SIGTERM, signal.SIGKILL):
    try:
      os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
      return
    try:
      proc.wait(timeout=1.5)
      return
    except subprocess.TimeoutExpired:
      continue


def on_term(signum, frame):
  for proc in list(_children):
    if proc.poll() is None:
      kill_group(proc)
  os._exit(143)


def clean(value, cap=TEXT_CAP):
  if value is None:
    return ""
  text = CONTROL_RE.sub(" ", str(value)).strip()
  return text[:cap]


def number(value):
  if isinstance(value, bool) or not isinstance(value, (int, float)):
    return None
  if value != value or value in (float("inf"), float("-inf")) or value < 0:
    return None
  return value


def as_dict(value):
  return value if isinstance(value, dict) else {}


def as_list(value):
  return value if isinstance(value, list) else []


def emit(doc):
  data = json.dumps(doc, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
  if len(data) > OUTPUT_CAP:
    data = json.dumps({"ok": False, "error": "result too large"}).encode("utf-8")
  sys.stdout.buffer.write(data + b"\n")
  sys.stdout.buffer.flush()


def fail(message):
  emit({"ok": False, "error": clean(message, 300)})
  sys.exit(1)


def find_incus(requested):
  home = pwd.getpwuid(os.geteuid()).pw_dir
  if requested:
    candidates = [requested]
  else:
    candidates = [
      "/usr/bin/incus",
      "/usr/local/bin/incus",
      os.path.join(home, ".local/bin/incus"),
      os.path.join(home, "bin/incus"),
    ]
  for path in candidates:
    if not os.path.isabs(path):
      continue
    try:
      st = os.stat(path)
    except OSError:
      continue
    # Refuse a binary someone else could have replaced.
    if not stat.S_ISREG(st.st_mode) or st.st_mode & 0o022 or st.st_uid not in (0, os.geteuid()):
      continue
    if os.access(path, os.X_OK):
      return path
  return None


def child_env():
  env = dict(os.environ)
  # Plain English errors, so the panel can tell an auth failure from a timeout.
  env["LC_ALL"] = "C"
  return env


def child_setup():
  die_with_parent()


def run_many(argvs, timeout, cap=QUERY_CAP):
  # Run every argv at once under one deadline. stdout is capped at cap + 1 so
  # an overflow is detected rather than truncated into something parseable.
  deadline = time.monotonic() + timeout
  env = child_env()
  runs = []
  for argv in argvs:
    proc = subprocess.Popen(
      argv,
      stdin=subprocess.DEVNULL,
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,
      start_new_session=True,
      preexec_fn=child_setup,
      env=env,
    )
    _children.append(proc)
    runs.append({"proc": proc, "out": bytearray(), "err": bytearray(), "over": False})

  fds = {}
  for index, run in enumerate(runs):
    fds[run["proc"].stdout.fileno()] = (index, "out")
    fds[run["proc"].stderr.fileno()] = (index, "err")

  timed_out = False
  while fds:
    left = deadline - time.monotonic()
    if left <= 0:
      timed_out = True
      break
    ready, _, _ = select.select(list(fds), [], [], left)
    for fd in ready:
      if fd not in fds:
        continue
      index, stream = fds[fd]
      run = runs[index]
      chunk = os.read(fd, 65536)
      if not chunk:
        del fds[fd]
        continue
      if stream == "err":
        room = STDERR_CAP - len(run["err"])
        if room > 0:
          run["err"] += chunk[:room]
        continue
      room = cap + 1 - len(run["out"])
      if room > 0:
        run["out"] += chunk[:room]
      if len(run["out"]) > cap:
        run["over"] = True
        kill_group(run["proc"])
        for other in [f for f, (i, _) in fds.items() if i == index]:
          del fds[other]

  results = []
  for run in runs:
    proc = run["proc"]
    if proc.poll() is None:
      if timed_out:
        kill_group(proc)
      else:
        try:
          proc.wait(timeout=max(0.1, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
          timed_out = True
          kill_group(proc)
    for pipe in (proc.stdout, proc.stderr):
      try:
        pipe.close()
      except OSError:
        pass
    if proc in _children:
      _children.remove(proc)
    results.append({
      "rc": proc.returncode,
      "out": bytes(run["out"]),
      "err": clean(run["err"].decode("utf-8", "replace").replace("Error: ", "", 1), 300),
      "over": run["over"],
      "timeout": timed_out and proc.returncode is not None and proc.returncode < 0 and not run["over"],
    })
  return results


def result_error(result):
  if result["over"]:
    return "response too large"
  if result["timeout"]:
    return "timed out"
  return result["err"] or "incus exited with status %s" % result["rc"]


def parse_json(result):
  if result["rc"] != 0 or result["over"]:
    return None
  try:
    return json.loads(result["out"].decode("utf-8"))
  except (UnicodeDecodeError, ValueError):
    return None


def is_forbidden(message):
  text = message.lower()
  return any(word in text for word in ("forbidden", "not authorized", "restricted", "not allowed", "permission"))


def is_unreachable(message):
  text = message.lower()
  return any(word in text for word in (
    "connection refused", "no route", "timed out", "i/o timeout", "unreachable",
    "no such host", "connect:", "eof", "tls", "certificate", "unix.socket",
  ))


def query_argv(incus, remote, path):
  return [incus, "query", "--", "%s:%s" % (remote, path)]


def check_name(value, pattern, what):
  if not isinstance(value, str) or not pattern.fullmatch(value) or value in (".", ".."):
    fail("invalid %s" % what)
  return value


# probe

def cmd_probe(incus):
  if incus is None:
    emit({"ok": True, "incus": "", "version": ""})
    return
  [result] = run_many([[incus, "version"]], 10, 4096)
  version = ""
  if result["rc"] == 0:
    for line in result["out"].decode("utf-8", "replace").splitlines():
      if line.lower().startswith("client version:"):
        version = clean(line.split(":", 1)[1], 40)
  emit({"ok": True, "incus": incus, "version": version})


# remotes

LOCAL_SOCKETS = (
  "/var/lib/incus/unix.socket",
  "/run/incus/unix.socket",
  "/var/lib/incus/unix.socket.user",
)


def local_socket_present():
  for path in LOCAL_SOCKETS:
    try:
      if stat.S_ISSOCK(os.stat(path).st_mode):
        return True
    except OSError:
      continue
  return False


def cmd_remotes(incus):
  results = run_many([
    [incus, "remote", "list", "--format", "json"],
    [incus, "remote", "get-default"],
  ], QUERY_TIMEOUT, 256 * 1024)
  listing = parse_json(results[0])
  if not isinstance(listing, dict):
    fail(result_error(results[0]))
  default = ""
  if results[1]["rc"] == 0:
    default = clean(results[1]["out"].decode("utf-8", "replace"), 63)

  remotes = []
  for name in sorted(listing):
    if len(remotes) >= MAX_REMOTES:
      break
    conf = as_dict(listing[name])
    if not NAME_RE.fullmatch(str(name)):
      continue
    protocol = clean(conf.get("Protocol") or conf.get("protocol") or "incus", 20)
    if protocol != "incus":
      continue  # image servers have nothing to watch
    addrs = as_list(conf.get("Addrs"))
    addr = clean(conf.get("Addr") or conf.get("addr") or (addrs[0] if addrs else "") or conf.get("LastWorkingAddr") or "", 200)
    local = addr == "" or addr.startswith("unix:")
    project = clean(conf.get("Project") or conf.get("project") or "", 63)
    if project != "" and not NAME_RE.fullmatch(project):
      project = ""
    remotes.append({
      "name": name,
      "addr": addr if addr.startswith("https://") else "",
      "local": local,
      "present": local_socket_present() if local else True,
      "project": project,
      "authType": clean(conf.get("AuthType") or conf.get("auth_type") or "", 20),
    })
  emit({"ok": True, "default": default if NAME_RE.fullmatch(default or "-") else "", "remotes": remotes})


# snapshot

def parse_time(value):
  text = clean(value, 64)
  # Incus reports a zero time as year 0001 for "never".
  if text == "" or text.startswith("0001-"):
    return ""
  return text


def compact_snapshots(items):
  newest = ""
  count = 0
  for item in as_list(items):
    item = as_dict(item)
    count += 1
    created = parse_time(item.get("created_at"))
    if created > newest:
      newest = created
  return count, newest


def compact_instance(raw):
  raw = as_dict(raw)
  name = raw.get("name")
  project = raw.get("project") or "default"
  if not isinstance(name, str) or not INSTANCE_RE.fullmatch(name):
    return None
  if not isinstance(project, str) or not NAME_RE.fullmatch(project):
    return None
  config = as_dict(raw.get("config"))
  state = as_dict(raw.get("state"))
  cpu = as_dict(state.get("cpu"))
  memory = as_dict(state.get("memory"))

  ipv4 = []
  ipv6 = []
  rx = 0
  tx = 0
  # Incus-managed NICs have a host-side interface; bridges made inside the
  # instance (Docker's, say) don't. List the Incus ones' addresses first.
  nics = sorted(as_dict(state.get("network")).items(), key=lambda item: not as_dict(item[1]).get("host_name"))
  for nic_name, nic in nics:
    nic = as_dict(nic)
    if nic_name == "lo" or clean(nic.get("type"), 20) == "loopback":
      continue
    counters = as_dict(nic.get("counters"))
    rx += number(counters.get("bytes_received")) or 0
    tx += number(counters.get("bytes_sent")) or 0
    for address in as_list(nic.get("addresses")):
      address = as_dict(address)
      value = address.get("address")
      if address.get("scope") != "global" or not isinstance(value, str) or not ADDRESS_RE.fullmatch(value):
        continue
      family = address.get("family")
      if family == "inet" and len(ipv4) < MAX_ADDRESSES:
        ipv4.append(value)
      elif family == "inet6" and len(ipv6) < MAX_ADDRESSES:
        ipv6.append(value)

  disks = as_dict(state.get("disk"))
  root = as_dict(disks.get("root"))
  disk_usage = number(root.get("usage"))
  disk_total = number(root.get("total"))

  ports = []
  for device in as_dict(raw.get("expanded_devices")).values():
    device = as_dict(device)
    if device.get("type") == "proxy" and len(ports) < MAX_PORTS:
      listen = clean(device.get("listen"), 80)
      if listen:
        ports.append(listen)

  profiles = [clean(p, 63) for p in as_list(raw.get("profiles"))[:MAX_PROFILES] if isinstance(p, str)]
  snapshot_count, snapshot_newest = compact_snapshots(raw.get("snapshots"))
  backup_count, backup_newest = compact_snapshots(raw.get("backups"))
  status = clean(raw.get("status") or state.get("status"), 20)
  kind = "vm" if raw.get("type") == "virtual-machine" else "container"
  processes = number(state.get("processes"))
  location = clean(raw.get("location"), 63)

  return {
    "name": name,
    "project": project,
    "type": kind,
    "status": status,
    "location": "" if location == "none" else location,
    "description": clean(raw.get("description")),
    "createdAt": parse_time(raw.get("created_at")),
    "lastUsedAt": parse_time(raw.get("last_used_at")),
    "startedAt": parse_time(state.get("started_at")),
    "ipv4": ipv4,
    "ipv6": ipv6,
    "rx": rx,
    "tx": tx,
    "cpuUsage": number(cpu.get("usage")),
    "cpuAllocated": number(cpu.get("allocated_time")),
    "memUsage": number(memory.get("usage")),
    "memTotal": number(memory.get("total")),
    "diskUsage": disk_usage,
    "diskTotal": disk_total,
    "processes": processes if processes is not None else -1,
    "limitsCpu": clean(config.get("limits.cpu"), 40),
    "limitsMemory": clean(config.get("limits.memory"), 40),
    "imageOs": clean(config.get("image.os"), 40),
    "imageRelease": clean(config.get("image.release"), 40),
    "imageSerial": clean(config.get("image.serial"), 40),
    "imageDescription": clean(config.get("image.description"), 80),
    "autostart": clean(config.get("boot.autostart"), 10) == "true",
    "snapshotSchedule": clean(config.get("snapshots.schedule"), 80),
    "snapshots": snapshot_count,
    "newestSnapshot": snapshot_newest,
    "backups": backup_count,
    "newestBackup": backup_newest,
    "profiles": profiles,
    "ports": ports,
  }


def compact_pool(raw, resources):
  raw = as_dict(raw)
  name = raw.get("name")
  if not isinstance(name, str) or not NAME_RE.fullmatch(name):
    return None
  space = as_dict(as_dict(resources).get("space"))
  return {
    "name": name,
    "driver": clean(raw.get("driver"), 20),
    "status": clean(raw.get("status"), 20),
    "used": number(space.get("used")),
    "total": number(space.get("total")),
  }


def compact_warning(raw):
  raw = as_dict(raw)
  status = clean(raw.get("status"), 20).lower()
  if status != "new":
    return None
  return {
    "type": clean(raw.get("type"), 80),
    "severity": clean(raw.get("severity"), 20).lower(),
    "message": clean(raw.get("last_message"), 300),
    "count": number(raw.get("count")) or 1,
    "project": clean(raw.get("project"), 63),
    "location": clean(raw.get("location"), 63),
    "lastSeen": parse_time(raw.get("last_seen_at")),
  }


def compact_member(raw):
  raw = as_dict(raw)
  name = raw.get("server_name")
  if not isinstance(name, str) or not NAME_RE.fullmatch(name):
    return None
  return {
    "name": name,
    "status": clean(raw.get("status"), 20),
    "message": clean(raw.get("message"), 200),
    "roles": [clean(r, 30) for r in as_list(raw.get("roles"))[:8] if isinstance(r, str)],
  }


def operation_progress(metadata):
  metadata = as_dict(metadata)
  for key, value in metadata.items():
    if isinstance(value, dict):
      percent = number(value.get("percent"))
      if percent is not None:
        return min(100, percent), clean(value.get("stage") or key, 60)
    elif isinstance(value, str) and "progress" in key and len(value) < 120:
      return None, clean(value, 80)
  return None, ""


def compact_operation(raw):
  raw = as_dict(raw)
  op_id = raw.get("id")
  if not isinstance(op_id, str) or not OPERATION_ID_RE.fullmatch(op_id):
    return None
  status = clean(raw.get("status"), 20)
  if status not in ("Running", "Pending"):
    return None
  if clean(raw.get("class"), 20) == "websocket":
    return None  # an open console or exec session, not a task
  percent, stage = operation_progress(raw.get("metadata"))
  return {
    "id": op_id,
    "description": clean(raw.get("description"), 120),
    "status": status,
    "percent": percent,
    "stage": stage,
    "createdAt": parse_time(raw.get("created_at")),
  }


def compact_host(server, resources):
  env = as_dict(as_dict(server).get("environment"))
  resources = as_dict(resources)
  cpu = as_dict(resources.get("cpu"))
  memory = as_dict(resources.get("memory"))
  load = as_dict(resources.get("load"))
  return {
    "name": clean(env.get("server_name"), 63),
    "version": clean(env.get("server_version"), 40),
    "clustered": env.get("server_clustered") is True,
    "cpuThreads": number(cpu.get("total")),
    "memUsed": number(memory.get("used")),
    "memTotal": number(memory.get("total")),
    "load1": number(load.get("average_1min", load.get("Average1Min"))),
    "load5": number(load.get("average_5min", load.get("Average5Min"))),
  }


def instances_from(doc):
  instances = []
  for raw in as_list(doc):
    if len(instances) >= MAX_INSTANCES:
      break
    item = compact_instance(raw)
    if item is not None:
      instances.append(item)
  return instances


def cmd_snapshot(incus, remote, project, instances_only):
  remote = check_name(remote, NAME_RE, "remote")
  if project != "":
    project = check_name(project, NAME_RE, "project")

  paths = ["/1.0/instances?recursion=2&all-projects=true"]
  if not instances_only:
    paths += [
      "/1.0",
      "/1.0/resources",
      "/1.0/storage-pools?recursion=1",
      "/1.0/warnings?recursion=1",
      "/1.0/operations?recursion=1&all-projects=true",
    ]
  results = run_many([query_argv(incus, remote, p) for p in paths], QUERY_TIMEOUT)
  docs = [parse_json(r) for r in results]

  instances_doc = docs[0]
  scope = "all"
  if not isinstance(instances_doc, list):
    message = result_error(results[0])
    if not is_forbidden(message):
      emit({"ok": False, "unreachable": is_unreachable(message), "error": message})
      return
    # A restricted certificate cannot list every project; fall back to the
    # remote's own project.
    scope = project or "default"
    [retry] = run_many([query_argv(incus, remote, "/1.0/instances?recursion=2&project=" + scope)], QUERY_TIMEOUT)
    instances_doc = parse_json(retry)
    if not isinstance(instances_doc, list):
      message = result_error(retry)
      emit({"ok": False, "unreachable": is_unreachable(message), "error": message})
      return

  doc = {"ok": True, "remote": remote, "scope": scope, "takenAt": time.time(), "instances": instances_from(instances_doc)}
  if instances_only:
    emit(doc)
    return

  server, resources, pools_doc, warnings_doc, operations_doc = docs[1:]
  host = compact_host(server, resources)

  members = []
  pool_list = [p for p in as_list(pools_doc)[:MAX_POOLS] if isinstance(as_dict(p).get("name"), str) and NAME_RE.fullmatch(as_dict(p)["name"])]
  extra = [query_argv(incus, remote, "/1.0/storage-pools/%s/resources" % as_dict(p)["name"]) for p in pool_list]
  if host["clustered"]:
    extra.append(query_argv(incus, remote, "/1.0/cluster/members?recursion=1"))
  extra_results = run_many(extra, QUERY_TIMEOUT) if extra else []

  pools = []
  for raw, result in zip(pool_list, extra_results):
    item = compact_pool(raw, parse_json(result))
    if item is not None:
      pools.append(item)
  if host["clustered"] and extra_results:
    for raw in as_list(parse_json(extra_results[-1]))[:MAX_MEMBERS]:
      item = compact_member(raw)
      if item is not None:
        members.append(item)

  warnings = []
  for raw in as_list(warnings_doc):
    item = compact_warning(raw)
    if item is not None:
      warnings.append(item)
  warnings.sort(key=lambda w: w["lastSeen"], reverse=True)

  operations = []
  for raw in as_list(operations_doc) if isinstance(operations_doc, list) else []:
    if len(operations) >= MAX_OPERATIONS:
      break
    item = compact_operation(raw)
    if item is not None:
      operations.append(item)

  doc.update({
    "host": host,
    "pools": pools,
    "warnings": warnings[:MAX_WARNINGS],
    "warningCount": len(warnings),
    "members": members,
    "operations": operations,
  })
  emit(doc)


# monitor

def compact_event(raw):
  raw = as_dict(raw)
  kind = raw.get("type")
  project = clean(raw.get("project"), 63)
  metadata = as_dict(raw.get("metadata"))
  if kind == "lifecycle":
    action = metadata.get("action")
    if not isinstance(action, str) or not EVENT_ACTION_RE.fullmatch(action):
      return None
    source = clean(metadata.get("source"), 300)
    name = ""
    match = re.match(r"/1\.0/instances/([A-Za-z0-9-]{1,63})(?:/|\?|$)", source)
    if match:
      name = match.group(1)
    requestor = as_dict(metadata.get("requestor"))
    return {
      "t": "life",
      "action": action,
      "name": name,
      "project": project if NAME_RE.fullmatch(project or "-") else "",
      "user": clean(requestor.get("username"), 80),
      "protocol": clean(requestor.get("protocol"), 20),
      "location": clean(raw.get("location"), 63),
    }
  if kind == "operation":
    item = compact_operation(metadata)
    status = clean(metadata.get("status"), 20)
    op_id = metadata.get("id")
    if item is None:
      if isinstance(op_id, str) and OPERATION_ID_RE.fullmatch(op_id):
        return {"t": "opdone", "id": op_id, "status": status}
      return None
    item["t"] = "op"
    return item
  return None


def cmd_monitor(incus, remote):
  remote = check_name(remote, NAME_RE, "remote")
  base = [incus, "monitor", "--type=lifecycle", "--type=operation", "--format=json"]
  attempts = [base + ["--all-projects", "--", remote + ":"], base + ["--", remote + ":"]]
  last_error = ""
  for argv in attempts:
    started = time.monotonic()
    proc = subprocess.Popen(
      argv,
      stdin=subprocess.DEVNULL,
      stdout=subprocess.PIPE,
      stderr=subprocess.PIPE,
      start_new_session=True,
      preexec_fn=child_setup,
      env=child_env(),
    )
    _children.append(proc)
    emit({"t": "up"})
    buffer = bytearray()
    err = bytearray()
    dropping = False
    last_op_emit = {}
    fds = {proc.stdout.fileno(): "out", proc.stderr.fileno(): "err"}
    while fds:
      ready, _, _ = select.select(list(fds), [], [])
      for fd in ready:
        chunk = os.read(fd, 65536)
        if not chunk:
          del fds[fd]
          continue
        if fds[fd] == "err":
          room = STDERR_CAP - len(err)
          if room > 0:
            err += chunk[:room]
          continue
        buffer += chunk
        while True:
          cut = buffer.find(b"\n")
          if cut < 0:
            if len(buffer) > EVENT_LINE_CAP:
              # An oversized event: drop it, and have the shell re-read state.
              buffer.clear()
              dropping = True
              emit({"t": "resync"})
            break
          line = bytes(buffer[:cut])
          del buffer[:cut + 1]
          if dropping:
            dropping = False
            continue
          if not line.strip():
            continue
          try:
            event = compact_event(json.loads(line.decode("utf-8")))
          except (UnicodeDecodeError, ValueError):
            continue
          if event is None:
            continue
          if event["t"] == "op":
            # Progress updates arrive many times a second during a download.
            now = time.monotonic()
            if now - last_op_emit.get(event["id"], 0) < 0.5:
              continue
            last_op_emit[event["id"]] = now
            if len(last_op_emit) > 256:
              last_op_emit.clear()
          emit(event)
    proc.wait()
    _children.remove(proc)
    last_error = clean(err.decode("utf-8", "replace").replace("Error: ", "", 1), 300)
    # Restricted certificates refuse --all-projects at once; retry without it.
    if time.monotonic() - started < 10 and is_forbidden(last_error) and argv is attempts[0]:
      continue
    break
  emit({"t": "down", "unreachable": is_unreachable(last_error), "error": last_error or "monitor stopped"})
  sys.exit(1)


# action

def cmd_action(incus, verb, remote, project, name):
  if verb not in ACTIONS:
    fail("unknown action")
  remote = check_name(remote, NAME_RE, "remote")
  project = check_name(project, NAME_RE, "project")
  name = check_name(name, INSTANCE_RE, "instance")
  argv = [incus] + ACTIONS[verb] + ["--project", project, "--", "%s:%s" % (remote, name)]
  [result] = run_many([argv], ACTION_TIMEOUT, 64 * 1024)
  if result["rc"] == 0:
    emit({"ok": True})
  else:
    emit({"ok": False, "error": result_error(result)})


# add-remote
#
# Runs in a terminal, not under the shell. The token is read without echo and
# reaches incus on stdin, never in an argv where other local users could read
# it. A token carries the server's certificate fingerprint; incus checks it
# only when the token is its argument, so the matching certificate is pinned
# here first, the way incus pins it itself, and incus then connects with it
# and asks for the token.

def incus_config_dir():
  if os.environ.get("INCUS_CONF"):
    return os.environ["INCUS_CONF"]
  base = os.environ.get("XDG_CONFIG_HOME", "")
  if not os.path.isabs(base):
    base = os.path.join(pwd.getpwuid(os.geteuid()).pw_dir, ".config")
  return os.path.join(base, "incus")


def decode_token(token):
  import base64
  try:
    doc = json.loads(base64.b64decode(token, validate=True))
  except ValueError:
    return None
  doc = as_dict(doc)
  addrs = [a for a in as_list(doc.get("addresses")) if isinstance(a, str) and ADDRESS_PORT_RE.fullmatch(a)]
  fingerprint = doc.get("fingerprint")
  if not addrs or not doc.get("secret") or not isinstance(fingerprint, str) or not FINGERPRINT_RE.fullmatch(fingerprint):
    return None
  return addrs, fingerprint


def server_certificate(addr):
  import ssl
  import urllib.parse
  url = urllib.parse.urlsplit("https://" + addr)
  try:
    pem = ssl.get_server_certificate((url.hostname, url.port or 8443), timeout=10)
  except (OSError, ValueError):
    return None
  return pem


def cmd_add_remote(incus):
  import getpass
  import hashlib
  import ssl
  signal.signal(signal.SIGINT, signal.default_int_handler)
  pinned = None
  try:
    name = input("Server name (e.g. homelab): ").strip()
    if not NAME_RE.fullmatch(name) or name in (".", ".."):
      print("Use letters, digits, dots, dashes and underscores.")
      return 1
    [listing] = run_many([[incus, "remote", "list", "--format", "json"]], QUERY_TIMEOUT, 256 * 1024)
    listing = parse_json(listing)
    if not isinstance(listing, dict):
      print("Couldn't read the incus remotes.")
      return 1
    if name in listing:
      print("A remote named %s already exists." % name)
      return 1

    token = getpass.getpass("Trust token (hidden): ").strip()
    decoded = decode_token(token)
    if decoded is None:
      print("That isn't an Incus trust token. Create one on the server with: incus config trust add <name>")
      return 1
    addrs, fingerprint = decoded

    pem = None
    for addr in addrs:
      pem = server_certificate(addr)
      if pem is not None:
        break
    if pem is None:
      print("Couldn't reach the server at %s." % ", ".join(addrs))
      return 1
    if hashlib.sha256(ssl.PEM_cert_to_DER_cert(pem)).hexdigest() != fingerprint.lower():
      print("The server's certificate doesn't match the token. Not adding it.")
      return 1

    certs = os.path.join(incus_config_dir(), "servercerts")
    os.makedirs(certs, 0o750, exist_ok=True)
    path = os.path.join(certs, name + ".crt")
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644), "w") as f:
      pinned = path
      f.write(pem)

    argv = [incus, "remote", "add", name] + ["https://" + a for a in addrs]
    rc = subprocess.run(argv, input=token + "\n", text=True, env=child_env()).returncode
    if rc == 0:
      pinned = None
    print()
    return rc
  except (KeyboardInterrupt, EOFError):
    print()
    return 130
  finally:
    # Drop the pin if incus didn't add the remote.
    if pinned is not None:
      try:
        os.unlink(pinned)
      except OSError:
        pass


def main(argv):
  load_libc()
  die_with_parent()
  signal.signal(signal.SIGTERM, on_term)
  signal.signal(signal.SIGINT, on_term)

  requested = ""
  if len(argv) >= 2 and argv[0] == "--incus":
    requested = argv[1]
    argv = argv[2:]
  if not argv:
    fail("missing command")
  command, args = argv[0], argv[1:]

  incus = find_incus(requested)
  if command == "probe":
    cmd_probe(incus)
    return
  if incus is None:
    fail("incus not found")
  if command == "remotes" and not args:
    cmd_remotes(incus)
  elif command == "snapshot" and len(args) in (2, 3):
    if len(args) == 3 and args[2] != "--instances-only":
      fail("bad arguments")
    cmd_snapshot(incus, args[0], args[1], len(args) == 3)
  elif command == "monitor" and len(args) == 1:
    cmd_monitor(incus, args[0])
  elif command == "action" and len(args) == 4:
    cmd_action(incus, *args)
  elif command == "add-remote" and not args:
    sys.exit(cmd_add_remote(incus))
  else:
    fail("bad arguments")


if __name__ == "__main__":
  try:
    main(sys.argv[1:])
  except BrokenPipeError:
    os._exit(0)
