#!/usr/bin/env bash
# Shared helpers for the EOEPCA+ processing deployment scripts.
#
# Provides: coloured output, the state file mechanism, interactive prompts with
# input validation, password generation and the check runner used by both
# check-prerequisites.sh and validation.sh.
#
# This file is meant to be sourced, not executed.

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
else
    C_RESET=""
    C_BOLD=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
fi

log() { printf '%s\n' "$*"; }
info() { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok() { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
error() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; }
skip() { printf '%s[SKIP]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }
die() {
    error "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# State file
#
# All answers collected by configure-oapip.sh are persisted so that later runs
# and the other scripts pick them up:
#
#   $HOME/.eoepca/state       (override with EOEPCA_STATE_FILE)
#
# It is the same file, with the same `export NAME="value"` line format, as the
# EOEPCA deployment guide scripts, so the shared variables (INGRESS_HOST,
# INGRESS_CLASS, HTTP_SCHEME, CLUSTER_ISSUER, PERSISTENT_STORAGECLASS,
# SHARED_STORAGECLASS, S3_*) are read and updated by both. Variables specific to
# this building block use their own names (OAPIP_HOSTNAME, ...) so they never
# clash with the guide's (OAPIP_HOST holds a URL there).
#
# The file is created with 0600 because it holds credentials.
# ---------------------------------------------------------------------------

STATE_DIR="${EOEPCA_STATE_DIR:-$HOME/.eoepca}"
STATE_FILE="${EOEPCA_STATE_FILE:-$STATE_DIR/state}"

create_state_file() {
    mkdir -p "$(dirname "$STATE_FILE")" || return 1
    chmod 700 "$(dirname "$STATE_FILE")" 2>/dev/null || true
    if [ ! -f "$STATE_FILE" ]; then
        : >"$STATE_FILE"
    fi
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

load_state() {
    create_state_file
    # shellcheck disable=SC1090
    set -a && . "$STATE_FILE" && set +a
}

# add_to_state_file KEY VALUE
# Exports the variable and stores it as `export KEY="VALUE"`, replacing any
# previous assignment (in this format or the plain `KEY=` one).
add_to_state_file() {
    local key="$1" value="$2" escaped tmp
    create_state_file
    export "$key=$value"
    # Escape the characters that are special inside double quotes.
    escaped="${value//\\/\\\\}"
    escaped="${escaped//\"/\\\"}"
    escaped="${escaped//\$/\\\$}"
    escaped="${escaped//\`/\\\`}"
    tmp="$(mktemp "${TMPDIR:-/tmp}/eoepca-state.XXXXXX")" || return 1
    grep -vE "^(export )?${key}=" "$STATE_FILE" >"$tmp" 2>/dev/null || true
    printf 'export %s="%s"\n' "$key" "$escaped" >>"$tmp"
    cat "$tmp" >"$STATE_FILE"
    rm -f "$tmp"
    chmod 600 "$STATE_FILE" 2>/dev/null || true
}

print_state() {
    create_state_file
    sed -E "s/^(export )?([A-Z_]*(PASSWORD|SECRET|SECRET_KEY|ACCESS_KEY|TOKEN)[A-Z_]*)=.*/\1\2=\"***\"/" "$STATE_FILE"
}

# yaml_quote VALUE - VALUE as a YAML single-quoted scalar (safe for any password)
yaml_quote() {
    local v="$1"
    printf "'%s'" "${v//\'/\'\'}"
}

# ---------------------------------------------------------------------------
# Input validators - each returns 0 when the single argument is acceptable
# ---------------------------------------------------------------------------

is_non_empty() { [ -n "$1" ]; }
is_boolean() { [ "$1" = "true" ] || [ "$1" = "false" ]; }
is_positive_int() { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
is_storage_size() { [[ "$1" =~ ^[1-9][0-9]*(Mi|Gi|Ti)$ ]]; }
is_valid_domain() { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?(\.[a-zA-Z]{2,})$ ]]; }
is_valid_hostname() { [[ "$1" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] && [ ${#1} -le 253 ]; }
is_k8s_name() { [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && [ ${#1} -le 63 ]; }
is_url() { [[ "$1" =~ ^https?://[^[:space:]]+$ ]]; }
is_tls_mode() { [ "$1" = "cert-manager" ] || [ "$1" = "none" ]; }
is_argo_auth_mode() { [ "$1" = "server" ] || [ "$1" = "client" ]; }
is_argo_role() { [ "$1" = "view" ] || [ "$1" = "edit" ] || [ "$1" = "admin" ]; }
is_k8s_dbname() { [[ "$1" =~ ^[a-z_][a-z0-9_]*$ ]] && [ ${#1} -le 63 ]; }
is_simple_token() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
is_min8_chars() { [ ${#1} -ge 8 ]; }
is_any() { return 0; }

# ---------------------------------------------------------------------------
# Prompting
#
#   ask VAR "question" [default] [validator]
#   ask_secret VAR "question" [default] [validator]
#
# Behaviour:
#   * a variable already set (state file or environment) is kept when it passes
#     the validator, unless EOEPCA_RECONFIGURE=true; an invalid stored value
#     (e.g. written by another building block) is asked again
#   * EOEPCA_NONINTERACTIVE=true never prompts: it takes the default, or fails
#     when there is none and the validator rejects an empty value (used for CI)
# ---------------------------------------------------------------------------

_ask_impl() {
    local var="$1" message="$2" default="${3:-}" validator="${4:-is_non_empty}" hidden="${5:-false}"
    local current="${!var:-}" input=""

    if [ -n "${!var+x}" ] && [ "${EOEPCA_RECONFIGURE:-false}" != "true" ]; then
        if "$validator" "$current"; then
            if [ "$hidden" = "true" ]; then
                ok "$var already set (value hidden)"
            else
                ok "$var already set: ${current:-<empty>}"
            fi
            add_to_state_file "$var" "$current"
            return 0
        fi
        warn "stored value of $var is not valid here, asking again"
    fi

    if [ "${EOEPCA_NONINTERACTIVE:-false}" = "true" ]; then
        "$validator" "$default" || die "$var is not set and its default is missing or invalid (non-interactive mode)"
        add_to_state_file "$var" "$default"
        ok "$var=$( [ "$hidden" = "true" ] && echo '***' || echo "$default") (default)"
        return 0
    fi

    while true; do
        if [ -n "$default" ] && [ "$hidden" != "true" ]; then
            printf '%s [%s]: ' "$message" "$default"
        else
            printf '%s: ' "$message"
        fi

        if [ "$hidden" = "true" ]; then
            read -rs input
            printf '\n'
        else
            read -r input
        fi

        [ -z "$input" ] && input="$default"

        if "$validator" "$input"; then
            add_to_state_file "$var" "$input"
            return 0
        fi
        warn "invalid value for $var, try again"
    done
}

ask() { _ask_impl "$1" "$2" "${3:-}" "${4:-is_non_empty}" "false"; }
ask_secret() { _ask_impl "$1" "$2" "${3:-}" "${4:-is_non_empty}" "true"; }

# ask_or_generate VAR "question" [length] [validator]
# Prompts for a secret; an empty answer generates one (alphanumeric, which
# satisfies every validator used by the scripts).
ask_or_generate() {
    local var="$1" message="$2" length="${3:-24}" validator="${4:-is_non_empty}"
    local current="${!var:-}" input=""

    if [ -n "$current" ] && [ "${EOEPCA_RECONFIGURE:-false}" != "true" ]; then
        if "$validator" "$current"; then
            ok "$var already set (value hidden)"
            add_to_state_file "$var" "$current"
            return 0
        fi
        warn "stored value of $var is not valid here, asking again"
    fi

    if [ "${EOEPCA_NONINTERACTIVE:-false}" = "true" ]; then
        add_to_state_file "$var" "$(generate_password "$length")"
        ok "$var generated"
        return 0
    fi

    while true; do
        printf '%s [empty = generate]: ' "$message"
        read -rs input
        printf '\n'
        if [ -z "$input" ]; then
            input="$(generate_password "$length")"
            ok "$var generated"
        fi
        "$validator" "$input" && break
        warn "invalid value for $var, try again"
    done
    add_to_state_file "$var" "$input"
}

# generate_password [length]
generate_password() {
    local length="${1:-24}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 $((length * 2)) | tr -dc 'A-Za-z0-9' | head -c "$length"
    else
        tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$length"
    fi
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

# curl_insecure [cluster] - succeeds when curl must skip server certificate
# verification (-k). CURL_INSECURE=true|false decides explicitly. When it is
# unset, verification is skipped only for the ingress of the cluster (argument
# "cluster") with TLS_MODE=cert-manager and the default self-signed issuer,
# whose CA the client does not trust.
curl_insecure() {
    case "${CURL_INSECURE:-}" in
    true) return 0 ;;
    false) return 1 ;;
    esac
    [ "${1:-}" = "cluster" ] &&
        [ "${TLS_MODE:-cert-manager}" = "cert-manager" ] &&
        [ "${CLUSTER_ISSUER:-selfsigned-ca-issuer}" = "selfsigned-ca-issuer" ]
}

# warn_if_curl_insecure SCHEME - one warning per run when cluster certificates are not verified
warn_if_curl_insecure() {
    if [ "$1" = "https" ] && curl_insecure cluster; then
        warn "server certificates are not verified (self-signed issuer or CURL_INSECURE=true); set CURL_INSECURE=false to verify them"
    fi
}

# ---------------------------------------------------------------------------
# Check runner
#
# Takes an array of command strings, runs each one, tallies the result and
# returns non-zero when at least one check failed. A check must return:
#   0 = pass, 1 = fail, 2 = skipped / inconclusive (counted, never fatal)
# ---------------------------------------------------------------------------

CHECKS_PASSED=0
CHECKS_FAILED=0
CHECKS_SKIPPED=0
FAILED_CHECKS=()

run_checks() {
    local check rc errexit=false
    CHECKS_PASSED=0
    CHECKS_FAILED=0
    CHECKS_SKIPPED=0
    FAILED_CHECKS=()

    # Checks may fail by design: suspend errexit while they run and restore the
    # caller's setting afterwards instead of forcing it on.
    case $- in *e*) errexit=true ;; esac
    set +e
    for check in "$@"; do
        eval "$check"
        rc=$?
        case "$rc" in
        0) CHECKS_PASSED=$((CHECKS_PASSED + 1)) ;;
        2) CHECKS_SKIPPED=$((CHECKS_SKIPPED + 1)) ;;
        *)
            CHECKS_FAILED=$((CHECKS_FAILED + 1))
            FAILED_CHECKS+=("$check")
            ;;
        esac
    done
    [ "$errexit" = "true" ] && set -e

    [ "${RUN_CHECKS_QUIET:-false}" = "true" ] || print_check_summary
    [ "$CHECKS_FAILED" -eq 0 ]
}

print_check_summary() {
    section "Summary"
    log "passed:  $CHECKS_PASSED"
    log "failed:  $CHECKS_FAILED"
    log "skipped: $CHECKS_SKIPPED"
    if [ "$CHECKS_FAILED" -gt 0 ]; then
        log ""
        error "failed checks:"
        local c
        for c in "${FAILED_CHECKS[@]}"; do
            log "  - $c"
        done
    fi
}
