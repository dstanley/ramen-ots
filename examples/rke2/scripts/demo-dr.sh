#!/bin/bash
# Unified DR Demo Script
# Usage: ./demo-dr.sh [command] [options]
#
# This script provides a unified interface for demonstrating Ramen DR
# with different deployment models:
#   - manifestwork: Direct ManifestWork-based deployment (simplest)
#   - argocd: ArgoCD ApplicationSet with OCM Placement
#   - fleet: Rancher Fleet GitRepo with cluster label targeting
#
# The script manages the full lifecycle: deploy, failover, relocate, cleanup

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLES_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration
NAMESPACE="${DR_NAMESPACE:-ramen-test}"
DRPC_NAME="${DRPC_NAME:-rto-rpo-test-drpc}"
PLACEMENT_NAME="${PLACEMENT_NAME:-rto-rpo-test-placement}"
APP_NAME="${APP_NAME:-rto-rpo-test}"
PVC_NAME="${PVC_NAME:-rto-rpo-data}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"

# Deployment model: manifestwork or argocd
DEPLOYMENT_MODEL="${DEPLOYMENT_MODEL:-manifestwork}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $1"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)]${NC} $1"; }
error() { echo -e "${RED}[$(date +%H:%M:%S)]${NC} $1"; }
info() { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
header() { echo -e "\n${BLUE}=== $1 ===${NC}\n"; }

usage() {
    cat << EOF
Usage: $0 <command> [options]

Commands:
  deploy [cluster]    Deploy the test app and enable DR protection
  failover [cluster]  Trigger failover to specified cluster
  relocate [cluster]  Trigger relocate to specified cluster
  status              Show current DR and app status
  cleanup             Remove all DR resources and app
  watch               Watch DR operations in real-time

Options:
  --model <type>      Deployment model: manifestwork (default), argocd, or fleet
  --namespace <ns>    Namespace for DR resources (default: ramen-test)
  --help              Show this help

Environment Variables:
  DEPLOYMENT_MODEL    Set deployment model (manifestwork/argocd/fleet)
  HUB_CONTEXT         kubectl context for hub cluster (default: rke2)
  DR_NAMESPACE        Namespace for DR resources (default: ramen-test)

Examples:
  # Deploy with ManifestWork model
  $0 deploy harv --model manifestwork

  # Deploy with ArgoCD model
  $0 deploy harv --model argocd

  # Deploy with Fleet model
  $0 deploy harv --model fleet

  # Failover to marv
  $0 failover marv

  # Watch DR status
  $0 watch
EOF
}

get_clusters() {
    kubectl --context "$HUB_CONTEXT" get drpolicy -o jsonpath='{.items[0].spec.drClusters[*]}' 2>/dev/null || echo "harv marv"
}

get_current_cluster() {
    kubectl --context "$HUB_CONTEXT" get placementdecision -n "$NAMESPACE" \
        -l cluster.open-cluster-management.io/placement="$PLACEMENT_NAME" \
        -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null || echo ""
}

get_drpc_status() {
    kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}/{.status.progression}' 2>/dev/null || echo "NotFound"
}

wait_for_pvc() {
    local cluster=$1
    log "Waiting for PVC $PVC_NAME on $cluster..."
    for i in {1..60}; do
        if kubectl --context "$cluster" get pvc "$PVC_NAME" -n "$NAMESPACE" &>/dev/null; then
            log "PVC ready"
            # Remove created-by-ramen label to enable protection
            kubectl --context "$cluster" label pvc "$PVC_NAME" -n "$NAMESPACE" \
                ramendr.openshift.io/created-by-ramen- --overwrite 2>/dev/null || true
            return 0
        fi
        sleep 2
    done
    error "Timeout waiting for PVC"
    return 1
}

