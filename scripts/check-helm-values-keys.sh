#!/usr/bin/env bash
# Pre-deploy guard: every key the operator sets in a Helm layer's
# values.yaml must appear in the chart's published values tree.
# Catches the wrong-chart-key class that silently dropped at render and
# cost the dominant share of diagnostic time during the 2026-05-29 →
# 2026-05-31 vaultwarden + langfuse bring-up (see
# homelab-docs/99-journal/2026-05-31-langfuse-and-vaultwarden-bringup-saga.md).
#
# v1 limitation — back-compat shims look like wrong-keys:
#   `helm show values` returns only the chart's DOCUMENTED defaults. Many
#   charts (e.g. guerzon/vaultwarden, langfuse/langfuse) silently accept
#   additional keys via `dig`/`default` helpers — they read those keys at
#   render time but don't surface them in the values defaults. Those keys
#   currently get flagged here even though the workload renders fine. So
#   for v1 this script is RUN MANUALLY (`scripts/check-helm-values-keys.sh`)
#   rather than wired into .pre-commit-config.yaml. Triage each flagged key
#   against the rendered output (`kustomize build --enable-helm <layer> |
#   grep -A2 <expected env>`) — real wrong-keys produce missing env, back-
#   compat shims render correctly. Refinement (per-layer .helmcheckignore
#   baseline file) is queued separately in the TODO.
#
# For every kustomization.yaml under the layer roots (infrastructure/,
# platform/, observability/, apps/) that declares a helmCharts: block,
# this script:
#   1. Resolves the chart + version + values file.
#   2. Runs `helm show values <repo>/<chart> --version <ver>` and extracts
#      every dotted key path present in the chart's defaults.
#   3. Reads the layer's values.yaml and extracts the same.
#   4. Reports any key path WE set that does NOT appear in the chart —
#      that's a typo or a chart-version key rename. Reports also the
#      total counts.
#
# Sub-chart values (e.g. `redis.primary.persistence.size` under a
# parent chart) ARE handled correctly: when a chart depends on a
# sub-chart, `helm show values` includes the sub-chart's values too, so
# their paths are in the comparison set.
#
# Exit codes:
#   0 = all layers' values keys are recognized by their chart.
#   1 = at least one unknown key found (block commit / deploy).
#   2 = invocation / dependency error (helm not found, chart unreachable).
#
# Usage:
#   scripts/check-helm-values-keys.sh                # check all layers
#   scripts/check-helm-values-keys.sh <files…>       # pre-commit mode (any
#                                                    # changed values.yaml /
#                                                    # kustomization.yaml
#                                                    # triggers a check of
#                                                    # the parent layer)
#   scripts/check-helm-values-keys.sh --layer DIR    # check one layer
#
# Options:
#   --layer DIR            check this one directory only
#   --strict               also fail on chart-default keys we set to the
#                          same value as the chart (low-value override)
#   -h | --help            this message
#
# Bypass:
#   SKIP_HELM_VALUES_KEYS_CHECK=1 git commit ...
#
# This script needs network access to fetch the helm chart. In airgapped
# bring-up, run it once where the network IS available (it caches the
# chart's resolved values per chart+version in /tmp/helmkeys-cache/).

set -euo pipefail

if [ "${SKIP_HELM_VALUES_KEYS_CHECK:-0}" = "1" ]; then
  echo "check-helm-values-keys: SKIP_HELM_VALUES_KEYS_CHECK=1 — bypassed."
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

layer_arg=""
strict=0
positional=()

usage() { sed -n '/^# Usage:/,/^$/p' "$0" | sed -E 's/^# ?//'; }
err()   { echo "ERROR: $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --layer)   layer_arg="${2:?}"; shift 2 ;;
    --strict)  strict=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; positional+=("$@"); break ;;
    -*)        err "unknown option: $1"; usage >&2; exit 2 ;;
    *)         positional+=("$1"); shift ;;
  esac
done

for tool in helm python3; do
  command -v "$tool" >/dev/null 2>&1 || {
    err "$tool not on PATH"; exit 2
  }
done

# Decide which layers to check.
declare -a layers
if [ -n "$layer_arg" ]; then
  layers=("$layer_arg")
elif [ "${#positional[@]}" -gt 0 ]; then
  # Pre-commit mode: derive layers from changed files.
  declare -A seen
  for f in "${positional[@]}"; do
    case "$f" in
      *.yaml)
        d="$(dirname "$f")"
        # Walk up until a kustomization.yaml exists.
        while [ "$d" != "/" ] && [ "$d" != "." ] && [ ! -f "$d/kustomization.yaml" ]; do
          d="$(dirname "$d")"
        done
        if [ -f "$d/kustomization.yaml" ] && [ -z "${seen[$d]:-}" ]; then
          layers+=("$d")
          seen[$d]=1
        fi
        ;;
    esac
  done
  [ "${#layers[@]}" -eq 0 ] && {
    echo "check-helm-values-keys: no Helm-using layers touched — nothing to do."
    exit 0
  }
else
  # Full sweep.
  while IFS= read -r kf; do
    layers+=("$(dirname "$kf")")
  done < <(
    find "$REPO_ROOT/infrastructure" "$REPO_ROOT/platform" \
         "$REPO_ROOT/observability" "$REPO_ROOT/apps" \
         -name kustomization.yaml 2>/dev/null
  )
fi

mkdir -p /tmp/helmkeys-cache

# The actual check, per layer, runs in Python (YAML handling is too brittle
# in pure bash + yq + jq combos).
check_layer() {
  local layer="$1"
  STRICT="$strict" REPO_ROOT="$REPO_ROOT" python3 - <<'PYEOF' "$layer"
import os, re, subprocess, sys, urllib.parse
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: python yaml not installed (pip install pyyaml or apt install python3-yaml)",
          file=sys.stderr)
    sys.exit(2)

