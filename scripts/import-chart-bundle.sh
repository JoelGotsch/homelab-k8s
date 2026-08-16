#!/usr/bin/env bash
# import-chart-bundle.sh — push a chart bundle back into a fresh registry.
#
# The other half of export-chart-bundle.sh, and the step that makes ADR 0052's
# cold-start claim true: after a rebuild, Forgejo Packages is empty, so every
# layer that references the mirror cannot render until the charts are back.
#
# ORDER OF OPERATIONS ON A COLD START
#
#   1. Ansible installs the tier-0 chain FROM THE BUNDLE FILES directly
#      (`kubernetes.core.helm chart_ref: <bundle>/<name>-<ver>.tgz`) — not from
#      the registry, which does not exist yet.
#   2. Forgejo comes up.
#   3. THIS SCRIPT repopulates the mirror.
#   4. Argo takes over and every layer renders from the mirror again.
#
# It verifies before it pushes: artifact hashes against the `.sha256` files, and
# it refuses to run at all if any file fails. A bundle that has rotted in
# storage is worse than no bundle, because it is trusted.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '  %s\n' "$*"; }

HELM_BIN="${HELM_BIN:-helm3}"
CA_FILE="${CA_FILE:-$HOME/.config/homelab/ca.pem}"
ORG="${ORG:-homelab}"

usage() {
  cat >&2 <<EOF
usage: $0 [--dry-run|--apply] <bundle-dir> [registry-host]

  Verifies every artifact against its .sha256, then pushes each chart to
  oci://<registry-host>/<org>. Default registry: registry.homelab.internal

  Credentials come from OpenBao (kv/shared/forgejo-packages/ci) when available,
  otherwise from HELM_REGISTRY_USER / HELM_REGISTRY_PASSWORD — a cold start may
  not have OpenBao yet, which is the whole point of this script.
EOF
  exit 2
}

APPLY=false
case "${1:-}" in
  --apply) APPLY=true; shift ;;
  --dry-run) APPLY=false; shift ;;
  -h|--help) usage ;;
esac
[ "$#" -ge 1 ] || usage
BUNDLE="$1"; REGISTRY="${2:-registry.homelab.internal}"

[ -d "$BUNDLE" ] || { err "no such bundle directory: $BUNDLE"; exit 1; }
command -v "$HELM_BIN" >/dev/null 2>&1 || { err "$HELM_BIN not found"; exit 1; }

# ── Verify FIRST, entirely, before pushing anything.
echo "── verifying $BUNDLE"
bad=0; n=0
for sum in "$BUNDLE"/*.tgz.sha256; do
  [ -e "$sum" ] || { err "bundle contains no .sha256 files — refusing to trust it"; exit 1; }
  n=$((n+1))
  ( cd "$BUNDLE" && shasum -a 256 -c "$(basename "$sum")" >/dev/null 2>&1 ) \
    || { err "checksum FAILED: $(basename "${sum%.sha256}")"; bad=$((bad+1)); }
done
if [ "$bad" -gt 0 ]; then
  err "$bad of $n artifacts failed verification — not pushing anything."
  note "A bundle that has rotted in storage is worse than no bundle: it is trusted."
  exit 1
fi
note "$n artifact(s) verified against their recorded hashes"

if [ "$APPLY" != true ]; then
  echo
  note "dry-run — verified only, nothing pushed. Re-run with --apply."
  exit 0
fi

# ── Credentials. OpenBao if reachable; env vars otherwise (cold start).
user="${HELM_REGISTRY_USER:-}"; pass="${HELM_REGISTRY_PASSWORD:-}"
if [ -z "$user" ] && command -v bao >/dev/null 2>&1; then
  user="$(bao kv get -mount=kv -field=username shared/forgejo-packages/ci 2>/dev/null || true)"
  pass="$(bao kv get -mount=kv -field=token    shared/forgejo-packages/ci 2>/dev/null || true)"
fi
[ -n "$user" ] && [ -n "$pass" ] || {
  err "no registry credentials. Set HELM_REGISTRY_USER/HELM_REGISTRY_PASSWORD, or make OpenBao reachable."
  exit 1
}
login_args=()
[ -f "$CA_FILE" ] && login_args=(--ca-file "$CA_FILE")
printf '%s' "$pass" | "$HELM_BIN" registry login "$REGISTRY" "${login_args[@]}" -u "$user" --password-stdin >/dev/null 2>&1 \
  || { err "helm registry login failed for $REGISTRY"; exit 1; }
unset pass

pushed=0; failed=0
for tgz in "$BUNDLE"/*.tgz; do
  name="$(basename "$tgz")"
  if "$HELM_BIN" push "$tgz" "oci://$REGISTRY/$ORG" "${login_args[@]}" >/dev/null 2>&1; then
    note "pushed $name"; pushed=$((pushed+1))
  else
    err "push failed: $name"; failed=$((failed+1))
  fi
done

echo
echo "── state"
echo "   verified : $n"
echo "   pushed   : $pushed"
echo "   failed   : $failed"
echo
note "Now confirm the cluster agrees: scripts/check-chart-lock.sh --online"
[ "$failed" -gt 0 ] && exit 1
exit 0
