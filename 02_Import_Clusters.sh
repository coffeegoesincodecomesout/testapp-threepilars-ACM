#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Managed Cluster Import Script
# ──────────────────────────────────────────────────────────────────────────────
# This script automates the import of managed clusters into ACM using clusteradm.
#
# Prerequisites:
#   - Hub cluster deployment complete (00_Deploy_Hub.sh)
#   - clusteradm CLI installed (https://open-cluster-management.io/getting-started/installation/start-the-control-plane/)
#   - Access to managed cluster kubeconfigs
#
# Usage:
#   ./01_Import_Clusters.sh <cluster1-name> <cluster2-name> ...
#
# Or interactively (will prompt for cluster names and kubeconfigs):
#   ./01_Import_Clusters.sh
# ──────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${SCRIPT_DIR}/import-clusters-$(date +%Y%m%d-%H%M%S).log"

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_FILE"
}

die() {
  log "ERROR: $*"
  exit 1
}

# ──────────────────────────────────────────────────────────────────────────────
# Check prerequisites
# ──────────────────────────────────────────────────────────────────────────────

log "=== Cluster Import Script (log: $LOG_FILE) ==="

# Check if clusteradm is installed
if ! command -v clusteradm &> /dev/null; then
  log "ERROR: clusteradm is not installed"
  log "Install it from: https://open-cluster-management.io/getting-started/installation/start-the-control-plane/"
  log ""
  log "Quick install:"
  log "  curl -L https://raw.githubusercontent.com/open-cluster-management-io/clusteradm/main/install.sh | bash"
  die "clusteradm not found"
fi

# Check if we're connected to the hub cluster
if ! oc get multiclusterhub -n open-cluster-management &>/dev/null; then
  die "Not connected to ACM hub cluster. Run 'oc login' to connect to your hub cluster first."
fi

log "Prerequisites check passed"
log ""

# ──────────────────────────────────────────────────────────────────────────────
# Import clusters
# ──────────────────────────────────────────────────────────────────────────────

if [ $# -eq 0 ]; then
  # Interactive mode
  log "=== Interactive Cluster Import ==="
  log ""
  read -p "Enter managed cluster names (space-separated): " -a CLUSTER_NAMES
else
  # Command-line arguments
  CLUSTER_NAMES=("$@")
fi

if [ ${#CLUSTER_NAMES[@]} -eq 0 ]; then
  die "No cluster names provided"
fi

log "Will import ${#CLUSTER_NAMES[@]} cluster(s): ${CLUSTER_NAMES[*]}"
log ""

# Generate join token from hub cluster
log "Generating join token from hub cluster..."
TOKEN_OUTPUT=$(clusteradm get token --use-bootstrap-token 2>&1) || die "Failed to generate token"
log "Token generated successfully"

# Extract the join command from the output
JOIN_CMD=$(echo "$TOKEN_OUTPUT" | grep "clusteradm join" | head -1)

if [ -z "$JOIN_CMD" ]; then
  log "Token output:"
  log "$TOKEN_OUTPUT"
  die "Could not extract join command from clusteradm output"
fi

log "Join command template: $JOIN_CMD"
log ""

# Import each cluster
for CLUSTER_NAME in "${CLUSTER_NAMES[@]}"; do
  log "──────────────────────────────────────────────────────────"
  log "Importing cluster: $CLUSTER_NAME"
  log "──────────────────────────────────────────────────────────"

  # Prompt for kubeconfig path
  read -p "Enter kubeconfig path for $CLUSTER_NAME (or press Enter to use current context): " KUBECONFIG_PATH

  if [ -n "$KUBECONFIG_PATH" ]; then
    if [ ! -f "$KUBECONFIG_PATH" ]; then
      log "WARNING: Kubeconfig file not found: $KUBECONFIG_PATH"
      log "Skipping cluster $CLUSTER_NAME"
      continue
    fi
    KUBECONFIG_ARG="--kubeconfig $KUBECONFIG_PATH"
  else
    KUBECONFIG_ARG=""
    log "Using current kubeconfig context"
  fi

  # Build the join command with the cluster name
  CLUSTER_JOIN_CMD="$JOIN_CMD --cluster-name $CLUSTER_NAME --wait --force-internal-endpoint-lookup"

  log "Running join command on managed cluster $CLUSTER_NAME..."
  if eval "$CLUSTER_JOIN_CMD $KUBECONFIG_ARG"; then
    log "Join request submitted for $CLUSTER_NAME"
  else
    log "WARNING: Failed to join cluster $CLUSTER_NAME"
    continue
  fi

  # Accept the cluster on the hub
  log "Accepting cluster $CLUSTER_NAME on hub..."
  sleep 5  # Give the hub a moment to receive the join request

  if clusteradm accept --clusters "$CLUSTER_NAME" --wait 30; then
    log "✓ Cluster $CLUSTER_NAME imported successfully"
  else
    log "WARNING: Failed to accept cluster $CLUSTER_NAME"
    log "You may need to manually accept it with: clusteradm accept --clusters $CLUSTER_NAME"
  fi

  log ""
done

# ──────────────────────────────────────────────────────────────────────────────
# Verify imported clusters
# ──────────────────────────────────────────────────────────────────────────────

log "=== Verifying Imported Clusters ==="
log ""

IMPORTED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -z "$IMPORTED_CLUSTERS" ]; then
  log "WARNING: No managed clusters found"
else
  log "Managed clusters:"
  for cluster in $IMPORTED_CLUSTERS; do
    STATUS=$(oc get managedcluster "$cluster" -o jsonpath='{.status.conditions[?(@.type=="ManagedClusterConditionAvailable")].status}' 2>/dev/null || echo "Unknown")
    log "  - $cluster (Available: $STATUS)"
  done
fi

log ""
log "=== Cluster Import Complete ==="
log ""
log "Next steps:"
log "  1. Verify cluster status: oc get managedclusters"
log "  2. Deploy applications: ./02_Deploy_Applications.sh"
log ""
