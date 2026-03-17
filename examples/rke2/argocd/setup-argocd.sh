#!/bin/bash
# Setup ArgoCD with Placement Integration
# Usage: ./setup-argocd.sh
#
# This script configures ArgoCD to work with PlacementDecision resources
# for automatic application deployment during DR operations.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
KUBECONFIGS_DIR="${KUBECONFIGS_DIR:-$HOME/.kube}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }
error() { echo -e "${RED}[$(date +%H:%M:%S)]${NC} $1"; exit 1; }

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    # Check ArgoCD is installed
    if ! kubectl --context "$HUB_CONTEXT" get namespace argocd &>/dev/null; then
        error "ArgoCD namespace not found. Please install ArgoCD first."
    fi

    # Check ArgoCD pods are running
    local running_pods=$(kubectl --context "$HUB_CONTEXT" get pods -n argocd 2>/dev/null | grep -c Running || echo 0)
    if [[ "$running_pods" -lt 5 ]]; then
        error "ArgoCD pods are not running (found $running_pods running pods)."
    fi

    log "Prerequisites check passed"
}

# Configure OCM integration in ArgoCD
configure_ocm_integration() {
    log "Configuring OCM Placement integration in ArgoCD..."

    # Patch argocd-cm to enable ClusterDecisionResource
    kubectl --context "$HUB_CONTEXT" patch configmap argocd-cm -n argocd --type=merge -p '
{
  "data": {
    "application.resourceTrackingMethod": "annotation"
  }
}'

    log "ArgoCD ConfigMap updated"
}

# Add managed cluster to ArgoCD
add_cluster() {
    local cluster_name=$1
    local kubeconfig_file=$2

    log "Adding cluster $cluster_name to ArgoCD..."

    if [[ ! -f "$kubeconfig_file" ]]; then
        warn "Kubeconfig file not found: $kubeconfig_file, skipping $cluster_name"
        return
    fi

    # Extract server URL and credentials
    local server=$(grep -A2 "server:" "$kubeconfig_file" | head -1 | awk '{print $2}' | tr -d '"')
    local ca_data=$(grep "certificate-authority-data:" "$kubeconfig_file" | head -1 | awk '{print $2}' | tr -d '"\\')
    local token=$(grep "token:" "$kubeconfig_file" | head -1 | awk '{print $2}' | tr -d '"')

    if [[ -z "$server" ]]; then
        warn "Could not extract server URL for $cluster_name"
        return
    fi

    # Create cluster secret
    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$cluster_name
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: $cluster_name
  server: $server
  config: |
    {
      "bearerToken": "$token",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "$ca_data"
      }
    }
EOF

    log "Cluster $cluster_name added to ArgoCD"
}

# Create the OCM Placement generator ConfigMap
create_placement_generator() {
    log "Creating OCM Placement generator ConfigMap..."

    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: acm-placement
  namespace: argocd
data:
  resource: placementdecisions.cluster.open-cluster-management.io
  statusListKey: status.decisions
  matchKey: clusterName
EOF

    log "Placement generator ConfigMap created"
}

# Grant ArgoCD permissions to read PlacementDecisions
grant_permissions() {
    log "Granting ArgoCD permissions to read PlacementDecisions..."

    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-placementdecision-reader
rules:
- apiGroups:
  - cluster.open-cluster-management.io
  resources:
  - placementdecisions
  verbs:
  - get
  - list
  - watch
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-placementdecision-reader
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: argocd-placementdecision-reader
subjects:
- kind: ServiceAccount
  name: argocd-applicationset-controller
  namespace: argocd
EOF

    log "Permissions granted"
}

# Create a test project for DR apps
create_dr_project() {
    log "Creating ArgoCD project for DR applications..."

    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: dr-apps
  namespace: argocd
spec:
  description: "DR-protected applications"
  sourceRepos:
  - '*'
  destinations:
  - namespace: '*'
    server: '*'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
  namespaceResourceWhitelist:
  - group: '*'
    kind: '*'
EOF

    log "DR project created"
}

# Configure ApplicationSet controller for multi-namespace support
configure_applicationset_controller() {
    log "Configuring ApplicationSet controller for multi-namespace support..."

    # Add the allowed namespaces to argocd-cmd-params-cm
    kubectl --context "$HUB_CONTEXT" patch configmap argocd-cmd-params-cm -n argocd --type=merge \
        -p '{"data":{"applicationsetcontroller.allowed.namespaces":"argocd,ramen-test"}}'

    # Patch the deployment to add required args
    # Note: This disables SCM providers which is required for multi-namespace support
    kubectl --context "$HUB_CONTEXT" patch deployment argocd-applicationset-controller -n argocd --type='json' -p='[
      {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--applicationset-namespaces=argocd,ramen-test"},
      {"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--enable-scm-providers=false"}
    ]' 2>/dev/null || log "Args already configured"

    # Wait for rollout
    kubectl --context "$HUB_CONTEXT" rollout status deployment argocd-applicationset-controller -n argocd --timeout=90s

    log "ApplicationSet controller configured"
}

# Main
main() {
    echo ""
    log "=== ArgoCD OCM Integration Setup ==="
    echo ""

    check_prerequisites
    configure_ocm_integration

    # Add managed clusters
    add_cluster "harv" "$KUBECONFIGS_DIR/harv_r211_kubeconfig.yaml"
    add_cluster "marv" "$KUBECONFIGS_DIR/marv_n70_kubeconfig.yaml"

    create_placement_generator
    grant_permissions
    create_dr_project
    configure_applicationset_controller

    echo ""
    log "=== Setup Complete ==="
    echo ""
    log "ArgoCD is now configured for DR applications."
    echo ""
    log "NOTE: The ClusterDecisionResource generator has a known limitation where it"
    log "      only looks for PlacementDecisions in the argocd namespace."
    log "      For production use, consider using the Cluster generator with labels:"
    echo ""
    log "Example using Cluster generator (recommended):"
    echo "  generators:"
    echo "  - clusters:"
    echo "      selector:"
    echo "        matchLabels:"
    echo "          ramen.dr/enabled: \"true\""
    echo ""
    log "To enable DR for a cluster, label its secret:"
    echo "  kubectl label secret cluster-harv -n argocd ramen.dr/enabled=true"
}

main "$@"
