#!/usr/bin/env bash
# verify-cnpg-restore.sh — prove a CNPG cluster's backups RESTORE, not just
# that they are written. The sibling of verify-cnpg-backup-lane.sh: that
# script proves a WAL segment lands in S3; this one proves base + WAL come
# back as the same data.
#
# Usage: verify-cnpg-restore.sh <namespace> <cluster> [--keep]
#   e.g. verify-cnpg-restore.sh woodpecker woodpecker-pg
#
# Ensures, in order (each step fails loudly with the state it left behind):
#   1. Preflight: kubectl context, source Cluster Ready + ContinuousArchiving,
#      plugin archiver (in-core barmanObjectStore is not supported — the
#      fleet is on the barman-cloud plugin, ADR 0050), the ObjectStore
#      exists and reports a last successful backup, a completed Backup CR
#      exists, and the disposable storage class really has reclaimPolicy
#      Delete (a Retain class would leave an orphaned Longhorn volume per run).
#   2. Snapshot A + named restore point, in ONE repeatable-read transaction on
#      the source primary: per-table row count and max(id) of the app DB,
#      then pg_create_restore_point(). Then pg_switch_wal() and wait until the
#      segment holding the restore point is archived.
#   3. Snapshot B on the source, right after the transaction commits.
#   4. Temporary network policy: every CiliumNetworkPolicy / NetworkPolicy
#      that selects the source's `cnpg.io/cluster` pods is cloned with that
#      label value swapped for the restore cluster's, so the restore pods run
#      under the SAME rule set as production (in a namespace with an egress
#      default-deny they would otherwise die on `dial tcp 10.96.0.1:443`,
#      restore-drill-history 2026-08-15; in a default-allow namespace they
#      would otherwise run unpoliced). Nothing is loosened; the clones carry
#      the managed-by label and are deleted on teardown.
#   5. A disposable 1-instance Cluster `<cluster>-restore-test` bootstrapped
#      by `bootstrap.recovery` through the barman-cloud plugin, to
#      `recoveryTarget.targetName` = the restore point, starting from the
#      newest completed base backup (`backupID`). It has NO WAL
#      archiver: pointing a second cluster's archiver at the source's
#      serverName would fork production's WAL history.
#   6. Compare: every table of snapshot A must exist restored. A table that
#      did not change between A and B must match A exactly (count and max id).
#      A table that changed in that window (rows committed while A was being
#      counted, before the restore point record) may land anywhere between A
#      and B — reported as `volatile`, never silently. Anything else FAILS.
#   7. Teardown (skipped with --keep): Cluster, its PVCs/PVs, the policy
#      clones; then prove nothing labelled for the restore cluster remains.
#
# Idempotent: a restore cluster left by an earlier --keep or interrupted run
# (it carries the managed-by label) is torn down first; a same-named cluster
# WITHOUT the label is not ours and the script refuses to touch it.
#
# Writes to production: one restore point + one WAL switch on the source
# primary (routine; no application data touched). Everything else is created
# under the restore cluster's name and removed again.
#
# Env overrides: EXPECTED_CONTEXT (admin@homelab), RESTORE_STORAGE_CLASS
# (longhorn-replica1), READY_TIMEOUT seconds (1800), WAL_TIMEOUT seconds (180).
# With --keep, CNPGClusterHasNoBackup fires after 6 h — tear down before then.

set -euo pipefail

