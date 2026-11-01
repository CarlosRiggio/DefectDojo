# DefectDojo — Local Deployment & SAST/DAST Pipeline POC

A proof-of-concept built end-to-end against a real, locally running [DefectDojo](https://github.com/DefectDojo/django-DefectDojo)
instance — the open-source ASPM/vulnerability-management platform used by AppSec teams to aggregate
findings across scanners and manage remediation. Every command and number documented in this repo was
actually run in the process of building it; nothing here is hypothetical.

**Start here:** [`docs/DEFECTDOJO.md`](docs/DEFECTDOJO.md) — what DefectDojo is, its data model, how it's
used, and why it's useful. The two parts below are the hands-on proof of each of those claims.

---

## Repo map

```
deployment/     Part 1 — stand up DefectDojo itself (Docker Compose) and prove the REST API works:
                product -> engagement -> scan import -> findings -> reimport/deduplication.

sample-app/     Part 2 — a minimal Flask app plus a local pipeline (Semgrep SAST + OWASP ZAP DAST)
                that scans it and reports the results into the DefectDojo from Part 1, automatically.

docs/           What DefectDojo actually is: data model, usage, integrations, value.
```

### Part 1 — [`deployment/`](deployment/)

A pre-built-image Docker Compose stack (no DefectDojo source checkout needed), pinned to release
`3.4.304`. [`deployment/README.md`](deployment/README.md) walks through standing it up and driving the
full product/engagement/finding lifecycle by hand via `curl`, including a reimport that proves
deduplication actually works.

### Part 2 — [`sample-app/`](sample-app/)

A deliberately tiny Flask app used purely as a scan target, plus
[`scan-and-report.sh`](sample-app/scan-and-report.sh): runs Semgrep (SAST) and an OWASP ZAP baseline scan
(DAST) against it, then imports both reports into the Part 1 DefectDojo instance via its API — a real
CI/CD-shaped pipeline (scan → report → import), run locally rather than on GitHub Actions because
DefectDojo here only exists on `localhost` and cloud runners can't reach it (see
[`sample-app/README.md`](sample-app/README.md) for why that tradeoff was made). One run of it produced 13
real findings (4 Semgrep, 9 ZAP) now sitting in DefectDojo.

### Docs — [`docs/DEFECTDOJO.md`](docs/DEFECTDOJO.md)

The deep-dive: what DefectDojo is, its Product → Engagement → Test → Finding data model, how scan
import/reimport/deduplication actually work, its integration ecosystem, Community vs. Pro, and why any of
this is useful to an organization — each claim cross-linked to where it's demonstrated in this repo.

---

## Quick start

```bash
git clone https://github.com/CarlosRiggio/DefectDojo.git
cd DefectDojo

# Part 1: bring up DefectDojo
cd deployment && cp .env.example .env   # fill in secrets, see deployment/README.md
docker compose up -d
cd ..

# Part 2: scan the sample app and report into it
cd sample-app && cp .env.example .env   # DD_PASSWORD from the initializer logs
./scan-and-report.sh
```
