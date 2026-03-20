# Ramen DR Setup on RKE2/Harvester - Summary

This document summarizes the steps to deploy Ramen DR with:
- **Hub cluster**: RKE2 on Hosted VMs
- **Managed clusters**: Two Harvester clusters (harv, marv in this example)

## Prerequisites

- RKE2 cluster for hub
- Two Harvester clusters for DR (harv, marv in this example)
- Container registry accessible from all clusters
- If using VMs, set CPU type to `host` (for x86-64-v2 support)
- Kubie for helper scripts

## Environment Variables

Set these to match your environment. Examples throughout this document use these values.

```bash
export REGISTRY=registry.example.com        # Container registry accessible from all clusters
export HUB_API=https://hub.example.com:6443 # Hub cluster API server URL
```

The examples use `harv` and `marv` as managed cluster names — substitute your own cluster names.

## 1. Build OTS Controller Image

```bash
# Native build (x86 Linux or amd64 Docker)
docker build -t $REGISTRY/ramen-ots:dev --load .

# Cross-compile for amd64 from Apple Silicon Mac (requires Rosetta in Rancher Desktop)
rdctl set --virtual-machine.type=vz
rdctl set --virtual-machine.use-rosetta
rdctl shutdown && sleep 2 && open -a "Rancher Desktop" && sleep 30
docker buildx build --platform linux/amd64 -t $REGISTRY/ramen-ots:dev --load .
```

### Push to Registry (with self-signed cert)

```bash
# Used skopeo to bypass TLS issues (test lab)
docker save ramen-ots:dev -o ramen-ots.tar
skopeo copy --dest-tls-verify=false docker-archive:ramen-ots.tar docker://$REGISTRY/ramen-ots:dev
rm ramen-ots.tar
```


## 2. Set Up OTS Controller

The OTS (Object Transport System) controller replaces OCM runtime components (klusterlet, work agents, addon controllers) by fulfilling ManifestWork and ManagedClusterView CRs directly from the hub using kubeconfig-based access to managed clusters.

```bash
# Run the setup script from the repo (installs CRDs, creates ManagedCluster CRs, deploys controller)
./examples/rke2/scripts/setup-ots.sh --clusters harv,marv \
  --kubeconfig ~/.kube/config \
  --image $REGISTRY/ramen-ots:dev

# Verify
kubectl get deployment -n ramen-ots-system
kubectl get managedclusters
```

The setup script handles:
1. Installing OCM CRDs (ManifestWork, ManagedClusterView, ManagedCluster, Placement, etc.)
2. Creating ManagedCluster namespaces and CRs with proper status conditions
3. Creating kubeconfig secrets for managed cluster access
4. Deploying the OTS controller

The default deployment manifest enables the Fleet PlacementDecision controller
(`--enable-fleet-controller`), which syncs PlacementDecision changes to Fleet
Cluster labels for automatic application failover. See the
[Fleet README](fleet/README.md) for details.

## 3. Deploy Ramen Hub Operator

```bash
make deploy-hub IMG=$REGISTRY/ramen-operator:dev PLATFORM=k8s

# Verify
kubectl get pods -n ramen-system
```

## 4. Deploy MinIO for S3 Storage

```bash
kubectl apply -f examples/rke2/config/minio.yaml

# Wait for pod
kubectl get pods -n minio-system -w

# Create bucket
kubectl -n minio-system run mc-create-bucket --rm -it --restart=Never \
  --image=minio/mc:RELEASE.2023-01-28T20-29-38Z \
  --command -- /bin/sh -c "mc alias set myminio http://minio.minio-system.svc.cluster.local:9000 minioadmin minioadmin && mc mb --ignore-existing myminio/ramen"
```

## 5. Configure Ramen Hub

```bash
# Create S3 secret
kubectl create secret generic s3-secret -n ramen-system \
  --from-literal=AWS_ACCESS_KEY_ID=minioadmin \
  --from-literal=AWS_SECRET_ACCESS_KEY=minioadmin

# Create hub config
kubectl create configmap ramen-hub-operator-config -n ramen-system \
  --from-file=ramen_manager_config.yaml=examples/rke2/config/dr_hub_config.yaml

# Restart to pick up config
kubectl rollout restart deployment -n ramen-system ramen-hub-operator

# Verify
kubectl logs -n ramen-system deployment/ramen-hub-operator -c manager --tail=20
```

## 6. Prepare Managed Cluster Kubeconfigs

The OTS controller uses kubeconfig secrets (created during Step 2) to access managed clusters.
Ensure your kubeconfig has working contexts for each managed cluster.


```yaml
# Example: kubie edit harv (or ~/.kube/harv.yaml)
apiVersion: v1
kind: Config
clusters:
- name: "harv"
  cluster:
    server: "https://<harvester-vip>/k8s/clusters/local"
    insecure-skip-tls-verify: true
users:
- name: "harv"
  user:
    token: "kubeconfig-user-xxx:token"
contexts:
- name: "harv"
  context:
    user: "harv"
    cluster: "harv"
current-context: "harv"
```

Verify the OTS controller can reach both clusters:

```bash
kubectl get managedclusters
kubectl logs -n ramen-ots-system deployment/ramen-ots-controller
```

Expected output:
```
NAME   HUB ACCEPTED   MANAGED CLUSTER URLS   JOINED   AVAILABLE   AGE
harv   true                                  True     Unknown     10m
marv   true                                  True     Unknown     6m
```

`Available=Unknown` is expected in OTS mode. The OCM agent that normally
heartbeats to set `Available=True` is not running. Ramen does not gate on
this condition.

## 7. Verify Managed Clusters Can Pull From Registry

Ensure each Harvester node can reach the container registry. If using a
self-signed certificate, add it to each node's trusted store or configure
containerd to skip TLS verification for the registry host.

