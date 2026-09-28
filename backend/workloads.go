// Workload browsing: pods, deployments, statefulsets, daemonsets, services,
// jobs, cronjobs, ingresses, configmaps, secrets, persistentvolumeclaims, and
// dynamically discovered CRDs in a single call.
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
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/metadata"
	"k8s.io/client-go/rest"
)

type podInfo struct {
	Name       string          `json:"name"`
	Namespace  string          `json:"namespace,omitempty"`
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
	Namespace  string `json:"namespace,omitempty"`
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
	Namespace  string `json:"namespace,omitempty"`
	Type       string `json:"type"`
	ClusterIP  string `json:"clusterIP"`
	Ports      string `json:"ports"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

type jobInfo struct {
	Name       string `json:"name"`
	Namespace  string `json:"namespace,omitempty"`
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

type ingressInfo struct {
	Name       string `json:"name"`
	Namespace  string `json:"namespace,omitempty"`
	Display    string `json:"display"`
	Kind       string `json:"kind"`
	Hosts      string `json:"hosts"`
	Class      string `json:"class"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

type configMapInfo struct {
	Name       string `json:"name"`
	Namespace  string `json:"namespace,omitempty"`
	Display    string `json:"display"`
	Kind       string `json:"kind"`
	DataCount  int    `json:"dataCount"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

type secretInfo struct {
	Name       string `json:"name"`
	Namespace  string `json:"namespace,omitempty"`
	Display    string `json:"display"`
	Kind       string `json:"kind"`
	Type       string `json:"type"`
	DataCount  int    `json:"dataCount"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

type pvcInfo struct {
	Name       string `json:"name"`
	Namespace  string `json:"namespace,omitempty"`
	Display    string `json:"display"`
	Kind       string `json:"kind"`
	Status     string `json:"status"`
	Capacity   string `json:"capacity"`
	Class      string `json:"class"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

type crdResourceInfo struct {
	Name       string `json:"name"`
	Namespace  string `json:"namespace,omitempty"`
	Kind       string `json:"kind"`
	Display    string `json:"display"`
	Meta       string `json:"meta,omitempty"`
	Age        string `json:"age"`
	AgeSeconds int64  `json:"ageSeconds"`
}

func runWorkloads(contextName, override, namespace string, timeoutSec int) error {
	ctxName := strings.TrimSpace(contextName)
	if ctxName == "" {
		return fmt.Errorf("workloads: --context is required")
	}
	rawNs := strings.TrimSpace(namespace)
	queryNs := rawNs
	if rawNs == "*" || rawNs == "all" || rawNs == "" {
		queryNs = ""
	}

	dyn, cs, cfg, err := dynamicClientFor(ctxName, override, timeoutSec)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), secondsToDuration(timeoutSec))
	defer cancel()

	result := map[string]any{"namespace": rawNs}
	if rawNs == "" {
		result["namespace"] = "*"
	}

	// 1. Pods
	if pods, err := cs.CoreV1().Pods(queryNs).List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err == nil {
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
				Name: p.Name, Namespace: p.Namespace, Phase: string(p.Status.Phase), Display: display, Kind: kind,
				Ready: ready, ReadyTotal: int32(len(p.Spec.Containers)), Restarts: restarts,
				Age: ageString(p.CreationTimestamp), AgeSeconds: ageSeconds(p.CreationTimestamp),
				Node: p.Spec.NodeName, PodIP: p.Status.PodIP,
				Containers: containers, Conditions: conds,
			})
		}
		sort.Slice(podInfos, func(i, j int) bool { return podInfos[i].Name < podInfos[j].Name })
		result["pods"] = podInfos
	} else {
		result["pods"] = []podInfo{}
	}

	// 2. Deployments
	if deps, err := cs.AppsV1().Deployments(queryNs).List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err == nil {
		depInfos := make([]scaleInfo, 0, len(deps.Items))
		for i := range deps.Items {
			d := &deps.Items[i]
			display, kind := deploymentDisplay(d)
			depInfos = append(depInfos, scaleInfo{
				Name: d.Name, Namespace: d.Namespace, Display: display, Kind: kind,
				Ready: d.Status.ReadyReplicas, Desired: d.Status.Replicas,
				Updated: d.Status.UpdatedReplicas, Available: d.Status.AvailableReplicas,
				Age: ageString(d.CreationTimestamp), AgeSeconds: ageSeconds(d.CreationTimestamp),
			})
		}
		sort.Slice(depInfos, func(i, j int) bool { return depInfos[i].Name < depInfos[j].Name })
		result["deployments"] = depInfos
	} else {
		result["deployments"] = []scaleInfo{}
	}

	// 3. StatefulSets
	if stss, err := cs.AppsV1().StatefulSets(queryNs).List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err == nil {
		infos := make([]scaleInfo, 0, len(stss.Items))
		for i := range stss.Items {
			s := &stss.Items[i]
			display, kind := "Ready", "running"
			if s.Status.ReadyReplicas < s.Status.Replicas {
				display = "Not ready"
				kind = "waiting"
			}
			infos = append(infos, scaleInfo{
				Name: s.Name, Namespace: s.Namespace, Display: display, Kind: kind,
				Ready: s.Status.ReadyReplicas, Desired: s.Status.Replicas,
				Updated: s.Status.UpdatedReplicas, Available: s.Status.ReadyReplicas,
				Age: ageString(s.CreationTimestamp), AgeSeconds: ageSeconds(s.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		result["statefulsets"] = infos
	} else {
		result["statefulsets"] = []scaleInfo{}
	}

	// 4. DaemonSets
	if dss, err := cs.AppsV1().DaemonSets(queryNs).List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err == nil {
		infos := make([]scaleInfo, 0, len(dss.Items))
		for i := range dss.Items {
			d := &dss.Items[i]
			display, kind := "Ready", "running"
			if d.Status.NumberReady < d.Status.DesiredNumberScheduled {
				display = "Not ready"
				kind = "waiting"
			}
			infos = append(infos, scaleInfo{
				Name: d.Name, Namespace: d.Namespace, Display: display, Kind: kind,
				Ready: d.Status.NumberReady, Desired: d.Status.DesiredNumberScheduled,
				Updated: d.Status.UpdatedNumberScheduled, Available: d.Status.NumberAvailable,
				Age: ageString(d.CreationTimestamp), AgeSeconds: ageSeconds(d.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		result["daemonsets"] = infos
	} else {
		result["daemonsets"] = []scaleInfo{}
	}

	// 5. Services
	if svcs, err := cs.CoreV1().Services(queryNs).List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err == nil {
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
				Name: s.Name, Namespace: s.Namespace, Type: string(s.Spec.Type), ClusterIP: s.Spec.ClusterIP,
				Ports: ports, Age: ageString(s.CreationTimestamp), AgeSeconds: ageSeconds(s.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		result["services"] = infos
	} else {
		result["services"] = []serviceInfo{}
	}

	// 6. Jobs & CronJobs
	jobs := []jobInfo{}
	if jl, err := cs.BatchV1().Jobs(queryNs).List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err == nil {
		for i := range jl.Items {
			j := &jl.Items[i]
			display, st := "Complete", "succeeded"
			if j.Status.Failed > 0 {
				display, st = "Failed", "failed"
			} else if j.Status.Active > 0 {
				display, st = "Running", "running"
			}
			jobs = append(jobs, jobInfo{
				Name: j.Name, Namespace: j.Namespace, Kind: "Job", StatusKind: st, Display: display,
				Succeeded: j.Status.Succeeded, Failed: j.Status.Failed, Active: j.Status.Active,
				Age: ageString(j.CreationTimestamp), AgeSeconds: ageSeconds(j.CreationTimestamp),
			})
		}
	}
	if cl, err := cs.BatchV1().CronJobs(queryNs).List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err == nil {
		for i := range cl.Items {
			c := &cl.Items[i]
			display, st := "Scheduled", "waiting"
			if len(c.Status.Active) > 0 {
				display, st = "Running", "running"
			}
			jobs = append(jobs, jobInfo{
				Name: c.Name, Namespace: c.Namespace, Kind: "CronJob", StatusKind: st, Display: display, Schedule: c.Spec.Schedule,
				Age: ageString(c.CreationTimestamp), AgeSeconds: ageSeconds(c.CreationTimestamp),
			})
		}
	}
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].Name < jobs[j].Name })
	result["jobs"] = jobs

	// 7. Ingresses
	if ings, err := cs.NetworkingV1().Ingresses(queryNs).List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err == nil && len(ings.Items) > 0 {
		infos := make([]ingressInfo, 0, len(ings.Items))
		for i := range ings.Items {
			ing := &ings.Items[i]
			hosts := []string{}
			for _, r := range ing.Spec.Rules {
				if r.Host != "" {
					hosts = append(hosts, r.Host)
				}
			}
			className := ""
			if ing.Spec.IngressClassName != nil {
				className = *ing.Spec.IngressClassName
			}
			infos = append(infos, ingressInfo{
				Name: ing.Name, Namespace: ing.Namespace, Display: "Active", Kind: "running",
				Hosts: strings.Join(hosts, ", "), Class: className,
				Age: ageString(ing.CreationTimestamp), AgeSeconds: ageSeconds(ing.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		result["ingresses"] = infos
	}

	// 8. ConfigMaps: Table query avoids retrieving large data payloads into memory.
	if cms := fetchConfigMaps(ctx, cs, queryNs, defaultListLimit); len(cms) > 0 {
		result["configmaps"] = cms
	}

	// 9. Secrets: Table query retrieves metadata, type, and key count WITHOUT fetching or decoding
	// sensitive credential values (.Data or .StringData) across the network or into memory.
	if secs := fetchSecretsMetadata(ctx, cs, cfg, queryNs, defaultListLimit); len(secs) > 0 {
		result["secrets"] = secs
	}

	// 10. PersistentVolumeClaims (PVC)
	if pvcs, err := cs.CoreV1().PersistentVolumeClaims(queryNs).List(ctx, metav1.ListOptions{Limit: defaultListLimit}); err == nil && len(pvcs.Items) > 0 {
		infos := make([]pvcInfo, 0, len(pvcs.Items))
		for i := range pvcs.Items {
			p := &pvcs.Items[i]
			status := string(p.Status.Phase)
			stKind := "running"
			if p.Status.Phase != corev1.ClaimBound {
				stKind = "waiting"
			}
			scName := ""
			if p.Spec.StorageClassName != nil {
				scName = *p.Spec.StorageClassName
			}
			capStr := ""
			if cap, ok := p.Status.Capacity[corev1.ResourceStorage]; ok {
				capStr = cap.String()
			}
			infos = append(infos, pvcInfo{
				Name: p.Name, Namespace: p.Namespace, Display: status, Kind: stKind,
				Status: status, Capacity: capStr, Class: scName,
				Age: ageString(p.CreationTimestamp), AgeSeconds: ageSeconds(p.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		result["pvc"] = infos
	}

	// 11. Dynamic Custom Resource Discovery (CRDs)
	queryCustomResources(ctx, dyn, cs, queryNs, result)

	raw, err := json.Marshal(result)
	if err != nil {
		return err
	}
	fmt.Println(string(raw))
	return nil
}

// queryCustomResources discovers Custom Resource Definitions (CRDs) available on the cluster
// and queries items in the namespace, populating them into the result map.
func queryCustomResources(ctx context.Context, dyn dynamic.Interface, cs *kubernetes.Clientset, ns string, result map[string]any) {
	if dyn == nil || cs == nil {
		return
	}
	lists, err := cs.Discovery().ServerPreferredResources()
	if err != nil && len(lists) == 0 {
		return
	}

	knownGroups := map[string]bool{
		"":                               true,
		"apps":                           true,
		"batch":                          true,
		"networking.k8s.io":              true,
		"events.k8s.io":                  true,
		"coordination.k8s.io":            true,
		"discovery.k8s.io":               true,
		"policy":                         true,
		"authentication.k8s.io":          true,
		"authorization.k8s.io":           true,
		"autoscaling":                    true,
		"admissionregistration.k8s.io":   true,
		"certificates.k8s.io":            true,
		"rbac.authorization.k8s.io":      true,
		"scheduling.k8s.io":              true,
		"storage.k8s.io":                 true,
		"metrics.k8s.io":                 true,
		"flowcontrol.apiserver.k8s.io":   true,
		"apiregistration.k8s.io":         true,
		"node.k8s.io":                    true,
	}

	knownKeys := map[string]bool{
		"pods":                   true,
		"deployments":            true,
		"statefulsets":           true,
		"daemonsets":             true,
		"services":               true,
		"jobs":                   true,
		"cronjobs":               true,
		"ingresses":              true,
		"configmaps":             true,
		"secrets":                true,
		"persistentvolumeclaims": true,
		"pvc":                    true,
		"namespace":              true,
		"events":                 true,
	}

	for _, list := range lists {
		gv, err := schema.ParseGroupVersion(list.GroupVersion)
		if err != nil {
			continue
		}
		if knownGroups[gv.Group] {
			continue
		}

		for _, res := range list.APIResources {
			if strings.Contains(res.Name, "/") || knownKeys[res.Name] {
				continue // Subresources or already tracked standard resources
			}
			canList := false
			for _, v := range res.Verbs {
				if v == "list" {
					canList = true
					break
				}
			}
			if !canList {
				continue
			}

			gvr := gv.WithResource(res.Name)
			var uList any
			var err error
			if res.Namespaced && ns != "" {
				uList, err = dyn.Resource(gvr).Namespace(ns).List(ctx, metav1.ListOptions{Limit: 50})
			} else if !res.Namespaced && ns != "" {
				continue // Don't list cluster-wide resources if user filtered to a specific namespace
			} else {
				uList, err = dyn.Resource(gvr).List(ctx, metav1.ListOptions{Limit: 50})
			}

			if err != nil {
				continue
			}

			bytes, mErr := json.Marshal(uList)
			if mErr != nil {
				continue
			}
			var parsed struct {
				Items []struct {
					Metadata metav1.ObjectMeta `json:"metadata"`
					Status   map[string]any    `json:"status"`
				} `json:"items"`
			}
			if pErr := json.Unmarshal(bytes, &parsed); pErr != nil || len(parsed.Items) == 0 {
				continue
			}

			items := make([]crdResourceInfo, 0, len(parsed.Items))
			for _, item := range parsed.Items {
				statusStr := "Ready"
				if item.Status != nil {
					if ph, ok := item.Status["phase"].(string); ok && ph != "" {
						statusStr = ph
					} else if st, ok := item.Status["status"].(string); ok && st != "" {
						statusStr = st
					}
				}
				items = append(items, crdResourceInfo{
					Name:      item.Metadata.Name,
					Namespace: item.Metadata.Namespace,
					Kind:      res.Kind,
					Display:   statusStr,
					Meta:      fmt.Sprintf("%s/%s", gv.Group, gv.Version),
					Age:       ageString(item.Metadata.CreationTimestamp),
					AgeSeconds: ageSeconds(item.Metadata.CreationTimestamp),
				})
			}
			sort.Slice(items, func(i, j int) bool { return items[i].Name < items[j].Name })
			result[res.Name] = items
		}
	}
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

// fetchSecretsMetadata queries secrets as a Table to retrieve metadata, type, and key counts
// WITHOUT fetching or decoding sensitive Secret payload/credential values (.Data, .StringData).
// The API server converts the secret into table rows containing only display columns,
// completely avoiding credential transmission and unnecessary memory allocation.
func fetchSecretsMetadata(ctx context.Context, cs *kubernetes.Clientset, cfg *rest.Config, queryNs string, limit int64) []secretInfo {
	var table metav1.Table
	req := cs.CoreV1().RESTClient().Get().
		Resource("secrets").
		SetHeader("Accept", "application/json;as=Table;v=v1;g=meta.k8s.io,application/json;as=Table;v=v1beta1;g=meta.k8s.io")
	if queryNs != "" {
		req = req.Namespace(queryNs)
	}
	opts := metav1.ListOptions{Limit: limit}
	err := req.VersionedParams(&opts, metav1.ParameterCodec).Do(ctx).Into(&table)
	if err == nil && len(table.Rows) > 0 {
		nameCol, typeCol, dataCol := -1, -1, -1
		for idx, col := range table.ColumnDefinitions {
			switch strings.ToLower(col.Name) {
			case "name":
				nameCol = idx
			case "type":
				typeCol = idx
			case "data":
				dataCol = idx
			}
		}

		infos := make([]secretInfo, 0, len(table.Rows))
		for _, row := range table.Rows {
			var meta metav1.PartialObjectMetadata
			if len(row.Object.Raw) > 0 {
				_ = json.Unmarshal(row.Object.Raw, &meta)
			}
			name := meta.Name
			if name == "" && nameCol >= 0 && nameCol < len(row.Cells) {
				name = fmt.Sprintf("%v", row.Cells[nameCol])
			}
			if name == "" {
				continue
			}
			ns := meta.Namespace
			if ns == "" && queryNs != "" {
				ns = queryNs
			}
			secType := "Opaque"
			if typeCol >= 0 && typeCol < len(row.Cells) {
				if tStr := fmt.Sprintf("%v", row.Cells[typeCol]); tStr != "" && tStr != "<nil>" {
					secType = tStr
				}
			}
			dataCount := 0
			if dataCol >= 0 && dataCol < len(row.Cells) {
				switch v := row.Cells[dataCol].(type) {
				case float64:
					dataCount = int(v)
				case int64:
					dataCount = int(v)
				case int:
					dataCount = v
				case string:
					fmt.Sscanf(v, "%d", &dataCount)
				}
			}
			age := ageString(meta.CreationTimestamp)
			ageSec := ageSeconds(meta.CreationTimestamp)
			infos = append(infos, secretInfo{
				Name:       name,
				Namespace:  ns,
				Display:    secType,
				Kind:       "running",
				Type:       secType,
				DataCount:  dataCount,
				Age:        age,
				AgeSeconds: ageSec,
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		return infos
	}

	// Safe fallback: metadata-only client. Never downloads or decodes Secret .Data or credentials.
	if cfg != nil {
		if metaClient, mErr := metadata.NewForConfig(cfg); mErr == nil {
			gvr := schema.GroupVersionResource{Group: "", Version: "v1", Resource: "secrets"}
			var mList *metav1.PartialObjectMetadataList
			if queryNs != "" {
				mList, err = metaClient.Resource(gvr).Namespace(queryNs).List(ctx, metav1.ListOptions{Limit: limit})
			} else {
				mList, err = metaClient.Resource(gvr).List(ctx, metav1.ListOptions{Limit: limit})
			}
			if err == nil && len(mList.Items) > 0 {
				infos := make([]secretInfo, 0, len(mList.Items))
				for i := range mList.Items {
					m := &mList.Items[i]
					infos = append(infos, secretInfo{
						Name:       m.Name,
						Namespace:  m.Namespace,
						Display:    "Secret",
						Kind:       "running",
						Type:       "Secret",
						DataCount:  0,
						Age:        ageString(m.CreationTimestamp),
						AgeSeconds: ageSeconds(m.CreationTimestamp),
					})
				}
				sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
				return infos
			}
		}
	}

	return nil
}

// fetchConfigMaps lists configmaps, preferring a Table request to avoid fetching large config payloads.
// Falls back to bounded standard List if Table is unavailable.
func fetchConfigMaps(ctx context.Context, cs *kubernetes.Clientset, queryNs string, limit int64) []configMapInfo {
	var table metav1.Table
	req := cs.CoreV1().RESTClient().Get().
		Resource("configmaps").
		SetHeader("Accept", "application/json;as=Table;v=v1;g=meta.k8s.io,application/json;as=Table;v=v1beta1;g=meta.k8s.io")
	if queryNs != "" {
		req = req.Namespace(queryNs)
	}
	opts := metav1.ListOptions{Limit: limit}
	err := req.VersionedParams(&opts, metav1.ParameterCodec).Do(ctx).Into(&table)
	if err == nil && len(table.Rows) > 0 {
		nameCol, dataCol := -1, -1
		for idx, col := range table.ColumnDefinitions {
			switch strings.ToLower(col.Name) {
			case "name":
				nameCol = idx
			case "data":
				dataCol = idx
			}
		}

		infos := make([]configMapInfo, 0, len(table.Rows))
		for _, row := range table.Rows {
			var meta metav1.PartialObjectMetadata
			if len(row.Object.Raw) > 0 {
				_ = json.Unmarshal(row.Object.Raw, &meta)
			}
			name := meta.Name
			if name == "" && nameCol >= 0 && nameCol < len(row.Cells) {
				name = fmt.Sprintf("%v", row.Cells[nameCol])
			}
			if name == "" {
				continue
			}
			ns := meta.Namespace
			if ns == "" && queryNs != "" {
				ns = queryNs
			}
			dataCount := 0
			if dataCol >= 0 && dataCol < len(row.Cells) {
				switch v := row.Cells[dataCol].(type) {
				case float64:
					dataCount = int(v)
				case int64:
					dataCount = int(v)
				case int:
					dataCount = v
				case string:
					fmt.Sscanf(v, "%d", &dataCount)
				}
			}
			infos = append(infos, configMapInfo{
				Name:       name,
				Namespace:  ns,
				Display:    fmt.Sprintf("%d keys", dataCount),
				Kind:       "running",
				DataCount:  dataCount,
				Age:        ageString(meta.CreationTimestamp),
				AgeSeconds: ageSeconds(meta.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		return infos
	}

	// Fallback to standard List with strict Limit
	if cms, err := cs.CoreV1().ConfigMaps(queryNs).List(ctx, metav1.ListOptions{Limit: limit}); err == nil && len(cms.Items) > 0 {
		infos := make([]configMapInfo, 0, len(cms.Items))
		for i := range cms.Items {
			cm := &cms.Items[i]
			infos = append(infos, configMapInfo{
				Name:       cm.Name,
				Namespace:  cm.Namespace,
				Display:    fmt.Sprintf("%d keys", len(cm.Data)),
				Kind:       "running",
				DataCount:  len(cm.Data),
				Age:        ageString(cm.CreationTimestamp),
				AgeSeconds: ageSeconds(cm.CreationTimestamp),
			})
		}
		sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
		return infos
	}
	return nil
}
