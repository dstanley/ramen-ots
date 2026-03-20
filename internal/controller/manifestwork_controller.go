// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package controller

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"

	"github.com/go-logr/logr"
	"github.com/ramendr/ramen-ots/internal/cluster"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	ocmworkv1 "open-cluster-management.io/api/work/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	ctrlutil "sigs.k8s.io/controller-runtime/pkg/controller/controllerutil"
)

const (
	manifestWorkFinalizer       = "ramen-ots.ramendr.openshift.io/manifestwork-cleanup"
	ocmManifestWorkFinalizer    = "cluster.open-cluster-management.io/manifest-work-cleanup"
	legacyManifestWorkFinalizer = "rancher-ots.ramendr.openshift.io/manifestwork-cleanup"
	manifestHashAnnotation      = "ramen-ots.io/manifest-hash"
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

	// Compute hash of manifests to detect changes
	currentHash := computeManifestHash(mw)
	lastHash := ""
	if mw.Annotations != nil {
		lastHash = mw.Annotations[manifestHashAnnotation]
	}

	// Only apply if manifests have changed
	var applyErr error
	if currentHash != lastHash {
		log.Info("Manifest spec changed, applying to cluster", "cluster", clusterName)
		applyErr = r.applyManifests(ctx, log, clusterName, mw)

		if applyErr == nil {
			// Store the hash so we skip next time if unchanged
			if mw.Annotations == nil {
				mw.Annotations = map[string]string{}
			}
			mw.Annotations[manifestHashAnnotation] = currentHash
			if err := r.Update(ctx, mw); err != nil {
				return ctrl.Result{}, err
			}
		}
	}

	// Update status conditions only if they actually changed
	if err := r.updateStatusIfChanged(ctx, mw, applyErr); err != nil {
		log.Error(err, "Failed to update ManifestWork status")
		return ctrl.Result{}, err
	}

	if applyErr != nil {
		log.Error(applyErr, "Failed to apply manifests, will retry")
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	return ctrl.Result{}, nil
}

// computeManifestHash returns a hex-encoded SHA256 hash of the ManifestWork's
// manifest payloads, used to detect spec changes and skip redundant applies.
func computeManifestHash(mw *ocmworkv1.ManifestWork) string {
	h := sha256.New()
	for _, m := range mw.Spec.Workload.Manifests {
		h.Write(m.Raw)
	}
	return fmt.Sprintf("%x", h.Sum(nil))
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

		// Remove "status" — Ramen embeds a stub status in VRG manifests that
		// contains null fields (e.g. lastUpdateTime: null), causing CRD
		// validation failures.
		delete(obj.Object, "status")

		gvk := obj.GroupVersionKind()
		gvr := gvrFromGVK(gvk)

		ns := obj.GetNamespace()

		if err := r.createOrUpdate(ctx, dc, gvr, ns, obj); err != nil {
			return fmt.Errorf("applying %s %s/%s to cluster %s: %w",
				gvk.Kind, ns, obj.GetName(), clusterName, err)
		}

		log.V(1).Info("Applied resource", "kind", gvk.Kind, "name", obj.GetName(),
			"namespace", ns, "cluster", clusterName)
	}

	return nil
}

// createOrUpdate creates the resource if it doesn't exist, or updates it by
// replacing the spec from the desired manifest. This avoids SSA field ownership
// issues where an empty struct (e.g. "volSync": {}) gets turned into null,
// triggering CRD validation failures. With a regular Update, empty structs
// remain as valid empty objects.
//
// After replacing the spec, fields managed exclusively by the managed cluster's
// ramen-dr-cluster-operator (e.g. volSync.rsSpec) are preserved from the
// existing object, since the hub never includes them in the ManifestWork.
func (r *ManifestWorkReconciler) createOrUpdate(
	ctx context.Context,
	dc dynamic.Interface,
	gvr schema.GroupVersionResource,
	ns string,
	desired *unstructured.Unstructured,
) error {
	var res dynamic.ResourceInterface
	if ns != "" {
		res = dc.Resource(gvr).Namespace(ns)
	} else {
		res = dc.Resource(gvr)
	}

	existing, err := res.Get(ctx, desired.GetName(), metav1.GetOptions{})
	if k8serrors.IsNotFound(err) {
		_, err = res.Create(ctx, desired, metav1.CreateOptions{})
		return err
	}
	if err != nil {
		return err
	}

	// Save fields managed by the local ramen-dr-cluster-operator before
	// replacing the spec. These fields are never set by the hub in the
	// ManifestWork and must survive spec replacement.
	savedLocalFields := preserveLocalFields(existing)

	// Replace spec entirely from the desired manifest. This ensures the hub's
	// intent is fully applied (e.g. clearing volSync.rdSpec by setting
	// volSync: {}) while preserving the existing object's metadata and status.
	if desiredSpec, ok := desired.Object["spec"]; ok {
		existing.Object["spec"] = desiredSpec
	}

	// Restore locally-managed fields into the replaced spec.
	restoreLocalFields(existing, savedLocalFields)

	// Merge labels and annotations from desired (additive, don't remove existing)
	if labels := desired.GetLabels(); len(labels) > 0 {
		merged := existing.GetLabels()
		if merged == nil {
			merged = map[string]string{}
		}
		for k, v := range labels {
			merged[k] = v
		}
		existing.SetLabels(merged)
	}
	if annotations := desired.GetAnnotations(); len(annotations) > 0 {
		merged := existing.GetAnnotations()
		if merged == nil {
			merged = map[string]string{}
		}
		for k, v := range annotations {
			merged[k] = v
		}
		existing.SetAnnotations(merged)
	}

	_, err = res.Update(ctx, existing, metav1.UpdateOptions{})
	return err
}