```bash
for cluster in harv marv; do
  kubie exec $cluster default kubectl run registry-check --rm -it --restart=Never \
    --image=$REGISTRY/ramen-ots:dev -- echo "pull OK"
done
```

## 8. Install Required CRDs on Managed Clusters

Ramen requires several CRDs on managed clusters for the DR cluster operator to function.

### 8.1 CSI Addon CRDs

Only the VolumeReplication and VolumeReplicationClass CRDs are strictly required — the DR cluster operator will crash without them. The remaining CRDs are optional: VolumeGroupReplication and VolumeGroupSnapshot CRDs enable consistency group support for multi-PVC applications, while NetworkFenceClass and CSIAddonsNode enable storage-level network fencing for shared storage backends (e.g., Dell PowerFlex, Ceph/RBD). We install all of them since they are harmless if unused and avoid debugging missing-CRD issues later.

Run the following from the **ramen** repo root (the CRD files live in `hack/test/`):

```
for cluster in harv marv; do
  echo "=== Applying CRDs to $cluster ==="
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumereplicationclasses.yaml
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumereplications.yaml
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumegroupreplicationclasses.yaml
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumegroupreplicationcontents.yaml
  kubie exec $cluster default kubectl apply -f hack/test/replication.storage.openshift.io_volumegroupreplications.yaml
  kubie exec $cluster default kubectl apply -f hack/test/groupsnapshot.storage.openshift.io_volumegroupsnapshotclasses.yaml
  kubie exec $cluster default kubectl apply -f hack/test/groupsnapshot.storage.openshift.io_volumegroupsnapshotcontents.yaml
  kubie exec $cluster default kubectl apply -f hack/test/groupsnapshot.storage.openshift.io_volumegroupsnapshots.yaml
  kubie exec $cluster default kubectl apply -f hack/test/networkfenceclasses.csiaddons.openshift.io.yaml
  kubie exec $cluster default kubectl apply -f hack/test/csiaddonsnodes.csiaddons.openshift.io.yaml
done
```

## 9. Deploy DR Cluster Operator on Managed Clusters

The DR cluster operator runs on each managed cluster and handles the data plane
for disaster recovery. It reconciles VolumeReplicationGroup (VRG) resources
deployed by the hub (via ManifestWork/OTS), manages VolSync
ReplicationSource/ReplicationDestination lifecycle, handles PVC snapshot and
restore during failover, and reports protection status back to the hub.

Run these commands from the **ramen** repo root.

```bash
# On harv
kubie ctx harv
make deploy-dr-cluster IMG=$REGISTRY/ramen-operator:dev PLATFORM=k8s

# On marv
kubie ctx marv
make deploy-dr-cluster IMG=$REGISTRY/ramen-operator:dev PLATFORM=k8s

# Verify pods are running (2/2)
kubie exec harv default kubectl get pods -n ramen-system
kubie exec marv default kubectl get pods -n ramen-system
```

## 10. Install VolSync on Managed Clusters

These commands handle the installation of VolSync, the data mover that Ramen uses to replicate the PVCs between Harvester clusters.

```bash
# Install via Helm
for cluster in harv marv; do
  echo "=== Installing VolSync on $cluster ==="
  kubie exec $cluster default helm repo add backube https://backube.github.io/helm-charts/
  kubie exec $cluster default helm install volsync backube/volsync -n volsync-system --create-namespace
done

# Verify
kubie exec harv default kubectl get pods -n volsync-system
kubie exec marv default kubectl get pods -n volsync-system
```

## 10a. Configure StorageClass and VolumeSnapshotClass Labels (Critical!)

**This step is required for VolSync async replication to work.**

Each cluster must have a **unique** `ramendr.openshift.io/storageid` label. Same storageID across clusters triggers sync (VolumeReplication) mode instead of async (VolSync).

```bash
# On harv cluster
KUBECONFIG=/path/to/harv_kubeconfig.yaml kubectl label storageclass harvester-longhorn \
  ramendr.openshift.io/storageid=longhorn-harv --overwrite
KUBECONFIG=/path/to/harv_kubeconfig.yaml kubectl label volumesnapshotclass longhorn-snapshot \
  ramendr.openshift.io/storageid=longhorn-harv --overwrite

# On marv cluster
KUBECONFIG=/path/to/marv_kubeconfig.yaml kubectl label storageclass harvester-longhorn \
  ramendr.openshift.io/storageid=longhorn-marv --overwrite
KUBECONFIG=/path/to/marv_kubeconfig.yaml kubectl label volumesnapshotclass longhorn-snapshot \
  ramendr.openshift.io/storageid=longhorn-marv --overwrite
```

Also set `longhorn-snapshot` as the default VolumeSnapshotClass (it uses local snapshots, unlike `longhorn` which requires a backup target):

```bash
for cluster in harv marv; do
  kubie exec $cluster default kubectl annotate volumesnapshotclass longhorn-snapshot \
    snapshot.storage.kubernetes.io/is-default-class=true --overwrite
done
```

## 10b. Install Submariner (Optional but Recommended)

Submariner provides secure cross-cluster networking via encrypted gateway
tunnels (IPsec/WireGuard). VolSync's rsync-tls replication requires network
connectivity between clusters. With Submariner, Ramen creates ServiceExport
resources that make ReplicationDestination services reachable at
`*.svc.clusterset.local` across clusters. Without Submariner, VolSync falls
back to LoadBalancer services, which may not work in environments such as:

- **Bare metal / Harvester** — no LoadBalancer provider without MetalLB or kube-vip
- **Isolated subnets** — clusters on different VLANs with no routed path between them
- **NAT / firewall boundaries** — clusters in separate datacenters or VPCs where
  LoadBalancer IPs are not externally reachable

### Install subctl CLI

