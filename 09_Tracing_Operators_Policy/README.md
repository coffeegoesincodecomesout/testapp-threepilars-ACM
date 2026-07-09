# Tracing Operators Policy Deployment

This directory contains ACM Policy-based deployment for tracing operators on managed clusters.

## Operators Deployed

1. **OpenTelemetry Operator** - Trace collection and processing
2. **Tempo Operator** - Distributed tracing backend

## Deployment

### Prerequisites

- ACM hub cluster with PolicyGenerator plugin installed
- Managed clusters imported into ACM
- `policies` namespace exists on hub cluster

### Generate and Apply Policies

```bash
cd 09_Tracing_Operators_Policy

# Generate the policies
mkdir -p generated
oc kustomize . --enable-alpha-plugins > generated/tracing-operators-policies.yaml

# Review the generated policies
cat generated/tracing-operators-policies.yaml

# Apply to hub cluster
oc apply -f generated/tracing-operators-policies.yaml
```

### Verify Deployment

```bash
# Check policy status on hub
oc get policies -n policies | grep -E "opentelemetry|tempo"

# On managed cluster, verify operator installations
oc get csv -n openshift-operators | grep -E "opentelemetry|tempo"
```

## Target Clusters

Policies target all managed clusters with `vendor: OpenShift` label.

## Notes

- Source manifests from: https://github.com/coffeegoesincodecomesout/testapp-threepilars-UWL/tree/useODF
- Starting CSVs removed from subscriptions to allow latest stable channel versions
- Both operators install in openshift-operators namespace
