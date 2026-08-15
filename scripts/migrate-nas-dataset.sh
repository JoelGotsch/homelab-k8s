#!/usr/bin/env bash
# Move a nas-crypt dataset from the share ROOT into its declared subdirectory.
#
# This is the data half of ADR 0051. The manifest half (static PVs with
# written-out remotePath) is already in git; this script makes the NAS layout
# match it, one dataset at a time.
#
#   ./scripts/migrate-nas-dataset.sh                      # plan everything (read-only)
#   ./scripts/migrate-nas-dataset.sh plan  <dataset>      # plan one dataset
#   ./scripts/migrate-nas-dataset.sh move  <dataset>      # do it
#   ./scripts/migrate-nas-dataset.sh status               # what is true right now
#
# WHAT IT DOES, AND WHY THIS WAY
#
# The move happens INSIDE the cluster, through an existing share-root FUSE
# mount (the `backup-src-<share>` PVC), as a plain `mv`. Two consequences worth
# being deliberate about:
#
#   * No crypt key ever leaves the node. The alternative — running `rclone`
#     directly with the share's config — would hand a Job the key that ADR 0030
#     exists to keep on the node. A `mv` through the mount asks the driver to
#     do the rename, which is what it is for.
#   * Within one crypt remote a rename is a rename, not a byte copy. rclone
#     translates it to a server-side move on the SMB backend. That is the
#     difference between minutes and days for Nextcloud's data tree — and it is
#     exactly the assumption `plan` measures instead of trusting.
#
# SAFETY PROPERTIES
#
#   * `plan` is the default and touches nothing.
#   * `move` refuses unless the app is already quiesced. It will not scale down
#     a user-facing workload for you; that is the operator's call and belongs in
#     the runbook, not in a script's side effects.
#   * `move` refuses unless the share's last offsite backup succeeded recently.
#   * The move is idempotent: a dataset already at its subpath is a clean no-op,
#     not a second move.
#   * Nothing is deleted, ever. Every operation is a rename within one share.
#
# WHAT IT DOES NOT DO
#
# It does not touch Kubernetes objects. Recreating the PVC against the new
# static PV is a git commit in the owning repo followed by an Argo sync, per
# the runbook — not something a script should do behind the reconciler's back.
#
# Runbook: homelab-docs/03-runbooks/nas/nas-crypt-dataset-migration.md
# Decision: homelab-docs/02-decisions/0051-nas-crypt-volumes-are-named-datasets.md

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NS="backup-cronjobs"
# Reuse the image the restic CronJob in this namespace already runs, pinned to
# the same digest. Two reasons, both discovered rather than assumed:
#
#   * `enforce-digest-pinning-allowlist` is a Kyverno ClusterPolicy in ENFORCE
#     mode covering Pods in `backup-cronjobs`. A tag-only image (busybox:1.36.1)
#     is rejected outright — the Job would never start.
#   * Reusing an image already pulled on the nodes and already covered by this
#     namespace's pull secret means the migration introduces no new supply-chain
#     surface and nothing new for Renovate to track. All this Job needs is
#     /bin/sh, mkdir and mv.
#
# Keep this digest in step with infrastructure/backup-cronjobs/nas-personal-cronjob.yaml.
JOB_IMAGE="restic/restic:0.17.3@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a"

