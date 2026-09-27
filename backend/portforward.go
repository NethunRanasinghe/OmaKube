// Port-forward runner: resolves pod|service|deployment targets to a running
// pod, then holds a client-go portforward session until killed. Designed to
// run as a QML-managed child process — death of the process (or the shell)
// ends the forward. Prints one JSON ready line, then blocks.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/util/httpstream"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/transport/spdy"
)

type forwardReady struct {
	Status     string `json:"status"`
	Target     string `json:"target"`
	Pod        string `json:"pod"`
	LocalPort  int    `json:"localPort"`
	RemotePort int    `json:"remotePort"`
}

func runPortForward(contextName, override, namespace, targetKind, target string, localPort, remotePort int, timeoutSec int) error {
	ctxName := strings.TrimSpace(contextName)
	if ctxName == "" || strings.TrimSpace(target) == "" {
		return fmt.Errorf("port-forward: --context and --target are required")
	}
	ns := strings.TrimSpace(namespace)
	if ns == "" {
		ns = "default"
	}
	kind := strings.ToLower(strings.TrimSpace(targetKind))
	if kind == "" {
		kind = "service"
	}
	if remotePort <= 0 {
		return fmt.Errorf("port-forward: --remote-port is required")
	}

	raw, err := rawConfig(override)
	if err != nil {
		return err
	}
	cfg, err := restConfigFor(raw, ctxName, timeoutSec)
	if err != nil {
		return err
	}
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), secondsToDuration(timeoutSec))
	defer cancel()

	podName, resolvedRemote, err := resolveForwardTarget(ctx, cs, ns, kind, target, remotePort)
	if err != nil {
		return err
	}
	if resolvedRemote > 0 {
		remotePort = resolvedRemote
	}

	transport, upgrader, err := spdy.RoundTripperFor(cfg)
	if err != nil {
		return fmt.Errorf("port-forward: %w", err)
	}
	serverURL, err := url.Parse(cfg.Host)
	if err != nil {
		return fmt.Errorf("port-forward: %w", err)
	}
	serverURL.Path = fmt.Sprintf("/api/v1/namespaces/%s/pods/%s/portforward", ns, podName)

	dialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, http.MethodPost, serverURL)

	local := localPort
	if local <= 0 {
		local = remotePort
	}
	ports := []string{fmt.Sprintf("%d:%d", local, remotePort)}
	ready := tryForward(dialer, ports)
	if ready == nil && local != 0 {
		// Requested port taken — fall back to a free one.
		ports = []string{fmt.Sprintf("0:%d", remotePort)}
		ready = tryForward(dialer, ports)
	}
	if ready == nil {
		return fmt.Errorf("port-forward: could not bind local port %d", local)
	}
	out, _ := json.Marshal(forwardReady{
		Status: "ready", Target: kind + "/" + target, Pod: podName,
		LocalPort: ready.local, RemotePort: remotePort,
	})
	fmt.Println(string(out))

	// Block until killed (SIGTERM from QML stop, shell exit, or Ctrl-C).
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	<-sig
	ready.fw.Close()
	return nil
}

type liveForward struct {
	fw    *portforward.PortForwarder
	local int
}

func tryForward(dialer httpstream.Dialer, ports []string) *liveForward {
	stopChan := make(chan struct{})
	readyChan := make(chan struct{})
	fw, err := portforward.New(dialer, ports, stopChan, readyChan, io.Discard, io.Discard)
	if err != nil {
		return nil
	}
	errCh := make(chan error, 1)
	go func() { errCh <- fw.ForwardPorts() }()
	select {
	case <-readyChan:
		break
	case err := <-errCh:
		_ = err
		close(stopChan)
		return nil
	case <-time.After(15 * time.Second):
		close(stopChan)
		return nil
	}
	fwdPorts, err := fw.GetPorts()
	if err != nil || len(fwdPorts) == 0 {
		return nil
	}
	return &liveForward{fw: fw, local: int(fwdPorts[0].Local)}
}

// resolveForwardTarget maps service|deployment|pod to a running pod name.
// A remotePort of 0 means "use the service's first port".
func resolveForwardTarget(ctx context.Context, cs *kubernetes.Clientset, ns, kind, target string, remotePort int) (string, int, error) {
	switch kind {
	case "pod":
		p, err := cs.CoreV1().Pods(ns).Get(ctx, target, metav1.GetOptions{})
		if err != nil {
			return "", 0, fmt.Errorf("port-forward: %w", err)
		}
		_ = p
		return target, remotePort, nil
	case "service":
		svc, err := cs.CoreV1().Services(ns).Get(ctx, target, metav1.GetOptions{})
		if err != nil {
			return "", 0, fmt.Errorf("port-forward: %w", err)
		}
		rp := remotePort
		if rp <= 0 && len(svc.Spec.Ports) > 0 {
			rp = int(svc.Spec.Ports[0].TargetPort.IntVal)
			if rp == 0 {
				rp = int(svc.Spec.Ports[0].Port)
			}
		}
		pod, err := firstReadyPodForSelector(ctx, cs, ns, svc.Spec.Selector)
		if err != nil {
			return "", 0, err
		}
		return pod, rp, nil
	case "deployment", "deploy", "statefulset", "sts":
		pod, err := firstReadyPodForOwner(ctx, cs, ns, target)
		if err != nil {
			return "", 0, err
		}
		return pod, remotePort, nil
	default:
		return "", 0, fmt.Errorf("port-forward: unsupported target kind %q (pod, service, deployment)", kind)
	}
}

func firstReadyPodForSelector(ctx context.Context, cs *kubernetes.Clientset, ns string, sel map[string]string) (string, error) {
	if len(sel) == 0 {
		return "", fmt.Errorf("port-forward: service has no selector")
	}
	pods, err := cs.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: labels.Set(sel).String()})
	if err != nil {
		return "", fmt.Errorf("port-forward: %w", err)
	}
	for i := range pods.Items {
		p := &pods.Items[i]
		if p.Status.Phase == corev1.PodRunning && podReady(p) {
			return p.Name, nil
		}
	}
	for i := range pods.Items {
		if pods.Items[i].Status.Phase == corev1.PodRunning {
			return pods.Items[i].Name, nil
		}
	}
	return "", fmt.Errorf("port-forward: no running pods back this target")
}

func firstReadyPodForOwner(ctx context.Context, cs *kubernetes.Clientset, ns, owner string) (string, error) {
	pods, err := cs.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{})
	if err != nil {
		return "", fmt.Errorf("port-forward: %w", err)
	}
	prefixes := []string{owner + "-"}
	for i := range pods.Items {
		p := &pods.Items[i]
		for _, pre := range prefixes {
			if strings.HasPrefix(p.Name, pre) && p.Status.Phase == corev1.PodRunning && podReady(p) {
				return p.Name, nil
			}
		}
	}
	return "", fmt.Errorf("port-forward: no running pods for %q", owner)
}
