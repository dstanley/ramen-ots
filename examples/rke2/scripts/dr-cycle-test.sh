#!/bin/bash
# DR Cycle Test — continuously alternates failover and relocate operations
# to soak-test the full DR stack (Ramen, OTS controller, Fleet, VolSync).
#
# Usage: ./dr-cycle-test.sh [options]
#
# Options:
#   --interval <seconds>   Wait time between operations (default: 300)
#   --cycles <n>           Number of cycles to run, 0=unlimited (default: 0)
#   --wait-protected       Wait for Protected=True before next op (default: true)
#   --no-wait-protected    Only wait for Completed, skip Protected wait
#   --cluster-a <name>     First cluster (default: harv)
#   --cluster-b <name>     Second cluster (default: marv)
#   --model <type>         Deployment model: fleet, argocd, manifestwork (default: fleet)
#
# Each cycle performs:
#   1. Failover from current cluster to the other
#   2. Wait for completion + optional Protected=True
#   3. Sleep for interval
#   4. Relocate back
#   5. Wait for completion + optional Protected=True
#   6. Sleep for interval
#
# Press Ctrl+C to stop gracefully after the current operation completes.

set -euo pipefail

NAMESPACE="${DR_NAMESPACE:-ramen-test}"
DRPC_NAME="${DRPC_NAME:-rto-rpo-test-drpc}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
APP_NAME="${APP_NAME:-rto-rpo-test}"

# Defaults
INTERVAL=300
MAX_CYCLES=0
WAIT_PROTECTED=true
CLUSTER_A="harv"
CLUSTER_B="marv"
DEPLOYMENT_MODEL="fleet"
SETTLE_TIMEOUT=600

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn()   { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }
error()  { echo -e "${RED}[$(date +%H:%M:%S)]${NC} $1"; }
info()   { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
header() { echo -e "\n${BLUE}${BOLD}=== $1 ===${NC}\n"; }

# Track results
TOTAL_OPS=0
SUCCESSFUL_OPS=0
FAILED_OPS=0
declare -a OP_RESULTS=()

STOP_REQUESTED=false
trap 'STOP_REQUESTED=true; warn "Stop requested, finishing current operation..."' INT TERM

# --- Argument parsing ---

while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval)     INTERVAL="$2"; shift 2 ;;
        --cycles)       MAX_CYCLES="$2"; shift 2 ;;
        --wait-protected)    WAIT_PROTECTED=true; shift ;;
        --no-wait-protected) WAIT_PROTECTED=false; shift ;;
        --cluster-a)    CLUSTER_A="$2"; shift 2 ;;
        --cluster-b)    CLUSTER_B="$2"; shift 2 ;;
        --model)        DEPLOYMENT_MODEL="$2"; shift 2 ;;
        --timeout)      SETTLE_TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            head -27 "$0" | tail -25
            exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Helper functions ---

get_drpc_json() {
    kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" -o json 2>/dev/null
}

get_drpc_field() {
    local field="$1"
    echo "$DRPC_JSON" | jq -r "$field // \"\"" 2>/dev/null
}

get_condition() {
    local type="$1"
    echo "$DRPC_JSON" | jq -r ".status.conditions[] | select(.type==\"$type\") | .status" 2>/dev/null || echo ""
}

get_current_cluster() {
    kubectl --context "$HUB_CONTEXT" get placementdecision -n "$NAMESPACE" \
        -l cluster.open-cluster-management.io/placement \
        -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null || echo ""
}

get_fleet_labels() {
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n fleet-default \
        -o custom-columns='DISPLAY:.metadata.labels.management\.cattle\.io/cluster-display-name,DR:.metadata.labels.ramen\.dr/fleet-enabled' \
        --no-headers 2>/dev/null
}

app_running_on() {
    local cluster="$1"
    kubectl --context "$cluster" get pod -n "$NAMESPACE" -l app="$APP_NAME" 2>/dev/null | grep -q Running
}

