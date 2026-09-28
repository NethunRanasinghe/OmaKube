// Recent events for a namespace, newest first — their own data source,
// not buried in a detail view.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type eventInfo struct {
	Name       string `json:"name"`
	Namespace  string `json:"namespace,omitempty"`
	Type       string `json:"type"` // Normal | Warning
	Reason     string `json:"reason"`
	Object     string `json:"object"`
	Message    string `json:"message"`
	Count      int32  `json:"count"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

func runEvents(contextName, override, namespace string, timeoutSec int) error {
	ctxName := strings.TrimSpace(contextName)
	if ctxName == "" {
		return fmt.Errorf("events: --context is required")
	}
	rawNs := strings.TrimSpace(namespace)
	queryNs := rawNs
	if rawNs == "*" || rawNs == "all" || rawNs == "" {
		queryNs = ""
	}

	cs, err := clientFor(ctxName, override, timeoutSec)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), secondsToDuration(timeoutSec))
	defer cancel()

	list, err := cs.CoreV1().Events(queryNs).List(ctx, metav1.ListOptions{Limit: maxEventsLimit})
	if err != nil {
		return fmt.Errorf("events: %w", err)
	}
	infos := make([]eventInfo, 0, len(list.Items))
	for i := range list.Items {
		e := &list.Items[i]
		ts := e.LastTimestamp
		if ts.IsZero() {
			ts = e.CreationTimestamp
		}
		msg := strings.TrimSpace(e.Message)
		if len(msg) > 240 {
			msg = msg[:237] + "…"
		}
		obj := string(e.InvolvedObject.Kind) + "/" + e.InvolvedObject.Name
		infos = append(infos, eventInfo{
			Name: e.Name, Namespace: e.Namespace, Type: e.Type, Reason: e.Reason, Object: obj,
			Message: msg, Count: e.Count,
			Age: ageString(ts), AgeSeconds: ageSeconds(ts),
		})
	}
	sort.Slice(infos, func(i, j int) bool { return infos[i].AgeSeconds < infos[j].AgeSeconds })
	if len(infos) > 100 {
		infos = infos[:100]
	}
	outNs := rawNs
	if outNs == "" {
		outNs = "*"
	}
	raw, err := json.Marshal(map[string]any{"namespace": outNs, "events": infos})
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}
