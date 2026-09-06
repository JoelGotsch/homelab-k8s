#!/bin/sh
# Ensure the Hetzner Storage Box holds a locally verified Raft snapshot that is
# newer than SNAPSHOT_MAX_REMOTE_AGE_SECONDS, uploading one when it does not.
#
# This is a convergence script, not an upload script (ADR 0018 D6, revised
# 2026-09-06). It runs hourly and is a near-no-op in the ~23 h a day when the
# off-site copy is already fresh; a transient Storage Box outage therefore costs
# one hour instead of a whole day. Before 2026-09-06 this ran once daily and a
# ~25 min outage aged the only off-site copy of the vault to 37 h.
#
# THE LOAD-BEARING CONTRACT, and the reason to read the exit paths carefully:
# this script's success means "a remote snapshot newer than the threshold now
# exists". It must NEVER exit 0 because it could not find out. `kube_cronjob_
# status_last_successful_time` is what OpenBaoDailyRaftSnapshotStale watches, so
# an exit 0 on an indeterminate remote state would refresh that metric hourly
# and permanently silence the one alert guarding the off-site copy — green while
# checking nothing. Every path that cannot establish the invariant exits
# non-zero, which surfaces as OpenBaoRaftSnapshotJobFailed and stops the
# staleness clock from being reset.

set -eu
umask 077

work_dir="${SNAPSHOT_WORK_DIR:-/work}"
known_hosts="${STORAGEBOX_KNOWN_HOSTS:-/etc/openbao-snapshot-ssh/known_hosts}"
termination_log="${TERMINATION_LOG:-/dev/termination-log}"
# 23 h, not 24 h: the objective is an off-site copy no older than a day, so
# uploading at 23 h leaves an hour of margin before that objective is missed
# rather than racing it. Consequence to expect in the logs: with hourly checks
# the upload hour walks ~1 h earlier each day.
max_remote_age="${SNAPSHOT_MAX_REMOTE_AGE_SECONDS:-82800}"
remote_dir=openbao-snapshots
# A fixed-name marker naming the newest verified snapshot. The freshness check
# reads this instead of listing the directory, because the Storage Box has no
# shell — no pipes, no redirects (Hetzner: "There is no full shell") — so `ls`
# transfers the WHOLE listing and its cost grows with retention: ~14.7 KB at
# today's 98 objects, ~35 KB after a year. `cat` of this marker is a constant
# ~12 KB. Timestamp comes from the snapshot filename the marker contains, not
# from remote mtime: the filename is data we wrote and its format is pinned by
# this script, whereas `stat` output format and the remote clock are not.
remote_marker="$remote_dir/LATEST"
ssh_dir=/tmp/.ssh
key_file="$ssh_dir/id_ed25519"
# /tmp is a 16Mi memory-backed emptyDir in this pod; the marker is one line.
marker_file=/tmp/LATEST
stage=preflight
attempt=0
outcome=unknown
# Assigned by remote_snapshot_age()/converge(); declared here so `set -u`
# catches a path that reads them before they are set.
remote_age=''
remote_age_observed=''

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
remote_final="$remote_dir/$snapshot_name"
remote_partial="$remote_dir/.${snapshot_name}.partial"

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
  ssh $ssh_opts "$ssh_target" mkdir -p "$remote_dir" >/dev/null || return 1

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

  # Publish the marker LAST. It is the freshness check's only input, so it must
  # never name a snapshot that has not already been verified byte-for-byte on
  # the remote side. Written to a .partial and moved, for the same reason the
  # snapshot is: a marker truncated mid-write would be unparseable, and an
  # unparseable marker forces a re-upload on every subsequent run.
  stage=publish-marker
  printf '%s\n' "$snapshot_name" > "$marker_file" || return 1
  # shellcheck disable=SC2086 # option words are intentional and contain no secrets
  scp $scp_opts "$marker_file" "$ssh_target:${remote_marker}.partial" || return 1
  # shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
  ssh $ssh_opts "$ssh_target" mv "${remote_marker}.partial" "$remote_marker" \
    >/dev/null || return 1

  return 0
}

