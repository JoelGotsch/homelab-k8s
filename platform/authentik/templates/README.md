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
3. **The app's own repo, `k8s/`** (ADR 0001; `homelab-k8s/apps/*` are
   superseded central copies): copy `oidc-client.template.yaml`, replace
   `{{APP_NAME}}`, `{{REDIRECT_URI}}` and `{{SCOPES}}`.

   Do **not** replace `AUTH_FQDN`. It stays as written and resolves from
   `components/site-config` via a `replacements:` block — the snippet is in
   the template's header comment, and `check-site-config.sh` fails the commit
   if the copy carries the token without the component. The template used to
   carry the literal `auth.lab.vyramo.com` (and this step used to name a
   `<HOMELAB-DOMAIN>` placeholder that the file had not contained for
   months); ADR 0045 C2 replaced both with the one token.
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
