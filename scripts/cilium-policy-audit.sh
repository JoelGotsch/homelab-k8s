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
#   cilium-policy-audit.sh watch   <namespace> [seconds] # default 90
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
#           Exit 0 when there are none, 3 when there are, 2 when there are
#           none but a node's buffer did not reach back as far as <since>.
#           READ THAT 2: each agent keeps a ring buffer of 4,095 flows, and
#           at this cluster's 800-900 flows/s per worker that is about FIVE
#           SECONDS. Until 2026-09-14 this subcommand answered "no flows in
#           the last 15m" from those five seconds (lessons.md). It now
#           prints how far back every node's buffer actually reaches, and
#           for the part of the window the buffers do not hold it asks
#           Prometheus: since 2026-09-14 (hl-0308) the agents' Hubble
#           metrics are scraped with source/destination = namespace (or the
#           reserved identity), so `hubble_drop_total{reason="POLICY_DENIED"}`
#           and `hubble_flows_processed_total{verdict="AUDIT"}` answer
#           "anything touching <namespace> in the last <since>" for as long
#           as Prometheus retains (15d). Counters, not flows: they say WHICH
#           namespace pair and protocol, not which pod or port — for that
#           use `watch`. Exit 0 = both sources clean; 3 = something in
#           either; 2 = buffers short AND Prometheus unreachable.
# watch   — the honest form for a rehearsal: streams AUDIT and DROPPED flows
#           touching <namespace> from every node for <seconds> (default 90)
#           while you exercise the workload, then summarises like observe.
#           Exit 0 none, 3 some. Run it in one terminal, drive traffic from
#           another; it does not depend on the buffer at all.
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
case "$cmd" in status|enable|disable|observe|watch) ;; *)
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

summarise() {  # <flows.json> -> prints the collapsed table on stderr, count on stdout
  jq -r 'select(.flow) | .flow
      | "\(.source.namespace // "")/\(.source.pod_name // ((.source.labels // []) | map(select(startswith("reserved:"))) | join(",")))  ->  \(.destination.namespace // "")/\(.destination.pod_name // ((.destination.labels // []) | map(select(startswith("reserved:"))) | join(","))) \(.IP.destination // "") :\(.l4.TCP.destination_port // .l4.UDP.destination_port // "-") \(.verdict) \(.drop_reason_desc // "")"' "$1" \
    | sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}( |$)/-*\1/g' | sort | uniq -c | sort -rn | tee /dev/stderr | wc -l | tr -d ' '
}

to_seconds() {  # 90 | 30s | 15m | 2h -> seconds
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *)  echo "$1" ;;
  esac
}

