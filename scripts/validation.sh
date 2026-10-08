#!/usr/bin/env bash
# Validates a deployed EOEPCA+ processing building block: workloads ready,
# services and volumes in place, endpoints answering.
#
# Reads its parameters from $HOME/.eoepca/state (written by configure-oapip.sh)
# and accepts overrides on the command line.
#
# Usage:
#   ./validation.sh [options]
#
# Options:
#   -r, --release NAME          helm release name (default: eoepca)
#   -n, --namespace NAME        release namespace (default: eoepca)
#       --ingress-address IP    send the HTTP checks to this ingress address instead
#                               of resolving the hostnames through DNS
#       --skip-urls             skip the HTTP endpoint checks
#       --skip-internal         skip the in-cluster port-forward checks
#       --quiet-report          do not print the resource listing at the end
#   -h, --help                  this message
#
# Environment:
#   CURL_INSECURE               true/false: skip/verify server certificates (default: skip
#                               only with TLS_MODE=cert-manager and selfsigned-ca-issuer)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/utils.sh
. "$SCRIPT_DIR/common/utils.sh"
# shellcheck source=common/validation-utils.sh
. "$SCRIPT_DIR/common/validation-utils.sh"

SKIP_URLS=false
SKIP_INTERNAL=false
QUIET_REPORT=false

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

load_state

while [ $# -gt 0 ]; do
    case "$1" in
    -r | --release)
        RELEASE_NAME="$2"
        shift 2
        ;;
    -n | --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
    --ingress-address)
        INGRESS_ADDRESS="$2"
        shift 2
        ;;
    --skip-urls)
        SKIP_URLS=true
        shift
        ;;
    --skip-internal)
        SKIP_INTERNAL=true
        shift
        ;;
    --quiet-report)
        QUIET_REPORT=true
        shift
        ;;
    -h | --help) usage 0 ;;
    *)
        error "unknown option: $1"
        usage 1
        ;;
    esac
done

REL="${RELEASE_NAME:-eoepca}"
NS="${NAMESPACE:-eoepca}"
WF_NS="${REL}-workflows"
SCHEME="${HTTP_SCHEME:-https}"
warn_if_curl_insecure "$SCHEME"
OAPIP_HOSTNAME="${OAPIP_HOSTNAME:-}"
ARGO_INGRESS_ENABLED="${ARGO_INGRESS_ENABLED:-true}"
ARGO_HOSTNAME="${ARGO_HOSTNAME:-}"
MINIO_INGRESS_ENABLED="${MINIO_INGRESS_ENABLED:-false}"
MINIO_HOSTNAME="${MINIO_HOSTNAME:-}"
export INGRESS_ADDRESS="${INGRESS_ADDRESS:-}"

require_cmd kubectl
require_cmd curl
kubectl get namespace "$NS" >/dev/null 2>&1 || die "namespace $NS does not exist"

# Per-section summaries are suppressed; a single summary is printed at the end.
export RUN_CHECKS_QUIET=true

section "Validating release '$REL' in namespace '$NS'"
[ -n "$INGRESS_ADDRESS" ] && info "HTTP checks are sent to the ingress address $INGRESS_ADDRESS"

# ---------------------------------------------------------------------------
# Workloads
# ---------------------------------------------------------------------------

workload_checks=(
    "check_statefulset_ready '$NS' '${REL}-postgres'"
    "check_deployment_ready '$NS' '${REL}-broker'"
    "check_deployment_ready '$NS' '${REL}-minio'"
    "check_deployment_ready '$NS' '${REL}-server'"
    "check_deployment_ready '$NS' '${REL}-worker'"
    "check_deployment_ready '$NS' '${REL}-worker-event-collector'"
    "check_deployment_ready '$NS' '${REL}-ogc-api-processes'"
    "check_deployment_ready '$NS' '${REL}-argo-workflows-workflow-controller'"
    "check_deployment_ready '$NS' '${REL}-argo-workflows-server'"
    "check_pods_running '$NS' 'app.kubernetes.io/name=postgres,app.kubernetes.io/instance=${REL}' 1"
    "check_pods_running '$NS' 'app.kubernetes.io/name=broker,app.kubernetes.io/instance=${REL}' 1"
    "check_pods_running '$NS' 'app.kubernetes.io/name=server,app.kubernetes.io/instance=${REL}' 1"
    "check_pods_running '$NS' 'app.kubernetes.io/name=worker,app.kubernetes.io/instance=${REL}' 1"
    "check_pods_running '$NS' 'app.kubernetes.io/name=worker-event-collector,app.kubernetes.io/instance=${REL}' 1"
    "check_pods_running '$NS' 'app.kubernetes.io/name=ogc-api-processes,app.kubernetes.io/instance=${REL}' 1"
    "check_pods_running '$NS' 'app=minio,release=${REL}' 1"
    "check_pods_running '$NS' 'app.kubernetes.io/instance=${REL},app.kubernetes.io/part-of=argo-workflows' 2"
)

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

