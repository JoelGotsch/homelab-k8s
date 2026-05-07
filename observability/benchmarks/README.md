# observability/benchmarks

One-shot performance baselines that run during cluster bring-up. The
manifest in this layer is **not** continuously-reconciled steady state —
it captures a number, the operator collects it, and the layer is
removed from git so Argo prunes it. Anything kept past bring-up belongs
in `kube-prometheus-stack/` or its own observability layer, not here.

## What runs here

### `write-speed-baseline.yaml` — persistent-write fio baseline

Runs once per cluster node (DaemonSet, tolerations for the
control-plane taint) post-Talos install, captures:

- `smartctl -a /dev/nvme0n1` pre-fio → `<host>-smart-pre.txt`
- `fio --rw=randwrite --bs=4k --size=200G --runtime=1800 --time_based
  --ioengine=libaio --direct=1 --numjobs=1 --iodepth=16
  --output-format=json` against a hostPath file →
  `<host>-fio.json`
- `smartctl -a /dev/nvme0n1` post-fio → `<host>-smart-post.txt`

Outputs land on each node at `/var/lib/fio-baseline/`. After fio
completes the runner deletes its 200 GB scratch file and `sleep
infinity`s; a sentinel file (`<host>-fio.json`) keeps the run idempotent
across pod restarts. The manifest is sync-wave 50 (after the
observability ApplicationSet's wave 5) so it lands well after Cilium /
OpenBao / Argo CD are healthy.

The runner image is `debian:12-slim` plus an apt install of fio +
smartmontools at startup. No pinned benchmarking image; the apt fetch
runs once per node and adds ~30 s before fio starts (negligible
against a 1 800 s run).

This baseline measures the **Talos + containerd + ext4 stack** —
i.e., what real workloads see — not raw NVMe firmware. If a node
shows >10 % deviation from the cohort median or any `smartctl` thermal
event, drop into a Talos debug shell on that node for raw NVMe
inspection (worker thermal-pad inspection per `cold-start.md §1c` is
the most likely root cause).

## Operator workflow

1. Reconcile this layer via Argo CD (Phase E1 of
   [`bring-up-progress.md`](../../../homelab-docs/04-guides/bring-up-progress.md#phase-e--persistent-write-speed-baseline-30-min-post-talos)).
2. Wait for fio: `kubectl -n observability-benchmarks logs ds/write-speed-baseline -c runner -f`
   (~30 min until each pod prints `[baseline] complete`).
3. Collect outputs from each node. Easiest path is a one-shot debug
   pod per node:

   ```sh
   for n in cp1 cp2 cp3 worker1 worker2 worker3; do
     kubectl debug node/${n} \
       --image=alpine --profile=sysadmin -- \
       sh -c "tar -C /host/var/lib/fio-baseline -cf - ." \
       | tar -C ./fio-baseline -xf -
   done
   ```

4. Aggregate to a markdown table (IOPS, throughput, p50 / p99 latency,
   throttle events) and append into the journal entry at
   `homelab-docs/99-journal/2026-05-07-cluster-write-speed-baseline.md`.
5. Delete this directory + commit. Argo prunes the namespace +
   DaemonSet + ConfigMap. The hostPath data on each node remains
   (small smart text files); operator can `rm -rf
   /var/lib/fio-baseline` from a debug shell if cleanup matters.

## What this layer is *not*

- Not a continuous performance regression check. A long-running
  cron-style benchmark belongs in its own layer with retention,
  alerting, and a Grafana dashboard — none of those are wired up
  here.
- Not a stress test. fio randwrite at 200 GB / 30 min is a *baseline*,
  not a torture test; the goal is "does this match the spec sheet,"
  not "does this fail under load."
