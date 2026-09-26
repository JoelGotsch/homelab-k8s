#!/usr/bin/env python3
"""Reject release-controller credential, privilege and identity drift in actual Helm renders."""

import copy
from pathlib import Path
import re
import subprocess
import yaml

ROOT = Path(__file__).resolve().parents[1]


def require(value, message):
    if not value:
        raise ValueError(message)


def check(docs):
    index = {(d["kind"], d["metadata"]["name"]): d for d in docs}
    deployments = [d for d in docs if d["kind"] == "Deployment"]
    require(
        {d["metadata"]["name"] for d in deployments}
        == {
            "argo-rollouts",
            "kargo-api",
            "kargo-controller",
            "kargo-management-controller",
            "kargo-webhooks-server",
        },
        "unexpected controller workloads",
    )
    for d in deployments:
        pod = d["spec"]["template"]["spec"]
        require(not pod.get("hostNetwork") and not pod.get("hostPID"), "host isolation disabled")
        require(not any("hostPath" in v for v in pod.get("volumes", [])), "host path mount")
        for c in pod["containers"] + pod.get("initContainers", []):
            require(re.search(r"@sha256:[a-f0-9]{64}$", c["image"]), "image is not digest pinned")
            security = c.get("securityContext", {})
            require(
                security.get("allowPrivilegeEscalation") is False
                and security.get("readOnlyRootFilesystem") is True
                and "ALL" in security.get("capabilities", {}).get("drop", [])
                and security.get("seccompProfile", {}).get("type") == "RuntimeDefault",
                "container hardening changed",
            )
            require(
                security.get("runAsNonRoot", pod.get("securityContext", {}).get("runAsNonRoot"))
                is True,
                "root execution permitted",
            )
            require(
                {"cpu", "memory"} <= c.get("resources", {}).get("limits", {}).keys(),
                "container limits absent",
            )
    require(
        not any(d["kind"] == "Secret" and (d.get("data") or d.get("stringData")) for d in docs),
        "inline controller credential",
    )
    require(
        not any(
            d["kind"] in ["ExternalSecret", "Job", "CronJob", "Stage", "Warehouse"] for d in docs
        ),
        "unexpected credential consumer or release workload",
    )
    for d in docs:
        if d["kind"] in ["Role", "ClusterRole"]:
            require(
                not any("applications" in r.get("resources", []) for r in d.get("rules", [])),
                "Argo application authority enabled before acceptance",
            )
        if d["kind"] == "NetworkPolicy":
            require(
                d["metadata"]["name"] != "default-deny", "collision with Kyverno policy ownership"
            )
        if d["kind"] == "ServiceAccount" and d["metadata"]["name"] in [
            "kargo-admin",
            "kargo-project-creator",
            "kargo-viewer",
        ]:
            require(
                not d["metadata"].get("annotations", {}).get("rbac.kargo.akuity.io/claims"),
                "global privileged or viewer claims mapped",
            )
    api = index["ConfigMap", "kargo-api"]["data"]
    require(
        api.get("OIDC_ENABLED") == "true" and api.get("OIDC_CLIENT_ID") == "homelab-kargo",
        "OIDC disabled or client differs",
    )
    require(api.get("ADMIN_ACCOUNT_ENABLED", "false") == "false", "default admin enabled")
    require(
        api.get("SECRET_MANAGEMENT_ENABLED", "false") == "false", "API secret management enabled"
    )
    require(api.get("OIDC_ADDITIONAL_SCOPES") == "email,profile", "OIDC scope drift")
    require(api.get("PERMISSIVE_CORS_POLICY_ENABLED") == "false", "permissive CORS enabled")
    user = index["ServiceAccount", "kargo-user"]["metadata"]["annotations"][
        "rbac.kargo.akuity.io/claims"
    ]
    import json

    require(json.loads(user) == {"groups": ["operator"]}, "system login mapping widened")
    for rule in index["ClusterRole", "kargo-user"]["rules"]:
        require(set(rule["verbs"]) <= {"get", "list", "watch"}, "system user role can write")
    for rule in index["ClusterRole", "kargo-controller"]["rules"]:
        require(
            "secrets" not in rule.get("resources", []),
            "promotion controller reads secrets cluster-wide",
        )
    run = index["AnalysisRun", "controller-bootstrap-v1"]
    require(run["metadata"]["namespace"] == "argo-rollouts", "proof namespace differs")
    metrics = run["spec"]["metrics"]
    require(
        len(metrics) == 1 and metrics[0]["count"] == 1 and metrics[0]["failureLimit"] == 0,
        "unbounded verification metrics",
    )
    job = metrics[0]["provider"]["job"]["spec"]
    require(
        job["backoffLimit"] == 0 and job["activeDeadlineSeconds"] == 180,
        "unbounded verification Job",
    )
    pod = job["template"]["spec"]
    require(
        pod.get("automountServiceAccountToken") is False
        and pod["serviceAccountName"] == "controller-bootstrap"
        and not pod.get("volumes")
        and not pod.get("initContainers"),
        "verification Job credentials or mounts enabled",
    )
    require(
        not job["template"]["metadata"]["labels"].get("app.kubernetes.io/name"),
        "verification Job inherits controller egress",
    )
    require(
        pod["securityContext"]["runAsNonRoot"] is True
        and pod["securityContext"]["runAsUser"] == 10001
        and pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault",
        "verification pod hardening differs",
    )
    require(len(pod["containers"]) == 1, "unexpected verification container")
    container = pod["containers"][0]
    require(
        re.search(r"@sha256:[a-f0-9]{64}$", container["image"])
        and container["resources"]["limits"] == {"cpu": "100m", "memory": "64Mi"}
        and not container.get("env")
        and not container.get("envFrom")
        and not container.get("volumeMounts")
        and container["securityContext"]["allowPrivilegeEscalation"] is False
        and container["securityContext"]["readOnlyRootFilesystem"] is True
        and container["securityContext"]["capabilities"]["drop"] == ["ALL"],
        "verification container boundary differs",
    )
    require(
        not any(
            subject.get("kind") == "ServiceAccount"
            and subject.get("name") == "controller-bootstrap"
            for obj in docs
            if obj["kind"] in ["RoleBinding", "ClusterRoleBinding"]
            for subject in obj.get("subjects", [])
        ),
        "verification SA has RBAC",
    )
    # The trusted management controller retains upstream project lifecycle RBAC;
    # it is distinct from the promotion controller's disabled global Secret read.
    require(
        not any(
            d["kind"] == "Namespace" and d["metadata"]["name"] == "kargo-cluster-secrets"
            for d in docs
        ),
        "deprecated secret migration namespace enabled",
    )
    for d in docs:
        if d["kind"] == "CiliumNetworkPolicy":
            for rule in d["spec"].get("egress", []):
                require(
                    not rule.get("toCIDR")
                    and not rule.get("toCIDRSet")
                    and not rule.get("toFQDNs")
                    and set(rule.get("toEntities", [])) <= {"kube-apiserver", "ingress"},
                    "controller internet egress enabled before credential review",
                )


