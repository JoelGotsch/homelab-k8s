#!/usr/bin/env bash
# Verify the reviewed projection of chart-generated storage claims and secret refs.
#
# The default mode is offline and hermetic: it binds every projection to the
# exact repository input digest, pinned chart metadata/package digest, and the
# repository-local retention contract. `--render` additionally downloads each
# pinned chart, verifies its package digest, renders from that local package,
# and compares the actual objects with the projection. Neither mode contacts a
# Kubernetes API or mutates live state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURE="$SCRIPT_DIR/fixtures/retention-rendered-projection.yaml"
CONTRACT="$SCRIPT_DIR/retention-contract.yaml"
RENDERED_CLAIM_CHECK="$SCRIPT_DIR/check-rendered-retention-claims.sh"
RENDER=false
PRINT_LAYER_DIGEST=""

usage() {
  sed -n '2,9p' "$0" | sed -E 's/^# ?//'
  printf '\nUsage: %s [--root DIR] [--fixture FILE] [--contract FILE] [--render]\n' "$0"
  printf '       %s [--root DIR] --print-layer-digest PATH\n' "$0"
}

absolute_file() {
  local candidate="$1"
  printf '%s/%s\n' "$(cd "$(dirname "$candidate")" && pwd)" "$(basename "$candidate")"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      REPO_ROOT="$(cd "${2:?--root requires a directory}" && pwd)"
      shift 2
      ;;
    --fixture)
      FIXTURE="$(absolute_file "${2:?--fixture requires a file}")"
      shift 2
      ;;
    --contract)
      CONTRACT="$(absolute_file "${2:?--contract requires a file}")"
      shift 2
      ;;
    --render)
      RENDER=true
      shift
      ;;
    --print-layer-digest)
      PRINT_LAYER_DIGEST="${2:?--print-layer-digest requires a path}"
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

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

sha256_stream() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    openssl dgst -sha256 | awk '{print $NF}'
  fi
}

layer_digest() {
  local layer_rel="$1"
  local layer_dir="$REPO_ROOT/$layer_rel"
  [ -d "$layer_dir" ] || {
    printf 'ERROR: layer does not exist: %s\n' "$layer_rel" >&2
    return 1
  }
  while IFS= read -r input_file; do
    case "$input_file" in
      # .helmcheckignore is a check-helm-values-keys.sh lint baseline, NOT a
      # Helm render input — it must not perturb the render-input digest.
      */README.md|*/charts/*|*/testdata/*|*/.helmcheckignore) continue ;;
    esac
    relative_input="${input_file#"$REPO_ROOT"/}"
    printf '%s  %s\n' "$(sha256_file "$input_file")" "$relative_input"
  done < <(find "$layer_dir" -type f -print | LC_ALL=C sort) | sha256_stream
}

if [ -n "$PRINT_LAYER_DIGEST" ]; then
  layer_digest "$PRINT_LAYER_DIGEST"
  exit 0
fi

[ -f "$FIXTURE" ] || { printf 'ERROR: fixture not found: %s\n' "$FIXTURE" >&2; exit 2; }
[ -f "$CONTRACT" ] || { printf 'ERROR: contract not found: %s\n' "$CONTRACT" >&2; exit 2; }

if [ "$RENDER" = true ]; then
  for required_tool in helm kustomize mktemp cp mkdir tar; do
    command -v "$required_tool" >/dev/null 2>&1 || {
      printf 'ERROR: %s is required for --render\n' "$required_tool" >&2
      exit 2
    }
  done
  [ -x "$RENDERED_CLAIM_CHECK" ] || {
    printf 'ERROR: rendered claim checker is not executable: %s\n' "$RENDERED_CLAIM_CHECK" >&2
    exit 2
  }
fi

problems=0
checked_claims=0
checked_implicit_default_claims=0
checked_secret_refs=0
checked_externalsecret_mirrors=0
checked_externalsecret_projections=0
checked_pod_selectors=0
checked_forbidden_literals=0
declare -A fixture_claim_ids=()
declare -A secret_ref_ids=()
declare -A pod_selector_ids=()

error() {
  printf 'ERROR: %s\n' "$*" >&2
  problems=$((problems + 1))
}

strip_yq_stream_markers() {
  awk 'NF && $0 != "---" && $0 != "null"'
}

fixture_version="$(yq e -r '.version // ""' "$FIXTURE")"
[ "$fixture_version" = "1" ] || error "$FIXTURE: expected version 1, got '$fixture_version'"

fixture_mode="$(yq e -r '.provenance.mode // ""' "$FIXTURE")"
[ "$fixture_mode" = "reviewed-render-projection" ] || \
  error "$FIXTURE: provenance.mode must be reviewed-render-projection"

default_storage_class="$(yq e -r '.cluster_defaults.storage_class.name // ""' "$FIXTURE")"
default_reclaim_policy="$(yq e -r '.cluster_defaults.storage_class.reclaim_policy // ""' "$FIXTURE")"
default_source_rel="$(yq e -r '.cluster_defaults.storage_class.source_file // ""' "$FIXTURE")"
chart_default_source_rel="$(yq e -r '.cluster_defaults.storage_class.chart_default_source_file // ""' "$FIXTURE")"
chart_default_value_path="$(yq e -r '.cluster_defaults.storage_class.chart_default_value_path // ""' "$FIXTURE")"
chart_default_enabled="$(yq e -r '.cluster_defaults.storage_class.chart_default_enabled' "$FIXTURE")"
[ "$default_storage_class" = "longhorn-replica2" ] && [ "$default_reclaim_policy" = "Delete" ] || \
  error "$FIXTURE: bounded implicit claim requires default longhorn-replica2 with Delete policy"
[ "$default_source_rel" = "infrastructure/longhorn/storageclasses.yaml" ] || \
  error "$FIXTURE: default StorageClass source path may not move"