# Wait for DRPC to reach a target phase with optional Protected=True
# Returns 0 on success, 1 on timeout
wait_for_settle() {
    local target_phase="$1"
    local op_name="$2"
    local start=$SECONDS
    local last_status=""

    while true; do
        local elapsed=$(( SECONDS - start ))
        if (( elapsed > SETTLE_TIMEOUT )); then
            error "Timeout after ${elapsed}s waiting for $op_name to settle"
            return 1
        fi

        DRPC_JSON=$(get_drpc_json)
        local phase=$(get_drpc_field '.status.phase')
        local progression=$(get_drpc_field '.status.progression')
        local available=$(get_condition "Available")
        local peer_ready=$(get_condition "PeerReady")
        local protected=$(get_condition "Protected")

        local status="${phase}/${progression} Avail=${available} Peer=${peer_ready} Prot=${protected}"
        if [[ "$status" != "$last_status" ]]; then
            info "  ${status} (${elapsed}s)"
            last_status="$status"
        fi

        # Check completion
        if [[ "$phase" == "$target_phase" && "$progression" == "Completed" ]]; then
            if [[ "$WAIT_PROTECTED" == "true" ]]; then
                if [[ "$peer_ready" == "True" && "$protected" == "True" ]]; then
                    return 0
                fi
            else
                if [[ "$peer_ready" == "True" ]]; then
                    return 0
                fi
            fi
        fi

        if [[ "$STOP_REQUESTED" == "true" ]]; then
            warn "Stop requested during wait"
            return 2
        fi

        sleep 5
    done
}

do_failover() {
    local target="$1"

    kubectl --context "$HUB_CONTEXT" patch drpc "$DRPC_NAME" -n "$NAMESPACE" --type=merge \
        -p "{\"spec\":{\"action\":\"Failover\",\"failoverCluster\":\"$target\"}}" >/dev/null

    wait_for_settle "FailedOver" "failover"
}

do_relocate() {
    local target="$1"

    kubectl --context "$HUB_CONTEXT" patch drpc "$DRPC_NAME" -n "$NAMESPACE" --type=merge \
        -p "{\"spec\":{\"action\":\"Relocate\",\"preferredCluster\":\"$target\"}}" >/dev/null

    wait_for_settle "Relocated" "relocate"
}

# Verify the operation result: app on target, Fleet labels correct
# Retries app check for up to 90s since Fleet/ArgoCD need time to deploy
verify_state() {
    local target="$1"
    local issues=0

    # Check Fleet labels first (if fleet model) — should be immediate
    if [[ "$DEPLOYMENT_MODEL" == "fleet" ]]; then
        local labeled
        labeled=$(get_fleet_labels | awk -v t="$target" '$1==t {print $2}')
        if [[ "$labeled" == "true" ]]; then
            log "  Fleet label correct on $target"
        else
            warn "  Fleet label NOT set on $target"
            ((issues++)) || true
        fi
    fi

    # Wait for app pod — Fleet/ArgoCD needs time to deploy after label change
    local app_ok=false
    info "  Waiting for app pod on $target..."
    for i in $(seq 1 18); do
        if app_running_on "$target"; then
            app_ok=true
            break
        fi
        sleep 5
    done

    if [[ "$app_ok" == "true" ]]; then
        log "  App running on $target"
    else
        warn "  App NOT running on $target after 90s"
        ((issues++)) || true
    fi

    return "$issues"
}

record_result() {
    local op="$1" target="$2" duration="$3" result="$4"
    TOTAL_OPS=$((TOTAL_OPS + 1))
    if [[ "$result" == "OK" ]]; then
        SUCCESSFUL_OPS=$((SUCCESSFUL_OPS + 1))
    else
        FAILED_OPS=$((FAILED_OPS + 1))
    fi
    OP_RESULTS+=("$(printf "%-4s %-12s -> %-6s %4ss  %s" "$TOTAL_OPS" "$op" "$target" "$duration" "$result")")
}

print_summary() {
    header "Cycle Test Summary"
    echo -e "${BOLD}#    Operation    Target  Time   Result${NC}"
    echo "---- ------------ ------- ------ ------"
    for r in "${OP_RESULTS[@]}"; do
        if [[ "$r" == *"FAIL"* ]]; then
            echo -e "${RED}${r}${NC}"
        else
            echo -e "${GREEN}${r}${NC}"
        fi
    done
    echo ""
    echo "Total: $TOTAL_OPS  Passed: $SUCCESSFUL_OPS  Failed: $FAILED_OPS"
    if (( FAILED_OPS > 0 )); then
        echo -e "${RED}Some operations failed.${NC}"
    else
        echo -e "${GREEN}All operations passed.${NC}"
    fi
}

interruptible_sleep() {
    local duration="$1"
    local elapsed=0
    while (( elapsed < duration )); do
        if [[ "$STOP_REQUESTED" == "true" ]]; then
            return 1
        fi
        sleep 1
        ((elapsed++))
    done
    return 0
}