usage() { echo "usage: $0 <namespace> <cluster> [--keep]" >&2; exit 2; }
[ $# -ge 2 ] || usage
NS="$1"
SRC="$2"
KEEP=false
[ "${3:-}" = "--keep" ] && KEEP=true
[ $# -le 3 ] || usage

RESTORE="${SRC}-restore-test"
EXPECTED_CONTEXT="${EXPECTED_CONTEXT:-admin@homelab}"
SC="${RESTORE_STORAGE_CLASS:-longhorn-replica1}"
READY_TIMEOUT="${READY_TIMEOUT:-1800}"
WAL_TIMEOUT="${WAL_TIMEOUT:-180}"
PLUGIN="barman-cloud.cloudnative-pg.io"
MANAGED_KEY="app.kubernetes.io/managed-by"
MANAGED_VAL="verify-cnpg-restore"
RP_NAME="verify-restore-$(date -u +%Y%m%dT%H%M%SZ)"
WORK="$(mktemp -d)"

k() { kubectl "$@"; }
say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
now() { date +%s; }

T0="$(now)"
T_APPLY=""
T_READY=""
RESULT="FAIL (did not reach comparison)"
CREATED=false

# ---------------------------------------------------------------- teardown
restore_leftovers() {
  # Everything this script could have left behind, by name and label.
  {
    k get clusters.postgresql.cnpg.io -n "$NS" "$RESTORE" -o name 2>/dev/null || true
    k get pods,jobs,pvc,services,secrets -n "$NS" -l "cnpg.io/cluster=$RESTORE" -o name 2>/dev/null || true
    k get ciliumnetworkpolicies.cilium.io,networkpolicies.networking.k8s.io -n "$NS" \
      -l "$MANAGED_KEY=$MANAGED_VAL" -o name 2>/dev/null || true
    k get pv -o json 2>/dev/null | jq -r --arg ns "$NS" --arg p "$RESTORE-" \
      '.items[] | select(.spec.claimRef.namespace==$ns and (.spec.claimRef.name|startswith($p))) | "pv/\(.metadata.name)"'
  } | sed '/^$/d'
}

teardown() {
  say "teardown: $NS/$RESTORE"
  k delete clusters.postgresql.cnpg.io -n "$NS" "$RESTORE" --ignore-not-found --wait=true --timeout=5m
  # PVCs are owner-referenced by the Cluster; delete explicitly anyway so an
  # orphan from an interrupted bootstrap cannot survive.
  k delete pvc -n "$NS" -l "cnpg.io/cluster=$RESTORE" --ignore-not-found --wait=true --timeout=5m
  k delete ciliumnetworkpolicies.cilium.io,networkpolicies.networking.k8s.io -n "$NS" \
    -l "$MANAGED_KEY=$MANAGED_VAL" --ignore-not-found
  local deadline=$(( $(now) + 300 )) left
  while :; do
    left="$(restore_leftovers)"
    [ -z "$left" ] && { echo "teardown complete: nothing named or labelled $RESTORE remains"; return 0; }
    [ "$(now)" -ge "$deadline" ] && { printf 'teardown INCOMPLETE, still present:\n%s\n' "$left" >&2; return 1; }
    sleep 5
  done
}

on_exit() {
  local rc=$?
  set +e
  if [ "$CREATED" = true ] && [ "$KEEP" = false ]; then
    teardown || rc=1
  fi
  say "summary"
  echo "source:            $NS/$SRC"
  echo "restore point:     $RP_NAME"
  echo "restore cluster:   $NS/$RESTORE ($([ "$KEEP" = true ] && [ "$CREATED" = true ] && echo KEPT || echo removed/not created))"
  [ -n "$T_APPLY" ] && echo "apply -> Ready:    $(( ${T_READY:-$(now)} - T_APPLY ))s$([ -z "$T_READY" ] && echo ' (never Ready)')"
  echo "total wall-clock:  $(( $(now) - T0 ))s"
  echo "result:            $RESULT"
  if [ "$KEEP" = true ] && [ "$CREATED" = true ]; then
    echo "remove with:       $0 $NS $SRC   (a re-run tears the kept cluster down first)"
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap on_exit EXIT

cget() { k get clusters.postgresql.cnpg.io -n "$NS" "$1" -o json; }

# --------------------------------------------------------------- preflight
say "1. preflight"
ctx="$(k config current-context)"
[ "$ctx" = "$EXPECTED_CONTEXT" ] || fail "kubectl context is '$ctx', expected '$EXPECTED_CONTEXT'"
echo "context: $ctx"

cget "$SRC" > "$WORK/src.json" 2>/dev/null || fail "no Cluster $NS/$SRC"
jq -r '.status.conditions[]? | "\(.type)=\(.status)"' "$WORK/src.json" | tr '\n' ' '; echo
[ "$(jq -r '.status.conditions[]? | select(.type=="Ready") | .status' "$WORK/src.json")" = True ] \
  || fail "source cluster not Ready"
[ "$(jq -r '.status.conditions[]? | select(.type=="ContinuousArchiving") | .status' "$WORK/src.json")" = True ] \
  || fail "source ContinuousArchiving is not True — nothing trustworthy to restore from"
[ -z "$(jq -r '.spec.backup.barmanObjectStore.destinationPath // empty' "$WORK/src.json")" ] \
  || fail "source uses in-core barmanObjectStore; this script restores through the $PLUGIN plugin only"

OBJSTORE="$(jq -r --arg p "$PLUGIN" '.spec.plugins[]? | select(.name==$p and .isWALArchiver==true) | .parameters.barmanObjectName // empty' "$WORK/src.json")"
SERVER="$(jq -r --arg p "$PLUGIN" --arg c "$SRC" '[.spec.plugins[]? | select(.name==$p and .isWALArchiver==true) | .parameters.serverName // $c][0] // $c' "$WORK/src.json")"
[ -n "$OBJSTORE" ] || fail "source has no $PLUGIN WAL archiver"
k get objectstores.barmancloud.cnpg.io -n "$NS" "$OBJSTORE" -o json > "$WORK/os.json" 2>/dev/null \
  || fail "ObjectStore $NS/$OBJSTORE not found"
last_backup="$(jq -r --arg s "$SERVER" '.status.serverRecoveryWindow[$s].lastSuccessfulBackupTime // empty' "$WORK/os.json")"
first_rp="$(jq -r --arg s "$SERVER" '.status.serverRecoveryWindow[$s].firstRecoverabilityPoint // empty' "$WORK/os.json")"
echo "objectstore: $OBJSTORE  serverName: $SERVER  lastSuccessfulBackup: ${last_backup:-<none>}  firstRecoverabilityPoint: ${first_rp:-<none>}"
[ -n "$last_backup" ] || fail "ObjectStore reports no successful backup for serverName $SERVER"
k get backups.postgresql.cnpg.io -n "$NS" -o json \
  | jq --arg c "$SRC" '[.items[] | select(.spec.cluster.name==$c and .status.phase=="completed" and .status.backupId != null)]
                       | sort_by(.status.stoppedAt)' > "$WORK/backups.json"
completed="$(jq length "$WORK/backups.json")"
# A named restore point cannot select its own base backup (only targetTime/
# targetLSN can; the admission webhook rejects targetName without backupID),
# so name the newest completed base backup explicitly. It predates the restore
# point created below, so the recovery replays base + WAL up to that point.
BACKUP_ID="$(jq -r '.[-1].status.backupId // empty' "$WORK/backups.json")"
echo "completed Backup CRs: $completed   newest backupId: ${BACKUP_ID:-<none>} (stopped $(jq -r '.[-1].status.stoppedAt // "-"' "$WORK/backups.json"))"
[ -n "$BACKUP_ID" ] || fail "no completed Backup CR with a backupId for $SRC"

reclaim="$(k get storageclass "$SC" -o jsonpath='{.reclaimPolicy}' 2>/dev/null || true)"
[ -n "$reclaim" ] || fail "storage class $SC does not exist (set RESTORE_STORAGE_CLASS)"
[ "$reclaim" = Delete ] || fail "storage class $SC has reclaimPolicy $reclaim; a disposable restore needs Delete"
echo "restore storage class: $SC (reclaimPolicy Delete)"

DB="$(jq -r '.spec.bootstrap.initdb.database // .spec.bootstrap.recovery.database // "app"' "$WORK/src.json")"
OWNER="$(jq -r --arg d "$DB" '.spec.bootstrap.initdb.owner // .spec.bootstrap.recovery.owner // $d' "$WORK/src.json")"
echo "app database: $DB (owner $OWNER)"

if existing="$(cget "$RESTORE" 2>/dev/null)"; then
  [ "$(printf '%s' "$existing" | jq -r --arg k "$MANAGED_KEY" '.metadata.labels[$k] // empty')" = "$MANAGED_VAL" ] \
    || fail "a Cluster $NS/$RESTORE exists WITHOUT $MANAGED_KEY=$MANAGED_VAL — not created by this script; refusing to touch it"
  echo "leftover restore cluster from an earlier run — converging by tearing it down first"
  teardown
elif [ -n "$(restore_leftovers)" ]; then
  echo "leftover restore resources without a Cluster — removing"
  teardown
fi

PRIMARY="$(k get pod -n "$NS" -l "cnpg.io/cluster=$SRC,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}')"
[ -n "$PRIMARY" ] || fail "no primary pod (cnpg.io/instanceRole=primary) for $SRC"
echo "source primary: $PRIMARY"

# ----------------------------------------------------------- data snapshots
# One row per table: T <schema.table> <count> <max(id) or empty>. max(id) only
# for an integer `id` column — the cheapest generic "newest row" marker.
COUNT_SQL="SELECT 'T', format('%I.%I', n.nspname, c.relname),
  (xpath('/row/c/text()', x))[1]::text,
  coalesce((xpath('/row/m/text()', x))[1]::text, '')
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN LATERAL query_to_xml(format('SELECT count(*) AS c%s FROM %I.%I',
  CASE WHEN EXISTS (SELECT 1 FROM pg_attribute a
                    WHERE a.attrelid = c.oid AND a.attname = 'id' AND NOT a.attisdropped
                      AND a.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype))
       THEN ', max(id) AS m' ELSE '' END,
  n.nspname, c.relname), false, true, '') AS x
WHERE c.relkind IN ('r', 'p')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
ORDER BY 2;"

psql_on() { # <pod> <db> ; SQL on stdin
  k exec -i -n "$NS" "$1" -c postgres -- psql -X -q -v ON_ERROR_STOP=1 -tA -F $'\t' -d "$2"
}

say "2. snapshot A + restore point '$RP_NAME' (one repeatable-read transaction)"
printf 'BEGIN ISOLATION LEVEL REPEATABLE READ;\n%s\nSELECT %s, lsn, pg_walfile_name(lsn) FROM pg_create_restore_point(%s) AS lsn;\nCOMMIT;\n' \
  "$COUNT_SQL" "'RP'" "'$RP_NAME'" | psql_on "$PRIMARY" "$DB" > "$WORK/a.raw"
grep '^T' "$WORK/a.raw" | cut -f2- > "$WORK/a.tsv"
RP_LSN="$(awk -F'\t' '$1=="RP"{print $2}' "$WORK/a.raw")"
RP_WAL="$(awk -F'\t' '$1=="RP"{print $3}' "$WORK/a.raw")"
[ -n "$RP_WAL" ] || fail "restore point was not created"
echo "tables: $(wc -l < "$WORK/a.tsv" | tr -d ' ')   restore point LSN $RP_LSN in segment $RP_WAL"
[ -s "$WORK/a.tsv" ] || fail "app database $DB has no tables — nothing to verify"

echo "SELECT pg_switch_wal();" | psql_on "$PRIMARY" "$DB" >/dev/null
deadline=$(( $(now) + WAL_TIMEOUT ))
while :; do
  last="$(echo "SELECT coalesce(last_archived_wal, '') FROM pg_stat_archiver;" | psql_on "$PRIMARY" "$DB")"
  # Same timeline, fixed-width hex: lexical order is WAL order.
  if [ -n "$last" ] && { [ "$last" = "$RP_WAL" ] || [[ "$last" > "$RP_WAL" ]]; }; then
    echo "archived through $last"
    break
  fi
  [ "$(now)" -ge "$deadline" ] && fail "segment $RP_WAL not archived within ${WAL_TIMEOUT}s (last_archived_wal=${last:-none})"
  sleep 5
done

say "3. snapshot B (after the restore point)"
printf '%s\n' "$COUNT_SQL" | psql_on "$PRIMARY" "$DB" | cut -f2- > "$WORK/b.tsv"

# ------------------------------------------------------- temporary policies
say "4. clone the source's network policies onto the restore cluster label"
clone_policies() { # <resource>
  k get "$1" -n "$NS" -o json | jq -c --arg src "$SRC" --arg dst "$RESTORE" \
    --arg mk "$MANAGED_KEY" --arg mv "$MANAGED_VAL" '
    def sel: (.spec.endpointSelector.matchLabels // .spec.podSelector.matchLabels // {});
    .items[]
    | select(sel | to_entries | any((.key=="cnpg.io/cluster" or .key=="k8s:cnpg.io/cluster") and .value==$src))
    | {apiVersion, kind,
       metadata: {name: (.metadata.name + "-" + $mv), namespace: .metadata.namespace,
                  labels: {($mk): $mv}},
       spec: (.spec | walk(if type=="object" then with_entries(
                if (.key=="cnpg.io/cluster" or .key=="k8s:cnpg.io/cluster") and .value==$src
                then .value=$dst else . end) else . end))}'
}
: > "$WORK/policies.jsonl"
clone_policies ciliumnetworkpolicies.cilium.io >> "$WORK/policies.jsonl"
clone_policies networkpolicies.networking.k8s.io >> "$WORK/policies.jsonl"
if [ -s "$WORK/policies.jsonl" ]; then
  jq -r '"  \(.kind)/\(.metadata.name)"' "$WORK/policies.jsonl"
else
  echo "  no policy selects cnpg.io/cluster=$SRC — the restore pods run under the same (namespace) posture as the source"
fi

# ------------------------------------------------------------ restore cluster
say "5. disposable recovery cluster $NS/$RESTORE -> restore point $RP_NAME"
jq --arg ns "$NS" --arg name "$RESTORE" --arg sc "$SC" --arg db "$DB" --arg owner "$OWNER" \
   --arg rp "$RP_NAME" --arg bid "$BACKUP_ID" --arg os "$OBJSTORE" --arg server "$SERVER" --arg plugin "$PLUGIN" \
   --arg mk "$MANAGED_KEY" --arg mv "$MANAGED_VAL" '
  .spec as $s
  # Parameters a recovering server must not set below the primary; the rest of
  # the live parameter map is CNPG-managed (fixed parameters are rejected).
  | ["max_connections","max_worker_processes","max_wal_senders","max_prepared_transactions",
     "max_locks_per_transaction","shared_buffers"] as $carry
  | {apiVersion: "postgresql.cnpg.io/v1", kind: "Cluster",
     metadata: {name: $name, namespace: $ns, labels: {($mk): $mv}},
     spec: ({
       instances: 1,
       storage: {size: $s.storage.size, storageClass: $sc},
       inheritedMetadata: {labels: (($s.inheritedMetadata.labels // {}) + {($mk): $mv})},
       postgresql: ({parameters: (($s.postgresql.parameters // {}) | with_entries(select(.key as $k | $carry | index($k))))}
         + (if $s.postgresql.shared_preload_libraries then {shared_preload_libraries: $s.postgresql.shared_preload_libraries} else {} end)
         + (if $s.postgresql.extensions then {extensions: $s.postgresql.extensions} else {} end)),
       bootstrap: {recovery: {source: "origin", database: $db, owner: $owner,
                              recoveryTarget: {targetName: $rp, backupID: $bid}}},
       externalClusters: [{name: "origin",
                           plugin: {name: $plugin,
                                    parameters: {barmanObjectName: $os, serverName: $server}}}]
     }
     + (if $s.imageName then {imageName: $s.imageName} else {} end)
     + (if $s.imageCatalogRef then {imageCatalogRef: $s.imageCatalogRef} else {} end)
     + (if ($s.resources // {}) != {} then {resources: $s.resources} else {} end)
     + (if $s.walStorage then {walStorage: ($s.walStorage + {storageClass: $sc})} else {} end))}
' "$WORK/src.json" > "$WORK/restore-cluster.json"

jq -s '{apiVersion: "v1", kind: "List", items: .}' "$WORK/policies.jsonl" > "$WORK/policies.json"
echo "server-side dry-run ..."
[ -s "$WORK/policies.jsonl" ] && k apply --dry-run=server -f "$WORK/policies.json" >/dev/null
k apply --dry-run=server -f "$WORK/restore-cluster.json" >/dev/null
echo "dry-run accepted"

CREATED=true
[ -s "$WORK/policies.jsonl" ] && k apply -f "$WORK/policies.json"
k apply -f "$WORK/restore-cluster.json"
T_APPLY="$(now)"

deadline=$(( T_APPLY + READY_TIMEOUT ))
last_phase=""
while :; do
  cj="$(cget "$RESTORE" 2>/dev/null || echo '{}')"
  phase="$(printf '%s' "$cj" | jq -r '.status.phase // "pending"')"
  ready="$(printf '%s' "$cj" | jq -r '.status.conditions[]? | select(.type=="Ready") | .status')"
  if [ "$phase" != "$last_phase" ]; then
    echo "  $(( $(now) - T_APPLY ))s  phase: $phase"
    last_phase="$phase"
  fi
  if [ "$ready" = True ]; then T_READY="$(now)"; break; fi
  failed_jobs="$(k get jobs -n "$NS" -l "cnpg.io/cluster=$RESTORE" -o json \
    | jq -r '[.items[] | select(any(.status.conditions[]?; .type=="Failed" and .status=="True")) | .metadata.name] | join(",")')"
  if [ -n "$failed_jobs" ]; then
    echo "recovery job failed: $failed_jobs — last error lines:" >&2
    k logs -n "$NS" "job/${failed_jobs%%,*}" --all-containers --tail=200 2>/dev/null \
      | grep -iE '"level":"(error|fatal)"|FATAL|ERROR' | tail -10 | cut -c1-400 >&2 || true
    fail "recovery job failed"
  fi
  [ "$(now)" -ge "$deadline" ] && fail "restore cluster not Ready within ${READY_TIMEOUT}s (phase: $phase)"
  sleep 10
done
echo "Ready after $(( T_READY - T_APPLY ))s"

RPOD="$(k get pod -n "$NS" -l "cnpg.io/cluster=$RESTORE,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}')"
[ -n "$RPOD" ] || fail "restore cluster Ready but no primary pod"
[ "$(echo 'SELECT pg_is_in_recovery();' | psql_on "$RPOD" "$DB")" = f ] \
  || fail "restored instance is still in recovery"
# Proof the replay stopped AT the restore point rather than running to the end
# of the archive: a table that did not change would match either way, so the
# comparison alone cannot tell the two apart. The evidence is durable, not a
# log line: on promotion Postgres writes the new timeline's history file with
# the stop reason (`at restore point "<name>"`). The recovery job's log is not
# usable for this — CNPG removes the job pod once the instance takes over.
tli="$(echo 'SELECT timeline_id FROM pg_control_checkpoint();' | psql_on "$RPOD" "$DB")"
hist="$(printf 'pg_wal/%08X.history' "$tli")"
stop_line="$(printf "SELECT pg_read_file('%s');\n" "$hist" | psql_on "$RPOD" "$DB" \
  | grep -F "at restore point \"$RP_NAME\"" | head -1 || true)"
[ -n "$stop_line" ] || fail "timeline $tli history ($hist) does not record 'at restore point \"$RP_NAME\"' — cannot prove the restore stopped at the target"
echo "recovery stop evidence ($hist): $(printf '%s' "$stop_line" | tr '\t' ' ')"

# ------------------------------------------------------------------ compare
say "6. compare restored data against snapshots A and B"
printf '%s\n' "$COUNT_SQL" | psql_on "$RPOD" "$DB" | cut -f2- > "$WORK/r.tsv"
set +e
python3 - "$WORK/a.tsv" "$WORK/b.tsv" "$WORK/r.tsv" <<'PY'
import sys
def load(p):
    out = {}
    for line in open(p):
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 2:
            out[parts[0]] = (int(parts[1]), int(parts[2]) if len(parts) > 2 and parts[2] else None)
    return out
a, b, r = (load(p) for p in sys.argv[1:4])
def within(x, lo, hi):
    return x is None and lo is None and hi is None or (
        x is not None and lo is not None and hi is not None and min(lo, hi) <= x <= max(lo, hi))
bad = vol = ok = 0
print(f"{'table':<44} {'A count/max':>18} {'B count/max':>18} {'restored':>18}  verdict")
for t in sorted(a):
    ac, am = a[t]
    bc, bm = b.get(t, (None, None))
    fmt = lambda c, m: "-" if c is None else f"{c}/{'' if m is None else m}"
    if bc is None:
        verdict, bad = "FAIL table vanished between A and B", bad + 1
        rc = rm = None
    elif t not in r:
        verdict, bad = "FAIL missing", bad + 1
        rc = rm = None
    else:
        rc, rm = r[t]
        if (ac, am) == (bc, bm):
            if (rc, rm) == (ac, am):
                verdict, ok = "ok", ok + 1
            else:
                verdict, bad = f"FAIL exact (count {rc - ac:+d})", bad + 1
        elif within(rc, ac, bc) and within(rm, am, bm):
            verdict, vol = f"volatile (A->B {bc - ac:+d}, restored {rc - ac:+d} vs A)", vol + 1
        else:
            verdict, bad = "FAIL outside A..B", bad + 1
    if verdict != "ok":
        print(f"{t:<44} {fmt(ac, am):>18} {fmt(bc, bm):>18} {fmt(rc, rm):>18}  {verdict}")
extra = sorted(set(r) - set(a))
for t in extra:
    print(f"{t:<44} {'-':>18} {'-':>18} {'present':>18}  FAIL not in source")
bad += len(extra)
print(f"\n{len(a)} tables: {ok} exact, {vol} volatile within A..B, {bad} failed "
      f"(rows A={sum(v[0] for v in a.values())} restored={sum(v[0] for v in r.values())})")
sys.exit(1 if bad else 0)
PY
cmp_rc=$?
set -e
[ "$cmp_rc" -eq 0 ] || { RESULT="FAIL (restored data does not match the source at the restore point)"; exit 1; }

RESULT="PASS — restored to '$RP_NAME' in $(( T_READY - T_APPLY ))s; every table matches the source at the restore point"
echo
echo "restore-drill-history row (05-security/audit/restore-drill-history.md):"
echo "| $(date -u +%F) | $SRC (CNPG \`$NS/$SRC\`) | warm (MinIO barman via the barman-cloud plugin, \`bootstrap.recovery\`) | named restore point \`$RP_NAME\` | 0 (restore point created by the run) | apply→Ready $(( T_READY - T_APPLY ))s | **PASS** | scripts/verify-cnpg-restore.sh $NS $SRC |"
