// SPDX-FileCopyrightText: The RamenDR authors
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"flag"
	"os"
	"time"

	"github.com/go-logr/logr"
	"github.com/ramendr/ramen-ots/internal/cluster"
	"github.com/ramendr/ramen-ots/internal/controller"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ocmworkv1 "open-cluster-management.io/api/work/v1"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	metricsserver "sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

var (
	scheme = runtime.NewScheme()
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(ocmworkv1.Install(scheme))
}

func main() {
	var (
		metricsAddr          string
		healthProbeAddr      string
		secretNamespace      string
		fallbackKubeconfig   string
		mcvRequeueInterval   time.Duration
		enableFleetController bool
		fleetLabelKey        string
		fleetNamespace       string
	)

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080",
		"The address the metric endpoint binds to.")
	flag.StringVar(&healthProbeAddr, "health-probe-bind-address", ":8081",
		"The address the health probe endpoint binds to.")
	flag.StringVar(&secretNamespace, "namespace", "ramen-ots-system",
		"Namespace where kubeconfig Secrets for managed clusters are stored.")
	flag.StringVar(&fallbackKubeconfig, "fallback-kubeconfig", "",
		"Path to a kubeconfig file with contexts matching cluster names (dev/testing).")
	flag.DurationVar(&mcvRequeueInterval, "mcv-requeue-interval", 15*time.Second,
		"Requeue interval for ManagedClusterView polling.")
	flag.BoolVar(&enableFleetController, "enable-fleet-controller", false,
		"Enable the Fleet PlacementDecision controller for managing Fleet cluster labels.")
	flag.StringVar(&fleetLabelKey, "fleet-label-key", "ramen.dr/fleet-enabled",
		"Label key to set on Fleet Cluster resources for DR targeting.")
	flag.StringVar(&fleetNamespace, "fleet-namespace", "fleet-default",
		"Namespace where Fleet Cluster resources are located.")

	opts := zap.Options{Development: true}
	opts.BindFlags(flag.CommandLine)
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseFlagOptions(&opts)))
	log := ctrl.Log.WithName("setup")

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		HealthProbeBindAddress: healthProbeAddr,
		Metrics: metricsserver.Options{
			BindAddress: metricsAddr,
		},
	})
	if err != nil {
		log.Error(err, "unable to create manager")
		os.Exit(1)
	}

	// Create cluster registry
	registry := cluster.NewRegistry(mgr.GetClient(), secretNamespace, log)
	if fallbackKubeconfig != "" {
		registry.SetFallbackKubeconfig(fallbackKubeconfig)
	}

	// Register ManifestWork controller
	if err := setupManifestWorkController(mgr, registry, log); err != nil {
		log.Error(err, "unable to create ManifestWork controller")
		os.Exit(1)
	}

	// Register ManagedClusterView controller
	if err := setupMCVController(mgr, registry, log, mcvRequeueInterval); err != nil {
		log.Error(err, "unable to create ManagedClusterView controller")
		os.Exit(1)
	}

	// Register Secret Propagator controller
	if err := setupSecretPropagatorController(mgr, log); err != nil {
		log.Error(err, "unable to create Secret Propagator controller")
		os.Exit(1)
	}

	// Register Fleet PlacementDecision controller (optional)
	if enableFleetController {
		if err := setupFleetPlacementController(mgr, log, fleetLabelKey, fleetNamespace); err != nil {
			log.Error(err, "unable to create Fleet PlacementDecision controller")
			os.Exit(1)
		}
	}

	// Health checks
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	log.Info("Starting manager",
		"namespace", secretNamespace,
		"metrics", metricsAddr,
		"health", healthProbeAddr,
		"fleetController", enableFleetController)

	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		log.Error(err, "problem running manager")
		os.Exit(1)
	}
}

func setupManifestWorkController(mgr ctrl.Manager, registry *cluster.Registry, log logr.Logger) error {
	reconciler := &controller.ManifestWorkReconciler{
		Client:   mgr.GetClient(),
		Log:      log.WithName("manifestwork"),
		Registry: registry,
	}
	return reconciler.SetupWithManager(mgr)
}

func setupMCVController(mgr ctrl.Manager, registry *cluster.Registry, log logr.Logger, requeueInterval time.Duration) error {
	reconciler := &controller.ManagedClusterViewReconciler{
		Client:          mgr.GetClient(),
		Log:             log.WithName("managedclusterview"),
		Registry:        registry,
		RequeueInterval: requeueInterval,
	}
	return reconciler.SetupWithManager(mgr)
}

func setupSecretPropagatorController(mgr ctrl.Manager, log logr.Logger) error {
	reconciler := &controller.SecretPropagatorReconciler{
		Client: mgr.GetClient(),
		Log:    log.WithName("secretpropagator"),
	}
	return reconciler.SetupWithManager(mgr)
}

func setupFleetPlacementController(mgr ctrl.Manager, log logr.Logger, labelKey, namespace string) error {
	reconciler := &controller.FleetPlacementReconciler{
		Client:         mgr.GetClient(),
		Log:            log.WithName("fleet-placement"),
		FleetLabelKey:  labelKey,
		FleetNamespace: namespace,
	}
	return reconciler.SetupWithManager(mgr)
}
