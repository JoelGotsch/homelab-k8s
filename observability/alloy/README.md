# observability/alloy

Alloy DaemonSet — log shipper to Loki. Per
[ADR 0021 D6](../../../homelab-docs/02-decisions/0021-observability-stack.md).

Replaces the older Promtail / Grafana Agent agents (Alloy is
the operator-facing-agent rename + flow-language refactor).

## What it ships

| Source | Loki labels | Notes |
|---|---|---|
| Pod logs, tailed from the node's `/var/log/pods/<ns>_<pod>_<uid>/<container>/*.log` (`local.file_match` + `loki.source.file`; pods discovered on this node via `discovery.kubernetes`) | `namespace`, `pod`, `container`, `node`, `app`, `component`, `stream` | `stage.cri` parses the CRI line format; drops k8s healthz probe-noise and lines older than Loki's 168h window |
| kube-apiserver audit log, tailed from `/var/log/audit/kube/kube-apiserver.log` on the control planes (`local.file_match` + `loki.source.file`; the directory is empty on workers) | `job="kube-apiserver-audit"`, `node` | `stage.json` lifts `verb`, `user.username`→`user`, `objectRef.resource`→`resource`, `responseStatus.code`→`code`, `stage`, `level` into **structured metadata** (not labels); entry time = `stageTimestamp`; same 168h `stage.drop`. What the apiserver writes is decided by `homelab-infra/talos/patches/kube-apiserver-audit-policy.yaml` (2026-09-14). Query: `{job="kube-apiserver-audit"} \| user="admin" \| verb="delete"` |

Ships to `http://loki.monitoring.svc.cluster.local:3100/loki/api/v1/push`.
There is no journald source: Talos has no journald (node logs go to the
`talos-log-sink` Vector DaemonSet, see the NOTE in `values.yaml`).

Until 2026-09-14 the pod-log source was `loki.source.kubernetes`, which
streamed every container's stdout through the kube-apiserver (~160 open
log streams across the three apiservers, 2.7 reconnects/s). The files
were already host-mounted; the switch is recorded in
`99-journal/2026-09-14-the-scrape-that-scraped-nothing.md`.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Pins the grafana/alloy chart (Renovate-managed, from the Forgejo mirror). |
| `values.yaml` | DaemonSet (one per node, all tolerations). Alloy flow-language config inline (River syntax). Validated by `scripts/check-alloy-config.sh` (pre-commit, needs `alloy`). |
| `networkpolicy.yaml` + `ciliumnetworkpolicy-egress.yaml` | Ingress from Prometheus (self-metrics); egress to Loki + kube-DNS, and (CNP, `toEntities: [kube-apiserver]`) to the kube-API for pod discovery. |
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

## Log-derived metrics

`loki.process "janitor_metrics"` is a second branch fed from the pod-log
pipeline that forwards nothing to Loki and only derives Prometheus series,
exposed on Alloy's own `/metrics` (scraped by `servicemonitor.yaml`). It
exists because a CronJob cannot be scraped and this estate has no
Pushgateway by decision (ADR 0062) and no textfile collector (Talos).

| Source line (stdout of `reboot-cascade-janitor`) | Series |
|---|---|
| `[metric] janitor_remediation_total signature=… action=… target_namespace=… target_pod=… node=… dry_run=…` | `janitor_remediation_total{signature,action,target_namespace,target_pod,node,dry_run}` (counter, 1h idle expiry) |
| `[metric] janitor_state_streak node=… value=N` | `janitor_state_streak{node}` (gauge, 15m idle expiry) |
| `[metric] janitor_run_timestamp_seconds value=…` / `janitor_run_duration_seconds value=…` | gauges, 1h idle expiry |

The janitor's own stream labels (`pod`, `instance`, …) are dropped for
the metric only, so a counter survives the Job pod changing every tick;
the series still carry Alloy's scrape labels, so consumers aggregate with
`sum by (target_…)`. The line format is a contract with
`infrastructure/reboot-cascade-janitor/reboot-cascade-janitor.yaml` (its
fixture scenarios 15–18 pin the lines) and the alerts live in
`observability/kube-prometheus-stack/janitor-rules.yaml`. Expiry is
deliberate: a janitor that stops running produces *absence*, which
`JanitorNotRunning` alerts on, not a stale last value.

`loki.process "backup_metrics"` is the same mechanism for the daily
Storage Box fill check in `backup-cronjobs`:

| Source line (stdout of `storagebox-fill-check`) | Series |
|---|---|
| `[metric] storagebox_df size_bytes=N used_bytes=N avail_bytes=N` | `storagebox_size_bytes`, `storagebox_used_bytes`, `storagebox_avail_bytes` (gauges, 1h idle expiry) |

Its selector names the check's `app` label, and its regex ends in `\s*$`
rather than `$`: it was written for `loki.source.kubernetes`, which passed
each entry on with its trailing newline, and an RE2 `$` does not match
before it (replayed through Alloy v1.19.2 on 2026-09-11). `loki.source.file`
+ `stage.cri` strip it, so since 2026-09-14 both forms match. The alerts live in
`infrastructure/backup-cronjobs/prometheusrule-footprint.yaml` and read
the gauges through `last_over_time`, so the 1h expiry only has to outlast
one scrape.

## Caveats

1. **Alloy runs as root with `CAP_DAC_READ_SEARCH`** because the
   kubelet writes `/var/log/pods/*/*/*.log` as `0640 root:root`
   (verified on worker1, 2026-09-14) and the apiserver writes
   `/var/log/audit/kube/` as `0700 nobody:nogroup` with `0600` files —
   root with every capability dropped cannot stat those (verified from
   the running pods the same day). Not privileged in the k8s sense
   (`runAsUser: 0`, read-only root FS, every other capability dropped,
   read-only hostPath); `DAC_READ_SEARCH` bypasses read/search checks
   only, never write. The historical reason (journald) never applied
   on Talos.

2. **No log enrichment beyond k8s metadata.** Operator can
   add `loki.process` stages (label_extract, JSON parse,
   etc.) inside `values.yaml` as workload-specific needs
   emerge. Alloy's flow-language is operator-readable.

3. **`drop` for `GET /healthz`** is one specific noise filter
   — bunch of others may emerge. Operator extends the
   `loki.process` rules; each drop is operator-deliberate
   (don't drop logs you might need for forensic review).

4. **Pod discovery via the kubernetes role + node-local
   selector** — one watch per node for metadata only. The
   log bytes no longer cross the apiserver (2026-09-14).

5. **Positions are not persisted.** `storagePath` is the `/tmp`
   emptyDir, so a restarted Alloy re-reads every file on its node
   from the start (chosen over `tail_from_end`, which would lose
   the first seconds of every new pod). Loki de-duplicates
   identical entries at query time; the cost is ingest bandwidth
   on restart. A hostPath for positions is TODO hl-0306.

6. **kube-API egress** is the `toEntities: [kube-apiserver]` CNP
   on :443 + :6443 (socket-LB DNAT, see the file header). Alloy
   uses the pod's ServiceAccount token from the projected mount.

7. **Self-metrics on port 12345** — chart default. Quirky
   port choice but documented; the ServiceMonitor matches.

8. **No buffering on disk.** If Loki is unreachable for
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
