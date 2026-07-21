#!/usr/bin/env bash
# Enforce the durable OBA-02 workload-identity and snapshot-delivery contract.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
layer="$repo_root/platform/openbao"
hourly="$layer/raft-snapshot-hourly.yaml"
daily="$layer/raft-snapshot-cronjob.yaml"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

rollback_bridge="$layer/snapshot-token-rollback-bridge.yaml"

rg -q 'bao kv patch -mount=kv prod/backup/hetzner-storage-box' \
  "$layer/README.md" \
  || fail 'Storage Box seed must patch the shared KV object without replacing sibling keys'
if rg -n 'bao kv put kv/prod/backup/hetzner-storage-box' "$layer/README.md"; then
  fail 'destructive full replacement of the shared Storage Box KV object is forbidden'
fi

# During the evidence window, the old credential may exist only as an unused,
# explicitly named rollback bridge. Any workload or documentation reference to
# its concrete Secret/KV identifiers is a regression.
if rg -n 'openbao-snapshot-token|prod/openbao/snapshot-token' "$layer" \
    -g '!snapshot-token-rollback-bridge.yaml'; then
  fail 'static snapshot-token identifiers are forbidden outside the rollback bridge'
fi

yq ea -e '
  [select(.kind == "ExternalSecret" and
    .metadata.name == "openbao-snapshot-token" and
    .metadata.namespace == "openbao" and
    .metadata.annotations."migration.homelab.internal/remove-after" ==
      "OBA-02 restore rehearsal" and
    .spec.secretStoreRef.kind == "ClusterSecretStore" and
    .spec.secretStoreRef.name == "openbao" and
    .spec.target.name == "openbao-snapshot-token" and
    (.spec.data | length == 1) and
    .spec.data[0].secretKey == "token" and
    .spec.data[0].remoteRef.key == "prod/openbao/snapshot-token" and
    .spec.data[0].remoteRef.property == "token")] | length == 1
' "$rollback_bridge" >/dev/null \
  || fail 'rollback bridge must retain exactly the existing static token'

rg -q 'snapshot-token-rollback-bridge.yaml' "$layer/kustomization.yaml" \
  || fail 'rollback bridge would be pruned before rollout evidence passes'

yq -e '
  .kind == "ServiceAccount" and
  .metadata.name == "openbao-raft-snapshot" and
  .metadata.namespace == "openbao" and
  .automountServiceAccountToken == false
' "$layer/snapshot-serviceaccount.yaml" >/dev/null \
  || fail 'dedicated ServiceAccount must disable automatic token mounting'

for tuple in \
  "openbao-raft-snapshot-hourly:$hourly" \
  "openbao-raft-snapshot:$daily"; do
  cron="${tuple%%:*}"
  manifest="${tuple#*:}"
  # shellcheck disable=SC2016 # yq reads CRON through strenv()
  CRON="$cron" yq ea -e '
    select(.kind == "CronJob" and .metadata.name == strenv(CRON)) |
    [
      (.spec.jobTemplate.spec.template.spec.serviceAccountName == "openbao-raft-snapshot"),
      (.spec.jobTemplate.spec.template.spec.automountServiceAccountToken == false),
      (.spec.jobTemplate.spec.ttlSecondsAfterFinished == 86400),
      (.spec.failedJobsHistoryLimit == 3)
    ] | all
  ' "$manifest" >/dev/null \
    || fail "$cron lacks the dedicated identity or retained evidence"
  CRON="$cron" yq ea -e '
    select(.kind == "CronJob" and .metadata.name == strenv(CRON)) |
    [.spec.jobTemplate.spec.template.spec.volumes[] |
      select(.name == "workload-jwt" and
      .projected.defaultMode == "0400" and
      .projected.sources[0].serviceAccountToken.audience == "openbao" and
      .projected.sources[0].serviceAccountToken.expirationSeconds == 900 and
      .projected.sources[0].serviceAccountToken.path == "token")] | length == 1
  ' "$manifest" >/dev/null \
    || fail "$cron lacks the bounded projected JWT"
done

