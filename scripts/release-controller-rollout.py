#!/usr/bin/env python3
"""Bounded, exact-revision Argo operations for the two release controllers only."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
REPO = 'https://forgejo.lab.vyramo.com/homelab/homelab-k8s'


def run(argv, *, data=None, env=None):
    result = subprocess.run(argv, input=data, env=env, cwd=ROOT, capture_output=True,
                            text=True, timeout=90)
    if result.returncode:
        # Neither application operations nor admission responses are raw log output.
        # Return only a diagnostic class; operator inspects private details separately.
        raise RuntimeError(f'{argv[0]} {argv[1]} failed (exit {result.returncode}); output withheld')
    return result.stdout


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('controller', choices=['argo-rollouts', 'kargo'])
    p.add_argument('action', choices=['status', 'preflight', 'sync'])
    p.add_argument('--revision', required=True)
    p.add_argument('--phase', choices=['namespace', 'crds', 'all'], default='all')
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--apply', action='store_true')
    a = p.parse_args()
    if not re.fullmatch('[0-9a-f]{40}', a.revision):
        p.error('a full committed SHA is required')
    if run(['kubectl', 'config', 'current-context']).strip() != 'admin@homelab':
        raise RuntimeError('Wrong Kubernetes context')
    if not any(line.startswith('Current context:') and line.split(':', 1)[1].strip() == 'homelab'
               for line in run(['talosctl', 'config', 'info']).splitlines()):
        raise RuntimeError('Wrong Talos context')
    with tempfile.TemporaryDirectory(prefix='release-controllers-') as tmp:
        config = Path(tmp) / 'config'
        config.touch(mode=0o600)
        config.write_text(run(['kubectl', 'config', 'view', '--raw', '--minify']))
        env = {**os.environ, 'KUBECONFIG': str(config)}
        run(['kubectl', 'config', 'set-context', '--current', '--namespace=argocd'], env=env)
        command = ['argocd', '--core', 'app']
        app = 'infra-' + a.controller
        live = json.loads(run([*command, 'get', app, '--hard-refresh', '-o', 'json'], env=env))
        spec = live['spec']
        if (spec['source'] != {'repoURL': REPO, 'path': 'infrastructure/' + a.controller,
                              'targetRevision': 'main'}
                or spec['syncPolicy'].get('automated', {}).get('enabled') is not False
                or 'ServerSideApply=true' not in spec['syncPolicy'].get('syncOptions', [])):
            raise RuntimeError('Application identity, manual hold or SSA policy differs')
        state = live.get('status', {})
        op = state.get('operationState', {})
        evidence = {'application': app, 'uid': live['metadata']['uid'],
                    'revision': state.get('sync', {}).get('revision'),
                    'sync': state.get('sync', {}).get('status'),
                    'health': state.get('health', {}).get('status'),
                    'phase': op.get('phase'),
                    'operation_revision': op.get('syncResult', {}).get('revision'),
                    'dry_run': op.get('operation', {}).get('sync', {}).get('dryRun', False),
                    'active': bool(live.get('operation')),
                    'condition_types': [x['type'] for x in state.get('conditions', [])]}
        print(json.dumps(evidence))
        if a.action == 'status':
            return
        if live.get('operation'):
            raise RuntimeError('An Argo operation is active; observe it before continuing')
        if run(['git', 'rev-parse', 'HEAD']).strip() != a.revision or run(['git', 'status', '--porcelain']).strip():
            raise RuntimeError('Checkout must be clean at the exact intended revision')
        remote = run(['git', 'ls-remote', 'forgejo', 'refs/heads/main']).split()[0]
        if remote != a.revision or evidence['revision'] != a.revision:
            raise RuntimeError('Published main and Argo comparison must match the intended revision')
        docs = [x for x in yaml.safe_load_all(run(['kustomize', 'build', '--enable-helm',
                                                 'infrastructure/' + a.controller])) if x]
        if any(x['kind'] == 'Secret' and (x.get('data') or x.get('stringData')) for x in docs):
            raise RuntimeError('Controller render contains inline credentials')
        selected = [x for x in docs if a.phase == 'all' or
                    x['kind'] == {'namespace': 'Namespace', 'crds': 'CustomResourceDefinition'}[a.phase]]
        if not selected:
            raise RuntimeError('Selected phase is empty')
        if a.action == 'preflight':
            appset = json.loads(run(['kubectl', '-n', 'argocd', 'get', 'applicationset',
                                     'infrastructure', '-o', 'json', '--show-managed-fields']))
            if not any(x['manager'] == 'argocd-controller' and x['operation'] == 'Apply'
                       for x in appset['metadata'].get('managedFields', [])):
                raise RuntimeError('Expected Argo SSA manager is not observed')
            run(['kubectl', 'apply', '--server-side', '--field-manager=argocd-controller',
                 '--dry-run=server', '-f', '-', '-o', 'name'], data=yaml.safe_dump_all(selected))
            print(json.dumps({'server_dry_run': 'passed', 'resources': len(selected), 'phase': a.phase}))
            return
        if not a.apply:
            raise RuntimeError('Sync requires explicit --apply, including an Argo dry-run operation')
        # Real sync must immediately follow a successful matching Argo dry-run.
        prior = op.get('operation', {}).get('sync', {})
        want = [] if a.phase == 'all' else [
            {'group': x['apiVersion'].split('/')[0] if '/' in x['apiVersion'] else '',
             'kind': x['kind'], 'name': x['metadata']['name']} for x in selected]
        actual = [{k: x.get(k, '') for k in ['group', 'kind', 'name']}
                  for x in prior.get('resources', [])]
        sortkey = lambda x: (x['group'], x['kind'], x['name'])
        if not a.dry_run and not (op.get('phase') == 'Succeeded' and prior.get('dryRun') is True
                                 and op.get('syncResult', {}).get('revision') == a.revision
                                 and sorted(actual, key=sortkey) == sorted(want, key=sortkey)):
            raise RuntimeError('A successful exact-revision, exact-resource Argo dry-run is required')
        args = [*command, 'sync', app, '--revision', a.revision, '--async']
        for x in want:
            args += ['--resource', f"{x['group']}:{x['kind']}:{x['name']}"]
        if a.dry_run:
            args.append('--dry-run')
        run(args, env=env)
        print(json.dumps({'submitted': True, 'dry_run': a.dry_run, 'phase': a.phase}))


if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        raise SystemExit(str(exc) if isinstance(exc, RuntimeError) else
                         f'Controller operation failed ({type(exc).__name__}); details withheld') from None
