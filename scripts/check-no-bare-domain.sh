#!/usr/bin/env bash
# check-no-bare-domain.sh — no value-bearing field hardcodes the site domain.
#
# TRI-REPO SYNCED SCRIPT: byte-identical copies live in homelab-k8s/scripts/,
# homelab-docs/scripts/ and every app repo's scripts/. Change one, sync all
# (enforced by the "tri-repo synced scripts are byte-identical" hook).
#
# ADR 0045: the workspace must be redeployable at another site with another
# domain, so a domain literal may never sit in a value the cluster consumes.
# Values resolve from the kustomize `site-config` component instead.
#
# Two things this deliberately changed on 2026-08-13 (ADR 0045 phase 1):
#
#   1. The old exemption was "a `.yaml.j2` sibling exists" — i.e. it treated
#      *being ansible-rendered* as the definition of correct. ADR 0045 D1
#      retires that model (the reconciler owns the file; Argo-reconciled paths
#      use site-config replacements), and the seven orphaned .j2 in app repos
#      were deleted, so the exemption pointed at files that no longer exist.
#
#   2. The domain literal was hardcoded IN THIS SCRIPT — itself the thing it
#      forbids. It is now read from the site-config the repo already carries,
#      so a domain change does not need this file edited.
#
# What counts as a violation: the literal in a **value position**. Comments are
# allowed — they are documentation, they do not break portability, and
# homelab-docs/scripts/check-hostnames.sh already catches a *wrong* hostname
# anywhere it appears. This is narrower and more honest than the old
# any-occurrence rule.

set -euo pipefail

err() { echo "ERROR: $*" >&2; }

# ── Locate the site-config this repo carries. homelab-k8s keeps it at the
#    top level; an app repo vendors it under k8s/ (ADR 0001 — an app repo must
#    build standalone).
SITE_CONFIG=""
for candidate in \
  components/site-config/site-config.env \
  k8s/components/site-config/site-config.env
do
  [ -f "$candidate" ] && { SITE_CONFIG="$candidate"; break; }
done

if [ -z "$SITE_CONFIG" ]; then
  echo "SKIP: no components/site-config/site-config.env in this repo — nothing to check" >&2
  exit 0
fi

DOMAIN_LITERAL="$(grep -E '^domain=' "$SITE_CONFIG" | head -1 | cut -d= -f2-)"
[ -n "$DOMAIN_LITERAL" ] || { err "no domain= in $SITE_CONFIG"; exit 1; }

# ── Allowlist: paths where the literal is documentation, not configuration.
#
#   READMEs             worked examples.
#   authentik blueprints rendered from ONE template + an inventory, so no
#                       per-app .j2 sibling exists by design.
#   site-config.env     the declaration itself.
ALLOWLIST_REGEX='(^|/)README\.md$|^platform/authentik/blueprints/[^/]+\.yaml$|site-config\.env$'

# ── Known violations, dated, to be emptied by ADR 0045 phase 2.
#
# These are REAL hardcoded values that predate this check. They are listed so
# the check can land and gate new regressions immediately (phase 1) while the
# migration onto replacements happens per-app (phase 2). Deleting a line here
# is how phase 2 records progress; the list must only ever shrink.
KNOWN_VIOLATIONS_REGEX='^k8s/values\.yaml$|^k8s/configmap\.yaml$|^k8s/deployment\.yaml$|^apps/nextcloud/values\.yaml$|^apps/paperless/values\.yaml$|^apps/ntfy/configmap\.yaml$|^apps/immich-public-proxy/deployment\.yaml$|^apps/vaultwarden/values\.yaml$'

# Use staged files as a pre-commit hook; otherwise everything tracked.
if [ -n "${PRE_COMMIT:-}" ] || [ "${1:-}" = "--staged" ]; then
  files=$(git diff --cached --name-only --diff-filter=ACM \
            | grep -E '\.(yaml|yml)$' || true)
else
  files=$(git ls-files '*.yaml' '*.yml')
fi

violations=0
known=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  echo "$f" | grep -qE "$ALLOWLIST_REGEX" && continue

  # A `.j2` sibling still exempts — but only because the ORPHANS were deleted
  # on 2026-08-13. Before that, seven app-repo files carried a .j2 that nothing
  # rendered, so this test passed for files that were in fact hand-edited. The
  # remaining .j2 under homelab-k8s all appear in 00-render-static.yml's list,
  # which is what makes the signal trustworthy again.
  #
  # ADR 0045 D1's end state is no .j2 under an Argo-reconciled path at all; when
  # that lands, this branch goes away and those files move to the migration list.
  [ -e "${f}.j2" ] && continue

  # Strip full-line comments and trailing comments before matching, so only a
  # value position can trip the check.
  if ! sed -e 's/[[:space:]]*#.*$//' "$f" | grep -q "$DOMAIN_LITERAL" 2>/dev/null; then
    continue
  fi

  if echo "$f" | grep -qE "$KNOWN_VIOLATIONS_REGEX"; then
    known=$((known + 1))
    continue
  fi

  err "$f hardcodes '$DOMAIN_LITERAL' in a value position."
  violations=$((violations + 1))
done <<< "$files"

if [ "$violations" -gt 0 ]; then
  cat >&2 <<EOF

Fix by resolving the value from the site-config component instead of
typing the domain:

  components:
    - components/site-config
  replacements:
    - source: { kind: ConfigMap, name: site-config, fieldPath: data.fqdn_suffix }
      targets:
        - select: { kind: <Kind>, name: <name> }
          fieldPaths: [<field>]
          options: { delimiter: '.', index: 1 }

jellyfin/k8s is the reference implementation. For a value that lands inside
a helmCharts valuesFile, target the RENDERED resource (e.g. the ConfigMap
field) — a replacement cannot reach inside the values file itself.

If the literal is genuinely documentation, put it in a comment or a README.

See ADR 0045 and homelab-docs/04-guides/config-single-declaration-rollout.md.
EOF
  exit 1
fi

if [ "$known" -gt 0 ]; then
  echo "OK: no new bare-domain values ($known known violation(s) pending ADR 0045 phase 2)."
else
  echo "OK: no value hardcodes '$DOMAIN_LITERAL'."
fi
exit 0