service_checks=(
    "check_service_exists '$NS' '${REL}-postgres-service'"
    "check_service_exists '$NS' '${REL}-broker-service'"
    "check_service_exists '$NS' '${REL}-server-service'"
    "check_service_exists '$NS' '${REL}-ogc-api-processes-service'"
    "check_service_exists '$NS' '${REL}-minio-service'"
    "check_service_exists '$NS' '${REL}-argo-workflows-server'"
)

# ---------------------------------------------------------------------------
# Storage, configuration and the workflows namespace
# ---------------------------------------------------------------------------

storage_checks=(
    "check_pvc_bound '$NS' 'data-${REL}-postgres-0'"
    "check_pvc_bound '$NS' '${REL}-broker'"
    "check_pvc_bound '$NS' '${REL}-minio'"
    "check_pvc_bound '$NS' '${REL}-server-data'"
)

config_checks=(
    "check_configmap_exists '$NS' '${REL}-platform-server-config'"
    "check_configmap_exists '$NS' '${REL}-platform-server-log-config'"
    "check_configmap_exists '$NS' '${REL}-worker-config'"
    "check_configmap_exists '$NS' '${REL}-worker-event-collector-config'"
    "check_configmap_exists '$NS' '${REL}-platform-worker-log-config'"
    "check_configmap_exists '$NS' '${REL}-ogcapi-config'"
    "check_secret_exists '$NS' '${REL}-secret'"
    "check_secret_exists '$NS' '${REL}-worker-secret'"
    "check_secret_exists '$NS' '${REL}-postgres-secret'"
    "check_secret_exists '$NS' 'activemq-user-secret'"
    "check_secret_exists '$NS' '${REL}-minio-storage-secret'"
)

# The pull secret names are the chart defaults (workflowPullSecrets); adjust
# WORKFLOW_PULL_SECRETS when the chart values rename them.
WORKFLOW_PULL_SECRETS="${WORKFLOW_PULL_SECRETS:-internal-registry-pull-secret external-registry-pull-secret}"
workflows_checks=(
    "check_namespace_exists '$WF_NS'"
    "check_configmap_exists '$WF_NS' 'input-downloader-config'"
    "check_configmap_exists '$WF_NS' 'output-uploader-config'"
    "check_secret_exists '$WF_NS' '${REL}-minio-storage-secret'"
    "check_role_exists '$WF_NS' '${REL}-worker'"
    "check_rolebinding_exists '$WF_NS' '${REL}-worker'"
    "check_crd_exists 'workflows.argoproj.io'"
    "check_crd_exists 'workflowtemplates.argoproj.io'"
    "check_crd_exists 'cronworkflows.argoproj.io'"
    "check_crd_exists 'clusterworkflowtemplates.argoproj.io'"
    "check_crd_exists 'workflowtaskresults.argoproj.io'"
)
for s in $WORKFLOW_PULL_SECRETS; do
    workflows_checks+=("check_secret_exists '$WF_NS' '$s'")
done

# ---------------------------------------------------------------------------
# Ingress
# ---------------------------------------------------------------------------

ingress_checks=(
    "check_ingress_exists '$NS' '${REL}-ogc-api-processes'"
    "check_ingress_exists '$NS' '${REL}-server'"
    "check_ingress_has_address '$NS' '${REL}-ogc-api-processes'"
)
[ "$MINIO_INGRESS_ENABLED" = "true" ] && ingress_checks+=("check_ingress_exists '$NS' '${REL}-minio'")
[ "$ARGO_INGRESS_ENABLED" = "true" ] && ingress_checks+=("check_ingress_exists '$NS' '${REL}-argo-workflows-server'")

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

url_checks=()
if [ "$SKIP_URLS" != "true" ]; then
    if [ -z "$OAPIP_HOSTNAME" ]; then
        warn "OAPIP_HOSTNAME is not set, skipping the HTTP endpoint checks (run configure-oapip.sh first)"
    else
        base="$SCHEME://$OAPIP_HOSTNAME"
        url_checks+=(
            "check_url_status_code '$base/ogcapi/' '200'"
            "check_url_status_code '$base/ogcapi/processes' '200'"
            "check_url_status_code '$base/ogcapi/conformance' '200'"
            "check_url_json_key '$base/ogcapi/processes' '.processes'"
            "check_url_status_code '$base/ogcapi/api/' '200'"
            # The server Ingress must expose only the job output endpoint.
            "CHECK_URL_NO_REDIRECT=true check_url_status_code '$base/secure/api/v2.0/jobs' '404'"
            "CHECK_URL_NO_REDIRECT=true check_url_status_code '$base/secure/api/v2.0/services' '404'"
        )
        [ "$ARGO_INGRESS_ENABLED" = "true" ] && [ -n "$ARGO_HOSTNAME" ] &&
            url_checks+=("check_url_status_code '$SCHEME://$ARGO_HOSTNAME/' '200'")
        [ "$MINIO_INGRESS_ENABLED" = "true" ] && [ -n "$MINIO_HOSTNAME" ] &&
            url_checks+=("check_url_status_code '$SCHEME://$MINIO_HOSTNAME/minio/health/ready' '200'")
    fi
