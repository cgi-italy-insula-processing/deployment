#!/usr/bin/env bash
# Thin wrapper around helm upgrade --install for the eoepca umbrella chart.
#
# It keeps two things consistent: the release name and namespace come from the
# state file, and `helm dependency update` is never called (the chart vendors
# its subcharts under charts/ and its dependencies declare no repository).
#
# Usage:
#   ./deploy.sh --chart PATH [options]
#
# Options:
#       --chart PATH      path to the helm-chart checkout (or CHART_PATH env)
#   -f, --values PATH     values file (default: ../generated/values.yaml)
#       --dry-run         render and validate without applying
#       --atomic          roll back automatically when the release fails
#       --timeout VALUE   helm timeout (default: 15m)
#   -h, --help            this message

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=common/utils.sh
. "$SCRIPT_DIR/common/utils.sh"

VALUES_PATH="$REPO_DIR/generated/values.yaml"
CHART_PATH="${CHART_PATH:-}"
HELM_TIMEOUT="15m"
EXTRA_ARGS=()

usage() {
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"
    exit "${1:-0}"
}

load_state

while [ $# -gt 0 ]; do
    case "$1" in
    --chart)
        CHART_PATH="$2"
        shift 2
        ;;
    -f | --values)
        VALUES_PATH="$2"
        shift 2
        ;;
    --dry-run)
        EXTRA_ARGS+=(--dry-run)
        shift
        ;;
    --atomic)
        EXTRA_ARGS+=(--atomic)
        shift
        ;;
    --timeout)
        HELM_TIMEOUT="$2"
        shift 2
        ;;
    -h | --help) usage 0 ;;
    *)
        error "unknown option: $1"
        usage 1
        ;;
    esac
done

require_cmd helm
[ -n "$CHART_PATH" ] || die "chart path not given, use --chart or set CHART_PATH"
[ -f "$CHART_PATH/Chart.yaml" ] || die "no Chart.yaml found in $CHART_PATH"
[ -f "$VALUES_PATH" ] || die "values file not found: $VALUES_PATH (run configure-oapip.sh first)"

REL="${RELEASE_NAME:-eoepca}"
NS="${NAMESPACE:-eoepca}"

section "Deploying release '$REL' to namespace '$NS'"
log "chart:  $CHART_PATH"
log "values: $VALUES_PATH"

helm upgrade --install "$REL" "$CHART_PATH" \
    --namespace "$NS" --create-namespace \
    --values "$VALUES_PATH" \
    --timeout "$HELM_TIMEOUT" \
    "${EXTRA_ARGS[@]}" || die "helm failed"

ok "helm completed, now run ./validation.sh"
