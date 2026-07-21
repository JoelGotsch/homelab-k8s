#!/usr/bin/env bash
# Mutation tests for the Langfuse-to-MinIO ingress contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECK="$SCRIPT_DIR/check-langfuse-minio-ingress.sh"
FIXTURE="$SCRIPT_DIR/fixtures/retention-rendered-projection.yaml"
POLICY_REL="infrastructure/minio-on-nas/networkpolicy.yaml"

for required_tool in yq mktemp cp mkdir rm; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "$required_tool" >&2
    exit 2
  }
done

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/langfuse-minio-ingress-test.XXXXXX")"
cleanup() {
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/langfuse-minio-ingress-test.*) rm -rf "$TEMP_ROOT" ;;
    *) printf 'ERROR: refusing to remove unexpected temp path: %s\n' "$TEMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

make_policy_fixture() {
  local fixture_root="$1"
  mkdir -p "$fixture_root/$(dirname "$POLICY_REL")"
  cp "$REPO_ROOT/$POLICY_REL" "$fixture_root/$POLICY_REL"
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
make_policy_fixture "$baseline_root"
expect_pass "least-privilege ingress baseline" --root "$baseline_root" --fixture "$FIXTURE"

namespace_wide_root="$TEMP_ROOT/namespace-wide"
make_policy_fixture "$namespace_wide_root"
yq e -i '
  (select(.kind == "NetworkPolicy" and .metadata.name == "minio-allow") |
   .spec.ingress[] | select(.from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "langfuse") |
   .from[0]) |= del(.podSelector)
' "$namespace_wide_root/$POLICY_REL"
expect_fail "namespace-wide Langfuse access is rejected" \
  --root "$namespace_wide_root" --fixture "$FIXTURE"

split_peer_root="$TEMP_ROOT/split-peer"
make_policy_fixture "$split_peer_root"
yq e -i '
  (select(.kind == "NetworkPolicy" and .metadata.name == "minio-allow") |
   .spec.ingress[] | select(.from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "langfuse") |
   .from) += [{"podSelector": {"matchLabels": {"app.kubernetes.io/component": "web"}}}]
' "$split_peer_root/$POLICY_REL"
expect_fail "namespace and pod selectors cannot be split into OR peers" \
  --root "$split_peer_root" --fixture "$FIXTURE"

component_root="$TEMP_ROOT/extra-component"
make_policy_fixture "$component_root"
yq e -i '
  (select(.kind == "NetworkPolicy" and .metadata.name == "minio-allow") |
   .spec.ingress[] | select(.from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "langfuse") |
   .from[0].podSelector.matchExpressions[0].values) += ["agent"]
' "$component_root/$POLICY_REL"
expect_fail "unreviewed Langfuse component access is rejected" \
  --root "$component_root" --fixture "$FIXTURE"

port_root="$TEMP_ROOT/wrong-port"
make_policy_fixture "$port_root"
yq e -i '
  (select(.kind == "NetworkPolicy" and .metadata.name == "minio-allow") |
   .spec.ingress[] | select(.from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "langfuse") |
   .ports[0].port) = 9001
' "$port_root/$POLICY_REL"
expect_fail "only MinIO API TCP/9000 is admitted" --root "$port_root" --fixture "$FIXTURE"

selector_fixture="$TEMP_ROOT/render-selector-drift.yaml"
cp "$FIXTURE" "$selector_fixture"
yq e -i '
  (.layers[] | select(.path == "observability/langfuse") | .pod_selectors[] |
   select(.workload_name == "langfuse-worker") | .label_value) = "jobs"
' "$selector_fixture"
expect_fail "policy selector must match the reviewed chart projection" \
  --root "$baseline_root" --fixture "$selector_fixture"

printf 'PASS: Langfuse MinIO ingress mutation tests\n'
