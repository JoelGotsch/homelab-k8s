#!/usr/bin/env python3
"""Keep app-specific Woodpecker egress narrow and two-hop complete."""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

REPO = Path(__file__).resolve().parents[1]
POLICY = REPO / "platform/woodpecker/networkpolicy.yaml"
NAME = "ci-woodpecker-todo-agents-windmill"


def main() -> int:
    documents = [item for item in yaml.safe_load_all(POLICY.read_text()) if item]
    matches = [
        item
        for item in documents
        if item.get("kind") == "CiliumNetworkPolicy"
        and item.get("metadata", {}).get("name") == NAME
    ]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one CiliumNetworkPolicy/{NAME}")
    policy: dict[str, Any] = matches[0]
    selector = policy["spec"]["endpointSelector"].get("matchLabels", {})
    if selector != {
        "woodpecker-ci.org/repo-full-name": "homelabtodo-agents",
        "woodpecker-ci.org/step": "wmill-push",
    }:
        raise SystemExit(f"{NAME} must select only the todo-agents wmill-push pod")

    egress = policy["spec"].get("egress", [])
    gateway = [rule for rule in egress if rule.get("toEntities") == ["ingress"]]
    backend = [rule for rule in egress if "toEndpoints" in rule]
    if len(egress) != 2 or len(gateway) != 1 or len(backend) != 1:
        raise SystemExit(
            f"{NAME} must contain exactly the Gateway and backend egress rules"
        )
    if gateway[0].get("toPorts") != [{"ports": [{"port": "443", "protocol": "TCP"}]}]:
        raise SystemExit(f"{NAME} Gateway rule must allow only ingress:443/TCP")
    if backend[0].get("toEndpoints") != [
        {
            "matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "windmill",
                "app.kubernetes.io/name": "windmill-app",
            }
        }
    ] or backend[0].get("toPorts") != [
        {"ports": [{"port": "8000", "protocol": "TCP"}]}
    ]:
        raise SystemExit(f"{NAME} backend rule must allow only windmill-app:8000/TCP")
    print("Woodpecker todo-agents egress is repo/step-scoped and two-hop complete")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
