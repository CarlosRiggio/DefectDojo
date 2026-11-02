# Part 2 — Sample App + Local SAST/SCA/DAST → DefectDojo Pipeline

A minimal Flask app used purely as a scan target, plus [`scan-and-report.sh`](scan-and-report.sh): a local
pipeline that runs **Semgrep (SAST)**, **Anchore Grype (SCA)** and **OWASP ZAP baseline (DAST)** against it,
imports all three reports straight into the DefectDojo instance from [`../deployment/`](../deployment/) via its
REST API, and then triages the CVE findings by real-world exploitability with **EPSS + CISA KEV**
([`enrich-epss-kev.py`](enrich-epss-kev.py); full write-up in
[`../docs/EPSS-KEV-TRIAGE.md`](../docs/EPSS-KEV-TRIAGE.md)).

### Why a local script instead of an actual GitHub Actions workflow

DefectDojo here only exists at `localhost:8080` on this machine. A cloud-hosted GitHub Actions runner
cannot reach that address, and the alternative (a self-hosted runner registered to this repo) means
arbitrary workflow code executes directly on your machine — a real risk that isn't worth taking for a
POC. So this reproduces the exact same pipeline *shape* a CI job would run (scan → report → import) as a
script you run locally, where "local" is also where DefectDojo actually lives. No exposed infra, no
runner to babysit, same result.

---

## Prerequisites

- Docker (used to run Semgrep, Grype, ZAP, and the sample app itself — no local pip/semgrep/grype/zap install needed)
- `python3` (standard library only) for report checks and the EPSS/KEV enrichment
- Outbound HTTPS to `cisa.gov` and `api.first.org` for the KEV catalog and EPSS scores
- The [`../deployment/`](../deployment/) DefectDojo stack already up (`docker compose up -d` there)

## Setup

```bash
cd sample-app
cp .env.example .env
# DD_PASSWORD: retrieve with
#   docker compose -f ../deployment/docker-compose.yml logs initializer | grep "Admin password:"
```

## Run it

```bash
./scan-and-report.sh
```

The script, step by step:
1. **SAST** — `semgrep/semgrep` (official image) scans `app.py` with the `auto` ruleset, `--json` output.
2. **SCA** — builds the sample app image (base image overridable via `BASE_IMAGE`, default
   `python:3.12-slim`), then `anchore/grype` (official image) scans it for vulnerable OS packages and
   Python deps. Grype's JSON includes EPSS scores and CISA KEV matches per CVE.
3. **Boots the target** — runs the image on a dedicated Docker network and polls `/health` until it
   actually responds.
