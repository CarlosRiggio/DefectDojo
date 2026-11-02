# deployment/

The DefectDojo stack: a 7-service Docker Compose deployment from pinned, pre-built images.

**Full guide:** [docs/02-deployment.md](../docs/02-deployment.md) covers the architecture, configuration
and the REST API walkthrough.

```bash
make up          # from the repo root: create .env, start, wait until ready
make password    # admin password for http://localhost:8080
make down        # stop (keeps data)
```

| File | Purpose |
|---|---|
| [`docker-compose.yml`](docker-compose.yml) | nginx, uwsgi, celerybeat, celeryworker, initializer, postgres, valkey |
| [`.env.example`](.env.example) | Documented configuration template. `make up` generates `.env` from it with random secrets |
| [`samples/generic-findings-sample.json`](samples/generic-findings-sample.json) | 3 hand-written findings used by the API walkthrough and `make test-smoke` |
