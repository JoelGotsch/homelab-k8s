#!/usr/bin/env python3
"""Offline rendered Google-source wiring guard. Prints names/errors, never secret values.

Uses only the pinned chart already cached below platform/authentik/charts.
Kustomize/Helm run in a disposable snapshot; Helm pull/network commands fail.
Run with --self-test to reject mutations of the actual rendered resources.
"""
from __future__ import annotations

import argparse
import copy
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
SECRET = "authentik-tridata-google"
KEYS = {"AUTHENTIK_TRIDATA_GOOGLE_CLIENT_ID": "client_id",
        "AUTHENTIK_TRIDATA_GOOGLE_CLIENT_SECRET": "client_secret"}
# Google source discovery adds the OIDC userinfo endpoint to login/token/API hosts.
HOSTS = {"accounts.google.com", "oauth2.googleapis.com", "www.googleapis.com",
         "openidconnect.googleapis.com"}
BLUEPRINTS = {"tridata-public.yaml", "tridata-google.yaml"}
# Authentik's built-in Google adapter ignores source PKCE; use its generic OIDC adapter.
SOURCE_CONTRACT = {
    "provider_type": "openidconnect",
    "oidc_well_known_url": "https://accounts.google.com/.well-known/openid-configuration",
    "authorization_code_auth_method": "post_body",
    "pkce": "S256",
    "additional_scopes": "",  # Adapter defaults already request openid, email and profile.
}


class ContractError(ValueError):
    """Diagnostic composed only from static contract labels, never manifest values."""


class BlueprintLoader(yaml.SafeLoader):
    pass


def blueprint_tag(loader, tag, node):
    if isinstance(node, yaml.ScalarNode):
        value = loader.construct_scalar(node)
    elif isinstance(node, yaml.SequenceNode):
        value = loader.construct_sequence(node)
    else:
        value = loader.construct_mapping(node)
    return {"tag": tag, "value": value}


BlueprintLoader.add_multi_constructor("!", blueprint_tag)


def require(condition, message):
    if not condition:
        raise ContractError(message)


def one(documents, kind, name):
    found = [d for d in documents if d.get("kind") == kind and d.get("metadata", {}).get("name") == name
             and d.get("metadata", {}).get("namespace") == "authentik"]
    require(len(found) == 1, f"expected one authentik/{name} {kind}")
    return found[0]


def render(root):
    layer = root / "platform/authentik"
    config = yaml.safe_load((layer / "kustomization.yaml").read_text())
    charts = config.get("helmCharts", [])
    require(len(charts) == 1 and charts[0].get("name") == "authentik", "unexpected Authentik chart input")
    chart = charts[0]
    cached = layer / "charts" / f"authentik-{chart['version']}" / "authentik"
    require((cached / "Chart.yaml").is_file(), "pinned Authentik chart cache missing; provision cache first")
    metadata = yaml.safe_load((cached / "Chart.yaml").read_text())
    require(metadata.get("name") == "authentik" and str(metadata.get("version")) == str(chart["version"]),
            "cached Authentik chart does not match pinned version")
    helm = shutil.which(os.environ.get("HELM_BIN", "helm"))
    kustomize = shutil.which(os.environ.get("KUSTOMIZE_BIN", "kustomize"))
    require(helm and kustomize, "Helm and Kustomize are required for the offline Google render")
    with tempfile.TemporaryDirectory(prefix="authentik-google-") as directory:
        snapshot = Path(directory)
        shutil.copytree(layer, snapshot / "platform/authentik")
        shutil.copytree(root / "components", snapshot / "components")
        wrapper = snapshot / "helm-offline"
        wrapper.write_text("#!/bin/sh\ncase \"$1\" in\nversion|template) exec " + shlex.quote(helm)
                           + " \"$@\" ;;\n*) echo 'Only local Helm rendering is allowed' >&2; exit 64 ;;\nesac\n")
        wrapper.chmod(0o755)
        result = subprocess.run([kustomize, "build", "--enable-helm", "--helm-command", str(wrapper),
                                 str(snapshot / "platform/authentik")], capture_output=True, text=True,
                                timeout=60)
        require(result.returncode == 0, "offline Authentik render failed (manifest/error content withheld)")
        return [d for d in yaml.safe_load_all(result.stdout) if isinstance(d, dict)]


def matches(selector, labels):
    require(set(selector) <= {"matchLabels", "matchExpressions"}, "unsupported policy selector")
    if any(labels.get(k) != v for k, v in selector.get("matchLabels", {}).items()):
        return False
    for item in selector.get("matchExpressions", []):
        key, operation, values = item["key"], item["operator"], item.get("values", [])
        if operation == "In" and labels.get(key) not in values:
            return False
        if operation == "NotIn" and labels.get(key) in values:
            return False
        if operation == "Exists" and key not in labels:
            return False
        if operation == "DoesNotExist" and key in labels:
            return False
        require(operation in {"In", "NotIn", "Exists", "DoesNotExist"}, "unsupported policy expression")
    return True


