#!/usr/bin/env bash
# Contain the temporary P0-07 notification-route drift.
#
# The desired end state is ntfy for operational alerts and Signal for approval
# items plus an explicitly conditional ntfy-outage fallback. Existing
# unconditional operational Signal routes and the recipient-incompatible custom
# ntfy relay cannot be removed safely until receipt/fallback gates are proven,
# so this check freezes their exact current surface instead.
#
# Discovery is independent of the baseline:
#   1. Alertmanager webhook receivers targeting approval-channel/signal-bridge
#      are operational Signal sinks because Alertmanager cannot originate an
#      approval item. Their routes are compared by matcher + timing semantics.
#   2. Any configured YAML scalar targeting the custom ntfy-e2ee-relay service
#      is an incompatible custom-relay dependency. This includes dormant
#      Falcosidekick values so suspension cannot hide an unsafe resume path.
#   3. Any non-comment manifest line invoking /v2/send through signal-bridge is
#      a direct Signal send. A base URL alone is not a route, which keeps future
#      approval-service transport configuration distinguishable.
#
# Requires: mikefarah yq v4+, git, awk, diff.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="${NOTIFICATION_ROUTE_REPO_ROOT:-$(cd "$script_dir/.." && pwd)}"
baseline="${NOTIFICATION_ROUTE_BASELINE:-$repo_root/scripts/temporary-notification-route-baseline.yaml}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v yq >/dev/null 2>&1 || fail "yq not on PATH (mikefarah v4+ required)"
yq --version 2>&1 | grep -Eq 'mikefarah|version v[4-9]' \
  || fail "wrong yq variant: $(yq --version 2>&1 | head -1)"
command -v git >/dev/null 2>&1 || fail "git not on PATH"
[ -f "$baseline" ] || fail "baseline not found: $baseline"

cd "$repo_root"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "$repo_root is not a Git worktree"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/notification-route-check.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

expected="$tmpdir/expected"
actual="$tmpdir/actual"
mkdir -p "$expected" "$actual"

compare_inventory() {
  local label="$1"
  local expected_file="$2"
  local actual_file="$3"

  # Keep duplicates: adding a second identical route is still route expansion.
  LC_ALL=C sort "$expected_file" -o "$expected_file"
  LC_ALL=C sort "$actual_file" -o "$actual_file"
  if ! cmp -s "$expected_file" "$actual_file"; then
    echo "FAIL: $label differs from the exact reviewed baseline." >&2
    diff -u --label "reviewed-$label" --label "discovered-$label" \
      "$expected_file" "$actual_file" >&2 || true
    echo "Do not expand the baseline as a workaround. Classify the route, prove" >&2
    echo "the required ntfy receipt/fallback gate, and review the policy change." >&2
    return 1
  fi
}

# Baseline schema and marker integrity. IDs and markers are unique, every marker
# is present exactly once in its declared source file, and the policy remains a
# containment baseline rather than being re-described as steady state.
[ "$(yq -r '.kind' "$baseline")" = "TemporaryNotificationRouteBaseline" ] \
  || fail "unexpected baseline kind"
[ "$(yq -r '.spec.policy.state' "$baseline")" = "containment-only" ] \
  || fail "baseline must remain containment-only"

yq -r '.spec.reviewedDrift | .. |
  select(tag == "!!map" and has("id") and has("marker") and has("file")) |
  [.id, .marker, .file] | @tsv' "$baseline" >"$expected/markers"

marker_rows="$(wc -l <"$expected/markers" | tr -d ' ')"
unique_ids="$(cut -f1 "$expected/markers" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
unique_markers="$(cut -f2 "$expected/markers" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
[ "$marker_rows" -gt 0 ] || fail "baseline contains no reviewed drift entries"
[ "$marker_rows" -eq "$unique_ids" ] || fail "baseline drift IDs must be unique"
[ "$marker_rows" -eq "$unique_markers" ] || fail "baseline markers must be unique"

while IFS=$'\t' read -r id marker file; do
  [ -f "$file" ] || fail "$id declares missing source file: $file"
  count="$(grep -F -c "$marker" "$file" || true)"
  [ "$count" -eq 1 ] \
    || fail "$id marker must occur exactly once in $file (found $count): $marker"
done <"$expected/markers"

# Alertmanager operational Signal receiver inventory. Any Alertmanager webhook
# to approval-channel or signal-bridge is operational by source, regardless of
# receiver naming. This deliberately does not classify service-to-signal-bridge
# base URLs elsewhere as alert routes.
alertmanager_config="$(yq -r '.spec.reviewedDrift.alertmanager.config' "$baseline")"
[ -f "$alertmanager_config" ] || fail "Alertmanager config missing: $alertmanager_config"

