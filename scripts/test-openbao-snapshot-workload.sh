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
# FAKE_UNREACHABLE=1 simulates the 2026-09-06 outage. 255 is what real ssh
# returns for its own failures, and the convergence path must treat that as
# "remote state unknown" rather than as any statement about freshness.
[[ "${FAKE_UNREACHABLE:-0}" == 1 ]] && exit 255
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    mkdir|mv|sha256sum|stat|cat|ls|rm) cmd=("${args[@]:$i}"); break ;;
  esac
done
case "${cmd[0]:-}" in
  mkdir) mkdir -p "$FAKE_REMOTE/${cmd[2]}" ;;
  mv) mv "$FAKE_REMOTE/${cmd[1]}" "$FAKE_REMOTE/${cmd[2]}" ;;
  sha256sum) sha256sum "$FAKE_REMOTE/${cmd[1]}" | sed "s#$FAKE_REMOTE/##" ;;
  # The Storage Box restricted shell offers both. The uploader uses `stat` on the
  # directory purely as a reachability probe, and `cat` to read the marker.
  # `.` is the connectivity probe and must answer whenever reachable, even
  # before the snapshot directory exists.
  stat) [[ "${cmd[1]}" == "." || -e "$FAKE_REMOTE/${cmd[1]}" ]] || exit 1 ;;
  cat) [[ -f "$FAKE_REMOTE/${cmd[1]}" ]] || exit 1; cat "$FAKE_REMOTE/${cmd[1]}" ;;
  # The prune lane's two verbs. `ls` of a missing directory fails as it does on
  # the real Storage Box, so a failed listing stays distinguishable from an empty
  # one. `rm` is strict: a removal that does not happen must surface.
  ls) ls "$FAKE_REMOTE/${cmd[1]}" ;;
  rm) rm "$FAKE_REMOTE/${cmd[1]}" ;;
  *) printf 'unexpected ssh invocation\n' >&2; exit 90 ;;
esac
FAKE

# The uploader dates the off-site marker with busybox's explicit-format parser
# (`date -D`), which the pinned restic image provides and macOS BSD date does
# not. Without a shim that parse fails on an operator laptop, the script falls
# back to "marker unusable -> upload", and every freshness branch below silently
# never executes: a test that passes while checking nothing. Shim exactly the two
# forms these scripts use, and only when the host date cannot do it.
if ! date -u -D '%Y%m%dT%H%M%SZ' -d 20260721T000000Z +%s >/dev/null 2>&1; then
  command -v python3 >/dev/null 2>&1 \
    || fail 'need a date(1) supporting -D, or python3, to test the freshness logic'
  cat >"$test_tmp/bin/date" <<'FAKEDATE'
#!/usr/bin/env python3
# Minimal busybox-date shim: handles `-u -D FMT -d STAMP +%s` and `-u +%s`,
# and delegates anything else to the real /bin/date.
import datetime, os, sys
a = sys.argv[1:]
if "-D" in a and "-d" in a and "+%s" in a:
    fmt = a[a.index("-D") + 1]
    stamp = a[a.index("-d") + 1]
    try:
        dt = datetime.datetime.strptime(stamp, fmt).replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        sys.exit(1)
    print(int(dt.timestamp()))
elif a == ["-u", "+%s"]:
    print(int(datetime.datetime.now(datetime.timezone.utc).timestamp()))
else:
    os.execv("/bin/date", ["/bin/date"] + a)
FAKEDATE
  chmod +x "$test_tmp/bin/date"
fi
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
grep -Fq 'openbao_snapshot_converged outcome=published' "$test_tmp/upload.term" \
  || fail 'upload success evidence missing'
# The marker is the freshness check's only input, so a publish that does not
# leave one behind would make every subsequent run re-upload.
[ -s "$test_tmp/remote/openbao-snapshots/LATEST" ] \
  || fail 'publish did not leave an off-site LATEST marker'
grep -Fqx 'bao-20260721T000000Z.snap' "$test_tmp/remote/openbao-snapshots/LATEST" \
  || fail 'off-site marker does not name the snapshot just published'
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
grep -Fq 'openbao_snapshot_converged outcome=published' "$test_tmp/upload-recovers.term" \
  || fail 'recovered upload lacks success evidence'
grep -Fq 'attempts=2' "$test_tmp/upload-recovers.term" \
  || fail 'recovered upload should report the attempt it succeeded on'
