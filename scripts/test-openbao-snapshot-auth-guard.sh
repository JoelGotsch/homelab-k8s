#!/usr/bin/env bash
# Mutation tests proving the OBA-02 static guard fails on scope regressions.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_tmp="$(mktemp -d /tmp/openbao-snapshot-guard.XXXXXX)"
trap 'rm -rf -- "$test_tmp"' EXIT INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

make_fixture() {
  fixture="$test_tmp/$1"
  mkdir -p "$fixture/scripts" "$fixture/platform" "$fixture/infrastructure/backup-cronjobs"
  cp "$repo_root/scripts/check-openbao-snapshot-auth.sh" "$fixture/scripts/"
  cp -R "$repo_root/platform/openbao" "$fixture/platform/"
  cp "$repo_root/infrastructure/backup-cronjobs/restic-known-hosts-configmap.yaml" \
    "$repo_root/infrastructure/backup-cronjobs/restic-passwd-configmap.yaml" \
    "$fixture/infrastructure/backup-cronjobs/"
}

expect_rejected() {
  name="$1"
  if "$test_tmp/$name/scripts/check-openbao-snapshot-auth.sh" \
      >"$test_tmp/$name.out" 2>&1; then
    fail "mutation $name unexpectedly passed"
  fi
}

make_fixture audience
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.volumes[] |
  select(.name == "workload-jwt") |
  .projected.sources[0].serviceAccountToken.audience) = "kubernetes"' \
  "$test_tmp/audience/platform/openbao/raft-snapshot-hourly.yaml"
expect_rejected audience

make_fixture static-token
printf '\nopenbao-snapshot-token\n' >> \
  "$test_tmp/static-token/platform/openbao/README.md"
expect_rejected static-token

make_fixture uploader-jwt
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.containers[0].volumeMounts) +=
  [{"name":"workload-jwt","mountPath":"/stolen"}]' \
  "$test_tmp/uploader-jwt/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected uploader-jwt

make_fixture shared-token-tmp
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] |
  select(.mountPath == "/tmp") | .name) = "snapshot-tmp"' \
  "$test_tmp/shared-token-tmp/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected shared-token-tmp

make_fixture broad-egress
yq -i '(select(.kind == "CiliumNetworkPolicy" and
  .metadata.name == "openbao-raft-snapshot-daily") | .spec.egress) +=
  [{"toEntities":["world"]}]' \
  "$test_tmp/broad-egress/platform/openbao/snapshot-networkpolicy.yaml"
expect_rejected broad-egress

make_fixture secret-routing
yq -i '(select(.kind == "ExternalSecret" and
  .metadata.name == "hetzner-sb-creds") | .spec.data) +=
  [{"secretKey":"HSB_PORT","remoteRef":{"key":"prod/backup/hetzner-storage-box","property":"port"}}]' \
  "$test_tmp/secret-routing/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected secret-routing

printf '%s\n' 'PASS: static token, wrong audience, token sharing, secret routing, and broad egress are rejected.'
