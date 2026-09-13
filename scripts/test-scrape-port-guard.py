#!/usr/bin/env python3
"""Regression tests for the scrape-port pass of check-selectors-match-render.py (TODO hl-0297).

Synthetic cases pin the resolution rules; the mutation case renders the real
kube-prometheus-stack and crowdsec layers and removes 6060 from
prometheus-allow, which must fail — that port was the sixth recurrence of the
"new scrape port, no egress" trap (220d6aa).
"""

from __future__ import annotations

import copy
import importlib.util
import shutil
import sys
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("selectors", ROOT / "scripts/check-selectors-match-render.py")
assert spec and spec.loader
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


def meta(kind: str, name: str, ns: str | None, labels: dict[str, str] | None = None, api: str = "v1") -> dict[str, Any]:
    m: dict[str, Any] = {"name": name, "labels": labels or {}}
    if ns is not None:
        m["namespace"] = ns
    return {"apiVersion": api, "kind": kind, "metadata": m}


def prometheus() -> dict[str, Any]:
    d = meta("Prometheus", "prom", "monitoring", api="monitoring.coreos.com/v1")
    d["spec"] = {"serviceMonitorSelector": {"matchLabels": {"release": "kps"}},
                 "podMonitorSelector": {"matchLabels": {"release": "kps"}}}
    return d


def allow(ports: list[int], ns_peer: dict[str, Any] | None = None) -> dict[str, Any]:
    d = meta("NetworkPolicy", "prometheus-allow", "monitoring", api="networking.k8s.io/v1")
    d["spec"] = {"podSelector": {"matchLabels": {"app.kubernetes.io/name": "prometheus"}},
                 "policyTypes": ["Egress"],
                 "egress": [{"to": [ns_peer if ns_peer is not None else {"namespaceSelector": {}}],
                             "ports": [{"port": p, "protocol": "TCP"} for p in ports]}]}
    return d


def host_cnp() -> dict[str, Any]:
    d = meta("CiliumNetworkPolicy", "prometheus-apiserver", "monitoring", api="cilium.io/v2")
    d["spec"] = {"endpointSelector": {"matchLabels": {"app.kubernetes.io/name": "prometheus"}},
                 "egress": [{"toEntities": ["kube-apiserver", "host", "remote-node"]}]}
    return d


def deployment(name: str, ns: str | None, labels: dict[str, str], ports: dict[str, int], host: bool = False) -> dict[str, Any]:
    d = meta("Deployment", name, ns, api="apps/v1")
    podspec: dict[str, Any] = {"containers": [{"name": "c", "ports": [{"name": k, "containerPort": v} for k, v in ports.items()]}]}
    if host:
        podspec["hostNetwork"] = True
    d["spec"] = {"template": {"metadata": {"labels": labels}, "spec": podspec}}
    return d


def service(name: str, ns: str | None, labels: dict[str, str], selector: dict[str, str], ports: list[dict[str, Any]]) -> dict[str, Any]:
    d = meta("Service", name, ns, labels)
    d["spec"] = {"selector": selector, "ports": ports}
    return d


def service_monitor(name: str, ns: str, selector: dict[str, str], endpoints: list[dict[str, Any]]) -> dict[str, Any]:
    d = meta("ServiceMonitor", name, ns, {"release": "kps"}, api="monitoring.coreos.com/v1")
    d["spec"] = {"selector": {"matchLabels": selector}, "endpoints": endpoints}
    return d


def pod_monitor(name: str, ns: str, selector: dict[str, str], port: str) -> dict[str, Any]:
    d = meta("PodMonitor", name, ns, {"release": "kps"}, api="monitoring.coreos.com/v1")
    d["spec"] = {"selector": {"matchLabels": selector}, "podMetricsEndpoints": [{"port": port}]}
    return d


def run(objs: list[tuple[str, dict[str, Any]]]) -> tuple[list[str], str]:
    pool: dict[Any, dict[str, list[Any]]] = {}
    rendered = []
    for layer, o in objs:
        slot = pool.setdefault(o["metadata"].get("namespace"), {"services": [], "pods": [], "service_specs": [], "pod_specs": []})
        rendered.append((Path(layer), o))
        if o["kind"] == "Service":
            slot["service_specs"].append({"layer": layer, "labels": o["metadata"]["labels"],
                                          "selector": o["spec"]["selector"], "ports": o["spec"]["ports"]})
        ps = guard.pod_spec_of(o)
        if ps is not None:
            slot["pod_specs"].append({"layer": layer, **ps})
    problems, summary, _ = guard.check_scrape_ports(rendered, pool)
    return problems, summary


APP = {"app": "x"}


