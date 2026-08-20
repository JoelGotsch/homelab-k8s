# cluster-dns

In-cluster split-horizon DNS authority for the internal zone
(`<fqdn_suffix>`), per **[ADR 0044](../../../homelab-docs/02-decisions/0044-in-cluster-tailscale-subnet-router-and-dns.md)**.

A second **CoreDNS** instance — distinct from `kube-system/coredns`
(which serves `cluster.local`). It ports Flint3's Unbound split-horizon
config: a wildcard `redirect` of `*.<fqdn_suffix>` to the gateway VIP
`10.10.30.50`, plus per-host overrides for the router/switch/nodes — and
recurses for everything else over DoT, so it is also the tailnet's
primary global resolver. It exists to move both resolver roles off the
883 MB Flint3 router, which was a single point of failure for all
Tailscale-side name resolution (not just `*.<fqdn_suffix>`: with
"Override local DNS" on, a dead Flint3 `tailscaled` took google.com down
for every tailnet client too).

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

## Scope

- **Authority + global resolver** (since 2026-08-20, ADR 0044 D4). Two
  server blocks: `<fqdn_suffix>:53` serves the zone file; `.:53`
  forwards everything else over DNS-over-TLS to Quad9 (`9.9.9.9`,
  `149.112.112.112`, SNI `dns.quad9.net`) with a 300 s cache and
  serve-stale. Quad9 only — CoreDNS's `tls_servername` is per forward
  block, so the two-provider list Flint3's Unbound uses cannot be
  expressed in one block; Quad9 was kept (EU-first). The NetworkPolicy
  allows exactly those two IPs on 853/tcp.
- The `.:53` block deliberately has **no `log`**: it would record every
  name every tailnet device resolves (`personal`, ADR 0003).
- The tailnet side — global nameservers `[10.10.30.53, 100.67.210.7]`,
  split DNS for `<fqdn_suffix>` to the same pair — is declared in the
  `tailnet-policy` repo (`dns.json`) and applied by its `tailnet.sh`
  (ADR 0054); it is not a console step any more.
- Verify from a tailnet device (via the subnet route):
  `dig @10.10.30.53 immich.<fqdn_suffix> +short` → `10.10.30.50`, and
  `dig @10.10.30.53 example.com +short` → a public answer.

No secrets — no ExternalSecret / OpenBao paths to seed.
