#!/usr/bin/env bash
# publish-chart-bundle.sh — put the chart bundle offsite when the lock changes.
#
# ADR 0052 D7: charts are referenced from a mirror that runs IN the cluster, so
# a cold start needs them from somewhere else. export-chart-bundle.sh makes the
# bundle; this puts it where a rebuild can reach it.
#
# TRIGGERED BY CONTENT, NOT BY A CLOCK
#
# The bundle is DERIVED from charts.lock.yaml. A weekly schedule would re-upload
# an unchanged bundle 51 times a year and still miss the Renovate bump that
# landed an hour after it ran. So this computes a digest over every lock, stores
# it alongside the bundle offsite, and does nothing when it matches. Run it as
# often as you like — hourly, per-commit, by hand. It acts only on change.
#
# WHERE IT PUTS THINGS
#
#   Hetzner Storage Box  chart-bundle/        — the durable copy, on the same box
#                        restic already writes to, alongside cluster-backups-tier-3/
#                        and openbao-snapshots/. This is what a cold start reads.
#   Email                a .tar.gz attachment — redundant third copy. At ~4.5 MB
#                        the whole bundle fits an attachment, so this is a real
#                        copy, not a notification. It is NOT verifiable storage:
#                        treat it as a backstop behind the box.
#
# CREDENTIALS — never echoed; see the credential section for the source order.
#
#   kv/prod/backup/hetzner-storage-box   host, user, port, ssh_key
#       Exactly what the restic lane uses (ExternalSecret -> hetzner-sb-creds).
#   kv/shared/forgejo-packages/ci        registry pull, for building the bundle
#   kv/shared/smtp                       host, port, username, from, password
#       The relay authentik, vaultwarden and nextcloud already send through.
#
# Host-key trust follows the same rule as restic: pinned from a known_hosts file,
# never StrictHostKeyChecking=no. In-cluster that is the restic-known-hosts
# ConfigMap; on a workstation, pass KNOWN_HOSTS=<file>.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '  %s\n' "$*"; }

HELM_BIN="${HELM_BIN:-helm3}"
# Relative to the Storage Box user's home, matching its existing top-level
# layout (cluster-backups-tier-3/, openbao-snapshots/). An absolute path is not
# writable there.
REMOTE_DIR="${REMOTE_DIR:-chart-bundle}"
KNOWN_HOSTS="${KNOWN_HOSTS:-}"
MAIL_TO="${MAIL_TO:-}"
DO_UPLOAD="${DO_UPLOAD:-true}"
DO_EMAIL="${DO_EMAIL:-true}"

usage() {
  cat >&2 <<EOF
usage: $0 [--dry-run|--apply] [--force] <workspace-root>

  Publishes the chart bundle when the combined lock digest has changed.

  --dry-run   (default) report what would happen
  --apply     build, upload, and email
  --force     act even if the digest is unchanged

env: REMOTE_DIR (default chart-bundle), KNOWN_HOSTS=<file>, BUNDLE_DIR=<dir>,
     MAIL_TO=<addr>, DO_UPLOAD/DO_EMAIL=true|false, HELM_BIN,
     BAO_ADDR/BAO_CACERT for credential reads.
EOF
  exit 2
}

APPLY=false; FORCE=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=true; shift ;;
    --dry-run) APPLY=false; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage ;;
    *) break ;;
  esac
done
[ "$#" -eq 1 ] || usage
WS="$1"
[ -d "$WS" ] || { err "no such workspace: $WS"; exit 1; }

for t in "$HELM_BIN" python3 sftp ssh curl shasum tar; do
  command -v "$t" >/dev/null 2>&1 || { err "required tool missing: $t"; exit 1; }
done
# kubectl and bao are each optional — see the credential section for why.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/publish-bundle.XXXXXX")"
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

# ── 1. Collect every lock in the workspace and digest them together.
locks=()
while IFS= read -r f; do locks+=("$f"); done < <(find "$WS" -maxdepth 2 -name charts.lock.yaml -not -path '*/.git/*' | LC_ALL=C sort)
[ "${#locks[@]}" -gt 0 ] || { err "no charts.lock.yaml found under $WS"; exit 1; }
note "locks found: ${#locks[@]}"

# Digest the CONTENT of the locks, not their paths or mtimes, so an unrelated
# repo move does not look like a chart change.
lock_digest="$(cat "${locks[@]}" | shasum -a 256 | cut -d' ' -f1)"
note "combined lock digest: ${lock_digest:0:16}…"

