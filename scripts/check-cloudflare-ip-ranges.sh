#!/usr/bin/env bash
# check-cloudflare-ip-ranges.sh — the cert-manager DNS-01 self-check egress
# list is Cloudflare's PUBLISHED IPv4 ranges, and the zone's nameservers
# actually live inside it.
#
# WHY (2026-09-14)
#
# cert-manager verifies a DNS-01 challenge by asking the zone's AUTHORITATIVE
# nameservers on :53 before it tells ACME to validate. Those are Cloudflare
# anycast addresses that rotate, so the first allow was `0.0.0.0/0:53` — an
# open Kyverno `homelab-disallow-open-egress-cnp` failure, and a selector that
# also picked up the CrowdSec ban-list identity and overflowed the DNS proxy's
# restart snapshot ("Too many IPs for a DNS rule", 4,320/day). The rule now
# lists Cloudflare's published ranges (https://www.cloudflare.com/ips-v4).
#
# A hand-copied list is only right on the day it is copied. This check holds
# two invariants on every commit touching the policy:
#
#   1. the committed CIDR set on the :53 rule == the published set, exactly;
#   2. every A record of every NS of the site zone falls inside that set —
#      the thing the rule is FOR. Invariant 1 could hold while Cloudflare
#      serves the zone from somewhere new; only 2 catches that, and the
#      symptom otherwise is the 2026-07-24 one: "Waiting for DNS-01 challenge
#      propagation: dial tcp <ns>:53: i/o timeout" for days, found with weeks
#      left on the cert.
#
# NETWORK: both invariants need the network (HTTPS to cloudflare.com, DNS).
# This script FAILS when it cannot reach them — it never skips. A check that
# passes because its input was unreachable is the "green while checking
# nothing" shape lessons.md tracks. It is scoped by the pre-commit `files:`
# pattern to the policy and to itself, so it only runs when the list is being
# changed; CI does not run pre-commit for this repo (2026-09-14).
#
# Exit 0 = both invariants hold. Exit 1 = a difference, an NS outside the set,
# a missing tool, or an unreachable source — each with the fix printed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

POLICY_FILE="infrastructure/cert-manager/networkpolicy.yaml"
POLICY_NAME="cert-manager-apiserver-acme"
PUBLISHED_URL="https://www.cloudflare.com/ips-v4"
SITE_CONFIG="components/site-config/site-config.env"

fail() { printf 'check-cloudflare-ip-ranges: FAIL — %s\n' "$*" >&2; exit 1; }

for tool in yq curl dig python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required (brew install ${tool/dig/bind})"
done
[ -f "$POLICY_FILE" ] || fail "$POLICY_FILE not found"
[ -f "$SITE_CONFIG" ] || fail "$SITE_CONFIG not found"

# 1. Committed set: every CIDR on the :53 toCIDRSet rule(s) of the named CNP.
#    Multi-document file, so eval-all + select on kind/name; the port filter
#    keeps a future non-DNS toCIDRSet rule in the same policy out of scope.
committed="$(
  yq eval-all '
    select(.kind == "CiliumNetworkPolicy" and .metadata.name == "'"$POLICY_NAME"'")
    | .spec.egress[]
    | select(.toCIDRSet != null and ([.toPorts[].ports[].port] | contains(["53"])))
    | .toCIDRSet[].cidr
  ' "$POLICY_FILE" | sort -u
)"
[ -n "$committed" ] || fail "no toCIDRSet rule on port 53 found in $POLICY_NAME ($POLICY_FILE)"

published="$(
  curl --fail --silent --show-error --location --max-time 20 "$PUBLISHED_URL" \
    | tr -d '\r' | sed '/^[[:space:]]*$/d' | sort -u
)" || fail "could not fetch $PUBLISHED_URL — this check needs network and does not skip; retry with connectivity"
[ -n "$published" ] || fail "$PUBLISHED_URL returned an empty list"

if ! diff_out="$(diff <(printf '%s\n' "$published") <(printf '%s\n' "$committed"))"; then
  printf 'check-cloudflare-ip-ranges: FAIL — %s differs from %s\n' "$POLICY_FILE" "$PUBLISHED_URL" >&2
  printf '  (< published, > committed)\n%s\n' "$diff_out" >&2
  printf '  Fix: make the :53 toCIDRSet in %s exactly the published list, then re-run.\n' "$POLICY_NAME" >&2
  exit 1
fi

# 2. The zone's nameservers resolve to addresses inside the committed set.
domain="$(sed -n 's/^domain=//p' "$SITE_CONFIG" | tr -d '"' | head -1)"
[ -n "$domain" ] || fail "no domain= in $SITE_CONFIG"

ns_list="$(dig +short NS "$domain" | sed 's/\.$//' | sort -u)"
[ -n "$ns_list" ] || fail "dig NS $domain returned nothing — DNS unreachable or zone has no NS; this check does not skip"

ns_ips=""
for ns in $ns_list; do
  ips="$(dig +short A "$ns" | /usr/bin/grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  [ -n "$ips" ] || fail "dig A $ns returned no IPv4 address"
  ns_ips="$ns_ips $(printf '%s' "$ips" | tr '\n' ' ')"
done

# Containment in python's stdlib ipaddress: no PyYAML, no third-party module,
# so the macOS system python3 is enough.
outside="$(
  printf '%s\n' "$committed" | python3 -c '
import ipaddress, sys
nets = [ipaddress.ip_network(l.strip()) for l in sys.stdin if l.strip()]
for ip in sys.argv[1:]:
    a = ipaddress.ip_address(ip)
    if not any(a in n for n in nets):
        print(ip)
' $ns_ips
)"
if [ -n "$outside" ]; then
  printf 'check-cloudflare-ip-ranges: FAIL — nameserver address(es) for %s are OUTSIDE the committed :53 allowlist:\n' "$domain" >&2
  printf '  %s\n' $outside >&2
  printf '  Cloudflare is serving the zone from ranges it does not publish at %s; cert-manager DNS-01 self-checks to these will time out.\n' "$PUBLISHED_URL" >&2
  exit 1
fi

n_cidr="$(printf '%s\n' "$committed" | /usr/bin/grep -c .)"
n_ns="$(printf '%s\n' "$ns_list" | /usr/bin/grep -c .)"
n_ip="$(printf '%s\n' $ns_ips | /usr/bin/grep -c .)"
echo "check-cloudflare-ip-ranges: OK — $n_cidr CIDRs match $PUBLISHED_URL; $n_ip address(es) of $n_ns NS for the site zone are inside them"
