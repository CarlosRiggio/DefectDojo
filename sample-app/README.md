# sample-app/

A deliberately vulnerable Flask app, its SAST + SCA + DAST pipeline into DefectDojo, and the EPSS/KEV
triage script.

**Guides:** [docs/03-scan-pipeline.md](../docs/03-scan-pipeline.md) covers the pipeline and its results;
[docs/04-epss-kev-triage.md](../docs/04-epss-kev-triage.md) covers EPSS + CISA KEV triage.

```bash
make scan             # from the repo root, with the stack up (make up)
make scan-stale       # same on a stale base image, to exercise the KEV "fix now" path
make enrich           # refresh EPSS/KEV + priority tags only
```

| File | Purpose |
|---|---|
| [`app.py`](app.py) | Scan target: 3 routes, `/greet` deliberately reflects input unescaped |
| [`requirements.txt`](requirements.txt), [`Dockerfile`](Dockerfile) | Container build (`BASE_IMAGE` build arg) |
| [`scan-and-report.sh`](scan-and-report.sh) | Semgrep → build + Grype → ZAP → import ×3 → EPSS/KEV triage |
| [`enrich-epss-kev.py`](enrich-epss-kev.py) | EPSS + CISA KEV enrichment and `priority-p0..p3` tags via the API |
| [`.env.example`](.env.example) | DefectDojo URL/credentials template. `make up` writes `.env` for you |
