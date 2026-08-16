#!/usr/bin/env bash
# check-render-determinism.sh — the same source must render the same output.
#
# WHY
#
# Some Helm charts mint values at render time with `randAlphaNum` and friends:
# passwords, shared tokens, registration secrets, plus `checksum/...` pod
# annotations derived from them. Rendering such a chart twice from identical
# inputs produces different manifests.
#
# Under GitOps that is not cosmetic. Argo re-renders a layer whenever the target
# revision changes, so EVERY commit to the repo — including commits that touch
# nothing in that layer — produces a new secret, a new checksum annotation, a
# Deployment update and a pod restart.
#
# Measured 2026-08-16, and the numbers line up almost exactly:
#
#   homelab-k8s commits            7.7 / day
#   crowdsec-lapi generation 576   6.9 / day   (84 days)
#   langfuse-s3  generation 564    6.7 / day   (84 days)
#
# The observable damage is a restart storm on workloads nobody asked to change,
# and a rotating shared secret: crowdsec's agent logged
# `heartbeat error: ... connect: no route to host` at the exact second lapi was
# replaced by a sync.
#
# This is NOT a self-sustaining loop — Argo caches the render per revision, so
# a layer does not thrash between commits. It is "any commit restarts these
# workloads".
#
# HOW
#
# Render each layer twice and diff. Any difference is chart non-determinism,
# because the input is byte-identical. Reports the differing FIELD PATHS, never
# the values — several of them are secrets.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '  %s\n' "$*"; }

KUSTOMIZE_BIN="${KUSTOMIZE_BIN:-kustomize}"
HELM_BIN="${HELM_BIN:-helm3}"

# Layers already understood and tracked. Listing one here does NOT make it
# acceptable — it records that the finding is filed, so the check can gate NEW
# non-determinism without failing on the known set. Deleting a line is how a fix
# gets recorded.
KNOWN='
platform/woodpecker|WOODPECKER_AGENT_SECRET
'

usage() { echo "usage: $0 [--all | <layer-dir>...]" >&2; exit 2; }

layers=()
case "${1:-}" in
  --all|"")
    while IFS= read -r f; do layers+=("$(dirname "$f")"); done < <(
      git ls-files '*kustomization.yaml' | grep -v '/charts/' | grep -v '^apps/')
    ;;
  -h|--help) usage ;;
  *) layers=("$@") ;;
esac

for t in "$KUSTOMIZE_BIN" python3; do
  command -v "$t" >/dev/null 2>&1 || { err "required tool missing: $t"; exit 1; }
done

work="$(mktemp -d "${TMPDIR:-/tmp}/render-determinism.XXXXXX")"
trap 'rm -rf "$work"' EXIT

render() { "$KUSTOMIZE_BIN" build --enable-helm --helm-command "$HELM_BIN" "$1"; }

nondet=0; clean=0; skipped=0; newfinding=0
for layer in "${layers[@]}"; do
  [ -f "$layer/kustomization.yaml" ] || continue
  grep -q '^helmCharts:' "$layer/kustomization.yaml" || continue   # only charts can be non-deterministic

  if ! render "$layer" > "$work/a.yaml" 2> "$work/e1"; then
    if grep -qE 'x509|tls: failed|FetchReference|connection refused|no such host' "$work/e1"; then
      note "$layer: SKIPPED — chart source unreachable from this host"
      skipped=$((skipped+1)); continue
    fi
    err "$layer: render failed"; sed 's/^/      /' "$work/e1" | head -3 >&2
    skipped=$((skipped+1)); continue
  fi
  render "$layer" > "$work/b.yaml" 2>/dev/null || true

  if cmp -s "$work/a.yaml" "$work/b.yaml"; then
    clean=$((clean+1)); continue
  fi

  # Report WHICH keys differ, never the values — most are secrets.
  paths="$(diff "$work/a.yaml" "$work/b.yaml" \
            | grep -E '^[<>]' \
            | sed -E 's/^[<>][[:space:]]*//; s/:.*$//' \
            | sed -E 's/^[[:space:]]*-?[[:space:]]*//' \
            | sort -u | tr '\n' ' ' || true)"   # diff exits 1 on difference;
                                                   # with pipefail that would
                                                   # kill the script under set -e
                                                   # immediately after computing
                                                   # the value it needs.
  known="$(printf '%s' "$KNOWN" | awk -F'|' -v l="$layer" '$1==l {print $2}')"
  if [ -n "$known" ]; then
    note "$layer: non-deterministic (KNOWN) — $known"
    nondet=$((nondet+1))
  else
    err "$layer: NEW non-deterministic render — differing keys: $paths"
    note "    The same source rendered twice produced different output, so every"
    note "    commit to this repo will restart this workload and rotate whatever"
    note "    value changed. Fix by pinning the value (ExternalSecret + explicit"
    note "    chart key) or, failing that, add it to the Application's"
    note "    ignoreDifferences — then record it in KNOWN above."
    nondet=$((nondet+1)); newfinding=$((newfinding+1))
  fi
done

echo
echo "── state"
echo "   deterministic        : $clean"
echo "   non-deterministic    : $nondet  (of which NEW: $newfinding)"
echo "   skipped/unrenderable : $skipped"
[ "$newfinding" -gt 0 ] && exit 1
exit 0
