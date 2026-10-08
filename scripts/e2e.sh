#!/usr/bin/env bash
# End-to-end test of a deployed EOEPCA+ processing building block.
#
# Deploys an OGC Application Package (CWL) through the OGC API, executes it on a
# STAC input, waits for the job to finish, then downloads the job output through
# the server Ingress and compares it with the input file.
#
# The processor is fastcopier-stac, which copies the selected assets of every
# item of its input STAC catalog into its output STAC catalog. The test serves,
# from a temporary in-cluster web server (ConfigMap + Pod + Service in the
# release namespace), the application package, a one-item STAC FeatureCollection
# and the item asset: a text file holding a message unique to the run. The job
# therefore exercises the whole chain: STAC input handling in the server, stage-in
# of the item and its asset by the input-downloader, the processor, stage-out by
# the output-uploader, and the download of the output file.
#
# The cluster must be able to pull the processor image and busybox (web server).
#
# Usage:
#   ./e2e.sh [options]
#
# Options:
#   -r, --release NAME          helm release name (default: eoepca)
#   -n, --namespace NAME        release namespace (default: eoepca)
#       --ingress-address IP    send the requests to this ingress address instead
#                               of resolving the hostname through DNS
#       --timeout SECONDS       maximum wait for the job (default: 600)
#       --keep                  keep the test process and the web server
#   -h, --help                  this message
#
# Environment:
#   E2E_PROCESSOR_IMAGE   processor image (default: the public fastcopier-stac 0.1)
#   E2E_WEB_IMAGE         web server image (default: busybox:1.37.0)
#   CURL_INSECURE         true/false: skip/verify server certificates (default: skip
#                         only with TLS_MODE=cert-manager and selfsigned-ca-issuer)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common/utils.sh
. "$SCRIPT_DIR/common/utils.sh"
# shellcheck source=common/validation-utils.sh
. "$SCRIPT_DIR/common/validation-utils.sh"

JOB_TIMEOUT=600
KEEP=false
PROCESSOR_IMAGE="${E2E_PROCESSOR_IMAGE:-ghcr.io/cgi-italy-insula-processing/com.cgi.eoss.platform/fastcopier-stac:0.1}"
WEB_IMAGE="${E2E_WEB_IMAGE:-busybox:1.37.0}"

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
    --timeout)
        JOB_TIMEOUT="$2"
        shift 2
        ;;
    --keep)
        KEEP=true
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
SCHEME="${HTTP_SCHEME:-https}"
export INGRESS_ADDRESS="${INGRESS_ADDRESS:-}"
[ -n "${OAPIP_HOSTNAME:-}" ] || die "OAPIP_HOSTNAME is not set (run configure-oapip.sh first)"
BASE="$SCHEME://$OAPIP_HOSTNAME"
warn_if_curl_insecure "$SCHEME"

require_cmd kubectl
require_cmd curl

RUN_ID="$(date +%s)"
PROCESS_ID="e2e-fastcopier-$RUN_ID"
ITEM_ID="e2e-item-$RUN_ID"
MESSAGE="EOEPCA+ processing e2e test $RUN_ID"
# Unique per run: the previous run's resources may still be terminating.
WEB_NAME="${REL}-e2e-web-${RUN_ID}"
WEB_URL="http://${WEB_NAME}.${NS}.svc.cluster.local"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/eoepca-e2e.XXXXXX")"
PROCESS_NUM=""

# http METHOD URL [curl args...] - prints the body, then the status code on the last line
http() {
    local method="$1" url="$2"
    shift 2
    local -a args=(-s -X "$method" -w '\n%{http_code}' --max-time "${CURL_TIMEOUT:-20}")
    curl_insecure cluster && args+=(-k)
    mapfile -t -O "${#args[@]}" args < <(curl_resolve_args "$url")
    curl "${args[@]}" "$@" "$url"
}

body_of() { sed '$d' <<<"$1"; }
code_of() { tail -n1 <<<"$1"; }

