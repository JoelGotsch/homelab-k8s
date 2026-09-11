#!/usr/bin/env bash
# sync-longhorn-no-snapshot.sh — converge every volume that opted out of
# Longhorn snapshots onto the `no-snapshot` recurring-job group, and nothing
# else.
#
# THE POLICY (decided 2026-09-11; homelab-docs 01-architecture/backup-and-dr.md
# §"Tier 1", infrastructure/longhorn/recurring-jobs.yaml §no-snapshot)
#
# A local snapshot is worth its disk only where it can help a restore. CNPG
# Postgres (Barman base + WAL archive, streaming standby), telemetry, caches
# and scratch get none. Their PVC carries
#   recurring-job-group.longhorn.io/no-snapshot: "enabled"
# and the no-snapshot group's jobs delete snapshots and trim — none take one.
#
# WHY A SCRIPT, WHEN THE LABEL IS IN GIT
#
# A NEW volume needs nothing from here: Kyverno copies the PVC label onto the
# Volume at creation, and Longhorn adds `default` only to a volume that has no
# recurring-job label at all (datastore.labelRecurringJobDefault, v1.12.1).
#
# An EXISTING volume keeps its old snapshot group, because every path that
# writes these labels only adds:
#   - CNPG does not propagate the removal of an inheritedMetadata label;
#   - the Kyverno longhorn-volume-label-propagation policy merges PVC labels
#     onto the Volume and never deletes one;
#   - scripts/sync-longhorn-recurring-job-labels.sh is add-only on purpose.
# Left alone, the volume would sit in `no-snapshot` AND `secret-personal` and
# keep being snapshotted hourly. This script removes the old group — from the
# PVC first, then the Volume, because Kyverno would copy a PVC label straight
# back onto the Volume — and sets spec.unmapMarkSnapChainRemoved: enabled so
# the no-snapshot trim frees the blocks of the snapshots the daily delete job
# removes. It cannot take away `backup` membership: it refuses such a volume.
#
# SCOPE IS DATA, NOT FLAGS
#
# In scope: every PVC that carries the no-snapshot label, plus NO_SNAPSHOT_PVCS
# below — the declared opt-outs whose PVC label cannot live in a manifest
# (a StatefulSet's volumeClaimTemplates are immutable; some PVCs belong to a
# chart or another repository). For those this list IS the git record, the
# same pattern as scripts/label-backup-volumes.sh. Names given on the command
# line only narrow the scope, for a small first apply.
#
# REFUSES, rather than half-converging, when:
#   - the volume or PVC is in the `backup` group: backup-daily keeps its last
#     backup's snapshot for the next incremental, and the daily delete job
#     would remove it;
#   - a label to remove is still declared upstream, where it would come back:
#     in the owning CNPG Cluster's spec.inheritedMetadata.labels, or on a PVC
#     Argo CD tracks (argocd.argoproj.io/tracking-id). Fix git first.
#
# Idempotent: a converged cluster prints only "ok" rows and changes nothing.

set -euo pipefail

err() { printf 'ERROR: %s\n' "$*" >&2; }

# namespace/pvc | why this volume gets no snapshot
NO_SNAPSHOT_PVCS=(
  "monitoring/prometheus-kube-prometheus-stack-prometheus-db-prometheus-kube-prometheus-stack-prometheus-0|telemetry: Prometheus TSDB; history is not restored from a snapshot (StatefulSet template, prometheus-operator)"
  "monitoring/storage-loki-0|telemetry: Loki WAL/index; chunks are in NAS object storage (StatefulSet template, loki chart)"
  "observability-tempo/storage-tempo-0|telemetry: traces (StatefulSet template, tempo chart)"
  "monitoring/falco-falcosidekick-ui-redis-data-falco-falcosidekick-ui-redis-0|telemetry: Falcosidekick UI event cache (StatefulSet template, falco chart)"
  "langfuse/log-volume-chi-langfuse-langfuse-0-0-0|telemetry: ClickHouse server logs (ClickHouseInstallation template)"
  "backup-cronjobs/restic-staging|scratch: restic staging, rebuilt by every nightly run; the copy is the restic repository"
  "immich/immich-machine-learning|cache: downloaded ML models, re-fetched on start (immich-k8s)"
  "nextcloud/redis-data-nextcloud-redis-master-0|cache: sessions + file locks; loss = users log in again (StatefulSet template, redis subchart)"
  "nextcloud-biz/redis-data-nextcloud-biz-redis-master-0|cache: sessions + file locks; loss = users log in again (StatefulSet template, redis subchart)"
  "paperless/redis-data-paperless-redis-master-0|queue: Celery broker, declared no-durability in paperless-k8s values.yaml (StatefulSet template, redis subchart)"
)

APPLY=false
case "${1:-}" in
  --apply) APPLY=true; shift ;;
  --dry-run) shift ;;
  -h|--help)
    cat >&2 <<EOF
