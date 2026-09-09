# apps/approval-channel

Webhook receiver that formats Alertmanager + deception alerts
and forwards them to [`signal-bridge`](../signal-bridge/) for
delivery to the operator's Signal account.

Per ADR 0009 (approval channel) + ADR 0021 D7 + D10. v0.1.0
implements the **alert-delivery half** of approval-channel; the
agent-approval state machine (approve / refuse / duress / abstain
on consequential writes) is a separate scope and lands later.

## Route classification

Despite this layer's historical name, the implemented `/v1/alert` and
`/v1/deception` endpoints are **operational alert** formatters. Alertmanager
calls cannot create, approve, refuse, or mutate an approval item. The current
routes to these endpoints are temporary operational Signal drift, exact-
baselined under P0-07 until readable ntfy receipt and conditional fallback are
proven.

The future approval workflow is not present in these manifests. It must use a
typed approval protocol with immutable command identity/digest and explicit
reply semantics, so alert delivery and approvals remain distinguishable even
though both may use signal-bridge as transport.

Source code: [`/approval-channel/`](../../../approval-channel/)
at the workspace root.

## Why a separate layer (not part of signal-bridge)

Per the architecture-priorities lens: signal-bridge owns the
signal-cli protocol concern (stateful daemon, registration data,
HTTP wrapper); this layer owns the routing / formatting / audit
concern (stateless, restart-friendly, tests cover the alert-shape
permutations). Each component has one job; failure modes are
independent.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `approval-channel` ns; PSA restricted. |
| `externalsecret.yaml` | OpenBao `kv/approval-channel/signal` → env vars (sender + recipients). |
| `deployment.yaml` | ConfigMap (signal-bridge URL, timeout) + Deployment + Service on 8000; runs as UID 1000, readonly root FS. |
| `networkpolicy.yaml` | Ingress: Alertmanager + Prometheus only. Egress: kube-DNS + signal-bridge. |
| `servicemonitor.yaml` | Scrape `/metrics` (prometheus-client format from app). |

## OpenBao paths to seed

| Path | Field | Notes |
|---|---|---|
| `kv/data/approval-channel/signal` | `sender` | E.164 number registered in signal-bridge — same number as the operator action documented in [`apps/signal-bridge/README.md`](../signal-bridge/README.md). |
| `kv/data/approval-channel/signal` | `recipients` | Comma-separated E.164 numbers. Operator's phone(s). |
| `kv/data/approval-channel/inbound-auth-token` | `token` | Bearer-token-style secret for the `/v1/*` POST endpoints. Generate at first install: `openssl rand -hex 32`. AM-side mirror Secret in monitoring ns is `am-inbound-tokens` (key `approval-channel`); created by the kube-prometheus-stack ESO ExternalSecret. |

Seed during cold-start Step 13c (per
[`04-guides/cold-start.md`](../../../homelab-docs/04-guides/cold-start.md)).
The bearer token is generated + seeded via the helper:

```sh
homelab-infra/scripts/seed-random-secret.sh \
    kv/approval-channel/inbound-auth-token token
```

The Signal sender/recipients fields are operator-typed (E.164
numbers, not random), so seed those manually:

```sh
bao kv put kv/approval-channel/signal \
    sender="+49..." \
    recipients="+49...,+49..."
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `apps/signal-bridge/` | signal-cli daemon up; operator runs the registration ceremony per signal-bridge README. |
| Operator seeds `kv/approval-channel/signal/{sender,recipients}` | ESO can populate the Secret. |
| Argo sync this layer | approval-channel Deployment Ready; `/healthz` returns 200. |
| Argo sync `observability/kube-prometheus-stack/` | The active, temporary critical/deception operational-alert routes call these endpoints. |

## Caveats

1. **No queue / no retry of own.** Alertmanager retry on 5xx is
   the durability layer. signal-bridge unreachable → 502 → AM
   retries. Acceptable; recorded in
   [`/approval-channel/README.md`](../../../approval-channel/README.md)
   caveat 1.
2. **Inbound bearer auth plus NetworkPolicy, but no message signature.**
   Alertmanager supplies the `am-inbound-tokens` credential and NetworkPolicy
   limits ingress. A source-bound HMAC/signature remains an upgrade path.
3. **Single-replica Deployment.** Stateless; HA isn't useful at
   homelab scale. AM retries cover transient unavailability.
4. **One formatter for both endpoints.** `/v1/alert` and
   `/v1/deception` share the formatter with a flag; per-shape
   formatters land as the operator finds gaps.
5. **Recipients are global, not per-route.** Every alert →
   every configured recipient. Per-severity routing is a
   follow-up.
6. **Image is operator-built.** No upstream image.
   `registry.homelab.internal/approval-channel:0.1.0` —
   built by the operator (or Woodpecker once CI lands) from
   [`/approval-channel/`](../../../approval-channel/).
   Renovate-pinned via the workspace renovate config.

## Related

- [ADR 0009](../../../homelab-docs/02-decisions/0009-approval-channel.md)
- [ADR 0021 D7 + D10](../../../homelab-docs/02-decisions/0021-observability-stack.md)
- [signal-webhook runbook](../../../homelab-docs/03-runbooks/observability/signal-webhook.md)
- [`apps/signal-bridge/`](../signal-bridge/) — the transport.
- [`/approval-channel/`](../../../approval-channel/) — source code.
- [99-journal/2026-04-30-signal-bridge-and-approval-channel.md](../../../homelab-docs/99-journal/2026-04-30-signal-bridge-and-approval-channel.md)
