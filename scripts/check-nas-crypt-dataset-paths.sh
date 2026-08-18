#!/usr/bin/env bash
# Enforce ADR 0051: a nas-crypt volume is a named dataset, not a dynamic volume.
#
# This check exists because of a specific incident. Until 2026-08-15 every
# `nas-crypt-*` StorageClass carried `remotePath: ""` — the share ROOT — so
# every PVC on a class mounted the same directory tree. A scratch PVC created
# on `nas-crypt-internal-archive` landed inside conversation-history's live L0
# vault, and a cleanup `rm` deleted its ledger files. Nothing in the manifests
# said a PVC meant anything other than what a PVC normally means.
#
# The fix (ADR 0051) is only as good as its invariants, and all four are
# mechanically checkable, so they are checked here rather than trusted:
#
#   1. No two PVs share a (remote, remotePath) pair. Two datasets on one path
#      is precisely the bug; Kubernetes will not stop you.
#   2. Every dataset PV has a non-empty remotePath — UNLESS it is explicitly
#      labelled `homelab.internal/component: backup-source`, which is the
#      documented, deliberate share-root mount the offsite backup depends on
#      (ADR 0051 §D7). Deliberate exceptions must be declared, not inferred.
#   3. Every PV has a claimRef, so a dataset cannot be claimed by whoever asks
#      first.
#   4. Every PVC in the workspace on a `nas-crypt-*` class binds by
#      `volumeName` to a PV declared here, and that PV's claimRef points back
#      at it. A PVC without `volumeName` is a dynamic provision — the thing
#      that is no longer supported.
#
# Invariant 4 is CROSS-REPO: PVCs live in the app repos per ADR 0049, while the
# PVs are cluster-scoped and live here (ADR 0051 §Consequences). Sibling repos
# that are not checked out are reported and skipped, never silently ignored.
#
# Exit 0 = clean. Exit 1 = at least one violation.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PV_FILE="$REPO_ROOT/infrastructure/csi-rclone/persistentvolumes.yaml"

if [ ! -f "$PV_FILE" ]; then
  echo "FAIL: $PV_FILE is missing." >&2
  echo "      ADR 0051 requires every nas-crypt dataset to be declared there." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "SKIP: python3 not found; cannot parse YAML." >&2
  exit 0
fi

python3 - "$PV_FILE" "$WORKSPACE_ROOT" <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    print("SKIP: PyYAML not installed; cannot parse YAML.", file=sys.stderr)
    sys.exit(0)

pv_file, workspace_root = sys.argv[1], sys.argv[2]

# ── Datasets not yet cut over ────────────────────────────────────────────────
#
# `spec.volumeName` is immutable on a bound PVC, so the app-repo commit that
# adds it IS the cutover step and cannot be pushed ahead of the data move (ADR
# 0051 §Consequences). This list is the honest record of what has not happened
# yet. It must SHRINK to empty as the migration in
# `homelab-docs/03-runbooks/nas/nas-crypt-dataset-migration.md` proceeds.
#
# The check enforces the list in both directions: a PVC listed here may lack
# volumeName, and a PVC listed here that ALREADY has one is a failure — a stale
# entry, meaning the list stopped describing reality. Delete the line when the
# dataset cuts over.
PENDING_MIGRATION = {
    ("nextcloud", "nextcloud-personal-files"),
    ("nextcloud", "nextcloud-family-shared"),
    ("immich", "immich-originals"),
    ("paperless", "paperless-media"),
    ("forgejo", "forgejo-lfs"),
    ("forgejo", "forgejo-packages"),
    ("backup-cronjobs", "backup-src-personal-photos"),
    ("backup-cronjobs", "backup-src-personal-files"),
    ("backup-cronjobs", "backup-src-family-shared"),
    ("backup-cronjobs", "backup-src-personal-documents"),
    ("backup-cronjobs", "backup-src-internal-archive"),
    ("backup-cronjobs", "backup-src-forgejo-lfs"),
}

