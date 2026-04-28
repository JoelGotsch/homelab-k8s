# Authentik templates

Reusable Authentik resource templates. Operator copies +
adapts per app.

## Files

| File | Purpose |
|---|---|
| `oidc-client.template.yaml` | OIDC client pattern: ExternalSecret pulling client_id + client_secret from OpenBao + ConfigMap with non-secret OIDC config endpoints |

## Pattern (per app needing OIDC)

1. **Authentik UI**: create the Application + OAuth2/OpenID
   Provider. Authentik produces `client_id` + `client_secret`.
2. **OpenBao**: stage the secrets at
   `kv/prod/authentik/clients/<app-name>/{client_id,client_secret,issuer}`.
3. **homelab-k8s/apps/<app-name>/**: copy `oidc-client.template.yaml`,
   replace placeholders (`{{APP_NAME}}`, `{{REDIRECT_URI}}`,
   `{{SCOPES}}`, `<HOMELAB-DOMAIN>`).
4. **App Helm values**: reference the Kubernetes Secret
   `<app-name>-oidc` for client credentials and the ConfigMap
   `<app-name>-oidc-config` for endpoint URLs.

## Per-app runbooks reference this pattern

Apps documenting their OIDC integration: Argo CD
(`infrastructure/cert-manager/...` patches), Vaultwarden,
Forgejo, Nextcloud, Jellyfin, Grafana, Argo CD itself. Their
per-app `initial-setup.md` runbooks under
`homelab-docs/03-runbooks/<app>/` reference this template
and document the specific scopes + redirect URIs each app
expects.

## Why a template instead of a fully-managed CRD

Authentik's terraform provider exists but adds a moving part
to the bring-up; for a single-operator homelab, manual
client creation via the Authentik UI is simpler + auditable
in operator's enrollment-inventory.md. If automation becomes
necessary (multiple environments, frequent rotation), the
provider is a defensible follow-up.
