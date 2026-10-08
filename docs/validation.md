# Validation

```sh
./validation.sh                               # full run
./validation.sh --ingress-address 127.0.0.1   # HTTP checks without DNS
./validation.sh --skip-urls                   # cluster objects only
./validation.sh --skip-internal               # no port-forward checks
./validation.sh -r eoepca -n eoepca           # override release and namespace
./validation.sh --quiet-report                # no resource listing at the end
```

Exit code `0` when every check passed, `1` when at least one failed. Skipped and
inconclusive checks never fail the run. Names below assume the release `<rel>` in
namespace `<ns>`, with the workflow namespace `<rel>-workflows`.

## Workloads

| Check | Resource |
| --- | --- |
| StatefulSet ready | `<rel>-postgres` |
| Deployment ready | `<rel>-broker`, `<rel>-minio`, `<rel>-server`, `<rel>-worker`, `<rel>-worker-event-collector`, `<rel>-ogc-api-processes`, `<rel>-argo-workflows-workflow-controller`, `<rel>-argo-workflows-server` |
| Pods running | by label: `app.kubernetes.io/name` in `postgres`, `broker`, `server`, `worker`, `worker-event-collector`, `ogc-api-processes` with `app.kubernetes.io/instance=<rel>`; `app=minio,release=<rel>`; `app.kubernetes.io/instance=<rel>,app.kubernetes.io/part-of=argo-workflows` (2 expected) |

Rollout checks wait up to `ROLLOUT_TIMEOUT` (default `180s`).

## Services

`<rel>-postgres-service`, `<rel>-broker-service`, `<rel>-server-service`,
`<rel>-ogc-api-processes-service`, `<rel>-minio-service`, `<rel>-argo-workflows-server`.

## Storage

PVCs expected Bound: `data-<rel>-postgres-0` (from the StatefulSet volume claim
template), `<rel>-broker`, `<rel>-minio`, `<rel>-server-data`. The buckets are created
by the applications on first use, so they are not checked here; `e2e.sh` exercises
them.

## Configuration

ConfigMaps: `<rel>-platform-server-config`, `<rel>-platform-server-log-config`,
`<rel>-worker-config`, `<rel>-worker-event-collector-config`,
`<rel>-platform-worker-log-config`, `<rel>-ogcapi-config`.

Secrets: `<rel>-secret` (platform DB), `<rel>-worker-secret`, `<rel>-postgres-secret`,
`activemq-user-secret`, `<rel>-minio-storage-secret`.

## Workflows namespace, RBAC and Argo CRDs

Namespace `<rel>-workflows` must contain the ConfigMaps `input-downloader-config` and
`output-uploader-config`, the secret `<rel>-minio-storage-secret`, the workflow pull
secrets (`WORKFLOW_PULL_SECRETS`, default `internal-registry-pull-secret
external-registry-pull-secret`), and the Role and RoleBinding `<rel>-worker` that grant
the worker and event collector access to pods, PVCs and workflows there.

CRDs checked: `workflows.argoproj.io`, `workflowtemplates.argoproj.io`,
`cronworkflows.argoproj.io`, `clusterworkflowtemplates.argoproj.io`,
`workflowtaskresults.argoproj.io`.

## Ingress

Existence of `<rel>-ogc-api-processes` and `<rel>-server`, plus `<rel>-argo-workflows-server`
and `<rel>-minio` when their ingress is enabled, and an address check on the OGC API
Ingress. The address check reports inconclusive rather than failing while the
controller is reconciling, or when the controller does not publish addresses (for
example ingress-nginx behind a NodePort).

## Public endpoints

