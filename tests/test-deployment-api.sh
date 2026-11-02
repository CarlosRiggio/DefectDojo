#!/usr/bin/env bash
# `cond && pass ... || fail ...` is intentional: pass() only prints and cannot fail.
# shellcheck disable=SC2015
# Smoke test of a running DefectDojo instance: replays the REST API walkthrough
# from docs/02-deployment.md (auth -> product -> engagement -> import ->
# verify -> reimport/dedup) against a throwaway product, then deletes it, so
# running it leaves no trace in the instance.
#
# Usage: make test-smoke   (or: tests/test-deployment-api.sh)

set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SAMPLE="$REPO_ROOT/deployment/samples/generic-findings-sample.json"
PRODUCT_NAME="Smoke Test $(date -u +%Y%m%dT%H%M%SZ)"
TODAY="$(date -u +%Y-%m-%d)"
PRODUCT_ID=""

cleanup() {
  if [[ -n "$PRODUCT_ID" ]]; then
    dd_delete "/api/v2/products/$PRODUCT_ID/" && echo "  (cleaned up throwaway product id=$PRODUCT_ID)"
  fi
}
trap cleanup EXIT

section "DefectDojo API smoke test against $DD_URL"

code=$(curl -s -o /dev/null -w '%{http_code}' "$DD_URL/login")
[[ "$code" == "200" ]] && pass "UI answers on /login (HTTP 200)" || fail "UI on /login returned HTTP $code"

TOKEN=$(dd_token) && [[ -n "$TOKEN" ]] && pass "API token issued for '$DD_USERNAME'" \
  || fail "could not authenticate (check sample-app/.env)"

PRODUCT_ID=$(dd_post_json /api/v2/products/ \
  "{\"name\":\"$PRODUCT_NAME\",\"description\":\"Throwaway product created by make test-smoke.\",\"prod_type\":1}" \
  | json_get "d['id']") && pass "created product id=$PRODUCT_ID" || fail "product creation failed"

ENGAGEMENT_ID=$(dd_post_json /api/v2/engagements/ \
  "{\"name\":\"Smoke\",\"product\":$PRODUCT_ID,\"target_start\":\"$TODAY\",\"target_end\":\"$TODAY\",\"status\":\"In Progress\",\"engagement_type\":\"Interactive\"}" \
  | json_get "d['id']") && pass "created engagement id=$ENGAGEMENT_ID" || fail "engagement creation failed"

IMPORT=$(curl -sf -X POST "$DD_URL/api/v2/import-scan/" -H "Authorization: Token $TOKEN" \
  -F "engagement=$ENGAGEMENT_ID" -F "scan_type=Generic Findings Import" -F "file=@$SAMPLE" \
  -F "active=true" -F "verified=true" -F "minimum_severity=Info") || fail "import-scan failed"
TEST_ID=$(echo "$IMPORT" | json_get "d['test_id']")
TOTAL=$(echo "$IMPORT" | json_get "d['statistics']['after']['total']['total']")
[[ "$TOTAL" == "3" ]] && pass "import-scan created test id=$TEST_ID with 3 findings" \
  || fail "import-scan reported $TOTAL findings, expected 3"

SEVERITIES=$(dd_get "/api/v2/findings/?test=$TEST_ID" | json_get "','.join(sorted(f['severity'] for f in d['results']))")
[[ "$SEVERITIES" == "High,Info,Medium" ]] && pass "findings round-trip with severities High/Medium/Info" \
  || fail "unexpected severities: $SEVERITIES"

REIMPORT=$(curl -sf -X POST "$DD_URL/api/v2/reimport-scan/" -H "Authorization: Token $TOKEN" \
  -F "test=$TEST_ID" -F "scan_type=Generic Findings Import" -F "file=@$SAMPLE" \
  -F "active=true" -F "verified=true" -F "minimum_severity=Info") || fail "reimport-scan failed"
CREATED=$(echo "$REIMPORT" | json_get "d['statistics']['delta']['created']['total']['total']")
UNTOUCHED=$(echo "$REIMPORT" | json_get "d['statistics']['delta']['untouched']['total']['total']")
[[ "$CREATED" == "0" && "$UNTOUCHED" == "3" ]] && pass "reimport deduplicated: created=0 untouched=3" \
  || fail "reimport delta created=$CREATED untouched=$UNTOUCHED, expected 0/3"

[[ "$(dd_count "/api/v2/findings/?test=$TEST_ID")" == "3" ]] && pass "test still holds exactly 3 findings" \
  || fail "finding count changed after reimport"

printf '\nSmoke test OK: %d checks passed\n' "$PASSED"
