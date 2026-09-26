# Argo Rollouts verification controller

Pinned chart 2.43.2 / controller v1.10.0 supplies namespaced AnalysisRuns for
Kargo. The application remains a Deployment. The chart is mirrored and content
verified through `charts.lock.yaml`; the controller image is digest pinned.

The first installation is held at manual sync by the infrastructure ApplicationSet.
One restricted controller has bounded resources and only DNS/API egress. No
public dashboard, provider credential or application verification Job is installed
by this layer. The retained `controller-bootstrap-v1` AnalysisRun executes one
synthetic, tokenless Python Job with 64 MiB/100m limits and a 180-second deadline.
Its separate service account has no RBAC bindings, volumes or egress grants.
This proves the AnalysisRun-to-Job path only; it does not qualify an app candidate.

Kubernetes RBAC comes from the pinned upstream controller chart;
AnalysisRun Jobs receive their own explicit, narrower service account and policy.

Install and verify this layer before enabling application promotion. Observe the
committed Argo revision, CRD establishment, controller readiness and image ID, then
run the separate synthetic verification rehearsal. A successful chart render does
not establish controller readiness or application qualification.

Upstream: [installation](https://argo-rollouts.readthedocs.io/en/stable/installation/).

From a clean published checkout, `python3 scripts/release-controller-rollout.py
argo-rollouts status --revision FULL_COMMIT_SHA` reports safe status fields.
Use `preflight --phase namespace`, then `sync --phase namespace --dry-run --apply`,
observe `status`, and `sync --phase namespace --apply`. Repeat preflight/dry-run/
observation/actual sync for `--phase crds`, then `--phase all`. Each sync refuses
an active operation, source drift, an absent manual hold or an unobserved dry-run.
The script checks both production contexts and uses a private temporary kubeconfig.
It neither prunes resources nor terminates active operations.

The retained AnalysisRun is observed Successful at
`cbfa1a6726765f43f013dcdeccf76ad7d6dcc1c3`; its one Job exited zero at the pinned
Python digest. The pod has no token, volumes, credentials or namespaced egress
grants. `python3 scripts/verify-release-controller-bootstrap.py --revision
FULL_COMMIT_SHA` checks its owner chain, exit, image and live policies alongside
both control planes. This is infrastructure acceptance, not candidate qualification.
