#!/usr/bin/env bash
# Require the least-privilege MinIO ingress path used by Langfuse S3 clients.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLICY_REL="infrastructure/minio-on-nas/networkpolicy.yaml"
FIXTURE="$SCRIPT_DIR/fixtures/retention-rendered-projection.yaml"

usage() {
  printf 'Usage: %s [--root DIR] [--fixture FILE]\n' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      REPO_ROOT="$(cd "${2:?--root requires a directory}" && pwd)"
      shift 2
      ;;
    --fixture)
      fixture_arg="${2:?--fixture requires a file}"
      FIXTURE="$(cd "$(dirname "$fixture_arg")" && pwd)/$(basename "$fixture_arg")"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v yq >/dev/null 2>&1 || { printf 'ERROR: yq is required\n' >&2; exit 2; }
policy_file="$REPO_ROOT/$POLICY_REL"
[ -f "$policy_file" ] || { printf 'ERROR: missing %s\n' "$policy_file" >&2; exit 2; }
[ -f "$FIXTURE" ] || { printf 'ERROR: missing %s\n' "$FIXTURE" >&2; exit 2; }

strip_yq_stream_markers() {
  awk 'NF && $0 != "---" && $0 != "null"'
}

policy_count="$(yq e -r '
  select(.kind == "NetworkPolicy" and .metadata.namespace == "minio-on-nas" and
    .metadata.name == "minio-allow") | .metadata.name
' "$policy_file" | strip_yq_stream_markers | wc -l | tr -d ' ')"
[ "$policy_count" -eq 1 ] || {
  printf 'ERROR: expected exactly one NetworkPolicy minio-on-nas/minio-allow, found %s\n' \
    "$policy_count" >&2
  exit 1
}

allow_all_peer_count="$(yq ea -r '
  select(.kind == "NetworkPolicy" and .metadata.namespace == "minio-on-nas" and
    .metadata.name == "minio-allow") |
  [.spec.ingress[]? | .from[]? |
   select((.ipBlock == null) and
          (((.namespaceSelector.matchLabels // {}) | length) == 0) and
          (((.namespaceSelector.matchExpressions // []) | length) == 0) and
          (((.podSelector.matchLabels // {}) | length) == 0) and
          (((.podSelector.matchExpressions // []) | length) == 0))] | length
' "$policy_file" | strip_yq_stream_markers)"
[ "$allow_all_peer_count" -eq 0 ] || {
  printf 'ERROR: %s contains %s ingress peer(s) that select every namespace and pod\n' \
    "$POLICY_REL" "$allow_all_peer_count" >&2
  exit 1
}

# LabelSelector maps with empty nested matchLabels and matchExpressions are
# semantically empty even though their top-level YAML maps have keys. Also
# reject a second peer that selects the Langfuse namespace by an equivalent
# immutable-name matchExpression while leaving its pod selector unrestricted.
langfuse_namespace_wide_peer_count="$(yq ea -r '
  select(.kind == "NetworkPolicy" and .metadata.namespace == "minio-on-nas" and
    .metadata.name == "minio-allow") |
  [.spec.ingress[]? | .from[]? |
   select((.ipBlock == null) and
          (((.podSelector.matchLabels // {}) | length) == 0) and
          (((.podSelector.matchExpressions // []) | length) == 0)) |
   select(
     (.namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "langfuse") or
     (([.namespaceSelector.matchExpressions[]? |
        select(.key == "kubernetes.io/metadata.name") |
        select(
          (.operator == "Exists") or
          ((.operator == "In") and
           (([.values[]? | select(. == "langfuse")] | length) > 0)) or
          ((.operator == "NotIn") and
           (([.values[]? | select(. == "langfuse")] | length) == 0))
        )] | length) > 0)
   )] | length
' "$policy_file" | strip_yq_stream_markers)"
[ "$langfuse_namespace_wide_peer_count" -eq 0 ] || {
  printf 'ERROR: %s contains %s ingress peer(s) that admit every pod in the Langfuse namespace\n' \
    "$POLICY_REL" "$langfuse_namespace_wide_peer_count" >&2
  exit 1
}

allow_all_rule_count="$(yq ea -r '
  select(.kind == "NetworkPolicy" and .metadata.namespace == "minio-on-nas" and
    .metadata.name == "minio-allow") |
  [.spec.ingress[]? | select(((.from // []) | length) == 0)] | length
' "$policy_file" | strip_yq_stream_markers)"
[ "$allow_all_rule_count" -eq 0 ] || {
  printf 'ERROR: %s contains %s ingress rule(s) with no source constraint\n' \
    "$POLICY_REL" "$allow_all_rule_count" >&2
  exit 1
}

langfuse_rules="$(yq e -r '
  select(.kind == "NetworkPolicy" and .metadata.namespace == "minio-on-nas" and
    .metadata.name == "minio-allow") |
  .spec.ingress[]? |
  select([.from[]? | .namespaceSelector.matchLabels."kubernetes.io/metadata.name" == "langfuse"] | any) |
  [(.from | length),
   (.from[0].namespaceSelector.matchLabels | length),
   .from[0].namespaceSelector.matchLabels."kubernetes.io/metadata.name",
   ((.from[0].podSelector.matchLabels // {}) | length),
   (.from[0].podSelector.matchExpressions | length),
   .from[0].podSelector.matchExpressions[0].key,
   .from[0].podSelector.matchExpressions[0].operator,
   (.from[0].podSelector.matchExpressions[0].values | sort | join(",")),
   (.ports | length),
   .ports[0].port,
   .ports[0].protocol] | @tsv
' "$policy_file" | strip_yq_stream_markers)"

rule_count="$(printf '%s\n' "$langfuse_rules" | awk 'NF' | wc -l | tr -d ' ')"
[ "$rule_count" -eq 1 ] || {
  printf 'ERROR: expected exactly one Langfuse ingress rule in %s, found %s\n' \
    "$POLICY_REL" "$rule_count" >&2
  exit 1
}

expected_rule=$'1\t1\tlangfuse\t0\t1\tapp.kubernetes.io/component\tIn\tweb,worker\t1\t9000\tTCP'
[ "$langfuse_rules" = "$expected_rule" ] || {
  printf 'ERROR: Langfuse ingress must be one combined namespace+component peer for web/worker on TCP/9000\n' >&2
  printf 'ERROR: observed structural tuple: %s\n' "$langfuse_rules" >&2
  exit 1
}

rendered_selectors="$(yq e -r '
  .layers[] | select(.path == "observability/langfuse") | .pod_selectors[]? |
  select(.workload_kind == "Deployment" and .label_key == "app.kubernetes.io/component") |
  [.workload_name, .label_value] | @tsv
' "$FIXTURE" | strip_yq_stream_markers | LC_ALL=C sort)"
expected_selectors=$'langfuse-web\tweb\nlangfuse-worker\tworker'
[ "$rendered_selectors" = "$expected_selectors" ] || {
  printf 'ERROR: render projection must bind the policy selectors to langfuse-web/web and langfuse-worker/worker\n' >&2
  exit 1
}

printf 'PASS: MinIO ingress admits only rendered Langfuse web/worker pods on TCP/9000.\n'
