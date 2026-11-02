#!/usr/bin/env bash
# Shared helpers for the integration tests (sourced, not executed).
# Reads DD_URL / DD_USERNAME / DD_PASSWORD from sample-app/.env.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/sample-app/.env" ]]; then
  echo "Missing sample-app/.env - run 'make env' first." >&2
  exit 1
fi
set -a
# shellcheck source=/dev/null
source "$REPO_ROOT/sample-app/.env"
set +a

PASSED=0

pass() { PASSED=$((PASSED + 1)); printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1" >&2; exit 1; }
section() { printf '\n%s\n' "$1"; }

# json_get '<python expression on d>' - reads JSON on stdin, prints the result.
json_get() { python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }

dd_token() {
  curl -sf -X POST "$DD_URL/api/v2/api-token-auth/" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$DD_USERNAME\",\"password\":\"$DD_PASSWORD\"}" | json_get "d['token']"
}

# dd_get <path-with-query>
dd_get() { curl -sf "$DD_URL$1" -H "Authorization: Token $TOKEN"; }

# dd_post_json <path> <json>
dd_post_json() {
  curl -sf -X POST "$DD_URL$1" -H "Authorization: Token $TOKEN" \
    -H "Content-Type: application/json" -d "$2"
}

dd_delete() { curl -sf -o /dev/null -X DELETE "$DD_URL$1" -H "Authorization: Token $TOKEN"; }

# dd_count <path-with-query> - number of results of a list endpoint
dd_count() { dd_get "$1" | json_get "d['count']"; }
