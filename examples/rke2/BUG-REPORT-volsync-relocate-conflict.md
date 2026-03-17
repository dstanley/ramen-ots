# Bug: VolSync relocate stuck at SettingUpVolSyncDest due to false PVC conflict

## Summary

During an async (VolSync) relocate operation, the DRPC gets permanently stuck at `SettingUpVolSyncDest` with `Protected: False (Error)`. The root cause is a false positive in the `NoClusterDataConflict` condition check when the VRG transitions from primary to secondary on the source cluster.

## Environment

- **Platform**: RKE2 on Harvester/Proxmox (vanilla Kubernetes, no ODF/OCS)
- **Storage**: Longhorn
- **Replication**: VolSync (async, rsync-tls)
- **Deployment model**: Fleet (also reproducible with ArgoCD or ManifestWork)
- **Ramen version**: Built from main branch (commit `2e92d374`)

## Steps to Reproduce

1. Deploy a DR-protected application with a PVC on cluster A (primary)
2. Wait for VolSync replication to complete (Protected=True)
3. Initiate a relocate to cluster B (`spec.action: Relocate`, `spec.preferredCluster: B`)
4. Relocate completes (phase=Relocated) but DRPC gets stuck at `progression: SettingUpVolSyncDest`

## Observed Behavior

The DRPC reports:

```
phase=Relocated progression=SettingUpVolSyncDest
Protected: False (Error) VolumeReplicationGroup (ramen-test/rto-rpo-test-drpc)
  on cluster B is reporting errors (A PVC that is not a replication destination
  should not match the label selector.) conflicting workload data, retrying till
  NoClusterDataConflict condition is met
```

The system never recovers from this state. The reverse replication (from new primary back to old primary) is never established, leaving the workload unprotected.

## Root Cause Analysis

### Call flow during relocate cleanup

1. DRPC calls `ensureCleanupAndSecondaryReplicationSetup(srcCluster)` (`drplacementcontrol.go:960`)
2. This calls `EnsureCleanup(srcCluster)` which transitions the VRG on the **source cluster** (cluster A) from primary to secondary (`drplacementcontrol.go:988`)
3. On cluster A, the VRG reconciler processes the VRG as secondary and calls `updateVRGConditions()` (`volumereplicationgroup_controller.go:2090`)
4. This invokes `aggregateVolSyncClusterDataConflictCondition()` → `validateSecondaryPVCConflictForVolsync()` (`vrg_volsync.go:1013`)

### The false positive

`validateSecondaryPVCConflictForVolsync()` iterates all PVCs matching the VRG's label selector (`v.volSyncPVCs`) and checks that each one has a corresponding entry in `Spec.VolSync.RDSpec`. During the primary-to-secondary transition:

- The **app PVC** (e.g., `rto-rpo-data`) still exists on cluster A — the application hasn't been cleaned up yet
- This PVC matches the VRG label selector, so it appears in `v.volSyncPVCs`
- But it has **no matching RDSpec entry** (RDSpec contains replication destination specs, not source PVCs)
- The function returns `true` (conflict detected), setting `NoClusterDataConflict=False`

### How it blocks the DRPC

The DRPC's `findConflictCondition()` (`drplacementcontrol_controller.go:1489`) scans **all VRGs across all clusters** for `NoClusterDataConflict=False`. It picks up the false conflict from cluster A's VRG and propagates it to the DRPC's `Protected` condition, blocking further progress.

### Why this doesn't happen with ODF/Ceph

With VolumeReplication (ODF/Ceph-CSI), the primary/secondary flip happens at the storage driver level. There are no separate app PVCs and replication destination PVCs — the same PVC changes replication direction atomically. With VolSync, Ramen must orchestrate the transition through separate API calls, creating a window where the app PVC exists as a "non-destination PVC" on the now-secondary cluster.

## Fix

**File**: `internal/controller/vrg_volsync.go`

In `validateSecondaryPVCConflictForVolsync()`, when a PVC doesn't match any RDSpec entry, check if it was previously protected by this VRG when it was primary (by checking `Status.ProtectedPVCs`). If it was, this is an expected transient leftover during the primary-to-secondary transition — not a conflict. Skip it instead of returning a false positive.

```go
if !matchFound {
    // During a relocate, the VRG transitions from primary to secondary. PVCs that were
    // previously protected as primary may still exist while the application is being
    // cleaned up. These are not conflicts — they are expected transient leftovers.
    if v.isPreviouslyProtectedPVC(pvc.GetName(), pvc.GetNamespace()) {
        v.log.Info("Skipping conflict for PVC that was previously protected as primary",
            "pvc", pvc.GetName(), "namespace", pvc.GetNamespace())
        continue
    }
    return true // No match found for this PVC, conflict detected!
}
```

```go
func (v *VRGInstance) isPreviouslyProtectedPVC(name, namespace string) bool {
    for i := range v.instance.Status.ProtectedPVCs {
        if v.instance.Status.ProtectedPVCs[i].Name == name &&
            v.instance.Status.ProtectedPVCs[i].Namespace == namespace {
            return true
        }
    }
    return false
}
```

### Why this is safe

- `Status.ProtectedPVCs` is populated by the VRG when it is primary, listing all PVCs it actively protects
- A PVC in this list on a VRG that just transitioned to secondary is definitionally a leftover from the primary phase
- True conflict PVCs (rogue workloads deployed by a user on the secondary) would NOT appear in `Status.ProtectedPVCs`
- The PVC will be cleaned up by the application lifecycle manager (ACM/Fleet/ArgoCD) or by the DRPC's cleanup logic

## Affected Code Paths

| File | Function | Line | Role |
|------|----------|------|------|
| `internal/controller/vrg_volsync.go` | `validateSecondaryPVCConflictForVolsync()` | 1013 | **Bug location** — false positive conflict detection |
| `internal/controller/vrg_volsync.go` | `aggregateVolSyncClusterDataConflictCondition()` | 1039 | Sets `NoClusterDataConflict=False` based on validation |
| `internal/controller/volumereplicationgroup_controller.go` | `updateVRGConditions()` | 2090 | Calls conflict aggregation during status update |
| `internal/controller/drplacementcontrol_controller.go` | `findConflictCondition()` | 1489 | Scans all VRGs for conflict — picks up false positive |
| `internal/controller/protected_condition.go` | `updateVRGNoClusterDataConflict()` | 187 | Blocks DRPC Protected condition |
| `internal/controller/drplacementcontrolvolsync.go` | `refreshVRGSecondarySpec()` | 323 | Sets progression to `SettingUpVolSyncDest` |
