#!/usr/bin/env bash
# check-storage-budget.sh — refuse a commit whose desired state would promise
# more Longhorn storage than 80 % of what Longhorn allows on one worker.
#
# ADR 0067 (successor to ADR 0036 D7).
#
# WHY. On 2026-07-09 Longhorn declared the cluster unschedulable at 99.6 % of
# its own accounting ceiling, and new PVCs stopped binding. ADR 0036 D7 raised
# the ceiling to 200 % over-provisioning and put an alert behind it. An alert
# fires after the volume exists, in whichever repo happened to push last. This
# check asks the question in the commit that adds the volume, in any
# reconciled repo, before Argo sees it.
#
# WHAT IS COUNTED — desired state from git, never the live cluster:
#
#   scope      every Application the homelab-k8s bootstrap declares: the
#              infrastructure/platform/observability directory generators,
#              the explicit apps.yaml list (external repos at k8s/, central
#              layers at homelab-k8s/apps/<name>) and the bootstrap
#              Applications (argocd-self, platform-forgejo).
#   manifests  PVCs; StatefulSet volumeClaimTemplates x replicas; CNPG
#              Clusters instances x (storage + walStorage + tablespaces);
#              ClickHouseInstallation claim templates x shards x replicas;
#              Prometheus/Alertmanager claim templates x replicas x shards;
#              generic ephemeral volumes. Read by following kustomization
#              resources/components statically — no kustomize, no helm, no
#              network.
#   charts     a chart-generated claim cannot be read without a render, and a
#              render needs the chart (network) and ~45 s for the estate. So
#              chart claims are DECLARED in homelab-k8s
#              scripts/storage-budget.yaml as values paths: a values edit moves
#              the budget, and every size/storage/storageClass key in a chart
#              layer's values must be declared there or dismissed with a
#              reason, so switching persistence on cannot slip past. These rows
#              are estimates and are labelled "chart-values".
#   runtime    claims made at run time (Woodpecker pipeline workspaces),
#              declared the same way and labelled "runtime".
#   classes    replicas from the StorageClass manifests (driver.longhorn.io)
#              and, for the two classes the Longhorn chart creates itself, from
#              the Longhorn values. Non-Longhorn classes (nas-crypt-*, nfs-*)
#              are excluded and reported.
#
# WHERE IT READS. The repo being committed is read from its INDEX — exactly
# what the commit will contain. Every other repo is read from its
# `forgejo/main` (else `origin/main`) remote-tracking ref: what Argo
# reconciles, as of the last fetch, and never a peer's uncommitted edit.
# Siblings are found beside the committing repo's main checkout, so this works
# from a worktree. A reconciled repo that is not checked out is a FAIL, not a
# skip: an undercount is a green that checks nothing.
#
# PLACEMENT. Longhorn's replica scheduling is not controlled from git, so the
# gate does not predict it. With hard replica anti-affinity
# (replicaSoftAntiAffinity=false) a worker holds at most ONE replica of each
# volume, so the most any worker can ever be promised is the sum of every
# volume's size — whatever Longhorn decides. That worst case is the gate. A
# balanced spread (largest volume first onto the least-loaded workers) is
# printed beside it for orientation only; the live cluster has been measured
# less balanced than that.
#
# WHAT IT CANNOT SEE, stated rather than implied:
#   - a chart default that creates a claim without any values key naming it
#     (only a render shows that; ADR 0067 records the render calibration);
#   - kustomize patches or replacements that change storage fields — these
#     FAIL as unmodelled rather than being silently mis-counted;
#   - volumes that exist live but not in git (restore drills, orphans,
#     detached leftovers). The live alert still covers those.
#
# Output: the per-worker table and RESULT are the last lines. `--explain`
# additionally prints every counted claim. Never prints manifest or values
# content beyond names, classes and sizes.
#
# CANONICAL COPY LIVES IN homelab-hooks/scripts/ and is consumed by app repos
# as a pre-commit `repo:`/`rev:` entry (ADR 0047). homelab-k8s carries a
# byte-identical mirror (ADR 0047 D4), policed by its check-synced-scripts.

set -euo pipefail

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not on PATH; the storage budget cannot be computed."
  echo "      Install python3 with PyYAML. This check does not skip: a budget"
  echo "      gate that skips would report Passed for a commit it never read."
  exit 1
fi
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "FAIL: $(command -v python3) has no PyYAML; the storage budget cannot be computed."
  echo "      pip install pyyaml   (this check does not skip — see the header)"
  exit 1
fi

exec python3 - "$@" <<'PY'
import os, posixpath, re, subprocess, sys
import yaml

LOADER = getattr(yaml, "CSafeLoader", yaml.SafeLoader)
GI = 1024 ** 3
HK8S = "homelab-k8s"
BUDGET_PATH = "scripts/storage-budget.yaml"
LONGHORN = "driver.longhorn.io"
KUSTOMIZATION = ("kustomization.yaml", "kustomization.yml", "Kustomization")
STORAGE_KINDS = {"PersistentVolumeClaim", "StatefulSet", "Cluster", "ClickHouseInstallation",
                 "Prometheus", "Alertmanager", "PersistentVolume", "StorageClass"}
