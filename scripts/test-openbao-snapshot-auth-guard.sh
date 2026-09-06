#!/usr/bin/env bash
# Mutation tests proving the OBA-02 static guard fails on scope regressions.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
test_tmp="$(mktemp -d /tmp/openbao-snapshot-guard.XXXXXX)"
trap 'rm -rf -- "$test_tmp"' EXIT INT TERM

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

make_fixture() {
  fixture="$test_tmp/$1"
  mkdir -p "$fixture/scripts" "$fixture/platform" "$fixture/infrastructure/backup-cronjobs"
  cp "$repo_root/scripts/check-openbao-snapshot-auth.sh" "$fixture/scripts/"
  cp -R "$repo_root/platform/openbao" "$fixture/platform/"
  cp "$repo_root/infrastructure/backup-cronjobs/restic-known-hosts-configmap.yaml" \
    "$repo_root/infrastructure/backup-cronjobs/restic-passwd-configmap.yaml" \
    "$fixture/infrastructure/backup-cronjobs/"
}

# A mutation that is rejected for the WRONG reason proves nothing about the
# assertion it was written for, and reads as a pass. The optional second argument
# pins the diagnostic, so each case demonstrates its own guard firing.
expect_rejected() {
  name="$1"
  expected="${2:-}"
  if "$test_tmp/$name/scripts/check-openbao-snapshot-auth.sh" \
      >"$test_tmp/$name.out" 2>&1; then
    fail "mutation $name unexpectedly passed"
  fi
  if [ -n "$expected" ] && ! grep -Fq "$expected" "$test_tmp/$name.out"; then
    fail "mutation $name was rejected, but not by the assertion it targets;
  expected a diagnostic containing: $expected
  got: $(tr '\n' '|' <"$test_tmp/$name.out" | tail -c 400)"
  fi
}

make_fixture audience
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.volumes[] |
  select(.name == "workload-jwt") |
  .projected.sources[0].serviceAccountToken.audience) = "kubernetes"' \
  "$test_tmp/audience/platform/openbao/raft-snapshot-hourly.yaml"
expect_rejected audience

make_fixture static-token
printf '\nopenbao-snapshot-token\n' >> \
  "$test_tmp/static-token/platform/openbao/README.md"
expect_rejected static-token

make_fixture uploader-jwt
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.containers[0].volumeMounts) +=
  [{"name":"workload-jwt","mountPath":"/stolen"}]' \
  "$test_tmp/uploader-jwt/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected uploader-jwt

make_fixture shared-token-tmp
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.containers[0].volumeMounts[] |
  select(.mountPath == "/tmp") | .name) = "snapshot-tmp"' \
  "$test_tmp/shared-token-tmp/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected shared-token-tmp

make_fixture broad-egress
yq -i '(select(.kind == "CiliumNetworkPolicy" and
  .metadata.name == "openbao-raft-snapshot-daily") | .spec.egress) +=
  [{"toEntities":["world"]}]' \
  "$test_tmp/broad-egress/platform/openbao/snapshot-networkpolicy.yaml"
expect_rejected broad-egress

make_fixture missing-dns-observation
yq -i 'del(select(.kind == "CiliumNetworkPolicy" and
  .metadata.name == "openbao-raft-snapshot-daily") |
  .spec.egress[] | select(.toEndpoints[0].matchLabels."k8s:k8s-app" == "kube-dns") |
  .toPorts[0].rules)' \
  "$test_tmp/missing-dns-observation/platform/openbao/snapshot-networkpolicy.yaml"
expect_rejected missing-dns-observation

make_fixture hourly-dns-observation
yq -i 'select(.kind == "CiliumNetworkPolicy" and
  .metadata.name == "openbao-raft-snapshot-hourly") |
  (.spec.egress[] | select(.toEndpoints[0].matchLabels."k8s:k8s-app" == "kube-dns") |
  .toPorts[0].rules.dns) = [{"matchPattern":"*"}]' \
  "$test_tmp/hourly-dns-observation/platform/openbao/snapshot-networkpolicy.yaml"
expect_rejected hourly-dns-observation

make_fixture missing-daily-ndots
yq -i 'del(select(.kind == "CronJob" and .metadata.name == "openbao-raft-snapshot") |
  .spec.jobTemplate.spec.template.spec.dnsConfig)' \
  "$test_tmp/missing-daily-ndots/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected missing-daily-ndots

