#!/usr/bin/env bash
# check-app-entries-render.sh — an app-of-apps entry must deploy something, or
# say out loud that it does not.
#
# WHY
#
# Argo reports an Application whose source path renders zero resources as
# Synced / Healthy. Not degraded, not missing — green. Six entries in
# bootstrap/applicationsets/apps.yaml are in exactly that state today
# (frigate, knowledge-graph, personal-agent, website, whatsapp-bridge,
# windmill): the directory exists, has no kustomization.yaml, deploys nothing,
# and looks perfect.
#
# That is fine while they are deliberate placeholders. It is not fine as a
# failure mode, because a REAL app is indistinguishable from a placeholder the
# moment its path breaks — a repo rename, a moved manifest directory, a deleted
# kustomization.yaml. `kubectl get app` would keep saying Synced/Healthy and the
# workload would simply never exist. On a cold start that reads as "68/68 green,
# cluster complete" while some apps silently deploy nothing.
#
# THE RULE
#
# Every entry in apps.yaml must either:
#   a) resolve to a real kustomization.yaml, or
#   b) be declared in the workspace's planned-apps.md (ADR 0001 / CLAUDE.md:
#      "A directory that has not been published is declared in planned-apps.md,
#      never given a fake URL").
#
# Anything else is an entry that will be green and empty without anyone having
# said so. Offline: reads git, never the cluster, so it works during a rebuild.

set -euo pipefail

err()  { printf 'ERROR: %s\n' "$*" >&2; }
note() { printf '  %s\n' "$*"; }

K8S_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${WS:-$(cd "$K8S_ROOT/.." && pwd)}"
APPSET="${APPSET:-$K8S_ROOT/bootstrap/applicationsets/apps.yaml}"
PLANNED="${PLANNED:-$WS/planned-apps.md}"

[ -f "$APPSET" ] || { err "app-of-apps not found: $APPSET"; exit 1; }
command -v python3 >/dev/null 2>&1 || { err "python3 required"; exit 1; }

# Cross-repo by nature: 14 of the entries point at sibling app repositories.
# Without them every external entry would look unresolvable and the check would
# fail for the wrong reason, so say so rather than guess.
if [ ! -f "$PLANNED" ]; then
  err "planned-apps.md not found at $PLANNED"
  note "This check is workspace-level; set WS=/path/to/workspace."
  exit 1
fi

python3 - "$APPSET" "$WS" "$PLANNED" <<'PY'
import sys, pathlib, yaml, re

appset, ws, planned_f = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
planned = planned_f.read_text().lower()

els = []
for doc in yaml.safe_load_all(appset.read_text()):
    if not doc:
        continue
    for g in doc.get('spec', {}).get('generators', []) or []:
        els += (g.get('list', {}) or {}).get('elements', []) or []

real, declared, broken, uncheckable = [], [], [], []
for e in els:
    name, repo, path = e.get('name'), e.get('repo'), e.get('path')
    if not (name and repo and path):
        broken.append((name or '?', 'entry missing name/repo/path')); continue

    repo_dir = ws / repo
    target = repo_dir / path / 'kustomization.yaml'

    if target.exists():
        real.append(name)
    elif not repo_dir.is_dir():
        # Cannot judge: the sibling repo simply is not checked out here.
        uncheckable.append((name, f'{repo}/ not checked out'))
    elif re.search(rf'(?m)^.*\b{re.escape(name.lower())}\b', planned):
        declared.append(name)
    else:
        broken.append((name, f'no kustomization.yaml at {repo}/{path}, and not in planned-apps.md'))

print(f"  entries                     : {len(els)}")
print(f"  deploy real manifests       : {len(real)}")
print(f"  empty but DECLARED planned  : {len(declared)}" + (f"  ({', '.join(sorted(declared))})" if declared else ""))
print(f"  unjudgeable (repo absent)   : {len(uncheckable)}")
for n, why in uncheckable:
    print(f"      - {n}: {why}")
print(f"  SILENTLY EMPTY              : {len(broken)}")
for n, why in broken:
    print(f"      - {n}: {why}")

sys.exit(1 if broken else 0)
PY
rc=$?

echo
if [ "$rc" -ne 0 ]; then
  err "app-of-apps entries would render zero resources without being declared."
  note "Argo shows these as Synced/Healthy, so nothing else will ever tell you."
  note "Either point the entry at real manifests, or declare it in planned-apps.md."
  exit 1
fi
note "PASS: every app entry either deploys manifests or is a declared placeholder."
exit 0
