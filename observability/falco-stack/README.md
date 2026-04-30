# observability/falco-stack

Falco DaemonSet + Falcosidekick fanout — runtime HIDS per
[ADR 0021 D4 + D7](../../../homelab-docs/02-decisions/0021-observability-stack.md).

Falco DaemonSet runs on every node (CO-RE eBPF probe; kmod
unavailable on Talos per ADR 0013). Events flow:

```
Falco DaemonSet  ──[HTTP POST]──>  Falcosidekick  ──┬── webhook → ntfy-e2ee-relay  → ntfy server  → operator's F-Droid
                                                    │
                                                    ├── (deferred) Loki — retrospection store
                                                    │
                                                    └── (deferred) Alertmanager → Signal (high-severity per ADR 0021 D7)
```

## Closes the audit TODO

The `Falcosidekick WEBHOOK_ADDRESS config` audit-flagged
TODO from the
[2026-04-29 known-caveats journal](../../../homelab-docs/99-journal/2026-04-29-known-caveats-and-mac-studio-runbooks.md):
the relay is deployed but never receives webhooks without
this wiring. `values.yaml`'s `falcosidekick.config.webhook.address`
points at
`http://ntfy-e2ee-relay.ntfy-e2ee-relay.svc.cluster.local:8000/webhook` — the relay's pre-existing route. Falcosidekick's webhook output sends the full event JSON with `output` as the human-readable rule message; the relay's `_extract_message` (per `ntfy-e2ee-relay/ntfy_relay/server.py`) handles that shape first.

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Pins falco Helm chart 4.20.0 (with falcosidekick subchart enabled). |
| `namespace.yaml` | `monitoring` namespace; PSA `privileged` (Falco DaemonSet needs to read `/proc` + load eBPF). |
| `values.yaml` | `driver: modern_ebpf`; tolerations for CP-tainted nodes; rule files (upstream + local overlay); Falcosidekick webhook → relay; Loki/Alertmanager outputs disabled-with-TODO until those layers land. |
| `networkpolicy.yaml` | Falco egress to Falcosidekick + kube-DNS; Falcosidekick ingress from Falco + Prometheus, egress to ntfy-e2ee-relay + kube-DNS. |
| `servicemonitor.yaml` | Self-metrics scrape for both Falco + Falcosidekick. |
| `rules-configmap.yaml` | Operator's local rule overlay (mounted at `/etc/falco/rules.d`). Empty at first install; conventions documented inline. |

## Bring-up

This layer is part of the broader observability layer rollout
per [ADR 0021](../../../homelab-docs/02-decisions/0021-observability-stack.md).
Sequencing:

| Bring-up step | What lands |
|---|---|
| [Step 9 — Cluster bring-up](../../../homelab-docs/04-guides/cold-start.md) | Cilium + OpenBao + Argo CD ready |
| Argo sync of this layer | `monitoring` ns + Falco DaemonSet + Falcosidekick + ServiceMonitors + NetworkPolicies |
| ntfy-e2ee-relay must be Healthy | for the webhook output to actually deliver — check via the layer's pre-deployment Ready gate |
| **(later) kube-prometheus-stack rollout** | enables ServiceMonitor scrape; Loki output enable; Alertmanager output enable + Signal high-severity routing |
| **(later) deception layer per [ADR 0010](../../../homelab-docs/02-decisions/0010-deception-controls.md)** | populate `rules-configmap.yaml` with deception rules (honeycred reads, etc.) |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

**At first install: none.** Falco doesn't need any operator-
provided secrets at scaffold time. The webhook output to
ntfy-e2ee-relay reaches via cluster-internal HTTP (no auth).

When Loki + Alertmanager outputs enable later:

