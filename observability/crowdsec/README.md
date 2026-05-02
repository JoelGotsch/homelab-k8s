# observability/crowdsec

CrowdSec — edge IP-reputation + behavioural detection. Per
[ADR 0021 D6](../../../homelab-docs/02-decisions/0021-observability-stack.md).

**Cluster-side only this layer.** Router-side (OpenWrt
CrowdSec package; shared LAPI access via Tailscale) is
tracked separately as remaining scope; see
[`homelab-docs/TODO.md` §CrowdSec — router-side remaining scope](../../../homelab-docs/TODO.md).

Decisions: [99-journal/2026-04-30-crowdsec-cluster-side.md](../../../homelab-docs/99-journal/2026-04-30-crowdsec-cluster-side.md).

## Architecture

```
                     ┌─ Loki (cilium-gateway envoy access logs)
                     │
                     ▼
                CrowdSec agent  ──→  CrowdSec LAPI  ──→  CNPG Postgres
                                          │                 (this ns)
                                          │
                                          ▼ (decisions API)
                              cidrgroup-sync CronJob  (every 5m)
                                          │
                                          ▼ (kubectl apply)
                              CiliumCIDRGroup `crowdsec-banned`
                                          ▲
                                          │ referenced by
                              CiliumClusterwideNetworkPolicy `crowdsec-banned-deny`
                                          │ ingressDeny: fromCIDRSet
                                          ▼
                                   ALL cluster endpoints
                                   (denied at L3/L4)
```

