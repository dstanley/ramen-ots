// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package controller

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/go-logr/logr"
	"github.com/ramendr/ramen-ots/internal/cluster"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	ocmworkv1 "open-cluster-management.io/api/work/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrlutil "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

const (
	manifestWorkFinalizer       = "ramen-ots.ramendr.openshift.io/manifestwork-cleanup"
	ocmManifestWorkFinalizer    = "cluster.open-cluster-management.io/manifest-work-cleanup"
	legacyManifestWorkFinalizer = "rancher-ots.ramendr.openshift.io/manifestwork-cleanup"
	fieldManager                = "ramen-ots"
)

// ManifestWorkReconciler fulfills ManifestWork CRs by applying their embedded
// resources to managed clusters via direct kubeconfig access.
type ManifestWorkReconciler struct {
	client.Client
	Log      logr.Logger
	Registry *cluster.Registry
}

func (r *ManifestWorkReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("manifestwork", req.NamespacedName)

	mw := &ocmworkv1.ManifestWork{}
	if err := r.Get(ctx, req.NamespacedName, mw); err != nil {
		if k8serrors.IsNotFound(err) {
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	clusterName := mw.Namespace

	// Handle deletion
	if !mw.DeletionTimestamp.IsZero() {
		needsUpdate := false
		if ctrlutil.ContainsFinalizer(mw, manifestWorkFinalizer) {
			if err := r.deleteManifests(ctx, log, clusterName, mw); err != nil {
				log.Error(err, "Failed to delete manifests from managed cluster")
				// Continue to remove finalizer — best effort cleanup
			}
			ctrlutil.RemoveFinalizer(mw, manifestWorkFinalizer)
			needsUpdate = true
		}
		// Also remove stale finalizers from OCM and legacy controller
		for _, f := range []string{ocmManifestWorkFinalizer, legacyManifestWorkFinalizer} {
			if ctrlutil.ContainsFinalizer(mw, f) {
				ctrlutil.RemoveFinalizer(mw, f)
				needsUpdate = true
			}
		}
		if needsUpdate {
			if err := r.Update(ctx, mw); err != nil {
				return ctrl.Result{}, err
			}
		}
		return ctrl.Result{}, nil
	}

	// Add our finalizer and remove any stale OCM finalizer
	needsFinalizerUpdate := false
	if !ctrlutil.ContainsFinalizer(mw, manifestWorkFinalizer) {
		ctrlutil.AddFinalizer(mw, manifestWorkFinalizer)
		needsFinalizerUpdate = true
	}
	for _, f := range []string{ocmManifestWorkFinalizer, legacyManifestWorkFinalizer} {
		if ctrlutil.ContainsFinalizer(mw, f) {
			ctrlutil.RemoveFinalizer(mw, f)
			needsFinalizerUpdate = true
		}
	}
	if needsFinalizerUpdate {
		if err := r.Update(ctx, mw); err != nil {
			return ctrl.Result{}, err
		}
	}

	// Apply manifests to managed cluster
	applyErr := r.applyManifests(ctx, log, clusterName, mw)

	// Update status conditions
	if err := r.updateStatus(ctx, mw, applyErr); err != nil {
		log.Error(err, "Failed to update ManifestWork status")
		return ctrl.Result{}, err
	}

	if applyErr != nil {
		log.Error(applyErr, "Failed to apply manifests, will retry")
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	return ctrl.Result{}, nil
}

func (r *ManifestWorkReconciler) applyManifests(
	ctx context.Context, log logr.Logger, clusterName string, mw *ocmworkv1.ManifestWork,
) error {
	dc, err := r.Registry.GetDynamicClient(clusterName)
	if err != nil {
		return fmt.Errorf("getting client for cluster %s: %w", clusterName, err)
	}

	for i, manifest := range mw.Spec.Workload.Manifests {
		obj := &unstructured.Unstructured{}
		if err := json.Unmarshal(manifest.Raw, obj); err != nil {
			return fmt.Errorf("unmarshaling manifest %d: %w", i, err)
		}

		gvk := obj.GroupVersionKind()
		gvr := gvrFromGVK(gvk)

		var resource = dc.Resource(gvr)

		objData, err := json.Marshal(obj)
		if err != nil {
			return fmt.Errorf("marshaling object for apply: %w", err)
		}

		ns := obj.GetNamespace()
		if ns != "" {
			_, err = resource.Namespace(ns).Patch(ctx, obj.GetName(),
				types.ApplyPatchType, objData,
				metav1.PatchOptions{FieldManager: fieldManager, Force: boolPtr(true)})
		} else {
			_, err = resource.Patch(ctx, obj.GetName(),
				types.ApplyPatchType, objData,
				metav1.PatchOptions{FieldManager: fieldManager, Force: boolPtr(true)})
		}

		if err != nil {
			return fmt.Errorf("applying %s %s/%s to cluster %s: %w",
				gvk.Kind, ns, obj.GetName(), clusterName, err)
		}

		log.V(1).Info("Applied resource", "kind", gvk.Kind, "name", obj.GetName(),
			"namespace", ns, "cluster", clusterName)
	}

	return nil
}

func (r *ManifestWorkReconciler) deleteManifests(
	ctx context.Context, log logr.Logger, clusterName string, mw *ocmworkv1.ManifestWork,
) error {
	// Check if delete option is Orphan
	if mw.Spec.DeleteOption != nil &&
		mw.Spec.DeleteOption.PropagationPolicy == ocmworkv1.DeletePropagationPolicyTypeOrphan {
		log.Info("DeleteOption is Orphan, skipping resource deletion", "cluster", clusterName)
		return nil
	}

	dc, err := r.Registry.GetDynamicClient(clusterName)
	if err != nil {
		return fmt.Errorf("getting client for cluster %s: %w", clusterName, err)
	}

	// Delete in reverse order
	for i := len(mw.Spec.Workload.Manifests) - 1; i >= 0; i-- {
		manifest := mw.Spec.Workload.Manifests[i]

		obj := &unstructured.Unstructured{}
		if err := json.Unmarshal(manifest.Raw, obj); err != nil {
			log.Error(err, "Failed to unmarshal manifest for deletion", "index", i)
			continue
		}

		gvk := obj.GroupVersionKind()
		gvr := gvrFromGVK(gvk)

		var resource = dc.Resource(gvr)

		ns := obj.GetNamespace()
		if ns != "" {
			err = resource.Namespace(ns).Delete(ctx, obj.GetName(), metav1.DeleteOptions{})
		} else {
			err = resource.Delete(ctx, obj.GetName(), metav1.DeleteOptions{})
		}

		if err != nil && !k8serrors.IsNotFound(err) {
			log.Error(err, "Failed to delete resource", "kind", gvk.Kind,
				"name", obj.GetName(), "cluster", clusterName)
		} else {
			log.V(1).Info("Deleted resource", "kind", gvk.Kind, "name", obj.GetName(),
				"cluster", clusterName)
		}
	}

	return nil
}

func (r *ManifestWorkReconciler) updateStatus(
	ctx context.Context, mw *ocmworkv1.ManifestWork, applyErr error,
) error {
	now := metav1.Now()

	if applyErr != nil {
		mw.Status.Conditions = []metav1.Condition{
			{
				Type:               ocmworkv1.WorkApplied,
				Status:             metav1.ConditionFalse,
				LastTransitionTime: now,
				Reason:             "ApplyFailed",
				Message:            applyErr.Error(),
			},
			{
				Type:               ocmworkv1.WorkAvailable,
				Status:             metav1.ConditionFalse,
				LastTransitionTime: now,
				Reason:             "ApplyFailed",
				Message:            applyErr.Error(),
			},
			{
				Type:               ocmworkv1.WorkDegraded,
				Status:             metav1.ConditionTrue,
				LastTransitionTime: now,
				Reason:             "ApplyFailed",
				Message:            applyErr.Error(),
			},
		}
	} else {
		mw.Status.Conditions = []metav1.Condition{
			{
				Type:               ocmworkv1.WorkApplied,
				Status:             metav1.ConditionTrue,
				LastTransitionTime: now,
				Reason:             "AppliedSuccessfully",
				Message:            "All manifests applied successfully",
			},
			{
				Type:               ocmworkv1.WorkAvailable,
				Status:             metav1.ConditionTrue,
				LastTransitionTime: now,
				Reason:             "ResourcesAvailable",
				Message:            "All resources are available",
			},
			{
				Type:               ocmworkv1.WorkDegraded,
				Status:             metav1.ConditionFalse,
				LastTransitionTime: now,
				Reason:             "NotDegraded",
				Message:            "Resources are healthy",
			},
		}
	}

	return r.Status().Update(ctx, mw)
}

func (r *ManifestWorkReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		For(&ocmworkv1.ManifestWork{}).
		Complete(r)
}

// gvrFromGVK converts a GVK to a GVR by pluralizing the Kind.
// This avoids using the hub cluster's REST mapper, which doesn't know about
// CRDs that only exist on managed clusters (e.g. DRClusterConfig, VRG).
func gvrFromGVK(gvk schema.GroupVersionKind) schema.GroupVersionResource {
	return schema.GroupVersionResource{
		Group:    gvk.Group,
		Version:  gvk.Version,
		Resource: pluralizeKind(gvk.Kind),
	}
}

func boolPtr(b bool) *bool {
	return &b
}