# ── 2. Credentials. Never echoed — piped straight into files or curl config.
#
# Three sources, tried in order, because this script runs in three places:
#   1. Environment — the CronJob gets these via `envFrom: hetzner-sb-creds`,
#      exactly like the restic lane. No cluster or OpenBao access needed.
#   2. The Kubernetes Secret ESO already materialised — for workstation runs.
#   3. OpenBao directly — the source of truth, when `bao` is authenticated.
#
# 2 is listed before 3 deliberately: OpenBao's own API is not reachable through
# the gateway (it serves HTTPS, the HTTPRoute speaks HTTP to the backend), so on
# a laptop the Secret is the path that actually works without a port-forward.
from_k8s() {
  command -v kubectl >/dev/null 2>&1 || return 0
  kubectl -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
}
from_bao() {
  command -v bao >/dev/null 2>&1 || return 0
  bao kv get -mount=kv -field="$2" "$1" 2>/dev/null || true
}

cred() {  # cred <ENVVAR> <bao-path> <bao-field> <ns> <secret> <key>
  local v="${!1:-}"
  [ -n "$v" ] || v="$(from_k8s "$4" "$5" "$6")"
  [ -n "$v" ] || v="$(from_bao "$2" "$3")"
  printf '%s' "$v"
}

SB_PATH=prod/backup/hetzner-storage-box
HSB_HOST="$(cred HSB_HOST "$SB_PATH" host backup-cronjobs hetzner-sb-creds HSB_HOST)"
HSB_USER="$(cred HSB_USER "$SB_PATH" user backup-cronjobs hetzner-sb-creds HSB_USER)"
HSB_PORT="$(cred HSB_PORT "$SB_PATH" port backup-cronjobs hetzner-sb-creds HSB_PORT)"
if [ -z "$HSB_HOST" ] || [ -z "$HSB_USER" ]; then
  err "no Storage Box credentials from env, cluster, or OpenBao."
  note "In-cluster: envFrom the hetzner-sb-creds Secret."
  note "Workstation: make sure kubectl can read backup-cronjobs/hetzner-sb-creds."
  exit 1
fi
HSB_PORT="${HSB_PORT:-23}"

ssh_key="$work/id_sb"
( umask 077; cred SSH_KEY "$SB_PATH" ssh_key backup-cronjobs hetzner-sb-creds SSH_KEY > "$ssh_key" )
[ -s "$ssh_key" ] || { err "storage-box ssh_key is empty"; exit 1; }
# ssh refuses a key without a trailing newline on some versions; harmless if present.
[ -n "$(tail -c1 "$ssh_key")" ] && printf '\n' >> "$ssh_key"
chmod 600 "$ssh_key"

if [ -z "$KNOWN_HOSTS" ]; then
  err "KNOWN_HOSTS not set. Host-key trust is pinned, never StrictHostKeyChecking=no."
  note "In-cluster: mount the restic-known-hosts ConfigMap and point KNOWN_HOSTS at it."
  note "On a workstation: extract it once —"
  note "  kubectl -n backup-cronjobs get cm restic-known-hosts -o jsonpath='{.data.known_hosts}' > ~/.config/homelab/sb_known_hosts"
  exit 1
fi
[ -f "$KNOWN_HOSTS" ] || { err "KNOWN_HOSTS file not found: $KNOWN_HOSTS"; exit 1; }
SSH_OPTS=(-i "$ssh_key" -o "UserKnownHostsFile=$KNOWN_HOSTS" -o BatchMode=yes -o StrictHostKeyChecking=yes -P "$HSB_PORT")

# ── 3. Prove the box is reachable BEFORE interpreting a missing digest.
#
# Without this, a refused connection and a genuinely absent lock.digest look
# identical — both yield an empty string — so an unreachable box would report
# "first publish" forever and quietly never publish anything.
if ! echo "pwd" | sftp -q -b - "${SSH_OPTS[@]}" "$HSB_USER@$HSB_HOST" >/dev/null 2>"$work/sftp.err"; then
  err "cannot reach $HSB_HOST:$HSB_PORT as $HSB_USER"
  sed 's/^/      /' "$work/sftp.err" | head -3 >&2
  note "If this says 'Permission denied (publickey)', the key is likely missing a"
  note "trailing newline — ssh will not even offer a malformed key."
  exit 1
fi

# ── 4. Has anything changed?
# Download it to a file rather than /dev/stdout: sftp echoes the command it is
# running onto stdout even under -q, so reading stdout yields "sftp> get ..."
# instead of the file. That silently looked like a digest mismatch and would
# have republished on every single run.
printf 'get %s/lock.digest %s/remote.digest\n' "$REMOTE_DIR" "$work" \
  | sftp -q -b - "${SSH_OPTS[@]}" "$HSB_USER@$HSB_HOST" >/dev/null 2>&1 || true
