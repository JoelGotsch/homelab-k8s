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
      */README.md|*/charts/*|*/testdata/*) continue ;;
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
fi

problems=0
checked_claims=0
checked_secret_refs=0
checked_pod_selectors=0
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
  declared_secret_ref_count="$(yq e -r ".layers[$layer_index].declared_secret_reference_count // \"\"" "$FIXTURE")"
  declared_pod_selector_count="$(yq e -r ".layers[$layer_index].declared_pod_selector_count // \"\"" "$FIXTURE")"
  secret_ref_pattern="$(yq e -r ".layers[$layer_index].secret_reference_env_pattern // \"\"" "$FIXTURE")"
  unset layer_fixture_claim_ids layer_fixture_secret_ids
  declare -A layer_fixture_claim_ids=()
  declare -A layer_fixture_secret_ids=()

  [ -n "$layer_rel" ] || { error "$FIXTURE: layer $layer_index has no path"; continue; }
  [ -d "$REPO_ROOT/$layer_rel" ] || { error "$FIXTURE: layer does not exist: $layer_rel"; continue; }
  [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || error "$FIXTURE: $layer_rel has invalid input digest"
  [[ "$package_digest" =~ ^[0-9a-f]{64}$ ]] || error "$FIXTURE: $layer_rel has invalid chart package digest"
  [ -n "$chart_name" ] || error "$FIXTURE: $layer_rel has no chart name"
  [ -n "$chart_repo" ] || error "$FIXTURE: $layer_rel has no chart repository"
  [ -n "$chart_version" ] || error "$FIXTURE: $layer_rel has no chart version"
  [ -n "$chart_app_version" ] || error "$FIXTURE: $layer_rel has no chart app_version"
  [[ "$declared_claim_count" =~ ^[0-9]+$ ]] || error "$FIXTURE: $layer_rel has invalid declared_claim_count"
  [[ "$declared_secret_ref_count" =~ ^[0-9]+$ ]] || \
    error "$FIXTURE: $layer_rel has invalid declared_secret_reference_count"
  [[ "$declared_pod_selector_count" =~ ^[0-9]+$ ]] || \
    error "$FIXTURE: $layer_rel has invalid declared_pod_selector_count"

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

  rendered_file=""
  if [ "$RENDER" = true ]; then
    layer_render_dir="$render_root/repo/$layer_rel"
    package_dir="$render_root/packages/$layer_index"
    mkdir -p "$package_dir" "$layer_render_dir/charts"
    helm pull "$chart_name" --repo "$chart_repo" --version "$chart_version" \
      --destination "$package_dir" >/dev/null
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

    [ -n "$contract_id" ] || { error "$FIXTURE: $layer_rel claim $claim_index has no contract_id"; continue; }
    [ -n "$claim_id" ] || { error "$FIXTURE: $contract_id has no rendered_claim_id"; continue; }
    [ -z "${fixture_claim_ids[$claim_id]:-}" ] || error "$FIXTURE: duplicate rendered claim id '$claim_id'"
    fixture_claim_ids["$claim_id"]="$contract_id"
    layer_fixture_claim_ids["$claim_id"]="$contract_id"

    contract_rows="$(CONTRACT_ID="$contract_id" yq e -r \
      '.entries[] | select(.id == strenv(CONTRACT_ID)) | [.rendered_claim_id, .current_storage_class] | @tsv' \
      "$CONTRACT" | strip_yq_stream_markers)"
    contract_count="$(printf '%s\n' "$contract_rows" | awk 'NF' | wc -l | tr -d ' ')"
    [ "$contract_count" -eq 1 ] || { error "$CONTRACT: expected exactly one entry $contract_id"; continue; }
    IFS=$'\t' read -r contract_claim_id contract_storage_class <<<"$contract_rows"
    [ "$contract_claim_id" = "$claim_id" ] || \
      error "$FIXTURE: $contract_id claim id '$claim_id' does not match contract '$contract_claim_id'"
    [ "$contract_storage_class" = "$storage_class" ] || \
      error "$FIXTURE: $contract_id class '$storage_class' does not match contract '$contract_storage_class'"
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

    if [ -n "$rendered_file" ]; then
      if [ "$kind" = "PersistentVolumeClaim" ]; then
        actual_claim_values="$(RESOURCE_NAME="$resource_name" yq e -r \
          'select(.kind == "PersistentVolumeClaim" and .metadata.name == strenv(RESOURCE_NAME)) | .spec.storageClassName' \
          "$rendered_file" | strip_yq_stream_markers)"
      else
        actual_claim_values="$(RESOURCE_NAME="$resource_name" CLAIM_NAME="$claim_name" yq e -r \
          'select(.kind == "StatefulSet" and .metadata.name == strenv(RESOURCE_NAME)) |
           .spec.volumeClaimTemplates[]? | select(.metadata.name == strenv(CLAIM_NAME)) | .spec.storageClassName' \
          "$rendered_file" | strip_yq_stream_markers)"
      fi
      actual_claim_count="$(printf '%s\n' "$actual_claim_values" | awk 'NF' | wc -l | tr -d ' ')"
      [ "$actual_claim_count" -eq 1 ] || \
        error "$layer_rel render: expected exactly one $kind/$claim_id claim selector, found $actual_claim_count"
      [ "$actual_claim_values" = "$storage_class" ] || \
        error "$layer_rel render: $claim_id class is '$actual_claim_values', fixture says '$storage_class'"
    fi
    checked_claims=$((checked_claims + 1))
  done

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
    source_name_path="$(yq e -r "$ref_base.source_name_path // \"\"" "$FIXTURE")"
    source_key_path="$(yq e -r "$ref_base.source_key_path // \"\"" "$FIXTURE")"
    externalsecret_rel="$(yq e -r "$ref_base.externalsecret_file // \"\"" "$FIXTURE")"
    ref_id="$workload_kind/$workload_name/$container_name/$env_name"

    for required_value in "$workload_kind" "$workload_name" "$container_name" "$env_name" \
      "$secret_name" "$secret_key" "$source_name_path" "$source_key_path" "$externalsecret_rel"; do
      [ -n "$required_value" ] || error "$FIXTURE: incomplete secret reference at $layer_rel index $secret_index"
    done
    [ -z "${secret_ref_ids[$ref_id]:-}" ] || error "$FIXTURE: duplicate secret reference '$ref_id'"
    secret_ref_ids["$ref_id"]=1
    layer_fixture_secret_ids["$ref_id"]=1
    [ "$secret_key" = "$env_name" ] || \
      error "$FIXTURE: $ref_id secret key '$secret_key' must equal its environment name"

    actual_source_name="$(yq e -r "$source_name_path // \"\"" "$values_file" | strip_yq_stream_markers)"
    actual_source_key="$(yq e -r "$source_key_path // \"\"" "$values_file" | strip_yq_stream_markers)"
    [ "$actual_source_name" = "$secret_name" ] || \
      error "$values_file_rel: $source_name_path is '$actual_source_name', expected '$secret_name'"
    [ "$actual_source_key" = "$secret_key" ] || \
      error "$values_file_rel: $source_key_path is '$actual_source_key', expected '$secret_key'"
    for ((mirror_index = 0; mirror_index < values_mirror_count; mirror_index++)); do
      mirror_rel="$(yq e -r ".layers[$layer_index].chart.values_mirrors[$mirror_index]" "$FIXTURE")"
      mirror_file="$REPO_ROOT/$layer_rel/$mirror_rel"
      [ -f "$mirror_file" ] || { error "$FIXTURE: missing values mirror $layer_rel/$mirror_rel"; continue; }
      mirror_source_name="$(yq e -r "$source_name_path // \"\"" "$mirror_file" | strip_yq_stream_markers)"
      mirror_source_key="$(yq e -r "$source_key_path // \"\"" "$mirror_file" | strip_yq_stream_markers)"
      [ "$mirror_source_name" = "$secret_name" ] || \
        error "$mirror_rel: $source_name_path is '$mirror_source_name', expected '$secret_name'"
      [ "$mirror_source_key" = "$secret_key" ] || \
        error "$mirror_rel: $source_key_path is '$mirror_source_key', expected '$secret_key'"
    done

    externalsecret_file="$REPO_ROOT/$externalsecret_rel"
    [ -f "$externalsecret_file" ] || { error "$FIXTURE: missing ExternalSecret source $externalsecret_rel"; continue; }
    projected_keys="$(SECRET_NAME="$secret_name" SECRET_KEY="$secret_key" yq e -r \
      'select(.kind == "ExternalSecret" and .spec.target.name == strenv(SECRET_NAME)) |
       .spec.data[]? | select(.secretKey == strenv(SECRET_KEY)) | .secretKey' \
      "$externalsecret_file" | strip_yq_stream_markers)"
    projected_key_count="$(printf '%s\n' "$projected_keys" | awk 'NF' | wc -l | tr -d ' ')"
    [ "$projected_key_count" -eq 1 ] || \
      error "$externalsecret_rel: expected exactly one projection for $secret_name/$secret_key, found $projected_key_count"

    if [ -n "$rendered_file" ]; then
      rendered_refs="$(WORKLOAD_KIND="$workload_kind" WORKLOAD_NAME="$workload_name" \
        CONTAINER_NAME="$container_name" ENV_NAME="$env_name" yq e -r \
        'select(.kind == strenv(WORKLOAD_KIND) and .metadata.name == strenv(WORKLOAD_NAME)) |
         .spec.template.spec.containers[]? | select(.name == strenv(CONTAINER_NAME)) |
         .env[]? | select(.name == strenv(ENV_NAME)) |
         [.valueFrom.secretKeyRef.name, .valueFrom.secretKeyRef.key, (.value // "")] | @tsv' \
        "$rendered_file" | strip_yq_stream_markers)"
      rendered_ref_count="$(printf '%s\n' "$rendered_refs" | awk 'NF' | wc -l | tr -d ' ')"
      [ "$rendered_ref_count" -eq 1 ] || \
        error "$layer_rel render: expected exactly one secret ref $ref_id, found $rendered_ref_count"
      expected_ref="$secret_name"$'\t'"$secret_key"$'\t'
      [ "$rendered_refs" = "$expected_ref" ] || \
        error "$layer_rel render: $ref_id is '$rendered_refs', expected secretKeyRef $secret_name/$secret_key and no literal value"
    fi
    checked_secret_refs=$((checked_secret_refs + 1))
  done

  if [ -n "$rendered_file" ]; then
    unset actual_layer_claim_ids actual_layer_secret_ids
    declare -A actual_layer_claim_ids=()
    declare -A actual_layer_secret_ids=()
    while IFS=$'\t' read -r rendered_claim_id rendered_storage_class; do
      [ -n "$rendered_claim_id" ] || continue
      [ -z "${actual_layer_claim_ids[$rendered_claim_id]:-}" ] || \
        error "$layer_rel render: duplicate generated claim identity '$rendered_claim_id'"
      actual_layer_claim_ids["$rendered_claim_id"]="$rendered_storage_class"
    done < <(
      # `$owner` is a yq variable, not a shell interpolation.
      # shellcheck disable=SC2016
      yq e -r '
        (select(.kind == "PersistentVolumeClaim" and
          ((.spec.storageClassName // "") | test("^longhorn"))) |
          [.metadata.name, .spec.storageClassName] | @tsv),
        (select(.kind == "StatefulSet") | .metadata.name as $owner |
          .spec.volumeClaimTemplates[]? |
          select(((.spec.storageClassName // "") | test("^longhorn"))) |
          [$owner + "/" + .metadata.name, .spec.storageClassName] | @tsv)
      ' "$rendered_file" | strip_yq_stream_markers
    )
    for rendered_claim_id in "${!layer_fixture_claim_ids[@]}"; do
      [ -n "${actual_layer_claim_ids[$rendered_claim_id]:-}" ] || \
        error "$layer_rel render: projected claim '$rendered_claim_id' was not generated"
    done
    for rendered_claim_id in "${!actual_layer_claim_ids[@]}"; do
      [ -n "${layer_fixture_claim_ids[$rendered_claim_id]:-}" ] || \
        error "$layer_rel render: generated Longhorn claim '$rendered_claim_id' is absent from the projection"
    done

    if [ -n "$secret_ref_pattern" ]; then
      while IFS=$'\t' read -r rendered_ref_id rendered_secret_name rendered_secret_key rendered_literal; do
        [ -n "$rendered_ref_id" ] || continue
        [ -z "${actual_layer_secret_ids[$rendered_ref_id]:-}" ] || \
          error "$layer_rel render: duplicate generated secret reference '$rendered_ref_id'"
        actual_layer_secret_ids["$rendered_ref_id"]=1
        [ -n "$rendered_secret_name" ] && [ -n "$rendered_secret_key" ] && [ -z "$rendered_literal" ] || \
          error "$layer_rel render: $rendered_ref_id must use secretKeyRef name/key and no literal value"
      done < <(
        # `$kind`, `$workload`, and `$container` are yq variables.
        # shellcheck disable=SC2016
        SECRET_REF_PATTERN="$secret_ref_pattern" yq e -r '
          select(.kind == "Deployment") | .kind as $kind | .metadata.name as $workload |
          .spec.template.spec.containers[]? | .name as $container | .env[]? |
          select(.name | test(strenv(SECRET_REF_PATTERN))) |
          [$kind + "/" + $workload + "/" + $container + "/" + .name,
           (.valueFrom.secretKeyRef.name // ""), (.valueFrom.secretKeyRef.key // ""), (.value // "")] | @tsv
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

if [ "$problems" -ne 0 ]; then
  printf '\nFAIL: rendered retention projection found %d problem(s).\n' "$problems" >&2
  printf '%s\n' 'Refresh the projection only after reviewing a verified render of the pinned chart package.' >&2
  exit 1
fi

mode="offline"
[ "$RENDER" = true ] && mode="verified-render"
printf 'PASS: %s retention projection covers %d chart claims, %d secret references, and %d pod selectors.\n' \
  "$mode" "$checked_claims" "$checked_secret_refs" "$checked_pod_selectors"