```bash
# Download latest subctl
curl -Ls https://get.submariner.io | VERSION=v0.22.1 bash

# Or install specific version
curl -LO https://github.com/submariner-io/subctl/releases/download/v0.22.1/subctl-v0.22.1-darwin-arm64.tar.gz
tar -xzf subctl-v0.22.1-darwin-arm64.tar.gz
mv subctl-v0.22.1/subctl /usr/local/bin/
```

**Important:** Use Submariner v0.22.1 or later for Kubernetes 1.34+ compatibility.

### Deploy Submariner Broker

```bash
# Deploy broker on hub cluster (or one of the managed clusters)
KUBECONFIG=/path/to/hub_kubeconfig.yaml subctl deploy-broker
```

This creates a `broker-info.subm` file containing connection details.

### Join Clusters to Submariner

```bash
# Join harv cluster (specify CIDRs to avoid auto-discovery issues)

Edit CIDRs to match your environment.

KUBECONFIG=/path/to/harv_kubeconfig.yaml subctl join broker-info.subm \
  --clusterid harv \
  --clustercidr 10.52.0.0/16 \
  --servicecidr 10.53.0.0/16

# Join marv cluster

Edit CIDRs to match your environment.

KUBECONFIG=/path/to/marv_kubeconfig.yaml subctl join broker-info.subm \
  --clusterid marv \
  --clustercidr 10.48.0.0/16 \
  --servicecidr 10.49.0.0/16
```

**Note:** Adjust CIDRs to match your cluster's actual pod and service CIDRs. You can find them with:
```bash
kubectl cluster-info dump | grep -m 1 cluster-cidr
kubectl cluster-info dump | grep -m 1 service-cluster-ip-range
```

### Verify Submariner Connectivity

```bash
# Check connection status
KUBECONFIG=/path/to/harv_kubeconfig.yaml subctl show connections

# Test cross-cluster connectivity
KUBECONFIG=/path/to/harv_kubeconfig.yaml subctl diagnose all
```

Expected output shows connected gateways with low latency (~4ms for local network).

## 10c. Install Velero (Optional)

Velero provides Kubernetes object protection (kube object protection) for
Ramen DR. When enabled, Ramen backs up and restores Kubernetes resources
(Deployments, ConfigMaps, Secrets, etc.) in addition to PVC data during
failover and relocate operations. Without Velero, only PVC data is
replicated via VolSync.

Velero is required if the DR cluster operator config includes
`kubeObjectProtection` (see `dr_cluster_config.yaml`). If you don't need
kube object protection, remove the `kubeObjectProtection` section from
the config and skip this step.

### Install Velero on Each Managed Cluster

Velero must be installed on every managed cluster that participates in DR.
The S3 backend can be the same MinIO instance used by Ramen (deployed in
step 4), but requires a separate bucket.

#### Create MinIO Bucket for Velero

```bash
kubectl -n minio-system run mc-create-bucket --rm -it --restart=Never \
  --image=minio/mc:RELEASE.2023-01-28T20-29-38Z \
  --command -- /bin/sh -c "mc alias set myminio http://minio.minio-system.svc.cluster.local:9000 minioadmin minioadmin && mc mb --ignore-existing myminio/velero"
```

#### Prepare Values File

Create a `velero-values.yaml` with your S3 configuration. The `s3Url`
must be reachable from managed clusters (use a NodePort or LoadBalancer
IP, not a cluster-internal service DNS):

```yaml
credentials:
  secretContents:
    cloud: |
      [default]
      aws_access_key_id = minioadmin
      aws_secret_access_key = minioadmin

snapshotsEnabled: false

configuration:
  backupStorageLocation:
    - name: default
      provider: aws
      bucket: velero
      default: true
      config:
        region: us-east-1
        s3ForcePathStyle: "true"
        s3Url: "http://<hub-node-ip>:<minio-nodeport>"
        checksumAlgorithm: ""
```

**Note:** The `aws` provider is the S3 protocol plugin name — it works
with any S3-compatible backend (MinIO, Ceph RGW, etc.), not just AWS.

#### Option A: Community Velero (vmware-tanzu)

```bash
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts

for cluster in harv marv; do
  echo "=== Installing Velero on $cluster ==="
  kubie exec $cluster default helm install velero vmware-tanzu/velero \
    --namespace velero --create-namespace \
    --values velero-values.yaml
done
```

#### Option B: SUSE Application Collection

If using SUSE Rancher, Velero is available from the Application
Collection registry (`dp.apps.rancher.io`). The chart pulls anonymously
but container images require an `application-collection` pull secret.

```bash
for cluster in harv marv; do
  echo "=== Installing Velero on $cluster ==="

  # Create image pull secret (use your AppCo credentials)
  kubie exec $cluster default kubectl create namespace velero --dry-run=client -o yaml | \
    kubie exec $cluster default kubectl apply -f -
  kubie exec $cluster default kubectl create secret docker-registry application-collection \
    --namespace velero \
    --docker-server=dp.apps.rancher.io \
    --docker-username='<your-email>' \
    --docker-password='<your-appco-token>'

  # Install chart with SUSE-specific values
  kubie exec $cluster default helm install velero \
    oci://dp.apps.rancher.io/charts/velero \
    --namespace velero --create-namespace \
    --set global.imagePullSecrets='{application-collection}' \
    --set image.registry=dp.apps.rancher.io \
    --values velero-values.yaml
done
```

**Note:** SUSE images use tags without the `v` prefix (e.g., `1.13.1`
not `v1.13.1`). If adding the AWS plugin as an initContainer, use the
SUSE image path:
```yaml
initContainers:
  - name: velero-plugin-for-aws
    image: dp.apps.rancher.io/containers/velero-plugin-for-aws:1.13.1
```

### Verify Installation