# ── Stale central copies, deliberately not enforced ──────────────────────────
#
# `nextcloud`, `immich` and `paperless` reconcile from their OWN repositories
# per bootstrap/applicationsets/apps.yaml. The copies under homelab-k8s/apps/
# are superseded leftovers pending guarded cleanup (see CLAUDE.md and ADR
# 0001's 2026-07-19 correction). Editing them would create a second, wrong
# source of truth for the same PVC, so ADR 0051 explicitly leaves them alone —
# which means this check must not demand they be migrated.
#
# Remove an entry here when the corresponding directory is deleted. If the path
# no longer exists, the check says so rather than silently carrying a dead rule.
STALE_CENTRAL_COPIES = (
    "homelab-k8s/apps/nextcloud/",
    "homelab-k8s/apps/immich/",
    "homelab-k8s/apps/paperless/",
)

failures = []
notes = []
pending_seen = set()
stale_copies_seen = set()

# ── Load the declared datasets ───────────────────────────────────────────────
with open(pv_file) as fh:
    pv_docs = [d for d in yaml.safe_load_all(fh) if d and d.get("kind") == "PersistentVolume"]

if not pv_docs:
    print(f"FAIL: {pv_file} declares no PersistentVolumes.", file=sys.stderr)
    sys.exit(1)

by_path = {}          # (remote, remotePath) -> [pv names]
declared = {}         # pv name -> {"claim": (ns, name), "remote": ..., "path": ...}

for pv in pv_docs:
    name = pv["metadata"]["name"]
    labels = pv["metadata"].get("labels") or {}
    spec = pv["spec"]
    csi = spec.get("csi") or {}
    attrs = csi.get("volumeAttributes") or {}
    remote = attrs.get("remote", "")
    path = attrs.get("remotePath", "")
    is_backup_source = labels.get("homelab.internal/component") == "backup-source"

    # Invariant 2 — non-empty path unless declared a share-root backup source.
    if path == "" and not is_backup_source:
        failures.append(
            f"{name}: remotePath is empty (the SHARE ROOT) but the PV is not "
            f"labelled homelab.internal/component: backup-source.\n"
            f"    An empty remotePath means every claimant sees the whole share. "
            f"If that is deliberate (ADR 0051 §D7), say so with the label."
        )

    # Invariant 3 — a dataset must be pre-bound to its claimant.
    claim = spec.get("claimRef")
    if not claim or not claim.get("namespace") or not claim.get("name"):
        failures.append(
            f"{name}: no claimRef. Without one, any PVC matching the class and "
            f"size can bind this dataset."
        )
    else:
        declared[name] = {
            "claim": (claim["namespace"], claim["name"]),
            "remote": remote,
            "path": path,
        }

    by_path.setdefault((remote, path), []).append(name)

# Invariant 1 — no two PVs on one path.
for (remote, path), names in sorted(by_path.items()):
    if len(names) > 1:
        failures.append(
            f"remotePath collision on {remote}:{path or '<SHARE ROOT>'} — "
            f"claimed by {len(names)} PVs: {', '.join(sorted(names))}.\n"
            f"    This is the ADR 0051 defect reproduced. Two datasets sharing "
            f"one directory is not something Kubernetes will warn about."
        )

claim_to_pv = {v["claim"]: k for k, v in declared.items()}

# ── Invariant 4 — every nas-crypt PVC in the workspace binds by volumeName ───
skipped_repos = []
checked_pvcs = 0

