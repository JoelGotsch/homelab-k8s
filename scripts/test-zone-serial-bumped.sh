#!/usr/bin/env bash
# Controls for check-zone-serial-bumped.sh, run against throwaway git repos.
#
# A guard whose failure branch is unreachable reports green forever. That is
# not hypothetical here: the serial in
#   `@   IN SOA ns hostmaster ( 2 7200 3600 1209600 60 )`
# is awk's $7, while $6 is the literal `(` -- a check reading $6 can never see
# a serial, so it either fails always or passes always. Case "serial 2 -> 10"
# below is the one that catches that class of defect: a broken parser can still
# pass the negative control by accident, but it cannot also pass this.
#
# No cluster, no network, no writes outside mktemp.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$SCRIPT_DIR/check-zone-serial-bumped.sh"

for required_tool in git python3 mktemp; do
  command -v "$required_tool" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "$required_tool" >&2
    exit 2
  }
done

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zone-serial-test.XXXXXX")"
cleanup() {
  case "$TEMP_ROOT" in
    "${TMPDIR:-/tmp}"/zone-serial-test.*) rm -rf "$TEMP_ROOT" ;;
    *) printf 'ERROR: refusing to remove unexpected temp path: %s\n' "$TEMP_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

failures=0

# A miniature of infrastructure/cluster-dns/configmap.yaml: a Corefile key the
# `reload` directive does watch, next to a zone key it does not.
baseline_configmap() {
  cat <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-dns-corefile
data:
  Corefile: |
    {$FQDN_SUFFIX}:53 {
        errors
        reload
        file /etc/coredns/db.zone
    }
  db.zone: |
    $TTL 60
    ; BUMP THE SERIAL ON EVERY EDIT TO THIS ZONE.
    @   IN SOA ns hostmaster ( 2 7200 3600 1209600 60 )
    @   IN NS  ns
    ns      IN A 10.10.30.50
    *       IN A 10.10.30.50
    cp1     IN A 10.10.30.11
EOF
}

new_repo() {  # new_repo <name> -> path, with the baseline committed
  local repo="$TEMP_ROOT/$1"
  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@example.invalid
  git -C "$repo" config user.name 'Zone Serial Test'
  git -C "$repo" config commit.gpgsign false
  baseline_configmap >"$repo/configmap.yaml"
  printf 'unrelated: true\n' >"$repo/other.yaml"
  git -C "$repo" add configmap.yaml other.yaml
  git -C "$repo" commit -q -m baseline
  printf '%s' "$repo"
}

# edit <repo> <sed-expression...>  — rewrite configmap.yaml and stage it
edit() {
  local repo="$1"; shift
  local expr
  for expr in "$@"; do
    python3 - "$repo/configmap.yaml" "$expr" <<'PY'
import sys
path, expr = sys.argv[1], sys.argv[2]
old, new = expr.split("=>", 1)
text = open(path, encoding="utf-8").read()
if old not in text:
    raise SystemExit("test bug: %r not found in %s" % (old, path))
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
  done
  git -C "$repo" add configmap.yaml
}

expect() {  # expect <pass|fail> <name> <repo> [grep-fixture...]
  local want="$1" name="$2" repo="$3"; shift 3
  local out rc=0
  out="$("$CHECK" --repo "$repo" 2>&1)" || rc=$?
  if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then
    printf 'FAIL: expected exit 0: %s\n%s\n' "$name" "$out" >&2
    failures=$((failures + 1))
    return
  fi
  if [ "$want" = fail ] && [ "$rc" -eq 0 ]; then
    printf 'FAIL: expected a non-zero exit: %s\n%s\n' "$name" "$out" >&2
    failures=$((failures + 1))
    return
  fi
  local needle
  for needle in "$@"; do
    if ! printf '%s' "$out" | grep -qF -- "$needle"; then
      printf 'FAIL: %s: output does not mention %s\n%s\n' "$name" "$needle" "$out" >&2
      failures=$((failures + 1))
      return
    fi
  done
  printf 'ok (exit %d): %s\n' "$rc" "$name"
}

# 1. negative control: a record added, serial left alone.
r="$(new_repo record-no-bump)"
edit "$r" '    cp1     IN A 10.10.30.11=>    cp1     IN A 10.10.30.11
    ssh.forgejo IN A 10.10.30.51'
