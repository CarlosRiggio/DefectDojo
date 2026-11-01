# What is DefectDojo?

[DefectDojo](https://github.com/DefectDojo/django-DefectDojo) is an open-source **Application Security
Posture Management (ASPM)** platform — a single system of record for every security finding an
organization produces, regardless of which tool found it. It started as an OWASP Flagship project
(maintained by Greg Anderson and Matt Tesauro) and is now developed as an open-source Community Edition
alongside a commercial Pro offering (DefectDojo, Inc.) that adds SSO/SAML/OIDC/LDAP/MFA and managed
hosting on top of the same open-source core. This repo runs the Community Edition.

The problem DefectDojo solves: a typical AppSec program runs a dozen different scanners (SAST, DAST, SCA,
container, infra, manual pentest) that each produce their own report format, their own severity scale,
and their own idea of what counts as a duplicate. Without a layer on top, findings live scattered across
Jira tickets, spreadsheets, and tool dashboards that never agree with each other. DefectDojo normalizes
all of it into one data model, de-duplicates across scans and across tools, and gives every finding a
lifecycle (new → verified → risk-accepted / mitigated → closed) that both developers and security teams
actually use.

---

## Core data model (the "elements")

```
Product Type
  └── Product                    (an application / service)
        └── Engagement           (a time-boxed round of testing: a sprint, a pentest, a CI pipeline)
              └── Test           (one scan or one manual test within that engagement)
                    └── Finding  (one vulnerability — severity, CWE/CVE, status, location)
                          └── Location / Endpoint   (where it lives: URL, file+line, package)
                          └── Risk Acceptance        (formally accepted instead of fixed)
                          └── Notes / Tags           (triage history, context)
```

| Element | What it represents | Example from this repo |
|---|---|---|
| **Product Type** | A grouping of products (e.g. "Internal Tools", "Customer-Facing") | `prod_type: 1`, the default created on first boot |
| **Product** | One application being tracked | `DefectDojo POC Product` ([`deployment/`](../deployment/)), `Sample Flask App` ([`sample-app/`](../sample-app/)) |
| **Engagement** | A bounded round of testing — manual pentest, a sprint, or (as here) one CI run | `POC Engagement`, `Automated Scan - <timestamp>` |
| **Test** | One scan or manual assessment inside an engagement, tied to a scan type | the Generic Findings import, the Semgrep import, the ZAP import — each is its own Test |
| **Finding** | One vulnerability: title, severity, CWE, description, mitigation, status flags (`active`, `verified`, `false_p`, `risk_accepted`, `is_mitigated`, `duplicate`) | all 16 findings created across both parts of this repo |
| **Location / Endpoint** | Where the finding actually lives — a URL (DAST), a file+line (SAST), or a package+version (SCA) | ZAP findings carry the URL; Semgrep findings carry `app.py` + line number |
| **Risk Acceptance** | A formal "we know, we're accepting this risk" record instead of a fix, with optional expiration | not exercised in this POC, but core to how teams triage Low/Info findings at scale |
| **SLA Configuration** | Per-severity remediation deadlines (e.g. Critical in 7 days) with automatic breach tracking/notifications | attached to every Product by default |

---

## How it's actually used

**1. Aggregating automated scans (what [`sample-app/`](../sample-app/) demonstrates).**
A scanner (SAST, DAST, SCA, container, IaC — [180+ tools have a built-in parser](https://github.com/DefectDojo/django-DefectDojo/tree/master/dojo/tools)) produces a report. A `POST /api/v2/import-scan/` call
with that file and a `scan_type` creates a Test and its Findings in one call. Re-running the same scan
later uses `reimport-scan` instead: DefectDojo diffs the new results against the existing Test and
reports a `delta` of `created` / `closed` / `reactivated` / `untouched` findings rather than duplicating
everything — this is what keeps a recurring CI pipeline from flooding the findings list on every build.
If a scanner has no dedicated parser, the **Generic Findings Import** format (JSON or CSV) accepts
arbitrary findings — what [`deployment/samples/generic-findings-sample.json`](../deployment/samples/generic-findings-sample.json) uses.

**2. Deduplication.** Independently of reimport, DefectDojo also deduplicates *across* different tools
and different tests on the same Engagement (configurable per-product: by hash, or by specific fields like
CWE + severity + endpoint). This is what lets a SAST tool and a DAST tool both flag the same underlying
bug without it counting twice in a report.

**3. Triage and remediation.** Each Finding has a status lifecycle developers and AppSec teams work
through: mark verified, assign an owner, push to Jira/Slack/Azure Boards, risk-accept with a justification
and expiry, or mark mitigated once fixed. SLA tracking runs underneath all of it, flagging breaches by
severity.

**4. Manual testing.** Not everything is a scanner. Engagements and Tests work the same way for a human
pentester or a manual code review — findings are entered directly rather than imported, going through the
identical lifecycle.

**5. Reporting and metrics.** Product-, engagement-, and org-level dashboards track open findings by
severity/age, SLA compliance, and trends over time — the material a security team shows leadership or an
auditor.

**6. The REST API.** Everything above is reachable at `/api/v2/` with token auth — the same surface this
repo's [`deployment/README.md`](../deployment/README.md) walkthrough and [`sample-app/scan-and-report.sh`](../sample-app/scan-and-report.sh)
both drive. This is also what any real CI/CD pipeline integration uses in production. (A v3 API is in
alpha upstream as of this writing; v2 is the stable, documented surface and what this repo uses throughout.)

---

## Integrations and extensibility

- **Scanner ecosystem**: 180+ parsers out of the box (Semgrep, Trivy, Snyk, ZAP, Checkmarx, Nessus,
  Burp, npm/pip audit tools, cloud/IaC scanners, and more), plus the Generic format as a catch-all.
- **Ticketing/chat**: Jira, Slack, Azure Boards, GitHub/GitLab issues, Microsoft Teams, email — findings
  can push out and sync status back.
- **Auth**: local accounts in Community Edition; SSO/SAML/OIDC/LDAP/MFA in Pro.
- **Deployment**: Docker Compose (this repo) or Helm/Kubernetes for production scale.

## Open Source vs. Pro

Everything demonstrated in this repo runs on the free, self-hosted **Community Edition** — the full data
model, the full REST API, the full scanner/parser ecosystem, deduplication, and SLA tracking are all open
source. **Pro** (DefectDojo, Inc., SaaS or self-hosted, from ~$100/mo) layers on enterprise auth (SSO,
SAML, OIDC, LDAP, MFA), managed hosting, and additional reporting/compliance features — it's an
enhancement on the same core, not a fork.

---

## Why this matters (the utility)

- **One system of record** instead of a dozen scanner dashboards and spreadsheets that disagree with
  each other.
- **Deduplication turns noisy scanner output into a manageable backlog** — the same reason the reimport
  delta in [`deployment/README.md`](../deployment/README.md) matters as much as the import itself.
- **Developer-facing remediation workflow** (Jira/Slack sync, SLA deadlines) instead of findings that
  only security people ever look at.
- **Audit/compliance evidence trail** — every import, status change, and risk acceptance is timestamped
  and attributable.
- **A scriptable API** means it's infrastructure, not a tool you click around in — exactly what
  [`sample-app/scan-and-report.sh`](../sample-app/scan-and-report.sh) exercises end-to-end in this repo.

## How this repo demonstrates it, end to end

| Capability | Where |
|---|---|
| Stand up DefectDojo itself, prove the API works | [`deployment/`](../deployment/) |
| Product → Engagement → Test → Finding data model, by hand | [`deployment/README.md`](../deployment/README.md) walkthrough |
| Reimport / deduplication behavior | [`deployment/README.md`](../deployment/README.md) step 6 |
| Real SAST + DAST tools reporting automatically | [`sample-app/`](../sample-app/) |
| One engagement per pipeline run, CI-shaped automation | [`sample-app/scan-and-report.sh`](../sample-app/scan-and-report.sh) |
