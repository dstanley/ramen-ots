// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package controller

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/go-logr/logr"
	"github.com/ramendr/ramen-ots/internal/cluster"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/dynamic"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	defaultRequeueInterval = 10 * time.Second
)

// ManagedClusterViewReconciler fulfills ManagedClusterView CRs by reading
// the specified resource from managed clusters via direct kubeconfig access.
type ManagedClusterViewReconciler struct {
	client.Client
	Log      logr.Logger
	Registry *cluster.Registry
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

	log.V(1).Info("Processing MCV", "cluster", clusterName,
		"apiGroup", scope.Group, "kind", scope.Kind, "name", scope.Name, "namespace", scope.Namespace)

	// Get managed cluster client
	dc, err := r.Registry.GetDynamicClient(clusterName)
	if err != nil {
		return r.updateMCVStatus(ctx, mcvUnst,
			fmt.Errorf("getting client for cluster %s: %w", clusterName, err))
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

	log.V(1).Info("Fetching resource", "gvr", gvr.String(), "name", scope.Name, "cluster", clusterName)

	// Read the resource from the managed cluster
	var result *unstructured.Unstructured
	if scope.Namespace != "" {
		result, err = dc.Resource(gvr).Namespace(scope.Namespace).Get(
			ctx, scope.Name, metav1.GetOptions{})
	} else {
		result, err = dc.Resource(gvr).Get(ctx, scope.Name, metav1.GetOptions{})
	}

	if err != nil {
		return r.updateMCVStatus(ctx, mcvUnst, err)
	}

	// Success — update MCV status with the resource data
	return r.updateMCVStatusSuccess(ctx, mcvUnst, result)
}

func (r *ManagedClusterViewReconciler) updateMCVStatus(
	ctx context.Context, mcv *unstructured.Unstructured, fetchErr error,
) (ctrl.Result, error) {
	now := metav1.Now().Format(time.RFC3339)

	reason := ReasonGetResourceFailed
	message := fetchErr.Error()

	// Ramen parses for "not found" in the message string
	if k8serrors.IsNotFound(fetchErr) {
		message = fmt.Sprintf("err: resource %s not found", message)
	}

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

	return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
}

func (r *ManagedClusterViewReconciler) updateMCVStatusSuccess(
	ctx context.Context, mcv *unstructured.Unstructured, result *unstructured.Unstructured,
) (ctrl.Result, error) {
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

	// Set the result with the raw resource data
	resultJSON, err := json.Marshal(result.Object)
	if err != nil {
		return ctrl.Result{}, fmt.Errorf("marshaling result: %w", err)
	}

	resultMap := map[string]interface{}{
		"raw": runtime.RawExtension{Raw: resultJSON},
	}

	// For the MCV status.result, we need to set the raw JSON directly
	// The OCM MCV status.result is a RawExtension at the top level
	var rawResult map[string]interface{}
	if err := json.Unmarshal(resultJSON, &rawResult); err != nil {
		return ctrl.Result{}, fmt.Errorf("unmarshaling result for status: %w", err)
	}

	_ = resultMap // not used directly; we set the result as the raw object
	if err := unstructured.SetNestedField(mcv.Object, rawResult, "status", "result"); err != nil {
		return ctrl.Result{}, fmt.Errorf("setting MCV result: %w", err)
	}

	if err := r.Status().Update(ctx, mcv); err != nil {
		return ctrl.Result{}, fmt.Errorf("updating MCV status: %w", err)
	}

	return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
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
		"Namespace":                  "namespaces",
		"Ingress":                    "ingresses",
		"NetworkPolicy":              "networkpolicies",
		"StorageClass":               "storageclasses",
		"RuntimeClass":               "runtimeclasses",
		"IngressClass":               "ingressclasses",
		"PriorityClass":              "priorityclasses",
		// Kubernetes resources commonly in ManifestWorks
		"ClusterRole":                "clusterroles",
		"ClusterRoleBinding":         "clusterrolebindings",
		"Role":                       "roles",
		"RoleBinding":                "rolebindings",
		"ServiceAccount":             "serviceaccounts",
		"ConfigMap":                  "configmaps",
		"Secret":                     "secrets",
		"Service":                    "services",
		"Deployment":                 "deployments",
		"DaemonSet":                  "daemonsets",
		"StatefulSet":                "statefulsets",
		"PersistentVolumeClaim":      "persistentvolumeclaims",
		"PersistentVolume":           "persistentvolumes",
		"CustomResourceDefinition":   "customresourcedefinitions",
		// CSI / storage
		"VolumeSnapshotClass":           "volumesnapshotclasses",
		"VolumeReplicationClass":        "volumereplicationclasses",
		"VolumeGroupSnapshotClass":      "volumegroupsnapshotclasses",
		"VolumeGroupReplicationClass":   "volumegroupreplicationclasses",
		// Ramen types
		"VolumeReplicationGroup":     "volumereplicationgroups",
		"DRClusterConfig":            "drclusterconfigs",
		"NetworkFence":               "networkfences",
		"MaintenanceMode":            "maintenancemodes",
	}

	if plural, ok := known[kind]; ok {
		return plural
	}

	// Default: lowercase the entire kind and add 's'
	return strings.ToLower(kind) + "s"
}

// Ensure interfaces are satisfied
var _ dynamic.Interface = nil
var _ types.NamespacedName = types.NamespacedName{}
