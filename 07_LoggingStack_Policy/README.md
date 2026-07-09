# Logging Stack Deployment Policy

This directory contains ACM Policy-based deployment for the Loki logging stack on managed clusters.

## Components Deployed

1. **ObjectBucketClaim** - S3-compatible bucket via NooBaa/ODF for Loki storage
2. **Bucket Secret** - Auto-generated from OBC ConfigMap and Secret using policy templates
3. **LokiStack** - Loki deployment for log aggregation
4. **UIPlugin** - Logging UI integration
5. **ClusterLogForwarder** - Log collection and forwarding to Loki

## Policy Dependencies

The policies are configured with dependencies to ensure proper deployment order:
- deploy-loki-bucket (depends on: install-logging-operator)
- create-loki-bucket-secret (depends on: deploy-loki-bucket)
- deploy-logging-stack (depends on: create-loki-bucket-secret)

## Prerequisites

- Logging operators deployed via 06_Logging_Policy
- NooBaa/MCG storage available (openshift-storage.noobaa.io storageClass)

## Deployment

### Generate and Apply Policies

```bash
cd 07_LoggingStack_Policy

# Generate the policies
oc kustomize . --enable-alpha-plugins > generated/logging-stack-policies.yaml

# Review the generated policies
cat generated/logging-stack-policies.yaml

# Apply to hub cluster
oc apply -f generated/logging-stack-policies.yaml
```

### Verify Deployment

```bash
# Check policy status on hub
oc get policies -n policies | grep loki

# On managed cluster, verify resources
oc get objectbucketclaim -n openshift-logging
oc get secret logging-loki-odf -n openshift-logging
oc get lokistack -n openshift-logging
oc get clusterlogforwarder -n openshift-logging
```

## Notes

- Source manifests from: https://github.com/coffeegoesincodecomesout/testapp-threepilars-UWL/tree/useODF/03_Logging
- The bucket secret policy uses object-templates-raw with lookups to automatically extract OBC credentials
- LokiStack size is `1x.demo` - suitable for testing, adjust for production
- Audit logs are commented out in ClusterLogForwarder pipeline
