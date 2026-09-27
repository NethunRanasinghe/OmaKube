# OmaKube — Kubernetes bar-widget popup for Omarchy

Single UI surface: a bar pill (context short label + health dot) and one
anchored popup. No second surface. The popup is a `KeyboardPanel`
layer-shell popup rendered in-process by `omarchy-shell` — verify with
`hyprctl clients` (opening it must add no new client).

## Architecture & Layout

- `manifest.json` — id `omakube`, kind `bar-widget`, entry `Panel.qml`
- `Panel.qml` — pill + high-density virtualized popup + quick context switcher
- `Service.qml` — data owner, manages async processes and state
- `Model.js` — pure helpers (labels, glyphs, accents, log rendering, categories)
- `OmakubeIcon.qml` — helm-mark icon, single stroke weight
- `backend/` — Go CLI (`client-go` + `apimachinery`), invoked per-query

## High-Density Scalable Design

Designed to scale seamlessly from 1 developer cluster (1–2 namespaces, 5 pods)
to large enterprise multi-tenant clusters (100+ namespaces, 10,000+ pods, 50+ CRDs).

- **Zone A: Smart Breadcrumb Bar (34px)**:
  - `[☸ Context ▾]` — clickable dropdown with status, nodes/pods telemetry, latency badge, quick switch.
  - `[⎈ Namespace ▾]` — searchable namespace popover with pod counts, failing badges (`✕`), and **All Namespaces (`*`)** support.
  - `[⚡ Kind (Count) ▾]` — categorized resource picker (Workloads, Network, Config/Storage, Custom CRDs).
  - Refresh indicator with latency monitor (`45ms`).
- **Zone B: Unified Omnibar & Filter Strip (32px)**:
  - Instant search (`/` to focus) with prefix syntax support (`@ns`, `:kind`).
  - Sort cycler (`Status`, `Name`, `Age`).
  - View density toggle (`Compact` 28px single-line vs `Comfort` two-line).
- **Zone C: Dynamic Virtualized Canvas (~538px)**:
  - **Workloads View:** Powered by virtualized `ListView` with delegate recycling. High data-ink ratio, inline container inspection, pod conditions, and quick actions (Logs, Port-Forward, Restart, Delete).
  - **Events View:** Virtualized event stream with Warnings-only filter and instant text search.
  - **Logs View:** Full-height terminal canvas (~460px), searchable pod selector dropdown, container picker, search highlight navigation (`‹`, `›`), live follow toggle, and export.
  - **Port Forwards View:** Dedicated forward manager with active connection tracking, instant stop, and inline forward creator.
  - **Settings View:** Clean two-column configuration form for kubeconfig, default namespace, export directory, refresh interval, and context accent colors.
- **Zone D: Docked Bottom Navigation Rail (36px)**:
  - Always visible regardless of scrolling: `[Workloads]` `[Events]` `[Logs]` `[⇄ Forwards]` `[⚙ Settings]`.
  - Badges highlight event warnings and active forwards.

## Dynamic Resource Discovery

The backend uses `ServerPreferredResources()` and the dynamic client to dynamically discover and query:
- Core workloads: Pods, Deployments, StatefulSets, DaemonSets, Services, Jobs, CronJobs
- Networking & Config: Ingresses, ConfigMaps, Secrets, PVCs
- Custom Resources (CRDs): Automatically queries custom resources installed on the cluster (e.g. `helmcharts`, `virtualservices`, `certificates`, etc.)
- Multi-namespace querying: `--all-namespaces` / `--namespace "*"`

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
./bin/omakube workloads --context <name> --all-namespaces
./bin/omakube events --context <name> --all-namespaces
./bin/omakube logs --context <name> --namespace <ns> --pod <pod> --tail 50
```
