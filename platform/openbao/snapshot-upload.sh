#!/bin/sh
# Upload one locally verified Raft snapshot to the exact Hetzner Storage Box,
# atomically publish it, and compare the remote SHA-256 to the local digest.

set -eu
umask 077

work_dir="${SNAPSHOT_WORK_DIR:-/work}"
known_hosts="${STORAGEBOX_KNOWN_HOSTS:-/etc/openbao-snapshot-ssh/known_hosts}"
termination_log="${TERMINATION_LOG:-/dev/termination-log}"
ssh_dir=/tmp/.ssh
key_file="$ssh_dir/id_ed25519"
stage=preflight
attempt=0

on_exit() {
  rc=$?
  rm -f "$key_file"
  if [ "$rc" -ne 0 ]; then
    printf 'openbao_snapshot_upload_failed stage=%s rc=%s attempts=%s\n' \
      "$stage" "$rc" "$attempt" > "$termination_log"
  fi
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

: "${HSB_HOST:?HSB_HOST is required}"
: "${HSB_USER:?HSB_USER is required}"
: "${HSB_PORT:?HSB_PORT is required}"
: "${SSH_KEY:?SSH_KEY is required}"
[ "$HSB_PORT" = 23 ] || {
  printf 'HSB_PORT must be 23 so remote checksum verification is available\n' >&2
  exit 1
}
[ -s "$known_hosts" ] || { printf 'pinned known_hosts is empty\n' >&2; exit 1; }

set -- "$work_dir"/bao-*.snap
[ "$#" -eq 1 ] && [ -s "$1" ] || {
  printf 'expected exactly one non-empty Raft snapshot in %s\n' "$work_dir" >&2
  exit 1
}
snapshot="$1"
checksum="${snapshot}.sha256"
[ -s "$checksum" ] || { printf 'snapshot checksum sidecar is missing\n' >&2; exit 1; }
(
  cd "$work_dir"
  sha256sum -c "$(basename "$checksum")" >/dev/null
)
local_digest="$(cut -d ' ' -f 1 "$checksum")"

mkdir -p "$ssh_dir"
printf '%s\n' "$SSH_KEY" >"$key_file"
chmod 0600 "$key_file"
cp "$known_hosts" "$ssh_dir/known_hosts"
chmod 0600 "$ssh_dir/known_hosts"

ssh_target="${HSB_USER}@${HSB_HOST}"
# ConnectTimeout bounds a black-holed SYN: the 2026-09-06 run spent 134s in the
# kernel's default connect timeout before reporting "Operation timed out", which
# made the retry budget unpredictable. ServerAliveInterval/CountMax bound the
# other observed shape — a session that is established and then silently dies
# mid-transfer (the concurrent restic lane reported "client_loop: send
# disconnect: Broken pipe" in the same minute). Without it a half-open session
# hangs until activeDeadlineSeconds kills the pod, burning the whole budget on
# one attempt.
common_opts="-o UserKnownHostsFile=$ssh_dir/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
ssh_opts="-i $key_file $common_opts -p $HSB_PORT"
scp_opts="-q -i $key_file $common_opts -P $HSB_PORT"
snapshot_name="$(basename "$snapshot")"
remote_final="openbao-snapshots/$snapshot_name"
remote_partial="openbao-snapshots/.${snapshot_name}.partial"

# One complete publish attempt. Safe to re-run from the top after a failure at
# any point, which is what makes the retry loop below legitimate:
#   - `mkdir -p`            idempotent by definition.
#   - scp -> .partial       overwrites, so a truncated leftover is replaced.
#   - mv .partial -> final  the preceding scp always recreates .partial, so the
#                           mv never runs sourceless — including the awkward case
#                           where a previous attempt completed the mv and then
#                           died before verifying.
#   - sha256sum             read-only.
#   - scp -> final.sha256   overwrites; published only after the object verified.
# Each step is guarded with `|| return 1` rather than relying on `set -e`:
# errexit is suppressed inside a function called from an `if` condition, so a
# bare failing command here would fall through to the next line.
publish_snapshot() {
  stage=remote-directory
  # shellcheck disable=SC2086 # option words are intentional and contain no secrets
  ssh $ssh_opts "$ssh_target" mkdir -p openbao-snapshots >/dev/null || return 1

  stage=upload
  # shellcheck disable=SC2086 # option words are intentional and contain no secrets
  scp $scp_opts "$snapshot" "$ssh_target:$remote_partial" || return 1
  # shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
  ssh $ssh_opts "$ssh_target" mv "$remote_partial" "$remote_final" >/dev/null || return 1

  stage=remote-integrity
  # Hetzner documents sha256sum as an allowed direct command on Storage Box port 23.
  # shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
  remote_result="$(ssh $ssh_opts "$ssh_target" sha256sum "$remote_final")" || return 1
  remote_digest="${remote_result%% *}"
  # A mismatch is retried rather than fatal: the likeliest cause is a transfer
  # truncated by the same network fault we are retrying, and the next attempt
  # re-uploads from the local snapshot, which was verified before we connected.
  # A genuinely corrupt source therefore exhausts the budget and fails loudly.
  [ "$remote_digest" = "$local_digest" ] || {
    printf 'remote checksum does not match local snapshot (attempt %s)\n' "$attempt" >&2
    return 1
  }
  # shellcheck disable=SC2086 # option words are intentional and contain no secrets
  scp $scp_opts "$checksum" "$ssh_target:${remote_final}.sha256" || return 1

  return 0
}

# Retry across an outage instead of across four minutes.
#
# On 2026-09-06 the Storage Box was unreachable on tcp/23 from ~03:05 until
# ~03:30. This lane lost the entire day to it: `backoffLimit: 2` spent all three
# pod attempts between 03:05:11 and 03:09:20 — 4m09s, every one of them inside
# the outage — and the CronJob does not run again for 24 h, so the off-site
# recovery point aged to 37 h before the staleness alert fired. The restic lane
# hit the *same* outage in the same minute and survived only because its retry
# happened to land at 03:30.
#
# Six attempts with these backoffs span ~16 min of waiting; with ConnectTimeout
# bounding each failed attempt at ~30s the worst case is ~21 min, inside
# activeDeadlineSeconds (1800s) with headroom for a slow-but-working upload.
#
# Both are overridable so the offline test in
# scripts/test-openbao-snapshot-workload.sh can exercise the give-up path in
# under a second. Nothing in the cluster sets them — the CronJob relies on these
# defaults, so a change here changes production behaviour.
max_attempts="${SNAPSHOT_UPLOAD_MAX_ATTEMPTS:-6}"
backoffs="${SNAPSHOT_UPLOAD_BACKOFFS:-60 120 180 300 300}"

while :; do
  attempt=$((attempt + 1))
  if publish_snapshot; then
    break
  fi
  if [ "$attempt" -ge "$max_attempts" ]; then
    printf 'giving up after %s attempts; last failing stage=%s\n' \
      "$attempt" "$stage" >&2
    exit 1
  fi
  # shellcheck disable=SC2086 # splitting $backoffs into one line per value is the point
  delay="$(printf '%s\n' $backoffs | sed -n "${attempt}p")"
  # Jitter so a retry never re-lands in lockstep with another client's retry on
  # the same Storage Box (Hetzner allows 10 simultaneous connections per
  # account). /dev/urandom is present in the restic image; fall back to no
  # jitter rather than failing the upload over it. Skipped entirely for a zero
  # backoff, so an injected `SNAPSHOT_UPLOAD_BACKOFFS='0 0'` really means "do
  # not sleep" and the offline test stays fast.
  if [ "$delay" -gt 0 ]; then
    jitter="$(od -An -N1 -tu1 /dev/urandom 2>/dev/null | tr -d ' \n' || true)"
    [ -n "$jitter" ] || jitter=0
    delay=$((delay + jitter % 30))
  fi
  printf 'openbao_snapshot_upload_retry attempt=%s stage=%s sleeping=%ss\n' \
    "$attempt" "$stage" "$delay" >&2
  sleep "$delay"
done

stage=complete
printf 'openbao_snapshot_upload_ok remote=%s bytes=%s sha256=%s attempts=%s\n' \
  "$remote_final" "$(stat -c %s "$snapshot")" "$local_digest" "$attempt" \
  | tee "$termination_log"