yq -r '.spec.reviewedDrift.alertmanager.operationalSignalReceivers[]? |
  [.name, .url, (.sendResolved | tostring)] | @tsv' "$baseline" \
  | sed '/^[[:space:]]*$/d' >"$expected/alertmanager-receivers"

yq -r '.spec.receivers[] as $receiver | $receiver.webhookConfigs[]? |
  select(.url | test("^https?://(approval-channel|signal-bridge)\\.")) |
  [$receiver.name, .url, ((.sendResolved // false) | tostring)] | @tsv' \
  "$alertmanager_config" | sed '/^$/d' >"$actual/alertmanager-receivers"

compare_inventory "Alertmanager operational Signal receivers" \
  "$expected/alertmanager-receivers" "$actual/alertmanager-receivers"

# A full route fingerprint prevents a new fan-out, matcher broadening, timing
# change, or `continue` change from hiding behind an existing receiver name.
yq -r '.spec.reviewedDrift.alertmanager.operationalSignalRoutes[]? |
  [.receiver, ((.matchers // []) | to_json(0)), (.groupWait // ""),
   (.groupInterval // ""), (.repeatInterval // ""),
   ((.continue // false) | tostring)] | @tsv' "$baseline" \
  | sed '/^[[:space:]]*$/d' >"$expected/alertmanager-routes"

cut -f1 "$actual/alertmanager-receivers" | LC_ALL=C sort -u \
  >"$actual/alertmanager-receiver-names"
yq -r '.spec.route | .. |
  select(tag == "!!map" and has("receiver")) |
  [.receiver, ((.matchers // []) | to_json(0)), (.groupWait // ""),
   (.groupInterval // ""), (.repeatInterval // ""),
   ((.continue // false) | tostring)] | @tsv' "$alertmanager_config" \
  | while IFS=$'\t' read -r receiver rest; do
      if grep -Fqx "$receiver" "$actual/alertmanager-receiver-names"; then
        printf '%s\t%s\n' "$receiver" "$rest"
      fi
    done >"$actual/alertmanager-routes"

compare_inventory "Alertmanager operational Signal routes" \
  "$expected/alertmanager-routes" "$actual/alertmanager-routes"

# Custom-relay dependencies in configured desired-state YAML. A raw-line scan
# is deliberate: this repo contains Go-template YAML fixtures which are not
# valid input to yq until rendered. Excluding comment-only lines avoids treating
# the disabled Cloudflare example inside a ConfigMap block as a route. Dormant
# values are included so a suspended layer cannot resume with an unreviewed
# incompatible route.
yq -r '.spec.reviewedDrift.customRelayRoutes[]? | [.file, .url] | @tsv' \
  "$baseline" | sed '/^[[:space:]]*$/d' >"$expected/custom-relay-routes"
: >"$actual/custom-relay-routes"
while IFS= read -r file; do
  [ -f "$file" ] || continue
  [ "$file" = "scripts/temporary-notification-route-baseline.yaml" ] && continue
  awk '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line ~ /^#/ || line !~ /https?:\/\/ntfy-e2ee-relay\./) {
        next
      }
      match(line, /https?:\/\//)
      url = substr(line, RSTART)
      sub(/[[:space:]"'\''#].*$/, "", url)
      printf "%s\t%s\n", FILENAME, url
    }
  ' "$file" >>"$actual/custom-relay-routes"
done < <(git ls-files '*.yaml' '*.yml')

compare_inventory "custom ntfy relay routes" \
  "$expected/custom-relay-routes" "$actual/custom-relay-routes"

# Direct Signal sends embedded in manifest scripts. Comment-only references and
# transport base URLs are excluded; executable /v2/send invocations are exact-
# baselined. This leaves approval service configuration distinguishable from an
# unconditional operational send.
yq -r '.spec.reviewedDrift.directOperationalSignalRoutes[] |
  .file + "\t" + .expression' "$baseline" >"$expected/direct-signal-routes"
: >"$actual/direct-signal-routes"
while IFS= read -r file; do
  [ -f "$file" ] || continue
  [ "$file" = "scripts/temporary-notification-route-baseline.yaml" ] && continue
  awk '
    {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (line !~ /^#/ && line ~ /\/v2\/send/) {
        printf "%s\t%s\n", FILENAME, line
      }
    }
  ' "$file" >>"$actual/direct-signal-routes"
done < <(git ls-files '*.yaml' '*.yml')

compare_inventory "direct operational Signal routes" \
  "$expected/direct-signal-routes" "$actual/direct-signal-routes"

echo "OK: Alertmanager has no operational Signal/custom-relay route; the one app-owned direct watchdog route remains exactly contained."
