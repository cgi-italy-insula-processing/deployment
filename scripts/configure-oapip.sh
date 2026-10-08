#!/usr/bin/env bash
# Collects the deployment parameters of the EOEPCA+ processing building block
# and writes a values.yaml override for the eoepca umbrella chart.
#
# Answers are stored in $HOME/.eoepca/state, so a second run keeps the previous
# values unless --reconfigure is given.
#
# Usage:
#   ./configure-oapip.sh [options]
#
# Options:
#   -o, --output PATH     output values file (default: ../generated/values.yaml)
#   -r, --reconfigure     prompt again for values that are already set
#   -y, --non-interactive accept all defaults, fail when a value has none
#   -h, --help            this message

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=common/utils.sh
. "$SCRIPT_DIR/common/utils.sh"

OUTPUT_PATH="$REPO_DIR/generated/values.yaml"

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

load_state

while [ $# -gt 0 ]; do
    case "$1" in
    -o | --output)
        OUTPUT_PATH="$2"
        shift 2
        ;;
    -r | --reconfigure)
        export EOEPCA_RECONFIGURE=true
        shift
        ;;
    -y | --non-interactive)
        export EOEPCA_NONINTERACTIVE=true
        shift
        ;;
    -h | --help) usage 0 ;;
    *)
        error "unknown option: $1"
        usage 1
        ;;
    esac
done

# ---------------------------------------------------------------------------
# Release identity
# ---------------------------------------------------------------------------

section "Release"
ask RELEASE_NAME "Helm release name (prefixes every resource name)" "eoepca" is_k8s_name
ask NAMESPACE "Kubernetes namespace for the release" "eoepca" is_k8s_name
add_to_state_file WORKFLOWS_NAMESPACE "${RELEASE_NAME}-workflows"
info "workflow pods will run in ${RELEASE_NAME}-workflows (namespace created by the chart)"

# ---------------------------------------------------------------------------
# Infrastructure
# ---------------------------------------------------------------------------

section "Infrastructure: ingress and TLS"
ask INGRESS_HOST "Base domain for the exposed services (e.g. example.com)" "" is_valid_domain
ask OAPIP_HOSTNAME "Hostname serving the OGC API Processes endpoint and the job output downloads" "processing.$INGRESS_HOST" is_valid_hostname
ask INGRESS_CLASS "IngressClass to use" "nginx" is_k8s_name
ask TLS_MODE "TLS mode: cert-manager (issue certificates) or none (plain HTTP)" "cert-manager" is_tls_mode

if [ "$TLS_MODE" = "cert-manager" ]; then
    ask CLUSTER_ISSUER "cert-manager ClusterIssuer name" "selfsigned-ca-issuer" is_k8s_name
    add_to_state_file HTTP_SCHEME "https"
else
    add_to_state_file HTTP_SCHEME "http"
    warn "TLS disabled: every exposed endpoint will be served over plain HTTP"
fi
ask INGRESS_ADDRESS "IP address of the ingress controller, used by validation.sh and e2e.sh instead of DNS (empty = use DNS)" "" is_any

section "Infrastructure: storage"
ask PERSISTENT_STORAGECLASS "Storage class for ReadWriteOnce volumes (empty = cluster default)" "" is_any
ask POSTGRES_STORAGE_SIZE "Postgres volume size" "20Gi" is_storage_size
ask MINIO_STORAGE_SIZE "MinIO volume size" "50Gi" is_storage_size
ask SERVER_STORAGE_SIZE "Server data volume size (job outputs)" "10Gi" is_storage_size
ask BROKER_STORAGE_SIZE "ActiveMQ broker volume size" "1Gi" is_storage_size
info "per-job workflow volumes always use the cluster default storage class"

# ---------------------------------------------------------------------------
# Backend
# ---------------------------------------------------------------------------

