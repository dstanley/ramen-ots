#!/bin/bash
# DRPC-Aware App Placement Controller
# Usage: ./app-controller.sh
#
# This controller watches both DRPC status and PlacementDecision to manage
# application lifecycle during DR operations.
#
# Key features:
# 1. Watches DRPC phase to detect Relocate and quiesce app early
# 2. Watches PlacementDecision to deploy app when placement changes
# 3. Removes created-by-ramen label from PVC to enable protection
#
# This solves the Relocate deadlock where final sync needs the PVC unmounted,
# but PlacementDecision doesn't change until after final sync completes.

set -e

NAMESPACE="${DR_NAMESPACE:-ramen-test}"
PLACEMENT="${PLACEMENT_NAME:-rto-rpo-test-placement}"
DRPC_NAME="${DRPC_NAME:-rto-rpo-test-drpc}"
HUB_CONTEXT="${HUB_CONTEXT:-rke2}"
APP_NAME="${APP_NAME:-rto-rpo-test}"
PVC_NAME="${PVC_NAME:-rto-rpo-data}"
LOG_FILE="/tmp/app-controller.log"

LAST_CLUSTER=""
RELOCATE_QUIESCED=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

wait_for_pvc_and_unlabel() {
    local cluster=$1
    log "Waiting for PVC to appear on $cluster..."

    for i in {1..30}; do
        if kubectl --context "$cluster" get pvc "$PVC_NAME" -n "$NAMESPACE" &>/dev/null; then
            log "PVC found! Removing created-by-ramen label..."
            kubectl --context "$cluster" label pvc "$PVC_NAME" -n "$NAMESPACE" \
                ramendr.openshift.io/created-by-ramen- --overwrite 2>/dev/null || true
            return 0
        fi
        sleep 2
    done

    error "ERROR: PVC $PVC_NAME never appeared on $cluster"
    return 1
}

deploy_app() {
    local cluster=$1
    log "=== DEPLOY APP TO $cluster ==="

    # Wait for PVC and unlabel it
    wait_for_pvc_and_unlabel "$cluster"

    # Apply app ManifestWork to hub
    kubectl --context "$HUB_CONTEXT" apply -f - <<EOF
apiVersion: work.open-cluster-management.io/v1
kind: ManifestWork
metadata:
  name: ${APP_NAME}-app
  namespace: $cluster
  labels:
    app: $APP_NAME
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
          TIMESTAMP_FILE="\${DATA_DIR}/timestamps.log"
          WRITE_INTERVAL="\${WRITE_INTERVAL:-1}"
          now_sec() { date +%s; }
          now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
          format_duration() {
            local seconds=\$1
            if [ \$seconds -ge 3600 ]; then
              echo "\$((seconds/3600))h \$(((seconds%3600)/60))m \$((seconds%60))s"
            elif [ \$seconds -ge 60 ]; then
              echo "\$((seconds/60))m \$((seconds%60))s"
            else
              echo "\${seconds}s"
            fi
          }
          echo "=============================================="
          echo "  RTO/RPO Test Application"
          echo "=============================================="
          echo "Hostname: \$(hostname)"
          echo "Start time: \$(now_iso)"
          if [ -f "\${STATE_FILE}" ]; then
            echo ">>> RECOVERY DETECTED <<<"
            LAST_WRITE=\$(grep -o '"last_write_sec":[0-9]*' "\${STATE_FILE}" | cut -d: -f2)
            LAST_HOST=\$(grep -o '"hostname":"[^"]*"' "\${STATE_FILE}" | cut -d: -f2 | tr -d '"')
            PREV_COUNT=\$(grep -o '"write_count":[0-9]*' "\${STATE_FILE}" | cut -d: -f2)
            CURRENT_SEC=\$(now_sec)
            if [ -n "\${LAST_WRITE}" ] && [ "\${LAST_WRITE}" -gt 0 ] 2>/dev/null; then
              RPO_SEC=\$((CURRENT_SEC - LAST_WRITE))
              echo "=== RPO MEASUREMENT ==="
              echo "RPO: \$(format_duration \${RPO_SEC}) (\${RPO_SEC} seconds)"
              echo "Previous host: \${LAST_HOST}"
              echo "Previous writes: \${PREV_COUNT}"
              echo "========================"
              echo "\$(now_iso) RECOVERY rpo_sec=\${RPO_SEC} from_host=\${LAST_HOST}" >> "\${TIMESTAMP_FILE}"
            fi
            echo "----------------------------------------------"
          else
            echo "First run - no previous state found"
          fi
          WRITE_COUNT=0
          INSTANCE_START=\$(now_sec)
          while true; do
            CURRENT_SEC=\$(now_sec)
            WRITE_COUNT=\$((WRITE_COUNT + 1))
            echo "\$(now_iso) WRITE seq=\${WRITE_COUNT} host=\$(hostname)" >> "\${TIMESTAMP_FILE}"
            printf '{"last_write_sec":%d,"last_write_iso":"%s","hostname":"%s","instance_start_sec":%d,"write_count":%d}\n' \\
              "\${CURRENT_SEC}" "\$(now_iso)" "\$(hostname)" "\${INSTANCE_START}" "\${WRITE_COUNT}" > "\${STATE_FILE}.tmp"
            mv "\${STATE_FILE}.tmp" "\${STATE_FILE}"
            [ \$((WRITE_COUNT % 10)) -eq 0 ] && echo "[\$(now_iso)] Writes: \${WRITE_COUNT}"
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
            volumes:
            - name: data
              persistentVolumeClaim:
                claimName: $PVC_NAME
            - name: scripts
              configMap:
                name: ${APP_NAME}-scripts
                defaultMode: 0755
EOF
    log "App ManifestWork applied to $cluster"
}

