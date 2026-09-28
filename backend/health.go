// Per-context health: one API round trip (latency) + node readiness + pod
// phase summary. Emits a single JSON object with an aggregate status so QML
// stays dumb:
//
//	healthy  — API reachable, nodes ready, no failing/pending pods
//	degraded — reachable but something needs attention (or RBAC-limited view)
//	down     — API unreachable or credentials unusable
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/client-go/kubernetes"
)

type healthReport struct {
	Context       string `json:"context"`
	Reachable     bool   `json:"reachable"`
	LatencyMs     int64  `json:"latencyMs"`
	Status        string `json:"status"` // healthy | degraded | down
	NodesTotal    int    `json:"nodesTotal"`
	NodesReady    int    `json:"nodesReady"`
	NodesVisible  bool   `json:"nodesVisible"`
	PodsTotal     int    `json:"podsTotal"`
	PodsRunning   int    `json:"podsRunning"`
	PodsPending   int    `json:"podsPending"`
	PodsFailed    int    `json:"podsFailed"`
	PodsSucceeded int    `json:"podsSucceeded"`
	PodsNotReady  int    `json:"podsNotReady"`
	Restarts      int64  `json:"restarts"`
	// Namespace-scoped counts for the popup's active namespace (step 3 reuses).
	NsName    string `json:"nsName"`
	NsPods    int    `json:"nsPods"`
	NsPending int    `json:"nsPending"`
	NsFailing int    `json:"nsFailing"`
	Error     string `json:"error"`
	ErrorKind string `json:"errorKind"` // "" | unreachable | auth | forbidden | timeout | unknown
	Summary   string `json:"summary"`
}

func runHealth(contextName, override, namespace string, timeoutSec int) error {
	ctxName := strings.TrimSpace(contextName)
	if ctxName == "" {
		return fmt.Errorf("health: --context is required")
	}
	rep := healthReport{Context: ctxName, Status: "down", NsName: namespace}
	if namespace == "" {
		rep.NsName = "default"
	}

	raw, err := rawConfig(override)
	if err != nil {
		rep.Error = err.Error()
		rep.ErrorKind = classifyError(err)
		rep.Summary = "kubeconfig unreadable"
		return printHealth(rep, classifyExit(rep.ErrorKind))
	}
	cfg, err := restConfigFor(raw, ctxName, timeoutSec)
	if err != nil {
		rep.Error = err.Error()
		rep.ErrorKind = classifyError(err)
		rep.Summary = "cannot configure client"
		return printHealth(rep, classifyExit(rep.ErrorKind))
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		rep.Error = err.Error()
		rep.ErrorKind = classifyError(err)
		rep.Summary = "cannot create client"
		return printHealth(rep, classifyExit(rep.ErrorKind))
	}

	ctx, cancel := context.WithTimeout(context.Background(), secondsToDuration(timeoutSec))
	defer cancel()

	// Latency + reachability in one round trip.
	start := time.Now()
	if _, err := cs.Discovery().ServerVersion(); err != nil {
		rep.Error = err.Error()
		rep.ErrorKind = classifyError(err)
		rep.Summary = "API unreachable"
		return printHealth(rep, classifyExit(rep.ErrorKind))
	}
	rep.LatencyMs = time.Since(start).Milliseconds()
	rep.Reachable = true

	// Nodes (may be RBAC-forbidden — degrade, don't fail).
	if nodes, err := cs.CoreV1().Nodes().List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err != nil {
		if errors.IsForbidden(err) {
			rep.NodesVisible = false
		} else {
			rep.Error = err.Error()
			rep.ErrorKind = classifyError(err)
		}
	} else {
		rep.NodesVisible = true
		rep.NodesTotal = len(nodes.Items)
		if nodes.RemainingItemCount != nil {
			rep.NodesTotal += int(*nodes.RemainingItemCount)
		}
		for i := range nodes.Items {
			if nodeReady(&nodes.Items[i]) {
				rep.NodesReady++
			}
		}
	}

	// Pods across all namespaces (bounded LIST).
	if pods, err := cs.CoreV1().Pods("").List(ctx, metav1.ListOptions{Limit: maxHealthPodLimit}); err != nil {
		if errors.IsForbidden(err) {
			if rep.Error == "" {
				rep.Error = "pods list forbidden by RBAC"
				rep.ErrorKind = "forbidden"
			}
		} else if rep.Error == "" {
			rep.Error = err.Error()
			rep.ErrorKind = classifyError(err)
		}
	} else {
		for i := range pods.Items {
			p := &pods.Items[i]
			rep.PodsTotal++
			switch p.Status.Phase {
			case corev1.PodRunning:
				rep.PodsRunning++
			case corev1.PodPending:
				rep.PodsPending++
			case corev1.PodFailed:
				rep.PodsFailed++
			case corev1.PodSucceeded:
				rep.PodsSucceeded++
			}
			if p.Status.Phase != corev1.PodSucceeded && !podReady(p) {
				rep.PodsNotReady++
			}
			for _, cs := range p.Status.ContainerStatuses {
				rep.Restarts += int64(cs.RestartCount)
			}
			for _, cs := range p.Status.InitContainerStatuses {
				rep.Restarts += int64(cs.RestartCount)
			}
			if p.Namespace == rep.NsName {
				rep.NsPods++
				if p.Status.Phase == corev1.PodPending {
					rep.NsPending++
				}
				if p.Status.Phase == corev1.PodFailed || (p.Status.Phase != corev1.PodSucceeded && !podReady(p)) {
					rep.NsFailing++
				}
			}
		}
		if pods.RemainingItemCount != nil {
			rep.PodsTotal += int(*pods.RemainingItemCount)
		}
	}

	finalizeHealth(&rep)
	return printHealth(rep, 0)
}