remote_digest="$( [ -f "$work/remote.digest" ] && tr -d '[:space:]' < "$work/remote.digest" || true )"
if [ "$remote_digest" = "$lock_digest" ] && [ "$FORCE" != true ]; then
  note "offsite copy already matches this lock digest — nothing to do."
  echo; echo "── state"; echo "   action: none (unchanged)"; exit 0
fi
if [ "$remote_digest" = "$lock_digest" ]; then
  note "offsite copy is current, but --force given — republishing anyway"
elif [ -n "$remote_digest" ]; then
  note "offsite digest differs (${remote_digest:0:16}…) — republishing"
else
  note "no offsite digest found — first publish"
fi

if [ "$APPLY" != true ]; then
  echo; echo "── state"; echo "   action: WOULD publish (dry-run)"; exit 0
fi

# ── 5. Build and verify the bundle.
#
# BUNDLE_DIR can point at a persistent directory: export-chart-bundle.sh skips
# any chart already present whose .sha256 still checks out, so a rebuild after a
# single Renovate bump downloads one chart, not all 32.
bundle="${BUNDLE_DIR:-$work/chart-bundle}"
"$SCRIPT_DIR/export-chart-bundle.sh" "$bundle" "${locks[@]}" >/dev/null \
  || { err "bundle export failed"; exit 1; }
"$SCRIPT_DIR/import-chart-bundle.sh" --dry-run "$bundle" >/dev/null \
  || { err "bundle failed its own verification — not publishing"; exit 1; }

# Prune charts the locks no longer pin. Without this a reused BUNDLE_DIR grows a
# tail of superseded versions after every Renovate bump, and they would be
# uploaded and emailed as if they were still current.
pruned="$(python3 - "$bundle" <<'PY'
import sys, os, re, glob
d = sys.argv[1]
txt = open(os.path.join(d, 'bundle.manifest')).read()
keep = set()
name = None
for line in txt.splitlines():
    m = re.match(r'\s*- name: (.+)$', line)
    if m: name = m.group(1).strip()
    m = re.match(r'\s*version: "(.+)"$', line)
    if m and name: keep.add(f"{name}-{m.group(1)}.tgz")
for f in glob.glob(os.path.join(d, '*.tgz')):
    if os.path.basename(f) not in keep:
        os.remove(f)
        for s in (f + '.sha256',):
            if os.path.exists(s): os.remove(s)
        print(os.path.basename(f))
PY
)"
[ -n "$pruned" ] && note "pruned superseded: $(printf '%s' "$pruned" | tr '\n' ' ')"

printf '%s\n' "$lock_digest" > "$bundle/lock.digest"
count="$(ls "$bundle"/*.tgz | wc -l | tr -d ' ')"
size="$(du -sh "$bundle" | cut -f1)"
note "bundle: $count charts, $size, verified"

