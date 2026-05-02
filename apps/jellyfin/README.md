# apps/jellyfin

Family-shared media streaming. NAS-Docker Jellyfin
replacement per
[`migration/nas.md`](../../../homelab-docs/03-runbooks/migration/nas.md).
Per [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
D1 (Cloudflare Tunnel for E2EE / `internal-media` services).

Single-replica Jellyfin + Longhorn for config/DB/cache + NFS-CSI
ReadOnly for the media library (NAS share). Cilium HTTPRoute on
`jellyfin.lab.<HOMELAB-DOMAIN>` Tailscale-only at first commit;
CF Tunnel migration documented for when that layer lands.

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `jellyfin` ns; PSA restricted. |
| `kustomization.yaml` | jellyfin/jellyfin helm 2.5.0; resource list below. |
| `values.yaml` | Single-replica + Longhorn config PVC + media-NFS-PVC ReadOnly; `priorityClassName: homelab-low`; nodeAffinity to workers only (control-plane excluded); `/dev/dri` hostPath-mounted for AMD Radeon VAAPI; sized for 2 simultaneous 4K streams (8Gi limit). |
| `priorityclass.yaml` | `homelab-low` PriorityClass (value -100); Jellyfin yields capacity to operator-critical workloads under node pressure. |
| `nfs-pv.yaml` | Static PV+PVC `jellyfin-media` (4Ti soft cap, ReadOnlyMany) backed by NAS share `<NAS_MEDIA_SHARE>`. |
| `externalsecret.yaml` | OIDC client (ships dormant). |
| `httproute.yaml` | Cilium HTTPRoute on `jellyfin.lab.<HOMELAB-DOMAIN>`; Tailscale-only at first commit. |
| `networkpolicy.yaml` | Vanilla NP: Cilium Gateway + Prometheus + Authentik. CCNP: NFS to `<NAS-IP>` + FQDN-allow for Jellyfin plugin repo + metadata sources (TheTVDB, TMDB, MusicBrainz). |
| `servicemonitor.yaml` | Prometheus scrape (community plugin exposes; ready to scrape post-install). |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/jellyfin/oidc` | `client_id`, `client_secret`, `issuer` | Provisioned via `provision-authentik-oidc-client.sh`. Ships dormant; LDAP/SSO Jellyfin plugin activated post-bring-up. |

(Jellyfin admin user is created via the first-run wizard,
not via env-projected secrets — Jellyfin's bootstrap is
browser-driven and intentionally sticks with that flow.)

**First-install seed:**

```sh
# Authentik OIDC client — provisioned via API helper.
AUTHENTIK_URL=https://auth.lab.<HOMELAB-DOMAIN> \
AUTHENTIK_TOKEN="$(bao kv get -field=api_token kv/authentik/admin)" \
homelab-infra/scripts/provision-authentik-oidc-client.sh \
    --app-name jellyfin \
    --redirect-uri \
      "https://jellyfin.lab.<HOMELAB-DOMAIN>/sso/OID/redirect/authentik" \
    --kv-path kv/jellyfin/oidc
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `infrastructure/cert-manager/` + `platform/openbao/` | Prereqs Healthy. |
| Operator pre-stages NAS share (`<NAS_MEDIA_SHARE>` exists + exported to k8s-nfs as **read-only**). | NFS PV can bind. |
| Argo sync this layer | Longhorn config PVC binds; NFS PVC binds; Jellyfin Deployment Ready; HTTPRoute reconciled. |
| First-time admin login at `https://jellyfin.lab.<HOMELAB-DOMAIN>` | Operator runs the first-run wizard: admin user creation, library setup pointing at `/media/<lib-name>` for each library. |
| Library scan completes | Family members can connect. |
| (post-Authentik) operator installs LDAP/SSO plugin | OIDC login flow active for family members. |

## Post-bring-up activation (one-time)

### 1. First-run wizard

Browser to `https://jellyfin.lab.<HOMELAB-DOMAIN>/`. Walk
through:
- Language + locale
- Admin user creation (operator-typed username + strong
  password; capture in Vaultwarden)
- Library setup: point at `/media/movies`, `/media/tv`,
  `/media/music`, etc. (each subdir under the NFS-mounted
  `/media` becomes a library).
- Remote access: leave OFF; Cilium Gateway already exposes
  it.

### 2. Plugin installs (Dashboard → Plugins → Catalog)

- **Metrics**: jellyfin-plugin-metrics for Prometheus scrape.
- **LDAP/SSO**: jellyfin-plugin-ldapauth for Authentik OIDC
  bridging (Jellyfin doesn't natively support OIDC; this
  plugin maps OIDC to Jellyfin user creation).

After installing the LDAP/SSO plugin: Dashboard → SSO
Authentication → Add Provider → paste values from
`kv/jellyfin/oidc` (the env vars are projected into the
pod via values.yaml's `extraEnv`).

### 3. Family-account onboarding

Per `jellyfin/family-account-onboarding.md` (TBD). Each
family member:
- Authentik account created in Authentik admin UI
- First Jellyfin login auto-creates the Jellyfin user via
  the SSO plugin
- Operator sets per-user library access + parental controls
- Family member's clients (Jellyfin Mobile, web) work

### 4. VAAPI activation (AMD Radeon Vega — workers only)

The Jellyfin pod is already (a) scheduled to worker nodes
only via nodeAffinity, and (b) hostPath-mounting `/dev/dri`
from the host. After first-run wizard:

1. Dashboard → Playback → Hardware Acceleration:
   - **Hardware acceleration**: `Video Acceleration API (VAAPI)`
   - **VA-API Device**: `/dev/dri/renderD128`
2. Save. Verify: stream a 4K H.265 source; check Dashboard
   → Logs for `vaapi_h265` or `vaapi_hevc` codec lines.

**AMD Vega VCN 2.x coverage** on cluster-node-4/5/6:
- H.264 / H.265 / HEVC 10-bit decode: yes
- Encode: **software only** (no UVE on this generation)
- HDR → SDR tone-mapping: software only

So VAAPI offloads ~50% of transcode CPU (decode side);
encode stays on the 8C/16T Ryzen — easy on workers.

**5700U caveat** (cluster-node-6 only): older VCN; per the
[2026-04-27 NAS journal](../../../homelab-docs/99-journal/2026-04-27-nas-trust-and-storage-redesign.md)
"should be tested before declaring 'Jellyfin on cluster' the
answer to streaming stutter." If 5700U misbehaves: add a
node anti-affinity excluding it.

**Render group GID**: hardcoded to 105 in values.yaml's
`supplementalGroups`. Validate at first deploy:
```sh
kubectl debug node/<worker-node-name> --image=alpine \
  -- ls -ln /dev/dri/renderD128
```
If GID differs (some Linux distros use 109 or 44), update
`supplementalGroups` in values.yaml.

### 5. Friend access (dual-mode auth)

Vaultwarden + Nextcloud are operator + family only via
Authentik. **Jellyfin runs dual-mode** to allow friends
without granting them access to the rest of the homelab:

| User class | Auth path | Access scope |
|---|---|---|
| **Operator + family** | Authentik OIDC + WebAuthn → SSO plugin auto-creates Jellyfin user | All libraries (or per-library ACL) |
| **Friends** | Jellyfin-native account (operator creates in Dashboard → Users) | Per-friend library ACL — typically only `public-media` library |

This works because:
- Authentik is **Tailscale-only** per ADR 0024 D3; friends
  can't reach `auth.lab.<DOMAIN>` without Tailscale → can't
  OIDC-login.
- The SSO plugin only intercepts logins flagged for OIDC;
  native logins pass through unchanged.
- Per-user library access in Jellyfin gates which libraries
  each friend sees.

**To onboard a friend** (post-bring-up):
1. Dashboard → Users → Add User
2. Name + password; AuthenticationProvider = `Default`
3. Library Access → only `public-media` (whatever the
   operator considers safe for non-family)
4. Send credentials via Signal (one-time). Friend logs in
   via the public Jellyfin URL once
   `infrastructure/cloudflare-tunnel/` lands; until then
   via Tailscale-with-shared-friend-account
   (operator-managed).

Friends never touch Authentik, never reach Vaultwarden /
Nextcloud / Forgejo, never appear in the OIDC user list.

## Caveats

1. **Media library is ReadOnlyMany.** Jellyfin scans + reads
   only. Operator's media-write path is direct SMB / NFS
   from laptop, **not** through cluster Jellyfin. Protects
   the library from accidental cluster-side mutation.

2. **Phase-2 Cloudflare Tunnel deferred.** Public-facing
   jellyfin.<HOMELAB-DOMAIN> waits for the
   `infrastructure/cloudflare-tunnel/` layer to land. Until
   then, family-shared streaming requires Tailscale on the
   client device. Operator-only testing is fine via Cilium
   HTTPRoute.

3. **No native OIDC.** Jellyfin's OIDC story is plugin-
   driven (jellyfin-plugin-ldapauth or community SSO
   plugins). Operator installs the plugin post-bring-up;
   the env vars are pre-wired so plugin config is a few
   clicks vs typing values. **Friends use native Jellyfin
   accounts** (not OIDC) — see §"Friend access (dual-mode
   auth)" above.

4. **`readOnlyRootFilesystem: false`.** Jellyfin writes
   transcode-cache to `/tmp` and plugin downloads to
   `/config` (its own PVC). Rootfs writes are minimal but
   non-zero. Switch to true requires redirecting transcode-
   cache to a separate emptyDir.

5. **Single replica.** No HA; pod eviction = ~30s
   interruption. Resilience via Longhorn snapshot + Restic
   tier-3 (config/DB) + NAS-side backup (media library).

6. **Memory limit 8Gi**, sized for 2 simultaneous 4K streams
   (per operator's 2026-05-02 decision). Budget: Jellyfin
   baseline ~500MB + 2 × FFmpeg transcode pipelines ~3GB +
   HDR→SDR tone-mapping buffers ~2GB + library scan / thumb
   gen ~500MB + ~2GB headroom. CPU is the more likely
   bottleneck than memory at 2× concurrent.

7. **Lowest-priority workload** (`homelab-low` PriorityClass).
   Under node resource pressure, kubelet evicts Jellyfin
   first — keeping operator-critical services
   (OpenBao, CNPG, Authentik, Vaultwarden, etc.) scheduling-
   resilient. Operator decision: "Jellyfin won't be used
   much but if so shouldn't be bound much by resource limits
   (large limit), priority is lowest compared to all other
   cluster processes."

8. **Worker-only scheduling.** nodeAffinity excludes
   control-plane nodes — Jellyfin needs the AMD Radeon
   Vega iGPU on worker nodes for VAAPI hardware decode.
   Control-plane nodes have iGPUs too (Ryzen 7 7730U) but
   the affinity intentionally restricts Jellyfin to workers
   to keep control-plane resources free for k8s control
   itself.

7. **Plugin-fetch egress is FQDN-curated** (TheTVDB, TMDB,
   MusicBrainz, Jellyfin plugin repo). New plugin → unlisted
   FQDN → operator extends `networkpolicy.yaml`'s CCNP
   `toFQDNs` list.

## Migration from NAS-Docker Jellyfin

Per [`migration/nas.md`](../../../homelab-docs/03-runbooks/migration/nas.md)
+ [`jellyfin/migrate-from-nas-docker.md`](../../../homelab-docs/03-runbooks/jellyfin/migrate-from-nas-docker.md)
(stub; covers VAAPI setup). High-level:

1. Cluster Jellyfin up + library scan complete.
2. Export user list + watched-state from NAS-Docker
   Jellyfin (Dashboard → Users → Export).
3. Import to cluster Jellyfin via the same plugin.
4. Family members re-add the cluster URL in their clients;
   keep NAS-Docker Jellyfin running 14 days as fallback.
5. After 14 days: stop NAS-Docker Jellyfin; 30 days later
   remove the container.

## Related

- [ADR 0024 D1](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — Cloudflare Tunnel + Authentik OIDC for Jellyfin.
- [ADR 0025](../../../homelab-docs/02-decisions/0025-nas-as-encrypted-bulk-substrate.md)
  — NAS as bulk-storage substrate (media library).
- [`platform/authentik/templates/`](../../platform/authentik/templates/)
  — OIDC client pattern.
- [03-runbooks/jellyfin/](../../../homelab-docs/03-runbooks/jellyfin/)
  — VAAPI setup, family-onboarding, NAS-Docker migration.
- [03-runbooks/migration/nas.md](../../../homelab-docs/03-runbooks/migration/nas.md)
  — pre-cluster NAS extraction.
