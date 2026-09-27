import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaKube — Single anchored bar-widget popup for Omarchy.
// Redesigned with maximum data-ink density, virtualized ListView engine,
// dynamic Kubernetes resource discovery (CRDs, core resources),
// instant searchable breadcrumbs, unified Omnibar, and dedicated full-height views.
Panel {
  id: root
  moduleName: "omakube"
  ipcTarget: "omakube"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: bar ? Qt.darker(bar.foreground, 1.55) : Qt.darker(Color.foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accent: backend.contextAccent || Color.accent
  readonly property color healthDot: Model.healthColor(backend.healthStatus, foreground, urgent, accent)
  readonly property color barFg: bar ? bar.barForeground : Color.foreground
  readonly property string pillLabel: {
    var ctx = backend.activeContext()
    return Model.shortLabel(ctx ? ctx.shortLabel || ctx.name : "k8s")
  }

  implicitWidth: pill.implicitWidth
  implicitHeight: pill.implicitHeight

  function persistSettings(patch) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var p in patch) entry[p] = patch[p]
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  onOpenedChanged: {
    backend.setPopupOpen(opened || quickOpened)
    if (opened) {
      quickOpened = false
      backend.refresh(false)
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }

  // Navigation states
  property string topMode: "workloads" // "workloads" | "events" | "logs" | "forwards" | "settings"
  property string selectedResourceKind: "pods"
  property string sortMode: "Status" // Status | Name | Age
  property bool compactMode: true
  property bool eventsOnlyWarnings: false

  // Pickers & Popovers
  property bool contextPickerOpen: false
  property bool nsPickerOpen: false
  property bool kindPickerOpen: false
  property bool logPodPickerOpen: false

  function closeAllPickers() {
    contextPickerOpen = false
    nsPickerOpen = false
    kindPickerOpen = false
    logPodPickerOpen = false
  }

  // Quick context right-click popup
  property bool quickOpened: false
  property int quickIndex: 0

  // Log viewer state
  property string logSearch: ""
  property int currentMatchLine: -1

  // Port forward inline form
  property string forwardFormKey: ""
  property string fwLocal: ""
  property string fwRemote: ""

  // Destructive action confirmation state
  property var confirmState: null

  readonly property var logPalette: ({
    text: String(foreground), dim: String(dim), error: String(urgent),
    warn: "#d9a13b", match: "rgba(217,161,59,0.45)", matchCurrent: "rgba(229,72,77,0.65)"
  })

  function toggleFull() {
    closeAllPickers()
    if (root.opened) { root.close(); backend.setPopupOpen(false) }
    else {
      if (root.quickOpened) root.quickOpened = false
      backend.setPopupOpen(true)
      root.open()
      backend.refresh(false)
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    }
  }

  function toggleQuick() {
    closeAllPickers()
    if (root.quickOpened) root.quickOpened = false
    else {
      if (root.opened) { root.close(); backend.setPopupOpen(false) }
      root.quickIndex = 0
      root.quickOpened = true
      Qt.callLater(function() { if (quickKeys) quickKeys.forceActiveFocus() })
    }
  }

  function closeAll() {
    closeAllPickers()
    root.quickOpened = false
    if (root.opened) { root.close(); backend.setPopupOpen(false) }
  }

  function switchTab(mode) {
    closeAllPickers()
    topMode = mode
    if (topMode === "logs") ensureLogPod()
    else if (topMode === "events") backend.fetchEvents()
    else if (topMode === "workloads") backend.fetchWorkloads()
    backend.expandedKey = ""
  }

  function availableResourceKinds() {
    var w = backend.workloads
    if (!w) return []
    var standard = [
      { key: "pods", label: "Pods" },
      { key: "deployments", label: "Deployments" },
      { key: "services", label: "Services" },
      { key: "statefulsets", label: "StatefulSets" },
      { key: "daemonsets", label: "DaemonSets" },
      { key: "jobs", label: "Jobs" },
      { key: "ingresses", label: "Ingresses" },
      { key: "configmaps", label: "ConfigMaps" },
      { key: "secrets", label: "Secrets" },
      { key: "pvc", label: "PVCs" }
    ]
    var out = []
    var seen = {}
    for (var i = 0; i < standard.length; i++) {
      var item = standard[i]
      var list = w[item.key]
      if (list instanceof Array && list.length > 0) {
        out.push({ id: item.key, label: item.label, count: list.length, category: Model.resourceCategory(item.key) })
        seen[item.key] = true
      }
    }
    for (var k in w) {
      if (k === "namespace" || seen[k]) continue
      var customList = w[k]
      if (customList instanceof Array && customList.length > 0) {
        out.push({ id: k, label: Model.formatKindLabel(k), count: customList.length, category: "Custom" })
      }
    }
    return out
  }

  function totalWorkloadCount() {
    var kinds = availableResourceKinds()
    var sum = 0
    for (var i = 0; i < kinds.length; i++) sum += kinds[i].count
    return sum
  }

  function currentResourceCount() {
    if (selectedResourceKind === "all") return totalWorkloadCount()
    var kinds = availableResourceKinds()
    for (var i = 0; i < kinds.length; i++) {
      if (kinds[i].id === selectedResourceKind) return kinds[i].count
    }
    return 0
  }

  function ensureLogPod() {
    if (backend.logPod !== "") { backend.fetchLogs(); return }
    var pods = (backend.workloads && backend.workloads.pods) || []
    if (pods.length > 0) backend.setLogPod(String(pods[0].name))
  }

  function logMatchLines() {
    var q = logSearch.trim().toLowerCase()
    if (q === "") return []
    var out = []
    var lines = backend.logLines || []
    for (var i = 0; i < lines.length; i++) {
      if (String(lines[i]).toLowerCase().indexOf(q) >= 0) out.push(i)
    }
    return out
  }

  function stepMatch(dir) {
    var m = logMatchLines()
    if (m.length === 0) return
    var pos = 0
    for (var i = 0; i < m.length; i++) {
      if (m[i] === currentMatchLine) { pos = (i + dir + m.length) % m.length; break }
      if (m[i] > currentMatchLine) { pos = dir > 0 ? i : Math.max(0, i - 1); break }
      pos = i
    }
    currentMatchLine = m[pos]
    scrollLogTo(currentMatchLine)
  }

  function scrollLogTo(idx) {
    if (!logLinesColumn || idx < 0 || idx >= logLinesColumn.children.length) return
    var item = logLinesColumn.children[idx]
    if (!item) return
    var y = item.y - Style.space(40)
    logFlick.contentY = Math.max(0, Math.min(y, Math.max(0, logFlick.contentHeight - logFlick.height)))
  }

  function scrollLogToBottom() {
    if (!logFlick) return
    logFlick.contentY = Math.max(0, logFlick.contentHeight - logFlick.height)
  }

  function runRowAction(r, a) {
    if (!r) return
    if (a === "logs") {
      backend.setLogPod(String(r.target))
      switchTab("logs")
      return
    }
    if (a === "forward") {
      root.fwLocal = String(r.remoteHint || "8080")
      root.fwRemote = String(r.remoteHint || "8080")
      root.forwardFormKey = String(r.key)
      return
    }
    if (a === "kill") {
      root.confirmState = { op: "delete-pod", kind: "pod", name: String(r.target) }
      return
    }
    if (a === "restart") {
      root.confirmState = { op: "restart", kind: String(r.targetKind), name: String(r.target) }
      return
    }
  }

  function confirmMessage() {
    var c = root.confirmState
    if (!c) return ""
    var what = c.op === "delete-pod" ? "Delete pod" : "Restart " + c.kind
    return what + " " + c.name + " in " + backend.activeNamespace + " on " + backend.activeContextName + "?"
  }

  function sevOf(kind) {
    var k = String(kind || "")
    if (k === "crashloop" || k === "failed") return 0
    if (k === "pending" || k === "waiting") return 1
    if (k === "running") return 2
    if (k === "succeeded") return 3
    return 2
  }

  function normRow(kind, it) {
    var kLower = String(kind || "").toLowerCase()
    var nsPrefix = (backend.activeNamespace === "*" && it.namespace) ? (it.namespace + " · ") : ""

    if (kLower === "pods" || kLower === "pod") {
      return {
        key: "pod/" + (it.namespace ? it.namespace + "/" : "") + it.name, kind: it.kind, title: it.name,
        namespace: it.namespace || "",
        typeLabel: "Pod",
        badge: it.display, badgeKind: it.kind,
        meta: nsPrefix + it.ready + "/" + it.readyTotal + " ready · " + it.restarts + "r · " + it.age + " · " + (it.node || it.podIP || ""),
        ageSeconds: it.ageSeconds || 0, sev: sevOf(it.kind),
        targetKind: "pod", target: it.name, remoteHint: 80,
        rawPod: it,
        lines: podLines(it)
      }
    }
    if (kLower === "services" || kLower === "svc") {
      return {
        key: "svc/" + (it.namespace ? it.namespace + "/" : "") + it.name, kind: "running", title: it.name,
        namespace: it.namespace || "",
        typeLabel: "Service",
        badge: it.type, badgeKind: "running",
        meta: nsPrefix + (it.clusterIP || "") + " · " + (it.ports || "") + " · " + it.age,
        ageSeconds: it.ageSeconds || 0, sev: 2,
        targetKind: "service", target: it.name, remoteHint: Model.firstPort(it.ports),
        rawItem: it,
        lines: ["Namespace: " + (it.namespace || "default"), "Type: " + it.type, "ClusterIP: " + (it.clusterIP || "—"), "Ports: " + (it.ports || "—"), "Age: " + it.age]
      }
    }
    if (kLower === "jobs" || kLower === "job") {
      var jk = it.statusKind || "waiting"
      return {
        key: "job/" + (it.namespace ? it.namespace + "/" : "") + it.name, kind: jk, title: it.name + (it.kind === "CronJob" ? "  ◷ " + (it.schedule || "") : ""),
        namespace: it.namespace || "",
        typeLabel: it.kind || "Job",
        badge: it.display, badgeKind: jk,
        meta: nsPrefix + it.kind + " · A" + it.active + "/S" + it.succeeded + "/F" + it.failed + " · " + it.age,
        ageSeconds: it.ageSeconds || 0, sev: sevOf(jk),
        targetKind: "", target: "", remoteHint: 0,
        rawItem: it,
        lines: [(it.schedule ? ("Schedule: " + it.schedule) : ""), "Active: " + it.active + " · Succeeded: " + it.succeeded + " · Failed: " + it.failed, "Age: " + it.age].filter(function(s){return s !== ""})
      }
    }
    var tk = kLower.indexOf("sts") >= 0 || kLower.indexOf("stateful") >= 0 ? "statefulset"
      : (kLower.indexOf("ds") >= 0 || kLower.indexOf("daemon") >= 0 ? "daemonset" : "deployment")
    var typeLabel = tk === "statefulset" ? "StatefulSet" : (tk === "daemonset" ? "DaemonSet" : "Deployment")
    if (kLower === "deployments" || kLower === "deploy" || kLower === "statefulsets" || kLower === "sts" || kLower === "daemonsets" || kLower === "ds") {
      return {
        key: tk + "/" + (it.namespace ? it.namespace + "/" : "") + it.name, kind: it.kind, title: it.name,
        namespace: it.namespace || "",
        typeLabel: typeLabel,
        badge: it.display, badgeKind: it.kind,
        meta: nsPrefix + it.ready + "/" + it.desired + " ready · upd " + it.updated + " · avail " + it.available + " · " + it.age,
        ageSeconds: it.ageSeconds || 0, sev: sevOf(it.kind),
        targetKind: tk, target: it.name, remoteHint: 80,
        rawItem: it,
        lines: ["Ready: " + it.ready + "/" + it.desired, "Updated: " + it.updated + " · Available: " + it.available, "Age: " + it.age]
      }
    }
    if (kLower === "ingresses" || kLower === "ingress" || kLower === "ing") {
      return {
        key: "ing/" + (it.namespace ? it.namespace + "/" : "") + it.name, kind: "running", title: it.name,
        namespace: it.namespace || "",
        typeLabel: "Ingress",
        badge: it.display || "Active", badgeKind: "running",
        meta: nsPrefix + (it.hosts ? it.hosts + " · " : "") + (it.class ? "class: " + it.class + " · " : "") + it.age,
        ageSeconds: it.ageSeconds || 0, sev: 2,
        targetKind: "ingress", target: it.name, remoteHint: 80,
        rawItem: it,
        lines: ["Hosts: " + (it.hosts || "—"), "Class: " + (it.class || "—"), "Age: " + it.age]
      }
    }
    if (kLower === "configmaps" || kLower === "cm") {
      return {
        key: "cm/" + (it.namespace ? it.namespace + "/" : "") + it.name, kind: "running", title: it.name,
        namespace: it.namespace || "",
        typeLabel: "ConfigMap",
        badge: it.display || (it.dataCount + " keys"), badgeKind: "running",
        meta: nsPrefix + (it.dataCount !== undefined ? it.dataCount + " keys · " : "") + it.age,
        ageSeconds: it.ageSeconds || 0, sev: 2,
        targetKind: "configmap", target: it.name, remoteHint: 0,
        rawItem: it,
        lines: ["Keys: " + (it.dataCount || 0), "Age: " + it.age]
      }
    }
    if (kLower === "secrets") {
      return {
        key: "secret/" + (it.namespace ? it.namespace + "/" : "") + it.name, kind: "running", title: it.name,
        namespace: it.namespace || "",
        typeLabel: "Secret",
        badge: it.type || "Secret", badgeKind: "running",
        meta: nsPrefix + (it.type ? it.type + " · " : "") + (it.dataCount !== undefined ? it.dataCount + " keys · " : "") + it.age,
        ageSeconds: it.ageSeconds || 0, sev: 2,
        targetKind: "secret", target: it.name, remoteHint: 0,
        rawItem: it,
        lines: ["Type: " + (it.type || "Opaque"), "Keys: " + (it.dataCount || 0), "Age: " + it.age]
      }
    }
    if (kLower === "pvc" || kLower === "persistentvolumeclaims") {
      return {
        key: "pvc/" + (it.namespace ? it.namespace + "/" : "") + it.name, kind: it.kind || "running", title: it.name,
        namespace: it.namespace || "",
        typeLabel: "PVC",
        badge: it.display || it.status || "Bound", badgeKind: it.kind || "running",
        meta: nsPrefix + (it.status ? it.status + " · " : "") + (it.capacity ? it.capacity + " · " : "") + (it.class ? it.class + " · " : "") + it.age,
        ageSeconds: it.ageSeconds || 0, sev: sevOf(it.kind),
        targetKind: "pvc", target: it.name, remoteHint: 0,
        rawItem: it,
        lines: ["Status: " + (it.status || "—"), "Capacity: " + (it.capacity || "—"), "StorageClass: " + (it.class || "—"), "Age: " + it.age]
      }
    }
    return {
      key: kind + "/" + (it.namespace ? it.namespace + "/" : "") + (it.name || "item"),
      kind: it.kind || "running",
      title: it.name || "item",
      namespace: it.namespace || "",
      typeLabel: it.type || Model.formatKindLabel(kind),
      badge: it.display || it.kind || it.status || "Ready",
      badgeKind: it.kind || "running",
      meta: nsPrefix + (it.meta ? it.meta + " · " : "") + (it.age || ""),
      ageSeconds: it.ageSeconds || 0,
      sev: sevOf(it.kind),
      targetKind: kind,
      target: it.name || "",
      remoteHint: 80,
      rawItem: it,
      lines: genericLines(it)
    }
  }

  function podLines(p) {
    if (!p) return []
    var l = []
    if (p.namespace) l.push("Namespace: " + p.namespace)
    l.push("Phase: " + p.phase + " (" + p.display + ")")
    l.push("Ready: " + p.ready + "/" + p.readyTotal + " · Restarts: " + p.restarts)
    if (p.node) l.push("Node: " + p.node)
    if (p.podIP) l.push("IP: " + p.podIP)
    l.push("Age: " + p.age)
    return l
  }

  function genericLines(it) {
    var out = []
    if (it.namespace) out.push("Namespace: " + it.namespace)
    if (it.age) out.push("Age: " + it.age)
    for (var k in it) {
      if (k === "name" || k === "kind" || k === "display" || k === "age" || k === "ageSeconds" || k === "namespace") continue
      var val = it[k]
      if (typeof val === "string" || typeof val === "number" || typeof val === "boolean") {
        out.push(k.charAt(0).toUpperCase() + k.slice(1) + ": " + val)
      }
    }
    return out
  }

  function filteredWorkloads() {
    var w = backend.workloads
    if (!w) return []
    var kinds = availableResourceKinds()
    var rows = []
    var q = (typeof omniSearch !== "undefined" && omniSearch ? omniSearch.text : "").trim().toLowerCase()
    var nsFilter = ""
    var kindFilter = ""

    if (q.indexOf("@") === 0) {
      var parts = q.slice(1).split(" ")
      nsFilter = parts[0]
      q = parts.slice(1).join(" ").trim()
    } else if (q.indexOf(":") === 0) {
      var kparts = q.slice(1).split(" ")
      kindFilter = kparts[0]
      q = kparts.slice(1).join(" ").trim()
    }

    for (var i = 0; i < kinds.length; i++) {
      var kid = kinds[i].id
      if (selectedResourceKind !== "all" && selectedResourceKind !== kid) continue
      if (kindFilter !== "" && kid.toLowerCase().indexOf(kindFilter) < 0) continue
      var list = w[kid] || []
      for (var j = 0; j < list.length; j++) {
        var it = list[j]
        if (nsFilter !== "" && it.namespace && it.namespace.toLowerCase().indexOf(nsFilter) < 0) continue
        var r = normRow(kid, it)
        if (q !== "") {
          var match = r.title.toLowerCase().indexOf(q) >= 0 ||
                      r.badge.toLowerCase().indexOf(q) >= 0 ||
                      (r.typeLabel && r.typeLabel.toLowerCase().indexOf(q) >= 0) ||
                      r.meta.toLowerCase().indexOf(q) >= 0
          if (!match) continue
        }
        rows.push(r)
      }
    }

    if (sortMode === "Name") {
      rows.sort(function(a, b) { return a.title < b.title ? -1 : (a.title > b.title ? 1 : 0) })
    } else if (sortMode === "Age") {
      rows.sort(function(a, b) { return a.ageSeconds - b.ageSeconds })
    } else {
      rows.sort(function(a, b) { return (a.sev - b.sev) || (a.title < b.title ? -1 : (a.title > b.title ? 1 : 0)) })
    }
    return rows
  }

  function cycleSort() {
    sortMode = sortMode === "Status" ? "Name" : (sortMode === "Name" ? "Age" : "Status")
  }

  function filteredEvents() {
    var q = (typeof omniSearch !== "undefined" && omniSearch ? omniSearch.text : "").trim().toLowerCase()
    var evs = backend.events || []
    var out = []
    for (var i = 0; i < evs.length; i++) {
      var e = evs[i]
      if (eventsOnlyWarnings && String(e.type) !== "Warning") continue
      if (q !== "") {
        var str = (e.reason + " " + e.object + " " + e.message + " " + (e.namespace || "")).toLowerCase()
        if (str.indexOf(q) < 0) continue
      }
      out.push(e)
    }
    return out
  }

  Service {
    id: backend
    settings: root.settings
  }

  Connections {
    target: backend
    function onLogLinesChanged() {
      if (backend.logFollow && root.topMode === "logs" && root.opened) {
        Qt.callLater(function() { root.scrollLogToBottom() })
      }
    }
    function onWorkloadsFreshChanged() {
      if (backend.workloadsFresh && root.topMode === "logs" && backend.logPod === "") {
        root.ensureLogPod()
      }
    }
  }

  Timer {
    interval: 5000
    running: root.opened && root.topMode === "logs" && backend.logFollow && !backend.logsLoading && backend.logPod !== ""
    repeat: true
    onTriggered: backend.fetchLogs()
  }

  Component.onCompleted: {
    backend.persistFn = function(patch) { root.persistSettings(patch) }
    backend.setPopupOpen(root.opened || root.quickOpened)
  }

  onConfirmStateChanged: {
    if (confirmState) Qt.callLater(function() { confirmOverlay.forceActiveFocus() })
    else if (opened) Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { backend.refresh(); return "ok" }
    function status(): string { return String(backend.healthStatus) }
    function expand(key: string): void { backend.expandedKey = key }
    function setMode(mode: string): void { root.switchTab(mode) }
    function setLogPod(pod: string): void { backend.setLogPod(pod); root.switchTab("logs") }
    function setNs(ns: string): void { backend.setNamespace(ns) }
    function toggleNs(): void { root.nsPickerOpen = !root.nsPickerOpen }
    function toggleKind(): void { root.kindPickerOpen = !root.kindPickerOpen }
    function toggleCtx(): void { root.contextPickerOpen = !root.contextPickerOpen }
  }

  // ---- Bar pill ----
  WidgetButton {
    id: pill
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    implicitWidth: Math.min(pillRow.implicitWidth + scaledHorizontalMargin * 2, Style.space(168))
    tooltipText: (backend.activeContextName || "kubernetes") + " · " + (backend.activeNamespace === "*" ? "all namespaces" : backend.activeNamespace) + " · " + backend.healthStatus

    Row {
      id: pillRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      Rectangle {
        id: dot
        width: Style.space(8)
        height: Style.space(8)
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.healthDot
      }

      OmakubeIcon {
        anchors.verticalCenter: parent.verticalCenter
        iconSize: Style.space(14)
        color: root.barFg
        opacityLevel: 1.0
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        width: Math.min(implicitWidth, Style.space(92))
        maximumLineCount: 1
        elide: Text.ElideRight
        text: root.pillLabel
        color: root.barFg
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleQuick()
      else if (buttonCode === Qt.MiddleButton) backend.refresh(true)
      else root.toggleFull()
    }
  }

  // ---- Main popup ----
  KeyboardPanel {
    id: panel
    anchorItem: pill
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: Math.min(Style.space(520), panel.fittedContentWidth(Style.space(520)))
    contentHeight: Style.space(640)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.confirmState !== null
      onCloseRequested: {
        if (root.contextPickerOpen || root.nsPickerOpen || root.kindPickerOpen || root.logPodPickerOpen) {
          root.closeAllPickers()
        } else {
          root.closeAll()
        }
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") { omniSearch.forceActiveFocus(); omniSearch.selectAll() }
        else if (t === "r" || t === "R") backend.refresh(true)
      }

      // Root layout container: zero wasted space, vertically stacked
      ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // =================================================================
        // ZONE A: SMART BREADCRUMB BAR (34px)
        // [☸ Context ▾] / [⎈ Namespace ▾] / [⚡ Kind (Count) ▾]  [● 45ms]
        // =================================================================
        BorderSurface {
          Layout.fillWidth: true
          implicitHeight: Style.space(34)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
          borderSpec: Border.controlSpec("normal", root.dim, root.accent)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(8)
            spacing: Style.space(6)

            // 1. Context Selector Button
            CursorSurface {
              implicitHeight: Style.space(26)
              implicitWidth: ctxRowBox.implicitWidth + Style.space(12)
              current: root.contextPickerOpen
              foreground: root.foreground

              RowLayout {
                id: ctxRowBox
                anchors.centerIn: parent
                spacing: Style.space(4)

                Rectangle {
                  width: Style.space(8); height: Style.space(8); radius: width / 2
                  color: root.healthDot
                }

                Text {
                  text: Model.shortLabel(backend.activeContextName || "k8s")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  text: "▾"
                  color: root.dim
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  var next = !root.contextPickerOpen
                  root.closeAllPickers()
                  root.contextPickerOpen = next
                }
              }
            }

            Text {
              text: "/"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // 2. Namespace Selector Button
            CursorSurface {
              implicitHeight: Style.space(26)
              implicitWidth: nsRowBox.implicitWidth + Style.space(12)
              current: root.nsPickerOpen
              foreground: root.foreground

              RowLayout {
                id: nsRowBox
                anchors.centerIn: parent
                spacing: Style.space(4)

                Text {
                  text: backend.activeNamespace === "*" ? "all namespaces" : backend.activeNamespace
                  color: backend.activeNamespace === "*" ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  text: "▾"
                  color: root.dim
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  var next = !root.nsPickerOpen
                  root.closeAllPickers()
                  root.nsPickerOpen = next
                  if (next) Qt.callLater(function() { nsSearchInput.forceActiveFocus() })
                }
              }
            }

            Text {
              text: "/"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // 3. Resource Kind Selector Button
            CursorSurface {
              implicitHeight: Style.space(26)
              implicitWidth: kindRowBox.implicitWidth + Style.space(12)
              current: root.kindPickerOpen
              foreground: root.foreground

              RowLayout {
                id: kindRowBox
                anchors.centerIn: parent
                spacing: Style.space(4)

                Text {
                  text: (root.selectedResourceKind === "all" ? "All" : Model.formatKindLabel(root.selectedResourceKind)) + " (" + root.currentResourceCount() + ")"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  text: "▾"
                  color: root.dim
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  var next = !root.kindPickerOpen
                  root.closeAllPickers()
                  root.kindPickerOpen = next
                }
              }
            }

            Item { Layout.fillWidth: true }

            // 4. Latency & Refresh Indicator
            RowLayout {
              spacing: Style.space(6)

              Text {
                visible: backend.apiLatencyMs >= 0
                text: backend.apiLatencyMs + "ms"
                color: root.dim
                font.family: "monospace"
                font.pixelSize: Style.font.caption
              }

              CursorSurface {
                implicitWidth: Style.space(24)
                implicitHeight: Style.space(24)
                foreground: root.foreground

                Item {
                  id: spinMark
                  anchors.centerIn: parent
                  width: Style.space(18); height: Style.space(18)
                  property bool spinning: backend.refreshing
                  onSpinningChanged: {
                    if (spinning) { rotation = 0; spinAnim.restart() }
                    else { spinAnim.stop(); rotation = 0 }
                  }
                  NumberAnimation {
                    id: spinAnim
                    target: spinMark
                    property: "rotation"
                    from: 0; to: 360; duration: 1800
                    loops: Animation.Infinite
                  }
                  OmakubeIcon {
                    anchors.fill: parent
                    iconSize: Style.space(18)
                    color: root.foreground
                    opacityLevel: backend.refreshing ? 1.0 : 0.75
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: backend.refresh(true)
                }
              }
            }
          }
        }

        // =================================================================
        // ZONE B: UNIFIED OMNIBAR & STATUS STRIP (28px)
        // [ ⌕ Filter pods… (/) ]  [Sort: Status ▾] [Compact]
        // =================================================================
        BorderSurface {
          Layout.fillWidth: true
          Layout.leftMargin: Style.space(8)
          Layout.rightMargin: Style.space(8)
          Layout.topMargin: Style.space(3)
          Layout.bottomMargin: Style.space(3)
          implicitHeight: Style.space(28)
          radius: Style.cornerRadius
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
          borderSpec: Border.controlSpec("normal", root.dim, root.accent)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8)
            anchors.rightMargin: Style.space(6)
            spacing: Style.space(6)

            Text {
              text: "⌕"
              color: root.dim
              font.pixelSize: Style.font.bodySmall
              Layout.alignment: Qt.AlignVCenter
            }

            TextField {
              id: omniSearch
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              foreground: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalPadding: 0
              verticalPadding: 0
              background: null
              placeholderText: root.topMode === "logs" ? "Search log stream… (/)" : ("Filter " + (root.selectedResourceKind === "all" ? "all workloads" : Model.formatKindLabel(root.selectedResourceKind).toLowerCase()) + "… (/)")
              text: root.topMode === "logs" ? root.logSearch : ""
              onTextChanged: {
                if (root.topMode === "logs") {
                  root.logSearch = text
                  root.currentMatchLine = -1
                  var m = root.logMatchLines()
                  if (m.length > 0) {
                    root.currentMatchLine = m[0]
                    root.scrollLogTo(m[0])
                  }
                }
              }
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) {
                  clear()
                  keyCatcher.forceActiveFocus()
                  event.accepted = true
                } else if (root.topMode === "logs" && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) {
                  root.stepMatch(1)
                  event.accepted = true
                }
              }
            }

            // Clear button
            Text {
              visible: omniSearch.text.trim() !== ""
              text: "✕"
              color: root.dim
              font.pixelSize: Style.font.caption - 1
              Layout.alignment: Qt.AlignVCenter
              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  omniSearch.clear()
                  if (root.topMode === "logs") root.logSearch = ""
                }
              }
            }

            // Match count indicator for logs
            Text {
              visible: root.topMode === "logs" && root.logSearch.trim() !== ""
              textFormat: Text.PlainText
              text: {
                var m = root.logMatchLines()
                if (m.length === 0) return "0/0"
                var pos = m.indexOf(root.currentMatchLine) + 1
                return (pos <= 0 ? "–" : pos) + "/" + m.length
              }
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Log navigation step buttons
            Button {
              visible: root.topMode === "logs" && root.logSearch.trim() !== ""
              text: "‹"
              fontSize: Style.font.caption - 1
              horizontalPadding: Style.space(6); verticalPadding: 1
              bordered: true
              onClicked: root.stepMatch(-1)
            }
            Button {
              visible: root.topMode === "logs" && root.logSearch.trim() !== ""
              text: "›"
              fontSize: Style.font.caption - 1
              horizontalPadding: Style.space(6); verticalPadding: 1
              bordered: true
              onClicked: root.stepMatch(1)
            }

            // Sort button
            CursorSurface {
              visible: root.topMode === "workloads"
              implicitHeight: Style.space(20)
              implicitWidth: sortText.implicitWidth + Style.space(10)
              foreground: root.foreground

              Text {
                id: sortText
                anchors.centerIn: parent
                text: "Sort: " + root.sortMode
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption - 1
                font.bold: true
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.cycleSort()
              }
            }

            // Density Mode Toggle Button
            CursorSurface {
              visible: root.topMode === "workloads"
              implicitHeight: Style.space(20)
              implicitWidth: denseText.implicitWidth + Style.space(10)
              foreground: root.foreground

              Text {
                id: denseText
                anchors.centerIn: parent
                text: root.compactMode ? "Compact" : "Comfort"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption - 1
                font.bold: true
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.compactMode = !root.compactMode
              }
            }
          }
        }

        // Action Status / Error Strip (compact toast)
        BorderSurface {
          visible: backend.actionStatus !== "" || backend.lastError !== ""
          Layout.fillWidth: true
          implicitHeight: Style.space(24)
          color: backend.lastError !== "" && backend.actionStatus === "" ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.12) : Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.12)
          borderSpec: Border.controlSpec("normal", backend.lastError !== "" ? root.urgent : root.accent, root.accent)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: backend.actionStatus !== "" ? backend.actionStatus : Model.humanError(backend.lastError)
              color: backend.lastError !== "" && backend.actionStatus === "" ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }
          }
        }

        // =================================================================
        // ZONE C: DYNAMIC CONTENT CANVAS (Fills remaining ~538px)
        // =================================================================
        Item {
          Layout.fillWidth: true
          Layout.fillHeight: true
          clip: true

          // --- VIEW 1: WORKLOADS (Virtualized ListView) ---
          Item {
            anchors.fill: parent
            visible: root.topMode === "workloads"

            ListView {
              id: wlList
              anchors.fill: parent
              anchors.margins: Style.space(4)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              model: root.filteredWorkloads()
              spacing: Style.space(4)
              visible: opacity > 0.01
              opacity: backend.workloadsFresh ? 1.0 : 0.0
              Behavior on opacity {
                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
              }
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: WorkloadRow {
                required property var modelData
                required property int index
                width: wlList.width - (wlList.ScrollBar.vertical.visible ? Style.space(8) : 0)
                row: modelData
                rowIndex: index
                isCompact: root.compactMode
              }
            }

            // Workloads Loading / Transition Splash Screen
            Column {
              anchors.centerIn: parent
              spacing: Style.space(8)
              visible: opacity > 0.01
              opacity: !backend.workloadsFresh ? 1.0 : 0.0
              Behavior on opacity {
                NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
              }

              Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Style.space(32)
                height: Style.space(32)

                Item {
                  id: wlSpin
                  anchors.fill: parent
                  NumberAnimation on rotation {
                    from: 0; to: 360; duration: 2000
                    loops: Animation.Infinite
                    running: backend.workloadsLoading
                  }
                  OmakubeIcon {
                    anchors.fill: parent
                    iconSize: Style.space(32)
                    color: root.accent
                    opacityLevel: 0.95
                  }
                }
              }

              Column {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(2)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: backend.actionStatus !== "" ? backend.actionStatus : ("Loading " + (backend.activeNamespace === "*" ? "all namespaces" : backend.activeNamespace) + "…")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "Querying " + (root.selectedResourceKind === "all" ? "cluster resources" : Model.formatKindLabel(root.selectedResourceKind).toLowerCase()) + " on " + Model.shortLabel(backend.activeContextName)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Empty state with actionable shortcuts
            Column {
              anchors.centerIn: parent
              spacing: Style.space(6)
              visible: backend.workloadsFresh && root.filteredWorkloads().length === 0

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "○"
                color: root.dim
                font.pixelSize: Style.font.display
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: omniSearch.text.trim() !== "" ? ("No match for “" + omniSearch.text.trim() + "”") : ("No " + (root.selectedResourceKind === "all" ? "workloads" : Model.formatKindLabel(root.selectedResourceKind).toLowerCase()) + " found in " + (backend.activeNamespace === "*" ? "all namespaces" : backend.activeNamespace))
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }

              RowLayout {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Style.space(6)

                Button {
                  visible: root.selectedResourceKind !== "all" && root.totalWorkloadCount() > 0
                  text: "View All (" + root.totalWorkloadCount() + ")"
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: root.selectedResourceKind = "all"
                }

                Button {
                  visible: backend.activeNamespace !== "*"
                  text: "All Namespaces (*)"
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: backend.setNamespace("*")
                }
              }
            }
          }

          // --- VIEW 2: EVENTS (Virtualized ListView) ---
          Item {
            anchors.fill: parent
            visible: root.topMode === "events"

            ColumnLayout {
              anchors.fill: parent
              spacing: Style.space(4)

              // Events top strip: Warning toggle + refresh
              RowLayout {
                Layout.fillWidth: true
                Layout.margins: Style.space(6)
                spacing: Style.space(6)

                Button {
                  text: root.eventsOnlyWarnings ? "Warnings Only: ON" : "Show All Events"
                  selected: root.eventsOnlyWarnings
                  bordered: true
                  fontSize: Style.font.caption
                  onClicked: root.eventsOnlyWarnings = !root.eventsOnlyWarnings
                }

                Item { Layout.fillWidth: true }

                Button {
                  text: "Refresh"
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: backend.fetchEvents()
                }
              }

              ListView {
                id: evList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: root.filteredEvents()
                spacing: Style.space(4)
                visible: !backend.eventsLoading || (backend.events && backend.events.length > 0)
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                delegate: EventRow {
                  required property var modelData
                  required property int index
                  width: evList.width - (evList.ScrollBar.vertical.visible ? Style.space(8) : 0)
                  ev: modelData
                  rowIndex: index
                }
              }

              // Events Loading Transition
              Column {
                Layout.alignment: Qt.AlignCenter
                spacing: Style.space(8)
                visible: backend.eventsLoading && (!backend.events || backend.events.length === 0)

                Item {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(28); height: Style.space(28)
                  NumberAnimation on rotation {
                    from: 0; to: 360; duration: 2000
                    loops: Animation.Infinite
                    running: backend.eventsLoading
                  }
                  OmakubeIcon {
                    anchors.fill: parent
                    iconSize: Style.space(28)
                    color: root.accent
                    opacityLevel: 0.95
                  }
                }

                Column {
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(2)
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Fetching events in " + (backend.activeNamespace === "*" ? "all namespaces" : backend.activeNamespace) + "…"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }
                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Querying recent cluster activity"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              // Events empty state
              Column {
                Layout.alignment: Qt.AlignCenter
                spacing: Style.space(4)
                visible: !backend.eventsLoading && root.filteredEvents().length === 0
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "○"
                  color: root.dim
                  font.pixelSize: Style.font.display
                }
                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "No events recorded"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }
            }
          }

          // --- VIEW 3: LOGS (Full-Canvas Terminal) ---
          Item {
            anchors.fill: parent
            visible: root.topMode === "logs"

            ColumnLayout {
              anchors.fill: parent
              spacing: Style.space(4)

              // Logs Control Strip
              RowLayout {
                Layout.fillWidth: true
                Layout.margins: Style.space(4)
                spacing: Style.space(6)

                // Pod Picker Dropdown Button
                CursorSurface {
                  implicitHeight: Style.space(26)
                  implicitWidth: logPodBox.implicitWidth + Style.space(12)
                  current: root.logPodPickerOpen
                  foreground: root.foreground

                  RowLayout {
                    id: logPodBox
                    anchors.centerIn: parent
                    spacing: Style.space(4)
                    Text {
                      text: backend.logPod || "Pick Pod ▾"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                      elide: Text.ElideRight
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      var next = !root.logPodPickerOpen
                      root.closeAllPickers()
                      root.logPodPickerOpen = next
                    }
                  }
                }

                // Container Picker (if > 1 container)
                Row {
                  visible: backend.logContainers.length > 1
                  spacing: Style.space(4)
                  Repeater {
                    model: backend.logContainers
                    Chip {
                      required property var modelData
                      label: String(modelData)
                      active: backend.logContainer === String(modelData)
                      onClicked: backend.setLogContainer(String(modelData))
                    }
                  }
                }

                Item { Layout.fillWidth: true }

                Button {
                  text: backend.logFollow ? "Follow: ON" : "Follow: OFF"
                  selected: backend.logFollow
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: {
                    backend.logFollow = !backend.logFollow
                    if (backend.logFollow) { backend.fetchLogs(); root.scrollLogToBottom() }
                  }
                }

                Button {
                  text: "Reload"
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: backend.fetchLogs()
                }

                Button {
                  text: "Export"
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: backend.exportLogs(String(backend.setting("logExportDir", "") || ""))
                }
              }

              // Terminal Container (Fills 100% of remaining space)
              BorderSurface {
                Layout.fillWidth: true
                Layout.fillHeight: true
                radius: Style.cornerRadius
                color: Color.surface || "#111318"
                borderSpec: Border.controlSpec("normal", root.dim, root.accent)
                clip: true

                Flickable {
                  id: logFlick
                  anchors.fill: parent
                  anchors.margins: Style.space(6)
                  contentWidth: width
                  contentHeight: logLinesColumn.implicitHeight
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  flickableDirection: Flickable.VerticalFlick
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                  Column {
                    id: logLinesColumn
                    width: logFlick.width
                    spacing: 1

                    Repeater {
                      model: backend.logLines
                      Text {
                        required property var modelData
                        required property int index
                        width: parent.width
                        textFormat: Text.RichText
                        text: Model.renderLogLine(modelData, root.logSearch, index === root.currentMatchLine, root.logPalette)
                        font.family: "monospace"
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                      }
                    }
                  }
                }

                // Logs Loading Transition
                Column {
                  anchors.centerIn: parent
                  spacing: Style.space(6)
                  visible: backend.logsLoading && (!backend.logLines || backend.logLines.length === 0)

                  Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Style.space(24); height: Style.space(24)
                    NumberAnimation on rotation {
                      from: 0; to: 360; duration: 2000
                      loops: Animation.Infinite
                      running: backend.logsLoading
                    }
                    OmakubeIcon {
                      anchors.fill: parent
                      iconSize: Style.space(24)
                      color: root.accent
                      opacityLevel: 0.95
                    }
                  }

                  Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Streaming logs for " + backend.logPod + "…"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }
              }
            }
          }

          // --- VIEW 4: PORT FORWARDS (Dedicated Manager) ---
          Item {
            anchors.fill: parent
            visible: root.topMode === "forwards"

            ColumnLayout {
              anchors.fill: parent
              anchors.margins: Style.space(8)
              spacing: Style.space(8)

              RowLayout {
                Layout.fillWidth: true
                Text {
                  text: "ACTIVE PORT FORWARDS (" + backend.forwards.count + ")"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Item { Layout.fillWidth: true }
                Button {
                  visible: backend.forwards.count > 0
                  text: "Stop All"
                  foreground: root.urgent
                  fontSize: Style.font.caption
                  bordered: true
                  onClicked: backend.stopAllForwards()
                }
              }

              ListView {
                id: fwList
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                model: backend.forwards
                spacing: Style.space(6)

                delegate: FwRow {
                  required property int fid
                  required property string targetKind
                  required property string target
                  required property string pod
                  required property int localPort
                  required property int remotePort
                  required property bool ready
                  width: fwList.width
                  fid: fid
                  label: ready ? ("localhost:" + localPort + " → " + targetKind + "/" + target) : ("starting → " + targetKind + "/" + target + "…")
                  sub: pod !== "" ? ("pod " + pod + " · remote :" + remotePort) : ("remote :" + remotePort)
                }
              }

              Text {
                visible: backend.forwards.count === 0
                Layout.alignment: Qt.AlignCenter
                text: "No active port forwards"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          // --- VIEW 5: SETTINGS & CONTEXTS (Clean Configuration Form) ---
          Item {
            anchors.fill: parent
            visible: root.topMode === "settings"

            Flickable {
              anchors.fill: parent
              anchors.margins: Style.space(10)
              contentWidth: width
              contentHeight: settingsCol.implicitHeight + Style.space(20)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              Column {
                id: settingsCol
                width: parent.width
                spacing: Style.space(10)

                Text {
                  text: "CONFIGURATION"
                  color: root.dim
                  font.bold: true
                  font.pixelSize: Style.font.caption
                }

                // Kubeconfig
                Column {
                  width: parent.width; spacing: Style.space(2)
                  Text { text: "Kubeconfig path override"; color: root.dim; font.pixelSize: Style.font.caption }
                  TextField {
                    width: parent.width; foreground: root.foreground; placeholderText: "Empty = $KUBECONFIG / ~/.kube/config"
                    text: String(backend.setting("kubeconfigPath", "") || "")
                    onAccepted: { backend.persist({ kubeconfigPath: text.trim() }); backend.refresh(true) }
                  }
                }

                // Default Namespace
                Column {
                  width: parent.width; spacing: Style.space(2)
                  Text { text: "Default namespace"; color: root.dim; font.pixelSize: Style.font.caption }
                  TextField {
                    width: parent.width; foreground: root.foreground; placeholderText: "default"
                    text: String(backend.setting("defaultNamespace", "") || "")
                    onAccepted: { backend.persist({ defaultNamespace: text.trim() }) }
                  }
                }

                // Log Export Directory
                Column {
                  width: parent.width; spacing: Style.space(2)
                  Text { text: "Log export directory"; color: root.dim; font.pixelSize: Style.font.caption }
                  TextField {
                    width: parent.width; foreground: root.foreground; placeholderText: "~/omakube-logs"
                    text: String(backend.setting("logExportDir", "") || "")
                    onAccepted: { backend.persist({ logExportDir: text.trim() }) }
                  }
                }

                // Refresh interval
                RowLayout {
                  width: parent.width
                  Text { Layout.fillWidth: true; text: "Refresh interval (seconds)"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                  NumberField {
                    value: backend.refreshIntervalSec; from: 5; to: 3600; stepSize: 5
                    foreground: root.foreground
                    onModified: function(v) { backend.persist({ refreshIntervalSec: v }) }
                  }
                }

                // Read-only mode
                RowLayout {
                  width: parent.width
                  ColumnLayout {
                    Layout.fillWidth: true; spacing: 0
                    Text { text: "Read-only mode"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                    Text { text: "Disables restart, kill pod and port-forward"; color: root.dim; font.pixelSize: Style.font.caption }
                  }
                  ToggleSwitch {
                    checked: backend.readOnly; foreground: root.foreground
                    onToggled: backend.persist({ readOnly: !backend.readOnly })
                  }
                }

                // Debug logging
                RowLayout {
                  width: parent.width
                  ColumnLayout {
                    Layout.fillWidth: true; spacing: 0
                    Text { text: "Debug logging"; color: root.foreground; font.pixelSize: Style.font.bodySmall }
                    Text { text: "Verbose backend logging for auth issues"; color: root.dim; font.pixelSize: Style.font.caption }
                  }
                  ToggleSwitch {
                    checked: backend.debugLogging; foreground: root.foreground
                    onToggled: backend.persist({ debugLogging: !backend.debugLogging })
                  }
                }

                PanelSeparator { foreground: root.foreground }

                // Context Accents
                Text {
                  text: "CONTEXT ACCENT COLORS"
                  color: root.dim
                  font.bold: true
                  font.pixelSize: Style.font.caption
                }

                Repeater {
                  model: backend.contexts
                  RowLayout {
                    required property var modelData
                    width: parent.width
                    spacing: Style.space(8)

                    Rectangle {
                      width: Style.space(14); height: Style.space(14); radius: width / 2
                      color: modelData.accent || root.accent
                      MouseArea {
                        anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                        onClicked: backend.cycleAccent(String(modelData.name))
                      }
                    }

                    Text {
                      Layout.fillWidth: true
                      text: String(modelData.name)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: String(modelData.name) === backend.activeContextName
                      elide: Text.ElideRight
                    }

                    Text {
                      text: String(modelData.accent || "")
                      color: root.dim
                      font.family: "monospace"
                      font.pixelSize: Style.font.caption
                    }
                  }
                }
              }
            }
          }
        }

        // =================================================================
        // ZONE D: BOTTOM NAVIGATION RAIL (36px)
        // [ Workloads (N) ]  [ Events (N) ]  [ Logs ]  [ ⇄ Forwards (N) ]  [ ⚙ ]
        // =================================================================
        BorderSurface {
          Layout.fillWidth: true
          implicitHeight: Style.space(36)
          color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)
          borderSpec: Border.controlSpec("normal", root.dim, root.accent)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6)
            spacing: Style.space(4)

            Button {
              Layout.fillWidth: true
              text: "Workloads (" + root.totalWorkloadCount() + ")"
              fontSize: Style.font.caption
              selected: root.topMode === "workloads"
              bordered: true
              onClicked: root.switchTab("workloads")
            }

            Button {
              Layout.fillWidth: true
              text: "Events (" + (backend.events ? backend.events.length : 0) + ")"
              fontSize: Style.font.caption
              selected: root.topMode === "events"
              bordered: true
              onClicked: root.switchTab("events")
            }

            Button {
              Layout.fillWidth: true
              text: "Logs"
              fontSize: Style.font.caption
              selected: root.topMode === "logs"
              bordered: true
              onClicked: root.switchTab("logs")
            }

            Button {
              Layout.fillWidth: true
              text: backend.forwards.count > 0 ? ("⇄ " + backend.forwards.count) : "Forwards"
              fontSize: Style.font.caption
              selected: root.topMode === "forwards"
              bordered: true
              onClicked: root.switchTab("forwards")
            }

            Button {
              implicitWidth: Style.space(34)
              text: "⚙"
              fontSize: Style.font.bodySmall
              selected: root.topMode === "settings"
              bordered: true
              onClicked: root.switchTab("settings")
            }
          }
        }
      }

      // =================================================================
      // OVERLAYS: MODAL POPOVERS (Contexts, Namespaces, Kinds, Log Pods)
      // =================================================================

      // Transparent backdrop to dismiss open pickers
      MouseArea {
        anchors.fill: parent
        z: 99
        visible: root.contextPickerOpen || root.nsPickerOpen || root.kindPickerOpen || root.logPodPickerOpen
        onClicked: root.closeAllPickers()
      }

      // 1. Context Picker Popover
      BorderSurface {
        z: 100
        visible: root.contextPickerOpen
        anchors.top: parent.top
        anchors.topMargin: Style.space(36)
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        width: Style.space(300)
        height: Style.space(260)
        radius: Style.cornerRadius
        color: Color.background || "#181a1f"
        borderSpec: Border.controlSpec("normal", root.dim, root.accent)

        ColumnLayout {
          id: ctxPickerCol
          anchors.fill: parent
          anchors.margins: Style.space(6)
          spacing: Style.space(4)

          Text {
            text: "SELECT CONTEXT"
            color: root.dim
            font.bold: true
            font.pixelSize: Style.font.caption
          }

          ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: backend.contexts
            spacing: 2
            delegate: CursorSurface {
              required property var modelData
              width: parent.width
              implicitHeight: Style.space(36)
              current: String(modelData.name) === backend.activeContextName
              foreground: root.foreground

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
                spacing: Style.space(6)

                Rectangle {
                  width: Style.space(8); height: Style.space(8); radius: width / 2
                  color: Model.healthColor(modelData.health, root.foreground, root.urgent, root.accent)
                }

                Text {
                  Layout.fillWidth: true
                  text: String(modelData.name)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: String(modelData.name) === backend.activeContextName
                  elide: Text.ElideRight
                }

                Text {
                  visible: modelData.latencyMs !== undefined && modelData.latencyMs >= 0
                  text: modelData.latencyMs + "ms"
                  color: root.dim
                  font.family: "monospace"
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  backend.setContext(String(modelData.name))
                  root.closeAllPickers()
                }
              }
            }
          }
        }
      }

      // 2. Namespace Picker Popover (Searchable, All Namespaces support)
      BorderSurface {
        z: 100
        visible: root.nsPickerOpen
        anchors.top: parent.top
        anchors.topMargin: Style.space(36)
        anchors.left: parent.left
        anchors.leftMargin: Style.space(40)
        width: Style.space(320)
        height: Style.space(280)
        radius: Style.cornerRadius
        color: Color.background || "#181a1f"
        borderSpec: Border.controlSpec("normal", root.dim, root.accent)

        ColumnLayout {
          id: nsPickerCol
          anchors.fill: parent
          anchors.margins: Style.space(6)
          spacing: Style.space(4)

          TextField {
            id: nsSearchInput
            Layout.fillWidth: true
            placeholderText: "Filter namespaces…"
            foreground: root.foreground
          }

          ListView {
            id: nsListPop
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            model: {
              var q = nsSearchInput.text.trim().toLowerCase()
              var all = backend.namespaces || []
              if (q === "") return all
              var out = []
              for (var i = 0; i < all.length; i++) {
                if (String(all[i].name).toLowerCase().indexOf(q) >= 0) out.push(all[i])
              }
              return out
            }

            delegate: CursorSurface {
              required property var modelData
              width: nsListPop.width - (nsListPop.ScrollBar.vertical.visible ? Style.space(8) : 0)
              implicitHeight: Style.space(32)
              current: String(modelData.name) === backend.activeNamespace
              foreground: root.foreground

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  text: String(modelData.name) === "*" ? "★ All Namespaces (*)" : String(modelData.name)
                  color: String(modelData.name) === "*" ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: String(modelData.name) === backend.activeNamespace
                  elide: Text.ElideRight
                }

                Text {
                  text: modelData.pods !== undefined ? (modelData.pods + " pods") : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: modelData.failing > 0
                  text: modelData.failing + "✕"
                  color: root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  backend.setNamespace(String(modelData.name))
                  root.closeAllPickers()
                }
              }
            }
          }
        }
      }

      // 3. Resource Kind Picker Popover (Categorized with counts)
      BorderSurface {
        z: 100
        visible: root.kindPickerOpen
        anchors.top: parent.top
        anchors.topMargin: Style.space(36)
        anchors.left: parent.left
        anchors.leftMargin: Style.space(120)
        width: Style.space(260)
        height: Style.space(280)
        radius: Style.cornerRadius
        color: Color.background || "#181a1f"
        borderSpec: Border.controlSpec("normal", root.dim, root.accent)

        ColumnLayout {
          id: kindPickerCol
          anchors.fill: parent
          anchors.margins: Style.space(6)
          spacing: Style.space(4)

          Text {
            text: "SELECT RESOURCE TYPE"
            color: root.dim
            font.bold: true
            font.pixelSize: Style.font.caption
          }

          // "All" item
          CursorSurface {
            Layout.fillWidth: true
            implicitHeight: Style.space(28)
            current: root.selectedResourceKind === "all"
            foreground: root.foreground

            RowLayout {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
              Text {
                Layout.fillWidth: true
                text: "All Resources"
                color: root.foreground
                font.bold: root.selectedResourceKind === "all"
                font.pixelSize: Style.font.bodySmall
              }
              Text {
                text: String(root.totalWorkloadCount())
                color: root.dim
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.selectedResourceKind = "all"; root.closeAllPickers() }
            }
          }

          ListView {
            id: kindListPop
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            model: root.availableResourceKinds()
            spacing: 2
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: CursorSurface {
              required property var modelData
              width: kindListPop.width - (kindListPop.ScrollBar.vertical.visible ? Style.space(8) : 0)
              implicitHeight: Style.space(28)
              current: root.selectedResourceKind === modelData.id
              foreground: root.foreground

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
                Text {
                  Layout.fillWidth: true
                  text: modelData.label
                  color: root.foreground
                  font.bold: root.selectedResourceKind === modelData.id
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
                Text {
                  text: String(modelData.count)
                  color: root.dim
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: { root.selectedResourceKind = modelData.id; root.closeAllPickers() }
              }
            }
          }
        }
      }

      // 4. Log Pod Picker Popover (Searchable pods in current namespace)
      BorderSurface {
        z: 100
        visible: root.logPodPickerOpen
        anchors.top: parent.top
        anchors.topMargin: Style.space(70)
        anchors.left: parent.left
        anchors.leftMargin: Style.space(8)
        width: Style.space(320)
        height: Style.space(280)
        radius: Style.cornerRadius
        color: Color.background || "#181a1f"
        borderSpec: Border.controlSpec("normal", root.dim, root.accent)

        ColumnLayout {
          id: logPodCol
          anchors.fill: parent
          anchors.margins: Style.space(6)
          spacing: Style.space(4)

          TextField {
            id: podSearchInput
            Layout.fillWidth: true
            placeholderText: "Search pods to view logs…"
            foreground: root.foreground
          }

          ListView {
            id: logPodListPop
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
            model: {
              var q = podSearchInput.text.trim().toLowerCase()
              var all = (backend.workloads && backend.workloads.pods) || []
              if (q === "") return all
              var out = []
              for (var i = 0; i < all.length; i++) {
                if (String(all[i].name).toLowerCase().indexOf(q) >= 0) out.push(all[i])
              }
              return out
            }

            delegate: CursorSurface {
              required property var modelData
              width: logPodListPop.width - (logPodListPop.ScrollBar.vertical.visible ? Style.space(8) : 0)
              implicitHeight: Style.space(30)
              current: backend.logPod === String(modelData.name)
              foreground: root.foreground

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
                spacing: Style.space(6)

                Rectangle {
                  width: Style.space(6); height: Style.space(6); radius: width / 2
                  color: Model.healthColor(modelData.kind, root.foreground, root.urgent, root.accent)
                }

                Text {
                  Layout.fillWidth: true
                  text: String(modelData.name)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: backend.logPod === String(modelData.name)
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  backend.setLogPod(String(modelData.name))
                  root.closeAllPickers()
                }
              }
            }
          }
        }
      }
    }

    // Confirmation Modal for Destructive Actions
    Item {
      id: confirmOverlay
      anchors.fill: parent
      visible: root.confirmState !== null
      focus: root.confirmState !== null
      Keys.onPressed: function(event) {
        if (confirmDlg.handleKey(event)) event.accepted = true
      }
      ConfirmDialog {
        id: confirmDlg
        anchors.fill: parent
        opened: root.confirmState !== null
        message: root.confirmMessage()
        confirmText: root.confirmState && root.confirmState.op === "delete-pod" ? "Delete" : "Restart"
        foreground: root.foreground
        fontFamily: root.fontFamily
        onCanceled: root.confirmState = null
        onConfirmed: {
          var c = root.confirmState
          root.confirmState = null
          if (c) {
            backend.runAction(c.op, c.kind, c.name)
            Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
          }
        }
      }
    }
  }

  // ---- Forward process runner: one process per forward ----
  Repeater {
    model: backend.forwards
    Process {
      id: fwProc
      required property int fid
      required property string targetKind
      required property string target
      required property int localPort
      required property int remotePort
      required property bool stopping
      property bool started: false

      running: started && !stopping
      stdout: StdioCollector {
        waitForEnd: false
        onTextChanged: backend.forwardOutput(fwProc.fid, text)
      }
      stderr: StdioCollector {
        id: fwErr
        waitForEnd: true
      }
      onExited: function(exitCode) {
        backend.forwardExited(fwProc.fid, exitCode, "", String(fwErr.text || ""))
      }
      Component.onCompleted: {
        fwProc.command = [backend.cliPath, "port-forward",
          "--context", backend.activeContextName, "--namespace", (backend.activeNamespace === "*" ? "default" : backend.activeNamespace),
          "--target-kind", fwProc.targetKind, "--target", fwProc.target,
          "--local-port", fwProc.localPort, "--remote-port", fwProc.remotePort,
          "--timeout", "10"].concat(backend.kubeconfigArgs())
        fwProc.started = true
      }
    }
  }

  // ---- Right-click quick context switcher ----
  KeyboardPanel {
    anchorItem: pill
    owner: root
    bar: root.bar
    open: root.quickOpened
    focusTarget: quickKeys
    contentWidth: Style.space(300)
    contentHeight: Math.min(quickColumn.implicitHeight + Style.spacing.popupPadding * 2, Style.space(320))

    PanelKeyCatcher {
      id: quickKeys
      anchors.fill: parent
      onCloseRequested: root.closeAll()
      onMoveRequested: function(dx, dy) {
        if (dy !== 0 && backend.contexts.length > 0)
          root.quickIndex = Math.max(0, Math.min(backend.contexts.length - 1, root.quickIndex + dy))
      }
      onActivateRequested: {
        if (backend.contexts.length > 0) {
          var ctx = backend.contexts[Math.max(0, Math.min(root.quickIndex, backend.contexts.length - 1))]
          if (ctx) { backend.setContext(ctx.name); root.closeAll() }
        }
      }

      Column {
        id: quickColumn
        width: parent.width - Style.spacing.popupPadding * 2
        anchors.centerIn: parent
        spacing: Style.space(4)
        Repeater {
          model: backend.contexts
          QuickRow {
            required property var modelData
            required property int index
            width: quickColumn.width
            ctx: modelData
            rowIndex: index
          }
        }
      }
    }
  }

  // =================================================================
  // REUSABLE ROW DELEGATES
  // =================================================================

  // --- WORKLOAD ROW (High-Density & Virtualized) ---
  component WorkloadRow: CursorSurface {
    id: wlRow
    property var row: null
    property int rowIndex: 0
    property bool isCompact: true
    readonly property bool expanded: wlRow.row && backend.expandedKey === String(wlRow.row.key)
    readonly property color badgeColor: Model.healthColor(wlRow.row ? wlRow.row.badgeKind : "unknown", root.foreground, root.urgent, root.accent)

    foreground: root.foreground
    implicitHeight: expanded ? (wlInner.implicitHeight + Style.space(8)) : (isCompact ? Style.space(28) : Style.space(42))
    height: implicitHeight

    Column {
      id: wlInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(4)
      spacing: Style.space(4)

      // Header row
      Item {
        width: parent.width
        height: wlRow.isCompact ? Style.space(22) : wlHeaderRow.implicitHeight

        RowLayout {
          id: wlHeaderRow
          anchors.fill: parent
          spacing: Style.space(6)

          // Status dot / glyph
          Text {
            Layout.alignment: Qt.AlignVCenter
            text: Model.statusGlyph(wlRow.row ? wlRow.row.badgeKind : "")
            color: wlRow.badgeColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // Compact or comfortable title + meta
          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: wlRow.row ? String(wlRow.row.title) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }

              // Namespace badge if viewing all namespaces
              Text {
                visible: !!(backend.activeNamespace === "*" && wlRow.row && wlRow.row.namespace)
                text: wlRow.row ? wlRow.row.namespace : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            // Comfortable mode: second line meta
            Text {
              visible: !wlRow.isCompact
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: wlRow.row ? String(wlRow.row.meta) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // Compact mode: inline metrics
          Text {
            visible: !!(wlRow.isCompact && wlRow.row && wlRow.row.rawPod)
            text: wlRow.row && wlRow.row.rawPod ? (wlRow.row.rawPod.ready + "/" + wlRow.row.rawPod.readyTotal) : ""
            color: root.foreground
            font.family: "monospace"
            font.pixelSize: Style.font.caption
          }

          Text {
            visible: !!(wlRow.isCompact && wlRow.row && wlRow.row.rawPod && wlRow.row.rawPod.restarts > 0)
            text: wlRow.row && wlRow.row.rawPod ? (wlRow.row.rawPod.restarts + "r") : ""
            color: root.urgent
            font.family: "monospace"
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            visible: !!(wlRow.isCompact && wlRow.row)
            text: wlRow.row ? String(wlRow.row.badge) : ""
            color: wlRow.badgeColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Text {
            Layout.alignment: Qt.AlignVCenter
            textFormat: Text.PlainText
            text: wlRow.expanded ? "▾" : "▸"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: if (wlRow.row) backend.toggleExpand(String(wlRow.row.key))
        }
      }

      // Expanded Detail Section
      BorderSurface {
        visible: wlRow.expanded
        width: parent.width
        implicitHeight: wlExpandedInner.implicitHeight + Style.space(16)
        radius: Style.cornerRadius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
        borderSpec: Border.controlSpec("normal", root.dim, root.accent)

        Column {
          id: wlExpandedInner
          anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
          anchors.margins: Style.space(8)
          spacing: Style.space(6)

          // Pod Containers
          Column {
            visible: !!(wlRow.row && wlRow.row.rawPod && wlRow.row.rawPod.containers && wlRow.row.rawPod.containers.length > 0)
            width: parent.width; spacing: Style.space(4)
            Text {
              text: "CONTAINERS (" + (wlRow.row && wlRow.row.rawPod ? wlRow.row.rawPod.containers.length : 0) + ")"
              color: root.dim; font.pixelSize: Style.font.caption; font.bold: true
            }
            Repeater {
              model: (wlRow.expanded && wlRow.row && wlRow.row.rawPod) ? wlRow.row.rawPod.containers : []
              BorderSurface {
                required property var modelData
                width: parent.width; implicitHeight: Style.space(26)
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.04)

                RowLayout {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6); anchors.rightMargin: Style.space(6)
                  spacing: Style.space(6)

                  Rectangle {
                    width: Style.space(6); height: Style.space(6); radius: width / 2
                    color: modelData.ready ? Model.STATUS_HEALTHY : root.urgent
                  }

                  Text {
                    text: modelData.name; color: root.foreground; font.bold: true; font.pixelSize: Style.font.caption
                  }

                  Text {
                    text: Model.shortImage(modelData.image); color: root.dim; font.family: "monospace"; font.pixelSize: Style.font.caption
                    Layout.fillWidth: true; elide: Text.ElideRight
                  }

                  Text {
                    text: modelData.state + (modelData.restarts > 0 ? (" · " + modelData.restarts + "r") : "")
                    color: modelData.restarts > 0 ? root.urgent : root.dim; font.pixelSize: Style.font.caption
                  }

                  Button {
                    text: "Logs"
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(6); verticalPadding: 1
                    bordered: true
                    onClicked: {
                      backend.setLogPod(wlRow.row.target)
                      backend.setLogContainer(modelData.name)
                      root.switchTab("logs")
                    }
                  }
                }
              }
            }
          }

          // Pod Conditions
          Column {
            visible: !!(wlRow.row && wlRow.row.rawPod && wlRow.row.rawPod.conditions && wlRow.row.rawPod.conditions.length > 0)
            width: parent.width; spacing: Style.space(4)
            Text { text: "CONDITIONS"; color: root.dim; font.pixelSize: Style.font.caption; font.bold: true }
            Flow {
              width: parent.width; spacing: Style.space(4)
              Repeater {
                model: (wlRow.expanded && wlRow.row && wlRow.row.rawPod) ? wlRow.row.rawPod.conditions : []
                BorderSurface {
                  required property var modelData
                  radius: Style.cornerRadius
                  color: modelData.status === "True" ? Qt.rgba(0.27, 0.65, 0.35, 0.15) : Qt.rgba(0.9, 0.28, 0.3, 0.18)
                  implicitWidth: condText.implicitWidth + Style.space(12); implicitHeight: Style.space(20)
                  Text {
                    id: condText; anchors.centerIn: parent
                    text: (modelData.status === "True" ? "✔ " : "✕ ") + modelData.type
                    color: modelData.status === "True" ? Model.STATUS_HEALTHY : root.urgent
                    font.pixelSize: Style.font.caption - 1
                  }
                }
              }
            }
          }

          // Generic lines (for non-pods or CRDs)
          Column {
            visible: !wlRow.row || !wlRow.row.rawPod
            width: parent.width; spacing: 2
            Repeater {
              model: (wlRow.expanded && wlRow.row && !wlRow.row.rawPod) ? wlRow.row.lines : []
              Text {
                required property var modelData
                width: parent.width; textFormat: Text.PlainText; text: String(modelData)
                color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight
              }
            }
          }

          // Action Buttons Bar
          RowLayout {
            visible: !backend.readOnly
            width: parent.width; spacing: Style.space(6)

            Button {
              visible: !!(wlRow.row && wlRow.row.targetKind === "pod")
              text: "View Logs"
              fontSize: Style.font.caption
              bordered: true
              onClicked: { backend.setLogPod(wlRow.row.target); root.switchTab("logs") }
            }

            Button {
              visible: !!(wlRow.row && (wlRow.row.targetKind === "pod" || wlRow.row.targetKind === "service"))
              text: "Port Forward"
              fontSize: Style.font.caption
              bordered: true
              selected: root.forwardFormKey === String(wlRow.row.key)
              onClicked: {
                root.fwLocal = String(wlRow.row.remoteHint || "8080")
                root.fwRemote = String(wlRow.row.remoteHint || "8080")
                root.forwardFormKey = root.forwardFormKey === String(wlRow.row.key) ? "" : String(wlRow.row.key)
              }
            }

            Button {
              visible: !!(wlRow.row && (wlRow.row.targetKind === "deployment" || wlRow.row.targetKind === "statefulset" || wlRow.row.targetKind === "daemonset"))
              text: "Restart"
              fontSize: Style.font.caption
              bordered: true
              onClicked: root.runRowAction(wlRow.row, "restart")
            }

            Item { Layout.fillWidth: true }

            Button {
              visible: !!(wlRow.row && wlRow.row.targetKind === "pod")
              text: "Delete Pod"
              fontSize: Style.font.caption
              foreground: root.urgent
              bordered: true
              onClicked: root.runRowAction(wlRow.row, "kill")
            }
          }

          // Inline Port-Forward Form
          BorderSurface {
            visible: !!(wlRow.expanded && wlRow.row && root.forwardFormKey === String(wlRow.row.key))
            width: parent.width; implicitHeight: fwFormInner.implicitHeight + Style.space(12)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            borderSpec: Border.controlSpec("normal", root.dim, root.accent)

            Column {
              id: fwFormInner
              anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
              anchors.margins: Style.space(6)
              spacing: Style.space(4)

              Text { text: "START PORT FORWARD"; color: root.dim; font.bold: true; font.pixelSize: Style.font.caption }

              RowLayout {
                width: parent.width; spacing: Style.space(4)
                Text { text: "local :"; color: root.dim; font.pixelSize: Style.font.caption }
                TextField {
                  Layout.preferredWidth: Style.space(70)
                  foreground: root.foreground; placeholderText: "8080"
                  text: root.forwardFormKey === String(wlRow.row.key) ? root.fwLocal : ""
                  onTextChanged: if (root.forwardFormKey === String(wlRow.row.key)) root.fwLocal = text
                }
                Text { text: "→ remote :"; color: root.dim; font.pixelSize: Style.font.caption }
                TextField {
                  Layout.preferredWidth: Style.space(70)
                  foreground: root.foreground; placeholderText: "80"
                  text: root.forwardFormKey === String(wlRow.row.key) ? root.fwRemote : ""
                  onTextChanged: if (root.forwardFormKey === String(wlRow.row.key)) root.fwRemote = text
                }
                Item { Layout.fillWidth: true }
                Button {
                  text: "Start"
                  selected: true; bordered: true; fontSize: Style.font.caption
                  onClicked: {
                    if (wlRow.row) backend.startForward(String(wlRow.row.targetKind), String(wlRow.row.target), root.fwLocal, root.fwRemote)
                    root.forwardFormKey = ""
                  }
                }
                Button {
                  text: "Cancel"
                  bordered: true; fontSize: Style.font.caption
                  onClicked: root.forwardFormKey = ""
                }
              }
            }
          }
        }
      }
    }
  }

  // --- EVENT ROW DELEGATE ---
  component EventRow: CursorSurface {
    id: evRow
    property var ev: null
    property int rowIndex: 0
    readonly property bool isWarning: evRow.ev && String(evRow.ev.type) === "Warning"
    readonly property color evColor: evRow.isWarning ? root.urgent : root.dim

    foreground: root.foreground
    implicitHeight: evInner.implicitHeight + Style.space(6)

    Column {
      id: evInner
      anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
      spacing: 1

      RowLayout {
        width: parent.width; spacing: Style.space(6)
        Text {
          Layout.alignment: Qt.AlignVCenter
          text: evRow.isWarning ? "▲" : "●"
          color: evRow.evColor
          font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: evRow.ev ? (String(evRow.ev.reason) + " · " + String(evRow.ev.object)) : ""
          color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
          elide: Text.ElideRight
        }
        Text {
          visible: !!(evRow.ev && evRow.ev.namespace && backend.activeNamespace === "*")
          text: evRow.ev ? String(evRow.ev.namespace) : ""
          color: root.accent; font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
        Text {
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: evRow.ev ? (String(evRow.ev.age) + (evRow.ev.count > 1 ? " · ×" + evRow.ev.count : "")) : ""
          color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
        }
      }

      Text {
        width: parent.width
        visible: !!(evRow.ev && String(evRow.ev.message) !== "")
        textFormat: Text.PlainText
        text: evRow.ev ? String(evRow.ev.message) : ""
        color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap; maximumLineCount: 2; elide: Text.ElideRight
      }
    }
  }

  // --- PORT FORWARD ROW DELEGATE ---
  component FwRow: CursorSurface {
    id: fwRow
    property int fid: -1
    property string label: ""
    property string sub: ""

    foreground: root.foreground
    implicitHeight: Style.space(38)

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(6)
      spacing: Style.space(6)

      Text {
        text: "⇄"; color: root.accent; font.pixelSize: Style.font.bodySmall
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true; spacing: 0
        Text {
          Layout.fillWidth: true; textFormat: Text.PlainText; text: fwRow.label
          color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall; font.bold: true
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true; textFormat: Text.PlainText; text: fwRow.sub
          color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        text: "Stop"
        foreground: root.urgent
        fontSize: Style.font.caption
        bordered: true
        onClicked: backend.stopForward(fwRow.fid)
      }
    }
  }

  // --- QUICK CONTEXT ROW DELEGATE ---
  component QuickRow: CursorSurface {
    id: qRow
    property var ctx: null
    property int rowIndex: 0
    readonly property bool isActive: ctx && String(ctx.name) === backend.activeContextName

    foreground: root.foreground
    hasCursor: root.quickIndex === rowIndex
    current: isActive
    implicitHeight: Style.space(32)

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(8); anchors.rightMargin: Style.space(8)
      spacing: Style.space(6)

      Rectangle {
        width: Style.space(6); height: Style.space(6); radius: width / 2
        color: Model.healthColor(qRow.ctx ? qRow.ctx.health : "unknown", root.foreground, root.urgent, root.accent)
      }

      Text {
        Layout.fillWidth: true; textFormat: Text.PlainText; text: qRow.ctx ? String(qRow.ctx.name) : ""
        color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.bodySmall
        font.bold: qRow.isActive; elide: Text.ElideRight
      }
    }
    MouseArea {
      anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
      onEntered: root.quickIndex = qRow.rowIndex
      onClicked: if (qRow.ctx) { backend.setContext(qRow.ctx.name); root.closeAll() }
    }
  }

  // --- CHIP COMPONENT ---
  component Chip: CursorSurface {
    id: chip
    signal clicked()
    property string label: ""
    property bool active: false
    property bool danger: false

    foreground: root.foreground
    current: chip.active
    implicitWidth: chipLabel.implicitWidth + Style.space(12)
    implicitHeight: Style.space(22)

    Text {
      id: chipLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chip.label
      color: chip.danger ? root.urgent : (chip.active ? root.foreground : root.dim)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: chip.active || chip.danger
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }
}