deploy_app_manifestwork() {
    local cluster=$1
    header "Deploying App via ManifestWork to $cluster"

    # Create app ManifestWork
    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: ${APP_NAME}-app
  namespace: $cluster
  labels:
    app: $APP_NAME
    drpc: $DRPC_NAME
spec:
  workload:
    manifests:
    - apiVersion: v1
      kind: ConfigMap
      metadata:
        name: ${APP_NAME}-scripts
        namespace: $NAMESPACE
      data:
        rto-rpo-writer.sh: |
          #!/bin/sh
          set -e
          DATA_DIR="/data"
          STATE_FILE="\${DATA_DIR}/state.json"
          WRITE_INTERVAL="\${WRITE_INTERVAL:-1}"
          now_sec() { date +%s; }
          now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
          echo "=============================================="
          echo "  RTO/RPO Test Application"
          echo "=============================================="
          echo "Hostname: \$(hostname)"
          echo "Start time: \$(now_iso)"
          if [ -f "\${STATE_FILE}" ]; then
            echo ">>> RECOVERY DETECTED <<<"
            LAST_WRITE=\$(grep -o '"last_write_sec":[0-9]*' "\${STATE_FILE}" | cut -d: -f2)
            CURRENT_SEC=\$(now_sec)
            if [ -n "\${LAST_WRITE}" ]; then
              RPO_SEC=\$((CURRENT_SEC - LAST_WRITE))
              echo "RPO: \${RPO_SEC} seconds"
            fi
          fi
          WRITE_COUNT=0
          while true; do
            WRITE_COUNT=\$((WRITE_COUNT + 1))
            printf '{"last_write_sec":%d,"hostname":"%s","write_count":%d}\n' \\
              "\$(now_sec)" "\$(hostname)" "\${WRITE_COUNT}" > "\${STATE_FILE}.tmp"
            mv "\${STATE_FILE}.tmp" "\${STATE_FILE}"
            [ \$((WRITE_COUNT % 30)) -eq 0 ] && echo "[\$(now_iso)] Writes: \${WRITE_COUNT}"
            sleep \${WRITE_INTERVAL}
          done
    - apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: $APP_NAME
        namespace: $NAMESPACE
        labels:
          app: $APP_NAME
      spec:
        replicas: 1
        selector:
          matchLabels:
            app: $APP_NAME
        template:
          metadata:
            labels:
              app: $APP_NAME
          spec:
            containers:
            - name: writer
              image: busybox:1.36
              command: ["/bin/sh", "/scripts/rto-rpo-writer.sh"]
              env:
              - name: WRITE_INTERVAL
                value: "1"
              volumeMounts:
              - name: data
                mountPath: /data
              - name: scripts
                mountPath: /scripts
              resources:
                requests:
                  cpu: 10m
                  memory: 32Mi
            volumes:
            - name: data
              persistentVolumeClaim:
                claimName: $PVC_NAME
            - name: scripts
              configMap:
                name: ${APP_NAME}-scripts
                defaultMode: 0755
EOF
    log "ManifestWork created for $cluster"
}

remove_app_manifestwork() {
    local cluster=$1
    log "Removing app ManifestWork from $cluster..."
    kubectl --context "$HUB_CONTEXT" delete manifestwork "${APP_NAME}-app" -n "$cluster" --ignore-not-found 2>/dev/null || true
}

deploy_dr_resources() {
    local primary_cluster=$1
    header "Deploying DR Resources"

    # Create namespace on hub
    kubectl --context "$HUB_CONTEXT" create namespace "$NAMESPACE" --dry-run=client -o yaml | \
        kubectl --context "$HUB_CONTEXT" apply -f -

    # Ensure ManagedClusterSetBinding exists for policy propagation
    log "Ensuring ManagedClusterSetBinding..."
    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: default
  namespace: $NAMESPACE
spec:
  clusterSet: default
EOF

    # Ensure ManagedClusters have the 'name' label.
    # The OCM PlacementRule controller (used by Ramen to propagate the VolSync
    # PSK secret) selects clusters by label "name=<cluster>" rather than by
    # metadata.name. Upstream OCM (clusteradm) does not set this label
    # automatically, unlike RHACM.
    log "Ensuring ManagedCluster name labels..."
    for cluster in $(kubectl --context "$HUB_CONTEXT" get drpolicy -o jsonpath='{.items[0].spec.drClusters[*]}' 2>/dev/null); do
        kubectl --context "$HUB_CONTEXT" label managedcluster "$cluster" "name=$cluster" --overwrite 2>/dev/null || true
    done

    # Create PVC ManifestWork for primary cluster
    log "Creating PVC on $primary_cluster..."
    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: ${APP_NAME}-pvc
  namespace: $primary_cluster
spec:
  workload:
    manifests:
    - apiVersion: v1
      kind: Namespace
      metadata:
        name: $NAMESPACE
    - apiVersion: v1
      kind: PersistentVolumeClaim
      metadata:
        name: $PVC_NAME
        namespace: $NAMESPACE
        labels:
          appname: $APP_NAME
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
        storageClassName: harvester-longhorn
EOF

    # Wait for PVC
    wait_for_pvc "$primary_cluster"

    # Create Placement
    # Note: The disable annotation is required for Ramen to manage scheduling
    log "Creating Placement..."
    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: cluster.open-cluster-management.io/v1beta1
kind: Placement
metadata:
  name: $PLACEMENT_NAME
  namespace: $NAMESPACE
  annotations:
    cluster.open-cluster-management.io/experimental-scheduling-disable: "true"
spec:
  clusterSets:
  - default
  numberOfClusters: 1
EOF

    # Create DRPlacementControl
    log "Creating DRPlacementControl..."
    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: ramendr.openshift.io/v1alpha1
kind: DRPlacementControl
metadata:
  name: $DRPC_NAME
  namespace: $NAMESPACE
spec:
  drPolicyRef:
    name: dr-policy
  placementRef:
    kind: Placement
    name: $PLACEMENT_NAME
  preferredCluster: $primary_cluster
  pvcSelector:
    matchLabels:
      appname: $APP_NAME
  volSyncSpec:
    moverConfig:
    - pvcName: $PVC_NAME
      pvcNamespace: $NAMESPACE
      moverSecurityContext:
        runAsUser: 65534
        runAsGroup: 65534
        fsGroup: 65534
EOF

    log "Waiting for DRPC to initialize..."
    sleep 5

    # Wait for placement decision
    log "Waiting for PlacementDecision..."
    for i in {1..30}; do
        cluster=$(get_current_cluster)
        if [[ -n "$cluster" ]]; then
            log "PlacementDecision set to: $cluster"
            break
        fi
        sleep 2
    done
}

