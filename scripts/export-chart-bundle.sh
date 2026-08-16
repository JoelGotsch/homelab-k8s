#!/usr/bin/env bash
# export-chart-bundle.sh — every chart the cluster needs, as files, outside the
# cluster.
#
# WHY THIS IS A PRECONDITION, NOT A NICETY (ADR 0052 D7)
#
# Charts are referenced from the Forgejo Packages mirror instead of vendored in
# git. That mirror runs *in the cluster*, and tier-0 charts (cilium,
# cert-manager, external-secrets, openbao, cnpg, longhorn, csi-rclone, forgejo)
# are what the cluster needs to exist before Forgejo can serve anything. Without
# a copy of those charts somewhere else, a cold start has no source for them and
# ADR 0052's resilience claim is half made.
#
# WHAT MAKES THE BUNDLE TRUSTWORTHY
#
# Each chart is written with a `.sha256` of the artifact, and `bundle.manifest`
# records the CONTENT digest from charts.lock.yaml — a hash over the extracted
# tree, which is what determines the render. Artifact bytes are not guaranteed
# to survive a mirror round-trip; content is. `import-chart-bundle.sh` verifies
# both before pushing anything.
#
# Idempotent: a chart already present with a matching artifact hash is not
# re-downloaded. Re-running is how you refresh after a Renovate bump.
#
# SIZE: all 32 charts are ~4.4 MB total, so this fits anywhere — a Storage Box,
# a laptop, a USB stick, even an email attachment.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '  %s\n' "$*"; }

HELM_BIN="${HELM_BIN:-helm3}"
REGISTRY="${REGISTRY:-registry.homelab.internal}"
ORG="${ORG:-homelab}"
CA_FILE="${CA_FILE:-$HOME/.config/homelab/ca.pem}"
SOURCE="${SOURCE:-mirror}"        # mirror | upstream

usage() {
  cat >&2 <<EOF
usage: $0 <outdir> <charts.lock.yaml> [more-locks...]

  Writes <name>-<version>.tgz + .sha256 for every locked chart, plus
  bundle.manifest recording content digests and tool versions.

env: SOURCE=mirror|upstream (default mirror), HELM_BIN, REGISTRY, ORG, CA_FILE

  SOURCE=upstream pulls from each chart's original repository instead — use it
  to build a bundle when the cluster (and therefore the mirror) is down, which
  is exactly the situation the bundle exists for.
EOF
  exit 2
}

[ "$#" -ge 2 ] || usage
OUTDIR="$1"; shift
LOCKS=("$@")

for t in "$HELM_BIN" python3 shasum; do
  command -v "$t" >/dev/null 2>&1 || { err "required tool missing: $t"; exit 1; }
done
for l in "${LOCKS[@]}"; do [ -f "$l" ] || { err "lock not found: $l"; exit 1; }; done

mkdir -p "$OUTDIR"
work="$(mktemp -d "${TMPDIR:-/tmp}/chart-bundle.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 - "${LOCKS[@]}" <<'PY' > "$work/entries.tsv"
import sys, yaml
seen = {}
for lockf in sys.argv[1:]:
    for e in (yaml.safe_load(open(lockf)) or []):
        key = (e['name'], str(e['version']))
        if key in seen:      # the same chart can be pinned by several repos
            continue
        seen[key] = e
        print(f"{e['name']}\t{e['version']}\t{e.get('upstream','')}\t{e.get('content_digest') or ''}")
PY

pulled=0; present=0; failed=0
: > "$work/manifest.tsv"
while IFS=$'\t' read -r name version upstream content; do
  [ -n "$name" ] || continue
  tgz="$OUTDIR/$name-$version.tgz"
  if [ -f "$tgz" ] && [ -f "$tgz.sha256" ] && ( cd "$OUTDIR" && shasum -a 256 -c "$name-$version.tgz.sha256" >/dev/null 2>&1 ); then
    present=$((present+1))
  else
    rm -f "$tgz" "$tgz.sha256"
    if [ "$SOURCE" = upstream ] && [ -n "$upstream" ]; then
      case "$upstream" in
        oci://*) "$HELM_BIN" pull "${upstream%/}/$name" --version "$version" -d "$OUTDIR" >/dev/null 2>&1 || { err "$name: upstream pull failed"; failed=$((failed+1)); continue; } ;;
        *)       "$HELM_BIN" pull "$name" --repo "$upstream" --version "$version" -d "$OUTDIR" >/dev/null 2>&1 || { err "$name: upstream pull failed"; failed=$((failed+1)); continue; } ;;
      esac
    else
      "$HELM_BIN" pull "oci://$REGISTRY/$ORG/$name" --version "$version" -d "$OUTDIR" --ca-file "$CA_FILE" >/dev/null 2>&1 \
        || { err "$name $version: pull from mirror failed"; failed=$((failed+1)); continue; }
    fi
    [ -f "$tgz" ] || { err "$name: helm produced no $name-$version.tgz"; failed=$((failed+1)); continue; }
    ( cd "$OUTDIR" && shasum -a 256 "$name-$version.tgz" > "$name-$version.tgz.sha256" )
    pulled=$((pulled+1))
  fi
  art="$( cd "$OUTDIR" && shasum -a 256 "$name-$version.tgz" | cut -d' ' -f1 )"
  printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$art" "$content" >> "$work/manifest.tsv"
done < "$work/entries.tsv"

{
  echo "# Chart bundle — every chart this workspace pins (ADR 0052 D7)."
  echo "#"
  echo "# Restore with: import-chart-bundle.sh <this-dir> <registry>"
  echo "# Verify only:  cd <this-dir> && shasum -a 256 -c *.sha256"
  echo "#"
  echo "# content_digest is a hash over the EXTRACTED tree, copied from"
  echo "# charts.lock.yaml. It is the render-determining identity; artifact bytes"
  echo "# are not guaranteed stable across a mirror round-trip."
  echo "#"
  echo "# NOTE: generated_at is deliberately absent — a timestamp would make every"
  echo "# regeneration a diff even when no chart changed, and this file is meant to"
  echo "# be comparable. Use the file mtime or the transport's own metadata."
  echo "helm_version: $($HELM_BIN version --short 2>/dev/null || echo unknown)"
  echo "source: $SOURCE"
  echo "chart_count: $(wc -l < "$work/manifest.tsv" | tr -d ' ')"
  echo "charts:"
  sort "$work/manifest.tsv" | while IFS=$'\t' read -r n v a c; do
    echo "  - name: $n"
    echo "    version: \"$v\""
    echo "    artifact_sha256: sha256:$a"
    echo "    content_digest: ${c:-null}"
  done
} > "$OUTDIR/bundle.manifest"

echo
echo "── state"
echo "   newly downloaded : $pulled"
echo "   already present  : $present"
echo "   failed           : $failed"
echo "   bundle           : $OUTDIR ($(du -sh "$OUTDIR" | cut -f1))"
[ "$failed" -gt 0 ] && exit 1
exit 0
