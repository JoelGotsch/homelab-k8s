#!/usr/bin/env bash
# Functional tests for the scripts mounted into the snapshot CronJobs.
# All OpenBao and SSH boundaries are fakes; no cluster/network is contacted.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_tmp="$(mktemp -d /tmp/openbao-snapshot-workload.XXXXXX)"
docker_volume=

cleanup() {
  if [[ -n "$docker_volume" ]]; then
    case "$docker_volume" in
      homelab-openbao-snapshot-permissions-*)
        docker volume rm -f "$docker_volume" >/dev/null 2>&1 || true
        ;;
    esac
  fi
  rm -rf -- "$test_tmp"
}
trap cleanup EXIT INT TERM
mkdir -p "$test_tmp/bin" "$test_tmp/hourly" "$test_tmp/work" \
  "$test_tmp/remote/openbao-snapshots"

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
SNAPSHOT_PUBLISH_MODE=0640 \
TERMINATION_LOG="$test_tmp/snapshot.term" \
  "$repo_root/platform/openbao/snapshot-auth.sh" >"$test_tmp/snapshot.log" 2>&1
[ -s "$test_tmp/work/bao-20260721T000000Z.snap" ] || fail 'snapshot was not created'
(cd "$test_tmp/work" && sha256sum -c bao-20260721T000000Z.snap.sha256 >/dev/null) \
  || fail 'snapshot checksum failed'
daily_mode_count="$(find "$test_tmp/work/bao-20260721T000000Z.snap" \
  "$test_tmp/work/bao-20260721T000000Z.snap.sha256" -prune -perm 0640 -print |
  wc -l | tr -d '[:space:]')"
[[ "$daily_mode_count" -eq 2 ]] \
  || fail 'daily artifacts were not published at exact mode 0640'
grep -Fq 'openbao_snapshot_ok' "$test_tmp/snapshot.term" \
  || fail 'snapshot success evidence missing'

# The hourly single-container path does not opt into cross-container sharing.
OPENBAO_JWT_FILE="$test_tmp/jwt" \
SNAPSHOT_OUTPUT="$test_tmp/hourly/bao-20260721T010000Z.snap" \
TERMINATION_LOG="$test_tmp/hourly.term" \
  "$repo_root/platform/openbao/snapshot-auth.sh" >"$test_tmp/hourly.log" 2>&1
hourly_mode_count="$(find "$test_tmp/hourly/bao-20260721T010000Z.snap" \
  "$test_tmp/hourly/bao-20260721T010000Z.snap.sha256" -prune -perm 0600 -print |
  wc -l | tr -d '[:space:]')"
[[ "$hourly_mode_count" -eq 2 ]] \
  || fail 'hourly artifacts did not remain at exact mode 0600'

if OPENBAO_JWT_FILE="$test_tmp/jwt" \
    SNAPSHOT_OUTPUT="$test_tmp/work/invalid-mode.snap" \
    SNAPSHOT_PUBLISH_MODE=0666 \
    TERMINATION_LOG="$test_tmp/invalid-mode.term" \
    "$repo_root/platform/openbao/snapshot-auth.sh" \
    >"$test_tmp/invalid-mode.log" 2>&1; then
  fail 'unsafe snapshot publish mode unexpectedly succeeded'
fi
grep -Fq 'SNAPSHOT_PUBLISH_MODE must be 0600 or 0640' "$test_tmp/invalid-mode.log" \
  || fail 'unsafe publish mode lacked an explicit diagnostic'
[ ! -e "$test_tmp/work/invalid-mode.snap" ] \
  || fail 'unsafe publish mode reached snapshot creation'

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
grep -Fq 'attempts=1' "$test_tmp/upload.term" \
  || fail 'a first-attempt success must report attempts=1'

