// OmaKube backend — Go CLI invoked per-query from QML (same pattern as the
// native tailscale/dropbox panels: short-lived subprocess, no daemon, no
// socket). Reads kubeconfig exactly like kubectl via clientcmd; never copies,
// stores, or transmits credentials elsewhere.
package main

import (
	"flag"
	"fmt"
	"os"
)

// exitError carries a process exit code without printing anything extra
// (the JSON report is already on stdout).
type exitError struct{ code int }

func (e exitError) Error() string { return fmt.Sprintf("exit %d", e.code) }

func errExit(code int) error {
	if code == 0 {
		return nil
	}
	return exitError{code: code}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: omakube <command> [flags]")
	fmt.Fprintln(os.Stderr, "  contexts [--json] [--kubeconfig PATH]")
	fmt.Fprintln(os.Stderr, "  health --context NAME [--namespace NS] [--timeout SEC] [--kubeconfig PATH]")
	fmt.Fprintln(os.Stderr, "  use-context NAME [--kubeconfig PATH]")
	fmt.Fprintln(os.Stderr, "  namespaces --context NAME [--timeout SEC] [--kubeconfig PATH]")
	fmt.Fprintln(os.Stderr, "  workloads --context NAME [--namespace NS] [--timeout SEC] [--kubeconfig PATH]")
	fmt.Fprintln(os.Stderr, "  events --context NAME [--namespace NS] [--timeout SEC] [--kubeconfig PATH]")
	fmt.Fprintln(os.Stderr, "  logs --context NAME [--namespace NS] --pod POD [--container C] [--tail N] [--out PATH] [--kubeconfig PATH]")
	fmt.Fprintln(os.Stderr, "  restart --context NAME [--namespace NS] --kind deployment|statefulset|daemonset --name NAME")
	fmt.Fprintln(os.Stderr, "  delete-pod --context NAME [--namespace NS] --name POD")
	fmt.Fprintln(os.Stderr, "  port-forward --context NAME [--namespace NS] --target-kind pod|service|deployment --target NAME [--local-port L] --remote-port R")
}

func main() {
	if len(os.Args) < 2 || os.Args[1] == "-h" || os.Args[1] == "--help" || os.Args[1] == "help" {
		usage()
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "contexts":
		fs := flag.NewFlagSet("contexts", flag.ContinueOnError)
		asJSON := fs.Bool("json", false, "")
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		err = runContexts(*asJSON, *kcfg)
	case "health":
		fs := flag.NewFlagSet("health", flag.ContinueOnError)
		ctx := fs.String("context", "", "")
		ns := fs.String("namespace", "default", "")
		timeout := fs.Int("timeout", 8, "")
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		err = runHealth(*ctx, *kcfg, *ns, *timeout)
	case "use-context":
		fs := flag.NewFlagSet("use-context", flag.ContinueOnError)
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		rest := fs.Args()
		name := ""
		if len(rest) > 0 {
			name = rest[0]
		}
		err = runUseContext(name, *kcfg)
	case "namespaces":
		fs := flag.NewFlagSet("namespaces", flag.ContinueOnError)
		ctx := fs.String("context", "", "")
		timeout := fs.Int("timeout", 8, "")
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		err = runNamespaces(*ctx, *kcfg, *timeout)
	case "workloads":
		fs := flag.NewFlagSet("workloads", flag.ContinueOnError)
		ctx := fs.String("context", "", "")
		ns := fs.String("namespace", "default", "")
		timeout := fs.Int("timeout", 10, "")
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		err = runWorkloads(*ctx, *kcfg, *ns, *timeout)
	case "events":
		fs := flag.NewFlagSet("events", flag.ContinueOnError)
		ctx := fs.String("context", "", "")
		ns := fs.String("namespace", "default", "")
		timeout := fs.Int("timeout", 8, "")
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		err = runEvents(*ctx, *kcfg, *ns, *timeout)
	case "logs":
		fs := flag.NewFlagSet("logs", flag.ContinueOnError)
		ctx := fs.String("context", "", "")
		ns := fs.String("namespace", "default", "")
		pod := fs.String("pod", "", "")
		container := fs.String("container", "", "")
		tail := fs.Int("tail", 200, "")
		out := fs.String("out", "", "")
		timeout := fs.Int("timeout", 10, "")
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		err = runLogs(*ctx, *kcfg, *ns, *pod, *container, *tail, *out, *timeout)
	case "restart":
		fs := flag.NewFlagSet("restart", flag.ContinueOnError)
		ctx := fs.String("context", "", "")
		ns := fs.String("namespace", "default", "")
		kind := fs.String("kind", "deployment", "")
		name := fs.String("name", "", "")
		timeout := fs.Int("timeout", 10, "")
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		err = runRestart(*ctx, *kcfg, *ns, *kind, *name, *timeout)
	case "delete-pod":
		fs := flag.NewFlagSet("delete-pod", flag.ContinueOnError)
		ctx := fs.String("context", "", "")
		ns := fs.String("namespace", "default", "")
		name := fs.String("name", "", "")
		timeout := fs.Int("timeout", 10, "")
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		err = runDeletePod(*ctx, *kcfg, *ns, *name, *timeout)
	case "port-forward":
		fs := flag.NewFlagSet("port-forward", flag.ContinueOnError)
		ctx := fs.String("context", "", "")
		ns := fs.String("namespace", "default", "")
		tkind := fs.String("target-kind", "service", "")
		target := fs.String("target", "", "")
		local := fs.Int("local-port", 0, "")
		remote := fs.Int("remote-port", 0, "")
		timeout := fs.Int("timeout", 10, "")
		kcfg := fs.String("kubeconfig", "", "")
		if ferr := fs.Parse(os.Args[2:]); ferr != nil {
			os.Exit(2)
		}
		err = runPortForward(*ctx, *kcfg, *ns, *tkind, *target, *local, *remote, *timeout)
	default:
		fmt.Fprintln(os.Stderr, "omakube: unknown command:", os.Args[1])
		os.Exit(2)
	}
	if err != nil {
		if ee, ok := err.(exitError); ok {
			os.Exit(ee.code)
		}
		fmt.Fprintln(os.Stderr, "omakube:", err)
		os.Exit(1)
	}
}
