#!/usr/bin/env python3
"""Rehearse V2 tokenless pod admission without creating workloads or reading tokens."""
import argparse
import copy
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
IMAGE = "docker.io/library/python@sha256:392307d22300de8b5986851a12d9176dfc0fc073e65bf6523ebd7dcbeb23564e"


def run(args, data=None):
    result = subprocess.run(args, input=data, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(f"{args[0]} {args[1]} failed; output withheld")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", required=True)
    args = parser.parse_args()
    if not re.fullmatch("[0-9a-f]{40}", args.revision):
        parser.error("full committed revision required")
    if run(["kubectl", "config", "current-context"]).strip() != "admin@homelab" or not any(
        line.startswith("Current context:") and line.split(":", 1)[1].strip() == "homelab"
        for line in run(["talosctl", "config", "info"]).splitlines()
    ):
        raise RuntimeError("Unexpected Kubernetes or Talos context")
    app = json.loads(run(["kubectl", "-n", "argocd", "get", "application", "infra-kyverno", "-o", "json"]))
    state = app["status"]
    op = state.get("operationState", {})
    if (state["sync"].get("revision") != args.revision or state["sync"].get("status") != "Synced"
            or state["health"].get("status") != "Healthy" or op.get("phase") != "Succeeded"
            or op.get("syncResult", {}).get("revision") != args.revision
            or op.get("operation", {}).get("sync", {}).get("dryRun") or app.get("operation")):
        raise RuntimeError("Expected exact-revision successful actual Kyverno reconciliation")
    policy = json.loads(run(["kubectl", "get", "mutatingpolicy", "chist-v2-ci-tokenless", "-o", "json"]))
    if not any(c.get("type") == "Ready" and c.get("status") == "True" for c in policy.get("status", {}).get("conditions", [])):
        raise RuntimeError("V2 admission policy is not Ready")
    runner = json.loads(run(["kubectl", "-n", "ci-woodpecker", "get", "serviceaccount", "ci-woodpecker-runner", "-o", "json"]))
    if runner.get("automountServiceAccountToken") is not False:
        raise RuntimeError("Runner service account is not tokenless")
    base = {"apiVersion": "v1", "kind": "Pod", "metadata": {
        "name": "chist-v2-admission-proof", "namespace": "ci-woodpecker",
        "labels": {"woodpecker-ci.org/repo-id": "35", "woodpecker-ci.org/repo-forge-id": "141"}},
        "spec": {"restartPolicy": "Never", "containers": [{"name": "proof", "image": IMAGE,
            "command": ["python", "-c", "pass"], "resources": {
                "requests": {"cpu": "10m", "memory": "32Mi"}, "limits": {"cpu": "100m", "memory": "64Mi"}},
            "securityContext": {"allowPrivilegeEscalation": False, "runAsUser": 1000,
                "runAsNonRoot": True, "capabilities": {"drop": ["ALL"]},
                "seccompProfile": {"type": "RuntimeDefault"}}}]}}
    reports = []
    for case in ["v2", "other-repository", "other-forge-id", "other-namespace"]:
        pod = copy.deepcopy(base)
        pod["metadata"]["name"] += "-" + case
        if case == "other-repository":
            pod["metadata"]["labels"]["woodpecker-ci.org/repo-id"] = "36"
        if case == "other-forge-id":
            pod["metadata"]["labels"]["woodpecker-ci.org/repo-forge-id"] = "142"
        if case == "other-namespace":
            pod["metadata"]["namespace"] = "default"
        admitted = json.loads(run(["kubectl", "create", "--dry-run=server", "-f", "-", "-o", "json"], json.dumps(pod)))
        spec = admitted["spec"]
        tokens = [v["name"] for v in spec.get("volumes", []) if any("serviceAccountToken" in s for s in v.get("projected", {}).get("sources", []))]
        if case == "v2":
            if spec.get("serviceAccountName") != "ci-woodpecker-runner" or spec.get("automountServiceAccountToken") is not False or tokens:
                raise RuntimeError("V2 pod admission retained token authority")
            if any(m["mountPath"].startswith("/var/run/secrets/kubernetes.io") for c in spec["containers"] for m in c.get("volumeMounts", [])):
                raise RuntimeError("V2 token mount remains")
        elif spec.get("serviceAccountName") != "default" or not tokens:
            raise RuntimeError("Another repository or namespace was changed by V2 admission")
        reports.append({"case": case, "token_volumes": len(tokens), "service_account": spec["serviceAccountName"], "passed": True})
    print(json.dumps({"revision": args.revision, "policy_uid": policy["metadata"]["uid"], "created_workloads": 0, "checks": reports}))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit(str(error) if isinstance(error, RuntimeError) else f"Admission rehearsal failed ({type(error).__name__}); details withheld") from None
