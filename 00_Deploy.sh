#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Utility
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy-$(date +%Y%m%d-%H%M%S).log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

run_script() {
  local script="${SCRIPT_DIR}/$1"
  log "Running: $1"
  bash "$script" || die "Script failed: $1"
}

# oc create wrapper — tolerates "already exists" errors, propagates real ones
oc_create() {
  local output exit_code=0
  output=$(oc create "$@" 2>&1) || exit_code=$?
  if [ $exit_code -eq 0 ]; then
    echo "$output"
  elif echo "$output" | grep -q "already exists"; then
    log "  (already exists — skipping)"
  else
    echo "$output" >&2
    return $exit_code
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Readiness checks
# ──────────────────────────────────────────────────────────────────────────────

# Wait for an OLM Subscription's CSV to reach phase Succeeded
wait_for_subscription() {
  local name=$1 namespace=$2 timeout=${3:-900}
  local interval=60 elapsed=0
  log "Waiting for subscription '$name' in '$namespace' (timeout: ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    local csv phase
    csv=$(oc get subscription "$name" -n "$namespace" \
          -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)
    if [ -n "$csv" ]; then
      phase=$(oc get csv "$csv" -n "$namespace" \
              -o jsonpath='{.status.phase}' 2>/dev/null || true)
      if [ "$phase" = "Succeeded" ]; then
        log "  '$name' ready (CSV: $csv)"
        return 0
      fi
      log "  CSV '$csv' phase: ${phase:-Unknown} (${elapsed}s elapsed)"
    else
      log "  Waiting for installedCSV... (${elapsed}s elapsed)"
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  die "Timed out waiting for subscription '$name' in '$namespace'"
}

# ──────────────────────────────────────────────────────────────────────────────
# Error trap
# ──────────────────────────────────────────────────────────────────────────────
trap 'log "FATAL: deploy aborted at line $LINENO (exit code $?)"' ERR

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

log "=== Starting deployment (log: $LOG_FILE) ==="

# ── Phase 1: MCG Standalone ───────────────────────────────────────────────────
log "--- Phase 1: Install MCG Standalone ---"
oc_create -Rf 01_Install_Odf/01_subscription_mcg.yaml
wait_for_subscription mcg-operator openshift-storage 900

oc_create -Rf 01_Install_Odf/02_noobaa.yaml
run_script "01_Install_Odf/03_postInstall.sh"   # polls until NooBaa is Ready

# ── Phase 2: Operators ────────────────────────────────────────────────────────
log "--- Phase 2: Install Operators ---"
oc_create -Rf 02_Operators/
wait_for_subscription acm-operator-subscription  open-cluster-management        900
wait_for_subscription openshift-gitops-operator  openshift-gitops-operator      600

# ── Phase 3: Observability ────────────────────────────────────────────────────
log "--- Phase 3: Observability ---"
oc_create -f 03_Observability/01_namespace.yaml
run_script "03_Observability/02_pullSecret.sh"
oc_create -f 03_Observability/03_objectclaim.yaml
run_script "03_Observability/04_bucketsecret.sh"
oc_create -f 03_Observability/05_MultiClusterObservability.yaml

log "=== Deployment complete ==="
