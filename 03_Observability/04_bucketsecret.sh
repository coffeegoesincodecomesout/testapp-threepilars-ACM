#!/bin/bash
set -euo pipefail

# Wait for ODF to provision the ObjectBucketClaim resources (configmap + secret)
NAMESPACE="open-cluster-management-observability"
CONFIGMAP="acm-bucket-odf"
SECRET="acm-bucket-odf"
TIMEOUT=300
INTERVAL=10
elapsed=0

echo "Waiting for configmap '$CONFIGMAP' and secret '$SECRET' in '$NAMESPACE'..."
until oc get configmap "$CONFIGMAP" -n "$NAMESPACE" &>/dev/null && \
      oc get secret    "$SECRET"    -n "$NAMESPACE" &>/dev/null; do
  if [ $elapsed -ge $TIMEOUT ]; then
    echo "ERROR: Timed out waiting for OBC resources in '$NAMESPACE'" >&2
    exit 1
  fi
  echo "  Not ready yet (${elapsed}s elapsed)..."
  sleep $INTERVAL
  elapsed=$((elapsed + INTERVAL))
done
echo "  OBC resources ready."

BUCKET_HOST=$(oc get -n "$NAMESPACE" configmap "$CONFIGMAP" -o jsonpath='{.data.BUCKET_HOST}')
BUCKET_NAME=$(oc get -n "$NAMESPACE" configmap "$CONFIGMAP" -o jsonpath='{.data.BUCKET_NAME}')
ACCESS_KEY=$(oc get -n "$NAMESPACE" secret "$SECRET" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}'     | base64 -d)
SECRET_KEY=$(oc get -n "$NAMESPACE" secret "$SECRET" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)

# Use HTTP (port 80) with insecure: true to avoid TLS certificate issues
# The internal S3 service uses self-signed certs, and HTTP is acceptable for internal cluster traffic
output=$(oc create secret generic thanos-object-storage -n "$NAMESPACE" \
  --from-literal=thanos.yaml="type: s3
config:
  bucket: ${BUCKET_NAME}
  endpoint: ${BUCKET_HOST}:80
  insecure: true
  access_key: ${ACCESS_KEY}
  secret_key: ${SECRET_KEY}" 2>&1) || {
  if echo "$output" | grep -q "already exists"; then
    echo "  Secret 'thanos-object-storage' already exists — skipping"
  else
    echo "$output" >&2
    exit 1
  fi
}