cleanup() {
    if [ "$KEEP" = "true" ]; then
        info "--keep: leaving process ${PROCESS_NUM:-?} and the $WEB_NAME web server in place"
    else
        if [ -n "$PROCESS_NUM" ]; then
            http DELETE "$BASE/ogcapi/processes/$PROCESS_NUM" >/dev/null 2>&1 || true
        fi
        kubectl -n "$NS" delete pod,service,configmap -l "app.kubernetes.io/instance=${WEB_NAME}" \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

section "End-to-end test of release '$REL' in namespace '$NS'"
log "OGC API:   $BASE/ogcapi"
log "processor: $PROCESSOR_IMAGE"
[ -n "$INGRESS_ADDRESS" ] && info "requests are sent to the ingress address $INGRESS_ADDRESS"

# ---------------------------------------------------------------------------
# 1. Application package, STAC input and asset, served in-cluster
# ---------------------------------------------------------------------------

section "Serving the application package and the STAC input"
cat >"$WORK_DIR/app.cwl" <<EOF
cwlVersion: v1.2
\$graph:
- class: Workflow
  id: $PROCESS_ID
  label: EOEPCA+ processing e2e test
  doc: Copies the data asset of every item of the input STAC catalog into the output catalog
  inputs:
    input:
      label: Input catalogue
      doc: STAC catalogue of the products to copy
      type: Directory
  outputs:
    output:
      type: Directory
      outputSource: process/output
  steps:
    process:
      run: '#main'
      in:
        input: input
      out:
        - output
- class: CommandLineTool
  id: main
  requirements:
    DockerRequirement:
      dockerPull: $PROCESSOR_IMAGE
  baseCommand:
    - fastcopier-stac
    - --stac-asset-names
    - data
    - --output-stac-catalog-dir
    - ./outDir/output
  inputs:
    input:
      label: Input catalogue
      doc: STAC catalogue of the products to copy
      type: Directory
      inputBinding:
        position: 1
        prefix: --input-stac-catalog
  outputs:
    output:
      type: Directory
      outputBinding:
        glob: ./outDir/output/
EOF

cat >"$WORK_DIR/input.json" <<EOF
{"type":"FeatureCollection","features":[{"type":"Feature","stac_version":"1.0.0","id":"$ITEM_ID",
"bbox":[12.4,41.8,12.6,42.0],
"geometry":{"type":"Polygon","coordinates":[[[12.4,41.8],[12.6,41.8],[12.6,42.0],[12.4,42.0],[12.4,41.8]]]},
"properties":{"datetime":"2026-01-01T00:00:00Z"},"links":[],
"assets":{"data":{"href":"$WEB_URL/message.txt","type":"text/plain","roles":["data"]}}}]}
EOF
printf '%s' "$MESSAGE" >"$WORK_DIR/message.txt"

kubectl -n "$NS" create configmap "$WEB_NAME" --from-file="$WORK_DIR/app.cwl" \
    --from-file="$WORK_DIR/input.json" --from-file="$WORK_DIR/message.txt" \
    --dry-run=client -o yaml |
    kubectl -n "$NS" label --local -f - "app.kubernetes.io/name=${REL}-e2e-web" "app.kubernetes.io/instance=${WEB_NAME}" -o yaml |
    kubectl -n "$NS" apply -f - >/dev/null || die "could not create the ConfigMap $WEB_NAME"
kubectl -n "$NS" apply -f - >/dev/null <<EOF || die "could not create the web server"
apiVersion: v1
kind: Pod
metadata:
  name: $WEB_NAME
  labels:
    app.kubernetes.io/name: ${REL}-e2e-web
    app.kubernetes.io/instance: $WEB_NAME
spec:
  containers:
    - name: httpd
      image: $WEB_IMAGE
      command: ["httpd", "-f", "-p", "8080", "-h", "/www"]
      ports:
        - containerPort: 8080
      volumeMounts:
        - name: files
          mountPath: /www
  volumes:
    - name: files
      configMap:
        name: $WEB_NAME
---
apiVersion: v1
kind: Service
metadata:
  name: $WEB_NAME
  labels:
    app.kubernetes.io/name: ${REL}-e2e-web
    app.kubernetes.io/instance: $WEB_NAME
spec:
  selector:
    app.kubernetes.io/instance: $WEB_NAME
  ports:
    - port: 80
      targetPort: 8080
EOF
kubectl -n "$NS" wait --for=condition=Ready "pod/$WEB_NAME" --timeout=120s >/dev/null ||
    die "the web server pod did not become ready"
# The Service routes traffic only once its EndpointSlice lists the ready pod.
for i in $(seq 1 30); do
    kubectl -n "$NS" get endpointslices -l "kubernetes.io/service-name=$WEB_NAME" \
        -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[0]}' 2>/dev/null | grep -q . && break
    sleep 2
done
ok "application package: $WEB_URL/app.cwl"
ok "STAC input:          $WEB_URL/input.json (item $ITEM_ID, asset data -> message.txt)"

# ---------------------------------------------------------------------------
# 2. Deploy
# ---------------------------------------------------------------------------

