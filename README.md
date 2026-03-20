# Ramen OTS Controller

An experimental Kubernetes controller that implements the OCM Object Transport System (OTS)
interface for Ramen DR, enabling disaster recovery without requiring OCM
runtime components.

The approach is informed by Martin Jackson's
[ramendr-analysis](https://github.com/mhjacks/ramendr-analysis), which examines
Ramen's OCM dependencies and proposes abstractions for decoupling them.


## What It Does

Ramen creates **ManifestWork** and **ManagedClusterView** custom resources to
deploy and monitor resources on managed clusters. Normally these are fulfilled
by OCM's work agent running on each managed cluster. This controller fulfills
them directly from the hub using kubeconfig-based access.

**ManifestWork** — Applies embedded Kubernetes resources to managed clusters
using create-or-update with spec replacement, manages lifecycle with finalizers,
and reports status conditions (Applied, Available, Degraded). Preserves fields
managed by the local ramen-dr-cluster-operator (e.g. `volSync.rsSpec`).

**ManagedClusterView** — Reads a specified resource from a managed cluster and
returns the result in the CR status. Polls every 15 seconds to keep status
current during DR operations.

**Secret Propagator** — Watches VolSync PSK hub secrets and propagates them to
managed clusters via ManifestWork.

**Velero Secret Propagator** — Reads S3 credentials from the Ramen hub config
and propagates Velero-formatted credentials (`vs3-secret`) to managed clusters
for kube object protection via Velero BackupStorageLocations.

**Fleet PlacementDecision** (optional) — Watches PlacementDecision resources
annotated with `ramen.dr/fleet-managed=true` and syncs labels on Rancher Fleet
Cluster resources. When Ramen updates the PlacementDecision during failover or
relocate, this controller sets `ramen.dr/fleet-enabled=true` on the target
Fleet Cluster and removes it from all others, causing Fleet to redeploy the
application to the correct cluster. Enabled with `--enable-fleet-controller`.

## Architecture

```
Hub Cluster
├── Ramen Hub Operator (unchanged)
│   ├── Creates ManifestWork CRs    (namespace = cluster name)
│   └── Creates ManagedClusterView  (namespace = cluster name)
│
└── Ramen OTS Controller
    ├── ManifestWork reconciler  → applies resources to managed cluster
    ├── MCV reconciler           → reads resources from managed cluster
    ├── Secret propagator        → propagates VolSync PSK secrets
    ├── Velero secret propagator → propagates Velero S3 credentials
    ├── Fleet reconciler (opt)   → syncs PlacementDecision to Fleet labels
    │
    └── Cluster Registry
        ├── Reads kubeconfig from Secret: <cluster>-kubeconfig
        └── Fallback: kubeconfig context matching cluster name
```

## Cluster Connectivity

The controller resolves cluster names to API clients using kubeconfig Secrets
stored on the **hub** cluster.

### Kubeconfig Secret Format

Create a Secret named `<cluster-name>-kubeconfig` in the controller namespace
(default: `ramen-ots-system`):

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: harv-kubeconfig
  namespace: ramen-ots-system
type: Opaque
data:
  kubeconfig: <base64-encoded kubeconfig>
```

The controller checks for data keys `kubeconfig` and `value` (the latter is
common in Rancher-managed clusters).

### Development Fallback

For local development, use `--fallback-kubeconfig` to point to a kubeconfig
file where context names match managed cluster names:

```bash
make run KUBECONFIG=~/.kube/config
```

## Building

```bash
# Build binary
make build

# Build container image (SUSE BCI base)
make docker-build IMG=myregistry/ramen-ots:v0.1.0

# Push container image
make docker-push IMG=myregistry/ramen-ots:v0.1.0
```

## Running

```bash
# Local development (uses kubeconfig contexts for cluster access)
go run ./cmd/ \
  --fallback-kubeconfig=$HOME/.kube/config \
  --namespace=ramen-ots-system

# Flags
#   --namespace              Namespace for kubeconfig Secrets (default: ramen-ots-system)
#   --fallback-kubeconfig    Kubeconfig file for dev/testing
#   --metrics-bind-address   Metrics endpoint (default: :8080)
#   --health-probe-bind-address  Health probe endpoint (default: :8081)
#   --enable-fleet-controller    Enable Fleet PlacementDecision controller (default: false)
#   --fleet-label-key            Label key on Fleet Clusters (default: ramen.dr/fleet-enabled)
#   --fleet-namespace            Namespace for Fleet Cluster resources (default: fleet-default)
```

## Prerequisites

- Ramen hub operator deployed with OCM CRDs installed (ManifestWork,
  ManagedClusterView)
- Kubeconfig Secrets for each managed cluster, or a kubeconfig file with
  matching context names
- Namespaces on the hub matching managed cluster names (Ramen creates these)

## Integration with Ramen

This controller works alongside an unmodified Ramen hub operator. Ramen creates
ManifestWork and MCV CRs as part of its normal DR operations. Instead of OCM
agents fulfilling those CRs on managed clusters, this controller fulfills them
directly from the hub using kubeconfig-based access. Ramen's OCM CRDs must
still be installed, but no OCM runtime components (hub controllers, klusterlet
agents) are required.

Key compatibility details:
- ManifestWork status must report `Applied=True`, `Available=True`,
  `Degraded=False` for Ramen to consider manifests applied
- MCV status must include exactly one condition of type `Processing` and the
  resource data in `status.result`
- Error messages for not-found resources must contain "not found" (Ramen
  parses this string)
