#!/usr/bin/env python3
"""Every selector authored in a layer must select something that layer renders.

THE BUG CLASS (found 2026-09-12). platform/woodpecker/servicemonitor.yaml
selected `app.kubernetes.io/name: woodpecker` + `app.kubernetes.io/component:
server`. The chart renders `name=server` + `instance=woodpecker` and no
`component` label at all, so for 111 days Prometheus had zero Woodpecker
targets — and nothing said so, because a selector that matches nothing is not
an error to anyone: the ServiceMonitor is Accepted, the Prometheus CR is
Healthy, the dashboard is merely empty. The two CiliumNetworkPolicies in the
same file select the same phantom labels: `kubectl get cep -n woodpecker`
shows ingress/egress enforcing `<none>` on both pods, which have run
default-allow since day one under a policy file that reads as a lockdown.

A selector is a claim about labels some other object carries. This check
renders each layer (`kustomize build --enable-helm`, the same render Argo
performs) and asserts, for every selector-bearing object the layer itself
authors, that at least one rendered object in the same namespace carries every
label it names:

    ServiceMonitor  spec.selector           -> a rendered Service
    PodMonitor      spec.selector           -> a rendered pod template
    NetworkPolicy   spec.podSelector        -> a rendered pod template
    CiliumNetworkPolicy spec.endpointSelector -> a rendered pod template

and that every ServiceMonitor/PodMonitor carries `release: kube-prometheus-stack`,
the one label the Prometheus CR's {pod,service}MonitorSelector requires — a
monitor without it is created and never read (lessons.md, CloudNativePG).

Targets are pooled from EVERY layer's render, keyed by namespace, because a
policy may legitimately select pods another layer renders into the same
namespace (hubble-flow-exporter selects Loki's pods in `monitoring`). Pod
templates come from Deployment/StatefulSet/DaemonSet/Job/CronJob/Pod and, for
operator-owned pods no render contains, from a small model of what the operator
stamps on them: CNPG `Cluster`, prometheus-operator `Prometheus`/`Alertmanager`,
Altinity `ClickHouseInstallation` (labels observed live 2026-09-12). An empty
selector selects everything and passes. A monitor whose namespaceSelector
reaches other namespaces, matchExpressions, and peer selectors
(fromEndpoints/toEndpoints, ingress/egress `from`/`to`) are out of scope: a
wrong peer selector fails closed and is found by the traffic it drops, while a
wrong subject selector fails OPEN and is found by nothing.

Objects rendered by a chart are not judged — a chart's own ServiceMonitor is
upstream's claim about upstream's labels. Only objects whose kind+name appear
in the layer's own committed manifests are checked.

EXEMPTIONS live in scripts/selector-exemptions.yaml: {layer, kind, name,
reason, owner}. An exemption must name a selector that actually fails; one that
no longer does is stale and FAILS the check, so the list cannot outlive the
defect it excuses (the 2026-09-11 repo-blind-exemption lesson).

Counts are printed beside the verdict. Read-only; never contacts a cluster.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import yaml

REPO = Path(__file__).resolve().parent.parent
EXEMPTIONS = REPO / "scripts" / "selector-exemptions.yaml"
KUSTOMIZE = os.environ.get("KUSTOMIZE_BIN", "kustomize")
HELM = os.environ.get("HELM_BIN", "helm3")

SELECTOR_KINDS = {
    "ServiceMonitor": ("spec", "selector"),
    "PodMonitor": ("spec", "selector"),
    "NetworkPolicy": ("spec", "podSelector"),
    "CiliumNetworkPolicy": ("spec", "endpointSelector"),
}
MONITOR_KINDS = {"ServiceMonitor", "PodMonitor"}
# The label the Prometheus CR's podMonitorSelector / serviceMonitorSelector
# require (kube-prometheus-stack, observed 2026-09-12: matchLabels
# release=kube-prometheus-stack on both). A monitor without it is inert.
MONITOR_LABEL = ("release", "kube-prometheus-stack")
POD_TEMPLATE_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "ReplicaSet"}
UNREACHABLE = ("x509", "tls: failed", "FetchReference", "connection refused", "no such host")


def die(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def git_files(pattern: str) -> list[str]:
    out = subprocess.run(["git", "ls-files", pattern], cwd=REPO, check=True, capture_output=True, text=True)
    return [line for line in out.stdout.splitlines() if line]


def load_docs(text: str) -> list[dict[str, Any]]:
    docs = []
    for doc in yaml.safe_load_all(text):
        if isinstance(doc, dict) and doc.get("kind") and isinstance(doc.get("metadata"), dict):
            docs.append(doc)
    return docs


def render(layer: Path) -> tuple[list[dict[str, Any]] | None, str]:
    proc = subprocess.run(
        [KUSTOMIZE, "build", "--enable-helm", "--helm-command", HELM, str(layer)],
        cwd=REPO, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return None, proc.stderr.strip()
    return load_docs(proc.stdout), ""


def own_objects(layer: Path) -> set[tuple[str, str]]:
    """(kind, name) of selector-bearing objects written in the layer's own files."""
    found: set[tuple[str, str]] = set()
    for rel in git_files(f"{layer.relative_to(REPO)}/*.y*ml"):
        p = REPO / rel
        if "/charts/" in rel or p.name == "kustomization.yaml" or p.name.startswith("values"):
            continue
        if p.parent != layer:  # only the layer's top level authors its objects
            continue
        try:
            docs = load_docs(p.read_text())
        except yaml.YAMLError:
            continue  # templated (.j2-rendered placeholders) or otherwise not plain YAML
        for d in docs:
            if d["kind"] in SELECTOR_KINDS:
                found.add((d["kind"], d["metadata"].get("name", "")))
    return found


