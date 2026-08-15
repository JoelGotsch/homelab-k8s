#!/usr/bin/env bash
# sync-longhorn-recurring-job-labels.sh — make Longhorn Volumes carry the
# recurring-job groups their PVCs declare.
#
# WHY THIS EXISTS
#
# Longhorn selects volumes for a RecurringJob by labels on the **Volume** CR,
# not on the PVC. Two things then have to be true for a declared group to take
# effect, and for most of this cluster's volumes only the first is:
#
#   1. the PVC declares `recurring-job-group.longhorn.io/<group>: enabled`
#      — that lives in git, and is what an operator reads and believes;
#   2. something copies it onto the Volume CR.
#
# For (2) this cluster uses the Kyverno `longhorn-volume-label-propagation`
# ClusterPolicy, which mutates Volumes on CREATE/UPDATE. It deliberately does
# NOT use Longhorn's native PVC->Volume sync, because enabling that
# (`recurring-job.longhorn.io/source: enabled` on the PVC) makes Longhorn treat
# the PVC as authoritative and strip the `backup` group that
# scripts/label-backup-volumes.sh applies straight to the Volume — i.e. it
# would silently drop volumes out of the OFFSITE lane to fix a snapshot lane.
#
# The gap is volumes that already existed when their PVC label was added. No
# Volume update fires, so the mutation never runs and the volume keeps
# Longhorn's catch-all `default` group. Measured 2026-08-15 across all 69
# volumes: exactly ONE matched its PVC. `snapshot-internal`,
# `snapshot-internal-media` and `snapshot-secret-personal` therefore applied to
# no volume at all, while every one of those volumes sat on `default`
# (hourly, retain 6).
#
# Root-caused 2026-07-25 (see homelab-docs TODO.md). The documented remedy was
# "touch the ClusterPolicy, or hand-label the volume" — fine for two
# stragglers, wrong shape for sixty. This script is the sweep, and re-running
# it is how you check the state later.
#
# ADD-ONLY, DELIBERATELY
#
# It never removes a label. The `backup` group is applied to Volume CRs by a
# different path (label-backup-volumes.sh) and is not represented on the PVC at
# all, so "make the Volume match the PVC exactly" would delete offsite backup
# membership. That is the single most dangerous thing this script could do, so
# it cannot: it only adds what the PVC declares and is missing.
#
# ONE EXCEPTION: `default` is removed when a named group is added.
#
# Longhorn writes `recurring-job-group.longhorn.io/default: enabled` onto a
# volume that belongs to no group. It does NOT take it off again when one is
# added — verified 2026-08-15 by adding `internal-media` to jellyfin-config's
# volume and watching for two minutes: both labels persisted. (The one volume
# on Longhorn's native PVC->Volume sync has no `default` label, which is what
# made the opposite look true.)
#
# Left in place, a swept volume would sit in BOTH schedules — e.g. hourly
# retain-6 AND daily retain-7 — which is more snapshots than either lane
# intends and the opposite of the point. So `default` is dropped, and only
# when the volume is gaining a real group. Nothing else is ever removed.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }

APPLY=false
case "${1:-}" in
  --apply) APPLY=true ;;
  --dry-run|"") APPLY=false ;;
  -h|--help)
    cat >&2 <<EOF
usage: $0 [--dry-run | --apply] [volume-name ...]

  --dry-run   (default) report what would change, touch nothing
  --apply     add the missing labels

With volume names, acts only on those volumes — use it for a first,
small-blast-radius apply before sweeping everything.
EOF
    exit 2 ;;
esac
shift || true
ONLY=("$@")

for tool in kubectl python3; do
  command -v "$tool" >/dev/null 2>&1 || { err "required tool missing: $tool"; exit 1; }
