#!/usr/bin/env bash
# Checks that a cluster can host the EOEPCA+ processing building block.
#
# Run it before configure-oapip.sh for a first pass with defaults, and again
# after configure-oapip.sh to check the exact values that were chosen.
#
# Usage:
#   ./check-prerequisites.sh [options]
#
# Options:
#   -n, --namespace NAME        target namespace (default: eoepca)
#   -c, --ingress-class NAME    expected IngressClass (default: nginx)
#   -s, --storage-class NAME    storage class for ReadWriteOnce volumes
#       --tls-mode MODE         cert-manager | none
#       --cluster-issuer NAME   cert-manager ClusterIssuer
#   -h, --help                  this message

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/utils.sh
. "$SCRIPT_DIR/common/utils.sh"
# shellcheck source=common/prerequisite-utils.sh
. "$SCRIPT_DIR/common/prerequisite-utils.sh"

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

load_state

while [ $# -gt 0 ]; do
    case "$1" in
    -n | --namespace)
        NAMESPACE="$2"
        shift 2
        ;;
    -c | --ingress-class)
        INGRESS_CLASS="$2"
        shift 2
        ;;
    -s | --storage-class)
        PERSISTENT_STORAGECLASS="$2"
        shift 2
        ;;
    --tls-mode)
        TLS_MODE="$2"
        shift 2
        ;;
    --cluster-issuer)
        CLUSTER_ISSUER="$2"
        shift 2
        ;;
    -h | --help) usage 0 ;;
    *)
        error "unknown option: $1"
        usage 1
        ;;
    esac
done

# Defaults, so the script is usable before configure-oapip.sh has ever run.
NAMESPACE="${NAMESPACE:-eoepca}"
INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
PERSISTENT_STORAGECLASS="${PERSISTENT_STORAGECLASS:-}"
SHARED_MOUNTS_ENABLED="${SHARED_MOUNTS_ENABLED:-false}"
SHARED_STORAGECLASS="${SHARED_STORAGECLASS:-}"
TLS_MODE="${TLS_MODE:-cert-manager}"
CLUSTER_ISSUER="${CLUSTER_ISSUER:-selfsigned-ca-issuer}"
S3_EXTERNAL="${S3_EXTERNAL:-false}"

section "Prerequisites for the EOEPCA+ processing building block"
log "namespace:         $NAMESPACE"
log "ingress class:     $INGRESS_CLASS"
log "storage class:     ${PERSISTENT_STORAGECLASS:-<cluster default>}"
log "tls mode:          $TLS_MODE"
log "shared (RWX) mode: $SHARED_MOUNTS_ENABLED"
log "external S3:       $S3_EXTERNAL"

checks=(
    "check_kubectl_installed"
    "check_helm_installed"
    "check_curl_installed"
    "check_kubernetes_access"
    "check_kubernetes_version"
    "check_namespace_available '$NAMESPACE'"
    "check_ingress_controller_installed"
    "check_storage_class_exists '$PERSISTENT_STORAGECLASS'"
    "check_cert_manager_installed"
    "check_cluster_issuer_exists '$CLUSTER_ISSUER'"
    "check_rwx_storage"
    "check_object_store_accessible"
)

section "Running checks"
if run_checks "${checks[@]}"; then
    log ""
    ok "all prerequisites satisfied"
    exit 0
fi
log ""
error "prerequisites are not satisfied, see the failures above"
exit 1
