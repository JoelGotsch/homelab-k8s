# observability/kube-prometheus-stack

Prometheus + Alertmanager + Grafana + node-exporter +
kube-state-metrics. Per [ADR 0021 D7 + D8](../../../homelab-docs/02-decisions/0021-observability-stack.md).

**Activates** the ServiceMonitors + PrometheusRules already
scaffolded across the cluster:

- [apps/ntfy-e2ee-relay/servicemonitor.yaml](../../apps/ntfy-e2ee-relay/servicemonitor.yaml)
- [apps/ntfy/servicemonitor.yaml](../../apps/ntfy/servicemonitor.yaml)
- [observability/falco-stack/servicemonitor.yaml](../falco-stack/servicemonitor.yaml)
  (Falco + Falcosidekick)
- [infrastructure/backup-cronjobs/prometheusrule.yaml](../../infrastructure/backup-cronjobs/prometheusrule.yaml)
  (4 alerts: PVC fill warning + critical, job-failed, missing-24h)

All labeled `release: kube-prometheus-stack` for chart-default
discovery via this layer's `serviceMonitorSelector` /
`ruleSelector`.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Pins kube-prometheus-stack chart 87.16.1. |
| `namespace.yaml` | `monitoring` ns (shared with falco-stack); PSA `privileged`. |
| `values.yaml` | Prometheus 30d retention on Longhorn-encrypted PVC; Alertmanager + Grafana persistence; chart-default ServiceMonitor / Rule selectors; node-exporter + kube-state-metrics enabled; OIDC commented-with-TODO until Authentik lands. |
| `alertmanager-config.yaml` | AlertmanagerConfig CRD — all operational routes target the ntfy-primary adapter; no direct Signal receiver. |
| `alert-formatter.yaml` | Single-replica ntfy-primary adapter, one-way Signal fallback, and a retained 256 MiB Longhorn PVC for the SQLite delivery ledger. |
| `externalsecret.yaml` | Grafana admin user + password from `kv/grafana/admin`. |
| `httproute.yaml` | Three HTTPRoutes: `grafana.lab.<HOMELAB-DOMAIN>`, `alertmanager.lab.<HOMELAB-DOMAIN>`, `prometheus.lab.<HOMELAB-DOMAIN>`. All Tailscale-fronted phase 1; Grafana intentionally NOT Cloudflare-Tunnel-served per ADR 0024 (dashboards surface internal-class data). |
| `networkpolicy.yaml` | Prometheus/Alertmanager/Grafana policy; Alertmanager egress is limited to alert-formatter. |

## Notification channel policy

[`notification-channel-policy.json`](notification-channel-policy.json) is
mounted beside the adapter and validated at startup. `alert_router.py` tries
ntfy first and calls approval-channel's one-way alert endpoint only after that
publish fails. A SQLite ledger records the ntfy attempt/outcome independently
from fallback state before responding to Alertmanager. Exact retries are
deduplicated for five minutes. A timeout or interrupted attempt is persisted as
`delivery_unknown` and is never retried blindly; an explicit HTTP rejection may
be retried. When the Signal rate limit is full and neither channel has
acknowledged the alert, the adapter returns 503 so Alertmanager retains it; the
ledger is not mistaken for an asynchronous delivery queue. The machine policy
limits Signal fallback to five attempts per 15 minutes and closes an outage
after three consecutive ntfy acknowledgements, then sends one recovery summary.
Unit tests prove healthy ntfy makes zero Signal calls. The static route guard
rejects a direct Alertmanager Signal receiver or custom relay reappearing.

The ledger stores only delivery hashes, normalized evidence, timestamps, and
outcomes—not alert bodies or credentials. Liveness is `/healthz`; `/readyz`
also verifies that the policy is valid and the ledger is writable. The
Deployment uses `Recreate` because the PVC is RWO and the process is a single
SQLite writer; Alertmanager retains notifications during that short handoff.
The claim uses `longhorn-replica2-retain` and `Prune=confirm`: a Git rollback
cannot silently discard unresolved delivery evidence. No independent backup is
claimed; the exact RPO/RTO and disposable rebind test are declared in
[`scripts/retention-contract.yaml`](../../scripts/retention-contract.yaml).
An ambiguous primary outcome is eligible for normal retention cleanup only
after Signal acknowledged the fallback; unresolved Signal ambiguity remains
pinned until operator reconciliation.

