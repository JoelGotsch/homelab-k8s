# blackbox-exporter — synthetic reachability probes

The cluster's synthetic-probe endpoint. One `blackbox_exporter` pod, one
`Probe` CR per external dependency being measured.

Per [ADR 0062](../../../homelab-docs/02-decisions/0062-external-dependency-reachability-is-measured.md)
— *external dependency reachability is measured directly, not inferred from
dependent job failures*.

## Why this exists

On 2026-09-06 at ~03:05 UTC, `u609156.your-storagebox.de:23` was unavailable
for roughly 25 minutes. Two independent off-site backup lanes in two
namespaces failed — `openbao/openbao-raft-snapshot` and
`backup-cronjobs/restic-minio-to-hetzner` — and **no alert named the actual
cause**. The only evidence was failed Jobs in two places, which reads as two
unrelated faults. Before this layer, the cluster had zero `Probe` objects and
zero `probe_success` series; the shared dependency was measured only through
the wreckage of the things that depended on it.

## What it measures today

| Target | Module | Interval | Alert |
|---|---|---|---|
| `u609156.your-storagebox.de:23` | `tcp_connect` | 30s | `HetznerStorageBoxUnreachable` (warning, `for: 3m`) |

Unauthenticated TCP connect only — no banner exchange, no credential. The
Storage Box SSH key is `secret` and is deliberately not part of this layer;
the connect is strictly less privileged than the backup jobs that share the
dependency. Host and port are public routing config already committed in
`platform/openbao/raft-snapshot-cronjob.yaml`.

## Adding a target

1. Add its FQDN to `ciliumnetworkpolicy.yaml` under `toFQDNs`. **A target
   that is not in that allowlist reports a permanent outage** — the probe
   fails closed, and the resulting alert is indistinguishable from a real one.
2. Add a `Probe` CR carrying `release: kube-prometheus-stack`. Without that
   label the Prometheus Operator silently does not select it.
3. If the check shape is new (HTTP, TLS-expiry, DNS), add a module to
   `configmap.yaml` and bump `checksum/config` in `deployment.yaml` so the
   pod actually restarts.
4. Add alerts. Select on `instance`, not `job` — `instance` is the target
   string and cannot drift with how the operator renders the job label.
5. Add promtool tests to `prometheusrule_test.yaml`; the
   `check-prometheusrule-tests` pre-commit hook runs them.

No further change is needed to `prometheus-allow`: port 9115 is already in
its egress allowlist. A *different* prober would need its own port added.

## Acceptance test

Not a green Argo sync. The check is a non-empty series:

```sh
curl -sG https://prometheus.lab.vyramo.com/api/v1/query \
  --data-urlencode 'query=probe_success{instance="u609156.your-storagebox.de:23"}'
# and a control query that must return data, so an empty result cannot be
# mistaken for "no such series":
curl -sG https://prometheus.lab.vyramo.com/api/v1/query \
  --data-urlencode 'query=count(up)'
```

`HetznerStorageBoxProbeAbsent` is the standing guard for this: if the series
stops existing for any reason — dead pod, lost `release:` label, renamed
target, missing egress port — the absence is reported rather than read as
health.

## Why hand-written manifests and not the Helm chart

A chart pin would pull in the whole [ADR 0052](../../../homelab-docs/02-decisions/0052-helm-charts-referenced-not-vendored.md)
surface: a `charts.lock.yaml` entry with three digests, a `mirror-chart.sh`
push to `registry.homelab.internal`, an offline-bundle refresh, and the
`check-chart-lock` / `check-patch-targets-match` hooks. blackbox-exporter is
a single static Go binary and the chart's only substantive feature —
templating the module map — is one ConfigMap here.

## Notes

- **Namespace is `monitoring`**, not the ApplicationSet default. Reasons are
  in the header comment of `kustomization.yaml`. Consequence: the
  observability ApplicationSet will mint an empty
  `observability-blackbox-exporter` namespace until its `templatePatch`
  names this layer.
- **No Secret and no ExternalSecret.** This layer therefore triggers neither
  `check-eso-readme` (no `## OpenBao paths to seed` section is required) nor
  the `cold-start.md` Step 13c registration obligation.
- **The prober's vantage is the cluster's egress.** It is not a substitute
  for the off-cluster Flint3 prober
  (`homelab-docs/03-runbooks/observability/external-prober.md`), which
  measures the shared external path *to* the cluster and cannot feed
  Alertmanager. Neither replaces the other.
