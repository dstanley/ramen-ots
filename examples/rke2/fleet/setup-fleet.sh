#!/bin/bash
# Setup Fleet for DR Integration with Ramen
# Usage: ./setup-fleet.sh
#
# This script verifies Fleet is installed and discovers managed cluster
# registrations. Since Fleet is bundled with Rancher, most setup is
# already done - this script validates the environment and shows the
# cluster ID mapping needed by fleet-dr-controller.sh.

set -e

HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
FLEET_NAMESPACE="${FLEET_NAMESPACE:-fleet-default}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }
error() { echo -e "${RED}[$(date +%H:%M:%S)]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }

check_prerequisites() {
    log "Checking prerequisites..."

    # Check Fleet CRD exists
    if ! kubectl --context "$HUB_CONTEXT" get crd gitrepos.fleet.cattle.io &>/dev/null; then
        error "Fleet CRDs not found. Is Rancher/Fleet installed?"
    fi

    # Check Fleet controller is running
    local running_pods
    running_pods=$(kubectl --context "$HUB_CONTEXT" get pods -n cattle-fleet-system 2>/dev/null | grep -c Running || echo 0)
    if [[ "$running_pods" -lt 1 ]]; then
        error "Fleet controller not running in cattle-fleet-system (found $running_pods running pods)"
    fi

    # Check fleet-default namespace exists
    if ! kubectl --context "$HUB_CONTEXT" get namespace "$FLEET_NAMESPACE" &>/dev/null; then
        error "Fleet namespace '$FLEET_NAMESPACE' not found"
    fi

    log "Prerequisites check passed"
}

discover_clusters() {
    log "Discovering Fleet clusters..."
    echo ""

    local clusters
    clusters=$(kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.management\.cattle\.io/cluster-display-name}{"\n"}{end}' 2>/dev/null)

    if [[ -z "$clusters" ]]; then
        error "No Fleet clusters found in namespace $FLEET_NAMESPACE"
    fi

    info "Fleet Cluster ID -> Display Name mapping:"
    echo ""
    printf "  %-20s %s\n" "FLEET ID" "DISPLAY NAME"
    printf "  %-20s %s\n" "--------" "------------"
    while IFS=$'\t' read -r fleet_id display_name; do
        printf "  %-20s %s\n" "$fleet_id" "$display_name"
    done <<< "$clusters"
    echo ""

    log "The fleet-dr-controller.sh resolves OCM cluster names to Fleet IDs"
    log "using the management.cattle.io/cluster-display-name label"
}

verify_cluster_status() {
    log "Checking Fleet cluster status..."
    echo ""

    kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -o custom-columns='NAME:.metadata.name,DISPLAY:.metadata.labels.management\.cattle\.io/cluster-display-name,READY:.status.conditions[?(@.type=="Ready")].status,STATE:.status.display.state' 2>/dev/null

    echo ""

    # Check for unhealthy clusters
    local not_ready
    not_ready=$(kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n "$FLEET_NAMESPACE" \
        -o jsonpath='{range .items[*]}{.metadata.labels.management\.cattle\.io/cluster-display-name}={.status.display.state}{"\n"}{end}' 2>/dev/null | grep -v "Active" || true)

    if [[ -n "$not_ready" ]]; then
        warn "Some clusters are not in Active state:"
        echo "  $not_ready"
        warn "Fleet may still work but check cluster connectivity"
    else
        log "All clusters are Active"
    fi
}

show_fleet_pods() {
    log "Fleet controller pods:"
    kubectl --context "$HUB_CONTEXT" get pods -n cattle-fleet-system \
        -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,RESTARTS:.status.containerStatuses[0].restartCount' 2>/dev/null
    echo ""
}

# Main
main() {
    echo ""
    log "=== Fleet DR Integration Setup ==="
    echo ""

    check_prerequisites
    discover_clusters
    verify_cluster_status
    show_fleet_pods

    log "=== Setup Verification Complete ==="
    echo ""
    log "Next steps:"
    echo "  1. Apply the GitRepo:  kubectl apply -f gitrepo.yaml --context $HUB_CONTEXT"
    echo "  2. Start controller:   ./fleet-dr-controller.sh"
    echo "  3. Deploy DR resources: ../scripts/demo-dr.sh deploy harv --model fleet"
    echo ""
}

main "$@"