# Daily is the only cross-container path: the producer and uploader have distinct
# UIDs but the same narrowly scoped group/fsGroup. Hourly remains owner-only.
yq ea -e '
  select(.kind == "CronJob" and .metadata.name == "openbao-raft-snapshot") |
  [
    (.spec.jobTemplate.spec.template.spec.securityContext.runAsUser == 1000),
    (.spec.jobTemplate.spec.template.spec.securityContext.runAsGroup == 1000),
    (.spec.jobTemplate.spec.template.spec.securityContext.fsGroup == 1000),
    (.spec.jobTemplate.spec.template.spec.initContainers[0].securityContext.runAsUser == 100),
    (.spec.jobTemplate.spec.template.spec.initContainers[0].securityContext.runAsGroup == 1000),
    ([.spec.jobTemplate.spec.template.spec.initContainers[0].env[] |
      select(.name == "SNAPSHOT_PUBLISH_MODE" and .value == "0640")] | length == 1)
  ] | all
' "$daily" >/dev/null \
  || fail 'daily snapshot artifacts require UID 100 -> UID 1000 through group/fsGroup 1000 at mode 0640'
yq ea -e '
  select(.kind == "CronJob" and .metadata.name == "openbao-raft-snapshot-hourly") |
  [
    (.spec.jobTemplate.spec.template.spec.securityContext.runAsUser == 100),
    (.spec.jobTemplate.spec.template.spec.securityContext.runAsGroup == 1000),
    (.spec.jobTemplate.spec.template.spec.securityContext.fsGroup == 1000),
    ([.spec.jobTemplate.spec.template.spec.containers[0].env[] |
      select(.name == "SNAPSHOT_PUBLISH_MODE" and .value == "0600")] | length == 1)
  ] | all
' "$hourly" >/dev/null \
  || fail 'hourly snapshot and checksum must remain owner-only at mode 0600'

# shellcheck disable=SC2016 # this is a yq expression, not shell interpolation
yq ea -e '
  select(.kind == "CronJob" and .metadata.name == "openbao-raft-snapshot") |
  [
    (.spec.jobTemplate.spec.template.spec.initContainers[0].name == "create-snapshot"),
    (.spec.jobTemplate.spec.template.spec.containers[0].name == "upload"),
    ([.spec.jobTemplate.spec.template.spec.initContainers[0].volumeMounts[] |
      select(.name == "workload-jwt")] | length == 1),
    ([.spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] |
      select(.name == "workload-jwt")] | length == 0),
    ([.spec.jobTemplate.spec.template.spec.initContainers[0].volumeMounts[] |
      select(.name == "snapshot-tmp" and .mountPath == "/tmp")] | length == 1),
    ([.spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] |
      select(.name == "upload-tmp" and .mountPath == "/tmp")] | length == 1),
    ([.spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] |
      select(.name == "snapshot-tmp")] | length == 0),
    ([.spec.jobTemplate.spec.template.spec.containers[0].env[] |
      select(.name == "HSB_HOST" and .value == "u609156.your-storagebox.de")] |
      length == 1),
    ([.spec.jobTemplate.spec.template.spec.containers[0].env[] |
      select(.name == "HSB_USER" and .value == "u609156")] | length == 1),
    ([.spec.jobTemplate.spec.template.spec.containers[0].env[] |
      select(.name == "HSB_PORT" and .value == "23")] | length == 1),
    (.spec.jobTemplate.spec.template.spec.containers[0].image ==
      "restic/restic:0.17.3@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a")
  ] | all
' "$daily" >/dev/null \
  || fail 'daily upload must be isolated from OpenBao identity and digest-pinned'

yq ea -e '
  select(.kind == "ExternalSecret" and .metadata.name == "hetzner-sb-creds") |
  (.spec.data | length == 1) and
  .spec.data[0].secretKey == "SSH_KEY" and
  .spec.data[0].remoteRef.key == "prod/backup/hetzner-storage-box" and
  .spec.data[0].remoteRef.property == "ssh_key"
' "$daily" >/dev/null \
  || fail 'only the private SSH key may be projected from OpenBao'

rg -q 'auth/kubernetes/login' "$layer/snapshot-auth.sh" \
  || fail 'snapshot script no longer logs in through Kubernetes auth'
rg -q 'role=openbao-raft-snapshot' "$layer/snapshot-auth.sh" \
  || fail 'snapshot script uses the wrong OpenBao role'
rg -Fq '0600|0640) ;;' "$layer/snapshot-auth.sh" \
  || fail 'snapshot script must reject publish modes outside 0600/0640'
rg -Fq 'chmod "$publish_mode" "$output" "${output}.sha256"' \
  "$layer/snapshot-auth.sh" \
  || fail 'only the verified final snapshot and checksum may receive the publish mode'
