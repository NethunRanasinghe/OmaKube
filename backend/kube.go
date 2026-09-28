// Shared kubeconfig loading: behaves exactly like kubectl — respects
// $KUBECONFIG, defaults to ~/.kube/config, merges multiple files, and never
// copies or stores credentials anywhere.
package main

import (
	"os"

	"k8s.io/cli-runtime/pkg/genericclioptions"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	clientcmdapi "k8s.io/client-go/tools/clientcmd/api"
)

const (
	// defaultListLimit bounds the number of items requested per API call,
	// preventing cluster-controlled memory exhaustion in the helper process.
	// 500 is consistent with kubectl's default chunk size.
	defaultListLimit = 500

	// maxEventsLimit bounds the events returned to the most recent items.
	maxEventsLimit = 200

	// maxHealthPodLimit bounds the pod count evaluated during periodic health checks.
	maxHealthPodLimit = 1000

	// maxCRDItemsPerType bounds the maximum number of items returned per CRD type.
	maxCRDItemsPerType = 50
)

// rawConfig loads the merged kubeconfig, optionally restricted to a single
// file via --kubeconfig (the settings override).
func rawConfig(kubeconfigOverride string) (clientcmdapi.Config, error) {
	if kubeconfigOverride != "" {
		loadingRules := clientcmd.NewDefaultClientConfigLoadingRules()
		loadingRules.ExplicitPath = kubeconfigOverride
		cfg, err := loadingRules.Load()
		if err != nil {
			return clientcmdapi.Config{}, err
		}
		return *cfg, nil
	}
	flags := genericclioptions.NewConfigFlags(true)
	loader := flags.ToRawKubeConfigLoader()
	raw, err := loader.RawConfig()
	if err != nil {
		return clientcmdapi.Config{}, err
	}
	return raw, nil
}

// restConfigFor builds a REST config pinned to one context.
func restConfigFor(raw clientcmdapi.Config, contextName string, timeoutSec int) (*rest.Config, error) {
	overrides := &clientcmd.ConfigOverrides{CurrentContext: contextName}
	cc := clientcmd.NewNonInteractiveClientConfig(raw, contextName, overrides, nil)
	cfg, err := cc.ClientConfig()
	if err != nil {
		return nil, err
	}
	if timeoutSec > 0 {
		cfg.Timeout = secondsToDuration(timeoutSec)
	}
	return cfg, nil
}

func kubeconfigPathForWrite(override string) (string, error) {
	if override != "" {
		return override, nil
	}
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	return rules.GetDefaultFilename(), nil
}

func getenvDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
