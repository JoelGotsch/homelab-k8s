#!/usr/bin/env bash
# Mutation tests for the repository-local retention contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/check-retention-contract.sh"
CONTRACT="$SCRIPT_DIR/retention-contract.yaml"

for required_tool in yq mktemp cp mkdir rm; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "$required_tool" >&2
    exit 2
  }
done

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/retention-contract-test.XXXXXX")"
cleanup() {
  rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

make_fixture() {
  local fixture_root="$1"
  local relative_file
  local scope_root
  mkdir -p "$fixture_root"
  while IFS= read -r scope_root; do
    [ -n "$scope_root" ] && mkdir -p "$fixture_root/$scope_root"
  done < <(yq e -r '.scope.roots[]' "$CONTRACT")
  while IFS= read -r relative_file; do
    [ -n "$relative_file" ] || continue
    mkdir -p "$fixture_root/$(dirname "$relative_file")"
    cp "$REPO_ROOT/$relative_file" "$fixture_root/$relative_file"
  done < <(
    {
      yq e -r '.storage_classes.source' "$CONTRACT"
      yq e -r '.entries[].source.file' "$CONTRACT"
      yq e -r '.entries[].source.mirrors[]?' "$CONTRACT"
    } | sort -u
  )
}

expect_pass() {
  local name="$1"
  shift
  if ! "$CHECK" "$@" >/dev/null; then
    printf 'FAIL: expected pass: %s\n' "$name" >&2
    return 1
  fi
}

expect_fail() {
  local name="$1"
  shift
  if "$CHECK" "$@" >/dev/null 2>&1; then
    printf 'FAIL: expected failure: %s\n' "$name" >&2
    return 1
  fi
}

baseline_root="$TEMP_ROOT/baseline"
make_fixture "$baseline_root"
expect_pass "finite central baseline" --root "$baseline_root" --contract "$CONTRACT"

expanded_root="$TEMP_ROOT/expanded"
make_fixture "$expanded_root"
mkdir -p "$expanded_root/platform/unclassified"
cp "$expanded_root/infrastructure/backup-cronjobs/pvc.yaml" \
  "$expanded_root/platform/unclassified/pvc.yaml"
expect_fail "new Longhorn selector without classification" \
  --root "$expanded_root" --contract "$CONTRACT"

j2_expanded_root="$TEMP_ROOT/j2-expanded"
make_fixture "$j2_expanded_root"
mkdir -p "$j2_expanded_root/platform/unclassified"
cp "$j2_expanded_root/infrastructure/backup-cronjobs/pvc.yaml" \
  "$j2_expanded_root/platform/unclassified/pvc.yaml.j2"
expect_fail "new J2-only Longhorn selector without classification" \
  --root "$j2_expanded_root" --contract "$CONTRACT"

implicit_root="$TEMP_ROOT/implicit-default"
make_fixture "$implicit_root"
mkdir -p "$implicit_root/platform/implicit"
cp "$implicit_root/infrastructure/backup-cronjobs/pvc.yaml" \
  "$implicit_root/platform/implicit/pvc.yaml"
yq e -i 'del(.spec.storageClassName)' "$implicit_root/platform/implicit/pvc.yaml"
expect_fail "implicit default StorageClass cannot bypass classification" \
  --root "$implicit_root" --contract "$CONTRACT"

source_drift_root="$TEMP_ROOT/source-drift"
make_fixture "$source_drift_root"
yq e -i '
  (select(.kind == "PersistentVolumeClaim" and .metadata.name == "openbao-raft-snapshots") |
    .spec.storageClassName) = "longhorn-replica2-retain"
' "$source_drift_root/platform/openbao/raft-snapshot-hourly.yaml"
expect_fail "source migration without contract update" \
  --root "$source_drift_root" --contract "$CONTRACT"

policy_drift_root="$TEMP_ROOT/policy-drift"
make_fixture "$policy_drift_root"
STORAGE_CLASS=longhorn-replica2 yq e -i '
  (select(.kind == "StorageClass" and .metadata.name == strenv(STORAGE_CLASS)) |
    .reclaimPolicy) = "Retain"
' "$policy_drift_root/infrastructure/longhorn/storageclasses.yaml"
expect_fail "StorageClass reclaim policy drift" \
  --root "$policy_drift_root" --contract "$CONTRACT"

mirror_drift_root="$TEMP_ROOT/mirror-drift"
make_fixture "$mirror_drift_root"
yq e -i '.persistence.storageClass = "longhorn-replica3-retain"' \
  "$mirror_drift_root/platform/forgejo/values.yaml.j2"
expect_fail "render-source mirror drift" \
  --root "$mirror_drift_root" --contract "$CONTRACT"

duplicate_locator_root="$TEMP_ROOT/duplicate-locator"
make_fixture "$duplicate_locator_root"
duplicate_locator_contract="$TEMP_ROOT/duplicate-locator-contract.yaml"
cp "$CONTRACT" "$duplicate_locator_contract"
ENTRY_ID=grafana-data yq e -i '
  (.entries[] | select(.id == strenv(ENTRY_ID)) | .source.value_path) =
    ".prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName" |
  (.entries[] | select(.id == strenv(ENTRY_ID)) | .source.document_index) = 0 |
  (.entries[] | select(.id == strenv(ENTRY_ID)) | .source.selector_path) =
    "prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName"
' "$duplicate_locator_contract"
expect_fail "duplicate file/class locator cannot mask an omitted exact selector" \
  --root "$duplicate_locator_root" --contract "$duplicate_locator_contract"

migrated_root="$TEMP_ROOT/migrated"
make_fixture "$migrated_root"
migrated_contract="$TEMP_ROOT/migrated-contract.yaml"
cp "$CONTRACT" "$migrated_contract"
yq e -i '
  (select(.kind == "PersistentVolumeClaim" and .metadata.name == "openbao-raft-snapshots") |
    .spec.storageClassName) = "longhorn-replica2-retain"
' "$migrated_root/platform/openbao/raft-snapshot-hourly.yaml"
ENTRY_ID=openbao-raft-snapshots yq e -i '
  (.entries[] | select(.id == strenv(ENTRY_ID)) | .current_storage_class) = "longhorn-replica2-retain" |
  (.entries[] | select(.id == strenv(ENTRY_ID)) | .state) = "compliant" |
  (.entries[] | select(.id == strenv(ENTRY_ID)) | .migration_owner) = "none"
' "$migrated_contract"
expect_pass "source and contract migrate atomically" \
  --root "$migrated_root" --contract "$migrated_contract"

printf 'PASS: retention contract mutation tests\n'
