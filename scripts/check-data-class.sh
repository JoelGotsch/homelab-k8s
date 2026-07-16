#!/usr/bin/env bash
# check-data-class.sh — every first-party Namespace must declare its data
# classification (ADR 0003 / ADR 0036 D3).
#
# THE INVARIANT: a first-party Namespace manifest
# (metadata.labels."homelab.internal/first-party" == "true") MUST also carry
# metadata.labels."homelab.internal/data-class" with one of the ADR 0003
# values: public | internal | personal | secret.
#
# WHY A LINT (CLAUDE.md rule 31 — ship every convention with its lint):
# data-class drives access posture (PSS, netpol) AND is the entry point for
# the backup decision (which volumes go offsite — see backup-and-dr.md +
# scripts/label-backup-volumes.sh). It is NOT enforced at admission by any
# Kyverno policy (verified 2026-07-16), and coverage is currently 100% only
# by review discipline. This shift-left guard keeps a new namespace from
# silently shipping without a classification — the exact gap ADR 0036 D3
# assumes is closed.
#
# NB: data-class is data SENSITIVITY (who may see it), a different axis from
# backup DURABILITY (whether a specific volume needs an offsite copy). A
# `personal` namespace still holds both unique data (backed up) and
# regenerable caches (not) — that per-volume decision lives in the Longhorn
# `backup` recurring-job group, not here.
#
# Requires: yq (mikefarah, v4+).
set -euo pipefail

cd "$(dirname "$0")/.."

command -v yq >/dev/null 2>&1 || { echo "FAIL: yq not on PATH (mikefarah v4+)"; exit 1; }
yq --version 2>&1 | grep -q 'mikefarah\|version v[4-9]' \
  || { echo "FAIL: wrong yq variant: $(yq --version 2>&1 | head -1)"; exit 1; }

VALID='public internal personal secret'
fail=0
checked=0

# Every manifest that declares a Namespace. Search the reconciled trees only.
while IFS= read -r f; do
  # A file may hold multiple docs; handle each Namespace doc.
  n_docs="$(yq ea '[select(.kind=="Namespace")] | length' "$f" 2>/dev/null || echo 0)"
  [ "${n_docs:-0}" -gt 0 ] || continue

  # iterate namespace docs by index
  i=0
  while [ "$i" -lt "$n_docs" ]; do
    name="$(yq ea "[select(.kind==\"Namespace\")] | .[$i].metadata.name" "$f" 2>/dev/null)"
    fp="$(yq ea "[select(.kind==\"Namespace\")] | .[$i].metadata.labels.\"homelab.internal/first-party\"" "$f" 2>/dev/null)"
    dc="$(yq ea "[select(.kind==\"Namespace\")] | .[$i].metadata.labels.\"homelab.internal/data-class\"" "$f" 2>/dev/null)"
    i=$((i + 1))

    # Only first-party namespaces are in scope (upstream/operator ns are exempt).
    [ "$fp" = "true" ] || continue
    checked=$((checked + 1))

    if [ "$dc" = "null" ] || [ -z "$dc" ]; then
      echo "FAIL: $f — namespace '$name' is first-party but has no homelab.internal/data-class"
      fail=1
      continue
    fi
    case " $VALID " in
      *" $dc "*) ;;
      *) echo "FAIL: $f — namespace '$name' has invalid data-class '$dc' (want: $VALID)"; fail=1 ;;
    esac
  done
done < <(grep -rl "kind: Namespace" --include="*.yaml" apps/ infrastructure/ platform/ observability/ 2>/dev/null | grep -v '/charts/')

if [ "$fail" -eq 0 ]; then
  echo "OK: $checked first-party namespace(s) declare a valid data-class"
fi
exit "$fail"
