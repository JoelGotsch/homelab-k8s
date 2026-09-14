#!/usr/bin/env python3
"""test-hubble-redaction.py — the redaction guard can go red.

Mutates the real infrastructure/cilium/values.yaml in memory and asserts
check-hubble-redaction.py rejects each unsafe shape (hl-0315).
"""
import copy
import importlib.util
import unittest
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("guard", HERE / "check-hubble-redaction.py")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
REAL = yaml.safe_load((HERE.parent / "infrastructure/cilium/values.yaml").read_text())


class RedactionGuard(unittest.TestCase):
    def mutated(self, fn):
        v = copy.deepcopy(REAL)
        fn(v)
        return guard.check(v)

    def test_real_values_pass(self):
        self.assertEqual(guard.check(REAL), [])

    def test_real_values_actually_export(self):
        # Otherwise the pass above proves nothing.
        self.assertIs(REAL["hubble"]["export"]["static"]["enabled"], True)

    def test_redact_removed_fails(self):
        self.assertTrue(self.mutated(lambda v: v["hubble"].pop("redact")))

    def test_redact_disabled_fails(self):
        self.assertTrue(self.mutated(lambda v: v["hubble"]["redact"].__setitem__("enabled", False)))

    def test_urlquery_off_fails(self):
        self.assertTrue(self.mutated(lambda v: v["hubble"]["redact"]["http"].__setitem__("urlQuery", False)))

    def test_empty_allow_list_fails(self):
        self.assertTrue(self.mutated(lambda v: v["hubble"]["redact"]["http"]["headers"].__setitem__("allow", [])))

    def test_deny_list_instead_fails(self):
        def m(v):
            v["hubble"]["redact"]["http"]["headers"] = {"deny": ["Authorization"]}
        self.assertTrue(self.mutated(m))

    def test_authorization_in_allow_list_fails(self):
        self.assertTrue(self.mutated(
            lambda v: v["hubble"]["redact"]["http"]["headers"]["allow"].append("Authorization")))

    def test_raw_export_path_without_redact_fails(self):
        def m(v):
            v["hubble"].pop("redact")
            v["hubble"]["export"]["static"]["enabled"] = False
            v.setdefault("extraConfig", {})["hubble-export-file-path"] = "/var/run/cilium/hubble/events.log"
        self.assertTrue(self.mutated(m))

    def test_no_export_needs_no_redact(self):
        def m(v):
            v["hubble"].pop("redact")
            v["hubble"]["export"]["static"]["enabled"] = False
            v.get("extraConfig", {}).pop("hubble-export-file-path", None)
        self.assertEqual(self.mutated(m), [])


if __name__ == "__main__":
    unittest.main()