def pod_labels_of(doc: dict[str, Any]) -> dict[str, str] | None:
    kind = doc["kind"]
    spec = doc.get("spec") or {}
    if kind == "Pod":
        return dict(doc["metadata"].get("labels") or {})
    if kind in POD_TEMPLATE_KINDS:
        return dict(((spec.get("template") or {}).get("metadata") or {}).get("labels") or {})
    if kind == "CronJob":
        tpl = ((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}
        return dict((tpl.get("metadata") or {}).get("labels") or {})
    if kind == "Cluster" and str(doc.get("apiVersion", "")).startswith("postgresql.cnpg.io/"):
        # Observed on a live instance pod 2026-09-12 (forgejo-pg-1), operator
        # 1.27-era labels; instanceName/instanceRole/role vary per pod and are
        # left out so a selector cannot pin one replica by accident.
        name = doc["metadata"]["name"]
        labels = {
            "cnpg.io/cluster": name, "cnpg.io/podRole": "instance",
            "app.kubernetes.io/name": "postgresql", "app.kubernetes.io/instance": name,
            "app.kubernetes.io/component": "database", "app.kubernetes.io/managed-by": "cloudnative-pg",
        }
        labels.update(((spec.get("inheritedMetadata") or {}).get("labels") or {}))
        return labels
    api = str(doc.get("apiVersion", ""))
    name = doc["metadata"].get("name", "")
    if kind in ("Prometheus", "Alertmanager") and api.startswith("monitoring.coreos.com/"):
        # prometheus-operator stamps app.kubernetes.io/name=<kind lower> and
        # <kind lower>=<name> on the StatefulSet pods it creates (live 2026-09-12:
        # app.kubernetes.io/name=prometheus, prometheus=kube-prometheus-stack-prometheus).
        low = kind.lower()
        return {"app.kubernetes.io/name": low, low: name, "app.kubernetes.io/managed-by": "prometheus-operator"}
    if kind == "ClickHouseInstallation" and api.startswith("clickhouse.altinity.com/"):
        return {"clickhouse.altinity.com/chi": name, "clickhouse.altinity.com/app": "chop"}
    return None


def normalise_cilium_key(key: str) -> str | None:
    """Strip Cilium source prefixes; None means the key is not a pod label."""
    for prefix in ("k8s:", "any:"):
        if key.startswith(prefix):
            key = key[len(prefix):]
    if key.startswith("reserved:") or key.startswith("io.cilium.k8s."):
        return None
    return key


def evaluate(obj: dict[str, Any], pool: dict[str | None, dict[str, list[dict[str, str]]]]) -> str | None:
    """Return a failure reason, or None when the selector selects something."""
    kind = obj["kind"]
    ns = obj["metadata"].get("namespace")
    labels = obj["metadata"].get("labels") or {}
    if kind in MONITOR_KINDS and labels.get(MONITOR_LABEL[0]) != MONITOR_LABEL[1]:
        return f"missing label {MONITOR_LABEL[0]}={MONITOR_LABEL[1]}; the Prometheus CR never selects it"

    a, b = SELECTOR_KINDS[kind]
    sel = (obj.get(a) or {}).get(b)
    if not sel:  # absent or {} selects every endpoint/pod
        return None
    if sel.get("matchExpressions"):
        return None  # out of scope; only matchLabels is asserted
    want: dict[str, str] = {}
    for k, v in (sel.get("matchLabels") or {}).items():
        if kind == "CiliumNetworkPolicy":
            nk = normalise_cilium_key(k)
            if nk is None:
                return None  # entity/reserved selection — not a label claim
            if nk == "io.kubernetes.pod.namespace":
                if ns and str(v) != ns:
                    return f"endpointSelector names namespace {v!r} but the policy lives in {ns!r}"
                continue
            k = nk
        want[k] = str(v)
    if not want:
        return None
    if kind in MONITOR_KINDS:
        nsel = (obj.get("spec") or {}).get("namespaceSelector") or {}
        if nsel.get("any") or [n for n in nsel.get("matchNames", []) if n != ns]:
            return None  # cross-namespace claim; out of scope
    bucket = "services" if kind == "ServiceMonitor" else "pods"
    what = "Service" if kind == "ServiceMonitor" else "pod template"
    candidates = list(pool.get(ns, {}).get(bucket, [])) + list(pool.get(None, {}).get(bucket, []))
    for c in candidates:
        if all(c.get(k) == v for k, v in want.items()):
            return None
    shown = ", ".join(f"{k}={v}" for k, v in want.items())
    return f"no rendered {what} in namespace {ns!r} carries {{{shown}}} ({len(candidates)} candidate(s))"


def main() -> int:
    for tool in (KUSTOMIZE, HELM):
        if shutil.which(tool) is None:
            die(f"required tool missing: {tool}")
    exemptions: list[dict[str, Any]] = []
    if EXEMPTIONS.exists():
        exemptions = (yaml.safe_load(EXEMPTIONS.read_text()) or {}).get("exemptions") or []
        for e in exemptions:
            for field in ("layer", "kind", "name", "reason", "owner"):
                if not e.get(field):
                    die(f"{EXEMPTIONS.name}: exemption {e} lacks '{field}'")
    exempt = {(e["layer"], e["kind"], e["name"]): e for e in exemptions}
    used: set[tuple[str, str, str]] = set()

    layers = sorted({Path(f).parent for f in git_files("*kustomization.yaml")
                     if "/charts/" not in f and not f.startswith("apps/")
                     and not f.startswith("components/") and not f.startswith("bootstrap/")})
    checked = failed = exempted = skipped_layers = rendered_layers = 0
    problems: list[str] = []
    # Pass 1: render every layer once; pool Services and pod templates by namespace.
    pool: dict[str | None, dict[str, list[dict[str, str]]]] = {}
    authored: list[tuple[Path, dict[str, Any]]] = []
    for layer_rel in layers:
        layer = REPO / layer_rel
        rendered, err = render(layer)
        if rendered is None:
            if any(tok in err for tok in UNREACHABLE):
                print(f"SKIPPED {layer_rel}: chart source unreachable from this host")
                skipped_layers += 1
                continue
            die(f"{layer_rel}: render failed:\n{err}")
        rendered_layers += 1
        own = own_objects(layer)
        for obj in rendered:
            ns = obj["metadata"].get("namespace")
            slot = pool.setdefault(ns, {"services": [], "pods": []})
            if obj["kind"] == "Service":
                slot["services"].append(dict(obj["metadata"].get("labels") or {}))
            pl = pod_labels_of(obj)
            if pl is not None:
                slot["pods"].append(pl)
            if (obj["kind"], obj["metadata"].get("name", "")) in own:
                authored.append((layer_rel, obj))
    # Pass 2: judge every authored selector against the whole pool.
    for layer_rel, obj in authored:
            key = (obj["kind"], obj["metadata"].get("name", ""))
            checked += 1
            reason = evaluate(obj, pool)
            ekey = (str(layer_rel), obj["kind"], obj["metadata"].get("name", ""))
            if reason is None:
                continue
            if ekey in exempt:
                used.add(ekey)
                exempted += 1
                print(f"EXEMPT {layer_rel} {obj['kind']}/{key[1]}: {reason}\n       reason: {exempt[ekey]['reason']} (owner: {exempt[ekey]['owner']})")
                continue
            failed += 1
            problems.append(f"{layer_rel} {obj['kind']}/{key[1]}: {reason}")

    stale = [k for k in exempt if k not in used]
    for k in stale:
        problems.append(f"stale exemption in {EXEMPTIONS.name}: {k[0]} {k[1]}/{k[2]} no longer fails — remove it")
    for p in problems:
        print(f"FAIL: {p}", file=sys.stderr)
    verdict = "FAIL" if problems else "PASS"
    print(f"{verdict}: {checked} selector(s) checked across {rendered_layers} rendered layer(s); "
          f"{failed} failing, {exempted} exempt, {len(stale)} stale exemption(s), {skipped_layers} layer(s) skipped")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
