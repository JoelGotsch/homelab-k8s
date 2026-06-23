# observability/talos-log-sink

Receiver for Talos's `machine.logging.destinations` — see the
matching Talos patch at
`homelab-infra/talos/patches/logging-destinations.yaml`.

## What it is

A Vector DaemonSet that:

- Listens on `0.0.0.0:6514/tcp` (hostPort 6514) for `json_lines`
  payloads pushed by `machined` on each Talos node.
- Writes them to a **node-local hostPath** at
  `/var/log/talos-log-sink/`, one file per day
  (`talos-YYYY-MM-DD.log`). Each node has its own copy of
  its own logs — independent of Longhorn (which depends on
  the CP being healthy to attach volumes, exactly the
  failure we're trying to be resilient to).
- Exposes a ClusterIP Service `talos-log-sink` on 6514/tcp so the
  Talos config can use a DNS name, even though every node
  actually writes to its own local pod via hostPort.

No auth. No TLS. No OpenBao / ESO / Loki / Longhorn
dependency. Closed loop inside the cluster, survives a
reboot of any single node because Talos's ephemeral
partition persists `/var/log/talos-log-sink/` across
reboots. A node losing its own crash logs to a disk
failure is no worse than today's in-memory-only state.

## Why hostPort 6514, not a Service VIP only

A Talos node dialing `talos-log-sink.monitoring.svc:6514` would
normally hit Cilium's eBPF and land on any pod in the DaemonSet.
With hostPort the connection short-circuits to the **local**
peer pod — no inter-node hop, no dependency on CNI being healthy
for the local node's logs to escape its tmpfs. That's the whole
reason this receiver exists: to survive partial cluster outages.

## Why not Loki / Alloy directly

This receiver's job is *kernel ring + machined services + kubelet
+ containerd* — the streams that are gone after a reboot. Alloy
(in `observability/alloy/`) already ships pod logs and journald
to Loki for steady-state observability. This receiver is the
forensic-evidence backstop.

Loki is also currently degraded (ESO refresh blocked by sealed
OpenBao), so coupling the forensic path to Loki would have
defeated the purpose.

## Files

| File | Purpose |
|---|---|
| `namespace.yaml` | (not needed — reuses `monitoring`) |
| `daemonset.yaml` | Vector container, hostPort 6514, PVC mount |
| `service.yaml` | ClusterIP for the Talos config DNS name |
| `configmap.yaml` | Vector toml config |
| `networkpolicy.yaml` | Ingress on 6514/tcp from node CIDR |
| `kustomization.yaml` | Wires everything into Argo |

## Bring-up order

1. Argo sync this layer **first** (receiver up before patch).
2. Verify `kubectl -n monitoring get ds talos-log-sink` shows
   one ready pod per node.
3. Apply the Talos patch per
   `homelab-docs/03-runbooks/talos/log-sink-bring-up.md`.
4. Verify lines flow:
   `kubectl -n monitoring exec ds/talos-log-sink -- tail -n 5 /sink/talos-$(date +%F).log`

## Caveats

- Vector buffers in-memory only for now. If the receiver pod is
  rescheduled mid-write, in-flight Talos lines are dropped on
  TCP RST. Acceptable — the alternative (Talos node losing
  evidence in its own crash) is what we're solving.
- Log volume on a 6-node cluster is small (~MB/day per node
  steady-state). We don't rotate automatically; operator
  runs `kubectl exec ds/talos-log-sink -- rm /sink/talos-OLD.log`
  during quarterly housekeeping. Each node's volume is its
  own — querying across nodes during an incident means
  iterating the DaemonSet pods.
- No alerting on receiver-down. If the receiver is down at
  the moment of a Talos crash, evidence is lost — same as
  today's "no receiver at all" state, no regression.