[ "$chart_default_source_rel" = "infrastructure/longhorn/values.yaml" ] && \
  [ "$chart_default_value_path" = ".persistence.defaultClass" ] && \
  [ "$chart_default_enabled" = "false" ] || \
  error "$FIXTURE: Longhorn chart default-class guard must remain false at the reviewed source path"

contract_default_storage_class="$(yq e -r '.storage_classes.default // ""' "$CONTRACT")"
contract_default_source_rel="$(yq e -r '.storage_classes.source // ""' "$CONTRACT")"
contract_chart_default_source_rel="$(yq e -r '.storage_classes.chart_default.source // ""' "$CONTRACT")"
contract_chart_default_value_path="$(yq e -r '.storage_classes.chart_default.value_path // ""' "$CONTRACT")"
contract_chart_default_enabled="$(yq e -r '.storage_classes.chart_default.enabled' "$CONTRACT")"
[ "$contract_default_storage_class" = "$default_storage_class" ] && \
  [ "$contract_default_source_rel" = "$default_source_rel" ] || \
  error "$FIXTURE: cluster default name/source must match the retention contract"
[ "$contract_chart_default_source_rel" = "$chart_default_source_rel" ] && \
  [ "$contract_chart_default_value_path" = "$chart_default_value_path" ] && \
  [ "$contract_chart_default_enabled" = "$chart_default_enabled" ] || \
  error "$FIXTURE: chart default-class guard must match the retention contract"

default_source="$REPO_ROOT/$default_source_rel"
[ -f "$default_source" ] || error "$FIXTURE: missing default StorageClass source $default_source_rel"
if [ -f "$default_source" ]; then
  default_rows="$(yq e -r '
    select(.kind == "StorageClass") |
    select(
      (.metadata.annotations."storageclass.kubernetes.io/is-default-class" == "true") or
      (.metadata.annotations."storageclass.k8s.io/is-default-class" == "true") or
      (.metadata.annotations."storageclass.kubernetes.io/is-default-class" == true) or
      (.metadata.annotations."storageclass.k8s.io/is-default-class" == true)
    ) | [.metadata.name, .reclaimPolicy] | @tsv
  ' "$default_source" | strip_yq_stream_markers)"
  default_count="$(printf '%s\n' "$default_rows" | awk 'NF' | wc -l | tr -d ' ')"
  [ "$default_count" -eq 1 ] || \
    error "$default_source_rel: expected exactly one declared default StorageClass, found $default_count"
  [ "$default_rows" = "$default_storage_class"$'\t'"$default_reclaim_policy" ] || \
    error "$default_source_rel: default StorageClass must remain $default_storage_class/$default_reclaim_policy"
fi

chart_default_source="$REPO_ROOT/$chart_default_source_rel"
[ -f "$chart_default_source" ] || error "$FIXTURE: missing chart default-class source $chart_default_source_rel"
if [ -f "$chart_default_source" ]; then
  actual_chart_default="$(yq e -r "$chart_default_value_path" "$chart_default_source" 2>/dev/null)" || {
    error "$chart_default_source_rel: could not evaluate $chart_default_value_path"
    actual_chart_default=""
  }
  [ "$actual_chart_default" = "false" ] || \
    error "$chart_default_source_rel: $chart_default_value_path must remain false, got '$actual_chart_default'"
fi

layer_count="$(yq e -r '.layers | length' "$FIXTURE")"
[[ "$layer_count" =~ ^[0-9]+$ ]] || { printf 'ERROR: invalid layers list\n' >&2; exit 2; }

render_root=""
if [ "$RENDER" = true ]; then
  render_root="$(mktemp -d "${TMPDIR:-/tmp}/retention-render.XXXXXX")"
  cleanup() {
    case "$render_root" in
      "${TMPDIR:-/tmp}"/retention-render.*) rm -rf "$render_root" ;;
      *) printf 'ERROR: refusing to remove unexpected temp path: %s\n' "$render_root" >&2 ;;
    esac
  }
  trap cleanup EXIT
  mkdir -p "$render_root/repo"
  for source_dir in infrastructure platform observability components; do
    [ -d "$REPO_ROOT/$source_dir" ] && cp -R "$REPO_ROOT/$source_dir" "$render_root/repo/$source_dir"
  done
fi

