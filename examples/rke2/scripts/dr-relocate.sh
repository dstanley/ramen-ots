#!/bin/bash
# Trigger a Relocate (Failback) operation
# Usage: ./dr-relocate.sh [target-cluster]
#
# This script triggers a Relocate (planned failback) to the specified target cluster.
# Relocate ensures a final sync is performed before moving the workload.
#
# IMPORTANT: During Relocate, the app must be stopped on the source cluster
# BEFORE final sync can complete. If using manual ManifestWorks, you must
# either use the app-controller.sh or manually delete the app ManifestWork.

set -e

NAMESPACE="${DR_NAMESPACE:-ramen-test}"
DRPC_NAME="${DRPC_NAME:-rto-rpo-test-drpc}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
TARGET_CLUSTER="${1:-}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() { echo -e "${GREEN}[$(date -u +%Y-%m-%dT%H:%M:%SZ)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date -u +%Y-%m-%dT%H:%M:%SZ)]${NC} $1"; }
error() { echo -e "${RED}[$(date -u +%Y-%m-%dT%H:%M:%SZ)]${NC} $1"; }

# Get current state
get_drpc_status() {
    kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
        -o jsonpath='{"phase":"}{.status.phase}{"\", \"progression\":\"}{.status.progression}{"\", \"cluster\":\"}{.status.preferredDecision.clusterName}{"\""}' 2>/dev/null
}

get_current_cluster() {
    kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.preferredDecision.clusterName}' 2>/dev/null
}

get_available_clusters() {
    kubectl --context "$HUB_CONTEXT" get drpolicy -o jsonpath='{.items[0].spec.drClusters[*]}' 2>/dev/null
}

# Show usage
usage() {
    echo "Usage: $0 [target-cluster]"
    echo ""
    echo "Triggers a Relocate (planned failback) to the specified cluster."
    echo ""
    echo "Environment variables:"
    echo "  DR_NAMESPACE   Namespace containing DRPC (default: ramen-test)"
    echo "  DRPC_NAME      Name of DRPlacementControl (default: rto-rpo-test-drpc)"
    echo "  HUB_CONTEXT    Kubectl context for hub cluster (default: rke2)"
    echo ""
    echo "Available clusters: $(get_available_clusters)"
    echo "Current cluster: $(get_current_cluster)"
    echo ""
    echo "NOTE: If using manual ManifestWorks, ensure app-controller.sh is running"
    echo "      to handle app quiescing during final sync."
}

# Main
if [[ "$1" == "-h" || "$1" == "--help" ]]; then
    usage
    exit 0
fi

CURRENT_CLUSTER=$(get_current_cluster)
AVAILABLE_CLUSTERS=$(get_available_clusters)

if [[ -z "$TARGET_CLUSTER" ]]; then
    # Auto-select the other cluster
    for cluster in $AVAILABLE_CLUSTERS; do
        if [[ "$cluster" != "$CURRENT_CLUSTER" ]]; then
            TARGET_CLUSTER="$cluster"
            break
        fi
    done
fi

if [[ -z "$TARGET_CLUSTER" ]]; then
    error "Could not determine target cluster"
    usage
    exit 1
fi

if [[ "$TARGET_CLUSTER" == "$CURRENT_CLUSTER" ]]; then
    error "Target cluster '$TARGET_CLUSTER' is already the current cluster"
    exit 1
fi

log "=== Triggering Relocate (Planned Failback) ==="
log "DRPC: $DRPC_NAME"
log "Namespace: $NAMESPACE"
log "Current cluster: $CURRENT_CLUSTER"
log "Target cluster: $TARGET_CLUSTER"
echo ""
warn "NOTE: Relocate performs a final sync before moving the workload."
warn "      The app on $CURRENT_CLUSTER must be stopped for final sync to complete."
echo ""

# Confirm
read -p "Proceed with Relocate to $TARGET_CLUSTER? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Aborted"
    exit 0
fi

# Record start time
START_TIME=$(date +%s)
log "Relocate initiated at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Trigger relocate
kubectl --context "$HUB_CONTEXT" patch drpc "$DRPC_NAME" -n "$NAMESPACE" --type=merge \
    -p "{\"spec\":{\"action\":\"Relocate\",\"preferredCluster\":\"$TARGET_CLUSTER\"}}"

log "DRPC patched, monitoring progress..."
echo ""

# Monitor progress
LAST_STATUS=""
WARNED_FINAL_SYNC=false
while true; do
    STATUS=$(get_drpc_status)

    if [[ "$STATUS" != "$LAST_STATUS" ]]; then
        log "Status: $STATUS"
        LAST_STATUS="$STATUS"
    fi

    # Check phases
    PHASE=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    PROGRESSION=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.progression}' 2>/dev/null)

    # Warn about final sync
    if [[ "$PROGRESSION" == "RunningFinalSync" && "$WARNED_FINAL_SYNC" == "false" ]]; then
        echo ""
        warn "=== Final Sync in Progress ==="
        warn "If this seems stuck, ensure the app on $CURRENT_CLUSTER is stopped."
        warn "The PVC must be unmounted for final sync to complete."
        echo ""
        WARNED_FINAL_SYNC=true
    fi

    # Check if complete
    if [[ "$PHASE" == "Relocated" && ("$PROGRESSION" == "Completed" || "$PROGRESSION" == "SettingUpVolSyncDest") ]]; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        echo ""
        log "=== Relocate Complete ==="
        log "Duration: ${DURATION}s"
        log "App now running on: $TARGET_CLUSTER"
        break
    fi

    sleep 5
done
