#!/bin/bash
# Fleet DR Controller
# Usage: ./fleet-dr-controller.sh
#
# This controller watches PlacementDecision changes and manages Fleet cluster
# labels to enable automatic application failover with Fleet GitRepo targeting.
#
# How it works:
# 1. Watches PlacementDecision for the specified placement
# 2. When the decision changes, updates the ramen.dr/fleet-enabled label on
#    Fleet Cluster resources in the fleet-default namespace
# 3. Fleet GitRepo (using clusterSelector) automatically deploys to labeled clusters
#
# Fleet clusters use auto-generated IDs (e.g., c-npk9v) rather than friendly names.
# This controller resolves managed cluster names (harv, marv) to Fleet cluster IDs
# using the management.cattle.io/cluster-display-name label.

set -e

NAMESPACE="${DR_NAMESPACE:-ramen-test}"
PLACEMENT_NAME="${PLACEMENT_NAME:-rto-rpo-test-placement}"
DRPC_NAME="${DRPC_NAME:-rto-rpo-test-drpc}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
LABEL_KEY="${LABEL_KEY:-ramen.dr/fleet-enabled}"
FLEET_NAMESPACE="${FLEET_NAMESPACE:-fleet-default}"
LOG_FILE="/tmp/fleet-dr-controller.log"

LAST_CLUSTER=""
LAST_DRPC_PHASE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
    echo -e "${GREEN}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

warn() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
    echo -e "${YELLOW}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

error() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
    echo -e "${RED}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

info() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1"
    echo -e "${CYAN}$msg${NC}"
    echo "$msg" >> "$LOG_FILE"
}

check_ok() { echo -e "  ${GREEN}OK${NC}  $1"; }
check_fail() { echo -e "  ${RED}FAIL${NC}  $1"; }
check_warn() { echo -e "  ${YELLOW}WARN${NC}  $1"; }

# --- Preflight checks ---

