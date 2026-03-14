// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package cluster

import (
	"context"
	"fmt"
	"sync"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

// Registry manages clients for managed clusters. It resolves cluster names
// to Kubernetes clients by reading kubeconfig data from Secrets on the hub.
type Registry struct {
	hubClient client.Client
	namespace string // namespace where kubeconfig Secrets live
	log       logr.Logger

	mu             sync.RWMutex
	restConfigs    map[string]*rest.Config
	dynamicClients map[string]dynamic.Interface

	// fallbackKubeconfig is an optional path to a kubeconfig file
	// with contexts matching cluster names (for dev/testing)
	fallbackKubeconfig string
}

// NewRegistry creates a cluster registry that reads kubeconfig Secrets
// from the given namespace on the hub cluster.
func NewRegistry(hubClient client.Client, namespace string, log logr.Logger) *Registry {
	return &Registry{
		hubClient:      hubClient,
		namespace:      namespace,
		log:            log.WithName("cluster-registry"),
		restConfigs:    make(map[string]*rest.Config),
		dynamicClients: make(map[string]dynamic.Interface),
	}
}

// SetFallbackKubeconfig sets a kubeconfig file path to use as fallback
// when no Secret is found for a cluster.
func (r *Registry) SetFallbackKubeconfig(path string) {
	r.fallbackKubeconfig = path
}

// GetDynamicClient returns a dynamic client for the named managed cluster.
func (r *Registry) GetDynamicClient(clusterName string) (dynamic.Interface, error) {
	r.mu.RLock()
	if dc, ok := r.dynamicClients[clusterName]; ok {
		r.mu.RUnlock()
		return dc, nil
	}
	r.mu.RUnlock()

	cfg, err := r.getRESTConfig(clusterName)
	if err != nil {
		return nil, fmt.Errorf("getting REST config for cluster %s: %w", clusterName, err)
	}

	dc, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("creating dynamic client for cluster %s: %w", clusterName, err)
	}

	r.mu.Lock()
	r.dynamicClients[clusterName] = dc
	r.mu.Unlock()

	return dc, nil
}

// InvalidateClient removes a cached client for the named cluster,
// forcing a fresh connection on next access.
func (r *Registry) InvalidateClient(clusterName string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.restConfigs, clusterName)
	delete(r.dynamicClients, clusterName)
}

func (r *Registry) getRESTConfig(clusterName string) (*rest.Config, error) {
	r.mu.RLock()
	if cfg, ok := r.restConfigs[clusterName]; ok {
		r.mu.RUnlock()
		return cfg, nil
	}
	r.mu.RUnlock()

	// Try loading from Secret first
	cfg, err := r.loadFromSecret(clusterName)
	if err != nil {
		r.log.V(1).Info("No kubeconfig Secret found, trying fallback", "cluster", clusterName, "error", err)

		// Fall back to kubeconfig contexts
		cfg, err = r.loadFromKubeconfig(clusterName)
		if err != nil {
			return nil, fmt.Errorf("no kubeconfig available for cluster %s: %w", clusterName, err)
		}
	}

	r.mu.Lock()
	r.restConfigs[clusterName] = cfg
	r.mu.Unlock()

	r.log.Info("Loaded REST config for cluster", "cluster", clusterName)

	return cfg, nil
}

// loadFromSecret reads a kubeconfig from Secret <clusterName>-kubeconfig
// in the controller namespace.
func (r *Registry) loadFromSecret(clusterName string) (*rest.Config, error) {
	secret := &corev1.Secret{}
	key := types.NamespacedName{
		Name:      clusterName + "-kubeconfig",
		Namespace: r.namespace,
	}

	if err := r.hubClient.Get(context.Background(), key, secret); err != nil {
		return nil, fmt.Errorf("getting kubeconfig Secret %s: %w", key, err)
	}

	kubeconfigData, ok := secret.Data["kubeconfig"]
	if !ok {
		// Also try "value" key (common in Rancher)
		kubeconfigData, ok = secret.Data["value"]
		if !ok {
			return nil, fmt.Errorf("Secret %s has no 'kubeconfig' or 'value' key", key)
		}
	}

	cfg, err := clientcmd.RESTConfigFromKubeConfig(kubeconfigData)
	if err != nil {
		return nil, fmt.Errorf("parsing kubeconfig from Secret %s: %w", key, err)
	}

	return cfg, nil
}

// loadFromKubeconfig loads a REST config from a kubeconfig file using
// the cluster name as the context name.
func (r *Registry) loadFromKubeconfig(clusterName string) (*rest.Config, error) {
	loadingRules := &clientcmd.ClientConfigLoadingRules{}
	if r.fallbackKubeconfig != "" {
		loadingRules.ExplicitPath = r.fallbackKubeconfig
	} else {
		loadingRules = clientcmd.NewDefaultClientConfigLoadingRules()
	}

	cfg, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		loadingRules,
		&clientcmd.ConfigOverrides{CurrentContext: clusterName},
	).ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("loading kubeconfig context %s: %w", clusterName, err)
	}

	return cfg, nil
}
