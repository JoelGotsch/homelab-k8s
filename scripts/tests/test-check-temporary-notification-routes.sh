#!/usr/bin/env bash
# Mutation tests for check-temporary-notification-routes.sh.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/scripts/check-temporary-notification-routes.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/notification-route-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT

mkdir -p \
  "$fixture/scripts" \
  "$fixture/observability/kube-prometheus-stack" \
  "$fixture/observability/falco-stack" \
  "$fixture/apps/signal-bridge"

copy_pristine() {
  cp "$repo_root/scripts/temporary-notification-route-baseline.yaml" \
    "$fixture/scripts/temporary-notification-route-baseline.yaml"
  cp "$repo_root/observability/kube-prometheus-stack/alertmanager-config.yaml" \
    "$fixture/observability/kube-prometheus-stack/alertmanager-config.yaml"
  cp "$repo_root/observability/falco-stack/values.yaml" \
    "$fixture/observability/falco-stack/values.yaml"
  cp "$repo_root/apps/signal-bridge/openbao-seal-watchdog-cronjob.yaml" \
    "$fixture/apps/signal-bridge/openbao-seal-watchdog-cronjob.yaml"
  git -C "$fixture" add -A
}

run_guard() {
  NOTIFICATION_ROUTE_REPO_ROOT="$fixture" \
    NOTIFICATION_ROUTE_BASELINE="$fixture/scripts/temporary-notification-route-baseline.yaml" \
    "$guard"
}

expect_failure() {
  local label="$1"
  local expected_message="$2"
  if run_guard >"$fixture/output" 2>&1; then
    echo "FAIL: mutation unexpectedly passed: $label" >&2
    exit 1
  fi
  if ! grep -Fq "$expected_message" "$fixture/output"; then
    echo "FAIL: mutation failed for the wrong reason: $label" >&2
    sed -n '1,120p' "$fixture/output" >&2
    exit 1
  fi
}

git -C "$fixture" init -q
copy_pristine
run_guard >/dev/null

# A duplicate route is still fan-out expansion and must not disappear under a
# set comparison.
yq -i '.spec.route.routes += [{"matchers": [{"name": "severity", "value": "critical"}], "receiver": "approval-channel-alert", "groupWait": "5s", "groupInterval": "1m", "repeatInterval": "1h"}]' \
  "$fixture/observability/kube-prometheus-stack/alertmanager-config.yaml"
expect_failure "new Alertmanager operational Signal route" \
  "Alertmanager operational Signal routes differs"

copy_pristine
yq -i '.falcosidekick.config.webhook.secondaryAddress = "http://ntfy-e2ee-relay.ntfy-e2ee-relay.svc.cluster.local:8000/secondary"' \
  "$fixture/observability/falco-stack/values.yaml"
expect_failure "new incompatible custom-relay route" \
  "custom ntfy relay routes differs"

copy_pristine
yq -i 'select(.kind == "ConfigMap" and .metadata.name == "openbao-seal-watchdog-config").data.TEST_DIRECT_SIGNAL = "curl $SIGNAL_BRIDGE_URL/v2/send"' \
  "$fixture/apps/signal-bridge/openbao-seal-watchdog-cronjob.yaml"
expect_failure "new direct operational Signal route" \
  "direct operational Signal routes differs"

echo "OK: notification-route guard rejects Alertmanager, custom-relay, and direct-Signal expansion."
