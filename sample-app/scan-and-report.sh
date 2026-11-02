#!/usr/bin/env bash
# Local SAST + SCA + DAST pipeline for sample-app, reporting straight into the
# already-running local DefectDojo instance.
#
#   1. SAST   -> Semgrep (official Docker image) over the app source
#   2. SCA    -> Anchore Grype (official Docker image) over the built app
#                container image - OS packages + Python deps, with EPSS
#                scores and CISA KEV matches included in its report
#   3. DAST   -> OWASP ZAP baseline scan (official Docker image) against the
#                app running in a container
#   4. Report -> all three results imported into DefectDojo via its REST API,
#                under a dedicated Product and a fresh Engagement per run.
#   5. Triage -> enrich-epss-kev.py refreshes EPSS/KEV on every CVE-bearing
#                finding of the product and tags it priority-p0..p3.
#
# Requires: Docker, python3, and sample-app/.env with DD_URL/DD_USERNAME/
# DD_PASSWORD for a DefectDojo instance that is already up (see ../deployment).
#
# Optional: BASE_IMAGE=python:3.11.5-slim-bookworm ./scan-and-report.sh
# builds the app on a stale base image, to demo what KEV/EPSS triage does
# with a real backlog of hundreds of CVEs (see README).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [[ ! -f .env ]]; then
  echo "Missing sample-app/.env - copy .env.example and fill in DD_PASSWORD." >&2
  exit 1
fi
set -a
source .env
set +a

NETWORK="dd-poc-net"
APP_IMAGE="sample-app:poc"
APP_CONTAINER="sample-app-scan-target"
APP_PORT=5000
SEMGREP_REPORT="$SCRIPT_DIR/semgrep-report.json"
ZAP_REPORT="$SCRIPT_DIR/zap-report.xml"
GRYPE_REPORT="$SCRIPT_DIR/grype-report.json"
BASE_IMAGE="${BASE_IMAGE:-python:3.12-slim}"
PRODUCT_NAME="Sample Flask App"
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"

step() { printf '\n==> %s\n' "$1"; }
fail() { echo "FAILED: $1" >&2; exit 1; }

# --- 1. SAST: Semgrep -------------------------------------------------------
step "Running Semgrep (SAST) against sample-app source"
rm -f "$SEMGREP_REPORT"
docker run --rm -v "$SCRIPT_DIR:/src" semgrep/semgrep \
  semgrep scan --config=auto --json --output=/src/semgrep-report.json /src/app.py

[[ -s "$SEMGREP_REPORT" ]] || fail "semgrep-report.json was not produced"
python3 -c "import json; d=json.load(open('$SEMGREP_REPORT')); assert 'results' in d" \
  || fail "semgrep-report.json is not valid / missing 'results'"
SEMGREP_COUNT=$(python3 -c "import json; print(len(json.load(open('$SEMGREP_REPORT'))['results']))")
echo "Checkpoint OK: semgrep-report.json valid JSON, $SEMGREP_COUNT result(s)"

# --- 2. Build the image + SCA: Grype -----------------------------------------
step "Building sample-app image (base: $BASE_IMAGE)"
docker build --build-arg "BASE_IMAGE=$BASE_IMAGE" -t "$APP_IMAGE" "$SCRIPT_DIR" >/dev/null \
  || fail "docker build failed"
echo "Checkpoint OK: built $APP_IMAGE"

step "Running Grype (SCA) against the sample-app container image"
rm -f "$GRYPE_REPORT"
# Grype reads the image straight from the local Docker engine via its socket.
# Its JSON output carries an `epss` and a `knownExploited` (CISA KEV) block per
# match, which DefectDojo's "Anchore Grype" parser maps onto the finding.
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock anchore/grype:latest \
  "$APP_IMAGE" -o json -q > "$GRYPE_REPORT" \
  || fail "grype scan failed"
