#!/usr/bin/env bash
# Prevent recurrence of the two configuration errors that hid first-party
# registry failure behind warm node caches:
#   1. Spegel wildcard/first-party ownership displacing Talos registry hosts.
#   2. registry-direct resolving the headless Forgejo Service only at startup.

set -euo pipefail

SPEGEL_VALUES="infrastructure/spegel/values.yaml"
REGISTRY_DIRECT="platform/forgejo/registry-direct.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[ -f "$SPEGEL_VALUES" ] || fail "$SPEGEL_VALUES not found; run from repo root"
[ -f "$REGISTRY_DIRECT" ] || fail "$REGISTRY_DIRECT not found; run from repo root"

mirror_scope=$(awk '
  /^  mirroredRegistries:/ { capture=1; next }
  capture && /^  [[:alnum:]_]/ { exit }
  capture { print }
' "$SPEGEL_VALUES")

[ -n "$mirror_scope" ] || fail "Spegel mirroredRegistries must be an explicit non-empty list"
if grep -Eq '(^|[[:space:]])(\*|https?://\*)($|[[:space:]])' <<<"$mirror_scope"; then
  fail "Spegel must never mirror all registries on Talos"
fi
if grep -Eq 'registry\.homelab\.internal|forgejo\.lab\.vyramo\.com' <<<"$mirror_scope"; then
  fail "Spegel must not own Talos first-party registry host directories"
fi

for registry in docker.io ghcr.io quay.io registry.k8s.io gcr.io; do
  grep -Fq -- "- https://$registry" <<<"$mirror_scope" \
    || fail "Spegel third-party scope is missing $registry"
done
mirror_count=$(grep -Ec '^[[:space:]]*-[[:space:]]+https://' <<<"$mirror_scope")
[ "$mirror_count" -eq 5 ] \
  || fail "Spegel scope must contain exactly the five reviewed third-party registries"

grep -Fq 'server forgejo-http.forgejo.svc.cluster.local:3000 resolve;' "$REGISTRY_DIRECT" \
  || fail "registry-direct must dynamically resolve the headless Forgejo Service"
grep -Fq 'zone forgejo_backend ' "$REGISTRY_DIRECT" \
  || fail "dynamic registry upstream requires a shared-memory zone"
grep -Fq 'resolver 10.96.0.10 ' "$REGISTRY_DIRECT" \
  || fail "dynamic registry upstream requires the trusted cluster DNS resolver"
grep -Fq 'httpGet: {path: /readyz, port: 8443, scheme: HTTPS}' "$REGISTRY_DIRECT" \
  || fail "registry-direct readiness must exercise its Forgejo upstream"
grep -Eq 'nginx-unprivileged:[^[:space:]]+@sha256:[0-9a-f]{64}' "$REGISTRY_DIRECT" \
  || fail "registry-direct image must be digest pinned"

echo "OK: registry critical-path ownership, resolution, readiness, and pinning are guarded"
