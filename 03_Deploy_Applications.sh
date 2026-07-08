#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Application Deployment - Phase 5
# ──────────────────────────────────────────────────────────────────────────────
# This script deploys ApplicationSets and configures managed clusters:
#   - Enables governance addons on managed clusters
#   - Deploys testapp-threepilars ApplicationSet
#   - Deploys RBAC to managed clusters
#   - Sets up Grafana developer instance
#
# Prerequisites:
#   - Hub cluster deployment complete (00_Deploy_Hub.sh)
#   - Managed clusters imported (01_Import_Clusters.sh)
# ──────────────────────────────────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# Utility
# ──────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/deploy-apps-$(date +%Y%m%d-%H%M%S).log"

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
trap 'log "FATAL: application deployment aborted at line $LINENO (exit code $?)"' ERR

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"

log "=== Starting Application Deployment (log: $LOG_FILE) ==="

# Check prerequisites
if ! oc get multiclusterhub -n open-cluster-management &>/dev/null; then
  die "MultiClusterHub not found. Run 00_Deploy_Hub.sh first."
fi

CLUSTER_COUNT=$(oc get managedclusters -o name 2>/dev/null | wc -l)
if [ "$CLUSTER_COUNT" -eq 0 ]; then
  log "WARNING: No managed clusters found"
  log "Import clusters using 01_Import_Clusters.sh before deploying applications"
  read -p "Continue anyway? (y/N): " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    die "Deployment cancelled"
  fi
else
  log "Found $CLUSTER_COUNT managed cluster(s)"
fi

# ── Enable Governance Addons on Managed Clusters ──────────────────────────────
log "--- Enabling Governance Addons on Managed Clusters ---"

# Enable governance-policy-framework addon on managed clusters
log "Enabling governance-policy-framework addon on managed clusters..."
for cluster in $(oc get managedclusters -o jsonpath='{.items[*].metadata.name}'); do
  log "  Enabling governance-policy-framework on cluster: $cluster"
  cat <<EOF | oc_create -f - 2>&1 | grep -v "already exists" || true
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: governance-policy-framework
  namespace: $cluster
spec:
  installNamespace: open-cluster-management-agent-addon
EOF
done

# Enable config-policy-controller addon on managed clusters
log "Enabling config-policy-controller addon on managed clusters..."
for cluster in $(oc get managedclusters -o jsonpath='{.items[*].metadata.name}'); do
  log "  Enabling config-policy-controller on cluster: $cluster"
  cat <<EOF | oc_create -f - 2>&1 | grep -v "already exists" || true
apiVersion: addon.open-cluster-management.io/v1alpha1
kind: ManagedClusterAddOn
metadata:
  name: config-policy-controller
  namespace: $cluster
spec:
  installNamespace: open-cluster-management-agent-addon
EOF
done

# ── Deploy Testapp-threepilars ApplicationSet ─────────────────────────────────
log "--- Deploying Testapp-threepilars ApplicationSet ---"

# Create testapp-threepilars namespace (for ManagedClusterSetBinding)
log "Creating testapp-threepilars namespace..."
oc_create -f 05_Testapp-threepilars/01_namespace.yaml

# Create Placement for testapp in openshift-gitops namespace
# (ApplicationSet controller searches for PlacementDecisions in openshift-gitops)
log "Creating Placement for testapp in openshift-gitops..."
oc_create -f 05_Testapp-threepilars/02_placement.yaml

# Create ManagedClusterSetBinding in testapp-threepilars namespace
log "Creating ManagedClusterSetBinding in testapp-threepilars namespace..."
oc_create -f 05_Testapp-threepilars/03_managedclustersetbinding.yaml

# Create RBAC for ApplicationSet controller in testapp-threepilars namespace
log "Creating RBAC for ApplicationSet controller in testapp-threepilars namespace..."
oc_create -f 05_Testapp-threepilars/04_rbac.yaml

# Patch ApplicationSet controller ClusterRole
log "Patching ApplicationSet controller ClusterRole..."
oc apply -f 05_Testapp-threepilars/06_clusterrole_patch.yaml

# Create testapp-threepilars ApplicationSet in openshift-gitops namespace
log "Creating testapp-threepilars ApplicationSet in openshift-gitops..."
oc_create -f 05_Testapp-threepilars/05_applicationset.yaml

# Create RBAC ManifestWorks for testapp on managed clusters
log "Creating RBAC ManifestWorks for testapp..."
oc apply -f 05_Testapp-threepilars/08_rbac_manifestwork.yaml
oc apply -f 05_Testapp-threepilars/09_rbac_manifestwork_local.yaml

# Wait for ApplicationSet to generate applications
log "Waiting for ApplicationSet to generate applications..."
sleep 15
TESTAPP_COUNT=$(oc get application.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | grep testapp | wc -l)
log "  testapp-threepilars ApplicationSet generated $TESTAPP_COUNT application(s)"

if [ "$TESTAPP_COUNT" -gt 0 ]; then
  log "Generated applications:"
  oc get application.argoproj.io -n openshift-gitops | grep testapp
fi

# ── ACM Grafana Developer Instance ────────────────────────────────────────────
log "--- Setting up ACM Grafana Developer Instance ---"
GRAFANA_REPO_DIR="${SCRIPT_DIR}/multicluster-observability-operator"

# Clone the multicluster-observability-operator repo if not already present
if [ ! -d "$GRAFANA_REPO_DIR" ]; then
  log "Cloning multicluster-observability-operator repository..."
  git clone https://github.com/open-cluster-management/multicluster-observability-operator.git "$GRAFANA_REPO_DIR" \
    || die "Failed to clone multicluster-observability-operator repository"
else
  log "Repository already exists at $GRAFANA_REPO_DIR (skipping clone)"
fi

# Run the Grafana dev setup script
log "Running setup-grafana-dev.sh..."
cd "${GRAFANA_REPO_DIR}/tools"
bash ./setup-grafana-dev.sh --deploy || log "WARNING: Grafana setup failed (non-fatal)"
cd "$SCRIPT_DIR"

log "=== Application Deployment Complete ==="
log ""
log "Next steps:"
log "  1. Verify ApplicationSet status: oc get applicationset -n openshift-gitops"
log "  2. Check generated Applications: oc get application -n openshift-gitops"
log "  3. View managed cluster deployments: oc get managedclusters"
log "  4. Access Grafana for observability dashboards"
log ""
log "To test the testapp-threepilars observability:"
log "  - Find the route: oc get route -n testapp-threepilars-app"
log "  - Hit /ping endpoint to increment metrics"
log "  - Check metrics in Grafana: query 'ping_request_count'"
log "  - Verify alerts fire when count > 0 for 1 minute"
log ""
