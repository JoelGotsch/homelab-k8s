# infrastructure/cert-manager

cert-manager Helm chart plus the **OpenBao-PKI ClusterIssuer**
for cluster-internal mTLS (per
[ADR 0034](../../../homelab-docs/02-decisions/0034-cluster-cert-issuance-hybrid.md)).

## Layout

- `kustomization.yaml` — inflates upstream cert-manager Helm
  chart (`v1.16.1`, Renovate-pinned) plus the two
  cluster-internal resources below.
- `values.yaml` — Helm values (CRDs included).
- `clusterissuer.yaml` — `ClusterIssuer/openbao-pki`,
  cluster-internal mTLS only.
- `openbao-pki-secret.yaml` — token Secret consumed by the
  ClusterIssuer.
- `externalsecret-cloudflare-api-token.yaml` — projects
  `kv/shared/cloudflare/api-token` into the
  `cloudflare-api-token` Secret in this namespace, consumed by
  the Ansible-rendered Let's Encrypt ClusterIssuer's DNS-01
  solver (`apiTokenSecretRef`).

## Sibling ClusterIssuer (Ansible-owned, not in this layer)

The **Let's Encrypt** ClusterIssuer (operator-facing certs per
[ADR 0034 D1](../../../homelab-docs/02-decisions/0034-cluster-cert-issuance-hybrid.md))
is rendered from
`homelab-infra/ansible/files/letsencrypt-clusterissuer.yaml.j2`
and applied by `09b-argocd-bootstrap.yml` — NOT reconciled by
Argo CD — because the operator's ACME-registration email is
private and stays out of this public GitOps repo. Same
discipline as cilium-overrides and openbao-overrides.

That ClusterIssuer references Secret `cloudflare-api-token`
(key `api-token`) in this namespace for its Cloudflare DNS-01
solver. The Secret lifecycle is the two-phase pattern below.

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Keys | Source |
|---|---|---|
| `kv/shared/cloudflare/api-token` | `api-token` | Cloudflare-issued API token, scoped to Zone:DNS:Edit + Zone:Zone:Read for the homelab apex zone. Same token previously held in `homelab_secrets.cloudflare_api_token` in `ansible/inventory/group_vars/all/secrets.sops.yaml`. |

**Two-phase token lifecycle** (matches the seed script's
intended post-OpenBao-up plan):

1. **Cold-start (before OpenBao exists):** the
   `cloudflare-api-token` Secret is seeded directly into the
   cluster by
   `homelab-infra/scripts/seed-cloudflare-api-token.sh`
   reading from `secrets.sops.yaml`. This unblocks initial
   Let's Encrypt issuance before OpenBao + ESO are up.
2. **Steady state (this layer):** once OpenBao is healthy and
   the operator has seeded `kv/shared/cloudflare/api-token`,
   the ExternalSecret in this layer projects the same Secret
   name + key — taking over ownership. cert-manager keeps
   reading the same Secret name across the handoff; no
   ClusterIssuer change.

**Seed snippet** (run once, post-OpenBao-up):

```sh
# Read the cold-start-seeded in-cluster Secret directly into
# bao kv — never echo or pass the token through shell args.
kubectl -n cert-manager get secret cloudflare-api-token \
  -o jsonpath='{.data.api-token}' | base64 -d | \
  bao kv put kv/shared/cloudflare/api-token api-token=-

# Verify (mask the value):
bao kv get -field=api-token kv/shared/cloudflare/api-token | wc -c
# Expect: 53 (current Cloudflare scoped-token length).
```

**Token rotation** (post-handoff): edit the kv path only —
`bao kv put kv/shared/cloudflare/api-token api-token=<new>`.
ESO re-projects within the 1h refreshInterval; cert-manager
re-reads on next DNS-01 attempt. The seed script and
secrets.sops.yaml stop being the source of truth.
