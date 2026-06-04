# infrastructure/spegel

Peer-to-peer container image cache per
[ADR 0019 D4](../../../homelab-docs/02-decisions/0019-forgejo-packages-as-artifact-registry.md).

Spegel runs as a DaemonSet on every node, advertises locally-
cached images to peers via a libp2p mesh, and serves cache
hits over the cluster network. Mitigates the homelab's 1 GbE
WAN link during mass-restart and image-pull bursts: the first
node to pull a given image serves it to its peers rather than
every node racing back to the upstream registry.

## Layout

- `kustomization.yaml` — inflates upstream `spegel` Helm chart
  from `oci://ghcr.io/spegel-org/helm-charts` (chart 0.3.0 /
  appVersion v0.3.0).
- `values.yaml` — chart values, including the **Talos-specific
  containerd path overrides** (see "Talos compatibility" below).
- `namespace.yaml` — `spegel` ns, PSA `privileged` (host-path
  mounts + hostPort).
- `networkpolicy.yaml` — standard K8s NetworkPolicy: ingress
  Prometheus + peer mesh; egress kube-DNS + peer mesh.
  No `CiliumNetworkPolicy` needed — Spegel v0.3.0 uses DNS
  bootstrap (no kube-apiserver egress).
- ServiceMonitor is rendered by the chart
  (`serviceMonitor.enabled: true` in values).
- Grafana dashboard is rendered by the chart
  (`grafanaDashboard.enabled: true`) and discovered by
  kube-prometheus-stack's Grafana sidecar.

## Talos compatibility — important

Spegel's chart-default `containerdRegistryConfigPath` is
`/etc/containerd/certs.d` (vanilla containerd). **Talos uses a
different path.** Verified on Talos v1.13.0 (kernel
6.18.24-talos, containerd 2.2.3) via
`talosctl read /etc/cri/conf.d/cri.toml`:

```toml
[plugins.'io.containerd.cri.v1.images'.registry]
  config_path = '/etc/cri/conf.d/hosts'
```

`values.yaml` therefore sets:

```yaml
spegel:
  containerdSock: /run/containerd/containerd.sock
  containerdNamespace: k8s.io
  containerdRegistryConfigPath: /etc/cri/conf.d/hosts
  containerdContentPath: /var/lib/containerd/io.containerd.content.v1.content
  containerdMirrorAdd: true
  prependExisting: true
```

### Talos machine-config patch: NOT required

`/etc/cri/conf.d/hosts` is a tmpfs-backed directory on Talos
that is already pointed to by containerd's CRI plugin (verified
above). Spegel's initContainer creates per-registry subdirs
(`<registry>/hosts.toml`) via the hostPath mount, and
containerd picks them up without restart.

**No `machine.registries.mirrors` block is required**, and
**no `machine.files` patch is required.** The two ways this
could change:

1. If you later add a `machine.registries.mirrors` block (e.g.
   to route a registry through a corporate proxy), Talos will
   render its own files into the same dir. Spegel's
   `prependExisting: true` setting (above) makes Spegel
   prepend rather than replace, so the two coexist.
2. If a future Talos release moves the path (it has changed
   once already, from `/etc/cri/conf.d/` to
   `/etc/cri/conf.d/hosts`), re-verify with
   `talosctl read /etc/cri/conf.d/cri.toml` and update
   `containerdRegistryConfigPath` accordingly.

### Talos gotchas worth flagging

- **Don't trust the chart's default path on Talos.** The
  upstream `spegel.dev` getting-started guide assumes vanilla
  containerd at `/etc/containerd/certs.d`. On Talos that
  directory doesn't exist; the initContainer would silently
  create it and write mirror configs that containerd never
  reads. Cache would be inert — no errors, no metrics —
  until pull failures during an outage surface the silence.
  (Helm-wrong-key-silently-dropped class of bug, memory
  feedback_helm_wrong_key_silently_dropped.)
- **containerd 2.x uses CRI v1.** Confirmed on v0.3.0 of the
  chart (uses `plugins.'io.containerd.cri.v1.images'`). Older
  Spegel versions may target containerd 1.x CRI paths.
- **Tag-resolve depends on the upstream registry being
  reachable for the first node.** Spegel resolves tags to
  digests by querying upstream; subsequent pulls hit peer
  cache. If the upstream is fully unreachable, the **first**
  pull of a given tag fails. ADR 0019 explicitly accepts this
  ("first pull goes to upstream").
- **Spegel does NOT pull from upstream itself.** It only
  serves bytes that containerd has already stored locally
  (via the read-only `containerdContentPath` mount). Don't
  read NetworkPolicy egress rules expecting to see registry
  egress — there isn't any.
- **Mirror-config cleanup depends on the Helm post-delete
  hook firing.** Spegel writes `_default/hosts.toml` into
  `/etc/cri/conf.d/hosts` (a host-mounted dir Argo / kubectl
  cannot see). The chart's `post-delete` hook spins up a
  one-shot DaemonSet to remove the file on each node. If you
  ever bypass Helm (raw `kubectl delete -f` against rendered
  YAML, or `kubectl delete ns spegel` before the hook
  finishes), the hostPath file leaks: every subsequent
  containerd pull will spend ~200ms timing out against the
  defunct Spegel hostPort before falling through to upstream.
  To recover, re-install Spegel and then `helm uninstall` it
  properly. **Argo CD removes the chart via Helm, so this
  only bites if you do manual surgery.** Verified during
  bring-up.

## Verification

```sh
# DaemonSet rolled out on every node:
kubectl -n spegel get ds spegel
# Expect: DESIRED == CURRENT == READY == <node count>

# Per-pod health:
kubectl -n spegel get pods -o wide

# Mirror config landed on each Talos node:
talosctl --nodes <node-ip> ls /etc/cri/conf.d/hosts
# Expect: one subdir per upstream registry the cluster has
# pulled from (docker.io/, ghcr.io/, registry.k8s.io/, …).

# ServiceMonitor scrape working:
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# In Prometheus UI: query `spegel_advertised_keys`,
# `spegel_mirror_requests_total{cache="hit"}`.
```

Cache-hit smoke test:

```sh
# Force a fresh image pull on one node:
NODE_A=worker1
NODE_B=worker2
IMAGE=ghcr.io/jellyfin/jellyfin:10.10.0  # pick anything new
kubectl debug node/$NODE_A -it --image=$IMAGE -- true
# Then force the SAME image on a different node:
kubectl debug node/$NODE_B -it --image=$IMAGE -- true
# Check spegel logs on $NODE_B:
kubectl -n spegel logs ds/spegel --tail=100 \
  --field-selector spec.nodeName=$NODE_B \
  | grep -i "mirror"
# Expect a "mirror hit" log line referencing the digest.
```

## Sync wave / Argo wiring

Picked up automatically by `bootstrap/applicationsets/infrastructure.yaml`
(git-directories generator). Sync wave -10 (infrastructure
layer). No Argo Application file in this directory.

## OpenBao paths to seed

None. Spegel has no secret material. Bypass `check-eso-readme.sh`
gracefully — there is no `ExternalSecret` in this layer.

## Related

- [ADR 0019](../../../homelab-docs/02-decisions/0019-forgejo-packages-as-artifact-registry.md) D4, D6.
- [ADR 0016](../../../homelab-docs/02-decisions/0016-longhorn-for-cluster-storage.md) — 1 GbE constraint motivating peer cache.
- Upstream: https://github.com/spegel-org/spegel
