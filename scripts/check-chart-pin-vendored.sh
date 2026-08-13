#!/usr/bin/env bash
# check-chart-pin-vendored.sh — the vendored Helm chart must match the pin.
#
# Usage: check-chart-pin-vendored.sh [--layer DIR] [--strict] [FILES...]
#
#   --layer DIR   Check exactly this kustomize layer.
#   --strict      Treat "layer vendors nothing" as a failure too (default:
#                 a layer with no charts/ directory has not opted into
#                 vendoring and is skipped).
#   FILES...      Pre-commit mode: derive the owning layer(s) from changed
#                 files by walking up to the nearest kustomization.yaml.
#   (no args)     Full sweep of every kustomization.yaml in the repo.
#
# WHY THIS EXISTS
#   A kustomize layer pins a chart version in `kustomization.yaml`:
#
#     helmCharts:
#       - name: nextcloud
#         repo: https://nextcloud.github.io/helm/
#         version: "9.2.5"        # OPERATOR PINS via Renovate
#
#   Layers that vendor their chart also carry the expanded copy under
#   `<layer>/charts/<name>-<version>/`. Nothing kept the two in sync.
#   Renovate bumps the pin — it edits YAML, it cannot re-pull a chart
#   tarball — so every chart bump silently desynchronized the vendored
#   copy from the version actually rendered.
#
#   Observed 2026-08-13: nextcloud pinned 9.2.5 while vendoring 5.5.6 (a
#   five-major gap, landed by Renovate PR #5), and vaultwarden pinned
#   0.44.0 while vendoring 0.43.1 (PR #2). Both had been drifted for
#   weeks with no signal.
#
#   That desync is not cosmetic. The vendored copy is what
#   check-helm-values-keys.sh reads to verify every key in the layer's
#   values.yaml is one the chart actually consumes. Point that check at a
#   stale chart and it validates against the wrong schema: keys renamed
#   by the new chart pass, keys the new chart added look unknown. Worse,
#   when no vendored copy matches the pin the linter falls back to a
#   network `helm show values` and SOFT-FAILS to a warning if the fetch
#   cannot reach the chart repo — which, under a deny-by-default CI
#   egress policy, is every run. The gate silently becomes a no-op.
#
#   So this check is a precondition for that one: it is cheap, it needs
#   no network and no helm binary, and it fails loudly and specifically.
#
# WHAT COUNTS AS OPTING IN
#   Presence of `<layer>/charts/`. A layer with no such directory does
#   not vendor and is skipped (use --strict to flag those too). This
#   mirrors the opt-in convention .helmcheckignore already establishes
#   for the values-key linter: a layer is enforced once the operator has
#   done the work to enforce it.
set -euo pipefail

usage() { sed -n '/^# Usage:/,/^$/p' "$0" | sed -E 's/^# ?//'; }
err()   { echo "ERROR: $*" >&2; }

layer_arg=""
strict=0
positional=()

while [ $# -gt 0 ]; do
  case "$1" in
    --layer)   layer_arg="${2:?--layer needs a directory}"; shift 2 ;;
    --strict)  strict=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --)        shift; positional+=("$@"); break ;;
    -*)        err "unknown option: $1"; usage >&2; exit 2 ;;
    *)         positional+=("$1"); shift ;;
  esac
done

# Repo root from the INVOCATION, not from $0. This script is consumed as a
# shared pre-commit hook, so $0 lives in pre-commit's clone cache, not in
# the repo being checked. pre-commit runs hooks with cwd = repo root.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# PyYAML is required to parse helmCharts reliably (multi-chart layers, OCI
# repos, quoted versions). Probe the same candidates as its sibling check:
# the operator's default python3 may be a venv build without yaml while
# /usr/bin/python3 has it.
PYTHON=""
for py in python3 /usr/bin/python3 /usr/local/bin/python3 python; do
  if command -v "$py" >/dev/null 2>&1 && "$py" -c "import yaml" >/dev/null 2>&1; then
    PYTHON="$py"; break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "check-chart-pin-vendored: no python3 with PyYAML found — SKIPPING" \
       "(install pyyaml to enable this check; env issue, not a pin bug)." >&2
  exit 0
fi

# Decide which layers to check.
# NB: `layers=()` not `declare -a layers` — a declared-but-unassigned array
# still trips `set -u` on `${#layers[@]}` in bash 5.x.
layers=()
if [ -n "$layer_arg" ]; then
  layers=("$layer_arg")
elif [ "${#positional[@]}" -gt 0 ]; then
  declare -A seen
  for f in "${positional[@]}"; do
    case "$f" in
      *.yaml)
        d="$(dirname "$f")"
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
  if [ "${#layers[@]}" -eq 0 ]; then
    echo "check-chart-pin-vendored: no kustomize layers touched — nothing to do."
    exit 0
  fi