STORAGE_TOKENS = re.compile(r"volumeClaimTemplates|storage|replicas|instances|walStorage|"
                            r"tablespaces|shardsCount|replicasCount|numberOfReplicas|volumeName")
KIND_LINE = re.compile(r"^\s*kind:\s*['\"]?(\w+)", re.M)
TEMPLATE_VAR = re.compile(r"\{\{\s*\.([A-Za-z0-9_]+)\s*\}\}")
CANDIDATE_SIZE_KEYS = {"size", "storage"}
CANDIDATE_CLASS_KEYS = {"storageClass", "storageClassName"}
ABSENT = object()

args = sys.argv[1:]
EXPLAIN = args == ["--explain"]
if args and not EXPLAIN:
    print("usage: check-storage-budget.sh [--explain]")
    print("  Reads the workspace; takes no scope arguments. --explain also prints every counted claim.")
    sys.exit(2)


# git exports GIT_DIR, GIT_INDEX_FILE and friends to its hooks. They describe
# the COMMITTING repo, and `git -C <sibling>` obeys them over -C: under a real
# `git commit` every sibling was read as the committing repo (2026-09-11, the
# first homelab-k8s commit of this script). Only the committing repo's own
# reads keep the environment; every sibling read runs without any GIT_*.
SIBLING_ENV = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}


def run(argv, env=None):
    r = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    return r.returncode, r.stdout, r.stderr.decode(errors="replace").strip()


_Q = re.compile(r"^\s*([0-9]+(?:\.[0-9]+)?)\s*(Ki|Mi|Gi|Ti|Pi|Ei|k|K|M|G|T|P|E)?\s*$")
_MULT = {None: 1, "Ki": 2**10, "Mi": 2**20, "Gi": 2**30, "Ti": 2**40, "Pi": 2**50, "Ei": 2**60,
         "k": 10**3, "K": 10**3, "M": 10**6, "G": 10**9, "T": 10**12, "P": 10**15, "E": 10**18}


