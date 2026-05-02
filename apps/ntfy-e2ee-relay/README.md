# apps/ntfy-e2ee-relay

Webhook proxy: Falcosidekick / Alertmanager → AES-256-GCM →
ntfy server. Per
[ADR 0024 D1 phase-2](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md).

Source code in the sibling repo
[ntfy-e2ee-relay/](../../../ntfy-e2ee-relay/) (per
[ADR 0001](../../../homelab-docs/02-decisions/0001-four-repo-split.md)
operator-owned code lives in its own repo).

## Layout

| File | Purpose |
|---|---|
| `kustomization.yaml` | Plain kustomize (no Helm chart from upstream — operator-owned image). |
| `namespace.yaml` | `ntfy-e2ee-relay` ns, restricted PSA. |
| `externalsecret.yaml` | Topic AES-256 key + optional ntfy auth header from OpenBao. |
| `deployment.yaml` | ConfigMap (cluster-internal config) + Deployment + Service. Single replica; readOnlyRootFilesystem; restricted PSA-compatible. |
| `networkpolicy.yaml` | Default-deny; ingress from `monitoring` ns (Falcosidekick); egress to `ntfy` ns (the cluster-hosted ntfy server) + kube-DNS only. |

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).
ExternalSecret in `externalsecret.yaml` projects these into
the namespace; without them, the pod fails to start.

| Path | Keys | Source |
|---|---|---|
| `kv/ntfy/topic-key` | `value` | `openssl rand 32 \| base64 -w0` — generate at first install. **Operator records the same key in the F-Droid app config** (Tier C device per [ADR 0024 D1](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)). |
| `kv/ntfy/publish-auth` | `header` | _(optional)_ Bearer / Basic auth header value if the cluster-hosted ntfy server requires topic auth. Empty / missing = relay publishes anonymously. |
| `kv/ntfy-e2ee-relay/inbound-auth-token` | `token` | Bearer-token-style secret for the `/webhook` endpoint. Generate at first install: `openssl rand -hex 32`. AM-side mirror Secret in monitoring ns is `am-inbound-tokens` (key `ntfy-e2ee-relay`); created by the kube-prometheus-stack ESO ExternalSecret. **Note:** the Falcosidekick → ntfy-relay direct webhook path is NOT currently authenticated (see [known-caveats.md §ntfy-e2ee-relay](../../../homelab-docs/04-guides/known-caveats.md)). |

**First-install seed:**

```sh
# Topic key — generate, store in OpenBao, and capture for
# F-Droid app config:
KEY_B64=$(openssl rand 32 | base64 -w0)
bao kv put kv/ntfy/topic-key value="$KEY_B64"

# Save for F-Droid app config (operator pastes into the app's
# topic settings under "Decrypt with key"). DO NOT email or
# Signal-send the key — operator types it into the phone
# directly from a sticky.
echo "$KEY_B64" > /tmp/ntfy-key-for-fdroid.txt
# (... operator types into phone, then ...)
shred -u /tmp/ntfy-key-for-fdroid.txt

# Optional: ntfy publish-auth (only if the cluster-hosted ntfy
# requires auth for publishing — see the ntfy server's own
# config):
bao kv put kv/ntfy/publish-auth \
  header="Bearer tk_xxxxxxxxxxxxxx"

unset KEY_B64
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| [Step 9 — Cluster bring-up](../../../homelab-docs/04-guides/cold-start.md) | OpenBao + ESO + ClusterSecretStore ready |
| Cluster-side ntfy server scaffold (separate, **TBD**) | `ntfy` namespace + ntfy server pod + per-topic config |
| [Step 13b — operator-managed images](../../../homelab-docs/04-guides/cold-start.md) | Woodpecker builds `ntfy-e2ee-relay:<tag>` from sibling repo |
| [Step 13c — Seed ExternalSecret OpenBao paths](../../../homelab-docs/04-guides/cold-start.md) | `kv/ntfy/topic-key` populated; F-Droid app config updated |
| Argo sync | This layer reconciles |

After Argo sync, run the end-to-end verify harness from the
sibling repo:

```sh
# From operator's Tier A laptop, after kubectl port-forward:
kubectl -n ntfy-e2ee-relay port-forward svc/ntfy-e2ee-relay 8000:8000 &
kubectl -n ntfy port-forward svc/ntfy 8080:80 &

NTFY_BASE_URL=http://localhost:8080 \
NTFY_TOPIC=homelab-alerts \
NTFY_TOPIC_KEY_B64=$(bao kv get -field=value kv/ntfy/topic-key) \
RELAY_URL=http://localhost:8000/webhook \
python3 ../../../ntfy-e2ee-relay/scripts/verify-e2e.py
# Expect: "OK: end-to-end E2EE verified."
```

## Operator inputs

Placeholders (caught by
[homelab-k8s/scripts/check-placeholders.sh](../../scripts/check-placeholders.sh)):

- _none in this layer's manifests at this time_ — all
  operator-fillable values are env-var-driven from the
  ConfigMap (cluster-internal endpoints) or
  ExternalSecret-projected (topic key + auth).

If the cluster-hosted ntfy server moves namespaces or its
service name changes, update `NTFY_BASE_URL` in
`deployment.yaml`'s ConfigMap.

## Caveats

- **Wire-format compatibility** — see
  [ntfy-e2ee-relay/README.md §Wire format](../../../ntfy-e2ee-relay/README.md).
  The relay's default `aes-256-gcm.b64` format must match
  what the operator's F-Droid app expects. **Verify
  end-to-end at first install** via the harness above; do
  not declare the layer healthy until the harness round-trips.
- **Cluster-hosted ntfy server is a separate scaffold**
  (TBD) and a hard prereq. The relay's NetworkPolicy
  allows egress to the `ntfy` namespace only; nothing
  works until that ns + server are up.
- **Falcosidekick wiring** — the relay accepts
  Falcosidekick's webhook output shape, but Falcosidekick
  itself must be configured to POST here. That config
  lands in the kube-prometheus-stack / Falcosidekick
  observability layer when it deploys.
- **Single replica.** Webhook proxy is stateless but
  multi-replica adds no value for this load profile (alert
  rate is sparse). If horizontal scaling becomes worth it
  (e.g. high-rate Alertmanager bursts), the deployment is
  HPA-ready — readinessProbe + stateless behavior already
  in place.
- **Topic key rotation is annual + manual** per
  [ADR 0024 D1](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md).
  Brief overlap window where old key is still valid.
  Procedure: generate new key, write to OpenBao, restart
  relay pod, update F-Droid app config; pause Falcosidekick
  during the swap window if alert continuity matters.

## Related

- [ADR 0024](../../../homelab-docs/02-decisions/0024-external-access-for-internal-services.md)
  — phase-2 design sketch.
- [ADR 0021](../../../homelab-docs/02-decisions/0021-observability-stack.md)
  — the alerting stack this hooks into.
- [ntfy-e2ee-relay/](../../../ntfy-e2ee-relay/) — sibling
  repo with the relay's source + tests + verify harness.
- [observability/signal-webhook.md](../../../homelab-docs/03-runbooks/observability/signal-webhook.md)
  — Signal sink (primary alert channel; ntfy is additive).
