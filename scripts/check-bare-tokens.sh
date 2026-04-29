#!/usr/bin/env bash
# Detect bare ALL_CAPS_TOKEN placeholders that should be in
# <UPPER_SNAKE> form per the convention pinned 2026-04-29.
#
# Why: check-placeholders.sh greps for `<X>`-bracketed tokens.
# Bare-token forms (e.g. `cidr: MAC_STUDIO_INFERENCE_IP/32`)
# slip past the bracket grep, and that exact case bit us at
# the bring-up residual sweep. This script catches them at the
# specific value-position keys where a bare CAPS_TOKEN cannot
# legitimately be a runtime env-var ref.
#
# Strategy: rather than try to distinguish env-var refs from
# placeholders in arbitrary YAML (hard, error-prone), we
# enforce on a positive-list of *keys* whose values must always
# be concrete (IP / CIDR / URL / hostname). A bare CAPS_TOKEN
# in those positions is unambiguously a placeholder.
#
# Per the operator's "script everything scriptable now" policy
# (memory feedback_script-don-t-defer.md).

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Keys whose values are always concrete (never env-var refs).
# Adding to this list = operator decided "no legitimate env-var
# substitution at this key" — safe-to-flag policy.
VALUE_KEYS=(
  cidr
  server
  endpoint
  endpointURL
  api_base
  apiBase
  api_addr
  cluster_addr
  targets        # Prometheus static_configs.targets list items
  url
  uri
  ipBlock
  loadBalancerIP
)

# Build a single regex alternation for the keys.
keys_alt=$(IFS='|'; echo "${VALUE_KEYS[*]}")

# Pattern: at start of value (after key + colon, optional list
# dash, optional whitespace), a bare ALL_CAPS_TOKEN of length
# >=4 (rules out short codes like `IP` alone in test fixtures).
# The token may be followed by `/`, `:`, `,`, end-of-line — any
# common terminator in YAML values.
#
# Excludes: anything between backticks (commentary in markdown
# embedded inside heredocs etc.); not relevant in pure YAML but
# defensive.
hits=$(grep -rEn --include='*.yaml' --include='*.yml' --include='*.j2' \
  "(^|\s)-?\s*(${keys_alt}):\s+[A-Z][A-Z0-9_]{3,}([:/,'\"\\.]|$)" \
  . 2>/dev/null \
  | grep -v '`[^`]*`' \
  || true)

# Filter out lines where the value is just the all-caps key
# name being repeated (e.g., `name: MY_SERVICE` is fine — `name`
# is not in VALUE_KEYS but if some future addition collides,
# this is defensive).
# Also filter list-form prometheus targets where the value is a
# bare hostname (no caps_token) — the regex requires
# uppercase-prefix so this is already excluded.

# Filter out env-var refs by exact comparison: if the value
# matches an obvious runtime-ref shape (${X}, $(X), or appears
# inside a `name:` line above), grep already excluded those
# (they don't match VALUE_KEYS). If a future false-positive
# fires, add to ALLOWED_BARE_TOKENS below.

ALLOWED_BARE_TOKENS=(
  # name:value pairs that the regex would otherwise flag.
  # Format: <line-grep-pattern>:<one-line reason>
  # Empty for now — every current hit IS a real placeholder.
)

is_allowed() {
  local line="$1"
  local entry pattern
  for entry in "${ALLOWED_BARE_TOKENS[@]}"; do
    pattern="${entry%%:*}"
    if echo "$line" | grep -qF "$pattern"; then
      return 0
    fi
  done
  return 1
}

remaining=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if ! is_allowed "$line"; then
    remaining="$remaining$line
"
  fi
done <<EOF
$hits
EOF

if [ -z "${remaining%$'\n'}" ]; then
  echo "OK: no bare-token placeholders at value-bearing keys."
  exit 0
fi

echo "FAIL: bare ALL_CAPS_TOKEN placeholder(s) at value-bearing keys:" >&2
echo "$remaining" | sed 's/^/  /' >&2
echo >&2
cat >&2 <<EOF
Convention (pinned 2026-04-29): every operator-fillable manifest
token uses the <UPPER_SNAKE> form so check-placeholders.sh catches
it. Bare ALL_CAPS_TOKEN at these keys (${keys_alt//|/, }) is
unambiguously a placeholder, not a runtime env-var ref.

Fix: wrap the token in angle brackets (e.g. MAC_STUDIO_INFERENCE_IP
→ <MAC_STUDIO_INFERENCE_IP>) so the next check-placeholders.sh
run reports its locations + reference value.

If a hit is genuinely a non-placeholder (false positive), add to
ALLOWED_BARE_TOKENS in this script with a one-line justification.
EOF
exit 1
