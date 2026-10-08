#!/usr/bin/env bash
# Prerequisite checks for the EOEPCA+ processing building block.
#
# Every function prints its own result line and returns:
#   0 = pass, 1 = fail, 2 = skipped / inconclusive
#
# This file is meant to be sourced, not executed.

HELM_MIN_VERSION="${HELM_MIN_VERSION:-3.5.0}"
# Must match kubeVersion in the chart's Chart.yaml: helm refuses older clusters.
KUBERNETES_MIN_VERSION="${KUBERNETES_MIN_VERSION:-1.34.0}"

# ---------------------------------------------------------------------------
# Tooling
# ---------------------------------------------------------------------------

check_command_installed() {
    local cmd="$1" hint="${2:-}"
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd is installed ($(command -v "$cmd"))"
        return 0
    fi
    error "$cmd is not installed${hint:+ - see $hint}"
    return 1
}

# version_at_least FOUND REQUIRED
version_at_least() {
    local found="$1" required="$2"
    [ "$(printf '%s\n%s\n' "$required" "$found" | sort -V | head -n1)" = "$required" ]
}

check_kubectl_installed() {
    check_command_installed kubectl "https://kubernetes.io/docs/tasks/tools/"
}

check_helm_installed() {
    check_command_installed helm "https://helm.sh/docs/intro/install/" || return 1
    local found
    found="$(helm version --short 2>/dev/null | sed -E 's/^v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
    if [ -z "$found" ]; then
        warn "could not determine the helm version"
        return 2
    fi
    if version_at_least "$found" "$HELM_MIN_VERSION"; then
        ok "helm $found satisfies the minimum version $HELM_MIN_VERSION"
        return 0
    fi
    error "helm $found is older than the required $HELM_MIN_VERSION"
    return 1
}

check_curl_installed() {
    check_command_installed curl "https://curl.se/"
}

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------

check_kubernetes_access() {
    if ! command -v kubectl >/dev/null 2>&1; then
        error "kubectl is not installed, cannot reach the cluster"
        return 1
    fi
    if kubectl version -o json >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
        local context nodes
        context="$(kubectl config current-context 2>/dev/null || echo unknown)"
        nodes="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
        ok "cluster reachable (context '$context', $nodes node(s))"
        return 0
    fi
    error "cannot reach the Kubernetes cluster, check your kubeconfig and context"
    return 1
}

check_kubernetes_version() {
    local found
    found="$(kubectl get --raw /version 2>/dev/null |
        sed -nE 's/.*"gitVersion"[[:space:]]*:[[:space:]]*"v?([0-9]+\.[0-9]+\.[0-9]+).*/\1/p')"
    if [ -z "$found" ]; then
        error "could not read the Kubernetes server version"
        return 1
    fi
    if version_at_least "$found" "$KUBERNETES_MIN_VERSION"; then
        ok "Kubernetes $found satisfies the minimum version $KUBERNETES_MIN_VERSION"
        return 0
    fi
    error "Kubernetes $found is older than the required $KUBERNETES_MIN_VERSION (the chart sets kubeVersion >= $KUBERNETES_MIN_VERSION)"
    return 1
}

check_namespace_available() {
    local ns="$1"
    if kubectl get namespace "$ns" >/dev/null 2>&1; then
        ok "namespace '$ns' exists"
    else
        info "namespace '$ns' does not exist yet, helm will need --create-namespace"
    fi
    return 0
}

check_ingress_controller_installed() {
    local classes
    classes="$(kubectl get ingressclass -o name 2>/dev/null | sed 's|ingressclass.networking.k8s.io/||' | tr '\n' ' ')"
    if [ -z "$classes" ]; then
        error "no IngressClass found, an ingress controller is required"
        return 1
    fi

    local wanted="${INGRESS_CLASS:-nginx}"
    if printf '%s' "$classes" | grep -qw "$wanted"; then
        ok "IngressClass '$wanted' is available (found: $classes)"
        return 0
    fi
    error "IngressClass '$wanted' not found, available: $classes"
    return 1
}

check_storage_class_exists() {
    local sc="$1"
    if [ -z "$sc" ]; then
        info "no storage class configured, the cluster default will be used"
        local default_sc
        default_sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n1)"
        if [ -n "$default_sc" ]; then
            ok "cluster default storage class is '$default_sc'"
            return 0
        fi
        error "no default storage class in the cluster and none configured"
        return 1
    fi
    if kubectl get storageclass "$sc" >/dev/null 2>&1; then
        ok "storage class '$sc' exists"
        return 0
    fi
    error "storage class '$sc' not found"
    return 1
}