### Ambiguous-delivery reconciliation

An ntfy timeout still permits the typed Signal backup. A Signal timeout is more
dangerous: Signal may have accepted the message even though its acknowledgement
was lost. The router returns 503 and pins that exact delivery in
`delivery_unknown` instead of sending a possible duplicate. Inspect only
non-sensitive ledger metadata in the running pod:

```sh
kubectl -n monitoring exec deploy/alert-formatter -- \
  python /app/alert_router.py list-unknown
```

After independently checking the downstream server path, resolve exactly one
channel outcome. `acknowledged` makes the retained Alertmanager retry a no-op;
`failed` permits a new fallback attempt:

```sh
kubectl -n monitoring exec deploy/alert-formatter -- \
  python /app/alert_router.py resolve-unknown \
  <DELIVERY_KEY> fallback acknowledged
```

These commands are deliberately manual: a guessed reconciliation would merely
hide the same ambiguity the ledger exists to expose. They do not access or
modify approval state.

If `list-unknown` reports a `recovery_summary` rather than a delivery, reconcile
that one Signal outcome by episode ID after checking the Signal adapter logs:

```sh
kubectl -n monitoring exec deploy/alert-formatter -- \
  python /app/alert_router.py resolve-recovery-summary \
  <EPISODE_ID> acknowledged
```

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Keys | Source |
|---|---|---|
| `kv/grafana/admin` | `user`, `password` | `openssl rand -base64 32` for the password. Operator-generated at first install. Annual rotation cadence. |

**First-install seed:**

```sh
# Scripted (recommended) — --print so operator can read the
# generated password once for first login. Clear scrollback
# after.
homelab-infra/scripts/seed-random-secret.sh \
    --print --format base64 --size 32 \
    kv/grafana/admin password
bao kv patch kv/grafana/admin user="admin"

# After Argo sync:
# Open https://grafana.lab.<HOMELAB-DOMAIN> via Tailscale.
# Login: admin / <password printed above>.
```

Manual fallback:

```sh
ADMIN_PW=$(openssl rand -base64 32)
bao kv put kv/grafana/admin user="admin" password="$ADMIN_PW"
unset ADMIN_PW
```

**Authentik OIDC** (after Authentik is up):

| Path | Keys | Source |
|---|---|---|
| `kv/grafana/oidc` | `client_id`, `client_secret`, `issuer` | Provisioned via `provision-authentik-oidc-client.sh` (see snippet below). |

Activation:

```sh
# Create the Grafana OIDC client in Authentik + seed OpenBao.
AUTHENTIK_URL=https://auth.lab.<HOMELAB-DOMAIN> \
AUTHENTIK_TOKEN="$(bao kv get -field=api_token kv/authentik/admin)" \
homelab-infra/scripts/provision-authentik-oidc-client.sh \
    --app-name grafana \
    --redirect-uri \
      "https://grafana.lab.<HOMELAB-DOMAIN>/login/generic_oauth" \
    --scopes "openid email profile groups" \
    --kv-path kv/grafana/oidc

# Flip values.yaml's grafana.ini.auth.generic_oauth.enabled
# from false → true; commit + push; Argo reconciles.
```

Until activation: the `grafana-oidc` ESO emits an empty
Secret; Grafana's `auth.generic_oauth.enabled: false` keeps
the OIDC path inert. Admin login (Grafana-native admin user)
keeps working throughout.

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| [Step 9 — Cluster bring-up](../../../homelab-docs/04-guides/cold-start.md) | Cilium + Longhorn (with the `longhorn-replica2` SC encrypted via OpenBao+ESO per ADR 0016 D5) + Argo CD ready |
| Argo sync this layer | CRDs + Prometheus operator + Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics |
| Pre-existing ServiceMonitors + PrometheusRules (4 layers) | Auto-discovered by the chart's selector match; scrape + rule-eval start within ~30s |
| AlertmanagerConfig in this layer | Picked up by Alertmanager via `alertmanagerConfigSelector` |
| **(later) Loki layer** | Grafana data source for log dashboards; Falcosidekick + Alertmanager log-shipping outputs enable; uncomment NetworkPolicy egress rule |
| Notification adapter | One PVC-backed replica formats to ntfy; a failed publish opens a deduplicated, rate-limited, typed Signal fallback without approval-state access. |
| **(later) Authentik OIDC** | Grafana `auth.generic_oauth` block enables; admin password becomes break-glass-only |

