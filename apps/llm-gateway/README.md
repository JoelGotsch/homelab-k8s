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
- `policies-configmap.yaml` — provider + MCP allowlists mounted
  at `/etc/litellm/policies`. Source-of-truth in sibling repo
  `llm-gateway/policies/`.
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

## Allowlist drift

The allowlists in `policies-configmap.yaml` mirror
`llm-gateway/policies/{provider,mcp}-allowlist.yaml`. Operator
copies on change. (Future: an Ansible task could render this,
but volume is low enough that manual sync is fine.)