# Age in seconds of the newest verified remote snapshot, assigned to the global
# `remote_age`. Deliberately NOT printed to stdout and captured with `$( )`: a
# command substitution runs the function in a subshell, which would discard
# every `stage=` assignment below and leave the termination message reporting a
# stale stage — the one thing the operator reads first.
#
# Exit codes are the whole point of this function, so they are explicit:
#   0 + a number  -> the remote state is known
#   1             -> the remote state could NOT be determined; the caller must
#                    retry and ultimately fail. Never conflate with "fresh".
#   2             -> the remote is reachable but holds no usable marker, so an
#                    upload is required. This is the fail-SAFE direction: a
#                    missing or corrupt marker uploads rather than skipping.
#
# The reachability probe is separate from reading the marker, and that
# separation is what makes codes 1 and 2 distinguishable at all: only once we
# know the host answered can a failing `cat` be attributed to an absent marker
# rather than to an unreachable host. Relying on ssh's exit 255 to tell those
# apart would be guessing at how Hetzner's restricted shell reports a missing
# file.
#
# The probe targets `.` (the account's home), NOT the snapshot directory. Probing
# the directory conflates "cannot reach the host" with "the directory does not
# exist yet", which would make a first-ever run — or a run after the directory
# was moved — fail forever instead of creating it: `mkdir -p` lives in
# publish_snapshot, which that path never reaches. `.` always exists whenever the
# session is up, so it tests exactly connectivity and nothing else.
remote_snapshot_age() {
  remote_age=''
  stage=remote-state
  # shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
  ssh $ssh_opts "$ssh_target" stat . >/dev/null 2>&1 || return 1

  stage=read-marker
  marker_content=''
  # shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
  marker_content="$(ssh $ssh_opts "$ssh_target" cat "$remote_marker" 2>/dev/null)" || {
    printf 'no readable off-site marker at %s (absent directory or first run); an upload is required\n' \\
      "$remote_marker" >&2
    return 2
  }

  # Keep only the first line and strip stray whitespace/CR, then require the
  # exact filename shape this script writes. Anything else is treated as a
  # corrupt marker (upload) rather than parsed optimistically.
  marker_name="$(printf '%s' "$marker_content" | head -n 1 | tr -d ' \t\r')"
  case "$marker_name" in
    bao-????????T??????Z.snap) ;;
    *)
      printf 'off-site marker content is not a snapshot name; an upload is required\n' >&2
      return 2
      ;;
  esac

  # busybox date parses this explicitly and rejects malformed input non-zero
  # (verified in the pinned restic image, BusyBox 1.36.1). A bad parse must not
  # silently become epoch 0, which would read as "ancient" and be harmless, nor
  # as "now", which would not.
  marker_stamp="${marker_name#bao-}"
  marker_stamp="${marker_stamp%.snap}"
  marker_epoch="$(date -u -D '%Y%m%dT%H%M%SZ' -d "$marker_stamp" +%s 2>/dev/null)" || {
    printf 'off-site marker timestamp %s is unparseable; an upload is required\n' \
      "$marker_stamp" >&2
    return 2
  }

  now_epoch="$(date -u +%s)"
  # A marker dated in the future means our clock and the marker disagree; treat
  # it as not-fresh rather than trusting it, so the lane converges instead of
  # skipping uploads until the clock catches up.
  if [ "$marker_epoch" -gt "$now_epoch" ]; then
    printf 'off-site marker is dated in the future; an upload is required\n' >&2
    return 2
  fi
  remote_age=$(( now_epoch - marker_epoch ))
  return 0
}

# One convergence attempt: establish the invariant, or report that it could not
# be established. Sets `outcome` for the final message.
#
# The rc is captured through an explicit if/else rather than by testing `$?`
# after a bare call, so the branch below is correct whether or not the caller
# happens to suppress errexit.
converge() {
  if remote_snapshot_age; then
    age_rc=0
  else
    age_rc=$?
  fi

  case "$age_rc" in
    0)
      if [ "$remote_age" -lt "$max_remote_age" ]; then
        stage=converged
        outcome=already-fresh
        remote_age_observed="$remote_age"
        return 0
      fi
      printf 'off-site snapshot is %ss old (threshold %ss); uploading\n' \
        "$remote_age" "$max_remote_age" >&2
      ;;
    2) ;;  # reachable, no usable marker: fall through to the upload
    *)
      # Indeterminate remote state. Do NOT treat as converged — see the
      # contract note at the top of this file.
      return 1
      ;;
  esac

  publish_snapshot || return 1
  outcome=published
  remote_age_observed=0
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
  if converge; then
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
# Two distinct successes, deliberately distinguishable in the logs and in the
# termination message. `already-fresh` is the common case — roughly 23 of every
# 24 runs — and says the off-site copy was verified young enough to keep;
# `published` says this run uploaded and re-verified one. An operator seeing
# `already-fresh` for more than ~24 h of runs is looking at a bug, because the
# threshold guarantees a publish inside that window.
case "$outcome" in
  published)
    printf 'openbao_snapshot_converged outcome=published remote=%s bytes=%s sha256=%s attempts=%s\n' \
      "$remote_final" "$(stat -c %s "$snapshot")" "$local_digest" "$attempt" \
      | tee "$termination_log"
    ;;
  already-fresh)
    printf 'openbao_snapshot_converged outcome=already-fresh remote_age=%ss threshold=%ss attempts=%s\n' \
      "$remote_age_observed" "$max_remote_age" "$attempt" \
      | tee "$termination_log"
    ;;
  *)
    # Unreachable by construction: converge() sets `outcome` on both of its
    # success paths. Fail loudly rather than exiting 0 with an unknown outcome —
    # a success here resets the staleness clock, so it must mean something.
    printf 'converged with an unrecognised outcome %s\n' "$outcome" >&2
    exit 1
    ;;
esac