cmd_deploy() {
    local cluster="${1:-harv}"

    header "Deploying DR-Protected Application"
    info "Deployment Model: $DEPLOYMENT_MODEL"
    info "Primary Cluster: $cluster"
    info "Namespace: $NAMESPACE"

    # Deploy DR resources
    deploy_dr_resources "$cluster"

    # Deploy app based on model
    case "$DEPLOYMENT_MODEL" in
        manifestwork)
            wait_for_pvc "$cluster"
            deploy_app_manifestwork "$cluster"
            log "Starting app controller in background..."
            nohup "$SCRIPT_DIR/app-controller.sh" > /tmp/app-controller.log 2>&1 &
            echo $! > /tmp/app-controller.pid
            log "App controller PID: $(cat /tmp/app-controller.pid)"
            ;;
        argocd)
            log "ArgoCD deployment - ApplicationSet handles app lifecycle"
            log "Ensure argocd-dr-controller.sh is running and ApplicationSet is applied"
            ;;
        fleet)
            log "Fleet deployment - GitRepo handles app lifecycle"
            log "Ensure fleet-dr-controller.sh is running and gitrepo.yaml is applied"
            ;;
        *)
            error "Unknown deployment model: $DEPLOYMENT_MODEL"
            exit 1
            ;;
    esac

    # Wait for app to be running
    log "Waiting for application to start..."
    for i in {1..60}; do
        if kubectl --context "$cluster" get pod -n "$NAMESPACE" -l app="$APP_NAME" 2>/dev/null | grep -q Running; then
            log "Application is running on $cluster"
            echo ""
            kubectl --context "$cluster" get pod -n "$NAMESPACE" -l app="$APP_NAME"
            break
        fi
        sleep 2
    done

    header "Deployment Complete"
    log "Run '$0 status' to check current state"
    log "Run '$0 failover <cluster>' to test failover"
}