usage: $0 [--dry-run | --apply] [namespace/pvc ...]

  --dry-run   (default) print the plan, touch nothing
  --apply     converge PVC labels, Volume labels and unmapMarkSnapChainRemoved

With namespace/pvc arguments, act only on those in-scope PVCs.
EOF
    exit 2 ;;
esac

for tool in kubectl python3; do
  command -v "$tool" >/dev/null 2>&1 || { err "required tool missing: $tool"; exit 1; }
done
kubectl version --request-timeout=15s >/dev/null 2>&1 \
  || { err "cannot reach the cluster. Set KUBECONFIG and try again."; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/lh-nosnap.XXXXXX")"
trap 'rm -rf "$work"' EXIT

kubectl -n longhorn-system get volumes.longhorn.io -o json       > "$work/volumes.json"
kubectl -n longhorn-system get snapshots.longhorn.io -o json     > "$work/snapshots.json"
kubectl -n longhorn-system get recurringjobs.longhorn.io -o json > "$work/jobs.json"
kubectl get pvc -A -o json                                       > "$work/pvcs.json"
kubectl get clusters.postgresql.cnpg.io -A -o json               > "$work/cnpg.json"
printf '%s\n' "${NO_SNAPSHOT_PVCS[@]}" > "$work/declared.txt"

APPLY="$APPLY" python3 - "$work" "$@" <<'PY'
import json, os, subprocess, sys

work, only = sys.argv[1], set(sys.argv[2:])
apply = os.environ["APPLY"] == "true"
load = lambda n: json.load(open(f"{work}/{n}.json"))["items"]

GROUP = "recurring-job-group.longhorn.io/"
JOB = "recurring-job.longhorn.io/"
NOSNAP = GROUP + "no-snapshot"
BACKUP = GROUP + "backup"
SOURCE = JOB + "source"          # PVC control label, never a job assignment
SNAPSHOT_TASKS = {"snapshot", "snapshot-force-create"}
BACKUP_TASKS = {"backup", "backup-force-create"}

vols = {v["metadata"]["name"]: v for v in load("volumes")}
pvcs = {(p["metadata"]["namespace"], p["metadata"]["name"]): p for p in load("pvcs")}
tasks = {j["metadata"]["name"]: j["spec"]["task"] for j in load("jobs")}
clusters = {(c["metadata"]["namespace"], c["metadata"]["name"]): c for c in load("cnpg")}
snaps = {}
for s in load("snapshots"):
    snaps[s["spec"]["volume"]] = snaps.get(s["spec"]["volume"], 0) + 1

declared = {}
for line in open(f"{work}/declared.txt").read().splitlines():
    ref, _, why = line.partition("|")
    ns, _, name = ref.partition("/")
    declared[(ns, name)] = why

scope = set(declared) | {k for k, p in pvcs.items()
                         if (p["metadata"].get("labels") or {}).get(NOSNAP) == "enabled"}
if only:
    unknown = only - {f"{ns}/{n}" for ns, n in scope}
    if unknown:
        print(f"ERROR: not in scope (no no-snapshot label, not declared): {' '.join(sorted(unknown))}",
              file=sys.stderr)
        sys.exit(1)
    scope = {k for k in scope if f"{k[0]}/{k[1]}" in only}

def is_backup(labels):
    return labels.get(BACKUP) == "enabled" or any(
        k.startswith(JOB) and k != SOURCE and tasks.get(k[len(JOB):]) in BACKUP_TASKS
        for k in labels)

def to_remove(labels):
    """Snapshot-taking recurring labels: every group but no-snapshot/backup,
    and job labels naming a snapshot task."""
    out = []
    for k in labels:
        if k.startswith(GROUP) and k not in (NOSNAP, BACKUP):
            out.append(k)
        elif k.startswith(JOB) and k != SOURCE and tasks.get(k[len(JOB):]) in SNAPSHOT_TASKS:
            out.append(k)
    return sorted(out)

def kubectl(*args):
    r = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args[:4])} ...: {r.stderr.strip()}")

short = lambda keys: ",".join(k.split("/", 1)[1] for k in keys) or "-"
rows, counts = [], {"ok": 0, "change": 0, "refused": 0, "skipped": 0, "failed": 0}
detached_with_snaps = []

