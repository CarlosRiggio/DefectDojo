# DefectDojo POC - one entry point for running and testing everything locally.
#
#   make help          list every target
#   make up            start DefectDojo (creates the .env files on first run)
#   make test          offline checks: lint + unit tests + docs links (no stack needed)
#   make test-all      everything, including the live end-to-end tests
#
# Requires: Docker (with Compose v2), python3, curl. See docs/06-testing.md.

SHELL := bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory
export PYTHONDONTWRITEBYTECODE := 1

DD_URL           ?= http://localhost:8080
WAIT_TIMEOUT     ?= 300
STALE_BASE_IMAGE ?= python:3.11.5-slim-bookworm
PRODUCT_ID       ?=
SERVICE          ?=

COMPOSE     := docker compose --project-directory deployment
SHELL_FILES := sample-app/scan-and-report.sh tests/lib.sh tests/test-deployment-api.sh tests/test-pipeline.sh
PY_FILES    := sample-app/enrich-epss-kev.py scripts/init-env.py tests/check_docs.py tests/test_enrich_epss_kev.py
SAMPLE_ENV  := set -a; source sample-app/.env; set +a

.PHONY: help prereqs env up wait down clean status logs password \
        scan scan-stale enrich enrich-dry-run demo \
        lint test-unit test-docs test test-smoke test-pipeline test-integration test-all

##@ Help

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} \
	  /^##@/ {printf "\n\033[1m%s\033[0m\n", substr($$0, 5)} \
	  /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo

##@ DefectDojo stack

prereqs: ## Check that docker, docker compose, python3 and curl are available
	@for bin in docker python3 curl; do \
	  command -v $$bin >/dev/null || { echo "missing: $$bin" >&2; exit 1; }; done
	@docker compose version >/dev/null || { echo "missing: docker compose v2" >&2; exit 1; }
	@docker info >/dev/null 2>&1 || { echo "Docker engine not reachable - is Docker running?" >&2; exit 1; }
	@echo "prereqs OK: $$(docker --version | cut -d, -f1), $$(python3 --version)"

deployment/.env:
	@python3 scripts/init-env.py deployment

env: deployment/.env ## Create deployment/.env (generated secrets) and, if the stack is up, sample-app/.env
	@if curl -sf -o /dev/null $(DD_URL)/login; then python3 scripts/init-env.py sample-app; \
	 else echo "Stack not up yet - sample-app/.env is created by 'make up'"; fi

up: prereqs deployment/.env ## Start DefectDojo, wait until it is ready, write sample-app/.env
	@$(COMPOSE) up -d
	@$(MAKE) wait
	@python3 scripts/init-env.py sample-app
	@echo "DefectDojo ready at $(DD_URL) - log in as admin ('make password' shows the password)"

wait: ## Wait for the UI to answer and the initializer to have exited 0
	@echo "Waiting up to $(WAIT_TIMEOUT)s for $(DD_URL)/login ..."
	@for i in $$(seq 1 $$(( $(WAIT_TIMEOUT) / 5 ))); do \
	  if curl -sf -o /dev/null $(DD_URL)/login; then echo "UI up after ~$$(( i * 5 ))s"; break; fi; \
	  if [[ $$i -eq $$(( $(WAIT_TIMEOUT) / 5 )) ]]; then echo "timed out" >&2; $(COMPOSE) ps >&2; exit 1; fi; \
	  sleep 5; done
	@code=$$(docker inspect defectdojo-initializer-1 --format '{{.State.ExitCode}}'); \
	  [[ "$$code" == "0" ]] || { echo "initializer exited $$code - see 'make logs SERVICE=initializer'" >&2; exit 1; }

down: ## Stop the stack (data volumes are kept)
	@$(COMPOSE) down

clean: ## DESTRUCTIVE: stop the stack AND delete all its data volumes (needs CONFIRM=1)
	@[[ "$(CONFIRM)" == "1" ]] || { echo "This deletes every finding/product in the local DefectDojo. Re-run with: make clean CONFIRM=1" >&2; exit 1; }
	@$(COMPOSE) down -v
	@rm -f sample-app/semgrep-report.json sample-app/zap-report.xml sample-app/zap.yaml sample-app/grype-report.json
	@echo "Stack and volumes removed. sample-app/.env still holds the OLD admin password: delete it before the next 'make up'."

status: ## Show stack containers
	@$(COMPOSE) ps -a

logs: ## Follow stack logs (SERVICE=uwsgi to pick one)
	@$(COMPOSE) logs -f --tail=100 $(SERVICE)

password: ## Print the admin password from the initializer logs
	@$(COMPOSE) logs --no-color initializer | grep -o "Admin password: .*" | tail -1

##@ Scan pipeline (needs the stack up)

scan: ## Run the SAST + SCA + DAST pipeline and EPSS/KEV triage on the current base image
	@sample-app/scan-and-report.sh

scan-stale: ## Same, on a stale base image (STALE_BASE_IMAGE) to exercise the KEV/P0 path
	@BASE_IMAGE=$(STALE_BASE_IMAGE) sample-app/scan-and-report.sh

enrich: ## Refresh EPSS/KEV + priority tags on all findings (PRODUCT_ID=n to scope)
	@$(SAMPLE_ENV); python3 sample-app/enrich-epss-kev.py $(if $(PRODUCT_ID),--product-id $(PRODUCT_ID))

enrich-dry-run: ## Show what 'make enrich' would change, without writing
	@$(SAMPLE_ENV); python3 sample-app/enrich-epss-kev.py --dry-run $(if $(PRODUCT_ID),--product-id $(PRODUCT_ID))

demo: up scan scan-stale ## Full demo from scratch: start the stack, run both pipeline variants

##@ Tests

lint: ## Static checks: bash syntax, shellcheck (via Docker), Python syntax, compose config
	@for f in $(SHELL_FILES); do bash -n $$f; done && echo "  PASS  bash -n ($(words $(SHELL_FILES)) scripts)"
	@docker run --rm -v "$(CURDIR):/mnt" -w /mnt koalaman/shellcheck:stable -x $(SHELL_FILES) \
	  && echo "  PASS  shellcheck"
	@python3 -c 'import ast,sys; [ast.parse(open(f).read(), f) for f in sys.argv[1:]]' $(PY_FILES) \
	  && echo "  PASS  python syntax ($(words $(PY_FILES)) files)"
	@$(COMPOSE) --env-file deployment/.env.example config -q && echo "  PASS  docker compose config"

test-unit: ## Unit tests for the EPSS/KEV triage logic (offline)
	@python3 -m unittest discover -s tests -p 'test_*.py'

test-docs: ## Check every relative link, image and anchor in the Markdown docs
	@python3 tests/check_docs.py

test: lint test-unit test-docs ## Offline test suite - no running stack needed
	@echo "Offline test suite OK"

test-smoke: ## Live: replay the REST API walkthrough against the running stack (self-cleaning)
	@tests/test-deployment-api.sh

test-pipeline: ## Live: run the full pipeline and assert on the resulting engagement
	@tests/test-pipeline.sh

test-integration: up test-smoke test-pipeline ## Live: start the stack, then smoke + pipeline tests

test-all: test test-integration ## Everything: offline suite + live integration tests
	@echo "All tests OK"
