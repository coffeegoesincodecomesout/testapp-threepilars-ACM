# testapp-threepilars-ACM

Demo deployment of the three pillars of observability (metrics, logs, traces) on OpenShift using Red Hat Advanced Cluster Management policies.

## Overview

This repository demonstrates deploying a complete observability stack to OpenShift clusters managed by ACM. All observability components are deployed via ACM governance policies.

## What Gets Deployed

**Hub Cluster:**
- Red Hat Advanced Cluster Management
- OpenShift GitOps (ArgoCD)
- Multi-Cluster Observability (Thanos)

**Managed Clusters (via ACM Policies):**
- **Metrics**: User workload monitoring, custom metrics forwarded to hub
- **Logs**: Loki stack (COO, Loki, Logging operators + ClusterLogForwarder)
- **Traces**: Tempo + OpenTelemetry (distributed tracing with Jaeger UI)
- **Storage**: MCG/NooBaa for Loki and Tempo object storage

**Demo Application:**
- Testapp-threepilars with full instrumentation (metrics, logs, traces)
- Deployed via ArgoCD ApplicationSet using ACM pull model

## Quick Start

### Prerequisites

- OpenShift 4.12+ clusters (1 hub + 1 or more managed)
- `oc` CLI
- `clusteradm` CLI ([install](https://open-cluster-management.io/getting-started/installation/start-the-control-plane/))
- Access to managed cluster kubeconfigs

### Deployment

```bash
# 1. Deploy hub cluster infrastructure
./000_Deploy_Hub.sh

# 2. Import managed clusters
./001_Import_Clusters.sh cluster1 cluster2

# 3. Deploy observability policies (three pillars)
./004_Deploy_Policies.sh

# 4. Deploy applications
./002_Deploy_Applications.sh
```

### Verify

```bash
# Check all policies are compliant
oc get policies -n policies

# On managed cluster - verify observability components
oc get pods -n openshift-logging
oc get pods -n openshift-tempo
oc get pods -n opentelemetry
```

## Three Pillars

### Metrics
- Prometheus user workload monitoring
- Custom metric: `ping_request_count`
- PrometheusRule alerts forwarded to hub

### Logs
- Loki for log aggregation
- ClusterLogForwarder collecting application and infrastructure logs
- Loki AlertingRule for log-based alerts

### Traces
- OpenTelemetry Collector
- Tempo for distributed tracing backend
- Jaeger UI via OpenShift console

## ACM Policies

16 policies enforce the observability stack:
- Storage: MCG operator, NooBaa
- Logging: COO, Loki, Logging operators + stack
- Tracing: OpenTelemetry, Tempo operators + stack

All policies use `enforce` remediation for automatic compliance.

## Testing the Demo

```bash
# Access the testapp
oc get route -n testapp-threepilars-app

# Trigger metrics, logs, and traces
curl https://<route-url>/ping

# View metrics on hub: Observe → Metrics
# Query: ping_request_count

# View logs on managed cluster: Observe → Logs

# View traces on managed cluster: Observe → Distributed Tracing
# Service: testapp-threepilars
```

## Repository Structure

- `000_Deploy_Hub.sh` - Hub cluster deployment
- `001_Import_Clusters.sh` - Cluster import via clusteradm
- `002_Deploy_Applications.sh` - Application deployment
- `004_Deploy_Policies.sh` - Policy deployment (three pillars)
- `06_Logging_Policy/` - Logging operators policies
- `07_LoggingStack_Policy/` - Loki stack policies
- `08_MCG_Policy/` - Storage policies
- `09_Tracing_Operators_Policy/` - Tracing operators policies
- `10_Tracing_Stack_Policy/` - Tempo stack policies

## Notes

- MCG/NooBaa deployed in standalone mode (not for production use)
- Policies generate secrets automatically using `object-templates-raw` lookups
- ApplicationSet uses ACM pull model for GitOps deployment
