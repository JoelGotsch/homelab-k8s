#!/usr/bin/env bash
# check-chart-lock.sh — every pinned chart is locked, mirrored, and RESOLVABLE.
#
# Replaces check-chart-pin-vendored (ADR 0052 D6): that guarded a vendored copy
# against the pin, and there is no vendored copy any more.
#
# THREE CHECKS, and the third is the one that earns its keep
#
#   1. every `helmCharts` entry has a charts.lock.yaml entry at the same version
#   2. the layer's `repo:` matches the lock's `mirror`
#   3. --online: the pinned version RESOLVES against the mirror
#
# Check 3 exists because of a real defect found 2026-08-16.
# `infrastructure/nfs-csi` pins `version: "v4.13.4"` while the chart's own
# Chart.yaml says `4.13.4`. A classic HTTP helm index is lenient about the
# prefix, so that layer rendered correctly for its entire life. **OCI tags are
# exact.** `helm push` tags by the chart's real version, so the mirror holds
# `4.13.4` and a render asking for `v4.13.4` fails:
#
#   Error: failed to perform "FetchReference" on source:
#     registry.homelab.internal/homelab/csi-driver-nfs:v4.13.4: not found
#
# Nothing reported it. The pin was not wrong — it became wrong the moment the
# chart source moved to OCI. Only an online resolve catches that class, and only
# where the version is actually asked for.
#
# WHERE THIS MUST RUN
#
# Pre-commit AND CI. Chart versions are bumped by Renovate, which commits
# server-side, so a local hook never fires on the commit that introduces the
# problem. Renovate opens a PR (verified: it writes the bare upstream version,
# e.g. `0.43.1` -> `0.44.0`, comment untouched), and this check on that PR is
# what stops an unresolvable pin from merging.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '  %s\n' "$*"; }

HELM_BIN="${HELM_BIN:-helm3}"
CA_FILE="${CA_FILE:-$HOME/.config/homelab/ca.pem}"
ONLINE=false
case "${1:-}" in
  --online) ONLINE=true ;;
  --offline|"") ONLINE=false ;;
  -h|--help) echo "usage: $0 [--offline | --online]" >&2; exit 2 ;;
  *) err "unknown argument: $1"; exit 2 ;;
esac

command -v python3 >/dev/null 2>&1 || { err "python3 required"; exit 1; }
[ -f charts.lock.yaml ] || { echo "SKIP: no charts.lock.yaml in this repo."; exit 0; }

problems=0
checked=0

# 1 + 2, offline: pins vs lock.
while IFS=$'\t' read -r status layer name version detail; do
  [ -n "$status" ] || continue
  case "$status" in
    OK)      checked=$((checked + 1)) ;;
    NOLOCK)  err "$layer pins $name $version but charts.lock.yaml has no entry at that version."
             note "  Run: HELM_BIN=$HELM_BIN scripts/mirror-chart.sh --apply --update-lock"
             problems=$((problems + 1)) ;;
    REPO)    err "$layer repo: does not match the lock's mirror for $name."
             note "  layer: $detail"
             problems=$((problems + 1)) ;;
  esac
done < <(python3 - <<'PY'
import yaml, subprocess, os, sys
lock = {(e['name'], str(e['version'])): e for e in (yaml.safe_load(open('charts.lock.yaml')) or [])}
files = subprocess.run(['git','ls-files','*kustomization.yaml'],capture_output=True,text=True).stdout.split()
for f in files:
    if '/charts/' in f or f.startswith('apps/'):
        continue
    try:
        d = yaml.safe_load(open(f)) or {}
    except Exception:
        continue
    for c in (d.get('helmCharts') or []):
        layer, name, ver = os.path.dirname(f) or '.', c['name'], str(c.get('version'))
        e = lock.get((name, ver))
        if not e:
            print(f"NOLOCK\t{layer}\t{name}\t{ver}\t"); continue
        repo = (c.get('repo') or '').rstrip('/')
        mirror = (e.get('mirror') or '').rstrip('/')
        # the layer points at the org; the lock names the chart under it
        if repo and mirror and not mirror.startswith(repo):
            print(f"REPO\t{layer}\t{name}\t{ver}\t{repo} vs {mirror}"); continue
        print(f"OK\t{layer}\t{name}\t{ver}\t")
PY
)

# 3, online: does the pinned version actually resolve on the mirror?
if [ "$ONLINE" = true ]; then
  command -v "$HELM_BIN" >/dev/null 2>&1 || { err "$HELM_BIN not found (needed for --online)"; exit 1; }
  [ -f "$CA_FILE" ] || { err "CA bundle not found at $CA_FILE (needed for --online).
      kubectl -n registry-integrity-probe get cm homelab-trust-bundle \\
        -o jsonpath='{.data.ca-certificates\\.crt}' > $CA_FILE
      Refresh it after a CA rotation."; exit 1; }
  while IFS=$'\t' read -r name version mirror; do
    [ -n "$name" ] || continue
    if "$HELM_BIN" show chart "$mirror" --version "$version" --ca-file "$CA_FILE" >/dev/null 2>&1; then
      continue
    fi
    err "$name $version does NOT resolve on the mirror."
    bare="${version#v}"
    if [ "$bare" != "$version" ] && "$HELM_BIN" show chart "$mirror" --version "$bare" --ca-file "$CA_FILE" >/dev/null 2>&1; then
      note "  The tag is '$bare'. The pin carries a leading 'v' that the chart's own"
      note "  Chart.yaml does not. A classic HTTP index tolerates that; OCI tags are"
      note "  exact. Fix the pin to '$bare' — do NOT retag the mirror."
    else
      note "  Not in the mirror at all. Run scripts/mirror-chart.sh --apply."
    fi
    problems=$((problems + 1))
  done < <(python3 -c "
import yaml
for e in yaml.safe_load(open('charts.lock.yaml')) or []:
    print(f\"{e['name']}\t{e['version']}\t{e['mirror']}\")")
fi

if [ "$problems" -gt 0 ]; then
  cat >&2 <<EOF

$problems chart-lock problem(s).

The lock is what replaced the vendored chart as the record of what was
reviewed. A pin with no lock entry, a layer pointing somewhere other than the
mirror, or a version that cannot be resolved are all states where the render
either drifts from what was approved or stops working.
EOF
  exit 1
fi

if [ "$ONLINE" = true ]; then
  echo "OK: $checked pinned chart(s) locked, pointing at the mirror, and resolvable."
else
  echo "OK: $checked pinned chart(s) locked and pointing at the mirror (offline checks only; use --online to verify they resolve)."
fi
exit 0