section "Deploying the process"
# A 5xx means the server could not fetch the CWL yet and created nothing, so the
# deploy is retried a few times; the process id is unique to this run.
for attempt in 1 2 3 4 5; do
    resp="$(http POST "$BASE/ogcapi/processes" -H 'Content-Type: application/ogcapppkg+json' \
        --data "{\"executionUnit\":{\"href\":\"$WEB_URL/app.cwl\"}}")"
    case "$(code_of "$resp")" in
    5*) [ "$attempt" -lt 5 ] && { warn "deploy returned HTTP $(code_of "$resp"), retrying"; sleep 5; } ;;
    *) break ;;
    esac
done
[ "$(code_of "$resp")" = "201" ] || die "deploy returned HTTP $(code_of "$resp"): $(body_of "$resp" | head -c 400)"
# The processes are addressed by their numeric id, taken from the self link.
PROCESS_NUM="$(body_of "$resp" | grep -o 'ogcapi/processes/[0-9]*' | head -n1 | grep -o '[0-9]*$')"
[ -n "$PROCESS_NUM" ] || die "could not read the process id from the deploy response"
ok "process $PROCESS_ID deployed as /ogcapi/processes/$PROCESS_NUM"

# ---------------------------------------------------------------------------
# 3. Execute and wait
# ---------------------------------------------------------------------------

section "Executing the process"
resp="$(http POST "$BASE/ogcapi/processes/$PROCESS_NUM/execution" -H 'Content-Type: application/json' \
    -H 'Prefer: respond-async' --data "{\"inputs\":{\"input\":\"$WEB_URL/input.json\"}}")"
[ "$(code_of "$resp")" = "201" ] || die "execute returned HTTP $(code_of "$resp"): $(body_of "$resp" | head -c 400)"
JOB_ID="$(body_of "$resp" | grep -o '"id":"[0-9]*"' | head -n1 | grep -o '[0-9]\+')"
[ -n "$JOB_ID" ] || die "could not read the job id from the execute response"
ok "job $JOB_ID accepted"

status="" waited=0
while [ "$waited" -lt "$JOB_TIMEOUT" ]; do
    resp="$(http GET "$BASE/ogcapi/jobs/$JOB_ID" -H 'Accept: application/json')"
    status="$(body_of "$resp" | grep -o '"status":"[a-z]*"' | head -n1 | cut -d'"' -f4)"
    case "$status" in
    successful | failed | dismissed) break ;;
    esac
    sleep 10
    waited=$((waited + 10))
done
[ "$status" = "successful" ] || die "job $JOB_ID ended with status '${status:-unknown}' after ${waited}s (see kubectl -n ${REL}-workflows get workflows)"
ok "job $JOB_ID successful after about ${waited}s"

# ---------------------------------------------------------------------------
# 4. Results and download through the server Ingress
# ---------------------------------------------------------------------------

section "Checking the job output"
resp="$(http GET "$BASE/ogcapi/jobs/$JOB_ID/results/output" -H 'Accept: application/json')"
[ "$(code_of "$resp")" = "200" ] || die "results returned HTTP $(code_of "$resp")"
body="$(body_of "$resp")"
# The results list one download link per output file: the copied item and its asset.
item_link="$(grep -o "\"href\":\"[^\"]*filename=${ITEM_ID}\.json\"" <<<"$body" | head -n1 | cut -d'"' -f4)"
asset="$(grep -o '"href":"[^"]*filename=message\.txt"' <<<"$body" | head -n1 | cut -d'"' -f4)"
[ -n "$item_link" ] || die "the job output has no copy of the STAC item $ITEM_ID: $(head -c 400 <<<"$body")"
[ -n "$asset" ] || die "the job output has no copy of the asset message.txt: $(head -c 400 <<<"$body")"

resp="$(http GET "$item_link")"
[ "$(code_of "$resp")" = "200" ] || die "item download returned HTTP $(code_of "$resp")"
grep -q 'message\.txt' <<<"$(body_of "$resp")" ||
    die "the copied STAC item does not reference the copied asset"
ok "output STAC item $ITEM_ID.json references its copied data asset"

resp="$(http GET "$asset")"
[ "$(code_of "$resp")" = "200" ] || die "download returned HTTP $(code_of "$resp")"
if [ "$(body_of "$resp")" = "$MESSAGE" ]; then
    ok "downloaded output file is a copy of the input asset: \"$MESSAGE\""
else
    die "downloaded output does not match the input asset"
fi

log ""
ok "end-to-end test passed"
