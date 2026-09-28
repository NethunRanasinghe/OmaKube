package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSanitizePathSegment(t *testing.T) {
	cases := []struct {
		input    string
		expected string
	}{
		{"x/../../outside", "x_outside"},
		{"../../etc/passwd", "etc_passwd"},
		{"prod/us-east-1/cluster-1", "prod_us-east-1_cluster-1"},
		{"my-cluster_name", "my-cluster_name"},
		{"../../../", "unknown"},
		{"", "unknown"},
		{"   ", "unknown"},
		{"context;rm -rf /", "context_rm_-rf"},
		{"$(whoami)", "whoami"},
		{"k3d-dev-cluster", "k3d-dev-cluster"},
	}

	for _, c := range cases {
		got := sanitizePathSegment(c.input)
		if got != c.expected {
			t.Errorf("sanitizePathSegment(%q) = %q, expected %q", c.input, got, c.expected)
		}
		if strings.Contains(got, "/") || strings.Contains(got, "\\") || strings.Contains(got, "..") {
			t.Errorf("sanitizePathSegment(%q) produced path traversal characters: %q", c.input, got)
		}
	}
}

func TestWriteLogExportTraversalRejection(t *testing.T) {
	tmpDir := t.TempDir()
	traversalPath := filepath.Join(tmpDir, "../../escaped.txt")

	_, err := writeLogExport(traversalPath, tmpDir, "myctx", "default", "mypod", "myc", []string{"line1"})
	if err == nil {
		t.Fatalf("expected error for traversal path outside outDir, got nil")
	}
	if !strings.Contains(err.Error(), "traverses outside") {
		t.Errorf("unexpected error message: %v", err)
	}
}

func TestWriteLogExportNoOverwrite(t *testing.T) {
	tmpDir := t.TempDir()
	target := filepath.Join(tmpDir, "test.txt")

	// Pre-create the file with sensitive content
	originalContent := "ORIGINAL_CONTENT"
	if err := os.WriteFile(target, []byte(originalContent), 0o600); err != nil {
		t.Fatalf("failed to create pre-existing file: %v", err)
	}

	finalPath, err := writeLogExport(target, tmpDir, "myctx", "default", "mypod", "myc", []string{"new log"})
	if err != nil {
		t.Fatalf("writeLogExport failed: %v", err)
	}

	// Verify original file was NOT overwritten
	content, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("failed to read target: %v", err)
	}
	if string(content) != originalContent {
		t.Fatalf("original file was overwritten! got %q, expected %q", string(content), originalContent)
	}

	// Verify new file was written to non-colliding alternative path
	if finalPath == target {
		t.Fatalf("expected different path due to collision, got %q", finalPath)
	}
	if !strings.HasPrefix(finalPath, filepath.Join(tmpDir, "test-1")) {
		t.Errorf("unexpected collision path: %q", finalPath)
	}

	// Check permissions on created file (should be 0600)
	info, err := os.Stat(finalPath)
	if err != nil {
		t.Fatalf("stat failed: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Errorf("expected 0600 permissions, got %04o", perm)
	}
}

func TestWriteLogExportSafeAutoName(t *testing.T) {
	tmpDir := t.TempDir()

	// Malicious context name with traversal attempt
	finalPath, err := writeLogExport("", tmpDir, "x/../../outside", "default", "mypod", "", []string{"log line"})
	if err != nil {
		t.Fatalf("writeLogExport failed: %v", err)
	}

	if !strings.HasPrefix(finalPath, tmpDir) {
		t.Errorf("finalPath %q does not start with tmpDir %q", finalPath, tmpDir)
	}
	rel, err := filepath.Rel(tmpDir, finalPath)
	if err != nil || strings.HasPrefix(rel, "..") {
		t.Errorf("finalPath escaped tmpDir: rel = %q", rel)
	}
	if strings.Contains(rel, "/") || strings.Contains(rel, "\\") {
		t.Errorf("rel contains subdirectories: %q", rel)
	}
	if !strings.Contains(filepath.Base(finalPath), "x_outside") {
		t.Errorf("expected sanitized context name 'x_outside' in filename, got %q", filepath.Base(finalPath))
	}
}

func TestWriteLogExportSystemDirRejection(t *testing.T) {
	systemDirs := []string{"/etc", "/etc/cron.d", "/usr", "/usr/local/bin", "/root", "/boot"}
	for _, sysDir := range systemDirs {
		_, err := writeLogExport("", sysDir, "ctx", "default", "pod", "", []string{"log"})
		if err == nil {
			t.Errorf("expected error when writing to system dir %q, got nil", sysDir)
		}
		if !strings.Contains(err.Error(), "refusing to write to system directory") {
			t.Errorf("unexpected error for %q: %v", sysDir, err)
		}
	}
}
