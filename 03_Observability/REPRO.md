# ACM-47877 — reproducer

> MCO reports Ready while all thanos store shards crash-loop on an untrusted object store CA

## Summary

When `thanos-object-storage` points at an HTTPS S3 endpoint whose serving certificate is signed by
the OpenShift service CA, and the objstore config carries no `http_config.tls_config.ca_file`,
Thanos falls back to the container's system root bundle — which contains public CAs only — and
fails verification. Every `observability-thanos-store-shard-*` pod crash-loops.

Two things make this worse than a plain misconfiguration:

1. **MultiClusterObservability still reports `Ready: True`** (`Observability components are deployed
   and running`) while all shards are `0/1` CrashLoopBackOff. MCO's S3 validation only checks bucket
   name length and a non-empty endpoint; it never inspects TLS settings, so nothing surfaces the
   problem in CR status.
2. **`thanos-compact` stays `1/1 Running`** while logging the identical x509 error. It retries
   rather than exiting, so it looks healthy while silently never compacting. There is no crash-loop
   and no status signal at all for this one.

## Environment

Reproduced 2026-10-12 on OCP with ACM 2.16.6, standalone MCG (`mcg-operator` 4.22.5-rhodf).

Full ODF/Ceph is **not** required. The original report came from a Ceph RGW endpoint
(`rook-ceph-rgw-ocs-storagecluster-cephobjectstore.openshift-storage.svc`), but NooBaa reproduces it
identically because both are fronted by OpenShift service-serving certificates:

```
$ oc -n openshift-storage get secret noobaa-s3-serving-cert \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -ext subjectAltName
issuer=CN=openshift-service-serving-signer@1791794745
X509v3 Subject Alternative Name:
    DNS:s3.openshift-storage.svc, DNS:s3.openshift-storage.svc.cluster.local
```

The SAN matches the endpoint and the cert is in date, so an untrusted issuer is the *only* possible
failure mode — no hostname-mismatch or expiry noise.

## What this branch changes

One file: `04_bucketsecret.sh`. It previously worked around the issue with HTTP on port 80 and
`insecure: true`. This branch removes that workaround to expose the bug:

```diff
+BUCKET_PORT=$(oc get -n "$NAMESPACE" configmap "$CONFIGMAP" -o jsonpath='{.data.BUCKET_PORT}')
...
-  endpoint: ${BUCKET_HOST}:80
-  insecure: true
+  endpoint: ${BUCKET_HOST}:${BUCKET_PORT}
+  insecure: false
```

Omitting `http_config.tls_config` entirely is the essential part — that is what makes Thanos fall
back to system roots.

## Steps to reproduce

Deploy the hub as normal (`000_Deploy_Hub.sh`), then:

```sh
# The script skips when the secret already exists, so delete it first.
oc delete secret thanos-object-storage -n open-cluster-management-observability
./03_Observability/04_bucketsecret.sh

# Required: the MCO config-hash does not cover this secret, so nothing restarts on its own.
oc rollout restart statefulset -n open-cluster-management-observability \
  observability-thanos-store-shard-0 observability-thanos-store-shard-1 \
  observability-thanos-store-shard-2 observability-thanos-compact
```

## Expected vs actual

Expected: either the store shards trust the endpoint, or MCO reports the object storage config as
invalid.

Actual:

```sh
$ oc get pods -n open-cluster-management-observability | grep store-shard
observability-thanos-store-shard-0-0   0/1   Running   2 (19s ago)   97s
observability-thanos-store-shard-1-0   0/1   Running   2 (26s ago)   97s
observability-thanos-store-shard-2-0   0/1   Running   2 (32s ago)   98s

$ oc get mco observability -o jsonpath='{range .status.conditions[*]}{.type}{" | "}{.status}{" | "}{.message}{"\n"}{end}'
Installing | True | Installation is in progress
Ready | True | Observability components are deployed and running
```

Store shard log:

```
level=warn msg="changing probe status" status=not-ready reason="bucket store initial sync: sync block:
BaseFetcher: iter bucket: Get \"https://s3.openshift-storage.svc/acm-bucket-odf-ef25caf4-07c1-4f6d-ac58-cf045c3eda6d/?location=\":
tls: failed to verify certificate: x509: certificate signed by unknown authority"
...
level=info msg="changing probe status" status=not-healthy reason="bucket store initial sync: ..."
level=error err="... store command failed" main.main /workspace/cmd/thanos/main.go:171
```

Code path from the stack trace: `cmd/thanos/store.go:499` → `BucketStore.InitialSync`
(`pkg/store/bucket.go:814`) → `SyncBlocks` (`bucket.go:737`) → `BaseFetcher.fetchMetadata`
(`pkg/block/fetcher.go:527`).

Confirm compact is quietly affected too:

```sh
oc logs -n open-cluster-management-observability observability-thanos-compact-0 | grep -c "unknown authority"
# non-zero, yet the pod reports 1/1 Running
```

## Workarounds

In order of preference:

1. Supply the CA. Copy the service CA into a Secret (MCO accepts only a Secret for `tlsSecretName`,
   while the service CA ships as the `openshift-service-ca.crt` ConfigMap), set
   `http_config.tls_config.ca_file` in `thanos.yaml`, and set **both** `tlsSecretName` and
   `tlsSecretMountPath` on the MultiClusterObservability CR. Setting `tlsSecretMountPath` is
   required — `ca_file` alone is not enough.
2. `http_config: {insecure_skip_verify: true}` — keeps TLS, drops verification.
3. Revert to HTTP with `insecure: true`, as `main` does today.