# A permanently failing remote must exhaust the retry budget and still report the
# stage it died at. SNAPSHOT_UPLOAD_BACKOFFS is squashed to sub-second sleeps so
# this stays a pre-commit-speed test; production uses the script's own defaults
# (~16 min of backoff), which is the entire point of the 2026-09-06 fix — a
# ~25 min Storage Box outage must not cost a whole day's off-site snapshot.
if FAKE_UPLOAD_FAIL=1 SNAPSHOT_WORK_DIR="$test_tmp/work" \
    STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
    SNAPSHOT_UPLOAD_MAX_ATTEMPTS=3 \
    SNAPSHOT_UPLOAD_BACKOFFS='0 0' \
    TERMINATION_LOG="$test_tmp/upload-failure.term" \
    "$repo_root/platform/openbao/snapshot-upload.sh" \
    >"$test_tmp/upload-failure.log" 2>&1; then
  fail 'upload failure unexpectedly succeeded'
fi
grep -Fq 'stage=upload' "$test_tmp/upload-failure.term" \
  || fail 'upload failure stage evidence missing'
grep -Fq 'attempts=3' "$test_tmp/upload-failure.term" \
  || fail 'upload failure did not spend the whole retry budget'
[ "$(grep -c 'openbao_snapshot_upload_retry' "$test_tmp/upload-failure.log")" -eq 2 ] \
  || fail 'expected exactly two retry announcements before giving up'

# A remote that fails once and then recovers must succeed, not surface the blip.
# This is the actual 2026-09-06 shape: transient refusal, then a working box.
cat >"$test_tmp/bin/scp" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
# Same publish behaviour as the stub above, but the first invocation fails.
# The counter lives in a file because each retry is a fresh process.
attempts_file="${FAKE_SCP_ATTEMPTS:?}"
n=$(( $(cat "$attempts_file" 2>/dev/null || echo 0) + 1 ))
printf '%s\n' "$n" >"$attempts_file"
[ "$n" -gt 1 ] || exit 2
args=("$@")
src="${args[$((${#args[@]} - 2))]}"
dest="${args[$((${#args[@]} - 1))]}"
remote_path="${dest#*:}"
cp "$src" "$FAKE_REMOTE/$remote_path"
FAKE
chmod +x "$test_tmp/bin/scp"
rm -rf "$test_tmp/remote/openbao-snapshots"
if ! FAKE_SCP_ATTEMPTS="$test_tmp/scp-attempts" \
    SNAPSHOT_WORK_DIR="$test_tmp/work" \
    STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
    SNAPSHOT_UPLOAD_BACKOFFS='0 0' \
    TERMINATION_LOG="$test_tmp/upload-recovers.term" \
    "$repo_root/platform/openbao/snapshot-upload.sh" \
    >"$test_tmp/upload-recovers.log" 2>&1; then
  fail 'upload did not recover from a single transient remote failure'
fi
grep -Fq 'openbao_snapshot_upload_ok' "$test_tmp/upload-recovers.term" \
  || fail 'recovered upload lacks success evidence'
grep -Fq 'attempts=2' "$test_tmp/upload-recovers.term" \
  || fail 'recovered upload should report the attempt it succeeded on'
[ -s "$test_tmp/remote/openbao-snapshots/bao-20260721T000000Z.snap" ] \
  || fail 'recovered upload did not publish the remote snapshot'

# When Docker and the already-pinned uploader image are locally available, use a
# real Linux filesystem to prove the Kubernetes UID/GID handoff. No image is
# pulled: CI without this exact local image retains the exact-mode tests above.
snapshot_image='restic/restic:0.17.3@sha256:8f5a62b422a2cb1277ea0dd6e826fe1acf649e5b9f02d60e5268d5fd1976255a'
if command -v docker >/dev/null 2>&1 &&
    docker info >/dev/null 2>&1 &&
    docker image inspect "$snapshot_image" >/dev/null 2>&1; then
  docker_volume="homelab-openbao-snapshot-permissions-${PPID}-$$"
  docker volume create --label purpose=openbao-snapshot-permission-test \
    "$docker_volume" >/dev/null
  mkdir -p "$test_tmp/docker-bin"
  cat >"$test_tmp/docker-bin/bao" <<'FAKE'
