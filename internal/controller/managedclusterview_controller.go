// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package controller

import (
	"context"
	"encoding/json"
	"fmt"
	"reflect"
	"strings"
	"time"

	"github.com/go-logr/logr"
	"github.com/ramendr/ramen-ots/internal/cluster"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	defaultMCVRequeueInterval = 15 * time.Second
)

// ManagedClusterViewReconciler fulfills ManagedClusterView CRs by reading
// the specified resource from managed clusters via direct kubeconfig access.
type ManagedClusterViewReconciler struct {
	client.Client
	Log             logr.Logger
	Registry        *cluster.Registry
	RequeueInterval time.Duration
}

func (r *ManagedClusterViewReconciler) requeueInterval() time.Duration {
	if r.RequeueInterval > 0 {
		return r.RequeueInterval
	}
	return defaultMCVRequeueInterval
}

func (r *ManagedClusterViewReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("managedclusterview", req.NamespacedName)

	// Get the MCV using unstructured since we defined the types locally
	mcvUnst := &unstructured.Unstructured{}
	mcvUnst.SetGroupVersionKind(ManagedClusterViewGVK)
	if err := r.Get(ctx, req.NamespacedName, mcvUnst); err != nil {
		if k8serrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Parse into our local type
	mcv := &ManagedClusterView{}
	data, err := json.Marshal(mcvUnst.Object)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("marshaling MCV: %w", err)
	}
	if err := json.Unmarshal(data, mcv); err != nil {
		return ctrl.Result{}, fmt.Errorf("unmarshaling MCV: %w", err)
	}

	clusterName := mcv.Namespace
	scope := mcv.Spec.Scope

	log.V(2).Info("Processing MCV", "cluster", clusterName,
		"apiGroup", scope.Group, "kind", scope.Kind, "name", scope.Name, "namespace", scope.Namespace)

	// Get managed cluster client
	dc, err := r.Registry.GetDynamicClient(clusterName)
	if err != nil {
		return r.updateMCVStatusIfChanged(ctx, log, mcvUnst,
			fmt.Errorf("getting client for cluster %s: %w", clusterName, err), nil)
	}

	// Build GVR from scope — use Resource field if set, otherwise derive from Kind
	resource := scope.Resource
	if resource == "" {
		resource = pluralizeKind(scope.Kind)
	}

	gvr := schema.GroupVersionResource{
		Group:    scope.Group,
		Version:  scope.Version,
		Resource: resource,
	}

	log.V(2).Info("Fetching resource", "gvr", gvr.String(), "name", scope.Name, "cluster", clusterName)

	// Read the resource from the managed cluster
	var result *unstructured.Unstructured
	if scope.Namespace != "" {
		result, err = dc.Resource(gvr).Namespace(scope.Namespace).Get(
			ctx, scope.Name, metav1.GetOptions{})
	} else {
		result, err = dc.Resource(gvr).Get(ctx, scope.Name, metav1.GetOptions{})
	}

	if err != nil {
		return r.updateMCVStatusIfChanged(ctx, log, mcvUnst, err, nil)
	}

	// Success — update MCV status with the resource data (only if changed)
	return r.updateMCVStatusIfChanged(ctx, log, mcvUnst, nil, result)
}

// updateMCVStatusIfChanged compares the fetched result with the existing MCV status
// and only writes an update when the condition or result data actually changed.
func (r *ManagedClusterViewReconciler) updateMCVStatusIfChanged(
	ctx context.Context, log logr.Logger, mcv *unstructured.Unstructured,
	fetchErr error, result *unstructured.Unstructured,
) (ctrl.Result, error) {
	requeue := ctrl.Result{RequeueAfter: r.requeueInterval()}

	if fetchErr != nil {
		return r.handleFetchError(ctx, log, mcv, fetchErr, requeue)
	}

	return r.handleFetchSuccess(ctx, log, mcv, result, requeue)
}

