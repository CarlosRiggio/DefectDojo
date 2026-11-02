[← README](../README.md) · **1. Overview** · [2. Deployment →](02-deployment.md)

# 1. DefectDojo Overview

What DefectDojo is, how its data is modeled, how teams actually use it, and where this repo demonstrates
each part.

- [The problem it solves](#the-problem-it-solves)
- [Core data model](#core-data-model)
- [How it's used](#how-its-used)
- [Integrations](#integrations)
- [Community Edition vs. Pro](#community-edition-vs-pro)
- [Why it matters](#why-it-matters)
- [Where this repo demonstrates each capability](#where-this-repo-demonstrates-each-capability)

---

## The problem it solves

[DefectDojo](https://github.com/DefectDojo/django-DefectDojo) is an open-source **Application Security
Posture Management (ASPM)** platform: a single system of record for every security finding an
organization produces, whichever tool found it. It started as an OWASP Flagship project and is now
developed by DefectDojo, Inc. as an open-source **Community Edition** (what this repo runs) alongside a
commercial **Pro** edition built on the same core.

A typical AppSec program runs a dozen scanners (SAST, DAST, SCA, container, infra, manual pentests). Each
has its own report format, its own severity scale and its own idea of what a duplicate is. Without a layer
on top, findings end up scattered across Jira tickets, spreadsheets and tool dashboards that never agree.
DefectDojo normalizes all of it into one data model, de-duplicates across scans and tools, and gives every
finding a lifecycle (new → verified → risk-accepted / mitigated → closed) that developers and security
teams both work from.

## Core data model

```
Product Type
  └── Product                    (an application / service)
        └── Engagement           (a time-boxed round of testing: a sprint, a pentest, a CI run)
              └── Test           (one scan or one manual test within that engagement)
                    └── Finding  (one vulnerability: severity, CWE/CVE, status, location)
                          ├── Location / Endpoint   (URL, file + line, or package + version)
                          ├── Risk Acceptance        (formally accepted instead of fixed)
                          └── Notes / Tags           (triage history, context)
```

| Element | What it represents | In this repo |
|---|---|---|
| **Product Type** | A grouping of products (e.g. "Internal Tools", "Customer-Facing") | `prod_type: 1`, the default created on first boot |
| **Product** | One application being tracked | `DefectDojo POC Product` (guide 2), `Sample Flask App` (guide 3) |
| **Engagement** | A bounded round of testing: a pentest, a sprint, or (here) one CI run | `POC Engagement`, `Automated Scan - <timestamp>` |
| **Test** | One scan or manual assessment inside an engagement, tied to a scan type | the Generic, Semgrep, ZAP and Grype imports are one Test each |
| **Finding** | One vulnerability: title, severity, CWE/CVE, description, mitigation, status flags (`active`, `verified`, `false_p`, `risk_accepted`, `is_mitigated`, `duplicate`) and, on CVE findings, EPSS/KEV fields | 3 hand-written, 13 SAST/DAST and hundreds of SCA findings |
| **Location / Endpoint** | Where the finding lives | ZAP: a URL. Semgrep: `app.py` + line. Grype: package + version |
| **Risk Acceptance** | A formal "we accept this risk" record with optional expiry | not exercised here, but core to triaging Low/Info at scale |
| **SLA Configuration** | Per-severity remediation deadlines with breach tracking | attached to every Product by default |

## How it's used

1. **Aggregating automated scans.** A scanner produces a report, and `POST /api/v2/import-scan/` with that
   file and a `scan_type` creates a Test and its Findings in one call. More than
   [180 tools have a built-in parser](https://github.com/DefectDojo/django-DefectDojo/tree/master/dojo/tools).
   Tools without one can use the **Generic Findings Import** format (JSON/CSV).
2. **Reimport.** Re-running a scan uses `reimport-scan`. DefectDojo diffs the new results against the
   existing Test and reports a `delta` (`created` / `closed` / `reactivated` / `untouched`) instead of
   duplicating everything. This is what stops a recurring CI pipeline from flooding the backlog.
3. **Deduplication.** Independently of reimport, DefectDojo also deduplicates *across* tools and tests
   (configurable per product: by hash, or by fields such as CWE + severity + endpoint). When a SAST tool
   and a DAST tool flag the same bug, it is not counted twice.
4. **Triage and remediation.** Findings move through a lifecycle: verify, assign, push to
   Jira/Slack/Azure Boards, risk-accept with a justification and expiry, or mark mitigated. SLA tracking
   runs underneath and flags breaches by severity.
5. **Manual testing.** Pentests and code reviews use the same Engagement/Test model, with findings entered
   by hand instead of imported.
6. **Reporting and metrics.** Product-, engagement- and org-level dashboards show open findings by
   severity and age, SLA compliance, and trends.
7. **The REST API.** Everything above is available at `/api/v2/` with token auth. This repo's scripts and
   tests use that API, and so does any real CI/CD integration. (A v3 API is in alpha upstream; v2 is the
   stable surface used here.)

## Integrations

- **Scanners**: 180+ parsers (Semgrep, Grype, Trivy, Snyk, ZAP, Checkmarx, Nessus, Burp, cloud/IaC
  tools, ...) plus the Generic format as a catch-all.
- **Ticketing/chat**: Jira, Slack, Azure Boards, GitHub/GitLab issues, Microsoft Teams, email.
- **Auth**: local accounts in Community Edition; SSO/SAML/OIDC/LDAP/MFA in Pro.
- **Deployment**: Docker Compose (this repo) or Helm/Kubernetes.

## Community Edition vs. Pro

Everything in this repo runs on the free, self-hosted **Community Edition**: the full data model, REST
API, parser ecosystem, deduplication and SLA tracking. **Pro** (DefectDojo, Inc., SaaS or self-hosted)
adds enterprise auth, managed hosting, extra reporting/compliance features, and a risk-based
prioritization engine. It extends the same core; it is not a fork.

The prioritization engine is the one Pro feature this repo deliberately backfills. Community Edition
already has the EPSS/KEV fields, list columns and filters, but nothing keeps them populated or ranks
findings by them. [Guide 4](04-epss-kev-triage.md) shows how a small API script covers that gap.

## Why it matters

- **One system of record** instead of a dozen scanner dashboards and spreadsheets that disagree.
- **Deduplication turns noisy scanner output into a manageable backlog.** The reimport delta in
  [guide 2](02-deployment.md#6-reimport-to-demonstrate-deduplication) matters as much as the import.
- **Prioritization by real risk.** EPSS/KEV ([guide 4](04-epss-kev-triage.md)) turns hundreds of
  "Highs" into a short, defensible fix-now list.
- **A developer-facing remediation workflow** (Jira/Slack sync, SLA deadlines), not a list only the
  security team reads.
- **An audit trail.** Every import, status change and risk acceptance is timestamped and attributable.
- **A scriptable API**, so it is infrastructure rather than a tool you click around in.

## Where this repo demonstrates each capability

| Capability | Where |
|---|---|
| Stand up DefectDojo and prove the API works | [2. Deployment](02-deployment.md) |
| Product → Engagement → Test → Finding by hand | [2. Deployment → API walkthrough](02-deployment.md#rest-api-walkthrough) |
| Reimport / deduplication | [2. Deployment → step 6](02-deployment.md#6-reimport-to-demonstrate-deduplication) |
| Real SAST + SCA + DAST tools reporting automatically, one engagement per run | [3. Scan pipeline](03-scan-pipeline.md) |
| Risk-based triage with EPSS + CISA KEV on Community Edition | [4. EPSS / KEV triage](04-epss-kev-triage.md) |
| Several projects on one instance | [5. Multi-project tracking](05-multi-project-tracking.md) |
| All of the above, verified automatically | [6. Testing & automation](06-testing.md) |

---

[← README](../README.md) · **1. Overview** · [2. Deployment →](02-deployment.md)
