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

SCRAPE PORTS (TODO hl-0297, added 2026-09-13). Prometheus's egress is a PORT
ALLOWLIST (`prometheus-allow` in observability/kube-prometheus-stack): a
monitor whose target port is not listed gets `EGRESS DENIED` and a target at
up=0, or none at all. That trap fired six times — node-exporter, grafana, the
loki/alloy/coredns batch, longhorn 9500, CNPG 9187 (every cnpg_* series absent
for 8 days), and crowdsec 6060 the moment its selector was fixed. So, for EVERY
rendered monitor the Prometheus CR selects (chart-rendered included — longhorn
and argocd were chart monitors), each endpoint is resolved to the port number
Prometheus actually dials:

    ServiceMonitor  endpoint.port (Service port name) -> Service targetPort
                    (number, or a container port name on the Service's pods)
    PodMonitor      endpoint.port (container port name) -> containerPort

and that number must be admitted by an egress rule on the policies selecting
the Prometheus pod: a NetworkPolicy/CNP peer covering the target's namespace
with the port listed (or no port list). Host-network targets (node-exporter)
are not reached through namespace peers; they need a CNP `toEntities` rule
naming host/remote-node. A target the render cannot resolve (a selector-less
Service such as the kubelet's, pods an operator creates that no model covers,
a namespace no layer renders — e.g. argocd under bootstrap/) is counted as
unresolved, not failed. Monitors living in external app repositories are not
rendered here and are not covered.

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
HELM = os.environ.get("HELM_BIN", "helm")

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
# Container ports the operators stamp on pods no render contains (observed live
# 2026-09-13: woodpecker-pg-1, prometheus-...-prometheus-0, alertmanager-...-0).
CNPG_PORTS = {"postgresql": 5432, "metrics": 9187, "status": 8000}
OPERATOR_PORTS = {
    "Prometheus": {"http-web": 9090, "reloader-web": 8080},
    "Alertmanager": {"http-web": 9093, "reloader-web": 8080},
}
HOST_ENTITIES = {"host", "remote-node"}
ALL_ENTITIES = {"all", "cluster"}
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
        # Both also carry app.kubernetes.io/instance=<name>; Prometheus pods add
        # operator.prometheus.io/name=<name>, which the chart's own Service selects
        # (live 2026-09-13).
        low = kind.lower()
        labels = {"app.kubernetes.io/name": low, low: name, "app.kubernetes.io/instance": name,
                  "app.kubernetes.io/managed-by": "prometheus-operator"}
        if kind == "Prometheus":
            labels["operator.prometheus.io/name"] = name
        return labels
    if kind == "ClickHouseInstallation" and api.startswith("clickhouse.altinity.com/"):
        return {"clickhouse.altinity.com/chi": name, "clickhouse.altinity.com/app": "chop"}
    return None


def pod_spec_of(doc: dict[str, Any]) -> dict[str, Any] | None:
    """{labels, ports: {name: number}, host} for anything that becomes a pod."""
    labels = pod_labels_of(doc)
    if labels is None:
        return None
    kind = doc["kind"]
    spec = doc.get("spec") or {}
    podspec: dict[str, Any] = {}
    if kind == "Pod":
        podspec = spec
    elif kind in POD_TEMPLATE_KINDS:
        podspec = (spec.get("template") or {}).get("spec") or {}
    elif kind == "CronJob":
        podspec = ((((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {})
    ports: dict[str, int] = {}
    for c in (podspec.get("containers") or []) + (podspec.get("initContainers") or []):
        for cp in c.get("ports") or []:
            if cp.get("name") and isinstance(cp.get("containerPort"), int):
                ports[cp["name"]] = cp["containerPort"]
    if kind == "Cluster":
        ports = dict(CNPG_PORTS)
    elif kind in OPERATOR_PORTS:
        ports = dict(OPERATOR_PORTS[kind])
    return {"labels": labels, "ports": ports, "host": bool(podspec.get("hostNetwork"))}


def matches(labels: dict[str, str], want: dict[str, Any]) -> bool:
    return all(labels.get(k) == str(v) for k, v in want.items())


Rule = tuple[str, "str | None", "dict[str, str] | None", "set[int] | None"]


def egress_rules(policy: dict[str, Any]) -> list[Rule] | None:
    """(scope, namespace, pod labels, ports) per egress peer; scope is any-ns|ns|host.

    None = the policy does not restrict egress. A peer this model cannot read
    (matchExpressions) is dropped, so it can only make the guard stricter."""
    kind = policy["kind"]
    spec = policy.get("spec") or {}
    own_ns = policy["metadata"].get("namespace")
    out: list[Rule] = []

    def numbers(raw: list[Any]) -> set[int] | None:
        nums = set()
        for pt in raw:
            try:
                nums.add(int(pt))
            except (TypeError, ValueError):
                return None  # named port: cannot compare, treat as unrestricted
        return nums or None

    if kind == "NetworkPolicy":
        if "Egress" not in (spec.get("policyTypes") or []) and "egress" not in spec:
            return None
        for rule in spec.get("egress") or []:
            ports = numbers([p.get("port") for p in rule.get("ports") or []]) if rule.get("ports") else None
            peers = rule.get("to") or []
            if not peers:
                out += [("any-ns", None, None, ports), ("host", None, None, ports)]
            for peer in peers:
                if "ipBlock" in peer:
                    continue
                psel = peer.get("podSelector")
                if psel is not None and psel.get("matchExpressions"):
                    continue
                pods = dict(psel.get("matchLabels") or {}) if psel is not None else None
                nsel = peer.get("namespaceSelector")
                if nsel is None:
                    out.append(("ns", own_ns, pods, ports))
                elif not nsel.get("matchLabels") and not nsel.get("matchExpressions"):
                    out.append(("any-ns", None, pods, ports))
                elif (nsel.get("matchLabels") or {}).get("kubernetes.io/metadata.name") and len(nsel["matchLabels"]) == 1:
                    out.append(("ns", nsel["matchLabels"]["kubernetes.io/metadata.name"], pods, ports))
        return out
    # CiliumNetworkPolicy
    if "egress" not in spec:
        return None
    for rule in spec.get("egress") or []:
        raw = [p.get("port") for tp in rule.get("toPorts") or [] for p in tp.get("ports") or []]
        ports = numbers(raw) if raw else None
        ents = set(rule.get("toEntities") or [])
        if ents & ALL_ENTITIES:
            out += [("any-ns", None, None, ports), ("host", None, None, ports)]
        if ents & HOST_ENTITIES:
            out.append(("host", None, None, ports))
        for ep in rule.get("toEndpoints") or []:
            if ep.get("matchExpressions"):
                continue
            ns, pods, readable = own_ns, {}, True
            for k, v in (ep.get("matchLabels") or {}).items():
                nk = normalise_cilium_key(k)
                if nk is None:
                    readable = False
                elif nk == "io.kubernetes.pod.namespace":
                    ns = str(v)
                else:
                    pods[nk] = str(v)
            if readable:
                out.append(("ns", ns, pods or None, ports))
    return out


def admitted(rules: list[Rule], ns: str | None, port: int, host: bool, labels: dict[str, str]) -> bool:
    for scope, rns, pods, ports in rules:
        if ports is not None and port not in ports:
            continue
        if host and scope == "host":
            return True
        if host or (pods is not None and not matches(labels, pods)):
            continue
        if scope == "any-ns" or (scope == "ns" and rns == ns):
            return True
    return False


def scrape_targets(mon: dict[str, Any], pool: dict[str | None, dict[str, list[Any]]],
                   layer: str) -> tuple[list[tuple[str, str | None, int, bool, tuple[tuple[str, str], ...]]], list[str]]:
    """([(endpoint-port-name, namespace, number, host, pod labels)], [unresolved endpoint port names]).

    A chart object rendered without metadata.namespace lands in its Argo
    Application's destination namespace, which the render does not know; like
    evaluate(), treat it as living in the monitor's namespace — but only when it
    comes from the monitor's own layer, so two charts' un-namespaced objects
    never stand in for each other."""
    spec = mon.get("spec") or {}
    own_ns = mon["metadata"].get("namespace")
    nsel = spec.get("namespaceSelector") or {}
    if nsel.get("any"):
        namespaces = [n for n in pool if n is not None]
    else:
        namespaces = list(nsel.get("matchNames") or [own_ns])
    sel = spec.get("selector") or {}
    if sel.get("matchExpressions"):
        return [], ["<matchExpressions selector>"]
    want = sel.get("matchLabels") or {}
    found: list[tuple[str, str | None, int, bool, tuple[tuple[str, str], ...]]] = []
    unresolved: list[str] = []

    def lab(pd: dict[str, Any]) -> tuple[tuple[str, str], ...]:
        return tuple(sorted(pd["labels"].items()))

    def bucket(ns: str | None, name: str) -> list[dict[str, Any]]:
        return list(pool.get(ns, {}).get(name, [])) + [x for x in pool.get(None, {}).get(name, []) if x["layer"] == layer]

    if mon["kind"] == "ServiceMonitor":
        for ep in spec.get("endpoints") or []:
            hit = False
            for ns in namespaces:
                for svc in bucket(ns, "service_specs"):
                    if not matches(svc["labels"], want):
                        continue
                    for sp in svc["ports"]:
                        if ep.get("port") is not None and sp.get("name") != ep.get("port"):
                            continue
                        if ep.get("port") is None and ep.get("targetPort") is None:
                            continue
                        target = ep.get("targetPort") or sp.get("targetPort") or sp.get("port")
                        backing = [pd for pd in bucket(ns, "pod_specs")
                                   if svc["selector"] and matches(pd["labels"], svc["selector"])]
                        for pd in backing:
                            num = target if isinstance(target, int) else pd["ports"].get(target)
                            if num:
                                found.append((str(ep.get("port") or target), ns, num, pd["host"], lab(pd)))
                                hit = True
            if not hit:
                unresolved.append(str(ep.get("port") or ep.get("targetPort")))
    else:
        for ep in spec.get("podMetricsEndpoints") or []:
            hit = False
            name = ep.get("port")
            for ns in namespaces:
                for pd in bucket(ns, "pod_specs"):
                    if matches(pd["labels"], want) and name in pd["ports"]:
                        found.append((name, ns, pd["ports"][name], pd["host"], lab(pd)))
                        hit = True
            if not hit:
                unresolved.append(str(ep.get("port") or ep.get("targetPort")))
    return sorted(set(found), key=lambda t: (str(t[1]), t[2], t[4])), unresolved


def check_scrape_ports(rendered_all: list[tuple[Path, dict[str, Any]]],
                       pool: dict[str | None, dict[str, list[Any]]]) -> tuple[list[str], str, list[str]]:
    """Problems, a one-line summary, and one detail line per unresolved endpoint."""
    prom = [o for _, o in rendered_all if o["kind"] == "Prometheus"
            and str(o.get("apiVersion", "")).startswith("monitoring.coreos.com/")]
    if not prom:
        return [], "scrape ports: no Prometheus CR rendered — not checked", []
    problems: list[str] = []
    details: list[str] = []
    resolved = unresolved = host_targets = 0
    seen: set[tuple[str, str, str]] = set()
    for cr in prom:
        pns = cr["metadata"].get("namespace")
        plabels = pod_labels_of(cr) or {}
        rules: list[Rule] = []
        restricted = False
        for _, pol in rendered_all:
            if pol["kind"] not in ("NetworkPolicy", "CiliumNetworkPolicy") or pol["metadata"].get("namespace") != pns:
                continue
            sel = (pol.get("spec") or {}).get("podSelector" if pol["kind"] == "NetworkPolicy" else "endpointSelector")
            if sel is None or sel.get("matchExpressions") or not matches(plabels, sel.get("matchLabels") or {}):
                continue
            r = egress_rules(pol)
            if r is None:
                continue
            restricted = True
            rules += r
        if not restricted:
            continue
        msel = (cr.get("spec") or {})
        for layer_rel, mon in rendered_all:
            if mon["kind"] not in MONITOR_KINDS:
                continue
            want = (msel.get("serviceMonitorSelector" if mon["kind"] == "ServiceMonitor" else "podMonitorSelector") or {}).get("matchLabels") or {}
            if not matches(mon["metadata"].get("labels") or {}, want):
                continue
            key = (mon["kind"], str(mon["metadata"].get("namespace")), mon["metadata"].get("name", ""))
            if key in seen:
                continue
            seen.add(key)
            targets, unres = scrape_targets(mon, pool, str(layer_rel))
            unresolved += len(unres)
            details += [f"{layer_rel} {mon['kind']}/{key[2]} port {u!r}" for u in unres]
            flagged: set[tuple[str | None, int, bool]] = set()
            for pname, ns, num, host, labels in targets:
                resolved += 1
                host_targets += host
                if not admitted(rules, ns, num, host, dict(labels)) and (ns, num, host) not in flagged:
                    flagged.add((ns, num, host))
                    where = "host-network target (needs a CNP toEntities host/remote-node rule)" if host else f"namespace {ns!r}"
                    problems.append(f"{layer_rel} {mon['kind']}/{key[2]}: port {pname!r} resolves to {num} in {where}, "
                                    f"which no egress rule on the Prometheus pod admits — the target will be up=0 "
                                    f"(add {num} to prometheus-allow's port allowlist)")
    return problems, (f"scrape ports: {resolved} target port(s) resolved ({host_targets} host-network), "
                      f"{unresolved} monitor endpoint(s) unresolved by the render, {len(problems)} not admitted"), details


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


def build_pool(layers: list[Path]) -> tuple[dict[str | None, dict[str, list[Any]]], list[tuple[Path, dict[str, Any]]],
                                          list[tuple[Path, dict[str, Any]]], int, int]:
    """Pass 1: render every layer once; pool Services and pod templates by namespace."""
    pool: dict[str | None, dict[str, list[Any]]] = {}
    authored: list[tuple[Path, dict[str, Any]]] = []
    rendered_all: list[tuple[Path, dict[str, Any]]] = []
    rendered_layers = skipped_layers = 0
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
            slot = pool.setdefault(ns, {"services": [], "pods": [], "service_specs": [], "pod_specs": []})
            rendered_all.append((layer_rel, obj))
            if obj["kind"] == "Service":
                slot["services"].append(dict(obj["metadata"].get("labels") or {}))
                sspec = obj.get("spec") or {}
                slot["service_specs"].append({"layer": str(layer_rel), "labels": dict(obj["metadata"].get("labels") or {}),
                                              "selector": dict(sspec.get("selector") or {}),
                                              "ports": list(sspec.get("ports") or [])})
            pl = pod_labels_of(obj)
            if pl is not None:
                slot["pods"].append(pl)
                ps = pod_spec_of(obj)
                if ps is not None:
                    slot["pod_specs"].append({"layer": str(layer_rel), **ps})
            if (obj["kind"], obj["metadata"].get("name", "")) in own:
                authored.append((layer_rel, obj))
    return pool, authored, rendered_all, rendered_layers, skipped_layers


def main() -> int:
    verbose = "--verbose" in sys.argv[1:]
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
    checked = failed = exempted = 0
    problems: list[str] = []
    pool, authored, rendered_all, rendered_layers, skipped_layers = build_pool(layers)
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

    port_problems, port_summary, port_details = check_scrape_ports(rendered_all, pool)
    problems += port_problems
    if verbose:
        for d in port_details:
            print(f"UNRESOLVED scrape port (not checked): {d}")

    stale = [k for k in exempt if k not in used]
    for k in stale:
        problems.append(f"stale exemption in {EXEMPTIONS.name}: {k[0]} {k[1]}/{k[2]} no longer fails — remove it")
    for p in problems:
        print(f"FAIL: {p}", file=sys.stderr)
    verdict = "FAIL" if problems else "PASS"
    print(f"{verdict}: {checked} selector(s) checked across {rendered_layers} rendered layer(s); "
          f"{failed} failing, {exempted} exempt, {len(stale)} stale exemption(s), {skipped_layers} layer(s) skipped; "
          f"{port_summary}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
