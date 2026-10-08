#!/usr/bin/env bash
# Post-deployment validation checks for the EOEPCA+ processing building block.
#
# Every function prints its own result line and returns:
#   0 = pass, 1 = fail, 2 = skipped / inconclusive
#
# This file is meant to be sourced, not executed.

ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-180s}"
CURL_TIMEOUT="${CURL_TIMEOUT:-20}"
# HTTP checks are retried CHECK_URL_RETRIES times, CHECK_URL_RETRY_DELAY seconds apart.
CHECK_URL_RETRIES="${CHECK_URL_RETRIES:-6}"
CHECK_URL_RETRY_DELAY="${CHECK_URL_RETRY_DELAY:-10}"

# ---------------------------------------------------------------------------
# Workloads
# ---------------------------------------------------------------------------

# check_pods_running NAMESPACE LABEL_SELECTOR EXPECTED_COUNT
check_pods_running() {
    local ns="$1" selector="$2" expected="${3:-1}" running
    running="$(kubectl get pods -n "$ns" -l "$selector" \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${running:-0}" -ge "$expected" ]; then
        ok "pods running in $ns matching '$selector': $running (expected >= $expected)"
        return 0
    fi
    error "pods running in $ns matching '$selector': ${running:-0} (expected >= $expected)"
    return 1
}

# check_deployment_ready NAMESPACE NAME
check_deployment_ready() {
    local ns="$1" name="$2"
    if ! kubectl get deployment "$name" -n "$ns" >/dev/null 2>&1; then
        error "deployment $ns/$name does not exist"
        return 1
    fi
    if kubectl rollout status "deployment/$name" -n "$ns" --timeout="$ROLLOUT_TIMEOUT" >/dev/null 2>&1; then
        ok "deployment $ns/$name is ready"
        return 0
    fi
    error "deployment $ns/$name is not ready within $ROLLOUT_TIMEOUT"
    return 1
}

# check_statefulset_ready NAMESPACE NAME
check_statefulset_ready() {
    local ns="$1" name="$2"
    if ! kubectl get statefulset "$name" -n "$ns" >/dev/null 2>&1; then
        error "statefulset $ns/$name does not exist"
        return 1
    fi
    if kubectl rollout status "statefulset/$name" -n "$ns" --timeout="$ROLLOUT_TIMEOUT" >/dev/null 2>&1; then
        ok "statefulset $ns/$name is ready"
        return 0
    fi
    error "statefulset $ns/$name is not ready within $ROLLOUT_TIMEOUT"
    return 1
}

# ---------------------------------------------------------------------------
# Objects
# ---------------------------------------------------------------------------

_check_object_exists() {
    local kind="$1" ns="$2" name="$3"
    if kubectl get "$kind" "$name" -n "$ns" >/dev/null 2>&1; then
        ok "$kind $ns/$name exists"
        return 0
    fi
    error "$kind $ns/$name does not exist"
    return 1
}

check_service_exists() { _check_object_exists service "$1" "$2"; }
check_configmap_exists() { _check_object_exists configmap "$1" "$2"; }
check_secret_exists() { _check_object_exists secret "$1" "$2"; }
check_ingress_exists() { _check_object_exists ingress "$1" "$2"; }
check_role_exists() { _check_object_exists role "$1" "$2"; }
check_rolebinding_exists() { _check_object_exists rolebinding "$1" "$2"; }

# check_namespace_exists NAME
check_namespace_exists() {
    local name="$1"
    if kubectl get namespace "$name" >/dev/null 2>&1; then
        ok "namespace $name exists"
        return 0
    fi
    error "namespace $name does not exist"
    return 1
}

# check_crd_exists NAME
check_crd_exists() {
    local name="$1"
    if kubectl get crd "$name" >/dev/null 2>&1; then
        ok "CRD $name is registered"
        return 0
    fi
    error "CRD $name is not registered"
    return 1
}

# check_pvc_bound NAMESPACE NAME
check_pvc_bound() {
    local ns="$1" name="$2" phase
    phase="$(kubectl get pvc "$name" -n "$ns" -o jsonpath='{.status.phase}' 2>/dev/null)"
    if [ "$phase" = "Bound" ]; then
        ok "pvc $ns/$name is Bound"
        return 0
    fi
    error "pvc $ns/$name is not Bound (phase: ${phase:-missing})"
    return 1
}

