[← 5. Multi-project tracking](05-multi-project-tracking.md) · **6. Testing & automation** · [README ↑](../README.md)

# 6. Testing & Automation

Everything in this repo runs from the root [`Makefile`](../Makefile): the stack lifecycle, both pipeline
demos, and a test suite in two layers. The **offline** layer needs no running stack and finishes in
seconds. The **live** layer exercises the real DefectDojo instance end to end.

- [Make targets](#make-targets)
- [Test suite](#test-suite)
- [Typical workflows](#typical-workflows)
- [Test files](#test-files)

---

## Make targets

`make help` lists them all:

| Group | Target | What it does |
|---|---|---|
| **Stack** | `make prereqs` | Checks docker, compose v2, python3, curl, and that the Docker engine answers |
| | `make up` | Creates `deployment/.env` with generated secrets if missing, starts the stack, waits for the UI and the initializer, writes `sample-app/.env` |
| | `make env` | Only the `.env` generation step ([`scripts/init-env.py`](../scripts/init-env.py)) |
| | `make wait` | Waits (default 300 s, `WAIT_TIMEOUT=`) for `/login` to answer and the initializer to have exited `0` |
| | `make status` / `make logs [SERVICE=uwsgi]` | Container states / follow logs |
| | `make password` | Prints the admin password from the initializer logs |
| | `make down` | Stops the stack and keeps the data |
| | `make clean CONFIRM=1` | **Destructive**: also deletes the data volumes and generated reports |
| **Pipeline** | `make scan` | SAST + SCA + DAST pipeline + EPSS/KEV triage ([guide 3](03-scan-pipeline.md)) |
| | `make scan-stale` | The same on `STALE_BASE_IMAGE` (default `python:3.11.5-slim-bookworm`) |
| | `make enrich [PRODUCT_ID=n]` / `make enrich-dry-run` | EPSS/KEV refresh only ([guide 4](04-epss-kev-triage.md)) |
| | `make demo` | `up` + `scan` + `scan-stale`: the whole demo from scratch |
| **Tests** | `make test` | Offline suite: `lint` + `test-unit` + `test-docs` |
| | `make test-smoke` | Live API walkthrough (self-cleaning) |
| | `make test-pipeline` | Live end-to-end pipeline run with assertions |
| | `make test-integration` | `up` + `test-smoke` + `test-pipeline` |
| | `make test-all` | `test` + `test-integration` |

Variables such as `DD_URL`, `WAIT_TIMEOUT`, `STALE_BASE_IMAGE`, `PRODUCT_ID` and `SERVICE` can be
overridden on the command line, e.g. `make scan-stale STALE_BASE_IMAGE=python:3.10.12-slim`.

## Test suite

### Offline: `make test`

| Target | Checks | Why it matters |
|---|---|---|
| `make lint` | `bash -n` and [shellcheck](https://www.shellcheck.net/) (run via its Docker image) on every shell script; Python syntax; `docker compose config` against `.env.example` | Catches script bugs and compose/template drift before anything runs |
| `make test-unit` | [`tests/test_enrich_epss_kev.py`](../tests/test_enrich_epss_kev.py): 15 unit tests of the triage logic | The multi-CVE rules (highest EPSS with its own percentile, KEV if any, earliest date), tier thresholds, tag ownership. No network |
| `make test-docs` | [`tests/check_docs.py`](../tests/check_docs.py): every relative link, image and `#anchor` in every Markdown file resolves; unreferenced screenshots are reported | Keeps these guides' cross-links and screenshots from rotting |

Real output:

```
$ make test
  PASS  bash -n (4 scripts)
  PASS  shellcheck
  PASS  python syntax (4 files)
  PASS  docker compose config
...............
----------------------------------------------------------------------
Ran 15 tests in 0.001s

OK
Checked 9 Markdown files, 13 images
  PASS  all relative links, images and anchors resolve
Offline test suite OK
```

### Live: `make test-smoke`

[`tests/test-deployment-api.sh`](../tests/test-deployment-api.sh) replays the
[REST API walkthrough](02-deployment.md#rest-api-walkthrough) against a **throwaway product** and deletes
it on exit (also on failure), so it can run any number of times without leaving data behind. It takes
seconds.

```
$ make test-smoke
DefectDojo API smoke test against http://localhost:8080
  PASS  UI answers on /login (HTTP 200)
  PASS  API token issued for 'admin'
  PASS  created product id=3
  PASS  created engagement id=5
  PASS  import-scan created test id=10 with 3 findings
  PASS  findings round-trip with severities High/Medium/Info
  PASS  reimport deduplicated: created=0 untouched=3
  PASS  test still holds exactly 3 findings

Smoke test OK: 8 checks passed
  (cleaned up throwaway product id=3)
```

### Live: `make test-pipeline`

[`tests/test-pipeline.sh`](../tests/test-pipeline.sh) runs the real pipeline (about 5 minutes) and then
checks the resulting engagement through the API:

- `scan-and-report.sh` exits `0` and reports its engagement
- the engagement has exactly the `Anchore Grype`, `Semgrep JSON Report` and `ZAP Scan` tests, each with
  findings (counted per test id)
- every CVE-bearing finding has an EPSS score and **exactly one** `priority-p*` tag, and `priority-p0`
  agrees with `known_exploited`
- no non-CVE (SAST/DAST) finding carries a priority tag

Unlike the smoke test, this is a genuine pipeline run: it **adds an engagement** to `Sample Flask App`,
as `make scan` does. Pass `BASE_IMAGE=python:3.11.5-slim-bookworm` to run it on the stale image.

```
$ make test-pipeline

Running the pipeline (base image: python:3.12-slim) - takes a few minutes
    ==> Running Semgrep (SAST) against sample-app source
    Checkpoint OK: semgrep-report.json valid JSON, 4 result(s)
    ==> Building sample-app image (base: python:3.12-slim)
    Checkpoint OK: built sample-app:poc
    ==> Running Grype (SCA) against the sample-app container image
    Checkpoint OK: grype-report.json valid JSON, 195 match(es), 0 in CISA KEV
    ==> Starting sample-app container
    Checkpoint OK: sample-app healthy after 2s
    ==> Running OWASP ZAP baseline scan (DAST) against sample-app
    Checkpoint OK: zap-report.xml well-formed
    ==> Stopping sample-app container
    ==> Authenticating to DefectDojo at http://localhost:8080
    Checkpoint OK: got API token
    ==> Looking up / creating product 'Sample Flask App'
    Checkpoint OK: reusing existing product id=2
    ==> Creating engagement for this run
    Checkpoint OK: created engagement id=7 ('Automated Scan - 20261102T162947Z')
    ==> Importing Semgrep (SAST) results
    Checkpoint OK: Semgrep import -> 4 finding(s) in DefectDojo
    ==> Importing ZAP (DAST) results
    Checkpoint OK: ZAP import -> 9 finding(s) in DefectDojo
    ==> Importing Grype (SCA) results
    Checkpoint OK: Grype import -> 195 finding(s) in DefectDojo
    ==> Enriching product findings with EPSS + CISA KEV and tagging triage tiers
    Tier summary: P0=2  P1=11  P2=418  P3=815
    Findings updated: 195 (unchanged: 1051)
    ==> Done
  PASS  scan-and-report.sh exited 0
  PASS  pipeline reported engagement id=7

Checking engagement 7 through the API
  PASS  engagement has the Grype, Semgrep and ZAP tests
  PASS  Semgrep JSON Report (test 14) produced 4 finding(s)
  PASS  ZAP Scan (test 15) produced 9 finding(s)
  PASS  Anchore Grype (test 16) produced 195 finding(s)
  PASS  195 CVE findings enriched + tiered (P0=0 P1=0 P2=60 P3=135); 13 non-CVE findings untagged

Pipeline test OK: 7 checks passed (engagement: http://localhost:8080/engagement/7)
```

## Typical workflows

| Situation | Run |
|---|---|
| Edited docs or scripts | `make test` |
| Changed the triage logic | `make test-unit`, then `make test-pipeline` |
| Fresh machine, full check | `make test-all` |
| Show the demo to someone | `make demo`, then open `http://localhost:8080/finding/open?tags=priority-p0` |
| Start over with an empty instance | `make clean CONFIRM=1 && rm sample-app/.env && make up` |

## Test files

| File | Kind |
|---|---|
| [`Makefile`](../Makefile) | Entry point for everything |
| [`scripts/init-env.py`](../scripts/init-env.py) | Generates `deployment/.env` (secrets) and `sample-app/.env` (admin password); never overwrites |
| [`tests/lib.sh`](../tests/lib.sh) | Shared helpers for the live tests (auth, API calls, PASS/FAIL output) |
| [`tests/test-deployment-api.sh`](../tests/test-deployment-api.sh) | Live smoke test |
| [`tests/test-pipeline.sh`](../tests/test-pipeline.sh) | Live end-to-end pipeline test |
| [`tests/test_enrich_epss_kev.py`](../tests/test_enrich_epss_kev.py) | Unit tests (stdlib `unittest`) |
| [`tests/check_docs.py`](../tests/check_docs.py) | Docs integrity check |

---

[← 5. Multi-project tracking](05-multi-project-tracking.md) · **6. Testing & automation** · [README ↑](../README.md)
