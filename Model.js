function shortLabel(name) {
  var s = String(name || "").trim()
  if (s === "") return "k8s"
  // Strip noise suffixes kubectl/k3d append, then shorten. "k3d-dev-cluster"
  // and "k3d-staging-cluster" become "k3d-dev" / "k3d-staging" — the part
  // that actually distinguishes them in a bar pill.
  s = s.replace(/[-_.](cluster|context)$/i, "")
  var parts = s.split(/[\/_:\s]+/)
  var last = parts[parts.length - 1] || s
  // Dash-compounds: keep the two most significant segments.
  var dash = last.split("-").filter(function(p) { return p !== "" })
  if (dash.length > 2) last = dash[0] + "-" + dash[1]
  else if (dash.length === 2 && (dash[0] === "k3d" || last.length > 12)) last = dash.slice(0, 2).join("-")
  return last.length > 12 ? last.slice(0, 11) + "…" : last
}

// Semantic status palette — status always reads the same, in both themes.
// Identity (which cluster) lives in the per-context accent, used by the
// popup hero/rows; the pill dot is pure health: green, amber, or red.
var STATUS_HEALTHY = "#46a758"
var STATUS_WARN = "#d9a13b"

function healthColor(status, foreground, urgent, accent) {
  var s = String(status || "unknown").toLowerCase()
  if (s === "healthy" || s === "running" || s === "ready" || s === "active" || s === "succeeded" || s === "completed") return STATUS_HEALTHY
  if (s === "degraded" || s === "warning" || s === "pending" || s === "waiting" || s === "containercreating" || s === "terminating") return STATUS_WARN
  if (s === "down" || s === "error" || s === "critical" || s === "failed" || s === "crashloop" || s === "crashloopbackoff" || s === "backoff" || s === "notready") return urgent
  return Qt.darker(foreground, 1.55)
}

// Distinct glyph per status so state reads without color.
function statusGlyph(status) {
  var s = String(status || "").toLowerCase()
  if (s === "running" || s === "healthy" || s === "ready" || s === "active") return "●"
  if (s === "pending" || s === "containercreating" || s === "waiting") return "◐"
  if (s === "crashloopbackoff" || s === "crashloop" || s === "backoff") return "▲"
  if (s === "failed" || s === "error" || s === "notready" || s === "down") return "■"
  if (s === "succeeded" || s === "completed") return "✔"
  if (s === "terminating") return "◌"
  return "○"
}

function humanError(raw) {
  var s = String(raw || "")
  if (s === "") return ""
  if (/exec plugin/i.test(s)) return "Auth plugin failed (aws-iam-authenticator / gke-gcloud-auth-plugin / oidc). Check the plugin binary and your kubeconfig."
  if (/token.*expir|expir.*token|unauthorized|401/i.test(s)) return "Token expired or unauthorized. Re-authenticate this context (re-login / refresh credentials)."
  if (/connection refused|no such host|i\/o timeout|unreachable|network/i.test(s)) return "API server unreachable. Check VPN / network, then retry."
  if (/no such file|not found.*kubeconfig|KUBECONFIG/i.test(s)) return "Kubeconfig not found. Set the path in settings or check $KUBECONFIG."
  if (s.length > 220) return s.slice(0, 217) + "…"
  return s
}

function contextSubtitle(ctx) {
  if (!ctx) return ""
  var host = String(ctx.host || "")
  var auth = String(ctx.auth || "")
  host = host.replace(/^https?:\/\//, "").split("/")[0].split(":")[0]
  var base = host !== "" && auth !== "" ? host + " · " + auth : (host || auth)
  var detail = String(ctx.healthDetail || "")
  return detail !== "" ? base + " · " + detail : base
}

// Fixed accent palette (distinct hues; red first so production-feeling
// names hash somewhere memorable, overridable per context).
var ACCENTS = ["#e5484d", "#f76b15", "#d9a13b", "#46a758", "#3ddbd9", "#52a8ff", "#9e8cfc", "#e93d82"]

function paletteIndex(name) {
  var s = String(name || "")
  var h = 0
  for (var i = 0; i < s.length; i++) h = ((h * 31) + s.charCodeAt(i)) | 0
  return Math.abs(h) % ACCENTS.length
}

function defaultAccent(name) {
  return ACCENTS[paletteIndex(name) % ACCENTS.length]
}

function nextAccent(current) {
  var idx = ACCENTS.indexOf(String(current || ""))
  return ACCENTS[(idx + 1 + ACCENTS.length) % ACCENTS.length]
}

function firstPort(ports) {
  var m = String(ports || "").match(/(\d+)/)
  return m ? parseInt(m[1], 10) : 80
}

function escapeHtml(s) {
  return String(s || "").replace(/&/g, "&amp;").replace(/</g, "&lt;")
    .replace(/>/g, "&gt;").replace(/"/g, "&quot;")
}

function logSeverity(line) {
  var s = String(line || "")
  if (/\b(ERROR|FATAL|Error|Failed|FAIL|panic)\b/.test(s)) return "error"
  if (/\b(WARN|WARNING|Warning)\b/.test(s)) return "warn"
  if (/\b(DEBUG|TRACE|Trace)\b/.test(s)) return "debug"
  return "info"
}

// Rich-text log line: severity color + search-term highlight. Colors are
// passed in (theme tokens live in QML, not here).
function renderLogLine(line, query, isCurrent, palette) {
  var s = String(line || "")
  var sev = logSeverity(s)
  var color = palette.text
  if (sev === "error") color = palette.error
  else if (sev === "warn") color = palette.warn
  else if (sev === "debug") color = palette.dim
  var q = String(query || "").trim()
  var esc = escapeHtml(s)
  if (q !== "") {
    var qi = s.toLowerCase().indexOf(q.toLowerCase())
    if (qi >= 0) {
      var before = escapeHtml(s.slice(0, qi))
      var match = escapeHtml(s.slice(qi, qi + q.length))
      var after = escapeHtml(s.slice(qi + q.length))
      var bg = isCurrent ? palette.matchCurrent : palette.match
      esc = before + "<span style=\"background:" + bg + ";font-weight:bold;\">" + match + "</span>" + after
    }
  }
  var weight = sev === "error" ? "bold" : "normal"
  return "<span style=\"color:" + color + ";font-weight:" + weight + ";\">" + esc + "</span>"
}
