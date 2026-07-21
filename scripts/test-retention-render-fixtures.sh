#!/usr/bin/env bash
# Mutation tests for the reviewed chart-render projection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/check-retention-render-fixtures.sh"
CLAIM_CHECK="$SCRIPT_DIR/check-rendered-retention-claims.sh"
FIXTURE="$SCRIPT_DIR/fixtures/retention-rendered-projection.yaml"
RENDERED_CLAIM_FIXTURE="$SCRIPT_DIR/fixtures/retention-rendered-claim-test.yaml"
CONTRACT="$SCRIPT_DIR/retention-contract.yaml"

for required_tool in yq mktemp cp mkdir rm rg; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "$required_tool" >&2
    exit 2
  }
done

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/retention-render-test.XXXXXX")"
cleanup() {
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/retention-render-test.*) rm -rf "$TEMP_ROOT" ;;
    *) printf 'ERROR: refusing to remove unexpected temp path: %s\n' "$TEMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

make_repo_fixture() {
  local fixture_root="$1"
  mkdir -p "$fixture_root/observability" "$fixture_root/platform"
  cp -R "$REPO_ROOT/observability/langfuse" "$fixture_root/observability/langfuse"
  cp -R "$REPO_ROOT/observability/crowdsec" "$fixture_root/observability/crowdsec"
  cp -R "$REPO_ROOT/platform/woodpecker" "$fixture_root/platform/woodpecker"
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

set_fixture_layer_digest() {
  local fixture_root="$1"
  local fixture_file="$2"
  local layer_path="$3"
  local digest
  digest="$($CHECK --root "$fixture_root" --print-layer-digest "$layer_path")"
  LAYER_PATH="$layer_path" LAYER_DIGEST="$digest" yq e -i '
    (.layers[] | select(.path == strenv(LAYER_PATH)) | .input_digest_sha256) = strenv(LAYER_DIGEST)
  ' "$fixture_file"
}

literal_presence_projection_count="$(rg -F 'has("value")' "$CHECK" | wc -l | tr -d ' ')"
[ "$literal_presence_projection_count" -eq 2 ] || {
  printf 'FAIL: both rendered-secret scans must project only literal-presence booleans\n' >&2
  exit 1
}
if rg -q '\[.*\.value[[:space:]]*//.*@tsv' "$CHECK"; then
  printf 'FAIL: rendered-secret scans must never place a raw literal value in TSV diagnostics\n' >&2
  exit 1
fi

baseline_root="$TEMP_ROOT/baseline"
make_repo_fixture "$baseline_root"
expect_pass "reviewed projection baseline" \
  --root "$baseline_root" --fixture "$FIXTURE" --contract "$CONTRACT"

if ! "$CLAIM_CHECK" --rendered "$RENDERED_CLAIM_FIXTURE" \
  --layer observability/langfuse --fixture "$FIXTURE" >/dev/null; then
  printf 'FAIL: expected rendered claim extractor baseline to pass\n' >&2
  exit 1
fi

missing_class_render="$TEMP_ROOT/missing-rendered-class.yaml"
cp "$RENDERED_CLAIM_FIXTURE" "$missing_class_render"
yq e -i '
  (select(.kind == "PersistentVolumeClaim" and .metadata.name == "langfuse-s3") | .spec) |=
    del(.storageClassName)
' "$missing_class_render"
if missing_output="$($CLAIM_CHECK --rendered "$missing_class_render" \
  --layer observability/langfuse --fixture "$FIXTURE" 2>&1)"; then
  printf 'FAIL: rendered PVC with missing class passed\n' >&2
  exit 1
fi
printf '%s\n' "$missing_output" | rg -q 'implicit default' || {
  printf 'FAIL: missing rendered PVC class did not report implicit default\n' >&2
  exit 1
}

empty_class_render="$TEMP_ROOT/empty-rendered-class.yaml"
cp "$RENDERED_CLAIM_FIXTURE" "$empty_class_render"
yq e -i '
  (select(.kind == "StatefulSet" and .metadata.name == "langfuse-redis-primary") |
   .spec.volumeClaimTemplates[] | select(.metadata.name == "valkey-data") |
   .spec.storageClassName) = ""
' "$empty_class_render"
if empty_output="$($CLAIM_CHECK --rendered "$empty_class_render" \
  --layer observability/langfuse --fixture "$FIXTURE" 2>&1)"; then
  printf 'FAIL: rendered StatefulSet claim template with empty class passed\n' >&2
  exit 1
fi
printf '%s\n' "$empty_output" | rg -q 'implicit default' || {
  printf 'FAIL: empty rendered claim-template class did not report implicit default\n' >&2
  exit 1
}

secret_root="$TEMP_ROOT/secret-key-drift"
make_repo_fixture "$secret_root"
secret_fixture="$TEMP_ROOT/secret-key-drift.yaml"
cp "$FIXTURE" "$secret_fixture"
yq e -i '
  .s3.eventUpload.accessKeyId.secretKeyRef.key = "WRONG_EVENT_ACCESS_KEY"
' "$secret_root/observability/langfuse/values.yaml"
set_fixture_layer_digest "$secret_root" "$secret_fixture" observability/langfuse
expect_fail "S3 key drift fails even after refreshing the layer digest" \
  --root "$secret_root" --fixture "$secret_fixture" --contract "$CONTRACT"

literal_root="$TEMP_ROOT/literal-secret-value"
make_repo_fixture "$literal_root"
literal_fixture="$TEMP_ROOT/literal-secret-value.yaml"
cp "$FIXTURE" "$literal_fixture"
yq e -i '
  .s3.eventUpload.accessKeyId.value = "PLAINTEXT_SENTINEL"
' "$literal_root/observability/langfuse/values.yaml"
set_fixture_layer_digest "$literal_root" "$literal_fixture" observability/langfuse
if literal_output="$($CHECK --root "$literal_root" --fixture "$literal_fixture" \
  --contract "$CONTRACT" 2>&1)"; then
  printf 'FAIL: non-empty S3 credential value passed after refreshing the layer digest\n' >&2
  exit 1
fi
printf '%s\n' "$literal_output" | rg -q 'must be empty when secretKeyRef is declared' || {
  printf 'FAIL: literal S3 credential mutation did not report the semantic violation\n' >&2
  exit 1
}
if printf '%s\n' "$literal_output" | rg -F -q 'PLAINTEXT_SENTINEL'; then
  printf 'FAIL: literal S3 credential value leaked into checker diagnostics\n' >&2
  exit 1
fi

fallback_literal_root="$TEMP_ROOT/fallback-literal-secret-value"
make_repo_fixture "$fallback_literal_root"
fallback_literal_fixture="$TEMP_ROOT/fallback-literal-secret-value.yaml"
cp "$FIXTURE" "$fallback_literal_fixture"
yq e -i '
  .s3.accessKeyId.value = "PLAINTEXT_FALLBACK_SENTINEL"
' "$fallback_literal_root/observability/langfuse/values.yaml"
set_fixture_layer_digest "$fallback_literal_root" "$fallback_literal_fixture" observability/langfuse
if fallback_output="$($CHECK --root "$fallback_literal_root" --fixture "$fallback_literal_fixture" \
  --contract "$CONTRACT" 2>&1)"; then
  printf 'FAIL: non-empty S3 fallback credential passed after refreshing the layer digest\n' >&2
  exit 1
fi
printf '%s\n' "$fallback_output" | rg -q 'credentials belong in a Secret' || {
  printf 'FAIL: literal S3 fallback mutation did not report the semantic violation\n' >&2
  exit 1
}

mirror_root="$TEMP_ROOT/secret-mirror-drift"
make_repo_fixture "$mirror_root"
mirror_fixture="$TEMP_ROOT/secret-mirror-drift.yaml"
cp "$FIXTURE" "$mirror_fixture"
yq e -i '
  .s3.mediaUpload.secretAccessKey.secretKeyRef.name = "wrong-secret"
' "$mirror_root/observability/langfuse/values.yaml.j2"
set_fixture_layer_digest "$mirror_root" "$mirror_fixture" observability/langfuse
expect_fail "authoritative values mirror secret refs cannot drift" \
  --root "$mirror_root" --fixture "$mirror_fixture" --contract "$CONTRACT"

externalsecret_mirror_root="$TEMP_ROOT/externalsecret-mirror-drift"
make_repo_fixture "$externalsecret_mirror_root"
externalsecret_mirror_fixture="$TEMP_ROOT/externalsecret-mirror-drift.yaml"
cp "$FIXTURE" "$externalsecret_mirror_fixture"
S3_SECRET_KEY=LANGFUSE_S3_BATCH_EXPORT_SECRET_ACCESS_KEY yq e -i '
  (select(.kind == "ExternalSecret" and .spec.target.name == "langfuse-app-secrets") |
    .spec.data) |= map(select(.secretKey != strenv(S3_SECRET_KEY)))
' "$externalsecret_mirror_root/observability/langfuse/externalsecret.yaml.j2"
set_fixture_layer_digest \
  "$externalsecret_mirror_root" "$externalsecret_mirror_fixture" observability/langfuse
if externalsecret_mirror_output="$($CHECK --root "$externalsecret_mirror_root" \
  --fixture "$externalsecret_mirror_fixture" --contract "$CONTRACT" 2>&1)"; then
  printf 'FAIL: authoritative ExternalSecret mirror omitted a referenced S3 key\n' >&2
  exit 1
fi
printf '%s\n' "$externalsecret_mirror_output" | \
  rg -q 'externalsecret.yaml.j2: missing projection for langfuse-app-secrets/LANGFUSE_S3_BATCH_EXPORT_SECRET_ACCESS_KEY' || {
    printf 'FAIL: ExternalSecret mirror mutation did not report the missing S3 projection\n' >&2
    exit 1
  }

externalsecret_remote_ref_root="$TEMP_ROOT/externalsecret-remote-ref-drift"
make_repo_fixture "$externalsecret_remote_ref_root"
externalsecret_remote_ref_fixture="$TEMP_ROOT/externalsecret-remote-ref-drift.yaml"
cp "$FIXTURE" "$externalsecret_remote_ref_fixture"
S3_SECRET_KEY=LANGFUSE_S3_BATCH_EXPORT_ACCESS_KEY_ID yq e -i '
  (select(.kind == "ExternalSecret" and .spec.target.name == "langfuse-app-secrets") |
    .spec.data[] | select(.secretKey == strenv(S3_SECRET_KEY)) |
    .remoteRef.property) = "secret_access_key"
' "$externalsecret_remote_ref_root/observability/langfuse/externalsecret.yaml.j2"
set_fixture_layer_digest \
  "$externalsecret_remote_ref_root" "$externalsecret_remote_ref_fixture" observability/langfuse
if externalsecret_remote_ref_output="$($CHECK --root "$externalsecret_remote_ref_root" \
  --fixture "$externalsecret_remote_ref_fixture" --contract "$CONTRACT" 2>&1)"; then
  printf 'FAIL: authoritative ExternalSecret mirror changed a referenced S3 remoteRef property\n' >&2
  exit 1
fi
printf '%s\n' "$externalsecret_remote_ref_output" | \
  rg -q 'externalsecret.yaml.j2: remoteRef key/property mismatch for langfuse-app-secrets/LANGFUSE_S3_BATCH_EXPORT_ACCESS_KEY_ID' || {
    printf 'FAIL: ExternalSecret remoteRef mutation did not report the source projection drift\n' >&2
    exit 1
  }

claim_fixture="$TEMP_ROOT/claim-class-drift.yaml"
cp "$FIXTURE" "$claim_fixture"
CLAIM_ID=langfuse-s3 yq e -i '
  (.layers[].claims[] | select(.rendered_claim_id == strenv(CLAIM_ID)) | .storage_class) =
    "longhorn-replica3"
' "$claim_fixture"
expect_fail "rendered claim class must match the retention contract" \
  --root "$baseline_root" --fixture "$claim_fixture" --contract "$CONTRACT"

duplicate_fixture="$TEMP_ROOT/duplicate-claim.yaml"
cp "$FIXTURE" "$duplicate_fixture"
CONTRACT_ID=woodpecker-agent-config yq e -i '
  (.layers[].claims[] | select(.contract_id == strenv(CONTRACT_ID)) | .rendered_claim_id) =
    "woodpecker-server/data"
' "$duplicate_fixture"
expect_fail "duplicate rendered claim identity cannot mask an omission" \
  --root "$baseline_root" --fixture "$duplicate_fixture" --contract "$CONTRACT"

omitted_ref_fixture="$TEMP_ROOT/omitted-secret-ref.yaml"
cp "$FIXTURE" "$omitted_ref_fixture"
yq e -i 'del(.layers[] | select(.path == "observability/langfuse") | .secret_references[0])' \
  "$omitted_ref_fixture"
expect_fail "declared reference count catches projection omissions" \
  --root "$baseline_root" --fixture "$omitted_ref_fixture" --contract "$CONTRACT"

chart_root="$TEMP_ROOT/chart-version-drift"
make_repo_fixture "$chart_root"
chart_fixture="$TEMP_ROOT/chart-version-drift.yaml"
cp "$FIXTURE" "$chart_fixture"
yq e -i '.helmCharts[] |= select(.name == "woodpecker").version = "3.6.6"' \
  "$chart_root/platform/woodpecker/kustomization.yaml"
set_fixture_layer_digest "$chart_root" "$chart_fixture" platform/woodpecker
expect_fail "chart pin drift requires reviewed package provenance" \
  --root "$chart_root" --fixture "$chart_fixture" --contract "$CONTRACT"

printf 'PASS: retention render projection mutation tests\n'