make_fixture default-daily-ndots
yq -i '(select(.kind == "CronJob" and .metadata.name == "openbao-raft-snapshot") |
  .spec.jobTemplate.spec.template.spec.dnsConfig.options[0].value) = "5"' \
  "$test_tmp/default-daily-ndots/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected default-daily-ndots

make_fixture hourly-ndots
yq -i '(select(.kind == "CronJob" and .metadata.name == "openbao-raft-snapshot-hourly") |
  .spec.jobTemplate.spec.template.spec.dnsConfig.options) =
  [{"name":"ndots","value":"1"}]' \
  "$test_tmp/hourly-ndots/platform/openbao/raft-snapshot-hourly.yaml"
expect_rejected hourly-ndots

make_fixture daily-private-mode
yq -i '(select(.kind == "CronJob" and .metadata.name == "openbao-raft-snapshot") |
  .spec.jobTemplate.spec.template.spec.initContainers[0].env[] |
  select(.name == "SNAPSHOT_PUBLISH_MODE") | .value) = "0600"' \
  "$test_tmp/daily-private-mode/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected daily-private-mode

make_fixture hourly-shared-mode
yq -i '(select(.kind == "CronJob" and .metadata.name == "openbao-raft-snapshot-hourly") |
  .spec.jobTemplate.spec.template.spec.containers[0].env[] |
  select(.name == "SNAPSHOT_PUBLISH_MODE") | .value) = "0640"' \
  "$test_tmp/hourly-shared-mode/platform/openbao/raft-snapshot-hourly.yaml"
expect_rejected hourly-shared-mode

make_fixture wrong-shared-group
yq -i '(select(.kind == "CronJob" and .metadata.name == "openbao-raft-snapshot") |
  .spec.jobTemplate.spec.template.spec.initContainers[0].securityContext.runAsGroup) = 2000' \
  "$test_tmp/wrong-shared-group/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected wrong-shared-group

make_fixture secret-routing
yq -i '(select(.kind == "ExternalSecret" and
  .metadata.name == "hetzner-sb-creds") | .spec.data) +=
  [{"secretKey":"HSB_PORT","remoteRef":{"key":"prod/backup/hetzner-storage-box","property":"port"}}]' \
  "$test_tmp/secret-routing/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected secret-routing

# ── Convergence and retention mutations (added 2026-09-06) ─────────────────
# The assertions these exercise were added with the hourly convergent lane and
# the off-site prune. Both introduce a way to be silently wrong rather than
# loudly broken — a run that reports success without checking, and a run that
# deletes backups — so each new assertion gets a mutation that must be caught.

# The threshold must be stated in the manifest, not inherited. Inheriting it
# would move production behaviour into a script default where no reviewer of the
# CronJob can see it.
make_fixture convergence-threshold-absent
yq -i 'del(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.containers[] |
  select(.name == "upload") | .env[] |
  select(.name == "SNAPSHOT_MAX_REMOTE_AGE_SECONDS"))' \
  "$test_tmp/convergence-threshold-absent/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected convergence-threshold-absent \
  'must state SNAPSHOT_MAX_REMOTE_AGE_SECONDS explicitly'

# 86400 is the boundary that matters: at exactly a day the lane only publishes
# once the "no older than 24 h" objective has already been missed.
make_fixture convergence-threshold-at-a-day
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.containers[] |
  select(.name == "upload") | .env[] |
  select(.name == "SNAPSHOT_MAX_REMOTE_AGE_SECONDS") | .value) = "86400"' \
  "$test_tmp/convergence-threshold-at-a-day/platform/openbao/raft-snapshot-cronjob.yaml"
expect_rejected convergence-threshold-at-a-day \
  'must be under 86400'

# Probing the snapshot directory instead of the account home reintroduces the
# bug found on 2026-09-06: "host unreachable" and "directory absent" become
# indistinguishable, and since `mkdir -p` lives past that point a first-ever run
# fails forever.
make_fixture convergence-probe-widened
# shellcheck disable=SC2016 # this is a sed program; the $ must stay literal
sed -i.bak 's#"\$ssh_target" stat \. #"$ssh_target" stat "$remote_dir" #' \
  "$test_tmp/convergence-probe-widened/platform/openbao/snapshot-upload.sh"
