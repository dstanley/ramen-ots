// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

// Package controller contains locally-defined ManagedClusterView types.
// These are compatible with the OCM ManagedClusterView CRD but avoid
// importing the heavy multicloud-operators-subscription module.
package controller

import (
	"context"
	"fmt"
	"time"

	"github.com/go-logr/logr"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	// defaultRequeueInterval is the shared requeue interval for controllers
	// that need periodic retry (ManifestWork on error, SecretPropagator).
	defaultRequeueInterval = 30 * time.Second

	// ConditionViewProcessing is the condition type for MCV status
	ConditionViewProcessing = "Processing"
	// ReasonGetResourceFailed indicates the resource could not be retrieved
	ReasonGetResourceFailed = "GetResourceFailed"
	// ReasonGetResource indicates the resource was successfully retrieved
	ReasonGetResource = "GetResource"
)

// ManagedClusterViewGVK is the GVK for ManagedClusterView
var ManagedClusterViewGVK = schema.GroupVersionKind{
	Group:   "view.open-cluster-management.io",
	Version: "v1beta1",
	Kind:    "ManagedClusterView",
}

// ManagedClusterViewGVR is the GVR for ManagedClusterView
var ManagedClusterViewGVR = schema.GroupVersionResource{
	Group:    "view.open-cluster-management.io",
	Version:  "v1beta1",
	Resource: "managedclusterviews",
}

// ViewScope defines the scope of the resource to view.
// Field names match the OCM ManagedClusterView CRD spec.
type ViewScope struct {
	// Kind of the resource
	Kind string `json:"kind,omitempty"`
	// Group (apiGroup) of the resource — matches CRD field name "apiGroup"
	Group string `json:"apiGroup,omitempty"`
	// Version of the resource
	Version string `json:"version,omitempty"`
	// Resource is the plural resource name (optional; if empty, derived from Kind)
	Resource string `json:"resource,omitempty"`
	// Name of the resource
	Name string `json:"name,omitempty"`
	// Namespace of the resource (empty for cluster-scoped)
	Namespace string `json:"namespace,omitempty"`
}

// ViewSpec defines the desired state of ManagedClusterView
type ViewSpec struct {
	// Scope defines the resource to view
	Scope ViewScope `json:"scope"`
}

// ViewResult contains the resource data
type ViewResult struct {
	runtime.RawExtension `json:",inline"`
}

// ViewStatus defines the observed state of ManagedClusterView
type ViewStatus struct {
	// Conditions contains the status conditions
	Conditions []metav1.Condition `json:"conditions,omitempty"`
	// Result contains the queried resource data
	Result ViewResult `json:"result,omitempty"`
}

// ManagedClusterView is a local representation of the OCM ManagedClusterView CR
// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
type ManagedClusterView struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ViewSpec   `json:"spec,omitempty"`
	Status ViewStatus `json:"status,omitempty"`
}

// ManagedClusterViewList contains a list of ManagedClusterView
// +kubebuilder:object:root=true
type ManagedClusterViewList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ManagedClusterView `json:"items"`
}

// DeepCopyObject implements runtime.Object
func (m *ManagedClusterView) DeepCopyObject() runtime.Object {
	if m == nil {
		return nil
	}
	out := new(ManagedClusterView)
	m.DeepCopyInto(out)
	return out
}

// DeepCopyInto copies all fields into another ManagedClusterView
func (m *ManagedClusterView) DeepCopyInto(out *ManagedClusterView) {
	*out = *m
	out.TypeMeta = m.TypeMeta
	m.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	out.Spec = m.Spec
	m.Status.DeepCopyInto(&out.Status)
}

// DeepCopyInto copies ViewStatus
func (s *ViewStatus) DeepCopyInto(out *ViewStatus) {
	*out = *s
	if s.Conditions != nil {
		out.Conditions = make([]metav1.Condition, len(s.Conditions))
		for i := range s.Conditions {
			s.Conditions[i].DeepCopyInto(&out.Conditions[i])
		}
	}
	s.Result.DeepCopyInto(&out.Result)
}

// DeepCopyInto copies ViewResult
func (r *ViewResult) DeepCopyInto(out *ViewResult) {
	r.RawExtension.DeepCopyInto(&out.RawExtension)
}

// DeepCopyObject implements runtime.Object for ManagedClusterViewList
func (m *ManagedClusterViewList) DeepCopyObject() runtime.Object {
	if m == nil {
		return nil
	}
	out := new(ManagedClusterViewList)
	m.DeepCopyInto(out)
	return out
}

// DeepCopyInto copies all fields into another ManagedClusterViewList
func (m *ManagedClusterViewList) DeepCopyInto(out *ManagedClusterViewList) {
	*out = *m
	out.TypeMeta = m.TypeMeta
	m.ListMeta.DeepCopyInto(&out.ListMeta)
	if m.Items != nil {
		out.Items = make([]ManagedClusterView, len(m.Items))
		for i := range m.Items {
			m.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

// getDRPolicyClusters reads all DRPolicy resources and returns the unique set
// of cluster names. Uses unstructured access to avoid importing Ramen API types.
func getDRPolicyClusters(ctx context.Context, c client.Client, log logr.Logger) ([]string, error) {
	drPolicies := &unstructured.UnstructuredList{}
	drPolicies.SetGroupVersionKind(schema.GroupVersionKind{
		Group:   "ramendr.openshift.io",
		Version: "v1alpha1",
		Kind:    "DRPolicyList",
	})

	if err := c.List(ctx, drPolicies); err != nil {
		return nil, fmt.Errorf("listing DRPolicies: %w", err)
	}

	clusterSet := make(map[string]bool)

	for _, dp := range drPolicies.Items {
		clusters, found, err := unstructured.NestedStringSlice(dp.Object, "spec", "drClusters")
		if err != nil || !found {
			log.V(1).Info("DRPolicy missing drClusters", "name", dp.GetName())
			continue
		}

		for _, c := range clusters {
			clusterSet[c] = true
		}
	}

	result := make([]string, 0, len(clusterSet))
	for c := range clusterSet {
		result = append(result, c)
	}

	return result, nil
}
