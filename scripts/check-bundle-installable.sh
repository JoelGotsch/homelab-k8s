#!/usr/bin/env bash
# check-bundle-installable.sh — the offline bundle must be USABLE, not just intact.
#
# import-chart-bundle.sh proves the bundle is *verifiable*: every artifact still
# hashes to what was recorded. That is a different claim from "a cold start can
# actually install from it", and the second one is what ADR 0052 D7 and plan
# phase A8 depend on. A bundle can verify perfectly and still be useless — an
# unvendored subchart dependency would make every render fail the moment the
# network it wanted is the network that is down.
#
# Three questions, all answerable offline from a laptop, none touching the
# cluster (helm template and helm pull are read-only):
#
#   1. Is every tier-0 chart present?          — A8.2 installs these, in order.
#   2. Does each render from the bundle FILE
#      with its real values?                   — A8.0/A8.2 premise.
#   3. Does the bundle render match the MIRROR
#      render, byte for byte?                  — A8.4 premise: when Argo takes
#                                                over a layer Ansible installed
#                                                from the bundle, the handoff
#                                                has to be a no-op sync. If the
#                                                two renders differ, it is not.
#
# Question 3 needs the mirror reachable and is SKIPPED (not failed) when it is
# not — that is the normal state during the cold start this exists for.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '  %s\n' "$*"; }

HELM_BIN="${HELM_BIN:-helm3}"
BUNDLE_DIR="${BUNDLE_DIR:-$HOME/.config/homelab/chart-bundle}"
REGISTRY="${REGISTRY:-registry.homelab.internal}"
ORG="${ORG:-homelab}"
CA_FILE="${CA_FILE:-$HOME/.config/homelab/ca.pem}"

# The tier-0 chain, in A8.2's install order. `layer` is the homelab-k8s path
# whose values.yaml is the real input; `chart` is the bundle basename. Chart
# names differ from layer names in three places (cnpg -> cloudnative-pg,
# csi-rclone -> csi-driver-rclone, cnpg-barman-plugin -> plugin-barman-cloud),
# which is exactly the sort of thing worth having written down.
#
# cnpg-barman-plugin was MISSING from this list until 2026-08-16. The plan reads
# "cnpg (+barman plugin)", which looks like one install; it is two charts and two
# homelab-k8s layers, each with its own values.yaml and lock pin. A tier-0 chart
# was therefore unguarded here while this check reported a confident 9 of 9.
TIER0='
cilium|infrastructure/cilium|cilium
cert-manager|infrastructure/cert-manager|cert-manager
trust-manager|infrastructure/trust-manager|trust-manager
external-secrets|infrastructure/external-secrets|external-secrets
longhorn|infrastructure/longhorn|longhorn
cnpg|infrastructure/cnpg|cloudnative-pg
cnpg-barman-plugin|infrastructure/cnpg-barman-plugin|plugin-barman-cloud
openbao|platform/openbao|openbao
csi-rclone|infrastructure/csi-rclone|csi-driver-rclone
forgejo|platform/forgejo|forgejo
'

usage() {
  cat >&2 <<EOF
usage: $0 [<homelab-k8s-root>]

  Checks that the offline chart bundle can actually install the tier-0 chain.

env: BUNDLE_DIR (default ~/.config/homelab/chart-bundle), HELM_BIN, REGISTRY,
     ORG, CA_FILE
EOF
  exit 2
}

case "${1:-}" in -h|--help) usage ;; esac
K8S_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -d "$K8S_ROOT/infrastructure" ] || { err "not a homelab-k8s root: $K8S_ROOT"; exit 1; }
[ -d "$BUNDLE_DIR" ] || { err "no bundle at $BUNDLE_DIR — run export-chart-bundle.sh first"; exit 1; }
command -v "$HELM_BIN" >/dev/null 2>&1 || { err "$HELM_BIN not found"; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/bundle-installable.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/mirror"          # helm pull -d does NOT create its target dir;
                                 # without this every pull fails with a
                                 # "no such file or directory" that reads as an
                                 # unreachable mirror.

missing=0; rendered=0; renderfail=0; identical=0; differs=0; skipped=0

printf '%-18s %-10s %-12s %s\n' LAYER PRESENT RENDER "VS-MIRROR"
printf '%-18s %-10s %-12s %s\n' ------ ------- ------ ---------

while IFS='|' read -r layer lpath chart; do
  [ -n "$layer" ] || continue

  # NOTE: do NOT name a loop variable `path` — in zsh it is tied to $PATH and
  # assigning it wipes the command search path for the rest of the shell.

  tgz="$(ls "$BUNDLE_DIR/$chart"-*.tgz 2>/dev/null | LC_ALL=C sort | tail -1)"
  if [ -z "$tgz" ]; then
    printf '%-18s %-10s %-12s %s\n' "$layer" "ABSENT" "-" "-"
    missing=$((missing+1)); continue
  fi
  base="$(basename "$tgz" .tgz)"; ver="${base##*-}"

  values="$K8S_ROOT/$lpath/values.yaml"
  if [ ! -f "$values" ]; then
    printf '%-18s %-10s %-12s %s\n' "$layer" "ok" "NO-VALUES" "-"
    renderfail=$((renderfail+1)); continue
  fi

  if ! a="$("$HELM_BIN" template "$chart" "$tgz" -f "$values" 2>"$work/e")"; then
    printf '%-18s %-10s %-12s %s\n' "$layer" "ok" "FAIL" "-"
    sed 's/^/      /' "$work/e" | head -2 >&2
    renderfail=$((renderfail+1)); continue
  fi
  rendered=$((rendered+1))

  vs="skip"
  if "$HELM_BIN" pull "oci://$REGISTRY/$ORG/$chart" --version "$ver" \
        -d "$work/mirror" --ca-file "$CA_FILE" >"$work/pull" 2>&1; then
    if b="$("$HELM_BIN" template "$chart" "$work/mirror/$base.tgz" -f "$values" 2>/dev/null)" \
       && [ "$a" = "$b" ]; then
      vs="identical"; identical=$((identical+1))
    else
      vs="DIFFERS"; differs=$((differs+1))
    fi
  else
    skipped=$((skipped+1))
  fi

  printf '%-18s %-10s %-12s %s\n' "$layer" "ok" "ok" "$vs"
done <<EOF
$TIER0
EOF

echo
echo "── state"
echo "   tier-0 charts present   : $((rendered+renderfail)) of $(printf '%s' "$TIER0" | grep -c '|')"
echo "   rendered from bundle    : $rendered   (failed: $renderfail, absent: $missing)"
echo "   identical to mirror     : $identical  (differs: $differs, mirror unreachable: $skipped)"
echo

if [ "$missing" -gt 0 ] || [ "$renderfail" -gt 0 ]; then
  err "the bundle cannot install the tier-0 chain as it stands."
  note "A bundle that verifies but cannot render is worse than none: it is trusted."
  exit 1
fi
if [ "$differs" -gt 0 ]; then
  err "bundle and mirror renders differ — the A8.4 handoff would NOT be a no-op sync."
  note "Argo would immediately re-apply what Ansible installed. Find out why before A8."
  exit 1
fi
note "Bundle can install tier-0 offline$( [ "$identical" -gt 0 ] && echo ", and matches the mirror" )."
exit 0
