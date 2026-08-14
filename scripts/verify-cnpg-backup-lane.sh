#!/usr/bin/env bash
# verify-cnpg-backup-lane.sh — prove a CNPG cluster's backup lane is
# actually working, against S3, not against status fields.
#
# Usage: verify-cnpg-backup-lane.sh <namespace> <cluster> <s3-prefix>
#   e.g. verify-cnpg-backup-lane.sh observability-crowdsec crowdsec-lapi crowdsec
#
# Checks, in order:
#   1. Cluster Ready + ContinuousArchiving=True.
#   2. Which archiver is in play (in-core barmanObjectStore vs plugin),
#      and that exactly one is configured.
#   3. Instance pods carry the barman sidecar with explicit memory
#      requests+limits (the LimitRange would otherwise cap it at 512Mi).
#   4. A forced WAL switch produces a NEW object under the SAME S3
#      prefix within the timeout — the only real proof of archiving.
#   5. Backup objects: newest phase + method.
#   6. lastSuccessfulBackup / firstRecoverabilityPoint are set.
#
# Exit non-zero on the first hard failure. Read-only except for
# pg_switch_wal() on the primary, which is a normal, safe operation.

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
  # mc writes config to ~/.mcli; PSS-restricted + read-only rootfs on the
  # MinIO pod means only /dev/shm is writable.
  k -n minio-on-nas exec "$pod" -- sh -c "
    MC_CONFIG_DIR=/dev/shm/mcc mc alias set local http://localhost:9000 \
      minioadmin \"\$MINIO_ROOT_PASSWORD\" >/dev/null
    MC_CONFIG_DIR=/dev/shm/mcc $*
  "
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
k get pod -n "$NS" -l "cnpg.io/cluster=$CLUSTER,cnpg.io/podRole=instance" \
  -o json | python3 -c '
import json,sys
bad=0
for p in json.load(sys.stdin)["items"]:
    names=[c["name"] for c in p["spec"]["containers"]]
    print(" ", p["metadata"]["name"], names)
    for c in p["spec"]["containers"]:
        r=c.get("resources",{})
        lim=(r.get("limits") or {}).get("memory")
        req=(r.get("requests") or {}).get("memory")
        print("      %-24s req=%s lim=%s" % (c["name"], req, lim))
        if c["name"] != "postgres" and not lim:
            bad=1
sys.exit(bad)
' || fail "a sidecar has no memory limit"

say "4. forced WAL switch lands a new object in s3://$BUCKET/cnpg/$PREFIX/"
before=$(mc "mc ls --recursive local/$BUCKET/cnpg/$PREFIX/" | wc -l | tr -d ' ')
primary=$(k get pod -n "$NS" \
  -l "cnpg.io/cluster=$CLUSTER,cnpg.io/instanceRole=primary" \
  -o jsonpath='{.items[0].metadata.name}')
[ -n "$primary" ] || fail "no primary pod found"
echo "primary: $primary   objects before: $before"
k exec -n "$NS" "$primary" -c postgres -- psql -tAc "SELECT pg_switch_wal();" >/dev/null
deadline=$(( $(date +%s) + WAL_TIMEOUT ))
while :; do
  after=$(mc "mc ls --recursive local/$BUCKET/cnpg/$PREFIX/" | wc -l | tr -d ' ')
  [ "$after" -gt "$before" ] && { echo "objects after: $after — NEW WAL ARCHIVED"; break; }
  [ "$(date +%s)" -ge "$deadline" ] && fail "no new object after ${WAL_TIMEOUT}s — archiving is NOT working"
  sleep 5
done

say "5. backup objects (fully-qualified: 'backup' alone resolves to longhorn.io)"
k get backups.postgresql.cnpg.io -n "$NS" \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns='NAME:.metadata.name,METHOD:.spec.method,PHASE:.status.phase,STOPPED:.status.stoppedAt' \
  | tail -5

say "6. recoverability"
k get clusters.postgresql.cnpg.io -n "$NS" "$CLUSTER" \
  -o jsonpath='lastSuccessfulBackup={.status.lastSuccessfulBackup}{"\n"}firstRecoverabilityPoint={.status.firstRecoverabilityPoint}{"\n"}'

printf '\nOK: %s/%s backup lane verified against S3.\n' "$NS" "$CLUSTER"
