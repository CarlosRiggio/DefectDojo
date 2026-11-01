# Part 1 — DefectDojo Local Deployment

A working, **pre-built-image** Docker Compose deployment of [DefectDojo](https://github.com/DefectDojo/django-DefectDojo)
(no DefectDojo source checkout required), plus a full walkthrough — executed and captured end-to-end — of
standing it up and driving it through its core workflow via the REST API: authenticate → create a product
→ create an engagement → import findings → verify them → demonstrate reimport/deduplication.

Everything below was actually run against this exact `docker-compose.yml`; command output shown is real,
with only secrets redacted. See [`../docs/DEFECTDOJO.md`](../docs/DEFECTDOJO.md) for what DefectDojo
actually is and why it's useful — this doc is just "how this instance was stood up and proven to work."

---

## Architecture

```
                        ┌──────────────┐
            :8080  ───▶ │    nginx     │
                        └──────┬───────┘
                               │
                        ┌──────▼───────┐        ┌──────────────┐
                        │    uwsgi     │◀──────▶│   postgres   │
                        │  (Django)    │        │   18.6-alpine│
                        └──────┬───────┘        └──────────────┘
                               │
                 ┌─────────────┼─────────────┐
          ┌──────▼──────┐ ┌────▼───────┐ ┌────▼────────┐
          │ celerybeat  │ │celeryworker│ │ initializer │
          │ (scheduler) │ │  (async)   │ │ (one-shot:  │
          └──────┬──────┘ └─────┬──────┘ │ migrations +│
                 │               │         │ admin boot) │
                 └───────┬───────┘         └─────────────┘
                 ┌────────▼────────┐
                 │     valkey      │  (Redis-compatible broker/cache)
                 │   9.1.2-alpine  │
                 └─────────────────┘
```

7 services, matching DefectDojo's own [upstream compose
file](https://github.com/DefectDojo/django-DefectDojo/blob/master/docker-compose.yml) — this repo's
`docker-compose.yml` is the same topology with `build:` removed so `nginx`/`uwsgi` pull pre-built images
(`defectdojo/defectdojo-django` / `defectdojo/defectdojo-nginx`) instead of needing the full application
source tree.

Image versions are **pinned** (not `latest`) for reproducibility:

| Component | Image | Version |
|---|---|---|
| Django / uwsgi | `defectdojo/defectdojo-django` | `3.4.304` |
| nginx | `defectdojo/defectdojo-nginx` | `3.4.304` |
| Database | `postgres` | `18.6-alpine` |
| Broker/cache | `valkey/valkey` | `9.1.2-alpine` |

---

## Quick start

**Prerequisites:** Docker Engine ≥ 19.03, Docker Compose v2.

```bash
git clone https://github.com/CarlosRiggio/DefectDojo.git
cd DefectDojo/deployment
cp .env.example .env
# edit .env: replace every CHANGE_ME with a generated secret, e.g.
#   openssl rand -hex 16   # for DD_SECRET_KEY / DD_CREDENTIAL_AES_256_KEY
#   openssl rand -hex 24   # for DD_DATABASE_PASSWORD
# DD_DATABASE_URL must use the same password as DD_DATABASE_PASSWORD.
# COMPOSE_PROJECT_NAME is pinned to "defectdojo" so commands behave the
# same regardless of which directory this file lives in.

docker compose up -d
```

Wait for all services to be healthy and the one-shot `initializer` to exit `0`:

```bash
$ docker compose ps
NAME                        SERVICE        STATUS          PORTS
defectdojo-celerybeat-1     celerybeat     Up
defectdojo-celeryworker-1   celeryworker   Up
defectdojo-nginx-1          nginx          Up              0.0.0.0:8080->8080/tcp
defectdojo-postgres-1       postgres       Up
defectdojo-uwsgi-1          uwsgi          Up
defectdojo-valkey-1         valkey         Up
# defectdojo-initializer-1 is a one-shot job: it exits after bootstrapping
```

```bash
$ docker inspect defectdojo-initializer-1 --format '{{.State.Status}} exitcode={{.State.ExitCode}}'
exited exitcode=0
```

Retrieve the auto-generated admin password from the initializer logs (DefectDojo does not let you set this
password via env var by design — it's randomly generated on first boot):

```bash
docker compose logs initializer | grep "Admin password:"
# Admin password: <redacted — unique per deployment>
```

Then open **http://localhost:8080** and log in as `admin` with that password.

Confirmed working in this session:

```bash
$ curl -sI http://localhost:8080/login
HTTP/1.1 200 OK
Server: nginx
Content-Type: text/html; charset=utf-8
```

---

## Functional walkthrough (REST API)

The full product → engagement → scan import → findings lifecycle was exercised via `curl` against the
`/api/v2/` REST API, DefectDojo's primary integration surface for CI/CD pipelines and external tooling.

### 1. Authenticate

```bash
curl -s -X POST http://localhost:8080/api/v2/api-token-auth/ \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"<admin password>"}'
```
```json
{"token":"<redacted>"}
```

### 2. Create a product

```bash
curl -s -X POST http://localhost:8080/api/v2/products/ \
  -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"DefectDojo POC Product","description":"Local Docker Compose POC deployment to demonstrate DefectDojo usage.","prod_type":1}'
```
→ `HTTP 201`, `id: 1`

### 3. Create an engagement under that product

```bash
curl -s -X POST http://localhost:8080/api/v2/engagements/ \
  -H "Authorization: Token $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"POC Engagement","product":1,"target_start":"2026-11-01","target_end":"2026-11-30","status":"In Progress","engagement_type":"Interactive"}'
```
→ `HTTP 201`, `id: 1`

### 4. Import findings

[`samples/generic-findings-sample.json`](samples/generic-findings-sample.json) is a hand-authored report in
DefectDojo's self-contained **Generic Findings Import** format (3 findings: High / Medium / Info), used here
instead of a third-party scanner output so the whole walkthrough is self-contained and reproducible.

```bash
curl -s -X POST http://localhost:8080/api/v2/import-scan/ \
  -H "Authorization: Token $TOKEN" \
  -F "engagement=1" \
  -F "scan_type=Generic Findings Import" \
  -F "file=@samples/generic-findings-sample.json" \
  -F "active=true" -F "verified=true" -F "minimum_severity=Info"
```
→ `HTTP 201`, `test_id: 1`, statistics confirm exactly the imported counts:

```json
"statistics": {
  "after": {
    "info":   {"total": 1},
    "medium": {"total": 1},
    "high":   {"total": 1},
    "total":  {"total": 3}
  }
}
```

### 5. Verify findings round-trip

```bash
curl -s "http://localhost:8080/api/v2/findings/?test=1" -H "Authorization: Token $TOKEN"
```
```
count: 3
- High   | Hardcoded Database Credentials in Configuration File
- Medium | Outdated Dependency With Known CVE
- Info   | Missing Security Headers on HTTP Responses
```

### 6. Reimport to demonstrate deduplication

Re-posting the identical file to `/api/v2/reimport-scan/` against the same test returns a `delta` showing
all 3 findings as `untouched` and 0 `created` — DefectDojo recognized them as already present rather than
duplicating them:

```json
"delta": {
  "created":   {"total": {"total": 0}},
  "untouched": {"total": {"total": 3}}
}
```

---

## Repository contents

| File | Purpose |
|---|---|
| `docker-compose.yml` | 7-service stack using pre-built DefectDojo images (no source checkout needed) |
| `.env.example` | Documented environment template — copy to `.env` and fill in secrets |
| `samples/generic-findings-sample.json` | Self-contained sample findings report used in the import walkthrough |

## Teardown

```bash
docker compose down -v   # -v also removes the postgres/media/redis volumes
```

## What's next

[`../sample-app/`](../sample-app/) builds on this exact running instance: a minimal app plus a local
SAST (Semgrep) + DAST (OWASP ZAP) pipeline that reports its findings straight into this DefectDojo via the
same REST API used above — a second, automated product/engagement living alongside the one created here.
