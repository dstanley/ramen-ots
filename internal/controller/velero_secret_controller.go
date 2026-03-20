// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package controller

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"

	"github.com/go-logr/logr"
	corev1 "k8s.io/api/core/v1"
	k8serrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ocmworkv1 "open-cluster-management.io/api/work/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/builder"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/event"
	"sigs.k8s.io/controller-runtime/pkg/handler"
	"sigs.k8s.io/controller-runtime/pkg/predicate"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
	"gopkg.in/yaml.v3"
)

const (
	// Ramen hub operator ConfigMap location
	hubConfigMapName      = "ramen-hub-operator-config"
	hubConfigMapNamespace = "ramen-system"
	hubConfigMapKey       = "ramen_manager_config.yaml"

	// Velero secret naming — matches Ramen's internal/controller/util/secrets_util.go
	veleroSecretPrefix = "v"           // veleroFormatPrefix in Ramen
	veleroSecretKey    = "ramengenerated" // VeleroSecretKeyNameDefault in Ramen

	// ManifestWork naming for Velero secrets
	veleroSecretMWPrefix = "velero-s3-secret-"
)

// Minimal structs for parsing RamenConfig YAML without importing Ramen API types.
type ramenHubConfig struct {
	S3StoreProfiles      []s3StoreProfile     `yaml:"s3StoreProfiles"`
	KubeObjectProtection kubeObjectProtection `yaml:"kubeObjectProtection"`
}

type s3StoreProfile struct {
	S3SecretRef struct {
		Name      string `yaml:"name"`
		Namespace string `yaml:"namespace"`
	} `yaml:"s3SecretRef"`
}

type kubeObjectProtection struct {
	Disabled            bool   `yaml:"disabled"`
	VeleroNamespaceName string `yaml:"veleroNamespaceName"`
}

// VeleroSecretReconciler watches the Ramen hub operator ConfigMap and S3 secrets,
// then propagates Velero-formatted credentials to managed clusters via ManifestWork.
//
// This replaces the OCM Policy-based secret propagation that Ramen uses in full
// OCM mode. When the hub ConfigMap has kubeObjectProtection configured, this
// controller reads each S3 store profile's secret, reformats the credentials
// into Velero's expected INI format, and delivers them as "vs3-secret" to
// managed clusters' velero namespace.
type VeleroSecretReconciler struct {
	client.Client
	Log logr.Logger
}

