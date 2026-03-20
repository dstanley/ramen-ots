// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package controller

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ocmworkv1 "open-cluster-management.io/api/work/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrlutil "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
)

const (
	secretPropagatorFinalizer = "ramen-ots.ramendr.openshift.io/secret-propagator-cleanup"

	// Ramen labels used on hub secrets
	createdByRamenLabel = "ramendr.openshift.io/created-by-ramen"

	// Hub secret suffix — Ramen creates secrets named "{drpc}-vs-secret-hub"
	hubSecretSuffix = "-vs-secret-hub"

	// Managed cluster secret suffix — VolSync expects "{drpc}-vs-secret"
	clusterSecretSuffix = "-vs-secret"

	// ManifestWork name prefix for propagated secrets
	secretMWPrefix = "vs-secret-"
)

// SecretPropagatorReconciler watches for VolSync hub secrets created by Ramen
// and propagates them to managed clusters via ManifestWork.
//
// This replaces the OCM governance-policy-propagator for VolSync secret
// propagation. When Ramen creates a PSK secret on the hub (named
// "{drpc}-vs-secret-hub"), this controller reads the DRPolicy to find
// the target clusters and creates a ManifestWork in each cluster's
// namespace containing the secret (renamed to "{drpc}-vs-secret").
type SecretPropagatorReconciler struct {
	client.Client
	Log logr.Logger
}

