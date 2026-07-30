# platform/pr-agent

Qodo PR-Agent — LLM-powered PR review bot in webhook mode, per
[ADR 0029](../../../homelab-docs/02-decisions/0029-llm-pr-review-tool.md).
Runs in the `pr-agent` namespace; receives Forgejo webhooks
cluster-internal, calls the LiteLLM gateway
([ADR 0026](../../../homelab-docs/02-decisions/0026-litellm-as-llm-gateway-implementation.md))
for inference using a per-app virtual key, posts reviews back
to Forgejo via a dedicated `pr-agent-bot` PAT.

No Tailscale or Cloudflare exposure (PR-Agent has no UI to
expose; operator interaction is via PR comments).

## Layout

| File | Purpose |
|---|---|
| `namespace.yaml` | `pr-agent` namespace; PSA restricted. |
| `kustomization.yaml` | Plain Deployment + Service + ConfigMap; no upstream Helm chart for the `gitea_app` target. |
| `configmap.yaml` | Non-secret env: provider=gitea, Forgejo URL, gateway base URL, model name, slash-command list, token budget. |
| `externalsecret.yaml` | Forgejo PAT, webhook shared-secret, gateway virtual-key. |
| `deployment.yaml` | PR-Agent container + ClusterIP Service on port 80→3000. |
| `networkpolicy.yaml` | Default-deny; ingress from `forgejo`, egress to kube-DNS + `forgejo` + `llm-gateway` only. |

## Image build

