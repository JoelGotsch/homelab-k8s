# observability/alloy

Alloy DaemonSet — log shipper to Loki. Per
[ADR 0021 D6](../../../homelab-docs/02-decisions/0021-observability-stack.md).

Replaces the older Promtail / Grafana Agent agents (Alloy is
the operator-facing-agent rename + flow-language refactor).

## What it ships

| Source | Loki labels | Notes |
|---|---|---|
| Pod logs from `/var/log/pods` (Kubernetes-discovered on this node) | `namespace`, `pod`, `container`, `app`, `component` | Drops k8s healthz probe-noise |
| Journald from each node's `/var/log/journal` | `job=journald`, `host`, `unit` | System logs + Talos audit-log path |

Both ship to `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Pins grafana/alloy chart 0.10.0. |
| `values.yaml` | DaemonSet (one per node, all tolerations). Alloy flow-language config inline (River syntax). |
| `networkpolicy.yaml` | Ingress from Prometheus (self-metrics); egress to kube-API (pod discovery) + Loki + kube-DNS. |
| `servicemonitor.yaml` | Self-metrics scrape via kube-prometheus-stack. |

## Bring-up wiring

Trigger: Loki layer Healthy. Operator sees pod logs in
Grafana → Explore → Loki data source → `{namespace="ntfy"}`
within ~30s of Alloy + Loki both Running.

| Bring-up step | What lands |
|---|---|
| Argo sync `observability/loki/` | Loki StatefulSet up |
| Argo sync this layer | Alloy DaemonSet on every node; first logs flow within ~30s |
| Argo sync `observability/kube-prometheus-stack/` (with Loki data source enabled) | Grafana queries surface |

## Caveats

1. **Alloy runs as root** for journald read access. Privileged
   in the k8s sense (no privileged-PSA escape; `runAsUser: 0`
   only). Acceptable trade-off — journald is the system-level
   audit + Falco syscall path; without it the operator loses
   half the security-forensic stream per ADR 0021 D8.

2. **No log enrichment beyond k8s metadata.** Operator can
   add `loki.process` stages (label_extract, JSON parse,
   etc.) inside `values.yaml` as workload-specific needs
   emerge. Alloy's flow-language is operator-readable.

3. **`drop` for `GET /healthz`** is one specific noise filter
   — bunch of others may emerge. Operator extends the
   `loki.process` rules; each drop is operator-deliberate
   (don't drop logs you might need for forensic review).

4. **Pod discovery via the kubernetes role + node-local
   selector** scales fine. Alloy uses the kube-API watch —
   one connection per node; reasonable load.

5. **No HTTPS to the kube-API.** The egress NetworkPolicy
   allows :6443 + :443 to api-server pods. Alloy uses the
   pod's ServiceAccount token from the projected mount;
   standard k8s pattern.

6. **Self-metrics on port 12345** — chart default. Quirky
   port choice but documented; the ServiceMonitor matches.

7. **No buffering on disk.** If Loki is unreachable for
   longer than Alloy's in-memory buffer, log lines drop.
   Acceptable for homelab volume; if Loki HA becomes a
   thing, Alloy's `loki.write.default` block can grow a
   `wal` directory backed by a hostPath volume.

## Related

- [ADR 0021 D6](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — log aggregation choice.
- [observability/loki/](../loki/) — the log destination.
- [observability/kube-prometheus-stack/](../kube-prometheus-stack/)
  — Grafana queries + Prometheus self-metrics scrape.
