#!/usr/bin/env python3
"""Keep app-specific Woodpecker egress narrow, and complete for its path.

Two exceptions exist, and they need opposite completeness checks. The
todo-agents Windmill sync crosses the Cilium Gateway, so it must have BOTH
hops or Envoy 403s it. The homelab-skills eval gate is pod-to-pod, so it must
have exactly ONE rule — a second would mean it had stopped being in-cluster.
Asserting "two hops" globally would have forced the eval policy to grow a rule
it does not need, which is why the check is per-policy rather than shared.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml

REPO = Path(__file__).resolve().parents[1]
POLICY = REPO / "platform/woodpecker/networkpolicy.yaml"
NAME = "ci-woodpecker-todo-agents-windmill"
EVALS_NAME = "ci-woodpecker-homelab-skills-evals"


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
    endpoint_selector = policy["spec"]["endpointSelector"]
    if endpoint_selector.get("matchLabels") != {
        "woodpecker-ci.org/repo-full-name": "homelabtodo-agents",
    } or endpoint_selector.get("matchExpressions") != [
        {
            "key": "woodpecker-ci.org/step",
            "operator": "In",
            "values": ["wmill-push", "wmill-drift"],
        }
    ]:
        raise SystemExit(f"{NAME} must select only todo-agents Windmill sync pods")

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
    print("Woodpecker todo-agents sync egress is repo/step-scoped and two-hop complete")
    _check_skills_evals(documents)
    return 0


def _check_skills_evals(documents: list[dict[str, Any]]) -> None:
    """The homelab-skills eval gate reaches exactly one backend, on one hop.

    Checked here rather than in its own script because the failure mode is the
    same one: a CI egress exception that quietly widens from "this step, this
    backend" to "any CI pod, anything". This policy is the more tempting one to
    widen, because the thing behind it is a model endpoint that every pipeline
    would find useful.

    Deliberately asserts a SINGLE egress rule. Adding a Gateway hop here would
    not be a tightening — it would mean the corpus had started reaching the
    model through an external route, which is the arrangement plan §5.10
    considered and rejected.
    """
    matches = [
        item
        for item in documents
        if item.get("kind") == "CiliumNetworkPolicy"
        and item.get("metadata", {}).get("name") == EVALS_NAME
    ]
    if len(matches) != 1:
        raise SystemExit(f"expected exactly one CiliumNetworkPolicy/{EVALS_NAME}")
    spec = matches[0]["spec"]
    selector = spec["endpointSelector"]
    if selector.get("matchLabels") != {
        "woodpecker-ci.org/repo-full-name": "homelabhomelab-skills",
    } or selector.get("matchExpressions") != [
        {"key": "woodpecker-ci.org/step", "operator": "In", "values": ["evals"]}
    ]:
        raise SystemExit(f"{EVALS_NAME} must select only the homelab-skills evals step")
    egress = spec.get("egress", [])
    if len(egress) != 1:
        raise SystemExit(f"{EVALS_NAME} must contain exactly one egress rule (in-cluster only)")
    if egress[0].get("toEndpoints") != [
        {
            "matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "llm-gateway",
                "app.kubernetes.io/name": "litellm",
            }
        }
    ] or egress[0].get("toPorts") != [{"ports": [{"port": "4000", "protocol": "TCP"}]}]:
        raise SystemExit(f"{EVALS_NAME} rule must allow only litellm:4000/TCP")
    print("Woodpecker homelab-skills eval egress is repo/step-scoped and single-hop")


if __name__ == "__main__":
    raise SystemExit(main())