done
kubectl version --request-timeout=15s >/dev/null 2>&1 \
  || { err "cannot reach the cluster. Set KUBECONFIG and try again."; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/lh-rj.XXXXXX")"
trap 'rm -rf "$work"' EXIT

kubectl -n longhorn-system get volume -o json > "$work/volumes.json"
kubectl get pv -o json                        > "$work/pvs.json"
kubectl get pvc -A -o json                    > "$work/pvcs.json"

# Resolution chain, identical to the Kyverno policy's:
#   Volume.metadata.name == PV.metadata.name -> PV.spec.claimRef -> PVC
python3 - "$work" "${ONLY[@]:-}" <<'PY' > "$work/plan.tsv"
import json, sys
work = sys.argv[1]
only = {a for a in sys.argv[2:] if a}

vols = json.load(open(f"{work}/volumes.json"))["items"]
pvs  = {p["metadata"]["name"]: p for p in json.load(open(f"{work}/pvs.json"))["items"]}
pvcs = {(p["metadata"]["namespace"], p["metadata"]["name"]): p
        for p in json.load(open(f"{work}/pvcs.json"))["items"]}

PREFIXES = ("recurring-job-group.longhorn.io/", "recurring-job.longhorn.io/")
# `recurring-job.longhorn.io/source` is a CONTROL label on the PVC — it opts
# that PVC into Longhorn's native PVC->Volume sync. On a Volume the same prefix
# means "assign the recurring job named <suffix>", so copying it across would
# assert a job called "source", which does not exist. Excluded deliberately.
#
# NOTE: the Kyverno longhorn-volume-label-propagation policy filters on the
# same two prefixes and does NOT make this exclusion, so it would copy `source`
# onto the Volume for any PVC that carries it (today: librechat-mongodump).
# Worth fixing there too.
CONTROL = ("recurring-job.longhorn.io/source",)
def rj(labels):
    return {k: v for k, v in (labels or {}).items()
            if k.startswith(PREFIXES) and k not in CONTROL}

for v in sorted(vols, key=lambda x: x["metadata"]["name"]):
    name = v["metadata"]["name"]
    if only and name not in only:
        continue
    actual = v.get("status", {}).get("actualSize", 0) or 0
    pv = pvs.get(name)
    if not pv:
        print(f"{name}\t-\tNO-PV\t\t\t{actual}")
        continue
    ref = (pv.get("spec", {}) or {}).get("claimRef") or {}
    ns, pn = ref.get("namespace"), ref.get("name")
    pvc = pvcs.get((ns, pn))
    if not pvc:
        print(f"{name}\t{ns}/{pn}\tNO-PVC\t\t\t{actual}")
        continue
    want = rj(pvc["metadata"].get("labels"))
    have = rj(v["metadata"].get("labels"))
    missing = {k: val for k, val in want.items() if have.get(k) != val}
    DEFAULT = "recurring-job-group.longhorn.io/default"
    missing.pop(DEFAULT, None)
    # Drop Longhorn's catch-all once the volume belongs to a real group —
    # whether that group is arriving now or was already there. Keying this on
    # "a label is being added" alone would leave `default` behind on any volume
    # swept earlier, which is a volume quietly in two schedules.
    final_groups = ({k for k in have} | set(missing)) - {DEFAULT}
    drop_default = DEFAULT in have and bool(final_groups)
    status = "ADD" if (missing or drop_default) else "ok"
    fmt = lambda d: ",".join(sorted(k.split("/")[-1] for k in d)) or "-"
    print(f"{name}\t{ns}/{pn}\t{status}\t{fmt(have)}\t{fmt(missing)}"
          + ("+drop:default" if drop_default else "")
          + f"\t{actual}\t" + json.dumps(missing) + "\t" + ("yes" if drop_default else ""))
PY

printf '%-46s %-40s %-6s %-22s %-16s %s\n' VOLUME PVC ACTION "HAS (volume)" "WILL ADD" ACTUAL
adds=0; oks=0; broken=0; addbytes=0
while IFS=$'\t' read -r vol pvc status have missing actual patch drop_default; do
  case "$status" in
    ADD)
      printf '%-46s %-40s %-6s %-22s %-16s %.2fGi\n' "${vol:0:46}" "${pvc:0:40}" "$status" "$have" "$missing" "$(echo "$actual" | awk '{print $1/1073741824}')"
      adds=$((adds+1)); addbytes=$((addbytes+actual))
      if [ "$APPLY" = true ]; then
        # One label per kubectl call keeps the failure attributable.
        echo "$patch" | python3 -c "
import json,sys
for k,v in json.load(sys.stdin).items(): print(f'{k}={v}')" | while IFS= read -r kv; do
          kubectl -n longhorn-system label volume "$vol" "$kv" --overwrite >/dev/null \
            && printf '    applied %s\n' "$kv" \
            || { err "failed to label $vol with $kv"; exit 1; }
        done
        if [ "$drop_default" = yes ]; then
          kubectl -n longhorn-system label volume "$vol" \
            'recurring-job-group.longhorn.io/default-' >/dev/null \
            && printf '    removed recurring-job-group.longhorn.io/default\n' \
            || err "failed to drop default from $vol"
        fi
      fi
      ;;
    ok) oks=$((oks+1)) ;;
    NO-PV|NO-PVC)
      printf '%-46s %-40s %-6s %s\n' "${vol:0:46}" "${pvc:0:40}" "$status" "(unbound or orphaned — skipped)"
      broken=$((broken+1)) ;;
  esac
done < "$work/plan.tsv"

echo
echo "── state"
echo "   already correct : $oks"
echo "   need labels     : $adds  (holding $(echo $addbytes | awk '{printf "%.1f", $1/1073741824}')Gi of actual data)"
echo "   unresolvable    : $broken"
if [ "$APPLY" = true ]; then
  echo "   MODE            : APPLIED"
  echo
  echo "Re-run without --apply to confirm 'need labels: 0'."
else
  echo "   MODE            : dry-run — nothing was changed. Re-run with --apply."
fi
exit 0
