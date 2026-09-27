// Namespace list with per-namespace health counts so problem namespaces
// are visible before picking one.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type namespaceInfo struct {
	Name    string `json:"name"`
	Pods    int    `json:"pods"`
	Pending int    `json:"pending"`
	Failing int    `json:"failing"`
}

func runNamespaces(contextName, override string, timeoutSec int) error {
	ctxName := strings.TrimSpace(contextName)
	if ctxName == "" {
		return fmt.Errorf("namespaces: --context is required")
	}
	cs, err := clientFor(ctxName, override, timeoutSec)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), secondsToDuration(timeoutSec))
	defer cancel()

	nsList, err := cs.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		return err
	}
	counts := map[string]*namespaceInfo{}
	for _, ns := range nsList.Items {
		counts[ns.Name] = &namespaceInfo{Name: ns.Name}
	}
	// One pod LIST across all namespaces, grouped locally.
	if pods, err := cs.CoreV1().Pods("").List(ctx, metav1.ListOptions{}); err == nil {
		for i := range pods.Items {
			p := &pods.Items[i]
			info, ok := counts[p.Namespace]
			if !ok {
				info = &namespaceInfo{Name: p.Namespace}
				counts[p.Namespace] = info
			}
			info.Pods++
			switch p.Status.Phase {
			case corev1.PodPending:
				info.Pending++
			case corev1.PodFailed:
				info.Failing++
			default:
				if p.Status.Phase != corev1.PodSucceeded && !podReady(p) {
					info.Failing++
				}
			}
		}
	}
	totalPods := 0
	totalPending := 0
	totalFailing := 0
	out := make([]namespaceInfo, 0, len(counts)+1)
	for _, v := range counts {
		totalPods += v.Pods
		totalPending += v.Pending
		totalFailing += v.Failing
		out = append(out, *v)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	allEntry := namespaceInfo{Name: "*", Pods: totalPods, Pending: totalPending, Failing: totalFailing}
	out = append([]namespaceInfo{allEntry}, out...)

	raw, err := json.Marshal(map[string]any{"namespaces": out})
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}
