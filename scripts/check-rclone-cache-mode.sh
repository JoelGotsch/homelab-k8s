#!/usr/bin/env bash
# Refuse `vfs-cache-mode=writes` on a csi-rclone PersistentVolume unless the PV
# itself carries an explicit, reasoned exemption annotation.
#
# WHY THIS EXISTS
#
# On 2026-08-29 and again on 2026-08-30, `blob-origins.jsonl` on
# `nas-internal-archive-conversation-history-vault` was destroyed: 45,895,680 of
# 45,909,540 bytes replaced by NUL, leaving 29 of 84,447 lines. Both corrupt
# copies shared a byte-identical NUL prefix of 45,895,680 = 11,205 x 4096, on
# files of different total size — the whole prior object zeroed, with only the
# freshly-appended tail surviving.
#
# Mechanism: under `vfs-cache-mode=writes`, opening an existing remote object
# for append makes rclone materialise the entire object in its cache (fetch,
# modify, upload it all back on close). These remotes are crypt over SMB. When
# the cache entry is evicted and the re-fetch does not complete, the un-fetched
# region reads as zeros and close() persists them. A file appended once per
# blob dies; `manifest.jsonl` on the same mount, appended once per night,
# survived untouched.
#
# WHY AN ANNOTATION AND NOT AN ALLOWLIST IN THIS SCRIPT
#
# A list of exempt names inside the checker is invisible to the person reading
# the manifest, and this workspace has already been bitten by exemption lists
# that silently stopped matching what they were meant to cover. Putting the
# exemption on the PV means the next reader of the PV sees the hazard and the
# reason, and a NEW PV cannot inherit an exemption by accident.
#
# To exempt a PV, add to its metadata.annotations:
#
#   homelab.internal/rclone-cache-mode-exemption: "why this one is safe or
#     why it has not been migrated yet, and what tracks the migration"
#
# Correct fix, where the workload allows it: `vfs-cache-mode=full`, which keeps
# a chunk-presence map instead of treating absent regions as zeros. That is
# mitigation, not a cure — the read-modify-write remains. The cure is that
# nothing reopens an existing object for write on these mounts at all.
#
# See `homelab/plans/conversation-history-ledger-durability.md` §6.2 / §12.2.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:-$ROOT/infrastructure/csi-rclone/persistentvolumes.yaml}"

if [[ ! -f "$TARGET" ]]; then
  echo "check-rclone-cache-mode: no such file: $TARGET" >&2
  exit 1
fi

python3 - "$TARGET" <<'PY'
import re
import sys

path = sys.argv[1]
raw = open(path, encoding="utf-8").read()

# Split on document separators at column 0 only; a "---" inside a block scalar
# is not a document break.
docs = re.split(r"(?m)^---\s*$", raw)

ANN = "homelab.internal/rclone-cache-mode-exemption"

problems = []
checked = 0
exempted = []

for doc in docs:
    if not re.search(r"(?m)^kind:\s*PersistentVolume\s*$", doc):
        continue
    name_m = re.search(r"(?m)^\s{2}name:\s*(\S+)", doc)
    name = name_m.group(1) if name_m else "<unnamed>"
    checked += 1

    # Only mountOptions entries count. A `vfs-cache-mode` mentioned inside a
    # comment must not trip the check — that is exactly how the explanatory
    # comments in this file are written.
    modes = re.findall(r"(?m)^\s*-\s*vfs-cache-mode=(\S+)\s*$", doc)
    if not modes:
        continue
    if len(set(modes)) > 1:
        problems.append(f"{name}: conflicting vfs-cache-mode values {sorted(set(modes))}")
        continue
    mode = modes[0]
    if mode != "writes":
        continue

    m = re.search(rf"(?m)^\s*{re.escape(ANN)}:\s*(.+)$", doc)
    if not m:
        problems.append(
            f"{name}: uses vfs-cache-mode=writes with no "
            f"`{ANN}` annotation. This mode destroyed a 45 MB ledger twice in "
            f"three days (2026-08-29, 2026-08-30). Use vfs-cache-mode=full, or "
            f"annotate the PV with why this one is safe."
        )
        continue
    reason = m.group(1).strip().strip('"').strip("'")
    if len(reason) < 25:
        problems.append(
            f"{name}: `{ANN}` is present but says too little ({reason!r}). "
            f"State why it is safe or what tracks its migration."
        )
        continue
    exempted.append((name, reason))

if checked == 0:
    print("check-rclone-cache-mode: FAIL — parsed no PersistentVolume documents", file=sys.stderr)
    print("  (the file moved or its shape changed; this check was silently passing)", file=sys.stderr)
    raise SystemExit(1)

if problems:
    for p in problems:
        print(f"FAIL: {p}", file=sys.stderr)
    raise SystemExit(1)

print(f"check-rclone-cache-mode OK — {checked} PersistentVolume(s) checked")
for name, reason in exempted:
    short = reason if len(reason) <= 88 else reason[:85] + "..."
    print(f"  exempt (still on `writes`): {name}\n      {short}")
PY
