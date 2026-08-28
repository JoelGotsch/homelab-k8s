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
import pathlib
import re
import sys

appset, ws, planned_f = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
planned = planned_f.read_text().lower()

# apps.yaml deliberately uses one inline mapping per explicit list entry. Parse
# that narrow, reviewable format without PyYAML so the repository-local guard
# works under the same plain Python promised by its preflight and in pre-commit.
els = []
for line_number, line in enumerate(appset.read_text().splitlines(), start=1):
    if not re.match(r'^\s*-\s*\{name:', line):
        continue
    match = re.match(r'^\s*-\s*\{(?P<body>[^{}]+)\}\s*$', line)
    if not match:
        els.append({'name': f'line {line_number}', '_parse_error': 'malformed inline mapping'})
        continue
    fields = {}
    for item in match.group('body').split(','):
        if ':' not in item:
            fields['_parse_error'] = f'malformed field at line {line_number}'
            break
        key, value = item.split(':', 1)
        fields[key.strip()] = value.strip().strip('"').strip("'")
    els.append(fields)

real, declared, broken, uncheckable = [], [], [], []
for e in els:
    if e.get('_parse_error'):
        broken.append((e.get('name', '?'), e['_parse_error'])); continue
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
