#!/usr/bin/env bash
# Regression for KVAL-01: concurrent Kustomize Helm inflation must never write
# into or collide inside Argo's shared cached Git checkout.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
wrapper="$repo_root/bootstrap/argocd/scripts/hermetic-kustomize"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

fixture_git() {
  # pre-commit exports GIT_INDEX_FILE for the parent repository. Strip all
  # repository-routing variables before touching the synthetic checkout.
  env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE git "$@"
}

fixture_test() {
  local temp_root fixture fake output_a output_b
  temp_root=$(mktemp -d "${TMPDIR:-/tmp}/test-hermetic-kustomize.XXXXXX")
  trap 'rm -rf -- "$temp_root"' RETURN
  fixture="$temp_root/repo"
  mkdir -p "$fixture/layer"
  fixture_git -C "$temp_root" init -q repo
  printf 'expected rendered output\n' >"$fixture/layer/fixture.txt"
  fixture_git -C "$fixture" add layer/fixture.txt
  # Do not inherit the operator's globally installed pre-commit template into
  # this synthetic repository (and never recurse into this repository's hook).
  fixture_git -C "$fixture" -c core.hooksPath=/dev/null \
    -c user.name=test -c user.email=test.invalid \
    commit -qm fixture

  fake="$temp_root/fake-kustomize"
  cp "$repo_root/scripts/fixtures/fake-kustomize" "$fake"
  chmod 0555 "$fake"
  output_a="$temp_root/a.yaml"
  output_b="$temp_root/b.yaml"

  HERMETIC_KUSTOMIZE_REAL="$fake" "$wrapper" build --enable-helm "$fixture/layer" >"$output_a" &
  local first_pid=$!
  HERMETIC_KUSTOMIZE_REAL="$fake" "$wrapper" build "$fixture/layer" --enable-helm >"$output_b" &
  local second_pid=$!
  wait "$first_pid"
  wait "$second_pid"

  cmp -s "$output_a" "$output_b" || fail "parallel renders were not byte-identical"
  cmp -s "$output_a" "$fixture/layer/fixture.txt" || fail "render output was unexpected"
  [[ ! -e "$fixture/layer/charts" ]] || fail "render wrote charts/ into the source checkout"
  [[ -z "$(fixture_git -C "$fixture" status --porcelain --untracked-files=all)" ]] || \
    fail "render changed the source checkout"

  HERMETIC_KUSTOMIZE_REAL="$fake" "$wrapper" version | grep -qx 'fake-kustomize v1' || \
    fail "non-build subcommands were not delegated unchanged"
  trap - RETURN
  rm -rf -- "$temp_root"
  echo "PASS: hermetic Kustomize fixture renders concurrently without source mutation"
}

integration_test() {
  local layer=${1:-infrastructure/clickhouse-operator}
  local temp_root before after first_pid second_pid
  [[ -f "$repo_root/$layer/kustomization.yaml" ]] || fail "not a Kustomize layer: $layer"
  command -v kustomize >/dev/null || fail "kustomize is required for integration mode"
  command -v helm >/dev/null || fail "helm is required for integration mode"

  temp_root=$(mktemp -d "${TMPDIR:-/tmp}/test-hermetic-kustomize-integration.XXXXXX")
  trap 'rm -rf -- "$temp_root"' RETURN
  before=$(git -C "$repo_root" status --porcelain --untracked-files=all)

  HERMETIC_KUSTOMIZE_REAL=$(command -v kustomize) \
    "$wrapper" build --enable-helm "$repo_root/$layer" >"$temp_root/a.yaml" &
  first_pid=$!
  HERMETIC_KUSTOMIZE_REAL=$(command -v kustomize) \
    "$wrapper" build "$repo_root/$layer" --enable-helm >"$temp_root/b.yaml" &
  second_pid=$!
  wait "$first_pid"
  wait "$second_pid"

  cmp -s "$temp_root/a.yaml" "$temp_root/b.yaml" || \
    fail "parallel integration renders were not byte-identical"
  [[ -s "$temp_root/a.yaml" ]] || fail "integration render was empty"
  after=$(git -C "$repo_root" status --porcelain --untracked-files=all)
  [[ "$after" == "$before" ]] || fail "integration render changed the source checkout"
  [[ ! -e "$repo_root/$layer/charts" ]] || fail "integration render left charts/ in source"

  trap - RETURN
  rm -rf -- "$temp_root"
  echo "PASS: $layer rendered twice concurrently, byte-identically, without source mutation"
}

case "${1:-}" in
  "") fixture_test ;;
  --integration) integration_test "${2:-}" ;;
  *) fail "usage: $0 [--integration [layer]]" ;;
esac
