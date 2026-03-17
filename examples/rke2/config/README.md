# Ramen DR Configuration

Kubernetes manifests for configuring Ramen DR on the hub and managed clusters.

## Files

| File | Applied To | Description |
|------|-----------|-------------|
| `drcluster.yaml` | Hub | DRCluster resources defining managed clusters participating in DR |
| `drpolicy.yaml` | Hub | DRPolicy resource defining the DR relationship and replication interval |
| `dr_hub_config.yaml` | Hub | Ramen hub operator ConfigMap (S3 profiles, DRCluster references) |
| `dr_cluster_config.yaml` | Managed clusters | Ramen DR cluster operator ConfigMap |
| `minio.yaml` | Hub | MinIO deployment providing S3-compatible storage for DR metadata |
| `clusterclaim-harv.yaml` | harv cluster | ClusterClaim identifying the harv cluster |
| `clusterclaim-marv.yaml` | marv cluster | ClusterClaim identifying the marv cluster |

## Usage

See [SETUP-SUMMARY.md](../SETUP-SUMMARY.md) for the order in which these are applied.
