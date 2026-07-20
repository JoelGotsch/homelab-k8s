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

on_exit() {
  rc=$?
  rm -f "$key_file"
  if [ "$rc" -ne 0 ]; then
    printf 'openbao_snapshot_upload_failed stage=%s rc=%s\n' "$stage" "$rc" \
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
ssh_opts="-i $key_file -o UserKnownHostsFile=$ssh_dir/known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -p $HSB_PORT"
snapshot_name="$(basename "$snapshot")"
remote_final="openbao-snapshots/$snapshot_name"
remote_partial="openbao-snapshots/.${snapshot_name}.partial"

stage=remote-directory
# shellcheck disable=SC2086 # option words are intentional and contain no secrets
ssh $ssh_opts "$ssh_target" mkdir -p openbao-snapshots >/dev/null

stage=upload
# shellcheck disable=SC2086 # option words are intentional and contain no secrets
scp -q -P "$HSB_PORT" -i "$key_file" \
  -o "UserKnownHostsFile=$ssh_dir/known_hosts" \
  -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes \
  -o IdentityAgent=none "$snapshot" "$ssh_target:$remote_partial"
# shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
ssh $ssh_opts "$ssh_target" mv "$remote_partial" "$remote_final" >/dev/null

stage=remote-integrity
# Hetzner documents sha256sum as an allowed direct command on Storage Box port 23.
# shellcheck disable=SC2086,SC2029 # option/path expansion is intentional and generated locally
remote_result="$(ssh $ssh_opts "$ssh_target" sha256sum "$remote_final")"
remote_digest="${remote_result%% *}"
[ "$remote_digest" = "$local_digest" ] || {
  printf 'remote checksum does not match local snapshot\n' >&2
  exit 1
}
# Publish the checksum only after the remote object itself has verified.
scp -q -P "$HSB_PORT" -i "$key_file" \
  -o "UserKnownHostsFile=$ssh_dir/known_hosts" \
  -o StrictHostKeyChecking=yes -o BatchMode=yes -o IdentitiesOnly=yes \
  -o IdentityAgent=none "$checksum" "$ssh_target:${remote_final}.sha256"

stage=complete
printf 'openbao_snapshot_upload_ok remote=%s bytes=%s sha256=%s\n' \
  "$remote_final" "$(stat -c %s "$snapshot")" "$local_digest" \
  | tee "$termination_log"
