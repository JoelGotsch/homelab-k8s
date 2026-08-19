#!/usr/bin/env bash
# check-backup-share-mounts.sh — every share the offsite job claims to back up
# is actually mounted into the pod that backs it up.
#
# WHY THIS EXISTS
#
# `backup_share` in nas-personal-cronjob.yaml begins:
#
#     backup_share() {  # $1=path  $2=class
#       if [ ! -d "$1" ]; then echo "SKIP $1 (not mounted)"; return 0; fi
#
# That `return 0` is deliberate and correct — a share whose PVC is temporarily
# unbound should not fail the whole run — but it means a **typo in a mountPath,
# a removed volume, or a renamed PVC silently drops a share from the offsite
# backup while the CronJob still reports success.** Nothing else notices: the
# job is green, the snapshot count for that share simply stops growing, and the
# only signal is a `SKIP` line in a log nobody reads until a restore.
#
# The second thing it catches is the drift that actually happened (2026-08-19):
# ADR 0051's Consequences said registry-blobs joins the offsite lane, the
# manifests said the opposite for four days, and nothing compared them. A
# decision recorded only in prose drifts silently.
#
# WHAT IS AND IS NOT AN ERROR
#
#   ERROR  a `backup_share` path with no matching volumeMount   -> silent skip
#   ERROR  a mounted volume whose PVC is not declared           -> pod won't start
#   NOTE   a `backup-src-*` PVC with no `backup_share` call     -> legitimate:
#          a share can have a share-root mount handle for
#          migrate-nas-dataset.sh without being in the backup lane. Reported so
#          the choice stays visible, never failed.
set -euo pipefail
cd "$(dirname "$0")/.."

CRON=infrastructure/backup-cronjobs/nas-personal-cronjob.yaml
PVCS=infrastructure/backup-cronjobs/nas-personal-pvcs.yaml
for f in "$CRON" "$PVCS"; do
  [ -f "$f" ] || { echo "FAIL: $f missing — cannot check the offsite lane."; exit 1; }
done

python3 - "$CRON" "$PVCS" <<'PY'
import re, sys, pathlib

cron = pathlib.Path(sys.argv[1]).read_text()
pvcs = pathlib.Path(sys.argv[2]).read_text()

# `backup_share /nas/<share> <class>` — skip the function definition itself.
shares = {m.group(1): m.group(2) for m in
          re.finditer(r'^\s*backup_share\s+(/nas/\S+)\s+(\S+)\s*$', cron, re.M)}

# `- { name: X, mountPath: /nas/Y, readOnly: true }`
mounts = {m.group(2): m.group(1) for m in
          re.finditer(r'-\s*\{\s*name:\s*([\w-]+),\s*mountPath:\s*(/nas/\S+?),', cron)}

# `- { name: X, persistentVolumeClaim: { claimName: Y } }`
vols = {m.group(1): m.group(2) for m in
        re.finditer(r'-\s*\{\s*name:\s*([\w-]+),\s*persistentVolumeClaim:\s*\{\s*claimName:\s*([\w-]+)', cron)}

declared = set(re.findall(r'^\s*name:\s*(backup-src-[\w-]+)\s*$', pvcs, re.M))

fail = 0
for path, cls in sorted(shares.items()):
    vol = mounts.get(path)
    if not vol:
        print(f"FAIL: `backup_share {path} {cls}` has no volumeMount at that path.")
        print( "      backup_share returns 0 when the path is absent, so this share")
        print( "      would be SILENTLY skipped and the job would still report success.")
        fail = 1
        continue
    claim = vols.get(vol)
    if not claim:
        print(f"FAIL: {path} mounts volume '{vol}', which has no persistentVolumeClaim.")
        fail = 1
    elif claim not in declared:
        print(f"FAIL: {path} -> volume '{vol}' -> PVC '{claim}', which nas-personal-pvcs.yaml does not declare.")
        fail = 1

unused = sorted(declared - {vols.get(mounts.get(p, ''), '') for p in shares})
if unused:
    print(f"note: {len(unused)} backup-src PVC(s) declared but not in the backup lane:")
    for u in unused:
        print(f"    - {u}")
    print( "      Legitimate if intended: a share can carry a share-root mount handle")
    print( "      for migrate-nas-dataset.sh without being backed up. Not a failure.")

if fail:
    sys.exit(1)
print(f"OK: {len(shares)} share(s) in the offsite lane, each mounted and PVC-backed.")
PY
