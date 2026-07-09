# MCG/NooBaa Storage Policy

This directory contains ACM Policy-based deployment for MCG (Multi-Cloud Gateway) and NooBaa object storage on managed clusters.

## Components Deployed

1. **MCG Operator** - Multi-Cloud Gateway operator for object storage
2. **NooBaa** - S3-compatible object storage backend

## Policy Dependencies

- install-noobaa (depends on: install-mcg-operator)

## Prerequisites

- Managed clusters with sufficient resources for NooBaa deployment
- Must be deployed **before** logging stack policies (07_LoggingStack_Policy)

## Deployment

### Generate and Apply Policies

```bash
cd 08_MCG_Policy

# Generate the policies
mkdir -p generated
oc kustomize . --enable-alpha-plugins > generated/mcg-policies.yaml

# Review the generated policies
cat generated/mcg-policies.yaml

# Apply to hub cluster
oc apply -f generated/mcg-policies.yaml
```

### Verify Deployment

```bash
# Check policy status on hub
oc get policies -n policies | grep mcg

# On managed cluster, verify resources
oc get csv -n openshift-storage
oc get noobaa -n openshift-storage
oc get storageclass openshift-storage.noobaa.io
```

## Notes

- NooBaa deployment uses minimal resources (cpu: 0.1, memory: 1Gi) suitable for testing
- Storage class `openshift-storage.noobaa.io` will be available after NooBaa is ready
- This is a prerequisite for the logging stack Loki bucket deployment