expect fail "record added without a serial bump" "$r" \
  "configmap.yaml [db.zone]" "HEAD 2, staged 2"

# 2. positive control: the same edit, serial bumped.
r="$(new_repo record-with-bump)"
edit "$r" '    cp1     IN A 10.10.30.11=>    cp1     IN A 10.10.30.11
    ssh.forgejo IN A 10.10.30.51' \
  '( 2 7200=>( 3 7200'
expect pass "record added with a serial bump" "$r" "serial 2 -> 3"

# 3. an unrelated staged file must not trip it.
r="$(new_repo unrelated-only)"
printf 'unrelated: true\nmore: yes\n' >"$r/other.yaml"
git -C "$r" add other.yaml
expect pass "an unrelated staged file is not in scope" "$r" "nothing to check"

# 4. nothing staged at all.
r="$(new_repo nothing-staged)"
expect pass "an empty index is not in scope" "$r" "nothing to check"

# 5. numeric, not lexical: 2 -> 10 is an increase. A column-guessing parser
#    (the `$6` == `(` defect) cannot pass this and case 1 at the same time.
r="$(new_repo serial-two-to-ten)"
edit "$r" '    cp1     IN A 10.10.30.11=>    cp2     IN A 10.10.30.12' \
  '( 2 7200=>( 10 7200'
expect pass "serial 2 -> 10 is an increase" "$r" "serial 2 -> 10"

# 6. a decrease is not a bump.
r="$(new_repo serial-decrease)"
edit "$r" '    cp1     IN A 10.10.30.11=>    cp2     IN A 10.10.30.12' \
  '( 2 7200=>( 1 7200'
expect fail "a serial decrease is rejected" "$r" "HEAD 2, staged 1"

# 7. a comment-only edit inside the zone needs no bump (CoreDNS ignores them).
r="$(new_repo comment-only)"
edit "$r" '; BUMP THE SERIAL ON EVERY EDIT TO THIS ZONE.=>; Bump the serial on every edit to this zone; see the 2026-09-12 incident.'
expect pass "a comment-only zone edit needs no bump" "$r" "zone content unchanged"

# 8. editing the Corefile (which `reload` DOES watch) needs no bump.
r="$(new_repo corefile-only)"
edit "$r" '        errors=>        errors
        log'
expect pass "a Corefile-only edit needs no bump" "$r" "zone content unchanged"

# 9. a brand-new zone file has no HEAD counterpart.
r="$(new_repo new-zone-file)"
cat >"$r/db.new.zone" <<'EOF'
$TTL 60
@   IN SOA ns hostmaster ( 1 7200 3600 1209600 60 )
@   IN NS  ns
ns  IN A 10.10.30.50
EOF
git -C "$r" add db.new.zone
expect pass "a new zone file has nothing to compare" "$r" "new zone"

# 10. multi-line SOA, edited without a bump.
r="$(new_repo multiline-no-bump)"
edit "$r" '    @   IN SOA ns hostmaster ( 2 7200 3600 1209600 60 )=>    @   IN SOA ns hostmaster (
                  2         ; serial
                  7200      ; refresh
                  3600      ; retry
                  1209600   ; expire
                  60 )'
git -C "$r" commit -q -m "multi-line SOA, same serial"
edit "$r" '    cp1     IN A 10.10.30.11=>    cp1     IN A 10.10.30.99'
expect fail "multi-line SOA edited without a bump" "$r" "HEAD 2, staged 2"

# 11. the same multi-line zone, bumped.
r="$(new_repo multiline-with-bump)"
edit "$r" '    @   IN SOA ns hostmaster ( 2 7200 3600 1209600 60 )=>    @   IN SOA ns hostmaster (
                  2         ; serial
                  7200      ; refresh
                  3600      ; retry
                  1209600   ; expire
                  60 )'
git -C "$r" commit -q -m "multi-line SOA, same serial"
edit "$r" '    cp1     IN A 10.10.30.11=>    cp1     IN A 10.10.30.99' \
  '                  2         ; serial=>                  3         ; serial'
expect pass "multi-line SOA edited with a bump" "$r" "serial 2 -> 3"

# 12. a second SOA in one key is refused, not guessed at.
r="$(new_repo two-soa-one-key)"
edit "$r" '    cp1     IN A 10.10.30.11=>    cp1     IN A 10.10.30.11
    other.  IN SOA ns hostmaster ( 5 7200 3600 1209600 60 )'
