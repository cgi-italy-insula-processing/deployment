# Configuration

`scripts/configure-oapip.sh` collects the deployment parameters and writes a values
override for the `eoepca` umbrella chart.

```sh
./configure-oapip.sh                          # interactive, keeps stored answers
./configure-oapip.sh --reconfigure            # ask again for everything
./configure-oapip.sh -o /tmp/values.yaml      # different output path
./configure-oapip.sh --non-interactive        # accept defaults, fail if a value has none
```

Output: `generated/values.yaml`, mode 0600, git-ignored. It contains credentials in
clear text, so treat it like a secret. Every value is written as a YAML single-quoted
string where needed, so typed passwords may contain any character except where noted.

## State file

Answers are persisted in `$HOME/.eoepca/state` (override with `EOEPCA_STATE_FILE`) as
`export NAME="value"` lines, the same file and format used by the EOEPCA deployment
guide scripts. All scripts source it, which is how `validation.sh` and `e2e.sh` know the
release, the hostnames and the scheme without asking again.

Variables shared with the deployment guide keep its meaning: `INGRESS_HOST`,
`INGRESS_CLASS`, `HTTP_SCHEME`, `CLUSTER_ISSUER`, `PERSISTENT_STORAGECLASS`,
`SHARED_STORAGECLASS`, `S3_ENDPOINT`, `S3_ACCESS_KEY`, `S3_SECRET_KEY`. The variables of
this building block use their own names (`OAPIP_HOSTNAME`, `OAPIP_S3_*`, ...), so they
do not clash with the guide's (its `OAPIP_HOST` holds a URL). A stored value that fails
the validation of a prompt is asked again instead of being reused.

```sh
# inspect without exposing secrets
sed -E 's/^(export )?([A-Z_]*(PASSWORD|SECRET|TOKEN)[A-Z_]*)=.*/\1\2="***"/' ~/.eoepca/state
```

## Release identity

| Variable | Default | Chart effect |
| --- | --- | --- |
| `RELEASE_NAME` | `eoepca` | Prefixes every resource name, and names the workflow namespace `<release>-workflows` |
| `NAMESPACE` | `eoepca` | Release namespace. Every workload, including the Argo controller and server, runs here |

## Infrastructure

| Variable | Default | Values path |
| --- | --- | --- |
| `INGRESS_HOST` | none | Base domain; only used to derive the hostnames below |
| `OAPIP_HOSTNAME` | `processing.$INGRESS_HOST` | `ogc-api-processes.ingress.hosts[0].host` and `server.ingress.hosts[0].host`. The job output links are built from it |
| `INGRESS_CLASS` | `nginx` | `className` / `ingressClassName` of every Ingress |
| `TLS_MODE` | `cert-manager` | `cert-manager`: every Ingress gets `tls[{secretName: <host>-tls}]` and `ssl-redirect: "true"`; one Ingress per host (OGC API, Argo, MinIO) gets the `cert-manager.io/cluster-issuer` annotation so cert-manager's ingress-shim issues `<host>-tls`, and the server Ingress reuses the OGC API secret. `none`: `tls: []` and `ssl-redirect: "false"` |
| `CLUSTER_ISSUER` | `selfsigned-ca-issuer` | Value of the `cert-manager.io/cluster-issuer` annotation |
| `HTTP_SCHEME` | derived | `https` with cert-manager, `http` otherwise; used by `validation.sh` and `e2e.sh` |
| `INGRESS_ADDRESS` | empty | Not written to the values. IP address of the ingress controller used by `validation.sh` and `e2e.sh` (`curl --resolve`) when the hostnames have no DNS record |
| `PERSISTENT_STORAGECLASS` | empty (cluster default) | `persistence.storageClass` of `postgres`, `broker`, `minio` and `server`, written only when set. Per-job workflow volumes always use the cluster default |
| `POSTGRES_STORAGE_SIZE` | `20Gi` | `postgres.persistence.size` |
| `MINIO_STORAGE_SIZE` | `50Gi` | `minio.persistence.size` |
| `SERVER_STORAGE_SIZE` | `10Gi` | `server.persistence.size` (job outputs) |
| `BROKER_STORAGE_SIZE` | `1Gi` | `broker.persistence.size` |

The server Ingress is always written with the single path
`/secure/api/v2.0/jobs/[0-9]+/outputs/[^/]+$` (`ImplementationSpecific`, ingress-nginx
`use-regex`): only the job output download endpoint is exposed.

Image references are not configured: the chart pulls public images from `ghcr.io`.
Override `image.repository` / `image.tag` in a second values file to use a mirror.

## Backend

| Variable | Default | Values path |
| --- | --- | --- |
| `OAPIP_S3_ACCESS_KEY` | `eoepca` | `global.storage.accesskey`: MinIO root user and the key used by the server, worker and workflow steps |
| `OAPIP_S3_SECRET_KEY` | generated | `global.storage.secretkey`; at least 8 characters (MinIO requirement) |
| `MINIO_INGRESS_ENABLED` | `false` | `minio.ingress.enabled`. The building block does not need it |
| `MINIO_HOSTNAME` | `minio-processing.$INGRESS_HOST` | `minio.ingress.hosts[0]`, asked only when the ingress is enabled |
| `PLATFORM_DB_NAME` / `PLATFORM_DB_USER` | `platform_v2` / `platform` | `global.database.platform.name` / `.username` (lowercase letters, digits, `_`) |
| `WORKER_DB_NAME` / `WORKER_DB_USER` | `platform_worker` / `platform_worker` | `global.database.worker.name` / `.username` |
| `PLATFORM_DB_PASSWORD` | generated | `databaseSecrets.platformPassword` |
| `WORKER_DB_PASSWORD` | generated | `databaseSecrets.workerPassword` |
| `POSTGRES_SUPERUSER_PASSWORD` | generated | `databaseSecrets.postgresPassword` |
| `ACTIVEMQ_USER` / `ACTIVEMQ_PASSWORD` | `platform` / generated | `global.activemq.username` / `.password`. Letters, digits, `.`, `_`, `-` only: they are written into the broker's Jetty realm file. They protect the web console; the broker does not authenticate JMS clients |
| `ARGO_INGRESS_ENABLED` | `true` | `argo-workflows.server.ingress.enabled` |
| `ARGO_HOSTNAME` | `argo-processing.$INGRESS_HOST` | `argo-workflows.server.ingress.hosts[0]`, asked only when the ingress is enabled |
| `ARGO_AUTH_MODE` | `client` | `argo-workflows.server.authModes`. `client` requires a bearer token in the UI, `server` disables authentication |
| `ARGO_UI_ROLE` | `edit` | `argoUiUser.clusterRole` (`view`, `edit` or `admin`), applied only in `client` mode |

## Argo UI token

In `client` mode the chart creates the service account `<release>-argo-ui` and the
token secret `<release>-argo-ui-token` in the `<release>-workflows` namespace:

```sh
kubectl -n "<release>-workflows" get secret "<release>-argo-ui-token" \
  -o jsonpath='{.data.token}' | base64 -d
```

Paste the value into the Argo UI login prompt prefixed with `Bearer `.

## Deployment

```sh
./deploy.sh --chart ../../helm-chart          # helm upgrade --install
./deploy.sh --chart ../../helm-chart --dry-run
```

Never run `helm dependency update` against the chart: its dependencies declare no
repository and the subcharts are vendored under `charts/`.
