#!/bin/bash

# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# =============================================================================
# Setup Submariner for cross-cluster networking (optional)
# =============================================================================
#
# Deploys Submariner to enable cross-cluster networking between managed
# clusters. This is needed when clusters are in different networks (e.g.,
# different AWS VPCs, different data centers) and cannot reach each other
# directly.
#
# Submariner provides:
#   - IPsec/WireGuard tunnels between clusters
#   - Service discovery (ServiceExport/ServiceImport)
#   - Cross-cluster pod/service network connectivity
#
# When is this needed?
#   - VolSync rsync-tls: source cluster must reach destination's rsync service
#   - S3 endpoint: managed clusters must reach the S3 store
#   - If clusters are on the same L2/L3 network, you do NOT need this
#
# Prerequisites:
#   - subctl installed (https://submariner.io/operations/deployment/subctl/)
#   - kubectl configured to talk to the hub cluster
#   - Kubeconfig files for managed clusters
#   - UDP port 4500 open between cluster gateway nodes
#   - One worker/gateway node per cluster with a public/routable IP
#
# Usage:
#   # Deploy using per-cluster kubeconfigs
#   ./setup-submariner.sh --clusters harv,marv \
#     --harv-kubeconfig ~/.kube/harv-config \
#     --marv-kubeconfig ~/.kube/marv-config
#
#   # Deploy using kubie-style (run from hub context)
#   ./setup-submariner.sh --clusters harv,marv \
#     --kubeconfig ~/.kube/config
#
#   # Verify connectivity
#   ./setup-submariner.sh --verify
#
#   # Remove Submariner
#   ./setup-submariner.sh --teardown --clusters harv,marv \
#     --harv-kubeconfig ~/.kube/harv-config \
#     --marv-kubeconfig ~/.kube/marv-config
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
CLUSTERS=""
KUBECONFIG_FILE=""
HUB_KUBECONFIG="${HUB_KUBECONFIG:-}"
BROKER_INFO="${BROKER_INFO:-broker-info.subm}"
CABLE_DRIVER="${CABLE_DRIVER:-libreswan}"  # libreswan or wireguard
GLOBALNET="${GLOBALNET:-false}"
SERVICE_DISCOVERY="${SERVICE_DISCOVERY:-true}"
ACTION="install"
DRY_RUN="${DRY_RUN:-false}"

# =============================================================================
# Colors and logging
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

# =============================================================================
# Parse arguments
# =============================================================================

usage() {
    echo "Usage: $0 --clusters name1,name2 [options]"
    echo ""
    echo "Actions:"
    echo "  (default)                Install Submariner"
    echo "  --teardown               Remove Submariner from all clusters"
    echo "  --verify                 Verify Submariner connectivity"
    echo ""
    echo "Options:"
    echo "  --clusters name1,name2   Comma-separated managed cluster names (required)"
    echo "  --kubeconfig path        Kubeconfig file with contexts matching cluster names"
    echo "  --<name>-kubeconfig path Kubeconfig file for a specific cluster"
    echo "  --hub-kubeconfig path    Hub cluster kubeconfig (default: current context)"
    echo "  --cable-driver driver    libreswan (default) or wireguard"
    echo "  --globalnet              Enable GlobalNet for overlapping CIDRs"
    echo "  --no-service-discovery   Disable service discovery (ServiceExport/Import)"
    echo "  --broker-info path       Broker info file path (default: broker-info.subm)"
    echo "  --dry-run                Print commands without executing"
    echo "  --help                   Show this help"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clusters)
            CLUSTERS="$2"; shift 2 ;;
        --kubeconfig)
            KUBECONFIG_FILE="$2"; shift 2 ;;
        --hub-kubeconfig)
            HUB_KUBECONFIG="$2"; shift 2 ;;
        --cable-driver)
            CABLE_DRIVER="$2"; shift 2 ;;
        --globalnet)
            GLOBALNET="true"; shift ;;
        --no-service-discovery)
            SERVICE_DISCOVERY="false"; shift ;;
        --broker-info)
            BROKER_INFO="$2"; shift 2 ;;
        --teardown)
            ACTION="teardown"; shift ;;
        --verify)
            ACTION="verify"; shift ;;
        --dry-run)
            DRY_RUN="true"; shift ;;
        --help)
            usage ;;
        --*-kubeconfig)
            name="${1#--}"
            name="${name%-kubeconfig}"
            eval "CLUSTER_KC_${name}=\$2"
            shift 2 ;;
        *)
            log_error "Unknown option: $1"
            usage ;;
    esac
done

# =============================================================================
# Helpers
# =============================================================================

check_subctl() {
    if ! command -v subctl &>/dev/null; then
        log_error "subctl not found. Install it:"
        log_error "  curl -Ls https://get.submariner.io | bash"
        log_error "  export PATH=\$PATH:~/.local/bin"
        exit 1
    fi
    log_info "subctl version: $(subctl version 2>/dev/null || echo 'unknown')"
}

get_cluster_kubeconfig() {
    local cluster="$1"
    local var="CLUSTER_KC_${cluster}"
    local val="${!var:-}"

    if [[ -n "$val" ]]; then
        echo "$val"
    elif [[ -n "$KUBECONFIG_FILE" ]]; then
        echo "$KUBECONFIG_FILE"
    else
        echo ""
    fi
}

get_hub_kc_flag() {
    if [[ -n "$HUB_KUBECONFIG" ]]; then
        echo "--kubeconfig $HUB_KUBECONFIG"
    else
        echo ""
    fi
}

# =============================================================================
# Install
# =============================================================================

