#!/bin/sh
# Apply the `secret`-class GFS retention policy to the off-site OpenBao Raft
# snapshot directory on the Hetzner Storage Box.
#
# Why this exists (2026-09-06): backup-and-dr.md has specified 14 daily / 8
# weekly / 12 monthly / 3 yearly for `secret`-class data for a long time, but the
# mechanism it names is `restic forget --keep-*`, and this lane has no restic
# repository — it is plain scp. So the policy was documented and unenforceable,
# and nothing had ever deleted anything: 49 snapshots and 49 checksum sidecars
# had accumulated in an unbroken daily chain since 2026-07-21, already 3.4x the
# stated daily retention.
#
# DEFAULTS TO REPORT-ONLY. Deleting backups is the one operation here that cannot
# be undone, so per this repo's infra-apply discipline ("minimal blast radius for
# any first real apply") the first deployment prints exactly what it would remove
# and removes nothing. Set SNAPSHOT_PRUNE_APPLY=true to arm it.
#
# Runs as its own CronJob rather than as a second container in the upload pod, so
# that a prune fault can never fail a run that successfully published a snapshot.

set -eu
umask 077

known_hosts="${STORAGEBOX_KNOWN_HOSTS:-/etc/openbao-snapshot-ssh/known_hosts}"
termination_log="${TERMINATION_LOG:-/dev/termination-log}"
remote_dir="${SNAPSHOT_REMOTE_DIR:-openbao-snapshots}"
apply="${SNAPSHOT_PRUNE_APPLY:-false}"

# Retention, matching backup-and-dr.md's `secret` row. Overridable so the offline
# test can drive small numbers, but the cluster sets them explicitly.
keep_daily="${SNAPSHOT_KEEP_DAILY:-14}"
keep_weekly="${SNAPSHOT_KEEP_WEEKLY:-8}"
keep_monthly="${SNAPSHOT_KEEP_MONTHLY:-12}"
keep_yearly="${SNAPSHOT_KEEP_YEARLY:-3}"

# A listing shorter than this is treated as a failed/truncated read rather than
# as "almost everything is gone, delete the rest". There is no legitimate path
# from 49 snapshots to a handful, so a small listing means the remote or the
# transport lied, and the only safe response is to abort untouched.
min_plausible="${SNAPSHOT_PRUNE_MIN_PLAUSIBLE:-10}"

ssh_dir=/tmp/.ssh
key_file="$ssh_dir/id_ed25519"
work=/tmp/prune
stage=preflight
deleted=0
kept=0

on_exit() {
  rc=$?
  rm -f "$key_file"
  if [ "$rc" -ne 0 ]; then
    printf 'openbao_snapshot_prune_failed stage=%s rc=%s\n' "$stage" "$rc" \
      > "$termination_log"
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
[ -s "$known_hosts" ] || { printf 'pinned known_hosts is empty\n' >&2; exit 1; }
case "$apply" in
  true|false) ;;
  *) printf 'SNAPSHOT_PRUNE_APPLY must be exactly true or false, got %s\n' \
       "$apply" >&2; exit 1 ;;
esac

mkdir -p "$ssh_dir" "$work"
printf '%s\n' "$SSH_KEY" >"$key_file"
chmod 0600 "$key_file"
cp "$known_hosts" "$ssh_dir/known_hosts"
chmod 0600 "$ssh_dir/known_hosts"

ssh_target="${HSB_USER}@${HSB_HOST}"
ssh_opts="-i $key_file -o UserKnownHostsFile=$ssh_dir/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=30 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -p $HSB_PORT"

# The one place a full listing is unavoidable: GFS selection needs every
# timestamp. The Storage Box has no shell, so there is no remote `ls | sort |
# tail` to push this work into — it comes back whole and is bucketed here.
stage=list
# shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
ssh $ssh_opts "$ssh_target" ls "$remote_dir" > "$work/listing" || {
  printf 'could not list %s; aborting without deleting anything\n' "$remote_dir" >&2
  exit 1
}

stage=parse
# Keep only well-formed snapshot names. Anything else in the directory (the
# LATEST marker, checksum sidecars, a leftover .partial) is not a prune
# candidate and must not be matched by accident.
grep -E '^bao-[0-9]{8}T[0-9]{6}Z\.snap$' "$work/listing" | sort > "$work/snapshots" || true
total="$(wc -l < "$work/snapshots" | tr -d ' ')"

[ "$total" -gt 0 ] || {
  printf 'no parseable snapshots in %s; aborting rather than acting on an empty parse\n' \
    "$remote_dir" >&2
  exit 1
}
[ "$total" -ge "$min_plausible" ] || {
  printf 'only %s snapshots listed (min plausible %s); refusing to prune a listing this short\n' \
    "$total" "$min_plausible" >&2
  exit 1
}

