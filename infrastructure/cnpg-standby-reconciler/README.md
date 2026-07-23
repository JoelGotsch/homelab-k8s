# cnpg-standby-reconciler

Unattended safety net for the **idle-primary WAL trap**: a CloudNativePG
standby that rejoins (or is re-cloned) after an unclean node loss can hang
forever at `FATAL: … Consistent recovery state has not been yet reached`
because its control file needs WAL a few bytes past the last page boundary it
streamed, and a fully idle primary emits none. The cluster sits at
`readyInstances < instances` and the operator does not self-heal it. Observed
on immich-pg (2026-07-21) and on immich-pg-1 + vaultwarden-pg-1 during the
2026-07-23 worker2 hot-pull. Rationale and decision: **ADR 0041**.

## What it does

A CronJob (every 5 min) lists CNPG clusters and, for any cluster stuck below
its instance count, re-clones one stuck standby: it deletes that instance's
PVC(s) + pod, and CNPG rebuilds it from the primary via `pg_basebackup`. A
fresh base backup snapshots at the primary's *current* LSN, so it never waits
on WAL the idle primary hasn't produced — and it also clears the other stuck
variants (walreceiver wedged, WAL recycled) that a `CHECKPOINT` can't.

It uses **only Kubernetes delete on PVCs/pods — no database credentials, no
`exec`** into the secret-tier databases. That is the deliberate reason a
standing component uses re-clone rather than the cheaper `CHECKPOINT`
(`CHECKPOINT` needs superuser-equivalent `pods/exec`). The operator's manual
fast-path for a planned rejoin remains `homelab-infra/scripts/reconcile-cnpg-standbys.sh`
(one CHECKPOINT, seconds, no data movement); this controller is the safety net
for when nobody runs it.

## Safety guards (the contract)

Acts only when **all** hold, at most `MAX_ACTIONS_PER_RUN` per run, one/cluster:

- cluster `spec.instances >= 2` (never a single-instance cluster);
- a current primary exists **and its pod is Ready** (a healthy clone source —
  otherwise it does nothing);
- the target is a **non-primary** instance pod not-Ready for `> GRACE_MINUTES`
  (default 30 — past any legitimate rejoin/base-backup, so a healthy in-progress
  clone is never interrupted);
- the cluster was not re-cloned within `COOLDOWN_MINUTES` (default 45), tracked
  in a runtime `ConfigMap` (`cnpg-standby-reconciler-state`, created by the job,
  **not** Argo-managed, so cooldown timestamps survive sync).

## Rollout — observe first

Ships in `MODE=observe` (log-only). Auto-deleting PVCs cluster-wide is powerful;
validate detection before enabling deletion:

1. Leave `MODE: observe`. Watch the logs across the next node-loss/game-day:
   `kubectl -n cnpg-standby-reconciler logs -l app.kubernetes.io/name=cnpg-standby-reconciler --tail=100`
   Confirm `OBSERVE … WOULD re-clone <the actually-stuck pod>` fires only for
   genuinely stuck standbys and never for healthy/mid-clone ones.
2. Flip `MODE: enforce` in `cnpg-standby-reconciler-config` (commit to git;
   Argo syncs). It will then re-clone stuck standbys automatically.

Config lives in the `cnpg-standby-reconciler-config` ConfigMap: `MODE`,
`GRACE_MINUTES`, `COOLDOWN_MINUTES`, `MAX_ACTIONS_PER_RUN`.

## Sunset

This exists because CNPG (1.30 at time of writing) does not auto-heal the stuck
standby. Tracked upstream:
[#10419](https://github.com/cloudnative-pg/cloudnative-pg/issues/10419),
[#9974](https://github.com/cloudnative-pg/cloudnative-pg/issues/9974),
[#3365](https://github.com/cloudnative-pg/cloudnative-pg/issues/3365).
A **September 2026** TODO re-checks these; if the operator gains native
self-healing, adopt it and delete this component.

## OpenBao paths to seed

None — this component has no `ExternalSecret`. It authenticates to the
apiserver with its own ServiceAccount token; it holds no database or external
credentials by design.
