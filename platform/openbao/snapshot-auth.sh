#!/bin/sh
# Exchange the bounded-audience Kubernetes JWT for a 15-minute OpenBao batch
# token and write one integrity-checked Raft snapshot. No credential is logged.

set -eu
umask 077

jwt_file="${OPENBAO_JWT_FILE:-/var/run/secrets/openbao-auth/token}"
output="${SNAPSHOT_OUTPUT:?SNAPSHOT_OUTPUT must name the final .snap file}"
termination_log="${TERMINATION_LOG:-/dev/termination-log}"
token_file="$(mktemp /tmp/openbao-token.XXXXXX)"
partial="${output}.partial"
stage=login

on_exit() {
  rc=$?
  unset BAO_TOKEN
  rm -f "$token_file" "$partial"
  if [ "$rc" -ne 0 ]; then
    printf 'openbao_snapshot_failed stage=%s rc=%s\n' "$stage" "$rc" \
      > "$termination_log"
  fi
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

[ -r "$jwt_file" ] || { printf 'projected OpenBao JWT is unreadable\n' >&2; exit 1; }
mkdir -p "$(dirname "$output")"

if ! bao write -field=token auth/kubernetes/login \
    role=openbao-raft-snapshot jwt="@$jwt_file" >"$token_file"; then
  printf 'OpenBao Kubernetes login failed\n' >&2
  exit 1
fi
[ -s "$token_file" ] || { printf 'OpenBao login returned an empty token\n' >&2; exit 1; }
chmod 0600 "$token_file"
BAO_TOKEN="$(cat "$token_file")"
export BAO_TOKEN

stage=snapshot
bao operator raft snapshot save "$partial"
[ -s "$partial" ] || { printf 'Raft snapshot output is empty\n' >&2; exit 1; }

stage=integrity
mv "$partial" "$output"
output_dir="$(dirname "$output")"
output_name="$(basename "$output")"
(
  cd "$output_dir"
  sha256sum "$output_name" >"${output_name}.sha256"
  sha256sum -c "${output_name}.sha256" >/dev/null
)
size="$(stat -c %s "$output")"
digest="$(cut -d ' ' -f 1 "${output}.sha256")"

stage=complete
printf 'openbao_snapshot_ok file=%s bytes=%s sha256=%s\n' \
  "$output_name" "$size" "$digest" | tee "$termination_log"