section "Backend: object storage (bundled MinIO, for testing only)"
ask OAPIP_S3_ACCESS_KEY "MinIO root user / S3 access key (shared with server, worker and workflow steps)" "eoepca" is_non_empty
ask_or_generate OAPIP_S3_SECRET_KEY "MinIO root password / S3 secret key, at least 8 characters (empty = generate)" 32 is_min8_chars
ask MINIO_INGRESS_ENABLED "Expose the MinIO S3 API through an Ingress? (not needed by the building block)" "false" is_boolean
if [ "$MINIO_INGRESS_ENABLED" = "true" ]; then
    ask MINIO_HOSTNAME "Hostname serving the MinIO S3 API" "minio-processing.$INGRESS_HOST" is_valid_hostname
fi

section "Backend: database"
ask PLATFORM_DB_NAME "Platform database name" "platform_v2" is_k8s_dbname
ask PLATFORM_DB_USER "Platform database user" "platform" is_k8s_dbname
ask WORKER_DB_NAME "Worker database name" "platform_worker" is_k8s_dbname
ask WORKER_DB_USER "Worker database user" "platform_worker" is_k8s_dbname
ask_or_generate PLATFORM_DB_PASSWORD "Platform database password (empty = generate)" 24
ask_or_generate WORKER_DB_PASSWORD "Worker database password (empty = generate)" 24
ask_or_generate POSTGRES_SUPERUSER_PASSWORD "Postgres superuser password (empty = generate)" 24

section "Backend: message broker"
ask ACTIVEMQ_USER "ActiveMQ web console username" "platform" is_simple_token
ask_or_generate ACTIVEMQ_PASSWORD "ActiveMQ web console password, letters, digits, . _ - only (empty = generate)" 24 is_simple_token
info "the broker does not authenticate JMS clients: keep it internal to the cluster"

section "Argo Workflows"
ask ARGO_INGRESS_ENABLED "Expose the Argo Workflows UI through an Ingress?" "true" is_boolean
if [ "$ARGO_INGRESS_ENABLED" = "true" ]; then
    ask ARGO_HOSTNAME "Hostname serving the Argo Workflows UI" "argo-processing.$INGRESS_HOST" is_valid_hostname
fi
ask ARGO_AUTH_MODE "Argo UI authentication: client (bearer token) or server (no auth)" "client" is_argo_auth_mode
if [ "$ARGO_AUTH_MODE" = "server" ] && [ "$ARGO_INGRESS_ENABLED" = "true" ]; then
    warn "authModes=server disables authentication: anyone reaching $ARGO_HOSTNAME gets full access, including running containers in the cluster"
fi
ask ARGO_UI_ROLE "Cluster role bound to the Argo UI service account (view|edit|admin)" "edit" is_argo_role

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

# emit_tls INDENT HOST - a tls block, or an empty list when TLS is off.
emit_tls() {
    local indent="$1" host="$2"
    if [ "$TLS_MODE" = "cert-manager" ]; then
        printf '%stls:\n%s  - secretName: %s-tls\n%s    hosts:\n%s      - %s\n' \
            "$indent" "$indent" "$host" "$indent" "$indent" "$host"
    else
        printf '%stls: []\n' "$indent"
    fi
}

# emit_ssl_annotations INDENT ISSUER - ssl-redirect follows the TLS mode; with
# ISSUER=true also asks cert-manager (ingress-shim) to issue <host>-tls. The
# issuer annotation goes on one Ingress per host only; the others reuse the secret.
emit_ssl_annotations() {
    local indent="$1" issuer="$2"
    if [ "$TLS_MODE" = "cert-manager" ]; then
        printf '%snginx.ingress.kubernetes.io/ssl-redirect: "true"\n' "$indent"
        [ "$issuer" = "true" ] && printf '%scert-manager.io/cluster-issuer: %s\n' "$indent" "$CLUSTER_ISSUER"
    else
        printf '%snginx.ingress.kubernetes.io/ssl-redirect: "false"\n' "$indent"
    fi
    return 0
}

# emit_storage_class INDENT - only when a class was chosen; empty = cluster default.
emit_storage_class() {
    local indent="$1"
    [ -n "$PERSISTENT_STORAGECLASS" ] && printf '%sstorageClass: %s\n' "$indent" "$(yaml_quote "$PERSISTENT_STORAGECLASS")"
    return 0
}