func finalizeHealth(rep *healthReport) {
	switch {
	case rep.ErrorKind == "forbidden":
		rep.Status = "degraded"
		rep.Summary = "limited by RBAC"
	case rep.ErrorKind != "":
		rep.Status = "down"
		rep.Summary = "API error"
	case rep.NodesVisible && rep.NodesTotal > 0 && rep.NodesReady < rep.NodesTotal:
		rep.Status = "degraded"
		rep.Summary = fmt.Sprintf("%d/%d nodes ready", rep.NodesReady, rep.NodesTotal)
	case rep.PodsFailed > 0 || rep.PodsNotReady > 0:
		rep.Status = "degraded"
		rep.Summary = fmt.Sprintf("%d failing", rep.PodsFailed+rep.PodsNotReady)
	case rep.PodsPending > 0:
		rep.Status = "degraded"
		rep.Summary = fmt.Sprintf("%d pending", rep.PodsPending)
	default:
		rep.Status = "healthy"
		if rep.PodsTotal == 0 {
			rep.Summary = "healthy · no pods"
		} else {
			rep.Summary = fmt.Sprintf("%d pods", rep.PodsTotal)
		}
	}
}

func printHealth(rep healthReport, exitCode int) error {
	out, err := json.Marshal(rep)
	if err != nil {
		return err
	}
	fmt.Println(string(out))
	if exitCode != 0 {
		return errExit(exitCode)
	}
	return nil
}

func nodeReady(n *corev1.Node) bool {
	for _, c := range n.Status.Conditions {
		if c.Type == corev1.NodeReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

func podReady(p *corev1.Pod) bool {
	for _, c := range p.Status.Conditions {
		if c.Type == corev1.PodReady {
			return c.Status == corev1.ConditionTrue
		}
	}
	return false
}

// classifyError maps client-go failures to the popup's error vocabulary.
func classifyError(err error) string {
	if err == nil {
		return ""
	}
	if errors.IsUnauthorized(err) || errors.IsForbidden(err) {
		// Forbidden on the version probe is effectively an auth problem.
		return "auth"
	}
	if errors.IsTimeout(err) || errors.IsServerTimeout(err) {
		return "timeout"
	}
	s := strings.ToLower(err.Error())
	switch {
	case strings.Contains(s, "connection refused"),
		strings.Contains(s, "no such host"),
		strings.Contains(s, "network is unreachable"),
		strings.Contains(s, "i/o timeout"),
		strings.Contains(s, "econnrefused"), strings.Contains(s, "econnreset"):
		return "unreachable"
	case strings.Contains(s, "exec plugin"),
		strings.Contains(s, "executable"), strings.Contains(s, "not found in path"),
		strings.Contains(s, "unauthorized"), strings.Contains(s, "401"),
		strings.Contains(s, "token"), strings.Contains(s, "certificate"),
		strings.Contains(s, "x509"), strings.Contains(s, "auth"):
		return "auth"
	case strings.Contains(s, "deadline exceeded"), strings.Contains(s, "timeout"):
		return "timeout"
	case strings.Contains(s, "forbidden"), strings.Contains(s, "cannot list"):
		return "forbidden"
	default:
		return "unknown"
	}
}

func classifyExit(kind string) int {
	// Always print the JSON report on stdout; use exit codes only to flag
	// hard failures (auth/unreachable) for shell scripting.
	switch kind {
	case "auth", "unreachable":
		return 1
	default:
		return 0
	}
}
