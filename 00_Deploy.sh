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
    csv=$(oc get subscription.operators.coreos.com "$name" -n "$namespace" \
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

# Wait for MultiClusterHub to reach Running phase
wait_for_multiclusterhub() {
  local name=$1 namespace=$2 timeout=${3:-1200}
  local interval=30 elapsed=0
  log "Waiting for MultiClusterHub '$name' in '$namespace' (timeout: ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    local phase
    phase=$(oc get multiclusterhub "$name" -n "$namespace" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
    if [ "$phase" = "Running" ]; then
      log "  MultiClusterHub '$name' is Running"
      return 0
    fi
    log "  MultiClusterHub phase: ${phase:-Unknown} (${elapsed}s elapsed)"
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  die "Timed out waiting for MultiClusterHub '$name' in '$namespace'"
}

# Wait for CRD to be available
wait_for_crd() {
  local crd=$1 timeout=${2:-300}
  local interval=10 elapsed=0
  log "Waiting for CRD '$crd' to be available (timeout: ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    if oc get crd "$crd" &>/dev/null; then
      log "  CRD '$crd' is available"
      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done
  die "Timed out waiting for CRD '$crd'"
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
oc_create -f 02_Operators/01_subscription_advanced-cluster-management.yaml
oc_create -f 02_Operators/02_subscription_gitops-operator.yaml
wait_for_subscription acm-operator-subscription  open-cluster-management        900
wait_for_subscription openshift-gitops-operator  openshift-gitops-operator      600

# ── Phase 3: Observability ────────────────────────────────────────────────────
log "--- Phase 3: Observability ---"
oc_create -f 03_Observability/01_namespace.yaml
run_script "03_Observability/02_pullSecret.sh"

# Create MultiClusterHub and wait for it to be ready
log "--- Creating MultiClusterHub ---"
oc_create -f 03_Observability/03_multiclusterhub.yaml
wait_for_multiclusterhub multiclusterhub open-cluster-management 1200

# Ensure observability CRD is available
wait_for_crd multiclusterobservabilities.observability.open-cluster-management.io

oc_create -f 03_Observability/03_objectclaim.yaml
run_script "03_Observability/04_bucketsecret.sh"
oc_create -f 03_Observability/05_MultiClusterObservability.yaml

# ── Phase 4: Enable ApplicationSet in Any Namespace ───────────────────────────
log "--- Phase 4: Enable ApplicationSet in Any Namespace ---"
MULTICLOUD_REPO_DIR="${SCRIPT_DIR}/multicloud-integrations"

# Clone the multicloud-integrations repo if not already present
if [ ! -d "$MULTICLOUD_REPO_DIR" ]; then
  log "Cloning multicloud-integrations repository..."
  git clone https://github.com/stolostron/multicloud-integrations.git "$MULTICLOUD_REPO_DIR" \
    || die "Failed to clone multicloud-integrations repository"
else
  log "Repository already exists at $MULTICLOUD_REPO_DIR (skipping clone)"
fi

# Run the ApplicationSet setup script
log "Running setup-appset-any-namespace.sh..."
cd "${MULTICLOUD_REPO_DIR}/deploy/appset-any-namespace"
bash ./setup-appset-any-namespace.sh --namespace openshift-gitops --argocd-name openshift-gitops \
  || die "Failed to enable ApplicationSet in any namespace"
cd "$SCRIPT_DIR"

# Create ManagedClusterSetBinding
log "Creating ManagedClusterSetBinding..."
oc_create -f 03_Observability/06_managedclustersetbinding.yaml

# Create Placement for all OpenShift clusters
log "Creating Placement for all OpenShift clusters..."
oc_create -f 03_Observability/07_placement.yaml

# Create GitOpsCluster to import ACM managed clusters into ArgoCD
log "Creating GitOpsCluster..."
oc_create -f 03_Observability/08_gitopscluster.yaml

# Create Policy to enable Application resource in any namespace on managed clusters
log "Creating ArgoCD policy for managed clusters..."
oc_create -f 03_Observability/09_argocd_policy.yaml

# Create PlacementBinding for ArgoCD policy
log "Creating PlacementBinding for ArgoCD policy..."
oc_create -f 03_Observability/09a_argocd_policy_placementbinding.yaml

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

# Create example Placement that excludes local cluster
log "Creating example Placement (excludes local cluster)..."
oc_create -f 03_Observability/10_placement_example.yaml

# Create appset-2 namespace for example ApplicationSet
log "Creating appset-2 namespace..."
oc_create -f 03_Observability/11_appset_namespace.yaml

# Create example ApplicationSet (helloworld app)
log "Creating example ApplicationSet (helloworld)..."
oc_create -f 03_Observability/12_applicationset_example.yaml

# ── Phase 5: ACM Grafana Developer Instance ───────────────────────────────────
log "--- Phase 5: Enable ACM Grafana Developer Instance ---"
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
bash ./setup-grafana-dev.sh --deploy || die "Failed to deploy Grafana developer instance"
cd "$SCRIPT_DIR"

log "=== Deployment complete ==="