```bash
for cluster in harv marv; do
  echo "=== $cluster ==="
  kubie exec $cluster default kubectl get pods -n velero
  kubie exec $cluster default kubectl get backupstoragelocation -n velero
done
```

The Velero pod should be `Running` and the BackupStorageLocation should
show `Phase: Available`.

### Velero S3 Credentials (Automatic)

The OTS controller automatically propagates Velero S3 credentials (`vs3-secret`)
to managed clusters when `kubeObjectProtection.veleroNamespaceName` is configured
in the Ramen hub operator config. No manual secret creation is needed — the OTS
Velero secret controller reads S3 credentials from the hub and creates the
properly formatted Velero credential secret on each managed cluster via
ManifestWork.

Verify the secret was propagated:

```bash
for cluster in harv marv; do
  echo "=== $cluster ==="
  kubie exec $cluster default kubectl get secret vs3-secret -n velero
done
```

### Restart DR Cluster Operators

After installing Velero, restart the DR cluster operator on each managed
cluster so it detects Velero:

```bash
for cluster in harv marv; do
  kubie exec $cluster default kubectl rollout restart deployment -n ramen-system ramen-dr-cluster-operator
done
```

## 11. Create ClusterClaim Resources on Managed Clusters

Each managed cluster needs a ClusterClaim to identify itself:

```bash
# On harv
kubie exec harv default kubectl apply -f examples/rke2/config/clusterclaim-harv.yaml

# On marv
kubie exec marv default kubectl apply -f examples/rke2/config/clusterclaim-marv.yaml

# Verify
kubie exec harv default kubectl get clusterclaim
kubie exec marv default kubectl get clusterclaim
```

## 12. Create DRCluster and DRPolicy Resources

**DRCluster** represents a managed cluster that participates in DR. It
references the cluster name, S3 profile for metadata storage, and the
replication scheduling interval. When created, Ramen validates connectivity
by deploying a DRClusterConfig to the managed cluster (via ManifestWork/OTS)
and reading back storage class and ClusterClaim information (via MCV).

**DRPolicy** defines a DR relationship between two or more DRClusters. It
specifies which clusters can protect each other and the replication schedule
(e.g., every 5 minutes). During validation, Ramen reads the `id.k8s.io`
ClusterClaim and storage class labels from each cluster to build peer class
mappings -- matching StorageClasses across clusters by their `storageid` labels
to determine whether to use sync or async (VolSync) replication.

On the hub cluster:

```bash
kubectl apply -f examples/rke2/config/drcluster.yaml
kubectl apply -f examples/rke2/config/drpolicy.yaml

# Verify validation
kubectl get drcluster -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions[?(@.type=="Validated")].status}{"\n"}{end}'
kubectl get drpolicy -o jsonpath='{.items[0].status.conditions[?(@.type=="Validated")].status}'
```

Expected output:
```
harv: True
marv: True
True
```

## Verification Checklist

```bash
# Hub cluster
kubectl get managedclusters                    # Both Joined=True, Available=Unknown (expected for OTS)
kubectl get deployment -n ramen-ots-system     # OTS controller running
kubectl get drcluster                          # Both should exist
kubectl get drpolicy                           # Should exist
kubectl get managedclusterview -A              # MCVs should have Processing=True

# Check DRCluster validation
kubectl get drcluster harv -o jsonpath='{.status.conditions[?(@.type=="Validated")].message}'
# Should show: "Validated the cluster"

# Check OTS controller logs
kubectl logs -n ramen-ots-system deployment/ramen-ots-controller --tail=20

# Managed clusters (harv/marv)
kubie exec harv default kubectl get pods -n ramen-system             # 2/2 Running
kubie exec harv default kubectl get drclusterconfig                   # Should exist with status
kubie exec harv default kubectl get clusterclaim                      # id.k8s.io
```

## Troubleshooting

### ManagedClusterView Not Working

If DRClusters show "missing ManagedClusterView conditions":

1. Verify the OTS controller is running on the hub
2. Check the OTS controller logs for errors accessing managed clusters
3. Verify the kubeconfig secrets exist and are valid

```bash
# Check OTS controller
kubectl get deployment -n ramen-ots-system
kubectl logs -n ramen-ots-system deployment/ramen-ots-controller --tail=50

# Check kubeconfig secrets
kubectl get secrets -n ramen-ots-system | grep kubeconfig

# Verify MCV status
kubectl get managedclusterview -A -o wide
```

### DR Cluster Operator CrashLoopBackOff

If the dr-cluster operator crashes with CRD errors, ensure all CSI addon CRDs are installed (see step 11.1).

### VM CPU Issues

If pods fail with "CPU does not support x86-64-v2" and using proxmox:
1. Proxmox UI -> VM -> Hardware -> Processors -> Edit -> Type: `host`
2. Reboot VM

In Harvester make sure the cpu model is set to host-passthrough


### S3 Bucket Not Found

If DRCluster shows "NoSuchBucket" error, recreate the MinIO bucket:

```bash
kubectl -n minio-system run mc-create-bucket --rm -it --restart=Never \
  --image=minio/mc:RELEASE.2023-01-28T20-29-38Z \
  --command -- /bin/sh -c "mc alias set myminio http://minio.minio-system.svc.cluster.local:9000 minioadmin minioadmin && mc mb --ignore-existing myminio/ramen"
```

### VolSync "setgid failed" Error

If ReplicationSource logs show `@ERROR: setgid failed`, the rsync mover needs security context configuration.

Add `moverSecurityContext` to the DRPC:

```bash
kubectl patch drpc -n <namespace> <drpc-name> --type=merge -p '
{
  "spec": {
    "volSyncSpec": {
      "moverConfig": [{
        "pvcName": "<pvc-name>",
        "pvcNamespace": "<namespace>",
        "moverSecurityContext": {
          "runAsUser": 65534,
          "runAsGroup": 65534,
          "fsGroup": 65534
        }
      }]
    }
  }
}'
```

