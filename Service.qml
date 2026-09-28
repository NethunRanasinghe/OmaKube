import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Data owner for the OmaKube popup. Talks to `bin/omakube` (Go + client-go)
// via short-lived Process calls — same pattern as the native tailscale /
// dropbox panels. No daemon, no socket, no polling loops against the API
// beyond the refresh interval; unreachable clusters back off automatically.
Item {
  id: root

  property var settings: ({})
  // Panel.qml injects persistSettings so Service stays bar-agnostic:
  // function persist(patch) — merges patch into the shell.json entry.
  property var persistFn: null

  // ---- context state ----
  property var contexts: []
  property string activeContextName: ""
  property string activeNamespace: "default"
  property string healthStatus: "unknown" // healthy | degraded | down | unknown
  property string contextAccent: "#52a8ff"
  property bool refreshing: false
  property bool warmedUp: false
  property string lastError: ""
  property string lastErrorKind: ""
  property string actionStatus: ""
  property double apiLatencyMs: -1

  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 30, 5, 3600)
  readonly property string defaultNamespace: String(setting("defaultNamespace", "") || "")
  readonly property bool readOnly: setting("readOnly", false) === true
  readonly property string kubeconfigPath: String(setting("kubeconfigPath", "") || "")
  readonly property bool debugLogging: setting("debugLogging", false) === true
  readonly property bool busy: contextsProcess.running || healthProcess.running || useProcess.running

  readonly property string cliPath: (Quickshell.env("HOME") || "") + "/.config/omarchy/plugins/omakube/bin/omakube"

  function setting(name, fallback) {
    var v = settings ? settings[name] : undefined
    return v === undefined || v === null ? fallback : v
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  function kubeconfigArgs() {
    return kubeconfigPath !== "" ? ["--kubeconfig", kubeconfigPath] : []
  }

  function persist(patch) {
    if (typeof persistFn === "function") persistFn(patch)
  }

  function restoreNamespace(ctxName, fallbackNs) {
    var perCtx = setting("namespaces", null)
    if (perCtx && typeof perCtx === "object" && perCtx[String(ctxName)]) {
      var s = String(perCtx[String(ctxName)])
      if (s !== "" && s !== "undefined") return s
    }
    if (defaultNamespace !== "") return defaultNamespace
    return "default"
  }

  function accentFor(name) {
    var saved = setting("accents", null)
    if (saved && typeof saved === "object" && saved[String(name)]) return String(saved[String(name)])
    return Model.defaultAccent(name)
  }

  function cycleAccent(name) {
    var next = Model.nextAccent(accentFor(name))
    var saved = setting("accents", null)
    var copy = {}
    if (saved && typeof saved === "object") for (var k in saved) copy[k] = saved[k]
    copy[String(name)] = next
    persist({ accents: copy })
    applyAccentToContexts(String(name), next)
    if (String(name) === activeContextName) contextAccent = next
    actionStatus = String(name) + " accent → " + next
    statusTimer.restart()
  }

  function applyAccentToContexts(name, accent) {
    var a = contexts.slice()
    for (var i = 0; i < a.length; i++) {
      if (String(a[i].name) === name) {
        var c = copyCtx(a[i])
        c.accent = accent
        a[i] = c
      }
    }
    contexts = a
  }

  function copyCtx(c) {
    var o = {}
    for (var k in c) o[k] = c[k]
    return o
  }

  function activeContext() {
    for (var i = 0; i < contexts.length; i++) {
      if (String(contexts[i].name) === activeContextName) return contexts[i]
    }
    return contexts.length > 0 ? contexts[0] : null
  }

  function heroDetail() {
    var ctx = activeContext()
    if (!ctx || !ctx.healthChecked) return ""
    var parts = []
    if (ctx.nodesVisible && ctx.nodesTotal > 0) parts.push(ctx.nodesReady + "/" + ctx.nodesTotal + " nodes")
    if (ctx.podsTotal > 0) parts.push(ctx.podsTotal + " pods")
    else if (ctx.health === "healthy") parts.push("no pods")
    if (ctx.latencyMs >= 0) parts.push(ctx.latencyMs + "ms")
    if (ctx.health === "degraded" && ctx.summary) parts.push(String(ctx.summary))
    return parts.join(" · ")
  }

  // ---- refresh pipeline: contexts (local file) → health(active) → health(rest) ----
  property var _healthQueue: []
  property bool _forceHealth: false
  property bool _popupOpen: false

  function setPopupOpen(open) {
    _popupOpen = open === true
    if (_popupOpen && activeContextName !== "") {
      if (!workloadsFresh || namespaces.length === 0) fetchData()
    }
  }

  function refresh(force) {
    if (busy) return
    _forceHealth = force === true
    refreshing = true
    lastError = ""
    lastErrorKind = ""
    contextsProcess.command = [cliPath, "contexts", "--json"].concat(kubeconfigArgs())
    contextsProcess.running = true
  }

  function parseContexts(stdout, stderr) {
    var data = null
    try { data = JSON.parse(stdout) } catch (e) { data = null }
    if (!data || !(data.contexts instanceof Array)) {
      lastError = Model.humanError(stderr) || "Could not read kubeconfig" + (cliPath !== "" ? " (" + cliPath + ")" : "")
      lastErrorKind = "unknown"
      refreshing = false
      warmedUp = true
      return
    }
    // Preserve cached health across refreshes.
    var cache = {}
    for (var i = 0; i < contexts.length; i++) cache[String(contexts[i].name)] = contexts[i]
    var next = []
    for (var j = 0; j < data.contexts.length; j++) {
      var src = data.contexts[j]
      var name = String(src.name || "")
      var old = cache[name] || {}
      next.push({
        name: name,
        host: String(src.host || ""),
        auth: String(src.auth || ""),
        ns: String(src.namespace || "default"),
        shortLabel: Model.shortLabel(name),
        accent: accentFor(name),
        health: old.health || "unknown",
        healthChecked: old.healthChecked === true,
        healthDetail: old.healthDetail || "",
        summary: old.summary || "",
        latencyMs: old.latencyMs !== undefined ? old.latencyMs : -1,
        nodesTotal: old.nodesTotal || 0,
        nodesReady: old.nodesReady || 0,
        nodesVisible: old.nodesVisible === true,
        podsTotal: old.podsTotal || 0,
        podsFailed: old.podsFailed || 0,
        podsNotReady: old.podsNotReady || 0,
        podsPending: old.podsPending || 0,
        restarts: old.restarts || 0,
        error: old.error || "",
        errorKind: old.errorKind || "",
        failCount: old.failCount || 0,
        lastFailAt: old.lastFailAt || 0
      })
    }
    contexts = next

    // Resolve active: remembered > kubeconfig current > first.
    var remembered = String(setting("lastContext", "") || "")
    var current = String(data.current || "")
    var pick = ""
    for (var k = 0; k < next.length; k++) {
      if (String(next[k].name) === remembered) { pick = remembered; break }
    }
    if (pick === "") {
      for (var m = 0; m < next.length; m++) {
        if (String(next[m].name) === current) { pick = current; break }
      }
    }
    if (pick === "" && next.length > 0) pick = String(next[0].name)
    if (pick !== "" && pick !== activeContextName) {
      activeContextName = pick
      workloadsFresh = false
      expandedKey = ""
      var act = activeContext()
      if (act) {
        contextAccent = String(act.accent)
        activeNamespace = restoreNamespace(pick, act.ns)
      }
      fetchData()
    } else if (pick !== "") {
      var act2 = activeContext()
      if (act2) contextAccent = String(act2.accent)
      if (!workloadsFresh) fetchData()
    }
    if (contexts.length === 0) {
      lastError = "No contexts in kubeconfig — add one with kubectl first."
      lastErrorKind = "unknown"
      refreshing = false
      warmedUp = true
      return
    }

    // Queue: active first, then the rest (others only when popup open,
    // unless forced). Backoff skips repeatedly-unreachable clusters.
    _healthQueue = []
    var now = Date.now()
    for (var a = 0; a < next.length; a++) {
      if (String(next[a].name) === activeContextName) _healthQueue.push(String(next[a].name))
    }
    for (var b = 0; b < next.length; b++) {
      var nm = String(next[b].name)
      if (nm === activeContextName) continue
      if (!_popupOpen && !_forceHealth) continue
      var e = cache[nm] || {}
      if (!_forceHealth && (e.failCount || 0) >= 2 && (now - (e.lastFailAt || 0)) < 120000) continue
      _healthQueue.push(nm)
    }
    pumpHealth()
  }

  function pumpHealth() {
    if (_healthQueue.length === 0) {
      refreshing = false
      warmedUp = true
      syncActiveState()
      if (_popupOpen) fetchData()
      return
    }
    var name = _healthQueue[0]
    // health always prints its JSON report; no --json flag.
    healthProcess.command = [cliPath, "health", "--context", name,
      "--namespace", activeNamespace, "--timeout", "8"].concat(kubeconfigArgs())
    healthProcess.running = true
  }

  function parseHealth(stdout, stderr) {
    var name = _healthQueue.length > 0 ? _healthQueue.shift() : ""
    var rep = null
    try { rep = JSON.parse(stdout) } catch (e) { rep = null }
    var idx = -1
    for (var i = 0; i < contexts.length; i++) {
      if (String(contexts[i].name) === name) { idx = i; break }
    }
    if (idx >= 0) {
      var c = copyCtx(contexts[idx])
      if (rep && String(rep.context) === name) {
        var failing = (rep.podsFailed || 0) + (rep.podsNotReady || 0)
        c.health = String(rep.status || "unknown")
        c.healthChecked = true
        c.latencyMs = rep.latencyMs !== undefined ? rep.latencyMs : -1
        c.nodesTotal = rep.nodesTotal || 0
        c.nodesReady = rep.nodesReady || 0
        c.nodesVisible = rep.nodesVisible === true
        c.podsTotal = rep.podsTotal || 0
        c.podsFailed = rep.podsFailed || 0
        c.podsNotReady = rep.podsNotReady || 0
        c.podsPending = rep.podsPending || 0
        c.restarts = rep.restarts || 0
        c.summary = String(rep.summary || "")
        c.error = String(rep.error || "")
        c.errorKind = String(rep.errorKind || "")
        var bits = []
        if (c.nodesVisible && c.nodesTotal > 0) bits.push(c.nodesReady + "/" + c.nodesTotal + " nodes")
        if (failing > 0) bits.push(failing + " failing")
        else if (c.podsPending > 0) bits.push(c.podsPending + " pending")
        else if (c.podsTotal > 0) bits.push(c.podsTotal + " pods")
        c.healthDetail = bits.join(" · ")
        if (c.errorKind !== "" && c.errorKind !== "forbidden") {
          c.failCount = (c.failCount || 0) + 1
          c.lastFailAt = Date.now()
        } else {
          c.failCount = 0
          c.lastFailAt = 0
        }
      } else {
        c.health = "down"
        c.healthChecked = true
        c.healthDetail = ""
        c.error = String(stderr || "health check failed")
        c.errorKind = "unknown"
        c.failCount = (c.failCount || 0) + 1
        c.lastFailAt = Date.now()
      }
      var a = contexts.slice()
      a[idx] = c
      contexts = a

      if (String(c.name) === activeContextName) {
        syncActiveState()
        if (_popupOpen && !workloadsFresh && !workloadsLoading) fetchData()
      }
    }
    pumpHealth()
  }

  function syncActiveState() {
    var act = activeContext()
    if (!act) return
    contextAccent = String(act.accent || contextAccent)
    healthStatus = String(act.health || "unknown")
    apiLatencyMs = act.latencyMs !== undefined ? act.latencyMs : -1
    if (String(act.name) === activeContextName && act.healthChecked) {
      if (act.errorKind !== "" && act.errorKind !== "forbidden") {
        lastError = act.error
        lastErrorKind = act.errorKind
      }
    }
  }

  function setContext(name) {
    var target = String(name || "")
    if (target === "" || useProcess.running) return
    if (target === activeContextName) {
      refresh(true)
      return
    }
    actionStatus = "Switching to " + target + "…"
    workloadsFresh = false
    workloadsLoading = true
    workloads = emptyWorkloads()
    namespaces = []
    events = []
    expandedKey = ""
    logPod = ""
    logContainer = ""
    logContainers = []
    logLines = []
    useProcess.command = [cliPath, "use-context", target].concat(kubeconfigArgs())
    useProcess.running = true
  }

  function parseUseContext(stdout, stderr, exitCode) {
    if (exitCode !== 0) {
      lastError = Model.humanError(stderr) || ("Could not switch context (" + stderr + ")")
      lastErrorKind = "unknown"
      actionStatus = ""
      return
    }
    var data = null
    try { data = JSON.parse(stdout) } catch (e) { data = null }
    var current = data && data.current ? String(data.current) : ""
    if (current !== "") {
      activeContextName = current
      workloadsFresh = false
      workloadsLoading = true
      workloads = emptyWorkloads()
      namespaces = []
      namespacesLoading = true
      events = []
      expandedKey = ""
      logPod = ""
      logContainer = ""
      logContainers = []
      logLines = []
      persist({ lastContext: current })
      var act = activeContext()
      if (act) {
        contextAccent = String(act.accent)
        activeNamespace = restoreNamespace(current, act.ns)
      }
      actionStatus = "Switched to " + current
      statusTimer.restart()
      fetchData()
      refresh(true)
    }
  }

  function setNamespace(ns) {
    var target = String(ns || defaultNamespace || "default")
    if (target === activeNamespace && workloadsFresh) {
      fetchWorkloads()
      return
    }
    activeNamespace = target
    workloadsFresh = false
    workloadsLoading = true
    workloads = emptyWorkloads()
    events = []
    expandedKey = ""
    logPod = ""
    logContainer = ""
    logContainers = []
    logLines = []
    var perCtx = setting("namespaces", null)
    var copy = {}
    if (perCtx && typeof perCtx === "object") for (var k in perCtx) copy[k] = perCtx[k]
    copy[activeContextName] = target
    persist({ namespaces: copy })
    actionStatus = "Namespace: " + target
    statusTimer.restart()
    fetchWorkloads()
  }

  function emptyWorkloads() {
    return { pods: [], deployments: [], statefulsets: [], daemonsets: [], services: [], jobs: [], ingresses: [], configmaps: [], secrets: [], pvc: [] }
  }

  // ---- workloads + namespaces (step 3) ----
  property var namespaces: []
  property bool namespacesLoading: false
  property var workloads: emptyWorkloads()
  property bool workloadsLoading: false
  property bool workloadsFresh: false
  property string workloadsError: ""
  property string expandedKey: ""
  property string wlContext: ""
  property string wlNamespace: ""

  function fetchData() {
    fetchNamespaces()
    fetchWorkloads()
  }

  // ---- events (step 4) ----
  property var events: []
  property bool eventsLoading: false

  function fetchEvents() {
    if (evProcess.running || activeContextName === "") return
    eventsLoading = true
    events = []
    var cmd = [cliPath, "events", "--context", activeContextName]
    if (activeNamespace === "*" || activeNamespace === "" || activeNamespace === "all") {
      cmd.push("--all-namespaces")
    } else {
      cmd.push("--namespace", activeNamespace)
    }
    cmd.push("--timeout", "8")
    evProcess.command = cmd.concat(kubeconfigArgs())
    evProcess.running = true
  }

  function parseEvents(stdout, stderr, exitCode) {
    eventsLoading = false
    var data = null
    try { data = JSON.parse(stdout) } catch (e) { data = null }
    if (data && data.events instanceof Array) events = data.events
    else events = []
  }

  // ---- logs (step 4) ----
  property string logPod: ""
  property string logContainer: ""
  property var logContainers: []
  property var logLines: []
  property bool logsLoading: false
  property bool logFollow: true
  property string _exportTarget: ""

  function setLogPod(pod) {
    logPod = String(pod || "")
    logContainer = ""
    logContainers = []
    logLines = []
    fetchLogs()
  }

  function setLogContainer(c) {
    logContainer = String(c || "")
    fetchLogs()
  }

  function fetchLogs() {
    if (logProcess.running || activeContextName === "" || logPod === "") return
    logsLoading = true
    var ns = (activeNamespace === "*" || activeNamespace === "" || activeNamespace === "all") ? "default" : activeNamespace
    var pods = (workloads && workloads.pods) || []
    for (var i = 0; i < pods.length; i++) {
      if (String(pods[i].name) === logPod && pods[i].namespace) {
        ns = String(pods[i].namespace)
        break
      }
    }
    var cmd = [cliPath, "logs", "--context", activeContextName, "--namespace", ns,
      "--pod", logPod, "--tail", "200", "--timeout", "10"]
    if (logContainer !== "") cmd.push("--container", logContainer)
    logProcess.command = cmd.concat(kubeconfigArgs())
    logProcess.running = true
  }

  function parseLogs(stdout, stderr, exitCode) {
    logsLoading = false
    var data = null
    try { data = JSON.parse(stdout) } catch (e) { data = null }
    if (data && data.lines instanceof Array) {
      if (data.containers instanceof Array) logContainers = data.containers
      if (data.container) logContainer = String(data.container)
      logLines = data.lines
    } else {
      lastError = Model.humanError(stderr) || "Could not load logs"
      lastErrorKind = "unknown"
    }
  }

  function exportLogs(dir) {
    if (exProcess.running || logPod === "") return
    var stamp = Qt.formatDateTime(new Date(), "yyyyMMdd-hhmmss")
    var target = (dir !== "" ? dir : Quickshell.env("HOME") + "/omakube-logs")
      + "/omakube-" + activeContextName + "-" + activeNamespace + "-" + logPod
      + (logContainer !== "" ? "-" + logContainer : "") + "-" + stamp + ".txt"
    actionStatus = "Exporting logs…"
    var cmd = [cliPath, "logs", "--context", activeContextName, "--namespace", activeNamespace,
      "--pod", logPod, "--tail", "2000", "--timeout", "15", "--out", target]
    if (logContainer !== "") cmd.push("--container", logContainer)
    exProcess.command = cmd.concat(kubeconfigArgs())
    _exportTarget = target
    exProcess.running = true
  }
  function fetchNamespaces() {
    if (nsProcess.running || activeContextName === "") return
    namespacesLoading = true
    nsProcess.command = [cliPath, "namespaces", "--context", activeContextName, "--timeout", "8"].concat(kubeconfigArgs())
    nsProcess.running = true
  }

  function fetchWorkloads() {
    if (wlProcess.running || activeContextName === "") return
    workloadsLoading = true
    workloadsError = ""
    var cmd = [cliPath, "workloads", "--context", activeContextName]
    if (activeNamespace === "*" || activeNamespace === "" || activeNamespace === "all") {
      cmd.push("--all-namespaces")
    } else {
      cmd.push("--namespace", activeNamespace)
    }
    cmd.push("--timeout", "12")
    wlProcess.command = cmd.concat(kubeconfigArgs())
    wlProcess.running = true
  }

  function parseNamespaces(stdout) {
    namespacesLoading = false
    var data = null
    try { data = JSON.parse(stdout) } catch (e) { data = null }
    if (data && data.namespaces instanceof Array) namespaces = data.namespaces
  }

  function parseWorkloads(stdout, stderr, exitCode) {
    workloadsLoading = false
    var data = null
    try { data = JSON.parse(stdout) } catch (e) { data = null }
    if (data && typeof data === "object") {
      var resNs = String(data.namespace || "")
      if (resNs !== "" && activeNamespace !== "*" && resNs !== activeNamespace) {
        fetchWorkloads()
        return
      }
      var tabs = ["pods", "deployments", "statefulsets", "daemonsets", "services", "jobs", "ingresses", "configmaps", "secrets", "pvc"]
      for (var ti = 0; ti < tabs.length; ti++) {
        if (!(data[tabs[ti]] instanceof Array)) data[tabs[ti]] = []
      }
      workloads = data
      workloadsError = ""
      workloadsFresh = true
      wlContext = activeContextName
      wlNamespace = activeNamespace
    } else {
      workloadsError = Model.humanError(stderr) || "Could not load workloads"
      workloadsFresh = false
    }
  }

  function toggleExpand(key) {
    expandedKey = expandedKey === key ? "" : key
  }

  function tabCount(tab) {
    var w = workloads
    if (tab === "Pods") return w.pods.length
    if (tab === "Deploy") return w.deployments.length
    if (tab === "STS") return w.statefulsets.length
    if (tab === "DS") return w.daemonsets.length
    if (tab === "Svc") return w.services.length
    if (tab === "Jobs") return w.jobs.length
    if (tab === "Events") return events ? events.length : 0
    return 0
  }

  // ---- mutating actions (step 5; all gated on readOnly + confirmation in Panel) ----
  property bool actBusy: false

  function runAction(op, kind, name) {
    if (readOnly) {
      actionStatus = "Read-only mode — action disabled"
      statusTimer.restart()
      return
    }
    if (actProcess.running) return
    var opName = String(op || "")
    var cmd = [cliPath]
    if (opName === "restart") {
      cmd.push("restart", "--context", activeContextName, "--namespace", activeNamespace,
        "--kind", String(kind || "deployment"), "--name", String(name || ""), "--timeout", "15")
    } else if (opName === "delete-pod") {
      cmd.push("delete-pod", "--context", activeContextName, "--namespace", activeNamespace,
        "--name", String(name || ""), "--timeout", "15")
    } else {
      return
    }
    actBusy = true
    actionStatus = "Working…"
    actProcess.command = cmd.concat(kubeconfigArgs())
    actProcess.running = true
  }

  function parseAction(stdout, stderr, exitCode) {
    actBusy = false
    var data = null
    try { data = JSON.parse(stdout) } catch (e) { data = null }
    if (exitCode === 0 && data && data.ok) {
      actionStatus = String(data.message || "Done")
      statusTimer.restart()
      fetchWorkloads()
      refresh(false)
    } else {
      lastError = Model.humanError(stderr) || "Action failed"
      lastErrorKind = "unknown"
      actionStatus = ""
    }
  }

  // ---- port-forwards: ListModel so starting/stopping one never
  // disturbs the others. Panel instantiates one Process per row;
  // setting stopping=false→true SIGTERMs exactly that forward.
  property int _nextFid: 1

  ListModel { id: forwardModel }
  property alias forwards: forwardModel

  function forwardIndex(fid) {
    for (var i = 0; i < forwardModel.count; i++) {
      if (forwardModel.get(i).fid === fid) return i
    }
    return -1
  }

  function startForward(targetKind, target, localPort, remotePort) {
    if (readOnly) {
      actionStatus = "Read-only mode — action disabled"
      statusTimer.restart()
      return
    }
    var tk = String(targetKind || ""), t = String(target || "")
    var rp = parseInt(remotePort, 10), lp = parseInt(localPort, 10)
    if (tk === "" || t === "" || !isFinite(rp) || rp <= 0) {
      actionStatus = "Pick a valid remote port"
      statusTimer.restart()
      return
    }
    if (!isFinite(lp) || lp < 0) lp = 0
    for (var i = 0; i < forwardModel.count; i++) {
      var e = forwardModel.get(i)
      if (e.targetKind === tk && e.target === t && e.remotePort === rp && !e.stopping) {
        actionStatus = "Already forwarding " + t
        statusTimer.restart()
        return
      }
    }
    var fid = _nextFid++
    forwardModel.append({ fid: fid, targetKind: tk, target: t, pod: "", localPort: lp,
      remotePort: rp, ready: false, stopping: false })
    actionStatus = "Starting forward → " + t + "…"
    statusTimer.restart()
  }

  function stopForward(fid) {
    var i = forwardIndex(fid)
    if (i >= 0) forwardModel.setProperty(i, "stopping", true)
  }

  function stopAllForwards() {
    for (var i = 0; i < forwardModel.count; i++) forwardModel.setProperty(i, "stopping", true)
  }

  function forwardOutput(fid, text) {
    var i = forwardIndex(fid)
    if (i < 0 || forwardModel.get(i).ready) return
    var line = String(text || "").split("\n")[0]
    var data = null
    try { data = JSON.parse(line) } catch (e) { data = null }
    if (data && data.status === "ready") {
      forwardModel.setProperty(i, "pod", String(data.pod || ""))
      forwardModel.setProperty(i, "localPort", data.localPort || 0)
      forwardModel.setProperty(i, "ready", true)
      var e = forwardModel.get(i)
      actionStatus = "Forwarding localhost:" + e.localPort + " → " + e.targetKind + "/" + e.target
      statusTimer.restart()
    }
  }

  function forwardExited(fid, exitCode, stdout, stderr) {
    var i = forwardIndex(fid)
    if (i < 0) return
    var e = forwardModel.get(i)
    var label = e.targetKind + "/" + e.target
    forwardModel.remove(i)
    if (e.stopping) {
      actionStatus = "Stopped " + label
      statusTimer.restart()
    } else if (!e.ready) {
      lastError = Model.humanError(String(stderr || stdout || "")) || ("Forward failed: " + label)
      lastErrorKind = "unknown"
    } else {
      lastError = "Forward " + label + " died — restart it if still needed"
      lastErrorKind = "unknown"
    }
  }

  // ---- processes (native pattern: command + StdioCollector + onExited) ----
  Process {
    id: actProcess
    running: false
    command: []
    stdout: StdioCollector { id: actStdout; waitForEnd: true }
    stderr: StdioCollector { id: actStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.parseAction(String(actStdout.text || ""), String(actStderr.text || ""), exitCode)
    }
  }

  Process {
    id: contextsProcess
    running: false
    command: []
    stdout: StdioCollector { id: contextsStdout; waitForEnd: true }
    stderr: StdioCollector { id: contextsStderr; waitForEnd: true }
    onExited: function(exitCode) {
      var out = String(contextsStdout.text || "")
      var err = String(contextsStderr.text || "")
      if (exitCode !== 0 && out === "") {
        root.lastError = Model.humanError(err) || ("Backend binary missing or failed (exit " + exitCode + "). Build it with 'make' in plugin folder.")
        root.lastErrorKind = "unknown"
        root.refreshing = false
        root.warmedUp = true
        return
      }
      root.parseContexts(out, err)
    }
  }

  Process {
    id: healthProcess
    running: false
    command: []
    stdout: StdioCollector { id: healthStdout; waitForEnd: true }
    stderr: StdioCollector { id: healthStderr; waitForEnd: true }
    onExited: function(exitCode) {
      // exit 1 still carries the JSON report on stdout for auth/unreachable.
      root.parseHealth(String(healthStdout.text || ""), String(healthStderr.text || ""))
    }
  }

  Process {
    id: useProcess
    running: false
    command: []
    stdout: StdioCollector { id: useStdout; waitForEnd: true }
    stderr: StdioCollector { id: useStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionStatus = ""
      root.parseUseContext(String(useStdout.text || ""), String(useStderr.text || ""), exitCode)
    }
  }

  Process {
    id: nsProcess
    running: false
    command: []
    stdout: StdioCollector { id: nsStdout; waitForEnd: true }
    stderr: StdioCollector { id: nsStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) root.parseNamespaces(String(nsStdout.text || ""))
    }
  }

  Process {
    id: wlProcess
    running: false
    command: []
    stdout: StdioCollector { id: wlStdout; waitForEnd: true }
    stderr: StdioCollector { id: wlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.parseWorkloads(String(wlStdout.text || ""), String(wlStderr.text || ""), exitCode)
    }
  }

  Process {
    id: evProcess
    running: false
    command: []
    stdout: StdioCollector { id: evStdout; waitForEnd: true }
    stderr: StdioCollector { id: evStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.parseEvents(String(evStdout.text || ""), String(evStderr.text || ""), exitCode)
    }
  }

  Process {
    id: logProcess
    running: false
    command: []
    stdout: StdioCollector { id: logStdout; waitForEnd: true }
    stderr: StdioCollector { id: logStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.parseLogs(String(logStdout.text || ""), String(logStderr.text || ""), exitCode)
    }
  }

  Process {
    id: exProcess
    running: false
    command: []
    stdout: StdioCollector { id: exStdout; waitForEnd: true }
    stderr: StdioCollector { id: exStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.actionStatus = "Saved " + root._exportTarget
        statusTimer.restart()
      } else {
        root.lastError = Model.humanError(String(exStderr.text || "")) || "Export failed"
        root.lastErrorKind = "unknown"
        root.actionStatus = ""
        statusTimer.restart()
      }
      root._exportTarget = ""
    }
  }

  Process {
    id: openDirProcess
    running: false
    command: []
  }

  function openExportDir(dir) {
    var d = String(dir || setting("logExportDir", "") || (Quickshell.env("HOME") + "/omakube-logs")).trim()
    openDirProcess.command = ["sh", "-c", "mkdir -p \"" + d + "\" && (xdg-open \"" + d + "\" || nautilus \"" + d + "\" || dolphin \"" + d + "\" || thunar \"" + d + "\")"]
    openDirProcess.running = true
  }

  Timer {
    id: statusTimer
    interval: 2600
    onTriggered: root.actionStatus = ""
  }

  Timer {
    interval: Math.max(5, root.refreshIntervalSec) * 1000
    running: true
    repeat: true
    onTriggered: if (!root.busy) root.refresh(false)
  }

  Component.onCompleted: {
    var remembered = String(setting("lastContext", "") || "")
    if (remembered !== "") {
      activeContextName = remembered
      contextAccent = accentFor(remembered)
      activeNamespace = restoreNamespace(remembered, "default")
    }
    // Reap orphaned forwards from a previous shell instance — no live
    // Service owns them (forwardModel starts empty), so by definition
    // they are stale. Forwards die with the shell, per spec.
    orphanReap.command = ["pkill", "-f", "omakube port-forward"]
    orphanReap.running = true
    refresh(false)
  }

  // Fire-and-forget; never blocks the pipeline.
  Process {
    id: orphanReap
    running: false
    command: []
  }
}
