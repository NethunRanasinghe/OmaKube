// Mutating actions with safety rails. Every command prints a JSON result;
// failures carry human-readable errors. QML gates all of these behind the
// read-only setting and an in-popup confirmation naming the exact
// resource + namespace + context.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

type actionResult struct {
	OK      bool   `json:"ok"`
	Action  string `json:"action"`
	Target  string `json:"target"`
	Message string `json:"message"`
}

func printResult(action, target, message string) {
	raw, _ := json.Marshal(actionResult{OK: true, Action: action, Target: target, Message: message})
	fmt.Println(string(raw))
}

// restartWorkload performs rollout-restart semantics (bump the restartedAt
// annotation) for deployments, statefulsets and daemonsets.
func runRestart(contextName, override, namespace, kind, name string, timeoutSec int) error {
	ctxName := strings.TrimSpace(contextName)
	if ctxName == "" || strings.TrimSpace(name) == "" {
		return fmt.Errorf("restart: --context and --name are required")
	}
	ns := strings.TrimSpace(namespace)
	if ns == "" {
		ns = "default"
	}
	kind = strings.ToLower(strings.TrimSpace(kind))
	if kind == "" {
		kind = "deployment"
	}
	cs, err := clientFor(ctxName, override, timeoutSec)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), secondsToDuration(timeoutSec))
	defer cancel()

	patch := fmt.Sprintf(`{"spec":{"template":{"metadata":{"annotations":{"kubectl.kubernetes.io/restartedAt":%q}}}}}`, time.Now().UTC().Format(time.RFC3339))
	pt := types.StrategicMergePatchType
	switch kind {
	case "deployment", "deploy":
		apps := cs.AppsV1().Deployments(ns)
		if _, err := apps.Get(ctx, name, metav1.GetOptions{}); err != nil {
			return fmt.Errorf("restart: %w", err)
		}
		if _, err := apps.Patch(ctx, name, pt, []byte(patch), metav1.PatchOptions{}); err != nil {
			return fmt.Errorf("restart: %w", err)
		}
	case "statefulset", "sts":
		ss := cs.AppsV1().StatefulSets(ns)
		if _, err := ss.Get(ctx, name, metav1.GetOptions{}); err != nil {
			return fmt.Errorf("restart: %w", err)
		}
		if _, err := ss.Patch(ctx, name, pt, []byte(patch), metav1.PatchOptions{}); err != nil {
			return fmt.Errorf("restart: %w", err)
		}
	case "daemonset", "ds":
		ds := cs.AppsV1().DaemonSets(ns)
		if _, err := ds.Get(ctx, name, metav1.GetOptions{}); err != nil {
			return fmt.Errorf("restart: %w", err)
		}
		if _, err := ds.Patch(ctx, name, pt, []byte(patch), metav1.PatchOptions{}); err != nil {
			return fmt.Errorf("restart: %w", err)
		}
	default:
		return fmt.Errorf("restart: unsupported kind %q (deployment, statefulset, daemonset)", kind)
	}
	printResult("restart", kind+"/"+name, "restarted "+kind+"/"+name+" in "+ns)
	return nil
}

// deletePod kills a pod (the controller recreates it per its policy).
func runDeletePod(contextName, override, namespace, name string, timeoutSec int) error {
	ctxName := strings.TrimSpace(contextName)
	if ctxName == "" || strings.TrimSpace(name) == "" {
		return fmt.Errorf("delete-pod: --context and --name are required")
	}
	ns := strings.TrimSpace(namespace)
	if ns == "" {
		ns = "default"
	}
	cs, err := clientFor(ctxName, override, timeoutSec)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), secondsToDuration(timeoutSec))
	defer cancel()

	if err := cs.CoreV1().Pods(ns).Delete(ctx, name, metav1.DeleteOptions{}); err != nil {
		return fmt.Errorf("delete-pod: %w", err)
	}
	printResult("delete-pod", "pod/"+name, "deleted pod "+name+" in "+ns)
	return nil
}
