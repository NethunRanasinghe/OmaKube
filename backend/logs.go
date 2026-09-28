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

func runLogs(contextName, override, namespace, pod, container string, tail int, outPath, outDir string, timeoutSec int) error {
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

	if outPath != "" || outDir != "" {
		finalFile, err := writeLogExport(outPath, outDir, ctxName, ns, pod, container, lines)
		if err != nil {
			return err
		}
		raw, _ := json.Marshal(map[string]any{
			"pod": pod, "container": container, "containers": containers,
			"lines": len(lines), "file": finalFile,
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

// sanitizePathSegment ensures values interpolated into filenames or export directories
// strictly contain only safe characters, preventing directory traversal (.., /, \).
func sanitizePathSegment(val string) string {
	s := strings.TrimSpace(val)
	var b strings.Builder
	lastUnderscore := false
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-' {
			b.WriteRune(r)
			lastUnderscore = false
		} else if !lastUnderscore {
			b.WriteByte('_')
			lastUnderscore = true
		}
	}
	res := strings.Trim(b.String(), "_-")
	if res == "" {
		return "unknown"
	}
	return res
}

func writeLogExport(outPath, outDir, ctxName, ns, pod, container string, lines []string) (string, error) {
	var targetPath string
	var exportDir string

	if outDir != "" {
		exportDir = filepath.Clean(outDir)
	}

	if outPath != "" {
		cleanPath := filepath.Clean(outPath)
		filename := filepath.Base(cleanPath)

		if filename == "." || filename == ".." || filename == "/" || filename == "\\" || filename == "" {
			return "", fmt.Errorf("export: invalid target filename in %q", outPath)
		}

		if exportDir != "" {
			// When outDir is specified, outPath MUST resolve directly inside exportDir without traversal.
			rel, err := filepath.Rel(exportDir, cleanPath)
			if err != nil || strings.HasPrefix(rel, "..") || rel == "." || strings.Contains(rel, "/") || strings.Contains(rel, "\\") {
				return "", fmt.Errorf("export: target path %q traverses outside log directory %q", outPath, exportDir)
			}
			targetPath = cleanPath
		} else {
			targetPath = cleanPath
			exportDir = filepath.Dir(cleanPath)
		}
	} else if exportDir != "" {
		safeCtx := sanitizePathSegment(ctxName)
		safeNs := sanitizePathSegment(ns)
		safePod := sanitizePathSegment(pod)
		safeC := ""
		if container != "" {
			safeC = "-" + sanitizePathSegment(container)
		}
		stamp := time.Now().Format("20060102-150405")
		filename := fmt.Sprintf("omakube-%s-%s-%s%s-%s.txt", safeCtx, safeNs, safePod, safeC, stamp)
		targetPath = filepath.Join(exportDir, filename)
	} else {
		return "", fmt.Errorf("export: destination path or directory required")
	}

	// Refuse writing directly to critical system directories
	switch exportDir {
	case "/", "/etc", "/usr", "/bin", "/sbin", "/boot", "/lib", "/lib64", "/sys", "/proc", "/dev", "/root":
		return "", fmt.Errorf("export: refusing to write to system directory %q", exportDir)
	}

	if err := os.MkdirAll(exportDir, 0o755); err != nil {
		return "", fmt.Errorf("export: directory creation failed: %w", err)
	}

	f, finalPath, err := openSafeExportFile(targetPath)
	if err != nil {
		return "", fmt.Errorf("export: %w", err)
	}
	defer f.Close()

	var b strings.Builder
	fmt.Fprintf(&b, "# omakube log export — %s / %s / pod %s / container %s\n",
		ctxName, ns, pod, container)
	fmt.Fprintf(&b, "# %s · %d lines\n\n", time.Now().Format(time.RFC3339), len(lines))
	for _, l := range lines {
		b.WriteString(l)
		b.WriteByte('\n')
	}
	if _, err := f.WriteString(b.String()); err != nil {
		return "", fmt.Errorf("export: write failed: %w", err)
	}
	return finalPath, nil
}

func openSafeExportFile(targetPath string) (*os.File, string, error) {
	// Mode 0o600 (owner read/write only). O_EXCL prevents overwriting existing files.
	f, err := os.OpenFile(targetPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err == nil {
		return f, targetPath, nil
	}
	if !os.IsExist(err) {
		return nil, "", err
	}

	// File collision: append sequence suffix up to 50 attempts
	ext := filepath.Ext(targetPath)
	base := strings.TrimSuffix(targetPath, ext)
	for i := 1; i <= 50; i++ {
		alt := fmt.Sprintf("%s-%d%s", base, i, ext)
		f, err = os.OpenFile(alt, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err == nil {
			return f, alt, nil
		}
		if !os.IsExist(err) {
			return nil, "", err
		}
	}
	return nil, "", fmt.Errorf("file %q already exists; refusing to overwrite", targetPath)
}