preflight_checks() {
    echo ""
    log "=== Preflight Checks ==="
    local failed=0

    # Hub connectivity
    if kubectl --context "$HUB_CONTEXT" get nodes &>/dev/null; then
        check_ok "Hub cluster reachable (context: $HUB_CONTEXT)"
    else
        check_fail "Hub cluster unreachable (context: $HUB_CONTEXT)"
        failed=1
    fi

    # OTS controller
    local ots_pod
    ots_pod=$(kubectl --context "$HUB_CONTEXT" get pods -n ramen-ots-system -l app=ramen-ots-controller \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$ots_pod" == "Running" ]]; then
        check_ok "OTS controller running"
    else
        check_fail "OTS controller not running in ramen-ots-system"
        failed=1
    fi

    # ManagedClusters
    local clusters
    clusters=$(kubectl --context "$HUB_CONTEXT" get managedcluster -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || echo "")
    if [[ -n "$clusters" ]]; then
        for cname in $clusters; do
            check_ok "ManagedCluster $cname"
        done
    else
        check_fail "No ManagedClusters found"
        failed=1
    fi

    # Fleet clusters
    local fleet_clusters
    fleet_clusters=$(kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.labels.management\.cattle\.io/cluster-display-name}{" "}{end}' 2>/dev/null || echo "")
    if [[ -n "$fleet_clusters" ]]; then
        for entry in $fleet_clusters; do
            local fid="${entry%%=*}"
            local fname="${entry#*=}"
            local ready
            ready=$(kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io "$fid" -n "$FLEET_NAMESPACE" \
                -o jsonpath='{.status.display.readyBundles}' 2>/dev/null || echo "?/?")
            check_ok "Fleet cluster $fid ($fname) bundles: $ready"
        done
    else
        check_fail "No Fleet clusters found in $FLEET_NAMESPACE"
        failed=1
    fi

    # Fleet GitRepo
    local gitrepo_name
    gitrepo_name=$(kubectl --context "$HUB_CONTEXT" get gitrepo -n "$FLEET_NAMESPACE" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$gitrepo_name" ]]; then
        local gitrepo_ready
        gitrepo_ready=$(kubectl --context "$HUB_CONTEXT" get gitrepo "$gitrepo_name" -n "$FLEET_NAMESPACE" \
            -o jsonpath='{.status.display.readyBundleDeployments}' 2>/dev/null || echo "?/?")
        check_ok "Fleet GitRepo '$gitrepo_name' (deployments: $gitrepo_ready)"
    else
        check_warn "No Fleet GitRepo found in $FLEET_NAMESPACE"
    fi

    # Submariner
    if kubectl --context "$HUB_CONTEXT" get crd serviceexports.multicluster.x-k8s.io &>/dev/null; then
        check_ok "Submariner CRDs present"
    else
        check_warn "Submariner not detected (cross-cluster VolSync may not work)"
    fi

    # DRPolicy
    local drpolicy
    drpolicy=$(kubectl --context "$HUB_CONTEXT" get drpolicy -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$drpolicy" ]]; then
        local dr_clusters
        dr_clusters=$(kubectl --context "$HUB_CONTEXT" get drpolicy "$drpolicy" \
            -o jsonpath='{.spec.drClusters[*]}' 2>/dev/null || echo "")
        local sched
        sched=$(kubectl --context "$HUB_CONTEXT" get drpolicy "$drpolicy" \
            -o jsonpath='{.spec.schedulingInterval}' 2>/dev/null || echo "?")
        check_ok "DRPolicy '$drpolicy' clusters=[$dr_clusters] interval=$sched"
    else
        check_warn "No DRPolicy found"
    fi

    # Ramen hub operator
    local hub_pod
    hub_pod=$(kubectl --context "$HUB_CONTEXT" get pods -n ramen-system -l app=ramen-hub \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$hub_pod" == "Running" ]]; then
        check_ok "Ramen hub operator running"
    else
        check_fail "Ramen hub operator not running"
        failed=1
    fi

    echo ""
    if [[ $failed -eq 1 ]]; then
        error "Preflight checks failed - resolve issues before continuing"
        exit 1
    fi
    log "All preflight checks passed"
    echo ""
}

# --- Cluster resolution ---

# Resolve managed cluster name (e.g., harv) to Fleet cluster ID (e.g., c-npk9v)
resolve_fleet_cluster_id() {
    local display_name=$1
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -l "management.cattle.io/cluster-display-name=$display_name" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# Get display name for a Fleet cluster ID
get_display_name() {
    local fleet_id=$1
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io "$fleet_id" \
        -n "$FLEET_NAMESPACE" \
        -o jsonpath='{.metadata.labels.management\.cattle\.io/cluster-display-name}' 2>/dev/null || echo "$fleet_id"
}

get_current_placement() {
    # During failover, PlacementDecision may contain two entries:
    # one with reason "RetainedForFailover" (old cluster) and the active target.
    # We need the non-retained cluster (the active placement target).
    local decisions
    decisions=$(kubectl --context "$HUB_CONTEXT" get placementdecision -n "$NAMESPACE" \
        -l cluster.open-cluster-management.io/placement="$PLACEMENT_NAME" \
        -o jsonpath='{range .items[0].status.decisions[*]}{.clusterName},{.reason}{"\n"}{end}' 2>/dev/null) || echo ""

    if [[ -z "$decisions" ]]; then
        echo ""
        return
    fi

    # Find the first decision that is NOT RetainedForFailover
    local active=""
    local first=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name="${line%%,*}"
        local reason="${line#*,}"
        [[ -z "$first" ]] && first="$name"
        if [[ "$reason" != "RetainedForFailover" ]]; then
            active="$name"
            break
        fi
    done <<< "$decisions"

    # If all are retained (shouldn't happen), fall back to first
    echo "${active:-$first}"
}

# --- DRPC and status helpers ---

get_drpc_status() {
    kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
        -o jsonpath='phase={.status.phase} action={.spec.action} progression={.status.progression}' 2>/dev/null || echo ""
}

get_drpc_phase() {
    kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo ""
}

get_drpc_conditions() {
    kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
        -o jsonpath='{range .status.conditions[*]}  {.type}: {.status} ({.reason}) {.message}{"\n"}{end}' 2>/dev/null || echo ""
}

show_vrg_status() {
    local cluster=$1
    local vrg_state
    vrg_state=$(kubectl --context "$HUB_CONTEXT" get managedclusterview "$DRPC_NAME" -n "$cluster" \
        -o jsonpath='{.status.result.spec.replicationState}/{.status.result.status.state}' 2>/dev/null || echo "")
    if [[ -n "$vrg_state" ]]; then
        info "  VRG on $cluster: $vrg_state"
    fi
}

show_fleet_status() {
    echo ""
    info "Fleet cluster state:"
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -o custom-columns='FLEET_ID:.metadata.name,DISPLAY:.metadata.labels.management\.cattle\.io/cluster-display-name,DR_ENABLED:.metadata.labels.ramen\.dr/fleet-enabled,BUNDLES:.status.display.readyBundles' 2>/dev/null || true

    # Show BundleDeployments if any
    local bd_count
    bd_count=$(kubectl --context "$HUB_CONTEXT" get bundledeployments -n "$FLEET_NAMESPACE" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$bd_count" -gt 0 ]]; then
        echo ""
        info "BundleDeployments:"
        kubectl --context "$HUB_CONTEXT" get bundledeployments -n "$FLEET_NAMESPACE" \
            -o custom-columns='NAME:.metadata.name,READY:.status.display.ready,STATE:.status.display.state' 2>/dev/null || true
    fi
    echo ""
}

show_drpc_summary() {
    local drpc_status
    drpc_status=$(get_drpc_status)
    if [[ -n "$drpc_status" ]]; then
        info "DRPC: $drpc_status"
    fi
    local conditions
    conditions=$(get_drpc_conditions)
    if [[ -n "$conditions" ]]; then
        echo -e "${DIM}$conditions${NC}"
    fi
}

# Wait for DR operation to fully settle, then print an all-clear summary.
# Checks: DRPC progression=Completed, PeerReady=True, Protected=True, and
# Fleet bundles ready on the target cluster.
wait_for_settle() {
    local operation=$1   # "Failover" or "Relocate"
    local target=$2      # target cluster name

    local max_wait=300   # 5 minutes
    local interval=5
    local elapsed=0

    info "Waiting for $operation to fully settle..."

    while [[ $elapsed -lt $max_wait ]]; do
        local progression peer_ready protected
        progression=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.progression}' 2>/dev/null || echo "")
        peer_ready=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="PeerReady")].status}' 2>/dev/null || echo "")
        protected=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
            -o jsonpath='{.status.conditions[?(@.type=="Protected")].status}' 2>/dev/null || echo "")

        # Check Fleet bundles on target
        local bundles_ok="false"
        if [[ -n "$target" ]]; then
            local fleet_id
            fleet_id=$(resolve_fleet_cluster_id "$target")
            if [[ -n "$fleet_id" ]]; then
                local ready_bundles
                ready_bundles=$(kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io "$fleet_id" \
                    -n "$FLEET_NAMESPACE" -o jsonpath='{.status.display.readyBundles}' 2>/dev/null || echo "")
                if [[ -n "$ready_bundles" ]]; then
                    local ready="${ready_bundles%%/*}"
                    local desired="${ready_bundles##*/}"
                    if [[ "$ready" == "$desired" && "$desired" -gt 0 ]]; then
                        bundles_ok="true"
                    fi
                fi
            fi
        else
            bundles_ok="true"
        fi

        if [[ "$progression" == "Completed" && "$peer_ready" == "True" && "$protected" == "True" && "$bundles_ok" == "true" ]]; then
            echo ""
            log "=== $operation Complete - All Clear ==="
            # Gather RTO/RPO data
            local duration action_start last_sync sync_duration sched_interval
            duration=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
                -o jsonpath='{.status.actionDuration}' 2>/dev/null || echo "unknown")
            action_start=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
                -o jsonpath='{.status.actionStartTime}' 2>/dev/null || echo "")
            last_sync=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
                -o jsonpath='{.status.lastGroupSyncTime}' 2>/dev/null || echo "")
            sync_duration=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
                -o jsonpath='{.status.lastGroupSyncDuration}' 2>/dev/null || echo "")
            sched_interval=$(kubectl --context "$HUB_CONTEXT" get drpolicy \
                -o jsonpath='{.items[0].spec.schedulingInterval}' 2>/dev/null || echo "unknown")

            check_ok "Progression: Completed"
            check_ok "PeerReady:   True"
            check_ok "Protected:   True"
            if [[ -n "$target" ]]; then
                check_ok "Fleet:       $target bundles ready"
            fi
            echo ""
            info "RTO/RPO Summary:"
            check_ok "RTO (actual):        $duration"
            check_ok "RPO (sync interval): $sched_interval"
            if [[ -n "$last_sync" ]]; then
                check_ok "Last sync:           $last_sync (took $sync_duration)"
            fi
            if [[ -n "$action_start" ]]; then
                check_ok "Action started:      $action_start"
            fi
            echo ""
            show_fleet_status
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    warn "$operation did not fully settle within ${max_wait}s"
    show_drpc_summary
    show_fleet_status
    return 1
}

