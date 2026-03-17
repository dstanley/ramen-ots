#!/bin/bash
# ArgoCD DR Controller
# Usage: ./argocd-dr-controller.sh
#
# This controller watches PlacementDecision changes and manages ArgoCD cluster
# labels to enable automatic application failover with the Cluster generator.
#
# How it works:
# 1. Watches PlacementDecision for the specified placement
# 2. When the decision changes, updates the ramen.dr/enabled label on cluster secrets
# 3. ArgoCD ApplicationSet (using Cluster generator) automatically deploys to labeled clusters
#
# This solves the limitation where ClusterDecisionResource generator only looks
# in the argocd namespace for PlacementDecisions.

set -e

NAMESPACE="${DR_NAMESPACE:-ramen-test}"
PLACEMENT_NAME="${PLACEMENT_NAME:-rto-rpo-test-placement}"
DRPC_NAME="${DRPC_NAME:-rto-rpo-test-drpc}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
LABEL_KEY="${LABEL_KEY:-ramen.dr/enabled}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
LOG_FILE="/tmp/argocd-dr-controller.log"

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

    # Placement controller
    local placement_pods
    placement_pods=$(kubectl --context "$HUB_CONTEXT" get pods -n open-cluster-management-hub \
        -l app=clustermanager-placement-controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$placement_pods" == "Running" ]]; then
        check_ok "Placement controller running"
    else
        check_fail "Placement controller not found or not running"
        failed=1
    fi

    # ManagedClusters
    local clusters
    clusters=$(kubectl --context "$HUB_CONTEXT" get managedcluster -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}{" "}{end}' 2>/dev/null || echo "")
    if [[ -n "$clusters" ]]; then
        for entry in $clusters; do
            local cname="${entry%%=*}"
            local cavail="${entry#*=}"
            if [[ "$cavail" == "True" ]]; then
                check_ok "ManagedCluster $cname (Available)"
            else
                check_warn "ManagedCluster $cname (Not Available)"
            fi
        done
    else
        check_fail "No ManagedClusters found"
        failed=1
    fi

    # ManagedCluster 'name' labels (required for VolSync secret propagation)
    for entry in $clusters; do
        local cname="${entry%%=*}"
        local nlabel
        nlabel=$(kubectl --context "$HUB_CONTEXT" get managedcluster "$cname" \
            -o jsonpath='{.metadata.labels.name}' 2>/dev/null || echo "")
        if [[ "$nlabel" == "$cname" ]]; then
            check_ok "ManagedCluster $cname has name label"
        else
            check_warn "ManagedCluster $cname missing 'name' label (VolSync secret propagation may fail)"
        fi
    done

    # ArgoCD server
    local argocd_pod
    argocd_pod=$(kubectl --context "$HUB_CONTEXT" get pods -n "$ARGOCD_NAMESPACE" \
        -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$argocd_pod" == "Running" ]]; then
        check_ok "ArgoCD server running"
    else
        check_fail "ArgoCD server not found or not running"
        failed=1
    fi

    # ArgoCD cluster secrets
    local cluster_secrets
    cluster_secrets=$(kubectl --context "$HUB_CONTEXT" get secrets -n "$ARGOCD_NAMESPACE" \
        -l argocd.argoproj.io/secret-type=cluster \
        -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || echo "")
    if [[ -n "$cluster_secrets" ]]; then
        for secret in $cluster_secrets; do
            local cname="${secret#cluster-}"
            check_ok "ArgoCD cluster secret: $cname"
        done
    else
        check_fail "No ArgoCD cluster secrets found"
        failed=1
    fi

    # ArgoCD ApplicationSet controller
    local appset_pod
    appset_pod=$(kubectl --context "$HUB_CONTEXT" get pods -n "$ARGOCD_NAMESPACE" \
        -l app.kubernetes.io/name=argocd-applicationset-controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$appset_pod" == "Running" ]]; then
        check_ok "ArgoCD ApplicationSet controller running"
    else
        check_warn "ArgoCD ApplicationSet controller not found"
    fi

    # Submariner
    local subm_gw
    subm_gw=$(kubectl --context "$HUB_CONTEXT" get submarinerconfig -A \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [[ -n "$subm_gw" ]]; then
        check_ok "Submariner config found"
    else
        if kubectl --context "$HUB_CONTEXT" get crd serviceexports.multicluster.x-k8s.io &>/dev/null; then
            check_ok "Submariner CRDs present"
        else
            check_warn "Submariner not detected (cross-cluster VolSync may not work)"
        fi
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

    # Governance policy framework
    local propagator
    propagator=$(kubectl --context "$HUB_CONTEXT" get pods -n open-cluster-management \
        -l name=governance-policy-propagator -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
    if [[ "$propagator" == "Running" ]]; then
        check_ok "Governance policy propagator running"
    else
        check_warn "Governance policy propagator not found (VolSync secret propagation may fail)"
    fi

    echo ""
    if [[ $failed -eq 1 ]]; then
        error "Preflight checks failed - resolve issues before continuing"
        exit 1
    fi
    log "All preflight checks passed"
    echo ""
}

# --- Placement ---

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

show_argocd_status() {
    echo ""
    info "ArgoCD cluster labels:"
    kubectl --context "$HUB_CONTEXT" get secrets -n "$ARGOCD_NAMESPACE" \
        -l argocd.argoproj.io/secret-type=cluster \
        -o custom-columns='CLUSTER:.metadata.name,DR_ENABLED:.metadata.labels.ramen\.dr/enabled' 2>/dev/null || true

    # Show Applications if any
    local app_count
    app_count=$(kubectl --context "$HUB_CONTEXT" get applications -n "$ARGOCD_NAMESPACE" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$app_count" -gt 0 ]]; then
        echo ""
        info "ArgoCD Applications:"
        kubectl --context "$HUB_CONTEXT" get applications -n "$ARGOCD_NAMESPACE" \
            -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status,CLUSTER:.spec.destination.name' 2>/dev/null || true
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

# --- Label management ---

get_all_clusters() {
    kubectl --context "$HUB_CONTEXT" get secrets -n "$ARGOCD_NAMESPACE" \
        -l argocd.argoproj.io/secret-type=cluster \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | sed 's/cluster-//'
}

get_labeled_cluster() {
    kubectl --context "$HUB_CONTEXT" get secrets -n "$ARGOCD_NAMESPACE" \
        -l argocd.argoproj.io/secret-type=cluster,"$LABEL_KEY"=true \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null | sed 's/cluster-//'
}

label_cluster() {
    local cluster=$1
    local secret_name="cluster-$cluster"

    log "Labeling cluster $cluster for ArgoCD deployment"
    kubectl --context "$HUB_CONTEXT" label secret "$secret_name" -n "$ARGOCD_NAMESPACE" \
        "$LABEL_KEY=true" --overwrite 2>/dev/null || true
}

unlabel_cluster() {
    local cluster=$1
    local secret_name="cluster-$cluster"

    log "Removing label from cluster $cluster"
    kubectl --context "$HUB_CONTEXT" label secret "$secret_name" -n "$ARGOCD_NAMESPACE" \
        "$LABEL_KEY-" 2>/dev/null || true
}

unlabel_all_clusters() {
    for cluster in $(get_all_clusters); do
        unlabel_cluster "$cluster"
    done
}

sync_labels() {
    local target_cluster=$1

    if [[ -z "$target_cluster" ]]; then
        warn "PlacementDecision is empty - unlabeling all clusters"
        unlabel_all_clusters
        return
    fi

    local current_labeled=$(get_labeled_cluster)

    if [[ "$current_labeled" == "$target_cluster" ]]; then
        # Already correct
        return
    fi

    log "Syncing labels: $current_labeled -> $target_cluster"

    # Remove label from all other clusters
    for cluster in $(get_all_clusters); do
        if [[ "$cluster" != "$target_cluster" ]]; then
            unlabel_cluster "$cluster"
        fi
    done

    # Add label to target cluster
    label_cluster "$target_cluster"
}

# --- Lifecycle ---

cleanup() {
    log "Shutting down ArgoCD DR controller..."
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
  --label KEY           Label key to use on cluster secrets (default: ramen.dr/enabled)
  --context CTX         Kubectl context for hub cluster (default: rke2)
  --skip-preflight      Skip preflight checks
  --help                Show this help

Environment Variables:
  DR_NAMESPACE          Same as --namespace
  PLACEMENT_NAME        Same as --placement
  DRPC_NAME             Same as --drpc
  LABEL_KEY             Same as --label
  HUB_CONTEXT           Same as --context

Examples:
  # Start controller with defaults
  $0

  # Watch a specific placement
  $0 --namespace my-app --placement my-app-placement

  # Run in background
  nohup $0 > /tmp/argocd-dr-controller.log 2>&1 &
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
log "=== ArgoCD DR Controller Started ==="
info "Namespace: $NAMESPACE"
info "Placement: $PLACEMENT_NAME"
info "DRPC: $DRPC_NAME"
info "Label: $LABEL_KEY"
info "ArgoCD Namespace: $ARGOCD_NAMESPACE"
info "Log file: $LOG_FILE"

# Run preflight checks
if [[ "$SKIP_PREFLIGHT" != "true" ]]; then
    preflight_checks
else
    echo ""
    warn "Preflight checks skipped"
    echo ""
fi

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

show_argocd_status

log "Watching for PlacementDecision changes (polling every 2s)..."
echo ""

LAST_DRPC_PHASE=$(get_drpc_phase)

while true; do
    CURRENT_CLUSTER=$(get_current_placement)

    if [[ "$CURRENT_CLUSTER" != "$LAST_CLUSTER" ]]; then
        if [[ -z "$CURRENT_CLUSTER" ]]; then
            warn "*** PlacementDecision CLEARED ***"
            warn "Relocate in progress - quiescing workload for final sync"
            info "ArgoCD will remove the app, freeing PVC for VolSync final sync"
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
        show_argocd_status
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
                show_argocd_status
                ;;
            Relocating)
                warn "DRPC phase: Relocating - relocate in progress..."
                show_drpc_summary
                ;;
            Relocated)
                log "DRPC phase: Relocated - relocate complete"
                show_drpc_summary
                show_argocd_status
                ;;
            *)
                info "DRPC phase: $current_phase"
                ;;
        esac
        LAST_DRPC_PHASE="$current_phase"
    fi

    sleep 2
done
