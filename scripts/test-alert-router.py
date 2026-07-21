#!/usr/bin/env python3
"""Dependency-free regression tests for the in-cluster alert router."""

from __future__ import annotations

import importlib.util
import json
import os
import socket
import subprocess
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
MANIFEST_PATH = ROOT / "observability/kube-prometheus-stack/alert-formatter.yaml"
KUSTOMIZE_LAYER = ROOT / "observability/kube-prometheus-stack"
OBSERVABILITY_APPLICATIONSET = ROOT / "bootstrap/applicationsets/observability.yaml"

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
sys.modules[spec.name] = router
spec.loader.exec_module(router)

PAYLOAD = {
    "receiver": "ntfy-critical",
    "status": "firing",
    "groupKey": '{}:{alertname="DiskFull"}',
    "groupLabels": {"alertname": "DiskFull", "severity": "critical"},
    "commonLabels": {"alertname": "DiskFull", "severity": "critical"},
    "alerts": [
        {
            "status": "firing",
            "labels": {"alertname": "DiskFull", "severity": "critical"},
            "annotations": {"summary": "disk is full"},
            "startsAt": "2026-07-21T01:00:00Z",
            "fingerprint": "alert-fingerprint-1",
        }
    ],
}


class AlertRouterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_dir.cleanup)
        self.ledger = router.DeliveryLedger(
            Path(self.temp_dir.name) / "delivery-ledger.sqlite3"
        )
        self.controls = router.DeliveryControls(
            dedup_window_seconds=300,
            ledger_retention_seconds=3600,
            fallback_max_messages=5,
            fallback_window_seconds=900,
            recovery_successes=3,
            recovery_minimum_seconds=0,
        )

    def deliver(
        self,
        payload: dict[str, object] = PAYLOAD,
        *,
        now: float = 1000,
        controls: object | None = None,
    ) -> str:
        return router._deliver(
            payload,
            "homelab-alerts",
            ledger=self.ledger,
            controls=controls or self.controls,
            now=now,
        )

    def changed_payload(self, suffix: str) -> dict[str, object]:
        payload = json.loads(json.dumps(PAYLOAD))
        payload["alerts"][0]["annotations"]["summary"] += suffix
        return payload

    def http_failure(self, url: str, code: int) -> urllib.error.HTTPError:
        error = urllib.error.HTTPError(url, code, "down", {}, None)
        self.addCleanup(error.close)
        return error

    def test_policy_is_consumed_and_validated(self) -> None:
        _, controls = router._load_policy()
        self.assertEqual(controls.fallback_max_messages, 5)
        self.assertEqual(controls.recovery_successes, 3)

    def test_policy_drift_fails_closed(self) -> None:
        policy = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
        policy["traffic"]["operationalAlert"]["signal"] = "always"
        path = Path(self.temp_dir.name) / "policy.json"
        path.write_text(json.dumps(policy), encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "rejects operationalAlert.signal"):
            router._load_policy(path)

    def test_missing_delivery_control_fails_closed(self) -> None:
        policy = json.loads(POLICY_PATH.read_text(encoding="utf-8"))
        del policy["traffic"]["operationalAlert"]["deliveryControl"]
        path = Path(self.temp_dir.name) / "policy.json"
        path.write_text(json.dumps(policy), encoding="utf-8")
        with self.assertRaisesRegex(RuntimeError, "dedupWindowSeconds"):
            router._load_policy(path)

    def test_manifest_preserves_single_writer_durable_ledger(self) -> None:
        manifest = MANIFEST_PATH.read_text(encoding="utf-8")
        required = (
            "type: Recreate",
            "value: /var/lib/alert-router/delivery-ledger.sqlite3",
            "mountPath: /var/lib/alert-router",
            "claimName: alert-formatter-state",
            "storageClassName: longhorn-replica2-retain",
            'argocd.argoproj.io/sync-wave: "-1"',
            "argocd.argoproj.io/sync-options: Prune=confirm",
            "automountServiceAccountToken: false",
            "path: /readyz",
        )
        for fragment in required:
            with self.subTest(fragment=fragment):
                self.assertIn(fragment, manifest)
        self.assertIn(
            """        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ntfy
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ntfy""",
            manifest,
        )

    def test_final_render_has_clean_recreate_strategy(self) -> None:
        rendered = subprocess.run(
            ["kustomize", "build", "--enable-helm", str(KUSTOMIZE_LAYER)],
            check=True,
            capture_output=True,
            text=True,
            timeout=120,
        ).stdout
        deployment_json = subprocess.run(
            [
                "yq",
                "-o=json",
                "-I=0",
                "select(.kind == \"Deployment\" and "
                ".metadata.name == \"alert-formatter\")",
            ],
            input=rendered,
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout
        deployment = json.loads(deployment_json)
        self.assertEqual(
            deployment["spec"]["strategy"],
            {"type": "Recreate"},
            "steady-state render must not retain transition-only strategy fields",
        )
        annotations = deployment["metadata"].get("annotations", {})
        self.assertNotIn(
            "argocd.argoproj.io/sync-options",
            annotations,
            "steady state must not retain the resource-level sync exception",
        )

    def test_observability_apps_have_no_server_side_diff_exception(self) -> None:
        applicationset = subprocess.run(
            ["yq", "-o=json", "-I=0", ".", str(OBSERVABILITY_APPLICATIONSET)],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        ).stdout
        application_set = json.loads(applicationset)
        self.assertNotIn(
            "templatePatch",
            application_set["spec"],
            "observability apps must no longer receive a generated compare exception",
        )
        self.assertNotIn(
            "ServerSideDiff=false",
            OBSERVABILITY_APPLICATIONSET.read_text(encoding="utf-8"),
            "no generated observability Application may disable server-side diff",
        )

    def test_healthy_ntfy_never_calls_signal(self) -> None:
        with mock.patch.object(
            router, "_request", return_value=b'{"id":"ntfy-id"}'
        ) as request:
            self.assertEqual(self.deliver(), "ntfy")
        self.assertEqual(request.call_count, 1)
        self.assertEqual(
            request.call_args.args[0].full_url, "http://ntfy.test/homelab-alerts"
        )

    def test_exact_retry_is_deduplicated_from_persistent_ledger(self) -> None:
        with mock.patch.object(
            router, "_request", return_value=b'{"id":"ntfy-id"}'
        ) as request:
            self.assertEqual(self.deliver(now=1000), "ntfy")
            self.assertEqual(self.deliver(now=1001), "ntfy-deduplicated")
        self.assertEqual(request.call_count, 1)

        reopened = router.DeliveryLedger(self.ledger.path)
        with mock.patch.object(router, "_request") as request:
            result = router._deliver(
                PAYLOAD,
                "homelab-alerts",
                ledger=reopened,
                controls=self.controls,
                now=1002,
            )
        self.assertEqual(result, "ntfy-deduplicated")
        request.assert_not_called()

    def test_repeat_after_dedup_window_is_delivered_again(self) -> None:
        with mock.patch.object(
            router, "_request", return_value=b'{"id":"ntfy-id"}'
        ) as request:
            self.assertEqual(self.deliver(now=1000), "ntfy")
            self.assertEqual(self.deliver(now=1400), "ntfy")
        self.assertEqual(request.call_count, 2)

    def test_ntfy_http_failure_calls_typed_signal_once(self) -> None:
        failure = self.http_failure("http://ntfy.test", 503)
        with mock.patch.object(
            router, "_request", side_effect=[failure, b""]
        ) as request:
            self.assertEqual(self.deliver(), "signal-fallback")
        self.assertEqual(request.call_count, 2)
        fallback = request.call_args_list[1].args[0]
        self.assertEqual(fallback.full_url, "http://approval.test/v1/alert")
        self.assertEqual(fallback.headers["X-homelab-delivery-mode"], "ntfy-fallback")
        fallback_payload = json.loads(fallback.data)
        summary = fallback_payload["alerts"][0]["annotations"]["summary"]
        self.assertTrue(summary.startswith(router.FALLBACK_PREFIX))
        self.assertIn("ntfy=http_503", summary)
        self.assertIn("first=2026-07-21T01:00:00Z", summary)
        self.assertEqual(
            fallback_payload["homelabFallback"]["type"], "operational-alert"
        )

    def test_deception_uses_fallback_endpoint_only_after_ntfy_failure(self) -> None:
        payload = json.loads(json.dumps(PAYLOAD))
        payload["commonLabels"]["component"] = "deception"
        failure = self.http_failure("http://ntfy.test", 503)
        with mock.patch.object(
            router, "_request", side_effect=[failure, b""]
        ) as request:
            self.deliver(payload)
        self.assertEqual(
            request.call_args_list[1].args[0].full_url,
            "http://approval.test/v1/deception",
        )

    def test_both_explicit_http_failures_request_alertmanager_retry(self) -> None:
        ntfy_failure = self.http_failure("http://ntfy.test", 503)
        signal_failure = self.http_failure("http://approval.test", 502)
        with mock.patch.object(
            router, "_request", side_effect=[ntfy_failure, signal_failure]
        ):
            with self.assertRaises(router.DeliveryError):
                self.deliver()

        # A retained retry starts again at the preferred channel. A transient
        # ntfy rejection must not pin retries to Signal for the dedup window.
        with mock.patch.object(
            router, "_request", return_value=b'{"id":"ntfy-recovered"}'
        ) as request:
            self.assertEqual(self.deliver(now=1001), "ntfy")
        request.assert_called_once()
        self.assertEqual(
            request.call_args.args[0].full_url,
            "http://ntfy.test/homelab-alerts",
        )

    def test_ntfy_timeout_is_persisted_unknown_before_fallback(self) -> None:
        with mock.patch.object(router, "_request", side_effect=[TimeoutError(), b""]):
            self.assertEqual(self.deliver(), "signal-fallback")
        rows = self.ledger.unknown_rows()
        self.assertEqual(len(rows), 1)
        record = self.ledger.get(rows[0]["delivery_key"])
        self.assertEqual(record.primary_status, "delivery_unknown")
        self.assertEqual(record.fallback_status, "acknowledged")

        with mock.patch.object(router, "_request") as request:
            self.assertEqual(self.deliver(now=1002), "signal-fallback-deduplicated")
        request.assert_not_called()

        with mock.patch.object(
            router, "_request", return_value=b'{"id":"repeat"}'
        ) as request:
            self.assertEqual(self.deliver(now=1400), "ntfy")
        request.assert_called_once()

    def test_acknowledged_fallback_bounds_primary_unknown_retention(self) -> None:
        with mock.patch.object(router, "_request", side_effect=[TimeoutError(), b""]):
            self.assertEqual(self.deliver(now=1000), "signal-fallback")
        unknown = self.ledger.unknown_rows()
        self.assertEqual(len(unknown), 1)
        delivery_key = unknown[0]["delivery_key"]

        # Signal acknowledgement makes this alert safe to age out even though
        # the ntfy timeout itself can never be resolved automatically.
        with mock.patch.object(
            router, "_request", return_value=b'{"id":"after-retention"}'
        ):
            self.assertEqual(self.deliver(now=5001), "ntfy")
        with self.assertRaises(KeyError):
            self.ledger.get(delivery_key)

    def test_signal_timeout_stays_unknown_and_is_not_blindly_retried(self) -> None:
        ntfy_failure = self.http_failure("http://ntfy.test", 503)
        with mock.patch.object(
            router, "_request", side_effect=[ntfy_failure, socket.timeout()]
        ):
            with self.assertRaises(router.DeliveryUnknown) as first:
                self.deliver()

        with mock.patch.object(router, "_request") as request:
            with self.assertRaises(router.DeliveryUnknown) as second:
                self.deliver(now=5000)
        self.assertEqual(first.exception.delivery_key, second.exception.delivery_key)
        request.assert_not_called()

        # A still-ambiguous fallback remains pinned even beyond normal ledger
        # retention while unrelated deliveries continue.
        with mock.patch.object(
            router, "_request", return_value=b'{"id":"unrelated"}'
        ):
            self.deliver(self.changed_payload(" unrelated"), now=9001)
        self.assertEqual(
            self.ledger.get(first.exception.delivery_key).fallback_status,
            "delivery_unknown",
        )

    def test_invalid_fallback_payload_never_creates_an_attempt(self) -> None:
        failure = self.http_failure("http://ntfy.test", 503)
        with (
            mock.patch.object(router, "_request", side_effect=[failure]) as request,
            mock.patch.object(
                router, "_fallback_payload", side_effect=ValueError("invalid")
            ),
        ):
            with self.assertRaisesRegex(router.DeliveryError, "payload is invalid"):
                self.deliver()
        request.assert_called_once()
        with self.ledger._read_connection() as connection:
            fallback_attempts = connection.execute(
                "SELECT COUNT(*) FROM attempts WHERE channel = 'signal-fallback'"
            ).fetchone()[0]
        self.assertEqual(fallback_attempts, 0)

    def test_operator_can_reconcile_unknown_without_resending(self) -> None:
        ntfy_failure = self.http_failure("http://ntfy.test", 503)
        with mock.patch.object(
            router, "_request", side_effect=[ntfy_failure, TimeoutError()]
        ):
            with self.assertRaises(router.DeliveryUnknown) as caught:
                self.deliver()
        self.ledger.reconcile(
            caught.exception.delivery_key, "fallback", "acknowledged", 1001
        )
        with mock.patch.object(router, "_request") as request:
            self.assertEqual(self.deliver(now=1002), "signal-fallback-deduplicated")
        request.assert_not_called()

    def test_process_restart_marks_inflight_attempt_unknown(self) -> None:
        record, _ = self.ledger.get_or_create(
            PAYLOAD, "homelab-alerts", 1000, 300, 3600
        )
        self.ledger.begin_attempt(record.delivery_key, "ntfy-primary", 1000)
        reopened = router.DeliveryLedger(self.ledger.path)
        self.assertEqual(reopened.recover_inflight(1001), 1)
        self.assertEqual(
            reopened.get(record.delivery_key).primary_status, "delivery_unknown"
        )

    def test_readiness_proves_write_without_leaving_probe_rows(self) -> None:
        with self.ledger._read_connection() as connection:
            before = connection.execute(
                "SELECT COUNT(*) FROM attempts WHERE channel = 'readiness-probe'"
            ).fetchone()[0]
        self.ledger.ready()
        with self.ledger._read_connection() as connection:
            after = connection.execute(
                "SELECT COUNT(*) FROM attempts WHERE channel = 'readiness-probe'"
            ).fetchone()[0]
        self.assertEqual(after, before)

    def test_fallback_is_deduplicated_and_globally_rate_limited(self) -> None:
        controls = router.DeliveryControls(300, 3600, 1, 900, 3, 0)
        failure_one = self.http_failure("http://ntfy.test", 503)
        failure_two = self.http_failure("http://ntfy.test", 503)
        with mock.patch.object(
            router,
            "_request",
            side_effect=[failure_one, b"", failure_two],
        ) as request:
            self.assertEqual(
                self.deliver(now=1000, controls=controls), "signal-fallback"
            )
            with self.assertRaises(router.DeliveryDeferred):
                self.deliver(
                    self.changed_payload(" again"), now=1001, controls=controls
                )
        self.assertEqual(request.call_count, 3)

        # The rate-limited row is durable but is not treated as delivered.
        # Alertmanager's retained retry rechecks ntfy before considering Signal.
        with mock.patch.object(
            router, "_request", return_value=b'{"id":"ntfy-recovered"}'
        ) as request:
            self.assertEqual(
                self.deliver(
                    self.changed_payload(" again"), now=1002, controls=controls
                ),
                "ntfy",
            )
        request.assert_called_once()

    def test_rate_limited_primary_unknown_never_retries_ntfy_blindly(self) -> None:
        controls = router.DeliveryControls(300, 3600, 1, 900, 3, 0)
        first_failure = self.http_failure("http://ntfy.test", 503)
        with mock.patch.object(
            router, "_request", side_effect=[first_failure, b""]
        ):
            self.assertEqual(
                self.deliver(now=1000, controls=controls), "signal-fallback"
            )

        payload = self.changed_payload(" ambiguous")
        with mock.patch.object(
            router, "_request", side_effect=[TimeoutError()]
        ) as request:
            with self.assertRaises(router.DeliveryDeferred):
                self.deliver(payload, now=1001, controls=controls)
        request.assert_called_once()

        # The primary ambiguity pins the record beyond the normal dedup window.
        # While Signal is still rate-limited, no downstream call is attempted.
        with mock.patch.object(router, "_request") as request:
            with self.assertRaises(router.DeliveryDeferred):
                self.deliver(payload, now=1400, controls=controls)
        request.assert_not_called()

        # Once the Signal window opens, only the backup is attempted; the
        # ambiguous ntfy call is never repeated.
        with mock.patch.object(router, "_request", return_value=b"") as request:
            self.assertEqual(
                self.deliver(payload, now=2001, controls=controls),
                "signal-fallback",
            )
        request.assert_called_once()
        self.assertEqual(
            request.call_args.args[0].full_url,
            "http://approval.test/v1/alert",
        )

    def test_three_primary_successes_close_episode_and_send_one_summary(self) -> None:
        failure = self.http_failure("http://ntfy.test", 503)
        responses = [
            failure,
            b"",
            b'{"id":"one"}',
            b'{"id":"two"}',
            b'{"id":"three"}',
            b"",
        ]
        with mock.patch.object(router, "_request", side_effect=responses) as request:
            self.assertEqual(self.deliver(now=1000), "signal-fallback")
            self.assertEqual(self.deliver(self.changed_payload(" 1"), now=1010), "ntfy")
            self.assertEqual(self.deliver(self.changed_payload(" 2"), now=1020), "ntfy")
            self.assertEqual(self.deliver(self.changed_payload(" 3"), now=1030), "ntfy")
        self.assertEqual(request.call_count, 6)
        recovery = request.call_args_list[-1].args[0]
        self.assertEqual(
            recovery.headers["X-homelab-delivery-mode"], "ntfy-recovery-summary"
        )
        recovery_payload = json.loads(recovery.data)
        self.assertEqual(
            recovery_payload["alerts"][0]["labels"]["alertname"],
            "NtfyDeliveryRecovered",
        )

    def test_unknown_recovery_summary_can_be_reconciled(self) -> None:
        failure = self.http_failure("http://ntfy.test", 503)
        responses = [
            failure,
            b"",
            b'{"id":"one"}',
            b'{"id":"two"}',
            b'{"id":"three"}',
            TimeoutError(),
        ]
        with mock.patch.object(router, "_request", side_effect=responses):
            self.assertEqual(self.deliver(now=1000), "signal-fallback")
            self.assertEqual(
                self.deliver(self.changed_payload(" 1"), now=1010), "ntfy"
            )
            self.assertEqual(
                self.deliver(self.changed_payload(" 2"), now=1020), "ntfy"
            )
            self.assertEqual(
                self.deliver(self.changed_payload(" 3"), now=1030), "ntfy"
            )

        rows = self.ledger.unknown_recovery_summaries()
        self.assertEqual(len(rows), 1)
        self.ledger.reconcile_recovery_summary(
            int(rows[0]["episode_id"]), "acknowledged", 1040
        )
        self.assertEqual(self.ledger.unknown_recovery_summaries(), [])

    def test_fallback_strips_approval_capability_fields(self) -> None:
        payload = json.loads(json.dumps(PAYLOAD))
        payload["approvalCommandId"] = "dangerous-id"
        payload["alerts"][0]["labels"]["replyToken"] = "secret"
        payload["alerts"][0]["annotations"]["commandDigest"] = "digest"
        marked = router._fallback_payload(payload, "fingerprint", "http_503", 1000)
        encoded = json.dumps(marked).lower()
        self.assertNotIn("approval", encoded)
        self.assertNotIn("command", encoded)
        self.assertNotIn("digest", encoded)
        self.assertNotIn("reply", encoded)
        self.assertNotIn("dangerous-id", encoded)
        self.assertEqual(payload["approvalCommandId"], "dangerous-id")

    def test_arbitrary_topic_is_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "topic is not allowed"):
            router._deliver(
                PAYLOAD,
                "attacker-selected-topic",
                ledger=self.ledger,
                controls=self.controls,
                now=1000,
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
