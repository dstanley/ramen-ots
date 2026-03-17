#!/bin/bash
# Show DR status
# Usage: ./dr-status.sh [-w]
#
# Options:
#   -w    Watch mode (continuous updates)

set -e

NAMESPACE="${DR_NAMESPACE:-ramen-test}"
DRPC_NAME="${DRPC_NAME:-rto-rpo-test-drpc}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
WATCH_MODE=false

if [[ "$1" == "-w" || "$1" == "--watch" ]]; then
    WATCH_MODE=true
fi

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

time_ago() {
    local ts="$1"
    [[ -z "$ts" || "$ts" == "-" ]] && return
    local sync_epoch now_epoch delta_s
    # macOS date -jf or GNU date -d
    if date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s &>/dev/null; then
        sync_epoch=$(date -u -jf "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null)
    else
        sync_epoch=$(date -u -d "$ts" +%s 2>/dev/null)
    fi
    [[ -z "$sync_epoch" ]] && return
    now_epoch=$(date -u +%s)
    delta_s=$((now_epoch - sync_epoch))
    if (( delta_s < 0 )); then
        echo "(just now)"
    elif (( delta_s < 60 )); then
        echo "(${delta_s}s ago)"
    elif (( delta_s < 3600 )); then
        echo "($(( delta_s / 60 ))m $(( delta_s % 60 ))s ago)"
    elif (( delta_s < 86400 )); then
        echo "($(( delta_s / 3600 ))h $(( (delta_s % 3600) / 60 ))m ago)"
    else
        echo "($(( delta_s / 86400 ))d $(( (delta_s % 86400) / 3600 ))h ago)"
    fi
}

show_status() {
    clear 2>/dev/null || true
    echo -e "${BLUE}=== DR Status ===${NC}"
    echo "Time: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""

    # DRPC Status
    echo -e "${BLUE}DRPC: $DRPC_NAME${NC}"
    DRPC_JSON=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" -o json 2>/dev/null)
    if [[ -n "$DRPC_JSON" ]]; then
        PHASE=$(echo "$DRPC_JSON" | jq -r '.status.phase // "Unknown"')
        PROGRESSION=$(echo "$DRPC_JSON" | jq -r '.status.progression // "Unknown"')
        CLUSTER=$(echo "$DRPC_JSON" | jq -r '.status.preferredDecision.clusterName // "None"')
        ACTION=$(echo "$DRPC_JSON" | jq -r '.spec.action // "None"')
        PROTECTED=$(echo "$DRPC_JSON" | jq -r '.status.conditions[] | select(.type=="Protected") | .status' 2>/dev/null || echo "Unknown")

        echo "  Phase: $PHASE"
        echo "  Progression: $PROGRESSION"
        echo "  Current Cluster: $CLUSTER"
        echo "  Action: $ACTION"
        echo "  Protected: $PROTECTED"
    else
        echo -e "  ${RED}Not found${NC}"
    fi
    echo ""

    # PlacementDecision
    echo -e "${BLUE}PlacementDecision:${NC}"
    PLACEMENT=$(kubectl --context "$HUB_CONTEXT" get placementdecision -n "$NAMESPACE" \
        -l cluster.open-cluster-management.io/placement -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null)
    echo "  Decision: ${PLACEMENT:-None}"
    echo ""

    # VRG Status on both clusters
    echo -e "${BLUE}VRG Status:${NC}"
    for cluster in harv marv; do
        VRG_STATUS=$(kubectl --context "$cluster" get vrg -n "$NAMESPACE" -o jsonpath='{.items[0].spec.replicationState}' 2>/dev/null || echo "NotFound")
        VRG_READY=$(kubectl --context "$cluster" get vrg -n "$NAMESPACE" -o jsonpath='{.items[0].status.conditions[?(@.type=="ClusterDataReady")].status}' 2>/dev/null || echo "-")
        echo "  $cluster: ReplicationState=$VRG_STATUS, DataReady=$VRG_READY"
    done
    echo ""

    # VolSync Status
    echo -e "${BLUE}VolSync Replication:${NC}"
    for cluster in harv marv; do
        RS=$(kubectl --context "$cluster" get replicationsource -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        RD=$(kubectl --context "$cluster" get replicationdestination -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$RS" ]]; then
            LAST_SYNC=$(kubectl --context "$cluster" get replicationsource "$RS" -n "$NAMESPACE" -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo "-")
            AGO=$(time_ago "$LAST_SYNC")
            echo "  $cluster: ReplicationSource ($RS), LastSync: ${AGO:-$LAST_SYNC} [$LAST_SYNC]"
        fi
        if [[ -n "$RD" ]]; then
            LAST_SYNC=$(kubectl --context "$cluster" get replicationdestination "$RD" -n "$NAMESPACE" -o jsonpath='{.status.lastSyncTime}' 2>/dev/null || echo "-")
            AGO=$(time_ago "$LAST_SYNC")
            echo "  $cluster: ReplicationDestination ($RD), LastSync: ${AGO:-$LAST_SYNC} [$LAST_SYNC]"
        fi
        if [[ -z "$RS" && -z "$RD" ]]; then
            echo "  $cluster: No VolSync resources"
        fi
    done
    echo ""

    # App Status
    echo -e "${BLUE}Application Pods:${NC}"
    for cluster in harv marv; do
        POD_STATUS=$(kubectl --context "$cluster" get pods -n "$NAMESPACE" -l app=rto-rpo-test --no-headers 2>/dev/null | awk '{print $1 " (" $3 ")"}' || echo "")
        if [[ -n "$POD_STATUS" ]]; then
            echo -e "  $cluster: ${GREEN}$POD_STATUS${NC}"
        else
            echo "  $cluster: No pods"
        fi
    done
    echo ""

    # PVC Status
    echo -e "${BLUE}PVC Status:${NC}"
    for cluster in harv marv; do
        PVC_STATUS=$(kubectl --context "$cluster" get pvc rto-rpo-data -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $2 " (" $4 ")"}' || echo "NotFound")
        echo "  $cluster: $PVC_STATUS"
    done
}

if [[ "$WATCH_MODE" == "true" ]]; then
    while true; do
        show_status
        sleep 5
    done
else
    show_status
fi
