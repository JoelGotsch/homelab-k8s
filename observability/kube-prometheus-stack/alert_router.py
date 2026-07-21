"""Durable ntfy-primary, Signal-fallback delivery for Alertmanager webhooks.

The router owns one operational delivery decision. It records an intent before
each downstream call, records the acknowledged/failed/unknown outcome after the
call, and never retries an ambiguous call blindly. Exact Alertmanager retries
are deduplicated in the SQLite ledger mounted on persistent storage.

Signal remains a one-way outage fallback. It cannot create or mutate approval
state, and it is invoked only after the corresponding ntfy publish failed or
became delivery-ambiguous.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import os
import socket
import sqlite3
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Iterator
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
STATE_PATH = Path(
    os.environ.get(
        "ALERT_ROUTER_STATE_PATH",
        "/var/lib/alert-router/delivery-ledger.sqlite3",
    )
)

ALLOWED_TOPICS = frozenset({"homelab-alerts", "homelab-alerts-warning"})
PRIORITY = {"critical": "5", "warning": "3", "info": "2"}
FALLBACK_PREFIX = "ALERT FALLBACK — "
_DELIVERY_LOCK = threading.RLock()
_LEDGER: DeliveryLedger | None = None


class DeliveryError(RuntimeError):
    """Neither primary nor fallback acknowledged delivery."""


class DeliveryUnknown(DeliveryError):
    """A downstream call may have delivered and must not be retried blindly."""

    def __init__(self, delivery_key: str) -> None:
        super().__init__(
            f"delivery_unknown for {delivery_key}; operator reconciliation required"
        )
        self.delivery_key = delivery_key


class DeliveryDeferred(DeliveryError):
    """No channel acknowledged delivery; Alertmanager must retain and retry."""


@dataclass(frozen=True)
class DeliveryControls:
    dedup_window_seconds: int
    ledger_retention_seconds: int
    fallback_max_messages: int
    fallback_window_seconds: int
    recovery_successes: int
    recovery_minimum_seconds: int


@dataclass(frozen=True)
class DeliveryRecord:
    delivery_key: str
    fingerprint: str
    primary_status: str
    primary_evidence: str | None
    fallback_status: str
    fallback_evidence: str | None


def _positive_int(value: Any, field: str, *, allow_zero: bool = False) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise RuntimeError(f"notification channel policy {field} must be an integer")
    invalid = value < 0 if allow_zero else value <= 0
    if invalid:
        qualifier = "non-negative" if allow_zero else "positive"
        raise RuntimeError(f"notification channel policy {field} must be {qualifier}")
    return value


def _load_policy(path: Path = POLICY_PATH) -> tuple[dict[str, Any], DeliveryControls]:
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

    delivery = operational.get("deliveryControl") or {}
    rate = delivery.get("fallbackRateLimit") or {}
    recovery = delivery.get("recovery") or {}
    controls = DeliveryControls(
        dedup_window_seconds=_positive_int(
            delivery.get("dedupWindowSeconds"), "dedupWindowSeconds"
        ),
        ledger_retention_seconds=_positive_int(
            delivery.get("ledgerRetentionSeconds"), "ledgerRetentionSeconds"
        ),
        fallback_max_messages=_positive_int(
            rate.get("maxMessages"), "fallbackRateLimit.maxMessages"
        ),
        fallback_window_seconds=_positive_int(
            rate.get("windowSeconds"), "fallbackRateLimit.windowSeconds"
        ),
        recovery_successes=_positive_int(
            recovery.get("consecutivePrimarySuccesses"),
            "recovery.consecutivePrimarySuccesses",
        ),
        recovery_minimum_seconds=_positive_int(
            recovery.get("minimumSeconds"),
            "recovery.minimumSeconds",
            allow_zero=True,
        ),
    )
    return policy, controls


def _validate_config() -> DeliveryControls:
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
    _, controls = _load_policy()
    _get_ledger().ready()
    return controls


class DeliveryLedger:
    """SQLite attempt ledger and ntfy-outage episode state."""

    def __init__(self, path: Path) -> None:
        self.path = path
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self._initialize()

    def _connect(self) -> sqlite3.Connection:
        connection = sqlite3.connect(self.path, timeout=5, isolation_level=None)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA busy_timeout = 5000")
        connection.execute("PRAGMA synchronous = FULL")
        return connection

    @contextmanager
    def _read_connection(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            yield connection
        finally:
            connection.close()

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            yield connection
            connection.commit()
        except Exception:
            connection.rollback()
            raise
        finally:
            connection.close()

    def _initialize(self) -> None:
        with self._read_connection() as connection:
            connection.execute("PRAGMA journal_mode = WAL")
            connection.execute("PRAGMA synchronous = FULL")
            connection.executescript(
                """
                CREATE TABLE IF NOT EXISTS deliveries (
                    delivery_key TEXT PRIMARY KEY,
                    identity_hash TEXT NOT NULL,
                    fingerprint TEXT NOT NULL,
                    topic TEXT NOT NULL,
                    payload_hash TEXT NOT NULL,
                    first_seen REAL NOT NULL,
                    last_seen REAL NOT NULL,
                    duplicate_count INTEGER NOT NULL DEFAULT 0,
                    primary_status TEXT NOT NULL DEFAULT 'not_attempted',
                    primary_evidence TEXT,
                    fallback_status TEXT NOT NULL DEFAULT 'not_attempted',
                    fallback_evidence TEXT
                );
                CREATE INDEX IF NOT EXISTS deliveries_identity_seen
                    ON deliveries(identity_hash, last_seen DESC);

                CREATE TABLE IF NOT EXISTS episodes (
                    episode_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    opened_at REAL NOT NULL,
                    last_failure_at REAL NOT NULL,
                    state TEXT NOT NULL DEFAULT 'degraded',
                    primary_failure_count INTEGER NOT NULL DEFAULT 1,
                    fallback_sent_count INTEGER NOT NULL DEFAULT 0,
                    fallback_suppressed_count INTEGER NOT NULL DEFAULT 0,
                    recovery_started_at REAL,
                    recovery_success_count INTEGER NOT NULL DEFAULT 0,
                    closed_at REAL,
                    recovery_summary_status TEXT NOT NULL DEFAULT 'not_attempted',
                    recovery_summary_evidence TEXT
                );

                CREATE TABLE IF NOT EXISTS attempts (
                    attempt_id INTEGER PRIMARY KEY AUTOINCREMENT,
                    delivery_key TEXT,
                    episode_id INTEGER,
                    channel TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    completed_at REAL,
                    outcome TEXT NOT NULL,
                    evidence TEXT,
                    FOREIGN KEY(delivery_key) REFERENCES deliveries(delivery_key)
                        ON DELETE CASCADE,
                    FOREIGN KEY(episode_id) REFERENCES episodes(episode_id)
                        ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS attempts_channel_started
                    ON attempts(channel, started_at DESC);
                """
            )
        os.chmod(self.path, 0o600)

    def ready(self) -> None:
        # A read-only SELECT can succeed while a full/read-only volume would
        # make the next delivery impossible to record. Roll back a real write
        # so readiness proves the ledger can durably accept another intent
        # without growing the database on every probe.
        with self._read_connection() as connection:
            try:
                connection.execute("BEGIN IMMEDIATE")
                connection.execute(
                    "INSERT INTO attempts (channel, started_at, outcome) "
                    "VALUES ('readiness-probe', ?, 'probe')",
                    (time.time(),),
                )
            finally:
                connection.rollback()

    def recover_inflight(self, now: float) -> int:
        """Turn pre-crash attempt intents into explicit ambiguous outcomes."""
        with self._transaction() as connection:
            rows = connection.execute(
                "SELECT attempt_id, delivery_key, episode_id, channel "
                "FROM attempts WHERE outcome = 'attempting'"
            ).fetchall()
            for row in rows:
                connection.execute(
                    "UPDATE attempts SET completed_at = ?, outcome = 'delivery_unknown', "
                    "evidence = 'process_restarted_during_attempt' WHERE attempt_id = ?",
                    (now, row["attempt_id"]),
                )
                if row["delivery_key"] and row["channel"] in {
                    "ntfy-primary",
                    "signal-fallback",
                }:
                    field = (
                        "primary" if row["channel"] == "ntfy-primary" else "fallback"
                    )
                    connection.execute(
                        f"UPDATE deliveries SET {field}_status = 'delivery_unknown', "
                        f"{field}_evidence = 'process_restarted_during_attempt' "
                        "WHERE delivery_key = ?",
                        (row["delivery_key"],),
                    )
                elif row["episode_id"] and row["channel"] == "signal-recovery":
                    connection.execute(
                        "UPDATE episodes SET recovery_summary_status = 'delivery_unknown', "
                        "recovery_summary_evidence = 'process_restarted_during_attempt' "
                        "WHERE episode_id = ?",
                        (row["episode_id"],),
                    )
            return len(rows)

    def get_or_create(
        self,
        payload: dict[str, Any],
        topic: str,
        now: float,
        dedup_window_seconds: int,
        retention_seconds: int,
    ) -> tuple[DeliveryRecord, bool]:
        encoded = json.dumps(
            payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False
        ).encode("utf-8")
        payload_hash = hashlib.sha256(encoded).hexdigest()
        identity_hash = hashlib.sha256(topic.encode() + b"\0" + encoded).hexdigest()
        fingerprint = _fingerprint(payload)
        with self._transaction() as connection:
            cutoff = now - retention_seconds
            connection.execute(
                "DELETE FROM deliveries WHERE last_seen < ? "
                "AND primary_status != 'attempting' "
                "AND fallback_status NOT IN ('attempting', 'delivery_unknown') "
                "AND (primary_status != 'delivery_unknown' "
                "OR fallback_status = 'acknowledged')",
                (cutoff,),
            )
            connection.execute(
                "DELETE FROM episodes WHERE closed_at IS NOT NULL AND closed_at < ? "
                "AND recovery_summary_status NOT IN "
                "('attempting', 'delivery_unknown')",
                (cutoff,),
            )
            row = connection.execute(
                "SELECT * FROM deliveries WHERE identity_hash = ? "
                "ORDER BY last_seen DESC LIMIT 1",
                (identity_hash,),
            ).fetchone()
            sticky_unknown = row and (
                row["fallback_status"] in {"attempting", "delivery_unknown"}
                or (
                    row["primary_status"] in {"attempting", "delivery_unknown"}
                    and row["fallback_status"] != "acknowledged"
                )
            )
            if row and (
                sticky_unknown or row["last_seen"] >= now - dedup_window_seconds
            ):
                connection.execute(
                    "UPDATE deliveries SET last_seen = ?, "
                    "duplicate_count = duplicate_count + 1 WHERE delivery_key = ?",
                    (now, row["delivery_key"]),
                )
                refreshed = connection.execute(
                    "SELECT * FROM deliveries WHERE delivery_key = ?",
                    (row["delivery_key"],),
                ).fetchone()
                return self._record(refreshed), False

            delivery_key = hashlib.sha256(
                f"{identity_hash}:{now}:{uuid.uuid4().hex}".encode()
            ).hexdigest()[:32]
            connection.execute(
                "INSERT INTO deliveries "
                "(delivery_key, identity_hash, fingerprint, topic, payload_hash, "
                "first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    delivery_key,
                    identity_hash,
                    fingerprint,
                    topic,
                    payload_hash,
                    now,
                    now,
                ),
            )
            row = connection.execute(
                "SELECT * FROM deliveries WHERE delivery_key = ?", (delivery_key,)
            ).fetchone()
            return self._record(row), True

    def get(self, delivery_key: str) -> DeliveryRecord:
        with self._read_connection() as connection:
            row = connection.execute(
                "SELECT * FROM deliveries WHERE delivery_key = ?", (delivery_key,)
            ).fetchone()
        if row is None:
            raise KeyError(delivery_key)
        return self._record(row)

    @staticmethod
    def _record(row: sqlite3.Row) -> DeliveryRecord:
        return DeliveryRecord(
            delivery_key=row["delivery_key"],
            fingerprint=row["fingerprint"],
            primary_status=row["primary_status"],
            primary_evidence=row["primary_evidence"],
            fallback_status=row["fallback_status"],
            fallback_evidence=row["fallback_evidence"],
        )

    def begin_attempt(
        self,
        delivery_key: str | None,
        channel: str,
        now: float,
        *,
        episode_id: int | None = None,
    ) -> int:
        with self._transaction() as connection:
            cursor = connection.execute(
                "INSERT INTO attempts "
                "(delivery_key, episode_id, channel, started_at, outcome) "
                "VALUES (?, ?, ?, ?, 'attempting')",
                (delivery_key, episode_id, channel, now),
            )
            if delivery_key:
                field = "primary" if channel == "ntfy-primary" else "fallback"
                connection.execute(
                    f"UPDATE deliveries SET {field}_status = 'attempting', "
                    f"{field}_evidence = NULL WHERE delivery_key = ?",
                    (delivery_key,),
                )
            elif episode_id:
                connection.execute(
                    "UPDATE episodes SET recovery_summary_status = 'attempting', "
                    "recovery_summary_evidence = NULL WHERE episode_id = ?",
                    (episode_id,),
                )
            return int(cursor.lastrowid)

    def finish_attempt(
        self,
        attempt_id: int,
        outcome: str,
        evidence: str,
        now: float,
    ) -> None:
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT delivery_key, episode_id, channel FROM attempts "
                "WHERE attempt_id = ?",
                (attempt_id,),
            ).fetchone()
            if row is None:
                raise KeyError(attempt_id)
            connection.execute(
                "UPDATE attempts SET completed_at = ?, outcome = ?, evidence = ? "
                "WHERE attempt_id = ?",
                (now, outcome, evidence, attempt_id),
            )
            if row["delivery_key"]:
                field = "primary" if row["channel"] == "ntfy-primary" else "fallback"
                connection.execute(
                    f"UPDATE deliveries SET {field}_status = ?, {field}_evidence = ? "
                    "WHERE delivery_key = ?",
                    (outcome, evidence, row["delivery_key"]),
                )
            elif row["episode_id"]:
                connection.execute(
                    "UPDATE episodes SET recovery_summary_status = ?, "
                    "recovery_summary_evidence = ? WHERE episode_id = ?",
                    (outcome, evidence, row["episode_id"]),
                )

    def note_primary_failure(self, now: float) -> int:
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT episode_id FROM episodes WHERE closed_at IS NULL "
                "ORDER BY episode_id DESC LIMIT 1"
            ).fetchone()
            if row is None:
                cursor = connection.execute(
                    "INSERT INTO episodes (opened_at, last_failure_at) VALUES (?, ?)",
                    (now, now),
                )
                return int(cursor.lastrowid)
            connection.execute(
                "UPDATE episodes SET last_failure_at = ?, state = 'degraded', "
                "primary_failure_count = primary_failure_count + 1, "
                "recovery_started_at = NULL, recovery_success_count = 0 "
                "WHERE episode_id = ?",
                (now, row["episode_id"]),
            )
            return int(row["episode_id"])

    def open_episode_id(self) -> int | None:
        with self._read_connection() as connection:
            row = connection.execute(
                "SELECT episode_id FROM episodes WHERE closed_at IS NULL "
                "ORDER BY episode_id DESC LIMIT 1"
            ).fetchone()
        return int(row["episode_id"]) if row else None

    def note_ntfy_success(
        self,
        now: float,
        required_successes: int,
        minimum_seconds: int,
    ) -> dict[str, int | float] | None:
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT * FROM episodes WHERE closed_at IS NULL "
                "ORDER BY episode_id DESC LIMIT 1"
            ).fetchone()
            if row is None:
                return None
            started = row["recovery_started_at"] or now
            successes = int(row["recovery_success_count"]) + 1
            if successes < required_successes or now - started < minimum_seconds:
                connection.execute(
                    "UPDATE episodes SET state = 'recovering', recovery_started_at = ?, "
                    "recovery_success_count = ? WHERE episode_id = ?",
                    (started, successes, row["episode_id"]),
                )
                return None
            connection.execute(
                "UPDATE episodes SET state = 'recovered', recovery_started_at = ?, "
                "recovery_success_count = ?, closed_at = ? WHERE episode_id = ?",
                (started, successes, now, row["episode_id"]),
            )
            return {
                "episode_id": int(row["episode_id"]),
                "opened_at": float(row["opened_at"]),
                "primary_failures": int(row["primary_failure_count"]),
                "fallback_sent": int(row["fallback_sent_count"]),
                "fallback_suppressed": int(row["fallback_suppressed_count"]),
                "recovery_successes": successes,
            }

    def fallback_allowed(self, now: float, maximum: int, window_seconds: int) -> bool:
        with self._read_connection() as connection:
            count = connection.execute(
                "SELECT COUNT(*) FROM attempts WHERE channel = 'signal-fallback' "
                "AND started_at >= ?",
                (now - window_seconds,),
            ).fetchone()[0]
        return int(count) < maximum

    def mark_fallback_suppressed(
        self, delivery_key: str, evidence: str, episode_id: int
    ) -> None:
        with self._transaction() as connection:
            connection.execute(
                "UPDATE deliveries SET fallback_status = 'rate_limited', "
                "fallback_evidence = ? WHERE delivery_key = ?",
                (evidence, delivery_key),
            )
            connection.execute(
                "UPDATE episodes SET fallback_suppressed_count = "
                "fallback_suppressed_count + 1 WHERE episode_id = ?",
                (episode_id,),
            )

    def note_fallback_sent(self, episode_id: int) -> None:
        with self._transaction() as connection:
            connection.execute(
                "UPDATE episodes SET fallback_sent_count = fallback_sent_count + 1 "
                "WHERE episode_id = ?",
                (episode_id,),
            )

    def unknown_rows(self) -> list[sqlite3.Row]:
        with self._read_connection() as connection:
            return connection.execute(
                "SELECT delivery_key, fingerprint, topic, first_seen, last_seen, "
                "primary_status, fallback_status FROM deliveries "
                "WHERE primary_status = 'delivery_unknown' "
                "OR fallback_status = 'delivery_unknown' ORDER BY first_seen"
            ).fetchall()

    def unknown_recovery_summaries(self) -> list[sqlite3.Row]:
        with self._read_connection() as connection:
            return connection.execute(
                "SELECT episode_id, opened_at, closed_at, primary_failure_count, "
                "fallback_sent_count, fallback_suppressed_count, "
                "recovery_summary_status FROM episodes "
                "WHERE recovery_summary_status = 'delivery_unknown' "
                "ORDER BY opened_at"
            ).fetchall()

    def reconcile(
        self, delivery_key: str, channel: str, outcome: str, now: float
    ) -> None:
        field = "primary" if channel == "primary" else "fallback"
        with self._transaction() as connection:
            row = connection.execute(
                f"SELECT {field}_status FROM deliveries WHERE delivery_key = ?",
                (delivery_key,),
            ).fetchone()
            if row is None:
                raise KeyError(delivery_key)
            if row[0] != "delivery_unknown":
                raise ValueError(f"{channel} outcome is not delivery_unknown")
            evidence = f"operator_reconciled_{outcome}"
            connection.execute(
                f"UPDATE deliveries SET {field}_status = ?, {field}_evidence = ? "
                "WHERE delivery_key = ?",
                (outcome, evidence, delivery_key),
            )
            connection.execute(
                "INSERT INTO attempts "
                "(delivery_key, channel, started_at, completed_at, outcome, evidence) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (delivery_key, "operator-reconciliation", now, now, outcome, evidence),
            )

    def reconcile_recovery_summary(
        self, episode_id: int, outcome: str, now: float
    ) -> None:
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT recovery_summary_status FROM episodes WHERE episode_id = ?",
                (episode_id,),
            ).fetchone()
            if row is None:
                raise KeyError(episode_id)
            if row[0] != "delivery_unknown":
                raise ValueError("recovery summary outcome is not delivery_unknown")
            evidence = f"operator_reconciled_{outcome}"
            connection.execute(
                "UPDATE episodes SET recovery_summary_status = ?, "
                "recovery_summary_evidence = ? WHERE episode_id = ?",
                (outcome, evidence, episode_id),
            )
            connection.execute(
                "INSERT INTO attempts "
                "(episode_id, channel, started_at, completed_at, outcome, evidence) "
                "VALUES (?, 'operator-reconciliation', ?, ?, ?, ?)",
                (episode_id, now, now, outcome, evidence),
            )


def _get_ledger() -> DeliveryLedger:
    global _LEDGER
    if _LEDGER is None:
        _LEDGER = DeliveryLedger(STATE_PATH)
    return _LEDGER


def _fingerprint(payload: dict[str, Any]) -> str:
    group_key = payload.get("groupKey")
    if group_key:
        material = str(group_key)
    else:
        fingerprints = sorted(
            str(alert.get("fingerprint"))
            for alert in payload.get("alerts") or []
            if alert.get("fingerprint")
        )
        material = json.dumps(
            {
                "groupLabels": payload.get("groupLabels") or {},
                "fingerprints": fingerprints,
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:16]


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


def _request(request: urllib.request.Request, *, timeout: float = 10) -> bytes:
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def _publish_ntfy(payload: dict[str, Any], topic: str) -> str:
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
    response = _request(request)
    try:
        message_id = json.loads(response).get("id") if response else None
    except (ValueError, AttributeError):
        message_id = None
    return f"ntfy_ack:{message_id}" if message_id else "ntfy_ack"


_FORBIDDEN_FALLBACK_KEYS = ("approval", "command", "digest", "reply", "token")


def _sanitize_fallback(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: _sanitize_fallback(child)
            for key, child in value.items()
            if not any(word in key.lower() for word in _FORBIDDEN_FALLBACK_KEYS)
        }
    if isinstance(value, list):
        return [_sanitize_fallback(child) for child in value]
    return value


def _fallback_payload(
    payload: dict[str, Any], fingerprint: str, evidence: str, observed_at: float
) -> dict[str, Any]:
    """Create an explicitly one-way fallback envelope without approval fields."""
    marked = _sanitize_fallback(copy.deepcopy(payload))
    alerts = marked.get("alerts") or []
    starts = sorted(
        str(alert.get("startsAt")) for alert in alerts if alert.get("startsAt")
    )
    ends = sorted(str(alert.get("endsAt")) for alert in alerts if alert.get("endsAt"))
    first = starts[0] if starts else "unknown"
    last = ends[-1] if ends else datetime.fromtimestamp(observed_at, UTC).isoformat()
    context = f"id={fingerprint}; ntfy={evidence}; first={first}; last={last}; "
    for alert in alerts:
        annotations = alert.setdefault("annotations", {})
        summary = annotations.get("summary") or annotations.get("description") or ""
        annotations["summary"] = FALLBACK_PREFIX + context + summary
    marked["receiver"] = "signal-operational-fallback"
    marked["homelabFallback"] = {
        "type": "operational-alert",
        "fingerprint": fingerprint,
        "ntfyEvidence": evidence,
        "observedAt": datetime.fromtimestamp(observed_at, UTC).isoformat(),
    }
    return marked


def _send_signal_payload(payload: dict[str, Any], *, mode: str) -> None:
    common = payload.get("commonLabels") or {}
    group = payload.get("groupLabels") or {}
    alerts = payload.get("alerts") or []
    component = common.get("component") or group.get("component")
    if component is None and alerts:
        component = (alerts[0].get("labels") or {}).get("component")
    endpoint = "deception" if component == "deception" else "alert"
    request = urllib.request.Request(
        f"{SIGNAL_FALLBACK_BASE_URL}/v1/{endpoint}",
        data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {SIGNAL_FALLBACK_TOKEN}",
            "Content-Type": "application/json",
            "X-Homelab-Delivery-Mode": mode,
        },
    )
    _request(request)


def _failure_outcome(error: Exception) -> tuple[str, str]:
    if isinstance(error, urllib.error.HTTPError):
        return "failed", f"http_{error.code}"
    reason = error.reason if isinstance(error, urllib.error.URLError) else error
    if isinstance(reason, (TimeoutError, socket.timeout)):
        return "delivery_unknown", "timeout"
    if isinstance(reason, (ConnectionRefusedError, socket.gaierror)):
        return "failed", type(reason).__name__.lower()
    return "delivery_unknown", f"ambiguous_{type(reason).__name__.lower()}"


def _recovery_payload(summary: dict[str, int | float]) -> dict[str, Any]:
    opened = datetime.fromtimestamp(float(summary["opened_at"]), UTC).isoformat()
    message = (
        "ntfy primary recovered after "
        f"{summary['recovery_successes']} consecutive acknowledged publishes; "
        f"episode opened {opened}; failures={summary['primary_failures']}; "
        f"Signal fallbacks={summary['fallback_sent']}; "
        f"rate-limited={summary['fallback_suppressed']}"
    )
    return {
        "receiver": "signal-operational-fallback",
        "status": "resolved",
        "commonLabels": {"component": "alert-delivery", "severity": "info"},
        "groupLabels": {"alertname": "NtfyDeliveryRecovered"},
        "alerts": [
            {
                "status": "resolved",
                "labels": {
                    "alertname": "NtfyDeliveryRecovered",
                    "severity": "info",
                    "component": "alert-delivery",
                },
                "annotations": {"summary": message},
            }
        ],
    }


def _send_recovery_summary(
    ledger: DeliveryLedger, summary: dict[str, int | float], now: float
) -> None:
    episode_id = int(summary["episode_id"])
    attempt_id = ledger.begin_attempt(
        None, "signal-recovery", now, episode_id=episode_id
    )
    try:
        _send_signal_payload(_recovery_payload(summary), mode="ntfy-recovery-summary")
    except Exception as error:  # noqa: BLE001 - outcome is normalized and persisted
        outcome, evidence = _failure_outcome(error)
        ledger.finish_attempt(attempt_id, outcome, evidence, now)
        sys.stderr.write(
            f"ntfy recovery summary {outcome} ({evidence}); not retried blindly\n"
        )
    else:
        ledger.finish_attempt(attempt_id, "acknowledged", "signal_ack", now)
        sys.stderr.write("ntfy recovery summary acknowledged by Signal adapter\n")


def _deliver(
    payload: dict[str, Any],
    topic: str,
    *,
    ledger: DeliveryLedger | None = None,
    controls: DeliveryControls | None = None,
    now: float | None = None,
) -> str:
    if topic not in ALLOWED_TOPICS:
        raise ValueError("topic is not allowed")
    ledger = ledger or _get_ledger()
    controls = controls or _load_policy()[1]
    observed_at = time.time() if now is None else now

    with _DELIVERY_LOCK:
        record, _ = ledger.get_or_create(
            payload,
            topic,
            observed_at,
            controls.dedup_window_seconds,
            controls.ledger_retention_seconds,
        )
        if record.primary_status == "acknowledged":
            return "ntfy-deduplicated"
        if record.fallback_status == "acknowledged":
            return "signal-fallback-deduplicated"
        if record.fallback_status in {"attempting", "delivery_unknown"}:
            raise DeliveryUnknown(record.delivery_key)

        episode_id: int | None = None
        primary_evidence = record.primary_evidence or "unknown"
        if record.primary_status in {"not_attempted", "failed"}:
            attempt_id = ledger.begin_attempt(
                record.delivery_key, "ntfy-primary", observed_at
            )
            try:
                acknowledgement = _publish_ntfy(payload, topic)
            except Exception as error:  # noqa: BLE001 - fallback covers any publish error
                outcome, primary_evidence = _failure_outcome(error)
                ledger.finish_attempt(
                    attempt_id, outcome, primary_evidence, observed_at
                )
                episode_id = ledger.note_primary_failure(observed_at)
                sys.stderr.write(
                    f"ntfy primary {outcome} ({primary_evidence}); "
                    "evaluating Signal fallback\n"
                )
            else:
                ledger.finish_attempt(
                    attempt_id, "acknowledged", acknowledgement, observed_at
                )
                recovery = ledger.note_ntfy_success(
                    observed_at,
                    controls.recovery_successes,
                    controls.recovery_minimum_seconds,
                )
                if recovery:
                    _send_recovery_summary(ledger, recovery, observed_at)
                return "ntfy"
        elif record.primary_status in {"failed", "delivery_unknown"}:
            episode_id = ledger.open_episode_id()
        else:
            raise DeliveryUnknown(record.delivery_key)

        if episode_id is None:
            episode_id = ledger.note_primary_failure(observed_at)
        if not ledger.fallback_allowed(
            observed_at,
            controls.fallback_max_messages,
            controls.fallback_window_seconds,
        ):
            evidence = (
                f"rate_limit_{controls.fallback_max_messages}_per_"
                f"{controls.fallback_window_seconds}s"
            )
            ledger.mark_fallback_suppressed(record.delivery_key, evidence, episode_id)
            sys.stderr.write(
                f"Signal fallback rate-limited for delivery {record.delivery_key}; "
                "request remains retained by Alertmanager\n"
            )
            raise DeliveryDeferred("Signal fallback is rate-limited")

        try:
            fallback = _fallback_payload(
                payload, record.fingerprint, primary_evidence, observed_at
            )
        except (AttributeError, TypeError, ValueError) as error:
            # Local payload preparation is not a downstream attempt. Do not
            # leave an `attempting` row that would falsely require ambiguity
            # reconciliation when no Signal call occurred.
            raise DeliveryError("fallback payload is invalid") from error
        attempt_id = ledger.begin_attempt(
            record.delivery_key, "signal-fallback", observed_at
        )
        try:
            _send_signal_payload(fallback, mode="ntfy-fallback")
        except Exception as error:  # noqa: BLE001 - normalized for Alertmanager
            outcome, evidence = _failure_outcome(error)
            ledger.finish_attempt(attempt_id, outcome, evidence, observed_at)
            if outcome == "delivery_unknown":
                raise DeliveryUnknown(record.delivery_key) from error
            raise DeliveryError("primary and fallback delivery failed") from error

        ledger.finish_attempt(
            attempt_id, "acknowledged", "signal_adapter_ack", observed_at
        )
        ledger.note_fallback_sent(episode_id)
        sys.stderr.write("Signal fallback acknowledged\n")
        return "signal-fallback"


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, message: bytes = b"") -> None:
        self.send_response(code)
        self.send_header("Content-Length", str(len(message)))
        self.end_headers()
        if message:
            self.wfile.write(message)

    def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
        path = urlparse(self.path).path
        if path == "/healthz":
            self._send(200, b"ok")
        elif path == "/readyz":
            try:
                _load_policy()
                _get_ledger().ready()
            except Exception:  # noqa: BLE001 - readiness exposes no internals
                self._send(503, b"not ready")
            else:
                self._send(200, b"ready")
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
        if length < 0:
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
        except DeliveryUnknown as error:
            self._send(503, str(error).encode("utf-8"))
        except DeliveryDeferred:
            self._send(503, b"delivery deferred")
        except DeliveryError:
            self._send(502, b"delivery failed")

    def log_message(self, *_args: Any) -> None:
        return


def _run_ledger_cli(arguments: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="inspect/reconcile alert delivery state"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("list-unknown")
    resolve = subparsers.add_parser("resolve-unknown")
    resolve.add_argument("delivery_key")
    resolve.add_argument("channel", choices=("primary", "fallback"))
    resolve.add_argument("outcome", choices=("acknowledged", "failed"))
    resolve_recovery = subparsers.add_parser("resolve-recovery-summary")
    resolve_recovery.add_argument("episode_id", type=int)
    resolve_recovery.add_argument("outcome", choices=("acknowledged", "failed"))
    args = parser.parse_args(arguments)
    ledger = _get_ledger()
    if args.command == "list-unknown":
        for row in ledger.unknown_rows():
            print(
                json.dumps(
                    {
                        "record_type": "delivery",
                        "delivery_key": row["delivery_key"],
                        "fingerprint": row["fingerprint"],
                        "topic": row["topic"],
                        "first_seen": row["first_seen"],
                        "last_seen": row["last_seen"],
                        "primary_status": row["primary_status"],
                        "fallback_status": row["fallback_status"],
                    },
                    sort_keys=True,
                )
            )
        for row in ledger.unknown_recovery_summaries():
            print(
                json.dumps(
                    {
                        "record_type": "recovery_summary",
                        "episode_id": row["episode_id"],
                        "opened_at": row["opened_at"],
                        "closed_at": row["closed_at"],
                        "primary_failure_count": row["primary_failure_count"],
                        "fallback_sent_count": row["fallback_sent_count"],
                        "fallback_suppressed_count": row["fallback_suppressed_count"],
                        "recovery_summary_status": row["recovery_summary_status"],
                    },
                    sort_keys=True,
                )
            )
        return 0
    try:
        if args.command == "resolve-unknown":
            ledger.reconcile(args.delivery_key, args.channel, args.outcome, time.time())
        else:
            ledger.reconcile_recovery_summary(
                args.episode_id, args.outcome, time.time()
            )
    except (KeyError, ValueError) as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    if sys.argv[1:]:
        raise SystemExit(_run_ledger_cli(sys.argv[1:]))
    controls = _validate_config()
    recovered = _get_ledger().recover_inflight(time.time())
    if recovered:
        sys.stderr.write(
            f"marked {recovered} interrupted downstream attempt(s) delivery_unknown\n"
        )
    sys.stderr.write(
        "alert router ready: durable ledger enabled; "
        f"fallback limit={controls.fallback_max_messages}/"
        f"{controls.fallback_window_seconds}s\n"
    )
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
