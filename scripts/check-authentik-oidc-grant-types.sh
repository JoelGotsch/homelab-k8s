#!/usr/bin/env bash
# Every generated OAuth2 blueprint must survive a cold start with usable grants.

set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
blueprint_dir="$repo_root/platform/authentik/blueprints"
failed=0
checked=0

while IFS= read -r blueprint; do
  rg -q '^# BEGIN ANSIBLE-RENDERED HEADER' "$blueprint" || continue
  rg -q 'model: authentik_providers_oauth2\.oauth2provider' "$blueprint" || continue
  checked=$((checked + 1))
  for required in \
    '^      grant_types:$' \
    '^        - authorization_code$' \
    '^        - refresh_token$'; do
    if ! rg -q "$required" "$blueprint"; then
      echo "FAIL: ${blueprint#"$repo_root/"} lacks the safe generated grant contract" >&2
      failed=1
      break
    fi
  done
done < <(git ls-files "$blueprint_dir/*.yaml")

[ "$checked" -gt 0 ] || {
  echo "FAIL: no generated Authentik OAuth2 blueprints were checked" >&2
  exit 1
}
[ "$failed" -eq 0 ] || exit 1
echo "OK: $checked generated Authentik providers allow authorization_code + refresh_token."
