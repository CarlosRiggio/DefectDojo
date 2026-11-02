# DefectDojo POC — Local Deployment, Scan Pipeline & Risk-Based Triage

A proof of concept built end to end against a real, locally running
[DefectDojo](https://github.com/DefectDojo/django-DefectDojo) (Community Edition). DefectDojo is the
open-source platform AppSec teams use to collect findings from all their scanners in one place and manage
remediation.

Every command, number and screenshot in this repo comes from an actual run. Nothing is hypothetical.

## What it demonstrates

| | What | Result from a real run |
|---|---|---|
| 1 | **Deployment.** A 7-service Docker Compose stack from pre-built images, driven through its REST API | Import → findings → reimport with deduplication (`created=0, untouched=3`) |
| 2 | **Scan pipeline.** Semgrep (SAST) + Grype (SCA) + OWASP ZAP (DAST) against a sample Flask app, imported automatically | 4 + 195 + 9 findings in one engagement per run |
| 3 | **Risk-based triage.** EPSS + CISA KEV enrichment and `priority-p0..p3` tiers, a Pro-only feature added to Community Edition | On a stale base image: 248 Critical/High → **13 actionable, 2 fix-now** |

![Open findings filtered to the fix-now queue: the two CISA KEV findings](docs/images/11-findings-kev-fix-now.png)

## Quick start

**Prerequisites:** Docker with Compose v2, `python3`, `curl`, `make`.

```bash
git clone https://github.com/CarlosRiggio/DefectDojo.git && cd DefectDojo

make up          # generate secrets, start DefectDojo, wait until ready (~1-2 min first time)
make password    # admin password -> log in at http://localhost:8080 as "admin"
make scan        # run the SAST + SCA + DAST pipeline and EPSS/KEV triage
make scan-stale  # same on a 2023 base image, to see the KEV "fix now" path
make test        # offline checks; `make test-all` also runs the live end-to-end tests
```

Run `make help` for every target. Each one is explained in [Testing & automation](docs/06-testing.md).

## Documentation

Read in order for the full story, or jump to what you need:

| # | Guide | Read it for |
|---|---|---|
| 1 | [DefectDojo overview](docs/01-defectdojo-overview.md) | What DefectDojo is, its data model, how teams use it, Community vs. Pro |
| 2 | [Deployment](docs/02-deployment.md) | The Compose stack, configuration, and the REST API walkthrough (import, reimport, dedup) |
| 3 | [Scan pipeline](docs/03-scan-pipeline.md) | The Semgrep + Grype + ZAP pipeline: how it works and what it found |
| 4 | [EPSS / KEV triage](docs/04-epss-kev-triage.md) | Ranking findings by real-world exploitation risk on Community Edition |
| 5 | [Multi-project tracking](docs/05-multi-project-tracking.md) | Scaling this setup from one sample app to many projects |
| 6 | [Testing & automation](docs/06-testing.md) | The Makefile, the test suite, and what each test proves |

## Repository layout

```
.
├── Makefile                    one entry point: stack lifecycle, demos, tests
├── deployment/                 DefectDojo itself
│   ├── docker-compose.yml        7 services, pinned pre-built images
│   ├── .env.example              configuration template (make up generates .env)
│   └── samples/                  Generic Findings sample used by the API walkthrough
├── sample-app/                 the scan target and its pipeline
│   ├── app.py, Dockerfile        deliberately vulnerable Flask app (base image overridable)
│   ├── scan-and-report.sh        Semgrep + Grype + ZAP -> DefectDojo -> EPSS/KEV triage
│   └── enrich-epss-kev.py        EPSS + CISA KEV enrichment and priority tagging
├── scripts/init-env.py         generates both .env files (secrets, admin password)
├── tests/                      unit, docs-integrity, smoke and end-to-end tests
└── docs/                       the guides above + screenshots
```

## Scope and constraints

This is a **local POC**. DefectDojo runs on `localhost`, so the pipeline is a local script and not a
hosted CI job. Secrets live in git-ignored `.env` files. Auth uses Community Edition local accounts. What
changes for a real rollout is covered in
[Multi-project tracking → constraints](docs/05-multi-project-tracking.md#constraints-to-carry-into-a-real-rollout).