# --- Label management ---

get_all_fleet_clusters() {
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n'
}

get_labeled_fleet_cluster() {
    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -l "$LABEL_KEY=true" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

label_fleet_cluster() {
    local ocm_name=$1
    local fleet_id
    fleet_id=$(resolve_fleet_cluster_id "$ocm_name")

    if [[ -z "$fleet_id" ]]; then
        error "Cannot resolve Fleet cluster ID for managed cluster: $ocm_name"
        return 1
    fi

    log "Labeling Fleet cluster $fleet_id ($ocm_name) for deployment"
    kubectl --context "$HUB_CONTEXT" label clusters.fleet.cattle.io "$fleet_id" \
        -n "$FLEET_NAMESPACE" "$LABEL_KEY=true" --overwrite 2>/dev/null || true
}

unlabel_fleet_cluster() {
    local fleet_id=$1
    local display_name
    display_name=$(get_display_name "$fleet_id")

    log "Removing label from Fleet cluster $fleet_id ($display_name)"
    kubectl --context "$HUB_CONTEXT" label clusters.fleet.cattle.io "$fleet_id" \
        -n "$FLEET_NAMESPACE" "$LABEL_KEY-" 2>/dev/null || true
}

unlabel_all_fleet_clusters() {
    for fleet_id in $(get_all_fleet_clusters); do
        # Check if this cluster has the label before trying to remove
        local has_label
        has_label=$(kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io "$fleet_id" \
            -n "$FLEET_NAMESPACE" \
            -o jsonpath="{.metadata.labels.ramen\.dr/fleet-enabled}" 2>/dev/null || echo "")
        if [[ "$has_label" == "true" ]]; then
            unlabel_fleet_cluster "$fleet_id"
        fi
    done
}

sync_labels() {
    local target_cluster=$1

    if [[ -z "$target_cluster" ]]; then
        warn "PlacementDecision is empty - unlabeling all Fleet clusters"
        unlabel_all_fleet_clusters
        return
    fi

    local target_fleet_id
    target_fleet_id=$(resolve_fleet_cluster_id "$target_cluster")

    if [[ -z "$target_fleet_id" ]]; then
        error "Cannot resolve Fleet cluster ID for: $target_cluster"
        return 1
    fi

    local current_labeled
    current_labeled=$(get_labeled_fleet_cluster)

    if [[ "$current_labeled" == "$target_fleet_id" ]]; then
        return
    fi

    log "Syncing labels: $(get_display_name "$current_labeled") -> $target_cluster"

    # Remove label from all other clusters
    for fleet_id in $(get_all_fleet_clusters); do
        if [[ "$fleet_id" != "$target_fleet_id" ]]; then
            local has_label
            has_label=$(kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io "$fleet_id" \
                -n "$FLEET_NAMESPACE" \
                -o jsonpath="{.metadata.labels.ramen\.dr/fleet-enabled}" 2>/dev/null || echo "")
            if [[ "$has_label" == "true" ]]; then
                unlabel_fleet_cluster "$fleet_id"
            fi
        fi
    done

    # Add label to target cluster
    label_fleet_cluster "$target_cluster"
}

# --- Lifecycle ---

cleanup() {
    log "Shutting down Fleet DR controller..."
    exit 0
}

trap cleanup SIGINT SIGTERM

usage() {
    cat << EOF
Usage: $0 [options]

Options:
  --namespace NS        Namespace containing PlacementDecision (default: ramen-test)
  --placement NAME      Name of the Placement to watch (default: rto-rpo-test-placement)
  --drpc NAME           Name of DRPlacementControl to monitor (default: rto-rpo-test-drpc)
  --label KEY           Label key to use on Fleet Cluster resources (default: ramen.dr/fleet-enabled)
  --context CTX         Kubectl context for hub cluster (default: rke2)
  --skip-preflight      Skip preflight checks
  --help                Show this help

Environment Variables:
  DR_NAMESPACE          Same as --namespace
  PLACEMENT_NAME        Same as --placement
  DRPC_NAME             Same as --drpc
  LABEL_KEY             Same as --label
  HUB_CONTEXT           Same as --context
  FLEET_NAMESPACE       Fleet namespace (default: fleet-default)

Examples:
  # Start controller with defaults
  $0

  # Watch a specific placement
  $0 --namespace my-app --placement my-app-placement

  # Run in background
  nohup $0 > /tmp/fleet-dr-controller.log 2>&1 &
EOF
}

# Parse arguments
SKIP_PREFLIGHT=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --placement)
            PLACEMENT_NAME="$2"
            shift 2
            ;;
        --drpc)
            DRPC_NAME="$2"
            shift 2
            ;;
        --label)
            LABEL_KEY="$2"
            shift 2
            ;;
        --context)
            HUB_CONTEXT="$2"
            shift 2
            ;;
        --skip-preflight)
            SKIP_PREFLIGHT=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# --- Main ---

