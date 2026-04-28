# external-hosts/

Prometheus scrape config + alerts for non-cluster hosts that
the cluster monitors over HTTP — currently the Mac Studio
inference host (per ADR 0005 + ADR 0026).

## What's here

- `additional-scrape-configs.yaml` — Secret consumed by the
  Prometheus CR via `spec.additionalScrapeConfigs`. Defines two
  static jobs:
    - `mac-studio-node` — scrapes node_exporter on :9100
    - `mac-studio-mlx` — scrapes the custom mlx-exporter on :9101
- `prometheus-rules.yaml` — PrometheusRule CRD with the
  `mac-studio.rules` group:
    - `MacStudioNodeExporterDown` — :9100 unreachable
    - `MacStudioMLXExporterDown` — :9101 unreachable
    - `MacStudioMLXServerDown` — MLX HTTP API down
    - `MacStudioOllamaDown` — Ollama HTTP API down
    - `MacStudioModelsDiskHigh` — models dir > 80% of expected ceiling
    - `MacStudioFilesystemFull` — root or /opt > 90%
- `kustomization.yaml` — bundles both into the
  `monitoring` namespace.

## Operator inputs

The Mac Studio's static IP is the only operator-specific value.
Edit `additional-scrape-configs.yaml` and replace
`MAC_STUDIO_INFERENCE_IP` with the address from the inference
VLAN (typically `10.x.x.x` per `network.md`).

## Wiring this into Prometheus

The kube-prometheus-stack (or whichever Prometheus chart this
repo eventually settles on) exposes
`prometheus.prometheusSpec.additionalScrapeConfigs` to point at
a Secret. Configure that to reference
`additional-scrape-configs` / key `prometheus-additional.yaml`.

For the alert group, the Prometheus operator picks up
`PrometheusRule` resources via `ruleSelector` — the chart's
default selector matches all rules in the `monitoring`
namespace, so no extra wiring is needed.

## Why a Secret (not a ConfigMap)

Prometheus operator's `additionalScrapeConfigs` field requires
a Secret reference. No actual secrets are stored here — but if
basic-auth or a bearer token is added later, Secret is already
the correct shape.
