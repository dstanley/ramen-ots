// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package controller

import "k8s.io/apimachinery/pkg/runtime/schema"

const (
	// fleetManagedAnnotation is the annotation key that must be set to "true"
	// on a PlacementDecision for the Fleet controller to process it.
	fleetManagedAnnotation = "ramen.dr/fleet-managed"

	// defaultFleetLabelKey is the default label key applied to Fleet Cluster
	// resources to indicate the active DR target.
	defaultFleetLabelKey = "ramen.dr/fleet-enabled"

	// defaultFleetNamespace is the default namespace where Fleet Cluster
	// resources are created by Rancher.
	defaultFleetNamespace = "fleet-default"

	// fleetClusterDisplayNameLabel is the Rancher-managed label on Fleet
	// Cluster resources that maps to the human-readable cluster name
	// (matching the OCM ManagedCluster name).
	fleetClusterDisplayNameLabel = "management.cattle.io/cluster-display-name"

	// retainedForFailoverReason is the reason string set on PlacementDecision
	// entries that are kept during failover but are not the active target.
	retainedForFailoverReason = "RetainedForFailover"
)

// PlacementDecisionGVK is the GroupVersionKind for OCM PlacementDecision.
var PlacementDecisionGVK = schema.GroupVersionKind{
	Group:   "cluster.open-cluster-management.io",
	Version: "v1beta1",
	Kind:    "PlacementDecision",
}

// FleetClusterGVK is the GroupVersionKind for Fleet Cluster.
var FleetClusterGVK = schema.GroupVersionKind{
	Group:   "fleet.cattle.io",
	Version: "v1alpha1",
	Kind:    "Cluster",
}

// FleetClusterListGVK is the list form for Fleet Cluster (used with r.List()).
var FleetClusterListGVK = schema.GroupVersionKind{
	Group:   "fleet.cattle.io",
	Version: "v1alpha1",
	Kind:    "ClusterList",
}
