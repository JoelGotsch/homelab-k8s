# apps/ntfy

The cluster-hosted ntfy server. Receives ciphertext alert
payloads from
[apps/ntfy-e2ee-relay/](../ntfy-e2ee-relay/), stores in
SQLite, fans out to subscribers (operator's F-Droid app).

Per
[ADR 0024 D1 phase-2](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md):
once the E2EE relay is operational + end-to-end-verified,
this server migrates from Tailscale-only ingress to
Cloudflare-Tunnel-served (the cutover is a Cloudflare-side
config + DNS change; this manifest doesn't change).

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Plain kustomize (no Helm chart from upstream — community charts drift faster than the binary). |
| `namespace.yaml` | `ntfy` ns, restricted PSA. |
| `pvc.yaml` | 5Gi Longhorn-replica2 PVC for SQLite DB + attachment cache. |
| `configmap.yaml` | `server.yml` (auth deny-all default, single-topic, cache-duration 12h, behind-proxy true, metrics on). |
| `externalsecret.yaml` | admin password + relay bearer token from OpenBao at `kv/ntfy/{admin-password,relay-token}`. |
| `deployment.yaml` | Single replica (SQLite-backed); `Recreate` strategy (RWO PVC); ntfy upstream image. |
| `httproute.yaml` | Cilium Gateway HTTPRoute on `ntfy.lab.<HOMELAB-DOMAIN>`. Tailscale-fronted phase 1; Cloudflare Tunnel phase 2. |
| `networkpolicy.yaml` | Default-deny + ingress from `ingress` (Gateway) + `ntfy-e2ee-relay` (publishers) + `monitoring` (scrape); egress kube-DNS only. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Keys | Source |
|---|---|---|
| `kv/ntfy/admin-password` | `value` | `openssl rand -base64 32`. Operator's break-glass into the ntfy CLI for user/ACL ops. |
| `kv/ntfy/relay-token` | `value` | `tk_*` bearer token issued **inside the running pod** (`ntfy token add relay`). Same value also written to `kv/ntfy/publish-auth` `header` field as `Bearer <token>` so the relay's ESO picks it up. |

**First-install seed** (after ntfy pod is `Running` but before
the relay's first publish attempt):

```sh
# 1. Admin password — generate + seed + bootstrap admin user
#    via kubectl-exec. The admin user creation itself stays
#    manual because it's a one-off with shell-side password
#    handling; everything else below is scripted.
homelab-infra/scripts/seed-random-secret.sh \
    --print --format base64 --size 32 \
    kv/ntfy/admin-password value
ADMIN_PW="$(bao kv get -field=value kv/ntfy/admin-password)"
kubectl -n ntfy exec -it deploy/ntfy -- sh -c "
  ntfy user add --role=admin admin <<EOF
$ADMIN_PW
$ADMIN_PW
EOF
"
unset ADMIN_PW

# 2. Relay user + write-only ACL + token (scripted).
homelab-infra/scripts/provision-ntfy-relay-token.sh \
    --user relay \
    --topic homelab-alerts \
    --acl-perm wo \
    --kv-path kv/ntfy/relay-token \
    --also-publish-auth-path kv/ntfy/publish-auth \
    --token-label e2ee-relay

# 3. Operator-mobile user + read-only ACL + token (scripted).
homelab-infra/scripts/provision-ntfy-relay-token.sh \
    --user operator-mobile \
    --topic homelab-alerts \
    --acl-perm ro \
    --kv-path kv/ntfy/operator-mobile-token \
    --token-label operator-fdroid
# Operator pulls the printed token into the F-Droid app's
# "Default access token" field along with the topic key from
# kv/ntfy/topic-key.
```

The admin-password step still uses kubectl-exec because the
admin role grants ntfy CLI access on the pod (effectively
the operator's break-glass into ntfy itself). The other two
users are scripted via `provision-ntfy-relay-token.sh`,
which wraps the same kubectl-exec ceremony with idempotency,
ACL setup, and OpenBao seeding.

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| [Step 9 — Cluster bring-up](../../../homelab-docs/04-guides/cold-start.md) | Longhorn + Cilium Gateway + ESO + OpenBao ready |
| [Step 13c — Seed ExternalSecret OpenBao paths](../../../homelab-docs/04-guides/cold-start.md) | `kv/ntfy/admin-password` populated; `kv/ntfy/relay-token` + `kv/ntfy/publish-auth` populated post-pod-up via the snippet above |
| Argo sync (this layer) | ntfy pod up, HTTPRoute reconciled, NetworkPolicy enforced |
| First-install bootstrap | Operator runs the kubectl-exec ceremony above to create admin + relay + operator-mobile users |
| Argo sync (apps/ntfy-e2ee-relay) | Relay starts; reads `NTFY_AUTH_HEADER` from its own ESO; first publish reaches ntfy with the token |
| Verify end-to-end | Run `scripts/verify-e2e.py` from sibling repo |

## Phase-1 vs phase-2 ingress

**Phase 1 (default — what this manifest produces):**
- HTTPRoute on `ntfy.lab.<HOMELAB-DOMAIN>` via the cluster
  Gateway.
- Operator reaches via Tailscale (Tailscale → cluster
  Ingress → Gateway → HTTPRoute → Service → ntfy pod).
- F-Droid app subscribes through Tailscale (operator's
  phone is on the tailnet).

**Phase 2 (after relay + end-to-end verify):**
- Cloudflare Tunnel fronts `ntfy.<HOMELAB-DOMAIN>` (no
  `lab.` subdomain), terminating TLS at Cloudflare and
  proxying to the cluster Gateway.
- Operator's phone reaches via 4G/WiFi → Cloudflare → cluster.
- Tailscale path remains as fallback per
  [`network/cloudflare-tunnel-to-dns-failover.md`](../../../homelab-docs/03-runbooks/network/cloudflare-tunnel-to-dns-failover.md).

The cutover is operator-side: add the Cloudflare Tunnel
config pointing at the cluster Gateway's IP, add the public
DNS record, and enable. **No homelab-k8s manifest change
required** — this HTTPRoute already serves both ingress
sources.

## Caveats

- **Single replica + SQLite.** Switching to multi-replica
  would need a Postgres backend (ntfy supports it). For the
  homelab's alert volume, single-replica is fine.
  `Recreate` rollout strategy avoids RWO-PVC deadlock at
  upgrade time (~30s downtime per restart, acceptable for
  alert delivery — ntfy's at-least-once semantics handle
  brief pod restarts via the publisher's retry logic).
- **`auth-default-access: deny-all`** means a misconfigured
  publisher (no Bearer token / wrong token) gets 401.
  First-install symptom: relay logs show
  `publish_rejected status=401`. Fix: re-check the
  `kv/ntfy/publish-auth` Secret's `header` value matches
  `Bearer <relay-token-from-pod-bootstrap>`.
- **Phase-1 vs phase-2 confusion at first install.** The
  HTTPRoute's hostname is `ntfy.lab.<HOMELAB-DOMAIN>` for
  phase 1 (internal-DNS + Tailscale). When phase-2 cuts
  over, operator changes the **Cloudflare-side** hostname
  to `ntfy.<HOMELAB-DOMAIN>` (no `lab.`). The HTTPRoute
  here doesn't change; Cloudflare handles the rewrite.
  Documented inline.
- **Bootstrap user/token ceremony is manual.** ntfy's
  user/token CLI operates inside the pod — there's no
  declarative API for "ensure user X exists with ACL Y."
  The seed snippet above is operator-run-once at first
  install; quarterly rotation of the relay-token is a
  separate runbook (TBD).
- **`base-url` placeholder must be filled** before sync.
  Caught by `scripts/check-placeholders.sh` (the configmap
  `server.yml` is YAML inside YAML; the placeholder lives
  in the inner string but the outer YAML still scans).
- **Web Push deliberately disabled.** Reduces external-
  network reach (web push touches Mozilla / Apple push
  servers). Operator uses F-Droid app (native ntfy
  subscription, no web push needed). If a future user
  needs web subscription, enable + accept the egress
  surface in `network.md`.
- **Rotation runbook deferred.** Topic-key rotation is
  annual + manual per ADR 0024 D1; relay-token rotation
  follows the same cadence. Both procedures fold into a
  future `ntfy/rotation.md` runbook.

## Related

- [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — D1 phase-2 design.
- [apps/ntfy-e2ee-relay/](../ntfy-e2ee-relay/) — companion
  relay; this server is its publish target.
- [ntfy-e2ee-relay/](../../../ntfy-e2ee-relay/) — sibling
  repo with relay source + verify-e2e harness.
- [observability/signal-webhook.md](../../../homelab-docs/03-runbooks/observability/signal-webhook.md)
  — Signal sink (primary alert channel; ntfy is additive).
- [network/cloudflare-tunnel-to-dns-failover.md](../../../homelab-docs/03-runbooks/network/cloudflare-tunnel-to-dns-failover.md)
  — phase-2 ingress drill for ntfy.<HOMELAB-DOMAIN>.
