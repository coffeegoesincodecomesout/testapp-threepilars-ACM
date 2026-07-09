# Tracing Stack Deployment Policy

This directory contains ACM Policy-based deployment for the distributed tracing stack on managed clusters.

## Components Deployed

1. **Namespaces** - opentelemetry and openshift-tempo
2. **ObjectBucketClaim** - S3-compatible bucket via NooBaa/ODF for Tempo storage
3. **Bucket Secret** - Auto-generated from OBC ConfigMap and Secret using policy templates
4. **TempoStack** - Tempo deployment for trace storage with multi-tenancy (dev/prod)
5. **OpenTelemetry Collector** - Trace collection and forwarding to Tempo
6. **UIPlugin** - Distributed tracing UI integration
7. **RBAC** - ServiceAccounts and ClusterRoles for trace read/write

## Policy Dependencies

The policies are configured with dependencies to ensure proper deployment order:
- create-tracing-namespaces (depends on: operators)
- deploy-tempo-bucket (depends on: namespaces, install-noobaa)
- create-tempo-bucket-secret (depends on: deploy-tempo-bucket)
- deploy-tempo-stack (depends on: create-tempo-bucket-secret)
- deploy-otel-collector (depends on: deploy-tempo-stack)

## Prerequisites

- Tracing operators deployed via 09_Tracing_Operators_Policy
- NooBaa/MCG storage available (from 08_MCG_Policy)

## Deployment

### Generate and Apply Policies

```bash
cd 10_Tracing_Stack_Policy

# Generate the policies
mkdir -p generated
oc kustomize . --enable-alpha-plugins > generated/tracing-stack-policies.yaml

# Review the generated policies
cat generated/tracing-stack-policies.yaml

# Apply to hub cluster
oc apply -f generated/tracing-stack-policies.yaml
```

### Verify Deployment

```bash
# Check policy status on hub
oc get policies -n policies | grep -E "tracing|tempo|otel"

# On managed cluster, verify resources
oc get tempostack -n openshift-tempo
oc get opentelemetrycollector -n opentelemetry
oc get pods -n openshift-tempo
oc get pods -n opentelemetry
```

## Configuration Details

- **Tempo Tenants**: dev (10h retention) and prod (20h retention)
- **Tempo Storage**: S3 via NooBaa with TLS enabled
- **OTel Collector**: Deployment mode with gRPC and HTTP receivers
- **Trace Export**: Both OTLP (gRPC) and OTLP/HTTP to Tempo gateway
- **UI Integration**: Jaeger Query UI enabled via TempoStack

## Notes

- Source manifests from: https://github.com/coffeegoesincodecomesout/testapp-threepilars-UWL/tree/useODF
- Bucket secret policy uses object-templates-raw with lookups
- OTel collector exports to dev tenant by default (X-Scope-OrgID: "dev")
- TempoStack creates ServiceMonitors and PrometheusRules for observability