Detection happens at the agent (rate-over-window scenarios on
envoy access logs read from Loki). Banning happens at the
Cilium CNI layer (CCNP referencing the CIDR group; updated
every 5 minutes from LAPI's decision list by the CronJob).

## Why these shapes (D-decisions in journal)

| Decision | Picked | Why |
|---|---|---|
| A | LAPI db: **CNPG** (not chart-default Postgres) | Codebase-pattern consistency; inherits the existing CNPG → MinIO backup path; one Postgres operator to maintain. |
| B | Cluster-side bouncer: **Cilium-native CCNP** (not HTTP middleware) | Native to the CNI; bans at L3/L4 (broader coverage; faster; covers all traffic types, not just HTTP); fits the Gateway API choice. Reconsider-trigger: per-route ban scenarios. |
| C | Router-side: **deferred** | OpenWrt UCI export + Tailscale subnet exposure are prereqs; landing half-wired would be sterile. Tracked as remaining scope. |
| D | Router → LAPI path (when router lands): **Tailscale** | Matches ADR 0024; encrypted, auth-via-ACL, survives WAN-IP changes. |
| E | Agent log source: **Loki API** (not file-tail DaemonSet) | Composes through canonical retention layer; no DaemonSet on every gateway node; no duplicated file-reading. Reconsider-trigger: credential-stuffing slipping past auth-layer rate limit AND CrowdSec catching up too slowly. |
| F | Allowlist: **ConfigMap (GitOps)** | Declarative; lives in git; matches "everything in git" principle. |

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | helm chart pin (`crowdsecurity/crowdsec` 0.13.5) + resource list. |
| `namespace.yaml` | `crowdsec` ns; PSA baseline. |
| `cnpg-cluster.yaml` | CNPG Cluster CR for the LAPI Postgres (2 instances, longhorn-replica3, MinIO WAL+base backup). |
| `cnpg-s3-externalsecret.yaml` | MinIO creds for CNPG backup. |
| `externalsecret.yaml` | Console enroll key + LAPI Postgres password + cilium-bouncer API key. |
| `values.yaml` | Helm values: agent + LAPI in one release; Loki acquisition; bouncer pre-creation; allowlist mount. |
| `allowlist-configmap.yaml` | Operator-managed whitelist (RFC1918 + Tailscale + cluster pod CIDR + Cloudflare egress placeholder). |
| `ciliumcidrgroup-bootstrap.yaml` | Empty `crowdsec-banned` CIDRGroup; CronJob populates. |
| `ciliumnetworkpolicy.yaml` | CCNP ingressDeny from `crowdsec-banned` CIDRGroup to all endpoints. |
| `ciliumnetworkpolicy-egress.yaml` | CCNP for FQDN-narrowed egress: agent → `hub.crowdsec.net`; LAPI → `api.crowdsec.net` + `app.crowdsec.net`. Replaces the previous broad `0.0.0.0/0:443` allow in vanilla NetPol. |
| `cidrgroup-sync-cronjob.yaml` | Every 5 min: curl LAPI → jq decisions → render CIDRGroup YAML → kubectl apply. Image: alpine/k8s. |
| `rbac.yaml` | ServiceAccount + ClusterRole + ClusterRoleBinding scoped to `crowdsec-banned` CIDRGroup only. |
| `networkpolicy.yaml` | Vanilla NetPols for LAPI + agent + sync (internal allow-lists per role; external 443 egress moved to `ciliumnetworkpolicy-egress.yaml`). |
| `servicemonitor.yaml` | Prometheus scrape of LAPI + agent on :6060. |
| `prometheusrule.yaml` | Alerts on `cs_lapi_decisions_total`: high ban rate, no-decisions-in-24h, LAPI down, CIDRGroup-sync stale. |

## OpenBao paths to seed

| Path | Field | Notes |
|---|---|---|
| `kv/data/crowdsec/console` | `enroll_key` | One-time operator action: register at app.crowdsec.net, enroll the cluster, paste the token. Enables community blocklist subscription. |
| `kv/data/crowdsec/lapi` | `postgres_password` | CNPG-issued password from the cluster's own creds Secret. Operator copies at first install — it's not auto-projected by CNPG, intentionally (separation of secrets). |
| `kv/data/crowdsec/bouncers` | `cilium_bouncer_key` | Generate a random 32-byte hex string (`openssl rand -hex 32`) at first install; the chart's `lapi.bouncers:` pre-creates the bouncer with this key on first start. |
| `kv/data/crowdsec/bouncers` | `openwrt_bouncer_key` | **Only when OpenWrt router-side is enabled.** Operator pre-creates the bouncer in cluster LAPI via `cscli bouncers add openwrt-bouncer -k <KEY>`; same key seeded here. Per [`03-runbooks/network/crowdsec-router-side-bring-up.md`](../../../homelab-docs/03-runbooks/network/crowdsec-router-side-bring-up.md). |
| `kv/data/crowdsec/machines` | `openwrt_machine_password` | **Only when OpenWrt router-side is enabled.** Operator pre-creates the machine in cluster LAPI via `cscli machines add openwrt --auto`; the auto-generated password is seeded here. The OpenWrt agent uses this to authenticate when shipping detections back. |
| `kv/data/cnpg/crowdsec/s3-creds` | `access_key_id`, `secret_access_key` | MinIO svc-account scoped to `homelab-backups-cluster/cnpg/crowdsec/`. Standard CNPG-app pattern. |

**First-install seed:**

```sh
# Bouncer key — generated + seeded:
homelab-infra/scripts/seed-random-secret.sh \
    kv/crowdsec/bouncers cilium_bouncer_key

# CNPG s3-creds — provisioned + seeded after MinIO Healthy:
homelab-infra/scripts/provision-minio-svcacct.sh \
    --alias minio \
    --kv-path kv/cnpg/crowdsec/s3-creds \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/crowdsec/*" \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/crowdsec" \
    --label crowdsec-cnpg

# Console enroll_key + postgres_password are operator-typed
# (one from app.crowdsec.net web UI, one copied from CNPG's
# auto-issued Secret) — seed manually:
bao kv put kv/crowdsec/console enroll_key="<paste-from-app.crowdsec.net>"
bao kv put kv/crowdsec/lapi \
    postgres_password="$(kubectl -n crowdsec get secret \
        crowdsec-lapi-app -o jsonpath='{.data.password}' | base64 -d)"
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `infrastructure/cnpg/` | CNPG operator up. |
| Argo sync this layer | CNPG `crowdsec-lapi` Cluster comes up; LAPI starts and migrates the schema; agent starts but acquisition is empty (no Cilium Gateway access logs in Loki yet). |
| Argo sync `apps/<first-public-app>/` with HTTPRoute | Cilium Gateway envoy starts logging; Alloy ships logs to Loki; agent's Loki acquisition starts seeing data. |
| First scenario fires | LAPI records the decision; CronJob picks it up on next 5m tick; CIDRGroup updates; CCNP ingressDeny matches; banned IP cannot reach any pod. |

## Tuning at first install

1. **Loki acquisition query** in `values.yaml` is `{namespace="cilium-gateway"} |= ""` — verify against
   the actual Cilium-Gateway pod-label scheme via:
   ```sh
   kubectl -n monitoring exec deploy/loki -- logcli labels namespace
   ```
   Adjust the query if the gateway envoy pods land in a
   different namespace.

2. **Parsers** — the chart pulls `crowdsecurity/envoy-logs`
   from the Hub, which assumes a standard envoy access-log
   format. Cilium Gateway's envoy may emit a different format;
   if scenarios don't fire on real traffic, validate via
   `cscli explain` from inside the agent pod and write a
   custom parser at
   `/etc/crowdsec/parsers/s01-parse/cilium-envoy.yaml`.
   Operator extends; mount via a ConfigMap follow-up.

3. **Allowlist** — `allowlist-configmap.yaml` includes
   RFC1918 + Tailscale + cluster pod CIDR + Loopback; **Cloudflare
   egress IPs are commented-out placeholders**, populate when
   the website ingress lands.

4. **Console enrollment** — at app.crowdsec.net, register
   the cluster + grab the enrollment key + write to OpenBao at
   `kv/crowdsec/console/enroll_key`. Without this the
   community blocklist subscription doesn't activate.

## Caveats

1. **Loki-API acquisition latency** — total ban latency
   (log line generated → IP banned at CNI) is ~30-45s vs
   ~5-12s for file-tail. Fine for the brute-force scenarios
   CrowdSec actually defends against; not fine if real-time
   matters for an evolving threat. Reconsider-trigger: see
   journal D-decision E.

2. **Bans propagate at 5-minute granularity** — the
   cidrgroup-sync CronJob runs `*/5 * * * *`. A ban issued
   at 12:00:01 is enforced at the CCNP level by ~12:05:30.
   Tighten the schedule (down to `* * * * *`) if you want
   1-minute granularity; LAPI handles the load.

3. **CIDRGroup `v2alpha1`** — beta in Cilium 1.16+. Future
   bump may move it to v2; sync CronJob script + bootstrap
   manifest both reference the alpha version explicitly.
   Renovate-flag will catch the bump.

4. **CronJob can lag if kube-API is unhealthy** — `kubectl
   apply` retries on transient errors but a sustained kube-
   API outage means CIDRGroup goes stale. Bans applied
   *before* the outage stay enforced (CCNP is durable);
   bans issued *during* don't propagate until kube-API
   recovers + the next CronJob run.

5. **No backup of LAPI ban-list state outside Postgres** —
   if CNPG cluster + MinIO + restic-tier-3 all fail, the
   ban list is lost. Acceptable: bans regenerate from live
   detection within minutes of agent restart; community
   blocklist re-fetches from Console on enrolment.

6. **Operator allowlist is operator-burden** — every false
   positive that the operator wants to silence requires a
   commit + Argo sync. No "click to whitelist" UI by
   design (per decision F).

7. **Cloudflare-fronted traffic shows source IP =
   Cloudflare**, not the real client. CCNP at L3 banning
   would block Cloudflare entirely — catastrophic. The
   allowlist includes commented Cloudflare-IP placeholders;
   operator MUST populate before any HTTPRoute behind
   Cloudflare Tunnel handles real traffic. For
   per-real-client-IP banning on Cloudflare-fronted services,
   the HTTP-middleware bouncer pattern is needed —
   reconsider-trigger named in journal D-decision B.

8. **No alerting on ban events themselves** — when CrowdSec
   bans an IP, that's not a Prometheus alert today. If alert
   volume on bans matters (operator wants to know "we just
   banned 50 IPs in 10 minutes"), wire a PrometheusRule on
   `cs_lapi_decisions_total` + route via Alertmanager →
   approval-channel.

9. **Hub fetches at startup** — agent calls
   `https://hub.crowdsec.net` for collections + parsers +
   scenarios. If egress is blocked or the Hub is down at
   first start, the agent fails to come up. NetworkPolicy
   allows broad 443 egress to make this work; FQDN policy
   via Cilium is the upgrade path.

10. **CronJob image is general-purpose** —
    `alpine/k8s:1.31.0` carries kubectl + curl + jq + many
    other tools we don't use. Single-purpose image is the
    upgrade path (build a tiny operator-owned image with
    only the three binaries); not load-bearing today.

## Related

- [ADR 0021 D6](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — edge IP-reputation + behavioural detection mandate.
- [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — Tailscale as the operator-internal-access path
  (relevant for the deferred router-side).
- [ADR 0001](../../../homelab-docs/02-decisions/0001-four-repo-split.md)
  — homelab-infra is the home for OpenWrt CrowdSec config
  when the router-side eventually lands.
- [99-journal/2026-04-30-crowdsec-cluster-side.md](../../../homelab-docs/99-journal/2026-04-30-crowdsec-cluster-side.md)
  — D1-D6 decisions + caveats + what didn't move.
- [`infrastructure/cilium/values.yaml`](../../infrastructure/cilium/values.yaml)
  — Cilium chart that hosts the CCNP machinery.
- [`observability/loki/`](../loki/) — log source for the
  agent's Loki acquisition.
