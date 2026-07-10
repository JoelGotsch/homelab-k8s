# Kyverno policies — homelab admission governance

This directory holds the `ClusterPolicy` resources that Kyverno enforces at
admission time and reports on via background scans. The set breaks into two
families:

- **Supply-chain / hygiene** (pre-existing): image signature verification,
  digest pinning, probe hygiene, DNS ndots workaround, Longhorn label
  propagation. Per ADR 0019 D3, ADR 0023.
- **Cluster-wide governance** (ADR 0036): namespace-baseline validators
  and generators, resource-declaration validation, CNP egress hygiene,
  storage-reclaim + inline-secret validation.

## Naming convention

- New governance policies are prefixed `homelab-` (this repo's admission
  layer, versus upstream Kyverno's public policy library).
- The verb in the name states the class:
  - `homelab-require-<subject>` — validate presence of a resource
  - `homelab-disallow-<subject>` — validate absence of an anti-pattern
  - `homelab-generate-<subject>` — auto-materialise a resource
  - `homelab-warn-<subject>` — audit-only signal, no enforcement path
- Pre-existing policies use the `verify-`, `audit-`, `enforce-` verbs
  from ADR 0019/0023. New ADR 0036 policies use the `homelab-` prefix.
  Both continue to coexist.

## Bypass annotation

Every homelab-governance policy honours a uniform per-policy waiver
annotation on the target resource:

    bypass.homelab.internal/<policy-name>: <non-empty reason>

Presence of the annotation with a non-empty value makes the policy skip
the check for that resource. Kyverno emits a warning event (see
`emitWarning: true` in each policy spec) which our Loki pipeline
captures so waivers are visible in the audit trail — not silent.

A handful of policies also honour a *semantic* bypass in addition to the
mechanistic per-policy one. For example, `homelab-disallow-inline-secrets`
accepts either
`bypass.homelab.internal/homelab-disallow-inline-secrets` (mechanistic)
or `bypass.homelab.internal/inline-secret` (semantic — "yes this secret
is intentionally inline"). Both patterns are equivalent; use whichever
reads better in the manifest.

## Labels the governance policies key off

- `homelab.internal/first-party: "true"` on Namespace — selects
  namespaces that the require-* and generate-* policies act on.
- `homelab.internal/data-class: {public,internal,personal,secret}` on
  Namespace — per ADR 0003, orthogonal to first-party selection but
  read by downstream tooling.
- `homelab.internal/component: default-deny` (or name `default-deny`)
  on NetworkPolicy — recognised by
  `homelab-require-namespace-default-deny-netpol` as the baseline.
- `homelab.internal/generated-by: kyverno` on generated resources —
  makes provenance greppable.
- `external-secrets.io/backend: openbao` on Secret — recognised by
  `homelab-disallow-inline-secrets` as ESO-owned.

## Retention annotation (storage)

`retention.homelab.internal/reason: <text>` on a PVC opts the PVC into
Retain-reclaim StorageClass usage. Enforced by
`homelab-disallow-retain-reclaim-without-annotation`.

## Default LimitRange shape (generated)

    default:        cpu 500m, memory 512Mi
    defaultRequest: cpu 50m,  memory 128Mi

Materialised as `default-limits` in every first-party namespace by
`homelab-generate-default-limitrange`. Namespaces that need different
defaults ship their own LimitRange under any *other* name; the generator
only owns `default-limits`.

## Default ResourceQuota shape (generated)

    requests.cpu:     4
    requests.memory:  8Gi
    limits.cpu:       8
    limits.memory:    16Gi
    count/pods:       50

Materialised as `default-quota`. Same "own name only" semantics as the
LimitRange.

## Default-deny NetworkPolicy shape (generated)

    podSelector: {}
    policyTypes: [Ingress, Egress]
    (no `ingress:` / `egress:` blocks — total deny)

Materialised as `default-deny`. Layer allow-CNPs on top per app.

## Audit -> Enforce migration procedure

Every governance policy in this directory starts with
`validationFailureAction: Audit` per project convention (see CLAUDE.md
rule 5 + the `verify-first-party-image-signature` policy header for the
same shape). Flipping a policy to Enforce is a three-step procedure:

1. **Watch the PolicyReport for the policy for at least 14 days.**
   Every namespace that would fail Enforce must either be fixed at the
   source, or explicitly waived with the bypass annotation.

       kubectl get polr -A -l homelab.internal/policy=<policy-name>
       # or, broader:
       kubectl get polr -A -o json \
         | jq '.items[].results[] | select(.policy=="<policy-name>" and .result=="fail")'

2. **Confirm zero un-waived `fail` results for a full 14-day window.**
   The window is calendar days — long enough that a weekly CronJob or a
   monthly rotation task lands within it.

3. **Edit the policy file: `validationFailureAction: Audit -> Enforce`.**
   Commit, ArgoCD sync. The next admission of a violating resource is
   rejected. Watch `kubectl get events -A --field-selector reason=PolicyViolation`
   for surprise blocks in the first 24h.

If a surprise block appears: **do not revert the flag**. Instead, either
add the bypass annotation to the offending resource (with a real reason
in the value) or fix the resource. Reverting Audit is the escape hatch
of last resort; it means the PolicyReport window missed something and
we should extend it, not that Enforce was wrong.

See `ROLLOUT.md` (this directory) for the per-policy planned Enforce
date and expected initial violation counts.
