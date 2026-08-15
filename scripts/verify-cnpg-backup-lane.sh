#!/usr/bin/env bash
# verify-cnpg-backup-lane.sh — prove a CNPG cluster's backup lane is
# actually working, against S3, not against status fields.
#
# Usage: verify-cnpg-backup-lane.sh <namespace> <cluster> <s3-prefix>
#   e.g. verify-cnpg-backup-lane.sh observability-crowdsec crowdsec-lapi crowdsec
#
# Checks, in order:
#   1. Cluster Ready + ContinuousArchiving=True.
#   2. Exactly one archiver configured: in-core barmanObjectStore XOR
#      the barman-cloud plugin.
#   3. Instance pods: every non-postgres container (i.e. the barman
#      sidecar, once migrated) carries a memory limit. Namespaces with a
#      LimitRange would silently cap it at 512Mi; namespaces without one
#      leave it unbounded.
#   4. THE PROOF: force a new WAL segment and require that this exact
#      segment lands in S3, under the prefix the cluster already uses.
#      This is what catches both classes of silent failure seen on
#      2026-08-14 — archiving that never worked (librechat-vectordb) and
#      a serverName change that would fork the object history.
#   5. Backup objects: newest method + phase.
#   6. lastSuccessfulBackup / firstRecoverabilityPoint are set.
#
# Why a restore point and not just pg_switch_wal(): on an IDLE primary
# `pg_switch_wal()` is a no-op — there is nothing in the current segment
# to close, so nothing is archived, and a naive "did a new object
# appear?" check reports a false failure. (It did, for llm-gateway, on
# 2026-08-14; the lane was healthy.) `pg_create_restore_point()` writes
# one small WAL record first, so the switch always has something to
# archive. Same idle-WAL trap as the standby-rejoin caveat in
# known-caveats.md.
#
# Exit non-zero on the first hard failure. The only write is a restore
# point plus a WAL switch on the primary: both are routine, and neither
# touches application data.

set -euo pipefail

NS="${1:?namespace}"
CLUSTER="${2:?cluster name}"
PREFIX="${3:?s3 prefix under homelab-backups-cluster/cnpg/}"
BUCKET="homelab-backups-cluster"
WAL_TIMEOUT="${WAL_TIMEOUT:-120}"

k() { kubectl "$@"; }
say() { printf '\n== %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

mc() {
  local pod
  # The MinIO pod is labelled `app=minio` (chart-legacy), NOT
  # app.kubernetes.io/name -- cluster-rebuild.md's snippet uses the
  # latter and silently selects nothing.
  pod="$(k -n minio-on-nas get pod -l app=minio \
    -o jsonpath='{.items[0].metadata.name}')"
  [ -n "$pod" ] || fail "no MinIO pod found in minio-on-nas"
  # mc writes its config to ~/.mcli; PSS-restricted + read-only rootfs
  # on the MinIO pod means only /dev/shm is writable.
  k -n minio-on-nas exec "$pod" -- sh -c "
    MC_CONFIG_DIR=/dev/shm/mcc mc alias set local http://localhost:9000 \
      minioadmin \"\$MINIO_ROOT_PASSWORD\" >/dev/null
    MC_CONFIG_DIR=/dev/shm/mcc $*
  "
}

psql_primary() {
  k exec -n "$NS" "$PRIMARY" -c postgres -- psql -tAc "$1"
}

say "1. cluster conditions"
k get clusters.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
ready=$(k get clusters.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
arch=$(k get clusters.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
  -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].status}')
[ "$ready" = "True" ] || fail "cluster not Ready"
[ "$arch" = "True" ] || fail "ContinuousArchiving is not True"

say "2. archiver configuration"
incore=$(k get clusters.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
  -o jsonpath='{.spec.backup.barmanObjectStore.destinationPath}')
plugin=$(k get clusters.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
  -o jsonpath='{.spec.plugins[?(@.isWALArchiver==true)].parameters.barmanObjectName}')
echo "in-core destinationPath: ${incore:-<none>}"
echo "plugin barmanObjectName: ${plugin:-<none>}"
[ -n "$incore" ] && [ -n "$plugin" ] && fail "both archivers configured"
[ -z "$incore" ] && [ -z "$plugin" ] && fail "NO archiver configured"

say "3. instance pods + sidecar resources"
# The barman sidecar is injected as a NATIVE sidecar: an initContainer
# with restartPolicy: Always. It does not appear in .spec.containers, so
# a check that only walks containers sees nothing and passes vacuously.
k get pod -n "$NS" -l "cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance" \
  -o json | python3 -c '
import json,sys
bad=0
for p in json.load(sys.stdin)["items"]:
    spec=p["spec"]
    sidecars=[c for c in spec.get("initContainers",[]) if c.get("restartPolicy")=="Always"]
    print(" ", p["metadata"]["name"],
          "containers=%s sidecars=%s" % ([c["name"] for c in spec["containers"]],
                                         [c["name"] for c in sidecars]))
    for c in spec["containers"] + sidecars:
        r=c.get("resources",{}) or {}
        lim=(r.get("limits") or {}).get("memory")
        req=(r.get("requests") or {}).get("memory")
        print("      %-24s req=%s lim=%s" % (c["name"], req, lim))
        if c["name"] != "postgres" and not lim:
            bad=1
sys.exit(bad)
' || fail "a sidecar has no memory limit"

say "4. force a WAL segment and require it in S3 under cnpg/$PREFIX/$CLUSTER/"
PRIMARY="$(k get pod -n "$NS" \
  -l "cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}')"
