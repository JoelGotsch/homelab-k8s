# Gateway API CRDs (v1.6.1, standard channel)

Upstream Gateway API CRDs for Cilium's Gateway support. Pinned
copies committed here instead of pulled at sync-time so:

1. We don't depend on raw.githubusercontent.com reachability
   from the cluster at sync-time, and
2. kustomize's URL heuristic doesn't try to `git fetch`
   github.com-hosted URLs.

These MUST land before any HTTPRoute / Gateway CR in the
cluster, since the resources reference these CRDs by GVK.
sync-wave -20 (before infrastructure default of -10).

Per [Cilium 1.20 docs](https://docs.cilium.io/en/v1.20/network/servicemesh/gateway-api/gateway-api/),
Cilium does NOT install these CRDs itself even with
`gatewayAPI.enabled: true` — the operator must install them
first. **Cilium 1.20 requires Gateway API v1.6.1 as a minimum**,
and upstream requires the CRDs to be upgraded *before* Cilium.

## Refresh sequence

Bump Cilium → check the Gateway API version that Cilium release
requires → take the **whole standard channel** from the release
artifact and split it per CRD → commit → push.

```sh
curl -sL -o /tmp/ga.yaml \
  https://github.com/kubernetes-sigs/gateway-api/releases/download/v<W.X.Y>/standard-install.yaml
# split per CRD by `metadata.name`, one file per kind, verbatim upstream text
```

Take the release artifact, not `config/crd` from the source tree:
the artifact is what upstream tests and ships, and it carries the
`gateway.networking.k8s.io/bundle-version` and `/channel`
annotations that make the installed version checkable:

```sh
kubectl get crd gateways.gateway.networking.k8s.io \
  -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}{"\n"}'
```

### Before replacing a CRD in place, check stored versions

An in-place replacement is rejected if a version listed in
`status.storedVersions` is absent from the new `spec.versions`.
Check every CRD, not just the ones you think changed:

```sh
for c in gatewayclasses gateways httproutes grpcroutes referencegrants \
         tlsroutes backendtlspolicies listenersets tcproutes udproutes; do
  printf '%-20s ' "$c"
  kubectl get crd $c.gateway.networking.k8s.io -o jsonpath='{.status.storedVersions}{"\n"}' 2>/dev/null
done
```

At the v1.4.1 → v1.6.1 bump this mattered for exactly one CRD:
`tlsroutes` stored `v1alpha3`, and v1.6.1 promotes TLSRoute to the
standard channel with storage `v1`. It is safe only because v1.6.1
still *lists* `v1alpha2`/`v1alpha3` as `served: false` — being
listed is what the API server requires. The storage version does
change, so any existing TLSRoute objects would need a storage
migration; there were **zero** in the cluster, so there was nothing
to migrate. `status.storedVersions` keeps reporting `v1alpha3`
until a migration runs, which is harmless at zero objects and is
*not* evidence the upgrade failed.

## Files here

All ten CRDs of the v1.6.1 **standard** channel are vendored. The
three marked *unused* are installed so the next person who wants
one does not have to repeat this refresh; Cilium 1.20 supports all
ten.

- `gatewayclasses.yaml` — `GatewayClass` (mandatory)
- `gateways.yaml` — `Gateway` (mandatory)
- `httproutes.yaml` — `HTTPRoute` (mandatory)
- `grpcroutes.yaml` — `GRPCRoute` (mandatory)
- `referencegrants.yaml` — `ReferenceGrant` (cross-namespace ingress)
- `tlsroutes.yaml` — `TLSRoute` (standard as of v1.6.1; was experimental at v1.4.1)
- `backendtlspolicies.yaml` — `BackendTLSPolicy` — **the reason for this bump.**
  Lets the gateway re-encrypt to a TLS-serving backend instead of
  forwarding plaintext. Used by `platform/openbao`.
- `listenersets.yaml` — `XListenerSet` (unused)
- `tcproutes.yaml` — `TCPRoute` (unused)
- `udproutes.yaml` — `UDPRoute` (unused)
