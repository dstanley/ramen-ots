// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package controller

import (
	"context"
	"fmt"

	"github.com/go-logr/logr"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

// FleetPlacementReconciler watches PlacementDecision resources annotated with
// ramen.dr/fleet-managed=true and syncs labels on Fleet Cluster resources to
// control where Fleet deploys applications during DR operations.
type FleetPlacementReconciler struct {
	client.Client
	Log            logr.Logger
	FleetLabelKey  string // Label key on Fleet Cluster (default: ramen.dr/fleet-enabled)
	FleetNamespace string // Namespace for Fleet Cluster resources (default: fleet-default)
}

func (r *FleetPlacementReconciler) fleetLabelKey() string {
	if r.FleetLabelKey != "" {
		return r.FleetLabelKey
	}
	return defaultFleetLabelKey
}

func (r *FleetPlacementReconciler) fleetNamespace() string {
	if r.FleetNamespace != "" {
		return r.FleetNamespace
	}
	return defaultFleetNamespace
}

func (r *FleetPlacementReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("placementdecision", req.NamespacedName)

	// Fetch the PlacementDecision
	pd := &unstructured.Unstructured{}
	pd.SetGroupVersionKind(PlacementDecisionGVK)
	if err := r.Get(ctx, req.NamespacedName, pd); err != nil {
		if k8serrors.IsNotFound(err) {
			log.Info("PlacementDecision deleted, removing Fleet labels")
			return ctrl.Result{}, r.removeAllFleetLabels(ctx, log)
		}
		return ctrl.Result{}, err
	}

	// Verify opt-in annotation
	annotations := pd.GetAnnotations()
	if annotations == nil || annotations[fleetManagedAnnotation] != "true" {
		return ctrl.Result{}, nil
	}

	// Extract active target cluster from status.decisions[]
	targetCluster, err := getActiveDecision(pd)
	if err != nil {
		log.Error(err, "Failed to extract decisions")
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	// Determine which cluster currently has the Fleet label
	currentCluster, err := r.getCurrentLabeledCluster(ctx)
	if err != nil {
		log.Error(err, "Failed to determine current Fleet target")
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	if targetCluster == "" {
		// Empty decisions — relocate quiesce phase
		if currentCluster != "" {
			log.Info(fmt.Sprintf("Quiescing workload: removing app from %s (placement cleared for relocate)", currentCluster))
		}
		if err := r.removeAllFleetLabels(ctx, log); err != nil {
			return ctrl.Result{}, err
		}
		log.Info("Quiesce complete: all Fleet labels removed, workload stopped for final sync")
		return ctrl.Result{}, nil
	}

	// Target hasn't changed — no-op
	if targetCluster == currentCluster {
		return ctrl.Result{}, nil
	}

	// Log the transition
	if currentCluster == "" {
		log.Info(fmt.Sprintf("Deploying app to %s", targetCluster))
	} else {
		log.Info(fmt.Sprintf("Moving app: %s -> %s", currentCluster, targetCluster))
	}

	if err := r.syncFleetLabels(ctx, log, targetCluster); err != nil {
		log.Error(err, "Failed to sync Fleet labels", "target", targetCluster)
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	log.Info(fmt.Sprintf("Fleet target updated: app now targeting %s", targetCluster))

	return ctrl.Result{}, nil
}

// getActiveDecision reads status.decisions[] from the PlacementDecision and
// returns the clusterName of the first decision that is not RetainedForFailover.
// Returns empty string if there are no active decisions.
func getActiveDecision(pd *unstructured.Unstructured) (string, error) {
	decisions, found, err := unstructured.NestedSlice(pd.Object, "status", "decisions")
	if err != nil {
		return "", fmt.Errorf("reading status.decisions: %w", err)
	}
	if !found || len(decisions) == 0 {
		return "", nil
	}

	var firstCluster string
	for _, d := range decisions {
		dm, ok := d.(map[string]interface{})
		if !ok {
			continue
		}
		clusterName, _, _ := unstructured.NestedString(dm, "clusterName")
		if clusterName == "" {
			continue
		}
		if firstCluster == "" {
			firstCluster = clusterName
		}
		reason, _, _ := unstructured.NestedString(dm, "reason")
		if reason != retainedForFailoverReason {
			return clusterName, nil
		}
	}

	// All retained — fall back to first (shouldn't happen in practice)
	return firstCluster, nil
}

// getCurrentLabeledCluster returns the display name of the Fleet Cluster that
// currently has the DR label, or empty string if none.
func (r *FleetPlacementReconciler) getCurrentLabeledCluster(ctx context.Context) (string, error) {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(FleetClusterListGVK)
	if err := r.List(ctx, list,
		client.InNamespace(r.fleetNamespace()),
		client.MatchingLabels{r.fleetLabelKey(): "true"},
	); err != nil {
		return "", fmt.Errorf("listing labeled Fleet clusters: %w", err)
	}

	if len(list.Items) == 0 {
		return "", nil
	}

	labels := list.Items[0].GetLabels()
	return labels[fleetClusterDisplayNameLabel], nil
}

// resolveFleetClusterName finds the Fleet Cluster resource whose
// management.cattle.io/cluster-display-name label matches the given OCM
// cluster name, and returns its metadata.name (the Fleet auto-generated ID).
func (r *FleetPlacementReconciler) resolveFleetClusterName(
	ctx context.Context, displayName string,
) (string, error) {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(FleetClusterListGVK)

	if err := r.List(ctx, list,
		client.InNamespace(r.fleetNamespace()),
		client.MatchingLabels{fleetClusterDisplayNameLabel: displayName},
	); err != nil {
		return "", fmt.Errorf("listing Fleet clusters with display-name=%s: %w", displayName, err)
	}

	if len(list.Items) == 0 {
		return "", fmt.Errorf("no Fleet Cluster found with display-name=%s", displayName)
	}

	return list.Items[0].GetName(), nil
}

// syncFleetLabels ensures exactly one Fleet Cluster (the target) has the
// Fleet label set to "true", and removes it from all others.
func (r *FleetPlacementReconciler) syncFleetLabels(
	ctx context.Context, log logr.Logger, targetCluster string,
) error {
	targetFleetName, err := r.resolveFleetClusterName(ctx, targetCluster)
	if err != nil {
		return err
	}

	allClusters := &unstructured.UnstructuredList{}
	allClusters.SetGroupVersionKind(FleetClusterListGVK)
	if err := r.List(ctx, allClusters, client.InNamespace(r.fleetNamespace())); err != nil {
		return fmt.Errorf("listing Fleet clusters: %w", err)
	}

	labelKey := r.fleetLabelKey()

	for i := range allClusters.Items {
		cluster := &allClusters.Items[i]
		labels := cluster.GetLabels()
		if labels == nil {
			labels = map[string]string{}
		}

		currentVal := labels[labelKey]
		isTarget := cluster.GetName() == targetFleetName

		if isTarget && currentVal == "true" {
			continue // already labeled
		}
		if !isTarget && currentVal == "" {
			continue // already unlabeled
		}

		if isTarget {
			labels[labelKey] = "true"
		} else {
			delete(labels, labelKey)
		}

		cluster.SetLabels(labels)
		if err := r.Update(ctx, cluster); err != nil {
			return fmt.Errorf("updating Fleet cluster %s labels: %w", cluster.GetName(), err)
		}
	}

	return nil
}

// removeAllFleetLabels removes the Fleet label from all Fleet Cluster resources.
func (r *FleetPlacementReconciler) removeAllFleetLabels(ctx context.Context, log logr.Logger) error {
	list := &unstructured.UnstructuredList{}
	list.SetGroupVersionKind(FleetClusterListGVK)
	if err := r.List(ctx, list,
		client.InNamespace(r.fleetNamespace()),
		client.MatchingLabels{r.fleetLabelKey(): "true"},
	); err != nil {
		return fmt.Errorf("listing labeled Fleet clusters: %w", err)
	}

	for i := range list.Items {
		cluster := &list.Items[i]
		labels := cluster.GetLabels()

		delete(labels, r.fleetLabelKey())
		cluster.SetLabels(labels)

		if err := r.Update(ctx, cluster); err != nil {
			return fmt.Errorf("removing label from Fleet cluster %s: %w", cluster.GetName(), err)
		}
	}

	return nil
}

func (r *FleetPlacementReconciler) SetupWithManager(mgr ctrl.Manager) error {
	pd := &unstructured.Unstructured{}
	pd.SetGroupVersionKind(PlacementDecisionGVK)

	return ctrl.NewControllerManagedBy(mgr).
		For(pd).
		WithEventFilter(fleetManagedPredicate()).
		Complete(r)
}

// fleetManagedPredicate filters events to only process PlacementDecisions
// that have the ramen.dr/fleet-managed=true annotation.
func fleetManagedPredicate() predicate.Predicate {
	isFleetManaged := func(obj client.Object) bool {
		annotations := obj.GetAnnotations()
		return annotations != nil && annotations[fleetManagedAnnotation] == "true"
	}

	return predicate.Funcs{
		CreateFunc: func(e event.CreateEvent) bool {
			return isFleetManaged(e.Object)
		},
		UpdateFunc: func(e event.UpdateEvent) bool {
			return isFleetManaged(e.ObjectOld) || isFleetManaged(e.ObjectNew)
		},
		DeleteFunc: func(e event.DeleteEvent) bool {
			return isFleetManaged(e.Object)
		},
		GenericFunc: func(e event.GenericEvent) bool {
			return isFleetManaged(e.Object)
		},
	}
}
