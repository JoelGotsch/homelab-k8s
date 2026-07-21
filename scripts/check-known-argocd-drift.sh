#!/usr/bin/env bash
# Keep API-server/controller defaults from turning healthy Argo applications
# permanently OutOfSync while still surfacing behavior-changing drift.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
applicationset="$repo_root/bootstrap/applicationsets/infrastructure.yaml"
policy_dir="$repo_root/infrastructure/kyverno/policies"
argocd_cm="$repo_root/bootstrap/argocd/patches/argocd-cm.yaml"
argocd_cmd_params="$repo_root/bootstrap/argocd/patches/argocd-cmd-params.yaml"
storageclasses="$repo_root/infrastructure/csi-rclone/storageclasses.yaml"
namespace_limits="$repo_root/components/first-party-namespace/limitrange.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v yq >/dev/null || fail "yq is required"
command -v rg >/dev/null || fail "rg is required"

[[ $(yq '.data."controller.diff.server.side"' "$argocd_cmd_params") == true ]] ||
  fail "Argo CD server-side diff must use controller.diff.server.side in cmd params"
if rg -q 'resource\.compareOptions|serverSideDiff:' "$argocd_cm"; then
  fail "argocd-cm contains the obsolete/non-functional server-side diff shape"
fi
if rg -q 'resource\.customizations\.ignoreDifferences\.kyverno\.io_ClusterPolicy' \
  "$argocd_cm"; then
  fail "top-level Kyverno policy behavior must not be hidden globally"
fi
if rg -q 'resource\.customizations\.ignoreDifferences\.storage\.k8s\.io_StorageClass' \
  "$argocd_cm"; then
  fail "immutable StorageClass parameters must be explicit, not globally ignored"
fi

storageclass_count=$(yq ea '[select(.kind == "StorageClass")] | length' "$storageclasses")
explicit_storageclass_count=$(yq ea '[select(.kind == "StorageClass") |
  select(.parameters.allow_other == "true" and .parameters.uid == "0" and
    .parameters.gid == "0")] | length' "$storageclasses")
[[ "$storageclass_count" -gt 0 && "$explicit_storageclass_count" == "$storageclass_count" ]] ||
  fail "every rclone StorageClass must declare its immutable allow_other/uid/gid values"

[[ $(yq '[.spec.limits[] | select(.type == "PersistentVolumeClaim" and
  .min.storage == "100Mi" and (has("max") | not))] | length' "$namespace_limits") == 1 ]] ||
  fail "shared PVC LimitRange must keep its floor without capping NAS claims"

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
[[ $(yq -o=json -I=0 '.imagePullSecrets' "$clickhouse_values") == '[]' ]] ||
  fail "remove the paired imagePullSecrets patch before configuring it"
[[ $(yq -o=json -I=0 '.nodeSelector' "$clickhouse_values") == '{}' ]] ||
  fail "remove the paired nodeSelector patch before configuring it"
[[ $(yq -o=json -I=0 '.tolerations' "$clickhouse_values") == '[]' ]] ||
  fail "remove the paired tolerations patch before configuring it"
[[ $(yq -o=json -I=0 '.topologySpreadConstraints' "$clickhouse_values") == '[]' ]] ||
  fail "remove the paired topologySpreadConstraints patch before configuring it"

required_ignores=(
  '.spec.rules[].skipBackgroundRequests'
  '.spec.rules[].validate.allowExistingViolations'
  '.spec.rules[].verifyImages[].attestors[].entries[].keys.signatureAlgorithm'
  '/metadata/labels'
)
for expression in "${required_ignores[@]}"; do
  rg -Fq -- "$expression" "$applicationset" ||
    fail "infrastructure ApplicationSet lost narrow ignore: $expression"
done

if rg -n '(^|[[:space:]])(skipBackgroundRequests|allowExistingViolations):[[:space:]]+false' \
  "$policy_dir"; then
  fail "an explicit false value is hidden by infra-kyverno ignoreDifferences"
fi

required_clickhouse_removals=(
  '/spec/template/spec/imagePullSecrets'
  '/spec/template/spec/nodeSelector'
  '/spec/template/spec/tolerations'
  '/spec/template/spec/topologySpreadConstraints'
)
for pointer in "${required_clickhouse_removals[@]}"; do
  rg -Fq -- "path: $pointer" "$clickhouse_kustomization" ||
    fail "ClickHouse chart-default removal is missing: $pointer"
done

kyverno_policy_crds=(
  deletingpolicies.policies.kyverno.io
  generatingpolicies.policies.kyverno.io
  imagevalidatingpolicies.policies.kyverno.io
  mutatingpolicies.policies.kyverno.io
  namespaceddeletingpolicies.policies.kyverno.io
  namespacedgeneratingpolicies.policies.kyverno.io
  namespacedimagevalidatingpolicies.policies.kyverno.io
  namespacedmutatingpolicies.policies.kyverno.io
  namespacedvalidatingpolicies.policies.kyverno.io
  policyexceptions.policies.kyverno.io
  validatingpolicies.policies.kyverno.io
)
for crd in "${kyverno_policy_crds[@]}"; do
  rg -Fq -- "name: $crd" "$applicationset" ||
    fail "missing exact conversion-default ignore for $crd"
done

echo "PASS: known Kyverno/ClickHouse API defaults are explicit or narrowly ignored"
