#!/usr/bin/env python3
"""Read-only acceptance of the held release controllers, before app promotion authority."""
import argparse
import json
import re
import subprocess


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=45)
    if result.returncode:
        raise RuntimeError(f'{args[0]} {args[1]} failed; response withheld')
    return result.stdout


def get(kind, name=None, namespace=None):
    args = ['kubectl'] + (['-n', namespace] if namespace else [])
    return json.loads(run(args + ['get', kind] + ([name] if name else []) + ['-o', 'json']))


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def permission(sa, verb, resource, scope, expected):
    result = subprocess.run(['kubectl', 'auth', 'can-i', verb, resource,
                             '--as=system:serviceaccount:kargo:' + sa, *scope],
                            capture_output=True, text=True, timeout=30)
    require(result.returncode in (0, 1) and result.stdout.strip() in ('yes', 'no'),
            'Authorization review did not return a decision')
    require((result.stdout.strip() == 'yes') == expected, f'Unexpected permission: {sa} {verb} {resource}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', required=True)
    args = parser.parse_args()
    require(re.fullmatch('[0-9a-f]{40}', args.revision), 'A full committed revision is required')
    require(run(['kubectl', 'config', 'current-context']).strip() == 'admin@homelab', 'Wrong Kubernetes context')
    require(any(x.startswith('Current context:') and x.split(':', 1)[1].strip() == 'homelab'
                for x in run(['talosctl', 'config', 'info']).splitlines()), 'Wrong Talos context')
    report = {'revision': args.revision, 'applications': {}, 'images': {}, 'crds': {}}
    for name in ['infra-kargo', 'infra-argo-rollouts', 'platform-authentik']:
        app = get('application', name, 'argocd')
        status = app.get('status', {})
        operation = status.get('operationState', {})
        require(not app.get('operation') and not status.get('conditions'), f'{name} is active or has conditions')
        require(status.get('sync', {}).get('status') == 'Synced'
                and status.get('sync', {}).get('revision') == args.revision
                and status.get('health', {}).get('status') == 'Healthy', f'{name} is not healthy at the requested revision')
        require(operation.get('phase') == 'Succeeded'
                and operation.get('syncResult', {}).get('revision') == args.revision
                and not operation.get('operation', {}).get('sync', {}).get('dryRun'), f'{name} actual sync is not proven')
        if name.startswith('infra-'):
            require(app['spec']['syncPolicy'].get('automated', {}).get('enabled') is False, 'Controller hold changed')
        report['applications'][name] = app['metadata']['uid']
    expected = {
        'kargo': ('ghcr.io/akuity/kargo@sha256:1413bdb63b1ad409c0a38a0ae5d6f4080e1fd3226aaf8344dfe0e5552921f533',
                  {'kargo-api', 'kargo-controller', 'kargo-management-controller', 'kargo-webhooks-server'}),
        'argo-rollouts': ('quay.io/argoproj/argo-rollouts@sha256:187630ba722846bb8e079630364d3c29c8246a256be95785fd957b088f621c4e', {'argo-rollouts'}),
    }
    for namespace, (digest, names) in expected.items():
        deployments = get('deployment', namespace=namespace)['items']
        require({d['metadata']['name'] for d in deployments} == names, 'Unexpected controller deployments')
        for deployment in deployments:
            require(deployment['status'].get('observedGeneration') == deployment['metadata']['generation']
                    and deployment['spec']['replicas'] == 1
                    and deployment['status'].get('updatedReplicas') == 1
                    and deployment['status'].get('readyReplicas') == 1, 'Controller rollout is incomplete')
        pods = [p for p in get('pods', namespace=namespace)['items'] if p['status'].get('phase') == 'Running']
        require(len(pods) == len(names), 'Unexpected running controller count')
        for pod in pods:
            states = pod['status'].get('containerStatuses', [])
            require(not pod['metadata'].get('deletionTimestamp') and len(states) == 1
                    and states[0]['ready'] and states[0]['imageID'] == digest, 'Controller image/readiness differs')
        report['images'][namespace] = digest
    crds = get('crd')['items']
    for group, count in [('kargo.akuity.io', 9), ('argoproj.io', 5)]:
        selected = [c for c in crds if c['spec']['group'] == group
                    and (group != 'argoproj.io' or c['metadata']['name'] in {
                        'analysisruns.argoproj.io', 'analysistemplates.argoproj.io',
                        'clusteranalysistemplates.argoproj.io', 'experiments.argoproj.io', 'rollouts.argoproj.io'})]
        require(len(selected) == count and all(any(c['type'] == 'Established' and c['status'] == 'True'
                for c in item['status'].get('conditions', [])) for item in selected), 'CRDs are not Established')
        report['crds'][group] = count
    certificate = get('certificate', 'kargo-webhooks-server', 'kargo')
    require(any(c['type'] == 'Ready' and c['status'] == 'True' for c in certificate['status']['conditions']), 'Webhook certificate not ready')
    route = get('httproute', 'kargo', 'kargo')
    require(any(all(any(c['type'] == t and c['status'] == 'True' for c in parent.get('conditions', []))
                    for t in ['Accepted', 'ResolvedRefs']) for parent in route['status'].get('parents', [])), 'Kargo route not accepted')
    analysis = get('analysisrun', 'controller-bootstrap-v1', 'argo-rollouts')
    require(analysis['status'].get('phase') == 'Successful'
            and len(analysis['status'].get('metricResults', [])) == 1
            and analysis['status']['metricResults'][0].get('successful') == 1, 'Synthetic analysis did not pass')
    def children(items, parent):
        return [x for x in items if any(r['uid'] == parent['metadata']['uid'] for r in x['metadata'].get('ownerReferences', []))]
    jobs = children(get('jobs', namespace='argo-rollouts')['items'], analysis)
    require(len(jobs) == 1 and jobs[0]['status'].get('succeeded') == 1, 'Synthetic job did not complete')
    pods = children(get('pods', namespace='argo-rollouts')['items'], jobs[0])
    require(len(pods) == 1, 'Unexpected synthetic pod count')
    pod = pods[0]
    spec = pod['spec']
    require(spec.get('automountServiceAccountToken') is False and spec['serviceAccountName'] == 'controller-bootstrap'
            and not spec.get('volumes') and all(not c.get('env') and not c.get('envFrom') and not c.get('volumeMounts')
                                              for c in spec['containers']), 'Synthetic pod has unexpected inputs')
    state = pod['status']['containerStatuses']
    require(len(state) == 1 and state[0]['state'].get('terminated', {}).get('exitCode') == 0
            and state[0]['imageID'] == 'docker.io/library/python@sha256:392307d22300de8b5986851a12d9176dfc0fc073e65bf6523ebd7dcbeb23564e', 'Synthetic image or exit differs')
    policies = get('ciliumnetworkpolicy', namespace='argo-rollouts')['items'] + get('networkpolicy', namespace='argo-rollouts')['items']
    labels = pod['metadata']['labels']
    def selector(policy):
        return policy['spec'].get('endpointSelector', policy['spec'].get('podSelector', {}))
    require(all('spec' in p and 'specs' not in p
                and not selector(p).get('matchExpressions') for p in policies),
            'Network policy shape requires explicit review')
    matching = [p for p in policies
                if all(labels.get(k.removeprefix('k8s:')) == v
                       for k, v in selector(p).get('matchLabels', {}).items())]
    require(any(p['metadata']['name'] == 'argo-rollouts-default-deny'
                and 'Egress' in p['spec'].get('policyTypes', []) for p in matching), 'Synthetic default deny is absent')
    require(not any(p['spec'].get('egress') for p in matching), 'Synthetic pod inherits unexpected egress')
    decisions = [
        ('kargo-user', 'list', 'projects.kargo.akuity.io', [], True),
        ('kargo-user', 'create', 'projects.kargo.akuity.io', [], False),
        ('kargo-user', 'promote', 'stages.kargo.akuity.io', ['-n', 'conversation-history-v2'], False),
        ('kargo-user', 'get', 'secrets', ['-n', 'conversation-history-v2'], False),
        ('kargo-controller', 'list', 'secrets', ['--all-namespaces'], False),
        ('kargo-controller', 'update', 'applications.argoproj.io', ['-n', 'argocd'], False),
    ]
    for decision in decisions:
        permission(*decision)
    report.update(synthetic_analysis=analysis['metadata']['uid'], synthetic_job=jobs[0]['metadata']['uid'],
                  no_token_or_mounts=True, namespaced_egress_denied=True, rbac_checks=len(decisions))
    print(json.dumps(report, sort_keys=True))


if __name__ == '__main__':
    try:
        main()
    except Exception as error:
        raise SystemExit(str(error) if isinstance(error, RuntimeError) else
                         f'Bootstrap verification failed ({type(error).__name__}); details withheld') from None