for ((layer_index = 0; layer_index < layer_count; layer_index++)); do
  layer_rel="$(yq e -r ".layers[$layer_index].path // \"\"" "$FIXTURE")"
  expected_digest="$(yq e -r ".layers[$layer_index].input_digest_sha256 // \"\"" "$FIXTURE")"
  chart_name="$(yq e -r ".layers[$layer_index].chart.name // \"\"" "$FIXTURE")"
  chart_repo="$(yq e -r ".layers[$layer_index].chart.repository // \"\"" "$FIXTURE")"
  chart_version="$(yq e -r ".layers[$layer_index].chart.version // \"\"" "$FIXTURE")"
  chart_app_version="$(yq e -r ".layers[$layer_index].chart.app_version // \"\"" "$FIXTURE")"
  package_digest="$(yq e -r ".layers[$layer_index].chart.package_sha256 // \"\"" "$FIXTURE")"
  declared_claim_count="$(yq e -r ".layers[$layer_index].declared_claim_count // \"\"" "$FIXTURE")"
  declared_implicit_default_claim_count="$(yq e -r ".layers[$layer_index].declared_implicit_default_claim_count // \"\"" "$FIXTURE")"
  declared_secret_ref_count="$(yq e -r ".layers[$layer_index].declared_secret_reference_count // \"\"" "$FIXTURE")"
  declared_externalsecret_mirror_count="$(yq e -r ".layers[$layer_index].declared_externalsecret_mirror_count // \"\"" "$FIXTURE")"
  declared_externalsecret_projection_count="$(yq e -r ".layers[$layer_index].declared_externalsecret_projection_count // \"\"" "$FIXTURE")"
  declared_pod_selector_count="$(yq e -r ".layers[$layer_index].declared_pod_selector_count // \"\"" "$FIXTURE")"
  declared_forbidden_literal_count="$(yq e -r ".layers[$layer_index].declared_forbidden_literal_count // \"\"" "$FIXTURE")"
  secret_ref_pattern="$(yq e -r ".layers[$layer_index].secret_reference_env_pattern // \"\"" "$FIXTURE")"
  unset layer_fixture_secret_ids
  declare -A layer_fixture_secret_ids=()
  unset layer_referenced_secret_projections layer_expected_secret_projections
  declare -A layer_referenced_secret_projections=()
  declare -A layer_expected_secret_projections=()

  [ -n "$layer_rel" ] || { error "$FIXTURE: layer $layer_index has no path"; continue; }
  [ -d "$REPO_ROOT/$layer_rel" ] || { error "$FIXTURE: layer does not exist: $layer_rel"; continue; }
  [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || error "$FIXTURE: $layer_rel has invalid input digest"
  [[ "$package_digest" =~ ^[0-9a-f]{64}$ ]] || error "$FIXTURE: $layer_rel has invalid chart package digest"
  [ -n "$chart_name" ] || error "$FIXTURE: $layer_rel has no chart name"
  [ -n "$chart_repo" ] || error "$FIXTURE: $layer_rel has no chart repository"
  [ -n "$chart_version" ] || error "$FIXTURE: $layer_rel has no chart version"
  [ -n "$chart_app_version" ] || error "$FIXTURE: $layer_rel has no chart app_version"
  [[ "$declared_claim_count" =~ ^[0-9]+$ ]] || error "$FIXTURE: $layer_rel has invalid declared_claim_count"
  [[ "$declared_implicit_default_claim_count" =~ ^[0-9]+$ ]] || \
    error "$FIXTURE: $layer_rel has invalid declared_implicit_default_claim_count"
  [[ "$declared_secret_ref_count" =~ ^[0-9]+$ ]] || \
    error "$FIXTURE: $layer_rel has invalid declared_secret_reference_count"
  [[ "$declared_externalsecret_mirror_count" =~ ^[0-9]+$ ]] || \
    error "$FIXTURE: $layer_rel has invalid declared_externalsecret_mirror_count"
  [[ "$declared_externalsecret_projection_count" =~ ^[0-9]+$ ]] || \
    error "$FIXTURE: $layer_rel has invalid declared_externalsecret_projection_count"
  [[ "$declared_pod_selector_count" =~ ^[0-9]+$ ]] || \
    error "$FIXTURE: $layer_rel has invalid declared_pod_selector_count"
  [[ "$declared_forbidden_literal_count" =~ ^[0-9]+$ ]] || \
    error "$FIXTURE: $layer_rel has invalid declared_forbidden_literal_count"

  actual_digest="$(layer_digest "$layer_rel")"
  [ "$actual_digest" = "$expected_digest" ] || \
    error "$layer_rel: input digest changed; review a fresh render projection (expected $expected_digest, got $actual_digest)"

  kustomization="$REPO_ROOT/$layer_rel/kustomization.yaml"
  [ -f "$kustomization" ] || { error "$layer_rel: kustomization.yaml is missing"; continue; }
  chart_rows="$(CHART_NAME="$chart_name" yq e -r \
    '.helmCharts[]? | select(.name == strenv(CHART_NAME)) | [.repo, .version, .valuesFile] | @tsv' \
    "$kustomization" | strip_yq_stream_markers)"
  chart_count="$(printf '%s\n' "$chart_rows" | awk 'NF' | wc -l | tr -d ' ')"
  [ "$chart_count" -eq 1 ] || {
    error "$kustomization: expected exactly one pinned chart named $chart_name, found $chart_count"
    continue
  }
  IFS=$'\t' read -r actual_chart_repo actual_chart_version values_file_rel <<<"$chart_rows"
  [ "$actual_chart_repo" = "$chart_repo" ] || \
    error "$kustomization: $chart_name repository is '$actual_chart_repo', fixture says '$chart_repo'"
  [ "$actual_chart_version" = "$chart_version" ] || \
    error "$kustomization: $chart_name version is '$actual_chart_version', fixture says '$chart_version'"
  values_file="$REPO_ROOT/$layer_rel/$values_file_rel"
  [ -f "$values_file" ] || error "$kustomization: values file does not exist: $values_file_rel"
  values_mirror_count="$(yq e -r ".layers[$layer_index].chart.values_mirrors // [] | length" "$FIXTURE")"
  for ((mirror_index = 0; mirror_index < values_mirror_count; mirror_index++)); do
    mirror_rel="$(yq e -r ".layers[$layer_index].chart.values_mirrors[$mirror_index]" "$FIXTURE")"
    [ -f "$REPO_ROOT/$layer_rel/$mirror_rel" ] || \
      error "$FIXTURE: missing values mirror $layer_rel/$mirror_rel"
  done

  forbidden_literal_count="$(yq e -r ".layers[$layer_index].forbidden_literal_paths // [] | length" "$FIXTURE")"
  [ "$forbidden_literal_count" = "$declared_forbidden_literal_count" ] || \
    error "$FIXTURE: $layer_rel declares $declared_forbidden_literal_count forbidden literal paths but contains $forbidden_literal_count"
  unset layer_forbidden_literal_paths
  declare -A layer_forbidden_literal_paths=()
  for ((literal_index = 0; literal_index < forbidden_literal_count; literal_index++)); do
    literal_path="$(yq e -r ".layers[$layer_index].forbidden_literal_paths[$literal_index] // \"\"" "$FIXTURE")"
    [ -n "$literal_path" ] || { error "$FIXTURE: $layer_rel has an empty forbidden literal path"; continue; }
    [ -z "${layer_forbidden_literal_paths[$literal_path]:-}" ] || \
      error "$FIXTURE: $layer_rel duplicates forbidden literal path '$literal_path'"
    layer_forbidden_literal_paths["$literal_path"]=1
    literal_value="$(yq e -r "$literal_path // \"\"" "$values_file" | strip_yq_stream_markers)"
    [ -z "$literal_value" ] || error "$values_file_rel: $literal_path must be empty; credentials belong in a Secret"
    for ((mirror_index = 0; mirror_index < values_mirror_count; mirror_index++)); do
      mirror_rel="$(yq e -r ".layers[$layer_index].chart.values_mirrors[$mirror_index]" "$FIXTURE")"
      mirror_file="$REPO_ROOT/$layer_rel/$mirror_rel"
      mirror_literal_value="$(yq e -r "$literal_path // \"\"" "$mirror_file" | strip_yq_stream_markers)"
      [ -z "$mirror_literal_value" ] || \
        error "$mirror_rel: $literal_path must be empty; credentials belong in a Secret"
    done
    checked_forbidden_literals=$((checked_forbidden_literals + 1))
  done

  rendered_file=""
  if [ "$RENDER" = true ]; then
    layer_render_dir="$render_root/repo/$layer_rel"
    package_dir="$render_root/packages/$layer_index"
    mkdir -p "$package_dir" "$layer_render_dir/charts"
    # An OCI repository takes the chart name in the REFERENCE, not in --repo;
    # `helm pull <name> --repo oci://…` fails with "invalid reference". Added
    # 2026-08-16 when ADR 0052 moved these layers onto the Forgejo mirror.
    #
    # The digest assertion below is unaffected and is the point: the package
    # this pulls must still hash to the fixture's package_sha256, so moving the
    # SOURCE cannot smuggle in a different chart. All three layers verified
    # byte-identical upstream vs mirrored at the time of the move.
    case "$chart_repo" in
      oci://*)
        helm pull "${chart_repo%/}/$chart_name" --version "$chart_version" \
          --destination "$package_dir" >/dev/null
        ;;
      *)
        helm pull "$chart_name" --repo "$chart_repo" --version "$chart_version" \
          --destination "$package_dir" >/dev/null
        ;;
    esac
    package_file="$package_dir/$chart_name-$chart_version.tgz"
    [ -f "$package_file" ] || { error "$layer_rel: helm did not produce $chart_name-$chart_version.tgz"; continue; }
    actual_package_digest="$(sha256_file "$package_file")"
    [ "$actual_package_digest" = "$package_digest" ] || {
      error "$layer_rel: downloaded chart digest is $actual_package_digest, expected $package_digest"
      continue
    }
    tar -xzf "$package_file" -C "$layer_render_dir/charts"
    extracted_chart="$layer_render_dir/charts/$chart_name/Chart.yaml"
    [ -f "$extracted_chart" ] || { error "$layer_rel: verified package has no $chart_name/Chart.yaml"; continue; }
    extracted_chart_version="$(yq e -r '.version // ""' "$extracted_chart")"
    extracted_app_version="$(yq e -r '.appVersion // ""' "$extracted_chart")"
    [ "$extracted_chart_version" = "$chart_version" ] || \
      error "$layer_rel: verified package chart version is '$extracted_chart_version', expected '$chart_version'"
    [ "$extracted_app_version" = "$chart_app_version" ] || \
      error "$layer_rel: verified package appVersion is '$extracted_app_version', expected '$chart_app_version'"
    yq e -i '.helmGlobals.chartHome = "charts"' "$layer_render_dir/kustomization.yaml"
    rendered_file="$render_root/rendered-$layer_index.yaml"
    if ! kustomize build --enable-helm "$layer_render_dir" >"$rendered_file"; then
      error "$layer_rel: kustomize render failed"
      rendered_file=""
    fi
  fi

  pod_selector_count="$(yq e -r ".layers[$layer_index].pod_selectors // [] | length" "$FIXTURE")"
  [ "$pod_selector_count" = "$declared_pod_selector_count" ] || \
    error "$FIXTURE: $layer_rel declares $declared_pod_selector_count pod selectors but contains $pod_selector_count"
  for ((selector_index = 0; selector_index < pod_selector_count; selector_index++)); do
    pod_base=".layers[$layer_index].pod_selectors[$selector_index]"
    workload_kind="$(yq e -r "$pod_base.workload_kind // \"\"" "$FIXTURE")"
    workload_name="$(yq e -r "$pod_base.workload_name // \"\"" "$FIXTURE")"
    label_key="$(yq e -r "$pod_base.label_key // \"\"" "$FIXTURE")"
    label_value="$(yq e -r "$pod_base.label_value // \"\"" "$FIXTURE")"
    pod_selector_id="$workload_kind/$workload_name/$label_key"
    [ -n "$workload_kind" ] && [ -n "$workload_name" ] && [ -n "$label_key" ] && [ -n "$label_value" ] || \
      error "$FIXTURE: incomplete pod selector at $layer_rel index $selector_index"
    [ -z "${pod_selector_ids[$pod_selector_id]:-}" ] || \
      error "$FIXTURE: duplicate pod selector '$pod_selector_id'"
    pod_selector_ids["$pod_selector_id"]="$label_value"
    if [ -n "$rendered_file" ]; then
      rendered_label_values="$(WORKLOAD_KIND="$workload_kind" WORKLOAD_NAME="$workload_name" \
        LABEL_KEY="$label_key" yq e -r '
          select(.kind == strenv(WORKLOAD_KIND) and .metadata.name == strenv(WORKLOAD_NAME)) |
          .spec.template.metadata.labels[strenv(LABEL_KEY)]
        ' "$rendered_file" | strip_yq_stream_markers)"
      rendered_label_count="$(printf '%s\n' "$rendered_label_values" | awk 'NF' | wc -l | tr -d ' ')"
      [ "$rendered_label_count" -eq 1 ] || \
        error "$layer_rel render: expected exactly one pod label $pod_selector_id, found $rendered_label_count"
      [ "$rendered_label_values" = "$label_value" ] || \
        error "$layer_rel render: $pod_selector_id is '$rendered_label_values', fixture says '$label_value'"
    fi
    checked_pod_selectors=$((checked_pod_selectors + 1))
  done

  claim_count="$(yq e -r ".layers[$layer_index].claims | length" "$FIXTURE")"
  [ "$claim_count" = "$declared_claim_count" ] || \
    error "$FIXTURE: $layer_rel declares $declared_claim_count claims but contains $claim_count"
  for ((claim_index = 0; claim_index < claim_count; claim_index++)); do
    claim_base=".layers[$layer_index].claims[$claim_index]"
    contract_id="$(yq e -r "$claim_base.contract_id // \"\"" "$FIXTURE")"
    claim_id="$(yq e -r "$claim_base.rendered_claim_id // \"\"" "$FIXTURE")"
    kind="$(yq e -r "$claim_base.kind // \"\"" "$FIXTURE")"
    resource_name="$(yq e -r "$claim_base.resource_name // \"\"" "$FIXTURE")"
    claim_name="$(yq e -r "$claim_base.claim_name // \"\"" "$FIXTURE")"
    selector_path="$(yq e -r "$claim_base.selector_path // \"\"" "$FIXTURE")"
    storage_class="$(yq e -r "$claim_base.storage_class // \"\"" "$FIXTURE")"
    storage_class_mode="$(yq e -r "$claim_base.storage_class_mode // \"\"" "$FIXTURE")"
    exception_owner="$(yq e -r "$claim_base.exception_owner // \"\"" "$FIXTURE")"
    exception_removal_condition="$(yq e -r "$claim_base.exception_removal_condition // \"\"" "$FIXTURE")"

    [ -n "$contract_id" ] || { error "$FIXTURE: $layer_rel claim $claim_index has no contract_id"; continue; }
    [ -n "$claim_id" ] || { error "$FIXTURE: $contract_id has no rendered_claim_id"; continue; }
    [ -z "${fixture_claim_ids[$claim_id]:-}" ] || error "$FIXTURE: duplicate rendered claim id '$claim_id'"
    fixture_claim_ids["$claim_id"]="$contract_id"
    contract_rows="$(CONTRACT_ID="$contract_id" yq e -r \
      '.entries[] | select(.id == strenv(CONTRACT_ID)) |
       [.rendered_claim_id, .current_storage_class,
        (.storage_class_selection // "explicit"), .state, .migration_owner,
        (.exception_removal_condition // "")] | @tsv' \
      "$CONTRACT" | strip_yq_stream_markers)"
    contract_count="$(printf '%s\n' "$contract_rows" | awk 'NF' | wc -l | tr -d ' ')"
    [ "$contract_count" -eq 1 ] || { error "$CONTRACT: expected exactly one entry $contract_id"; continue; }
    IFS=$'\t' read -r contract_claim_id contract_storage_class contract_selection \
      contract_state contract_migration_owner contract_removal_condition <<<"$contract_rows"
    [ "$contract_claim_id" = "$claim_id" ] || \
      error "$FIXTURE: $contract_id claim id '$claim_id' does not match contract '$contract_claim_id'"
    [ "$contract_storage_class" = "$storage_class" ] || \
      error "$FIXTURE: $contract_id class '$storage_class' does not match contract '$contract_storage_class'"
    [ "$contract_selection" = "$storage_class_mode" ] || \
      error "$FIXTURE: $contract_id selection '$storage_class_mode' does not match contract '$contract_selection'"
    case "$storage_class_mode" in
      explicit)
        [ -z "$exception_owner" ] && [ -z "$exception_removal_condition" ] || \
          error "$FIXTURE: explicit claim $claim_id cannot carry implicit-default exception metadata"
        ;;
      implicit-default)
        checked_implicit_default_claims=$((checked_implicit_default_claims + 1))
        [ "$layer_rel" = "platform/woodpecker" ] && \
          [ "$contract_id" = "woodpecker-agent-config" ] && \
          [ "$claim_id" = "woodpecker-agent/agent-config" ] && \
          [ "$storage_class" = "longhorn-replica2" ] && \
          [ "$contract_state" = "compliant" ] || \
          error "$FIXTURE: implicit-default exception is restricted to the compliant Woodpecker agent claim"
        [ -n "$exception_owner" ] && [ "$exception_owner" = "$contract_migration_owner" ] || \
          error "$FIXTURE: $claim_id exception owner must match its contract migration owner"
        [ -n "$exception_removal_condition" ] && \
          [ "$exception_removal_condition" = "$contract_removal_condition" ] || \
          error "$FIXTURE: $claim_id exception removal condition must match its contract"
        ;;
      *) error "$FIXTURE: $claim_id has invalid storage_class_mode '$storage_class_mode'" ;;
    esac
    case "$kind" in
      PersistentVolumeClaim)
        [ "$claim_id" = "$resource_name" ] || error "$FIXTURE: PVC $claim_id must equal resource_name"
        [ "$claim_name" = "$resource_name" ] || error "$FIXTURE: PVC $claim_id must equal claim_name"
        [ "$selector_path" = "spec.storageClassName" ] || error "$FIXTURE: PVC $claim_id has invalid selector_path"
        ;;
      StatefulSet)
        [ "$claim_id" = "$resource_name/$claim_name" ] || \
          error "$FIXTURE: StatefulSet claim id must be resource_name/claim_name: $claim_id"
        [[ "$selector_path" =~ ^spec\.volumeClaimTemplates\.[0-9]+\.spec\.storageClassName$ ]] || \
          error "$FIXTURE: StatefulSet $claim_id has invalid selector_path '$selector_path'"
        ;;
      *) error "$FIXTURE: $claim_id has unsupported kind '$kind'" ;;
    esac

    checked_claims=$((checked_claims + 1))
  done
  layer_implicit_default_count="$(yq e -r ".layers[$layer_index].claims |
    [ .[] | select(.storage_class_mode == \"implicit-default\") ] | length" "$FIXTURE")"
  [ "$layer_implicit_default_count" = "$declared_implicit_default_claim_count" ] || \
    error "$FIXTURE: $layer_rel declares $declared_implicit_default_claim_count implicit claims but contains $layer_implicit_default_count"

  secret_ref_count="$(yq e -r ".layers[$layer_index].secret_references // [] | length" "$FIXTURE")"
  [ "$secret_ref_count" = "$declared_secret_ref_count" ] || \
    error "$FIXTURE: $layer_rel declares $declared_secret_ref_count secret refs but contains $secret_ref_count"
  if [ "$secret_ref_count" -gt 0 ]; then
    [ -n "$secret_ref_pattern" ] || error "$FIXTURE: $layer_rel secret refs require an environment-name pattern"
  else
    [ -z "$secret_ref_pattern" ] || error "$FIXTURE: $layer_rel has a secret pattern but no references"
  fi
  for ((secret_index = 0; secret_index < secret_ref_count; secret_index++)); do
    ref_base=".layers[$layer_index].secret_references[$secret_index]"
    workload_kind="$(yq e -r "$ref_base.workload_kind // \"\"" "$FIXTURE")"
    workload_name="$(yq e -r "$ref_base.workload_name // \"\"" "$FIXTURE")"
    container_name="$(yq e -r "$ref_base.container_name // \"\"" "$FIXTURE")"
    env_name="$(yq e -r "$ref_base.env_name // \"\"" "$FIXTURE")"
    secret_name="$(yq e -r "$ref_base.secret_name // \"\"" "$FIXTURE")"
    secret_key="$(yq e -r "$ref_base.secret_key // \"\"" "$FIXTURE")"
    source_value_path="$(yq e -r "$ref_base.source_value_path // \"\"" "$FIXTURE")"
    source_name_path="$(yq e -r "$ref_base.source_name_path // \"\"" "$FIXTURE")"
    source_key_path="$(yq e -r "$ref_base.source_key_path // \"\"" "$FIXTURE")"
    ref_id="$workload_kind/$workload_name/$container_name/$env_name"

    for required_value in "$workload_kind" "$workload_name" "$container_name" "$env_name" \
      "$secret_name" "$secret_key" "$source_value_path" "$source_name_path" "$source_key_path"; do
      [ -n "$required_value" ] || error "$FIXTURE: incomplete secret reference at $layer_rel index $secret_index"
    done
    [ -z "${secret_ref_ids[$ref_id]:-}" ] || error "$FIXTURE: duplicate secret reference '$ref_id'"
    secret_ref_ids["$ref_id"]=1
    layer_fixture_secret_ids["$ref_id"]=1
    layer_referenced_secret_projections["$secret_name"$'\t'"$secret_key"]=1
    [ "$secret_key" = "$env_name" ] || \
      error "$FIXTURE: $ref_id secret key '$secret_key' must equal its environment name"

    actual_source_name="$(yq e -r "$source_name_path // \"\"" "$values_file" | strip_yq_stream_markers)"
    actual_source_key="$(yq e -r "$source_key_path // \"\"" "$values_file" | strip_yq_stream_markers)"
    actual_source_value="$(yq e -r "$source_value_path // \"\"" "$values_file" | strip_yq_stream_markers)"
    [ "$actual_source_name" = "$secret_name" ] || \
      error "$values_file_rel: $source_name_path is '$actual_source_name', expected '$secret_name'"
    [ "$actual_source_key" = "$secret_key" ] || \
      error "$values_file_rel: $source_key_path is '$actual_source_key', expected '$secret_key'"
    [ -z "$actual_source_value" ] || \
      error "$values_file_rel: $source_value_path must be empty when secretKeyRef is declared"
    for ((mirror_index = 0; mirror_index < values_mirror_count; mirror_index++)); do
      mirror_rel="$(yq e -r ".layers[$layer_index].chart.values_mirrors[$mirror_index]" "$FIXTURE")"
      mirror_file="$REPO_ROOT/$layer_rel/$mirror_rel"
      [ -f "$mirror_file" ] || { error "$FIXTURE: missing values mirror $layer_rel/$mirror_rel"; continue; }
      mirror_source_name="$(yq e -r "$source_name_path // \"\"" "$mirror_file" | strip_yq_stream_markers)"
      mirror_source_key="$(yq e -r "$source_key_path // \"\"" "$mirror_file" | strip_yq_stream_markers)"
      mirror_source_value="$(yq e -r "$source_value_path // \"\"" "$mirror_file" | strip_yq_stream_markers)"
      [ "$mirror_source_name" = "$secret_name" ] || \
        error "$mirror_rel: $source_name_path is '$mirror_source_name', expected '$secret_name'"
      [ "$mirror_source_key" = "$secret_key" ] || \
        error "$mirror_rel: $source_key_path is '$mirror_source_key', expected '$secret_key'"
      [ -z "$mirror_source_value" ] || \
        error "$mirror_rel: $source_value_path must be empty when secretKeyRef is declared"
    done

    if [ -n "$rendered_file" ]; then
      rendered_refs="$(WORKLOAD_KIND="$workload_kind" WORKLOAD_NAME="$workload_name" \
        CONTAINER_NAME="$container_name" ENV_NAME="$env_name" yq e -r \
        'select(.kind == strenv(WORKLOAD_KIND) and .metadata.name == strenv(WORKLOAD_NAME)) |
         .spec.template.spec.containers[]? | select(.name == strenv(CONTAINER_NAME)) |
         .env[]? | select(.name == strenv(ENV_NAME)) |
         [.valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key, has("value")] | @tsv' \
        "$rendered_file" | strip_yq_stream_markers)"
      rendered_ref_count="$(printf '%s\n' "$rendered_refs" | awk 'NF' | wc -l | tr -d ' ')"
      [ "$rendered_ref_count" -eq 1 ] || \
        error "$layer_rel render: expected exactly one secret ref $ref_id, found $rendered_ref_count"
      if [ "$rendered_ref_count" -eq 1 ]; then
        IFS=$'\t' read -r rendered_secret_name rendered_secret_key rendered_literal_present <<<"$rendered_refs"
        [ "$rendered_secret_name" = "$secret_name" ] && [ "$rendered_secret_key" = "$secret_key" ] || \
          error "$layer_rel render: $ref_id secretKeyRef name/key differs from the reviewed projection"
        [ "$rendered_literal_present" = false ] || \
          error "$layer_rel render: $ref_id contains a literal credential value [redacted]"
      fi
    fi
    checked_secret_refs=$((checked_secret_refs + 1))
  done

  externalsecret_projection_count="$(yq e -r ".layers[$layer_index].externalsecret_projections // [] | length" "$FIXTURE")"
  [ "$externalsecret_projection_count" = "$declared_externalsecret_projection_count" ] || \
    error "$FIXTURE: $layer_rel declares $declared_externalsecret_projection_count ExternalSecret projections but contains $externalsecret_projection_count"
  if [ "$secret_ref_count" -gt 0 ]; then
    [ "$externalsecret_projection_count" -gt 0 ] || \
      error "$FIXTURE: $layer_rel secret refs require explicit ExternalSecret source projections"
  else
    [ "$externalsecret_projection_count" -eq 0 ] || \
      error "$FIXTURE: $layer_rel has ExternalSecret projections but no secret references"
  fi
  for ((projection_index = 0; projection_index < externalsecret_projection_count; projection_index++)); do
    projection_base=".layers[$layer_index].externalsecret_projections[$projection_index]"
    projected_secret_name="$(yq e -r "$projection_base.secret_name // \"\"" "$FIXTURE")"
    projected_secret_key="$(yq e -r "$projection_base.secret_key // \"\"" "$FIXTURE")"
    projected_remote_key="$(yq e -r "$projection_base.remote_ref_key // \"\"" "$FIXTURE")"
    projected_remote_property="$(yq e -r "$projection_base.remote_ref_property // \"\"" "$FIXTURE")"
    for required_value in "$projected_secret_name" "$projected_secret_key" \
      "$projected_remote_key" "$projected_remote_property"; do
      [ -n "$required_value" ] || \
        error "$FIXTURE: incomplete ExternalSecret projection at $layer_rel index $projection_index"
    done
    projection_id="$projected_secret_name"$'\t'"$projected_secret_key"
    [ -z "${layer_expected_secret_projections[$projection_id]:-}" ] || \
      error "$FIXTURE: duplicate ExternalSecret projection for $projected_secret_name/$projected_secret_key"
    layer_expected_secret_projections["$projection_id"]="$projected_remote_key"$'\t'"$projected_remote_property"
    checked_externalsecret_projections=$((checked_externalsecret_projections + 1))
  done
  for projection_id in "${!layer_referenced_secret_projections[@]}"; do
    if [ -z "${layer_expected_secret_projections[$projection_id]:-}" ]; then
      IFS=$'\t' read -r projected_secret_name projected_secret_key <<<"$projection_id"
      error "$FIXTURE: referenced Secret key $projected_secret_name/$projected_secret_key lacks an ExternalSecret source projection"
    fi
  done
  for projection_id in "${!layer_expected_secret_projections[@]}"; do
    if [ -z "${layer_referenced_secret_projections[$projection_id]:-}" ]; then
      IFS=$'\t' read -r projected_secret_name projected_secret_key <<<"$projection_id"
      error "$FIXTURE: unreferenced ExternalSecret source projection for $projected_secret_name/$projected_secret_key"
    fi
  done

  externalsecret_mirror_count="$(yq e -r ".layers[$layer_index].externalsecret_mirrors // [] | length" "$FIXTURE")"
  [ "$externalsecret_mirror_count" = "$declared_externalsecret_mirror_count" ] || \
    error "$FIXTURE: $layer_rel declares $declared_externalsecret_mirror_count ExternalSecret mirrors but contains $externalsecret_mirror_count"
  if [ "$secret_ref_count" -gt 0 ]; then
    [ "$externalsecret_mirror_count" -gt 0 ] || \
      error "$FIXTURE: $layer_rel secret refs require at least one ExternalSecret mirror"
  else
    [ "$externalsecret_mirror_count" -eq 0 ] || \
      error "$FIXTURE: $layer_rel has ExternalSecret mirrors but no secret references"
  fi
  unset layer_externalsecret_mirrors
  declare -A layer_externalsecret_mirrors=()
  for ((mirror_index = 0; mirror_index < externalsecret_mirror_count; mirror_index++)); do
    externalsecret_rel="$(yq e -r ".layers[$layer_index].externalsecret_mirrors[$mirror_index] // \"\"" "$FIXTURE")"
    [ -n "$externalsecret_rel" ] || { error "$FIXTURE: $layer_rel has an empty ExternalSecret mirror path"; continue; }
    case "$externalsecret_rel" in
      "$layer_rel"/*) ;;
      *) error "$FIXTURE: ExternalSecret mirror $externalsecret_rel must be inside $layer_rel" ;;
    esac
    [ -z "${layer_externalsecret_mirrors[$externalsecret_rel]:-}" ] || \
      error "$FIXTURE: $layer_rel duplicates ExternalSecret mirror '$externalsecret_rel'"
    layer_externalsecret_mirrors["$externalsecret_rel"]=1
    externalsecret_file="$REPO_ROOT/$externalsecret_rel"
    [ -f "$externalsecret_file" ] || { error "$FIXTURE: missing ExternalSecret mirror $externalsecret_rel"; continue; }

    unset actual_secret_projections
    declare -A actual_secret_projections=()
    while IFS=$'\t' read -r projected_secret_name projected_secret_key \
      projected_remote_key projected_remote_property; do
      [ -n "$projected_secret_name" ] && [ -n "$projected_secret_key" ] || continue
      projection_id="$projected_secret_name"$'\t'"$projected_secret_key"
      [ -z "${actual_secret_projections[$projection_id]:-}" ] || \
        error "$externalsecret_rel: duplicate projection for $projected_secret_name/$projected_secret_key"
      actual_secret_projections["$projection_id"]="$projected_remote_key"$'\t'"$projected_remote_property"
    done < <(
      # `$target` and `$key` are yq variables.
      # shellcheck disable=SC2016
      SECRET_REF_PATTERN="$secret_ref_pattern" yq e -r '
        select(.kind == "ExternalSecret") | .spec.target.name as $target |
        .spec.data[]? | (.secretKey // "") as $key |
        select($key | test(strenv(SECRET_REF_PATTERN))) |
        [$target, $key, (.remoteRef.key // ""), (.remoteRef.property // "")] | @tsv
      ' "$externalsecret_file" | strip_yq_stream_markers
    )
    for projection_id in "${!layer_expected_secret_projections[@]}"; do
      if [ -z "${actual_secret_projections[$projection_id]:-}" ]; then
        IFS=$'\t' read -r projected_secret_name projected_secret_key <<<"$projection_id"
        error "$externalsecret_rel: missing projection for $projected_secret_name/$projected_secret_key"
      elif [ "${actual_secret_projections[$projection_id]}" != \
        "${layer_expected_secret_projections[$projection_id]}" ]; then
        IFS=$'\t' read -r projected_secret_name projected_secret_key <<<"$projection_id"
        error "$externalsecret_rel: remoteRef key/property mismatch for $projected_secret_name/$projected_secret_key"
      fi
    done
    for projection_id in "${!actual_secret_projections[@]}"; do
      if [ -z "${layer_expected_secret_projections[$projection_id]:-}" ]; then
        IFS=$'\t' read -r projected_secret_name projected_secret_key <<<"$projection_id"
        error "$externalsecret_rel: unreferenced projection for $projected_secret_name/$projected_secret_key"
      fi
    done
    checked_externalsecret_mirrors=$((checked_externalsecret_mirrors + 1))
  done

  if [ -n "$rendered_file" ]; then
    if ! "$RENDERED_CLAIM_CHECK" --rendered "$rendered_file" --layer "$layer_rel" \
      --fixture "$FIXTURE" --quiet; then
      error "$layer_rel render: generated claim inventory failed"
    fi
    unset actual_layer_secret_ids
    declare -A actual_layer_secret_ids=()
    if [ -n "$secret_ref_pattern" ]; then
      while IFS=$'\t' read -r rendered_ref_id rendered_secret_name rendered_secret_key \
        rendered_literal_present; do
        [ -n "$rendered_ref_id" ] || continue
        [ -z "${actual_layer_secret_ids[$rendered_ref_id]:-}" ] || \
          error "$layer_rel render: duplicate generated secret reference '$rendered_ref_id'"
        actual_layer_secret_ids["$rendered_ref_id"]=1
        [ -n "$rendered_secret_name" ] && [ -n "$rendered_secret_key" ] && \
          [ "$rendered_literal_present" = false ] || \
          error "$layer_rel render: $rendered_ref_id must use secretKeyRef name/key and no literal value"
      done < <(
        # `$kind`, `$workload`, and `$container` are yq variables.
        # shellcheck disable=SC2016
        SECRET_REF_PATTERN="$secret_ref_pattern" yq e -r '
          select(.kind == "Deployment") | .kind as $kind | .metadata.name as $workload |
          .spec.template.spec.containers[]? | .name as $container | .env[]? |
          select(.name | test(strenv(SECRET_REF_PATTERN))) |
          [$kind + "/" + $workload + "/" + $container + "/" + .name,
           (.valueFrom.secretKeyRef.name // ""), (.valueFrom.secretKeyRef.key // ""), has("value")] | @tsv
        ' "$rendered_file" | strip_yq_stream_markers
      )
      for rendered_ref_id in "${!layer_fixture_secret_ids[@]}"; do
        [ -n "${actual_layer_secret_ids[$rendered_ref_id]:-}" ] || \
          error "$layer_rel render: projected secret reference '$rendered_ref_id' was not generated"
      done
      for rendered_ref_id in "${!actual_layer_secret_ids[@]}"; do
        [ -n "${layer_fixture_secret_ids[$rendered_ref_id]:-}" ] || \
          error "$layer_rel render: generated secret reference '$rendered_ref_id' is absent from the projection"
      done
    fi
  fi
done

while IFS=$'\t' read -r contract_id claim_id; do
  [ -n "$claim_id" ] || continue
  [ -n "${fixture_claim_ids[$claim_id]:-}" ] || \
    error "$CONTRACT: rendered claim $contract_id/$claim_id is missing from $FIXTURE"
done < <(yq e -r '.entries[] | select(.rendered_claim_id != null) | [.id, .rendered_claim_id] | @tsv' "$CONTRACT")

[ "$checked_implicit_default_claims" -eq 1 ] || \
  error "$FIXTURE: expected exactly one bounded implicit-default claim, checked $checked_implicit_default_claims"

if [ "$problems" -ne 0 ]; then
  printf '\nFAIL: rendered retention projection found %d problem(s).\n' "$problems" >&2
  printf '%s\n' 'Refresh the projection only after reviewing a verified render of the pinned chart package.' >&2
  exit 1
fi

mode="offline"
[ "$RENDER" = true ] && mode="verified-render"
printf 'PASS: %s retention projection covers %d chart claims (%d bounded implicit), %d secret references, %d ExternalSecret source projections across %d mirrors, %d pod selectors, and %d forbidden literal paths.\n' \
  "$mode" "$checked_claims" "$checked_implicit_default_claims" "$checked_secret_refs" "$checked_externalsecret_projections" \
  "$checked_externalsecret_mirrors" "$checked_pod_selectors" "$checked_forbidden_literals"
