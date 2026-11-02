#!/usr/bin/env python3
"""
EPSS + CISA KEV enrichment for DefectDojo Community Edition.

DefectDojo (Community and Pro) has EPSS/KEV fields on every Finding
(epss_score, epss_percentile, known_exploited, ransomware_used, kev_date),
but only Pro keeps them populated automatically. This script does that job
for Community Edition, via the REST API:

  1. Pulls active findings from DefectDojo (optionally scoped to one product)
     and collects their CVE IDs (from `vulnerability_ids`).
  2. Downloads the CISA KEV catalog and looks up EPSS scores at FIRST.org.
  3. PATCHes each CVE-bearing finding with fresh EPSS/KEV values (clearing
     stale KEV values if a CVE has dropped off the catalog).
  4. Assigns a triage tier and tags it, because Community Edition has no
     Priority field (Pro does). Severity is never touched: severity is
     impact, EPSS/KEV is likelihood - they stay separate signals.

Triage tiers (thresholds are flags):
  priority-p0  Known exploited (in CISA KEV)                     -> fix now
  priority-p1  EPSS >= --epss-threshold AND severity High/Critical -> urgent
  priority-p2  EPSS >= --epss-threshold OR severity High/Critical  -> planned
  priority-p3  everything else with a CVE                          -> backlog
Plus signal tags: `kev`, `kev-ransomware`, `epss-high`.

Multi-CVE findings follow the same rule as DefectDojo Pro: highest EPSS score
(paired with that same CVE's percentile), KEV if any CVE is listed,
ransomware if any CVE is ransomware-linked, earliest KEV date.

Standard library only - no pip install needed. Reads DD_URL / DD_USERNAME /
DD_PASSWORD from the environment (scan-and-report.sh sources sample-app/.env).

Usage:
  python3 enrich-epss-kev.py                    # whole instance
  python3 enrich-epss-kev.py --product-id 2     # one product
  python3 enrich-epss-kev.py --dry-run          # show what would change
"""

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date

KEV_URL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
EPSS_URL = "https://api.first.org/data/v1/epss"
EPSS_BATCH = 100  # FIRST API page limit
CVE_RE = re.compile(r"^CVE-\d{4}-\d{4,}$", re.IGNORECASE)
HIGH_SEVERITIES = {"Critical", "High"}

# Tags this script owns. Anything else on a finding is left untouched.
MANAGED_TAGS = {"kev", "kev-ransomware", "epss-high",
                "priority-p0", "priority-p1", "priority-p2", "priority-p3"}


# --- HTTP helpers ------------------------------------------------------------

def http_json(url, method="GET", headers=None, body=None, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    if data is not None:
        req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "dd-poc-epss-kev-enricher/1.0")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.load(resp)


class DefectDojo:
    def __init__(self, url, username, password):
        self.url = url.rstrip("/")
        token = http_json(f"{self.url}/api/v2/api-token-auth/", "POST",
                          body={"username": username, "password": password})["token"]
        self.headers = {"Authorization": f"Token {token}"}

    def findings(self, product_id=None):
        params = {"active": "true", "limit": 250}
        if product_id:
            params["test__engagement__product"] = product_id
        url = f"{self.url}/api/v2/findings/?{urllib.parse.urlencode(params)}"
        while url:
            page = http_json(url, headers=self.headers)
            yield from page["results"]
            url = page.get("next")

    def patch_finding(self, finding_id, fields):
        return http_json(f"{self.url}/api/v2/findings/{finding_id}/", "PATCH",
                         headers=self.headers, body=fields)


# --- Threat-intel feeds --------------------------------------------------------

def load_kev():
    feed = http_json(KEV_URL)
    kev = {}
    for v in feed["vulnerabilities"]:
        kev[v["cveID"].upper()] = {
            "date_added": v.get("dateAdded"),
            "due_date": v.get("dueDate"),
            "ransomware": v.get("knownRansomwareCampaignUse", "").lower() == "known",
        }
    return feed.get("catalogVersion"), kev


def load_epss(cves):
    epss = {}
    cves = sorted(cves)
    for i in range(0, len(cves), EPSS_BATCH):
        batch = cves[i:i + EPSS_BATCH]
        url = f"{EPSS_URL}?{urllib.parse.urlencode({'cve': ','.join(batch), 'limit': EPSS_BATCH})}"
        for row in http_json(url).get("data", []):
            epss[row["cve"].upper()] = (float(row["epss"]), float(row["percentile"]))
    return epss


# --- Enrichment logic ----------------------------------------------------------

def finding_cves(finding):
    ids = [v.get("vulnerability_id", "") for v in finding.get("vulnerability_ids") or []]
    return sorted({i.upper() for i in ids if CVE_RE.match(i or "")})


def compute(cves, kev, epss):
    """Combine per-CVE intel into one set of finding values (Pro's rules)."""
    best = max((epss[c] for c in cves if c in epss), default=(None, None), key=lambda t: t[0])
    kev_hits = [kev[c] for c in cves if c in kev]
    kev_dates = sorted(h["date_added"] for h in kev_hits if h["date_added"])
    due_dates = sorted(h["due_date"] for h in kev_hits if h["due_date"])
    return {
        "epss_score": best[0],
        "epss_percentile": best[1],
        "known_exploited": bool(kev_hits),
        "ransomware_used": any(h["ransomware"] for h in kev_hits),
        "kev_date": kev_dates[0] if kev_dates else None,
    }, (due_dates[0] if due_dates else None)