cmd_failover() {
    local target="${1:-}"
    local current=$(get_current_cluster)

    if [[ -z "$target" ]]; then
        # Auto-select the other cluster
        for c in $(get_clusters); do
            if [[ "$c" != "$current" ]]; then
                target="$c"
                break
            fi
        done
    fi

    if [[ -z "$target" ]]; then
        error "Could not determine target cluster"
        exit 1
    fi

    header "Initiating Failover"
    info "Current cluster: $current"
    info "Target cluster: $target"
    info "Deployment model: $DEPLOYMENT_MODEL"

    START_TIME=$(date +%s)

    # Trigger failover
    kubectl --context "$HUB_CONTEXT" patch drpc "$DRPC_NAME" -n "$NAMESPACE" --type=merge \
        -p "{\"spec\":{\"action\":\"Failover\",\"failoverCluster\":\"$target\"}}"

    log "Failover initiated, monitoring progress..."

    # Monitor progress
    while true; do
        status=$(get_drpc_status)
        phase=$(echo "$status" | cut -d/ -f1)
        progression=$(echo "$status" | cut -d/ -f2)

        printf "\r[%s] Phase: %-15s Progression: %-30s" "$(date +%H:%M:%S)" "$phase" "$progression"

        if [[ "$phase" == "FailedOver" ]]; then
            echo ""
            END_TIME=$(date +%s)
            DURATION=$((END_TIME - START_TIME))
            header "Failover Complete"
            log "Duration: ${DURATION}s"

            # For ManifestWork model, deploy app to target
            if [[ "$DEPLOYMENT_MODEL" == "manifestwork" ]]; then
                wait_for_pvc "$target"
                deploy_app_manifestwork "$target"
            fi

            # Wait for app and show RPO
            log "Waiting for application on $target..."
            for i in {1..30}; do
                if kubectl --context "$target" get pod -n "$NAMESPACE" -l app="$APP_NAME" 2>/dev/null | grep -q Running; then
                    log "Application running on $target"
                    echo ""
                    log "Application logs (showing RPO):"
                    kubectl --context "$target" logs -n "$NAMESPACE" -l app="$APP_NAME" --tail=20 2>/dev/null || true
                    break
                fi
                sleep 2
            done
            break
        fi

        sleep 3
    done
}

cmd_relocate() {
    local target="${1:-}"
    local current=$(get_current_cluster)

    if [[ -z "$target" ]]; then
        for c in $(get_clusters); do
            if [[ "$c" != "$current" ]]; then
                target="$c"
                break
            fi
        done
    fi

    header "Initiating Relocate (Planned Failback)"
    info "Current cluster: $current"
    info "Target cluster: $target"
    info "Deployment model: $DEPLOYMENT_MODEL"
    warn "Relocate requires app quiescing for final sync"

    START_TIME=$(date +%s)

    # Trigger relocate
    kubectl --context "$HUB_CONTEXT" patch drpc "$DRPC_NAME" -n "$NAMESPACE" --type=merge \
        -p "{\"spec\":{\"action\":\"Relocate\",\"preferredCluster\":\"$target\"}}"

    log "Relocate initiated, monitoring progress..."

    QUIESCED=false
    while true; do
        status=$(get_drpc_status)
        phase=$(echo "$status" | cut -d/ -f1)
        progression=$(echo "$status" | cut -d/ -f2)

        printf "\r[%s] Phase: %-15s Progression: %-30s" "$(date +%H:%M:%S)" "$phase" "$progression"

        # Handle app quiescing for ManifestWork model
        if [[ "$DEPLOYMENT_MODEL" == "manifestwork" && "$QUIESCED" == "false" ]]; then
            if [[ "$phase" == "Relocating" || "$phase" == "Initiating" ]]; then
                echo ""
                log "Quiescing app on $current for final sync..."
                remove_app_manifestwork "$current"
                QUIESCED=true
            fi
        fi

        if [[ "$phase" == "Relocated" ]]; then
            echo ""
            END_TIME=$(date +%s)
            DURATION=$((END_TIME - START_TIME))
            header "Relocate Complete"
            log "Duration: ${DURATION}s"

            # Deploy app to target
            if [[ "$DEPLOYMENT_MODEL" == "manifestwork" ]]; then
                wait_for_pvc "$target"
                deploy_app_manifestwork "$target"
            fi

            # Wait for app
            log "Waiting for application on $target..."
            for i in {1..30}; do
                if kubectl --context "$target" get pod -n "$NAMESPACE" -l app="$APP_NAME" 2>/dev/null | grep -q Running; then
                    log "Application running on $target"
                    kubectl --context "$target" logs -n "$NAMESPACE" -l app="$APP_NAME" --tail=20 2>/dev/null || true
                    break
                fi
                sleep 2
            done
            break
        fi

        sleep 3
    done
}

