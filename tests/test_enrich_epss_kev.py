"""
Unit tests for the pure logic in sample-app/enrich-epss-kev.py: how per-CVE
EPSS/KEV data is combined into one finding, how tiers are assigned, and how
tags are produced. No network, no DefectDojo needed.

Run: make test-unit   (or: python3 -m unittest discover -s tests -v)
"""

import importlib.util
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "sample-app" / "enrich-epss-kev.py"
spec = importlib.util.spec_from_file_location("enrich_epss_kev", SCRIPT)
enrich = importlib.util.module_from_spec(spec)
spec.loader.exec_module(enrich)

KEV = {
    "CVE-2023-4911": {"date_added": "2023-11-21", "due_date": "2023-12-12", "ransomware": False},
    "CVE-2021-44228": {"date_added": "2021-12-10", "due_date": "2021-12-24", "ransomware": True},
}
EPSS = {
    "CVE-2023-4911": (0.63769, 0.99221),
    "CVE-2021-44228": (0.99999, 1.0),
    "CVE-2024-0001": (0.002, 0.10),
    "CVE-2024-0002": (0.35, 0.97),
}


class FindingCves(unittest.TestCase):
    def test_keeps_only_cve_ids_deduplicated_and_uppercased(self):
        finding = {"vulnerability_ids": [
            {"vulnerability_id": "cve-2023-4911"},
            {"vulnerability_id": "CVE-2023-4911"},
            {"vulnerability_id": "GHSA-xxxx-yyyy-zzzz"},
            {"vulnerability_id": ""},
        ]}
        self.assertEqual(enrich.finding_cves(finding), ["CVE-2023-4911"])

    def test_no_vulnerability_ids(self):
        self.assertEqual(enrich.finding_cves({"vulnerability_ids": None}), [])
        self.assertEqual(enrich.finding_cves({}), [])


class Compute(unittest.TestCase):
    def test_single_kev_cve(self):
        values, due = enrich.compute(["CVE-2023-4911"], KEV, EPSS)
        self.assertEqual(values, {
            "epss_score": 0.63769, "epss_percentile": 0.99221,
            "known_exploited": True, "ransomware_used": False, "kev_date": "2023-11-21",
        })
        self.assertEqual(due, "2023-12-12")

    def test_multi_cve_takes_highest_epss_with_its_own_percentile(self):
        values, _ = enrich.compute(["CVE-2024-0001", "CVE-2024-0002"], KEV, EPSS)
        self.assertEqual((values["epss_score"], values["epss_percentile"]), (0.35, 0.97))

    def test_multi_cve_kev_any_ransomware_any_earliest_date(self):
        values, due = enrich.compute(["CVE-2023-4911", "CVE-2021-44228"], KEV, EPSS)
        self.assertTrue(values["known_exploited"])
        self.assertTrue(values["ransomware_used"])
        self.assertEqual(values["kev_date"], "2021-12-10")
        self.assertEqual(due, "2021-12-24")

    def test_unknown_cve_clears_everything(self):
        values, due = enrich.compute(["CVE-2099-9999"], KEV, EPSS)
        self.assertEqual(values, {
            "epss_score": None, "epss_percentile": None,
            "known_exploited": False, "ransomware_used": False, "kev_date": None,
        })
        self.assertIsNone(due)


class Tier(unittest.TestCase):
    def v(self, epss=None, kev=False):
        return {"epss_score": epss, "known_exploited": kev}

    def test_kev_is_p0_regardless_of_severity_or_epss(self):
        self.assertEqual(enrich.tier(self.v(0.0001, kev=True), "Low", 0.1), "priority-p0")

    def test_high_epss_and_high_severity_is_p1(self):
        self.assertEqual(enrich.tier(self.v(0.5), "Critical", 0.1), "priority-p1")
        self.assertEqual(enrich.tier(self.v(0.1), "High", 0.1), "priority-p1")  # threshold inclusive

    def test_either_signal_alone_is_p2(self):
        self.assertEqual(enrich.tier(self.v(0.5), "Medium", 0.1), "priority-p2")
        self.assertEqual(enrich.tier(self.v(0.01), "High", 0.1), "priority-p2")
        self.assertEqual(enrich.tier(self.v(None), "Critical", 0.1), "priority-p2")

    def test_neither_signal_is_p3(self):
        self.assertEqual(enrich.tier(self.v(0.01), "Medium", 0.1), "priority-p3")
        self.assertEqual(enrich.tier(self.v(None), "Info", 0.1), "priority-p3")

    def test_threshold_is_configurable(self):
        self.assertEqual(enrich.tier(self.v(0.05), "High", 0.05), "priority-p1")
        self.assertEqual(enrich.tier(self.v(0.05), "High", 0.5), "priority-p2")


class Tags(unittest.TestCase):
    def test_signal_tags(self):
        values = {"epss_score": 0.7, "known_exploited": True, "ransomware_used": True}
        self.assertEqual(enrich.tags_for(values, "priority-p0", 0.1),
                         {"priority-p0", "kev", "kev-ransomware", "epss-high"})

    def test_quiet_finding_gets_only_its_tier(self):
        values = {"epss_score": None, "known_exploited": False, "ransomware_used": False}
        self.assertEqual(enrich.tags_for(values, "priority-p3", 0.1), {"priority-p3"})

    def test_every_generated_tag_is_managed(self):
        # Anything the script emits must be in MANAGED_TAGS, or re-runs would
        # never remove it when a finding changes tier.
        values = {"epss_score": 1.0, "known_exploited": True, "ransomware_used": True}
        for t in ("priority-p0", "priority-p1", "priority-p2", "priority-p3"):
            self.assertLessEqual(enrich.tags_for(values, t, 0.1), enrich.MANAGED_TAGS)


class SameFloat(unittest.TestCase):
    def test_comparisons(self):
        self.assertTrue(enrich.same_float(None, None))
        self.assertFalse(enrich.same_float(None, 0.0))
        self.assertTrue(enrich.same_float(0.63769, 0.63769 + 1e-12))
        self.assertFalse(enrich.same_float(0.5, 0.6))


if __name__ == "__main__":
    unittest.main()