def quantity(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    m = _Q.match(str(v))
    return int(float(m.group(1)) * _MULT[m.group(2)]) if m else None


def gi(b):
    return b / GI


# ── Repository views: a path -> blob map, read through one cat-file process ──
class View:
    def __init__(self, repo, path, source, label):
        self.repo, self.path, self.source, self.label = repo, path, source, label
        self.files, self._cat, self._cache = {}, None, {}
        self.env = None if source == "index" else SIBLING_ENV
        if source == "index":
            rc, out, err = run(["git", "-C", path, "ls-files", "-s", "-z"])
            if rc:
                raise RuntimeError(f"git ls-files failed in {path}: {err}")
            for rec in out.split(b"\0"):
                if not rec:
                    continue
                meta, name = rec.split(b"\t", 1)
                mode, sha, stage = meta.split(b" ")
                if mode.startswith(b"16"):
                    continue
                self.files[name.decode()] = sha.decode()
        else:
            rc, out, err = run(["git", "-C", path, "ls-tree", "-r", "-z", source], env=self.env)
            if rc:
                raise RuntimeError(f"git ls-tree {source} failed in {path}: {err}")
            for rec in out.split(b"\0"):
                if not rec:
                    continue
                meta, name = rec.split(b"\t", 1)
                mode, typ, sha = meta.split(b" ")
                if typ == b"blob":
                    self.files[name.decode()] = sha.decode()
        self.dirs = {""}
        for f in self.files:
            d = posixpath.dirname(f)
            while d not in self.dirs:
                self.dirs.add(d)
                d = posixpath.dirname(d)

    def isfile(self, p):
        return p in self.files

    def isdir(self, p):
        return p in self.dirs

    def children(self, d):
        pre = d + "/" if d else ""
        return sorted(f for f in self.files if f.startswith(pre) and "/" not in f[len(pre):])

    def read(self, p):
        if p not in self._cache:
            if self._cat is None:
                self._cat = subprocess.Popen(["git", "-C", self.path, "cat-file", "--batch"],
                                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=self.env)
            self._cat.stdin.write(self.files[p].encode() + b"\n")
            self._cat.stdin.flush()
            header = self._cat.stdout.readline().split()
            data = self._cat.stdout.read(int(header[2]))
            self._cat.stdout.read(1)
            self._cache[p] = data
        return self._cache[p]


# ── Where am I: the committing repo, and the workspace its main checkout sits in ──
rc, top, err = run(["git", "rev-parse", "--show-toplevel"])
if rc:
    print("FAIL: not inside a git repository; run this from a workspace repo.")
    sys.exit(1)
TOP = top.decode().strip()
rc, common, err = run(["git", "-C", TOP, "rev-parse", "--git-common-dir"])
COMMON = os.path.normpath(os.path.join(TOP, common.decode().strip()))
MAIN_CHECKOUT = os.path.dirname(COMMON) if os.path.basename(COMMON) == ".git" else COMMON
SELF = os.path.basename(MAIN_CHECKOUT)
WS = os.path.dirname(MAIN_CHECKOUT)


class Projection:
    """One evaluation of the budget, with the committing repo read from `self_source`."""

    def __init__(self, self_source, shared_views):
        self.self_source = self_source
        self.views = shared_views
        self.problems = []
        self.claims, self.excluded, self.estimated_layers = [], [], set()
        self.pvs, self.scs = {}, {}
        self.repo_refs = {}

    def problem(self, head, *detail):
        self.problems.append((head, list(detail)))

    # ── views ──
    def view(self, repo):
        key = (repo, self.self_source if repo == SELF else "ref")
        if key in self.views:
            v = self.views[key]
            if v is not None and repo != SELF:
                self.repo_refs[repo] = v.label
            return v
        v = None
        if repo == SELF and self.self_source == "index":
            v = View(repo, TOP, "index", "index (staged)")
        else:
            d = os.path.join(WS, repo)
            if not os.path.exists(os.path.join(d, ".git")):
                self.problem(f"{repo} is reconciled but not checked out at {d}",
                             "Its claims cannot be counted, so any total would be an undercount.",
                             "Clone it beside the other repos (scripts/setup.sh at the workspace root clones repos.manifest), then commit again.")
            else:
                for cand in ("refs/remotes/forgejo/main", "refs/remotes/origin/main"):
                    rc, out, _ = run(["git", "-C", d, "rev-parse", "--verify", "-q", cand + "^{commit}"], env=SIBLING_ENV)
                    if rc == 0:
                        v = View(repo, d, cand, f"{cand[len('refs/remotes/'):]}@{out.decode()[:7]}")
                        break
                if v is None:
                    if repo == SELF:
                        return None
                    self.problem(f"{repo} has no forgejo/main or origin/main ref",
                                 f"Fetch it: git -C {d} fetch forgejo   (or origin)")
        self.views[key] = v
        if v is not None and repo != SELF:
            self.repo_refs[repo] = v.label
        return v

    def docs(self, v, p):
        try:
            return [d for d in yaml.load_all(v.read(p), Loader=LOADER) if isinstance(d, dict)]
        except yaml.YAMLError as e:
            mark = getattr(e, "problem_mark", None)
            where = f" (line {mark.line + 1})" if mark else ""
            self.problem(f"{v.repo}/{p} does not parse as YAML{where}",
                         "Content not shown: the file may carry secret material.")
            return []

    # ── scope: what the bootstrap tells Argo to reconcile ──
    def scope(self, hk):
        layers = {}

        def add(repo, path, rev, why):
            if rev not in (None, "", "main", "HEAD"):
                self.problem(f"{why} reconciles {repo}@{rev}, not main",
                             "This check reads main only; extend it before relying on the budget.")
            if repo is None:
                if hk.isdir(path):
                    repo = HK8S
                else:
                    self.problem(f"{why}: repoURL is a placeholder and {path} is not in {HK8S}")
                    return
            layers.setdefault((repo, posixpath.normpath(path)), []).append(why)

        boot = "bootstrap/kustomization.yaml"
        if not hk.isfile(boot):
            self.problem(f"{HK8S} {hk.label} has no {boot}; the reconciled scope cannot be derived.")
            return layers
        kz = (self.docs(hk, boot) or [{}])[0]
        for res in kz.get("resources") or []:
            p = posixpath.normpath(posixpath.join("bootstrap", str(res)))
            if not hk.isfile(p):
                continue
            for d in self.docs(hk, p):
                kind, name = d.get("kind"), (d.get("metadata") or {}).get("name")
                spec = d.get("spec") or {}
                if kind == "Application":
                    for s in spec.get("sources") or [spec.get("source") or {}]:
                        if s.get("chart"):
                            self.problem(f"Application {name} installs a Helm repository chart directly",
                                         "Its claims are invisible to this check; extend it first.")
                            continue
                        add(repo_of(s.get("repoURL")), s.get("path") or "", s.get("targetRevision"),
                            f"Application {name}")
                elif kind == "ApplicationSet":
                    tsrc = ((spec.get("template") or {}).get("spec") or {}).get("source") or {}
                    for gen in spec.get("generators") or []:
                        if (gen.get("git") or {}).get("directories"):
                            g = gen["git"]
                            repo = repo_of(g.get("repoURL")) or HK8S
                            gv = hk if repo == HK8S else self.view(repo)
                            if gv is None:
                                continue
                            inc = [x.get("path") for x in g["directories"] if not x.get("exclude")]
                            exc = [x.get("path") for x in g["directories"] if x.get("exclude")]
                            for dpath in sorted(gv.dirs):
                                if dpath and any(glob(dpath, i) for i in inc) and not any(glob(dpath, x) for x in exc):
                                    add(repo, dpath, g.get("revision"), f"ApplicationSet {name}")
                        elif "list" in gen:
                            for el in (gen["list"] or {}).get("elements") or []:
                                sub = lambda s: TEMPLATE_VAR.sub(lambda m: str(el.get(m.group(1), m.group(0))), str(s or ""))
                                add(repo_of(sub(tsrc.get("repoURL"))), sub(tsrc.get("path")),
                                    sub(tsrc.get("targetRevision")), f"ApplicationSet {name}/{el.get('name')}")
                        else:
                            self.problem(f"ApplicationSet {name} uses a generator this check does not model: {sorted(gen)}")
        return layers

    # ── one layer: follow kustomization resources/components ──
    def build(self, v, d, ns, depth, acc):
        if depth > 40:
            self.problem(f"{v.repo}/{d}: kustomization nesting deeper than 40; a cycle?")
            return
        kzp = next((posixpath.join(d, n) for n in KUSTOMIZATION if v.isfile(posixpath.join(d, n))), None)
        if kzp is None:
            for f in v.children(d):
                if f.endswith((".yaml", ".yml", ".json")):
                    acc["docs"].extend((doc, f, ns) for doc in self.docs(v, f))
            return
        kz = (self.docs(v, kzp) or [{}])[0]
        ns = ns or kz.get("namespace")
        for r in kz.get("replicas") or []:
            if isinstance(r, dict) and "name" in r:
                acc["replicas"].setdefault(r["name"], r.get("count"))
        for key in ("resources", "bases", "components"):
            for entry in kz.get(key) or []:
                entry = str(entry)
                if "://" in entry or entry.startswith(("github.com/", "git@")):
                    self.problem(f"{v.repo}/{kzp}: remote {key} entry cannot be read offline: {entry}")
                    continue
                p = posixpath.normpath(posixpath.join(d, entry))
                if p == ".." or p.startswith("../"):
                    self.problem(f"{v.repo}/{kzp}: {key} entry leaves the repository: {entry}")
                elif v.isfile(p):
                    acc["docs"].extend((doc, p, ns) for doc in self.docs(v, p))
                elif v.isdir(p):
                    self.build(v, p, ns, depth + 1, acc)
                else:
                    self.problem(f"{v.repo}/{kzp}: {key} entry {entry} does not exist at {v.label}",
                                 "Argo would fail to build this layer too.")
        for hc in kz.get("helmCharts") or []:
            acc["charts"].append((d, hc))
        for key in ("patches", "patchesStrategicMerge", "patchesJson6902"):
            for pt in kz.get(key) or []:
                if isinstance(pt, str):
                    pt = {"patch": pt} if "\n" in pt else {"path": pt}
                body = str(pt.get("patch") or "")
                if pt.get("path"):
                    pp = posixpath.normpath(posixpath.join(d, pt["path"]))
                    body = v.read(pp).decode(errors="replace") if v.isfile(pp) else ""
                target = (pt.get("target") or {}).get("kind")
                kinds = ({target} if target else set(KIND_LINE.findall(body))) & STORAGE_KINDS
                if kinds and STORAGE_TOKENS.search(body):
                    self.problem(f"{v.repo}/{kzp}: a {key} entry changes storage fields on {', '.join(sorted(kinds))}",
                                 "Patches are not applied by this check, so the patched size/class/replicas would be mis-counted.",
                                 "Put the value in the base manifest or chart values, or extend this check to model the patch.")
        for rp in kz.get("replacements") or []:
            for t in (rp.get("targets") or []) if isinstance(rp, dict) else []:
                k = (t.get("select") or {}).get("kind")
                if k in STORAGE_KINDS and any(STORAGE_TOKENS.search(str(fp)) for fp in t.get("fieldPaths") or []):
                    self.problem(f"{v.repo}/{kzp}: a replacement writes storage fields on {k}",
                                 "Replacements are not applied by this check; extend it or move the value.")

    # ── claims ──
    def claim(self, where, kind, name, klass, size, count, volume=None, origin="manifest"):
        self.claims.append(dict(where, kind=kind, name=name, klass=klass, size=size, count=count,
                                volume=volume, origin=origin))

    def manifest_claims(self, v, layer, acc):
        reps = acc["replicas"]
        for doc, f, ns in acc["docs"]:
            kind = doc.get("kind")
            if kind == "Secret":
                continue
            md, spec = doc.get("metadata") or {}, doc.get("spec") or {}
            name, api = str(md.get("name", "?")), str(doc.get("apiVersion", ""))
            where = dict(repo=v.repo, layer=layer, file=f, ns=ns or md.get("namespace") or "-")
            if kind == "PersistentVolumeClaim":
                self.claim(where, "PVC", name, spec.get("storageClassName", ABSENT), req(spec), 1, spec.get("volumeName"))
            elif kind == "StatefulSet":
                n = reps.get(name, spec.get("replicas", 1))
                for t in spec.get("volumeClaimTemplates") or []:
                    ts = t.get("spec") or {}
                    self.claim(where, "StatefulSet VCT", f"{name}/{(t.get('metadata') or {}).get('name')}",
                               ts.get("storageClassName", ABSENT), req(ts), n)
            elif kind == "Cluster" and api.startswith("postgresql.cnpg.io/"):
                parts = [("storage", spec.get("storage")), ("walStorage", spec.get("walStorage"))]
                parts += [(f"tablespace {t.get('name')}", t.get("storage")) for t in spec.get("tablespaces") or []]
                for label, st in parts:
                    if not st:
                        continue
                    tpl = (st.get("pvcTemplate") or {})
                    klass = st["storageClass"] if "storageClass" in st else tpl.get("storageClassName", ABSENT)
                    self.claim(where, f"CNPG {label}", name, klass, st.get("size") or req(tpl), spec.get("instances", 1))
            elif kind == "ClickHouseInstallation":
                n = 0
                for c in ((spec.get("configuration") or {}).get("clusters") or []):
                    lay = c.get("layout") or {}
                    n += int(lay.get("shardsCount", 1)) * int(lay.get("replicasCount", 1))
                for t in (spec.get("templates") or {}).get("volumeClaimTemplates") or []:
                    ts = t.get("spec") or {}
                    self.claim(where, "ClickHouse VCT", f"{name}/{t.get('name')}", ts.get("storageClassName", ABSENT), req(ts), n or 1)
            elif kind in ("Prometheus", "Alertmanager") and api.startswith("monitoring.coreos.com/"):
                ts = ((spec.get("storage") or {}).get("volumeClaimTemplate") or {}).get("spec")
                if ts:
                    n = int(spec.get("replicas", 1)) * int(spec.get("shards", 1) if kind == "Prometheus" else 1)
                    self.claim(where, f"{kind} VCT", name, ts.get("storageClassName", ABSENT), req(ts), n)
            elif kind == "PersistentVolume":
                csi = spec.get("csi") or {}
                self.pvs[name] = dict(klass=spec.get("storageClassName"), driver=csi.get("driver") or ("nfs" if spec.get("nfs") else "?"),
                                      replicas=(csi.get("volumeAttributes") or {}).get("numberOfReplicas"))
            elif kind == "StorageClass":
                ann = md.get("annotations") or {}
                self.scs[name] = dict(provisioner=doc.get("provisioner"),
                                      replicas=(doc.get("parameters") or {}).get("numberOfReplicas"),
                                      default=str(ann.get("storageclass.kubernetes.io/is-default-class", "")).lower() == "true",
                                      where=f"{v.repo}/{f}")
            pod = ((spec.get("template") or {}).get("spec")
                   or ((((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec"))
                   or {})
            for vol in pod.get("volumes") or []:
                if isinstance(vol, dict) and "ephemeral" in vol:
                    es = ((vol["ephemeral"] or {}).get("volumeClaimTemplate") or {}).get("spec") or {}
                    n = "workers" if kind == "DaemonSet" else reps.get(name, spec.get("replicas", 1))
                    self.claim(where, f"{kind} ephemeral", f"{name}/{vol.get('name')}", es.get("storageClassName", ABSENT), req(es), n)

    def chart_claims(self, v, layer, acc, decl):
        entries = decl.pop((v.repo, layer), [])
        releases = [hc.get("releaseName") or hc.get("name") for _, hc in acc["charts"]]
        for kdir, hc in acc["charts"]:
            release = hc.get("releaseName") or hc.get("name")
            values = {}
            for vf in [hc.get("valuesFile")] + list(hc.get("additionalValuesFiles") or []):
                if not vf:
                    continue
                p = posixpath.normpath(posixpath.join(kdir, vf))
                if not v.isfile(p):
                    self.problem(f"{v.repo}/{kdir}: values file {vf} of chart {hc.get('name')} does not exist at {v.label}")
                    continue
                for doc in self.docs(v, p):
                    merge(values, doc)
            if isinstance(hc.get("valuesInline"), dict):
                merge(values, hc["valuesInline"])
            mine = [e for e in entries if e.get("release") in (None, release)]
            if len(releases) > 1 and any(e.get("release") is None for e in mine):
                self.problem(f"{v.repo}/{layer}: {len(releases)} charts in one layer; its storage-budget entry must name a release")
            covered = set()
            for e in mine:
                e["_matched"] = True
                for c in e.get("claims") or []:
                    self.eval_chart_claim(v, layer, release, values, c, covered)
                for nc in e.get("not_claims") or []:
                    covered.add(nc.get("path"))
                    if not lookup(values, nc.get("path"))[0]:
                        self.problem(f"{v.repo}/{layer} ({release}): not_claims path {nc.get('path')} is not in the values any more",
                                     f"Delete that entry from {HK8S}/{BUDGET_PATH}.")
            for path, val in candidates(values):
                if path not in covered:
                    self.problem(f"{v.repo}/{layer} ({release}): values key {path} = {val!r} is not declared in the storage budget",
                                 "A chart turns keys like this into claims this check cannot see without a render.",
                                 f"Declare it in {HK8S}/{BUDGET_PATH} under chart_claims: as a claim (size/class/count paths),",
                                 "or under not_claims with the reason it creates no Longhorn volume.")
            if mine or candidates(values):
                self.estimated_layers.add(f"{v.repo}/{layer}")
        for e in entries:
            if not e.get("_matched"):
                self.problem(f"{HK8S}/{BUDGET_PATH}: chart_claims entry {v.repo}/{layer} release {e.get('release')} matches no chart in that layer")
        entries[:] = []

    def eval_chart_claim(self, v, layer, release, values, c, covered):
        where = dict(repo=v.repo, layer=layer, file=f"{release} values", ns="-")
        got = {}
        for fld in ("enabled", "size", "storage_class", "count"):
            spec = c.get(fld, True if fld == "enabled" else 1 if fld == "count" else None)
            if isinstance(spec, dict) and "path" in spec:
                if fld in ("size", "storage_class"):
                    covered.add(spec["path"])
                found, val = lookup(values, spec["path"])
                if found and val is not None and val != "":
                    got[fld] = val
                elif "default" in spec:
                    got[fld] = spec["default"]
                elif fld == "storage_class":
                    got[fld] = None  # unset: the chart renders no class -> cluster default class
                else:
                    self.problem(f"{v.repo}/{layer} ({release}): claim {c.get('name')}: {spec['path']} is not set and declares no default",
                                 f"Fix the path in {HK8S}/{BUDGET_PATH} (a chart bump may have moved the key).")
                    return
            else:
                got[fld] = spec
        if str(got["enabled"]).lower() in ("false", "0", "none"):
            return
        klass = got["storage_class"]
        count = got["count"]
        if isinstance(count, str) and count.isdigit():
            count = int(count)
        origin = "runtime" if c.get("runtime") else "chart-values"
        self.claim(where, c.get("kind", "chart claim"), c.get("name"), ABSENT if klass in (None, "") else klass,
                   got["size"], count, origin=origin)

    # ── the whole projection ──
    def compute(self):
        hk = self.view(HK8S)
        if hk is None:
            return None
        if not hk.isfile(BUDGET_PATH):
            self.problem(f"{HK8S} {hk.label} has no {BUDGET_PATH}",
                         "The budget declarations (workers, thresholds, chart claims) live there.",
                         f"If ADR 0067's first commit is not merged yet, fetch {HK8S}; otherwise restore the file.")
            return None
        budget = (self.docs(hk, BUDGET_PATH) or [{}])[0]
        decl = {}
        for e in budget.get("chart_claims") or []:
            decl.setdefault((e.get("repo"), e.get("layer")), []).append(dict(e))
        layers = self.scope(hk)
        self.layer_count = len(layers)
        for (repo, path) in sorted(layers):
            v = hk if repo == HK8S else self.view(repo)
            if v is None:
                continue
            if not v.isdir(path):
                self.problem(f"{', '.join(layers[(repo, path)])} reconciles {repo}/{path}, which does not exist at {v.label}")
                continue
            acc = {"docs": [], "charts": [], "replicas": {}}
            self.build(v, path, None, 0, acc)
            self.manifest_claims(v, path, acc)
            self.chart_claims(v, path, acc, decl)
        for (repo, layer), entries in decl.items():
            if entries:
                self.problem(f"{HK8S}/{BUDGET_PATH}: chart_claims entry {repo}/{layer} is not a reconciled layer",
                             "Delete the entry, or fix its repo/layer.")

        # Longhorn settings and the classes the chart creates itself
        lh = budget.get("longhorn") or {}
        lv = {}
        if hk.isfile(lh.get("values", "")):
            for doc in self.docs(hk, lh["values"]):
                merge(lv, doc)
        else:
            self.problem(f"{HK8S}/{BUDGET_PATH}: longhorn.values {lh.get('values')!r} does not exist at {hk.label}")
        settings = lv.get("defaultSettings") or {}
        dflt = lh.get("setting_defaults") or {}

        def setting(k):
            val = settings.get(k)
            if val is None:
                if k not in dflt:
                    self.problem(f"{HK8S}/{BUDGET_PATH}: Longhorn setting {k} is unset in values and has no declared default")
                    return None
                return dflt[k]
            return val

        overprov = quantity(setting("storageOverProvisioningPercentage"))
        reserved_pct = quantity(setting("storageReservedPercentageForDefaultDisk"))
        soft = str(setting("replicaSoftAntiAffinity")).lower() == "true"
        for cname, spec in (lh.get("chart_storage_classes") or {}).items():
            found, val = lookup(lv, spec.get("replicas_path"))
            if not found or val is None:
                if "default" not in spec:
                    self.problem(f"{HK8S}/{BUDGET_PATH}: chart class {cname}: {spec.get('replicas_path')} is unset and declares no default")
                    continue
                val = spec["default"]
            self.scs.setdefault(cname, dict(provisioner=LONGHORN, replicas=val, default=False, where=f"{HK8S}/{lh.get('values')}"))

        workers = budget.get("workers") or []
        threshold = quantity(budget.get("threshold_percent"))
        if not workers or threshold is None or overprov is None or reserved_pct is None:
            self.problem(f"{HK8S}/{BUDGET_PATH}: workers, threshold_percent and the Longhorn settings are all required")
            return None

        defaults = sorted(n for n, s in self.scs.items() if s["default"])
        vols = []
        for c in self.claims:
            size = quantity(c["size"])
            label = f"{c['repo']}/{c['layer']} {c['kind']} {c['name']}"
            if size is None:
                self.problem(f"{label}: storage size {c['size']!r} is not a quantity")
                continue
            count = c["count"]
            if count == "workers":
                count = len(workers)
            try:
                count = int(count)
            except (TypeError, ValueError):
                self.problem(f"{label}: replica/instance count {count!r} is not an integer")
                continue
            klass = c["klass"]
            if klass is ABSENT:
                if len(defaults) != 1:
                    self.problem(f"{label} names no StorageClass and the reconciled manifests declare {len(defaults)} default classes ({', '.join(defaults) or 'none'})")
                    continue
                klass = defaults[0]
            c["class_resolved"] = klass
            if klass == "":
                pv = self.pvs.get(c.get("volume") or "")
                if pv is None:
                    self.problem(f"{label} binds statically (storageClassName \"\") but no PersistentVolume {c.get('volume')!r} is reconciled")
                    continue
                if pv["driver"] != LONGHORN:
                    self.excluded.append((c, size, count, f"static PV {c.get('volume')} via {pv['driver']}"))
                    continue
                replicas = pv["replicas"]
            elif klass in self.scs and self.scs[klass]["provisioner"] == LONGHORN:
                replicas = self.scs[klass]["replicas"]
            elif klass in self.scs:
                self.excluded.append((c, size, count, f"{klass} via {self.scs[klass]['provisioner']}"))
                continue
            else:
                self.problem(f"{label} uses StorageClass {klass!r}, which no reconciled manifest defines")
                continue
            try:
                replicas = int(replicas)
            except (TypeError, ValueError):
                self.problem(f"StorageClass {klass}: numberOfReplicas {replicas!r} is not an integer")
                continue
            c["replicas"] = replicas
            c["size_b"], c["count_i"] = size, count
            if not soft and replicas > len(workers):
                self.problem(f"{label}: {replicas} replicas on {klass} can never be placed on {len(workers)} workers under hard anti-affinity")
            for i in range(count):
                vols.append((size, replicas, c))

        rows = []
        for w in workers:
            disk = quantity(w.get("longhorn_disk")) or 0
            reserved = disk * reserved_pct // 100
            allowed = (disk - reserved) * overprov // 100
            rows.append(dict(name=w.get("name"), disk=disk, reserved=reserved, allowed=allowed,
                             line=allowed * threshold // 100, balanced=0, worst=0))
        for size, replicas, _ in vols:
            for r in rows:
                r["worst"] += size * (replicas if soft else 1)
        for size, replicas, _ in sorted(vols, key=lambda t: -t[0]):
            for r in sorted(rows, key=lambda r: (r["balanced"] / r["allowed"] if r["allowed"] else 0, r["name"]))[:replicas]:
                r["balanced"] += size
        self.rows, self.vols, self.soft = rows, vols, soft
        self.threshold, self.overprov, self.reserved_pct = threshold, overprov, reserved_pct
        return rows


def repo_of(url):
    url = str(url or "").rstrip("/")
    if url.endswith(".git"):
        url = url[:-4]
    return url.rsplit("/", 1)[-1] if "/" in url else None


def glob(path, pattern):
    import fnmatch
    a, b = path.split("/"), str(pattern or "").split("/")
    return len(a) == len(b) and all(fnmatch.fnmatchcase(x, y) for x, y in zip(a, b))


def req(spec):
    return ((spec.get("resources") or {}).get("requests") or {}).get("storage")


def merge(dst, src):
    for k, v in (src or {}).items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        elif v is None:
            dst.pop(k, None)
        else:
            dst[k] = v
    return dst


_TOK = re.compile(r"\.([^.\[\]]+)|\[(\d+)\]")


def lookup(values, path):
    node = values
    pos = 0
    path = str(path or "")
    while pos < len(path):
        m = _TOK.match(path, pos)
        if not m:
            return False, None
        pos = m.end()
        if m.group(1) is not None:
            if not isinstance(node, dict) or m.group(1) not in node:
                return False, None
            node = node[m.group(1)]
        else:
            i = int(m.group(2))
            if not isinstance(node, list) or i >= len(node):
                return False, None
            node = node[i]
    return True, node


def candidates(node, path=""):
    out = []
    if isinstance(node, dict):
        for k, v in node.items():
            p = f"{path}.{k}"
            if isinstance(v, (dict, list)):
                out.extend(candidates(v, p))
            elif k in CANDIDATE_CLASS_KEYS and isinstance(v, str):
                out.append((p, v))
            elif k in CANDIDATE_SIZE_KEYS and isinstance(v, str) and quantity(v) is not None:
                out.append((p, v))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            out.extend(candidates(v, f"{path}[{i}]"))
    return out


# ── run: the staged state, and (for the delta line) the committed state ──
shared = {}
now = Projection("index", shared)
rows = now.compute()
base = None
if rows is not None:
    b = Projection("ref", shared)
    if b.view(SELF) is not None and b.compute() is not None and not b.problems:
        base = b


def fmt(b):
    return f"{gi(b):7.0f}"


def key(c):
    return (c["repo"], c["layer"], c["kind"], c["name"])


if EXPLAIN and rows is not None:
    print("counted claims (Gi; promise = size x count x replicas):")
    print(f"  {'origin':<12} {'repo/layer':<44} {'kind':<22} {'name':<46} {'class':<26} {'size':>6} {'n':>3} {'r':>2} {'promise':>8}")
    for c in sorted((c for c in now.claims if "size_b" in c), key=lambda c: (c["repo"], c["layer"], c["name"])):
        promise = c["size_b"] * c["count_i"] * c["replicas"]
        print(f"  {c['origin']:<12} {c['repo'] + '/' + c['layer']:<44} {c['kind']:<22} {str(c['name']):<46} {c['class_resolved']:<26} "
              f"{gi(c['size_b']):6.1f} {c['count_i']:>3} {c['replicas']:>2} {gi(promise):8.1f}")
    print("excluded claims (not Longhorn):")
    for c, size, count, why in sorted(now.excluded, key=lambda t: (t[0]["repo"], t[0]["name"])):
        print(f"  {c['repo'] + '/' + c['layer']:<44} {str(c['name']):<46} {gi(size):8.0f} Gi x{count}  {why}")
    print()

if now.problems:
    print("FAIL: the storage budget cannot be trusted — fix these first:")
    for head, detail in now.problems:
        print(f"  - {head}")
        for line in detail:
            print(f"      {line}")
    print()

if rows is None:
    print("RESULT: FAIL — no projection computed (see above).")
    sys.exit(1)

worst = max(rows, key=lambda r: r["worst"] / r["allowed"] if r["allowed"] else 0)
over = [r for r in rows if r["worst"] > r["line"]]

delta_lines = []
if base is not None:
    before = {key(c): c for c in base.claims if "size_b" in c}
    after = {key(c): c for c in now.claims if "size_b" in c}
    for k in sorted(set(before) | set(after)):
        a, b_ = after.get(k), before.get(k)
        pa = a["size_b"] * a["count_i"] if a else 0
        pb = b_["size_b"] * b_["count_i"] if b_ else 0
        if pa != pb or (a and b_ and a["replicas"] != b_["replicas"]):
            delta_lines.append(f"    {k[0]}/{k[1]} {k[2]} {k[3]}: {gi(pb):.1f} -> {gi(pa):.1f} Gi of volume size")
    wb = max(base.rows, key=lambda r: r["name"] == worst["name"])["worst"] if base.rows else 0

if over:
    print(f"FAIL: projected Longhorn promises exceed {now.threshold} % of what Longhorn allows on {', '.join(r['name'] for r in over)}.")
    print(f"      Worst case on {worst['name']}: {gi(worst['worst']):.0f} Gi promised vs a {gi(worst['line']):.0f} Gi line "
          f"({now.threshold} % of {gi(worst['allowed']):.0f} Gi allowed).")
    if delta_lines:
        print(f"      This commit changes (committed -> staged):")
        for line in delta_lines:
            print(line)
    print("      Largest contributors to the worst case:")
    for size, replicas, c in sorted(now.vols, key=lambda t: -t[0])[:8]:
        print(f"        {gi(size):6.0f} Gi  r={replicas}  {c['repo']}/{c['layer']} {c['kind']} {c['name']} ({c['origin']})")
    print("      To converge: shrink or remove the new claim, move data whose class allows it off Longhorn")
    print("      (NAS classes, ADR 0064), lower a replica count, or — if the disks changed — update")
    print(f"      workers in {HK8S}/{BUDGET_PATH}. Raising the threshold is a decision (ADR 0067), not a fix.")
    print()

refs = ", ".join(sorted(set(now.repo_refs.values())))
n_counted = len([c for c in now.claims if "size_b" in c])
n_est = len([c for c in now.claims if "size_b" in c and c["origin"] != "manifest"])
print(f"storage budget (ADR 0067) — Longhorn promises vs {now.threshold} % of what Longhorn allows per worker")
print(f"  read      {SELF}: index (staged); {len(now.repo_refs)} other repo(s) at forgejo|origin/main as last fetched")
print(f"  scope     {now.layer_count} reconciled layers, {n_counted} Longhorn claims ({n_est} estimated from chart values/runtime), "
      f"{len(now.excluded)} non-Longhorn claims excluded")
print(f"  estimated {', '.join(sorted(now.estimated_layers)) or 'none'}")
print(f"  longhorn  over-provisioning {now.overprov} %, reserved {now.reserved_pct} % of each disk, "
      f"replica anti-affinity {'SOFT (worst case counts every replica)' if now.soft else 'hard (a worker holds at most one replica per volume)'}")
if base is not None:
    print(f"  change    {gi(worst['worst'] - wb):+.1f} Gi on the worst-case worker vs {SELF}'s committed state"
          + (f" ({len(delta_lines)} claim(s) changed)" if delta_lines else ""))
print()
print(f"  {'worker':<9} {'disk':>7} {'reserved':>8} {'allowed':>8} {str(now.threshold) + ' % line':>9} {'balanced':>8} {'worst':>8} {'worst %':>8}  status")
for r in rows:
    pct = 100 * r["worst"] / r["allowed"] if r["allowed"] else 0
    print(f"  {r['name']:<9} {fmt(r['disk'])} {gi(r['reserved']):8.0f} {gi(r['allowed']):8.0f} {gi(r['line']):9.0f} "
          f"{gi(r['balanced']):8.0f} {gi(r['worst']):8.0f} {pct:7.1f}%  {'OVER' if r in over else 'ok'}")
allowed = sum(r["allowed"] for r in rows)
total = sum(size * replicas for size, replicas, _ in now.vols)
print(f"  {'cluster':<9} {fmt(sum(r['disk'] for r in rows))} {gi(sum(r['reserved'] for r in rows)):8.0f} {gi(allowed):8.0f} "
      f"{gi(sum(r['line'] for r in rows)):9.0f} {gi(total):8.0f} {'':>8} {100 * total / allowed if allowed else 0:7.1f}%  (sum of size x replicas)")
print("  (GiB. balanced = largest-first spread, orientation only; worst = every volume has a replica on that worker — the gate)")
print()
if now.problems or over:
    print(f"RESULT: FAIL — {len(now.problems)} input problem(s), {len(over)} worker(s) over the {now.threshold} % line")
    sys.exit(1)
print(f"RESULT: PASS — headroom on the fullest worker: {gi(worst['line'] - worst['worst']):.0f} Gi of new volume size before the {now.threshold} % line")
PY
