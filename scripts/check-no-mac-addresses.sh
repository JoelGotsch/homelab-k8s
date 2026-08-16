#!/usr/bin/env bash
# Reject commits that introduce IEEE-802 MAC-address strings into
# tracked files. MAC values identify operator hardware on the home
# network; per CLAUDE.md cross-cutting rules + ADR 0003 they are
# classified `internal` and live in
# `homelab-infra/ansible/inventory/hosts.yml` (gitignored today;
# SOPS-encrypted post-Phase C1d) and nowhere else.
#
# Pattern: 6 colon-separated hex pairs, case-insensitive — the
# canonical IEEE-802 form. Hyphen-separated MACs are not matched
# because nothing in this workspace uses that variant; if a future
# tool emits hyphen-form, extend PATTERN.
#
# Allowed exceptions: a tracked file may carry MAC-shaped strings
# only if there's a documented reason (e.g. this script's own regex
# literal). Add the file path to EXEMPT below with a one-line
# justification — keep the list as small as possible.
#
# Per the operator's "script everything scriptable now" policy
# (memory feedback_script-don-t-defer.md). CANONICAL COPY LIVES IN
# homelab-hooks/scripts/ and is consumed by app repos as a pre-commit
# `repo:`/`rev:` entry (ADR 0047, Track G1, 2026-08-16). The copies in
# homelab-docs/, homelab-infra/ and homelab-k8s/ are byte-identical
# MIRRORS kept per ADR 0047 D3 so those three repos can gate without
# reaching Forgejo. Change homelab-hooks first, then re-sync the mirrors.

set -eu

EXEMPT=(
  "scripts/check-no-mac-addresses.sh"  # this script's regex literal
  # Trust-manager root-CA bundle carries a SHA-1 fingerprint of the
  # homelab-internal-issuer root cert (20 hex bytes prefixed `SHA1:`
  # per RFC 5280). The 6-byte-pair regex matches substrings of that
  # 20-byte fingerprint. Not a MAC — same style is used across every
  # PKI toolchain that prints certificate digests. See ADR 0034 D2.
  "infrastructure/trust-manager/bundles.yaml"
)

PATTERN='([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}'

EXCLUDES=()
for f in "${EXEMPT[@]}"; do
  EXCLUDES+=(":(exclude)${f}")
done

# git grep over tracked files only (gitignored hosts.yml is skipped
# automatically). Exits 0 on match, 1 on no match, >1 on error.
if hits=$(git grep -nE "${PATTERN}" -- . "${EXCLUDES[@]}" 2>/dev/null); then
  echo "FAIL: MAC-address-shaped strings found in tracked files:"
  echo "${hits}" | sed 's/^/  /'
  echo
  echo "MAC values are classified internal — keep them in"
  echo "homelab-infra/ansible/inventory/hosts.yml (gitignored today;"
  echo "SOPS-encrypted post-Phase C1d)."
  echo
  echo "If a hit is a legitimate non-MAC (e.g. an example value in a"
  echo "doc), add the file to EXEMPT in scripts/check-no-mac-addresses.sh"
  echo "with a one-line justification."
  exit 1
fi

echo "OK: no MAC-address-shaped strings in tracked files."
