# observability/grafana-dashboards

Operator-authored Grafana dashboards as ConfigMaps. Picked
up by the kube-prometheus-stack chart's bundled Grafana
dashboard sidecar (`kiwigrid/k8s-sidecar`), which watches
cluster-wide for ConfigMaps with the
`grafana_dashboard: "1"` label and imports them into the
running Grafana via its HTTP API.

Per
[ADR 0021](../../../homelab-docs/02-decisions/0021-observability-stack.md)
+ the convention pinned in
[`observability/kube-prometheus-stack/values.yaml`](../kube-prometheus-stack/values.yaml)
(grafana block trailing comment).

## What ships

Two starter dashboards. Per-app deep-dives emerge as
workload patterns settle (per
[TODO.md](../../../homelab-docs/TODO.md) "Operator-authored
Grafana dashboards").

| ConfigMap | Dashboard | Data sources |
|---|---|---|
| `grafana-dashboard-cluster-overview` | **Cluster overview** — node count + condition, pod totals, CPU/mem cluster-wide, top-10 PVC fill, top-10 pods by namespace, Cilium agent status, Argo CD app sync + health counts, pods-not-Running table | Prometheus (kube-state-metrics + node-exporter + cilium + argocd-metrics) |
| `grafana-dashboard-llm-gateway` | **LLM gateway** — requests/s by model, token throughput in/out, p50/p95/p99 latency by model, failed requests by exception class, per-team top-5, plus a Loki panel for `rejected_by_tag` / `rejected_by_secrets_scan` log events from the `llm-gateway` namespace | Prometheus (LiteLLM's `litellm_*` metrics via `apps/llm-gateway/`'s ServiceMonitor) + Loki |

Both dashboards land in a Grafana folder named `Homelab` via
the sidecar's `grafana_folder` annotation, so they don't
intermix with chart-default dashboards.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | ConfigMap resource list. No helm chart, no namespace — co-locates in `monitoring` (already created by [`observability/kube-prometheus-stack/namespace.yaml`](../kube-prometheus-stack/namespace.yaml)). |
| `cluster-overview.yaml` | ConfigMap with the cluster-overview dashboard JSON model in a single `cluster-overview.json` data key. |
| `llm-gateway.yaml` | ConfigMap with the llm-gateway dashboard JSON model in a single `llm-gateway.json` data key. |

## Conventions

- Filename = dashboard slug = ConfigMap data key. Keeps the
  three identifiers aligned so a grep across the layer
  resolves to one file.
- Dashboard `uid` is stable (`homelab-cluster-overview`,
  `homelab-llm-gateway`) — re-imports update in place rather
  than fork.
- Discovery label is the load-bearing contract:
  `grafana_dashboard: "1"`. The chart's sidecar matches on
  exactly that label across all namespaces; namespace
  placement is operator preference (we co-locate with
  Grafana for discoverability, but anywhere works).
- `grafana_folder: "Homelab"` annotation routes both
  dashboards into the `Homelab` folder.
- Datasource UIDs reference the chart-shipped names:
  `prometheus` (chart-default) and `loki` (added in
  [`observability/kube-prometheus-stack/values.yaml`](../kube-prometheus-stack/values.yaml)
  `additionalDataSources`).
- Each dashboard is a single screen (no rows / hidden
  panels) at the default Grafana grid (24-wide). Easier
  to scan during incident triage.

## Caveats

1. **LLM gateway tag rejections come from logs, not
   metrics.** The
   [pre_call hook](../../../llm-gateway/llm_gateway/hooks/pre_call.py)
   currently emits `log.warning("rejected_by_tag" ...)`
   structured-log events but no Prometheus counter. The
   dashboard's tag-rejection panel is a Loki query against
   the `llm-gateway` namespace. When the hook grows
   counters (`rejected_by_tag_total{model,tag}`,
   `rejected_by_secrets_scan_total{model}`), swap that panel
   for a timeseries against the counter rate and update this
   README.
2. **`team` label depends on virtual-key configuration.**
   LiteLLM emits `team=<team>` on `litellm_requests_metric`
   only when the master-key-issued virtual key has a team
   set (per LiteLLM's team management). Until consumers
   start using team-scoped virtual keys, the per-team panel
   shows a single `unset` series.
3. **`machine_cpu_cores` denominator on the cluster CPU
   panel.** That metric comes from cAdvisor (kubelet),
   which the chart enables. If `kubelet` ServiceMonitor
   is disabled, the CPU % panel goes blank — falls back to
   raw `rate(node_cpu_seconds_total)` if so.
4. **Argo CD metrics scrape.** Panels 3 and 4 query
   `argocd_app_info` — that requires a ServiceMonitor for
   `argocd-metrics` (chart-default in argo-cd helm chart).
   If
   [`bootstrap/argocd/`](../../bootstrap/argocd/)
   doesn't enable it (it's a chart-default off-by-flag),
   the Argo panels show `No data`.
5. **No alerts.** Dashboards visualize; alert rules live
   in
   [`observability/kube-prometheus-stack/`](../kube-prometheus-stack/)
   PrometheusRules + AlertmanagerConfig. Operator looking
   at a red panel here should expect a parallel alert
   already firing.
6. **No ExternalSecret.** This layer stores no secrets;
   the OpenBao-paths-to-seed contract from
   [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md)
   doesn't apply (and is enforced by
   [`scripts/check-eso-readme.sh`](../../scripts/check-eso-readme.sh)
   only when an ExternalSecret manifest is present).
7. **JSON authored by hand, not exported from Grafana.**
   Operator-authored dashboards stay minimal so PR diffs
   are reviewable. If the operator iterates in Grafana's
   UI and exports JSON, paste the export into the data
   key, but expect a noisier diff.

## Related

- [ADR 0021](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — the observability-stack decision; D7 covers Grafana's
  role.
- [ADR 0007](../../../homelab-docs/02-decisions/0007-external-llm-egress-gateway.md)
  + [ADR 0026](../../../homelab-docs/02-decisions/0026-litellm-as-llm-gateway-implementation.md)
  — the LLM gateway being dashboarded.
- [`observability/kube-prometheus-stack/`](../kube-prometheus-stack/)
  — Grafana itself + the dashboard sidecar.
- [`apps/llm-gateway/`](../../apps/llm-gateway/)
  — LiteLLM proxy emitting the `litellm_*` metrics.
- [`llm-gateway/`](../../../llm-gateway/) (sibling repo)
  — pre/post-call hooks; tag-rejection log events.
