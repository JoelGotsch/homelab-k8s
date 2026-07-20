#!/usr/bin/env bash
# Functional tests for the scripts mounted into the snapshot CronJobs.
# All OpenBao and SSH boundaries are fakes; no cluster/network is contacted.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_tmp="$(mktemp -d /tmp/openbao-snapshot-workload.XXXXXX)"
trap 'rm -rf -- "$test_tmp"' EXIT INT TERM
mkdir -p "$test_tmp/bin" "$test_tmp/work" "$test_tmp/remote/openbao-snapshots"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

cat >"$test_tmp/bin/bao" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-} ${3:-}" in
  'write -field=token auth/kubernetes/login')
    [ "${FAKE_LOGIN_FAIL:-0}" -eq 0 ] || exit 2
    printf '%s\n' 'b.TESTTOKENMUSTNEVERAPPEAR00000'
    ;;
  'operator raft snapshot')
    [ "${4:-}" = save ] || exit 90
    [ "${FAKE_SNAPSHOT_FAIL:-0}" -eq 0 ] || exit 2
    printf '%s\n' 'encrypted-raft-snapshot-fixture' >"${5:?output missing}"
    ;;
  *) printf 'unexpected bao invocation: %s\n' "$*" >&2; exit 90 ;;
esac
FAKE

cat >"$test_tmp/bin/stat" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -c ] && [ "$2" = %s ] || exit 90
wc -c <"$3" | tr -d ' '
FAKE

cat >"$test_tmp/bin/scp" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[ "${FAKE_UPLOAD_FAIL:-0}" -eq 0 ] || exit 2
args=("$@")
src="${args[$((${#args[@]} - 2))]}"
dest="${args[$((${#args[@]} - 1))]}"
remote_path="${dest#*:}"
cp "$src" "$FAKE_REMOTE/$remote_path"
FAKE

cat >"$test_tmp/bin/ssh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    mkdir|mv|sha256sum) cmd=("${args[@]:$i}"); break ;;
  esac
done
case "${cmd[0]:-}" in
  mkdir) mkdir -p "$FAKE_REMOTE/${cmd[2]}" ;;
  mv) mv "$FAKE_REMOTE/${cmd[1]}" "$FAKE_REMOTE/${cmd[2]}" ;;
  sha256sum) sha256sum "$FAKE_REMOTE/${cmd[1]}" | sed "s#$FAKE_REMOTE/##" ;;
  *) printf 'unexpected ssh invocation\n' >&2; exit 90 ;;
esac
FAKE
chmod +x "$test_tmp/bin/"*

export PATH="$test_tmp/bin:$PATH"
export FAKE_REMOTE="$test_tmp/remote"
printf '%s\n' jwt-fixture >"$test_tmp/jwt"

OPENBAO_JWT_FILE="$test_tmp/jwt" \
SNAPSHOT_OUTPUT="$test_tmp/work/bao-20260721T000000Z.snap" \
TERMINATION_LOG="$test_tmp/snapshot.term" \
  "$repo_root/platform/openbao/snapshot-auth.sh" >"$test_tmp/snapshot.log" 2>&1
[ -s "$test_tmp/work/bao-20260721T000000Z.snap" ] || fail 'snapshot was not created'
(cd "$test_tmp/work" && sha256sum -c bao-20260721T000000Z.snap.sha256 >/dev/null) \
  || fail 'snapshot checksum failed'
grep -Fq 'openbao_snapshot_ok' "$test_tmp/snapshot.term" \
  || fail 'snapshot success evidence missing'

if FAKE_LOGIN_FAIL=1 OPENBAO_JWT_FILE="$test_tmp/jwt" \
    SNAPSHOT_OUTPUT="$test_tmp/work/login-failure.snap" \
    TERMINATION_LOG="$test_tmp/login-failure.term" \
    "$repo_root/platform/openbao/snapshot-auth.sh" \
    >"$test_tmp/login-failure.log" 2>&1; then
  fail 'login failure unexpectedly succeeded'
fi
grep -Fq 'stage=login' "$test_tmp/login-failure.term" \
  || fail 'login failure stage evidence missing'

printf '%s\n' 'pinned-host-key' >"$test_tmp/known_hosts"
export HSB_HOST=u609156.your-storagebox.de
export HSB_USER=u609156
export HSB_PORT=23
export SSH_KEY='TEST-PRIVATE-KEY-MUST-NEVER-APPEAR'
SNAPSHOT_WORK_DIR="$test_tmp/work" \
STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
TERMINATION_LOG="$test_tmp/upload.term" \
  "$repo_root/platform/openbao/snapshot-upload.sh" >"$test_tmp/upload.log" 2>&1
[ -s "$test_tmp/remote/openbao-snapshots/bao-20260721T000000Z.snap" ] \
  || fail 'remote snapshot was not published'
grep -Fq 'openbao_snapshot_upload_ok' "$test_tmp/upload.term" \
  || fail 'upload success evidence missing'

if FAKE_UPLOAD_FAIL=1 SNAPSHOT_WORK_DIR="$test_tmp/work" \
    STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
    TERMINATION_LOG="$test_tmp/upload-failure.term" \
    "$repo_root/platform/openbao/snapshot-upload.sh" \
    >"$test_tmp/upload-failure.log" 2>&1; then
  fail 'upload failure unexpectedly succeeded'
fi
grep -Fq 'stage=upload' "$test_tmp/upload-failure.term" \
  || fail 'upload failure stage evidence missing'

if rg 'TESTTOKENMUSTNEVERAPPEAR|TEST-PRIVATE-KEY-MUST-NEVER-APPEAR' \
    "$test_tmp" -g '*.log' -g '*.term'; then
  fail 'credential reached workload logs or termination evidence'
fi

printf '%s\n' 'PASS: snapshot login, integrity, upload, failures, and log hygiene are enforced.'
