# Kyverno policies — homelab admission governance

This directory holds the Kyverno policies that are enforced at admission time
and reported on via background scans. Since 2026-09-14 (hl-0284) every policy
is a `policies.kyverno.io/v1` CEL kind under `cel/` — `ValidatingPolicy`,
`MutatingPolicy`, `GeneratingPolicy`, `ImageValidatingPolicy`; the
`kyverno.io/v1 ClusterPolicy` kind is deprecated in the running Kyverno 1.19
and removed in 1.20. Each file header records how its ClusterPolicy
predecessor mapped onto the new shape. The set breaks into two families:

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
the check for that resource (a `matchConditions` entry on the CEL kinds;
`preconditions` on the old kind). Failures are surfaced to the client as
admission warnings (`validationActions: [Audit, Warn]` — the `Warn` action
is what the old kind's `emitWarning: true` did) which our Loki pipeline
captures so violations are visible in the audit trail — not silent.

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

## Proving a policy evaluates

A policy that compiles and reports `Ready` can still evaluate nothing
(2026-08-02 revert 7b1e30e). Two signals, per kind, are the proof:

- **PolicyReport rows** with the policy's name. Rows from the CEL kinds
  carry `source: KyvernoValidatingPolicy` / `KyvernoMutatingPolicy` /
  `KyvernoGeneratingPolicy` / `KyvernoImageValidatingPolicy`; rows from
  the old kind carried `source: kyverno`. The resource a report is about is
  the report's `.scope` (kind/namespace/name), not `.results[].resources`.
- **Per-kind metrics**: `kyverno_validating_policy_results_total`,
  `kyverno_mutating_policy_results_total`,
  `kyverno_generating_policy_results_total`,
  `kyverno_image_validating_policy_results_total` (labels `policy_name`,
  `result`, `execution_cause`, `resource_kind`). `kyverno_policy_results_total`
  counts the OLD kind only and will read zero for every policy here.

Offline, `scripts/check-kyverno-policy-tests.sh` runs the suites under
`testdata/` with the CLI pinned to the chart's appVersion; see
`testdata/README.md` for what the CLI can and cannot represent.

## Failure mode: Audit never blocks a write

Two independent knobs decide what a policy does to an admission request,
and only one of them is the verdict:

- `validationActions` (`Audit`, `Warn`, `Deny`) — what happens when a
  validation evaluates to **false**.
- `failurePolicy` (`Ignore`, `Fail`; **the API default is `Fail`**) — what
  happens when the policy cannot be evaluated at all: the admission
  controller is unreachable, the webhook call times out
  (`webhookConfiguration.timeoutSeconds`, default 10 s), or a CEL
  expression errors at runtime. `kubectl explain
  validatingpolicies.policies.kyverno.io.spec.failurePolicy`: "failurePolicy
  does not define how validations that evaluate to false are handled."

Kyverno registers **one webhook per policy** in
`kyverno-resource-validating-webhook-cfg` /
`kyverno-resource-mutating-webhook-cfg`, named `vpol.validate.kyverno.svc-
{fail,ignore}-…` (`mpol.…`, `gpol.…`, `ivpol.…`), carrying the policy's
`failurePolicy` and its `matchConstraints` as the webhook's `rules` +
`namespaceSelector`. So the failure mode is decided per policy, and it is
decided by the file — the old ClusterPolicies' Audit rules failed open, and
the migration to the CEL kinds (2026-09-14, `8d13415`) silently flipped ten
Audit-only validators and two mutations to fail **closed**, because the new
field was left unset. Discovered the same evening; fixed in the follow-up
commit.

Why this matters here: in the 2026-06-08 OpenBao incident
(`homelab-docs/99-journal/2026-06-08-openbao-degradation.md`) every Kyverno
pod sat on one worker; when it went NotReady, a `Fail` mutating webhook
stalled every write that traversed it — longhorn-manager, the OpenBao
VolumeAttachments — until the worker came back. A policy whose *only* job
is to write a PolicyReport row must never be able to do that.

The rules, pinned by `scripts/check-known-argocd-drift.sh` on every commit:

| policy class | `failurePolicy` | why |
|---|---|---|
| `validationActions` without `Deny` (Audit, Warn) | `Ignore`, always | it cannot block a write on a verdict, so it must not block one on an outage |
| `validationActions` with `Deny` | **explicit** `Fail` or `Ignore` | `Fail` is a gate and must stay one — but say so in the file, with the webhook's live `namespaceSelector` as the blast-radius evidence (`enforce-digest-pinning-allowlist`: `In [minio-on-nas, backup-cronjobs]` only) |
| `MutatingPolicy` | `Ignore`, always | every mutation here is a convenience (an annotation, `ndots`, a label copy); a skipped mutation is recoverable by hand, a stalled cold start is not |
| `GeneratingPolicy` | (unset) | Kyverno registers `gpol.*` webhooks as `Ignore` regardless — verified live 2026-09-14 |

What `Ignore` costs: an admission-time CEL runtime error on an Audit policy
is swallowed instead of being recorded per `validationActions`; the
background scan (`evaluation.background.enabled: true`) still evaluates the
same expression and reports the error in the PolicyReport, so nothing is
hidden for long. `Ignore` never changes a verdict — a validation that
evaluates to false is still reported, and still returns the `Warn` header.

When a policy is flipped to `Deny` (procedure below), step 3 includes
setting `failurePolicy` explicitly and reading the live webhook's
`namespaceSelector` back:

    kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg -o json \
      | jq -r '.webhooks[] | "\(.name)\t\(.failurePolicy)\t\(.namespaceSelector.matchExpressions|tostring)"'

## Audit -> Deny migration procedure

Every governance policy in this directory starts with
`validationActions: [Audit, Warn]` per project convention (see CLAUDE.md
rule 5 + the `verify-first-party-image-signature` policy header for the
same shape). Flipping a policy to Deny is a three-step procedure:

1. **Watch the PolicyReport for the policy for at least 14 days.**
   Every namespace that would fail Enforce must either be fixed at the
   source, or explicitly waived with the bypass annotation.

       kubectl get polr -A -o json \
         | jq -r '.items[] | .scope as $s | .results[]
                  | select(.policy=="<policy-name>" and .result=="fail")
                  | "\($s.kind) \($s.namespace)/\($s.name)"'

2. **Confirm zero un-waived `fail` results for a full 14-day window.**
   The window is calendar days — long enough that a weekly CronJob or a
   monthly rotation task lands within it.

3. **Edit the policy file: `validationActions: [Audit, Warn] -> [Deny]`, and
   set `failurePolicy` explicitly** (see "Failure mode" above — `Fail` only
   with the webhook's namespaceSelector quoted as the blast radius).
   Commit, ArgoCD sync. The next admission of a violating resource is
   rejected with `Policy <name> failed: <message>` from the policy's own
   webhook (`vpol.validate.kyverno.svc-fail-<hash>`). Watch the reports for
   surprise blocks in the first 24h (same jq as step 1; a report's resource
   is its `.scope`, the old `.results[].resources` path is empty on this
   Kyverno):

       kubectl get policyreport -A -o json \
         | jq -r '.items[] | .scope as $s | .results[]
                  | select(.policy=="<policy-name>" and .result=="fail")
                  | "\($s.kind) \($s.namespace)/\($s.name)"'
       kubectl get clusterpolicyreport -o json | jq '.items[].summary'

   Do NOT watch `kubectl get events --field-selector reason=PolicyViolation`:
   since 2026-09-14 Kyverno is configured with
   `features.omitEvents.eventTypes: [PolicyApplied, PolicySkipped, PolicyViolation]`
   (values.yaml), so no PolicyViolation events are emitted — they were 72% of
   every Event in etcd with no consumer. A blocked admission is still visible
   to the client as the webhook's denial message, and `PolicyError` events
   (engine failures) are still emitted.

If a surprise block appears: **do not revert the flag**. Instead, either
add the bypass annotation to the offending resource (with a real reason
in the value) or fix the resource. Reverting Audit is the escape hatch
of last resort; it means the PolicyReport window missed something and
we should extend it, not that Enforce was wrong.

See `ROLLOUT.md` (this directory) for the per-policy planned Enforce
date and expected initial violation counts.
