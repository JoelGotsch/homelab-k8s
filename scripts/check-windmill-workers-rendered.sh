#!/usr/bin/env bash
# Cross-repo guard for the external Windmill Application source. The owning
# repo also runs this check locally; this wrapper keeps the app-of-apps source
# switch honest when homelab-k8s is committed independently.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
workspace_root="$(cd "$repo_root/.." && pwd)"
exec "$workspace_root/windmill-k8s/scripts/check-workers-rendered.sh"
