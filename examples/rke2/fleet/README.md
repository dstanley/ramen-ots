# Fleet Integration with Ramen DR

This directory contains scripts and manifests for setting up Rancher Fleet with Placement integration for automatic application failover during DR operations.

## Overview

When using Fleet GitRepo with Ramen DR:
1. `fleet-dr-controller.sh` watches PlacementDecision for cluster changes
2. When Ramen updates PlacementDecision during failover/relocate:
   - Controller updates `ramen.dr/fleet-enabled` label on Fleet Cluster resources
   - Fleet detects label change on Cluster resource
   - Fleet creates/removes BundleDeployment for the target cluster
   - Fleet agent deploys/removes application resources

This provides **fully automatic application failover** without manual intervention.

## Fleet Cluster Naming

Fleet uses auto-generated cluster IDs (e.g., `c-npk9v`) rather than friendly names. The display name is stored in the `management.cattle.io/cluster-display-name` label. The controller resolves managed cluster names (harv, marv) to Fleet IDs using this label.

**Note:** Harvester clusters imported into Rancher require manual fleet-agent bootstrapping in the `cattle-fleet-clusters-system` namespace. See [Fleet Agent Bootstrap](#fleet-agent-bootstrap-for-harvester) below.

```
Name        Fleet ID    Label
harv        c-npk9v     management.cattle.io/cluster-display-name=harv
marv        c-djjjc     management.cattle.io/cluster-display-name=marv
```

## Setup

### Prerequisites

- Rancher installed on hub cluster (Fleet is bundled with Rancher)
- Managed clusters registered with Rancher
- OTS controller running on hub (see [SETUP-SUMMARY.md](../SETUP-SUMMARY.md))

### Verify Fleet Installation

```bash
# Run the setup/verification script
./setup-fleet.sh
```

This verifies Fleet is installed, discovers cluster mappings, and checks connectivity.

### Apply the GitRepo

```bash
# Apply the Fleet GitRepo resource
kubectl apply -f gitrepo.yaml --context rke2
```

The GitRepo targets clusters with `ramen.dr/fleet-enabled=true`. No clusters are labeled initially, so nothing deploys yet.

### Verify

```bash
# Check GitRepo was created
kubectl get gitrepo -n fleet-default --context rke2

# Check Fleet clusters
kubectl get clusters.fleet.cattle.io -n fleet-default --context rke2
```

## Usage

### Start the DR Controller

The controller manages Fleet cluster labels based on PlacementDecision changes:

```bash
# Start controller (runs in foreground)
./fleet-dr-controller.sh

# Or run in background
nohup ./fleet-dr-controller.sh > /tmp/fleet-dr-controller.log 2>&1 &

# With custom options
./fleet-dr-controller.sh --namespace ramen-test --placement rto-rpo-test-placement
```

### Deploy Application with Fleet

```bash
# 1. Create DR resources (namespace, PVC, Placement, DRPC) using demo-dr.sh
../scripts/demo-dr.sh deploy harv --model fleet

# 2. Apply the GitRepo (if not already applied)
kubectl apply -f gitrepo.yaml --context rke2

# 3. Start the DR controller if not already running
./fleet-dr-controller.sh &

# 4. Check Fleet BundleDeployments
kubectl get bundledeployments -n fleet-default --context rke2
```

### Trigger Failover

```bash
# Use the demo script
../scripts/demo-dr.sh failover marv --model fleet

# Or patch DRPC directly
kubectl patch drpc rto-rpo-test-drpc -n ramen-test --context rke2 \
  --type merge -p '{"spec":{"action":"Failover","failoverCluster":"marv"}}'
```

When PlacementDecision changes:
1. Controller detects change and relabels Fleet clusters
2. Fleet removes BundleDeployment from source cluster
3. Fleet creates BundleDeployment for target cluster
4. Fleet agent deploys app to target cluster

### Trigger Relocate

```bash
../scripts/demo-dr.sh relocate harv --model fleet
```

Fleet handles relocate automatically:
1. When PlacementDecision becomes empty (during quiesce), controller unlabels all clusters
2. Fleet removes the app, freeing the PVC for final sync
3. When PlacementDecision points to new cluster, controller labels it
4. Fleet deploys app to new cluster

## PVC Ownership

Fleet **must not** deploy the PVC. Ramen manages PVC lifecycle during DR operations. The `.fleetignore` file in `test-app/` excludes `pvc.yaml` and other non-application files. The initial PVC is created by `demo-dr.sh` via ManifestWork.

## Comparison: ManifestWork vs ArgoCD vs Fleet

| Aspect | ManifestWork | ArgoCD | Fleet |
|--------|-------------|--------|-------|
| App deployment | Manual via script | Automatic via ApplicationSet | Automatic via GitRepo |
| Failover cleanup | Manual or app-controller | Automatic | Automatic |
| Relocate cleanup | Manual or app-controller | Automatic | Automatic |
| Git integration | None | Full GitOps | Full GitOps |
| Cluster naming | Friendly names (harv) | Friendly names | Auto-generated IDs (c-xxxxx) |
| Prerequisite | OTS only | ArgoCD + OTS | Rancher + Fleet + OTS |
| Complexity | Low | Medium | Low (if Rancher installed) |

## Files

| File | Description |
|------|-------------|
| `setup-fleet.sh` | Script to verify Fleet installation and discover clusters |
| `fleet-dr-controller.sh` | Controller that manages cluster labels based on PlacementDecision |
| `gitrepo.yaml` | Fleet GitRepo resource targeting labeled clusters |
| `../test-app/fleet.yaml` | Fleet bundle configuration (namespace, deployment settings) |
| `../test-app/.fleetignore` | Excludes PVC and non-app files from Fleet deployment |

## Troubleshooting

### GitRepo not creating BundleDeployments

```bash
# Check GitRepo status
kubectl describe gitrepo rto-rpo-test -n fleet-default --context rke2

# Check if any cluster has the DR label
kubectl get clusters.fleet.cattle.io -n fleet-default --context rke2 \
  -l ramen.dr/fleet-enabled=true

# Check Fleet controller logs
kubectl logs -n cattle-fleet-system -l app=fleet-controller --context rke2 --tail=50
```

### Fleet cluster not found for managed cluster name

If the controller reports "Cannot resolve Fleet cluster ID", verify the display name label:

```bash
kubectl get clusters.fleet.cattle.io -n fleet-default --context rke2 \
  -o custom-columns='ID:.metadata.name,DISPLAY:.metadata.labels.management\.cattle\.io/cluster-display-name'
```

The `management.cattle.io/cluster-display-name` must match the ManagedCluster name.

### BundleDeployment stuck

```bash
# Check bundle status
kubectl get bundles -n fleet-default --context rke2

# Check BundleDeployment status
kubectl describe bundledeployment -n fleet-default --context rke2

# Check Fleet agent on managed cluster
kubectl get pods -n cattle-fleet-system --context harv
```

### Resources not cleaned up after label removal

Fleet v0.3.9+ (Rancher v2.6.4+) correctly removes resources when a cluster no longer matches. On older versions, manual cleanup may be needed:

```bash
kubectl delete bundledeployment <name> -n fleet-default --context rke2
```

## Fleet Agent Bootstrap for Harvester

Harvester clusters imported into Rancher have their own internal Fleet (in `cattle-fleet-system` and `cattle-fleet-local-system`). Rancher creates Fleet cluster objects (`c-npk9v`, `c-djjjc`) for these imported clusters but does not automatically bootstrap a fleet-agent that connects back to the management cluster's Fleet. This leaves the clusters in `WaitCheckIn` state.

The fix is to manually deploy a fleet-agent in the `cattle-fleet-clusters-system` namespace on each Harvester cluster. This namespace is designated for upstream fleet registration and does not conflict with Harvester's internal Fleet.

### Steps

1. **Create a ClusterRegistrationToken on the hub** (if not already present):

```bash
kubectl apply --context rke2 -f - <<EOF
apiVersion: fleet.cattle.io/v1alpha1
kind: ClusterRegistrationToken
metadata:
  name: import-token-default
  namespace: fleet-default
spec:
  ttl: 720h
EOF
```

2. **Patch Rancher Fleet cluster clientIDs** to match the agent registration IDs (after first registration, get the IDs from the ClusterRegistration objects and patch):

```bash
kubectl patch clusters.fleet.cattle.io c-npk9v -n fleet-default --context rke2 \
  --type merge -p '{"spec":{"clientID":"<agent-registration-id>"}}'
```

3. **On each Harvester cluster**, create the bootstrap secret, configmap, and fleet-agent deployment. See `setup-fleet.sh` for the complete bootstrap procedure.

4. **Verify** the Fleet clusters show `BUNDLES-READY: 1/1` and `LAST-SEEN` is set:

```bash
kubectl get clusters.fleet.cattle.io -n fleet-default --context rke2 -o wide
```

## Architecture

```
+-----------------------------------------------------------------------------+
|                              Hub Cluster                                     |
|                                                                              |
|  +-----------+     +------------------+     +---------------------------+    |
|  | Placement +---->| PlacementDecision|<----+ Fleet GitRepo             |    |
|  |           |     | (cluster: harv)  |     | (watches cluster labels)  |    |
|  +-----------+     +--------+---------+     +-------------+-------------+    |
|       ^                     |                             |                  |
|       |                     |                             |                  |
|       |                     v                             v                  |
|  +----+------------+  fleet-dr-controller    +------------------------+      |
|  |DRPlacementControl|  detects change,       | BundleDeployment       |      |
|  |(controls DR)     |  labels Fleet cluster  | (for labeled cluster)  |      |
|  +------------------+                        +-----------+------------+      |
|                                                          |                   |
+----------------------------------------------------------+-------------------+
                                                           | Fleet Agent Pull
                                                           v
                                                  +-----------------+
                                                  | Managed Cluster |
                                                  |     (harv)      |
                                                  |                 |
                                                  | [Application]   |
                                                  | [PVC with data] |
                                                  +-----------------+
```
