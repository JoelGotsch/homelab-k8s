# generic-device-plugin

Node agent (DaemonSet, workers only) that advertises host device nodes as
Kubernetes **extended resources**, so a pod in a Pod-Security-`restricted`
namespace can receive a GPU render node without `hostPath`.

| Resource | Host path | Per-node capacity | Consumer |
|---|---|---|---|
| `devic.es/amd-render` | `/dev/dri/renderD128` | 4 (containers, not streams) | Jellyfin VA-API (`jellyfin-k8s/k8s/values.yaml`) |

Upstream: <https://github.com/squat/generic-device-plugin>, image
`ghcr.io/squat/generic-device-plugin:0.2.0` (digest-pinned in
`daemonset.yaml`). Plan and evidence: `homelab/plans/jellyfin-gpu-transcoding.md`.

## Why

- **PSS.** The `jellyfin` namespace enforces `restricted`. PSS forbids
  `spec.volumes[*].hostPath` from `baseline` up, so the 2026-08-15 idea of
  hostPath-mounting `/dev/dri/renderD128` would have been rejected at
  admission (`FailedCreate`, zero pods). Device plugins hand the device to the
  container through the CRI device list, which no PSS rule restricts.
- **Scheduling for free.** A worker without `/dev/dri/renderD128` (no
  `amdgpu` Talos extension yet) advertises `0`; a pod requesting `1` only
  lands where the device exists and otherwise stays `Pending` with
  `Insufficient devic.es/amd-render`. No temporary nodeSelector pin while
  the workers roll one at a time, and no silent fallback to CPU.
- **Not the upstream chart.** Chart 0.1.2 hard-codes its device list in the
  template; there is no values key for devices.

## How it works

- `daemonset.yaml` runs one pod per worker with `/var/lib/kubelet/device-plugins`
  (registration socket) and `/dev` (read-only, discovery) hostPath-mounted —
  hence the namespace is `privileged` PSA. The **container** is not
  privileged: root uid, all capabilities dropped, read-only rootfs.
- `--domain=devic.es` is passed explicitly (0.2.0 changed the default from
  `squat.ai`; a later default change must not rename the resource).
- `count: 4` lets four containers on one node hold the render node at once.

## Verify

```sh
# registered on every worker (0 until the worker runs the amdgpu schematic)
kubectl get nodes -l '!node-role.kubernetes.io/control-plane' \
  -o custom-columns='NODE:.metadata.name,AMD_RENDER:.status.allocatable.devic\.es/amd-render'
kubectl -n generic-device-plugin logs ds/generic-device-plugin --tail=20
```

A `restricted`-compliant smoke test (plan §6.3): a non-root pod requesting
`devic.es/amd-render: 1` with the `jellyfin/jellyfin` image, running
`ls -ln /dev/dri && /usr/lib/jellyfin-ffmpeg/vainfo`, must land on a rolled
worker by itself and print `VAProfileHEVCMain10 : VAEntrypointVLD` and
`VAProfileH264Main : VAEntrypointEncSlice`.

## Caveats

- Allocations survive a plugin restart (the kubelet checkpoints them); a
  plugin that is down only blocks **new** placements.
- On Talos the render node is `crw-rw-rw- root root` (stock udev rule
  `MODE="0666"`, no `/etc/group`), so consumers need no `supplementalGroups`.
  Observe on the first rolled worker before relying on it.
- Adding a second device type is one more `--device` block here plus a
  README row; do not widen `count` without checking the consumer's engine
  contention (VCN 2.x: one decode + one encode engine per iGPU).