class Synthetic(unittest.TestCase):
    def base(self, policy_ports: list[int]) -> list[tuple[str, dict[str, Any]]]:
        # An empty port list admits every port (NetworkPolicy semantics), so a
        # case that must deny passes some unrelated port.
        return [("kps", prometheus()), ("kps", allow(policy_ports)), ("kps", host_cnp())]

    def test_named_target_port_resolves_to_container_port(self) -> None:
        objs = [("app", deployment("x", "app", APP, {"metrics": 7777})),
                ("app", service("x", "app", APP, APP, [{"name": "metrics", "port": 80, "targetPort": "metrics"}])),
                ("app", service_monitor("x", "app", APP, [{"port": "metrics"}]))]
        self.assertEqual(run(self.base([7777]) + objs)[0], [])
        problems = run(self.base([80]) + objs)[0]  # the Service port is not what Prometheus dials
        self.assertEqual(len(problems), 1)
        self.assertIn("resolves to 7777", problems[0])

    def test_endpoint_target_port_overrides_service(self) -> None:
        objs = [("app", deployment("x", "app", APP, {"metrics": 7777, "alt": 7778})),
                ("app", service("x", "app", APP, APP, [{"name": "metrics", "port": 80, "targetPort": "metrics"}])),
                ("app", service_monitor("x", "app", APP, [{"port": "metrics", "targetPort": "alt"}]))]
        self.assertIn("resolves to 7778", run(self.base([7777]) + objs)[0][0])

    def test_pod_monitor_uses_container_port(self) -> None:
        objs = [("app", deployment("x", "app", APP, {"metrics": 9001})),
                ("app", pod_monitor("x", "app", APP, "metrics"))]
        self.assertEqual(run(self.base([9001]) + objs)[0], [])
        self.assertIn("resolves to 9001", run(self.base([9000]) + objs)[0][0])

    def test_host_network_needs_host_entity_not_namespace_peer(self) -> None:
        objs = [("app", deployment("x", "app", APP, {"metrics": 9100}, host=True)),
                ("app", pod_monitor("x", "app", APP, "metrics"))]
        self.assertEqual(run(self.base([]) + objs)[0], [])  # the CNP admits host on any port
        no_cnp = [("kps", prometheus()), ("kps", allow([9100]))]
        self.assertIn("host-network", run(no_cnp + objs)[0][0])

    def test_namespace_scoped_peer_only_admits_that_namespace(self) -> None:
        peer = {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "other"}}}
        objs = [("app", deployment("x", "app", APP, {"metrics": 7777})),
                ("app", pod_monitor("x", "app", APP, "metrics"))]
        self.assertEqual(len(run([("kps", prometheus()), ("kps", allow([7777], peer))] + objs)[0]), 1)

    def test_pod_scoped_peer_only_admits_matching_pods(self) -> None:
        peer = {"namespaceSelector": {}, "podSelector": {"matchLabels": {"app": "y"}}}
        objs = [("app", deployment("x", "app", APP, {"metrics": 7777})),
                ("app", pod_monitor("x", "app", APP, "metrics"))]
        self.assertEqual(len(run([("kps", prometheus()), ("kps", allow([7777], peer))] + objs)[0]), 1)
        peer["podSelector"]["matchLabels"] = APP
        self.assertEqual(run([("kps", prometheus()), ("kps", allow([7777], peer))] + objs)[0], [])

    def test_unresolvable_endpoint_is_counted_not_failed(self) -> None:
        objs = [("app", service("x", "app", APP, {}, [{"name": "metrics", "port": 10250}])),
                ("app", service_monitor("x", "app", APP, [{"port": "metrics"}]))]
        problems, summary = run(self.base([]) + objs)
        self.assertEqual(problems, [])
        self.assertIn("1 monitor endpoint(s) unresolved", summary)

    def test_unnamespaced_object_only_stands_in_within_its_layer(self) -> None:
        pods = deployment("x", None, APP, {"metrics": 7777})
        mon = pod_monitor("x", "app", APP, "metrics")
        self.assertEqual(len(run(self.base([1]) + [("app", pods), ("app", mon)])[0]), 1)
        _, summary = run(self.base([1]) + [("other", pods), ("app", mon)])
        self.assertIn("1 monitor endpoint(s) unresolved", summary)

    def test_unselected_monitor_is_ignored(self) -> None:
        mon = pod_monitor("x", "app", APP, "metrics")
        mon["metadata"]["labels"] = {}
        objs = [("app", deployment("x", "app", APP, {"metrics": 7777})), ("app", mon)]
        self.assertEqual(run(self.base([1]) + objs)[0], [])


@unittest.skipUnless(shutil.which(guard.KUSTOMIZE) and shutil.which(guard.HELM), "kustomize/helm not on PATH")
class RealTreeMutation(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        layers = [Path("observability/kube-prometheus-stack"), Path("observability/crowdsec")]
        cls.pool, _, cls.rendered, rendered_layers, _ = guard.build_pool(layers)
        if rendered_layers != 2:
            raise unittest.SkipTest("a chart source was unreachable")

    def test_current_tree_admits_every_resolved_port(self) -> None:
        problems, summary, _ = guard.check_scrape_ports(self.rendered, self.pool)
        self.assertEqual(problems, [])
        self.assertNotIn(" 0 target port(s) resolved", summary)

    def test_removing_6060_fails_on_crowdsec(self) -> None:
        mutated = []
        hits = 0
        for layer, o in self.rendered:
            if o["kind"] == "NetworkPolicy" and o["metadata"]["name"] == "prometheus-allow":
                o = copy.deepcopy(o)
                for rule in o["spec"]["egress"]:
                    before = len(rule.get("ports") or [])
                    rule["ports"] = [p for p in rule.get("ports") or [] if p.get("port") != 6060]
                    hits += before - len(rule["ports"])
            mutated.append((layer, o))
        self.assertEqual(hits, 1, "prometheus-allow no longer lists 6060 exactly once — update this test")
        problems, _, _ = guard.check_scrape_ports(mutated, self.pool)
        crowdsec = [p for p in problems if "crowdsec" in p and "6060" in p]
        self.assertEqual(len(crowdsec), 2, problems)  # crowdsec-agent and crowdsec-lapi


if __name__ == "__main__":
    unittest.main(verbosity=1)
