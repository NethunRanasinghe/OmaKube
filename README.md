# OmaKube — Kubernetes bar-widget popup for Omarchy

Single UI surface: a bar pill (context short label + health dot) and one
anchored popup. No second surface. The popup is a `KeyboardPanel`
layer-shell popup rendered in-process by `omarchy-shell` — verify with
`hyprctl clients` (opening it must add no new client).

## Layout

- `manifest.json` — id `omakube`, kind `bar-widget`, entry `Panel.qml`
- `Panel.qml` — pill + full popup + right-click quick switcher
- `Service.qml` — data owner, spawns `bin/omakube` per query
- `Model.js` — pure helpers (labels, glyphs, accents, log rendering)
- `OmakubeIcon.qml` — helm-mark icon, one stroke weight
- `backend/` — Go CLI (`client-go` + `apimachinery`), invoked per-query

## What the popup does

- Health hero (live ring, accent glow) + context list with per-context
  health; one-click switch (`use-context`), last context remembered
- Namespace chips with failing counts; per-context namespace remembered
- Workload tabs (Pods, Deploy, STS, DS, Svc, Jobs, Events, Logs) with
  instant filter (`/`), status badges (color + shape), sort cycler,
  inline row expansion
- Events tab; pod log tail with containers, follow/pause, search +
  highlight + match navigation, export to timestamped file
- Quick actions (hidden in read-only mode): pod Logs jump, rollout
  restart, kill pod (both with confirmation naming resource + namespace
  + context), port-forward start/stop/stop-all with free-port fallback
- Collapsible settings: kubeconfig override, default namespace, log dir,
  refresh interval, read-only, debug logging, per-context accents

## Dev / test

```bash
omarchy plugin validate ~/MyData/Oma-Plugins/OmaKube
ln -sfn ~/MyData/Oma-Plugins/OmaKube ~/.config/omarchy/plugins/omakube
omarchy plugin enable omakube --section right
# NOTE: symlinked checkouts do NOT hot-reload — restart after QML edits:
omarchy restart shell
# open the popup, then:
hyprctl clients | grep -c "Window "   # unchanged = true anchored popup
ps aux | grep "omakube port-forward" | grep -v grep  # forwards die with stops/shell exit
```

Backend:

```bash
go build -o bin/omakube ./backend   # run inside backend/
./bin/omakube contexts --json
./bin/omakube health --context <name> --timeout 8
./bin/omakube workloads --context <name> --namespace kube-system
./bin/omakube logs --context <name> --namespace <ns> --pod <pod> --tail 50
```