fi

internal_checks=()
if [ "$SKIP_INTERNAL" != "true" ]; then
    internal_checks+=(
        "check_port_forward_endpoint '$NS' 'deployment/${REL}-ogc-api-processes' 8081 '/actuator/health/readiness' '200'"
        "check_port_forward_endpoint '$NS' 'service/${REL}-broker-service' 8161 '/' '200,401,302'"
        "check_port_forward_endpoint '$NS' 'service/${REL}-minio-service' 9000 '/minio/health/ready' '200'"
    )
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

section "Workloads"
run_checks "${workload_checks[@]}"
w_pass=$CHECKS_PASSED w_fail=$CHECKS_FAILED w_skip=$CHECKS_SKIPPED
w_failed=("${FAILED_CHECKS[@]}")

section "Services"
run_checks "${service_checks[@]}"
s_pass=$CHECKS_PASSED s_fail=$CHECKS_FAILED s_skip=$CHECKS_SKIPPED
s_failed=("${FAILED_CHECKS[@]}")

section "Storage"
run_checks "${storage_checks[@]}"
st_pass=$CHECKS_PASSED st_fail=$CHECKS_FAILED st_skip=$CHECKS_SKIPPED
st_failed=("${FAILED_CHECKS[@]}")

section "Configuration"
run_checks "${config_checks[@]}"
c_pass=$CHECKS_PASSED c_fail=$CHECKS_FAILED c_skip=$CHECKS_SKIPPED
c_failed=("${FAILED_CHECKS[@]}")

section "Workflows namespace and Argo CRDs"
run_checks "${workflows_checks[@]}"
wf_pass=$CHECKS_PASSED wf_fail=$CHECKS_FAILED wf_skip=$CHECKS_SKIPPED
wf_failed=("${FAILED_CHECKS[@]}")

section "Ingress"
run_checks "${ingress_checks[@]}"
i_pass=$CHECKS_PASSED i_fail=$CHECKS_FAILED i_skip=$CHECKS_SKIPPED
i_failed=("${FAILED_CHECKS[@]}")

u_pass=0 u_fail=0 u_skip=0
u_failed=()
if [ ${#url_checks[@]} -gt 0 ]; then
    section "Endpoints"
    run_checks "${url_checks[@]}"
    u_pass=$CHECKS_PASSED u_fail=$CHECKS_FAILED u_skip=$CHECKS_SKIPPED
    u_failed=("${FAILED_CHECKS[@]}")
fi

n_pass=0 n_fail=0 n_skip=0
n_failed=()
if [ ${#internal_checks[@]} -gt 0 ]; then
    section "In-cluster endpoints"
    run_checks "${internal_checks[@]}"
    n_pass=$CHECKS_PASSED n_fail=$CHECKS_FAILED n_skip=$CHECKS_SKIPPED
    n_failed=("${FAILED_CHECKS[@]}")
fi

total_pass=$((w_pass + s_pass + st_pass + c_pass + wf_pass + i_pass + u_pass + n_pass))
total_fail=$((w_fail + s_fail + st_fail + c_fail + wf_fail + i_fail + u_fail + n_fail))
total_skip=$((w_skip + s_skip + st_skip + c_skip + wf_skip + i_skip + u_skip + n_skip))

section "Validation result"
log "passed:  $total_pass"
log "failed:  $total_fail"
log "skipped: $total_skip"

if [ "$total_fail" -gt 0 ]; then
    log ""
    error "failed checks:"
    for c in "${w_failed[@]}" "${s_failed[@]}" "${st_failed[@]}" "${c_failed[@]}" \
        "${wf_failed[@]}" "${i_failed[@]}" "${u_failed[@]}" "${n_failed[@]}"; do
        [ -n "$c" ] && log "  - $c"
    done
fi

[ "$QUIET_REPORT" = "true" ] || print_release_resources "$NS" "$REL"

if [ "$total_fail" -gt 0 ]; then
    log ""
    error "deployment validation failed"
    exit 1
fi
log ""
ok "deployment validation passed"
exit 0