func (r *ManagedClusterViewReconciler) handleFetchError(
	ctx context.Context, log logr.Logger, mcv *unstructured.Unstructured,
	fetchErr error, requeue ctrl.Result,
) (ctrl.Result, error) {
	reason := ReasonGetResourceFailed
	message := fetchErr.Error()

	// Ramen parses for "not found" in the message string
	if k8serrors.IsNotFound(fetchErr) {
		message = fmt.Sprintf("err: resource %s not found", message)
	}

	// Check if condition already reflects this error state
	existingConditions, _, _ := unstructured.NestedSlice(mcv.Object, "status", "conditions")
	if len(existingConditions) > 0 {
		if ec, ok := existingConditions[0].(map[string]interface{}); ok {
			if ec["status"] == string(metav1.ConditionFalse) && ec["reason"] == reason {
				// Already in error state, skip update
				return requeue, nil
			}
		}
	}

	now := metav1.Now().Format(time.RFC3339)
	conditions := []interface{}{
		map[string]interface{}{
			"type":               ConditionViewProcessing,
			"status":             string(metav1.ConditionFalse),
			"lastTransitionTime": now,
			"reason":             reason,
			"message":            message,
		},
	}

	if err := unstructured.SetNestedSlice(mcv.Object, conditions, "status", "conditions"); err != nil {
		return ctrl.Result{}, fmt.Errorf("setting MCV conditions: %w", err)
	}

	// Clear stale result data to prevent Ramen from reading outdated resource state
	unstructured.RemoveNestedField(mcv.Object, "status", "result")

	if err := r.Status().Update(ctx, mcv); err != nil {
		return ctrl.Result{}, fmt.Errorf("updating MCV status: %w", err)
	}

	return requeue, nil
}

func (r *ManagedClusterViewReconciler) handleFetchSuccess(
	ctx context.Context, log logr.Logger, mcv *unstructured.Unstructured,
	result *unstructured.Unstructured, requeue ctrl.Result,
) (ctrl.Result, error) {
	resultJSON, err := json.Marshal(result.Object)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("marshaling result: %w", err)
	}

	var rawResult map[string]interface{}
	if err := json.Unmarshal(resultJSON, &rawResult); err != nil {
		return ctrl.Result{}, fmt.Errorf("unmarshaling result for status: %w", err)
	}

	// Compare with existing result — skip update if unchanged.
	// Strip volatile metadata (resourceVersion, managedFields, etc.) before
	// comparison so that server-side bookkeeping doesn't cause false diffs.
	existingResult, _, _ := unstructured.NestedMap(mcv.Object, "status", "result")
	existingConditions, _, _ := unstructured.NestedSlice(mcv.Object, "status", "conditions")

	alreadySuccess := false
	if len(existingConditions) > 0 {
		if ec, ok := existingConditions[0].(map[string]interface{}); ok {
			alreadySuccess = ec["status"] == string(metav1.ConditionTrue) &&
				ec["reason"] == ReasonGetResource
		}
	}

	if alreadySuccess && resultUnchanged(existingResult, rawResult) {
		// Nothing changed — skip the status write
		return requeue, nil
	}

	log.V(2).Info("MCV result changed, updating status", "mcv", mcv.GetName())

	now := metav1.Now().Format(time.RFC3339)
	conditions := []interface{}{
		map[string]interface{}{
			"type":               ConditionViewProcessing,
			"status":             string(metav1.ConditionTrue),
			"lastTransitionTime": now,
			"reason":             ReasonGetResource,
			"message":            "Resource retrieved successfully",
		},
	}

	if err := unstructured.SetNestedSlice(mcv.Object, conditions, "status", "conditions"); err != nil {
		return ctrl.Result{}, fmt.Errorf("setting MCV conditions: %w", err)
	}

	if err := unstructured.SetNestedField(mcv.Object, rawResult, "status", "result"); err != nil {
		return ctrl.Result{}, fmt.Errorf("setting MCV result: %w", err)
	}

	if err := r.Status().Update(ctx, mcv); err != nil {
		return ctrl.Result{}, fmt.Errorf("updating MCV status: %w", err)
	}

	return requeue, nil
}

func (r *ManagedClusterViewReconciler) SetupWithManager(mgr ctrl.Manager) error {
	// Watch ManagedClusterView using unstructured since we defined types locally
	mcv := &unstructured.Unstructured{}
	mcv.SetGroupVersionKind(ManagedClusterViewGVK)

	return ctrl.NewControllerManagedBy(mgr).
		For(mcv).
		Complete(r)
}

