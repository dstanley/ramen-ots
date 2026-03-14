#!/bin/bash

# SPDX-FileCopyrightText: The RamenDR authors
# SPDX-License-Identifier: Apache-2.0

# =============================================================================
# Create a kubeconfig Secret for a managed cluster
# =============================================================================
#
# Creates (or updates) a Secret named <cluster>-kubeconfig in the OTS
# namespace. The OTS controller reads this to connect to managed clusters.
#
# Usage:
#   # From the current kubeconfig context (works with kubie)
#   kubie ctx harv
#   ./create-cluster-secret.sh harv --from-current
#
#   # From a kubeconfig file
#   ./create-cluster-secret.sh harv --from-file ~/.kube/harv-config
#
#   # Extract a named context from a kubeconfig
#   ./create-cluster-secret.sh harv --from-context harv --kubeconfig ~/.kube/config
#
# =============================================================================

set -euo pipefail

OTS_NAMESPACE="${OTS_NAMESPACE:-ramen-ots-system}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

usage() {
    echo "Usage: $0 <cluster-name> [options]"
    echo ""
    echo "Options:"
    echo "  --from-current          Use the current kubeconfig/context (kubie-friendly)"
    echo "  --from-file path        Use this kubeconfig file directly"
    echo "  --from-context name     Extract this context from --kubeconfig"
    echo "  --kubeconfig path       Kubeconfig file to extract context from"
    echo "  --namespace ns          OTS namespace (default: ramen-ots-system)"
    echo "  --help                  Show this help"
    exit 1
}

CLUSTER_NAME=""
FROM_CURRENT=false
FROM_FILE=""
FROM_CONTEXT=""
KC_FILE=""

# Parse args
if [[ $# -lt 1 ]]; then
    usage
fi

CLUSTER_NAME="$1"; shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from-current)
            FROM_CURRENT=true; shift ;;
        --from-file)
            FROM_FILE="$2"; shift 2 ;;
        --from-context)
            FROM_CONTEXT="$2"; shift 2 ;;
        --kubeconfig)
            KC_FILE="$2"; shift 2 ;;
        --namespace)
            OTS_NAMESPACE="$2"; shift 2 ;;
        --help)
            usage ;;
        *)
            log_error "Unknown option: $1"
            usage ;;
    esac
done

SECRET_NAME="${CLUSTER_NAME}-kubeconfig"

# Determine the kubeconfig data
TMP_KC=$(mktemp)
trap "rm -f $TMP_KC" EXIT

if [[ "$FROM_CURRENT" == "true" ]]; then
    # Export the current kubeconfig context (works with kubie, kubectx, etc.)
    local_ctx=$(kubectl config current-context 2>/dev/null || true)
    log_info "Using current context: ${local_ctx:-<default>}"
    log_info "KUBECONFIG=${KUBECONFIG:-<default>}"

    kubectl config view --flatten --minify > "$TMP_KC"
    if [[ ! -s "$TMP_KC" ]]; then
        log_error "Could not export current kubeconfig context"
        exit 1
    fi
    KC_DATA_FILE="$TMP_KC"

elif [[ -n "$FROM_FILE" ]]; then
    if [[ ! -f "$FROM_FILE" ]]; then
        log_error "File not found: $FROM_FILE"
        exit 1
    fi
    KC_DATA_FILE="$FROM_FILE"
    log_info "Using kubeconfig file: $FROM_FILE"

elif [[ -n "$FROM_CONTEXT" ]]; then
    KC_ARGS=""
    if [[ -n "$KC_FILE" ]]; then
        KC_ARGS="--kubeconfig=$KC_FILE"
    fi

    log_info "Extracting context '$FROM_CONTEXT'..."
    kubectl config view $KC_ARGS --context="$FROM_CONTEXT" --flatten --minify > "$TMP_KC"
    if [[ ! -s "$TMP_KC" ]]; then
        log_error "Could not extract context '$FROM_CONTEXT'"
        exit 1
    fi
    KC_DATA_FILE="$TMP_KC"

else
    log_error "Specify --from-current, --from-file, or --from-context"
    usage
fi

# Ensure namespace exists
if ! kubectl get namespace "$OTS_NAMESPACE" &>/dev/null; then
    log_info "Creating namespace: $OTS_NAMESPACE"
    kubectl create namespace "$OTS_NAMESPACE"
fi

# Create or update the secret
log_info "Creating secret $SECRET_NAME in $OTS_NAMESPACE"
kubectl create secret generic "$SECRET_NAME" \
    -n "$OTS_NAMESPACE" \
    --from-file=kubeconfig="$KC_DATA_FILE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Verify
log_info "Verifying secret..."
kubectl get secret "$SECRET_NAME" -n "$OTS_NAMESPACE" -o jsonpath='{.metadata.name}' &>/dev/null

log_success "Secret $SECRET_NAME created in $OTS_NAMESPACE"
echo ""
echo "The OTS controller will use this to connect to cluster '$CLUSTER_NAME'"