4. **DAST** — `zaproxy/zap-stable` (official image) runs a baseline scan against the running container,
   XML report (the format DefectDojo's `ZAP Scan` parser requires).
5. **Reports** — authenticates to DefectDojo, finds-or-creates a `Sample Flask App` product, creates a
   fresh `Automated Scan - <UTC timestamp>` engagement (its description records the base image), and
   imports all three reports into it.
6. **Triage** — [`enrich-epss-kev.py`](enrich-epss-kev.py) refreshes EPSS + CISA KEV on every CVE-bearing
   finding of the product and tags each one `priority-p0` (in KEV) … `priority-p3`, because Community
   Edition has no Priority field (Pro does). Severity is never changed. See
   [EPSS / KEV triage](#epss--kev-triage) below.

Each step prints its own checkpoint (file exists and parses, app responds, import returned `201`, enrichment summary) rather
than only a final summary — if something breaks, the script tells you which stage.

---

## A real run (captured output)

> This is the original SAST + DAST run from before the SCA/triage stages were added (engagement 2). The
> Grype + EPSS/KEV stages and their real output are in [EPSS / KEV triage](#epss--kev-triage) below.

```
==> Running Semgrep (SAST) against sample-app source
...
Ran 290 rules on 1 file: 4 findings.
Checkpoint OK: semgrep-report.json valid JSON, 4 result(s)

==> Building and starting sample-app container
Waiting for sample-app to respond on :5000/health ...
Checkpoint OK: sample-app healthy after 2s

==> Running OWASP ZAP baseline scan (DAST) against sample-app
...
WARN-NEW: Missing Anti-clickjacking Header [10020] x 1
WARN-NEW: X-Content-Type-Options Header Missing [10021] x 1
WARN-NEW: Server Leaks Version Information via "Server" HTTP Response Header Field [10036] x 3
WARN-NEW: Content Security Policy (CSP) Header Not Set [10038] x 3
WARN-NEW: Storable and Cacheable Content [10049] x 3
WARN-NEW: Permissions Policy Header Not Set [10063] x 3
WARN-NEW: Cross-Origin-Embedder-Policy Header Missing or Invalid [90004] x 3
FAIL-NEW: 0  WARN-NEW: 7  INFO: 0  PASS: 61
Checkpoint OK: zap-report.xml well-formed

==> Authenticating to DefectDojo at http://localhost:8080
Checkpoint OK: got API token

==> Looking up / creating product 'Sample Flask App'
Checkpoint OK: created product id=2

==> Creating engagement for this run
Checkpoint OK: created engagement id=2 ('Automated Scan - 20261101T115437Z')

==> Importing Semgrep (SAST) results
Checkpoint OK: Semgrep import -> 4 finding(s) in DefectDojo

==> Importing ZAP (DAST) results
Checkpoint OK: ZAP import -> 9 finding(s) in DefectDojo

==> Done
Engagement: http://localhost:8080/engagement/2
Semgrep findings imported: 4
ZAP findings imported:     9
```

All 13 findings as they actually appear in DefectDojo afterward (`GET /api/v2/findings/?test__engagement=2`):

| Severity | Finding | Source |
|---|---|---|
| Medium | `directly-returned-format-string` — raw f-string returned as a response | Semgrep |
| Medium | `raw-html-format` (Django rule, matched Flask's equivalent pattern) | Semgrep |
| Medium | `raw-html-concat` — unescaped string concatenated into an HTML response | Semgrep |
| Medium | `avoid_app_run_with_bad_host` — app bound to `0.0.0.0` | Semgrep |
| Medium | Content Security Policy (CSP) Header Not Set | ZAP |
| Medium | Missing Anti-Clickjacking Header | ZAP |
| Low | Cross-Origin-Embedder-Policy Header Missing or Invalid | ZAP |
| Low | Cross-Origin-Opener-Policy Header Missing or Invalid | ZAP |
| Low | Cross-Origin-Resource-Policy Header Missing or Invalid | ZAP |
| Low | Permissions Policy Header Not Set | ZAP |
| Low | Server Leaks Version Information via "Server" Header | ZAP |
| Low | X-Content-Type-Options Header Missing | ZAP |
| Info | Storable and Cacheable Content | ZAP |

The three Semgrep "Medium" findings on `raw-html-format`/`raw-html-concat`/`directly-returned-format-string`
are exactly what [`app.py`](app.py)'s `/greet` route was built to trigger: it reflects a query parameter
straight into an HTML response without escaping it. It's left in deliberately — the whole point of this
app is to give both scanners something real to find, not to be production code.

The engagement as it actually looks in DefectDojo — two Tests, one per tool, 4 and 9 findings respectively:

![Engagement showing the Semgrep and ZAP tests side by side](../docs/images/05-engagement-sample-app-scan.png)

Two finding detail pages, deliberately shown side by side — same severity scale, two different kinds of
location data depending on where the finding actually came from:

![Semgrep finding detail: file + line number as the location](../docs/images/07-finding-detail-semgrep.png)

![ZAP finding detail: a URL endpoint as the location](../docs/images/08-finding-detail-zap.png)

## EPSS / KEV triage

Semgrep and ZAP findings are CWE-type weaknesses with no CVE, so threat intelligence can't be attached to
them. Grype's findings all carry CVEs, and on a container image there are many of them. EPSS (the
probability of exploitation in the next 30 days, from FIRST.org) and CISA KEV (confirmed exploited in the
wild) separate the handful that matter from the rest. The pipeline was run twice on 2026-11-02, once per
base image:

```bash
./scan-and-report.sh                                          # engagement 3: current base image
BASE_IMAGE=python:3.11.5-slim-bookworm ./scan-and-report.sh   # engagement 4: stale base image (Aug 2023)
```

| | `python:3.12-slim` | `python:3.11.5-slim-bookworm` |
|---|---|---|
| Grype findings | 195 | 662 |
| Critical + High | 60 | 248 |
| `priority-p0` (in CISA KEV) | 0 | **2** — CVE-2023-4911 "Looney Tunables" (glibc) |
| `priority-p1` (EPSS ≥ 10% and High/Critical) | 0 | **11** |
| `priority-p2` / `priority-p3` | 60 / 135 | 238 / 410 |

The new stages from the stale-base run, as printed:

```
==> Building sample-app image (base: python:3.11.5-slim-bookworm)
Checkpoint OK: built sample-app:poc

==> Running Grype (SCA) against the sample-app container image
Checkpoint OK: grype-report.json valid JSON, 662 match(es), 2 in CISA KEV
...
==> Importing Grype (SCA) results
Checkpoint OK: Grype import -> 662 finding(s) in DefectDojo

==> Enriching product findings with EPSS + CISA KEV and tagging triage tiers
Active findings: 896 (856 with a CVE, 404 distinct CVEs; findings without a CVE cannot be enriched)
CISA KEV catalog 2026.10.30: 1766 entries | EPSS scores returned for 404/404 CVEs

Top 20 of 856 CVE-bearing findings, most urgent first:
Tier    ID  Severity    EPSS   Pctl  KEV Ransom CVE(s) / title
P0     238  High      63.77%   0.99  yes no     CVE-2023-4911 - CVE-2023-4911 in libc-bin:2.36-9+deb12u1  [CISA due 2023-12-12]
P0     239  High      63.77%   0.99  yes no     CVE-2023-4911 - CVE-2023-4911 in libc6:2.36-9+deb12u1  [CISA due 2023-12-12]
P1     240  High      99.99%   1.00  no  no     CVE-2023-50387 - CVE-2023-50387 in libsystemd0:252.12-1~deb12u1
...
Tier summary: P0=2  P1=11  P2=298  P3=545
Findings updated: 661 (unchanged: 195)

==> Done
Engagement: http://localhost:8080/engagement/4
Semgrep findings imported: 4
Grype findings imported:   662
ZAP findings imported:     9
Fix-now queue (CISA KEV):  http://localhost:8080/finding/open?tags=priority-p0
```

(The tier summary covers the whole product, so it includes engagement 3's 195 still-open findings.)

The engagement now has three tests, one per tool:

![Engagement with Anchore Grype, Semgrep and ZAP tests](../docs/images/10-engagement-sca-stale-base.png)

Out of 662 Grype findings, the fix-now queue (`/finding/open?tags=priority-p0`) holds exactly two.
Community Edition shows the EPSS/KEV fields as native columns:

![Open findings filtered to priority-p0](../docs/images/11-findings-kev-fix-now.png)

The design, the Community-vs-Pro comparison, more screenshots, scheduling the enrichment with cron, and its
limitations are in [`../docs/EPSS-KEV-TRIAGE.md`](../docs/EPSS-KEV-TRIAGE.md).

## Re-running

The script is idempotent on the product (reuses `Sample Flask App` if it already exists) and creates one
new engagement per run, so you can run it repeatedly to simulate recurring CI scans landing in DefectDojo
over time. The EPSS/KEV enrichment is idempotent too: a re-run with nothing new to import reported
`Findings updated: 0 (unchanged: 856)`. It only PATCHes values that actually changed upstream.

## Files

| File | Purpose |
|---|---|
| `app.py` | The scan target — 3 routes, one deliberately reflecting input unescaped |
| `requirements.txt`, `Dockerfile` | Build the scan target as a container (`BASE_IMAGE` build arg) |
| `scan-and-report.sh` | The pipeline: SAST → build + SCA → boot target → DAST → import all three → EPSS/KEV triage |
| `enrich-epss-kev.py` | EPSS + CISA KEV enrichment and `priority-p0..p3` tagging via the DefectDojo API (stdlib only, runnable standalone / from cron) |
| `.env.example` | `DD_URL` / `DD_USERNAME` / `DD_PASSWORD` template |
