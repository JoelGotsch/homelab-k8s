"""Alertmanager webhook adapter with ntfy-primary, Signal-fallback delivery.

This module is mounted into the in-cluster alert-formatter Deployment.  It uses
only the Python standard library so the deployment does not require a custom
image.  Delivery has one owner:

1. publish the readable alert to ntfy;
2. only when that synchronous publish fails, forward the original Alertmanager
   batch to approval-channel's one-way alert endpoint;
3. return success when either path acknowledges the request, otherwise return
   502 so Alertmanager retains and retries the notification.

Signal fallback never creates or mutates approval state.  The channel contract
is loaded from notification-channel-policy.json at startup and fails closed if
the expected operational-alert policy is absent.
"""

from __future__ import annotations

import copy
import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

NTFY_BASE_URL = os.environ.get("NTFY_BASE_URL", "").rstrip("/")
NTFY_TOKEN = os.environ.get("NTFY_TOKEN", "")
SIGNAL_FALLBACK_BASE_URL = os.environ.get("SIGNAL_FALLBACK_BASE_URL", "").rstrip("/")
SIGNAL_FALLBACK_TOKEN = os.environ.get("SIGNAL_FALLBACK_TOKEN", "")
POLICY_PATH = Path(
    os.environ.get(
        "NOTIFICATION_CHANNEL_POLICY_PATH",
        "/app/notification-channel-policy.json",
    )
)

ALLOWED_TOPICS = frozenset({"homelab-alerts", "homelab-alerts-warning"})
PRIORITY = {"critical": "5", "warning": "3", "info": "2"}
FALLBACK_PREFIX = "ALERT FALLBACK — ntfy publish failed; "


class DeliveryError(RuntimeError):
    """Neither the primary nor fallback channel acknowledged delivery."""


def _load_policy(path: Path = POLICY_PATH) -> dict[str, Any]:
    try:
        policy = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise RuntimeError(f"notification channel policy is unreadable: {exc}") from exc

    operational = policy.get("traffic", {}).get("operationalAlert", {})
    expected = {
        "primary": "ntfy",
        "signal": "conditional-fallback-only",
        "fallbackEvidence": "synchronous-ntfy-publish-error",
        "approvalStateAccess": "forbidden",
    }
    for key, value in expected.items():
        if operational.get(key) != value:
            raise RuntimeError(
                f"notification channel policy rejects operationalAlert.{key}: "
                f"expected {value!r}"
            )
    return policy


def _validate_config() -> None:
    missing = [
        name
        for name, value in (
            ("NTFY_BASE_URL", NTFY_BASE_URL),
            ("NTFY_TOKEN", NTFY_TOKEN),
            ("SIGNAL_FALLBACK_BASE_URL", SIGNAL_FALLBACK_BASE_URL),
            ("SIGNAL_FALLBACK_TOKEN", SIGNAL_FALLBACK_TOKEN),
        )
        if not value
    ]
    if missing:
        raise RuntimeError(f"missing required configuration: {', '.join(missing)}")
    _load_policy()


def _tag(status: str, severity: str | None) -> str:
    if status == "resolved":
        return "white_check_mark"
    return {
        "critical": "rotating_light",
        "warning": "warning",
        "info": "information_source",
    }.get(severity or "", "bell")


def _format(payload: dict[str, Any]) -> tuple[str, str, str, str]:
    status = payload.get("status", "firing")
    alerts = payload.get("alerts") or []
    group = payload.get("groupLabels") or {}
    common = payload.get("commonLabels") or {}
    alertname = group.get("alertname") or common.get("alertname") or "alert"
    severity = (
        common.get("severity")
        or group.get("severity")
        or (alerts[0].get("labels", {}).get("severity") if alerts else None)
    )
    count = len(alerts)
    prefix = "RESOLVED" if status == "resolved" else "FIRING"
    title = f"[{prefix}] {alertname}"
    if count > 1:
        title = f"[{prefix}] {alertname} ({count} alerts)"
    lines = []
    for alert in alerts[:20]:
        labels = alert.get("labels") or {}
        annotations = alert.get("annotations") or {}
        alert_severity = labels.get("severity", "?")
        location = labels.get("namespace") or labels.get("pod") or ""
        message = (
            annotations.get("summary")
            or annotations.get("description")
            or labels.get("alertname", "")
        )
        lines.append(
            f"{alert_severity}"
            + (f" · {location}" if location else "")
            + f": {message}"
        )
    if count > 20:
        lines.append(f"... +{count - 20} more")
    body = "\n".join(lines) if lines else alertname
    return title, body, PRIORITY.get(severity or "", "3"), _tag(status, severity)