if [ "$cmd" = observe ]; then
  since="${1:-15m}"; want="$(to_seconds "$since")"
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  short=0
  for cp in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
    node="$(kubectl -n kube-system get "$cp" -o jsonpath='{.spec.nodeName}')"
    # How far back this node's ring buffer reaches: the oldest flow in it.
    oldest="$(kubectl -n kube-system exec "$cp" -c cilium-agent -- hubble observe --first 1 -o json 2>/dev/null \
      | jq -r 'select(.flow) | .flow.time' | head -1)"
    if [ -n "$oldest" ]; then
      age=$(( $(date -u +%s) - $(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${oldest%%.*}" +%s 2>/dev/null || date -u -d "${oldest%%.*}" +%s) ))
      printf 'buffer on %-8s reaches back %5ss (asked %s)\n' "$node" "$age" "$since" >&2
      [ "$age" -ge "$want" ] || short=1
    else
      printf 'buffer on %-8s unreadable\n' "$node" >&2; short=1
    fi
    for v in AUDIT DROPPED; do
      kubectl -n kube-system exec "$cp" -c cilium-agent -- \
        hubble observe --namespace "$ns" --verdict "$v" --since "$since" -o json 2>/dev/null >>"$tmp" || true
    done
  done
  n="$(summarise "$tmp")"

  # Prometheus for the whole window (counters survive the buffer). A local
  # port-forward to the Prometheus Service, torn down on exit.
  pm=0; prom_ok=0
  pf_port=$(( 20000 + RANDOM % 10000 ))
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus "$pf_port:9090" --address 127.0.0.1 >/dev/null 2>&1 &
  pf_pid=$!
  trap 'kill "$pf_pid" 2>/dev/null; rm -f "$tmp"' EXIT
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    curl -sf --max-time 2 "http://127.0.0.1:$pf_port/-/ready" >/dev/null 2>&1 && { prom_ok=1; break; }
    sleep 1
  done
  if [ "$prom_ok" = 1 ]; then
    q_drop="sum by (source, destination, protocol) (increase(hubble_drop_total{reason=\"POLICY_DENIED\", source=\"$ns\"}[$since]) or increase(hubble_drop_total{reason=\"POLICY_DENIED\", destination=\"$ns\"}[$since])) > 0.5"
    q_audit="sum by (source, destination, protocol) (increase(hubble_flows_processed_total{verdict=\"AUDIT\", source=\"$ns\"}[$since]) or increase(hubble_flows_processed_total{verdict=\"AUDIT\", destination=\"$ns\"}[$since])) > 0.5"
    for pair in "DROPPED POLICY_DENIED|$q_drop" "AUDIT|$q_audit"; do
      tag="${pair%%|*}"; q="${pair#*|}"
      rows="$(curl -sG --max-time 15 "http://127.0.0.1:$pf_port/api/v1/query" --data-urlencode "query=$q" \
        | jq -r --arg tag "$tag" '.data.result[]? | "\(.value[1]|tonumber|round)\t\(.metric.source) -> \(.metric.destination) \(.metric.protocol) \($tag)"')"
      if [ -n "$rows" ]; then
        printf '%s\n' "$rows" | sort -rn >&2
        pm=$(( pm + $(printf '%s\n' "$rows" | wc -l) ))
      fi
    done
    printf 'prometheus: %s namespace-pair(s) with AUDIT/POLICY_DENIED counts touching %s in the last %s\n' "$pm" "$ns" "$since" >&2
  else
    printf 'prometheus: unreachable through port-forward — counters not consulted\n' >&2
  fi

  if [ "$n" != 0 ] || [ "$pm" != 0 ]; then
    printf 'ATTENTION: %s distinct AUDIT/DROPPED flow(s) in the buffers and %s Prometheus pair(s) touching %s in the last %s (listed above).\n' "$n" "$pm" "$ns" "$since"
    exit 3
  fi
  if [ "$short" = 1 ] && [ "$prom_ok" = 0 ]; then
    printf 'INCONCLUSIVE: nothing in what the buffers hold, but at least one node holds less than %s and Prometheus was unreachable. Use: %s watch %s <seconds> while driving traffic.\n' "$since" "$0" "$ns"
    exit 2
  fi
  if [ "$short" = 1 ]; then
    printf 'OK: no AUDIT or POLICY_DENIED counts touching %s in the last %s (Prometheus), and nothing in the buffers (which cover only seconds).\n' "$ns" "$since"
  else
    printf 'OK: no AUDIT or DROPPED flows touching %s in the last %s, in the buffers or in Prometheus.\n' "$ns" "$since"
  fi
  exit 0
fi

if [ "$cmd" = watch ]; then
  secs="${1:-90}"
  dir="$(mktemp -d)"; trap 'rm -rf "$dir"' EXIT
  pods="$(kubectl -n kube-system get pods -l k8s-app=cilium -o name)"
  printf 'watching AUDIT/DROPPED flows touching %s on %s node(s) for %ss — drive the traffic now\n' \
    "$ns" "$(printf '%s\n' "$pods" | wc -l | tr -d ' ')" "$secs" >&2
  for cp in $pods; do
    # timeout (uutils coreutils in the agent image) ends the stream; 124 is its normal exit.
    kubectl -n kube-system exec "$cp" -c cilium-agent -- \
      timeout "$secs" hubble observe --namespace "$ns" --verdict AUDIT --verdict DROPPED --follow -o json \
      >"$dir/${cp##*/}.json" 2>/dev/null &
  done
  wait
  cat "$dir"/*.json >"$dir/all"
  n="$(summarise "$dir/all")"
  if [ "$n" = 0 ]; then
    printf 'OK: no AUDIT or DROPPED flows touching %s during the %ss watch, on any node.\n' "$ns" "$secs"
    exit 0
  fi
  printf 'ATTENTION: %s distinct AUDIT/DROPPED flow(s) touching %s during the %ss watch (listed above).\n' "$n" "$ns" "$secs"
  exit 3
fi

[ "$#" -ge 1 ] || die "name at least one pod"
for pod in "$@"; do per_pod "$pod"; done
case "$cmd" in
  enable)  printf 'Audit mode ON for %s pod(s). It is lost on pod restart; every policy on these endpoints is advisory until disable.\n' "$#" ;;
  disable) printf 'Audit mode OFF for %s pod(s): realised policies now ENFORCE. Run: %s observe %s\n' "$#" "$0" "$ns" ;;
esac