Then delete and let Ramen recreate the ReplicationSource/ReplicationDestination:

```bash
kubectl delete replicationsource -n <namespace> <pvc-name>
kubectl delete replicationdestination -n <namespace> <pvc-name>  # on secondary cluster
kubectl annotate vrg -n <namespace> <vrg-name> reconcile="$(date +%s)" --overwrite
```

### VolSync "DNS resolution failed" (clusterset.local)

If the ReplicationSource can't resolve `*.clusterset.local`:

1. Verify Submariner is installed and connected:
   ```bash
   subctl show connections
   ```

2. Verify the ServiceExport exists on the destination cluster:
   ```bash
   kubectl get serviceexport -n <namespace>
   ```

3. Test DNS resolution from the source cluster:
   ```bash
   kubectl run -it --rm debug --image=busybox --restart=Never -- \
     nslookup volsync-rsync-tls-dst-<pvc-name>.<namespace>.svc.clusterset.local
   ```

### VolSync Uses Wrong VolumeSnapshotClass

If VolumeSnapshots use `longhorn` instead of `longhorn-snapshot` and fail with "backup target not available":

1. Ensure StorageClass has the correct `storageid` label matching the VolumeSnapshotClass
2. Ensure `longhorn-snapshot` is set as default:
   ```bash
   kubectl annotate volumesnapshotclass longhorn-snapshot \
     snapshot.storage.kubernetes.io/is-default-class=true
   ```
3. Delete and recreate the ReplicationSource

### DRPolicy Shows Sync Instead of Async Peer Classes

If `kubectl get drpolicy -o yaml` shows `sync.peerClasses` populated but `async.peerClasses` empty:

The StorageClasses on both clusters have the **same** `storageid` label. This triggers sync detection.

Fix: Ensure each cluster has a unique storageID:
```bash
# On cluster 1
kubectl label storageclass harvester-longhorn ramendr.openshift.io/storageid=longhorn-cluster1 --overwrite

# On cluster 2
kubectl label storageclass harvester-longhorn ramendr.openshift.io/storageid=longhorn-cluster2 --overwrite
```

Then trigger DRPolicy reconciliation:
```bash
kubectl annotate drpolicy dr-policy reconcile="$(date +%s)" --overwrite
```

### Submariner Network Discovery Fails (K8s 1.34+)

If `subctl join` fails with "could not determine the service IP range":

This is a known issue with Submariner versions prior to 0.22.x on Kubernetes 1.34+.

**Solution 1:** Upgrade to Submariner v0.22.1+

**Solution 2:** Explicitly provide CIDRs during join:
```bash
subctl join broker-info.subm \
  --clusterid <name> \
  --clustercidr <pod-cidr> \
  --servicecidr <service-cidr>
```

### VRG Stuck Because Velero Not Installed

**Symptom:** DR cluster operator logs show:
```
VRG {ramen-ops/disapp-deploy-longhorn} with kube object protection doesn't work if velero/oadp is not installed. Please install velero/oadp and restart the operator
```

**Cause:** The DR cluster config has `kubeObjectProtection` enabled but Velero is not installed on the managed cluster.

**Fix:** Either install Velero (see step 10c) or remove `kubeObjectProtection` from the DR cluster config:
```bash
# Remove kubeObjectProtection from the configmap
kubectl edit configmap ramen-dr-cluster-operator-config -n ramen-system
# Then restart the operator
kubectl rollout restart deployment -n ramen-system ramen-dr-cluster-operator
```

### VRG Not Finding PVCs After Failover (created-by-ramen label) (Ramen Bug - Fixed)

After failover or relocate, the VRG on the new primary cluster shows "No PVCs are protected using Volsync scheme" even though PVCs exist. `DataProtected` never becomes `True`.

**Symptom:** VRG controller logs show:
```
Found 0 PVCs using label selector app=rto-rpo-test,app.kubernetes.io/created-by notin (volsync),ramendr.openshift.io/created-by-ramen notin (true)
```

**Root Cause:** `ensurePVCFromSnapshot()` in `vshandler.go` stamps restored PVCs with the label `ramendr.openshift.io/created-by-ramen=true` to prevent premature VRG enumeration during restore. However, the label is never removed after restore completes. `ListPVCsByPVCSelector()` in `pvcs_util.go` explicitly filters out PVCs with this label, so the VRG permanently ignores the restored PVC.

**Fix:** Remove the `created-by-ramen` label after the PVC is successfully created/updated from the snapshot in `ensurePVCFromSnapshot()`.

**Workaround (if running unfixed Ramen):** Remove the label from the PVC:
```bash
kubectl label pvc <pvc-name> -n <namespace> ramendr.openshift.io/created-by-ramen-
```

The VRG will then find the PVC and create a ReplicationSource for reverse replication.

### Namespace Stuck Terminating After Failover

After failover, the old namespace on the source cluster may be stuck in Terminating state.

**Symptom:**
```
Some content in the namespace has finalizers remaining:
volumereplicationgroups.ramendr.openshift.io/pvc-volsync-protection in 1 resource instances
```

**Cause:** A PVC has a VRG finalizer that wasn't cleaned up properly during failover.

**Fix:** Remove the finalizer from the stuck PVC:
```bash
kubectl patch pvc <pvc-name> -n <namespace> -p '{"metadata":{"finalizers":null}}' --type=merge
```

Then recreate the namespace if needed for the secondary VRG.

### Namespace Stuck Terminating Due to VolumeSnapshot Finalizer

After DR cleanup, a namespace may be stuck Terminating because a VolumeSnapshot
has a finalizer preventing deletion.

