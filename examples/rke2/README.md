# Ramen DR on RKE2/Harvester

Example configurations and scripts for running Ramen disaster recovery across
RKE2/Harvester clusters using VolSync and Longhorn.

This example uses an experimental [Ramen OTS controller](https://github.com/dstanley/ramen-ots)
to fulfill OCM ManifestWork and ManagedClusterView CRs without requiring OCM
runtime components. The approach is informed by Martin Jackson's
[ramendr-analysis](https://github.com/mhjacks/ramendr-analysis), which examines
Ramen's OCM dependencies and proposes abstractions for decoupling them.

## Documentation

| Document | Description |
|----------|-------------|
| [SETUP-SUMMARY.md](SETUP-SUMMARY.md) | Step-by-step setup guide |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Architecture overview, DR operation flows, deployment models |

## Directory Structure

```
rke2/
  config/
    drcluster.yaml             # DRCluster resources
    drpolicy.yaml              # DRPolicy resource
    dr_hub_config.yaml         # Ramen hub operator configuration
    dr_cluster_config.yaml     # Ramen DR cluster operator configuration
    minio.yaml                 # MinIO deployment for S3 storage
  scripts/
    setup-ots.sh               # Set up OTS controller and managed clusters
    setup-submariner.sh        # Configure cross-cluster networking
    demo-dr.sh                 # Unified DR demo: deploy, failover, relocate, cleanup
    dr-status.sh               # Check DR status
    dr-failover.sh             # Execute failover
    dr-relocate.sh             # Execute relocation
  test-app/                    # Sample DR-protected application manifests
  argocd/                      # ArgoCD integration (ApplicationSet + DR controller)
  fleet/                       # Rancher Fleet integration (GitRepo + DR controller)
```

## Quick Start

After completing [setup](SETUP-SUMMARY.md), use `demo-dr.sh` to run the full DR lifecycle:

```bash
# Deploy app with DR protection (choose: manifestwork, argocd, or fleet)
./scripts/demo-dr.sh deploy harv --model fleet

# Failover to secondary cluster
./scripts/demo-dr.sh failover marv --model fleet

# Relocate back to primary
./scripts/demo-dr.sh relocate harv --model fleet

# Check status
./scripts/demo-dr.sh status --model fleet

# Cleanup
./scripts/demo-dr.sh cleanup --model fleet
```

## Deployment Models

Ramen supports three application deployment models. See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed comparison.

| Model | How it works | Cleanup on failover |
|-------|-------------|---------------------|
| **ManifestWork** | Direct resource deployment via OTS | Manual (app-controller.sh) |
| **ArgoCD** | ApplicationSet with Placement integration | Automatic |
| **Fleet** | Rancher Fleet GitRepo with cluster label targeting | Automatic |
