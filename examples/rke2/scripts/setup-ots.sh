#!/bin/bash

# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# =============================================================================
# Set up Ramen OTS Controller
# =============================================================================
#
# This script:
#   1. Installs OCM CRDs (ManifestWork, ManagedClusterView, ManagedCluster, etc.)
#   2. Creates managed cluster namespaces and ManagedCluster CRs
#   3. Creates kubeconfig secrets for managed clusters
#   4. Deploys the Ramen OTS controller
#
# Prerequisites:
#   - kubectl configured to talk to the hub cluster
#   - Kubeconfig files for managed clusters available
#   - OTS controller image available in a registry accessible from the hub
#
# Usage:
#   ./setup-ots.sh --clusters harv,marv \
#     --harv-kubeconfig ~/.kube/harv-config \
#     --marv-kubeconfig ~/.kube/marv-config
#
#   Or with a single kubeconfig with named contexts:
#   ./setup-ots.sh --clusters harv,marv --kubeconfig ~/.kube/config
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
RAMEN_DIR="${RAMEN_DIR:-}"

# Defaults
OTS_NAMESPACE="ramen-ots-system"
OTS_IMAGE="${OTS_IMAGE:-ramen-ots:latest}"
OTS_DEPLOY_DIR="${OTS_DEPLOY_DIR:-}"
CLUSTERS=""
KUBECONFIG_FILE=""
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
    echo "Options:"
    echo "  --clusters name1,name2    Comma-separated managed cluster names (required)"
    echo "  --kubeconfig path         Kubeconfig file with contexts matching cluster names"
    echo "  --<name>-kubeconfig path  Kubeconfig file for a specific cluster"
    echo "  --image image:tag         OTS controller image (default: ramen-ots:latest)"
    echo "  --namespace ns            OTS namespace (default: ramen-ots-system)"
    echo "  --deploy-dir path         Path to OTS deploy manifests (namespace.yaml, rbac.yaml, deployment.yaml)"
    echo "  --dry-run                 Print commands without executing"
    echo "  --help                    Show this help"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --clusters)
            CLUSTERS="$2"; shift 2 ;;
        --kubeconfig)
            KUBECONFIG_FILE="$2"; shift 2 ;;
        --image)
            OTS_IMAGE="$2"; shift 2 ;;
        --namespace)
            OTS_NAMESPACE="$2"; shift 2 ;;
        --deploy-dir)
            OTS_DEPLOY_DIR="$2"; shift 2 ;;
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

if [[ -z "$CLUSTERS" ]]; then
    log_error "No clusters specified. Use --clusters name1,name2"
    usage
fi

IFS=',' read -ra CLUSTER_LIST <<< "$CLUSTERS"

# =============================================================================
# Step 1: Ensure OCM CRDs exist
# =============================================================================

ensure_crds() {
    log_info "=========================================="
    log_info "Step 1: Ensuring OCM CRDs are installed"
    log_info "=========================================="

    local crds_dir=""

    # Look for CRDs in the Ramen repo (set RAMEN_DIR to the ramen repo root)
    if [[ -n "$RAMEN_DIR" && -d "$RAMEN_DIR/hack/test" ]]; then
        crds_dir="$RAMEN_DIR/hack/test"
    else
        if [[ -n "$RAMEN_DIR" ]]; then
            log_warn "Ramen repo not found at $RAMEN_DIR/hack/test"
        fi
        log_warn "Set RAMEN_DIR to the Ramen repo root, or install CRDs manually"
        log_warn "Checking if CRDs already exist..."

        local missing=false
        for crd in manifestworks.work.open-cluster-management.io \
                   managedclusterviews.view.open-cluster-management.io \
                   managedclusters.cluster.open-cluster-management.io \
                   placements.cluster.open-cluster-management.io \
                   placementdecisions.cluster.open-cluster-management.io; do
            if ! kubectl get crd "$crd" &>/dev/null; then
                log_error "Missing CRD: $crd"
                missing=true
            fi
        done

        if [[ "$missing" == "true" ]]; then
            log_error "Required CRDs are missing. Set RAMEN_DIR or install CRDs manually."
            exit 1
        fi

        log_success "All required CRDs present"
        return
    fi

    # Apply CRDs from Ramen hack/test
    local crd_files=(
        "0000_00_work.open-cluster-management.io_manifestworks.crd.yaml"
        "view.open-cluster-management.io_managedclusterviews.yaml"
        "0000_00_clusters.open-cluster-management.io_managedclusters.crd.yaml"
        "0000_02_clusters.open-cluster-management.io_placements.crd.yaml"
        "0000_03_clusters.open-cluster-management.io_placementdecisions.crd.yaml"
        "0000_02_clusters.open-cluster-management.io_clusterclaims.crd.yaml"
    )

    for f in "${crd_files[@]}"; do
        if [[ -f "$crds_dir/$f" ]]; then
            log_info "Applying CRD: $f"
            run kubectl apply -f "$crds_dir/$f"
        else
            log_warn "CRD file not found: $f"
        fi
    done

    log_success "CRDs installed"
}