**Symptom:** `kubectl get volumesnapshot -n <namespace>` shows a snapshot still
present while the namespace is Terminating.

**Cause:** Longhorn VolumeSnapshot or VolumeSnapshotContent finalizers prevent
garbage collection when the underlying volume no longer exists (e.g. after
failover moved the workload).

**Fix:** Patch the finalizer off the VolumeSnapshot:
```bash
kubectl patch volumesnapshot <snapshot-name> -n <namespace> \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

If a VolumeSnapshotContent is also stuck:
```bash
kubectl patch volumesnapshotcontent <content-name> \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

### VolSync PSK Secret Not Propagating to Managed Clusters

The VolSync PSK secret is never created on managed clusters even though the DRPC is deployed.

**Symptom:** VRG controller logs show:
```
ERROR Failed to reconcile VolSync Replication Destination "error": "psk secret: <drpc-name>-vs-secret is not found"
```

**Root Cause:** Ramen propagates VolSync PSK secrets via ManifestWork. If the ManifestWork is not being fulfilled, the secret won't appear on managed clusters.

**Fix:** Check that the OTS controller is running and the ManifestWork exists:
```bash
# Check for PSK secret ManifestWork
kubectl get manifestwork -A | grep vs-secret

# Check OTS controller logs
kubectl logs -n ramen-ots-system deployment/ramen-ots-controller --tail=50

# If needed, trigger DRPC reconciliation
kubectl annotate drpc <drpc-name> -n <app-namespace> reconcile="$(date +%s)" --overwrite
```

### VolSync PSK Secret Missing After Namespace Recreation

After a namespace is deleted and recreated (e.g., due to stuck terminating state), the VolSync PSK secret may be missing.

**Symptom:** VRG controller logs show:
```
ERROR Failed to reconcile VolSync Replication Destination "error": "psk secret: <drpc-name>-vs-secret is not found"
```

**Cause:** The PSK secret was deleted with the namespace and wasn't recreated by DRPC.

**Fix:** Copy the PSK secret from the peer cluster:
```bash
# Get secret from primary cluster
kubectl get secret <drpc-name>-vs-secret -n <namespace> -o json | \
  jq 'del(.metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.ownerReferences, .metadata.managedFields)' \
  > /tmp/vs-secret.json

# Apply to secondary cluster (use appropriate kubeconfig)
kubectl apply -f /tmp/vs-secret.json
```

Then trigger VRG reconciliation:
```bash
kubectl annotate vrg <vrg-name> -n <namespace> reconcile="$(date +%s)" --overwrite
```

### ManifestWork Stuck with Stale Error

After fixing namespace issues, ManifestWork may still show old errors.

**Symptom:** ManifestWork shows "namespace is being terminated" error even after namespace is recreated.

**Fix:** Delete and let DRPC recreate the ManifestWork:
```bash
kubectl delete manifestwork <manifestwork-name> -n <cluster-namespace>
```

The DRPC controller will recreate it within a few seconds.

### ArgoCD ApplicationSet: PVC Dual Ownership Conflict

When using ArgoCD ApplicationSets for DR-protected applications, including the PVC in the ApplicationSet causes dual ownership conflicts during failover.

**Symptom:** After failover, the secondary VRG reports:
```
NoClusterDataConflict: False - A PVC that is not a replication destination should not match the label selector
```

**Root Cause:** Both ArgoCD and Ramen attempt to manage the PVC lifecycle. During failover, the PVC on the source cluster retains ArgoCD tracking labels and is not cleaned up, causing the secondary VRG to detect a PVC that isn't a VolSync replication destination.

**Fix:** Exclude `pvc.yaml` from the ArgoCD ApplicationSet's directory include list. Ramen should be the sole owner of PVC lifecycle during DR operations:
```yaml
sources:
- repoURL: https://github.com/example/repo.git
  path: app/
  directory:
    recurse: false
    # PVC excluded - Ramen manages PVC lifecycle during DR operations
    include: '{namespace.yaml,configmap.yaml,deployment.yaml}'
```

The initial PVC should be created separately (e.g., via ManifestWork or the `demo-dr.sh` script) before enabling DR protection.

## Architecture Summary

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           Hub Cluster (RKE2)                            │
├─────────────────────────────────────────────────────────────────────────┤
│  ramen-ots-system:                                                      │
│    - ramen-ots-controller  (ManifestWork + MCV + Fleet label sync)      │
│                                                                         │
│  ramen-system:                                                          │
│    - ramen-hub-operator                                                 │
│                                                                         │
│  minio-system:                                                          │
│    - minio (S3 storage for DR metadata)                                 │
└─────────────────────────────────────────────────────────────────────────┘
           │                                        │
           │  ManifestWork (push via OTS)           │  ManagedClusterView (pull via OTS)
           │  DRClusterConfig                       │  DRClusterConfig status
           ▼                                        ▼
┌──────────────────────────────┐    ┌──────────────────────────────┐
│   Managed Cluster: harv      │    │   Managed Cluster: marv      │
├──────────────────────────────┤    ├──────────────────────────────┤
│  ramen-system:               │    │  ramen-system:               │
│    - ramen-dr-cluster-operator│   │    - ramen-dr-cluster-operator│
│                              │    │                              │
│  volsync-system:             │    │  volsync-system:             │
│    - volsync                 │    │    - volsync                 │
│                              │    │                              │
│  velero: (optional)          │    │  velero: (optional)          │
│    - velero (kube obj prot.) │    │    - velero (kube obj prot.) │
│                              │    │                              │
│  longhorn-system:            │    │  longhorn-system:            │
│    - longhorn (CSI storage)  │    │    - longhorn (CSI storage)  │
└──────────────────────────────┘    └──────────────────────────────┘
```

## How ManifestWork and MCV Work with OTS

The OTS controller on the hub fulfills both ManifestWork and ManagedClusterView CRs using direct kubeconfig access to managed clusters:

1. **ManifestWork (push)**: OTS watches ManifestWork CRs, applies embedded resources to the target managed cluster via create-or-update, and updates status conditions
2. **ManagedClusterView (pull)**: OTS watches MCV CRs, reads the specified resource from the managed cluster, and writes the result to MCV status

No agents or addons are required on managed clusters. The OTS controller handles all hub-to-cluster communication.

## Failover and Failback Procedures

### Triggering a Failover

To failover from the current primary cluster to the secondary:

```bash
# On hub cluster
kubectl patch drpc <drpc-name> -n <namespace> --type=merge \
  -p '{"spec":{"action":"Failover","failoverCluster":"<target-cluster>"}}'
