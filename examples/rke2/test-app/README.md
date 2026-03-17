# RTO/RPO Test Application

This test application measures Recovery Time Objective (RTO) and Recovery Point Objective (RPO) during Ramen DR failover operations.

## How It Works

The application:
1. Writes timestamps to a PVC every second
2. Maintains a state file with the last write time
3. On startup, detects if it's recovering from a failover
4. Calculates and displays RPO (time since last successful write)
5. RTO can be measured externally (time from failover initiation to app running)

## Files

| File | Description |
|------|-------------|
| `namespace.yaml` | Namespace for the test app |
| `configmap.yaml` | Shell scripts for timestamp writing |
| `pvc.yaml` | PVC with Ramen protection label |
| `deployment.yaml` | Deployment running the timestamp writer |
| `placement.yaml` | OCM Placement for cluster selection |
| `drplacementcontrol.yaml` | Ramen DR protection for the app |
| `manifestwork.yaml` | OCM ManifestWork for direct deployment |
| `kustomization.yaml` | Kustomize for local testing |

## Deployment Options

### Option 1: Direct Deployment via ManifestWork (Simplest)

Deploy directly to a managed cluster using ManifestWork:

```bash
# Deploy to harv cluster
kubectl apply -f manifestwork.yaml --context hub

# Or modify the namespace in manifestwork.yaml to deploy to marv
sed 's/namespace: harv/namespace: marv/' manifestwork.yaml | kubectl apply -f - --context hub
```

### Option 2: Local Deployment for Testing

Deploy directly to a cluster for local testing:

```bash
# Using kustomize
kubectl apply -k . --context harv

# Or apply files individually
kubectl apply -f namespace.yaml --context harv
kubectl apply -f configmap.yaml --context harv
kubectl apply -f pvc.yaml --context harv
kubectl apply -f deployment.yaml --context harv
```

### Option 3: DR-Protected Deployment (Full Ramen Integration)

For full DR protection with automatic failover:

```bash
# First, create the namespace on the hub for DR resources
kubectl create namespace ramen-test --context hub

# Apply the Placement and DRPlacementControl on the hub
kubectl apply -f placement.yaml --context hub
kubectl apply -f drplacementcontrol.yaml --context hub

# The DRPC will coordinate with the Placement to deploy the app
# and set up VolSync replication
```

## Monitoring the Application

### Check Pod Logs

```bash
# On the cluster where the app is running
kubectl logs -f deployment/rto-rpo-test -n ramen-test --context harv
```

### Check Current State

```bash
# Exec into the pod and check state
kubectl exec -it deployment/rto-rpo-test -n ramen-test --context harv -- cat /data/state.json
```

### Check RPO Without Restart

```bash
# Run the check-rpo.sh script
kubectl exec -it deployment/rto-rpo-test -n ramen-test --context harv -- /bin/sh /scripts/check-rpo.sh
```

## Failover Testing

### Step 1: Verify Initial State

```bash
# Check the app is running on the primary cluster
kubectl get pods -n ramen-test --context harv

# Check DRPC status
kubectl get drpc -n ramen-test --context hub

# Watch the logs to see writes happening
kubectl logs -f deployment/rto-rpo-test -n ramen-test --context harv
```

### Step 2: Initiate Failover

```bash
# Record the start time
START_TIME=$(date +%s)

# Patch the DRPC to failover to the secondary cluster
kubectl patch drpc rto-rpo-test-drpc -n ramen-test --context hub \
  --type merge -p '{"spec":{"action":"Failover","failoverCluster":"marv"}}'
```

### Step 3: Monitor Failover Progress

```bash
# Watch DRPC status
kubectl get drpc -n ramen-test --context hub -w

# Check for pod on secondary cluster
kubectl get pods -n ramen-test --context marv -w
```

### Step 4: Measure RTO/RPO

Once the pod is running on the secondary cluster:

```bash
# Check the pod logs for RPO measurement
kubectl logs deployment/rto-rpo-test -n ramen-test --context marv

# Calculate RTO (time from failover start to app running)
END_TIME=$(date +%s)
RTO=$((END_TIME - START_TIME))
echo "RTO: ${RTO} seconds"
```

The pod logs will show something like:
```
==============================================
  RTO/RPO Test Application
==============================================

Hostname: rto-rpo-test-xyz-abc
Start time: 2024-01-15T10:30:45.000Z
Data directory: /data
Write interval: 1s

>>> RECOVERY DETECTED <<<

RPO Analysis:
  Last write time: 2024-01-15T10:28:30.000Z
  Current time:    2024-01-15T10:30:45.000Z
  RPO (data age):  2m 15s
  RPO (ms):        135000

Previous Instance:
  Hostname:    rto-rpo-test-old-pod
  Write count: 1842
```

### Step 5: Relocate Back (Optional)

```bash
# Relocate back to primary cluster
kubectl patch drpc rto-rpo-test-drpc -n ramen-test --context hub \
  --type merge -p '{"spec":{"action":"Relocate","preferredCluster":"harv"}}'
```

## Interpreting Results

### RPO (Recovery Point Objective)
- **What it measures**: How much data was lost (in time)
- **Displayed in**: Pod logs on recovery
- **Expected values**: Depends on VolSync replication interval
  - With 1-minute sync: ~1-2 minutes worst case
  - With 5-minute sync: ~5-6 minutes worst case

### RTO (Recovery Time Objective)
- **What it measures**: Time to recover after failover
- **How to measure**: Time from failover initiation to app running
- **Components**:
  - VolSync final sync time
  - PVC provisioning on target cluster
  - Pod scheduling and startup
- **Expected values**: Typically 2-5 minutes depending on cluster

## Cleanup

```bash
# Remove ManifestWork (if using Option 1)
kubectl delete -f manifestwork.yaml --context hub

# Remove DRPC (if using Option 3)
kubectl delete -f drplacementcontrol.yaml --context hub
kubectl delete -f placement.yaml --context hub

# Clean up namespace on managed clusters
kubectl delete namespace ramen-test --context harv
kubectl delete namespace ramen-test --context marv
```

## Troubleshooting

### Pod Not Starting

```bash
# Check PVC status
kubectl get pvc -n ramen-test --context harv

# Check events
kubectl get events -n ramen-test --context harv --sort-by='.lastTimestamp'
```

### VolSync Not Replicating

```bash
# Check ReplicationSource on primary
kubectl get replicationsource -n ramen-test --context harv

# Check ReplicationDestination on secondary
kubectl get replicationdestination -n ramen-test --context marv
```

### DRPC Not Progressing

```bash
# Check DRPC status and conditions
kubectl describe drpc rto-rpo-test-drpc -n ramen-test --context hub

# Check VRG on managed clusters
kubectl get vrg -n ramen-test --context harv
kubectl get vrg -n ramen-test --context marv
```