for entry in sorted(os.listdir(workspace_root)):
    repo = os.path.join(workspace_root, entry)
    if not os.path.isdir(repo) or entry.startswith(".") or entry.startswith("_"):
        continue

    for dirpath, dirnames, filenames in os.walk(repo):
        dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", ".venv", "vendor")]
        for fn in filenames:
            if not fn.endswith((".yaml", ".yml")):
                continue
            full = os.path.join(dirpath, fn)
            try:
                with open(full) as fh:
                    docs = list(yaml.safe_load_all(fh))
            except Exception:
                continue  # templates, helm values with unparseable YAML, etc.

            for doc in docs:
                if not isinstance(doc, dict) or doc.get("kind") != "PersistentVolumeClaim":
                    continue
                spec = doc.get("spec") or {}
                sc = spec.get("storageClassName") or ""
                if not sc.startswith("nas-crypt-"):
                    continue

                meta = doc.get("metadata") or {}
                ns = meta.get("namespace")
                nm = meta.get("name")
                rel = os.path.relpath(full, workspace_root)
                vol = spec.get("volumeName")

                if any(rel.startswith(p) for p in STALE_CENTRAL_COPIES):
                    stale_copies_seen.add(rel)
                    continue

                checked_pvcs += 1

                if (ns, nm) in PENDING_MIGRATION:
                    pending_seen.add((ns, nm))
                    if vol:
                        failures.append(
                            f"{rel}: PVC {ns}/{nm} already binds volumeName '{vol}', but it "
                            f"is still listed in PENDING_MIGRATION in this script.\n"
                            f"    The dataset has cut over — remove the line so the list "
                            f"keeps describing reality."
                        )
                    else:
                        continue  # legitimately not migrated yet

                if not vol:
                    failures.append(
                        f"{rel}: PVC {ns}/{nm} claims {sc} with no volumeName.\n"
                        f"    That is a dynamic provision. Under ADR 0051 it no longer "
                        f"allocates a dataset — it parks in _unallocated/. Bind the "
                        f"static PV by name instead."
                    )
                    continue

                if vol not in declared:
                    failures.append(
                        f"{rel}: PVC {ns}/{nm} binds volumeName '{vol}', which is not "
                        f"declared in infrastructure/csi-rclone/persistentvolumes.yaml."
                    )
                    continue

                want_ns, want_nm = declared[vol]["claim"]
                if (want_ns, want_nm) != (ns, nm):
                    failures.append(
                        f"{rel}: PVC {ns}/{nm} binds '{vol}', but that PV's claimRef "
                        f"names {want_ns}/{want_nm}. The binding will not happen."
                    )

# Report datasets whose owning repo is not checked out. Not a failure — a
# sibling repo may simply be absent — but it must be said out loud, because an
# unverified PVC is not a verified one.
for pv_name, info in sorted(declared.items()):
    ns, nm = info["claim"]
    repo_present = any(
        os.path.isdir(os.path.join(workspace_root, d))
        for d in (ns, f"{ns}-k8s")
    )
    if not repo_present and ns not in ("backup-cronjobs", "forgejo"):
        skipped_repos.append(f"{pv_name} -> {ns}/{nm} (no sibling repo for '{ns}')")

if skipped_repos:
    notes.append(
        "Sibling repos not checked out — their PVCs were not verified:\n    "
        + "\n    ".join(skipped_repos)
    )

# ── Report ───────────────────────────────────────────────────────────────────
print(f"nas-crypt datasets declared: {len(declared)}")
print(f"nas-crypt PVCs found in workspace: {checked_pvcs}")

still_pending = sorted(pending_seen)
if still_pending:
    print(f"pending migration (ADR 0051, not yet cut over): {len(still_pending)}")
    for ns, nm in still_pending:
        print(f"    - {ns}/{nm}")

stale = sorted(PENDING_MIGRATION - pending_seen)
if stale:
    notes.append(
        "PENDING_MIGRATION lists PVCs that were not found on disk — either they "
        "cut over and the manifest moved, or the sibling repo is absent:\n    "
        + "\n    ".join(f"{ns}/{nm}" for ns, nm in stale)
    )

if stale_copies_seen:
    print(f"skipped (superseded central copies, ADR 0001): {len(stale_copies_seen)}")
    for rel in sorted(stale_copies_seen):
        print(f"    - {rel}")

dead_rules = [
    p for p in STALE_CENTRAL_COPIES
    if not os.path.isdir(os.path.join(workspace_root, p))
]
if dead_rules:
    notes.append(
        "STALE_CENTRAL_COPIES names paths that no longer exist — the guarded "
        "cleanup happened. Drop these lines:\n    " + "\n    ".join(dead_rules)
    )

for note in notes:
    print(f"NOTE: {note}")

if failures:
    print()
    print(f"FAIL: {len(failures)} ADR 0051 violation(s):", file=sys.stderr)
    for f in failures:
        print(f"  - {f}", file=sys.stderr)
    sys.exit(1)

print("OK: every dataset has a unique path, a claimRef, and a matching PVC.")
PY
