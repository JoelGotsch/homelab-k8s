#!/usr/bin/env bash
# check-kyverno-policy-tests.sh — run the Kyverno CLI test suites under
# infrastructure/kyverno/policies/testdata/*/ against the CEL policies in
# infrastructure/kyverno/policies/cel/, with a CLI pinned to the engine version.
#
# WHY A PINNED CLI
#   The CLI compiles CEL with the same compiler the admission controller uses
#   (verified 2026-09-14: `resource.List(...).items.filter(...)` was rejected
#   identically by both — "expression of type 'any' cannot be range of a
#   comprehension"), and it evaluates mutations with the same runtime rules
#   (an ApplyConfiguration on an atomic list fails here with the same "may not
#   mutate atomic arrays" the cluster would raise at the first Pod). A CLI of
#   another version tests another engine. Pin: policies/testdata/cli-pin.env.
#
# WHAT "GREEN" MEANS
#   Every kyverno-test.yaml passed AND at least one test ran in each suite
#   (`--require-tests`). Deprecation warnings are errors, so a kyverno.io/v1
#   ClusterPolicy cannot slip back into the suites unnoticed.
#
# WHAT IT DOES NOT PROVE
#   That a policy evaluates on the cluster. The 2026-08-02 revert (7b1e30e) is
#   the reference: a policy can compile, report Ready and enforce nothing. The
#   cluster proof is the PolicyReport fail set + kyverno_policy_results_total,
#   per policies/README.md "Proving a policy evaluates".
#
# EXIT
#   0 all suites green; 1 a test failed; 2 environment (no CLI, pin mismatch).
set -euo pipefail
repo_root=$(git rev-parse --show-toplevel)
tests_dir="$repo_root/infrastructure/kyverno/policies/testdata"
pin="$tests_dir/cli-pin.env"
kustomization="$repo_root/infrastructure/kyverno/kustomization.yaml"

fail() { echo "check-kyverno-policy-tests: FAIL: $*" >&2; exit 1; }
envfail() { echo "check-kyverno-policy-tests: ENV: $*" >&2; exit 2; }

# shellcheck disable=SC1090
source "$pin"
: "${KYVERNO_CHART_VERSION:?}" "${KYVERNO_CLI_VERSION:?}"

# 1. The pin pair must still match the chart the layer pins.
chart_pinned=$(awk '/^helmCharts:/{f=1} f && /version:/{gsub(/"/,"",$2); print $2; exit}' "$kustomization")
[[ "$chart_pinned" == "$KYVERNO_CHART_VERSION" ]] ||
  fail "kustomization pins kyverno chart $chart_pinned but tests/cli-pin.env pairs $KYVERNO_CHART_VERSION with CLI $KYVERNO_CLI_VERSION — look up the new chart's appVersion and bump both lines"

# 1b. When the vendored chart is present locally (infrastructure/kyverno/charts/
#     is gitignored, so it may not be), its Chart.yaml appVersion is the
#     authoritative engine version — it must equal the CLI pin.
chart_yaml="$repo_root/infrastructure/kyverno/charts/kyverno-$KYVERNO_CHART_VERSION/kyverno/Chart.yaml"
if [[ -f "$chart_yaml" ]]; then
  app_version=$(awk -F': *' '/^appVersion:/{print $2; exit}' "$chart_yaml")
  [[ "$app_version" == "$KYVERNO_CLI_VERSION" ]] ||
    fail "vendored chart $KYVERNO_CHART_VERSION has appVersion $app_version but tests/cli-pin.env pins CLI $KYVERNO_CLI_VERSION — bump KYVERNO_CLI_VERSION"
fi

# 2. Resolve a CLI of exactly the pinned version: PATH, then cache, then download.
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/homelab/kyverno-cli/$KYVERNO_CLI_VERSION"
version_of() { "$1" version 2>/dev/null | awk -F': *' '/^Version/{print $2; exit}'; }
kyverno_bin=""
if command -v kyverno >/dev/null 2>&1 && [[ "v$(version_of kyverno)" == "$KYVERNO_CLI_VERSION" ]]; then
  kyverno_bin=$(command -v kyverno)
elif [[ -x "$cache_dir/kyverno" && "v$(version_of "$cache_dir/kyverno")" == "$KYVERNO_CLI_VERSION" ]]; then
  kyverno_bin="$cache_dir/kyverno"
else
  os=$(uname -s | tr '[:upper:]' '[:lower:]'); arch=$(uname -m)
  case "$arch" in aarch64) arch=arm64;; amd64) arch=x86_64;; esac
  asset="kyverno-cli_${KYVERNO_CLI_VERSION}_${os}_${arch}.tar.gz"
  base="https://github.com/kyverno/kyverno/releases/download/${KYVERNO_CLI_VERSION}"
  echo "check-kyverno-policy-tests: fetching $asset into $cache_dir (no kyverno $KYVERNO_CLI_VERSION on PATH)" >&2
  mkdir -p "$cache_dir"; tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/$asset" "$base/$asset" || envfail "download of $asset failed"
  curl -fsSL -o "$tmp/checksums.txt" "$base/checksums.txt" || envfail "download of checksums.txt failed"
  want=$(awk -v a="$asset" '$2==a{print $1}' "$tmp/checksums.txt"); [[ -n "$want" ]] || envfail "$asset not in checksums.txt"
  got=$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')
  [[ "$got" == "$want" ]] || envfail "checksum mismatch for $asset: got $got want $want"
  tar -xzf "$tmp/$asset" -C "$cache_dir" kyverno
  kyverno_bin="$cache_dir/kyverno"
  [[ "v$(version_of "$kyverno_bin")" == "$KYVERNO_CLI_VERSION" ]] || envfail "downloaded CLI reports $(version_of "$kyverno_bin")"
fi

# 3. Run every suite. The suites reference ../../cel/<policy>.yaml, i.e. the
#    committed policy files themselves — never copies.
rc=0; ran=0
for suite in "$tests_dir"/*/; do
  [[ -f "$suite/kyverno-test.yaml" ]] || continue
  ran=$((ran+1))
  if ! out=$("$kyverno_bin" test "$suite" --require-tests --warnings-as-errors --remove-color 2>&1); then
    echo "$out" | tail -40 >&2; echo "check-kyverno-policy-tests: suite $(basename "$suite") FAILED" >&2; rc=1
  else
    echo "check-kyverno-policy-tests: $(basename "$suite"): $(echo "$out" | grep -E '^Test Summary' | tail -1)"
  fi
done
[[ $ran -gt 0 ]] || fail "no suites found under $tests_dir"
exit $rc
