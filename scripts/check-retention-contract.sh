#!/usr/bin/env bash
# Static P0-08/KST-01 Longhorn lifecycle gate.
#
# The default contract deliberately covers only manifests owned by this
# repository. It never calls kubectl and never treats desired state as evidence
# about an existing PV. The checker is also repository-agnostic: an app repo can
# carry the same script and a repository-local contract, while a later workspace
# aggregate verifies that every registered source repository exposes one.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTRACT="$SCRIPT_DIR/retention-contract.yaml"

usage() {
  sed -n '2,9p' "$0" | sed -E 's/^# ?//'
  printf '\nUsage: %s [--root DIR] [--contract FILE]\n' "$0"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      REPO_ROOT="$(cd "${2:?--root requires a directory}" && pwd)"
      shift 2
      ;;
    --contract)
      contract_arg="${2:?--contract requires a file}"
      CONTRACT="$(cd "$(dirname "$contract_arg")" && pwd)/$(basename "$contract_arg")"
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

for required_tool in yq find sort awk; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "$required_tool" >&2
    exit 2
  }
done

[ -f "$CONTRACT" ] || {
  printf 'ERROR: retention contract not found: %s\n' "$CONTRACT" >&2
  exit 2
}

problems=0
checked_entries=0

error() {
  printf 'ERROR: %s\n' "$*" >&2
  problems=$((problems + 1))
}

strip_yq_stream_markers() {
  awk 'NF && $0 != "---" && $0 != "null"'
}

contract_version="$(yq e -r '.version // ""' "$CONTRACT")"
[ "$contract_version" = "1" ] || error "$CONTRACT: expected version 1, got '$contract_version'"

owner_repository="$(yq e -r '.owner_repository // ""' "$CONTRACT")"
[ -n "$owner_repository" ] || error "$CONTRACT: owner_repository is required"

declared_count="$(yq e -r '.declared_count // ""' "$CONTRACT")"
entry_count="$(yq e -r '.entries | length' "$CONTRACT")"
[ "$declared_count" = "$entry_count" ] || \
  error "$CONTRACT: declared_count=$declared_count but entries=$entry_count"

declare -A class_policy=()
declare -A entry_ids=()
declare -A declared_selectors=()
declare -A discovered_selectors=()

while IFS= read -r storage_class; do
  [ -n "$storage_class" ] || continue
  [ -z "${class_policy[$storage_class]:-}" ] || error "$CONTRACT: duplicate StorageClass '$storage_class'"
  class_policy["$storage_class"]="Delete"
done < <(yq e -r '.storage_classes.delete[]' "$CONTRACT" | strip_yq_stream_markers)

while IFS= read -r storage_class; do
  [ -n "$storage_class" ] || continue
  [ -z "${class_policy[$storage_class]:-}" ] || error "$CONTRACT: duplicate StorageClass '$storage_class'"
  class_policy["$storage_class"]="Retain"
done < <(yq e -r '.storage_classes.retain[]' "$CONTRACT" | strip_yq_stream_markers)

[ "${#class_policy[@]}" -gt 0 ] || error "$CONTRACT: StorageClass catalog is empty"

storageclass_source_rel="$(yq e -r '.storage_classes.source // ""' "$CONTRACT")"
if [ -n "$storageclass_source_rel" ]; then
  storageclass_source="$REPO_ROOT/$storageclass_source_rel"
  [ -f "$storageclass_source" ] || error "missing StorageClass catalog source: $storageclass_source_rel"
  if [ -f "$storageclass_source" ]; then
    for storage_class in "${!class_policy[@]}"; do
      expected_policy="${class_policy[$storage_class]}"
      actual_policies="$(
        STORAGE_CLASS="$storage_class" yq e -r \
          'select(.kind == "StorageClass" and .metadata.name == strenv(STORAGE_CLASS)) | .reclaimPolicy' \
          "$storageclass_source" | strip_yq_stream_markers
      )"
      actual_count="$(printf '%s\n' "$actual_policies" | awk 'NF' | wc -l | tr -d ' ')"
      [ "$actual_count" -eq 1 ] || {
        error "$storageclass_source_rel: expected exactly one StorageClass/$storage_class, found $actual_count"
        continue
      }
      [ "$actual_policies" = "$expected_policy" ] || \
        error "$storageclass_source_rel: StorageClass/$storage_class is '$actual_policies', contract says '$expected_policy'"
    done
  fi