# ── The datasets, as data ────────────────────────────────────────────────────
#
# Scope comes from this table, not from flags. A dataset that is not here is
# not in scope; a dataset here whose PV is not declared in
# infrastructure/csi-rclone/persistentvolumes.yaml is a bug the script reports
# rather than works around.
#
#   <dataset> <share> <subpath> <quiesce-targets> <pvc>
#
# quiesce-targets is a COMMA-SEPARATED list of `<namespace>/<kind>/<name>` that
# must not be writing before the move, or `-` when nothing writes to the share.
#
# These were enumerated from the live cluster (every workload whose pod spec
# mounts the PVC), not assumed from names, and two of them are not what you
# would guess:
#
#   * The vault has NO Deployment. It is written by three CronJobs — the
#     nightly seals and contacts-sync. Quiescing it means SUSPENDING those and
#     confirming no Job is mid-run; there are no replicas to scale.
#   * Forgejo is a Deployment, not a StatefulSet, and one workload holds BOTH
#     the LFS and the Packages datasets.
#
# If you add a dataset, derive its writers the same way rather than guessing:
#   kubectl get deploy,sts,cronjob -A -o json | <find pods mounting the PVC>
DATASETS="
internal-archive-vault|internal-archive|conversation-history/vault|conversation-history/cronjob/seal-signal,conversation-history/cronjob/seal-whatsapp,conversation-history/cronjob/contacts-sync|conversation-history/vault
internal-archive-nextcloud|internal-archive|nextcloud/internal-archive|nextcloud/deployment/nextcloud|nextcloud/nextcloud-internal-archive
personal-photos-immich|personal-photos|immich/originals|immich/deployment/immich-server|immich/immich-originals
personal-files-nextcloud|personal-files|nextcloud/data|nextcloud/deployment/nextcloud|nextcloud/nextcloud-personal-files
family-shared-nextcloud|family-shared|nextcloud/family-shared|nextcloud/deployment/nextcloud|nextcloud/nextcloud-family-shared
personal-documents-paperless|personal-documents|paperless/media|paperless/deployment/paperless-paperless-ngx|paperless/paperless-media
forgejo-lfs-forgejo|forgejo-lfs|forgejo/lfs|forgejo/deployment/forgejo|forgejo/forgejo-lfs
registry-blobs-forgejo|registry-blobs|forgejo/packages|forgejo/deployment/forgejo|forgejo/forgejo-packages
"

# Shares whose root is mounted by a backup-src PVC. registry-blobs has none —
# it is deliberately outside the offsite lane (ADR 0051 §Consequences), which
# also means this script has no share-root mount to work through for it.
BACKUP_SRC_SHARES="internal-archive personal-photos personal-files family-shared personal-documents forgejo-lfs"

MAX_BACKUP_AGE_HOURS=48

die() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  $*"; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found in PATH."; }
need kubectl

kubectl version --request-timeout=15s >/dev/null 2>&1 \
  || die "cannot reach the cluster. Set KUBECONFIG and try again."

# Both helpers end with `:` on purpose. Their `while` loops finish on a failed
# test for the table's blank lines, and under `set -e` that non-zero status
# would propagate out of the pipeline and kill the script mid-report.
dataset_row() {
  echo "$DATASETS" | while IFS='|' read -r name share subpath quiesce pvc; do
    [ -n "${name:-}" ] || continue
    [ "$name" = "$1" ] && echo "$name|$share|$subpath|$quiesce|$pvc"
  done
  :
}

all_datasets() {
  echo "$DATASETS" | while IFS='|' read -r name _rest; do
    [ -n "${name:-}" ] || continue
    echo "$name"
  done
  :
}

# Every first path component reserved on a share — these are other datasets'
# directories and must never be swept into this dataset's subpath.
reserved_components() {
  local share="$1"
  {
    echo "_unallocated"
    echo "$DATASETS" | while IFS='|' read -r _n s sub _q _p; do
      [ "${s:-}" = "$share" ] && echo "${sub%%/*}"
    done
  } | sort -u
  :
}

backup_src_pvc() {
  local share="$1"
  case " $BACKUP_SRC_SHARES " in
    *" $share "*) echo "backup-src-$share" ;;
    *) echo "" ;;
  esac
}

# ── Preconditions ────────────────────────────────────────────────────────────

check_declared() {
  local pvc_ns="${1%%/*}" pvc_name="${1##*/}" subpath="$2"
  local pv_file="$REPO_ROOT/infrastructure/csi-rclone/persistentvolumes.yaml"
  [ -f "$pv_file" ] || die "$pv_file missing — the desired state is not in git."
  grep -q "remotePath: \"$subpath\"" "$pv_file" \
    || die "no PV in persistentvolumes.yaml declares remotePath \"$subpath\".
      Commit the desired state before moving data to match it."
}

