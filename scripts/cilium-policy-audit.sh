#!/usr/bin/env bash
# cilium-policy-audit.sh — the PolicyAuditMode + Hubble ceremony as a script.
#
# Every first enforcement of a CiliumNetworkPolicy in this repo follows the
# same steps (known-caveats: "Never merge-and-apply a tightening netpol
# blind"): put the target endpoints in PolicyAuditMode BEFORE the policy that
# selects them lands, watch for AUDIT verdicts while the real flows run, then
# take audit mode off and watch for DROPPED. Until 2026-09-13 those steps were
# hand-typed per rollout. This script owns the mechanics; the operator owns
# the decision to enforce.
#
# Usage:
#   cilium-policy-audit.sh status  <namespace> <pod>...
#   cilium-policy-audit.sh enable  <namespace> <pod>...
#   cilium-policy-audit.sh disable <namespace> <pod>...
#   cilium-policy-audit.sh observe <namespace> [since]   # default since=15m
#
# status  — per pod: node, endpoint id, PolicyAuditMode, policy-enabled
#           direction, and the NAMES of the policies realised on the
#           endpoint (derived-from rules). This is the evidence that a policy
#           selects a pod. Do not use the CiliumEndpoint for it: on Cilium
#           1.20 its .status.policy is empty for every endpoint (lessons.md).
# enable  — PolicyAuditMode=Enabled on each pod's endpoint (idempotent).
# disable — PolicyAuditMode=Disabled on each pod's endpoint (idempotent).
# observe — AUDIT and DROPPED flows touching <namespace> on EVERY node since
#           <since>, collapsed to "src -> dst :port verdict" with counts.
#           Exit 0 when there are none, 3 when there are.
#
# Audit mode is a per-endpoint runtime option: it is NOT in git, it is lost
# when the pod restarts (new endpoint), and while it is on, EVERY policy on
# that endpoint is advisory — including the clusterwide crowdsec-banned-deny.
# Keep the window short, and do not restart the pods inside it.

set -euo pipefail

die() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

CTX="$(kubectl config current-context)"
[ "$CTX" = "admin@homelab" ] || die "kubectl context is '$CTX', expected admin@homelab"

cmd="${1:-}"; shift || true
case "$cmd" in status|enable|disable|observe) ;; *)
  sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac

ns="${1:?namespace}"; shift

cilium_pod_on() {
  local node="$1" p
  p="$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$node" -o name | head -1)"
  [ -n "$p" ] || die "no cilium agent pod on node $node"
  printf '%s' "$p"
}

endpoint_of() {  # <cilium-pod> <pod-ip> -> endpoint id
  kubectl -n kube-system exec "$1" -c cilium-agent -- cilium-dbg endpoint list -o json \
    | jq -r --arg ip "$2" '.[] | select(.status.networking.addressing[]?.ipv4 == $ip) | .id'
}

per_pod() {
  local pod="$1" node ip cp id
  node="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.spec.nodeName}')" \
    || die "pod $ns/$pod not found"
  ip="$(kubectl -n "$ns" get pod "$pod" -o jsonpath='{.status.podIP}')"
  [ -n "$ip" ] || die "pod $ns/$pod has no IP yet"
  cp="$(cilium_pod_on "$node")"
  id="$(endpoint_of "$cp" "$ip")"
  [ -n "$id" ] || die "no Cilium endpoint for $ns/$pod ($ip) on $node — host-network pod?"

  case "$cmd" in
    enable)  kubectl -n kube-system exec "$cp" -c cilium-agent -- cilium-dbg endpoint config "$id" PolicyAuditMode=Enabled >/dev/null ;;
    disable) kubectl -n kube-system exec "$cp" -c cilium-agent -- cilium-dbg endpoint config "$id" PolicyAuditMode=Disabled >/dev/null ;;
  esac

  local audit enabled rules
  audit="$(kubectl -n kube-system exec "$cp" -c cilium-agent -- cilium-dbg endpoint config "$id" \
    | awk -F': *' '/^PolicyAuditMode/{print $2}')"
  enabled="$(kubectl -n kube-system exec "$cp" -c cilium-agent -- cilium-dbg endpoint get "$id" -o json \
    | jq -r '.[0].status.policy.realized["policy-enabled"] // "none"')"
  rules="$(kubectl -n kube-system exec "$cp" -c cilium-agent -- cilium-dbg endpoint get "$id" -o json \
    | jq -r '[.. | objects | .["derived-from-rules"]? // empty | .[]? | .[]? | select(startswith("k8s:io.cilium.k8s.policy.name=")) | sub("^k8s:io.cilium.k8s.policy.name=";"")] | unique | join(",")')"

  if [ "$cmd" = enable ] && [ "$audit" != Enabled ]; then die "$ns/$pod endpoint $id: PolicyAuditMode is '$audit' after enable"; fi
  if [ "$cmd" = disable ] && [ "$audit" != Disabled ]; then die "$ns/$pod endpoint $id: PolicyAuditMode is '$audit' after disable"; fi
  printf '%-40s node=%-8s ep=%-5s audit=%-8s enforcing=%-7s policies=%s\n' \
    "$ns/$pod" "$node" "$id" "$audit" "$enabled" "${rules:-<none>}"
}

if [ "$cmd" = observe ]; then
  since="${1:-15m}"
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  for cp in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
    for v in AUDIT DROPPED; do
      kubectl -n kube-system exec "$cp" -c cilium-agent -- \
        hubble observe --namespace "$ns" --verdict "$v" --since "$since" -o json 2>/dev/null >>"$tmp" || true
    done
  done
  n="$(jq -r 'select(.flow) | .flow
      | "\(.source.namespace // "")/\(.source.pod_name // ((.source.labels // []) | map(select(startswith("reserved:"))) | join(",")))  ->  \(.destination.namespace // "")/\(.destination.pod_name // ((.destination.labels // []) | map(select(startswith("reserved:"))) | join(","))) \(.IP.destination // "") :\(.l4.TCP.destination_port // .l4.UDP.destination_port // "-") \(.verdict) \(.drop_reason_desc // "")"' "$tmp" \
    | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}( |$)/-*\1/g' | sort | uniq -c | sort -rn | tee /dev/stderr | wc -l | tr -d ' ')"
  if [ "$n" = 0 ]; then
    printf 'OK: no AUDIT or DROPPED flows touching %s in the last %s, on any node.\n' "$ns" "$since"
    exit 0
  fi
  printf 'ATTENTION: %s distinct AUDIT/DROPPED flow(s) touching %s in the last %s (listed above).\n' "$n" "$ns" "$since"
  exit 3
fi

[ "$#" -ge 1 ] || die "name at least one pod"
for pod in "$@"; do per_pod "$pod"; done
case "$cmd" in
  enable)  printf 'Audit mode ON for %s pod(s). It is lost on pod restart; every policy on these endpoints is advisory until disable.\n' "$#" ;;
  disable) printf 'Audit mode OFF for %s pod(s): realised policies now ENFORCE. Run: %s observe %s\n' "$#" "$0" "$ns" ;;
esac