def _request(request: urllib.request.Request, *, timeout: float = 10) -> None:
    with urllib.request.urlopen(request, timeout=timeout) as response:
        response.read()


def _publish_ntfy(payload: dict[str, Any], topic: str) -> None:
    title, body, priority, tag = _format(payload)
    request = urllib.request.Request(
        f"{NTFY_BASE_URL}/{topic}",
        data=body.encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {NTFY_TOKEN}",
            "Title": title,
            "Priority": priority,
            "Tags": tag,
            "Content-Type": "text/plain; charset=utf-8",
        },
    )
    _request(request)


def _fallback_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Mark a one-way fallback without introducing approval vocabulary."""
    marked = copy.deepcopy(payload)
    for alert in marked.get("alerts") or []:
        annotations = alert.setdefault("annotations", {})
        summary = annotations.get("summary") or annotations.get("description") or ""
        annotations["summary"] = FALLBACK_PREFIX + summary
    return marked


def _send_signal_fallback(payload: dict[str, Any]) -> None:
    common = payload.get("commonLabels") or {}
    group = payload.get("groupLabels") or {}
    alerts = payload.get("alerts") or []
    component = common.get("component") or group.get("component")
    if component is None and alerts:
        component = (alerts[0].get("labels") or {}).get("component")
    endpoint = "deception" if component == "deception" else "alert"
    request = urllib.request.Request(
        f"{SIGNAL_FALLBACK_BASE_URL}/v1/{endpoint}",
        data=json.dumps(_fallback_payload(payload), separators=(",", ":")).encode(
            "utf-8"
        ),
        method="POST",
        headers={
            "Authorization": f"Bearer {SIGNAL_FALLBACK_TOKEN}",
            "Content-Type": "application/json",
            "X-Homelab-Delivery-Mode": "ntfy-fallback",
        },
    )
    _request(request)


def _deliver(payload: dict[str, Any], topic: str) -> str:
    if topic not in ALLOWED_TOPICS:
        raise ValueError("topic is not allowed")
    try:
        _publish_ntfy(payload, topic)
        return "ntfy"
    except Exception as ntfy_error:  # noqa: BLE001 - fallback covers transport + HTTP failure
        sys.stderr.write(
            f"ntfy primary failed ({type(ntfy_error).__name__}); attempting Signal fallback\n"
        )

    try:
        _send_signal_fallback(payload)
        sys.stderr.write("Signal fallback acknowledged\n")
        return "signal-fallback"
    except Exception as signal_error:  # noqa: BLE001 - normalized for Alertmanager retry
        sys.stderr.write(f"Signal fallback failed ({type(signal_error).__name__})\n")
        raise DeliveryError("primary and fallback delivery failed") from signal_error


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, message: bytes = b"") -> None:
        self.send_response(code)
        self.send_header("Content-Length", str(len(message)))
        self.end_headers()
        if message:
            self.wfile.write(message)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        if urlparse(self.path).path == "/healthz":
            self._send(200, b"ok")
        else:
            self._send(404)

    def do_POST(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        parsed = urlparse(self.path)
        if parsed.path != "/publish":
            self._send(404)
            return
        topic = (parse_qs(parsed.query).get("topic") or [""])[0]
        if topic not in ALLOWED_TOPICS:
            self._send(400, b"invalid topic")
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self._send(400, b"invalid content length")
            return
        if length > 1_048_576:
            self._send(413, b"payload too large")
            return
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw)
            if not isinstance(payload, dict):
                raise ValueError("payload must be an object")
        except (ValueError, TypeError):
            self._send(400, b"bad json")
            return
        try:
            _deliver(payload, topic)
            self._send(204)
        except DeliveryError:
            self._send(502)

    def log_message(self, *_args: Any) -> None:
        return


if __name__ == "__main__":
    _validate_config()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
