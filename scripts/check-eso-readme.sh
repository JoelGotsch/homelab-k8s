#!/usr/bin/env bash
# Verify every kustomize layer that uses ExternalSecret has the
# canonical "## OpenBao paths to seed" section in its README.md.
#
# Per cold-start.md Step 13c convention: every ExternalSecret-using
# layer documents its OpenBao path inventory + first-install seed
# snippet in its own README.md. Without this, new apps adding ESO
# silently re-emerge the cold-start.md drift gap.
#
# Per the operator's "script everything scriptable now" policy
# (memory feedback_script-don-t-defer.md): this used to be
# "could be CI-linted later." It's not later anymore.
#
# Convention enforced:
# - For each ExternalSecret manifest under apps/<x>/ or
#   infrastructure/<x>/ or platform/<x>/ or observability/<x>/,
#   the parent dir MUST contain README.md with a
#   "## OpenBao paths to seed" heading (case-sensitive).
# - The check intentionally does not validate the *contents* of
#   the section — too much false-positive risk. Pairing presence
#   is the load-bearing property.
#
# Exit 0 = clean. Exit 1 = at least one gap.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Find every ExternalSecret manifest. Two patterns:
# - filename includes 'externalsecret' (case-insensitive)
# - file contains `kind: ExternalSecret`
# We use the filename pattern as primary (avoids parsing yaml in
# bash); content scan as fallback to catch atypical names.

# Vendored upstream charts excluded ('*/charts/*'): the ESO chart
# ships its own CRD files matching '*externalsecret*' (e.g.
# charts/external-secrets-0.10.5/.../templates/crds/) — those are
# not first-party layers (false positive found 2026-07-19; same
# fix as docs' check-cold-start-completeness.sh, which duplicates
# this logic).
eso_dirs=$(
  {
    find apps infrastructure platform observability -type f \
      \( -iname '*externalsecret*.yaml' -o -iname '*externalsecret*.yml' \) \
      ! -iname '*.template.yaml' ! -iname '*.j2' \
      -not -path '*/charts/*' \
      -printf '%h\n' 2>/dev/null
    grep -rln '^kind: ExternalSecret' apps infrastructure platform observability \
      --include='*.yaml' --include='*.yml' \
      --exclude='*.template.yaml' --exclude='*.j2' \
      --exclude-dir=charts 2>/dev/null \
      | xargs -I{} dirname {}
  } | sort -u
)

if [ -z "$eso_dirs" ]; then
  echo "OK: no ExternalSecret manifests found (nothing to check)."
  exit 0
fi

failed=0
for dir in $eso_dirs; do
  readme="$dir/README.md"
  if [ ! -f "$readme" ]; then
    echo "FAIL: $dir/ has ExternalSecret(s) but no README.md" >&2
    failed=1
    continue
  fi
  if ! grep -qF '## OpenBao paths to seed' "$readme"; then
    echo "FAIL: $readme is missing '## OpenBao paths to seed' section" >&2
    echo "      (parent dir contains ExternalSecret manifest(s); per cold-start.md Step 13c convention)" >&2
    failed=1
  fi
done

if [ "$failed" -eq 0 ]; then
  count=$(echo "$eso_dirs" | wc -l | tr -d ' ')
  echo "OK: all $count ExternalSecret-using layer(s) have the seed-paths section."
  exit 0
fi

cat >&2 <<'EOF'

To fix, add this section to the offending README.md:

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).
ExternalSecret in `externalsecret.yaml` projects these into the
namespace; without them, the pod fails to start.

| Path | Keys | Source |
|---|---|---|
| `kv/<...>` | `<key>` | `<how to obtain>` |

**First-install seed:**

```sh
bao kv put kv/<...> <key>="<value>"
```

Then add a row to cold-start.md Step 13c's inventory table linking to this section.
EOF
exit 1