[ -s "$test_tmp/remote/openbao-snapshots/bao-20260721T000000Z.snap" ] \
  || fail 'recovered upload did not publish the remote snapshot'

# ── Convergence contract (2026-09-06) ─────────────────────────────────────────
# The lane runs hourly and is a no-op when the off-site copy is already young
# enough. These three cases are the whole reason that is safe.
#
# Restore the plain scp stub first; the transient-failure one above is stateful.
cat >"$test_tmp/bin/scp" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${FAKE_UNREACHABLE:-0}" == 1 ]] && exit 255
args=("$@")
src="${args[$((${#args[@]} - 2))]}"
dest="${args[$((${#args[@]} - 1))]}"
remote_path="${dest#*:}"
mkdir -p "$FAKE_REMOTE/$(dirname "$remote_path")"
cp "$src" "$FAKE_REMOTE/$remote_path"
FAKE
chmod +x "$test_tmp/bin/scp"

# (1) A marker young enough must converge WITHOUT uploading. Proven by removing
#     the remote snapshot and asserting the run does not put it back.
mkdir -p "$test_tmp/remote/openbao-snapshots"
rm -f "$test_tmp/remote/openbao-snapshots/bao-20260721T000000Z.snap"
fresh_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
printf 'bao-%s.snap\n' "$fresh_stamp" >"$test_tmp/remote/openbao-snapshots/LATEST"
if ! SNAPSHOT_WORK_DIR="$test_tmp/work" \
    STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
    SNAPSHOT_UPLOAD_BACKOFFS='0 0' \
    TERMINATION_LOG="$test_tmp/upload-fresh.term" \
    "$repo_root/platform/openbao/snapshot-upload.sh" \
    >"$test_tmp/upload-fresh.log" 2>&1; then
  fail 'a fresh off-site copy should converge successfully, not fail'
fi
grep -Fq 'openbao_snapshot_converged outcome=already-fresh' "$test_tmp/upload-fresh.term" \
  || fail 'fresh off-site copy did not report the already-fresh outcome'
[ ! -e "$test_tmp/remote/openbao-snapshots/bao-20260721T000000Z.snap" ] \
  || fail 'converged run uploaded anyway; the freshness gate is not working'

# (2) A marker older than the threshold must upload.
rm -f "$test_tmp/remote/openbao-snapshots/bao-20260721T000000Z.snap"
printf 'bao-20200101T000000Z.snap\n' >"$test_tmp/remote/openbao-snapshots/LATEST"
if ! SNAPSHOT_WORK_DIR="$test_tmp/work" \
    STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
    SNAPSHOT_UPLOAD_BACKOFFS='0 0' \
    TERMINATION_LOG="$test_tmp/upload-stale.term" \
    "$repo_root/platform/openbao/snapshot-upload.sh" \
    >"$test_tmp/upload-stale.log" 2>&1; then
  fail 'a stale off-site copy should have been refreshed'
fi
grep -Fq 'openbao_snapshot_converged outcome=published' "$test_tmp/upload-stale.term" \
  || fail 'stale off-site copy was not republished'
[ -s "$test_tmp/remote/openbao-snapshots/bao-20260721T000000Z.snap" ] \
  || fail 'stale off-site copy did not result in an upload'

# (3) THE LOAD-BEARING CASE. When the remote cannot be reached the run must FAIL,
#     even though a fresh marker is sitting there — because it cannot read it. An
#     exit 0 here would refresh kube_cronjob_status_last_successful_time every
#     hour and permanently silence OpenBaoDailyRaftSnapshotStale, which is the
#     only alert guarding the off-site copy. This is the hourly lane's equivalent
#     of the 2026-09-06 bug: reporting health without having checked.
printf 'bao-%s.snap\n' "$fresh_stamp" >"$test_tmp/remote/openbao-snapshots/LATEST"
if FAKE_UNREACHABLE=1 SNAPSHOT_WORK_DIR="$test_tmp/work" \
    STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
    SNAPSHOT_UPLOAD_MAX_ATTEMPTS=2 \
    SNAPSHOT_UPLOAD_BACKOFFS='0 0' \
    TERMINATION_LOG="$test_tmp/upload-unreachable.term" \
    "$repo_root/platform/openbao/snapshot-upload.sh" \
    >"$test_tmp/upload-unreachable.log" 2>&1; then
  fail 'an undeterminable remote state must not report success'
