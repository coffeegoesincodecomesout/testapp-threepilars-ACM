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

# Configure ArgoCD to watch all namespaces and disable OpenShift OAuth (to avoid dex restart loop)
log "Configuring ArgoCD for multi-namespace support..."
oc patch argocd openshift-gitops -n openshift-gitops --type=merge -p '{"spec":{"sourceNamespaces":["*"],"sso":{"provider":"dex","dex":{"openShiftOAuth":false}}}}' \
  || log "  Warning: Failed to patch ArgoCD (may already be configured)"

# Increase ArgoCD server memory limits
log "Increasing ArgoCD server memory limits..."
oc patch argocd openshift-gitops -n openshift-gitops --type=merge -p '{"spec":{"server":{"resources":{"limits":{"memory":"2Gi"},"requests":{"memory":"512Mi"}}}}}' \
  || log "  Warning: Failed to patch ArgoCD server resources"

# Configure ApplicationSet controller to watch all namespaces
log "Configuring ApplicationSet controller for multi-namespace support..."
oc set env deployment/openshift-gitops-applicationset-controller -n openshift-gitops \
  ARGOCD_APPLICATIONSET_CONTROLLER_NAMESPACES='*' \
  ARGOCD_APPLICATIONSET_CONTROLLER_ENABLE_SCM_PROVIDERS=false \
  || log "  Warning: Failed to set ApplicationSet controller environment variables"

# Wait for ArgoCD components to be ready
log "Waiting for ArgoCD components to be ready..."
oc wait --for=condition=Ready pod -l app.kubernetes.io/name=openshift-gitops-server -n openshift-gitops --timeout=300s || log "  Warning: Timeout waiting for ArgoCD server"
oc wait --for=condition=Ready pod -l app.kubernetes.io/name=openshift-gitops-applicationset-controller -n openshift-gitops --timeout=120s || log "  Warning: Timeout waiting for ApplicationSet controller"

# Create ManagedClusterSetBinding
log "Creating ManagedClusterSetBinding..."
oc_create -f 03_Observability/06_managedclustersetbinding.yaml

# Create Placement for all OpenShift clusters
log "Creating Placement for all OpenShift clusters..."
oc_create -f 03_Observability/07_placement.yaml

# Create GitOpsCluster to import ACM managed clusters into ArgoCD
log "Creating GitOpsCluster..."
oc_create -f 03_Observability/08_gitopscluster.yaml

# Create Policy and PlacementBinding to enable Application resource in any namespace on managed clusters
log "Creating ArgoCD policy and PlacementBinding for managed clusters..."
oc_create -f 03_Observability/09_argocd_policy_merged.yaml

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

# Create Placement in appset-2 namespace
log "Creating Placement in appset-2 namespace..."
oc_create -f 03_Observability/13_appset2_placement.yaml

# Create ManagedClusterSetBinding in appset-2 namespace
log "Creating ManagedClusterSetBinding in appset-2 namespace..."
oc_create -f 03_Observability/14_appset2_managedclustersetbinding.yaml

# Create RBAC for ApplicationSet controller in appset-2 namespace
log "Creating RBAC for ApplicationSet controller in appset-2 namespace..."
oc_create -f 03_Observability/15_appset2_rbac.yaml

# NOTE: Helloworld ApplicationSet is now created in openshift-gitops namespace (Phase 5)
# to work properly with ACM pull model

# ── Phase 5: Testapp-threepilars and Helloworld ApplicationSets ──────────────
log "--- Phase 5: Deploy ApplicationSets ---"

# Create testapp-threepilars namespace (for ManagedClusterSetBinding)
log "Creating testapp-threepilars namespace..."
oc_create -f 04_Testapp-threepilars/01_namespace.yaml

# Create Placement for testapp in openshift-gitops namespace
# (ApplicationSet controller searches for PlacementDecisions in openshift-gitops)
log "Creating Placement for testapp in openshift-gitops..."
oc_create -f 04_Testapp-threepilars/02_placement.yaml

# Create ManagedClusterSetBinding in testapp-threepilars namespace
log "Creating ManagedClusterSetBinding in testapp-threepilars namespace..."
oc_create -f 04_Testapp-threepilars/03_managedclustersetbinding.yaml

# Create RBAC for ApplicationSet controller in testapp-threepilars namespace
log "Creating RBAC for ApplicationSet controller in testapp-threepilars namespace..."
oc_create -f 04_Testapp-threepilars/04_rbac.yaml

# Patch ApplicationSet controller ClusterRole
log "Patching ApplicationSet controller ClusterRole..."
oc apply -f 04_Testapp-threepilars/06_clusterrole_patch.yaml

# Create testapp-threepilars ApplicationSet in openshift-gitops namespace
log "Creating testapp-threepilars ApplicationSet in openshift-gitops..."
oc_create -f 04_Testapp-threepilars/05_applicationset.yaml

# Create helloworld ApplicationSet in openshift-gitops namespace (moved from appset-2)
log "Creating helloworld ApplicationSet in openshift-gitops..."
oc_create -f 03_Observability/12_applicationset_example.yaml

# Create RBAC ManifestWorks for testapp on managed clusters
log "Creating RBAC ManifestWorks for testapp..."
oc apply -f 04_Testapp-threepilars/08_rbac_manifestwork.yaml
oc apply -f 04_Testapp-threepilars/09_rbac_manifestwork_local.yaml

# Create RBAC ManifestWorks for helloworld on managed clusters
log "Creating RBAC ManifestWorks for helloworld..."
oc apply -f 03_Observability/16_helloworld_rbac_manifestwork.yaml
oc apply -f 03_Observability/17_helloworld_rbac_manifestwork_local.yaml

# Wait for ApplicationSets to generate applications
log "Waiting for ApplicationSets to generate applications..."
sleep 15
TESTAPP_COUNT=$(oc get application.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | grep testapp | wc -l)
HELLOWORLD_COUNT=$(oc get application.argoproj.io -n openshift-gitops --no-headers 2>/dev/null | grep helloworld | wc -l)
log "  testapp-threepilars ApplicationSet generated $TESTAPP_COUNT application(s)"
log "  helloworld ApplicationSet generated $HELLOWORLD_COUNT application(s)"

# ── Phase 6: ACM Grafana Developer Instance ───────────────────────────────────
log "--- Phase 6: Enable ACM Grafana Developer Instance ---"
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
