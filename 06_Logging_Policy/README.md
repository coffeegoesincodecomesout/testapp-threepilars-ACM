# Logging Operators Policy Deployment

This directory contains ACM Policy-based deployment for the logging observability stack on managed clusters.

## Operators Deployed

1. **Cluster Observability Operator (COO)** - Base observability framework
2. **Loki Operator** - Log aggregation and storage
3. **Cluster Logging Operator** - Log collection and forwarding

## Policy Dependencies

The policies are configured with dependencies to ensure proper installation order:
- COO → Loki → Logging

## Deployment

### Prerequisites

- ACM hub cluster with PolicyGenerator plugin installed
- Managed clusters imported into ACM
- `policies` namespace exists on hub cluster

### Install PolicyGenerator Plugin (if not already installed)

```bash
mkdir -p ~/.config/kustomize/plugin/policy.open-cluster-management.io/v1/policygenerator
cd ~/.config/kustomize/plugin/policy.open-cluster-management.io/v1/policygenerator
curl -sL https://github.com/open-cluster-management-io/policy-generator-plugin/releases/download/v1.19.0/linux-amd64-PolicyGenerator -o PolicyGenerator
chmod +x PolicyGenerator
```

### Generate and Apply Policies

```bash
# Create policies namespace
oc create -f 00_namespace.yaml

# Generate the policies from PolicyGenerator configs
oc kustomize . --enable-alpha-plugins > generated/logging-policies.yaml

# Review the generated policies
cat generated/logging-policies.yaml

# Apply to hub cluster
oc apply -f generated/logging-policies.yaml
```

### Verify Deployment

```bash
# Check policy status on hub
oc get policies -n policies

# Check policy compliance
oc get policies -n policies -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.compliant}{"\n"}{end}'

# On managed clusters, verify operator installations
oc get csv -n openshift-cluster-observability-operator
oc get csv -n openshift-operators-redhat
oc get csv -n openshift-logging
```

## Target Clusters

Policies target all managed clusters with:
```yaml
labelSelector:
  matchExpressions:
    - key: vendor
      operator: In
      values:
        - "OpenShift"
```

## Remediation

All policies are set to `remediationAction: enforce` - operators will be automatically installed on non-compliant clusters.

## Notes

- Source manifests are from: https://github.com/coffeegoesincodecomesout/testapp-threepilars-UWL/tree/useODF
- Starting CSVs removed from subscriptions to allow latest stable channel versions
- Policies deploy to the `policies` namespace on the hub cluster
