#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Policy Deployment Script
# ──────────────────────────────────────────────────────────────────────────────
# This script deploys ACM policies for the three pillars of observability:
#   - Logging operators and stack (Loki, COO, Logging)
#   - MCG/NooBaa storage
#   - Tracing operators and stack (OpenTelemetry, Tempo)
#
# Prerequisites:
#   - Hub cluster deployment complete (000_Deploy_Hub.sh)
#   - Managed clusters imported (001_Import_Clusters.sh)
#   - PolicyGenerator plugin installed
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy-policies-$(date +%Y%m%d-%H%M%S).log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
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
# Error trap
# ──────────────────────────────────────────────────────────────────────────────
trap 'log "FATAL: policy deployment aborted at line $LINENO (exit code $?)"' ERR

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

log "=== Starting Policy Deployment (log: $LOG_FILE) ==="

# Check prerequisites
if ! oc get multiclusterhub -n open-cluster-management &>/dev/null; then
  die "MultiClusterHub not found. Run 000_Deploy_Hub.sh first."
fi

CLUSTER_COUNT=$(oc get managedclusters -o name 2>/dev/null | wc -l)
if [ "$CLUSTER_COUNT" -eq 0 ]; then
  log "WARNING: No managed clusters found"
  log "Import clusters using 001_Import_Clusters.sh before deploying policies"
  read -p "Continue anyway? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    die "Deployment cancelled"
  fi
else
  log "Found $CLUSTER_COUNT managed cluster(s)"
fi

# ── Create Policies Namespace and ManagedClusterSetBinding ────────────────────
log "--- Setting up Policies Namespace ---"

log "Creating policies namespace..."
oc_create -f 06_Logging_Policy/00_namespace.yaml

log "Creating ManagedClusterSetBinding in policies namespace..."
oc_create -f 06_Logging_Policy/00_managedclustersetbinding.yaml

# ── Deploy MCG/NooBaa Storage Policies ─────────────────────────────────────────
log "--- Deploying MCG/NooBaa Storage Policies ---"
log "MCG and NooBaa are prerequisites for Loki and Tempo storage"

if [ ! -f "08_MCG_Policy/generated/mcg-policies.yaml" ]; then
  log "Generating MCG policies..."
  cd 08_MCG_Policy
  oc kustomize . --enable-alpha-plugins > generated/mcg-policies.yaml || die "Failed to generate MCG policies"
  cd ..
fi

log "Applying MCG policies..."
oc apply -f 08_MCG_Policy/generated/mcg-policies.yaml

# ── Deploy Logging Operators Policies ──────────────────────────────────────────
log "--- Deploying Logging Operators Policies ---"

if [ ! -f "06_Logging_Policy/generated/logging-policies.yaml" ]; then
  log "Generating logging operator policies..."
  cd 06_Logging_Policy
  oc kustomize . --enable-alpha-plugins > generated/logging-policies.yaml || die "Failed to generate logging policies"
  cd ..
fi

log "Applying logging operator policies..."
oc apply -f 06_Logging_Policy/generated/logging-policies.yaml

# ── Deploy Logging Stack Policies ──────────────────────────────────────────────
log "--- Deploying Logging Stack Policies ---"

if [ ! -f "07_LoggingStack_Policy/generated/logging-stack-policies.yaml" ]; then
  log "Generating logging stack policies..."
  cd 07_LoggingStack_Policy
  oc kustomize . --enable-alpha-plugins > generated/logging-stack-policies.yaml || die "Failed to generate logging stack policies"
  cd ..
fi

log "Applying logging stack policies..."
oc apply -f 07_LoggingStack_Policy/generated/logging-stack-policies.yaml

# ── Deploy Tracing Operators Policies ──────────────────────────────────────────
log "--- Deploying Tracing Operators Policies ---"

if [ ! -f "09_Tracing_Operators_Policy/generated/tracing-operators-policies.yaml" ]; then
  log "Generating tracing operator policies..."
  cd 09_Tracing_Operators_Policy
  oc kustomize . --enable-alpha-plugins > generated/tracing-operators-policies.yaml || die "Failed to generate tracing operator policies"
  cd ..
fi

log "Applying tracing operator policies..."
oc apply -f 09_Tracing_Operators_Policy/generated/tracing-operators-policies.yaml

# ── Deploy Tracing Stack Policies ──────────────────────────────────────────────
log "--- Deploying Tracing Stack Policies ---"

if [ ! -f "10_Tracing_Stack_Policy/generated/tracing-stack-policies.yaml" ]; then
  log "Generating tracing stack policies..."
  cd 10_Tracing_Stack_Policy
  oc kustomize . --enable-alpha-plugins > generated/tracing-stack-policies.yaml || die "Failed to generate tracing stack policies"
  cd ..
fi

log "Applying tracing stack policies..."
oc apply -f 10_Tracing_Stack_Policy/generated/tracing-stack-policies.yaml

# ── Verify Policy Deployment ───────────────────────────────────────────────────
log "--- Verifying Policy Deployment ---"
log ""

sleep 5

TOTAL_POLICIES=$(oc get policies -n policies --no-headers 2>/dev/null | wc -l)
log "Total policies deployed: $TOTAL_POLICIES"
log ""

log "Policy compliance status:"
oc get policies -n policies -o custom-columns='NAME:.metadata.name,STATE:.status.compliant' 2>/dev/null || log "Unable to fetch policy status"

log ""
log "=== Policy Deployment Complete ==="
log ""
log "Next steps:"
log "  1. Wait for all policies to reach Compliant state: oc get policies -n policies"
log "  2. Deploy applications: ./002_Deploy_Applications.sh"
log "  3. Monitor policy status: watch -n 10 'oc get policies -n policies'"
log ""
log "Note: Policies have dependencies and will enforce in the correct order:"
log "  - MCG/NooBaa → Logging/Tracing operators → Storage buckets → Stacks"
log ""