[ -n "$PRIMARY" ] || fail "no primary pod found (cnpg.io/instanceRole=primary)"
before_count="$(psql_primary 'SELECT archived_count FROM pg_stat_archiver;' | tr -d ' ')"
before_wal="$(psql_primary 'SELECT last_archived_wal FROM pg_stat_archiver;' | tr -d ' ')"
echo "primary: $PRIMARY   archived_count=$before_count last=$before_wal"

# A restore point guarantees the current segment is non-empty, so the
# switch below always produces something to archive.
psql_primary "SELECT pg_create_restore_point('backup-lane-verify');" >/dev/null
psql_primary 'SELECT pg_switch_wal();' >/dev/null

deadline=$(( $(date +%s) + WAL_TIMEOUT ))
while :; do
  now_count="$(psql_primary 'SELECT archived_count FROM pg_stat_archiver;' | tr -d ' ')"
  now_wal="$(psql_primary 'SELECT last_archived_wal FROM pg_stat_archiver;' | tr -d ' ')"
  if [ "$now_count" -gt "$before_count" ] 2>/dev/null; then
    echo "archived_count $before_count -> $now_count, last_archived_wal=$now_wal"
    break
  fi
  [ "$(date +%s)" -ge "$deadline" ] && fail "pg_stat_archiver did not advance in ${WAL_TIMEOUT}s — archiving is NOT working"
  sleep 5
done

# The object must exist under the cluster's OWN prefix. A serverName
# change would archive successfully into a DIFFERENT prefix and fork the
# history, which a "did the bucket grow?" check cannot see.
key="cnpg/$PREFIX/$CLUSTER/wals/${now_wal:0:16}/${now_wal}.bz2"
echo "expecting s3://$BUCKET/$key"
mc "mc stat local/$BUCKET/$key" >/dev/null 2>&1 \
  || fail "archived $now_wal is NOT at the expected key ($key) — serverName or destinationPath drift"
echo "object present — WAL chain continues under the same prefix"

say "5. backup objects (fully-qualified: 'backup' alone resolves to longhorn.io)"
k get backups.postgresql.cnpg.io -n "$NS" \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns='NAME:.metadata.name,METHOD:.spec.method,PHASE:.status.phase,STOPPED:.status.stoppedAt' \
  | tail -5

say "6. recoverability"
k get clusters.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
  -o jsonpath='lastSuccessfulBackup={.status.lastSuccessfulBackup}{"\n"}firstRecoverabilityPoint={.status.firstRecoverabilityPoint}{"\n"}'

printf '\nOK: %s/%s backup lane verified against S3.\n' "$NS" "$CLUSTER"
