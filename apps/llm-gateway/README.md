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

Placeholders (caught by
[homelab-k8s/scripts/check-placeholders.sh](../../scripts/check-placeholders.sh),
gated at [cold-start.md Step 13a](../../../homelab-docs/04-guides/cold-start.md)):

- `<MAC_STUDIO_INFERENCE_IP>` in `values.yaml` and
  `networkpolicy.yaml` — inference-VLAN address (matches
  `mac_inference_ip` in
  `homelab-infra/group_vars/all/main.yml`).
- `<HOMELAB-DOMAIN>` in `httproute.yaml` — operator's homelab
  domain (matches `homelab_domain` in group_vars).

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).
ExternalSecret in `externalsecret.yaml` projects these into
the namespace; without them, the pod fails to start.

| Path | Keys | Source |
|---|---|---|
| `kv/llm-gateway/anthropic` | `api_key` | Anthropic console — operator-issued API key (`sk-ant-...`) |
| `kv/llm-gateway/openai` | `api_key` | OpenAI platform — operator-issued API key (`sk-...`) |
| `kv/llm-gateway/master-key` | `value` | `openssl rand -hex 32` — generated at first install, persisted; rotation per [llm-gateway/rotate-key.md](../../../homelab-docs/03-runbooks/llm-gateway/rotate-key.md) |
| `kv/cnpg/llm-gateway/s3-creds` | `access_key_id`, `secret_access_key` | provisioned post-MinIO-Healthy via `mc admin user svcacct add` per [minio-on-nas/README §Per-app credentials](../../infrastructure/minio-on-nas/README.md) |

**First-install seed (paste before Step 13c-driven Argo
sync):**

```sh
# Provider keys — operator-typed (issued by Anthropic / OpenAI):
bao kv put kv/llm-gateway/anthropic api_key="sk-ant-..."
bao kv put kv/llm-gateway/openai    api_key="sk-..."

# Master key — generated + seeded:
homelab-infra/scripts/seed-random-secret.sh \
    kv/llm-gateway/master-key value

# CNPG s3-creds — after MinIO Healthy:
homelab-infra/scripts/provision-minio-svcacct.sh \
    --alias minio \
    --kv-path kv/cnpg/llm-gateway/s3-creds \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/llm-gateway/*" \
    --resource-prefix \
        "arn:aws:s3:::homelab-backups-cluster/cnpg/llm-gateway" \
    --label llm-gateway-cnpg
```

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
