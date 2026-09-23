#!/usr/bin/env python3
"""Require a namespace-and-role peer for Tridata original-file clients."""
import copy
from pathlib import Path
import sys

import yaml


def require(condition, message):
    if not condition:
        raise ValueError(message)


def check(documents):
    policy = next(d for d in documents if d and d.get('metadata', {}).get('name') == 'minio-allow')
    rules = [r for r in policy['spec']['ingress'] if any(
        p.get('namespaceSelector', {}).get('matchLabels', {}).get('kubernetes.io/metadata.name') == 'tridata-staging'
        for p in r.get('from', [])
    )]
    require(len(rules) == 1, 'Expected one Tridata MinIO ingress rule')
    rule = rules[0]
    require(rule['ports'] == [{'port': 9000, 'protocol': 'TCP'}], 'Tridata may only reach the S3 port')
    require(len(rule['from']) == 1, 'Namespace and pod selectors must be in one peer (AND)')
    peer = rule['from'][0]
    expressions = peer.get('podSelector', {}).get('matchExpressions', [])
    require(len(expressions) == 1, 'Tridata ingress must select named pod roles')
    expression = expressions[0]
    require(expression['key'] == 'app.kubernetes.io/name' and expression['operator'] == 'In', 'Invalid role selector')
    require(set(expression['values']) == {'tridata-api', 'tridata-worker'}, 'Unexpected object-store client role')


root = Path(__file__).resolve().parents[1]
documents = list(yaml.safe_load_all((root / 'infrastructure/minio-on-nas/networkpolicy.yaml').read_text()))
check(documents)
if '--self-test' in sys.argv:
    for mode in ('namespace_only', 'split_peers', 'web_role', 'console_port'):
        broken = copy.deepcopy(documents)
        policy = next(d for d in broken if d and d.get('metadata', {}).get('name') == 'minio-allow')
        rule = next(r for r in policy['spec']['ingress'] if any(
            p.get('namespaceSelector', {}).get('matchLabels', {}).get('kubernetes.io/metadata.name') == 'tridata-staging'
            for p in r.get('from', [])
        ))
        peer = rule['from'][0]
        if mode == 'namespace_only': del peer['podSelector']
        elif mode == 'split_peers': rule['from'].append({'podSelector': peer.pop('podSelector')})
        elif mode == 'web_role': peer['podSelector']['matchExpressions'][0]['values'].append('tridata-web')
        else: rule['ports'][0]['port'] = 9001
        try:
            check(broken)
        except ValueError:
            continue
        raise SystemExit('Mutation was accepted: ' + mode)
print('Tridata MinIO ingress scope passed')
