#!/usr/bin/env bash
# Detect hardcoded operator-email substrings (joelgotsch.com today;
# the operator_email var in general) that should be templated via
# {{ operator_email }} per Pick 3 D (2026-06-03 session).
#
# Why: the PII audit (2026-06-03) found 2 fixable operator-email
# leaks in tracked files (authentik.yml.example, scripts/README.md).
# Nothing prevented the regression. This hook does, going forward.
#
# Strategy: every tracked file containing the literal substring MUST
# have a `.yaml.j2` / `.yml.j2` sibling (rendered output) OR be in
# the allowlist. Same pattern as check-no-bare-domain.sh.
#
# The substring match catches every variant: contact@joelgotsch.com,
# homelab@joelgotsch.com, joel.gotsch@joelgotsch.com, etc.
#
# When the operator forks the homelab, change EMAIL_LITERAL below
# to whatever email substring is hardcoded today, run this once,
# fix each hit, then it stops firing.
#
# Auth model: none — local file scan; runs in pre-commit.
# Tested against: bash 4+ (macOS default 3.2 unsupported — see guard).

set -euo pipefail

# Bash 4+ guard (same as the other check scripts).
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "ERROR: this script needs bash 4+. macOS default is 3.2." >&2
  exit 1
fi

EMAIL_LITERAL="joelgotsch.com"

# Paths allowed to contain the literal:
#   - 99-journal/ entries are immutable per CLAUDE.md (historical
#     PII would already be there; can't be rewritten).
#   - This script itself (mentions the literal in its own comments).
#
# Deliberately NOT exempt:
#   - .md files (runbooks must use the <operator-email> placeholder
#     pattern; the audit fixed scripts/README.md to enforce this).
#   - .example files (authentik.yml.example was the audit's main
#     finding — placeholder-ify'd this session; re-adding a real
#     email to any .example must fail again).
#
# Tighten only when a legitimate documented-as-historical hit
# surfaces; less risk of missing a real leak.
ALLOWLIST_REGEX='^99-journal/|^.*/99-journal/|^scripts/check-no-operator-email\.sh$|^.*/scripts/check-no-operator-email\.sh$'

err()  { echo "ERROR: $*" >&2; }

# Use staged files when running as a pre-commit hook or when
# --staged is passed; --all forces full scan; default is full scan.
if [ "${1:-}" = "--all" ]; then
  files=$(git ls-files)
elif [ -n "${PRE_COMMIT:-}" ] || [ "${1:-}" = "--staged" ]; then
  files=$(git diff --cached --name-only --diff-filter=ACM || true)
else
  files=$(git ls-files)
fi

violations=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -e "$f" ] || continue
  # Skip allowlisted paths.
  echo "$f" | grep -qE "$ALLOWLIST_REGEX" && continue
  # Skip .j2 sources — they use {{ operator_email }}, so they
  # don't match the literal grep naturally; this is a fast-path.
  case "$f" in *.j2) continue ;; esac
  # Skip files whose rendered-output sibling-by-convention
  # exists (foo.yaml with foo.yaml.j2 next to it). Mirrors the
  # check-no-bare-domain.sh pattern.
  [ -e "${f}.j2" ] && continue
  # Only fire if literal is actually present.
  grep -q "$EMAIL_LITERAL" "$f" 2>/dev/null || continue
  err "$f contains '$EMAIL_LITERAL' but has no $f.j2 sibling and is not on the allowlist."
  violations=$((violations + 1))
done <<< "$files"

if [ "$violations" -gt 0 ]; then
  cat >&2 << EOF

Fix each by one of:
  (a) Replace the literal with {{ operator_email }} in a .yaml.j2
      sibling, add an entry to homelab-infra/ansible/playbooks/00-render-static.yml's
      cross_repo_renders list, run the playbook to regenerate
      the .yaml, commit both.
  (b) For docs / .example files, use the <operator-email>
      placeholder (operator fills at cold-start.md Step 13a).
  (c) If the literal is truly unavoidable and historical
      (e.g. a journal entry not in 99-journal/), add the path
      to ALLOWLIST_REGEX in this script with a one-line rationale.

See: Pick 3 D + the 2026-06-03 PII audit session.
EOF
  exit 1
fi

exit 0
