#!/usr/bin/env python3
"""check-hubble-redaction.py — no Hubble flow export without L7 redaction.

Hubble HTTP flows carry request headers. With `hubble.redact` off they carry
Authorization, Cookie and Set-Cookie VALUES in clear, and any export ships
them onward. On 2026-09-14 a trial of the re-added static export + Vector
sidecar put 806 lines of live credentials into Loki in twelve minutes
(TODO hl-0315; Loki delete request, token rotation). Redaction runs in the
L7 parser, ahead of observe, relay, metrics and every export.

Fails when infrastructure/cilium/values.yaml enables a Hubble export — the
static exporter (`hubble.export.static.enabled`), a dynamic one
(`hubble.export.dynamic.enabled`) or a raw `extraConfig`
`hubble-export-file-path` — and does not also have ALL of:
  hubble.redact.enabled: true
  hubble.redact.http.urlQuery: true        (OAuth codes, share tokens)
  hubble.redact.http.userInfo: true        (basic-auth passwords in URLs)
  hubble.redact.http.headers.allow: [...]  (non-empty allow-list; a deny-list
                                            misses the header nobody listed)

Usage: check-hubble-redaction.py [values.yaml]   (default: the repo's file)
Exit 0 ok, 1 violation, 2 unreadable input.
"""
import sys
from pathlib import Path

import yaml

DEFAULT = Path(__file__).resolve().parent.parent / "infrastructure/cilium/values.yaml"


def get(d, *path):
    for p in path:
        if not isinstance(d, dict) or p not in d:
            return None
        d = d[p]
    return d


def check(values):
    exports = []
    if get(values, "hubble", "export", "static", "enabled") is True:
        exports.append("hubble.export.static")
    if get(values, "hubble", "export", "dynamic", "enabled") is True:
        exports.append("hubble.export.dynamic")
    if get(values, "extraConfig", "hubble-export-file-path"):
        exports.append("extraConfig.hubble-export-file-path")
    if not exports:
        return []

    problems = []
    if get(values, "hubble", "redact", "enabled") is not True:
        problems.append("hubble.redact.enabled is not true")
    if get(values, "hubble", "redact", "http", "urlQuery") is not True:
        problems.append("hubble.redact.http.urlQuery is not true")
    if get(values, "hubble", "redact", "http", "userInfo") is not True:
        problems.append("hubble.redact.http.userInfo is not true")
    allow = get(values, "hubble", "redact", "http", "headers", "allow")
    if not (isinstance(allow, list) and allow):
        problems.append("hubble.redact.http.headers.allow is not a non-empty allow-list")
    deny = get(values, "hubble", "redact", "http", "headers", "deny")
    if deny:
        problems.append("hubble.redact.http.headers.deny is set (allow and deny are exclusive; use allow)")
    lower = {str(h).lower() for h in (allow or [])}
    leaked = sorted(lower & {"authorization", "cookie", "set-cookie", "proxy-authorization"})
    if leaked:
        problems.append(f"the header allow-list lets credential headers through: {', '.join(leaked)}")
    return [f"{', '.join(exports)} enabled but {p}" for p in problems]


def main():
    path = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT
    try:
        values = yaml.safe_load(path.read_text()) or {}
    except (OSError, yaml.YAMLError) as e:
        print(f"FAIL: cannot read {path}: {e}")
        return 2
    problems = check(values)
    if problems:
        for p in problems:
            print(f"FAIL: {p}")
        print("Hubble L7 flows carry credential header values unless redacted (hl-0315).")
        return 1
    print(f"OK: {path.name}: no Hubble export, or export with allow-list redaction.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
