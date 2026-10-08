# Prerequisites

Run `scripts/check-prerequisites.sh` to verify all of this automatically.

## Client tooling

| Tool | Minimum | Used for |
| --- | --- | --- |
| bash | 4.4 | the scripts themselves |
| kubectl | matching the cluster | every cluster check |
| helm | 3.5 | installing the chart |
| curl | any | endpoint checks and the end-to-end test |
| openssl | any | password generation (falls back to `/dev/urandom`) |
| jq | any | optional, inspects one JSON payload during validation |

## Cluster

| Requirement | Notes |
| --- | --- |
| Kubernetes 1.34 or newer | The chart sets `kubeVersion: >=1.34.0-0`, so helm refuses older clusters. Override the check with `KUBERNETES_MIN_VERSION` only together with the chart |
| Kubernetes API access | The current kubeconfig context must be able to list nodes, create namespaces and install CRDs and ClusterRoles (Argo Workflows) |
| Ingress controller | An `IngressClass` matching `INGRESS_CLASS` (default `nginx`). The server Ingress uses ingress-nginx regular expression paths |
| Storage class for ReadWriteOnce volumes | Used by Postgres (20Gi), MinIO (50Gi), the server data volume (10Gi), the broker (1Gi) and one volume per job. An empty value means the cluster default, which must then exist |
| cert-manager | Only when `TLS_MODE=cert-manager`. The CRDs must be installed, at least one cert-manager pod running, and the `ClusterIssuer` named in `CLUSTER_ISSUER` must report `Ready=True` |
| ReadWriteMany storage | Not needed by the building block. Checked only with `SHARED_MOUNTS_ENABLED=true` and `SHARED_STORAGECLASS` set: the check creates a 1Gi RWX PVC, waits up to 60s for it to bind and deletes it. A storage class with `volumeBindingMode: WaitForFirstConsumer` is reported as inconclusive |
| External object store | Only with `S3_EXTERNAL=true`: `S3_ENDPOINT` must answer over HTTP (its certificate is verified unless `CURL_INSECURE=true`) and `S3_ACCESS_KEY` / `S3_SECRET_KEY` must be set. See the known limitations in the README |
| Public images | The cluster pulls from `ghcr.io`, `quay.io` and Docker Hub (`postgres`, `apache/activemq-classic`, `busybox`). `e2e.sh` also pulls `ghcr.io/cgi-italy-insula-processing/com.cgi.eoss.platform/fastcopier-stac:0.1` |

Nothing else is required. In particular the building block needs no Crossplane, no
Keycloak and no APISIX, unlike the EOEPCA reference deployment.

## Resource footprint

A default install creates nine workloads and four persistent volumes, plus one 10Gi
volume per running job. The memory limits of the default values add up to about 13 GiB
(OGC API 5Gi, server 4Gi, worker 2Gi, broker 1Gi, MinIO 1Gi request); the chart was
validated on a single-node kind cluster with 16 GiB of memory. With the default sizes
plan about 81Gi of volume capacity plus the job volumes.

## Command line overrides

```sh
./check-prerequisites.sh \
  --namespace eoepca \
  --ingress-class nginx \
  --storage-class my-storage-class \
  --tls-mode cert-manager \
  --cluster-issuer selfsigned-ca-issuer
```

Run the script once before `configure-oapip.sh` to catch obvious gaps, and again
afterwards: the second run reads the real answers from `$HOME/.eoepca/state` and
checks exactly what will be deployed.