check_cert_manager_installed() {
    if [ "${TLS_MODE:-cert-manager}" != "cert-manager" ]; then
        skip "TLS_MODE=${TLS_MODE:-}, cert-manager is not required"
        return 2
    fi
    if ! kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
        error "cert-manager CRDs not found, install cert-manager or set TLS_MODE=none"
        return 1
    fi
    local ready
    ready="$(kubectl get pods -A -l app.kubernetes.io/name=cert-manager --no-headers 2>/dev/null | grep -c 'Running' || true)"
    if [ "${ready:-0}" -ge 1 ]; then
        ok "cert-manager is installed and running"
        return 0
    fi
    error "cert-manager CRDs exist but no cert-manager pod is running"
    return 1
}

check_cluster_issuer_exists() {
    local issuer="${1:-${CLUSTER_ISSUER:-}}"
    if [ "${TLS_MODE:-cert-manager}" != "cert-manager" ]; then
        skip "TLS_MODE=${TLS_MODE:-}, no ClusterIssuer needed"
        return 2
    fi
    if [ -z "$issuer" ]; then
        error "TLS_MODE=cert-manager but CLUSTER_ISSUER is empty"
        return 1
    fi
    if kubectl get clusterissuer "$issuer" >/dev/null 2>&1; then
        local ready
        ready="$(kubectl get clusterissuer "$issuer" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
        if [ "$ready" = "True" ]; then
            ok "ClusterIssuer '$issuer' is ready"
            return 0
        fi
        error "ClusterIssuer '$issuer' exists but is not ready (status: ${ready:-unknown})"
        return 1
    fi
    error "ClusterIssuer '$issuer' not found"
    return 1
}

# ---------------------------------------------------------------------------
# Storage
#
# The chart only needs ReadWriteOnce volumes in its default configuration.
# ReadWriteMany is checked on demand: SHARED_MOUNTS_ENABLED=true.
# ---------------------------------------------------------------------------

check_rwx_storage() {
    if [ "${SHARED_MOUNTS_ENABLED:-false}" != "true" ]; then
        skip "SHARED_MOUNTS_ENABLED=false, ReadWriteMany storage is not required"
        return 2
    fi

    local sc="${SHARED_STORAGECLASS:-}" ns="${NAMESPACE:-default}"
    local pvc="eoepca-rwx-precheck-$$"

    if [ -z "$sc" ]; then
        error "SHARED_MOUNTS_ENABLED=true but SHARED_STORAGECLASS is empty"
        return 1
    fi

    kubectl get namespace "$ns" >/dev/null 2>&1 || ns="default"

    cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: $pvc
  namespace: $ns
spec:
  accessModes: [ReadWriteMany]
  storageClassName: $sc
  resources:
    requests:
      storage: 1Gi
EOF
    if [ $? -ne 0 ]; then
        error "could not create the test PVC in namespace '$ns'"
        return 1
    fi

    local phase="" i
    for i in $(seq 1 30); do
        phase="$(kubectl get pvc "$pvc" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)"
        [ "$phase" = "Bound" ] && break
        sleep 2
    done
    kubectl delete pvc "$pvc" -n "$ns" --wait=false >/dev/null 2>&1 || true

    if [ "$phase" = "Bound" ]; then
        ok "storage class '$sc' provisions ReadWriteMany volumes"
        return 0
    fi

    local binding_mode
    binding_mode="$(kubectl get storageclass "$sc" -o jsonpath='{.volumeBindingMode}' 2>/dev/null)"
    if [ "$binding_mode" = "WaitForFirstConsumer" ]; then
        warn "storage class '$sc' uses WaitForFirstConsumer, the test PVC stays Pending until a pod mounts it: inconclusive"
        return 2
    fi
    error "test PVC on storage class '$sc' did not bind (phase: ${phase:-unknown})"
    return 1
}

# ---------------------------------------------------------------------------
# Object storage
#
# The chart deploys its own MinIO, so an external object store only has to be
# reachable when the deployer opted for one.
# ---------------------------------------------------------------------------

check_object_store_accessible() {
    if [ "${S3_EXTERNAL:-false}" != "true" ]; then
        skip "S3_EXTERNAL=false, the in-cluster MinIO is used as object store"
        return 2
    fi
    local endpoint="${S3_ENDPOINT:-}"
    if [ -z "$endpoint" ]; then
        error "S3_EXTERNAL=true but S3_ENDPOINT is empty"
        return 1
    fi
    if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ]; then
        error "S3_ACCESS_KEY / S3_SECRET_KEY must both be set when S3_EXTERNAL=true"
        return 1
    fi
    local code
    local -a tls=()
    curl_insecure && tls=(-k)
    code="$(curl "${tls[@]}" -s -o /dev/null -w '%{http_code}' --max-time 15 "$endpoint" 2>/dev/null)"
    if [ -n "$code" ] && [ "$code" != "000" ]; then
        ok "object store endpoint $endpoint answered (HTTP $code)"
        return 0
    fi
    error "object store endpoint $endpoint is not reachable"
    return 1
}