| Path | Keys | Source |
|---|---|---|
| `kv/prod/falcosidekick/loki-bearer` | `token` | (Loki may or may not require auth depending on operator's Loki config; if it does, capture the bearer + write here) |
| `kv/prod/falcosidekick/alertmanager-basic` | `username`, `password` | (Alertmanager auth, if enabled per the kube-prometheus-stack values) |

Both are operator-fillable at observability-layer rollout
time — included here as documented forward-compatibility,
not a current install requirement.

## Operator inputs

- Confirm `monitoring` namespace doesn't already exist
  with conflicting PSA labels (kube-prometheus-stack also
  creates this ns; whichever Argo Application syncs first
  wins on labels). If conflict surfaces post-deploy, the
  newer manifest wins via Argo's last-applied tracking.
- Review Falco's upstream rule list at chart-bump time —
  Renovate opens a PR per chart bump; operator confirms
  no breaking rule changes per
  [update-policy.md](../../../homelab-docs/01-architecture/update-policy.md).

## Caveats

1. **CO-RE eBPF requires kernel 5.8+.** Talos current ships
   6.x — fully supported. If operator ever runs Falco on a
   non-Talos node (rare; mac-studio doesn't get Falco), CO-RE
   compatibility needs verification.
2. **Detection-only.** Per [ADR 0021 D4](../../../homelab-docs/02-decisions/0021-observability-stack.md):
   Falco doesn't kill processes or block syscalls. Response
   path is external (revert + rotate + redeploy via the
   incident-response runbooks). Acknowledged trade-off: in-
   kernel enforcement was rejected because false-positive
   blast radius in a homelab is operator-disruptive.
3. **Privileged DaemonSet.** Falco runs privileged for syscall
   capture. The privilege is read-only on syscalls (Falco
   doesn't write back). Documented as accepted in
   [ADR 0021 D4](../../../homelab-docs/02-decisions/0021-observability-stack.md).
4. **Rule-tuning is ongoing.** Out-of-the-box rules will
   produce false positives in the homelab's specific
   workload mix. Per
   [03-runbooks/observability/rule-tuning.md](../../../homelab-docs/03-runbooks/observability/rule-tuning.md):
   quarterly review of false positives + rule overlay
   updates in `rules-configmap.yaml`.
5. **Falco's webhook output sends ALL severities** without
   filtering at first install (`minimumpriority: notice`).
   When Alertmanager output enables, route filtering moves
   there (Alertmanager → Signal at >= warning per ADR 0021
   D7); the webhook output to relay stays all-severities
   for ntfy. Operator can tighten if alert-fatigue surfaces.
6. **`monitoring` namespace co-locates Falco (privileged)
   with Prometheus (restricted).** PSA at the namespace
   level is `privileged` (the floor); each pod's
   `securityContext` enforces the actual posture. Standard
   pattern; documented inline in `namespace.yaml`.
7. **Loki + Alertmanager outputs are disabled with comments
   in `values.yaml`.** Without them, Falcosidekick's only
   output is the webhook to ntfy-e2ee-relay → ntfy. Once
   Loki lands, retrospection becomes possible; once
   Alertmanager lands, Signal high-severity routing per
   ADR 0021 D7 becomes possible. Both are observability-
   layer-rollout follow-ups.
8. **k8s audit-log integration depends on Talos config.**
   Per ADR 0021 D4 the K8s audit-log plugin is enabled in
   `values.yaml` — but Talos must route the audit log to
   the path Falco's plugin watches. Talos-side routing
   lives in the talos-bootstrap playbook (operator
   confirms the audit-log path matches at first install).

## Related

- [ADR 0021](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — observability stack design (Falco choice + outputs +
  routing).
- [ADR 0010](../../../homelab-docs/02-decisions/0010-deception-controls.md)
  — deception layer; operator extends `rules-configmap.yaml`
  when honeycred files land.
- [03-runbooks/observability/rule-tuning.md](../../../homelab-docs/03-runbooks/observability/rule-tuning.md)
  — quarterly false-positive review + suppression patterns.
- [03-runbooks/observability/signal-webhook.md](../../../homelab-docs/03-runbooks/observability/signal-webhook.md)
  — Signal output wiring (lands when Alertmanager output
  enables here).
- [apps/ntfy-e2ee-relay/](../../apps/ntfy-e2ee-relay/) —
  the webhook target for this layer's Falcosidekick output.
- [apps/ntfy/](../../apps/ntfy/) — the eventual delivery
  endpoint (relay encrypts + posts here).