expect_rejected convergence-probe-widened \
  'must probe reachability with stat on the account home'

# Collapsing the two success outcomes removes the only signal that says whether
# the lane is still actually uploading, as opposed to reporting a stale marker
# fresh forever.
make_fixture convergence-outcomes-collapsed
sed -i.bak 's#outcome=already-fresh remote_age#outcome=published remote_age#' \
  "$test_tmp/convergence-outcomes-collapsed/platform/openbao/snapshot-upload.sh"
expect_rejected convergence-outcomes-collapsed \
  'convergence must report outcome=already-fresh distinctly'

# Arming the prune must be a reviewed commit. Either default alone is enough to
# arm it in practice, so both are asserted and both are mutated.
make_fixture prune-armed-in-cluster
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.containers[0].env[] |
  select(.name == "SNAPSHOT_PRUNE_APPLY") | .value) = "true"' \
  "$test_tmp/prune-armed-in-cluster/platform/openbao/raft-snapshot-prune.yaml"
expect_rejected prune-armed-in-cluster \
  'prune CronJob must ship report-only'

make_fixture prune-armed-by-default
sed -i.bak 's#SNAPSHOT_PRUNE_APPLY:-false#SNAPSHOT_PRUNE_APPLY:-true#' \
  "$test_tmp/prune-armed-by-default/platform/openbao/snapshot-prune.sh"
expect_rejected prune-armed-by-default \
  'snapshot-prune.sh must default to report-only'

# The two independent floors under the delete path. Losing either one is how a
# quota refactor turns into deleted backups.
make_fixture prune-newest-floor-removed
sed -i.bak '/keep\[newest\] = 1/d' \
  "$test_tmp/prune-newest-floor-removed/platform/openbao/snapshot-prune.sh"
expect_rejected prune-newest-floor-removed \
  'newest snapshot must be kept unconditionally'

make_fixture prune-min-plausible-removed
sed -i.bak '/^min_plausible=/d' \
  "$test_tmp/prune-min-plausible-removed/platform/openbao/snapshot-prune.sh"
expect_rejected prune-min-plausible-removed \
  'min-plausible floor is missing'

# The prune pod has no business with the Kubernetes or OpenBao APIs; it lists
# names and removes files.
make_fixture prune-gains-identity
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.spec.serviceAccountName) = "openbao-raft-snapshot"' \
  "$test_tmp/prune-gains-identity/platform/openbao/raft-snapshot-prune.yaml"
expect_rejected prune-gains-identity \
  'prune workload must carry no OpenBao identity'

make_fixture prune-broad-egress
yq -i '(select(.kind == "CiliumNetworkPolicy" and
  .metadata.name == "openbao-raft-snapshot-prune") | .spec.egress) +=
  [{"toEntities":["world"]}]' \
  "$test_tmp/prune-broad-egress/platform/openbao/raft-snapshot-prune.yaml"
expect_rejected prune-broad-egress \
  'prune egress needs exact kube-dns L7 observation'

# The pod label and the policy selector are a pair. Under this namespace's
# default-deny a mismatch is not a loose policy — it is a pod with no egress at
# all, which fails as a DNS timeout rather than as anything mentioning policy.
make_fixture prune-label-drift
yq -i '(select(.kind == "CronJob") |
  .spec.jobTemplate.spec.template.metadata.labels."app.kubernetes.io/component") = "daily-offsite"' \
  "$test_tmp/prune-label-drift/platform/openbao/raft-snapshot-prune.yaml"
expect_rejected prune-label-drift \
  'prune pod label must match its own policy selector'

# The script is inert unless kustomize ships it into the shared ConfigMap.
make_fixture prune-script-unshipped
yq -i 'del(.configMapGenerator[] | select(.name == "openbao-snapshot-scripts") |
  .files[] | select(. == "snapshot-prune.sh"))' \
  "$test_tmp/prune-script-unshipped/platform/openbao/kustomization.yaml"
expect_rejected prune-script-unshipped \
  'snapshot-prune.sh must be in the openbao-snapshot-scripts configMapGenerator'

printf '%s\n' 'PASS: identity, token isolation, artifact modes/groups, secret routing, DNS observation/resolver scope, egress, convergence-contract, and retention mutations are rejected.'