remove_app() {
    local cluster=$1
    log "=== REMOVE APP FROM $cluster ==="
    kubectl --context "$HUB_CONTEXT" delete manifestwork "${APP_NAME}-app" -n "$cluster" --ignore-not-found 2>/dev/null || true
}

cleanup() {
    log "Shutting down app controller..."
    exit 0
}

trap cleanup SIGINT SIGTERM

# Main loop
log "=== RTO/RPO App Placement Controller Started ==="
log "Namespace: $NAMESPACE"
log "DRPC: $DRPC_NAME"
log "Placement: $PLACEMENT"
log "Log file: $LOG_FILE"
echo ""

while true; do
    # 1. MEDIATION STEP: Watch DRPC status for Relocate operations
    DRPC_PHASE=$(kubectl --context "$HUB_CONTEXT" get drpc "$DRPC_NAME" -n "$NAMESPACE" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [[ "$DRPC_PHASE" == "Relocating" && -n "$LAST_CLUSTER" && "$RELOCATE_QUIESCED" != "$LAST_CLUSTER" ]]; then
        warn "*** DRPC RELOCATING DETECTED ***"
        log "Relocation Handshake: Quiescing app on $LAST_CLUSTER to allow Final Sync..."
        remove_app "$LAST_CLUSTER"
        RELOCATE_QUIESCED="$LAST_CLUSTER"
    fi

    # Reset quiesce flag when not relocating
    if [[ "$DRPC_PHASE" != "Relocating" && "$DRPC_PHASE" != "Initiating" ]]; then
        RELOCATE_QUIESCED=""
    fi

    # 2. PLACEMENT STEP: Standard placement-based deployment
    CURRENT_CLUSTER=$(kubectl --context "$HUB_CONTEXT" get placementdecision -n "$NAMESPACE" \
        -l cluster.open-cluster-management.io/placement="$PLACEMENT" \
        -o jsonpath='{.items[0].status.decisions[0].clusterName}' 2>/dev/null || echo "")

    if [[ -n "$CURRENT_CLUSTER" && "$CURRENT_CLUSTER" != "$LAST_CLUSTER" ]]; then
        log "*** PLACEMENT CHANGED: $LAST_CLUSTER -> $CURRENT_CLUSTER ***"

        # Only remove if we haven't already (during Relocate quiesce)
        if [[ -n "$LAST_CLUSTER" && "$RELOCATE_QUIESCED" != "$LAST_CLUSTER" ]]; then
            remove_app "$LAST_CLUSTER"
        fi

        deploy_app "$CURRENT_CLUSTER"
        LAST_CLUSTER="$CURRENT_CLUSTER"
        RELOCATE_QUIESCED=""  # Reset after successful deployment
    fi

    sleep 2
done