render_minio_ingress() {
    if [ "$MINIO_INGRESS_ENABLED" = "true" ]; then
        cat <<EOF
  ingress:
    enabled: true
    ingressClassName: $INGRESS_CLASS
    annotations:
$(emit_ssl_annotations "      " true)
    hosts:
      - $MINIO_HOSTNAME
$(emit_tls "    " "$MINIO_HOSTNAME")
EOF
    else
        printf '  ingress:\n    enabled: false\n'
    fi
}

render_argo_ingress() {
    if [ "$ARGO_INGRESS_ENABLED" = "true" ]; then
        cat <<EOF
    ingress:
      enabled: true
      ingressClassName: $INGRESS_CLASS
      annotations:
$(emit_ssl_annotations "        " true)
      hosts:
        - $ARGO_HOSTNAME
$(emit_tls "      " "$ARGO_HOSTNAME")
EOF
    else
        printf '    ingress:\n      enabled: false\n'
    fi
}

render_values() {
    cat <<EOF
# Generated by scripts/configure-oapip.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# Release: $RELEASE_NAME   Namespace: $NAMESPACE
#
# This file contains credentials in clear text. Do not commit it.
# Regenerate with: scripts/configure-oapip.sh --reconfigure

global:
  database:
    platform:
      username: $(yaml_quote "$PLATFORM_DB_USER")
      name: $(yaml_quote "$PLATFORM_DB_NAME")
    worker:
      username: $(yaml_quote "$WORKER_DB_USER")
      name: $(yaml_quote "$WORKER_DB_NAME")
  activemq:
    username: $(yaml_quote "$ACTIVEMQ_USER")
    password: $(yaml_quote "$ACTIVEMQ_PASSWORD")
  storage:
    accesskey: $(yaml_quote "$OAPIP_S3_ACCESS_KEY")
    secretkey: $(yaml_quote "$OAPIP_S3_SECRET_KEY")

databaseSecrets:
  platformPassword: $(yaml_quote "$PLATFORM_DB_PASSWORD")
  workerPassword: $(yaml_quote "$WORKER_DB_PASSWORD")
  postgresPassword: $(yaml_quote "$POSTGRES_SUPERUSER_PASSWORD")

postgres:
  persistence:
$(emit_storage_class "    ")
    size: $POSTGRES_STORAGE_SIZE

broker:
  persistence:
$(emit_storage_class "    ")
    size: $BROKER_STORAGE_SIZE

minio:
  persistence:
$(emit_storage_class "    ")
    size: $MINIO_STORAGE_SIZE
$(render_minio_ingress)

server:
  persistence:
$(emit_storage_class "    ")
    size: $SERVER_STORAGE_SIZE
  # Only the job output download endpoint is exposed (regex path, ingress-nginx).
  # The job output links are derived from this host (https when tls is set).
  ingress:
    enabled: true
    className: $INGRESS_CLASS
    annotations:
      nginx.ingress.kubernetes.io/use-regex: "true"
$(emit_ssl_annotations "      " false)
    hosts:
      - host: $OAPIP_HOSTNAME
        paths:
          - path: /secure/api/v2.0/jobs/[0-9]+/outputs/[^/]+\$
            pathType: ImplementationSpecific
$(emit_tls "    " "$OAPIP_HOSTNAME")

ogc-api-processes:
  ingress:
    enabled: true
    className: $INGRESS_CLASS
    annotations:
$(emit_ssl_annotations "      " true)
    hosts:
      - host: $OAPIP_HOSTNAME
        paths:
          - path: /ogcapi
            pathType: Prefix
$(emit_tls "    " "$OAPIP_HOSTNAME")

argo-workflows:
  server:
    authModes: ["$ARGO_AUTH_MODE"]
$(render_argo_ingress)

argoUiUser:
  clusterRole: $ARGO_UI_ROLE
EOF
}

section "Writing values"
mkdir -p "$(dirname "$OUTPUT_PATH")"
umask 077
render_values >"$OUTPUT_PATH"
chmod 600 "$OUTPUT_PATH"
ok "values written to $OUTPUT_PATH"
ok "answers stored in $STATE_FILE"

log ""
info "next steps:"
log "  1. ./check-prerequisites.sh"
log "  2. ./deploy.sh --chart <path-to>/helm-chart"
log "  3. ./validation.sh"
log "  4. ./e2e.sh"