fi

read_source_locator() {
  local source_file="$1"
  local value_path="$2"
  yq e -r \
    "$value_path | [documentIndex, (path | join(\".\")), .] | @tsv" \
    "$source_file" 2>/dev/null | strip_yq_stream_markers
}

for ((entry_index = 0; entry_index < entry_count; entry_index++)); do
  id="$(yq e -r ".entries[$entry_index].id // \"\"" "$CONTRACT")"
  source_rel="$(yq e -r ".entries[$entry_index].source.file // \"\"" "$CONTRACT")"
  value_path="$(yq e -r ".entries[$entry_index].source.value_path // \"\"" "$CONTRACT")"
  document_index="$(yq e -r ".entries[$entry_index].source.document_index // \"\"" "$CONTRACT")"
  selector_path="$(yq e -r ".entries[$entry_index].source.selector_path // \"\"" "$CONTRACT")"
  current_class="$(yq e -r ".entries[$entry_index].current_storage_class // \"\"" "$CONTRACT")"
  target_class="$(yq e -r ".entries[$entry_index].target_storage_class // \"\"" "$CONTRACT")"
  desired_policy="$(yq e -r ".entries[$entry_index].desired_reclaim_policy // \"\"" "$CONTRACT")"
  state="$(yq e -r ".entries[$entry_index].state // \"\"" "$CONTRACT")"
  migration_owner="$(yq e -r ".entries[$entry_index].migration_owner // \"\"" "$CONTRACT")"

  [ -n "$id" ] || { error "$CONTRACT: entry $entry_index has no id"; continue; }
  [ -z "${entry_ids[$id]:-}" ] || { error "$CONTRACT: duplicate entry id '$id'"; continue; }
  entry_ids["$id"]=1

  for required_path in workload namespace claim data_class data_value backup_tier rpo rto required_restore_test reason; do
    required_value="$(yq e -r ".entries[$entry_index].$required_path // \"\"" "$CONTRACT")"
    [ -n "$required_value" ] || error "$CONTRACT: $id is missing $required_path"
  done

  [ -n "$source_rel" ] || { error "$CONTRACT: $id has no source.file"; continue; }
  [ -n "$value_path" ] || { error "$CONTRACT: $id has no source.value_path"; continue; }
  [[ "$document_index" =~ ^[0-9]+$ ]] || {
    error "$CONTRACT: $id source.document_index must be a non-negative integer"
    continue
  }
  [ -n "$selector_path" ] || { error "$CONTRACT: $id has no source.selector_path"; continue; }
  [ -n "$current_class" ] || { error "$CONTRACT: $id has no current_storage_class"; continue; }
  [ -n "$target_class" ] || { error "$CONTRACT: $id has no target_storage_class"; continue; }
  [ -n "${class_policy[$current_class]:-}" ] || error "$CONTRACT: $id uses unknown current class '$current_class'"
  [ -n "${class_policy[$target_class]:-}" ] || error "$CONTRACT: $id uses unknown target class '$target_class'"
  case "$desired_policy" in Delete|Retain) ;; *) error "$CONTRACT: $id has invalid desired policy '$desired_policy'" ;; esac
  [ "${class_policy[$target_class]:-}" = "$desired_policy" ] || \
    error "$CONTRACT: $id target $target_class does not implement $desired_policy"

  expected_state="known-mismatch"
  [ "${class_policy[$current_class]:-}" = "$desired_policy" ] && expected_state="compliant"
  [ "$state" = "$expected_state" ] || \
    error "$CONTRACT: $id state is '$state', expected '$expected_state' from current and desired policies"
  if [ "$state" = "known-mismatch" ]; then
    [ -n "$migration_owner" ] && [ "$migration_owner" != "none" ] || \
      error "$CONTRACT: $id known mismatch requires a concrete migration_owner"
  else
    [ "$migration_owner" = "none" ] || \
      error "$CONTRACT: $id compliant entry must use migration_owner: none"
  fi

  source_file="$REPO_ROOT/$source_rel"
  [ -f "$source_file" ] || { error "$CONTRACT: $id source does not exist: $source_rel"; continue; }
  actual_locators="$(read_source_locator "$source_file" "$value_path")" || {
    error "$CONTRACT: $id could not evaluate $source_rel at $value_path"
    continue
  }
  actual_count="$(printf '%s\n' "$actual_locators" | awk 'NF' | wc -l | tr -d ' ')"
  [ "$actual_count" -eq 1 ] || {
    error "$CONTRACT: $id selector matched $actual_count values in $source_rel"
    continue
  }
  IFS=$'\t' read -r actual_document_index actual_selector_path actual_value <<<"$actual_locators"
  [ "$actual_document_index" = "$document_index" ] || \
    error "$CONTRACT: $id expected document $document_index in $source_rel, got $actual_document_index"
  [ "$actual_selector_path" = "$selector_path" ] || \
    error "$CONTRACT: $id expected path $selector_path in $source_rel, got '$actual_selector_path'"
  [ "$actual_value" = "$current_class" ] || \
    error "$CONTRACT: $id expected $current_class in $source_rel, got '$actual_value'; update or retire the contract in the same review"

  mirror_count="$(yq e -r ".entries[$entry_index].source.mirrors // [] | length" "$CONTRACT")"
  for ((mirror_index = 0; mirror_index < mirror_count; mirror_index++)); do
    mirror_rel="$(yq e -r ".entries[$entry_index].source.mirrors[$mirror_index]" "$CONTRACT")"
    mirror_file="$REPO_ROOT/$mirror_rel"
    [ -f "$mirror_file" ] || { error "$CONTRACT: $id mirror does not exist: $mirror_rel"; continue; }
    mirror_locators="$(read_source_locator "$mirror_file" "$value_path")" || {
      error "$CONTRACT: $id could not evaluate mirror $mirror_rel at $value_path"
      continue
    }
    mirror_value_count="$(printf '%s\n' "$mirror_locators" | awk 'NF' | wc -l | tr -d ' ')"
    [ "$mirror_value_count" -eq 1 ] || {
      error "$CONTRACT: $id mirror selector matched $mirror_value_count values in $mirror_rel"
      continue
    }
    IFS=$'\t' read -r mirror_document_index mirror_selector_path mirror_value <<<"$mirror_locators"
    [ "$mirror_document_index" = "$document_index" ] || \
      error "$CONTRACT: $id mirror expected document $document_index in $mirror_rel, got $mirror_document_index"
    [ "$mirror_selector_path" = "$selector_path" ] || \
      error "$CONTRACT: $id mirror expected path $selector_path in $mirror_rel, got '$mirror_selector_path'"
    [ "$mirror_value" = "$current_class" ] || \
      error "$CONTRACT: $id mirror expected $current_class in $mirror_rel, got '$mirror_value'"
  done

  selector_fingerprint="$source_rel|$document_index|$selector_path|$current_class"
  if [ -n "${declared_selectors[$selector_fingerprint]:-}" ]; then
    error "$CONTRACT: $id duplicates exact selector owned by ${declared_selectors[$selector_fingerprint]}: $selector_fingerprint"
  else
    declared_selectors["$selector_fingerprint"]="$id"
  fi
  checked_entries=$((checked_entries + 1))