# A writer is quiesced when it cannot start a new write AND is not mid-write.
# The two kinds need different questions asked:
#   Deployment/StatefulSet — 0 replicas.
#   CronJob               — suspended AND no Job currently active. Suspending
#                           alone is not enough: a seal that started at 03:00
#                           is still holding the mount at 03:05.
check_quiesced_one() {
  local target="$1"
  local ns kind name
  ns="$(echo "$target" | cut -d/ -f1)"
  kind="$(echo "$target" | cut -d/ -f2)"
  name="$(echo "$target" | cut -d/ -f3)"

  case "$kind" in
    cronjob)
      local suspended active
      suspended="$(kubectl -n "$ns" get cronjob "$name" \
        -o jsonpath='{.spec.suspend}' --request-timeout=20s 2>/dev/null || echo "")"
      active="$(kubectl -n "$ns" get cronjob "$name" \
        -o jsonpath='{.status.active[*].name}' --request-timeout=20s 2>/dev/null || echo "")"
      if [ "$suspended" != "true" ]; then
        note "quiesce: $target is NOT suspended"
        return 1
      fi
      if [ -n "$active" ]; then
        note "quiesce: $target is suspended but still has an ACTIVE job: $active"
        return 1
      fi
      note "quiesce: $target suspended, no active job — OK"
      return 0
      ;;
    *)
      local replicas
      replicas="$(kubectl -n "$ns" get "$kind" "$name" \
        -o jsonpath='{.status.replicas}' --request-timeout=20s 2>/dev/null || echo "?")"
      [ -z "$replicas" ] && replicas=0
      if [ "$replicas" = "0" ]; then
        note "quiesce: $target is at 0 replicas — OK"
        return 0
      fi
      note "quiesce: $target still has $replicas replica(s)"
      return 1
      ;;
  esac
}

check_quiesced() {
  local targets="$1"
  [ "$targets" = "-" ] && { note "quiesce: nothing writes to this share"; return 0; }
  local ok=0 t
  # Check every writer, and report all of them, before deciding. Bailing on the
  # first failure would hide the second one and cost another round trip.
  for t in $(echo "$targets" | tr ',' ' '); do
    check_quiesced_one "$t" || ok=1
  done
  return "$ok"
}