# =============================================================================
# Step 2: Create managed cluster namespaces and ManagedCluster CRs
# =============================================================================

create_managed_clusters() {
    log_info "=========================================="
    log_info "Step 2: Creating ManagedCluster resources"
    log_info "=========================================="

    for cluster in "${CLUSTER_LIST[@]}"; do
        # Create namespace (Ramen expects namespace = cluster name)
        if ! kubectl get namespace "$cluster" &>/dev/null; then
            log_info "Creating namespace: $cluster"
            run kubectl create namespace "$cluster"
        fi

        # Create ManagedCluster CR with conditions that satisfy Ramen
        log_info "Creating ManagedCluster: $cluster"
        run kubectl apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1
kind: ManagedCluster
metadata:
  name: ${cluster}
  labels:
    name: ${cluster}
    cloud: Other
    vendor: Other
spec:
  hubAcceptsClient: true
  leaseDurationSeconds: 60
EOF

        # Patch status to mark as joined and available
        # Ramen checks these conditions before creating ManifestWork/MCV
        log_info "Patching ManagedCluster status: $cluster"
        run kubectl patch managedcluster "$cluster" --type=merge --subresource=status -p "$(cat <<EOF
{
  "status": {
    "conditions": [
      {
        "type": "HubAcceptedManagedCluster",
        "status": "True",
        "reason": "HubClusterAdminAccepted",
        "message": "Accepted by OTS controller",
        "lastTransitionTime": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      },
      {
        "type": "ManagedClusterJoined",
        "status": "True",
        "reason": "ManagedClusterJoined",
        "message": "Managed by OTS controller",
        "lastTransitionTime": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      },
      {
        "type": "ManagedClusterConditionAvailable",
        "status": "True",
        "reason": "ManagedClusterAvailable",
        "message": "Cluster is reachable via OTS",
        "lastTransitionTime": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      }
    ]
  }
}
EOF
)" 2>/dev/null || log_warn "Could not patch ManagedCluster status for $cluster (may need manual update)"

    done

    log_success "ManagedCluster resources created"
}

# =============================================================================
# Step 3: Create kubeconfig secrets
# =============================================================================