# --- Main ---

header "DR Cycle Test"
info "Clusters: $CLUSTER_A <-> $CLUSTER_B"
info "Interval: ${INTERVAL}s between operations"
info "Wait for Protected: $WAIT_PROTECTED"
info "Max cycles: $([ "$MAX_CYCLES" -eq 0 ] && echo "unlimited" || echo "$MAX_CYCLES")"
info "Settle timeout: ${SETTLE_TIMEOUT}s"
info "Model: $DEPLOYMENT_MODEL"
echo ""

# Determine starting state
CURRENT=$(get_current_cluster)
if [[ -z "$CURRENT" ]]; then
    error "No current PlacementDecision found. Is the app deployed?"
    exit 1
fi
log "Current active cluster: $CURRENT"

# Determine cycle direction
if [[ "$CURRENT" == "$CLUSTER_A" ]]; then
    NEXT_TARGET="$CLUSTER_B"
else
    NEXT_TARGET="$CLUSTER_A"
fi

CYCLE=0
while true; do
    CYCLE=$((CYCLE + 1))
    if (( MAX_CYCLES > 0 && CYCLE > MAX_CYCLES )); then
        log "Reached max cycles ($MAX_CYCLES)"
        break
    fi

    if [[ "$STOP_REQUESTED" == "true" ]]; then
        break
    fi

    header "Cycle $CYCLE — Failover to $NEXT_TARGET"
    OP_START=$SECONDS

    if do_failover "$NEXT_TARGET"; then
        OP_DURATION=$(( SECONDS - OP_START ))
        if verify_state "$NEXT_TARGET"; then
            record_result "Failover" "$NEXT_TARGET" "$OP_DURATION" "OK"
            log "Failover to $NEXT_TARGET completed in ${OP_DURATION}s"
        else
            record_result "Failover" "$NEXT_TARGET" "$OP_DURATION" "FAIL(verify)"
            warn "Failover completed but verification found issues"
        fi
    else
        OP_DURATION=$(( SECONDS - OP_START ))
        record_result "Failover" "$NEXT_TARGET" "$OP_DURATION" "FAIL(timeout)"
        error "Failover to $NEXT_TARGET timed out after ${OP_DURATION}s"
    fi

    FAILOVER_TARGET="$NEXT_TARGET"
    # Swap for relocate back
    if [[ "$NEXT_TARGET" == "$CLUSTER_A" ]]; then
        NEXT_TARGET="$CLUSTER_B"
    else
        NEXT_TARGET="$CLUSTER_A"
    fi

    if [[ "$STOP_REQUESTED" == "true" ]]; then
        break
    fi

    # Wait between operations
    info "Waiting ${INTERVAL}s before relocate..."
    if ! interruptible_sleep "$INTERVAL"; then
        break
    fi

    header "Cycle $CYCLE — Relocate to $NEXT_TARGET"
    OP_START=$SECONDS

    if do_relocate "$NEXT_TARGET"; then
        OP_DURATION=$(( SECONDS - OP_START ))
        if verify_state "$NEXT_TARGET"; then
            record_result "Relocate" "$NEXT_TARGET" "$OP_DURATION" "OK"
            log "Relocate to $NEXT_TARGET completed in ${OP_DURATION}s"
        else
            record_result "Relocate" "$NEXT_TARGET" "$OP_DURATION" "FAIL(verify)"
            warn "Relocate completed but verification found issues"
        fi
    else
        OP_DURATION=$(( SECONDS - OP_START ))
        record_result "Relocate" "$NEXT_TARGET" "$OP_DURATION" "FAIL(timeout)"
        error "Relocate to $NEXT_TARGET timed out after ${OP_DURATION}s"
    fi

    RELOCATE_TARGET="$NEXT_TARGET"
    # Swap for next failover
    if [[ "$NEXT_TARGET" == "$CLUSTER_A" ]]; then
        NEXT_TARGET="$CLUSTER_B"
    else
        NEXT_TARGET="$CLUSTER_A"
    fi

    if [[ "$STOP_REQUESTED" == "true" ]]; then
        break
    fi

    # Wait between cycles
    info "Waiting ${INTERVAL}s before next cycle..."
    if ! interruptible_sleep "$INTERVAL"; then
        break
    fi
done

print_summary
