#!/usr/bin/env bash
# Run promtool unit tests for every PrometheusRule that has them.
#
# Convention enforced:
# - A test file named `<name>_test.yaml` sits beside the PrometheusRule
#   manifest `<name>.yaml` it tests.
# - promtool cannot consume a PrometheusRule CR (it wants a bare
#   `groups:` document), so this script extracts `.spec.groups` into a
#   generated `rules.yaml` inside a temp dir, copies the test beside it,
#   and runs `promtool test rules` there. That is why the test files say
#   `rule_files: [rules.yaml]` rather than naming the manifest.
#
# Why this exists (2026-09-06): OpenBaoRaftSnapshotJobFailed was gated on
# `time() - kube_job_status_start_time < 3600`. That is a timer, not a
# condition — the alert fired at 03:12 and resolved *itself* at 04:04
# while the off-site OpenBao snapshot was still missing, so the operator
# got the vague 36 h staleness alert 11.5 h later instead of the precise
# one carrying the runbook link. The rule had been reviewed by reading
# it; reading it is what missed the bug. Alert predicates now get
# asserted the way code does.
#
# Per the operator's "script everything scriptable now" policy
# (memory feedback_script-don-t-defer.md): landing this as a hook now,
# not as a "wire it up when CI exists" note.
#
# Exit 0 = all tests pass, or no test files exist. Exit 1 = a failure, a
# malformed pairing, or a missing test dependency.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Vendored upstream charts ship their own rule files and tests; only
# first-party manifests are in scope.
#
# Listed into a temp file rather than a `mapfile` array (bash 4+; macOS
# /bin/bash is 3.2) and iterated with a redirect rather than a pipe, so the
# loop body runs in THIS shell and its `rc=1` actually escapes. A `find |
# while read` pipeline would set rc in a subshell and exit 0 with failures
# on screen — the "green while checking nothing" shape this repo tracks.
TEST_LIST="$(mktemp)"
trap 'rm -f "$TEST_LIST"' EXIT
find . -name '*_test.yaml' -not -path './.git/*' -not -path '*/charts/*' | sort > "$TEST_LIST"

if [ ! -s "$TEST_LIST" ]; then
  echo "check-prometheusrule-tests: no *_test.yaml files found; nothing to do"
  exit 0
fi

# yq is a hard dependency of the sibling checks in this directory, so it is the
# right tool for the extraction below. It replaced a `python3 -c "import yaml"`
# heredoc on 2026-09-06: PyYAML is not in macOS system python and not in
# Homebrew's, and the hook only worked because an unrelated project's direnv venv
# happened to be first on PATH. Under `pre-commit` (its own environment) or on
# any other machine it would have died on ModuleNotFoundError — a hook whose
# dependency is satisfied by accident is a hook that will stop working without
# anyone changing it.
if ! command -v yq >/dev/null 2>&1; then
  echo "check-prometheusrule-tests: yq is required to extract .spec.groups" >&2
  exit 1
fi

if ! command -v promtool >/dev/null 2>&1; then
  # Fail loudly rather than skipping silently: a check that quietly
  # passes when its tool is absent is the exact "green while checking
  # nothing" failure this repo tracks in lessons.md.
  cat >&2 <<'EOF'
check-prometheusrule-tests: promtool is NOT installed, so alert-rule tests
did not run. This is a hard failure, not a skip — a rule test that silently
passes when the runner is missing is worse than no test.

Install it (pin to the cluster's Prometheus version; v3.13.1 as of 2026-09-06):

  V=3.13.1
  curl -sSLO "https://github.com/prometheus/prometheus/releases/download/v${V}/prometheus-${V}.darwin-arm64.tar.gz"
  curl -sSL  "https://github.com/prometheus/prometheus/releases/download/v${V}/sha256sums.txt" \
    | grep "prometheus-${V}.darwin-arm64.tar.gz" | shasum -a 256 -c -
  tar xzf "prometheus-${V}.darwin-arm64.tar.gz"
  # then put ./prometheus-${V}.darwin-arm64/promtool on PATH
EOF
  exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -f "$TEST_LIST"; rm -rf "$WORK_DIR"' EXIT

rc=0
tested=0
while IFS= read -r test_file; do
  [ -n "$test_file" ] || continue
  manifest="${test_file%_test.yaml}.yaml"
  if [ ! -f "$manifest" ]; then
    echo "FAIL $test_file: no sibling manifest $manifest" >&2
    rc=1
    continue
  fi

  # One clean subdir per test so `rule_files: [rules.yaml]` resolves and
  # concurrent manifests cannot see each other's generated rules.
  case_dir="$WORK_DIR/$tested"
  mkdir -p "$case_dir"

  # Extract .spec.groups into the bare `groups:` document promtool wants. A
  # PrometheusRule with no groups is a bug in the manifest, not an empty test
  # run, so it fails rather than producing an empty rules file that every test
  # would then vacuously not match.
  if ! yq -e '.spec.groups | select(. != null and length > 0)' "$manifest" \
      >/dev/null 2>&1; then
    echo "FAIL $manifest: no .spec.groups to test" >&2
    rc=1
    continue
  fi
  if ! yq '{"groups": .spec.groups}' "$manifest" > "$case_dir/rules.yaml"; then
    echo "FAIL $manifest: could not extract .spec.groups" >&2
    rc=1
    continue
  fi

  cp "$test_file" "$case_dir/test.yaml"

  echo "== $test_file (rules from $manifest)"
  if ! (cd "$case_dir" && promtool check rules rules.yaml >/dev/null && promtool test rules test.yaml); then
    echo "FAIL $test_file" >&2
    rc=1
  fi
  tested=$((tested + 1))
done < "$TEST_LIST"

if [ "$rc" -ne 0 ]; then
  echo "check-prometheusrule-tests: FAILED" >&2
else
  echo "check-prometheusrule-tests: all alert-rule tests pass"
fi
exit "$rc"
