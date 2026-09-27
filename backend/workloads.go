// Workload browsing: pods, deployments, statefulsets, daemonsets, services,
// jobs and cronjobs for one namespace in a single call.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

type podInfo struct {
	Name       string          `json:"name"`
	Phase      string          `json:"phase"`
	Display    string          `json:"display"`
	Kind       string          `json:"kind"`
	Ready      int32           `json:"ready"`
	ReadyTotal int32           `json:"readyTotal"`
	Restarts   int32           `json:"restarts"`
	Age        string          `json:"age"`
	AgeSeconds int64           `json:"ageSeconds"`
	Node       string          `json:"node"`
	PodIP      string          `json:"podIP"`
	Containers []containerInfo `json:"containers"`
	Conditions []conditionInfo `json:"conditions"`
}

type scaleInfo struct {
	Name       string `json:"name"`
	Display    string `json:"display"`
	Kind       string `json:"kind"`
	Ready      int32  `json:"ready"`
	Desired    int32  `json:"desired"`
	Updated    int32  `json:"updated"`
	Available  int32  `json:"available"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

type serviceInfo struct {
	Name       string `json:"name"`
	Type       string `json:"type"`
	ClusterIP  string `json:"clusterIP"`
	Ports      string `json:"ports"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

type jobInfo struct {
	Name       string `json:"name"`
	Kind       string `json:"kind"` // Job | CronJob
	StatusKind string `json:"statusKind"`
	Display    string `json:"display"`
	Succeeded  int32  `json:"succeeded"`
	Failed     int32  `json:"failed"`
	Active     int32  `json:"active"`
	Schedule   string `json:"schedule"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

func runWorkloads(contextName, override, namespace string, timeoutSec int) error {
	ctxName := strings.TrimSpace(contextName)
	if ctxName == "" {
		return fmt.Errorf("workloads: --context is required")
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

	result := map[string]any{"namespace": ns}

	pods, err := cs.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("pods: %w", err)
	}
	podInfos := make([]podInfo, 0, len(pods.Items))
	for i := range pods.Items {
		p := &pods.Items[i]
		display, kind := podDisplay(p)
		var ready, restarts int32
		containers := make([]containerInfo, 0, len(p.Spec.Containers))
		statusByName := map[string]corev1.ContainerStatus{}
		for _, s := range p.Status.ContainerStatuses {
			statusByName[s.Name] = s
		}
		for _, c := range p.Spec.Containers {
			ci := containerInfo{Name: c.Name, Image: c.Image}
			if s, ok := statusByName[c.Name]; ok {
				ci.Ready = s.Ready
				ci.Restarts = s.RestartCount
				ci.State = containerState(s)
				if s.Ready {
					ready++
				}
				restarts += s.RestartCount
			} else {
				ci.State = "waiting"
			}
			containers = append(containers, ci)
		}
		conds := make([]conditionInfo, 0, len(p.Status.Conditions))
		for _, c := range p.Status.Conditions {
			conds = append(conds, conditionInfo{Type: string(c.Type), Status: string(c.Status), Reason: c.Reason})
		}
		podInfos = append(podInfos, podInfo{
			Name: p.Name, Phase: string(p.Status.Phase), Display: display, Kind: kind,
			Ready: ready, ReadyTotal: int32(len(p.Spec.Containers)), Restarts: restarts,
			Age: ageString(p.CreationTimestamp), AgeSeconds: ageSeconds(p.CreationTimestamp),
			Node: p.Spec.NodeName, PodIP: p.Status.PodIP,
			Containers: containers, Conditions: conds,
		})
	}
	sort.Slice(podInfos, func(i, j int) bool { return podInfos[i].Name < podInfos[j].Name })
	result["pods"] = podInfos

	deps, err := cs.AppsV1().Deployments(ns).List(ctx, metav1.ListOptions{})
	if err != nil {
		return fmt.Errorf("deployments: %w", err)
	}
	depInfos := make([]scaleInfo, 0, len(deps.Items))
	for i := range deps.Items {
		d := &deps.Items[i]
		display, kind := deploymentDisplay(d)
		depInfos = append(depInfos, scaleInfo{
			Name: d.Name, Display: display, Kind: kind,
			Ready: d.Status.ReadyReplicas, Desired: d.Status.Replicas,
			Updated: d.Status.UpdatedReplicas, Available: d.Status.AvailableReplicas,
			Age: ageString(d.CreationTimestamp), AgeSeconds: ageSeconds(d.CreationTimestamp),
		})
	}
	sort.Slice(depInfos, func(i, j int) bool { return depInfos[i].Name < depInfos[j].Name })
	result["deployments"] = depInfos

	if stss, err := cs.AppsV1().StatefulSets(ns).List(ctx, metav1.ListOptions{}); err == nil {
		infos := make([]scaleInfo, 0, len(stss.Items))
		for i := range stss.Items {
			s := &stss.Items[i]
			display, kind := "Ready", "running"
			if s.Status.ReadyReplicas < s.Status.Replicas {
				display = "Not ready"
				kind = "waiting"
			}
			infos = append(infos, scaleInfo{
				Name: s.Name, Display: display, Kind: kind,
				Ready: s.Status.ReadyReplicas, Desired: s.Status.Replicas,
				Updated: s.Status.UpdatedReplicas, Available: s.Status.ReadyReplicas,
				Age: ageString(s.CreationTimestamp), AgeSeconds: ageSeconds(s.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		result["statefulsets"] = infos
	}

	if dss, err := cs.AppsV1().DaemonSets(ns).List(ctx, metav1.ListOptions{}); err == nil {
		infos := make([]scaleInfo, 0, len(dss.Items))
		for i := range dss.Items {
			d := &dss.Items[i]
			display, kind := "Ready", "running"
			if d.Status.NumberReady < d.Status.DesiredNumberScheduled {
				display = "Not ready"
				kind = "waiting"
			}
			infos = append(infos, scaleInfo{
				Name: d.Name, Display: display, Kind: kind,
				Ready: d.Status.NumberReady, Desired: d.Status.DesiredNumberScheduled,
				Updated: d.Status.UpdatedNumberScheduled, Available: d.Status.NumberAvailable,
				Age: ageString(d.CreationTimestamp), AgeSeconds: ageSeconds(d.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		result["daemonsets"] = infos
	}

	if svcs, err := cs.CoreV1().Services(ns).List(ctx, metav1.ListOptions{}); err == nil {
		infos := make([]serviceInfo, 0, len(svcs.Items))
		for i := range svcs.Items {
			s := &svcs.Items[i]
			ports := ""
			for pi, p := range s.Spec.Ports {
				if pi > 0 {
					ports += ","
				}
				ports += fmt.Sprintf("%d:%d/%s", p.Port, p.TargetPort.IntVal, p.Protocol)
			}
			infos = append(infos, serviceInfo{
				Name: s.Name, Type: string(s.Spec.Type), ClusterIP: s.Spec.ClusterIP,
				Ports: ports, Age: ageString(s.CreationTimestamp), AgeSeconds: ageSeconds(s.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		result["services"] = infos
	}

	jobs := []jobInfo{}
	if jl, err := cs.BatchV1().Jobs(ns).List(ctx, metav1.ListOptions{}); err == nil {
		for i := range jl.Items {
			j := &jl.Items[i]
			display, st := "Complete", "succeeded"
			if j.Status.Failed > 0 {
				display, st = "Failed", "failed"
			} else if j.Status.Active > 0 {
				display, st = "Running", "running"
			}
			jobs = append(jobs, jobInfo{
				Name: j.Name, Kind: "Job", StatusKind: st, Display: display,
				Succeeded: j.Status.Succeeded, Failed: j.Status.Failed, Active: j.Status.Active,
				Age: ageString(j.CreationTimestamp), AgeSeconds: ageSeconds(j.CreationTimestamp),
			})
		}
	}
	if cl, err := cs.BatchV1().CronJobs(ns).List(ctx, metav1.ListOptions{}); err == nil {
		for i := range cl.Items {
			c := &cl.Items[i]
			display, st := "Scheduled", "waiting"
			if len(c.Status.Active) > 0 {
				display, st = "Running", "running"
			}
			jobs = append(jobs, jobInfo{
				Name: c.Name, Kind: "CronJob", StatusKind: st, Display: display, Schedule: c.Spec.Schedule,
				Age: ageString(c.CreationTimestamp), AgeSeconds: ageSeconds(c.CreationTimestamp),
			})
		}
	}
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].Name < jobs[j].Name })
	result["jobs"] = jobs

	raw, err := json.Marshal(result)
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}

func deploymentDisplay(d *appsv1.Deployment) (string, string) {
	for _, c := range d.Status.Conditions {
		if c.Type == appsv1.DeploymentAvailable && c.Status == corev1.ConditionFalse {
			return "Unavailable", "failed"
		}
		if c.Type == appsv1.DeploymentProgressing && c.Reason == "ProgressDeadlineExceeded" {
			return "Stalled", "failed"
		}
	}
	if d.Status.UpdatedReplicas != d.Status.Replicas || d.Status.ReadyReplicas < d.Status.Replicas {
		return "Progressing", "waiting"
	}
	return "Available", "running"
}
