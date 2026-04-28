# apps/llm-gateway

LiteLLM proxy with homelab tag-enforcement hooks. Single egress
chokepoint for LLM calls per ADR 0026.

## Layout

- `kustomization.yaml` — inflates the upstream `litellm-helm`
  chart with overrides from `values.yaml` and pulls in the
  resources below.
- `values.yaml` — Helm values: image override (homelab-built),
  inline LiteLLM `proxy_config`, env wiring, security context.
- `namespace.yaml` — `llm-gateway` namespace with restricted PSA.
- `policies-configmap.yaml.j2` — Jinja template for the
  allowlist ConfigMap. Source-of-truth is sibling repo
  `llm-gateway/policies/{provider,mcp}-allowlist.yaml`. The
  rendered `policies-configmap.yaml` is gitignored; produced by
  `homelab-infra/ansible/playbooks/00-render-static.yml`.
- `externalsecret.yaml` — pulls upstream API keys + Postgres
  DSN from OpenBao at `kv/data/llm-gateway/*`.
- `httproute.yaml` — internal-only HTTPRoute on the homelab
  Cilium gateway.
- `networkpolicy.yaml` — default-deny + explicit allows
  (kube-DNS, OpenBao, CNPG, Mac Studio MLX/Ollama, WAN:443).

## Operator inputs

- Replace `MAC_STUDIO_INFERENCE_IP` in `values.yaml` and
  `networkpolicy.yaml` with the inference-VLAN address.
- Replace `<HOMELAB-DOMAIN>` in `httproute.yaml`.
- Seed OpenBao at the paths referenced in `externalsecret.yaml`.

## Image

Built from the sibling `llm-gateway/` repo and pushed to
`registry.homelab.internal/llm-gateway:<tag>` by Woodpecker on
tagged commits.

## Allowlist source-of-truth

Allowlists live in sibling repo `llm-gateway/policies/`. Only
the `.j2` template is hand-edited here; the rendered
`policies-configmap.yaml` is produced by Ansible:

```sh
cd homelab-infra
ansible-playbook ansible/playbooks/00-render-static.yml
```

The rendered file IS committed (Argo CD reads from git, so
gitignoring it would break the sync). After re-rendering,
commit both repos together so the ConfigMap matches the
sibling repo's allowlist version.
