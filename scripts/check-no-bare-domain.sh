#!/usr/bin/env bash
# check-no-bare-domain.sh — no value-bearing field hardcodes the site domain.
#
# SYNCED SCRIPT: the canonical copy is homelab-hooks/scripts/ (ADR 0047,
# Track G1, 2026-08-16); homelab-k8s/scripts/ keeps a byte-identical
# copies live in every app repo's scripts/. Change the canonical one, sync all.
#
# It said "TRI-REPO SYNCED … and homelab-docs/scripts/" until 2026-08-15. That
# was never true: homelab-docs carries no site-config, so this check would
# SKIP there anyway, and no copy was ever placed in it. The header claimed a
# third home to keep symmetry with check-no-mac-addresses.sh, which genuinely
# is tri-repo. Corrected rather than made true — a copy that always skips is
# a copy that rots.
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

# ── Locate the site-config this repo carries, and with it the paths whose
#    contents the CLUSTER consumes. homelab-k8s keeps site-config at the top
#    level and reconciles six directories; an app repo vendors it under k8s/
#    and reconciles that one directory (ADR 0001 — an app repo must build
#    standalone).
#
#    Why scope at all (added 2026-08-15): before this, the check read every
#    tracked YAML in the repo. `.pre-commit-config.yaml` and `.woodpecker.yml`
#    name the Forgejo host in order to CLONE THE SHARED HOOKS — they are read
#    by pre-commit and by Woodpecker, never by the cluster — and so failed the
#    check in five app repos, which is why nothing could commit through it.
#    That is not the defect ADR 0045 describes: redeploying at another site
#    rebuilds its own CI wiring, and the hook source is that wiring. Scoping to
#    the reconciled paths removes the false positives BY CONSTRUCTION, which is
#    honest, instead of allowlisting two filenames forever, which would also
#    have exempted them if they ever did carry a cluster value.
SITE_CONFIG=""
SCOPE_REGEX=""
if [ -f components/site-config/site-config.env ]; then
  SITE_CONFIG="components/site-config/site-config.env"
  SCOPE_REGEX='^(infrastructure|platform|observability|apps|components|bootstrap)/'
elif [ -f k8s/components/site-config/site-config.env ]; then
  SITE_CONFIG="k8s/components/site-config/site-config.env"
  SCOPE_REGEX='^k8s/'
fi

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

# ── Which repo is this? The known-violations list below is shared by every
#    copy of this script, so an unqualified path exempts that path in ALL of
#    them: `^k8s/values\.yaml$` meant "any app repo may hardcode the domain in
#    its values.yaml", which is four repos' worth of exemption bought by one
#    repo's debt. Entries are therefore keyed `<repo>:<path>`.
REPO_NAME="$(basename "$(git rev-parse --show-toplevel)")"
# ADR 0048 renames every manifest-only repo to `<app>-k8s`. Strip that suffix
# so a rename does not silently void a line below (the check would then pass
# by accident, which is worse than failing). `homelab-k8s` is not one of those
# renames — it is the repo's own name — so it keeps its own key.
[ "$REPO_NAME" = "homelab-k8s" ] || REPO_NAME="${REPO_NAME%-k8s}"

# ── Known violations, dated, to be emptied by ADR 0045 phase 2.
#
# These are REAL hardcoded values that predate this check. They are listed so
# the check can land and gate new regressions immediately (phase 1) while the
# migration onto replacements happens per-app (phase 2). Deleting a line here
# is how phase 2 records progress; the list must only ever shrink.
#
# Cleared:
#   2026-08-14  k8s/deployment.yaml + apps/immich-public-proxy/deployment.yaml
#               immich-public-proxy PUBLIC_BASE_URL now resolves from
#               site-config; render verified byte-identical.
#   2026-08-15  the four `^apps/…` entries (nextcloud, paperless, ntfy,
#               vaultwarden) were unreachable, not fixed: each of those legacy
#               central copies carries a `.yaml.j2` sibling, so the exemption
#               at the bottom of the loop already skipped them and these lines
#               exempted nothing. Removed rather than left to read as debt
#               that is being paid. NOTE FOR ADR 0045 C2.6: when the `.j2`
#               sibling exemption is replaced by a named exception list, those
#               eight legacy `apps/*` files become live findings again unless
#               the guarded `apps/*` cleanup has deleted them first. Do the
#               cleanup first, or re-add them here for the interval.
KNOWN_VIOLATIONS_REGEX='^nextcloud:k8s/values\.yaml$'

# Use staged files as a pre-commit hook; otherwise everything tracked. Both
# lists are narrowed to SCOPE_REGEX — a file the cluster never reads cannot
# break portability, and pretending otherwise is what blocked commits.
if [ -n "${PRE_COMMIT:-}" ] || [ "${1:-}" = "--staged" ]; then
  files=$(git diff --cached --name-only --diff-filter=ACM \
            | grep -E '\.(yaml|yml)$' | grep -E "$SCOPE_REGEX" || true)
else
  files=$(git ls-files '*.yaml' '*.yml' | grep -E "$SCOPE_REGEX" || true)
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

  if echo "$REPO_NAME:$f" | grep -qE "$KNOWN_VIOLATIONS_REGEX"; then
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

checked=$(echo "$files" | grep -c . || true)
if [ "$known" -gt 0 ]; then
  echo "OK: no new bare-domain values in $checked file(s) matching $SCOPE_REGEX ($known known violation(s) pending ADR 0045 phase 2)."
else
  echo "OK: no value hardcodes '$DOMAIN_LITERAL' in $checked file(s) matching $SCOPE_REGEX."
fi
exit 0