server_image="$(yq -r '.server.image.registry + "/" + .server.image.repository + ":" + .server.image.tag' \
  "$layer/values.yaml")"
snapshot_images="$(yq ea -r -N '
  select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec |
  (.initContainers[]?.image, .containers[].image) |
  select(test("^quay.io/openbao/openbao:"))
' "$hourly" "$daily")" \
  || fail 'could not enumerate snapshot OpenBao images'
[ "$(printf '%s\n' "$snapshot_images" | grep -c .)" -eq 2 ] \
  || fail 'expected one OpenBao snapshot container in each CronJob'
while IFS= read -r snapshot_image; do
  [ "$snapshot_image" = "$server_image" ] \
    || fail "snapshot OpenBao image must match the digest-pinned server image"
done <<<"$snapshot_images"
unset snapshot_images snapshot_image server_image
if rg -n 'ssh-keyscan|StrictHostKeyChecking=(no|accept-new)' \
    "$layer/snapshot-upload.sh" "$daily"; then
  fail 'TOFU or disabled Storage Box host verification is forbidden'
fi
rg -q 'remote checksum does not match' "$layer/snapshot-upload.sh" \
  || fail 'remote integrity comparison is missing'

for key in known_hosts passwd group; do
  case "$key" in
    known_hosts) source="$repo_root/infrastructure/backup-cronjobs/restic-known-hosts-configmap.yaml" ;;
    passwd|group) source="$repo_root/infrastructure/backup-cronjobs/restic-passwd-configmap.yaml" ;;
  esac
  cmp -s \
    <(yq -r ".data.$key" "$layer/snapshot-uploader-config.yaml") \
    <(yq -r ".data.$key" "$source") \
    || fail "snapshot uploader $key drifted from backup-cronjobs"
done

yq ea -e '
  select(.kind == "CiliumNetworkPolicy" and
    .metadata.name == "openbao-raft-snapshot-daily") |
  [
    (.spec.egress | length == 3),
    ([.spec.egress[].toPorts[]?.rules.dns[]?] | length == 1),
    ([.spec.egress[] | select(
      (.toEndpoints | length == 1) and
      (.toEndpoints[0].matchLabels | length == 2) and
      .toEndpoints[0].matchLabels."k8s:io.kubernetes.pod.namespace" == "kube-system" and
      .toEndpoints[0].matchLabels."k8s:k8s-app" == "kube-dns" and
      (.toPorts | length == 1) and
      (.toPorts[0].ports | length == 2) and
      ([.toPorts[0].ports[] | select(.port == "53" and .protocol == "UDP")] | length == 1) and
      ([.toPorts[0].ports[] | select(.port == "53" and .protocol == "TCP")] | length == 1) and
      (.toPorts[0].rules | length == 1) and
      (.toPorts[0].rules.dns | length == 1) and
      .toPorts[0].rules.dns[0].matchPattern == "*" and
      (.toPorts[0].rules.dns[0] | length == 1)
    )] | length == 1),
    ([.spec.egress[] | select(
      ([.toFQDNs[]? | select(.matchName == "u609156.your-storagebox.de")] | length == 1) and
      ([.toPorts[].ports[]? | select(.port == "23" and .protocol == "TCP")] | length == 1) and
      (.toPorts[0].ports | length == 1)
    )] | length == 1),
    ([.spec.egress[].toEntities[]? | select(. == "world")] | length == 0)
  ] | all
' "$layer/snapshot-networkpolicy.yaml" >/dev/null \
  || fail 'daily egress needs exact kube-dns L7 observation and the pinned Storage Box FQDN on TCP/23'
yq ea -e '
  select(.kind == "CiliumNetworkPolicy" and
    .metadata.name == "openbao-raft-snapshot-hourly") |
  [
    (.spec.egress | length == 2),
    ([.spec.egress[].toFQDNs[]?] | length == 0),
    ([.spec.egress[].toPorts[]?.rules.dns[]?] | length == 0),
    ([.spec.egress[].toEntities[]? | select(. == "world")] | length == 0)
  ] | all
' "$layer/snapshot-networkpolicy.yaml" >/dev/null \
  || fail 'hourly egress must remain L3/L4 DNS plus OpenBao only, without an unnecessary DNS proxy'

printf '%s\n' 'OpenBao snapshot authentication and delivery contract: PASS'
