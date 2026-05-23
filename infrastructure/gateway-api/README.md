# Gateway API CRDs (v1.4.1)

Upstream Gateway API CRDs for Cilium's Gateway support. Pinned
copies committed here instead of pulled at sync-time so:

1. We don't depend on raw.githubusercontent.com reachability
   from the cluster at sync-time, and
2. kustomize's URL heuristic doesn't try to `git fetch`
   github.com-hosted URLs.

These MUST land before any HTTPRoute / Gateway CR in the
cluster, since the resources reference these CRDs by GVK.
sync-wave -20 (before infrastructure default of -10).

Refresh sequence: bump Cilium → check
`https://docs.cilium.io/en/v<X.Y>/network/servicemesh/gateway-api/`
for the required Gateway API CRD version → download the
standard/* CRDs from
`https://github.com/kubernetes-sigs/gateway-api/tree/v<W.X.Y>/config/crd`
→ commit → push.

Per [Cilium 1.19 docs](https://docs.cilium.io/en/v1.19/network/servicemesh/gateway-api/gateway-api/),
Cilium does NOT install these CRDs itself even with
`gatewayAPI.enabled: true` — the operator must install them
first.

Files here:

- `gatewayclasses.yaml` — `gateway.networking.k8s.io/GatewayClass` (mandatory)
- `gateways.yaml` — `gateway.networking.k8s.io/Gateway` (mandatory)
- `httproutes.yaml` — `gateway.networking.k8s.io/HTTPRoute` (mandatory)
- `grpcroutes.yaml` — `gateway.networking.k8s.io/GRPCRoute` (mandatory)
- `referencegrants.yaml` — `gateway.networking.k8s.io/ReferenceGrant` (cross-namespace ingress)
- `tlsroutes.yaml` — `gateway.networking.k8s.io/TLSRoute` (experimental; used for TLS passthrough)
