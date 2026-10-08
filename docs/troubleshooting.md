# Troubleshooting

Failures are grouped by the symptom reported by the scripts.

## helm refuses the chart: `chart requires kubeVersion: >=1.34.0-0`

The chart supports Kubernetes 1.34 and newer only. `check-prerequisites.sh` reports
the same failure as `check_kubernetes_version`. Upgrade the cluster.

## `helm dependency update` fails

Expected. The umbrella dependencies declare no repository and the subcharts are
vendored under `charts/`. Install directly from the chart directory; `deploy.sh` does
that.

## Ingress answers, but the certificate is wrong or missing

With `TLS_MODE=cert-manager`, cert-manager's ingress-shim issues `<host>-tls` for the
Ingress that carries the `cert-manager.io/cluster-issuer` annotation. Check that it was
issued:

```sh
kubectl -n "$NAMESPACE" get certificate,certificaterequest,order,challenge
kubectl -n "$NAMESPACE" describe certificate "<host>-tls"
```

## Endpoint checks fail with `no-response` or an unexpected 404 while the pods are ready

The hostname probably does not resolve to the ingress controller. Check in this
order: DNS for the hostname, the ingress address, then the service.

```sh
getent hosts "$OAPIP_HOSTNAME" || nslookup "$OAPIP_HOSTNAME"
kubectl -n "$NAMESPACE" get ingress
./validation.sh --skip-urls          # confirms the cluster side is healthy
```

Without DNS records (placeholder hosts, a kind or k3s node reached by IP), pass the
controller address instead: `./validation.sh --ingress-address <ip>` (or set
`INGRESS_ADDRESS` with `configure-oapip.sh`).

## `/ogcapi/processes` returns 500 right after the deployment

The server and worker restart once or twice while Postgres initialises, and the server
has no readiness probe. The HTTP checks retry for a minute by default; raise
`CHECK_URL_RETRIES` on slow clusters.

## PVC stays Pending

```sh
kubectl -n "$NAMESPACE" describe pvc <name>
kubectl get storageclass
```

A class with `volumeBindingMode: WaitForFirstConsumer` binds only once a pod mounts
the volume. Per-job volumes in `<release>-workflows` always use the cluster default
storage class, which must therefore exist.

## Workflow steps fail with `failed to look-up entrypoint/cmd`

Argo reads the workflow pull secrets to look up the entrypoint of the input-downloader
and output-uploader images. The chart creates them (`workflowPullSecrets`) and lets the
Argo controller read only those names (`argo-workflows.controller.rbac.secretWhitelist`).
The step fails when:

- a secret is missing: `secrets "<name>" not found`;
- the controller may not read it: `secrets "<name>" is forbidden`.

Both happen when the names in the worker properties
(`platform.worker.workflow.legacy.*ImagePullSecretName`), `workflowPullSecrets` and the
whitelist differ.

```sh
kubectl -n "${RELEASE_NAME}-workflows" get secrets
kubectl -n "${RELEASE_NAME}-workflows" get workflows
```

## Workflow pods fail to pull a processor image

The default pull secrets carry no credentials (`{"auths":{}}`), so processor images
must be public, or the operator sets `dockerconfigjson` in `workflowPullSecrets` in the
chart values.

```sh
kubectl -n "${RELEASE_NAME}-workflows" get pods
kubectl -n "${RELEASE_NAME}-workflows" describe pod <pod>
```

## `e2e.sh` fails

| Step | Look at |
| --- | --- |
| Serving the application package and the STAC input | `kubectl -n "$NAMESPACE" describe pod -l app.kubernetes.io/name="${RELEASE_NAME}-e2e-web"`: the cluster must pull `busybox` |
| Deploying the process | `kubectl -n "$NAMESPACE" logs deploy/"${RELEASE_NAME}-server"`: the server fetches the CWL from the in-cluster URL. A single 500 right after the web server starts is retried |
| Executing / waiting | `kubectl -n "${RELEASE_NAME}-workflows" get workflows,pods` and the logs of the `input`, `processing` (fastcopier-stac) and `output` step pods. Successful workflows are deleted by the worker, so watch them while the job runs |
| Checking the job output | the server Ingress (`kubectl -n "$NAMESPACE" get ingress "${RELEASE_NAME}-server" -o yaml`) |

`./e2e.sh --keep` leaves the test process and its web server in place for inspection.

## server or worker pod crashes at startup

Most startup failures are database or broker related.

```sh
kubectl -n "$NAMESPACE" logs deploy/"${RELEASE_NAME}-server" --tail=200
kubectl -n "$NAMESPACE" logs deploy/"${RELEASE_NAME}-worker" --tail=200
kubectl -n "$NAMESPACE" logs sts/"${RELEASE_NAME}-postgres" --tail=100
kubectl -n "$NAMESPACE" get events --field-selector reason=FailedPostStartHook
```

The Postgres pod creates the roles and databases named in `global.database.*` and sets
their passwords at every start. Flyway reports `schema_version` mismatches when a
volume from an earlier release is reused: restore a matching image tag or delete the
Postgres volume for a clean development install.

## Argo UI returns 401 or asks for a token

`ARGO_AUTH_MODE=client` is the default and requires a bearer token:

```sh
kubectl -n "${RELEASE_NAME}-workflows" get secret "${RELEASE_NAME}-argo-ui-token" \
  -o jsonpath='{.data.token}' | base64 -d
```

`ARGO_AUTH_MODE=server` disables authentication completely and exposes full workflow
control to anyone reaching the Ingress.

## Re-running the scripts

```sh
./configure-oapip.sh --reconfigure     # change stored answers
```

The state file `$HOME/.eoepca/state` may be shared with other EOEPCA building blocks:
do not delete it. Deleting it also discards the generated passwords; if the release is
already installed, new passwords are applied to the database at the next Postgres
restart but must be redeployed to the server and worker together.
