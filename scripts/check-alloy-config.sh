#!/usr/bin/env bash
# Validate the inline Alloy configuration in observability/alloy/values.yaml.
#
# WHY. The Alloy DaemonSet ships every pod's logs on every node, and since
# 2026-09-09 it also derives the reboot-cascade janitor's metrics from those
# logs (loki.process "janitor_metrics"). Its configuration is a River
# document embedded as a YAML string, which no YAML or kustomize check can
# parse: a typo in a stage block is invisible until Argo rolls the DaemonSet
# and every Alloy pod crash-loops — which is exactly how the journald block
# took log shipping down once already (see the NOTE in values.yaml). The
# blast radius of a bad edit is cluster-wide log loss, so the config is
# validated the way the rule files are: with the real binary, before commit.
#
# `alloy validate` loads the file and evaluates every component's
# arguments — regex, LogQL selectors, stage layout — without starting any.
#
# Exit 0 = valid. Exit 1 = invalid, or `alloy` is missing. Missing is a hard
# failure, not a skip, for the same reason check-prometheusrule-tests.sh
# fails without promtool: a check that passes when its tool is absent is
# the "green while checking nothing" shape lessons.md tracks.

set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALUES="$REPO_ROOT/observability/alloy/values.yaml"

if ! command -v yq >/dev/null 2>&1; then
  echo "check-alloy-config: yq is required to extract .alloy.configMap.content" >&2
  exit 1
fi
if ! command -v alloy >/dev/null 2>&1; then
  cat >&2 <<'MSG'
check-alloy-config: `alloy` is NOT installed, so the inline Alloy config was
not validated. This is a hard failure, not a skip.

Install it (the cluster runs the chart-pinned image; any 1.x binary parses
the same River syntax — 1.19.2 validated the 1.17.1 config on 2026-09-09):

  brew install grafana-alloy
MSG
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if ! yq -e '.alloy.configMap.content | select(. != null and length > 0)' "$VALUES" >"$WORK/config.alloy" 2>/dev/null; then
  echo "check-alloy-config: no .alloy.configMap.content in $VALUES" >&2
  exit 1
fi

if alloy validate "$WORK/config.alloy"; then
  echo "check-alloy-config: $VALUES inline config is valid ($(alloy --version 2>/dev/null | head -1))"
else
  echo "check-alloy-config: FAILED — $VALUES inline Alloy config does not validate" >&2
  exit 1
fi
