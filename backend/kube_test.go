package main

import (
	"compress/gzip"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

func TestTypedPodListResponseLimit(t *testing.T) {
	for _, tc := range []struct {
		name       string
		annotation int
		gzip       bool
		wantError  bool
	}{
		{"normal", 64, false, false},
		{"oversized", maxKubeResponseBytes, false, true},
		{"oversized gzip", maxKubeResponseBytes, true, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/api/v1/pods" {
					http.NotFound(w, r)
					return
				}
				w.Header().Set("Content-Type", "application/json")
				var out http.ResponseWriter = w
				if tc.gzip {
					w.Header().Set("Content-Encoding", "gzip")
					gz := gzip.NewWriter(w)
					defer gz.Close()
					out = gzipResponseWriter{ResponseWriter: w, writer: gz}
				}
				fmt.Fprint(out, `{"apiVersion":"v1","kind":"PodList","items":[{"metadata":{"name":"sample","annotations":{"large":"`)
				fmt.Fprint(out, strings.Repeat("x", tc.annotation))
				fmt.Fprint(out, `"}},"status":{"phase":"Running"}}]}`)
			}))
			defer server.Close()

			raw := clientcmdapi.Config{
				CurrentContext: "test",
				Clusters:       map[string]*clientcmdapi.Cluster{"test": {Server: server.URL}},
				AuthInfos:      map[string]*clientcmdapi.AuthInfo{"test": {}},
				Contexts:       map[string]*clientcmdapi.Context{"test": {Cluster: "test", AuthInfo: "test"}},
			}
			cfg, err := restConfigFor(raw, "test", 10)
			if err != nil {
				t.Fatal(err)
			}
			cs, err := kubernetes.NewForConfig(cfg)
			if err != nil {
				t.Fatal(err)
			}
			pods, err := cs.CoreV1().Pods("").List(context.Background(), metav1.ListOptions{Limit: maxHealthPodLimit})
			if tc.wantError {
				if err == nil || !strings.Contains(err.Error(), "response exceeds") {
					t.Fatalf("expected response limit error, got %v", err)
				}
			} else if err != nil || len(pods.Items) != 1 || pods.Items[0].Name != "sample" {
				t.Fatalf("ordinary Pod list failed: pods=%v err=%v", pods, err)
			}
		})
	}
}

type gzipResponseWriter struct {
	http.ResponseWriter
	writer *gzip.Writer
}

func (w gzipResponseWriter) Write(p []byte) (int, error) { return w.writer.Write(p) }

func TestUpgradeBodyIsNotWrapped(t *testing.T) {
	body := io.NopCloser(strings.NewReader("upgrade"))
	rt := boundedTransport{rt: roundTripFunc(func(*http.Request) (*http.Response, error) {
		return &http.Response{StatusCode: http.StatusSwitchingProtocols, Body: body}, nil
	})}
	resp, err := rt.RoundTrip(httptest.NewRequest(http.MethodPost, "http://example.test/portforward", nil))
	if err != nil || resp.Body != body {
		t.Fatalf("SPDY upgrade body was changed: %v", err)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }
