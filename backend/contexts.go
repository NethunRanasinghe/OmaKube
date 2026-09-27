package main

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

type contextInfo struct {
	Name      string `json:"name"`
	Host      string `json:"host"`
	Auth      string `json:"auth"`
	Namespace string `json:"namespace"`
	Active    bool   `json:"active"`
}

func runContexts(asJSON bool, override string) error {
	raw, err := rawConfig(override)
	if err != nil {
		return err
	}
	current := raw.CurrentContext
	infos := make([]contextInfo, 0, len(raw.Contexts))
	for name, ctx := range raw.Contexts {
		cluster := raw.Clusters[ctx.Cluster]
		user := raw.AuthInfos[ctx.AuthInfo]
		ns := strings.TrimSpace(ctx.Namespace)
		if ns == "" {
			ns = "default"
		}
		infos = append(infos, contextInfo{
			Name:      name,
			Host:      clusterHost(cluster),
			Auth:      authMethod(user),
			Namespace: ns,
			Active:    name == current,
		})
	}
	sort.Slice(infos, func(i, j int) bool { return infos[i].Name < infos[j].Name })
	if !asJSON {
		for _, c := range infos {
			mark := " "
			if c.Active {
				mark = "*"
			}
			fmt.Printf("%s %-30s %-40s %s\n", mark, c.Name, c.Host, c.Auth)
		}
		return nil
	}
	out, err := json.Marshal(map[string]any{"current": current, "contexts": infos})
	if err != nil {
		return err
	}
	fmt.Println(string(out))
	return nil
}

func clusterHost(c *clientcmdapi.Cluster) string {
	if c == nil {
		return ""
	}
	return strings.TrimSpace(c.Server)
}

func authMethod(u *clientcmdapi.AuthInfo) string {
	if u == nil {
		return "none"
	}
	switch {
	case u.Exec != nil:
		return "exec:" + u.Exec.Command
	case u.Token != "" || u.TokenFile != "":
		return "token"
	case u.ClientCertificate != "" || u.ClientCertificateData != nil:
		return "cert"
	case u.Username != "":
		return "basic"
	case u.AuthProvider != nil:
		return "oidc:" + u.AuthProvider.Name
	default:
		return "unknown"
	}
}
