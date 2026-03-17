#!/bin/bash
# Trigger a Failover operation
# Usage: ./dr-failover.sh [target-cluster]
#
# This script triggers a Failover from the current primary to the specified target cluster.
# Failover is used for unplanned disaster recovery (primary is down or unreachable).

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
    echo "Triggers a Failover to the specified cluster."
    echo ""
    echo "Environment variables:"
    echo "  DR_NAMESPACE   Namespace containing DRPC (default: ramen-test)"
    echo "  DRPC_NAME      Name of DRPlacementControl (default: rto-rpo-test-drpc)"
    echo "  HUB_CONTEXT    Kubectl context for hub cluster (default: rke2)"
    echo ""
    echo "Available clusters: $(get_available_clusters)"
    echo "Current cluster: $(get_current_cluster)"
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

log "=== Triggering Failover ==="
log "DRPC: $DRPC_NAME"
log "Namespace: $NAMESPACE"
log "Current cluster: $CURRENT_CLUSTER"
log "Target cluster: $TARGET_CLUSTER"
echo ""

# Confirm
read -p "Proceed with Failover to $TARGET_CLUSTER? (y/N) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log "Aborted"
    exit 0
fi

# Record start time
START_TIME=$(date +%s)
log "Failover initiated at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Trigger failover
kubectl --context "$HUB_CONTEXT" patch drpc "$DRPC_NAME" -n "$NAMESPACE" --type=merge \
    -p "{\"spec\":{\"action\":\"Failover\",\"failoverCluster\":\"$TARGET_CLUSTER\"}}"

log "DRPC patched, monitoring progress..."
echo ""

# Monitor progress
LAST_STATUS=""
while true; do
    STATUS=$(get_drpc_status)

    if [[ "$STATUS" != "$LAST_STATUS" ]]; then
        log "Status: $STATUS"
        LAST_STATUS="$STATUS"
    fi

    # Check if complete
    PHASE=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
    PROGRESSION=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" -o jsonpath='{.status.progression}' 2>/dev/null)

    if [[ "$PHASE" == "FailedOver" && "$PROGRESSION" == "Completed" ]]; then
        END_TIME=$(date +%s)
        DURATION=$((END_TIME - START_TIME))
        echo ""
        log "=== Failover Complete ==="
        log "Duration: ${DURATION}s"
        log "App now running on: $TARGET_CLUSTER"
        break
    fi

    sleep 5
done
