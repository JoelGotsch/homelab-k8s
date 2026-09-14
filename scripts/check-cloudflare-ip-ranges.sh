#!/usr/bin/env bash
# check-cloudflare-ip-ranges.sh — every CNP rule that allows "Cloudflare" by
# CIDR lists Cloudflare's PUBLISHED IPv4 ranges exactly, and the hosts the
# rule exists for actually resolve inside them.
#
# WHY (2026-09-14)
#
# Two policies talk to Cloudflare's anycast edge, whose addresses rotate:
#
#   cert-manager (`cert-manager-apiserver-acme`, :53) verifies a DNS-01
#   challenge by asking the zone's AUTHORITATIVE nameservers before it tells
#   ACME to validate. The first allow was `0.0.0.0/0:53` — an open Kyverno
#   `homelab-disallow-open-egress-cnp` failure, and a selector that also
#   picked up the CrowdSec ban-list identity and overflowed the DNS proxy's
#   restart snapshot ("Too many IPs for a DNS rule", 4,320/day).
#
#   cloudflared (`cloudflared-edge-egress`, :7844 and :443) registers its
#   tunnel at region1/region2.v2.argotunnel.com. The first allow was
#   `toEntities: world` on those four ports — the same Kyverno failure, on
#   the pod that terminates every public hostname of the site.
#
# Both rules now list Cloudflare's published ranges
# (https://www.cloudflare.com/ips-v4). A hand-copied list is only right on
# the day it is copied, so this check holds two invariants per policy on
# every commit touching it:
#
#   1. the committed CIDR set on the rule == the published set, exactly;
#   2. every A record of every host the rule is FOR falls inside that set.
#      Invariant 1 could hold while Cloudflare serves the zone, or the
#      tunnel edge, from somewhere it does not publish; only 2 catches that.
#      The symptom otherwise is the 2026-07-24 one for cert-manager
#      ("Waiting for DNS-01 challenge propagation: dial tcp <ns>:53: i/o
#      timeout" for days) and, for cloudflared, every public hostname of
#      the site returning Cloudflare's 530 while the pods log
#      "failed to dial to edge".
#
# TARGETS below is the table: policy file | policy name | port whose
# toCIDRSet rule(s) are in scope | hosts to resolve. `ns:` means "the NS
# records of the site zone" (read from site-config); `host:` is a literal
# comma-separated list. Add a row when another policy pins Cloudflare.
#
# NETWORK: both invariants need the network (HTTPS to cloudflare.com, DNS).
# This script FAILS when it cannot reach them — it never skips. A check that
# passes because its input was unreachable is the "green while checking
# nothing" shape lessons.md tracks. It is scoped by the pre-commit `files:`
# pattern to the policies and to itself, so it only runs when a list is
# being changed; CI does not run pre-commit for this repo (2026-09-14).
#
# Exit 0 = both invariants hold for every target. Exit 1 = a difference, a
# host outside its set, a missing tool, or an unreachable source — each with
# the fix printed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PUBLISHED_URL="https://www.cloudflare.com/ips-v4"
SITE_CONFIG="components/site-config/site-config.env"

TARGETS=(
  "infrastructure/cert-manager/networkpolicy.yaml|cert-manager-apiserver-acme|53|ns:"
  "infrastructure/cloudflare-tunnel/ciliumnetworkpolicy.yaml|cloudflared-edge-egress|7844|host:region1.v2.argotunnel.com,region2.v2.argotunnel.com"
)

fail() { printf 'check-cloudflare-ip-ranges: FAIL — %s\n' "$*" >&2; exit 1; }

for tool in yq curl dig python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required (brew install ${tool/dig/bind})"
done
[ -f "$SITE_CONFIG" ] || fail "$SITE_CONFIG not found"

published="$(
  curl --fail --silent --show-error --location --max-time 20 "$PUBLISHED_URL" \
    | tr -d '\r' | sed '/^[[:space:]]*$/d' | sort -u
)" || fail "could not fetch $PUBLISHED_URL — this check needs network and does not skip; retry with connectivity"
[ -n "$published" ] || fail "$PUBLISHED_URL returned an empty list"