PR-Agent's `gitea_app` Docker target is upstream-defined but
not published as a tagged image. The build runs inside Woodpecker
via the dedicated wrapper repo
[`homelab/pr-agent-build`](https://forgejo.lab.vyramo.com/homelab/pr-agent-build)
— see that repo's README for the wrapper-pattern rationale and the
manual bump procedure. Replaces the operator-on-Tier-A
`docker build && docker push` recipe that previously lived here
(removed 2026-06-10).

Quick bump flow:

1. Renovate opens a PR against `homelab/pr-agent-build`
   bumping `.upstream-tag`.
2. Merge to `main`.
3. Tag the wrapper repo with the matching plain version (e.g.
   wrapper tag `0.35` for upstream `v0.35`); Woodpecker builds +
   publishes `registry.homelab.internal/forgejo-admin/pr-agent:gitea_app-0.35`.
4. Bump the `image:` line in [deployment.yaml](deployment.yaml) to
   match (Renovate can manage this too, given the standard image-
   reference format).

## OpenBao paths to seed

Per [cold-start.md Step 13c](../../../homelab-docs/04-guides/cold-start.md).

| Path | Field(s) | Source |
|---|---|---|
| `kv/data/pr-agent/forgejo-pat` | `token` | PAT issued by Forgejo for the dedicated `pr-agent-bot` user. Scope: `read:repository`, `write:issue`, `write:repository`. Seed after the bot user exists in Forgejo. |
| `kv/data/pr-agent/webhook-secret` | `secret` | Random shared-secret. Forgejo signs incoming webhooks with this; PR-Agent verifies. Same value typed into Forgejo's per-repo webhook configuration at activation. |
| `kv/data/pr-agent/litellm-virtual-key` | `key` | Per-app virtual key issued by the LLM gateway (ADR 0026 D6). Generated via the gateway's admin API; allowlist scoped to self-hosted models only per ADR 0029 D3. |

**First-install seed:**

```sh
# 1. Forgejo bot PAT — operator creates `pr-agent-bot` user in
#    Forgejo (Site Administration → Users → New User), then
#    logs in as that user and issues a PAT with the scopes
#    above (Settings → Applications → Tokens).
bao kv put kv/pr-agent/forgejo-pat \
    token="<paste-pat-from-forgejo>"

# 2. Webhook shared-secret — random.
homelab-infra/scripts/seed-random-secret.sh \
    kv/pr-agent/webhook-secret secret

# 3. LiteLLM virtual key — issued by the gateway per ADR 0026
#    D6 + apps/llm-gateway/README.md §"Per-app virtual key".
#    The provisioning script issues a key constrained to the
#    pr-agent allowlist (self-hosted models only) and seeds it.
homelab-infra/scripts/provision-litellm-virtual-key.sh \
    --app pr-agent \
    --allowlist self-hosted \
    --kv-path kv/pr-agent/litellm-virtual-key
```

## Bring-up wiring

| Bring-up step | What lands |
|---|---|
| Argo sync `platform/forgejo/` | Forgejo up; operator creates `pr-agent-bot` user + issues PAT. |
| Argo sync `apps/llm-gateway/` | Gateway up; operator issues per-app virtual key for pr-agent. |
| Operator builds + pushes `pr-agent:gitea_app-<tag>` to `registry.homelab.internal` | Image available for pull. |
| Operator seeds `kv/pr-agent/{forgejo-pat,webhook-secret,litellm-virtual-key}` | ESO can populate Secrets. |
| Argo sync this layer | Deployment Ready; webhook listener available cluster-internally. |
| Operator activates pr-agent on a repo | Walk §"Post-bring-up activation" below. |

## Post-bring-up activation (per repo)

PR-Agent doesn't auto-activate on Forgejo repos — it activates
per-repo via webhook registration.

### 1. Register the webhook on the target Forgejo repo

In Forgejo: `<repo> → Settings → Webhooks → Add Webhook → Gitea`:

- **Target URL**: `http://pr-agent.pr-agent.svc.cluster.local/api/v1/gitea_webhooks`
- **HTTP Method**: POST
- **Content Type**: `application/json`
- **Secret**: paste the value from `bao kv get -field=secret kv/pr-agent/webhook-secret`
- **Trigger On**: "Custom Events" → check **Pull Request** + **Pull Request Comment**
- **Active**: yes

### 2. Verify the bot can comment

Open a test PR. PR-Agent should auto-respond with a `/describe`
+ `/review` summary within ~30 seconds (longer on first cold
self-hosted-model load). If silent, check:

```sh
kubectl -n pr-agent logs deploy/pr-agent --tail=200
# Common: signature mismatch (webhook secret typo), 401 from
# Forgejo (PAT scope wrong), 403/timeout from gateway (virtual
# key not yet issued / model not in allowlist).
```

### 3. Try a slash command

In a PR comment: `/review`, `/improve`, or `/ask <question>`.
PR-Agent re-runs the relevant pipeline and replies with a
review comment. No push needed.

## Caveats

1. **Upstream Forgejo support is shared with Gitea.** PR-Agent
   treats the two as one provider. Forgejo API drift has bitten
   this code path before
   ([qodo-ai/pr-agent#1657](https://github.com/qodo-ai/pr-agent/issues/1657)).
   Per ADR 0029 D5, Red Hat Edge `ai-code-review` stays on the
   bench as the fallback if PR-Agent breaks against a future
   Forgejo version and upstream is slow to fix.

2. **Self-hosted-model latency.** PR-Agent loads whole-diff
   context; on a slow self-hosted model the first review on a
   large PR may take 30–90 seconds. Acceptable for review-bot
   UX. Tune `CONFIG__MAX_MODEL_TOKENS` if a model's context
   window is smaller than the default 32k.

3. **No HTTPRoute.** PR-Agent has no UI; webhooks come from
   Forgejo cluster-internally; egress is the gateway. Adding
   external exposure would change the AGPL-3.0 analysis (see
   ADR 0029 D6).

4. **`gitea_app` image must be operator-built** until upstream
   publishes a tagged image for that target. Renovate tracks
   upstream tags; rebuild on each tag bump.

5. **Per-repo activation is manual.** No auto-activation across
   all Forgejo repos — operator registers the webhook per repo
   that should get reviews. Same model as Woodpecker repo
   activation. Worth a small helper script if the repo count
   grows.

6. **Token budget is not enforced cluster-side.** PR-Agent
   asks the gateway and the gateway honours the virtual-key
   limits set per ADR 0026. A misconfigured virtual key (no
   spend cap) lets a long PR run consume substantial gateway-
   accounted tokens. Spend caps belong on the gateway side at
   key-issuance time.

7. **Public-repos future instance is deferred.** Per ADR 0029
   D3 the same chart can run a second instance for public OSS
   repos with a SaaS backend; that layer (e.g.
   `platform/pr-agent-public/`) doesn't exist yet and decision
   is deferred until the first public repo lands.

## Related

- [ADR 0029](../../../homelab-docs/02-decisions/0029-llm-pr-review-tool.md)
  — tool decision.
- [ADR 0026](../../../homelab-docs/02-decisions/0026-litellm-as-llm-gateway-implementation.md)
  — gateway + per-app virtual key.
- [ADR 0007](../../../homelab-docs/02-decisions/0007-external-llm-egress-gateway.md)
  — egress chokepoint.
- [ADR 0023](../../../homelab-docs/02-decisions/0023-forgejo-and-woodpecker-ci.md)
  — Forgejo + Woodpecker; PR-Agent receives webhooks from this Forgejo.
- [`platform/forgejo/`](../forgejo/) — webhook source.
- [`apps/llm-gateway/`](../../apps/llm-gateway/) — inference target.
- [99-journal/2026-05-02-llm-pr-review-tool-choice.md](../../../homelab-docs/99-journal/2026-05-02-llm-pr-review-tool-choice.md)
  — reasoning session.