def tier(values, severity, epss_threshold):
    high_sev = severity in HIGH_SEVERITIES
    high_epss = (values["epss_score"] or 0) >= epss_threshold
    if values["known_exploited"]:
        return "priority-p0"
    if high_epss and high_sev:
        return "priority-p1"
    if high_epss or high_sev:
        return "priority-p2"
    return "priority-p3"


def tags_for(values, priority, epss_threshold):
    tags = {priority}
    if values["known_exploited"]:
        tags.add("kev")
    if values["ransomware_used"]:
        tags.add("kev-ransomware")
    if (values["epss_score"] or 0) >= epss_threshold:
        tags.add("epss-high")
    return tags


def same_float(a, b):
    if a is None or b is None:
        return a is b
    return abs(a - b) < 1e-9


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--product-id", type=int, help="only enrich findings of this product")
    ap.add_argument("--epss-threshold", type=float, default=0.1,
                    help="EPSS probability counted as 'high' (default 0.1 = 10%%)")
    ap.add_argument("--dry-run", action="store_true", help="compute and print, but do not PATCH")
    ap.add_argument("--top", type=int, default=20, help="rows of the triage table to print (0 = all)")
    args = ap.parse_args()

    for var in ("DD_URL", "DD_USERNAME", "DD_PASSWORD"):
        if not os.environ.get(var):
            sys.exit(f"Missing {var} in environment (source sample-app/.env first)")

    dd = DefectDojo(os.environ["DD_URL"], os.environ["DD_USERNAME"], os.environ["DD_PASSWORD"])
    findings = list(dd.findings(args.product_id))
    with_cve = [(f, finding_cves(f)) for f in findings]
    with_cve = [(f, c) for f, c in with_cve if c]
    all_cves = {c for _, cves in with_cve for c in cves}
    print(f"Active findings: {len(findings)} ({len(with_cve)} with a CVE, "
          f"{len(all_cves)} distinct CVEs; findings without a CVE cannot be enriched)")
    if not with_cve:
        return

    catalog_version, kev = load_kev()
    epss = load_epss(all_cves)
    print(f"CISA KEV catalog {catalog_version}: {len(kev)} entries | "
          f"EPSS scores returned for {len(epss)}/{len(all_cves)} CVEs")

    counts = {t: 0 for t in ("priority-p0", "priority-p1", "priority-p2", "priority-p3")}
    patched = 0
    rows = []
    for f, cves in with_cve:
        values, kev_due = compute(cves, kev, epss)
        priority = tier(values, f["severity"], args.epss_threshold)
        counts[priority] += 1

        current_tags = set(f.get("tags") or [])
        new_tags = (current_tags - MANAGED_TAGS) | tags_for(values, priority, args.epss_threshold)

        changes = {}
        for k in ("epss_score", "epss_percentile"):
            if not same_float(f.get(k), values[k]):
                changes[k] = values[k]
        for k in ("known_exploited", "ransomware_used", "kev_date"):
            if f.get(k) != values[k]:
                changes[k] = values[k]
        if new_tags != current_tags:
            changes["tags"] = sorted(new_tags)

        rows.append((priority, f, cves, values, kev_due))
        if changes and not args.dry_run:
            dd.patch_finding(f["id"], changes)
            patched += 1

    # Report, most urgent first.
    rows.sort(key=lambda r: (r[0], -(r[3]["epss_score"] or 0)))
    shown = rows if args.top == 0 else rows[:args.top]
    print(f"\nTop {len(shown)} of {len(rows)} CVE-bearing findings, most urgent first:")
    print(f"{'Tier':<4} {'ID':>5}  {'Severity':<8} {'EPSS':>7} {'Pctl':>6}  {'KEV':<3} {'Ransom':<6} CVE(s) / title")
    for priority, f, cves, v, kev_due in shown:
        epss_s = f"{v['epss_score']:.2%}" if v["epss_score"] is not None else "-"
        pct_s = f"{v['epss_percentile']:.2f}" if v["epss_percentile"] is not None else "-"
        due = f"  [CISA due {kev_due}]" if kev_due else ""
        print(f"{priority[-2:].upper():<4} {f['id']:>5}  {f['severity']:<8} {epss_s:>7} {pct_s:>6}  "
              f"{'yes' if v['known_exploited'] else 'no':<3} {'yes' if v['ransomware_used'] else 'no':<6} "
              f"{','.join(cves)} - {f['title'][:60]}{due}")

    print("\nTier summary: " + "  ".join(f"{k[-2:].upper()}={n}" for k, n in counts.items()))
    if args.dry_run:
        print("Dry run: no findings were modified.")
    else:
        print(f"Findings updated: {patched} (unchanged: {len(with_cve) - patched})")
    print(f"Enrichment date: {date.today().isoformat()}")


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as e:
        sys.exit(f"HTTP {e.code} from {e.url}: {e.read()[:500].decode(errors='replace')}")
    except urllib.error.URLError as e:
        sys.exit(f"Network error: {e.reason}")
