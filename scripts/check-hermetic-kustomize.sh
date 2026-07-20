#!/usr/bin/env bash
# Exercise the wrapper and prove the self-managed Argo layer actually mounts it.
set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)

# Argo implements source.kustomize overrides by running `kustomize edit` before
# `kustomize build`. The wrapper snapshots only the build, so those edits would
# be lost. No current Application uses that surface; fail closed if one appears
# until the wrapper is replaced by a per-request CMP or gains session isolation.
if rg -n '^\s+kustomize:' "$repo_root/bootstrap/applicationsets"; then
  echo "FAIL: ApplicationSet source.kustomize overrides are incompatible with the hermetic wrapper" >&2
  exit 1
fi

"$repo_root/scripts/test-hermetic-kustomize.sh"

rendered=$(mktemp "${TMPDIR:-/tmp}/rendered-hermetic-kustomize.XXXXXX")
trap 'rm -f -- "$rendered"' EXIT INT TERM
kustomize build "$repo_root/bootstrap/argocd" >"$rendered"

config_name=$(yq ea -r 'select(.kind == "ConfigMap") | .metadata.name' "$rendered" |
  grep '^argocd-hermetic-kustomize-' || true)
[[ -n "$config_name" ]] || { echo "FAIL: rendered wrapper ConfigMap missing" >&2; exit 1; }

repo_server='select(.kind == "Deployment" and .metadata.name == "argocd-repo-server")'
path_value=$(yq ea -r "$repo_server | .spec.template.spec.containers[] |
  select(.name == \"argocd-repo-server\") | .env[] | select(.name == \"PATH\") | .value" "$rendered")
[[ "$path_value" == /opt/homelab-kustomize:* ]] || {
  echo "FAIL: hermetic wrapper is not first in repo-server PATH" >&2
  exit 1
}
mount_value=$(yq ea -r "$repo_server | .spec.template.spec.containers[] |
  select(.name == \"argocd-repo-server\") | .volumeMounts[] |
  select(.name == \"hermetic-kustomize\") | [.mountPath, .readOnly] | @tsv" "$rendered")
[[ "$mount_value" == $'/opt/homelab-kustomize/kustomize\ttrue' ]] || {
  echo "FAIL: repo-server wrapper mount is missing or writable" >&2
  exit 1
}
volume_config=$(yq ea -r "$repo_server | .spec.template.spec.volumes[] |
  select(.name == \"hermetic-kustomize\") | .configMap.name" "$rendered")
[[ "$volume_config" == "$config_name" ]] || {
  echo "FAIL: repo-server volume does not reference generated ConfigMap" >&2
  exit 1
}

echo "PASS: self-managed Argo renders with the hermetic Kustomize wrapper mounted"