expect fail "two SOA records in one region are refused" "$r" "unknowable"

# 13. the word SOA inside TXT rdata is not a record type.
r="$(new_repo soa-in-txt)"
edit "$r" '    cp1     IN A 10.10.30.11=>    cp1     IN A 10.10.30.11
    note    IN TXT "this SOA word must not be parsed as a record"'
expect fail "a TXT mentioning SOA does not confuse the parser" "$r" "HEAD 2, staged 2"
r="$(new_repo soa-in-txt-bumped)"
edit "$r" '    cp1     IN A 10.10.30.11=>    cp1     IN A 10.10.30.11
    note    IN TXT "this SOA word must not be parsed as a record"' \
  '( 2 7200=>( 4 7200'
expect pass "a TXT mentioning SOA still resolves one serial" "$r" "serial 2 -> 4"

# 14. the real repo's own zone, edited without a bump, must fail. This is the
#     only case that exercises the file the incident happened in.
r="$TEMP_ROOT/real-zone"
mkdir -p "$r/infrastructure/cluster-dns"
git -C "$r" init -q
git -C "$r" config user.email test@example.invalid
git -C "$r" config user.name 'Zone Serial Test'
git -C "$r" config commit.gpgsign false
cp "$SCRIPT_DIR/../infrastructure/cluster-dns/configmap.yaml" "$r/infrastructure/cluster-dns/configmap.yaml"
git -C "$r" add -A
git -C "$r" commit -q -m "real cluster-dns configmap"
printf '    probe   IN A 10.10.30.99\n' >>"$r/infrastructure/cluster-dns/configmap.yaml"
git -C "$r" add -A
expect fail "the real cluster-dns zone, edited without a bump" "$r" \
  "infrastructure/cluster-dns/configmap.yaml [db.zone]"

# 15. prose and code that merely QUOTE an SOA are not zones. The guard's own
#     script, this suite and the hook registration all contain a literal SOA
#     record; the first repo-wide run of an earlier revision therefore failed
#     on all three, which would have made the hook unusable.
r="$(new_repo documents-a-zone)"
cp "$SCRIPT_DIR/check-zone-serial-bumped.sh" "$r/check-copy.sh"
cp "$SCRIPT_DIR/../.pre-commit-config.yaml" "$r/pre-commit-copy.yaml"
git -C "$r" add -A
expect pass "the guard's own script and hook registration are not zones" "$r" "nothing to check"

# 15b. The one place the guard does bite itself, on purpose: the heredoc above
#      is a real zone under a real `db.zone: |`, so editing THIS suite's
#      fixture records means bumping the fixture serial (and the expectations
#      that quote it). That is the guard working, not a false positive -- but
#      it is surprising enough to pin here rather than leave to be discovered.
r="$(new_repo suite-fixture-is-itself-a-zone)"
cp "$SCRIPT_DIR/test-zone-serial-bumped.sh" "$r/test-copy.sh"
git -C "$r" add -A
git -C "$r" commit -q -m "this suite, whose fixture heredoc is a zone"
python3 - "$r/test-copy.sh" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
old = "    cp1     IN A 10.10.30.11"
assert old in text
open(path, "w", encoding="utf-8").write(text.replace(old, "    cp1     IN A 10.10.30.77", 1))
PY
git -C "$r" add -A
expect fail "this suite's own fixture zone is guarded like any other" "$r" \
  "test-copy.sh [db.zone]" "HEAD 2, staged 2"

# 16. the same for an edited prose file whose SOA sits at column 0.
r="$(new_repo prose-at-column-zero)"
cat >"$r/notes.md" <<'EOF'
CoreDNS re-reads a zone only when the serial rises, e.g. in
@   IN SOA ns hostmaster ( 2 7200 3600 1209600 60 )
the 2 is the serial and 7200 is the refresh interval.
EOF
git -C "$r" add notes.md
git -C "$r" commit -q -m "notes"
printf 'One more sentence about zone serials.\n' >>"$r/notes.md"
git -C "$r" add notes.md
expect pass "prose quoting an SOA at column 0 is not a zone" "$r" "nothing to check"

if [ "$failures" -ne 0 ]; then
  printf 'FAIL: %d zone-serial control(s) did not behave as required\n' "$failures" >&2
  exit 1
fi
printf 'PASS: zone SOA serial guard controls\n'