def check(documents):
    secret = one(documents, "ExternalSecret", SECRET)["spec"]
    require(secret.get("secretStoreRef") == {"kind": "ClusterSecretStore", "name": "openbao"},
            "Google ExternalSecret must use the OpenBao store")
    require(secret.get("target", {}).get("name") == SECRET and not secret.get("dataFrom"),
            "Google ExternalSecret target or explicit-key contract changed")
    rows = secret.get("data", [])
    require(len(rows) == 2 and {r.get("secretKey") for r in rows} == set(KEYS),
            "Google ExternalSecret must project exactly the two required environment keys")
    for row in rows:
        require(row.get("remoteRef") == {"key": "tridata/public/google", "property": KEYS[row["secretKey"]]},
                "Google ExternalSecret remote path/property changed")
    config = one(documents, "ConfigMap", "authentik-blueprints")
    require(BLUEPRINTS <= set(config.get("data", {})), "Google or public base blueprint is not rendered")
    base = yaml.load(config["data"]["tridata-public.yaml"], Loader=BlueprintLoader)
    require(base.get("metadata", {}).get("name") == "tridata-public", "public blueprint identity changed")
    google = yaml.load(config["data"]["tridata-google.yaml"], Loader=BlueprintLoader)
    dependencies = [e for e in google.get("entries", []) if e.get("model") == "authentik_blueprints.metaapplyblueprint"]
    require(any(e.get("attrs") == {"identifiers": {"name": "tridata-public"}, "required": True}
                for e in dependencies), "Google blueprint lacks required public-base metaapply dependency")
    base_entries = {e.get("id"): e for e in base.get("entries", []) if e.get("id")}
    google_entries = {e.get("id"): e for e in google.get("entries", []) if e.get("id")}
    legal = base_entries.get("tridata-public-legal-links", {}).get("attrs", {})
    require(legal.get("type") == "static" and legal.get("initial_value_expression") is False
            and legal.get("placeholder_expression") is False,
            "Tridata legal notice must be fixed static content")
    for path in ("privacy", "terms"):
        require(f'href="https://tridata.vyramo.com/{path}"' in legal.get("initial_value", ""),
                "Tridata legal notice is missing its public " + path + " URL")
    for stage in ("tridata-public-register-prompt", "tridata-public-password-prompt"):
        require({"tag": "KeyOf", "value": "tridata-public-legal-links"}
                in base_entries.get(stage, {}).get("attrs", {}).get("fields", []),
                "Tridata legal notice is missing from " + stage)
    legal_stage = google_entries.get("tridata-public-google-legal", {}).get("attrs", {})
    require({"tag": "Find", "value": ["authentik_stages_prompt.prompt",
                                      ["name", "tridata-public-legal-links"]]}
            in legal_stage.get("fields", []), "Google enrollment has no Tridata legal notice")
    binding = google_entries.get("tridata-public-google-enrollment-5", {}).get("identifiers", {})
    require(binding.get("target") == {"tag": "KeyOf", "value": "tridata-public-google-enrollment"}
            and binding.get("stage") == {"tag": "KeyOf", "value": "tridata-public-google-legal"}
            and binding.get("order") == 5, "Google legal notice must precede account creation")
    sources = [e for e in google.get("entries", []) if e.get("model") == "authentik_sources_oauth.oauthsource"]
    require(len(sources) == 1 and sources[0].get("attrs", {}).get("enabled") is True,
            "Google source is absent or disabled")
    require(sources[0].get("identifiers", {}).get("slug") == "tridata-google"
            and sources[0]["attrs"].get("name") == "Google", "Google source identity changed")
    for field, expected in SOURCE_CONTRACT.items():
        require(sources[0]["attrs"].get(field) == expected,
                "Google OIDC/PKCE source contract changed: " + field)
    for key, field in zip(KEYS, ("consumer_key", "consumer_secret")):
        require(sources[0]["attrs"].get(field) == {"tag": "Env", "value": key},
                "Google source credential must reference the matching injected environment key")

    for role in ("server", "worker"):
        deployment = one(documents, "Deployment", "authentik-" + role)
        pod = deployment["spec"]["template"]
        containers = [c for c in pod["spec"]["containers"] if c.get("name") == role]
        require(len(containers) == 1, f"missing rendered Authentik {role} container")
        container = containers[0]
        require({"secretRef": {"name": SECRET}} in container.get("envFrom", []),
                f"{role} lacks mandatory unprefixed Google secret envFrom")
        require(not any(e.get("name") in KEYS for e in container.get("env", [])),
                f"{role} explicitly overrides a Google credential environment key")
        if role == "worker":
            volumes = [v for v in pod["spec"].get("volumes", [])
                       if v.get("configMap", {}).get("name") == "authentik-blueprints"]
            require(len(volumes) == 1, "worker has no unique public/Google blueprint volume")
            volume = volumes[0]
            items = volume["configMap"].get("items")
            require(items is None or all(any(i.get("key") == key and i.get("path") == key
                                            for i in items) for key in BLUEPRINTS),
                    "worker blueprint projection drops a required blueprint")
            mounts = [m for m in container.get("volumeMounts", []) if m.get("name") == volume["name"]]
            require(len(mounts) == 1 and mounts[0].get("mountPath", "").startswith("/blueprints/")
                    and not mounts[0].get("subPath") and not mounts[0].get("subPathExpr"),
                    "worker does not mount both blueprints inside the discovery directory")
        policy = one(documents, "CiliumNetworkPolicy", "authentik-" + role)
        require(policy["spec"].get("endpointSelector") == {"matchLabels": {
            "app.kubernetes.io/name": "authentik", "app.kubernetes.io/component": role}},
            f"{role} policy must select only its Authentik workload")
        google_rule = {"toFQDNs": [{"matchName": host} for host in sorted(HOSTS)],
                       "toPorts": [{"ports": [{"port": "443", "protocol": "TCP"}]}]}
        dns_rule = {"toEndpoints": [{"matchLabels": {
            "k8s:io.kubernetes.pod.namespace": "kube-system", "k8s-app": "kube-dns"}}],
            "toPorts": [{"ports": [{"port": "53", "protocol": "UDP"}, {"port": "53", "protocol": "TCP"}],
                         "rules": {"dns": [{"matchPattern": "*"}]}}]}
        egress = policy["spec"].get("egress", [])
        google_rules = [r for r in egress if any(p.get("matchName") in HOSTS for p in r.get("toFQDNs", []))]
        require(len(google_rules) == 1, f"{role} must have one Google HTTPS rule")
        normalized = copy.deepcopy(google_rules[0])
        normalized["toFQDNs"] = sorted(normalized["toFQDNs"], key=lambda p: p.get("matchName", ""))
        require(normalized == google_rule, f"{role} Google egress must match exactly the four HTTPS endpoints")
        require(dns_rule in egress, f"{role} requires intercepted UDP/TCP kube-DNS for FQDN identity")
        # Policies are additive: an extra broad rule must not bypass the narrow rule.
        for other in documents:
            if other.get("kind") != "CiliumNetworkPolicy" or other.get("metadata", {}).get("namespace") != "authentik":
                continue
            spec = other.get("spec", {})
            if not matches(spec.get("endpointSelector", {}), pod["metadata"]["labels"]):
                continue
            for rule in spec.get("egress", []):
                require(not set(rule) & {"toEntities", "toCIDR", "toCIDRSet", "toServices", "toGroups"},
                        f"{role} has an unmodelled/broad external egress bypass")
                require(rule.get("toEndpoints") or rule.get("toFQDNs"), f"{role} has unrestricted egress")
                if rule.get("toFQDNs") and rule not in google_rules:
                    require(role == "worker" and rule == {"toFQDNs": [{"matchName": "smtp.protonmail.ch"}],
                            "toPorts": [{"ports": [{"port": "587", "protocol": "TCP"}]}]},
                            f"{role} has unexpected external FQDN egress")


