#!/usr/bin/env bash
# Mutation tests for the reviewed chart-render projection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/check-retention-render-fixtures.sh"
FIXTURE="$SCRIPT_DIR/fixtures/retention-rendered-projection.yaml"
CONTRACT="$SCRIPT_DIR/retention-contract.yaml"

for required_tool in yq mktemp cp mkdir rm; do
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

baseline_root="$TEMP_ROOT/baseline"
make_repo_fixture "$baseline_root"
expect_pass "reviewed projection baseline" \
  --root "$baseline_root" --fixture "$FIXTURE" --contract "$CONTRACT"

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
