#!/usr/bin/env bash
# Prove the installed Authentik chart consumes the security-context keys.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
layer="$repo_root/platform/authentik"
helm_bin="${HELM_BIN:-helm3}"

for command in "$helm_bin" yq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "FAIL: $command is required for the Authentik security render gate" >&2
    exit 1
  }
done

chart_name="$(yq -r '.helmCharts[0].name' "$layer/kustomization.yaml")"
chart_repo="$(yq -r '.helmCharts[0].repo' "$layer/kustomization.yaml")"
chart_version="$(yq -r '.helmCharts[0].version' "$layer/kustomization.yaml")"
values_file="$(yq -r '.helmCharts[0].valuesFile' "$layer/kustomization.yaml")"

work="$(mktemp -d)"
trap 'rm -r "$work"' EXIT
"$helm_bin" template authentik "${chart_repo%/}/$chart_name" \
  --version "$chart_version" --namespace authentik \
  --values "$layer/$values_file" >"$work/rendered.yaml"

for workload in server worker; do
  pod_context="$(
    yq -r -N "select(.kind == \"Deployment\" and .metadata.name == \"authentik-$workload\") |
      [.spec.template.spec.securityContext.runAsNonRoot,
       .spec.template.spec.securityContext.runAsUser,
       .spec.template.spec.securityContext.runAsGroup,
       .spec.template.spec.securityContext.fsGroup,
       .spec.template.spec.securityContext.seccompProfile.type] | @tsv" \
      "$work/rendered.yaml" | sed '/^$/d'
  )"
  if [ "$pod_context" != $'true\t1000\t1000\t1000\tRuntimeDefault' ]; then
    echo "FAIL: authentik-$workload pod security context is not rendered" >&2
    exit 1
  fi

  container_context="$(
    yq -r -N "select(.kind == \"Deployment\" and .metadata.name == \"authentik-$workload\") |
      .spec.template.spec.containers[] | select(.name == \"$workload\") |
      [.securityContext.allowPrivilegeEscalation,
       .securityContext.readOnlyRootFilesystem,
       (.securityContext.capabilities.drop | join(\",\"))] | @tsv" \
      "$work/rendered.yaml" | sed '/^$/d'
  )"
  if [ "$container_context" != $'false\ttrue\tALL' ]; then
    echo "FAIL: authentik-$workload container security context is not rendered" >&2
    exit 1
  fi
done

echo "OK: Authentik server and worker render explicit uid-1000 restricted contexts."