// pluralizeKind converts a Kind to its plural resource name.
// This is used instead of the hub's REST mapper because CRDs may only
// exist on managed clusters, not on the hub.
func pluralizeKind(kind string) string {
	// Explicit mappings for kinds that don't follow simple lowering + "s"
	known := map[string]string{
		// Kubernetes built-ins
		"Namespace":                "namespaces",
		"Ingress":                  "ingresses",
		"NetworkPolicy":            "networkpolicies",
		"StorageClass":             "storageclasses",
		"RuntimeClass":             "runtimeclasses",
		"IngressClass":             "ingressclasses",
		"PriorityClass":            "priorityclasses",
		// Kubernetes resources commonly in ManifestWorks
		"ClusterRole":              "clusterroles",
		"ClusterRoleBinding":       "clusterrolebindings",
		"Role":                     "roles",
		"RoleBinding":              "rolebindings",
		"ServiceAccount":           "serviceaccounts",
		"ConfigMap":                "configmaps",
		"Secret":                   "secrets",
		"Service":                  "services",
		"Deployment":               "deployments",
		"DaemonSet":                "daemonsets",
		"StatefulSet":              "statefulsets",
		"PersistentVolumeClaim":    "persistentvolumeclaims",
		"PersistentVolume":         "persistentvolumes",
		"CustomResourceDefinition": "customresourcedefinitions",
		// CSI / storage
		"VolumeSnapshotClass":         "volumesnapshotclasses",
		"VolumeReplicationClass":      "volumereplicationclasses",
		"VolumeGroupSnapshotClass":    "volumegroupsnapshotclasses",
		"VolumeGroupReplicationClass": "volumegroupreplicationclasses",
		// Ramen types
		"VolumeReplicationGroup": "volumereplicationgroups",
		"DRClusterConfig":        "drclusterconfigs",
		"NetworkFence":           "networkfences",
		"MaintenanceMode":        "maintenancemodes",
	}

	if plural, ok := known[kind]; ok {
		return plural
	}

	// Default: lowercase the entire kind and add 's'
	return strings.ToLower(kind) + "s"
}

// resultUnchanged compares two unstructured result maps after stripping
// volatile metadata fields that change on every reconcile (resourceVersion,
// managedFields, generation, etc.). This prevents false diffs caused by
// server-side bookkeeping on the managed cluster.
func resultUnchanged(existing, fetched map[string]interface{}) bool {
	if existing == nil || fetched == nil {
		return existing == nil && fetched == nil
	}

	a := stripVolatileMetadata(existing)
	b := stripVolatileMetadata(fetched)

	return reflect.DeepEqual(a, b)
}

// stripVolatileMetadata returns a deep-ish copy of the object map with
// frequently-changing fields removed so that comparisons reflect meaningful
// changes only.
func stripVolatileMetadata(obj map[string]interface{}) map[string]interface{} {
	out := make(map[string]interface{}, len(obj))
	for k, v := range obj {
		out[k] = v
	}

	// Strip volatile metadata fields
	if md, ok := out["metadata"].(map[string]interface{}); ok {
		cleaned := make(map[string]interface{}, len(md))
		for k, v := range md {
			cleaned[k] = v
		}
		delete(cleaned, "resourceVersion")
		delete(cleaned, "managedFields")
		delete(cleaned, "generation")
		out["metadata"] = cleaned
	}

	// Strip timestamps from status.conditions — condition type/status/reason
	// changes are meaningful, but lastTransitionTime changes on every reconcile.
	if status, ok := out["status"].(map[string]interface{}); ok {
		cleanedStatus := make(map[string]interface{}, len(status))
		for k, v := range status {
			cleanedStatus[k] = v
		}
		if conditions, ok := cleanedStatus["conditions"].([]interface{}); ok {
			cleanedConds := make([]interface{}, len(conditions))
			for i, c := range conditions {
				if cm, ok := c.(map[string]interface{}); ok {
					cc := make(map[string]interface{}, len(cm))
					for k, v := range cm {
						cc[k] = v
					}
					delete(cc, "lastTransitionTime")
					delete(cc, "lastHeartbeatTime")
					cleanedConds[i] = cc
				} else {
					cleanedConds[i] = c
				}
			}
			cleanedStatus["conditions"] = cleanedConds
		}
		out["status"] = cleanedStatus
	}

	return out
}

// Ensure interfaces are satisfied
var _ dynamic.Interface = nil
var _ types.NamespacedName = types.NamespacedName{}
