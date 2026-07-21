#!/usr/bin/env bash
# Keep API-server/controller defaults from turning healthy Argo applications
# permanently OutOfSync while still surfacing behavior-changing drift.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
applicationset="$repo_root/bootstrap/applicationsets/infrastructure.yaml"
policy_dir="$repo_root/infrastructure/kyverno/policies"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v yq >/dev/null || fail "yq is required"
command -v rg >/dev/null || fail "rg is required"

while IFS= read -r policy; do
  if yq '[.. | select(tag == "!!map" and has("apiCall")) | .apiCall |
    select(.method != "GET" and .method != "POST")] | length' "$policy" |
    rg -qv '^0$'; then
    fail "$policy has a context.apiCall without an explicit GET/POST method"
  fi
done < <(rg --files "$policy_dir" -g '*.yaml' | sort)

verify_policy="$policy_dir/verify-first-party-image-signature.yaml"
[[ $(yq '.spec.rules[].verifyImages[].useCache' "$verify_policy") == true ]] ||
  fail "image verification cache behavior must be explicit"
[[ $(yq '.spec.rules[].verifyImages[].attestors[].entries[].signatureAlgorithm' \
  "$verify_policy") == sha256 ]] ||
  fail "supported image-signature algorithm field must be explicit"

inline_secret_policy="$policy_dir/homelab-disallow-inline-secrets.yaml"
[[ $(yq '.spec.background' "$inline_secret_policy") == false ]] ||
  fail "inline-secret reporting must not require cluster-wide Secret reads"

kyverno_values="$repo_root/infrastructure/kyverno/values.yaml"
cnp_permissions=$(yq '[.reportsController.rbac.clusterRole.extraResources[] |
  select((.apiGroups | length) == 1 and .apiGroups[0] == "cilium.io" and
    (.resources | length) == 2 and
    .resources[0] == "ciliumnetworkpolicies" and
    .resources[1] == "ciliumclusterwidenetworkpolicies" and
    (.verbs | length) == 3 and .verbs[0] == "get" and
    .verbs[1] == "list" and .verbs[2] == "watch")] | length' "$kyverno_values")
[[ "$cnp_permissions" == 1 ]] ||
  fail "reports controller lacks exact read-only Cilium policy permissions"

clickhouse_values="$repo_root/infrastructure/clickhouse-operator/values.yaml"
clickhouse_kustomization="$repo_root/infrastructure/clickhouse-operator/kustomization.yaml"
[[ $(yq '.crdHook.enabled' "$clickhouse_values") == false ]] ||
  fail "redundant ClickHouse CRD hook must stay disabled"
[[ $(yq '.helmCharts[] | select(.name == "altinity-clickhouse-operator") |
  .includeCRDs' "$clickhouse_kustomization") == true ]] ||
  fail "ClickHouse chart CRDs must stay rendered under Argo ownership"

required_ignores=(
  '.spec.rules[].verifyImages[].attestors[].entries[].keys.signatureAlgorithm'
  '.spec.template.spec.imagePullSecrets | select(length == 0)'
  '.spec.template.spec.nodeSelector | select(length == 0)'
  '.spec.template.spec.tolerations | select(length == 0)'
  '.spec.template.spec.topologySpreadConstraints | select(length == 0)'
  '.spec.conversion | select(.strategy == "None")'
)
for expression in "${required_ignores[@]}"; do
  rg -Fq -- "$expression" "$applicationset" ||
    fail "infrastructure ApplicationSet lost narrow ignore: $expression"
done

echo "PASS: known Kyverno/ClickHouse API defaults are explicit or narrowly ignored"
