// Shared client construction + formatting helpers for resource commands.
package main

import (
	"fmt"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
)

func clientFor(contextName, override string, timeoutSec int) (*kubernetes.Clientset, error) {
	raw, err := rawConfig(override)
	if err != nil {
		return nil, err
	}
	cfg, err := restConfigFor(raw, contextName, timeoutSec)
	if err != nil {
		return nil, err
	}
	return kubernetes.NewForConfig(cfg)
}

func dynamicClientFor(contextName, override string, timeoutSec int) (*dynamic.DynamicClient, *kubernetes.Clientset, error) {
	raw, err := rawConfig(override)
	if err != nil {
		return nil, nil, err
	}
	cfg, err := restConfigFor(raw, contextName, timeoutSec)
	if err != nil {
		return nil, nil, err
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, nil, err
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return nil, nil, err
	}
	return dyn, cs, nil
}

func ageString(t metav1.Time) string {
	d := time.Since(t.Time)
	if d < 0 {
		d = 0
	}
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

func ageSeconds(t metav1.Time) int64 {
	d := time.Since(t.Time)
	if d < 0 {
		return 0
	}
	return int64(d.Seconds())
}

// podDisplay derives the kubectl-style display status plus a stable kind for
// icon mapping: running | pending | crashloop | failed | succeeded | waiting | unknown.
func podDisplay(p *corev1.Pod) (display, kind string) {
	phase := string(p.Status.Phase)
	// Surface the most severe container reason first (kubectl logic).
	for _, cs := range p.Status.ContainerStatuses {
		if cs.State.Waiting != nil {
			r := cs.State.Waiting.Reason
			switch r {
			case "CrashLoopBackOff":
				return r, "crashloop"
			case "ImagePullBackOff", "ErrImagePull", "CreateContainerConfigError", "InvalidImageName":
				return r, "failed"
			default:
				if phase == "Pending" || phase == "" {
					return r, "pending"
				}
				return r, "waiting"
			}
		}
		if cs.State.Terminated != nil && cs.State.Terminated.Reason != "" && cs.State.Terminated.ExitCode != 0 {
			return cs.State.Terminated.Reason, "failed"
		}
	}
	switch p.Status.Phase {
	case corev1.PodRunning:
		if podReady(p) {
			return "Running", "running"
		}
		return "Running · not ready", "waiting"
	case corev1.PodPending:
		return "Pending", "pending"
	case corev1.PodFailed:
		return "Failed", "failed"
	case corev1.PodSucceeded:
		return "Completed", "succeeded"
	default:
		if phase == "" {
			return "Unknown", "unknown"
		}
		return phase, "unknown"
	}
}

type containerInfo struct {
	Name     string `json:"name"`
	Image    string `json:"image"`
	Ready    bool   `json:"ready"`
	Restarts int32  `json:"restarts"`
	State    string `json:"state"`
}

func containerState(cs corev1.ContainerStatus) string {
	switch {
	case cs.State.Running != nil:
		return "running"
	case cs.State.Waiting != nil:
		return cs.State.Waiting.Reason
	case cs.State.Terminated != nil:
		return cs.State.Terminated.Reason
	default:
		return "unknown"
	}
}

type conditionInfo struct {
	Type   string `json:"type"`
	Status string `json:"status"`
	Reason string `json:"reason"`
}
