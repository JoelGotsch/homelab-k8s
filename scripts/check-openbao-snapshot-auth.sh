#!/usr/bin/env bash
# Contain the temporary OpenBao snapshot-token bridge until OBA-02 replaces it.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readme="$repo_root/platform/openbao/README.md"
manifest="$repo_root/platform/openbao/raft-snapshot-cronjob.yaml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

if rg -n -- '-ttl=8760h|Yearly rotation|long-lived orphan token' \
  "$readme" "$manifest"; then
  fail 'impossible one-year/static snapshot-token guidance reappeared'
fi

yq ea -e '[select(
  .kind == "ExternalSecret" and
  .metadata.name == "openbao-snapshot-token" and
  .spec.data[0].secretKey == "token" and
  .spec.data[0].remoteRef.key == "prod/openbao/snapshot-token" and
  .spec.data[0].remoteRef.property == "token" and
  (.spec.data | length) == 1
)] | length == 1' "$manifest" >/dev/null ||
  fail 'snapshot ExternalSecret must select the exact token property'

rg -q 'expires `2026-08-19T21:40:48Z`' "$readme" ||
  fail 'README must retain the temporary bridge expiry'
rg -q 'Do not issue another long-lived token' "$readme" ||
  fail 'README must block static-token renewal'

printf '%s\n' 'OpenBao snapshot authentication containment: PASS'