cmd_status() {
    header "DR Status"

    echo "DRPC:"
    kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
        -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,PROGRESSION:.status.progression,CLUSTER:.status.preferredDecision.clusterName' 2>/dev/null || echo "  Not found"
    echo ""

    echo "PlacementDecision:"
    kubectl --context "$HUB_CONTEXT" get placementdecision -n "$NAMESPACE" \
        -l cluster.open-cluster-management.io/placement="$PLACEMENT_NAME" \
        -o jsonpath='  Cluster: {.items[0].status.decisions[0].clusterName}{"\n"}' 2>/dev/null || echo "  Not found"
    echo ""

    echo "VolumeReplicationGroups:"
    for cluster in $(get_clusters); do
        printf "  %-6s: " "$cluster"
        kubectl --context "$cluster" get vrg -n "$NAMESPACE" \
            -o jsonpath='{.items[0].spec.replicationState}/{.items[0].status.state}' 2>/dev/null || echo "none"
        echo ""
    done
    echo ""

    echo "Application Pods:"
    for cluster in $(get_clusters); do
        printf "  %-6s: " "$cluster"
        kubectl --context "$cluster" get pod -n "$NAMESPACE" -l app="$APP_NAME" \
            -o jsonpath='{.items[0].metadata.name} ({.items[0].status.phase})' 2>/dev/null || echo "none"
        echo ""
    done
    echo ""

    if [[ "$DEPLOYMENT_MODEL" == "manifestwork" ]]; then
        echo "App ManifestWorks:"
        for cluster in $(get_clusters); do
            printf "  %-6s: " "$cluster"
            kubectl --context "$HUB_CONTEXT" get manifestwork "${APP_NAME}-app" -n "$cluster" \
                -o jsonpath='{.metadata.name}' 2>/dev/null || echo "none"
            echo ""
        done
    elif [[ "$DEPLOYMENT_MODEL" == "fleet" ]]; then
        echo "Fleet GitRepo:"
        kubectl --context "$HUB_CONTEXT" get gitrepo "$APP_NAME" -n fleet-default \
            -o custom-columns='NAME:.metadata.name,READY:.status.readyClusters,DESIRED:.status.desiredReadyClusters' 2>/dev/null || echo "  Not found"
        echo ""
        echo "Fleet Cluster Labels:"
        kubectl --context "$HUB_CONTEXT" get clusters.fleet.cattle.io -n fleet-default \
            -o custom-columns='FLEET_ID:.metadata.name,DISPLAY:.metadata.labels.management\.cattle\.io/cluster-display-name,DR_ENABLED:.metadata.labels.ramen\.dr/fleet-enabled' 2>/dev/null || true
    fi
}

cmd_watch() {
    header "Watching DR Operations"
    log "Press Ctrl+C to exit"

    while true; do
        clear
        echo -e "${BLUE}=== DR Status ($(date +%H:%M:%S)) ===${NC}"
        echo ""
        cmd_status
        sleep 3
    done
}

cmd_cleanup() {
    header "Cleaning Up DR Resources"

    # Stop app controller
    if [[ -f /tmp/app-controller.pid ]]; then
        kill $(cat /tmp/app-controller.pid) 2>/dev/null || true
        rm -f /tmp/app-controller.pid
    fi

    # Delete DRPC
    log "Deleting DRPlacementControl..."
    kubectl --context "$HUB_CONTEXT" delete drpc "$DRPC_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

    # Wait for VRGs to be cleaned up
    log "Waiting for VRG cleanup..."
    sleep 10

    # Delete Placement
    log "Deleting Placement..."
    kubectl --context "$HUB_CONTEXT" delete placement "$PLACEMENT_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

    # Delete ManifestWorks
    for cluster in $(get_clusters); do
        log "Cleaning up ManifestWorks for $cluster..."
        kubectl --context "$HUB_CONTEXT" delete manifestwork "${APP_NAME}-app" -n "$cluster" --ignore-not-found 2>/dev/null || true
        kubectl --context "$HUB_CONTEXT" delete manifestwork "${APP_NAME}-pvc" -n "$cluster" --ignore-not-found 2>/dev/null || true
    done

    # Delete namespace on managed clusters
    for cluster in $(get_clusters); do
        log "Cleaning up namespace on $cluster..."
        kubectl --context "$cluster" delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true
    done

    # Delete namespace on hub
    log "Cleaning up hub namespace..."
    kubectl --context "$HUB_CONTEXT" delete namespace "$NAMESPACE" --ignore-not-found 2>/dev/null || true

    header "Cleanup Complete"
}

# Parse arguments
COMMAND=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            DEPLOYMENT_MODEL="$2"
            shift 2
            ;;
        --namespace)
            NAMESPACE="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

set -- "${POSITIONAL_ARGS[@]}"
COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    deploy)
        cmd_deploy "$@"
        ;;
    failover)
        cmd_failover "$@"
        ;;
    relocate)
        cmd_relocate "$@"
        ;;
    status)
        cmd_status
        ;;
    watch)
        cmd_watch
        ;;
    cleanup)
        cmd_cleanup
        ;;
    *)
        usage
        exit 1
        ;;
esac
