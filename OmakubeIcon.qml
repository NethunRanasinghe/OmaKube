import QtQuick
import qs.Commons

// Kubernetes wheel mark, ported from the official logo geometry.
// Renders in two grades: full detail (lobed rim, hollow hub) at larger
// sizes, and a bold simplified cut at bar sizes where fine strokes would
// just turn to mud. Single theme-aware color throughout.
Item {
  id: root
  property real iconSize: Style.space(12)
  property color color: Color.foreground
  property real opacityLevel: 1.0

  readonly property bool fine: iconSize > 17

  width: iconSize
  height: iconSize
  opacity: opacityLevel

  Canvas {
    anchors.fill: parent
    antialiasing: true
    renderTarget: Canvas.FramebufferObject
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var cx = width / 2, cy = height / 2
      var r = Math.min(width, height) / 2 - 0.5
      ctx.fillStyle = root.color
      ctx.strokeStyle = root.color
      ctx.lineCap = "round"
      var n = 7
      if (root.fine) {
        var rimR = r * 0.70
        // Lobed rim: seven round-capped arcs leave concave gaps between
        // the spoke paddles, like the real mark.
        ctx.lineWidth = Math.max(1.2, r * 0.30)
        for (var i = 0; i < n; i++) {
          var a = (Math.PI * 2 / n) * i - Math.PI / 2
          ctx.beginPath()
          ctx.arc(cx, cy, rimR, a - 0.33, a + 0.33)
          ctx.stroke()
        }
        // Paddle spokes, reaching just past the rim.
        ctx.lineWidth = Math.max(1.0, r * 0.19)
        for (var j = 0; j < n; j++) {
          var b = (Math.PI * 2 / n) * j - Math.PI / 2
          ctx.beginPath()
          ctx.moveTo(cx + Math.cos(b) * r * 0.16, cy + Math.sin(b) * r * 0.16)
          ctx.lineTo(cx + Math.cos(b) * r * 0.88, cy + Math.sin(b) * r * 0.88)
          ctx.stroke()
        }
        // Hollow hub: punch through so any background shows.
        ctx.globalCompositeOperation = "destination-out"
        ctx.beginPath()
        ctx.arc(cx, cy, Math.max(1.0, r * 0.13), 0, Math.PI * 2)
        ctx.fill()
        ctx.globalCompositeOperation = "source-over"
      } else {
        // Bar-size cut: solid ring, short bold spokes, solid hub.
        // No hairlines, no punch-outs — reads at a glance.
        ctx.lineWidth = Math.max(1.6, r * 0.30)
        ctx.beginPath()
        ctx.arc(cx, cy, r * 0.68, 0, Math.PI * 2)
        ctx.stroke()
        ctx.lineWidth = Math.max(1.4, r * 0.24)
        for (var k = 0; k < n; k++) {
          var c = (Math.PI * 2 / n) * k - Math.PI / 2
          ctx.beginPath()
          ctx.moveTo(cx + Math.cos(c) * r * 0.30, cy + Math.sin(c) * r * 0.30)
          ctx.lineTo(cx + Math.cos(c) * r * 0.68, cy + Math.sin(c) * r * 0.68)
          ctx.stroke()
        }
        ctx.beginPath()
        ctx.arc(cx, cy, Math.max(1.3, r * 0.20), 0, Math.PI * 2)
        ctx.fill()
      }
    }
    onWidthChanged: requestPaint()
  }
}