echo ""
log "=== Fleet DR Controller Started ==="
info "Namespace: $NAMESPACE"
info "Placement: $PLACEMENT_NAME"
info "DRPC: $DRPC_NAME"
info "Label: $LABEL_KEY"
info "Fleet Namespace: $FLEET_NAMESPACE"
info "Log file: $LOG_FILE"

# Run preflight checks
if [[ "$SKIP_PREFLIGHT" != "true" ]]; then
    preflight_checks
else
    echo ""
    warn "Preflight checks skipped"
    echo ""
fi

# Show cluster mapping
info "Fleet cluster mapping:"
kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
    -o custom-columns='FLEET_ID:.metadata.name,DISPLAY_NAME:.metadata.labels.management\.cattle\.io/cluster-display-name' 2>/dev/null || true
echo ""

# Show initial DRPC status
show_drpc_summary

# Initial sync
CURRENT_CLUSTER=$(get_current_placement)
if [[ -n "$CURRENT_CLUSTER" ]]; then
    log "Initial PlacementDecision: $CURRENT_CLUSTER"
    sync_labels "$CURRENT_CLUSTER"
    LAST_CLUSTER="$CURRENT_CLUSTER"
else
    warn "No PlacementDecision found initially"
fi

show_fleet_status

log "Watching for PlacementDecision changes (polling every 2s)..."
echo ""