// localFields holds VRG spec fields managed by the ramen-dr-cluster-operator
// on the managed cluster. The hub never sets these in the ManifestWork.
type localFields struct {
	rsSpec interface{} // spec.volSync.rsSpec — VolSync ReplicationSource specs
}

// preserveLocalFields extracts fields from the existing object that are
// managed by the local ramen-dr-cluster-operator (not the hub).
func preserveLocalFields(existing *unstructured.Unstructured) localFields {
	var saved localFields
	volSync, ok := nestedMap(existing.Object, "spec", "volSync")
	if ok {
		saved.rsSpec = volSync["rsSpec"]
	}
	return saved
}

// restoreLocalFields writes back locally-managed fields into the object after
// spec replacement. Only restores fields that existed in the original object.
func restoreLocalFields(obj *unstructured.Unstructured, saved localFields) {
	if saved.rsSpec == nil {
		return
	}
	spec, ok := obj.Object["spec"].(map[string]interface{})
	if !ok {
		return
	}
	volSync, ok := spec["volSync"].(map[string]interface{})
	if !ok {
		// Create volSync map if the desired spec omitted it
		volSync = map[string]interface{}{}
		spec["volSync"] = volSync
	}
	volSync["rsSpec"] = saved.rsSpec
}

// nestedMap retrieves a nested map from an unstructured object by path keys.
func nestedMap(obj map[string]interface{}, keys ...string) (map[string]interface{}, bool) {
	current := obj
	for _, key := range keys {
		next, ok := current[key].(map[string]interface{})
		if !ok {
			return nil, false
		}
		current = next
	}
	return current, true
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

// updateStatusIfChanged only writes status when conditions actually differ from
// what is already on the ManifestWork, avoiding timestamp churn and unnecessary
// watch events.
func (r *ManifestWorkReconciler) updateStatusIfChanged(
	ctx context.Context, mw *ocmworkv1.ManifestWork, applyErr error,
) error {
	desired := desiredConditions(applyErr)

	// Check if conditions already match
	if conditionsMatch(mw.Status.Conditions, desired) {
		return nil
	}

	now := metav1.Now()
	for i := range desired {
		desired[i].LastTransitionTime = now
	}
	mw.Status.Conditions = desired

	return r.Status().Update(ctx, mw)
}

// desiredConditions returns the target conditions for the given apply result,
// without timestamps (those are set only when we actually write).
func desiredConditions(applyErr error) []metav1.Condition {
	if applyErr != nil {
		msg := applyErr.Error()
		return []metav1.Condition{
			{Type: ocmworkv1.WorkApplied, Status: metav1.ConditionFalse, Reason: "ApplyFailed", Message: msg},
			{Type: ocmworkv1.WorkAvailable, Status: metav1.ConditionFalse, Reason: "ApplyFailed", Message: msg},
			{Type: ocmworkv1.WorkDegraded, Status: metav1.ConditionTrue, Reason: "ApplyFailed", Message: msg},
		}
	}
	return []metav1.Condition{
		{Type: ocmworkv1.WorkApplied, Status: metav1.ConditionTrue, Reason: "AppliedSuccessfully", Message: "All manifests applied successfully"},
		{Type: ocmworkv1.WorkAvailable, Status: metav1.ConditionTrue, Reason: "ResourcesAvailable", Message: "All resources are available"},
		{Type: ocmworkv1.WorkDegraded, Status: metav1.ConditionFalse, Reason: "NotDegraded", Message: "Resources are healthy"},
	}
}

// conditionsMatch returns true if the existing conditions have the same
// Status and Reason as the desired conditions (ignoring timestamps and messages).
func conditionsMatch(existing, desired []metav1.Condition) bool {
	if len(existing) != len(desired) {
		return false
	}
	lookup := map[string]metav1.Condition{}
	for _, c := range existing {
		lookup[c.Type] = c
	}
	for _, d := range desired {
		e, ok := lookup[d.Type]
		if !ok || e.Status != d.Status || e.Reason != d.Reason {
			return false
		}
	}
	return true
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