create_kubeconfig_secrets() {
    log_info "=========================================="
    log_info "Step 3: Creating kubeconfig Secrets"
    log_info "=========================================="

    # Ensure OTS namespace exists
    if ! kubectl get namespace "$OTS_NAMESPACE" &>/dev/null; then
        log_info "Creating namespace: $OTS_NAMESPACE"
        run kubectl create namespace "$OTS_NAMESPACE"
    fi

    for cluster in "${CLUSTER_LIST[@]}"; do
        local kc_file=""
        local secret_name="${cluster}-kubeconfig"

        local _var="CLUSTER_KC_${cluster}"
        if [[ -n "${!_var:-}" ]]; then
            kc_file="${!_var}"
        elif [[ -n "$KUBECONFIG_FILE" ]]; then
            # Extract the cluster's context from the shared kubeconfig
            log_info "Extracting context '$cluster' from shared kubeconfig..."
            local tmp_kc
            tmp_kc=$(mktemp)
            kubectl config view --kubeconfig="$KUBECONFIG_FILE" \
                --context="$cluster" --flatten --minify > "$tmp_kc" 2>/dev/null
            if [[ -s "$tmp_kc" ]]; then
                kc_file="$tmp_kc"
            else
                rm -f "$tmp_kc"
                log_warn "Could not extract context '$cluster' from kubeconfig"
            fi
        fi

        if [[ -z "$kc_file" || ! -f "$kc_file" ]]; then
            log_warn "No kubeconfig found for $cluster — create secret manually:"
            log_warn "  kubectl create secret generic $secret_name -n $OTS_NAMESPACE --from-file=kubeconfig=<path>"
            continue
        fi

        log_info "Creating secret $secret_name in $OTS_NAMESPACE"
        run kubectl create secret generic "$secret_name" \
            -n "$OTS_NAMESPACE" \
            --from-file=kubeconfig="$kc_file" \
            --dry-run=client -o yaml | run kubectl apply -f -

        # Clean up temp file if we created one
        if [[ "$kc_file" == /tmp/* ]]; then
            rm -f "$kc_file"
        fi
    done

    log_success "Kubeconfig secrets created"
}

# =============================================================================
# Step 4: Deploy OTS controller
# =============================================================================

deploy_ots() {
    log_info "=========================================="
    log_info "Step 4: Deploying Ramen OTS controller"
    log_info "=========================================="

    # Find deploy manifests
    local deploy_dir="$OTS_DEPLOY_DIR"
    if [[ -z "$deploy_dir" ]]; then
        # Default: look in repo root scripts/deploy
        if [[ -f "$REPO_ROOT/scripts/deploy/deployment.yaml" ]]; then
            deploy_dir="$REPO_ROOT/scripts/deploy"
        else
            log_error "No deploy directory found."
            log_error "Pass --deploy-dir <path>/scripts/deploy or run from the ramen-ots repo."
            exit 1
        fi
    fi

    if [[ ! -f "$deploy_dir/deployment.yaml" ]]; then
        log_error "Deploy manifests not found at $deploy_dir"
        exit 1
    fi

    # Apply namespace
    run kubectl apply -f "$deploy_dir/namespace.yaml"

    # Apply RBAC
    run kubectl apply -f "$deploy_dir/rbac.yaml"

    # Apply deployment with image override
    if [[ "$OTS_IMAGE" != "ramen-ots:latest" ]]; then
        log_info "Using image: $OTS_IMAGE"
        sed "s|image: ramen-ots:latest|image: $OTS_IMAGE|" "$deploy_dir/deployment.yaml" | run kubectl apply -f -
    else
        run kubectl apply -f "$deploy_dir/deployment.yaml"
    fi

    # Wait for rollout
    log_info "Waiting for controller to be ready..."
    run kubectl rollout status deployment/ramen-ots-controller -n "$OTS_NAMESPACE" --timeout=120s || true

    log_success "OTS controller deployed"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    log_info "Setting up Ramen OTS Controller"
    log_info "Clusters: ${CLUSTER_LIST[*]}"
    log_info "Namespace: $OTS_NAMESPACE"
    log_info "Image: $OTS_IMAGE"
    echo ""

    ensure_crds
    create_managed_clusters
    create_kubeconfig_secrets
    deploy_ots

    echo ""
    log_success "=========================================="
    log_success "OTS setup complete!"
    log_success "=========================================="
    echo ""
    log_info "Verify with:"
    log_info "  kubectl get deployment -n $OTS_NAMESPACE"
    log_info "  kubectl get managedclusters"
    log_info "  kubectl logs -n $OTS_NAMESPACE deployment/ramen-ots-controller"
}

main
