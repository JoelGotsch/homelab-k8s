# Trivy Operator

Continuous CVE / config-audit / exposed-secret scanning of running
images. Per [ADR 0019 D2][adr0019].

[adr0019]: https://github.com/JoelGotsch/homelab-docs/blob/main/adrs/0019-supply-chain-vulnerability-hygiene.md

---

## What it does

Watches every Deployment / StatefulSet / DaemonSet / ReplicaSet /
CronJob / Job / Pod / ReplicationController in the cluster (except
the namespaces in `excludeNamespaces`), and for each unique image:

1. Spawns a short-lived **scan job** in `trivy-system` that runs
   `trivy image <ref>` against the upstream Trivy CVE database.
2. Persists the result as a `VulnerabilityReport` CRD in the
   workload's own namespace.
3. Also writes `ConfigAuditReport` (chart / manifest issues),
   `ExposedSecretReport` (leaked tokens/keys), and
   `RbacAssessmentReport` (over-permissive RBAC) CRDs per workload.

Findings flow into Prometheus via the operator's `/metrics`
endpoint (counter family `trivy_image_vulnerabilities`); alert
rules in `prometheusrule.yaml` route CRITICAL findings to the
operator's approval-channel route and HIGH findings to the
warning route.

## Out of scope (intentionally)

- **InfraAssessmentReport / ClusterComplianceReport.** Both need
  the upstream `node-collector` DaemonSet, which hostPath-mounts
  `/var/lib/etcd`, `/var/lib/kubelet`, `/var/lib/kube-scheduler`,
  `/var/lib/kube-controller-manager`, `/etc/kubernetes`,
  `/etc/cni/net.d`, `/etc/systemd`, `/lib/systemd`. Talos's
  read-only root + minimal `/etc` means none of those paths are
  mountable into a Pod, and the CIS-K8s benchmark on Talos is the
  Talos team's contract — we don't double-score it. Disabled via
  `operator.infraAssessmentScannerEnabled: false` and
  `operator.clusterComplianceEnabled: false`.
- **`ci-woodpecker` namespace.** Ephemeral CI pods churn faster
  than the operator's scan cadence and the resulting reports are
  noise. Excluded via `excludeNamespaces`.

## kv paths

None at first deploy. Optional cold-start lever IF GitHub-rate-
limits the trivy-db OCI download (signal: scan jobs erroring on
`429 Too Many Requests` from ghcr.io):

| Trivy field | Suggested kv path | Notes |
| --- | --- | --- |
| `trivy.githubToken` | `kv/shared/trivy-operator/github-token` | Read-only PAT, public-scope only — used purely to raise the unauthenticated rate limit. Use the chart's `trivy.existingSecret: true` + a Secret named `trivy-operator-trivy-config` populated by ESO. |

We are NOT setting this on first deploy because the homelab image
count + scan cadence is comfortably below the unauthenticated
rate limit. Revisit if the `TrivyOperatorNoReports` alert fires
with rate-limit errors in scan-job logs.

## Cold-start notes

1. **First scan after fresh deploy takes ~10 min.** Each scan job
   downloads the full trivy-db (~50 MB compressed) on first run.
   Subsequent jobs share the cached DB until expiry (built-in
   24h refresh).

2. **Verify the operator is healthy:**
   ```sh
   kubectl -n trivy-system get pod -l app.kubernetes.io/name=trivy-operator
   kubectl -n trivy-system logs deploy/trivy-operator | tail -50
   ```
   Expect `1/1 Running` and a steady stream of `Reconciled` log
   lines as workloads are scanned.

3. **Verify Reports are landing in workload namespaces:**
   ```sh
   kubectl get vulnerabilityreport -A
   kubectl get configauditreport -A
   kubectl get exposedsecretreport -A
   ```
   Expect a Report per (workload, container) pair across the
   cluster within ~15 min of deploy.

4. **Verify Prometheus is scraping:**
   ```sh
   kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
   # then in a browser: localhost:9090/targets — filter "trivy"
   ```
   The `trivy-system/trivy-operator` target should be `UP`.

5. **Inspect a Report manually:**
   ```sh
   kubectl -n <ns> get vulnerabilityreport <name> -o yaml | yq \
     '.report.vulnerabilities[] | select(.severity=="CRITICAL")'
   ```

## Network egress

`trivy-system` is default-deny. The egress allowed:

- **kube-DNS** (vanilla NetworkPolicy + Cilium L7 DNS for FQDN
  cache).
- **kube-API** :443 + :6443 (Cilium socket-LB DNATs the Service
  hop; both ports allowed per the recurring CNPG-on-Cilium
  pattern in this repo).
- **External registries** for trivy-db, the operator image, the
  trivy image, and every image-under-scan: ghcr.io,
  mirror.gcr.io, registry-1.docker.io, index.docker.io, quay.io,
  registry.k8s.io, public.ecr.aws, plus their blob-storage
  CDNs. FQDN-gated by `ciliumnetworkpolicy-egress.yaml`.

If a future workload pulls from a registry not in that list, its
scan job will fail with a connection-refused / DNS-block error
in Cilium's L7 DNS proxy log. Add the FQDN to
`ciliumnetworkpolicy-egress.yaml`.

## Prometheus alerts

- **TrivyCriticalCVEOnDeployedImage** (critical) — any image
  with ≥1 CRITICAL CVE for 30m. Routes to ntfy AND the
  approval-channel via the Signal bridge.
- **TrivyManyHighCVEOnDeployedImage** (warning) — image with
  >5 HIGH CVEs for 2h. Routes to ntfy only.
- **TrivyOperatorNoReports** (warning) — zero
  `VulnerabilityReport` CRDs cluster-wide for 6h; signals
  operator broken or trivy-db rate-limited. Routes to ntfy.

## Renovate

The chart is pinned by `# OPERATOR PINS via Renovate` next to
`version:` in `kustomization.yaml`. Renovate picks up new
`trivy-operator` chart releases from the Aqua repo via the
`helm-charts-minor` group; majors are not held back.

## Talos-specific gotchas

1. **Node-collector unusable** — see "Out of scope" above. Scope
   is the per-image CVE / config-audit / secret scanning; the
   node-CIS-benchmark scanner is Talos's job.
2. **Scan-job hostPath usage is zero** in our config. The chart
   defaults to non-host scan jobs; we leave that intact + emptied
   the `nodeCollector.volumes` / `volumeMounts` lists as a belt-
   and-suspenders against a future chart-default flip.
3. **Pod-security baseline (not restricted)** on `trivy-system`
   — see the comment in `namespace.yaml`. Scan jobs would pass
   restricted; the namespace label leaves headroom for a future
   private-registry-CA mount.
