// One-click context switching: moves only the current-context pointer
// (same semantics as `kubectl config use-context`). Credentials are never
// touched.
package main

import (
	"encoding/json"
	"fmt"
	"strings"

	"k8s.io/client-go/tools/clientcmd"
)

func runUseContext(name, override string) error {
	target := strings.TrimSpace(name)
	if target == "" {
		return fmt.Errorf("use-context: context name is required")
	}
	raw, err := rawConfig(override)
	if err != nil {
		return err
	}
	if _, ok := raw.Contexts[target]; !ok {
		return fmt.Errorf("no such context %q", target)
	}
	raw.CurrentContext = target

	if override != "" {
		if err := clientcmd.WriteToFile(raw, override); err != nil {
			return err
		}
	} else if err := clientcmd.ModifyConfig(clientcmd.NewDefaultPathOptions(), raw, true); err != nil {
		return err
	}
	out, _ := json.Marshal(map[string]any{"current": target})
	fmt.Println(string(out))
	return nil
}
