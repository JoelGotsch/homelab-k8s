#!/usr/bin/env bash
# Compare every rendered Longhorn PVC/claim template with one fixture layer.
# Missing or empty storageClassName is always an error: it would silently bind
# to cluster-default behavior (or disable provisioning) outside the contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/retention-rendered-projection.yaml"
RENDERED=""
LAYER_PATH=""
QUIET=false

usage() {
  printf 'Usage: %s --rendered FILE --layer PATH [--fixture FILE] [--quiet]\n' "$0"
}

absolute_file() {
  local candidate="$1"
  printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd)" "$(basename "$candidate")"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --rendered)
      RENDERED="$(absolute_file "${2:?--rendered requires a file}")"
      shift 2
      ;;
    --layer)
      LAYER_PATH="${2:?--layer requires a path}"
      shift 2
      ;;
    --fixture)
      FIXTURE="$(absolute_file "${2:?--fixture requires a file}")"
      shift 2
      ;;
    --quiet)
      QUIET=true
      shift
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

for required_tool in yq awk; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "$required_tool" >&2
    exit 2
  }
done
[ -n "$RENDERED" ] && [ -f "$RENDERED" ] || { printf 'ERROR: rendered file is required\n' >&2; exit 2; }
[ -n "$LAYER_PATH" ] || { printf 'ERROR: layer path is required\n' >&2; exit 2; }
[ -f "$FIXTURE" ] || { printf 'ERROR: fixture not found: %s\n' "$FIXTURE" >&2; exit 2; }

problems=0
explicit_non_longhorn=0
declare -A fixture_claims=()
declare -A actual_longhorn_claims=()
declare -A actual_claim_ids=()

error() {
  printf 'ERROR: %s\n' "$*" >&2
  problems=$((problems + 1))
}

strip_yq_stream_markers() {
  awk 'NF && $0 != "---" && $0 != "null"'
}

layer_count="$(LAYER_PATH="$LAYER_PATH" yq e -r \
  '[.layers[] | select(.path == strenv(LAYER_PATH))] | length' "$FIXTURE")"
[ "$layer_count" -eq 1 ] || {
  printf 'ERROR: expected exactly one fixture layer %s, found %s\n' "$LAYER_PATH" "$layer_count" >&2
  exit 1
}

while IFS=$'\t' read -r claim_id storage_class; do
  [ -n "$claim_id" ] || continue
  [ -z "${fixture_claims[$claim_id]:-}" ] || error "$FIXTURE: duplicate rendered claim '$claim_id'"
  case "$storage_class" in
    longhorn*) fixture_claims["$claim_id"]="$storage_class" ;;
    *) error "$FIXTURE: projected claim $claim_id must declare an explicit Longhorn class" ;;
  esac
done < <(
  LAYER_PATH="$LAYER_PATH" yq e -r '
    .layers[] | select(.path == strenv(LAYER_PATH)) | .claims[]? |
    [.rendered_claim_id, .storage_class] | @tsv
  ' "$FIXTURE" | strip_yq_stream_markers
)

while IFS=$'\t' read -r claim_id has_storage_class storage_class; do
  [ -n "$claim_id" ] || continue
  [ -z "${actual_claim_ids[$claim_id]:-}" ] || error "$LAYER_PATH render: duplicate claim identity '$claim_id'"
  actual_claim_ids["$claim_id"]=1
  if [ "$has_storage_class" != "true" ] || [ -z "$storage_class" ]; then
    error "$LAYER_PATH render: implicit default storage class is forbidden for '$claim_id' (storageClassName absent or empty)"
    continue
  fi
  case "$storage_class" in
    longhorn*) actual_longhorn_claims["$claim_id"]="$storage_class" ;;
    *) explicit_non_longhorn=$((explicit_non_longhorn + 1)) ;;
  esac
done < <(
  # `$owner` is a yq variable, not a shell interpolation.
  # shellcheck disable=SC2016
  yq e -r '
    (select(.kind == "PersistentVolumeClaim") |
      [.metadata.name, (.spec | has("storageClassName")), (.spec.storageClassName // "")] | @tsv),
    (select(.kind == "StatefulSet") | .metadata.name as $owner |
      .spec.volumeClaimTemplates[]? |
      [$owner + "/" + .metadata.name, (.spec | has("storageClassName")),
       (.spec.storageClassName // "")] | @tsv)
  ' "$RENDERED" | strip_yq_stream_markers
)

for claim_id in "${!fixture_claims[@]}"; do
  [ -n "${actual_longhorn_claims[$claim_id]:-}" ] || {
    error "$LAYER_PATH render: projected Longhorn claim '$claim_id' was not generated"
    continue
  }
  [ "${actual_longhorn_claims[$claim_id]}" = "${fixture_claims[$claim_id]}" ] || \
    error "$LAYER_PATH render: $claim_id class is '${actual_longhorn_claims[$claim_id]}', fixture says '${fixture_claims[$claim_id]}'"
done

for claim_id in "${!actual_longhorn_claims[@]}"; do
  [ -n "${fixture_claims[$claim_id]:-}" ] || \
    error "$LAYER_PATH render: generated Longhorn claim '$claim_id' is absent from the projection"
done

if [ "$problems" -ne 0 ]; then
  printf 'FAIL: rendered claim inventory found %d problem(s).\n' "$problems" >&2
  exit 1
fi

if [ "$QUIET" = false ]; then
  printf 'PASS: %s rendered claims match (%d Longhorn, %d explicit non-Longhorn).\n' \
    "$LAYER_PATH" "${#actual_longhorn_claims[@]}" "$explicit_non_longhorn"
fi
