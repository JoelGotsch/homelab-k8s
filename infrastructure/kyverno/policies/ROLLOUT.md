# ADR 0036 Kyverno policy rollout — Audit -> Enforce roadmap

All ADR-0036 governance policies are currently in `Audit`. Migration to
`Enforce` follows the procedure in `README.md` and the order below,
which is intentionally **least-current-violators first** so that early
flips build operator confidence in the Enforce shape before we hit the
high-count policies.

## Ordering rationale

1. **Storage policies (fewest current violators)** — the new
   `longhorn-replica*-retain` StorageClasses do not exist yet on any
   PVC, so the retain-annotation validator has essentially zero
   day-one violations. Ships as an Enforce candidate the moment the
   StorageClasses land.
2. **Secrets policy** — small blast radius; the `external-secrets.io/
   backend` label is already set on ESO-owned secrets. Expect a
   handful of bootstrap secrets to need the `inline-secret` bypass.
3. **CNP open-egress policy** — countable violators (feedback file
   already lists the CI Woodpecker case as fixed; a few monitoring
   collectors expected).
4. **Namespace-baseline require-* policies** — every first-party
   namespace should have all three baselines once the paired
   generators run one reconcile cycle. Flip after generators observed
   stable for 14 days.
5. **Per-container memory limits** — highest current-violator count
   (~40% from the 2026-06-26 memory baseline sweep). Flip last, once
   the offender list has been swept by the "audit + fix all first-
   party apps" task track.
6. **`homelab-warn-unlimited-cpu`** — never flips to Enforce; CFS
   quota throttling is a real hazard cluster-wide.

## Policy table

| Policy                                                     | Current | Target flip                                                                     | Expected initial `fail` count                          |
|------------------------------------------------------------|---------|---------------------------------------------------------------------------------|--------------------------------------------------------|
| `homelab-disallow-retain-reclaim-without-annotation`       | Audit   | On `longhorn-replica{2,3}-retain` SC ship + 14d clean PolicyReports             | 0 at day-one (SC not yet used)                         |
| `homelab-disallow-inline-secrets`                          | Audit   | 14d clean after operator sweep of first-party ns Secrets                        | ~5-10 (bootstrap + helm-hook secrets across the fleet) |
| `homelab-disallow-open-egress-cnp`                         | Audit   | 14d clean after CNP audit (CI Woodpecker already fixed; check monitoring set)   | ~3-5 (monitoring collectors expected)                  |
| `homelab-require-namespace-limitrange`                     | Audit   | 14d after `homelab-generate-default-limitrange` observed stable                 | 0 (generator materialises baseline)                    |
| `homelab-require-namespace-resourcequota`                  | Audit   | 14d after `homelab-generate-default-resourcequota` observed stable              | 0 (generator materialises baseline)                    |
| `homelab-require-namespace-default-deny-netpol`            | Audit   | 14d after `homelab-generate-default-deny-netpol` observed stable                | 0 (generator materialises baseline)                    |
| `homelab-generate-default-limitrange`                      | Audit   | Stays Audit (generate rules have no admission-block semantics; report-only)     | 0 generate-failures expected                           |
| `homelab-generate-default-resourcequota`                   | Audit   | Stays Audit (same reason)                                                       | 0 generate-failures expected                           |
| `homelab-generate-default-deny-netpol`                     | Audit   | Stays Audit (same reason)                                                       | 0 generate-failures expected                           |
| `homelab-disallow-unlimited-containers`                    | Audit   | After sweep of all first-party workloads + cluster-mcp goes live + 14d clean    | ~40% of containers (2026-06-26 memory baseline stat)   |
| `homelab-warn-unlimited-cpu`                               | Audit   | **Never** (audit-only forever — CFS throttling caveat)                          | ~87% of containers (2026-06-26 memory baseline stat)   |

## Expected order of flips (chronological, once conditions met)

1. `homelab-disallow-retain-reclaim-without-annotation`
2. `homelab-disallow-inline-secrets`
3. `homelab-disallow-open-egress-cnp`
4. `homelab-require-namespace-limitrange`
5. `homelab-require-namespace-resourcequota`
6. `homelab-require-namespace-default-deny-netpol`
7. `homelab-disallow-unlimited-containers`

(The three generate-* policies and `homelab-warn-unlimited-cpu` never
flip to Enforce, per the notes above.)
