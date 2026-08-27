#!/usr/bin/env bash
# mirror-chart.sh — ensure every chart a repo pins exists in the Forgejo
# Packages mirror, byte-identical to upstream.
#
# ADR 0052 D1/D2: charts are referenced from the mirror, not vendored. This is
# what puts them there, and re-running it is how you check they are still
# right. Declared-state, not a sequence of actions: a second run with nothing
# changed is a no-op that prints `present`.
#
# CONTENT DIGEST, NOT ARTIFACT DIGEST — the correction that matters
#
# The obvious integrity check is "sha256 of the .tgz upstream == sha256 of the
# .tgz from the mirror". It is NOT SAFE to require, because the artifact bytes
# are not guaranteed to survive a mirror round-trip. Measured 2026-08-16:
#
#   vaultwarden 0.44.0   upstream 194adc8e…  mirrored b87527fb…  trees IDENTICAL
#   the five charts pushed by this script   upstream == mirrored, byte for byte
#
# So it depends on HOW the chart got there. Pushing the pulled tarball
# unchanged (what this script does) preserves the bytes; a copy that was
# repackaged along the way — as vaultwarden's evidently was, before this script
# existed — keeps the same content under different bytes. Requiring artifact
# equality would therefore flag a perfectly good mirror as divergent, and only
# for entries whose history nobody remembers.
#
# The invariant is over CONTENT: extract both, hash the file tree
# (`find -type f | sort` then sha256 of each path+content). That is what
# `content_digest` in charts.lock.yaml records, and it is the thing worth
# asserting — it is what determines the render. Both artifact digests are
# recorded for provenance, and deliberately never compared to each other.
#
# The artifact digests are recorded too, for provenance, but never compared to
# each other.
#
# CREDENTIALS
#
#   push  kv/shared/forgejo-packages/ci   (package:write)
#   pull  kv/argocd/registry-pull         (read:package — repo-server's, not used here)
#
# Never echoed: read from OpenBao into a variable, piped to helm on stdin.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '  %s\n' "$*"; }

HELM_BIN="${HELM_BIN:-helm3}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
REGISTRY="${REGISTRY:-registry.homelab.internal}"
ORG="${ORG:-homelab}"
CA_FILE="${CA_FILE:-$HOME/.config/homelab/ca.pem}"

APPLY=false
UPDATE_LOCK=false
# A LOOP, not a single `case`. It was a bare `case "${1:-}"` until 2026-08-20,
# which meant only the FIRST flag was ever parsed: in
# `mirror-chart.sh --apply --update-lock cilium` the `--apply` matched, and
# `--update-lock` fell through into ONLY=("$@") as a CHART-NAME FILTER. It
# matched no chart, so it was silently ignored and the lock was never written —
# while the chart really was pushed, so the run looked entirely successful.
#
# That is the exact command `check-chart-lock.sh` prints as its remedy, so the
# documented fix for a lock problem could not fix it. Cost a wrong diagnosis on
# 2026-08-19 ("the mirror was absent so there was nothing verified to record"),
# which was not the reason.
while [ "$#" -gt 0 ]; do
case "${1:-}" in
  --apply) APPLY=true; shift ;;
  --update-lock) UPDATE_LOCK=true; shift ;;
  --dry-run) APPLY=false; shift ;;
  "") shift || true ;;
  -h|--help)
    cat >&2 <<EOF
usage: $0 [--dry-run | --apply] [chart-name ...]

  --dry-run      (default) report what is missing or divergent
  --apply        pull from upstream and push what is missing
  --update-lock  verify, then record the observed digests into charts.lock.yaml
                 (only for entries that verified clean — never for a divergent
                 one, or the lock would launder a mismatch into the record)

Reads charts.lock.yaml in the current repo. env: HELM_BIN (default helm3),
PYTHON_BIN (default python3; must provide PyYAML), REGISTRY, ORG, CA_FILE,
BAO_ADDR/BAO_CACERT for the push credential.
EOF
    exit 2 ;;
  *) break ;;                # first non-flag: the rest are chart-name filters