```

**Monitor progress:**
```bash
kubectl get drpc -n <namespace> -o jsonpath='Phase: {.items[0].status.phase}, Progression: {.items[0].status.progression}'
```

**Expected progression:**
1. `FailingOver` / `WaitingForResourceRestore`
2. `FailedOver` / `Cleaning Up`
3. `FailedOver` / `SettingUpVolSyncDest`
4. `FailedOver` / `Completed` (Protected: True)

### Triggering a Failback (Relocate)

To failback to the original primary cluster after data has been synced:

```bash
# On hub cluster
kubectl patch drpc <drpc-name> -n <namespace> --type=merge \
  -p '{"spec":{"action":"Relocate","preferredCluster":"<original-primary>"}}'
```

**Note:** Relocate requires that VolSync has successfully synced data back to the target cluster.

### Verifying Protection Status

```bash
# Check DRPC status
kubectl get drpc -n <namespace> -o jsonpath='{range .items[0].status.conditions[*]}{.type}: {.status} - {.message}{"\n"}{end}'

# Check VolSync replication
kubectl get replicationsource -n <namespace> -o wide   # On primary
kubectl get replicationdestination -n <namespace> -o wide  # On secondary

# Check VRG status on managed cluster
kubectl get vrg -n <namespace> -o jsonpath='{range .items[0].status.conditions[*]}{.type}: {.status}{"\n"}{end}'
```

### Post-Failover Checklist

After a failover completes, verify:

1. **App running on target cluster:**
   ```bash
   kubectl get pods -n <namespace> -l <app-label>
   ```

2. **Data accessible:**
   ```bash
   kubectl exec -n <namespace> <pod> -- ls -la /data/
   ```

3. **VolSync reverse replication working:**
   ```bash
   kubectl get replicationsource -n <namespace>  # Should show LAST SYNC time
   ```

4. **DRPC Protected: True:**
   ```bash
   kubectl get drpc -n <namespace> -o jsonpath='{.items[0].status.conditions[?(@.type=="Protected")].status}'
   ```

## Application ManifestWork Management

When using manual ManifestWorks (not OCM Subscriptions), you must manage the application lifecycle during DR operations:

### Important: Namespace Ownership

**CRITICAL**: If your app ManifestWork includes the Namespace resource, deleting the ManifestWork will delete the namespace and ALL its contents (including VRG, PVCs, and data).

**Best Practice**: Use separate ManifestWorks:
1. **Namespace ManifestWork** (managed by Ramen's DRPC) - created automatically
2. **App ManifestWork** (managed by you) - should NOT include namespace

Example app ManifestWork structure:
```yaml
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: myapp-app
  namespace: <managed-cluster>  # harv or marv
spec:
  workload:
    manifests:
    - apiVersion: v1
      kind: ConfigMap  # NOT Namespace
      metadata:
        name: myapp-config
        namespace: myapp-ns
    - apiVersion: apps/v1
      kind: Deployment
      ...
```

### Relocate (Failback) Process

During a Relocate operation, you must:

1. **Remove app from source cluster FIRST** (before final sync):
   ```bash
   # Delete app ManifestWork from source cluster namespace on hub
   kubectl delete manifestwork myapp-app -n <source-cluster>
   ```

2. **Wait for final sync to complete** - DRPC shows progression `RunningFinalSync` → `EnsuringVolumesAreSecondary`

3. **Apply app to target cluster AFTER relocate completes**:
   ```bash
   # Create app ManifestWork in target cluster namespace on hub
   kubectl apply -f myapp-manifestwork.yaml -n <target-cluster>
   ```

### Final Sync Requirements

For final sync during Relocate to work:
- PVC must be **unmounted** (no pods using it)
- ReplicationSource must be able to run a sync job
- PSK secret must exist on both clusters

If you accidentally delete the namespace on the source cluster before final sync completes:
- The final sync cannot run
- Data is restored from the **last successful sync point**
- Any writes after the last sync will be lost

### Relocate Stuck at RunningFinalSync

If Relocate is stuck at `RunningFinalSync`:

1. **Check if PVC is in use:**
   ```bash
   kubectl get pods -n <namespace> --context <source-cluster>
   ```

2. **If app is still running, remove it:**
   ```bash
   kubectl delete manifestwork <app>-app -n <source-cluster> --context hub
   ```

3. **If namespace was deleted, recreate it:**
   ```bash
   kubectl create ns <namespace> --context <source-cluster>
   # Then trigger ManifestWork reconciliation
   kubectl annotate manifestwork <drpc>-vrg-mw -n <source-cluster> reconcile=$(date +%s) --overwrite --context hub
   ```

4. **Force final sync completion (data loss scenario):**
   ```bash
   # If source data is already lost, patch VRG to indicate sync complete
   kubectl patch vrg <drpc-name> -n <namespace> --context <source-cluster> \
     --type=merge -p '{"spec":{"runFinalSync":true},"status":{"finalSyncComplete":true}}'
   ```

## DRPC-Aware App Controller

> **Note:** This section applies only to the **ManifestWork deployment model**.
> When using **Fleet** or **ArgoCD**, application lifecycle is handled
> automatically and this controller is not needed.

For testing RTO/RPO with manual ManifestWorks, use a controller that watches both DRPC status and PlacementDecision:

```bash
#!/bin/bash
# /tmp/rto-rpo-app-controller.sh
# DRPC-aware app placement controller

