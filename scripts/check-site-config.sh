#!/usr/bin/env bash
# check-site-config.sh — internal consistency of the single-source site config.
#
# site-config.env holds a few DERIVED keys (forgejo_fqdn) because kustomize
# `replacements` substitute whole delimiter-tokens and cannot compose
# "forgejo." + fqdn_suffix inside a URL token (phase-2 migration, 2026-07-19).
# Derivation drift would silently point repoURLs at the wrong host, so this
# lint makes the derivations impossible to get wrong:
#   fqdn_suffix   == <internal_subdomain>.<domain>
#   forgejo_fqdn  == forgejo.<fqdn_suffix>
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=components/site-config/site-config.env
get() { grep -E "^$1=" "$ENV" | head -1 | cut -d= -f2-; }
fail=0
domain=$(get domain); sub=$(get internal_subdomain); fqdn=$(get fqdn_suffix); fj=$(get forgejo_fqdn)
[ "$fqdn" = "$sub.$domain" ] || { echo "FAIL: fqdn_suffix '$fqdn' != '$sub.$domain'"; fail=1; }
[ -z "$fj" ] || [ "$fj" = "forgejo.$fqdn" ] || { echo "FAIL: forgejo_fqdn '$fj' != 'forgejo.$fqdn'"; fail=1; }
# every FQDN_SUFFIX / FORGEJO_FQDN placeholder must sit in a kustomization
# that pulls the site-config component (else it renders literally).
while IFS= read -r f; do
  dir=$(dirname "$f")
  k="$dir/kustomization.yaml"
  # bootstrap/argocd patches resolve via the parent kustomization
  [ -f "$k" ] || k="$(dirname "$dir")/kustomization.yaml"
  grep -q 'components/site-config' "$k" 2>/dev/null || { echo "FAIL: $f has a placeholder but $k lacks the site-config component"; fail=1; }
done < <(grep -rlE 'FQDN_SUFFIX|FORGEJO_FQDN' --include='*.yaml' apps platform observability infrastructure bootstrap 2>/dev/null)
[ "$fail" -eq 0 ] && echo "OK: site-config internally consistent; all placeholders component-backed."
exit "$fail"