LAST_DRPC_PHASE=$(get_drpc_phase)

while true; do
    CURRENT_CLUSTER=$(get_current_placement)

    if [[ "$CURRENT_CLUSTER" != "$LAST_CLUSTER" ]]; then
        if [[ -z "$CURRENT_CLUSTER" ]]; then
            warn "*** PlacementDecision CLEARED ***"
            warn "Relocate in progress - quiescing workload for final sync"
            info "Fleet will remove the app, freeing PVC for VolSync final sync"
        elif [[ -z "$LAST_CLUSTER" ]]; then
            log "*** PlacementDecision SET: -> $CURRENT_CLUSTER ***"
            if [[ "$LAST_DRPC_PHASE" == "Relocating" ]]; then
                info "Relocate completing - deploying app to $CURRENT_CLUSTER"
            else
                info "Deploying app to $CURRENT_CLUSTER"
            fi
        else
            log "*** PlacementDecision CHANGED: $LAST_CLUSTER -> $CURRENT_CLUSTER ***"
            info "Failover in progress - moving app from $LAST_CLUSTER to $CURRENT_CLUSTER"
        fi

        sync_labels "$CURRENT_CLUSTER"
        LAST_CLUSTER="$CURRENT_CLUSTER"

        # Show detailed status after change
        echo ""
        show_drpc_summary
        show_fleet_status
    fi

    # Monitor DRPC phase transitions
    current_phase=$(get_drpc_phase)
    if [[ "$current_phase" != "$LAST_DRPC_PHASE" && -n "$current_phase" ]]; then
        case "$current_phase" in
            Deploying)
                info "DRPC phase: Deploying - initial app deployment in progress"
                ;;
            Deployed)
                log "DRPC phase: Deployed - app is deployed and protected"
                ;;
            FailingOver)
                warn "DRPC phase: FailingOver - failover in progress..."
                show_drpc_summary
                ;;
            FailedOver)
                log "DRPC phase: FailedOver - failover complete"
                show_drpc_summary
                wait_for_settle "Failover" "$CURRENT_CLUSTER"
                ;;
            Relocating)
                warn "DRPC phase: Relocating - relocate in progress..."
                show_drpc_summary
                ;;
            Relocated)
                log "DRPC phase: Relocated - relocate complete"
                show_drpc_summary
                wait_for_settle "Relocate" "$CURRENT_CLUSTER"
                ;;
            *)
                info "DRPC phase: $current_phase"
                ;;
        esac
        LAST_DRPC_PHASE="$current_phase"
    fi

    sleep 2
done