done

selector_key_allowed() {
  local candidate="$1"
  local selector_key
  while IFS= read -r selector_key; do
    [ "$candidate" = "$selector_key" ] && return 0
  done < <(yq e -r '.scope.storage_selector_keys[]' "$CONTRACT" | strip_yq_stream_markers)
  return 1
}

path_is_excluded() {
  local relative_file="$1"
  local excluded_name
  while IFS= read -r excluded_name; do
    case "/$relative_file/" in
      */"$excluded_name"/*) return 0 ;;
    esac
  done < <(yq e -r '.scope.excluded_directory_names[]' "$CONTRACT" | strip_yq_stream_markers)
  return 1
}

while IFS= read -r scope_root; do
  [ -n "$scope_root" ] || continue
  [ -d "$REPO_ROOT/$scope_root" ] || { error "$CONTRACT: scope root does not exist: $scope_root"; continue; }
  while IFS= read -r -d '' yaml_file; do
    relative_file="${yaml_file#"$REPO_ROOT"/}"
    path_is_excluded "$relative_file" && continue
    if ! yq e '.' "$yaml_file" >/dev/null 2>&1; then
      error "$relative_file: yq could not parse YAML"
      continue
    fi
    while IFS=$'\t' read -r discovered_document_index discovered_selector_path selector_value; do
      [ -n "$discovered_selector_path" ] || continue
      selector_key="${discovered_selector_path##*.}"
      selector_key_allowed "$selector_key" || continue
      case "$selector_value" in longhorn*) ;; *) continue ;; esac
      selector_fingerprint="$relative_file|$discovered_document_index|$discovered_selector_path|$selector_value"
      if [ -n "${discovered_selectors[$selector_fingerprint]:-}" ]; then
        error "$relative_file: duplicate discovered selector identity: $selector_fingerprint"
      else
        discovered_selectors["$selector_fingerprint"]=1
      fi
    done < <(
      yq e -r '
        .. | select(tag == "!!str" and test("^longhorn")) |
        [documentIndex, (path | join(".")), .] | @tsv
      ' "$yaml_file"
    )

    while IFS=$'\t' read -r implicit_kind implicit_name; do
      [ -n "$implicit_kind" ] || continue
      error "implicit default StorageClass is not classifiable: $relative_file|$implicit_kind|$implicit_name"
    done < <(
      # `$owner` is a yq variable, not a shell interpolation.
      # shellcheck disable=SC2016
      yq e -r '
        (select(.kind == "PersistentVolumeClaim" and ((.spec | has("storageClassName")) == false)) |
          [.kind, .metadata.name] | @tsv),
        (select(.kind == "Cluster" and ((.spec.storage | has("storageClass")) == false)) |
          [.kind, .metadata.name] | @tsv),
        (select(.kind == "StatefulSet") | .metadata.name as $owner |
          .spec.volumeClaimTemplates[]? |
          select((.spec | has("storageClassName")) == false) |
          ["StatefulSet", $owner + "/" + .metadata.name] | @tsv),
        (select(.kind == "ClickHouseInstallation") | .metadata.name as $owner |
          .spec.templates.volumeClaimTemplates[]? |
          select((.spec | has("storageClassName")) == false) |
          ["ClickHouseInstallation", $owner + "/" + .name] | @tsv)
      ' "$yaml_file"
    )
  done < <(find "$REPO_ROOT/$scope_root" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
done < <(yq e -r '.scope.roots[]' "$CONTRACT" | strip_yq_stream_markers)

for fingerprint in "${!declared_selectors[@]}"; do
  [ -n "${discovered_selectors[$fingerprint]:-}" ] || \
    error "contract selector not discovered at its exact identity: $fingerprint"
done

for fingerprint in "${!discovered_selectors[@]}"; do
  [ -n "${declared_selectors[$fingerprint]:-}" ] || \
    error "unclassified Longhorn selector outside the contract: $fingerprint"
done

if [ "$problems" -ne 0 ]; then
  printf '\nFAIL: retention contract found %d problem(s).\n' "$problems" >&2
  printf '%s\n' 'Do not edit a live claim to satisfy this gate. Classify fresh desired state' >&2
  printf '%s\n' 'or update the finite contract with reviewed migration ownership.' >&2
  exit 1
fi

known_mismatches="$(yq e -r '[.entries[] | select(.state == "known-mismatch")] | length' "$CONTRACT")"
printf 'PASS: %s retention contract is complete for its static scope (%d entries, %d known mismatches).\n' \
  "$owner_repository" "$checked_entries" "$known_mismatches"