domain="$(sed -n 's/^domain=//p' "$SITE_CONFIG" | tr -d '"' | head -1)"
[ -n "$domain" ] || fail "no domain= in $SITE_CONFIG"

resolve_a() {
  # A records of one hostname, IPv4 only; fails loudly on an empty answer.
  local host="$1" ips
  ips="$(dig +short A "$host" | /usr/bin/grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  [ -n "$ips" ] || fail "dig A $host returned no IPv4 address — DNS unreachable or the name is gone; this check does not skip"
  printf '%s\n' "$ips"
}

summary=""
for target in "${TARGETS[@]}"; do
  IFS='|' read -r policy_file policy_name port hosts_spec <<<"$target"
  [ -f "$policy_file" ] || fail "$policy_file not found"

  # 1. Committed set: every CIDR on the :$port toCIDRSet rule(s) of the named
  #    CNP. Multi-document file, so eval-all + select on kind/name; the port
  #    filter keeps an unrelated toCIDRSet rule in the same policy out of scope.
  committed="$(
    yq eval-all '
      select(.kind == "CiliumNetworkPolicy" and .metadata.name == "'"$policy_name"'")
      | .spec.egress[]
      | select(.toCIDRSet != null and ([.toPorts[].ports[].port] | contains(["'"$port"'"])))
      | .toCIDRSet[].cidr
    ' "$policy_file" | sort -u
  )"
  [ -n "$committed" ] || fail "no toCIDRSet rule on port $port found in $policy_name ($policy_file)"

  if ! diff_out="$(diff <(printf '%s\n' "$published") <(printf '%s\n' "$committed"))"; then
    printf 'check-cloudflare-ip-ranges: FAIL — %s (%s, :%s) differs from %s\n' "$policy_file" "$policy_name" "$port" "$PUBLISHED_URL" >&2
    printf '  (< published, > committed)\n%s\n' "$diff_out" >&2
    printf '  Fix: make the :%s toCIDRSet in %s exactly the published list, then re-run.\n' "$port" "$policy_name" >&2
    exit 1
  fi

  # 2. The hosts the rule is for resolve to addresses inside the committed set.
  case "$hosts_spec" in
    ns:)
      hosts="$(dig +short NS "$domain" | sed 's/\.$//' | sort -u)"
      [ -n "$hosts" ] || fail "dig NS $domain returned nothing — DNS unreachable or zone has no NS; this check does not skip"
      what="NS of the site zone"
      ;;
    host:*)
      hosts="$(printf '%s' "${hosts_spec#host:}" | tr ',' '\n')"
      what="tunnel edge host(s)"
      ;;
    *) fail "unknown hosts spec '$hosts_spec' in TARGETS" ;;
  esac

  host_ips=""
  for h in $hosts; do
    host_ips="$host_ips $(resolve_a "$h" | tr '\n' ' ')"
  done

  # Containment in python's stdlib ipaddress: no PyYAML, no third-party
  # module, so the macOS system python3 is enough.
  outside="$(
    printf '%s\n' "$committed" | python3 -c '
import ipaddress, sys
nets = [ipaddress.ip_network(l.strip()) for l in sys.stdin if l.strip()]
for ip in sys.argv[1:]:
    a = ipaddress.ip_address(ip)
    if not any(a in n for n in nets):
        print(ip)
' $host_ips
  )"
  if [ -n "$outside" ]; then
    printf 'check-cloudflare-ip-ranges: FAIL — address(es) of the %s are OUTSIDE the :%s allowlist of %s:\n' "$what" "$port" "$policy_name" >&2
    printf '  %s\n' $outside >&2
    printf '  Cloudflare is serving these from ranges it does not publish at %s; connections from the policied pods to them will time out.\n' "$PUBLISHED_URL" >&2
    exit 1
  fi

  n_cidr="$(printf '%s\n' "$committed" | /usr/bin/grep -c .)"
  n_host="$(printf '%s\n' "$hosts" | /usr/bin/grep -c .)"
  n_ip="$(printf '%s\n' $host_ips | /usr/bin/grep -c .)"
  summary="$summary
  $policy_name :$port — $n_cidr CIDRs match; $n_ip address(es) of $n_host $what inside them"
done

echo "check-cloudflare-ip-ranges: OK — published list $PUBLISHED_URL$summary"