deploy_broker() {
    log_info "=========================================="
    log_info "Step 1: Deploying Submariner broker on hub"
    log_info "=========================================="

    local hub_kc_flag
    hub_kc_flag=$(get_hub_kc_flag)

    local broker_args="deploy-broker"
    if [[ -n "$hub_kc_flag" ]]; then
        broker_args="$broker_args $hub_kc_flag"
    fi

    if [[ "$GLOBALNET" == "true" ]]; then
        broker_args="$broker_args --globalnet"
    fi

    if [[ "$SERVICE_DISCOVERY" == "true" ]]; then
        broker_args="$broker_args --service-discovery"
    fi

    log_info "Running: subctl $broker_args"
    run subctl $broker_args

    if [[ ! -f "$BROKER_INFO" && "$DRY_RUN" != "true" ]]; then
        log_error "Broker info file not created at $BROKER_INFO"
        log_error "Check if deploy-broker succeeded"
        exit 1
    fi

    log_success "Broker deployed"
}

join_clusters() {
    log_info "=========================================="
    log_info "Step 2: Joining managed clusters"
    log_info "=========================================="

    for cluster in "${CLUSTER_LIST[@]}"; do
        local kc
        kc=$(get_cluster_kubeconfig "$cluster")

        if [[ -z "$kc" ]]; then
            log_warn "No kubeconfig for $cluster — skipping"
            continue
        fi

        log_info "Joining $cluster to Submariner broker..."

        local join_args="join $BROKER_INFO"
        join_args="$join_args --kubeconfig $kc"

        # If using a shared kubeconfig, specify the context
        local _var="CLUSTER_KC_${cluster}"
        if [[ -n "$KUBECONFIG_FILE" && -z "${!_var:-}" ]]; then
            join_args="$join_args --context $cluster"
        fi

        join_args="$join_args --clusterid $cluster"
        join_args="$join_args --cable-driver $CABLE_DRIVER"

        if [[ "$SERVICE_DISCOVERY" == "true" ]]; then
            join_args="$join_args --service-discovery"
        fi

        log_info "Running: subctl $join_args"
        run subctl $join_args

        log_success "$cluster joined"
    done
}

verify_connectivity() {
    log_info "=========================================="
    log_info "Verifying Submariner connectivity"
    log_info "=========================================="

    # Show status from hub
    local hub_kc_flag
    hub_kc_flag=$(get_hub_kc_flag)

    log_info "Submariner status:"
    if [[ -n "$hub_kc_flag" ]]; then
        run subctl show all $hub_kc_flag 2>/dev/null || true
    else
        run subctl show all 2>/dev/null || true
    fi

    log_success "Verification complete"
}

do_install() {
    if [[ -z "$CLUSTERS" ]]; then
        log_error "No clusters specified. Use --clusters name1,name2"
        usage
    fi

    IFS=',' read -ra CLUSTER_LIST <<< "$CLUSTERS"

    echo ""
    log_info "Setting up Submariner"
    log_info "Clusters: ${CLUSTER_LIST[*]}"
    log_info "Cable driver: $CABLE_DRIVER"
    log_info "GlobalNet: $GLOBALNET"
    log_info "Service discovery: $SERVICE_DISCOVERY"
    echo ""

    check_subctl
    deploy_broker
    join_clusters
    verify_connectivity

    echo ""
    log_success "=========================================="
    log_success "Submariner setup complete!"
    log_success "=========================================="
    echo ""
    log_info "Cross-cluster networking is now available."
    log_info "VolSync rsync-tls and S3 endpoints can traverse the tunnel."
    echo ""
    log_info "Useful commands:"
    log_info "  subctl show all                    # Show connection status"
    log_info "  subctl show connections             # Show tunnel connections"
    log_info "  subctl verify --only connectivity   # Run connectivity tests"
}

# =============================================================================
# Teardown
# =============================================================================

do_teardown() {
    if [[ -z "$CLUSTERS" ]]; then
        log_error "No clusters specified. Use --clusters name1,name2"
        usage
    fi

    IFS=',' read -ra CLUSTER_LIST <<< "$CLUSTERS"

    echo ""
    log_info "Removing Submariner"
    log_info "Clusters: ${CLUSTER_LIST[*]}"
    echo ""

    check_subctl

    # Uninstall from managed clusters
    for cluster in "${CLUSTER_LIST[@]}"; do
        local kc
        kc=$(get_cluster_kubeconfig "$cluster")

        if [[ -z "$kc" ]]; then
            log_warn "No kubeconfig for $cluster — skipping"
            continue
        fi

        log_info "Removing Submariner from $cluster..."

        local uninstall_args="uninstall --kubeconfig $kc"
        local _var="CLUSTER_KC_${cluster}"
        if [[ -n "$KUBECONFIG_FILE" && -z "${!_var:-}" ]]; then
            uninstall_args="$uninstall_args --context $cluster"
        fi

        run subctl $uninstall_args 2>/dev/null || true
        log_success "$cluster cleaned up"
    done

    # Clean up broker on hub
    log_info "Removing Submariner broker from hub..."
    local hub_kc_flag
    hub_kc_flag=$(get_hub_kc_flag)

    if [[ -n "$hub_kc_flag" ]]; then
        run kubectl $hub_kc_flag delete namespace submariner-k8s-broker --ignore-not-found=true 2>/dev/null || true
    else
        run kubectl delete namespace submariner-k8s-broker --ignore-not-found=true 2>/dev/null || true
    fi

    # Clean up broker info file
    rm -f "$BROKER_INFO"

    echo ""
    log_success "Submariner removed"
}

# =============================================================================
# Verify only
# =============================================================================

do_verify() {
    check_subctl
    verify_connectivity
}

# =============================================================================
# Main
# =============================================================================

case "$ACTION" in
    install)  do_install ;;
    teardown) do_teardown ;;
    verify)   do_verify ;;
esac