# ── 6. Storage Box.
if [ "$DO_UPLOAD" = true ]; then
  # lock.digest is uploaded LAST and is the completion marker: if a transfer dies
  # halfway, the digest still shows the OLD value, so the next run republishes
  # rather than trusting a partial directory.
  {
    # Only mkdir a parent when there is one; `dirname chart-bundle` is "." and
    # mkdir "." fails noisily on every run.
    case "$REMOTE_DIR" in */*) echo "-mkdir $(dirname "$REMOTE_DIR")" ;; esac
    echo "-mkdir $REMOTE_DIR"
    echo "cd $REMOTE_DIR"
    echo "-rm *.tgz"
    echo "-rm *.tgz.sha256"
    for f in "$bundle"/*.tgz "$bundle"/*.tgz.sha256 "$bundle"/bundle.manifest; do
      echo "put \"$f\""
    done
    echo "put \"$bundle/lock.digest\""
  } | sftp -q "${SSH_OPTS[@]}" "$HSB_USER@$HSB_HOST" >/dev/null \
    || { err "sftp upload failed"; exit 1; }
  note "uploaded to $HSB_HOST:$REMOTE_DIR"
fi

# ── 7. Email a compressed copy.
if [ "$DO_EMAIL" = true ]; then
  # Same relay authentik, vaultwarden and nextcloud send through (kv/shared/smtp).
  SMTP_HOST="$(cred SMTP_HOST shared/smtp host     backup-cronjobs chart-bundle-smtp SMTP_HOST)"
  SMTP_PORT="$(cred SMTP_PORT shared/smtp port     backup-cronjobs chart-bundle-smtp SMTP_PORT)"
  SMTP_USER="$(cred SMTP_USERNAME shared/smtp username backup-cronjobs chart-bundle-smtp SMTP_USERNAME)"
  SMTP_FROM="$(cred SMTP_FROM shared/smtp from     backup-cronjobs chart-bundle-smtp SMTP_FROM)"
  smtp_pass="$(cred SMTP_PASSWORD shared/smtp password backup-cronjobs chart-bundle-smtp SMTP_PASSWORD)"
  to="${MAIL_TO:-$SMTP_FROM}"
  if [ -z "$SMTP_HOST" ] || [ -z "$smtp_pass" ]; then
    err "kv/shared/smtp incomplete — skipping email (the Storage Box copy still landed)"
  else
    tarball="$work/chart-bundle-${lock_digest:0:12}.tar.gz"
    tar -czf "$tarball" -C "$(dirname "$bundle")" "$(basename "$bundle")"
    # Build with the email library rather than by hand. A hand-rolled MIME body
    # put the whole base64 payload on ONE line; SMTP limits a line to 1000
    # characters (RFC 5321 §4.5.3.1), so the relay stalled and curl reported a
    # response timeout that looked like a network fault. EmailMessage wraps the
    # payload at 76 columns and policy.SMTP emits CRLF endings.
    python3 - "$tarball" "$SMTP_FROM" "$to" "$lock_digest" "$count" "$size" "$REMOTE_DIR" > "$work/mail.eml" <<'PY'
import sys, os
from email.message import EmailMessage
from email import policy

tarball, sender, to, digest, count, size, remote = sys.argv[1:8]
name = os.path.basename(tarball)

m = EmailMessage(policy=policy.SMTP)
m['From'] = sender
m['To'] = to
m['Subject'] = f"[homelab] chart bundle {digest[:12]} ({count} charts, {size})"
m.set_content(
    "Chart bundle published because charts.lock.yaml changed.\n\n"
    f"  charts      : {count}\n"
    f"  size        : {size}\n"
    f"  lock digest : {digest}\n\n"
    "This attachment is the REDUNDANT copy. The durable one is on the Hetzner\n"
    f"Storage Box under {remote}/, which is what a cold start should read --\n"
    "it is the copy that gets verified, and it is not subject to a mailbox\n"
    "retention policy.\n\n"
    "Verify either copy with:\n\n"
    f"  tar xzf {name} && cd chart-bundle && shasum -a 256 -c *.sha256\n\n"
    "Restore into a rebuilt registry with:\n\n"
    "  homelab-k8s/scripts/import-chart-bundle.sh --apply <dir> <registry>\n"
)
m.add_attachment(open(tarball, 'rb').read(),
                 maintype='application', subtype='gzip', filename=name)
sys.stdout.write(m.as_string())
PY
    # Port picks the scheme: 465 is implicit TLS, everything else is submission
    # with mandatory STARTTLS. --ssl-reqd so a relay that fails to negotiate TLS
    # aborts instead of sending credentials in the clear.
    SMTP_PORT="${SMTP_PORT:-587}"
    if [ "$SMTP_PORT" = "465" ]; then url="smtps://$SMTP_HOST:465"; else url="smtp://$SMTP_HOST:$SMTP_PORT"; fi

    # The password goes in a 0600 config file, never in argv — `ps` is readable
    # by every process on the host, and this relay is the same one authentik,
    # vaultwarden and tailscale invitations go through.
    ( umask 077; printf 'user = "%s:%s"\n' "$SMTP_USER" "$smtp_pass" > "$work/curlrc" )
    unset smtp_pass

    if curl -sS --config "$work/curlrc" --url "$url" --ssl-reqd \
         --mail-from "$SMTP_FROM" --mail-rcpt "$to" \
         --upload-file "$work/mail.eml" >"$work/curl.err" 2>&1; then
      note "emailed to $to ($(basename "$url"))"
    else
      err "email failed — the Storage Box copy still landed. curl said:"
      sed 's/^/      /' "$work/curl.err" | head -3 >&2
    fi
    rm -f "$work/curlrc"
  fi
fi

echo
echo "── state"
echo "   charts published : $count ($size)"
echo "   lock digest      : ${lock_digest:0:16}…"
echo "   storage box      : $([ "$DO_UPLOAD" = true ] && echo "$REMOTE_DIR" || echo skipped)"
echo "   email            : $([ "$DO_EMAIL" = true ] && echo sent-or-reported || echo skipped)"
exit 0