def self_test(documents):
    mutations = []
    for role in ("server", "worker"):
        def missing_env(docs, role=role):
            container = one(docs, "Deployment", "authentik-" + role)["spec"]["template"]["spec"]["containers"][0]
            container["envFrom"] = [e for e in container["envFrom"] if e.get("secretRef", {}).get("name") != SECRET]
        mutations.append((role + " missing envFrom", missing_env))
        def broad_egress(docs, role=role):
            one(docs, "CiliumNetworkPolicy", "authentik-" + role)["spec"]["egress"].append({"toEntities": ["world"]})
        mutations.append((role + " broad egress", broad_egress))
        def missing_dns(docs, role=role):
            for rule in one(docs, "CiliumNetworkPolicy", "authentik-" + role)["spec"]["egress"]:
                for ports in rule.get("toPorts", []):
                    ports.pop("rules", None)
        mutations.append((role + " missing DNS interception", missing_dns))
        def override_env(docs, role=role):
            container = one(docs, "Deployment", "authentik-" + role)["spec"]["template"]["spec"]["containers"][0]
            container.setdefault("env", []).append({"name": next(iter(KEYS)), "value": "fixture-override"})
        mutations.append((role + " overrides projected credential", override_env))
        def broaden_selector(docs, role=role):
            one(docs, "CiliumNetworkPolicy", "authentik-" + role)["spec"]["endpointSelector"] = {}
        mutations.append((role + " broad workload selector", broaden_selector))
        def insecure_google_port(docs, role=role):
            for rule in one(docs, "CiliumNetworkPolicy", "authentik-" + role)["spec"]["egress"]:
                if any(peer.get("matchName") in HOSTS for peer in rule.get("toFQDNs", [])):
                    rule["toPorts"][0]["ports"].append({"port": "80", "protocol": "TCP"})
        mutations.append((role + " Google cleartext egress", insecure_google_port))
    def missing_dependency(docs):
        config = one(docs, "ConfigMap", "authentik-blueprints")["data"]
        text = config["tridata-google.yaml"]
        start = text.index("- model: authentik_blueprints.metaapplyblueprint")
        end = text.index("- model:", start + 1)
        config["tridata-google.yaml"] = text[:start] + text[end:]
    mutations.append(("missing base dependency", missing_dependency))
    def optional_dependency(docs):
        config = one(docs, "ConfigMap", "authentik-blueprints")["data"]
        config["tridata-google.yaml"] = config["tridata-google.yaml"].replace("required: true", "required: false", 1)
    mutations.append(("optional base dependency", optional_dependency))
    def missing_base(docs):
        del one(docs, "ConfigMap", "authentik-blueprints")["data"]["tridata-public.yaml"]
    mutations.append(("unmounted base blueprint", missing_base))

    def wrong_path(docs):
        one(docs, "ExternalSecret", SECRET)["spec"]["data"][0]["remoteRef"]["key"] = "wrong/path"
    mutations.append(("wrong ESO path", wrong_path))
    def missing_key(docs):
        one(docs, "ExternalSecret", SECRET)["spec"]["data"].pop()
    mutations.append(("missing ESO key", missing_key))
    def wrong_property(docs):
        one(docs, "ExternalSecret", SECRET)["spec"]["data"][0]["remoteRef"]["property"] = "other"
    mutations.append(("wrong ESO property", wrong_property))

    def missing_mount(docs):
        container = one(docs, "Deployment", "authentik-worker")["spec"]["template"]["spec"]["containers"][0]
        container["volumeMounts"] = []
    mutations.append(("missing blueprint discovery mount", missing_mount))
    def extra_broad_policy(docs):
        docs.append({"kind": "CiliumNetworkPolicy", "metadata": {"name": "bypass", "namespace": "authentik"},
                     "spec": {"endpointSelector": {}, "egress": [{"toEntities": ["world"]}]}})
    mutations.append(("additive broad policy", extra_broad_policy))
    for field, value in {
        "provider_type": "google",
        "oidc_well_known_url": "https://wrong.example/.well-known/openid-configuration",
        "authorization_code_auth_method": "basic_auth",
        "pkce": "none",
        "additional_scopes": "calendar",
    }.items():
        def unsafe_source(docs, field=field, value=value):
            config = one(docs, "ConfigMap", "authentik-blueprints")["data"]
            blueprint = yaml.load(config["tridata-google.yaml"], Loader=BlueprintLoader)
            source = next(e for e in blueprint["entries"] if e.get("model") == "authentik_sources_oauth.oauthsource")
            source["attrs"][field] = value
            config["tridata-google.yaml"] = yaml.safe_dump(blueprint)
        mutations.append(("unsafe Google source " + field, unsafe_source))
    for filename, entry_id in (("tridata-public.yaml", "tridata-public-legal-links"),
                               ("tridata-google.yaml", "tridata-public-google-enrollment-5")):
        def missing_legal(docs, filename=filename, entry_id=entry_id):
            config = one(docs, "ConfigMap", "authentik-blueprints")["data"]
            blueprint = yaml.load(config[filename], Loader=BlueprintLoader)
            blueprint["entries"] = [e for e in blueprint["entries"] if e.get("id") != entry_id]
            config[filename] = yaml.safe_dump(blueprint)
        mutations.append(("missing legal notice " + entry_id, missing_legal))
    for name, mutate in mutations:
        broken = copy.deepcopy(documents)
        mutate(broken)
        try:
            check(broken)
        except ContractError:
            continue
        raise ContractError("unsafe mutation accepted: " + name)
    return len(mutations)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    try:
        documents = render(ROOT)
        check(documents)
        count = self_test(documents) if args.self_test else 0
    except ContractError as error:
        raise SystemExit("FAIL: " + str(error)) from None
    except (ValueError, KeyError, TypeError, OSError, subprocess.TimeoutExpired, yaml.YAMLError):
        # Suppress exception payloads: renderer/YAML diagnostics may contain secrets.
        raise SystemExit("FAIL: Google wiring/render contract failed; no manifest or credential values printed") from None
    print(f"Google ESO, rendered env/mounts, dependency and narrow egress passed; {count} unsafe mutations rejected")


if __name__ == "__main__":
    main()