#!/bin/sh
set -eu
case "${1:-} ${2:-} ${3:-}" in
  'write -field=token auth/kubernetes/login')
    printf '%s\n' 'b.DOCKERTESTTOKENMUSTNEVERAPPEAR'
    ;;
  'operator raft snapshot')
    [ "${4:-}" = save ] || exit 90
    printf '%s\n' 'cross-uid-encrypted-raft-snapshot' >"${5:?output missing}"
    ;;
  *) exit 90 ;;
esac
FAKE
  chmod 0555 "$test_tmp/docker-bin/bao"

  docker run --rm --pull never --user 0:0 \
    --volume "$docker_volume:/work" --entrypoint /bin/sh "$snapshot_image" \
    -c 'chown 100:1000 /work && chmod 0770 /work'
  docker run --rm --pull never --user 100:1000 \
    --env PATH=/test-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    --env OPENBAO_JWT_FILE=/jwt --env SNAPSHOT_OUTPUT=/work/bao-cross-uid.snap \
    --env SNAPSHOT_PUBLISH_MODE=0640 --env TERMINATION_LOG=/tmp/termination.log \
    --volume "$docker_volume:/work" \
    --volume "$repo_root/platform/openbao/snapshot-auth.sh:/app/snapshot-auth.sh:ro" \
    --volume "$test_tmp/docker-bin:/test-bin:ro" --volume "$test_tmp/jwt:/jwt:ro" \
    --entrypoint /bin/sh "$snapshot_image" -c /app/snapshot-auth.sh \
    >"$test_tmp/docker-producer.log" 2>&1

  metadata="$(docker run --rm --pull never --user 0:0 \
    --volume "$docker_volume:/work:ro" --entrypoint /bin/sh "$snapshot_image" \
    -c "stat -c '%u:%g %a %n' /work/bao-cross-uid.snap /work/bao-cross-uid.snap.sha256")"
  [[ "$metadata" == $'100:1000 640 /work/bao-cross-uid.snap\n100:1000 640 /work/bao-cross-uid.snap.sha256' ]] \
    || fail "cross-UID artifacts have wrong ownership/mode: $metadata"

  docker run --rm --pull never --user 1000:1000 \
    --volume "$docker_volume:/work:ro" --entrypoint /bin/sh "$snapshot_image" \
    -c 'test -r /work/bao-cross-uid.snap &&
        test -r /work/bao-cross-uid.snap.sha256 &&
        cd /work && sha256sum -c bao-cross-uid.snap.sha256 >/dev/null'
  if docker run --rm --pull never --user 1000:2000 \
      --volume "$docker_volume:/work:ro" --entrypoint /bin/sh "$snapshot_image" \
      -c 'cat /work/bao-cross-uid.snap >/dev/null' >/dev/null 2>&1; then
    fail 'snapshot was readable outside owner/shared group'
  fi
  if rg 'DOCKERTESTTOKENMUSTNEVERAPPEAR' "$test_tmp/docker-producer.log"; then
    fail 'Docker producer exposed its OpenBao token'
  fi
  docker volume rm -f "$docker_volume" >/dev/null
  docker_volume=
  printf '%s\n' 'PASS: UID 100/GID 1000 producer artifacts are readable by UID 1000/GID 1000 only.'
else
  printf '%s\n' 'SKIP: exact cross-UID Docker image unavailable; exact 0640/0600 mode tests passed.'
fi

if rg 'TESTTOKENMUSTNEVERAPPEAR|TEST-PRIVATE-KEY-MUST-NEVER-APPEAR' \
    "$test_tmp" -g '*.log' -g '*.term'; then
  fail 'credential reached workload logs or termination evidence'
fi

printf '%s\n' 'PASS: snapshot login, integrity, upload, failures, and log hygiene are enforced.'