func (r *VeleroSecretReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	log := r.Log.WithValues("trigger", req.NamespacedName)

	// Read hub ConfigMap
	cm := &corev1.ConfigMap{}
	cmKey := types.NamespacedName{Name: hubConfigMapName, Namespace: hubConfigMapNamespace}

	if err := r.Get(ctx, cmKey, cm); err != nil {
		if k8serrors.IsNotFound(err) {
			log.V(1).Info("Hub ConfigMap not found, skipping Velero secret propagation")
			return ctrl.Result{}, nil
		}

		return ctrl.Result{}, err
	}

	// Parse config
	configYAML, ok := cm.Data[hubConfigMapKey]
	if !ok {
		log.V(1).Info("Hub ConfigMap missing config key", "key", hubConfigMapKey)
		return ctrl.Result{}, nil
	}

	var config ramenHubConfig
	if err := yaml.Unmarshal([]byte(configYAML), &config); err != nil {
		log.Error(err, "Failed to parse hub ConfigMap")
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	// Check if kube object protection is configured
	if config.KubeObjectProtection.Disabled || config.KubeObjectProtection.VeleroNamespaceName == "" {
		log.V(1).Info("Kube object protection not configured, skipping")
		return ctrl.Result{}, nil
	}

	veleroNS := config.KubeObjectProtection.VeleroNamespaceName

	// Get target clusters from DRPolicy
	clusters, err := r.getDRPolicyClusters(ctx, log)
	if err != nil {
		log.Error(err, "Failed to get DR clusters")
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	if len(clusters) == 0 {
		log.V(1).Info("No DR clusters found, skipping")
		return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
	}

	// Process each S3 store profile
	for _, profile := range config.S3StoreProfiles {
		if profile.S3SecretRef.Name == "" {
			continue
		}

		secretNS := profile.S3SecretRef.Namespace
		if secretNS == "" {
			secretNS = hubConfigMapNamespace
		}

		if err := r.reconcileVeleroSecret(ctx, log, profile.S3SecretRef.Name, secretNS, veleroNS, clusters); err != nil {
			log.Error(err, "Failed to reconcile Velero secret",
				"secret", profile.S3SecretRef.Name, "namespace", secretNS)
			return ctrl.Result{RequeueAfter: defaultRequeueInterval}, nil
		}
	}

	log.Info("Velero secrets reconciled", "clusters", clusters)

	return ctrl.Result{}, nil
}

// reconcileVeleroSecret reads an S3 secret, formats it for Velero, and ensures
// a ManifestWork exists in each cluster namespace to deliver the secret.
func (r *VeleroSecretReconciler) reconcileVeleroSecret(
	ctx context.Context, log logr.Logger,
	secretName, secretNamespace, veleroNS string,
	clusters []string,
) error {
	// Read source S3 secret
	secret := &corev1.Secret{}
	if err := r.Get(ctx, types.NamespacedName{Name: secretName, Namespace: secretNamespace}, secret); err != nil {
		return fmt.Errorf("reading S3 secret %s/%s: %w", secretNamespace, secretName, err)
	}

	// Extract credentials
	accessKeyID := string(secret.Data["AWS_ACCESS_KEY_ID"])
	secretAccessKey := string(secret.Data["AWS_SECRET_ACCESS_KEY"])

	if accessKeyID == "" || secretAccessKey == "" {
		return fmt.Errorf("S3 secret %s/%s missing AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY",
			secretNamespace, secretName)
	}

	// Format as Velero credentials
	credentialsINI := fmt.Sprintf("[default]\n  aws_access_key_id = %s\n  aws_secret_access_key = %s\n",
		accessKeyID, secretAccessKey)
	credentialsB64 := base64.StdEncoding.EncodeToString([]byte(credentialsINI))

	// Target secret name follows Ramen convention: "v" + source name
	targetSecretName := veleroSecretPrefix + secretName

	// Create ManifestWork for each cluster
	for _, clusterName := range clusters {
		if err := r.ensureVeleroSecretManifestWork(
			ctx, log, clusterName, targetSecretName, veleroNS, credentialsB64,
		); err != nil {
			return fmt.Errorf("ensuring ManifestWork for cluster %s: %w", clusterName, err)
		}
	}

	return nil
}

// ensureVeleroSecretManifestWork creates or updates a ManifestWork that deploys
// the Velero S3 credential secret to a managed cluster.
func (r *VeleroSecretReconciler) ensureVeleroSecretManifestWork(
	ctx context.Context, log logr.Logger,
	clusterName, secretName, veleroNS, credentialsB64 string,
) error {
	mwName := veleroSecretMWPrefix + secretName

	// Build the secret for the managed cluster.
	// Use StringData with the base64-decoded value — Kubernetes will base64-encode it.
	// Actually, Ramen's code puts base64-encoded data in the Data field of the secret
	// that gets embedded in the OCM Policy template. But since we're creating the secret
	// directly (not via OCM template), we use the raw credentials in StringData.
	clusterSecret := &corev1.Secret{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "v1",
			Kind:       "Secret",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      secretName,
			Namespace: veleroNS,
			Labels: map[string]string{
				createdByRamenLabel: "true",
			},
		},
		// Decode credentialsB64 back to raw bytes for the Data field,
		// since JSON marshaling of corev1.Secret will base64-encode Data values.
		Data: map[string][]byte{
			veleroSecretKey: mustDecodeBase64(credentialsB64),
		},
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

		log.Info("Created Velero secret ManifestWork", "cluster", clusterName, "manifestwork", mwName)

		return nil
	}

	// Update existing ManifestWork
	existing.Spec.Workload.Manifests = []ocmworkv1.Manifest{manifest}
	if err := r.Update(ctx, existing); err != nil {
		return fmt.Errorf("updating ManifestWork: %w", err)
	}

	log.V(1).Info("Updated Velero secret ManifestWork", "cluster", clusterName, "manifestwork", mwName)

	return nil
}

// getDRPolicyClusters reads all DRPolicy resources and returns the unique set
// of cluster names. Reuses the same unstructured pattern as SecretPropagatorReconciler.
func (r *VeleroSecretReconciler) getDRPolicyClusters(ctx context.Context, log logr.Logger) ([]string, error) {
	return getDRPolicyClusters(ctx, r.Client, log)
}

// mustDecodeBase64 decodes a base64 string, panicking on error (for known-good input).
func mustDecodeBase64(s string) []byte {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		panic(fmt.Sprintf("invalid base64: %v", err))
	}

	return b
}

func (r *VeleroSecretReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		Named("velero-secret-propagator").
		For(&corev1.ConfigMap{}, builder.WithPredicates(hubConfigMapPredicate())).
		Watches(&corev1.Secret{}, handler.EnqueueRequestsFromMapFunc(mapToHubConfigMap),
			builder.WithPredicates(ramenSystemSecretPredicate())).
		Complete(r)
}

// hubConfigMapPredicate filters for the Ramen hub operator ConfigMap only.
func hubConfigMapPredicate() predicate.Predicate {
	isHubCM := func(obj client.Object) bool {
		return obj.GetName() == hubConfigMapName && obj.GetNamespace() == hubConfigMapNamespace
	}

	return predicate.Funcs{
		CreateFunc:  func(e event.CreateEvent) bool { return isHubCM(e.Object) },
		UpdateFunc:  func(e event.UpdateEvent) bool { return isHubCM(e.ObjectNew) },
		DeleteFunc:  func(e event.DeleteEvent) bool { return false }, // no action on CM delete
		GenericFunc: func(e event.GenericEvent) bool { return isHubCM(e.Object) },
	}
}

// ramenSystemSecretPredicate filters for secrets in the ramen-system namespace.
func ramenSystemSecretPredicate() predicate.Predicate {
	isMatch := func(obj client.Object) bool {
		return obj.GetNamespace() == hubConfigMapNamespace
	}

	return predicate.Funcs{
		CreateFunc:  func(e event.CreateEvent) bool { return isMatch(e.Object) },
		UpdateFunc:  func(e event.UpdateEvent) bool { return isMatch(e.ObjectNew) },
		DeleteFunc:  func(e event.DeleteEvent) bool { return false },
		GenericFunc: func(e event.GenericEvent) bool { return isMatch(e.Object) },
	}
}

// mapToHubConfigMap maps any event to a reconcile request for the hub ConfigMap,
// so all triggers funnel through the same reconcile logic.
func mapToHubConfigMap(_ context.Context, _ client.Object) []reconcile.Request {
	return []reconcile.Request{
		{NamespacedName: types.NamespacedName{Name: hubConfigMapName, Namespace: hubConfigMapNamespace}},
	}
}