python3 -c "import json; d=json.load(open('$GRYPE_REPORT')); assert 'matches' in d" \
  || fail "grype-report.json is not valid / missing 'matches'"
read -r GRYPE_COUNT GRYPE_KEV < <(python3 -c "
import json; m=json.load(open('$GRYPE_REPORT'))['matches']
print(len(m), sum(1 for x in m if x['vulnerability'].get('knownExploited')))")
echo "Checkpoint OK: grype-report.json valid JSON, $GRYPE_COUNT match(es), $GRYPE_KEV in CISA KEV"

# --- 3. Boot the scan target -------------------------------------------------
step "Starting sample-app container"
docker rm -f "$APP_CONTAINER" >/dev/null 2>&1 || true
docker network inspect "$NETWORK" >/dev/null 2>&1 || docker network create "$NETWORK" >/dev/null
docker run -d --name "$APP_CONTAINER" --network "$NETWORK" -p "$APP_PORT:5000" "$APP_IMAGE" >/dev/null

echo "Waiting for sample-app to respond on :$APP_PORT/health ..."
for i in $(seq 1 20); do
  if curl -sf "http://localhost:$APP_PORT/health" >/dev/null 2>&1; then
    echo "Checkpoint OK: sample-app healthy after ${i}s"
    break
  fi
  sleep 1
  [[ $i -eq 20 ]] && { docker logs "$APP_CONTAINER"; fail "sample-app never became healthy"; }
done

# --- 4. DAST: OWASP ZAP baseline ---------------------------------------------
step "Running OWASP ZAP baseline scan (DAST) against sample-app"
rm -f "$ZAP_REPORT"
docker run --rm --network "$NETWORK" -v "$SCRIPT_DIR:/zap/wrk/:rw" \
  zaproxy/zap-stable zap-baseline.py \
  -t "http://${APP_CONTAINER}:5000" -x zap-report.xml -I
# zap-baseline.py exits non-zero when it finds WARN/FAIL alerts - that's
# expected and not a pipeline error, so its exit code is deliberately ignored.
# The real success signal is the report file itself:
[[ -s "$ZAP_REPORT" ]] || fail "zap-report.xml was not produced"
python3 -c "import xml.etree.ElementTree as ET; ET.parse('$ZAP_REPORT')" \
  || fail "zap-report.xml is not well-formed XML"
echo "Checkpoint OK: zap-report.xml well-formed"

step "Stopping sample-app container"
docker rm -f "$APP_CONTAINER" >/dev/null

# --- 5. Report into DefectDojo -----------------------------------------------
step "Authenticating to DefectDojo at $DD_URL"
TOKEN=$(curl -sf -X POST "$DD_URL/api/v2/api-token-auth/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"$DD_USERNAME\",\"password\":\"$DD_PASSWORD\"}" | python3 -c "import json,sys; print(json.load(sys.stdin)['token'])") \
  || fail "could not authenticate to DefectDojo (check DD_URL/DD_USERNAME/DD_PASSWORD in .env)"
echo "Checkpoint OK: got API token"

step "Looking up / creating product '$PRODUCT_NAME'"
PRODUCT_ID=$(curl -sf "$DD_URL/api/v2/products/?name=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$PRODUCT_NAME")" \
  -H "Authorization: Token $TOKEN" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['results'][0]['id'] if d['count'] else '')
")
if [[ -z "$PRODUCT_ID" ]]; then
  PRODUCT_ID=$(curl -sf -X POST "$DD_URL/api/v2/products/" \
    -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" \
    -d "{\"name\":\"$PRODUCT_NAME\",\"description\":\"Minimal Flask app used as a local SAST/DAST pipeline target.\",\"prod_type\":1}" \
    | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])") \
    || fail "could not create product"
  echo "Checkpoint OK: created product id=$PRODUCT_ID"
else
  echo "Checkpoint OK: reusing existing product id=$PRODUCT_ID"
fi

step "Creating engagement for this run"
ENGAGEMENT_NAME="Automated Scan - $RUN_TS"
ENGAGEMENT_ID=$(curl -sf -X POST "$DD_URL/api/v2/engagements/" \
  -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" \
  -d "{\"name\":\"$ENGAGEMENT_NAME\",\"product\":$PRODUCT_ID,\"target_start\":\"$(date -u +%Y-%m-%d)\",\"target_end\":\"$(date -u +%Y-%m-%d)\",\"status\":\"In Progress\",\"engagement_type\":\"CI/CD\",\"description\":\"Semgrep + Grype + ZAP. Image base: $BASE_IMAGE\"}" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])") \
  || fail "could not create engagement"
echo "Checkpoint OK: created engagement id=$ENGAGEMENT_ID ('$ENGAGEMENT_NAME')"

step "Importing Semgrep (SAST) results"
SEMGREP_IMPORT=$(curl -sf -X POST "$DD_URL/api/v2/import-scan/" \
  -H "Authorization: Token $TOKEN" \
  -F "engagement=$ENGAGEMENT_ID" \
  -F "scan_type=Semgrep JSON Report" \
  -F "file=@$SEMGREP_REPORT" \
  -F "active=true" -F "verified=true" -F "minimum_severity=Info") \
  || fail "Semgrep import failed"
SEMGREP_IMPORTED=$(echo "$SEMGREP_IMPORT" | python3 -c "import json,sys; print(json.load(sys.stdin)['statistics']['after']['total']['total'])")
echo "Checkpoint OK: Semgrep import -> $SEMGREP_IMPORTED finding(s) in DefectDojo"

step "Importing ZAP (DAST) results"
ZAP_IMPORT=$(curl -sf -X POST "$DD_URL/api/v2/import-scan/" \
  -H "Authorization: Token $TOKEN" \
  -F "engagement=$ENGAGEMENT_ID" \
  -F "scan_type=ZAP Scan" \
  -F "file=@$ZAP_REPORT" \
  -F "active=true" -F "verified=true" -F "minimum_severity=Info") \
  || fail "ZAP import failed"
ZAP_IMPORTED=$(echo "$ZAP_IMPORT" | python3 -c "import json,sys; print(json.load(sys.stdin)['statistics']['after']['total']['total'])")
echo "Checkpoint OK: ZAP import -> $ZAP_IMPORTED finding(s) in DefectDojo"

step "Importing Grype (SCA) results"
GRYPE_IMPORT=$(curl -sf -X POST "$DD_URL/api/v2/import-scan/" \
  -H "Authorization: Token $TOKEN" \
  -F "engagement=$ENGAGEMENT_ID" \
  -F "scan_type=Anchore Grype" \
  -F "file=@$GRYPE_REPORT" \
  -F "active=true" -F "verified=true" -F "minimum_severity=Info") \
  || fail "Grype import failed"
GRYPE_IMPORTED=$(echo "$GRYPE_IMPORT" | python3 -c "import json,sys; print(json.load(sys.stdin)['statistics']['after']['total']['total'])")
echo "Checkpoint OK: Grype import -> $GRYPE_IMPORTED finding(s) in DefectDojo"

# --- 6. Triage: EPSS + CISA KEV enrichment ------------------------------------
step "Enriching product findings with EPSS + CISA KEV and tagging triage tiers"
python3 "$SCRIPT_DIR/enrich-epss-kev.py" --product-id "$PRODUCT_ID" \
  || fail "EPSS/KEV enrichment failed"

step "Done"
echo "Engagement: $DD_URL/engagement/$ENGAGEMENT_ID"
echo "Semgrep findings imported: $SEMGREP_IMPORTED"
echo "Grype findings imported:   $GRYPE_IMPORTED"
echo "ZAP findings imported:     $ZAP_IMPORTED"
echo "Fix-now queue (CISA KEV):  $DD_URL/finding/open?tags=priority-p0"
