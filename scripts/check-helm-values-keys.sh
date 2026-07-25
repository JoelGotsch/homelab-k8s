#!/usr/bin/env bash
# Pre-deploy guard: every key the operator sets in a Helm layer's
# values.yaml must appear in the chart's published values tree.
# Catches the wrong-chart-key class that silently dropped at render and
# cost the dominant share of diagnostic time during the 2026-05-29 →
# 2026-05-31 vaultwarden + langfuse bring-up (see
# homelab-docs/99-journal/2026-05-31-langfuse-and-vaultwarden-bringup-saga.md).
#
# v2 — per-layer `.helmcheckignore` baseline (why some keys are "known"):
#   `helm show values` returns only the chart's DOCUMENTED defaults. A key WE
#   set can be absent from that tree for two DIFFERENT reasons:
#     (a) BACK-COMPAT-OK: the chart's templates DO read the key (via a `with`/
#         `range`/`toYaml` over a list or empty-dict default, e.g. langfuse
#         `langfuse.web.pod.additionalEnv[]` or vaultwarden `resources: {}`),
#         so it renders fine — it just isn't surfaced as a default. FALSE
#         POSITIVE.
#     (b) GENUINE WRONG-KEY: the chart doesn't read it at all (typo, renamed
#         key, or a bitnami-style subkey the chart's wrapper never forwards,
#         e.g. langfuse `redis.primary.persistence.size`). Value is DROPPED at
#         render and the workload behaves as if unconfigured. TRUE POSITIVE.
#   To let the operator ACKNOWLEDGE the current known set so future commits
#   flag only NEW unknowns, each layer may carry a `.helmcheckignore` baseline
#   next to its `values.yaml`: one key path per line, `#` comments and blank
#   lines allowed. A line `a.b.c` acknowledges `a.b.c` AND every key nested
#   under it (`a.b.c.*`) — so one line covers a list-item's subpaths. Keep the
#   file split into a "back-compat-OK" section and a "KNOWN WRONG-KEY — tracked
#   bug, fix & remove" section so a suppression is never mistaken for approval.
#   Triage a NEW flag against the chart templates (`grep -rn '.Values.<key>'
#   <layer>/charts/*/`): referenced → back-compat-OK; absent → real wrong-key.
#
# Offline: this hook prefers the LOCAL vendored chart that kustomize expands
#   under `<layer>/charts/<name>-<version>/` (present because these layers
#   commit their charts), so it runs with NO network. It falls back to
#   `helm show values <repo>/<name> --version` only when no vendored copy
#   exists, and soft-fails (warn, don't block) if that fetch can't reach the
#   repo — a pre-commit hook must never wedge on a network blip.
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
# Enforcement is OPT-IN per layer (v2). A layer BLOCKS on unknown keys only
# once it carries a `.helmcheckignore` (the operator has triaged it). Layers
# without one WARN but do not block — so this hook can be wired repo-wide
# without reding CI on the pre-existing v1 flags that most helm layers still
# have. To gate a layer: run `--layer <dir>`, triage each flag against the
# chart templates, and record it in that layer's `.helmcheckignore`.
#
# Exit codes:
#   0 = every BASELINED layer is clean (unbaselined layers may have warned).
#   1 = a baselined layer has an unknown key beyond its .helmcheckignore
#       (NEW drift → block commit / deploy).
#   2 = invocation / dependency error (helm not found). Missing PyYAML or an
#       unreachable non-vendored chart repo soft-skip (exit 0), never block.
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

command -v helm >/dev/null 2>&1 || { err "helm not on PATH"; exit 2; }

# Pick a python3 that actually has PyYAML — the operator's default python3 may
# be a brew build without it while /usr/bin/python3 has it. If NONE has yaml,
# soft-skip (exit 0): a missing lib is an environment issue, not a values bug,
# and a pre-commit hook must never wedge a commit on it.
PYTHON=""
for py in python3 /usr/bin/python3 /usr/local/bin/python3 python; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c "import yaml" >/dev/null 2>&1; then
    PYTHON="$py"; break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "check-helm-values-keys: no python3 with PyYAML found — SKIPPING (install" \
       "pyyaml to enable this check; env issue, not a values bug)." >&2
  exit 0
fi

# Decide which layers to check.
# NB: `layers=()` not `declare -a layers` — a declared-but-unassigned array
# still trips `set -u` on `${#layers[@]}` in bash 5.x; an empty assignment
# initializes it safely.
layers=()
if [ -n "$layer_arg" ]; then
  layers=("$layer_arg")
