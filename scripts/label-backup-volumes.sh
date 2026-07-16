#!/usr/bin/env bash
# Authoritative membership for the Longhorn `backup` recurring-job group.
#
# WHY A SCRIPT: Longhorn recurring-job group membership is a label on the
# Longhorn *Volume* CR, which is a runtime object created by Longhorn — it
# can't live in Argo/git. This script is the GitOps-tracked source of truth
# for WHICH volumes get the opt-in daily NAS backup (infrastructure/longhorn/
# recurring-jobs.yaml `backup-daily`, group `backup`). Run it after adding a
# new backup-worthy PVC. Idempotent.
#
# CONTEXT: backup was made opt-in on 2026-07-16 (was blanket `default` retain
# 90 → all ~54 volumes, which over-retained the NAS bucket and OOM-crashlooped
# longhorn-manager via orphaned Pending Backup CRs). Only volumes holding
# UNIQUE data that isn't already protected elsewhere belong here. Snapshots are
# separate — every volume keeps local `default` snapshots regardless.
#
# NOT in the backup set (and why):
#   *-pg-1/2, llm-gateway-1/2  → CNPG; barman base+WAL → NAS + restic offsite
#   openbao data/audit/raft    → own raft-snapshot → Hetzner pipeline
#   prometheus/loki/tempo/...   → telemetry, regenerable
#   *-hot, *-ml, *-redis/valkey → caches, regenerable
#   jellyfin-config, crowdsec-* → regenerable (rescan / rebuild)
#   woodpecker-*, restic-staging→ CI / scratch
#   langfuse clickhouse/s3      → Workstream D (efficient logical backup) later
# See backup-implementation-plan.md + TODO "Backup strategy" for the full map.
set -euo pipefail

NS=longhorn-system
GROUP_LABEL="recurring-job-group.longhorn.io/backup=enabled"

# PVC name (namespace/pvc) => reason. The backup set:
BACKUP_PVCS=(
  "vaultwarden/vaultwarden-data-vaultwarden-0|secret: attachments + org keys"
  "forgejo/gitea-shared-storage|internal: git repos + LFS"
  "signal-bridge/signal-bridge-data|secret: Signal linked-device session/keys"
  "paperless/paperless-data|personal: insurance copy (docs are on NAS-crypt)"
  "ntfy/ntfy-data|internal: default-offsite (cached msgs/attachments)"
  "nextcloud/nextcloud-hot|personal: datadirectory (file versions/trashbin) + config.php instance secret/passwordsalt (bulk user files are on NAS-crypt via Workstream C)"
  "langfuse/data-volume-chi-langfuse-langfuse-0-0-0|personal: ClickHouse trace store (private prompt/completion content). RAW-VOLUME backup = crash-consistent, not app-consistent; re-evaluate Sept 2026 vs clickhouse-backup logical + storage size"
  "langfuse/langfuse-s3|personal: Langfuse blob store (large trace payloads)"
)

echo "Labelling Longhorn volumes into the 'backup' recurring-job group..."
for entry in "${BACKUP_PVCS[@]}"; do
  pvc_ref="${entry%%|*}"; reason="${entry#*|}"
  ns="${pvc_ref%%/*}"; pvc="${pvc_ref#*/}"
  # Resolve PVC -> Longhorn volume name (the bound PV name == Longhorn volume name)
  vol=$(kubectl -n "$ns" get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
  if [[ -z "$vol" ]]; then
    echo "  SKIP $pvc_ref — PVC not found / unbound (app not deployed yet?)"
    continue
  fi
  kubectl -n "$NS" label volume "$vol" $GROUP_LABEL --overwrite >/dev/null
  echo "  OK   $pvc_ref  ->  $vol   [$reason]"
done

echo
echo "Verify: volumes currently in the 'backup' group —"
kubectl -n "$NS" get volumes.longhorn.io \
  -l recurring-job-group.longhorn.io/backup=enabled \
  -o custom-columns=VOLUME:.metadata.name,PVC:.status.kubernetesStatus.pvcName --no-headers 2>/dev/null \
  | sed 's/^/  /'
