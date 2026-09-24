#!/usr/bin/env python3
"""Exercise the actual offline projection against isolated Kustomize fixtures."""
import ast
import copy
from pathlib import Path
import unittest

import yaml

script = Path(__file__).with_name('check-storage-budget.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]
tree = ast.parse(script)
# Import definitions without running the CLI or reading the workspace/cluster.
constants = {'LOADER', 'KUSTOMIZATION', 'STORAGE_KINDS', 'STORAGE_TOKENS', 'KIND_LINE', 'ABSENT'}
nodes = [n for n in tree.body if isinstance(n, (ast.Import, ast.ImportFrom, ast.FunctionDef, ast.ClassDef))
         or (isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id in constants for t in n.targets))]
module = {}
exec(compile(ast.Module(body=nodes, type_ignores=[]), '<storage-budget-definitions>', 'exec'), module)
Projection = module['Projection']


class View:
    repo, label = 'app', 'fixture'

    def __init__(self, files):
        self.files = {p: yaml.safe_dump(v).encode() for p, v in files.items()}

    def isfile(self, p):
        return p in self.files

    def isdir(self, p):
        return any(f.startswith(p + '/') for f in self.files)

    def read(self, p):
        return self.files[p]


class StoragePatchTest(unittest.TestCase):
    def setUp(self):
        self.cluster = {'apiVersion': 'postgresql.cnpg.io/v1', 'kind': 'Cluster',
                        'metadata': {'name': 'tridata-pg', 'namespace': 'staging'},
                        'spec': {'instances': 1, 'storage': {'size': '5Gi', 'storageClass': 'longhorn'}}}
        self.patch = {'target': {'kind': 'Cluster', 'name': 'tridata-pg'},
                      'patch': yaml.safe_dump([{'op': 'replace', 'path': '/spec/storage/size', 'value': '40Gi'},
                                              {'op': 'add', 'path': '/spec/resources',
                                               'value': {'requests': {'memory': '1Gi'}}}])}
        self.files = {'k8s/cluster.yaml': self.cluster,
                      'k8s/kustomization.yaml': {'resources': ['cluster.yaml'], 'namespace': 'staging'},
                      'k8s-public/kustomization.yaml': {'resources': ['../k8s'], 'namespace': 'public',
                                                       'patches': [self.patch]}}

    def project(self, layer='k8s-public'):
        projection = Projection('index', {})
        acc = {'docs': [], 'charts': [], 'replicas': {}}
        view = View(self.files)
        projection.build(view, layer, None, 0, acc)
        projection.manifest_claims(view, layer, acc)
        return projection, acc

    def test_public_40gi_and_staging_5gi_are_isolated(self):
        public, acc = self.project()
        staging, _ = self.project('k8s')
        self.assertEqual(public.problems + staging.problems, [])
        self.assertEqual([(c['size'], c['ns']) for c in public.claims], [('40Gi', 'public')])
        self.assertEqual([(c['size'], c['ns']) for c in staging.claims], [('5Gi', 'staging')])
        self.assertEqual(acc['docs'][0][0]['spec']['resources']['requests']['memory'], '1Gi')
        self.assertEqual(self.cluster['spec']['storage']['size'], '5Gi')

    def test_file_based_legacy_json6902_patch(self):
        self.files['k8s-public/size.yaml'] = yaml.safe_load(self.patch['patch'])
        kz = self.files['k8s-public/kustomization.yaml']
        kz['patchesJson6902'] = [{'target': dict(self.patch['target'], group='postgresql.cnpg.io', version='v1'),
                                 'path': 'size.yaml'}]
        del kz['patches']
        projection, _ = self.project()
        self.assertEqual(projection.problems, [])
        self.assertEqual(projection.claims[0]['size'], '40Gi')

    def test_failed_or_unknown_operations_fail_without_partial_mutation(self):
        for op in [{'op': 'remove', 'path': '/spec/storage'},
                   {'op': 'move', 'path': '/spec/storage/size', 'from': '/spec/instances'},
                   {'op': 'replace', 'path': '/spec/storage/missing', 'value': '1Gi'},
                   {'op': 'replace', 'path': '/spec/missing/size', 'value': '1Gi'},
                   {'op': 'test', 'path': '/spec/storage/size', 'value': 'wrong'},
                   {'op': 'replace', 'path': '/spec/storage/~2', 'value': '1Gi'}]:
            with self.subTest(op=op):
                self.patch['patch'] = yaml.safe_dump([
                    {'op': 'replace', 'path': '/spec/storage/size', 'value': '40Gi'}, op])
                projection, _ = self.project()
                self.assertTrue(projection.problems)
                self.assertEqual(projection.claims[0]['size'], '5Gi')

    def test_unknown_selectors_and_unmatched_targets_fail(self):
        for target in [{'kind': 'Cluster', 'name': 'missing'}, {'kind': 'Cluster', 'name': 'tridata-.*'},
                       {'kind': 'Cluster'}, dict(self.patch['target'], namespace='public'),
                       dict(self.patch['target'], labelSelector='app=tridata'),
                       dict(self.patch['target'], group='other')]:
            with self.subTest(target=target):
                self.patch['target'] = target
                projection, _ = self.project()
                self.assertTrue(projection.problems)
                self.assertEqual(projection.claims[0]['size'], '5Gi')

    def test_ambiguous_target_fails(self):
        self.files['k8s/duplicate.yaml'] = copy.deepcopy(self.cluster)
        self.files['k8s/duplicate.yaml']['metadata']['namespace'] = 'another'
        self.files['k8s/kustomization.yaml']['resources'].append('duplicate.yaml')
        projection, _ = self.project()
        self.assertTrue(projection.problems)

    def test_nested_patches_run_before_parent(self):
        self.files['k8s/kustomization.yaml']['patches'] = [copy.deepcopy(self.patch)]
        self.patch['patch'] = yaml.safe_dump([
            {'op': 'test', 'path': '/spec/storage/size', 'value': '40Gi'},
            {'op': 'replace', 'path': '/spec/storage/size', 'value': '42Gi'}])
        projection, _ = self.project()
        self.assertEqual(projection.problems, [])
        self.assertEqual(projection.claims[0]['size'], '42Gi')

    def test_missing_patch_file_fails(self):
        self.patch.pop('patch')
        self.patch['path'] = 'missing.yaml'
        self.assertTrue(self.project()[0].problems)

    def test_replica_change_and_array_operations_are_counted(self):
        self.patch['patch'] = yaml.safe_dump([
            {'op': 'replace', 'path': '/spec/instances', 'value': 2},
            {'op': 'add', 'path': '/spec/tablespaces', 'value': []},
            {'op': 'add', 'path': '/spec/tablespaces/-',
             'value': {'name': 'extra', 'storage': {'size': '3Gi', 'storageClass': 'longhorn'}}},
            {'op': 'replace', 'path': '/spec/tablespaces/0/storage/size', 'value': '4Gi'}])
        projection, _ = self.project()
        self.assertEqual(projection.problems, [])
        self.assertEqual([(c['size'], c['count']) for c in projection.claims], [('5Gi', 2), ('4Gi', 2)])

    def test_strategic_merge_storage_and_replacements_still_fail(self):
        kz = self.files['k8s-public/kustomization.yaml']
        kz['patches'] = [{'patch': yaml.safe_dump(dict(self.cluster, spec={'storage': {'size': '40Gi'}}))}]
        self.assertTrue(self.project()[0].problems)
        kz['patches'] = []
        kz['replacements'] = [{'targets': [{'select': {'kind': 'Cluster'}, 'fieldPaths': ['spec.storage.size']}]}]
        self.assertTrue(self.project()[0].problems)


if __name__ == '__main__':
    unittest.main()
