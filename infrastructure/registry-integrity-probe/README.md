# registry-integrity-probe

Scheduled `crane validate` sweep over the **first-party** OCI images in
the Forgejo Packages registry (`registry.homelab.internal`).

## Why

Forgejo Packages blob loss has recurred (ntfy-e2ee-relay `0.1.0`,
2026-06-27 family). A manifest can remain listed while a layer/config
blob it references is gone; nothing notices until a fresh node cold-pulls
the image and fails. This layer pulls **and digests** every first-party
image daily, so blob loss surfaces as a failed Job (→ alert) rather than
a silent landmine.

## How it works

- `cronjob.yaml` runs one `crane validate --remote <ref>` container per
  first-party image (no `--fast` — downloading the blobs *is* the test).
  All run in parallel; the Job fails if any validation exits non-zero.
- The registry is reached via a pod **hostAlias**
  `registry.homelab.internal -> 10.10.30.52` (the registry-direct LB,
  ADR 0038) — the in-pod equivalent of
  `curl --resolve registry.homelab.internal:443:10.10.30.52`. This
  bypasses the Cilium Gateway 403 trap and works before/after the
  unbound DNS cutover.
- TLS verifies against the trust-manager `homelab-trust-bundle`
  ConfigMap (namespace labeled `homelab.lab/inject-ca: "true"`), mounted
  at `/etc/ssl/certs`. Auth is a dockerconfigjson from the
  ExternalSecret.
- `prometheusrule.yaml` alerts on `kube_job_status_failed` (a failed
  run) and on staleness (no success in 2 days / never ran).

## Adding an image

Append a container block to `cronjob.yaml` (same mounts, new
`validate --remote <ref>` args). Keep the ref list aligned with the
first-party deployments: `apps/ntfy-e2ee-relay`, `apps/approval-channel`,
`platform/pr-agent`.

## OpenBao paths to seed

| Path | Keys | Consumed by | Notes |
| --- | --- | --- | --- |
| `kv/shared/forgejo-packages/ci` | `username`, `token` | `externalsecret.yaml` → `registry-homelab-internal-pull` (dockerconfigjson) | **Already seeded** for the `ci-packages` bot (shared with `backup-cronjobs` and every first-party image-pull secret). No new secret to create; this layer only reuses the existing path for pull auth. |
