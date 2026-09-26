# Kargo release control plane

Chart 1.11.4 / Kargo v1.11.4 is mirrored with verified content in `charts.lock.yaml`;
its workload image is pinned by digest. Argo Rollouts chart 2.43.2 / v1.10.0
supplies AnalysisRuns. Application workloads remain Deployments.

The API uses the internal HTTPS Gateway and Authentik's public `homelab-kargo`
authorization-code/PKCE client. Its sole registered redirect is `/login` on the
Kargo origin; there is no CLI callback or client secret to provision. Authentik
admits only `operator`. Kargo maps that group to its read-only system user role;
it maps no principal to global admin, project creator or viewer roles. Project
read/promotion rights will be separately declared with the application pipeline.
The built-in admin, API Secret management, external webhooks, Dex, permissive CORS
and garbage collector are disabled.

The initial installation has **no Git/registry credentials and no Argo integration
or application RoleBinding**. The promotion controller's cluster-wide Secret
reading stays off. The separate trusted management controller retains upstream
project-lifecycle RBAC (including namespace/RBAC/Secret management); it is not a
sandbox. No Kargo Project, Warehouse, Stage or application verifier is installed
by this layer. Enabling those requires their own reviewed credential and RBAC
boundaries plus successful control-plane verification.

Each of the three namespaces has its own default-deny policy and existing budget
component; policy names differ from Kyverno's generated `default-deny`. Controller
egress is DNS/Kubernetes API only. The API additionally reaches the HTTPS Gateway
and its selected Authentik backend, with matching ingress on Authentik. Only the
API accepts Gateway ingress; the webhook accepts Kubernetes API traffic on 9443.
Admission rules affect Kargo resources and labeled Kargo project namespaces.
cert-manager supplies the internal webhook certificate.

The infrastructure ApplicationSet holds installation at manual sync. Use the
[bounded rollout helper](../argo-rollouts/README.md) for namespace, CRD and full
phases; observe the exact committed revision, CRD establishment, readiness and
image IDs. Prove the real Authentik round trip, non-operator rejection and a small
synthetic AnalysisRun before granting application promotion authority. The render
guard rejects mutable images, missing hardening/limits, default admin, global
Secret access, premature Argo writes and broad egress; ten defect mutations
exercise those checks.

References: [Kargo installation](https://docs.kargo.io/operator-guide/basic-installation),
[secure configuration](https://docs.kargo.io/operator-guide/security/secure-configuration),
[OIDC](https://docs.kargo.io/operator-guide/security/openid-connect),
[access controls](https://docs.kargo.io/user-guide/security/access-controls).

The initial installation is accepted at `cbfa1a6726765f43f013dcdeccf76ad7d6dcc1c3`:
Argo is Synced/Healthy with an actual successful operation; nine CRDs are Established,
four pods are Ready at the pinned image, and certificate/route checks pass. The live
Authentik/HTTPS helper passes 18 protocol, admission and API checks with rolled-back
synthetic users. Six Kubernetes authorization reviews confirm read access and deny
project creation, promotion, staging secrets, cluster-wide Secret listing and Argo
writes for the relevant mapped user/controller. Existing confidential blueprint
renders are byte-for-byte unchanged. The injected session is distinct from real
browser login, which remains pending. No application promotion is enabled.

Run `python3 scripts/verify-release-controller-bootstrap.py --revision FULL_COMMIT_SHA`
to verify exact-revision operations, CRDs, images, readiness, webhook certificate,
route, the retained synthetic AnalysisRun/Job and effective Kubernetes permissions.
It is a read-only bootstrap check, expected to require revision as app promotion
rights are deliberately introduced later. It prints only safe evidence fields.
