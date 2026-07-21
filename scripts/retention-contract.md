# Distributed retention contract

`check-retention-contract.sh` is a desired-state-only P0-08/KST-01 gate. It
does not call the cluster, inspect a PV, change a claim, or prove a backup. The
default `retention-contract.yaml` covers only storage selectors owned by
`homelab-k8s`: `infrastructure/`, `platform/`, `observability/`, and
`components/`.

That scope is intentional. `bootstrap/applicationsets/apps.yaml` may source an
app from `k8s/` in another Forgejo repository. Once that cutover happens, a
central scan of the old `apps/<name>/` copy is both stale and unsafe: it can be
green while the reconciled repository regresses.

## Repository-local contract

Every repository which owns a Longhorn-backed app must carry:

1. the same checker interface;
2. a repository-local `retention-contract.yaml` whose `scope.roots` contains
   only paths that repository owns; and
3. a pre-commit hook over those paths, the checker, and the contract.

The checker accepts `--root DIR --contract FILE`, so the mutation suite can
exercise a fixture or a workspace aggregate can invoke an app contract without
changing the app checkout.

Each explicit Longhorn `storageClass` or `storageClassName` in the declared
scope must have exactly one matrix entry. An entry records the source selector,
current and target class, desired reclaim policy, finite state
(`compliant`/`known-mismatch`), data value/class, backup tier, RPO/RTO,
migration owner, and required restore test. The check rejects:

- an unclassified new Longhorn selector;
- source or generated `.j2` mirror drift;
- an inaccurate StorageClass reclaim-policy catalog;
- duplicate/incomplete entries;
- a target class that does not implement the declared lifecycle; and
- a mismatch without a named migration owner.

`known-mismatch` is containment only. It is not a waiver, proof that a live PV
uses `Retain`, or authority to change an immutable claim. Remove it only in the
same reviewed source/contract change used by an attended KST-03 migration.

## Workspace aggregate

The aggregate belongs at workspace level, not in an app repository. It should:

1. parse the static list in `bootstrap/applicationsets/apps.yaml`;
2. resolve each exact `repo` and `path` at the reviewed main commit;
3. require a repository-local contract even when it has zero Longhorn claims;
4. invoke that repository's checker and record the commit plus contract digest;
5. reject a registered source with no contract, an unregistered contract, or a
   contract whose declared root does not contain the ApplicationSet path; and
6. aggregate, but never silently copy, the owner-repository matrix rows.

Do not make this aggregate a precondition for the central hook: a single-repo
checkout must still protect the manifests it owns. CI can invoke the aggregate
later, but the repository-local hooks land first.

The six app entries still sourced from `homelab-k8s/apps/` need zero-entry or
populated app-local contracts before the aggregate can be made blocking. The
published app repositories need the same adoption change on their own mains.
Until then, this central contract closes only the cluster-owned slice and must
not be reported as full workspace KST-01 completion.
