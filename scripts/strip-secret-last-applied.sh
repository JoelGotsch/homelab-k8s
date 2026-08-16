#!/usr/bin/env bash
# strip-secret-last-applied.sh — no Secret should carry its own payload in an
# annotation.
#
# WHY
#
# Client-side `kubectl apply` records the ENTIRE object it applied in
# `kubectl.kubernetes.io/last-applied-configuration`, so for a Secret the key
# material is written twice: once in `data` (which everyone treats as
# sensitive) and once in an annotation (which almost nobody does). Anything
# that reads "just the metadata" reads the secret:
#
#   kubectl get secret X -o yaml          shows it
#   kubectl get secret X -o jsonpath='{.metadata.annotations}'  shows it
#   an object-level backup or a support dump  carries it
#
# That is not theoretical here. On 2026-08-15 an operator-facing transcript
# captured the OpenBao server TLS private key because a command asked for
# `.metadata.annotations` on `openbao-tls` — a request that looks entirely
# harmless. The key was rotated on 2026-08-16 (it was also 5 days from expiry);
# this script exists so the next one cannot happen the same way.
#
# Measured 2026-08-16: 37 Secrets carried the annotation, 35 of them
# duplicating key material — restic-tier-3-password, vaultwarden-admin,
# authentik-bootstrap, the CNPG S3 credentials, and more.
#
# WHY IT IS SAFE
#
# The annotation is client-side-apply bookkeeping and nothing else. It is not
# read by the workload, by ESO, or by Argo — Argo applies server-side
# (ServerSideApply=true), which uses managedFields instead and never writes
# this annotation. Removing it changes no Secret `data`.
#
# The one real consequence: a future CLIENT-SIDE `kubectl apply` against a
# stripped Secret does a full replace rather than a three-way merge. For these
# Secrets that is fine — they are owned by ESO, by Argo, or by a bootstrap
# script that applies the whole object anyway.
#
# These are bootstrap-era residue. If one reappears, something is applying a
# Secret client-side; fix that rather than re-running this on a schedule.

set -euo pipefail

err() { printf 'ERROR: %s\n' "$*" >&2; }

APPLY=false
case "${1:-}" in
  --apply) APPLY=true ;;
  --dry-run|"") APPLY=false ;;
  -h|--help)
    echo "usage: $0 [--dry-run | --apply]" >&2
    echo "  --dry-run  (default) list affected Secrets, change nothing" >&2
    echo "  --apply    remove the annotation" >&2
    exit 2 ;;
  *) err "unknown argument: $1"; exit 2 ;;
esac

for tool in kubectl python3; do
  command -v "$tool" >/dev/null 2>&1 || { err "required tool missing: $tool"; exit 1; }
done
kubectl version --request-timeout=15s >/dev/null 2>&1 \
  || { err "cannot reach the cluster. Set KUBECONFIG and try again."; exit 1; }

ANNOTATION='kubectl.kubernetes.io/last-applied-configuration'

# Report whether key material is duplicated, never the material itself.
kubectl get secret -A -o json | python3 -c "
import json, sys
ann = 'kubectl.kubernetes.io/last-applied-configuration'
for s in json.load(sys.stdin)['items']:
    a = s['metadata'].get('annotations') or {}
    if ann not in a:
        continue
    blob = a[ann]
    risky = any(k in blob for k in ('tls.key', 'password', 'token', 'privateKey', '\"key\"', 'secret'))
    print(f\"{s['metadata']['namespace']}\t{s['metadata']['name']}\t{'KEY-MATERIAL' if risky else 'metadata-only'}\t{len(blob)}\")
" > /tmp/.slaa.$$ || { err "failed to enumerate secrets"; exit 1; }
trap 'rm -f /tmp/.slaa.$$' EXIT

total=0; risky=0; stripped=0
printf '%-26s %-46s %-14s %s\n' NAMESPACE SECRET CONTENT BYTES
while IFS=$'\t' read -r ns name kind size; do
  [ -n "$ns" ] || continue
  total=$((total + 1))
  [ "$kind" = "KEY-MATERIAL" ] && risky=$((risky + 1))
  printf '%-26s %-46s %-14s %s\n' "$ns" "${name:0:46}" "$kind" "$size"
  if [ "$APPLY" = true ]; then
    if kubectl -n "$ns" annotate secret "$name" "${ANNOTATION}-" >/dev/null 2>&1; then
      stripped=$((stripped + 1))
    else
      err "failed to strip $ns/$name"
    fi
  fi
done < /tmp/.slaa.$$

echo
echo "── state"
echo "   secrets carrying the annotation : $total"
echo "   of those, duplicating key material: $risky"
if [ "$APPLY" = true ]; then
  echo "   stripped                        : $stripped"
  echo
  echo "Re-run without --apply to confirm the count is 0."
else
  echo "   MODE                            : dry-run — nothing changed."
fi
[ "$APPLY" = false ] && [ "$total" -gt 0 ] && exit 1
exit 0
