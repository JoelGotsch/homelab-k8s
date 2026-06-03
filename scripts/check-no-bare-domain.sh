#!/usr/bin/env bash
# Detect hardcoded operator-domain strings (vyramo.com today;
# the homelab_domain operator var in general) that should be
# under Jinja templating per Pick 3 (2026-06-03 session, see
# homelab-docs/04-guides/cold-start.md §9c.1).
#
# Why: 45 files were de-hardcoded via .yaml.j2 sources rendered
# from homelab-infra/ansible/playbooks/00-render-static.yml. New
# files that hardcode the domain reopen the wound. Pre-commit
# catches them at author-time, not at fork-and-go time.
#
# Strategy: every tracked `.yaml` / `.yml` file containing the
# literal domain string MUST have a `.yaml.j2` / `.yml.j2`
# sibling (meaning it's a rendered output). Without a sibling
# it's a regression.
#
# Exemptions:
#   - The .j2 sources themselves use {{ homelab_domain }} so
#     they don't match the literal grep — naturally exempt.
#   - README files (worked examples allowed) — by path pattern.
#
# When the operator forks the homelab, change DOMAIN_LITERAL
# below to whatever string is hardcoded today, run this once,
# fix each hit, then it stops firing.
#
# Auth model: none — local file scan; runs in pre-commit.
# Tested against: bash 5+, macOS + Linux.

set -euo pipefail

DOMAIN_LITERAL="vyramo.com"

# Paths allowed to contain the literal (README examples + outputs
# of parametric renders that don't follow the per-file .yaml.j2
# sibling convention).
#
# Parametric exemptions:
#   platform/authentik/blueprints/*.yaml — rendered by
#     homelab-infra/ansible/playbooks/00-render-static.yml from
#     ONE template (blueprints/_blueprint.yaml.j2) + an inventory
#     file (platform/authentik/oidc-apps.yaml). No per-app .yaml.j2
#     sibling exists by design; see Pick 5 in the workspace audit.
ALLOWLIST_REGEX='^README\.md$|^.*/README\.md$|^platform/authentik/blueprints/[^/]+\.yaml$'

err()  { echo "ERROR: $*" >&2; }

# Use staged files when running as a pre-commit hook; else scan
# everything tracked.
if [ -n "${PRE_COMMIT:-}" ] || [ "${1:-}" = "--staged" ]; then
  files=$(git diff --cached --name-only --diff-filter=ACM \
            | grep -E '\.(yaml|yml)$' \
            | grep -vE '\.j2$' \
            || true)
else
  files=$(git ls-files '*.yaml' '*.yml' | grep -vE '\.j2$')
fi

violations=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  echo "$f" | grep -qE "$ALLOWLIST_REGEX" && continue
  [ -e "${f}.j2" ] && continue
  grep -q "$DOMAIN_LITERAL" "$f" 2>/dev/null || continue
  err "$f hardcodes '$DOMAIN_LITERAL' but has no $f.j2 sibling."
  violations=$((violations + 1))
done <<< "$files"

if [ "$violations" -gt 0 ]; then
  cat >&2 << EOF

Fix each by one of:
  (a) Create the .j2 sibling that substitutes {{ homelab_domain }}
      (and {{ homelab_internal_subdomain }} for *.lab.\$DOMAIN),
      add an entry to homelab-infra/ansible/playbooks/00-render-static.yml's
      cross_repo_renders list, run the playbook to regenerate
      the .yaml, commit both.
  (b) If the literal is unavoidable (e.g. a runbook example),
      add the path to ALLOWLIST_REGEX in this script.

See: homelab-docs/04-guides/cold-start.md §9c.1.
EOF
  exit 1
fi

exit 0
