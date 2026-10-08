# EOEPCA+ processing building block - deployment scripts

Prerequisite, configuration, deployment, validation and end-to-end test scripts for
the EOEPCA+ processing building block (OGC API Processes engine), deployed with the
`eoepca` umbrella Helm chart from the companion repository
[helm-chart](https://github.com/cgi-italy-insula-processing/helm-chart).

The scripts follow the conventions of the
[EOEPCA deployment guide](https://deployment-guide.docs.eoepca.org/current/building-blocks/oapip-engine/)
(`check-prerequisites.sh`, `configure-oapip.sh`, `validation.sh`, a shared
`$HOME/.eoepca/state` file), but every check and every generated value is written
against the `eoepca` chart, not against the reference `zoo-project-dru` deployment.

> **No authentication or authorization.** The building block exposes its endpoints
> anonymously. Protecting them is the responsibility of the operator; see the
> Security section of the chart README.

## What the scripts do

| Script | Purpose |
| --- | --- |
| `scripts/check-prerequisites.sh` | Verifies the cluster can host the building block: tooling, API access, Kubernetes version (1.34+), ingress controller, storage class, cert-manager when TLS is on, optional RWX storage and external object store |
| `scripts/configure-oapip.sh` | Asks for the deployment parameters and writes a `values.yaml` override for the chart |
| `scripts/deploy.sh` | `helm upgrade --install` wrapper using the generated values |
| `scripts/validation.sh` | Validates a deployed release: workloads, services, volumes, configuration, workflows namespace and RBAC, Argo CRDs, ingresses, public and in-cluster endpoints, and that the server Ingress exposes only the job output endpoint |
| `scripts/e2e.sh` | Deploys the `fastcopier-stac` application package through the OGC API, runs it on a STAC input and checks the copied output file |

Everything is plain Bash (>= 4.4) plus `kubectl`, `helm` and `curl`. `jq` is optional
and only used by one validation check.

## Repository layout

```
scripts/
  common/
    utils.sh               # output, state file, prompting, check runner
    prerequisite-utils.sh  # check_* functions for the pre-flight checks
    validation-utils.sh    # check_* functions for the post-deploy checks
  check-prerequisites.sh
  configure-oapip.sh
  deploy.sh
  validation.sh
  e2e.sh
docs/
  prerequisites.md
  configuration.md
  validation.md
  troubleshooting.md
generated/                 # generated values.yaml, git-ignored, contains secrets
```

## Quickstart

```sh
git clone https://github.com/cgi-italy-insula-processing/helm-chart.git
git clone https://github.com/cgi-italy-insula-processing/deployment.git
cd deployment/scripts

./check-prerequisites.sh                      # first pass, with defaults
./configure-oapip.sh                          # answers -> ../generated/values.yaml
./check-prerequisites.sh                      # second pass, with the real values
./deploy.sh --chart ../../helm-chart
./validation.sh
./e2e.sh
```

Without DNS records for the chosen hostnames, answer the `INGRESS_ADDRESS` prompt
with the IP address of the ingress controller (for example `127.0.0.1` on a kind
node): `validation.sh` and `e2e.sh` then send their requests there. With the default
self-signed issuer they do not verify the server certificates and say so; see
[docs/validation.md](docs/validation.md) for `CURL_INSECURE`.

Every answer is stored in `$HOME/.eoepca/state` (mode 0600, holds credentials). A
second run keeps the stored answers; use `configure-oapip.sh --reconfigure` to change
them, or `--non-interactive` to accept all defaults in CI.

## Configuration surface

`configure-oapip.sh` collects and writes into the values file:

- **Infrastructure:** base domain (`INGRESS_HOST`), the OGC API hostname (also used by
  the job output links), the optional Argo UI and MinIO hostnames, IngressClass, TLS
  mode (cert-manager ClusterIssuer or plain HTTP), storage class and volume sizes.
- **Backend:** MinIO/S3 credentials (shared with the server, worker and workflow
  steps), database names, users and passwords, Postgres superuser password, ActiveMQ
  console credentials, Argo UI exposure, authentication mode and role.

Passwords can be generated instead of typed. Image references are left to the chart,
which pulls public images. See [docs/configuration.md](docs/configuration.md) for the
mapping between prompts and chart values.

## Known limitations

- The bundled MinIO is for testing only. Using an external object store needs the S3
  endpoint in the server and worker application properties of the chart; the scripts
  do not generate them (`S3_EXTERNAL=true` only runs the reachability check).
- Per-job workflow volumes always use the cluster default StorageClass.
- The scripts target ingress-nginx: the server Ingress restricts its path with a
  regular expression (`nginx.ingress.kubernetes.io/use-regex`).

## Documentation

- [docs/prerequisites.md](docs/prerequisites.md) - what the cluster must provide
- [docs/configuration.md](docs/configuration.md) - prompts and the chart values they set
- [docs/validation.md](docs/validation.md) - every check performed, and the end-to-end test
- [docs/troubleshooting.md](docs/troubleshooting.md) - common failures and how to read them

## License

Apache License 2.0, see [LICENSE](LICENSE).