fi
grep -Fq 'stage=remote-state' "$test_tmp/upload-unreachable.term" \
  || fail 'unreachable remote did not report the remote-state stage'
if grep -Fq 'openbao_snapshot_converged' "$test_tmp/upload-unreachable.term"; then
  fail 'unreachable remote emitted a convergence success message'
fi

# ── Off-site retention ─────────────────────────────────────────────────────
# snapshot-prune.sh is the only script here that deletes data, so its guards are
# tested rather than reviewed. A separate fixture directory keeps these cases
# from touching the convergence fixtures above.
prune_remote="$test_tmp/remote/prune-fixture"
mkdir -p "$prune_remote"
# 40 consecutive daily snapshots ending 2026-09-06, each with a checksum
# sidecar — the real shape of the directory on that date (49 snapshots, unbroken
# daily chain since 2026-07-21, nothing ever deleted).
for offset in $(seq 0 39); do
  day="$(python3 -c 'import datetime,sys; print((datetime.date(2026,9,6) - datetime.timedelta(days=int(sys.argv[1]))).strftime("%Y%m%d"))' "$offset")"
  printf 'snapshot-fixture\n' >"$prune_remote/bao-${day}T031500Z.snap"
  printf 'deadbeef  bao-%sT031500Z.snap\n' "$day" \
    >"$prune_remote/bao-${day}T031500Z.snap.sha256"
done
printf 'bao-20260906T031500Z.snap\n' >"$prune_remote/LATEST"
before_prune="$(find "$prune_remote" -name 'bao-*.snap' | wc -l | tr -d ' ')"
[ "$before_prune" -eq 40 ] || fail 'prune fixture was not built'

# Report-only is the shipped default, so it is the first thing asserted: an
# unarmed run must produce a full plan and delete nothing.
SNAPSHOT_REMOTE_DIR=prune-fixture \
STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
SNAPSHOT_PRUNE_APPLY=false \
TERMINATION_LOG="$test_tmp/prune-report.term" \
  "$repo_root/platform/openbao/snapshot-prune.sh" \
  >"$test_tmp/prune-report.log" 2>&1 \
  || fail 'report-only prune failed'
grep -Fq 'openbao_snapshot_prune_ok mode=report-only' "$test_tmp/prune-report.term" \
  || fail 'report-only prune lacks its evidence line'
grep -Fq 'openbao_snapshot_prune_plan total=40' "$test_tmp/prune-report.log" \
  || fail 'report-only prune did not print a plan over the whole listing'
[ "$(find "$prune_remote" -name 'bao-*.snap' | wc -l | tr -d ' ')" -eq "$before_prune" ] \
  || fail 'report-only prune deleted something'

# Armed. 40 consecutive dailies under 14d/8w/12m/3y keep the 14 newest days plus
# one per earlier week and month, so the outcome is checked as properties rather
# than as one brittle number: the newest survives, the daily floor is met, every
# survivor still has its sidecar, and something was actually removed.
SNAPSHOT_REMOTE_DIR=prune-fixture \
STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
SNAPSHOT_PRUNE_APPLY=true \
TERMINATION_LOG="$test_tmp/prune-apply.term" \
  "$repo_root/platform/openbao/snapshot-prune.sh" \
  >"$test_tmp/prune-apply.log" 2>&1 \
  || fail 'armed prune failed'
grep -Fq 'openbao_snapshot_prune_ok mode=apply' "$test_tmp/prune-apply.term" \
  || fail 'armed prune lacks its evidence line'
[ -e "$prune_remote/bao-20260906T031500Z.snap" ] \
  || fail 'prune deleted the newest off-site snapshot'
for kept_snapshot in "$prune_remote"/bao-*.snap; do
  [ -e "${kept_snapshot}.sha256" ] \
    || fail "prune left $(basename "$kept_snapshot") without its checksum sidecar"
done
for orphan_sidecar in "$prune_remote"/bao-*.snap.sha256; do
  [ -e "${orphan_sidecar%.sha256}" ] \
    || fail "prune left $(basename "$orphan_sidecar") without its snapshot"
done
after_prune="$(find "$prune_remote" -name 'bao-*.snap' | wc -l | tr -d ' ')"
[ "$after_prune" -lt "$before_prune" ] || fail 'armed prune removed nothing'
[ "$after_prune" -ge 14 ] \
  || fail "armed prune kept only $after_prune snapshots, below the 14-daily floor"

