# OmaKube — Kubernetes Bar-Widget & Control Deck for Omarchy

**OmaKube** is an ultra-dense, keyboard-driven Kubernetes popup widget designed for the [Omarchy](https://omarchy.org/) desktop shell. It bridges the gap between lightweight status-bar widgets and full-featured desktop dashboards, scaling from single-node development clusters (`k3s`, `minikube`) to multi-tenant enterprise clusters with hundreds of namespaces, thousands of pods, and custom resource definitions (CRDs).

---

## Highlights & Scalable Architecture

- **Single Anchored Layer-Shell Surface:** Rendered in-process by `omarchy-shell` via `KeyboardPanel` (`hyprctl clients` confirms zero floating window overhead).
- **Zone A: Smart Breadcrumb Header (34px):**
  - `[☸ Context ▾]` — Instant switcher with cluster reachability, health dots, node/pod metrics, and live API latency (`45ms`).
  - `[⎈ Namespace ▾]` — Searchable namespace drawer with pod counts, failure badges (`✕`), and **All Namespaces (`*`)** support.
  - `[⚡ Resource (Count) ▾]` — Categorized resource catalog: Workloads, Networking, Config/Storage, and dynamically discovered CRDs.
  - Background refresh indicator with animated Helm mark.
- **Zone B: Integrated Omnibar & Filter Strip (28px):**
  - Instant text filter (`/` to focus) supporting prefix syntax (`@namespace`, `:kind`).
  - Sort cycler (`Status`, `Name`, `Age`).
  - View density toggle (`Compact` 28px single-line row vs `Comfort` two-line row).
  - 2px accent shimmer line displaying non-intrusive background refresh activity.
- **Zone C: Virtualized Dynamic Canvas (~538px):**
  - **Workloads View:** Powered by virtualized `ListView` with delegate recycling. High data-ink ratio, inline container inspection, pod conditions, and quick actions (Logs, Port-Forward, Restart, Delete).
  - **Events View:** Virtualized cluster event stream with Warnings-only filter and instant text search.
  - **Logs View:** Full-height terminal canvas (~460px) with pod dropdown, container picker, search highlight navigation (`‹`, `›`), live follow toggle, and timestamped file exports with an **Open Folder** shortcut.
  - **Port Forwards View:** Active port-forward manager with live traffic routing, auto-assigned free port fallback, and 1-click stop.
  - **Settings View:** Clean, grouped configuration cards (Cluster Defaults, Logs & Telemetry, Safety & Permissions) with folder opener and read-only mode protection.
- **Zone D: Docked Bottom Navigation Rail (36px):**
  - Always visible regardless of scrolling: `[ Workloads ]` `[ Events ]` `[ Logs ]` `[ Forwards ]` `[ Settings ]`.
  - Notification badges for warning events and active port-forwards.

---

## Dynamic Resource Discovery

The backend Go CLI (`bin/omakube`) uses `client-go` and `DiscoveryClient.ServerPreferredResources()` along with the dynamic client (`dynamic.NewForConfig`) to query:
- **Workloads:** Pods, Deployments, StatefulSets, DaemonSets, Jobs, CronJobs
- **Network:** Services, Ingresses, Endpoints
- **Configuration & Storage:** ConfigMaps, Secrets, PersistentVolumeClaims (PVCs)
- **Custom Resource Definitions (CRDs):** Automatically discovers and catalogs custom resources installed on the cluster (e.g. `helmcharts`, `virtualservices`, `certificates`, `sealedsecrets`, etc.).
- **Multi-Namespace Scope:** Seamless querying across single namespaces or cluster-wide (`--all-namespaces` / `--namespace "*"`).

---

## Keyboard Shortcuts

| Shortcut | Action |
| :--- | :--- |
| **`/`** | Focus the Omnibar filter field (auto-selects text) |
| **`Esc`** | Clear active search filter, close open popovers, or dismiss popup |
| **`r` / `R`** | Trigger immediate cluster refresh |
| **`Enter` / `Shift+Enter`** | Step to next / previous match in log stream search |
| **`Up` / `Down` / `j` / `k`** | Navigate quick context switcher (right-click) |
| **`Left-Click (Pill)`** | Toggle full OmaKube control deck |
| **`Right-Click (Pill)`** | Quick context switcher dropdown |
| **`Middle-Click (Pill)`** | Trigger background refresh |

---

## Project Structure

```
├── manifest.json       # Omarchy plugin contract & configuration schema
├── LICENSE             # MIT License
├── README.md           # Documentation & usage guide
├── Panel.qml           # Primary UI entry point (bar pill + popup + popovers)
├── Service.qml         # Asynchronous data owner & process supervisor
├── Model.js            # Pure functional helpers, status mappings, and log styling
├── OmakubeIcon.qml     # Helm-mark vector icon
├── bin/
│   └── omakube         # Compiled backend binary (Go + client-go)
└── backend/            # Go backend source code
    ├── main.go         # CLI entry point & argument parser
    ├── kube.go         # Kubeconfig resolution & client builder
    ├── resources.go    # Client factories & status mappers
    ├── workloads.go    # Workload browsing & dynamic CRD discovery
    ├── namespaces.go   # Namespace list with health counters
    ├── contexts.go     # Context list & active context switcher
    ├── events.go       # Cluster event streaming
    ├── logs.go         # Pod container log tailing & export
    ├── actions.go      # Restart deployment, delete pod
    └── portforward.go  # SPDY port-forward runner
```

---

## Installation & Setup

1. **Clone or link into Omarchy plugins directory:**
   ```bash
   ln -sfn ~/MyData/Oma-Plugins/OmaKube ~/.config/omarchy/plugins/omakube
   ```

2. **Validate the plugin contract:**
   ```bash
   omarchy plugin validate ~/.config/omarchy/plugins/omakube
   ```

3. **Enable in your Omarchy bar:**
   ```bash
   omarchy plugin enable omakube --section right
   omarchy restart shell
   ```

4. **Verify popup rendering:**
   ```bash
   # Opening the popup should add NO new client (anchored layer-shell popup):
   hyprctl clients | grep -c "Window "
   ```

---

## Backend Development & Manual Testing

Compile the Go backend binary:

```bash
cd backend
go build -o ../bin/omakube .
cd ..
```

Test commands manually:

```bash
./bin/omakube contexts --json
./bin/omakube health --context <name> --timeout 8
./bin/omakube workloads --context <name> --namespace default
./bin/omakube workloads --context <name> --all-namespaces
./bin/omakube namespaces --context <name>
./bin/omakube events --context <name> --namespace default
./bin/omakube logs --context <name> --namespace default --pod <pod> --tail 100
```

---

## License

This project is licensed under the [MIT License](LICENSE).
