// Log tail for a pod/container, plus file export. Single scrollback window
// (no multi-pod merge — explicitly out of scope).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

func runLogs(contextName, override, namespace, pod, container string, tail int, outPath string, timeoutSec int) error {
	ctxName := strings.TrimSpace(contextName)
	if ctxName == "" {
		return fmt.Errorf("logs: --context is required")
	}
	ns := strings.TrimSpace(namespace)
	if ns == "" {
		ns = "default"
	}
	if strings.TrimSpace(pod) == "" {
		return fmt.Errorf("logs: --pod is required")
	}
	if tail <= 0 {
		tail = 200
	}
	if tail > 2000 {
		tail = 2000
	}
	cs, err := clientFor(ctxName, override, timeoutSec)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), secondsToDuration(timeoutSec))
	defer cancel()

	// Resolve container list + default.
	podObj, err := cs.CoreV1().Pods(ns).Get(ctx, pod, metav1.GetOptions{})
	if err != nil {
		return fmt.Errorf("logs: %w", err)
	}
	containers := make([]string, 0, len(podObj.Spec.Containers))
	for _, c := range podObj.Spec.Containers {
		containers = append(containers, c.Name)
	}
	if len(containers) == 0 {
		return fmt.Errorf("logs: pod %q has no containers", pod)
	}
	if container == "" {
		container = containers[0]
	}

	tailLines := int64(tail)
	req := cs.CoreV1().Pods(ns).GetLogs(pod, &corev1.PodLogOptions{
		Container: container,
		TailLines: &tailLines,
	})
	stream, err := req.Stream(ctx)
	if err != nil {
		return fmt.Errorf("logs: %w", err)
	}
	defer stream.Close()
	body, err := io.ReadAll(io.LimitReader(stream, 4<<20))
	if err != nil {
		return fmt.Errorf("logs: %w", err)
	}
	lines := strings.Split(strings.TrimRight(string(body), "\n"), "\n")
	if len(lines) == 1 && lines[0] == "" {
		lines = []string{}
	}

	if outPath != "" {
		if err := writeLogExport(outPath, ctxName, ns, pod, container, lines); err != nil {
			return err
		}
		raw, _ := json.Marshal(map[string]any{
			"pod": pod, "container": container, "containers": containers,
			"lines": len(lines), "file": outPath,
		})
		fmt.Println(string(raw))
		return nil
	}
	raw, err := json.Marshal(map[string]any{
		"pod": pod, "container": container, "containers": containers, "lines": lines,
	})
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}

func writeLogExport(path, ctxName, ns, pod, container string, lines []string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("export: %w", err)
	}
	var b strings.Builder
	fmt.Fprintf(&b, "# omakube log export — %s / %s / pod %s / container %s\n",
		ctxName, ns, pod, container)
	fmt.Fprintf(&b, "# %s · %d lines\n\n", time.Now().Format(time.RFC3339), len(lines))
	for _, l := range lines {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		return fmt.Errorf("export: %w", err)
	}
	return nil
}