# Re-running immediately must be a no-op: the previous run already converged the
# directory onto the policy. A prune that keeps finding work to do is deleting
# something it should have kept.
SNAPSHOT_REMOTE_DIR=prune-fixture \
STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
SNAPSHOT_PRUNE_APPLY=true \
TERMINATION_LOG="$test_tmp/prune-again.term" \
  "$repo_root/platform/openbao/snapshot-prune.sh" \
  >"$test_tmp/prune-again.log" 2>&1 \
  || fail 'second prune run failed'
grep -Fq 'removed=0' "$test_tmp/prune-again.term" \
  || fail 'prune is not idempotent; a second run removed more'

# A listing shorter than the min-plausible floor must abort untouched. This is
# the guard against acting on a truncated or lying remote read — the difference
# between "retention converged" and "the backups are gone".
short_remote="$test_tmp/remote/prune-short"
mkdir -p "$short_remote"
printf 'snapshot-fixture\n' >"$short_remote/bao-20260906T031500Z.snap"
if SNAPSHOT_REMOTE_DIR=prune-short \
    STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
    SNAPSHOT_PRUNE_APPLY=true \
    TERMINATION_LOG="$test_tmp/prune-short.term" \
    "$repo_root/platform/openbao/snapshot-prune.sh" \
    >"$test_tmp/prune-short.log" 2>&1; then
  fail 'prune acted on an implausibly short listing'
fi
[ -e "$short_remote/bao-20260906T031500Z.snap" ] \
  || fail 'prune deleted from a listing it should have refused outright'
grep -Fq 'refusing to prune a listing this short' "$test_tmp/prune-short.log" \
  || fail 'short-listing refusal lacks an explicit diagnostic'

# Names outside the snapshot pattern are not prune candidates at all. The
# directory legitimately holds the LATEST marker and one .sha256 per snapshot,
# and the plan above reported total=40 over a directory of 81 objects, which is
# that filter working. A name that PASSES the pattern but is not a real date is
# the dangerous case — it reaches the bucketing arithmetic — and it must abort
# the whole run rather than be skipped: a snapshot we cannot date is one we must
# not reason about deleting.
bad_remote="$test_tmp/remote/prune-bad"
mkdir -p "$bad_remote"
for offset in $(seq 0 19); do
  day="$(python3 -c 'import datetime,sys; print((datetime.date(2026,9,6) - datetime.timedelta(days=int(sys.argv[1]))).strftime("%Y%m%d"))' "$offset")"
  printf 'snapshot-fixture\n' >"$bad_remote/bao-${day}T031500Z.snap"
  printf 'deadbeef  bao-%sT031500Z.snap\n' "$day" >"$bad_remote/bao-${day}T031500Z.snap.sha256"
done
# Month 13, day 52: eight digits, so it clears the pattern, and rejected by
# busybox `date -D`, which is exactly the seam being tested.
printf 'snapshot-fixture\n' >"$bad_remote/bao-20261352T031500Z.snap"
# Retention squashed to 1/1/1/1 so that a run which did NOT abort would delete
# almost everything; the assertion below would then be unmissable.
if SNAPSHOT_REMOTE_DIR=prune-bad \
    STORAGEBOX_KNOWN_HOSTS="$test_tmp/known_hosts" \
    SNAPSHOT_PRUNE_APPLY=true \
    SNAPSHOT_KEEP_DAILY=1 SNAPSHOT_KEEP_WEEKLY=1 \
    SNAPSHOT_KEEP_MONTHLY=1 SNAPSHOT_KEEP_YEARLY=1 \
    TERMINATION_LOG="$test_tmp/prune-bad.term" \
    "$repo_root/platform/openbao/snapshot-prune.sh" \
    >"$test_tmp/prune-bad.log" 2>&1; then
  fail 'prune completed over a listing containing an undatable snapshot name'
fi
[ "$(find "$bad_remote" -name 'bao-*.snap' | wc -l | tr -d ' ')" -eq 21 ] \
  || fail 'prune deleted something before aborting on an undatable name'
grep -Fq 'cannot parse timestamp in bao-20261352T031500Z.snap' "$test_tmp/prune-bad.log" \
  || fail 'undatable-name abort lacks an explicit diagnostic naming the file'

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

printf '%s\n' 'PASS: snapshot login, integrity, convergence, retention, failures, and log hygiene are enforced.'
