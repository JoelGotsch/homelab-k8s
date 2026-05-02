# apps/immich-public-proxy

Read-only public sharing surface for Immich. Per
[ADR 0024 D1](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
(Cloudflare Tunnel for narrowly-scoped E2EE / public-shareable
services).

The Immich admin UI / API / mobile-backup endpoint stays
Tailscale-only at all times. This separate cluster layer accepts
only `/share/*` URLs from the public internet, calls the
cluster-internal `immich-server` Service, and returns the
asset bytes. It holds no credentials, stores no state, and is
configured creds-free (the underlying Immich share already
encodes its own random unguessable token in the URL).

Upstream:
[github.com/alangrainger/immich-public-proxy](https://github.com/alangrainger/immich-public-proxy).

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `immich-public-proxy` ns; PSA restricted. |
| `kustomization.yaml` | Direct manifests (no helm chart — single stateless image). |
| `deployment.yaml` | 2-replica Deployment, soft pod-anti-affinity, non-root + readonly rootfs + dropped caps; image `alangrainger/immich-public-proxy` pinned via Renovate. |
| `service.yaml` | ClusterIP on port 3000 (named `http`). |
| `networkpolicy.yaml` | Ingress: ONLY cloudflare-tunnel ns. Egress: kube-DNS + the `immich` ns's `immich-server` pod (port 2283). No outbound internet. |

## OpenBao paths to seed

None. The proxy is creds-free — no API key, no client secret,
no DB. This is by design: the Immich share-link tokens are the
only secret in the path, and they live in Immich's DB on the
internal side.

## Bring-up wiring

| Step | Owner | What lands |
|---|---|---|
| 1. Cloudflare DNS CNAME | Operator (one-time) | `photos.<HOMELAB-DOMAIN>` → `<CF_TUNNEL_UUID>.cfargotunnel.com` (proxied / orange cloud). Identical pattern to vaultwarden + jellyfin per `infrastructure/cloudflare-tunnel/README.md` Step 4. |
| 2. Append ingress rule to `infrastructure/cloudflare-tunnel/configmap.yaml` | Argo (after operator commits) | New rule routes `photos.<HOMELAB-DOMAIN>` → `http://immich-public-proxy.immich-public-proxy.svc.cluster.local:3000`. cloudflared rolls the new config on next sync. |
| 3. Add cloudflare-tunnel egress allow for this ns in its NetworkPolicy | Argo | `infrastructure/cloudflare-tunnel/networkpolicy.yaml` gets a new `to:` block targeting the `immich-public-proxy` namespace on port 3000. |
| 4. Argo sync this layer | Argo | Namespace + Deployment + Service + NetworkPolicy land. Pods come up, healthcheck passes against upstream Immich. |
| 5. Configure Immich's "External Domain" | Operator (one-time, web UI) | Administration → Settings → Server → External Domain = `https://photos.<HOMELAB-DOMAIN>`. From then on, every Create-link button generates a friend-ready URL with no host-rewrite step. |
| 6. End-to-end check | Operator | Generate a 7-day test share link from a throwaway album → paste into a non-tailnet browser → verify gallery loads + downloads work. Delete the link. |

## Caveats

1. **Public attack surface.** This is the only homelab service
   intentionally reachable from the public internet without
   Tailscale (besides the others already routed through CF
   Tunnel: vaultwarden, jellyfin, ntfy). Surface is narrow
   (only `/share/*` URLs are honoured by the upstream image —
   any other path returns 404), and Cloudflare's WAF + DDoS
   protection sits in front, but the surface is non-zero.
   Operator monitors via the cloudflared dashboard +
   Prometheus scrape on the cloudflared pod.

2. **Share link revocation is operator-driven.** Public links
   are created from the Immich UI (per the
   [photo-management guide](../../../homelab-docs/04-guides/photo-management-with-immich.md)
   §"The default flow"). Expirations handle the bulk;
   manual revocation is via the Sharing view in Immich's left
   nav. The proxy itself has no revocation knob — it just asks
   Immich whether each share token is still active.

3. **No Immich API key here.** The proxy talks to Immich's
   public-share endpoints, which don't require auth — they
   gate on the share token in the URL. So the proxy doesn't
   need (and never accepts) an API key. This bounds the
   blast radius if the proxy itself is ever compromised:
   compromise = exposure only of currently-live share tokens,
   not the whole library.

4. **Image is non-Anthropic / non-CNCF community.** Single
   maintainer, MIT license. Operator pins via Renovate and
   reviews release notes before bumps. Acceptable risk for a
   feature whose alternative is "no public sharing" — see
   ADR 0024 D1 reasoning.

5. **Mirror via internal registry once Forgejo Packages is
   serving** (per ADR 0019). Until then, pulls go to Docker
   Hub directly; rate-limit-pull risk is mitigated by
   `imagePullPolicy: IfNotPresent` and Renovate's bounded
   bump cadence.

## Related

- [ADR 0024 D1](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — CF Tunnel for narrowly-scoped E2EE / public-shareable services.
- [`infrastructure/cloudflare-tunnel/`](../../infrastructure/cloudflare-tunnel/)
  — sibling layer that publishes `photos.<HOMELAB-DOMAIN>` here.
- [`apps/immich/`](../immich/) — the upstream Immich install
  this proxies to.
- [`04-guides/photo-management-with-immich.md`](../../../homelab-docs/04-guides/photo-management-with-immich.md)
  §"The default flow" — operator's day-to-day public-sharing
  workflow.
- Upstream: [alangrainger/immich-public-proxy](https://github.com/alangrainger/immich-public-proxy).