NAMESPACE="ramen-test"
PLACEMENT="rto-rpo-test-placement"
DRPC_NAME="rto-rpo-test-drpc"
HUB_CONTEXT="rke2"
LAST_CLUSTER=""
RELOCATE_QUIESCED=""

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" | tee -a /tmp/app-controller.log
}

deploy_app() {
    local cluster=$1
    log "=== DEPLOY APP TO $cluster ==="

    # Wait for PVC and remove created-by-ramen label
    for i in {1..15}; do
        if kubie exec $cluster $NAMESPACE -- kubectl get pvc rto-rpo-data -n $NAMESPACE &>/dev/null; then
            kubie exec $cluster $NAMESPACE -- kubectl label pvc rto-rpo-data -n $NAMESPACE ramendr.openshift.io/created-by-ramen- --overwrite 2>/dev/null || true
            break
        fi
        sleep 2
    done

    # Apply ManifestWork here (deployment + configmap)
    log "App ManifestWork applied to $cluster"
}

remove_app() {
    local cluster=$1
    log "=== REMOVE APP FROM $cluster ==="
    kubie exec $HUB_CONTEXT $NAMESPACE -- kubectl delete manifestwork rto-rpo-test-app -n $cluster --ignore-not-found
}

log "=== App Controller Started ==="

while true; do
    # 1. MEDIATION: Detect Relocate and quiesce app early
    DRPC_PHASE=$(kubie exec $HUB_CONTEXT $NAMESPACE -- kubectl get drpc $DRPC_NAME -n $NAMESPACE -o jsonpath='{.status.phase}' 2>/dev/null)

    if [[ "$DRPC_PHASE" == "Relocating" && -n "$LAST_CLUSTER" && "$RELOCATE_QUIESCED" != "$LAST_CLUSTER" ]]; then
        log "*** DRPC RELOCATING: Quiescing app on $LAST_CLUSTER for Final Sync ***"
        remove_app "$LAST_CLUSTER"
        RELOCATE_QUIESCED="$LAST_CLUSTER"
    fi

    # Reset quiesce flag when not relocating
    [[ "$DRPC_PHASE" != "Relocating" && "$DRPC_PHASE" != "Initiating" ]] && RELOCATE_QUIESCED=""

    # 2. PLACEMENT: Deploy app when placement changes
    CURRENT_CLUSTER=$(kubie exec $HUB_CONTEXT $NAMESPACE -- kubectl get placementdecision -n $NAMESPACE -l cluster.open-cluster-management.io/placement=$PLACEMENT -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null)

    if [[ -n "$CURRENT_CLUSTER" && "$CURRENT_CLUSTER" != "$LAST_CLUSTER" ]]; then
        log "*** PLACEMENT CHANGED: $LAST_CLUSTER -> $CURRENT_CLUSTER ***"
        [[ -n "$LAST_CLUSTER" && "$RELOCATE_QUIESCED" != "$LAST_CLUSTER" ]] && remove_app "$LAST_CLUSTER"
        deploy_app "$CURRENT_CLUSTER"
        LAST_CLUSTER="$CURRENT_CLUSTER"
        RELOCATE_QUIESCED=""
    fi

    sleep 2
done
```

**Key insight:** By watching DRPC phase `Relocating`, the controller can remove the app BEFORE PlacementDecision changes, allowing VRG to delete the PVC and run final sync.

## RTO/RPO Test Results

Test environment: RKE2 hub + 2 Harvester clusters, VolSync rsync-tls over Submariner

### ManifestWork Model (Manual App Deployment)

#### Failover (harv → marv)
- **RTO**: ~52 seconds (from DRPC Failover trigger to app running on marv)
- **RPO**: ~5.5 minutes (data loss window based on VolSync sync interval)

#### Failback/Relocate (marv → harv)
- **RTO**: Higher due to final sync requirement
- **RPO**: Minimal (final sync captures latest writes)

### ArgoCD ApplicationSet Model

#### Failover (harv → marv)
- **RTO**: ~22 seconds (from DRPC Failover trigger to DRPC Completed)
- **RPO**: Based on VolSync sync interval (default: 5m)
- ArgoCD automatically deploys app to new cluster via PlacementDecision change

#### Relocate (marv → harv)
- **RTO**: ~707 seconds (with manual intervention for two Ramen bugs, see Known Issues)
- **RPO**: Minimal (final sync captures latest writes before cutover)
- ArgoCD automatically removes app from source when PlacementDecision empties
- Expected to be significantly faster once Ramen bug fixes are applied

### Fleet GitRepo Model

#### Failover (harv → marv)
- **RTO**: ~30 seconds (from DRPC Failover trigger to DRPC Completed)
- **RPO**: Based on VolSync sync interval (default: 5m)
- OTS Fleet reconciler relabels Fleet clusters, Fleet automatically deploys app to target

#### Relocate (marv → harv)
- **RTO**: ~115 seconds (includes graceful quiesce and final sync)
- **RPO**: Zero (final sync completes before cutover)
- OTS Fleet reconciler unlabels all clusters during quiesce, Fleet removes app freeing PVC for final sync

**Note:** RPO depends on VolSync schedulingInterval configured in DRPolicy (default: 5m). RTO depends on PVC restore time, app startup time, and deployment model. ArgoCD and Fleet provide fastest failover since app deployment is fully automatic.