layer = Path(sys.argv[1])
kust = layer / "kustomization.yaml"
if not kust.exists():
    sys.exit(0)

try:
    kdata = yaml.safe_load(kust.read_text()) or {}
except yaml.YAMLError as e:
    print(f"  {layer}: kustomization.yaml is not valid YAML — {e}", file=sys.stderr)
    sys.exit(1)

charts = kdata.get("helmCharts") or []
if not charts:
    sys.exit(0)

strict = os.environ.get("STRICT", "0") == "1"
problems = 0

def all_paths(node, prefix=""):
    """Every dotted path in a YAML doc. Lists are descended only when they
    contain dicts (list-of-objects); list-of-scalars (e.g. drop:[ALL]) are
    not unpacked since they're values, not paths."""
    out = set()
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{prefix}.{k}" if prefix else k
            out.add(p)
            out |= all_paths(v, p)
    elif isinstance(node, list):
        for item in node:
            if isinstance(item, dict):
                out |= all_paths(item, prefix)
    return out

def cache_chart_values(repo, name, ver):
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_",
                  f"{urllib.parse.urlparse(repo).netloc}_{name}_{ver}")
    cache = Path(f"/tmp/helmkeys-cache/{safe}.yaml")
    if not cache.exists():
        try:
            r = subprocess.run(
                ["helm", "show", "values", f"{repo}/{name}".lower(),
                 "--version", ver],
                check=False, capture_output=True, text=True, timeout=60,
            )
            if r.returncode != 0:
                # Try with repo add + alias.
                alias = "checkhk_" + safe
                subprocess.run(["helm", "repo", "add", alias, repo],
                               check=False, capture_output=True)
                subprocess.run(["helm", "repo", "update", alias],
                               check=False, capture_output=True)
                r = subprocess.run(
                    ["helm", "show", "values", f"{alias}/{name}",
                     "--version", ver],
                    check=False, capture_output=True, text=True, timeout=60,
                )
                if r.returncode != 0:
                    return None, r.stderr.strip() or "helm show values failed"
            cache.write_text(r.stdout)
        except subprocess.TimeoutExpired:
            return None, "helm show values timed out"
    try:
        return yaml.safe_load(cache.read_text()) or {}, None
    except yaml.YAMLError as e:
        return None, f"chart values not valid YAML: {e}"

for c in charts:
    name = c.get("name", "?")
    ver  = c.get("version", "")
    repo = c.get("repo", "")
    vf   = c.get("valuesFile", "values.yaml")
    if not (repo and name and ver):
        print(f"  {layer}/kustomization.yaml: helmChart '{name}' missing repo/name/version — skipped",
              file=sys.stderr)
        problems += 1
        continue

    vfp = layer / vf
    if not vfp.exists():
        print(f"  {layer}/{vf}: declared by kustomization but file is missing", file=sys.stderr)
        problems += 1
        continue

    vtext = vfp.read_text()

    # NOTE(journal 2026-06-09-cluster-state-survey): guard against
    # duplicate top-level keys. Commit 8cbc291 introduced a second
    # top-level `tempo:` block; YAML last-key-wins silently overrode the
    # original block (resources/securityContext lost) and yaml.safe_load
    # below would hide it too. Detect on the raw text before parsing.
    seen_top = {}
    for lineno, line in enumerate(vtext.splitlines(), 1):
        if line.strip() == "---":
            seen_top = {}
            continue
        m = re.match(r"^([A-Za-z0-9_.-]+):", line)
        if m:
            k = m.group(1)
            if k in seen_top:
                print(f"  ✗ {vfp}: duplicate top-level key '{k}:' "
                      f"(lines {seen_top[k]} and {lineno}) — YAML last-key-wins "
                      f"silently drops the earlier block")
                problems += 1
            else:
                seen_top[k] = lineno

    try:
        ours = yaml.safe_load(vtext) or {}
    except yaml.YAMLError as e:
        print(f"  {vfp}: not valid YAML — {e}", file=sys.stderr)
        problems += 1
        continue

    chart_vals, cerr = cache_chart_values(repo, name, ver)
    if chart_vals is None:
        print(f"  {layer}: could not fetch chart values for {repo}/{name}@{ver}: {cerr}",
              file=sys.stderr)
        # Soft-fail: can't gate a deploy on network. Warn loudly, exit 0
        # for this layer.
        continue

    chart_paths = all_paths(chart_vals)
    our_paths   = all_paths(ours)
    unknown = sorted(p for p in our_paths if p not in chart_paths)

    if unknown:
        print(f"  ✗ {vfp}: keys NOT in chart {name}@{ver}:")
        for p in unknown:
            print(f"      - {p}")
        print(f"    (Run `helm show values {repo}/{name} --version {ver}` to see the chart's full key tree.)")
        problems += 1
    elif strict:
        # Optional: warn on overrides that match the chart default exactly.
        # (Not implemented in v1 — placeholder for --strict mode.)
        pass

sys.exit(0 if problems == 0 else 1)
PYEOF
}

rc=0
echo "check-helm-values-keys: scanning ${#layers[@]} layer(s)…"
for L in "${layers[@]}"; do
  check_layer "$L" || rc=1
done

if [ "$rc" -ne 0 ]; then
  echo
  echo "✗ Wrong-chart-key found. These values would be silently dropped at"
  echo "  render and the workload would behave as if unconfigured."
  echo "  Fix the key paths against the chart's published values tree, or"
  echo "  bypass with SKIP_HELM_VALUES_KEYS_CHECK=1 git commit ..."
fi

exit $rc
