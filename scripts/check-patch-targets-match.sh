#!/usr/bin/env bash
# check-patch-targets-match.sh — every kustomize patch must actually change the render.
#
# SYNCED SCRIPT: canonical copy is homelab-k8s/scripts/. App repos consume it
# (via homelab-hooks once ADR 0047's migration lands; a byte-identical copy
# until then).
#
# WHY THIS EXISTS
#
# ADR 0052 keeps kustomize in the Helm render path — charts come from the
# mirror, and layers keep post-rendering them with `patches:`. That decision
# was taken over the alternative (Argo's own Helm source) specifically because
# post-render can express things chart values cannot: jellyfin's config PVC
# carries a Longhorn `recurring-job-group.longhorn.io/*` LABEL, and that chart
# templates PVC labels only from its own helper — there is no values key for it.
#
# The price is that kustomize fails *silently* in exactly the case a chart bump
# produces. Measured 2026-08-15 against jellyfin/k8s with kustomize 5.8.1:
#
#   patch target                                     chart bump renames it
#   ----------------------------------------------   ---------------------
#   strategic merge, target by name                  exit 0, no stderr, patch GONE
#   strategic merge, target by labelSelector         exit 0, no stderr, patch GONE
#   JSON 6902, path that no longer exists            exit 1, "doc is missing path"
#
# So the loud case is already caught by the render itself, and the silent case
# is not caught by anything. A chart bump that renames a Deployment or drops
# `app.kubernetes.io/managed-by=Helm` would remove `Replace=true` and the
# Longhorn backup-group label from the render, and Argo would sync it green.
# That is the same failure class as the `check-helm-values-keys` network
# soft-fail ADR 0047 was written about: a gate reporting success while
# checking nothing.
#
# THE TEST
#
# Render the layer with all patches, then once per patch with that patch
# removed. If the output is identical, the patch changed nothing — it is either
# not matching, or it is dead weight setting a value that already holds. Both
# are worth a human looking.
#
# WHERE IT MUST RUN
#
# Pre-commit AND CI. Chart version pins are bumped by Renovate, which commits
# server-side, so a local hook never fires on the commit that actually breaks a
# patch target. CI is the only place that path is observed.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '  %s\n' "$*"; }

KUSTOMIZE_BIN="${KUSTOMIZE_BIN:-kustomize}"
# CI sets this: a layer whose chart source is unreachable is a FAILURE there,
# because CI is the only place that observes Renovate's server-side commits.
REQUIRE_RENDER="${REQUIRE_RENDER:-false}"
HELM_BIN="${HELM_BIN:-helm}"

for tool in "$KUSTOMIZE_BIN" python3 git; do
  command -v "$tool" >/dev/null 2>&1 || { err "required tool missing: $tool"; exit 1; }
done

# Layers may opt out with a reason. A patch that legitimately renders identically
# is dead config, so the bar for adding a line here is "explain why it stays".
#   <layer>|<patch index>|<reason>
OPT_OUT='
'

usage() {
  cat >&2 <<EOF
usage: $0 [--all | <layer-dir>...]

  (no args)     layers owning staged files — the pre-commit mode
  --all         every kustomization.yaml with a 'patches:' block
  (env REQUIRE_RENDER=true turns an unreachable chart source into a failure —
   set it in CI, leave it unset on a workstation)
  <layer-dir>   check exactly these layers

env: KUSTOMIZE_BIN (default: kustomize), HELM_BIN (default: helm)
EOF
  exit 2
}

