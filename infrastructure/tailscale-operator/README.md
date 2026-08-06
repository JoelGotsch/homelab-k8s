# tailscale-operator

In-cluster **Tailscale Kubernetes operator** running the subnet-router
role, per **[ADR 0044](../../../homelab-docs/02-decisions/0044-in-cluster-tailscale-subnet-router-and-dns.md)**.

The operator reconciles the `Connector` (`connector.yaml`) into a
`tailscaled` subnet-router pod that advertises the servers VLAN
`10.10.30.0/24` into the tailnet. It displaces Flint3's 883 MB
`tailscaled` — which OOM-crash-looped under bulk throughput — as the
**primary** subnet router; Flint3 stays a **fallback** advertiser of the
same route. This is the "subnet-router pod" that
`observability/crowdsec/httproute.yaml` anticipated.

## Shape

- Chart `tailscale-operator` (Tailscale Helm repo), pinned; `installCRDs:
  true` ships the `Connector`/`ProxyClass` CRDs.
- Namespace `tailscale` runs **privileged** PSS — the subnet-router pod
  needs elevated networking (NET_ADMIN/tun); a documented exception like
  cilium/longhorn.
- Auth: an **OAuth client** (not a static auth key). With the Helm
  `oauth` block unset, the operator reads the `operator-oauth` Secret,
  which the ESO projects from OpenBao.
- `apiServerProxyConfig.mode: "false"` — subnet routing only; the
  Kubernetes API is NOT exposed over the tailnet.
- Egress/ingress via a permissive namespace-scoped CiliumNetworkPolicy
  (connector pods reach arbitrary DERP/WireGuard peers and forward to the
  whole servers VLAN).

## Tailscale admin console prerequisites (not in git)

- OAuth client with **Devices: write** + **Auth Keys: write**, tag
  `tag:k8s-router` (its `client_id`/`client_secret` seed the path below).
- ACL: `tag:k8s-router` in `tagOwners`, and an `autoApprovers.routes`
  entry `"10.10.30.0/24": ["tag:k8s-router"]` so the advertised route
  self-approves (else approve once in the admin console).

## OpenBao paths to seed

| Path | Keys | Notes |
|---|---|---|
| `kv/shared/tailscale-operator` | `client_id`, `client_secret` | Tailscale OAuth client (KB 1215). Projected by ESO into the `operator-oauth` Secret the operator reads. |

## Follow-ups

- HA: bump `Connector.spec.replicas` once the single router is proven.
- Moving the tailnet **global** resolver in-cluster (ADR 0044 D4) is a
  separate `cluster-dns` change, not here.