else
  # Full sweep. Prune charts/ — a vendored chart contains its own
  # kustomization.yaml files in some upstream charts, and those are not
  # our layers.
  while IFS= read -r kf; do
    layers+=("$(dirname "$kf")")
  done < <(
    find "$REPO_ROOT" -type d -name charts -prune -o \
         -type d -name .git -prune -o \
         -name kustomization.yaml -print 2>/dev/null
  )
  if [ "${#layers[@]}" -eq 0 ]; then
    echo "check-chart-pin-vendored: no kustomization.yaml found under $REPO_ROOT."
    exit 0
  fi
fi

problems=0

for layer in "${layers[@]}"; do
  STRICT="$strict" "$PYTHON" - "$layer" <<'PYEOF' || problems=$((problems + 1))
import os, sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("ERROR: python yaml not installed", file=sys.stderr)
    sys.exit(2)

layer  = Path(sys.argv[1])
strict = os.environ.get("STRICT") == "1"
kust   = layer / "kustomization.yaml"

if not kust.exists():
    sys.exit(0)

try:
    kdata = yaml.safe_load(kust.read_text()) or {}
except yaml.YAMLError as e:
    print(f"  {layer}/kustomization.yaml: not valid YAML — {e}", file=sys.stderr)
    sys.exit(1)

charts = kdata.get("helmCharts") or []
if not charts:
    sys.exit(0)

charts_dir = layer / "charts"
if not charts_dir.is_dir():
    if strict:
        print(f"  {layer}: pins {len(charts)} chart(s) but vendors none "
              f"(--strict); expected {layer}/charts/", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)

def chart_yaml_for(base, name):
    """`helm pull --untar --untardir <base>` lands the chart at
    <base>/<name>/Chart.yaml. Tolerate <base>/Chart.yaml too, for charts
    vendored without the extra level."""
    for cand in (base / name, base):
        cy = cand / "Chart.yaml"
        if cy.is_file():
            return cy
    return None

failed   = False
expected = set()

for c in charts:
    name = c.get("name")
    ver  = c.get("version")
    if not name or not ver:
        print(f"  {layer}: helmCharts entry missing name/version "
              f"(name={name!r} version={ver!r})", file=sys.stderr)
        failed = True
        continue

    ver = str(ver)
    base = charts_dir / f"{name}-{ver}"
    expected.add(base.name)

    cy = chart_yaml_for(base, name)
    if cy is None:
        have = sorted(p.name for p in charts_dir.iterdir() if p.is_dir())
        print(f"  {layer}: pins {name}@{ver} but no vendored chart at "
              f"{base.relative_to(layer)}/", file=sys.stderr)
        print(f"      vendored here: {', '.join(have) if have else '(none)'}",
              file=sys.stderr)
        # `helm pull <repo-url>/<name>` is NOT valid for an HTTP repo — helm
        # reads the concatenation as a chart URL and 404s. The repo goes in
        # --repo (helm 3.18 `helm pull [chart URL | repo/chartname]`).
        # OCI is the exception: there the ref genuinely is <repo>/<name>.
        repo_url = c.get("repo", "")
        if repo_url.startswith("oci://"):
            pull = f"helm pull {repo_url.rstrip('/')}/{name}"
        else:
            pull = f"helm pull {name} --repo {repo_url or '<repo>'}"
        print(f"      fix: {pull} --version {ver} --untar --untardir {base}",
              file=sys.stderr)
        failed = True
        continue

    try:
        cmeta = yaml.safe_load(cy.read_text()) or {}
    except yaml.YAMLError as e:
        print(f"  {cy}: not valid YAML — {e}", file=sys.stderr)
        failed = True
        continue

    actual = str(cmeta.get("version", ""))
    if actual != ver:
        print(f"  {layer}: pins {name}@{ver} but {cy.relative_to(layer)} "
              f"declares version {actual!r} — directory name lies",
              file=sys.stderr)
        failed = True

    cname = str(cmeta.get("name", ""))
    if cname and cname != name:
        print(f"  {layer}: pins name {name!r} but {cy.relative_to(layer)} "
              f"declares name {cname!r}", file=sys.stderr)
        failed = True

# A stale copy left beside the pinned one is what git history is for, and it
# is the exact shape the drift took before it was noticed.
stale = sorted(p.name for p in charts_dir.iterdir()
               if p.is_dir() and p.name not in expected)
if stale:
    print(f"  {layer}: stale vendored chart(s) not referenced by any pin: "
          f"{', '.join(stale)}", file=sys.stderr)
    print(f"      git history already holds them; remove from the worktree.",
          file=sys.stderr)
    failed = True

sys.exit(1 if failed else 0)
PYEOF
done

if [ "$problems" -gt 0 ]; then
  err "vendored Helm charts disagree with their pins in $problems layer(s)."
  echo "       The values-key linter reads the VENDORED chart; a stale copy" >&2
  echo "       validates values.yaml against the wrong schema, and a missing" >&2
  echo "       one degrades that check to a network soft-fail." >&2
  exit 1
fi

echo "PASS: every vendoring layer's chart matches its pin."
