# cluster-dns

In-cluster split-horizon DNS authority for the internal zone
(`<fqdn_suffix>`), per **[ADR 0044](../../../homelab-docs/02-decisions/0044-in-cluster-tailscale-subnet-router-and-dns.md)**.

A second **CoreDNS** instance — distinct from `kube-system/coredns`
(which serves `cluster.local`). It ports Flint3's Unbound split-horizon
config: a wildcard `redirect` of `*.<fqdn_suffix>` to the gateway VIP
`10.10.30.50`, plus per-host overrides for the router/switch/nodes. It
exists to move that resolver role off the 883 MB Flint3 router, which
was a single point of failure for all Tailscale-side `*.<fqdn_suffix>`
resolution.

## Shape

- **Deployment** — 2 replicas (spread across nodes), reusing the
  cluster's pinned `registry.k8s.io/coredns/coredns` image. Restricted
  PSS; binds `:53` via `NET_BIND_SERVICE`.
- **Service** — `LoadBalancer` on **10.10.30.53** (next free in the
  `homelab-ingress` pool), L2-announced on the servers VLAN via the
  `homelab.io/l2-announce` label, so it is reachable via **either**
  subnet router (in-cluster or the Flint3 fallback).
- **Corefile** — the zone name and per-host FQDNs use CoreDNS's
  `{$FQDN_SUFFIX}` env substitution; the env is filled at build time by
  the `components/site-config` replacement in `kustomization.yaml`, so
  **no domain literal is committed** (no `.j2` needed). `{{ .Name }}` in
  the Corefile is CoreDNS's own `template`-plugin Go template, not Jinja.
- **NetworkPolicy + CiliumNetworkPolicy** — default-deny (ADR 0036);
  ingress on `:53` allowed from `remote-node`/`host` because the
  LoadBalancer path arrives SNAT'd as a node identity.

## Scope / follow-ups

- **Authoritative-only** today (phase 2): out-of-zone queries are
  REFUSED. Moving the tailnet **global** resolver in-cluster (ADR 0044
  D4) means adding a `.:53 { forward . <upstream>; cache }` block plus
  the matching upstream egress allow.
- The **MagicDNS split-DNS** repoint (`<fqdn_suffix>` → 10.10.30.53) is
  a Tailscale-admin-console step (phase 4), operator-gated and instantly
  reversible.

No secrets — no ExternalSecret / OpenBao paths to seed.
