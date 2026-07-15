#!/usr/bin/env bash
# check-cnpg-netpol.sh — guard against the llm-gateway CNPG-outage class.
#
# THE BUG CLASS (2026-06→07, twice): a namespace running a CloudNativePG
# cluster gets a namespace-wide EGRESS default-deny, but the policy that
# selects the DB pods only grants INGRESS — so the instance manager can't
# reach the kube-apiserver (`dial tcp 10.96.0.1:443: i/o timeout` in
# wait-for-get-cluster), DNS, MinIO (barman WAL), or its replication peer.
# The cluster clears bootstrap on pods that predate the policy but any
# restart CrashLoopBackOffs. This is the "missing half of CLAUDE.md rule
# 14" that hit llm-gateway (ingress-only, 2026-06-29) and stalled it 1/2.
#
# THE INVARIANT this enforces (per netpol-best-practices.md checklist E):
#   For every namespace that ships a CNPG `Cluster` AND an egress
#   default-deny, its networkpolicy.yaml MUST grant the DB pods egress to:
#     - kube-apiserver (Cilium entity) on 443 AND 6443  (socket-LB
#       translates ClusterIP:443 -> backend:6443 before policy eval)
#     - kube-dns (port 53)
#     - MinIO object store (port 9000) for WAL/base-backup archiving
#     - the replication peer (cnpg.io/cluster pods) on 5432
#
# Namespaces whose DB pods run in Cilium default-allow (no egress
# default-deny) are intentionally NOT flagged here — that is a separate
# posture decision (netpol-audit.md MEDIUM-2), not an outage. This check
# only fires once a namespace opts into egress default-deny, which is
# exactly when the rule set becomes mandatory.
#
# Heuristic, not a full policy simulator: it confirms the required
# tokens are present in the namespace's networkpolicy.yaml. That is
# sufficient to catch the real failure (llm-gateway had NONE of them) and
# cheap enough to run in pre-commit.
#
# Requires: yq (mikefarah, v4+).

set -euo pipefail

cd "$(dirname "$0")/.."

command -v yq >/dev/null 2>&1 || { echo "FAIL: yq not on PATH (mikefarah v4+)"; exit 1; }
yq --version 2>&1 | grep -q 'mikefarah\|version v[4-9]' \
  || { echo "FAIL: wrong yq variant: $(yq --version 2>&1 | head -1)"; exit 1; }

fail=0
checked=0

# Every dir that ships a CNPG cluster manifest.
while IFS= read -r cluster; do
  dir="$(dirname "$cluster")"
  # skip overlay/restore-drill variants — they render under the parent ns
  case "$dir" in *overlays*) continue ;; esac
  np="$dir/networkpolicy.yaml"
  if [ ! -f "$np" ]; then
    echo "WARN: $dir ships a CNPG Cluster but has no networkpolicy.yaml"
    continue
  fi

  # Does this namespace declare an EGRESS default-deny? (native NP with an
  # empty podSelector + Egress policyType, OR a CNP with an empty
  # endpointSelector that carries an egress block.)
  dd="$(yq ea '[
      select(.kind=="NetworkPolicy"
             and (.spec.podSelector | length == 0)
             and (.spec.policyTypes // [] | contains(["Egress"]))),
      select(.kind=="CiliumNetworkPolicy"
             and (.spec.endpointSelector | length == 0)
             and (.spec.egress))
    ] | length' "$np" 2>/dev/null || echo 0)"
  [ "${dd:-0}" -gt 0 ] || continue   # default-allow ns — not this check's concern

  checked=$((checked + 1))
  miss=""
  grep -q "kube-apiserver"       "$np" || miss="$miss apiserver-entity"
  grep -Eq '(^|[^0-9])6443([^0-9]|$)' "$np" || miss="$miss apiserver-6443"
  grep -q "kube-dns"             "$np" || miss="$miss kube-dns"
  grep -Eq '(^|[^0-9])9000([^0-9]|$)' "$np" || miss="$miss minio-9000"
  # Replication (peer DB pod on 5432) is satisfied EITHER by an explicit
  # cnpg.io/cluster peer rule on 5432 (least-privilege; llm-gateway) OR by
  # a same-namespace allow-all egress (podSelector {} -> podSelector {};
  # immich/paperless get replication for free that way). Accept both.
  peer_ok=0
  if grep -q "cnpg.io/cluster" "$np" && grep -Eq '(^|[^0-9])5432([^0-9]|$)' "$np"; then
    peer_ok=1
  fi
  samens="$(yq ea '[select(.kind=="NetworkPolicy"
                and (.spec.podSelector | length == 0)
                and (.spec.egress[]?.to[]? | has("podSelector")))] | length' "$np" 2>/dev/null || echo 0)"
  [ "${samens:-0}" -gt 0 ] && peer_ok=1
  [ "$peer_ok" -eq 1 ] || miss="$miss peer-5432"

  if [ -n "$miss" ]; then
    echo "FAIL: $dir has an egress default-deny but its CNPG egress is missing:$miss"
    echo "      -> model on apps/paperless/networkpolicy.yaml (the correct template)."
    fail=1
  fi
done < <(grep -rl "postgresql.cnpg.io" --include='cnpg-cluster*.yaml' apps platform observability 2>/dev/null)

if [ "$fail" -eq 0 ]; then
  echo "OK: $checked CNPG namespace(s) with an egress default-deny carry the full DB egress rule set."
fi
exit "$fail"
