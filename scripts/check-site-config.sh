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
#   auth_fqdn     == auth.<fqdn_suffix>
#   forgejo_layer_repo_url == the Forgejo URL, or the GitHub mirror URL
set -euo pipefail
cd "$(dirname "$0")/.."
ENV=components/site-config/site-config.env
get() { grep -E "^$1=" "$ENV" | head -1 | cut -d= -f2-; }
fail=0
domain=$(get domain); sub=$(get internal_subdomain); fqdn=$(get fqdn_suffix); fj=$(get forgejo_fqdn)
auth=$(get auth_fqdn); gh=$(get operator_github_user); layer=$(get forgejo_layer_repo_url)
[ "$fqdn" = "$sub.$domain" ] || { echo "FAIL: fqdn_suffix '$fqdn' != '$sub.$domain'"; fail=1; }
[ -z "$fj" ] || [ "$fj" = "forgejo.$fqdn" ] || { echo "FAIL: forgejo_fqdn '$fj' != 'forgejo.$fqdn'"; fail=1; }
# auth_fqdn was added for the OIDC issuer replacement (Track C) and was NOT
# covered here, so it could drift from fqdn_suffix unnoticed — the same class
# of silent-wrong-host bug this script exists for.
[ -z "$auth" ] || [ "$auth" = "auth.$fqdn" ] || { echo "FAIL: auth_fqdn '$auth' != 'auth.$fqdn'"; fail=1; }
# forgejo_layer_repo_url is deliberately flippable, but only between exactly
# two values. Anything else means platform/forgejo is reconciling from a
# repository nobody declared — including, at the wrong moment, one that is down.
if [ -n "$layer" ]; then
  fj_url="https://$fj/homelab/homelab-k8s"
  gh_url="https://github.com/$gh/homelab-k8s"
  case "$layer" in
    "$fj_url") : ;;
    "$gh_url") echo "NOTE: forgejo_layer_repo_url is on the GitHub MIRROR ($gh_url)."
               echo "      That is the ADR 0051 B7 break-glass position. Flip it back to"
               echo "      $fj_url once the Forgejo window is closed." ;;
    *) echo "FAIL: forgejo_layer_repo_url '$layer' is neither"
       echo "      '$fj_url' nor '$gh_url'"; fail=1 ;;
  esac
fi
# Every site-config placeholder must sit in a kustomization that pulls the
# site-config component (else it renders literally — `https://FORGEJO_FQDN`
# reaches a pod as a DNS failure, `OPERATOR_GITHUB_USER` reaches a paged
# operator as a 404 runbook link).
#
# AUTH_FQDN and OPERATOR_GITHUB_USER joined the list on 2026-08-20 with the
# ADR 0045 C2 `.j2` migration: they are site-config keys like the others, and
# a token nothing checks is a token that renders literally.
while IFS= read -r f; do
  dir=$(dirname "$f")
  k="$dir/kustomization.yaml"
  # bootstrap/argocd patches resolve via the parent kustomization
  [ -f "$k" ] || k="$(dirname "$dir")/kustomization.yaml"
  # Match a real `components:` LIST ENTRY, not any mention of the path.
  # Until 2026-08-20 this was `grep -q 'components/site-config'`, which every
  # converted layer now satisfies from the provenance comment above its
  # `replacements:` block ("-> components/site-config/site-config.env").
  # Deleting the component itself then left the check green while the
  # placeholder rendered literally — proven by deleting it from
  # infrastructure/backup-cronjobs and watching this script still say OK.
  # Anchored to `site-config` at a path boundary so `site-config-example`
  # cannot stand in for it either.
  grep -qE '^[[:space:]]*-[[:space:]]+[^#]*components/site-config([[:space:]]|$)' "$k" 2>/dev/null \
    || { echo "FAIL: $f has a placeholder but $k lacks the site-config component"; fail=1; }
done < <(grep -rlE 'FQDN_SUFFIX|FORGEJO_FQDN|FORGEJO_LAYER_REPO_URL|AUTH_FQDN|OPERATOR_GITHUB_USER' --include='*.yaml' apps platform observability infrastructure bootstrap 2>/dev/null)
[ "$fail" -eq 0 ] && echo "OK: site-config internally consistent; all placeholders component-backed."
exit "$fail"
