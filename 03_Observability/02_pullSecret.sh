#!/bin/bash
set -euo pipefail

#DOCKER_CONFIG_JSON=`oc extract secret/multiclusterhub-operator-pull-secret -n open-cluster-management --to=-`
DOCKER_CONFIG_JSON=`oc extract secret/pull-secret -n openshift-config --to=-`

# Check if secret already exists
if oc get secret multiclusterhub-operator-pull-secret -n open-cluster-management-observability &>/dev/null; then
    echo "Secret 'multiclusterhub-operator-pull-secret' already exists — skipping"
    exit 0
fi

oc create secret generic multiclusterhub-operator-pull-secret \
    -n open-cluster-management-observability \
    --from-literal=.dockerconfigjson="$DOCKER_CONFIG_JSON" \
    --type=kubernetes.io/dockerconfigjson