def main():
    docs = []
    for layer in ["argo-rollouts", "kargo"]:
        result = subprocess.run(
            ["kustomize", "build", "--enable-helm", str(ROOT / "infrastructure" / layer)],
            capture_output=True,
            text=True,
        )
        require(result.returncode == 0, f"{layer} render failed; details withheld")
        docs += [d for d in yaml.safe_load_all(result.stdout) if d]
    check(docs)
    # Defect mutations exercise the security boundary, not a mirror of the input.
    mutations = [
        (
            "admin",
            lambda d: d["data"].__setitem__("ADMIN_ACCOUNT_ENABLED", "true"),
            "ConfigMap",
            "kargo-api",
        ),
        (
            "secret-management",
            lambda d: d["data"].__setitem__("SECRET_MANAGEMENT_ENABLED", "true"),
            "ConfigMap",
            "kargo-api",
        ),
        (
            "global-secret-read",
            lambda d: d["rules"].append(
                {"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]}
            ),
            "ClusterRole",
            "kargo-controller",
        ),
        (
            "Argo-write",
            lambda d: d["rules"].append(
                {"apiGroups": ["argoproj.io"], "resources": ["applications"], "verbs": ["patch"]}
            ),
            "ClusterRole",
            "kargo-controller",
        ),
        (
            "operator-write",
            lambda d: d["rules"][0]["verbs"].append("create"),
            "ClusterRole",
            "kargo-user",
        ),
        (
            "unbounded-egress",
            lambda d: d["spec"]["egress"].append({"toEntities": ["world"]}),
            "CiliumNetworkPolicy",
            "controllers-api-dns",
        ),
        (
            "deny-policy-collision",
            lambda d: d["metadata"].__setitem__("name", "default-deny"),
            "NetworkPolicy",
            "kargo-default-deny",
        ),
        (
            "mutable-image",
            lambda d: d["spec"]["template"]["spec"]["containers"][0].__setitem__(
                "image", "test:latest"
            ),
            "Deployment",
            "kargo-api",
        ),
    ]
    mutations += [
        (
            "verification-token",
            lambda d: d["spec"]["metrics"][0]["provider"]["job"]["spec"]["template"][
                "spec"
            ].__setitem__("automountServiceAccountToken", True),
            "AnalysisRun",
            "controller-bootstrap-v1",
        ),
        (
            "verification-egress",
            lambda d: d["spec"]["metrics"][0]["provider"]["job"]["spec"]["template"]["metadata"][
                "labels"
            ].__setitem__("app.kubernetes.io/name", "argo-rollouts"),
            "AnalysisRun",
            "controller-bootstrap-v1",
        ),
    ]
    for name, mutate, kind, resource in mutations:
        candidate = copy.deepcopy(docs)
        obj = next(d for d in candidate if d["kind"] == kind and d["metadata"]["name"] == resource)
        mutate(obj)
        try:
            check(candidate)
        except ValueError:
            continue
        raise ValueError(f"unsafe mutation accepted: {name}")
    print(f"OK: {len(docs)} rendered resources; {len(mutations)} unsafe mutations rejected")


if __name__ == "__main__":
    main()
