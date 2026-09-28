package main

import (
	"context"
	"strings"
	"testing"
)

func TestFetchSecretsMetadata(t *testing.T) {
	dyn, cs, cfg, err := dynamicClientFor("k3d-dev-cluster", "", 10)
	if err != nil || cs == nil {
		t.Skip("skipping live cluster test: k3d-dev-cluster not available")
	}
	_ = dyn

	ctx := context.Background()
	secs := fetchSecretsMetadata(ctx, cs, cfg, "kube-system", defaultListLimit)
	if len(secs) == 0 {
		t.Fatalf("expected secrets in kube-system, got none")
	}

	foundTLS := false
	for _, s := range secs {
		if s.Name == "" {
			t.Errorf("secret has empty name")
		}
		if s.Namespace != "kube-system" {
			t.Errorf("expected namespace kube-system, got %q", s.Namespace)
		}
		if s.Type == "" {
			t.Errorf("secret %q has empty type", s.Name)
		}
		if s.DataCount <= 0 {
			t.Errorf("secret %q has unexpected dataCount: %d", s.Name, s.DataCount)
		}
		if s.Name == "k3s-serving" {
			foundTLS = true
			if s.Type != "kubernetes.io/tls" {
				t.Errorf("expected k3s-serving type to be kubernetes.io/tls, got %q", s.Type)
			}
			if s.DataCount != 2 {
				t.Errorf("expected k3s-serving dataCount to be 2, got %d", s.DataCount)
			}
		}
	}
	if !foundTLS {
		t.Errorf("expected to find k3s-serving secret in kube-system")
	}
}

func TestFetchConfigMaps(t *testing.T) {
	_, cs, cfg, err := dynamicClientFor("k3d-dev-cluster", "", 10)
	if err != nil || cs == nil {
		t.Skip("skipping live cluster test: k3d-dev-cluster not available")
	}

	ctx := context.Background()
	cms := fetchConfigMaps(ctx, cs, cfg, "kube-system", defaultListLimit)
	if len(cms) == 0 {
		t.Fatalf("expected configmaps in kube-system, got none")
	}

	for _, cm := range cms {
		if cm.Name == "" {
			t.Errorf("configmap has empty name")
		}
		if cm.Namespace != "kube-system" {
			t.Errorf("expected namespace kube-system, got %q", cm.Namespace)
		}
		if cm.DataCount < 0 {
			t.Errorf("configmap %q has negative dataCount: %d", cm.Name, cm.DataCount)
		}
		if !strings.HasSuffix(cm.Display, "keys") {
			t.Errorf("configmap %q unexpected display: %q", cm.Name, cm.Display)
		}
	}
}

func TestPortForwardValidation(t *testing.T) {
	// Remote port <= 0
	err := runPortForward("k3d-dev-cluster", "", "default", "service", "mysvc", 0, 0, 5)
	if err == nil || !strings.Contains(err.Error(), "invalid remote port") {
		t.Errorf("expected invalid remote port error for 0, got: %v", err)
	}

	// Remote port > 65535
	err = runPortForward("k3d-dev-cluster", "", "default", "service", "mysvc", 0, 70000, 5)
	if err == nil || !strings.Contains(err.Error(), "invalid remote port") {
		t.Errorf("expected invalid remote port error for 70000, got: %v", err)
	}

	// Local port < 0
	err = runPortForward("k3d-dev-cluster", "", "default", "service", "mysvc", -1, 8080, 5)
	if err == nil || !strings.Contains(err.Error(), "invalid local port") {
		t.Errorf("expected invalid local port error for -1, got: %v", err)
	}

	// Local port > 65535
	err = runPortForward("k3d-dev-cluster", "", "default", "service", "mysvc", 99999, 8080, 5)
	if err == nil || !strings.Contains(err.Error(), "invalid local port") {
		t.Errorf("expected invalid local port error for 99999, got: %v", err)
	}
}

func TestQueryCustomResourcesMetadataOnly(t *testing.T) {
	_, cs, cfg, err := dynamicClientFor("k3d-dev-cluster", "", 10)
	if err != nil || cs == nil {
		t.Skip("skipping live cluster test: k3d-dev-cluster not available")
	}

	result := make(map[string]any)
	queryCustomResources(context.Background(), cs, cfg, "kube-system", result)

	addons, ok := result["addons"]
	if !ok {
		t.Fatalf("expected addons CRD in result, got: %v", result)
	}
	addonList, ok := addons.([]crdResourceInfo)
	if !ok || len(addonList) == 0 {
		t.Fatalf("expected non-empty crdResourceInfo slice for addons, got: %v", addons)
	}

	for _, it := range addonList {
		if it.Name == "" {
			t.Errorf("expected non-empty addon name")
		}
		if it.Namespace != "kube-system" {
			t.Errorf("expected kube-system namespace, got %q", it.Namespace)
		}
		if it.Display == "" {
			t.Errorf("expected non-empty display for addon %q", it.Name)
		}
	}
}

func TestSanitizeDisplayString(t *testing.T) {
	short := "Ready"
	if got := sanitizeDisplayString(short, 64); got != "Ready" {
		t.Errorf("expected %q, got %q", short, got)
	}

	oversized := strings.Repeat("A", 200)
	got := sanitizeDisplayString(oversized, 64)
	if len(got) != 64 {
		t.Errorf("expected length 64, got %d", len(got))
	}
	if !strings.HasSuffix(got, "…") {
		t.Errorf("expected ellipsis suffix, got %q", got)
	}
}