# ── Which layers?
layers=()
case "${1:-}" in
  --all)
    while IFS= read -r f; do layers+=("$(dirname "$f")"); done < <(
      git ls-files '*kustomization.yaml' \
        | grep -v '/charts/' \
        | while IFS= read -r f; do grep -q '^patches:' "$f" && echo "$f"; done
    )
    ;;
  -h|--help) usage ;;
  "")
    # Pre-commit: map each staged file up to the nearest kustomization.yaml.
    staged=$(git diff --cached --name-only --diff-filter=ACM || true)
    [ -n "$staged" ] || { echo "OK: nothing staged."; exit 0; }
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in */charts/*) continue ;; esac
      d=$(dirname "$f")
      while [ "$d" != "." ] && [ "$d" != "/" ]; do
        if [ -f "$d/kustomization.yaml" ] && grep -q '^patches:' "$d/kustomization.yaml"; then
          layers+=("$d"); break
        fi
        d=$(dirname "$d")
      done
    done <<< "$staged"
    ;;
  *) layers=("$@") ;;
esac

# de-duplicate, preserve order
if [ "${#layers[@]}" -gt 0 ]; then
  mapfile -t layers < <(printf '%s\n' "${layers[@]}" | awk '!seen[$0]++')
fi

if [ "${#layers[@]}" -eq 0 ]; then
  echo "OK: no patch-bearing layer in scope."
  exit 0
fi

tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/patch-targets.XXXXXX")"
trap 'rm -rf "$tmp_root"' EXIT

# Render in a COPY OF THE WHOLE REPO, not of the layer.
#
# Copying just the layer looks cheaper and is wrong: homelab-k8s layers pull
# shared components by relative path (`../../components/site-config`), so a
# lone layer fails to build with "not a valid directory" — which this script
# would then report as a broken patch. Found the first time it ran across all
# layers: five of eight "failed", none of them because of a patch.
#
# The copy is also what keeps the source tree clean — kustomize's Helm inflator
# writes charts/ next to the kustomization it builds, and doing that in the real
# checkout is exactly what test-hermetic-kustomize.sh forbids. A vendored
# charts/ that comes along in the copy is a bonus: those layers need no network.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$repo_root" ]; then
  build_root="$tmp_root/repo"
  mkdir -p "$build_root"
  # tar rather than cp -R: excludes .git without copying it first.
  (cd "$repo_root" && tar --exclude=./.git -cf - .) | (cd "$build_root" && tar -xf -)
else
  build_root=""   # not a git repo: fall back to per-layer copies (see below)
fi

render() {
  # $1 = dir. Renders to stdout. --enable-helm is harmless on a layer with no
  # helmCharts, and required on one that has them.
  "$KUSTOMIZE_BIN" build --enable-helm --helm-command "$HELM_BIN" "$1"
}

problems=0
checked=0
render_failures=0
unreachable=0

for layer in "${layers[@]}"; do
  k="$layer/kustomization.yaml"
  [ -f "$k" ] || { err "$layer has no kustomization.yaml"; problems=$((problems+1)); continue; }
  grep -q '^patches:' "$k" || { note "$layer: no patches — skipped"; continue; }

  n_patches=$(python3 -c "
import sys,yaml
d=yaml.safe_load(open('$k')) or {}
print(len(d.get('patches') or []))
")
  [ "$n_patches" -gt 0 ] || { note "$layer: patches: block is empty — skipped"; continue; }

  if [ -n "$build_root" ]; then
    # Repo-relative path inside the copy, so `../../components/...` resolves.
    rel="$(cd "$layer" && git rev-parse --show-prefix)"
    work="$build_root/${rel%/}"
  else
    work="$tmp_root/$(echo "$layer" | tr '/' '_')"
    mkdir -p "$work"
    cp -R "$layer/." "$work/"
  fi
  k_work="$work/kustomization.yaml"

  echo "== $layer ($n_patches patch(es))"

  if ! render "$work" > "$tmp_root/.baseline.yaml" 2> "$tmp_root/.baseline.err"; then
    # Distinguish "this host cannot reach the chart source" from "this layer is
    # broken". Since ADR 0052 the charts come from an OCI mirror, and a macOS
    # workstation cannot pull from it at all: Go on darwin verifies through
    # Security.framework and ignores SSL_CERT_FILE, so every converted layer
    # fails with x509 locally while rendering perfectly in argocd-repo-server,
    # which is Linux. Treating that as a patch defect would block every commit
    # touching a converted layer, on the machine where commits are made.
    if grep -qE 'x509|tls: failed|FetchReference|connection refused|no such host' "$tmp_root/.baseline.err"; then
      if [ "$REQUIRE_RENDER" = true ]; then
        err "$layer: cannot reach the chart source, and --require-render is set."
        sed 's/^/      /' "$tmp_root/.baseline.err" | head -3 >&2
        render_failures=$((render_failures+1))
      else
        note "$layer: SKIPPED — chart source unreachable from this host (expected on"
        note "    macOS for a mirror-backed layer). NOT verified here; CI runs this"
        note "    with --require-render, which is where it is enforced."
        unreachable=$((unreachable+1))
      fi
      continue
    fi
    err "$layer: baseline render FAILED — fix that before this check can mean anything"
    sed 's/^/      /' "$tmp_root/.baseline.err" | head -5 >&2
    render_failures=$((render_failures+1))
    continue
  fi
  # The baseline render populated charts/ inside $work, so the per-patch
  # renders below reuse it instead of pulling the chart N more times.

  i=0
  while [ "$i" -lt "$n_patches" ]; do
    reason=$(printf '%s' "$OPT_OUT" | awk -F'|' -v l="$layer" -v i="$i" '$1==l && $2==i {print $3}')
    if [ -n "$reason" ]; then
      note "patch[$i]: opted out — $reason"
      i=$((i+1)); continue
    fi

    desc=$(python3 -c "
import yaml
d=yaml.safe_load(open('$k')) or {}
p=(d.get('patches') or [])[$i]
t=p.get('target') or {}
bits=[f\"{k2}={v}\" for k2,v in t.items()]
src=p.get('path') or 'inline'
print(f\"target({', '.join(bits) or 'none'}) via {src}\")
")

    python3 - "$k" "$k_work" "$i" <<'PY'
import sys, yaml
src, dst, idx = sys.argv[1], sys.argv[2], int(sys.argv[3])
d = yaml.safe_load(open(src)) or {}
patches = d.get('patches') or []
del patches[idx]
d['patches'] = patches
yaml.safe_dump(d, open(dst, 'w'), sort_keys=False)
PY

    if ! render "$work" > "$tmp_root/.without.yaml" 2> "$tmp_root/.without.err"; then
      # Removing a patch broke the render. That is information, not a pass:
      # usually one patch creates what another targets.
      note "patch[$i]: removing it breaks the render — treated as APPLYING. $desc"
      i=$((i+1))
      cp "$k" "$k_work"
      continue
    fi

    if cmp -s "$tmp_root/.baseline.yaml" "$tmp_root/.without.yaml"; then
      err "$layer patch[$i] changes NOTHING — it is not matching any rendered object."
      note "    $desc"
      note "    Either its target moved (a chart bump renames or relabels), or the"
      note "    patch sets a value that already holds. kustomize does not report"
      note "    this: an unmatched selector is exit 0 with no stderr."
      problems=$((problems+1))
    else
      changed=$(diff "$tmp_root/.baseline.yaml" "$tmp_root/.without.yaml" | grep -c '^[<>]' || true)
      note "patch[$i]: applies ($changed line(s)) — $desc"
    fi

    cp "$k" "$k_work"
    checked=$((checked+1))
    i=$((i+1))
  done
done

if [ "$render_failures" -gt 0 ]; then
  cat >&2 <<EOF

$render_failures layer(s) could not be rendered at all, so their patches were
never tested. That is a broken layer, not a broken patch — fix the render first.
EOF
fi

if [ "$problems" -gt 0 ]; then
  cat >&2 <<EOF

$problems patch(es) matched nothing.

This is the failure mode ADR 0052 accepted when it kept kustomize in the Helm
render path: a chart bump can rename or relabel the object a patch targets, and
kustomize drops the patch silently rather than failing. Argo then syncs the
result green.

Fix by re-pointing the patch at the object the chart renders now — compare
\`kustomize build --enable-helm <layer>\` before and after the bump. If the patch
is genuinely obsolete, delete it. If it must stay and legitimately renders
identically, add a line to OPT_OUT in this script with the reason.
EOF
  exit 1
fi

if [ "$render_failures" -gt 0 ]; then exit 1; fi

if [ "$unreachable" -gt 0 ]; then
  echo "NOTE: $unreachable layer(s) skipped — chart source unreachable from this host."
  echo "      They are enforced in CI (REQUIRE_RENDER=true). This run did not verify them."
fi
echo "OK: $checked patch(es) across ${#layers[@]} layer(s) all change the render."
exit 0
