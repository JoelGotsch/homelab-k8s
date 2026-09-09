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
  "$fixture/observability/falco-stack"

copy_pristine() {
  cp "$repo_root/scripts/temporary-notification-route-baseline.yaml" \
    "$fixture/scripts/temporary-notification-route-baseline.yaml"
  cp "$repo_root/observability/kube-prometheus-stack/alertmanager-config.yaml" \
    "$fixture/observability/kube-prometheus-stack/alertmanager-config.yaml"
  cp "$repo_root/observability/falco-stack/values.yaml" \
    "$fixture/observability/falco-stack/values.yaml"
  rm -f "$fixture/observability/kube-prometheus-stack/direct-signal-probe.yaml"
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

# Re-adding an Alertmanager Signal sink is the regression this guards. Since the
# ntfy-first migration the config has NO receiver with an approval-channel /
# signal-bridge webhook URL, so a route alone is undetectable by construction:
# the checker classifies routes only by whether their receiver is a Signal sink.
# The mutation therefore adds the receiver AND a route to it, which is the shape
# a real regression takes. Receivers are compared before routes, so the receiver
# inventory is what reports first.
yq -i '.spec.receivers += [{"name": "approval-channel-alert", "webhookConfigs": [{"url": "http://approval-channel.approval-channel.svc.cluster.local:8080/v1/alert", "sendResolved": false}]}]' \
  "$fixture/observability/kube-prometheus-stack/alertmanager-config.yaml"
yq -i '.spec.route.routes += [{"matchers": [{"name": "severity", "value": "critical"}], "receiver": "approval-channel-alert", "groupWait": "5s", "groupInterval": "1m", "repeatInterval": "1h"}]' \
  "$fixture/observability/kube-prometheus-stack/alertmanager-config.yaml"
expect_failure "re-added Alertmanager operational Signal receiver + route" \
  "Alertmanager operational Signal receivers differs"

copy_pristine
yq -i '.falcosidekick.config.webhook.secondaryAddress = "http://ntfy-e2ee-relay.ntfy-e2ee-relay.svc.cluster.local:8000/secondary"' \
  "$fixture/observability/falco-stack/values.yaml"
expect_failure "new incompatible custom-relay route" \
  "custom ntfy relay routes differs"

# The baseline has held no direct route since the superseded central
# signal-bridge copy was deleted (2026-09-09), so ANY executable /v2/send line in
# a tracked manifest is an expansion. A synthetic ConfigMap stands in for one.
copy_pristine
cat >"$fixture/observability/kube-prometheus-stack/direct-signal-probe.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: direct-signal-probe
data:
  TEST_DIRECT_SIGNAL: 'curl "$SIGNAL_BRIDGE_URL/v2/send"'
EOF
git -C "$fixture" add -A
expect_failure "new direct operational Signal route" \
  "direct operational Signal routes differs"

echo "OK: notification-route guard rejects Alertmanager, custom-relay, and direct-Signal expansion."