check_backup_fresh() {
  local share="$1"
  local last
  last="$(kubectl -n "$NS" get jobs \
    -o jsonpath='{range .items[?(@.status.succeeded==1)]}{.metadata.name}{" "}{.status.completionTime}{"\n"}{end}' \
    --request-timeout=20s 2>/dev/null | grep 'restic-nas-personal' | sort -k2 | tail -1 || true)"
  if [ -z "$last" ]; then
    note "offsite: NO successful restic-nas-personal run found"
    return 1
  fi
  local when age_h
  when="$(echo "$last" | awk '{print $2}')"
  age_h="$(python3 -c "
import datetime,sys
t=datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00'))
now=datetime.datetime.now(datetime.timezone.utc)
print(int((now-t).total_seconds()//3600))
" "$when" 2>/dev/null || echo 9999)"
  note "offsite: last successful run ${age_h}h ago ($when)"
  [ "$age_h" -le "$MAX_BACKUP_AGE_HOURS" ]
}

# ── Inspect / move ───────────────────────────────────────────────────────────
#
# One Job does both. In `plan` mode it only lists and counts; in `move` mode it
# renames. Same code path, so what plan reports is what move acts on.

run_share_job() {
  local share="$1" subpath="$2" mode="$3" target="${4:-}"
  local src_pvc job_name
  src_pvc="$(backup_src_pvc "$share")"
  [ -n "$src_pvc" ] || die "share '$share' has no share-root PVC in $NS.
      Without one there is no mount to perform the rename through. See
      the runbook's section on registry-blobs."

  local reserved
  reserved="$(reserved_components "$share" | tr '\n' ' ')"
  job_name="nas-migrate-$(echo "$share-$mode" | tr -c 'a-z0-9-' '-' | cut -c1-40)$$"

  kubectl -n "$NS" delete job "$job_name" --ignore-not-found >/dev/null 2>&1 || true

  cat <<EOF | kubectl -n "$NS" apply -f - >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  labels:
    app.kubernetes.io/component: nas-dataset-migration
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 1000
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: migrate
          image: $JOB_IMAGE
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          # ADR 0042: requests always, memory limit always, CPU limit opt-out.
          # A rename loop is IO-bound and holds nothing in memory — the work
          # happens on the NAS, not here.
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { memory: 128Mi }
          env:
            - { name: MODE,     value: "$mode" }
            - { name: SUBPATH,  value: "$subpath" }
            - { name: RESERVED, value: "$reserved" }
            - { name: TARGET,   value: "$target" }
          command: ["/bin/sh","-c"]
          args:
            - |
              set -eu
              ROOT=/nas/share
              echo "== share root: \$ROOT"
              echo "== target subpath: \$SUBPATH"
              echo "== reserved components: \$RESERVED"

              is_reserved() {
                for r in \$RESERVED; do [ "\$1" = "\$r" ] && return 0; done
                return 1
              }

              # busybox has these, but fail loudly rather than silently
              # reporting files=0 if a future image does not.
              command -v find >/dev/null && command -v du >/dev/null && command -v wc >/dev/null \
                || { echo "!! find/du/wc missing in \$(cat /etc/os-release 2>/dev/null | head -1)"; echo "RESULT=missing-tools"; exit 1; }

              # ── ledger: count what is there, before and after a move. Two
              #    identical ledgers are the evidence that a rename moved
              #    everything and invented nothing. TARGET empty = share root.
              if [ "\$MODE" = "ledger" ]; then
                T="\$ROOT/\${TARGET:-.}"
                [ -d "\$T" ] || { echo "!! no such path: \$T"; echo "RESULT=no-such-path"; exit 1; }
                # wc -l pads its output; these numbers get compared by eye
                # against the run before the move, so strip the padding.
                echo "LEDGER path=\$T files=\$(find "\$T" -type f | wc -l | tr -d ' ') dirs=\$(find "\$T" -type d | wc -l | tr -d ' ') kib=\$(du -sk "\$T" | cut -f1 | tr -d ' ')"
                echo "RESULT=ledger"
                exit 0
              fi

              # ── Three passes over the SAME glob. Entry names never pass
              #    through a whitespace-split variable: the previous version
              #    accumulated them into MOVE_LIST and re-split on IFS, so any
              #    name containing a space became two bogus names and the mv
              #    failed mid-run. It also tested each conflict inside the
              #    rename loop, so a collision on the fifth entry left the
              #    first four already moved — a half-migrated share, which is
              #    the one outcome this script exists to prevent.
              #
              #    pass 1 plan · pass 2 ALL conflicts · pass 3 rename.

              COUNT=0
              for entry in "\$ROOT"/* "\$ROOT"/.[!.]*; do
                [ -e "\$entry" ] || continue
                base="\$(basename "\$entry")"
                if is_reserved "\$base"; then
                  echo "   keep     \$base   (reserved — another dataset)"
                  continue
                fi
                echo "   move     \$base"
                COUNT=\$((COUNT+1))
              done

              if [ "\$COUNT" = "0" ]; then
                echo "== nothing at the share root to move — already migrated."
                echo "RESULT=already-migrated"
                exit 0
              fi

              if [ "\$MODE" = "plan" ]; then
                echo "== PLAN ONLY. \$COUNT top-level entries would move into \$SUBPATH."
                echo "RESULT=plan"
                exit 0
              fi

              CONFLICT=0
              for entry in "\$ROOT"/* "\$ROOT"/.[!.]*; do
                [ -e "\$entry" ] || continue
                base="\$(basename "\$entry")"
                is_reserved "\$base" && continue
                if [ -e "\$ROOT/\$SUBPATH/\$base" ]; then
                  echo "!! \$SUBPATH/\$base already exists — refusing to overwrite."
                  CONFLICT=1
                fi
              done
              if [ "\$CONFLICT" = "1" ]; then
                echo "== refusing to move: every conflict above is listed, and NOTHING has been renamed."
                echo "RESULT=conflict"
                exit 1
              fi

              mkdir -p "\$ROOT/\$SUBPATH"
              # Pass 3 re-globs AFTER the mkdir, so the directory just created
              # is itself a glob hit. It is skipped only because
              # reserved_components() emits the first path component of EVERY
              # dataset on this share, including this one — so \$SUBPATH's own
              # head is always reserved. Do not relax that: without it this
              # loop would mv the target into itself.
              for entry in "\$ROOT"/* "\$ROOT"/.[!.]*; do
                [ -e "\$entry" ] || continue
                base="\$(basename "\$entry")"
                is_reserved "\$base" && continue
                mv "\$ROOT/\$base" "\$ROOT/\$SUBPATH/\$base" && echo "   moved    \$base"
              done
              echo "== moved \$COUNT entries into \$SUBPATH"
              echo "RESULT=moved"
          volumeMounts:
            - { name: share, mountPath: /nas/share }
      volumes:
        - name: share
          persistentVolumeClaim:
            claimName: $src_pvc
EOF

  # Poll rather than `kubectl wait`: we need to distinguish complete from
  # failed, and a backgrounded pair of waits races on which one returns first.
  local waited=0 succeeded="" failed=""
  while [ "$waited" -lt 1800 ]; do
    succeeded="$(kubectl -n "$NS" get job "$job_name" -o jsonpath='{.status.succeeded}' 2>/dev/null || echo "")"
    failed="$(kubectl -n "$NS" get job "$job_name" -o jsonpath='{.status.failed}' 2>/dev/null || echo "")"
    [ "${succeeded:-0}" != "0" ] && [ -n "${succeeded:-}" ] && break
    [ "${failed:-0}" != "0" ] && [ -n "${failed:-}" ] && break
    sleep 5
    waited=$((waited + 5))
  done

  kubectl -n "$NS" logs "job/$job_name" --tail=300 2>/dev/null | sed 's/^/  /' || true

  if [ -n "${failed:-}" ] && [ "${failed:-0}" != "0" ]; then
    kubectl -n "$NS" delete job "$job_name" --ignore-not-found >/dev/null 2>&1 || true
    die "migration job failed for share '$share'.
      Nothing was deleted — every operation in that job is a rename. Read the
      log above, fix the cause, re-run. The move is idempotent."
  fi
  if [ -z "${succeeded:-}" ] || [ "${succeeded:-0}" = "0" ]; then
    die "migration job for '$share' did not finish within 1800s.
      It is still running as job/$job_name in namespace $NS — inspect it there
      rather than starting a second one."
  fi

  kubectl -n "$NS" delete job "$job_name" --ignore-not-found >/dev/null 2>&1 || true
}

# ── Commands ─────────────────────────────────────────────────────────────────

cmd_plan() {
  local ds="$1"
  local row; row="$(dataset_row "$ds")"
  [ -n "$row" ] || die "unknown dataset '$ds'. Known: $(all_datasets | tr '\n' ' ')"
  IFS='|' read -r name share subpath quiesce pvc <<EOF
$row
EOF
  echo "── $name"
  note "share:    $share"
  note "subpath:  $subpath"
  note "pvc:      $pvc"
  check_declared "$pvc" "$subpath"
  note "declared: PV with remotePath \"$subpath\" is in git — OK"
  check_quiesced "$quiesce" || note "quiesce: NOT clear (see above) — move would be refused"
  check_backup_fresh "$share" || note "offsite: STALE or missing — move would be refused"
  run_share_job "$share" "$subpath" plan
  echo
}

cmd_move() {
  local ds="$1"
  local row; row="$(dataset_row "$ds")"
  [ -n "$row" ] || die "unknown dataset '$ds'. Known: $(all_datasets | tr '\n' ' ')"
  IFS='|' read -r name share subpath quiesce pvc <<EOF
$row
EOF
  echo "── moving $name"
  check_declared "$pvc" "$subpath"

  check_quiesced "$quiesce" || die "one or more writers are still active (listed above).
      Moving a dataset out from under a live writer is how you get a
      half-migrated share. Scale it to 0, confirm, then re-run.
      The runbook has the exact sequence."

  check_backup_fresh "$share" || die "no successful offsite backup within ${MAX_BACKUP_AGE_HOURS}h for '$share'.
      A data move without a recent verified backup is a bet. Run the
      restic lane, confirm it succeeded, then re-run."

  run_share_job "$share" "$subpath" move
  echo
  echo "Data is now at $share:$subpath."
  echo "NEXT: commit the PVC's volumeName in the owning repo and let Argo"
  echo "      rebind it. Until then the app is still pointed at the share root"
  echo "      and will come back up seeing an EMPTY directory. See the runbook."
  echo
}

# ── ledger: the before/after evidence a dataset window turns on.
#
# Run it on the share ROOT before the move and on the dataset's SUBPATH after.
# Identical files/dirs/kib is what "the rename moved everything and invented
# nothing" looks like; anything else stops the window. It is deliberately not
# folded into `move`: the operator must hold both numbers, and a script that
# prints its own pass mark is not evidence.
cmd_ledger() {
  local ds="$1" where="${2:-root}"
  local row; row="$(dataset_row "$ds")"
  [ -n "$row" ] || die "unknown dataset '$ds'. Known: $(all_datasets | tr '\n' ' ')"
  IFS='|' read -r name share subpath quiesce pvc <<EOF
$row
EOF
  local target=""
  case "$where" in
    root)   target="" ;;
    target) target="$subpath" ;;
    *) die "ledger takes 'root' (the share root, before the move) or 'target'
      (the dataset's subpath, after it). Got '$where'." ;;
  esac
  echo "── ledger $name ($where)"
  note "share:    $share"
  note "path:     ${target:-<share root>}"
  run_share_job "$share" "$subpath" ledger "$target"
  echo
}

cmd_status() {
  echo "nas-crypt datasets (ADR 0051)"
  echo
  printf "  %-30s %-20s %-28s %s\n" DATASET SHARE SUBPATH "PVC BOUND TO"
  all_datasets | while read -r ds; do
    row="$(dataset_row "$ds")"
    IFS='|' read -r name share subpath quiesce pvc <<EOF
$row
EOF
    pvc_ns="${pvc%%/*}"; pvc_name="${pvc##*/}"
    bound="$(kubectl -n "$pvc_ns" get pvc "$pvc_name" \
      -o jsonpath='{.spec.volumeName}' --request-timeout=20s 2>/dev/null || echo "-")"
    [ -n "$bound" ] || bound="-"
    case "$bound" in
      pvc-*) bound="$bound (dynamic — NOT migrated)" ;;
      nas-*) bound="$bound (static — migrated)" ;;
    esac
    printf "  %-30s %-20s %-28s %s\n" "$name" "$share" "$subpath" "$bound"
  done
  :
  echo
  echo "A dataset is migrated when BOTH are true: its data sits at the subpath"
  echo "on the NAS, and its PVC is bound to the static PV. 'status' shows the"
  echo "second; 'plan <dataset>' shows the first."
}

case "${1:-plan}" in
  plan)
    if [ -n "${2:-}" ]; then cmd_plan "$2"
    else all_datasets | while read -r ds; do cmd_plan "$ds" || true; done
    fi
    ;;
  move)
    [ -n "${2:-}" ] || die "move requires a dataset name. Known: $(all_datasets | tr '\n' ' ')"
    cmd_move "$2"
    ;;
  ledger)
    [ -n "${2:-}" ] || die "ledger requires a dataset name. Known: $(all_datasets | tr '\n' ' ')"
    cmd_ledger "$2" "${3:-root}"
    ;;
  status) cmd_status ;;
  *) die "unknown command '${1}'. Use: plan [dataset] | move <dataset> | ledger <dataset> [root|target] | status" ;;
esac