print(f"{'PVC':<58} {'STATE':<9} {'SNAPS':>5} {'ACTUAL':>8}  ACTION")
for ns, name in sorted(scope):
    ref = f"{ns}/{name}"
    pvc = pvcs.get((ns, name))
    vol = vols.get((pvc or {}).get("spec", {}).get("volumeName") or "")
    if not pvc or not vol:
        counts["skipped"] += 1
        print(f"{ref[:58]:<58} {'-':<9} {'-':>5} {'-':>8}  SKIP not found / unbound / not Longhorn")
        continue
    vname = vol["metadata"]["name"]
    plab = pvc["metadata"].get("labels") or {}
    vlab = vol["metadata"].get("labels") or {}
    state = vol.get("status", {}).get("state", "?")
    nsnap = snaps.get(vname, 0)
    actual = f"{int(vol.get('status', {}).get('actualSize') or 0) / 2**30:.1f}Gi"
    head = f"{ref[:58]:<58} {state:<9} {nsnap:>5} {actual:>8}"

    problems = []
    if is_backup(plab) or is_backup(vlab):
        problems.append("in the backup group — backup-daily needs its last snapshot")
    p_rm, v_rm = to_remove(plab), to_remove(vlab)
    owner = next((o["name"] for o in pvc["metadata"].get("ownerReferences") or []
                  if o.get("kind") == "Cluster"), None)
    if owner:
        inherited = (clusters.get((ns, owner), {}).get("spec", {})
                     .get("inheritedMetadata", {}) or {}).get("labels") or {}
        back = sorted(set(p_rm) & set(inherited))
        if back:
            problems.append(f"CNPG Cluster {owner} still declares {short(back)} in inheritedMetadata")
        if inherited.get(NOSNAP) != "enabled" and (ns, name) not in declared:
            problems.append(f"CNPG Cluster {owner} does not declare no-snapshot")
    if p_rm and "argocd.argoproj.io/tracking-id" in (pvc["metadata"].get("annotations") or {}):
        problems.append(f"Argo-tracked PVC still carries {short(p_rm)} — remove it in git")
    if problems:
        counts["refused"] += 1
        print(f"{head}  REFUSED: {'; '.join(problems)}")
        continue

    unmap = vol.get("spec", {}).get("unmapMarkSnapChainRemoved")
    steps = []
    if plab.get(NOSNAP) != "enabled":
        steps.append(("pvc +no-snapshot", ["-n", ns, "label", "pvc", name, f"{NOSNAP}=enabled", "--overwrite"]))
    if p_rm:
        steps.append((f"pvc -{short(p_rm)}", ["-n", ns, "label", "pvc", name, *[k + "-" for k in p_rm]]))
    if vlab.get(NOSNAP) != "enabled":
        steps.append(("vol +no-snapshot", ["-n", "longhorn-system", "label", "volumes.longhorn.io", vname,
                                           f"{NOSNAP}=enabled", "--overwrite"]))
    if v_rm:
        steps.append((f"vol -{short(v_rm)}", ["-n", "longhorn-system", "label", "volumes.longhorn.io", vname,
                                              *[k + "-" for k in v_rm]]))
    if unmap != "enabled":
        steps.append((f"unmapMarkSnapChainRemoved {unmap}->enabled",
                      ["-n", "longhorn-system", "patch", "volumes.longhorn.io", vname, "--type", "merge",
                       "-p", '{"spec":{"unmapMarkSnapChainRemoved":"enabled"}}']))
    if nsnap and state != "attached":
        detached_with_snaps.append(f"{ref} ({nsnap})")

    if not steps:
        counts["ok"] += 1
        print(f"{head}  ok")
        continue
    counts["change"] += 1
    print(f"{head}  {' | '.join(s for s, _ in steps)}")
    if apply:
        # Order matters: no-snapshot goes on before anything comes off, so the
        # volume is never label-less (Longhorn would add `default`), and the PVC
        # loses a label before the Volume does (Kyverno copies PVC -> Volume).
        for desc, args in steps:
            try:
                kubectl(*args)
            except RuntimeError as e:
                counts["failed"] += 1
                print(f"    FAILED at '{desc}': {e}")
                print("    State: the steps before this one are applied; re-run to converge.")
                break

print()
print("── state")
print(f"   converged        : {counts['ok']}")
print(f"   {'changed' if apply else 'would change'}     : {counts['change']}")
print(f"   refused          : {counts['refused']}  (precondition unmet — see REFUSED rows)")
print(f"   skipped          : {counts['skipped']}  (PVC absent or unbound)")
if counts["failed"]:
    print(f"   FAILED           : {counts['failed']}")
if detached_with_snaps:
    print(f"   detached, snapshots kept until next attach: {', '.join(detached_with_snaps)}")
    print("     (recurring jobs skip detached volumes: allow-recurring-job-while-volume-detached=false)")
print("   MODE             : " + ("APPLIED — re-run without --apply to confirm 'would change: 0'"
                                  if apply else "dry-run — nothing changed; re-run with --apply"))
print("   Snapshots go at the next 04:35 UTC snapshot-delete-no-snapshot run, their blocks at the")
print("   Saturday 05:35 UTC filesystem-trim-no-snapshot run. To run either now for the whole group:")
print("     kubectl -n longhorn-system create job --from=cronjob/snapshot-delete-no-snapshot <job-name>")
sys.exit(1 if counts["refused"] or counts["failed"] else 0)
PY