elif [ "${#positional[@]}" -gt 0 ]; then
  # Pre-commit mode: derive layers from changed files.
  declare -A seen
  for f in "${positional[@]}"; do
    case "$f" in
      *.yaml|*.helmcheckignore)
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
  STRICT="$strict" REPO_ROOT="$REPO_ROOT" "$PYTHON" - <<'PYEOF' "$layer"
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

def local_chart_dir(name, ver):
    """kustomize expands a committed helmChart under
    <layer>/charts/<name>-<ver>/. `helm show values` wants the dir holding
    Chart.yaml, which is either that dir or a <name>/ subdir inside it.
    Returns the path if a vendored copy exists, else None (→ remote fetch)."""
    base = layer / "charts" / f"{name}-{ver}"
    for cand in (base / name, base):
        if (cand / "Chart.yaml").is_file():
            return cand
    return None

def cache_chart_values(repo, name, ver):
    safe = re.sub(r"[^A-Za-z0-9_.-]", "_",
                  f"{urllib.parse.urlparse(repo).netloc}_{name}_{ver}")
    cache = Path(f"/tmp/helmkeys-cache/{safe}.yaml")
    local = local_chart_dir(name, ver)
    if local is not None:
        # Offline path: read the vendored chart directly. No cache, no network.
        try:
            r = subprocess.run(
                ["helm", "show", "values", str(local)],
                check=False, capture_output=True, text=True, timeout=60,
            )
            if r.returncode != 0:
                return None, r.stderr.strip() or "helm show values (local chart) failed"
            return yaml.safe_load(r.stdout) or {}, None
        except subprocess.TimeoutExpired:
            return None, "helm show values (local chart) timed out"
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

    # Per-layer baseline: acknowledged keys (and their nested descendants) are
    # suppressed so only NEW unknowns flag. `#` comments + blank lines ignored.
    baseline_file = layer / ".helmcheckignore"
    baseline = []
    if baseline_file.exists():
        for raw in baseline_file.read_text().splitlines():
            entry = raw.split("#", 1)[0].strip()
            if entry:
                baseline.append(entry)

    def acknowledged(path):
        # An entry `a.b` covers `a.b` exactly and any descendant `a.b.*`.
        return any(path == e or path.startswith(e + ".") for e in baseline)

    suppressed = [p for p in unknown if acknowledged(p)]
    unknown = [p for p in unknown if not acknowledged(p)]

    # Flag stale baseline entries (acknowledge nothing currently flagged) so the
    # file stays honest as the chart/values evolve. Non-fatal — just a nudge.
    if baseline:
        matched = {e for p in suppressed for e in baseline
                   if p == e or p.startswith(e + ".")}
        stale = [e for e in baseline if e not in matched]
        if stale:
            print(f"  · {baseline_file}: {len(stale)} stale baseline entry(ies) "
                  f"(no longer flagged — safe to delete): {', '.join(stale)}",
                  file=sys.stderr)
    if suppressed:
        print(f"  · {vfp}: {len(suppressed)} key(s) suppressed by "
              f".helmcheckignore baseline.")

    if unknown and baseline_file.exists():
        # Layer is OPTED INTO enforcement (it has a baseline): any key beyond
        # the baseline is NEW drift → block.
        print(f"  ✗ {vfp}: keys NOT in chart {name}@{ver} (and not in "
              f".helmcheckignore):")
        for p in unknown:
            print(f"      - {p}")
        print(f"    Triage: `grep -rn '.Values.{unknown[0]}' {layer}/charts/*/` "
              f"— chart reads it → add to {baseline_file} (back-compat-OK "
              f"section); it doesn't → real dropped wrong-key, fix values.yaml.")
        problems += 1
    elif unknown:
        # No baseline yet → enforcement is OPT-IN. Warn, don't block: wiring
        # this hook repo-wide must not red CI on the pre-existing v1 flags that
        # exist across most helm layers (list-item subpaths, empty-dict/toYaml
        # passthrough configs, plus some genuine wrong-keys). A layer becomes
        # gated once the operator triages it into a .helmcheckignore. Run
        # `--layer <dir>` to see the keys.
        print(f"  · {vfp}: {len(unknown)} unrecognized key(s), no "
              f".helmcheckignore — NOT enforced. Triage with "
              f"`scripts/check-helm-values-keys.sh --layer {layer}` and add a "
              f"baseline to gate this layer.", file=sys.stderr)
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
