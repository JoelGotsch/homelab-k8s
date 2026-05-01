# apps/signal-bridge

The Signal-cli transport layer. Per ADR 0009 D1 (Signal as
default approval transport) + ADR 0021 D7 (Signal as
high-severity alert sink).

`bbernhard/signal-cli-rest-api` wraps signal-cli with a small
HTTP API; this layer deploys it. The higher-level
alert-formatting + audit + approval-state-machine logic
lives at [`apps/approval-channel/`](../approval-channel/) —
this layer is **transport only**.

## Why a separate layer (not a sidecar to approval-channel)

Per the architecture-priorities lens (clean composability +
failure-mode independence over minimum-component-count):

- **Stateful daemon, independent lifecycle.** signal-cli holds
  registration state in a SQLite store on the PVC. Coupling
  its restart to approval-channel deploys would mean every
  approval-channel rollout briefly suspends Signal delivery.
  Separate Deployments → independent rollout cadence.
- **Single responsibility.** This layer owns `signal-cli`
  protocol concerns. approval-channel owns routing /
  formatting / audit. Each is reasoned about + debugged in
  isolation.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `signal-bridge` ns; PSA baseline (signal-cli is non-root). |
| `pvc.yaml` | 2 GiB Longhorn-replica2 PVC for signal-cli registration + session data. |
| `deployment.yaml` | Single-replica Recreate-strategy Deployment (PVC-RWX-of-one + SQLite-locks); ConfigMap with `MODE=native` + `ENABLE_METRICS=1`; Service on 8080. |
| `networkpolicy.yaml` | Ingress: approval-channel + Prometheus only. Egress: kube-DNS only (external Signal-infrastructure egress moved to `ciliumnetworkpolicy-egress.yaml`). |
| `ciliumnetworkpolicy-egress.yaml` | CCNP for FQDN-narrowed egress: `toFQDNs: *.signal.org`. Replaces the previous broad `0.0.0.0/0:443,80` allow in vanilla NetPol. |
| `servicemonitor.yaml` | Scrape `/v1/metrics` (Prometheus format, exposed when `ENABLE_METRICS=1`). |

## First-install operator action: register signal-cli

This layer's PVC starts empty. signal-cli must be registered
*once* against the operator's Signal account before
approval-channel can dispatch messages. Procedure:

1. Apply this layer (`kubectl apply -k apps/signal-bridge/`
   or via Argo).
2. Wait for the `signal-bridge` pod to be Ready (the daemon
   starts; `/v1/health` returns 200).
3. Register against the operator's Signal number:
   ```sh
   kubectl -n signal-bridge exec deploy/signal-bridge -- \
     curl -sS -X POST \
       -H 'Content-Type: application/json' \
       -d '{"captcha": "<captcha-token>"}' \
       http://localhost:8080/v1/register/+<E164-number>
   ```
   (Signal requires a captcha token; obtain via the Signal
   Desktop captcha endpoint per signal-cli docs. The token
   is single-use + time-bounded.)
4. Verify with the SMS code Signal sends to the number:
   ```sh
   kubectl -n signal-bridge exec deploy/signal-bridge -- \
     curl -sS -X POST \
       http://localhost:8080/v1/register/+<E164-number>/verify/<sms-code>
   ```
5. Confirm registration:
   ```sh
   kubectl -n signal-bridge exec deploy/signal-bridge -- \
     curl -sS http://localhost:8080/v1/accounts
   ```
   Should list `+<E164-number>`.
6. **Backup the PVC** — Longhorn snapshot + restic tier-3
   per [`backup-cronjobs/README.md`](../../infrastructure/backup-cronjobs/README.md).
   Loss of the data dir = re-registration ceremony +
   captcha + SMS verification all over again.

The registered number is the *sender*; approval-channel
holds the recipient list (operator's other phone, etc.).

## Caveats

1. **Single replica + Recreate strategy.** Two pods
   on the same data dir corrupt the SQLite lock. Pod
   eviction = brief outage (signal-cli restart is ~2s on
   the native build; alerts queued during outage are lost
   unless approval-channel has its own buffer — it does
   not, today).
2. **No HA path within this layer.** Multi-instance
   signal-cli is upstream-unsupported. The architectural
   answer is "Signal is degraded → fall back to ntfy"
   handled at approval-channel.
3. **Image is a community wrapper.** `bbernhard/
   signal-cli-rest-api` is well-maintained but not
   first-party Signal. Renovate-pinned per
   [renovate.json5](../../renovate.json5); supply-chain
   trust model is the same as for any community image
   (per ADR 0019 — Trivy + cosign on first-party images;
   for community images, pin + read release notes).
4. **External egress narrowed via CCNP `toFQDNs: *.signal.org`**
   (in `ciliumnetworkpolicy-egress.yaml`). Vanilla NetworkPolicy
   gates internal traffic only. Cold-start brittleness: Cilium's
   FQDN cache must populate from observed DNS responses before
   the first connection succeeds (~ms in steady state).
5. **No Helm chart upstream.** Manifests are hand-rolled.
   The trade-off is no upstream values-schema risk on
   bumps; the cost is operator-side maintenance of all the
   Deployment + Service + ConfigMap shape.
6. **Metrics endpoint pattern is image-specific.**
   `ENABLE_METRICS=1` exposes `/v1/metrics` in Prometheus
   format. If a future bbernhard release changes the path,
   the ServiceMonitor needs an update.
7. **Registration captcha is operator-action.** No
   automated re-registration path. If Signal forces re-
   registration (rare; account migration / lost-device),
   the operator runs the procedure above again.

## Related

- [ADR 0009](../../../homelab-docs/02-decisions/0009-approval-channel.md)
  — approval channel design; D1 pins Signal as the default
  transport.
- [ADR 0021 D7](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — Signal as high-severity alert sink.
- [signal-webhook runbook](../../../homelab-docs/03-runbooks/observability/signal-webhook.md)
  — end-to-end pipeline from Alertmanager / Falcosidekick /
  Langfuse → approval-channel → signal-bridge → operator phone.
- [99-journal/2026-04-30-signal-bridge-and-approval-channel.md](../../../homelab-docs/99-journal/2026-04-30-signal-bridge-and-approval-channel.md)
  — D-decisions: layer split, image choice, registration
  procedure, single-replica trade-off.
- [`apps/approval-channel/`](../approval-channel/) — the
  caller; routes Alertmanager + deception webhook calls
  through this layer.