## Caveats

1. **Prometheus scrape egress is wide** — every namespace,
   common metrics ports. Intentional: scrape targets exist
   everywhere by design; metrics endpoints are
   unauthenticated within-cluster (standard Prometheus
   pattern). Cross-namespace blast radius is bounded by
   the metrics-only port allowlist + the fact that
   Prometheus itself doesn't accept arbitrary inputs.
2. **Grafana intentionally Tailscale-only** (no Cloudflare
   Tunnel). Dashboards surface internal-class data in
   graph titles, labels, panel descriptions — even when
   the dashboard's "data" is encrypted at the data source,
   the dashboard structure leaks operational shape.
3. **Storage retention vs encryption.** Per ADR 0016 D5:
   `longhorn-replica2` SC encrypts at-rest via Longhorn's
   per-volume key sourced from OpenBao+ESO. If that ESO
   integration isn't yet live at observability-rollout
   time, Prometheus PVC + Alertmanager PVC + Grafana PVC
   are all unencrypted-at-rest. Operator gates: confirm
   the longhorn-encryption ESO is healthy before this
   layer's first sync.
4. **AlertmanagerConfig CRD vs chart's default ConfigMap.**
   We `config: null` the chart's default to force routing
   through our AlertmanagerConfig CRD (which is also more
   GitOps-friendly — operator edits the CRD, not the
   chart values). If the chart's default ever changes
   shape, our override might leak the chart-default
   behavior; verify at chart-bump time.
5. **Server acknowledgement is not phone receipt.** The durable ledger proves
   the in-cluster ntfy/Signal server paths only. Periodic attended phone
   canaries remain required by ADR 0040. ntfy v2.11 has no client-supplied
   idempotency key, so timeout ambiguity is recorded and reconciled rather than
   silently treated as exact-once delivery.
6. **Grafana OIDC commented-with-TODO until Authentik
   lands.** First-install operator logs in with the
   ESO-projected admin password directly. When Authentik
   arrives, OIDC enables + the admin password becomes
   break-glass-only. Migration path = "rotate admin
   password to a fresh random, store in OpenBao,
   un-comment the OIDC block, restart Grafana."
7. **Three HTTPRoutes (grafana / alertmanager /
   prometheus)** — operator can reach all three via
   Tailscale. ADR 0024 doesn't list these as Cloudflare-
   Tunnel-eligible (dashboards leak operational shape).
   If a future operator wants Grafana on Cloudflare,
   that's an ADR amendment, not a route swap.
8. **Wide Prometheus scrape NetworkPolicy** lists common
   metrics ports (8080, 8081, 9100, 10250, etc.) — not
   exhaustive. If a new workload exposes metrics on an
   unconventional port, operator extends the egress list.
   Documented inline in `networkpolicy.yaml`.
9. **No metrics retention beyond 30d.** ADR 0021 D8 hot
   tier; longer history needs Thanos / Mimir / similar
   (out of scope per the ADR's "deferred with reconsider-
   trigger"). Operator extracts important time-series
   manually if a >30d question arises.
10. **kube-state-metrics + node-exporter cardinality** —
    chart defaults are reasonable for homelab scale.
    Watch for metric-cardinality blow-up at first week
    of operation; Prometheus-side `metric_relabel_configs`
    drops heavy labels if needed.

## Related

- [ADR 0021](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — D7 routing + D8 storage tiering.
- [ADR 0016 D5](../../../homelab-docs/02-decisions/0016-longhorn-for-cluster-storage.md)
  — Longhorn per-volume encryption via OpenBao+ESO; this
  layer's PVCs depend on it.
- [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — why Grafana stays Tailscale-only.
- [observability/falco-stack/](../falco-stack/) — peer
  observability layer, currently suspended; its dormant Alertmanager output is
  the supported ntfy path; the incompatible custom-relay resume setting was removed.
- [03-runbooks/observability/rule-tuning.md](../../../homelab-docs/03-runbooks/observability/rule-tuning.md)
  — quarterly false-positive review across both
  Prometheus rules + Falco rules.
- [`scripts/temporary-notification-route-baseline.yaml`](../../scripts/temporary-notification-route-baseline.yaml)
  — exact reviewed inventory and removal gates for temporary routes.