esac
done
ONLY=("$@")

for t in "$HELM_BIN" "$PYTHON_BIN" bao; do
  command -v "$t" >/dev/null 2>&1 || { err "required tool missing: $t"; exit 1; }
done
"$PYTHON_BIN" -c 'import yaml' >/dev/null 2>&1 || {
  err "$PYTHON_BIN is present but cannot import yaml (PyYAML required)"
  err "select a prepared interpreter with PYTHON_BIN=<path-or-name>"
  exit 1
}
[ -f charts.lock.yaml ] || { err "no charts.lock.yaml in $(pwd)"; exit 1; }
[ -f "$CA_FILE" ] || { err "CA bundle not found at $CA_FILE.
      Get it with (it is a PUBLIC value):
        kubectl -n registry-integrity-probe get cm homelab-trust-bundle \\
          -o jsonpath='{.data.ca-certificates\\.crt}' > $CA_FILE
      Refresh it after any CA rotation — a stale copy fails with
      'certificate signed by unknown authority'."; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/mirror-chart.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# Content digest: hash of (relative path + file bytes) over the extracted tree,
# so packaging differences cannot affect it.
content_digest() {
  local dir="$1"
  ( cd "$dir" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s\n' "$f"; cat "$f"
    done ) | shasum -a 256 | cut -d' ' -f1
}

logged_in=false
registry_login() {
  [ "$logged_in" = true ] && return 0
  local u p
  u="$(bao kv get -mount=kv -field=username shared/forgejo-packages/ci)" || {
    err "cannot read the push credential from OpenBao (kv/shared/forgejo-packages/ci)"; return 1; }
  p="$(bao kv get -mount=kv -field=token shared/forgejo-packages/ci)" || return 1
  printf '%s' "$p" | "$HELM_BIN" registry login "$REGISTRY" \
      --ca-file "$CA_FILE" -u "$u" --password-stdin >/dev/null 2>&1 \
    || { err "helm registry login failed for $REGISTRY"; return 1; }
  logged_in=true
}

"$PYTHON_BIN" - charts.lock.yaml "${ONLY[@]:-}" <<'PY' > "$work/entries.tsv"
import sys, yaml
lock = yaml.safe_load(open(sys.argv[1])) or []
only = {a for a in sys.argv[2:] if a}
for e in lock:
    if only and e['name'] not in only:
        continue
    # `.get(k, '')` returns None when the key EXISTS with a null value, which is
    # exactly the state of a freshly generated lock — and "None" then compares
    # unequal to the real digest and reports a false "upstream changed".
    print(f"{e['name']}\t{e['version']}\t{e['upstream']}\t{e.get('content_digest') or ''}")
PY

present=0; pushed=0; mismatch=0; failed=0
while IFS=$'\t' read -r name version upstream want_digest; do
  [ -n "$name" ] || continue
  echo "── $name $version"

  # 1. upstream
  mkdir -p "$work/$name/up"
  case "$upstream" in
    oci://*) "$HELM_BIN" pull "$upstream/$name" --version "$version" -d "$work/$name/up" >/dev/null 2>&1 ;;
    *)       "$HELM_BIN" pull "$name" --repo "$upstream" --version "$version" -d "$work/$name/up" >/dev/null 2>&1 ;;
  esac || { err "$name: upstream pull failed from $upstream"; failed=$((failed+1)); continue; }
  ( cd "$work/$name/up" && tar xzf ./*.tgz )
  up_digest="$(content_digest "$work/$name/up/$name")"
  up_art="$(shasum -a 256 "$work/$name"/up/*.tgz | cut -d' ' -f1)"
  note "upstream  content=${up_digest:0:16}… artifact=${up_art:0:16}…"

  # Compare BARE hex to BARE hex. The lock stores `content_digest: sha256:<hex>`
  # while content_digest() returns the hex alone, so comparing the two strings
  # directly was true for EVERY entry that had ever been through --update-lock:
  # each one reported "UPSTREAM CHANGED under a pinned version" and the script
  # exited 1. Reproduced 2026-08-20 on cilium 1.20.0, where the two values are
  # the same hash. The bug hid behind the `-n` guard — a freshly generated lock
  # has null digests, so a first run looks clean and only the SECOND is wrong.
  if [ -n "$want_digest" ] && [ "${want_digest#sha256:}" != "${up_digest#sha256:}" ]; then
    err "$name: UPSTREAM CHANGED under a pinned version."
    note "  lock says   ${want_digest:0:24}…"
    note "  upstream is ${up_digest:0:24}…"
    note "  That is news, not a warning: a pinned version was re-cut. Investigate"
    note "  before updating the lock."
    mismatch=$((mismatch+1)); continue
  fi

  # 2. mirror
  mkdir -p "$work/$name/mir"
  if "$HELM_BIN" pull "oci://$REGISTRY/$ORG/$name" --version "$version" \
       -d "$work/$name/mir" --ca-file "$CA_FILE" >/dev/null 2>&1; then
    ( cd "$work/$name/mir" && tar xzf ./*.tgz )
    mir_digest="$(content_digest "$work/$name/mir/$name")"
    if [ "$mir_digest" = "$up_digest" ]; then
      note "mirror    present and content-identical"
      present=$((present+1))
      mir_art="$(shasum -a 256 "$work/$name"/mir/*.tgz | cut -d' ' -f1)"
      printf '%s\t%s\t%s\t%s\n' "$name" "$up_digest" "$up_art" "$mir_art" >> "$work/verified.tsv"
      continue
    fi
    err "$name: MIRROR DIVERGES from upstream at the same version."
    note "  upstream ${up_digest:0:24}…  mirror ${mir_digest:0:24}…"
    mismatch=$((mismatch+1)); continue
  fi

  note "mirror    ABSENT"
  if [ "$APPLY" != true ]; then continue; fi
  registry_login || { failed=$((failed+1)); continue; }
  if "$HELM_BIN" push "$work/$name"/up/*.tgz "oci://$REGISTRY/$ORG" \
       --ca-file "$CA_FILE" >/dev/null 2>&1; then
    note "mirror    PUSHED"
    pushed=$((pushed+1))
  else
    err "$name: push failed"; failed=$((failed+1))
  fi
done < "$work/entries.tsv"

if [ "$UPDATE_LOCK" = true ] && [ -s "$work/verified.tsv" ]; then
  "$PYTHON_BIN" - charts.lock.yaml "$work/verified.tsv" <<'PY2'
import sys, yaml
lockf, tsv = sys.argv[1], sys.argv[2]
seen = {}
for line in open(tsv):
    n, c, ua, ma = line.rstrip('\n').split('\t')
    seen[n] = (c, ua, ma)
lock = yaml.safe_load(open(lockf)) or []
for e in lock:
    if e['name'] in seen:
        c, ua, ma = seen[e['name']]
        e['content_digest'] = f'sha256:{c}'
        e['upstream_artifact_sha256'] = f'sha256:{ua}'
        e['mirror_artifact_sha256'] = f'sha256:{ma}'
hdr = ''.join(l for l in open(lockf) if l.startswith('#'))
with open(lockf, 'w') as fh:
    fh.write(hdr)
    yaml.safe_dump(lock, fh, sort_keys=False, default_flow_style=False)
print(f'   lock updated for {len(seen)} entr(y|ies)')
PY2
fi

echo
echo "── state"
echo "   present + identical : $present"
echo "   pushed              : $pushed"
echo "   divergent           : $mismatch"
echo "   failed              : $failed"
[ "$APPLY" = true ] || echo "   MODE                : dry-run"
{ [ "$mismatch" -gt 0 ] || [ "$failed" -gt 0 ]; } && exit 1
exit 0