func (r *SecretPropagatorReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("secret", req.NamespacedName)

	secret := &corev1.Secret{}
	if err := r.Get(ctx, req.NamespacedName, secret); err != nil {
		if k8serrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Verify this is a Ramen VolSync hub secret
	if !isVolSyncHubSecret(secret) {
		return ctrl.Result{}, nil
	}

	log.Info("Processing VolSync hub secret")

	// Handle deletion — clean up ManifestWorks
	if !secret.DeletionTimestamp.IsZero() {
		if ctrlutil.ContainsFinalizer(secret, secretPropagatorFinalizer) {
			if err := r.deleteSecretManifestWorks(ctx, log, secret); err != nil {
				log.Error(err, "Failed to delete secret ManifestWorks")
				// Continue to remove finalizer — best effort cleanup
			}
			ctrlutil.RemoveFinalizer(secret, secretPropagatorFinalizer)
			if err := r.Update(ctx, secret); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// Add finalizer
	if !ctrlutil.ContainsFinalizer(secret, secretPropagatorFinalizer) {
		ctrlutil.AddFinalizer(secret, secretPropagatorFinalizer)
		if err := r.Update(ctx, secret); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Get target clusters from DRPolicy
	clusters, err := r.getDRPolicyClusters(ctx, log)
	if err != nil {
		log.Error(err, "Failed to get DR clusters")
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	if len(clusters) == 0 {
		log.Info("No DR clusters found, skipping secret propagation")
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	// Derive the managed cluster secret name from the hub secret name
	// "{drpc}-vs-secret-hub" → "{drpc}-vs-secret"
	clusterSecretName := strings.TrimSuffix(secret.Name, hubSecretSuffix) + clusterSecretSuffix
	targetNamespace := secret.Namespace

	// Create ManifestWork in each cluster namespace
	for _, clusterName := range clusters {
		if err := r.ensureSecretManifestWork(ctx, log, secret, clusterName, clusterSecretName, targetNamespace); err != nil {
			log.Error(err, "Failed to create secret ManifestWork", "cluster", clusterName)
			return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
		}
	}

	log.Info("Secret propagated to all clusters", "clusters", clusters, "secretName", clusterSecretName)
	return ctrl.Result{}, nil
}

// ensureSecretManifestWork creates or updates a ManifestWork that deploys the
// VolSync PSK secret to a managed cluster.
func (r *SecretPropagatorReconciler) ensureSecretManifestWork(
	ctx context.Context, log logr.Logger,
	hubSecret *corev1.Secret, clusterName, secretName, namespace string,
) error {
	mwName := secretMWPrefix + secretName

	// Build the secret to deploy on the managed cluster
	clusterSecret := &corev1.Secret{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "v1",
			Kind:       "Secret",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: namespace,
			Labels: map[string]string{
				createdByRamenLabel: "true",
			},
		},
		Data: hubSecret.Data,
		Type: corev1.SecretTypeOpaque,
	}

	secretJSON, err := json.Marshal(clusterSecret)
	if err != nil {
		return fmt.Errorf("marshaling secret: %w", err)
	}

	manifest := ocmworkv1.Manifest{
		RawExtension: runtime.RawExtension{Raw: secretJSON},
	}

	// Check if ManifestWork already exists
	existing := &ocmworkv1.ManifestWork{}
	err = r.Get(ctx, types.NamespacedName{Name: mwName, Namespace: clusterName}, existing)

	if err != nil {
		if !k8serrors.IsNotFound(err) {
			return fmt.Errorf("checking existing ManifestWork: %w", err)
		}

		// Create new ManifestWork
		mw := &ocmworkv1.ManifestWork{
			ObjectMeta: metav1.ObjectMeta{
				Name:      mwName,
				Namespace: clusterName,
				Labels: map[string]string{
					createdByRamenLabel:      "true",
					"ramen-ots.io/secret-mw": "true",
				},
			},
			Spec: ocmworkv1.ManifestWorkSpec{
				Workload: ocmworkv1.ManifestsTemplate{
					Manifests: []ocmworkv1.Manifest{manifest},
				},
			},
		}

		if err := r.Create(ctx, mw); err != nil {
			return fmt.Errorf("creating ManifestWork: %w", err)
		}

		log.Info("Created secret ManifestWork", "cluster", clusterName, "manifestwork", mwName)
		return nil
	}

	// Update existing ManifestWork if secret data changed
	existing.Spec.Workload.Manifests = []ocmworkv1.Manifest{manifest}

	if err := r.Update(ctx, existing); err != nil {
		return fmt.Errorf("updating ManifestWork: %w", err)
	}

	log.V(1).Info("Updated secret ManifestWork", "cluster", clusterName, "manifestwork", mwName)
	return nil
}

// deleteSecretManifestWorks removes the ManifestWorks created for this hub secret.
func (r *SecretPropagatorReconciler) deleteSecretManifestWorks(
	ctx context.Context, log logr.Logger, hubSecret *corev1.Secret,
) error {
	clusterSecretName := strings.TrimSuffix(hubSecret.Name, hubSecretSuffix) + clusterSecretSuffix
	mwName := secretMWPrefix + clusterSecretName

	// Get all clusters from DRPolicy
	clusters, err := r.getDRPolicyClusters(ctx, log)
	if err != nil {
		// If we can't get clusters, try to find MWs by label
		log.Info("Cannot get DR clusters, searching for ManifestWorks by label")
		return r.deleteSecretManifestWorksByLabel(ctx, log)
	}

	for _, clusterName := range clusters {
		mw := &ocmworkv1.ManifestWork{}
		err := r.Get(ctx, types.NamespacedName{Name: mwName, Namespace: clusterName}, mw)
		if err != nil {
			if k8serrors.IsNotFound(err) {
				continue
			}
			log.Error(err, "Failed to get ManifestWork for deletion", "cluster", clusterName)
			continue
		}

		if err := r.Delete(ctx, mw); err != nil && !k8serrors.IsNotFound(err) {
			log.Error(err, "Failed to delete ManifestWork", "cluster", clusterName)
		} else {
			log.Info("Deleted secret ManifestWork", "cluster", clusterName, "manifestwork", mwName)
		}
	}

	return nil
}

// deleteSecretManifestWorksByLabel finds and deletes all secret ManifestWorks by label.
func (r *SecretPropagatorReconciler) deleteSecretManifestWorksByLabel(
	ctx context.Context, log logr.Logger,
) error {
	mwList := &ocmworkv1.ManifestWorkList{}
	if err := r.List(ctx, mwList, client.MatchingLabels{"ramen-ots.io/secret-mw": "true"}); err != nil {
		return fmt.Errorf("listing secret ManifestWorks: %w", err)
	}

	for i := range mwList.Items {
		if err := r.Delete(ctx, &mwList.Items[i]); err != nil && !k8serrors.IsNotFound(err) {
			log.Error(err, "Failed to delete ManifestWork",
				"name", mwList.Items[i].Name, "namespace", mwList.Items[i].Namespace)
		}
	}

	return nil
}

// getDRPolicyClusters reads all DRPolicy resources and returns the unique set
// of cluster names. Uses unstructured access to avoid importing Ramen API types.
func (r *SecretPropagatorReconciler) getDRPolicyClusters(ctx context.Context, log logr.Logger) ([]string, error) {
	return getDRPolicyClusters(ctx, r.Client, log)
}

// isVolSyncHubSecret returns true if the secret matches the Ramen VolSync hub
// secret pattern: has the created-by-ramen label and name ends with "-vs-secret-hub".
func isVolSyncHubSecret(secret *corev1.Secret) bool {
	if secret.Labels == nil {
		return false
	}
	if secret.Labels[createdByRamenLabel] != "true" {
		return false
	}
	return strings.HasSuffix(secret.Name, hubSecretSuffix)
}

func (r *SecretPropagatorReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Secret{}).
		WithEventFilter(volSyncSecretPredicate()).
		Complete(r)
}

// volSyncSecretPredicate filters events to only process secrets that match
// the VolSync hub secret pattern.
func volSyncSecretPredicate() predicate.Predicate {
	isMatch := func(obj client.Object) bool {
		labels := obj.GetLabels()
		if labels == nil {
			return false
		}
		if labels[createdByRamenLabel] != "true" {
			return false
		}
		return strings.HasSuffix(obj.GetName(), hubSecretSuffix)
	}

	return predicate.Funcs{
		CreateFunc: func(e event.CreateEvent) bool {
			return isMatch(e.Object)
		},
		UpdateFunc: func(e event.UpdateEvent) bool {
			return isMatch(e.ObjectNew)
		},
		DeleteFunc: func(e event.DeleteEvent) bool {
			return isMatch(e.Object)
		},
		GenericFunc: func(e event.GenericEvent) bool {
			return isMatch(e.Object)
		},
	}
}
