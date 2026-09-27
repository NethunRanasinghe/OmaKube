import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// OmaKube — single bar-widget entry point. The ONLY UI surface is the
// anchored popup below: pill (left-click) -> full popup, pill
// (right-click) -> quick context switcher. Rendered in-process by
// omarchy-shell as a KeyboardPanel layer-shell popup — never a separate
// top-level window, never `omarchy-shell shell summon`. Verify with:
//   hyprctl clients   # opening the popup must add no new client
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

  property bool quickOpened: false
  property string toast: backend.actionStatus
  property int quickIndex: 0
  property string activeTab: "Pods"
  readonly property var wlTabs: ["Pods", "Deploy", "STS", "DS", "Svc", "Jobs", "Events", "Logs"]
  readonly property var resourceTabs: ["Pods", "Deploy", "STS", "DS", "Svc", "Jobs"]
  property string topMode: "workloads" // "workloads" | "events" | "logs"
  onTopModeChanged: {
    if (topMode === "logs") ensureLogPod()
    else if (topMode === "events") backend.fetchEvents()
  }
  property string selectedResourceKind: "all"
  property string sortMode: "Status" // Status | Name | Age
  property string logSearch: ""
  property int currentMatchLine: -1
  property string forwardFormKey: ""
  property string fwLocal: ""
  property string fwRemote: ""
  property bool settingsOpen: false
  property bool contextsOpen: false
  property bool namespacesOpen: false
  // Pending destructive confirmation: {op, kind, name, label}
  property var confirmState: null
  readonly property var logPalette: ({
    text: String(foreground), dim: String(dim), error: String(urgent),
    warn: "#d9a13b", match: "rgba(217,161,59,0.45)", matchCurrent: "rgba(229,72,77,0.65)"
  })

  function isResourceTab() {
    return topMode === "workloads"
  }

  function switchTab(tab) {
    if (tab === "Events") {
      topMode = "events"
      backend.fetchEvents()
    } else if (tab === "Logs") {
      topMode = "logs"
      ensureLogPod()
    } else {
      topMode = "workloads"
      selectedResourceKind = String(tab || "all").toLowerCase()
    }
    backend.expandedKey = ""
    pulseWlList()
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
      { key: "jobs", label: "Jobs" }
    ]
    var out = []
    var seen = {}
    for (var i = 0; i < standard.length; i++) {
      var item = standard[i]
      var list = w[item.key]
      if (list instanceof Array && list.length > 0) {
        out.push({ id: item.key, label: item.label, count: list.length })
        seen[item.key] = true
      }
    }
    for (var k in w) {
      if (k === "namespace" || seen[k]) continue
      var customList = w[k]
      if (customList instanceof Array && customList.length > 0) {
        var cap = k.charAt(0).toUpperCase() + k.slice(1)
        out.push({ id: k, label: cap, count: customList.length })
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

  // Gentle fade for user-initiated list changes only — background polls
  // update the models silently, which is what killed the flashing.
  function pulseWlList() {
    if (!wlColumn) return
    wlListFade.stop()
    wlColumn.opacity = 0.35
    wlListFade.restart()
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

  function rowActions(r) {
    // Which mutating/navigating chips an expanded row offers.
    if (!r || r.targetKind === "") return []
    if (r.targetKind === "pod") return ["logs", "forward", "kill"]
    if (r.targetKind === "service") return ["forward"]
    return ["restart", "forward"]
  }

  function actionLabel(a) {
    if (a === "logs") return "Logs"
    if (a === "forward") return "Forward"
    if (a === "kill") return "Kill pod"
    if (a === "restart") return "Restart"
    return a
  }

  function runRowAction(r, a) {
    if (!r) return
    if (a === "logs") {
      backend.setLogPod(String(r.target))
      root.topMode = "logs"
      return
    }
    if (a === "forward") {
      root.fwLocal = String(r.remoteHint || "")
      root.fwRemote = String(r.remoteHint || "")
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

  function wlItems(tab) {
    var w = backend.workloads
    if (!w) return []
    if (tab === "Pods") return w.pods || []
    if (tab === "Deploy") return w.deployments || []
    if (tab === "STS") return w.statefulsets || []
    if (tab === "DS") return w.daemonsets || []
    if (tab === "Svc") return w.services || []
    if (tab === "Jobs") return w.jobs || []
    return []
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
    if (kLower === "pods" || kLower === "pod") {
      return {
        key: "pod/" + it.name, kind: it.kind, title: it.name,
        typeLabel: "Pod",
        badge: it.display, badgeKind: it.kind,
        meta: it.ready + "/" + it.readyTotal + " ready · " + it.restarts + " restarts · " + it.age + " · " + (it.node || "?"),
        ageSeconds: it.ageSeconds || 0, sev: sevOf(it.kind),
        targetKind: "pod", target: it.name, remoteHint: 80,
        rawPod: it,
        lines: podLines(it)
      }
    }
    if (kLower === "services" || kLower === "svc") {
      return {
        key: "svc/" + it.name, kind: "running", title: it.name,
        typeLabel: "Service",
        badge: it.type, badgeKind: "running",
        meta: (it.clusterIP || "") + " · " + (it.ports || "") + " · " + it.age,
        ageSeconds: it.ageSeconds || 0, sev: 2,
        targetKind: "service", target: it.name, remoteHint: Model.firstPort(it.ports),
        rawItem: it,
        lines: ["Type: " + it.type, "ClusterIP: " + (it.clusterIP || "—"), "Ports: " + (it.ports || "—"), "Age: " + it.age]
      }
    }
    if (kLower === "jobs" || kLower === "job") {
      var jk = it.statusKind || "waiting"
      return {
        key: "job/" + it.name, kind: jk, title: it.name + (it.kind === "CronJob" ? "  ◷ " + (it.schedule || "") : ""),
        typeLabel: it.kind || "Job",
        badge: it.display, badgeKind: jk,
        meta: it.kind + " · A" + it.active + "/S" + it.succeeded + "/F" + it.failed + " · " + it.age,
        ageSeconds: it.ageSeconds || 0, sev: sevOf(jk),
        targetKind: "", target: "", remoteHint: 0,
        rawItem: it,
        lines: [(it.schedule ? ("Schedule: " + it.schedule) : ""), "Active: " + it.active + " · Succeeded: " + it.succeeded + " · Failed: " + it.failed, "Age: " + it.age].filter(function(s){return s !== ""})
      }
    }
    // Deploy / STS / DS scale rows
    var tk = kLower.indexOf("sts") >= 0 || kLower.indexOf("stateful") >= 0 ? "statefulset"
      : (kLower.indexOf("ds") >= 0 || kLower.indexOf("daemon") >= 0 ? "daemonset" : "deployment")
    var typeLabel = tk === "statefulset" ? "StatefulSet" : (tk === "daemonset" ? "DaemonSet" : "Deployment")
    if (kLower === "deployments" || kLower === "deploy" || kLower === "statefulsets" || kLower === "sts" || kLower === "daemonsets" || kLower === "ds") {
      return {
        key: tk + "/" + it.name, kind: it.kind, title: it.name,
        typeLabel: typeLabel,
        badge: it.display, badgeKind: it.kind,
        meta: it.ready + "/" + it.desired + " ready · upd " + it.updated + " · avail " + it.available + " · " + it.age,
        ageSeconds: it.ageSeconds || 0, sev: sevOf(it.kind),
        targetKind: tk, target: it.name, remoteHint: 80,
        rawItem: it,
        lines: ["Ready: " + it.ready + "/" + it.desired, "Updated: " + it.updated + " · Available: " + it.available, "Age: " + it.age]
      }
    }
    // Generic / Custom Resource Definition (CRD) row!
    return {
      key: kind + "/" + (it.name || "item"),
      kind: it.kind || "running",
      title: it.name || "item",
      typeLabel: it.type || kind,
      badge: it.display || it.kind || it.status || "Ready",
      badgeKind: it.kind || "running",
      meta: (it.meta || it.age || it.namespace || ""),
      ageSeconds: it.ageSeconds || 0,
      sev: sevOf(it.kind),
      targetKind: kind,
      target: it.name || "",
      remoteHint: 80,
      rawItem: it,
      lines: genericLines(it)
    }
  }

  function genericLines(it) {
    var out = []
    if (it.age) out.push("Age: " + it.age)
    for (var k in it) {
      if (k === "name" || k === "kind" || k === "display" || k === "age" || k === "ageSeconds") continue
      var val = it[k]
      if (typeof val === "string" || typeof val === "number" || typeof val === "boolean") {
        out.push(k + ": " + val)
      }
    }
    return out
  }

  function podLines(p) {
    var out = ["Node " + (p.node || "?") + " · IP " + (p.podIP || "—") + " · Age " + p.age]
    var cs = p.containers || []
    for (var i = 0; i < cs.length; i++) {
      var c = cs[i]
      var img = String(c.image || "")
      var short = img.indexOf("/") >= 0 ? img.slice(img.lastIndexOf("/") + 1) : img
      out.push((c.ready ? "● " : "○ ") + c.name + " (" + short + ") · " + c.state + (c.restarts > 0 ? " · " + c.restarts + " restarts" : ""))
    }
    var conds = p.conditions || []
    var bits = []
    for (var j = 0; j < conds.length; j++) {
      var cnd = conds[j]
      if (cnd.status === "True") bits.push("✔ " + cnd.type)
      else bits.push("✕ " + cnd.type)
    }
    if (bits.length > 0) out.push(bits.join("  "))
    return out
  }

  function filteredWorkloads() {
    if (topMode !== "workloads") return []
    var w = backend.workloads
    if (!w) return []
    var kinds = availableResourceKinds()
    var rows = []
    var q = searchField.text.trim().toLowerCase()

    for (var i = 0; i < kinds.length; i++) {
      var kid = kinds[i].id
      if (selectedResourceKind !== "all" && selectedResourceKind !== kid) continue
      var list = w[kid] || []
      for (var j = 0; j < list.length; j++) {
        var r = normRow(kid, list[j])
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
    var q = searchField.text.trim().toLowerCase()
    var out = []
    var evs = backend.events || []
    for (var i = 0; i < evs.length; i++) {
      var e = evs[i]
      if (q !== "") {
        var hay = (String(e.reason || "") + " " + String(e.object || "") + " " + String(e.message || "")).toLowerCase()
        if (hay.indexOf(q) === -1) continue
      }
      out.push(e)
    }
    return out
  }

  function toggleFull() {
    quickOpened = false
    root.toggle()
  }

  function toggleQuick() {
    if (root.opened) root.close()
    quickOpened = !quickOpened
    backend.setPopupOpen(root.opened || quickOpened)
    if (quickOpened) Qt.callLater(function() { if (quickKeys) quickKeys.forceActiveFocus() })
  }

  function closeAll() {
    quickOpened = false
    backend.setPopupOpen(false)
    root.close()
  }

  // Merge a patch into this widget's shell.json entry (persists
  // lastContext + per-context accents across restarts). Same mechanism
  // native panels use; values flow back in as root.settings.
  function persistSettings(patch) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var p in patch) entry[p] = patch[p]
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  implicitWidth: pill.implicitWidth
  implicitHeight: pill.implicitHeight

  onOpenedChanged: {
    backend.setPopupOpen(opened || quickOpened)
    if (opened) {
      quickOpened = false
      backend.refresh(false)
      Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
      // Springy entrance for the content (the card itself already fades
      // natively in 140ms OutCubic — this scale runs on top, never blocks).
      popupContent.scale = 0.96
      popupContent.opacity = 0.0
      entrance.restart()
    }
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
    function onActiveNamespaceChanged() { root.pulseWlList() }
    function onWorkloadsFreshChanged() {
      if (backend.workloadsFresh && root.topMode === "logs" && backend.logPod === "") {
        root.ensureLogPod()
      }
    }
  }

  NumberAnimation {
    id: wlListFade
    target: wlColumn
    property: "opacity"
    to: 1.0
    duration: 160
    easing.type: Easing.OutCubic
  }

  // Log follow polling: tail refreshes while the Logs tab is open.
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
    function setMode(mode: string): void { root.topMode = mode }
    function setLogPod(pod: string): void { backend.setLogPod(pod); root.topMode = "logs" }
  }

  // ---- bar pill: k8s mark + health dot + short label, sized to content ----
  // The button's width tracks the row (capped) so long context names can
  // never paint over neighboring widgets; the label itself elides.
  WidgetButton {
    id: pill
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    implicitWidth: Math.min(pillRow.implicitWidth + scaledHorizontalMargin * 2, Style.space(168))
    tooltipText: (backend.activeContextName || "kubernetes") + " · " + backend.healthStatus

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
        border.width: 1
        border.color: Qt.rgba(0, 0, 0, 0.35)
        // Idle pulse ONLY when degraded — healthy stays calm/static.
        SequentialAnimation on opacity {
          running: backend.healthStatus === "degraded" || backend.healthStatus === "down"
          loops: Animation.Infinite
          NumberAnimation { to: 0.45; duration: 700; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutQuad }
        }
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

  // ---- the product: full popup anchored under the pill ----
  KeyboardPanel {
    id: panel
    anchorItem: pill
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: Math.min(Style.space(520), panel.fittedContentWidth(Style.space(520)))
    contentHeight: panel.fittedContentHeight(column.implicitHeight + Style.space(20), Style.space(640))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.confirmState !== null
      onCloseRequested: root.closeAll()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "/") searchField.forceActiveFocus()
        else if (t === "r" || t === "R") backend.refresh(true)
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight + Style.space(20)
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        // Entrance wrapper: springy scale+fade, never blocks clicks.
        Item {
          id: popupContent
          width: column.width
          height: column.height

          SequentialAnimation {
            id: entrance
            ParallelAnimation {
              NumberAnimation { target: popupContent; property: "scale"; from: 0.96; to: 1.0; duration: 180; easing.type: Easing.OutBack }
              NumberAnimation { target: popupContent; property: "opacity"; from: 0.0; to: 1.0; duration: 140; easing.type: Easing.OutCubic }
            }
          }
          transformOrigin: Item.Top

          Column {
            id: column
            width: panel.contentWidth - Style.spacing.popupPadding * 2 - Style.space(4)
            spacing: Style.space(12)

            // ---- context hero: quiet mark + status, no glow, no ring ----
            PanelHero {
              id: hero
              width: parent.width
              title: backend.activeContextName || "no context"
              meta: (backend.activeNamespace || "default").toUpperCase() + " · " + String(backend.healthStatus).toUpperCase()
              detail: backend.heroDetail()
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconComponent: Component {
                Item {
                  width: Style.space(30)
                  height: Style.space(30)
                  // Calm refresh indicator: one slow revolution (~2.6s),
                  // eased back to rest instead of snapping.
                  Item {
                    id: heroSpin
                    anchors.centerIn: parent
                    width: Style.space(24)
                    height: Style.space(24)
                    property bool spinning: backend.refreshing
                    onSpinningChanged: {
                      if (spinning) { rotation = 0; spinLoop.restart() }
                      else { spinLoop.stop(); spinFinish.from = rotation; spinFinish.restart() }
                    }
                    NumberAnimation {
                      id: spinLoop
                      target: heroSpin
                      property: "rotation"
                      from: 0
                      to: 360
                      duration: 2600
                      loops: Animation.Infinite
                    }
                    NumberAnimation {
                      id: spinFinish
                      target: heroSpin
                      property: "rotation"
                      to: 360
                      duration: 300
                      easing.type: Easing.OutCubic
                      onFinished: heroSpin.rotation = 0
                    }
                    OmakubeIcon {
                      anchors.fill: parent
                      iconSize: Style.space(24)
                      color: root.foreground
                      opacityLevel: 0.95
                    }
                  }
                  Rectangle {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    width: Style.space(10)
                    height: Style.space(10)
                    radius: width / 2
                    color: root.healthDot
                    border.width: 2
                    border.color: Color.background
                  }
                }
              }
            }

            Text {
              visible: backend.actionStatus !== "" || backend.lastError !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: backend.actionStatus !== "" ? backend.actionStatus : Model.humanError(backend.lastError)
              color: backend.lastError !== "" && backend.actionStatus === "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            // ---- search (instant, reachable via /) ----
            TextField {
              id: searchField
              width: parent.width
              foreground: root.foreground
              placeholderText: "Filter workloads…  ( / )"
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { clear(); keyCatcher.forceActiveFocus(); event.accepted = true }
              }
            }

            // ---- namespace switcher ----
            Column {
              visible: backend.namespaces.length > 0
              width: parent.width
              spacing: Style.space(6)

              SectionToggle {
                title: "NAMESPACES"
                badge: backend.activeNamespace
                open: root.namespacesOpen
                onToggled: root.namespacesOpen = !root.namespacesOpen
              }

              Flickable {
                visible: root.namespacesOpen
                width: parent.width
                height: nsRow.height
                contentWidth: nsRow.width
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.HorizontalFlick
                interactive: contentWidth > width
                Row {
                  id: nsRow
                  spacing: Style.space(6)
                  Repeater {
                    model: backend.namespaces
                    NsChip {
                      required property var modelData
                      width: implicitWidth
                      ns: modelData
                    }
                  }
                }
              }
            }

            // ---- top mode bar: Workloads | Events | Logs ----
            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Button {
                Layout.fillWidth: true
                text: "Workloads (" + root.totalWorkloadCount() + ")"
                fontSize: Style.font.bodySmall
                selected: root.topMode === "workloads"
                bordered: true
                onClicked: root.topMode = "workloads"
              }

              Button {
                Layout.fillWidth: true
                text: "Events (" + (backend.events ? backend.events.length : 0) + ")"
                fontSize: Style.font.bodySmall
                selected: root.topMode === "events"
                bordered: true
                onClicked: {
                  root.topMode = "events"
                  backend.fetchEvents()
                }
              }

              Button {
                Layout.fillWidth: true
                text: "Logs"
                fontSize: Style.font.bodySmall
                selected: root.topMode === "logs"
                bordered: true
                onClicked: {
                  root.topMode = "logs"
                  root.ensureLogPod()
                }
              }
            }

            // ---- workloads skeleton ----
            Column {
              visible: root.topMode === "workloads" && backend.workloadsLoading && !backend.workloadsFresh
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: 3
                Rectangle {
                  width: parent.width
                  height: Style.space(34)
                  radius: Style.cornerRadius
                  color: root.dim
                  opacity: 0.25
                  SequentialAnimation on opacity {
                    running: visible
                    loops: Animation.Infinite
                    NumberAnimation { to: 0.12; duration: 600; easing.type: Easing.InOutQuad }
                    NumberAnimation { to: 0.25; duration: 600; easing.type: Easing.InOutQuad }
                  }
                }
              }
            }

            // ---- workloads: kind filters + list ----
            Column {
              visible: root.topMode === "workloads" && backend.workloadsFresh && backend.workloadsError === ""
              width: parent.width
              spacing: Style.space(8)

              // Dynamic Resource Kinds filter bar (Pods, Deployments, Services, CRDs, etc.)
              Flickable {
                id: kindFlick
                width: parent.width
                height: kindRow.height
                contentWidth: kindRow.width
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.HorizontalFlick
                interactive: contentWidth > width

                Row {
                  id: kindRow
                  spacing: Style.space(6)

                  Chip {
                    label: "All (" + root.totalWorkloadCount() + ")"
                    active: root.selectedResourceKind === "all"
                    onClicked: root.selectedResourceKind = "all"
                  }

                  Repeater {
                    model: root.availableResourceKinds()
                    Chip {
                      required property var modelData
                      label: modelData.label + " (" + modelData.count + ")"
                      active: root.selectedResourceKind === modelData.id
                      onClicked: root.selectedResourceKind = modelData.id
                    }
                  }
                }
              }

              RowLayout {
                width: parent.width
                Text {
                  textFormat: Text.PlainText
                  text: (root.selectedResourceKind === "all" ? "All workloads" : root.selectedResourceKind.toUpperCase()) + " in " + backend.activeNamespace
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Item { Layout.fillWidth: true; height: 1 }
                Text {
                  textFormat: Text.PlainText
                  text: "Sort: " + root.sortMode + " ▾"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.cycleSort()
                  }
                }
              }

              Column {
                id: wlColumn
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.filteredWorkloads()
                  WorkloadRow {
                    required property var modelData
                    required property int index
                    width: wlColumn.width
                    row: modelData
                    rowIndex: index
                  }
                }
              }

              // Empty state
              Column {
                visible: root.filteredWorkloads().length === 0
                width: parent.width
                spacing: Style.space(4)
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: "○"
                  color: root.dim
                  font.pixelSize: Style.font.display
                }
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: searchField.text.trim() !== "" ? "No match for “" + searchField.text.trim() + "”" : "No resources found in " + backend.activeNamespace
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: (root.selectedResourceKind === "all" ? "All types" : root.selectedResourceKind) + " · " + backend.activeNamespace
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // ---- events view ----
            Column {
              visible: root.topMode === "events"
              width: parent.width
              spacing: Style.space(6)

              RowLayout {
                width: parent.width
                Text {
                  textFormat: Text.PlainText
                  text: "Events in " + backend.activeNamespace
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
                Item { Layout.fillWidth: true; height: 1 }
                Button {
                  text: "Refresh"
                  fontSize: Style.font.caption
                  horizontalPadding: Style.space(8)
                  verticalPadding: Style.space(2)
                  bordered: true
                  onClicked: backend.fetchEvents()
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: root.filteredEvents()
                  EventRow {
                    required property var modelData
                    required property int index
                    width: parent.width
                    ev: modelData
                    rowIndex: index
                  }
                }
              }

              Column {
                visible: !backend.eventsLoading && root.filteredEvents().length === 0
                width: parent.width
                spacing: Style.space(4)
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: "○"
                  color: root.dim
                  font.pixelSize: Style.font.display
                }
                Text {
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  textFormat: Text.PlainText
                  text: "No events in " + backend.activeNamespace
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
            }

            // ---- logs view ----
            Column {
              visible: root.topMode === "logs"
              width: parent.width
              spacing: Style.space(8)

              // Pod picker
              Column {
                width: parent.width
                spacing: Style.space(4)
                Text {
                  text: "SELECT POD"
                  color: root.dim
                  font.bold: true
                  font.pixelSize: Style.font.caption
                }
                Flickable {
                  width: parent.width
                  height: logPodRow.height
                  contentWidth: logPodRow.width
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  flickableDirection: Flickable.HorizontalFlick
                  interactive: contentWidth > width
                  Row {
                    id: logPodRow
                    spacing: Style.space(4)
                    Repeater {
                      model: (backend.workloads && backend.workloads.pods) || []
                      Chip {
                        required property var modelData
                        label: String(modelData.name)
                        active: backend.logPod === String(modelData.name)
                        onClicked: backend.setLogPod(String(modelData.name))
                      }
                    }
                  }
                }
              }

              // Container picker (if pod has multiple containers)
              Column {
                visible: backend.logContainers.length > 1
                width: parent.width
                spacing: Style.space(4)
                Text {
                  text: "CONTAINER"
                  color: root.dim
                  font.bold: true
                  font.pixelSize: Style.font.caption
                }
                Row {
                  id: logCtrRow
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
              }

              // Log Search input
              RowLayout {
                width: parent.width
                spacing: Style.space(4)
                TextField {
                  id: logSearchField
                  Layout.fillWidth: true
                  foreground: root.foreground
                  placeholderText: "Search in logs…"
                  text: root.logSearch
                  onTextChanged: {
                    root.logSearch = text
                    root.currentMatchLine = -1
                    var m = root.logMatchLines()
                    if (m.length > 0) {
                      root.currentMatchLine = m[0]
                      root.scrollLogTo(m[0])
                    }
                  }
                  Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Escape) { clear(); keyCatcher.forceActiveFocus(); event.accepted = true }
                    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { root.stepMatch(1); event.accepted = true }
                  }
                }
                Text {
                  visible: root.logSearch.trim() !== ""
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
                Button {
                  text: "‹"
                  fontSize: Style.font.bodySmall
                  horizontalPadding: Style.space(8)
                  bordered: true
                  onClicked: root.stepMatch(-1)
                }
                Button {
                  text: "›"
                  fontSize: Style.font.bodySmall
                  horizontalPadding: Style.space(8)
                  bordered: true
                  onClicked: root.stepMatch(1)
                }
              }

              // Controls: Live Follow, Reload, Export
              RowLayout {
                width: parent.width
                spacing: Style.space(6)
                Button {
                  text: backend.logFollow ? "Live: ON" : "Live: OFF"
                  selected: backend.logFollow
                  bordered: true
                  onClicked: {
                    backend.logFollow = !backend.logFollow
                    if (backend.logFollow) { backend.fetchLogs(); root.scrollLogToBottom() }
                  }
                }
                Button {
                  text: "Reload"
                  bordered: true
                  onClicked: backend.fetchLogs()
                }
                Button {
                  text: "Export"
                  bordered: true
                  onClicked: backend.exportLogs(String(backend.setting("logExportDir", "") || ""))
                }
                Item { Layout.fillWidth: true; height: 1 }
                Text {
                  visible: backend.logPod !== ""
                  textFormat: Text.PlainText
                  text: backend.logPod + (backend.logContainer !== "" ? " / " + backend.logContainer : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              // Terminal container
              BorderSurface {
                width: parent.width
                height: Style.space(320)
                radius: Style.cornerRadius
                color: Color.surface || "#111318"
                borderSpec: Border.controlSpec("normal", root.dim, root.accent)
                clip: true

                Flickable {
                  id: logFlick
                  anchors.fill: parent
                  anchors.margins: Style.space(8)
                  contentWidth: width
                  contentHeight: logLinesColumn.implicitHeight
                  clip: true
                  boundsBehavior: Flickable.StopAtBounds
                  flickableDirection: Flickable.VerticalFlick
                  ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                  Column {
                    id: logLinesColumn
                    width: logFlick.width
                    spacing: 2
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
              }

              Text {
                visible: backend.logsLoading
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: "Loading logs for " + backend.logPod + "…"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                visible: !backend.logsLoading && backend.logPod !== "" && backend.logLines.length === 0
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: "No log output for " + backend.logPod
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                visible: backend.logPod === ""
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: "Pick a pod above to tail its logs"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            // ---- workloads error (distinct from empty) ----
            Column {
              visible: backend.workloadsError !== ""
              width: parent.width
              spacing: Style.space(4)
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "■"
                color: root.urgent
                font.pixelSize: Style.font.display
              }
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: "Couldn't load workloads"
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                textFormat: Text.PlainText
                text: backend.workloadsError
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            PanelSeparator { foreground: root.foreground }

            // ---- active port-forwards ----
            Column {
              visible: backend.forwards.count > 0
              width: parent.width
              spacing: Style.space(8)
              PanelSectionHeader { text: "PORT FORWARDS"; foreground: root.foreground; fontFamily: root.fontFamily }

              Column {
                id: fwColumn
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: backend.forwards
                  FwRow {
                    required property int fid
                    required property string targetKind
                    required property string target
                    required property string pod
                    required property int localPort
                    required property int remotePort
                    required property bool ready
                    width: fwColumn.width
                    fid: fid
                    label: ready ? ("localhost:" + localPort + " → " + targetKind + "/" + target)
                                 : ("starting → " + targetKind + "/" + target + "…")
                    sub: pod !== "" ? ("pod " + pod + " · remote :" + remotePort) : ("remote :" + remotePort)
                  }
                }
              }

              Row {
                width: parent.width
                Chip {
                  label: "Stop all"
                  danger: true
                  onClicked: backend.stopAllForwards()
                }
              }
            }

            PanelSeparator { visible: backend.forwards.count > 0; foreground: root.foreground }

            // ---- settings (collapsible) ----
            Column {
              width: parent.width
              spacing: Style.space(8)

              SectionToggle {
                title: "SETTINGS"
                open: root.settingsOpen
                onToggled: root.settingsOpen = !root.settingsOpen
              }

              Column {
                visible: root.settingsOpen
                width: parent.width
                spacing: Style.space(8)

                Column {
                  width: parent.width
                  spacing: Style.space(2)
                  Text {
                    textFormat: Text.PlainText
                    text: "Kubeconfig override"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  TextField {
                    width: parent.width
                    foreground: root.foreground
                    placeholderText: "Empty = $KUBECONFIG / ~/.kube/config"
                    text: String(backend.setting("kubeconfigPath", "") || "")
                    onAccepted: {
                      backend.persist({ kubeconfigPath: text.trim() })
                      backend.refresh(true)
                      keyCatcher.forceActiveFocus()
                    }
                  }
                }

                Column {
                  width: parent.width
                  spacing: Style.space(2)
                  Text {
                    textFormat: Text.PlainText
                    text: "Default namespace"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  TextField {
                    width: parent.width
                    foreground: root.foreground
                    placeholderText: "default"
                    text: String(backend.setting("defaultNamespace", "") || "")
                    onAccepted: {
                      backend.persist({ defaultNamespace: text.trim() })
                      keyCatcher.forceActiveFocus()
                    }
                  }
                }

                Column {
                  width: parent.width
                  spacing: Style.space(2)
                  Text {
                    textFormat: Text.PlainText
                    text: "Log export directory"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  TextField {
                    width: parent.width
                    foreground: root.foreground
                    placeholderText: "~/omakube-logs"
                    text: String(backend.setting("logExportDir", "") || "")
                    onAccepted: {
                      backend.persist({ logExportDir: text.trim() })
                      keyCatcher.forceActiveFocus()
                    }
                  }
                }

                RowLayout {
                  width: parent.width
                  Text {
                    Layout.fillWidth: true
                    textFormat: Text.PlainText
                    text: "Refresh interval (s)"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  NumberField {
                    value: backend.refreshIntervalSec
                    from: 5
                    to: 3600
                    stepSize: 5
                    foreground: root.foreground
                    onModified: function(v) { backend.persist({ refreshIntervalSec: v }) }
                  }
                }

                RowLayout {
                  width: parent.width
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                      textFormat: Text.PlainText
                      text: "Read-only mode"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: "Disables restart, kill and port-forward"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                  ToggleSwitch {
                    checked: backend.readOnly
                    foreground: root.foreground
                    onToggled: backend.persist({ readOnly: !backend.readOnly })
                  }
                }

                RowLayout {
                  width: parent.width
                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    Text {
                      textFormat: Text.PlainText
                      text: "Debug logging"
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: "Verbose backend output for auth issues"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                  ToggleSwitch {
                    checked: backend.debugLogging
                    foreground: root.foreground
                    onToggled: backend.persist({ debugLogging: !backend.debugLogging })
                  }
                }

                Column {
                  width: parent.width
                  spacing: Style.space(4)
                  Text {
                    textFormat: Text.PlainText
                    text: "Context accent colors"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Repeater {
                    model: backend.contexts
                    RowLayout {
                      required property var modelData
                      width: parent.width
                      spacing: Style.space(8)
                      Rectangle {
                        width: Style.space(12)
                        height: Style.space(12)
                        radius: width / 2
                        Layout.alignment: Qt.AlignVCenter
                        color: modelData.accent || root.accent
                        MouseArea {
                          anchors.fill: parent
                          hoverEnabled: true
                          cursorShape: Qt.PointingHandCursor
                          onClicked: backend.cycleAccent(String(modelData.name))
                        }
                      }
                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: String(modelData.name)
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }
                      Text {
                        textFormat: Text.PlainText
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

            PanelSeparator { foreground: root.foreground }

            Column {
              width: parent.width
              spacing: Style.space(8)

              SectionToggle {
                title: "CONTEXTS"
                badge: backend.contexts.length > 0 ? (backend.contexts.length + " available") : ""
                open: root.contextsOpen
                onToggled: root.contextsOpen = !root.contextsOpen
              }

              Column {
                id: ctxColumn
                visible: root.contextsOpen
                width: parent.width
                spacing: Style.space(6)
                Repeater {
                  model: backend.contexts
                  ContextRow {
                    required property var modelData
                    required property int index
                    width: ctxColumn.width
                    ctx: modelData
                    rowIndex: index
                  }
                }
              }
            }

            Item {
              width: parent.width
              height: Style.space(6)
            }
          }
        }
      }
    }

    // Destructive-action confirmation: names the exact resource +
    // namespace + context before anything mutates.
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
            // Fresh eyes on the result as soon as it lands.
            Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
          }
        }
      }
    }
  }

  // ---- forward runners: one process per active forward ----
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
          "--context", backend.activeContextName, "--namespace", backend.activeNamespace,
          "--target-kind", fwProc.targetKind, "--target", fwProc.target,
          "--local-port", fwProc.localPort, "--remote-port", fwProc.remotePort,
          "--timeout", "10"].concat(backend.kubeconfigArgs())
        fwProc.started = true
      }
    }
  }

  // ---- right-click: lightweight quick context switcher only ----
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
        spacing: Style.space(6)
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

  // ---- rows ----
  component ContextRow: CursorSurface {
    id: ctxRow
    property var ctx: null
    property int rowIndex: 0
    readonly property bool isActive: ctx && String(ctx.name) === backend.activeContextName

    foreground: root.foreground
    current: isActive
    implicitHeight: Style.space(46)

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 1
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: ctxRow.ctx ? String(ctxRow.ctx.name) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: ctxRow.isActive
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: Model.contextSubtitle(ctxRow.ctx)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        Layout.alignment: Qt.AlignVCenter
        text: Model.statusGlyph(ctxRow.ctx ? ctxRow.ctx.health : "")
        color: Model.healthColor(ctxRow.ctx ? ctxRow.ctx.health : "unknown", root.foreground, root.urgent, root.accent)
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (ctxRow.ctx) { backend.setContext(ctxRow.ctx.name) }
    }
  }

  component NsChip: CursorSurface {
    id: nsChip
    property var ns: null
    readonly property string nsName: nsChip.ns ? String(nsChip.ns.name) : ""
    readonly property bool isActive: nsChip.nsName !== "" && nsChip.nsName === backend.activeNamespace
    readonly property int failing: nsChip.ns ? (nsChip.ns.failing || 0) : 0
    readonly property int pending: nsChip.ns ? (nsChip.ns.pending || 0) : 0

    foreground: root.foreground
    current: isActive
    implicitWidth: nsLabel.implicitWidth + Style.space(20)
    implicitHeight: Style.space(30)

    Text {
      id: nsLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: nsChip.nsName + (nsChip.failing > 0 ? " · " + nsChip.failing + "✕" : "")
      color: nsChip.failing > 0 ? root.urgent : (nsChip.pending > 0 ? Qt.rgba(0.85, 0.63, 0.23, 1) : root.foreground)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: nsChip.isActive
    }

    MouseArea {
      id: nsMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: if (nsChip.nsName !== "") backend.setNamespace(nsChip.nsName)
    }

    PanelToolTip {
      visible: nsMouse.containsMouse
      text: nsChip.nsName + " · " + (nsChip.ns ? nsChip.ns.pods : 0) + " pods"
      fontFamily: root.fontFamily
    }
  }

  component WorkloadRow: CursorSurface {
    id: wlRow
    property var row: null
    property int rowIndex: 0
    readonly property bool expanded: wlRow.row && backend.expandedKey === String(wlRow.row.key)
    readonly property color badgeColor: Model.healthColor(wlRow.row ? wlRow.row.badgeKind : "unknown", root.foreground, root.urgent, root.accent)

    foreground: root.foreground
    height: implicitHeight
    implicitHeight: wlInner.implicitHeight + Style.space(8)

    Column {
      id: wlInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(8)
      spacing: Style.space(6)

      // Header row
      Item {
        id: wlHeaderArea
        width: parent.width
        implicitHeight: wlHeaderRow.implicitHeight

        RowLayout {
          id: wlHeaderRow
          anchors.fill: parent
          spacing: Style.space(8)

          Text {
            Layout.alignment: Qt.AlignVCenter
            text: Model.statusGlyph(wlRow.row ? wlRow.row.badgeKind : "")
            color: wlRow.badgeColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)
              Text {
                Layout.fillWidth: true
                textFormat: Text.PlainText
                text: wlRow.row ? String(wlRow.row.title) : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.weight: Font.DemiBold
                elide: Text.ElideRight
              }
              // Type tag
              BorderSurface {
                visible: wlRow.row && wlRow.row.typeLabel
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                width: typeLabelText.implicitWidth + Style.space(8)
                height: typeLabelText.implicitHeight + Style.space(4)
                Text {
                  id: typeLabelText
                  anchors.centerIn: parent
                  text: wlRow.row ? wlRow.row.typeLabel : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption - 1
                }
              }
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: wlRow.row ? String(wlRow.row.meta) : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // Badge
          BorderSurface {
            Layout.alignment: Qt.AlignVCenter
            radius: Style.cornerRadius
            color: Qt.rgba(wlRow.badgeColor.r, wlRow.badgeColor.g, wlRow.badgeColor.b, 0.15)
            width: badgeText.implicitWidth + Style.space(12)
            height: badgeText.implicitHeight + Style.space(6)
            Text {
              id: badgeText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: wlRow.row ? String(wlRow.row.badge) : ""
              color: wlRow.badgeColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Text {
            Layout.alignment: Qt.AlignVCenter
            textFormat: Text.PlainText
            text: wlRow.expanded ? "▾" : "▸"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
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
        height: wlExpandedInner.implicitHeight + Style.space(20)
        radius: Style.cornerRadius
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.03)
        borderSpec: Border.controlSpec("normal", root.dim, root.accent)

        Column {
          id: wlExpandedInner
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: Style.space(10)
          spacing: Style.space(8)

          // 1. Pod Containers (if it's a pod with containers)
          Column {
            visible: wlRow.row && wlRow.row.rawPod && wlRow.row.rawPod.containers && wlRow.row.rawPod.containers.length > 0
            width: parent.width
            spacing: Style.space(4)

            Text {
              text: "CONTAINERS (" + (wlRow.row && wlRow.row.rawPod ? wlRow.row.rawPod.containers.length : 0) + ")"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              model: (wlRow.expanded && wlRow.row && wlRow.row.rawPod) ? wlRow.row.rawPod.containers : []
              BorderSurface {
                required property var modelData
                width: parent.width
                height: ctrRowLayout.implicitHeight + Style.space(12)
                radius: Style.cornerRadius
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
                borderSpec: Border.controlSpec("normal", root.dim, root.accent)

                RowLayout {
                  id: ctrRowLayout
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(6)

                  Rectangle {
                    width: Style.space(8); height: Style.space(8); radius: width / 2
                    color: modelData.ready ? Model.STATUS_HEALTHY : root.urgent
                  }

                  Text {
                    text: modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                  }

                  Text {
                    text: Model.shortImage(modelData.image)
                    color: root.dim
                    font.family: "monospace"
                    font.pixelSize: Style.font.caption
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                  }

                  Text {
                    text: modelData.state + (modelData.restarts > 0 ? (" · " + modelData.restarts + "r") : "")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Button {
                    text: "Logs"
                    fontSize: Style.font.caption
                    horizontalPadding: Style.space(8)
                    verticalPadding: Style.space(2)
                    bordered: true
                    onClicked: {
                      backend.setLogPod(wlRow.row.target)
                      backend.setLogContainer(modelData.name)
                      root.topMode = "logs"
                    }
                  }
                }
              }
            }
          }

          // 2. Pod Conditions (status pills)
          Column {
            visible: wlRow.row && wlRow.row.rawPod && wlRow.row.rawPod.conditions && wlRow.row.rawPod.conditions.length > 0
            width: parent.width
            spacing: Style.space(4)

            Text {
              text: "CONDITIONS"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Flow {
              width: parent.width
              spacing: Style.space(4)
              Repeater {
                model: (wlRow.expanded && wlRow.row && wlRow.row.rawPod) ? wlRow.row.rawPod.conditions : []
                BorderSurface {
                  required property var modelData
                  radius: Style.cornerRadius
                  color: modelData.status === "True" ? Qt.rgba(0.27, 0.65, 0.35, 0.15) : Qt.rgba(0.9, 0.28, 0.3, 0.18)
                  borderSpec: Border.controlSpec("normal", modelData.status === "True" ? Model.STATUS_HEALTHY : root.urgent, root.accent)
                  width: cndRow.implicitWidth + Style.space(12)
                  height: cndRow.implicitHeight + Style.space(6)
                  Row {
                    id: cndRow
                    anchors.centerIn: parent
                    spacing: Style.space(4)
                    Text {
                      text: modelData.status === "True" ? "✔" : "✕"
                      color: modelData.status === "True" ? Model.STATUS_HEALTHY : root.urgent
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      text: modelData.type
                      color: modelData.status === "True" ? root.foreground : root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: modelData.status !== "True"
                    }
                  }
                }
              }
            }
          }

          // 3. Generic details (for non-pod resources or CRDs)
          Column {
            visible: !wlRow.row || !wlRow.row.rawPod
            width: parent.width
            spacing: Style.space(3)
            Repeater {
              model: (wlRow.expanded && wlRow.row && !wlRow.row.rawPod) ? wlRow.row.lines : []
              Text {
                required property var modelData
                width: parent.width
                textFormat: Text.PlainText
                text: String(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          // 4. Action Buttons Bar
          RowLayout {
            visible: !backend.readOnly
            width: parent.width
            spacing: Style.space(6)

            Button {
              visible: wlRow.row && wlRow.row.targetKind === "pod"
              text: "View Logs"
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: {
                backend.setLogPod(wlRow.row.target)
                root.topMode = "logs"
              }
            }

            Button {
              visible: wlRow.row && (wlRow.row.targetKind === "pod" || wlRow.row.targetKind === "service")
              text: "Port Forward"
              fontSize: Style.font.bodySmall
              bordered: true
              selected: root.forwardFormKey === String(wlRow.row.key)
              onClicked: {
                root.fwLocal = String(wlRow.row.remoteHint || "8080")
                root.fwRemote = String(wlRow.row.remoteHint || "8080")
                root.forwardFormKey = root.forwardFormKey === String(wlRow.row.key) ? "" : String(wlRow.row.key)
              }
            }

            Button {
              visible: wlRow.row && (wlRow.row.targetKind === "deployment" || wlRow.row.targetKind === "statefulset" || wlRow.row.targetKind === "daemonset")
              text: "Restart"
              fontSize: Style.font.bodySmall
              bordered: true
              onClicked: root.runRowAction(wlRow.row, "restart")
            }

            Item { Layout.fillWidth: true; height: 1 }

            Button {
              visible: wlRow.row && wlRow.row.targetKind === "pod"
              text: "Delete Pod"
              fontSize: Style.font.bodySmall
              foreground: root.urgent
              bordered: true
              onClicked: root.runRowAction(wlRow.row, "kill")
            }
          }

          // 5. Inline Port-Forward Form
          BorderSurface {
            visible: wlRow.expanded && wlRow.row && root.forwardFormKey === String(wlRow.row.key)
            width: parent.width
            height: fwFormInner.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.05)
            borderSpec: Border.controlSpec("normal", root.dim, root.accent)

            Column {
              id: fwFormInner
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.margins: Style.space(8)
              spacing: Style.space(6)

              Text {
                text: "PORT FORWARD"
                color: root.dim
                font.bold: true
                font.pixelSize: Style.font.caption
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(6)

                Text {
                  text: "localhost:"
                  color: root.dim
                  font.pixelSize: Style.font.bodySmall
                }

                TextField {
                  Layout.preferredWidth: Style.space(80)
                  foreground: root.foreground
                  placeholderText: "local"
                  text: root.forwardFormKey === String(wlRow.row.key) ? root.fwLocal : ""
                  onTextChanged: if (root.forwardFormKey === String(wlRow.row.key)) root.fwLocal = text
                }

                Text {
                  text: "→ remote :"
                  color: root.dim
                  font.pixelSize: Style.font.bodySmall
                }

                TextField {
                  Layout.preferredWidth: Style.space(80)
                  foreground: root.foreground
                  placeholderText: "remote"
                  text: root.forwardFormKey === String(wlRow.row.key) ? root.fwRemote : ""
                  onTextChanged: if (root.forwardFormKey === String(wlRow.row.key)) root.fwRemote = text
                }

                Item { Layout.fillWidth: true; height: 1 }
              }

              RowLayout {
                width: parent.width
                spacing: Style.space(6)

                Button {
                  text: "Start Forward"
                  selected: true
                  bordered: true
                  onClicked: {
                    if (wlRow.row) backend.startForward(String(wlRow.row.targetKind), String(wlRow.row.target), root.fwLocal, root.fwRemote)
                    root.forwardFormKey = ""
                  }
                }

                Button {
                  text: "Cancel"
                  bordered: true
                  onClicked: root.forwardFormKey = ""
                }
              }
            }
          }
        }
      }
    }
  }

  component SectionToggle: Item {
    id: secToggle
    property string title: ""
    property string badge: ""
    property bool open: false
    signal toggled()

    width: parent.width
    height: Math.max(headerText.implicitHeight, Style.space(22))

    RowLayout {
      anchors.fill: parent
      spacing: Style.space(6)

      PanelSectionHeader {
        id: headerText
        text: secToggle.title
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Text {
        visible: secToggle.badge !== ""
        textFormat: Text.PlainText
        text: "· " + secToggle.badge
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item { Layout.fillWidth: true; height: 1 }

      Text {
        textFormat: Text.PlainText
        text: secToggle.open ? "▾" : "▸"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: secToggle.toggled()
    }
  }

  component Chip: CursorSurface {
    id: chip
    signal clicked()
    property string label: ""
    property bool active: false
    property bool danger: false

    foreground: root.foreground
    current: chip.active
    implicitWidth: chipLabel.implicitWidth + Style.space(16)
    implicitHeight: Style.space(28)

    Text {
      id: chipLabel
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: chip.label
      color: chip.danger ? root.urgent : (chip.active ? root.foreground : root.dim)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: chip.active || chip.danger
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
  }

  component EventRow: CursorSurface {
    id: evRow
    property var ev: null
    property int rowIndex: 0
    readonly property bool isWarning: evRow.ev && String(evRow.ev.type) === "Warning"
    readonly property color evColor: evRow.isWarning ? root.urgent : root.dim

    foreground: root.foreground
    implicitHeight: evInner.implicitHeight + Style.spacing.rowPaddingX

    Column {
      id: evInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(2)

      RowLayout {
        width: parent.width
        spacing: Style.space(8)
        Text {
          Layout.alignment: Qt.AlignVCenter
          text: evRow.isWarning ? "▲" : "●"
          color: evRow.evColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: evRow.ev ? (String(evRow.ev.reason) + " · " + String(evRow.ev.object)) : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.weight: Font.DemiBold
          elide: Text.ElideRight
        }
        Text {
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: evRow.ev ? (String(evRow.ev.age) + (evRow.ev.count > 1 ? " · ×" + evRow.ev.count : "")) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Text {
        width: parent.width
        visible: evRow.ev && String(evRow.ev.message) !== ""
        textFormat: Text.PlainText
        text: evRow.ev ? String(evRow.ev.message) : ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        maximumLineCount: 3
        elide: Text.ElideRight
      }
    }
  }

  component FwRow: CursorSurface {
    id: fwRow
    property int fid: -1
    property string label: ""
    property string sub: ""

    foreground: root.foreground
    implicitHeight: Style.space(44)

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(8)

      Text {
        text: "⇄"
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: 1
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: fwRow.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: fwRow.sub
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Chip {
        label: "Stop"
        danger: true
        onClicked: backend.stopForward(fwRow.fid)
      }
    }
  }

  component QuickRow: CursorSurface {
    id: qRow
    property var ctx: null
    property int rowIndex: 0
    readonly property bool isActive: ctx && String(ctx.name) === backend.activeContextName

    foreground: root.foreground
    hasCursor: root.quickIndex === rowIndex
    current: isActive
    implicitHeight: Style.space(38)

    RowLayout {
      anchors.fill: parent
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)
      Text {
        Layout.fillWidth: true
        textFormat: Text.PlainText
        text: qRow.ctx ? String(qRow.ctx.name) : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: qRow.isActive
        elide: Text.ElideRight
      }
    }
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.quickIndex = qRow.rowIndex
      onClicked: if (qRow.ctx) { backend.setContext(qRow.ctx.name); root.closeAll() }
    }
  }
}
