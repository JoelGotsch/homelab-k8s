# infrastructure/kyverno

Kyverno admission controller plus the supply-chain policies
referenced by ADR 0019 D3 and ADR 0023.

Resources:

- `kustomization.yaml` — Helm chart pull + resource glue.
- `values.yaml` — chart values (replica counts, image
  overrides for the cleanup CronJobs).
- `clusterpolicies.yaml` — `require-first-party-image-digest`
  (Audit during bring-up) + `audit-third-party-image-digest`
  (Audit, non-blocking).
- `policies/verify-first-party-image-signature.yaml` —
  cosign signature verification on first-party images (ADR
  0019 D3). Templated from the `.yaml.j2` sibling for the
  parametric Forgejo apex hostname; render entry in
  `homelab-infra/ansible/playbooks/00-render-static.yml`.
- `externalsecret-cosign-public-key.yaml` — projects the
  cosign public key into the kyverno namespace for the
  verify policy to reference.

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).
ExternalSecret in `externalsecret-cosign-public-key.yaml`
projects these into the namespace; without them, the verify
policy fails open in Audit mode (PolicyReport `error: secret
not found`) and would fail closed in Enforce mode (every
first-party Pod admission rejected).

| Path | Keys | Source |
|---|---|---|
| `kv/shared/cosign/key` | `public` | `homelab-infra/scripts/seed-cosign-keypair.sh` — `cosign generate-key-pair` ceremony; also writes `private` + `password` for the CI signing step (consumed by Woodpecker, not by Kyverno) |

**First-install seed:**

```sh
# tier-A workstation, with bao login session:
cd homelab-infra && ./scripts/seed-cosign-keypair.sh
```

That script writes private + password + public to a single kv
path (`kv/shared/cosign/key`); the public field is what this
ExternalSecret reads. ESO refresh interval is 1h; force-sync
with:

```sh
kubectl -n kyverno annotate externalsecret \
  cosign-public-key force-sync=$(date +%s)
```

Then add a row to cold-start.md Step 13c's inventory table
linking to this section.

## Promoting verify-first-party-image-signature to Enforce

The policy ships in Audit mode (`failureAction: Audit`,
`mutateDigest: false`). After one successful first-party Pod
admission shows `result: pass` in the PolicyReport, flip both
fields together:

```yaml
verifyImages:
  - failureAction: Enforce
    mutateDigest: true
```

Kyverno's admission webhook rejects `mutateDigest: true +
failureAction: Audit` as inconsistent ("mutateDigest must be
set to false for 'Audit' failure action"). They must be
flipped in the same commit.

Observe the PolicyReport before flipping:

```sh
kubectl get policyreport -A -o json \
  | jq '.items[].results[] | select(.policy == "verify-first-party-image-signature")'
```

## Rotating the cosign keypair

1. `homelab-infra/scripts/seed-cosign-keypair.sh --rotate`
   (prints OLD public key first — keep if needed to verify
   historical signatures).
2. `homelab-infra/scripts/provision-woodpecker-repo.sh
   --config ansible/inventory/woodpecker-repos.yml` (pushes
   new private + password to Woodpecker repo secrets).
3. ESO syncs the new public key into the cluster within 1h
   (or force-sync per above).
4. New signed images verify; old signed images fail
   verification until rebuilt + resigned. This is by design —
   cosign verifies against the current trust anchor only.