# Emit "name day week month year" per snapshot. Day/month/year come straight out
# of the fixed-width timestamp; the week bucket needs real arithmetic, so it is
# computed as a 7-day epoch bucket via busybox `date -D`. Deliberately not ISO
# calendar weeks: the goal is "keep 8 copies about a week apart", and floor
# division over epoch seconds has no locale, year-boundary or %V portability
# edge cases. A timestamp busybox cannot parse aborts the run — a snapshot we
# cannot date is one we must not reason about deleting.
stage=bucket
: > "$work/buckets"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  stamp="${name#bao-}"
  stamp="${stamp%.snap}"
  epoch="$(date -u -D '%Y%m%dT%H%M%SZ' -d "$stamp" +%s 2>/dev/null)" || {
    printf 'cannot parse timestamp in %s; aborting without deleting anything\n' \
      "$name" >&2
    exit 1
  }
  printf '%s %s %s %s %s\n' \
    "$name" \
    "$(printf '%s' "$stamp" | cut -c1-8)" \
    "$(( epoch / 604800 ))" \
    "$(printf '%s' "$stamp" | cut -c1-6)" \
    "$(printf '%s' "$stamp" | cut -c1-4)" \
    >> "$work/buckets"
done < "$work/snapshots"

# GFS selection, newest first: within each class, keep the newest snapshot of
# each distinct period until that class's quota is met. The union is the keep
# set. This is the same shape as `restic forget --keep-daily/weekly/monthly/
# yearly`, which is what backup-and-dr.md's numbers were written against.
stage=select
sort -r "$work/buckets" | awk \
  -v kd="$keep_daily" -v kw="$keep_weekly" -v km="$keep_monthly" -v ky="$keep_yearly" '
  {
    name = $1
    # First record wins per period because input is sorted newest-first.
    if (nd < kd && !(seen_d[$2]++)) { keep[name] = 1; nd++; why[name] = why[name] "daily " }
    if (nw < kw && !(seen_w[$3]++)) { keep[name] = 1; nw++; why[name] = why[name] "weekly " }
    if (nm < km && !(seen_m[$4]++)) { keep[name] = 1; nm++; why[name] = why[name] "monthly " }
    if (ny < ky && !(seen_y[$5]++)) { keep[name] = 1; ny++; why[name] = why[name] "yearly " }
    order[NR] = name
    if (NR == 1) newest = name
  }
  END {
    # Belt and braces: the newest snapshot is always kept by the daily rule, but
    # an off-by-one in the quota logic must never be able to delete the only
    # current off-site copy of the vault.
    keep[newest] = 1
    if (why[newest] == "") why[newest] = "newest "
    for (i = 1; i <= NR; i++) {
      n = order[i]
      if (keep[n]) printf "KEEP %s %s\n", n, why[n]
      else printf "DELETE %s\n", n
    }
  }' > "$work/plan"

kept="$(grep -c '^KEEP ' "$work/plan" || true)"
deleted="$(grep -c '^DELETE ' "$work/plan" || true)"

printf 'openbao_snapshot_prune_plan total=%s keep=%s delete=%s policy=%sd/%sw/%sm/%sy apply=%s\n' \
  "$total" "$kept" "$deleted" \
  "$keep_daily" "$keep_weekly" "$keep_monthly" "$keep_yearly" "$apply"
printf -- '--- retention plan (newest first) ---\n'
cat "$work/plan"
printf -- '--- end plan ---\n'

if [ "$apply" != true ]; then
  stage=complete
  printf 'openbao_snapshot_prune_ok mode=report-only total=%s would_delete=%s\n' \
    "$total" "$deleted" | tee "$termination_log"
  exit 0
fi

# Each snapshot is removed together with its checksum sidecar, so the directory
# never holds a snapshot whose integrity record is gone or vice versa. The
# sidecar is removed FIRST: a sidecar without its snapshot is inert, whereas a
# snapshot without its sidecar looks restorable but cannot be verified.
stage=delete
removed=0
while IFS= read -r line; do
  case "$line" in DELETE\ *) ;; *) continue ;; esac
  name="${line#DELETE }"
  # shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
  ssh $ssh_opts "$ssh_target" rm "$remote_dir/${name}.sha256" >/dev/null 2>&1 || \
    printf 'note: no sidecar for %s (already absent)\n' "$name" >&2
  # shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
  ssh $ssh_opts "$ssh_target" rm "$remote_dir/$name" >/dev/null || {
    printf 'failed to remove %s\n' "$name" >&2
    exit 1
  }
  removed=$((removed + 1))
  printf 'removed %s\n' "$name"
done < "$work/plan"

stage=complete
printf 'openbao_snapshot_prune_ok mode=apply total=%s removed=%s kept=%s\n' \
  "$total" "$removed" "$kept" | tee "$termination_log"