| URL | Expected |
| --- | --- |
| `$HTTP_SCHEME://$OAPIP_HOSTNAME/ogcapi/` | 200 (landing page) |
| `$HTTP_SCHEME://$OAPIP_HOSTNAME/ogcapi/processes` | 200, and the payload contains `.processes` when `jq` is available |
| `$HTTP_SCHEME://$OAPIP_HOSTNAME/ogcapi/conformance` | 200 |
| `$HTTP_SCHEME://$OAPIP_HOSTNAME/ogcapi/api/` | 200 after the redirect to the Swagger UI |
| `$HTTP_SCHEME://$OAPIP_HOSTNAME/secure/api/v2.0/jobs` and `/secure/api/v2.0/services` | 404: the server Ingress must expose only `/jobs/{jobId}/outputs/{outputId}` |
| `$HTTP_SCHEME://$ARGO_HOSTNAME/` | 200, only when the Argo ingress is enabled |
| `$HTTP_SCHEME://$MINIO_HOSTNAME/minio/health/ready` | 200, only when the MinIO ingress is enabled |

Redirects are followed except for the 404 checks. Each HTTP check is retried
`CHECK_URL_RETRIES` times (default 6), `CHECK_URL_RETRY_DELAY` seconds apart (default
10): the Java services report ready before their HTTP stack answers. With
`INGRESS_ADDRESS` set (state file or `--ingress-address`), requests go to that address
through `curl --resolve`, so placeholder hostnames work without DNS.

Server certificates are verified, except with `TLS_MODE=cert-manager` and the default
`selfsigned-ca-issuer`, whose CA the client does not trust: then `validation.sh` and
`e2e.sh` skip the verification (`curl -k`) and print a warning. Set `CURL_INSECURE=false`
to verify them anyway (for example with the issuer CA installed on the client), or
`CURL_INSECURE=true` to skip the verification with any issuer.

## In-cluster endpoints

Checked through a temporary `kubectl port-forward`, because no Ingress exposes them:

| Target | Path | Expected |
| --- | --- | --- |
| `deployment/<rel>-ogc-api-processes:8081` | `/actuator/health/readiness` | 200 |
| `service/<rel>-broker-service:8161` | `/` | 200, 401 or 302 |
| `service/<rel>-minio-service:9000` | `/minio/health/ready` | 200 |

Use `--skip-internal` where port-forwarding is not allowed. The local port can be
changed with `LOCAL_PORT`.

## End-to-end test

```sh
./e2e.sh                                      # uses the state file
./e2e.sh --ingress-address 127.0.0.1          # without DNS
./e2e.sh --keep --timeout 900                 # keep the test process, wait longer
```

`e2e.sh` runs the whole processing chain with the
[`fastcopier-stac`](https://github.com/orgs/cgi-italy-insula-processing/packages/container/package/com.cgi.eoss.platform%2Ffastcopier-stac)
processor, which copies the selected assets of every item of its input STAC catalog
(`Directory` input) into its output STAC catalog (`Directory` output):

1. Serves, from a temporary web server in the release namespace (ConfigMap, Pod and
   Service `<rel>-e2e-web-<run>`), the application package (CWL), a one-item STAC
   FeatureCollection and the item asset `message.txt`, holding a message unique to the
   run.
2. Deploys the package through `POST /ogcapi/processes` (`application/ogcapppkg+json`,
   execution unit by reference), with a unique process id per run.
3. Executes it with the FeatureCollection URL as input and waits for the job to succeed
   (`--timeout`, default 600 seconds). The job is an Argo Workflow in `<rel>-workflows`:
   - the server stores the STAC document in the stac-items bucket;
   - the input-downloader stages in the catalog, the item and its asset;
   - `fastcopier-stac` copies the item and the asset into the output catalog;
   - the output-uploader uploads the output catalog to object storage.
4. Reads the job results, downloads through the server Ingress the copied STAC item
   (which must reference the copied asset) and the copied asset, which must equal the
   message.
5. Undeploys the process and removes the web server, unless `--keep` is given.

Exit code `0` when the downloaded output matches, `1` at the first failing step. Set
`E2E_PROCESSOR_IMAGE` or `E2E_WEB_IMAGE` to use mirrored images.