# check_ingress_has_address NAMESPACE NAME
check_ingress_has_address() {
    local ns="$1" name="$2" address
    if ! kubectl get ingress "$name" -n "$ns" >/dev/null 2>&1; then
        error "ingress $ns/$name does not exist"
        return 1
    fi
    address="$(kubectl get ingress "$name" -n "$ns" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
    if [ -n "$address" ]; then
        ok "ingress $ns/$name has address $address"
        return 0
    fi
    warn "ingress $ns/$name has no address yet, the controller may still be reconciling"
    return 2
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

# curl_resolve_args URL - prints curl --resolve options that send the request
# for the host of URL to INGRESS_ADDRESS (ports 80 and 443), so the checks work
# with placeholder hostnames that have no DNS record. Prints nothing when
# INGRESS_ADDRESS is empty.
curl_resolve_args() {
    local url="$1" host
    [ -n "${INGRESS_ADDRESS:-}" ] || return 0
    host="$(printf '%s' "$url" | sed -E 's#^[a-zA-Z]+://([^/:?]+).*#\1#')"
    printf -- '--resolve\n%s:80:%s\n--resolve\n%s:443:%s\n' "$host" "$INGRESS_ADDRESS" "$host" "$INGRESS_ADDRESS"
}

# check_url_status_code URL EXPECTED_CODES
# EXPECTED_CODES is a comma separated list, e.g. "200,403".
# Optional env: CHECK_USER, CHECK_PASSWORD, CHECK_URL_NO_REDIRECT=true, INGRESS_ADDRESS
check_url_status_code() {
    local url="$1" expected="${2:-200}" code
    local -a args=(-s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT")
    curl_insecure cluster && args+=(-k)

    [ "${CHECK_URL_NO_REDIRECT:-false}" = "true" ] || args+=(-L)
    if [ -n "${CHECK_USER:-}" ]; then
        args+=(-u "${CHECK_USER}:${CHECK_PASSWORD:-}")
    fi
    mapfile -t -O "${#args[@]}" args < <(curl_resolve_args "$url")

    # Retry: the Java services report ready before their HTTP stack answers.
    local attempt
    for attempt in $(seq 1 "$CHECK_URL_RETRIES"); do
        code="$(curl "${args[@]}" "$url" 2>/dev/null)"
        if printf '%s' ",$expected," | grep -q ",$code,"; then
            ok "$url returned HTTP $code (expected $expected)"
            return 0
        fi
        [ "$attempt" -lt "$CHECK_URL_RETRIES" ] && sleep "$CHECK_URL_RETRY_DELAY"
    done
    error "$url returned HTTP ${code:-no-response} (expected $expected)"
    return 1
}

# check_url_json_key URL JQ_PATH
# Confirms an endpoint answers with JSON containing a given key. Needs jq;
# skipped when jq is unavailable.
check_url_json_key() {
    local url="$1" path="$2"
    local -a args=(-s --max-time "$CURL_TIMEOUT" -H "Accept: application/json")
    curl_insecure cluster && args+=(-k)
    if ! command -v jq >/dev/null 2>&1; then
        skip "jq is not installed, cannot inspect the payload of $url"
        return 2
    fi
    mapfile -t -O "${#args[@]}" args < <(curl_resolve_args "$url")
    local attempt
    for attempt in $(seq 1 "$CHECK_URL_RETRIES"); do
        if curl "${args[@]}" "$url" 2>/dev/null | jq -e "$path" >/dev/null 2>&1; then
            ok "$url payload contains $path"
            return 0
        fi
        [ "$attempt" -lt "$CHECK_URL_RETRIES" ] && sleep "$CHECK_URL_RETRY_DELAY"
    done
    error "$url payload does not contain $path"
    return 1
}

# check_port_forward_endpoint NAMESPACE RESOURCE PORT PATH EXPECTED_CODES
# In-cluster check through a temporary port-forward, for endpoints that are
# not exposed by an ingress (actuator health, broker console, MinIO health).
# RESOURCE is any port-forward target, e.g. service/<name> or deployment/<name>.
check_port_forward_endpoint() {
    local ns="$1" target="$2" port="$3" path="$4" expected="${5:-200}"
    local local_port="${LOCAL_PORT:-18080}" pid code i

    kubectl port-forward -n "$ns" "$target" "$local_port:$port" >/dev/null 2>&1 &
    pid=$!
    for i in $(seq 1 15); do
        sleep 1
        # shellcheck disable=SC2086
        kill -0 $pid 2>/dev/null || break
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${local_port}${path}" 2>/dev/null)"
        [ -n "$code" ] && [ "$code" != "000" ] && break
    done
    kill "$pid" >/dev/null 2>&1 || true
    wait "$pid" 2>/dev/null || true

    if printf '%s' ",$expected," | grep -q ",${code:-000},"; then
        ok "$ns/$target:$port$path returned HTTP $code (expected $expected)"
        return 0
    fi
    error "$ns/$target:$port$path returned HTTP ${code:-no-response} (expected $expected)"
    return 1
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

# print_release_resources NAMESPACE RELEASE_NAME
print_release_resources() {
    local ns="$1" release="$2"
    section "Resources in namespace $ns"
    kubectl get deploy,sts,svc,ingress,pvc,job -n "$ns" 2>/dev/null || true
    section "Resources in namespace ${release}-workflows"
    kubectl get all,cm,secret -n "${release}-workflows" 2>/dev/null || true
    section "Pods not in a Running or Completed state"
    kubectl get pods -n "$ns" 2>/dev/null |
        awk 'NR==1 || ($3!="Running" && $3!="Completed")' || true
}
