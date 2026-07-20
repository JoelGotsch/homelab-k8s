#!/usr/bin/env python3
"""Dependency-free regression tests for the in-cluster alert router."""

from __future__ import annotations

import importlib.util
import json
import os
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
ROUTER_PATH = ROOT / "observability/kube-prometheus-stack/alert_router.py"
POLICY_PATH = (
    ROOT / "observability/kube-prometheus-stack/notification-channel-policy.json"
)

os.environ.update(
    {
        "NTFY_BASE_URL": "http://ntfy.test",
        "NTFY_TOKEN": "ntfy-test-token",
        "SIGNAL_FALLBACK_BASE_URL": "http://approval.test",
        "SIGNAL_FALLBACK_TOKEN": "signal-test-token",
        "NOTIFICATION_CHANNEL_POLICY_PATH": str(POLICY_PATH),
    }
)
sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("alert_router", ROUTER_PATH)
assert spec and spec.loader
router = importlib.util.module_from_spec(spec)
spec.loader.exec_module(router)

PAYLOAD = {
    "status": "firing",
    "groupLabels": {"alertname": "DiskFull", "severity": "critical"},
    "commonLabels": {"alertname": "DiskFull", "severity": "critical"},
    "alerts": [
        {
            "labels": {"alertname": "DiskFull", "severity": "critical"},
            "annotations": {"summary": "disk is full"},
        }
    ],
}


class AlertRouterTests(unittest.TestCase):
    def test_policy_is_consumed_and_validated(self) -> None:
        router._validate_config()

    def test_policy_drift_fails_closed(self) -> None:
        policy = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
        policy["traffic"]["operationalAlert"]["signal"] = "always"
        with tempfile.TemporaryDirectory() as temp_dir:
            path = Path(temp_dir) / "policy.json"
            path.write_text(json.dumps(policy), encoding="utf-8")
            with self.assertRaisesRegex(
                RuntimeError, "rejects operationalAlert.signal"
            ):
                router._load_policy(path)

    def test_healthy_ntfy_never_calls_signal(self) -> None:
        with mock.patch.object(router, "_request") as request:
            self.assertEqual(router._deliver(PAYLOAD, "homelab-alerts"), "ntfy")
        self.assertEqual(request.call_count, 1)
        self.assertEqual(
            request.call_args.args[0].full_url, "http://ntfy.test/homelab-alerts"
        )

    def test_ntfy_http_failure_calls_signal_once(self) -> None:
        failure = urllib.error.HTTPError("http://ntfy.test", 503, "down", {}, None)
        with mock.patch.object(
            router, "_request", side_effect=[failure, None]
        ) as request:
            self.assertEqual(
                router._deliver(PAYLOAD, "homelab-alerts"),
                "signal-fallback",
            )
        self.assertEqual(request.call_count, 2)
        fallback = request.call_args_list[1].args[0]
        self.assertEqual(fallback.full_url, "http://approval.test/v1/alert")
        self.assertEqual(fallback.headers["X-homelab-delivery-mode"], "ntfy-fallback")
        fallback_payload = json.loads(fallback.data)
        self.assertTrue(
            fallback_payload["alerts"][0]["annotations"]["summary"].startswith(
                router.FALLBACK_PREFIX
            )
        )

    def test_deception_uses_fallback_endpoint_only_after_ntfy_failure(self) -> None:
        payload = json.loads(json.dumps(PAYLOAD))
        payload["commonLabels"]["component"] = "deception"
        with mock.patch.object(
            router, "_request", side_effect=[OSError("down"), None]
        ) as request:
            router._deliver(payload, "homelab-alerts")
        self.assertEqual(
            request.call_args_list[1].args[0].full_url,
            "http://approval.test/v1/deception",
        )

    def test_both_channels_failing_requests_alertmanager_retry(self) -> None:
        with mock.patch.object(router, "_request", side_effect=OSError("down")):
            with self.assertRaises(router.DeliveryError):
                router._deliver(PAYLOAD, "homelab-alerts")

    def test_arbitrary_topic_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "topic is not allowed"):
            router._deliver(PAYLOAD, "attacker-selected-topic")

    def test_fallback_does_not_mutate_original_payload(self) -> None:
        original = json.dumps(PAYLOAD, sort_keys=True)
        marked = router._fallback_payload(PAYLOAD)
        self.assertEqual(json.dumps(PAYLOAD, sort_keys=True), original)
        self.assertTrue(
            marked["alerts"][0]["annotations"]["summary"].startswith(
                router.FALLBACK_PREFIX
            )
        )
        self.assertNotIn("approval", json.dumps(marked).lower())


if __name__ == "__main__":
    unittest.main(verbosity=2)
