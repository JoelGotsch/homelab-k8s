# infrastructure/cloudflare-tunnel

Outbound-connect daemon that exposes selected E2EE-encrypted
or `internal-media`-classified services to public hostnames
through Cloudflare's edge. Per
[ADR 0024 D1](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
(Cloudflare narrowly: in the path for the public Vaultwarden
+ Jellyfin (+ later ntfy-e2ee-relay); never for non-E2EE
internal services).

`cloudflared` connects out-only to Cloudflare's edge, so no
inbound port forwarding on the home router is needed.
Cloudflare provides DDoS protection + WAF + global anycast
ingress in front of the cluster.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `cloudflare-tunnel` ns; PSA restricted. |
| `kustomization.yaml` | Direct manifests (no helm chart — cloudflared is a 1-image deployment; helm doesn't add value). |
| `deployment.yaml` | 2-replica cloudflared Deployment with soft pod-anti-affinity; non-root + readonly rootfs + dropped caps. |
| `configmap.yaml` | `config.yaml`: tunnel UUID + per-hostname ingress rules → cluster Services + catch-all 404. |
| `externalsecret.yaml` | Tunnel credentials JSON from `kv/cloudflare/tunnel/credentials_json`. |
| `networkpolicy.yaml` | Egress: kube-DNS + Cloudflare edge (TCP/UDP 443 + 7844, `toEntities: world`) + per-upstream ns explicit allows. Ingress: Prometheus scrape on metrics port only. |
| `servicemonitor.yaml` | Prometheus scrape on `/metrics` (port 2000). |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/cloudflare/tunnel` | `credentials_json` | Verbatim contents of `~/.cloudflared/<TUNNEL-UUID>.json` produced by `cloudflared tunnel create` (operator-side, one-time). Includes AccountTag + TunnelID + TunnelSecret. |

## Pre-bring-up: tunnel + DNS provisioning (operator-side)

These run on the operator's Tier A workstation **once**,
before the layer's first sync.

### 1. Authenticate `cloudflared` to the operator's Cloudflare account

```sh
# Install cloudflared (apt or release binary):
sudo apt install cloudflared
# Browser opens; operator authenticates against the Cloudflare
# account that owns <HOMELAB-DOMAIN>:
cloudflared tunnel login
# Drops a cert.pem into ~/.cloudflared/
```

### 2. Create the tunnel

```sh
cloudflared tunnel create homelab
# Output (something like):
#   Created tunnel homelab with id 12345678-1234-1234-1234-123456789abc
#   Tunnel credentials written to ~/.cloudflared/12345678-...json

TUNNEL_UUID="<from-output>"
echo "$TUNNEL_UUID"
# Operator memorizes / records this UUID for the
# config.yaml + DNS step below.
```

### 3. Seed the credentials JSON to OpenBao

```sh
bao kv put kv/cloudflare/tunnel \
    credentials_json="$(cat ~/.cloudflared/${TUNNEL_UUID}.json)"
```

### 4. Configure Cloudflare DNS (CNAMEs per hostname)

In Cloudflare's dashboard for `<HOMELAB-DOMAIN>`, create
CNAMEs for each hostname routed by the tunnel:

| Subdomain | Type | Target | Proxied |
|---|---|---|---|
| `vaultwarden` | CNAME | `${TUNNEL_UUID}.cfargotunnel.com` | Proxied (orange cloud) |
| `jellyfin` | CNAME | `${TUNNEL_UUID}.cfargotunnel.com` | Proxied (orange cloud) |
| `photos` | CNAME | `${TUNNEL_UUID}.cfargotunnel.com` | Proxied (orange cloud) |
| `ntfy` (when added) | CNAME | `${TUNNEL_UUID}.cfargotunnel.com` | Proxied (orange cloud) |

**Proxied = orange cloud** — required for tunnel routing.
DNS-only (gray cloud) bypasses Cloudflare → tunnel doesn't
trigger.

### 5. Fill placeholders in this layer's manifests

`configmap.yaml`:
- Replace `<CF_TUNNEL_UUID>` with the operator's tunnel UUID
  (line 1 of the `data.config.yaml`).
- Replace `<HOMELAB-DOMAIN>` (the public domain).

These are caught by `homelab-k8s/scripts/check-placeholders.sh`
at deploy time.

### 6. Argo sync

After the seed + placeholder fills, Argo's first reconcile
of this layer brings up the cloudflared Deployment. Verify:

```sh
kubectl -n cloudflare-tunnel get pods
# 2/2 cloudflared-* Running

# Check the metrics endpoint:
kubectl -n cloudflare-tunnel logs -l app.kubernetes.io/name=cloudflared --tail=20
# Expect: "Connection registered" lines for each replica.

# From operator's laptop OUTSIDE the tailnet:
curl -I https://vaultwarden.<HOMELAB-DOMAIN>
# Expect: 200 + valid Cloudflare cert chain.
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Operator runs steps 1-3 above | tunnel exists at Cloudflare; credentials seeded to OpenBao. |
| Operator runs step 4 | DNS records routing hostnames to the tunnel. |
| Argo sync `infrastructure/external-secrets/` + `platform/openbao/` | ESO can pull the credentials Secret. |
| Argo sync this layer | cloudflared Deployment Ready (2 replicas connected to Cloudflare edge). |
| Argo sync `apps/vaultwarden/` + `apps/jellyfin/` + `apps/immich-public-proxy/` | Upstream Services that the tunnel routes to come up. |
| Operator validates per step 6 above | Public ingress confirmed working. |

## Adding a new tunnel-routed service

1. Confirm the service qualifies per ADR 0024 §"What
   qualifies" (E2EE, or `internal-media` classification, or
   has explicit ADR amendment).
2. Add a CNAME in Cloudflare DNS:
   `<subdomain>.<HOMELAB-DOMAIN>` → `${TUNNEL_UUID}.cfargotunnel.com`
   (Proxied).
3. Append an `ingress:` rule to `configmap.yaml` BEFORE the
   catch-all `service: http_status:404` line.
4. Append a matching egress rule to `networkpolicy.yaml`
   pointing at the upstream namespace.
5. Add an ingress allow in the upstream service's NetworkPolicy
   matching `namespaceSelector: cloudflare-tunnel`.
6. Commit + push; Argo rolls cloudflared (no downtime — the
   2 replicas restart staggered).

## Caveats

1. **Single tunnel for the whole homelab.** All public
   services share one Cloudflare tunnel UUID. Compromised
   tunnel credentials → all routed services are reachable
   via the attacker's cloudflared. Mitigation: credentials
   are in OpenBao; tunnel is bound to the operator's
   Cloudflare account; rotation procedure documented in
   `03-runbooks/external-services/cloudflare-tunnel-rotation.md`
   (TBD — tracked in `homelab-docs/TODO.md` under "Runbooks").

2. **TLS termination at Cloudflare.** Per ADR 0024 D4:
   only services where Cloudflare-readable plaintext is
   acceptable (E2EE-encrypted apps, `internal-media` classs)
   route through the tunnel. Forgejo + Authentik + Nextcloud
   are explicitly NOT here for this reason.

3. **HTTP-only between cloudflared and upstream Services.**
   The `service:` URLs in `configmap.yaml` use `http://` not
   `https://`. cloudflared talks plaintext to in-cluster
   Services (Cilium NetworkPolicy + cluster network are the
   confidentiality layer). For TLS-strict apps, add
   `originRequest.noTLSVerify: false` + `caPool` per
   cloudflared docs — homelab uses the simpler form.

4. **`toEntities: world` egress** in the NetworkPolicy is
   broader than the rest of the cluster's posture
   (FQDN-curated). Cloudflare's edge IPs are
   geographically-rotating + many; FQDN-allowlisting is
   brittle. The bound is "outbound 443/UDP+TCP only"; the
   cloudflared image itself is the trust boundary
   (Renovate-pinned + cosign-verifiable).

5. **No HA at Cloudflare-side.** A Cloudflare-edge outage
   = no public access. Tailscale-via-Cilium-Gateway is the
   fallback path (operator + family already on tailnet).
   Friends without Tailscale lose access during a CF edge
   outage; per ADR 0024 D1's "asymmetry" framing this is
   accepted.

6. **Tunnel UUID is operator-fillable in `configmap.yaml`**
   — replaces `<CF_TUNNEL_UUID>` literal. If the tunnel is
   re-created (rare; rotation events), every reference must
   update + cloudflared rolls. Documented as a single-token
   placeholder so operator's editor can find-and-replace.

## Related

- [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — Cloudflare Tunnel + Authentik decisions.
- [`apps/vaultwarden/`](../../apps/vaultwarden/) — first
  Phase-2 consumer.
- [`apps/jellyfin/`](../../apps/jellyfin/) — second.
- [`apps/immich-public-proxy/`](../../apps/immich-public-proxy/)
  — third; read-only `/share/*` surface for Immich albums.
- [03-runbooks/network/cloudflare-tunnel-to-dns-failover.md](../../../homelab-docs/03-runbooks/network/cloudflare-tunnel-to-dns-failover.md)
  — failover when tunnel fails.
- [04-guides/known-caveats.md §Cloudflare Tunnel](../../../homelab-docs/04-guides/known-caveats.md)
  — accumulated caveats.
