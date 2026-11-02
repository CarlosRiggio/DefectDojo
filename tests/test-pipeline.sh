#!/usr/bin/env bash
# `cond && pass ... || fail ...` is intentional: pass() only prints and cannot fail.
# shellcheck disable=SC2015
# End-to-end test of the scan pipeline: runs sample-app/scan-and-report.sh
# for real (Semgrep + Grype + ZAP -> DefectDojo -> EPSS/KEV triage) and then
# checks the resulting engagement through the API:
#
#   - it has exactly the three expected tests, each with findings
#   - every CVE-bearing finding was enriched (EPSS present) and carries
#     exactly one priority-p0..p3 tag, consistent with its KEV flag
#   - findings without a CVE (SAST/DAST) carry no priority tag
#
# Usage: make test-pipeline [BASE_IMAGE=python:3.11.5-slim-bookworm]

set -uo pipefail
# shellcheck source=tests/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOG="$(mktemp)"
trap 'rm -f "$LOG"' EXIT

section "Running the pipeline (base image: ${BASE_IMAGE:-python:3.12-slim}) - takes a few minutes"
"$REPO_ROOT/sample-app/scan-and-report.sh" >"$LOG" 2>&1
rc=$?
grep -E '^(==>|Checkpoint OK|FAILED|Tier summary|Findings updated)' "$LOG" | sed 's/^/    /'
[[ $rc -eq 0 ]] && pass "scan-and-report.sh exited 0" || { tail -30 "$LOG" >&2; fail "scan-and-report.sh exited $rc"; }

ENGAGEMENT_ID=$(sed -n 's#^Engagement: .*/engagement/\([0-9]*\)$#\1#p' "$LOG")
[[ -n "$ENGAGEMENT_ID" ]] && pass "pipeline reported engagement id=$ENGAGEMENT_ID" || fail "no engagement id in output"

section "Checking engagement $ENGAGEMENT_ID through the API"
TOKEN=$(dd_token) || fail "could not authenticate"

TESTS=$(dd_get "/api/v2/tests/?engagement=$ENGAGEMENT_ID" \
  | json_get "','.join(sorted(t['test_type_name'] for t in d['results']))")
[[ "$TESTS" == "Anchore Grype,Semgrep JSON Report,ZAP Scan" ]] && pass "engagement has the Grype, Semgrep and ZAP tests" \
  || fail "unexpected tests: $TESTS"

# Count per test id (the findings API has no filter on test type name - an
# unknown filter is silently ignored and would count the whole engagement).
while IFS=$'\t' read -r test_id scan; do
  n=$(dd_count "/api/v2/findings/?test=$test_id&limit=1")
  [[ "$n" -gt 0 ]] && pass "$scan (test $test_id) produced $n finding(s)" || fail "$scan produced no findings"
done < <(dd_get "/api/v2/tests/?engagement=$ENGAGEMENT_ID" \
  | json_get "'\n'.join(f\"{t['id']}\t{t['test_type_name']}\" for t in d['results'])")

# Pull every finding of the engagement and check the triage invariants.
python3 - "$DD_URL" "$TOKEN" "$ENGAGEMENT_ID" <<'EOF' || fail "triage invariants violated (see above)"
import json, re, sys, urllib.request
url, token, eng = sys.argv[1:]
nxt = f"{url}/api/v2/findings/?test__engagement={eng}&limit=500"
findings = []
while nxt:
    req = urllib.request.Request(nxt, headers={"Authorization": f"Token {token}"})
    page = json.load(urllib.request.urlopen(req))
    findings += page["results"]; nxt = page["next"]

tiers = {"priority-p0", "priority-p1", "priority-p2", "priority-p3"}
errors, with_cve, counts = [], 0, {t: 0 for t in sorted(tiers)}
for f in findings:
    has_cve = any(re.match(r"^CVE-\d{4}-\d+$", v["vulnerability_id"], re.I)
                  for v in f.get("vulnerability_ids") or [])
    got = tiers & set(f.get("tags") or [])
    if not has_cve:
        if got:
            errors.append(f"#{f['id']} has no CVE but is tagged {got}")
        continue
    with_cve += 1
    if len(got) != 1:
        errors.append(f"#{f['id']} has {len(got)} priority tags: {got}")
        continue
    tier = got.pop(); counts[tier] += 1
    if f["epss_score"] is None:
        errors.append(f"#{f['id']} has a CVE but no EPSS score")
    if (tier == "priority-p0") != bool(f["known_exploited"]):
        errors.append(f"#{f['id']} tier {tier} disagrees with known_exploited={f['known_exploited']}")

for e in errors[:20]:
    print("    " + e)
summary = " ".join(f"{k[-2:].upper()}={v}" for k, v in counts.items())
print(f"  {'PASS' if not errors else 'FAIL'}  {with_cve} CVE findings enriched + tiered ({summary}); "
      f"{len(findings) - with_cve} non-CVE findings untagged")
sys.exit(1 if errors else 0)
EOF
PASSED=$((PASSED + 1))

printf '\nPipeline test OK: %d checks passed (engagement: %s/engagement/%s)\n' "$PASSED" "$DD_URL" "$ENGAGEMENT_ID"
