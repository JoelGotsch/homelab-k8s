#!/usr/bin/env bash
# Check for unfilled <PLACEHOLDER> tokens in homelab-k8s
# manifests. Run before `kubectl apply -k` / Argo bootstrap.
# Mirrors homelab-infra/scripts/preflight-check.sh's
# placeholder-grep logic, scoped to this repo.
#
# Convention: any all-caps token between `<` and `>` (e.g.
# `<NAS-IP>`, `<CLUSTER_ENDPOINT>`) is a marker for an
# operator-fillable value. Comments may legitimately reference
# placeholders inside backticks (e.g.
# `<NAS-IP>`-style examples) — those are excluded by the
# leading-context filter below.
#
# Exit codes:
#   0 — no unfilled placeholders.
#   1 — at least one placeholder found; details on stderr.
#   2 — script invocation error.
#
# To allow a known placeholder to remain (e.g. operator-
# documented later-fill), add an exception to ALLOWED_LEFTOVERS
# below with a one-line reason.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Patterns that may legitimately remain at apply time. Add
# with care — every entry is a future bring-up trip-hazard if
# left stale. Format: `<TOKEN>:<one-line reason>`.
ALLOWED_LEFTOVERS=(
  # (no current allowlist entries)
)

is_allowed() {
  local match="$1"
  local entry
  for entry in "${ALLOWED_LEFTOVERS[@]}"; do
    if [ "${entry%%:*}" = "$match" ]; then
      return 0
    fi
  done
  return 1
}

# Find tokens of the form <SOMETHING_LIKE_THIS> across yaml /
# yaml.j2 files. Filter:
# - skip backtick-wrapped (commentary).
# - require at least one uppercase or digit (rules out things
#   like `<value>` in comments).
hits=$(grep -rEn --include='*.yaml' --include='*.yml' --include='*.j2' \
  '<[A-Z0-9][A-Z0-9_-]+>' . \
  | grep -v '`<[A-Z0-9_-]\+>`' \
  || true)

if [ -z "$hits" ]; then
  echo "OK: no unfilled placeholders in homelab-k8s manifests."
  exit 0
fi

# Collect unique tokens for the allowlist check.
unique_tokens=$(echo "$hits" | grep -oE '<[A-Z0-9][A-Z0-9_-]+>' | sort -u)

remaining=""
for token in $unique_tokens; do
  if is_allowed "$token"; then
    continue
  fi
  remaining="$remaining $token"
done

if [ -z "${remaining// /}" ]; then
  echo "OK: only allowlisted placeholders remain."
  exit 0
fi

echo "FAIL: unfilled placeholder(s) found in homelab-k8s manifests:" >&2
echo >&2
for token in $remaining; do
  echo "  $token:" >&2
  grep -rEn --include='*.yaml' --include='*.yml' --include='*.j2' \
    -F "$token" . | sed 's/^/    /' >&2
  echo >&2
done

cat >&2 <<'EOF'

Fill the placeholders before applying. Reference values:
  <NAS-IP>            → homelab-infra/group_vars/cluster.yml :: nas_storage_ip
  <CLUSTER_ENDPOINT>  → talosctl config endpoint after step 9
  <CLUSTER_INGRESS_IP> → assigned at step 9; see cold-start.md phase 2
  <MAC_STUDIO_INFERENCE_IP> → homelab-infra/group_vars/all/main.yml
  (others) → see the file's nearby comment for context

If a placeholder is intentionally retained (e.g. filled by a
parent overlay), add it to ALLOWED_LEFTOVERS in this script
with a one-line justification.
EOF
exit 1

