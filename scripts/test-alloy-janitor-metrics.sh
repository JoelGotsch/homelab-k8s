#!/usr/bin/env bash
# Contract test between the reboot-cascade janitor's "[metric]" lines and the
# Alloy pipeline that turns them into Prometheus series.
#
# WHY. The janitor's metrics are log-derived (no Pushgateway by ADR 0062, no
# textfile collector on Talos): the Job prints
#     [metric] janitor_remediation_total signature=... action=... node=... dry_run=...
# and `loki.process "janitor_metrics"` in observability/alloy/values.yaml
# parses it with a regex into labelled counters and gauges. Two files, one
# format, no compiler between them: drift breaks the alerts in
# janitor-rules.yaml silently — the line still ships to Loki, the regex just
# stops matching, and the counter is never incremented. That is the "green
# while checking nothing" shape lessons.md tracks, so the contract is
# executed here rather than read.
#
# WHICH HALF THIS CHECK OWNS — measured 2026-09-09, not assumed. This script's
# INPUT is the metric lines the fixtures pin, so it cannot see a change on the
# janitor side; an earlier version of this comment claimed it caught "a rename
# on either side", and re-introducing one proved that false:
#
#   janitor prints `host=` instead of `node=`   -> THIS SCRIPT PASSES.
#   janitor stops printing the run gauge        -> THIS SCRIPT PASSES.
#   Alloy's regex renames a capture group       -> caught here.
#   Alloy's stage.label_drop is removed         -> caught here.
#   River syntax broken                         -> caught by check-alloy-config.sh.
#
# The janitor half is owned by scripts/test-reboot-cascade-janitor.sh, whose
# scenarios 15-18 assert the exact "[metric]" lines against the deployed
# manifest — both janitor-side mutations above fail scenario 15 loudly. So the
# pair is complete only together: the harness proves the janitor emits these
# lines, this script proves these lines become the series the alerts query.
# If you ever change the line format, the fixtures are the file to edit first;
# this script then re-derives its expectations from them automatically.
#
# HOW. The fixture scenarios under scripts/fixtures/reboot-cascade-janitor/
# pin the exact metric lines the janitor prints (the offline harness asserts
# the janitor really prints them). This script feeds those SAME lines through
# the REAL janitor_metrics block — extracted verbatim from values.yaml — in a
# local `alloy run` with the pod-log stream labels the DaemonSet would attach,
# and reads Alloy's /metrics back. It asserts that every distinct remediation
# line became exactly one series, that the janitor pod's own stream labels
# were dropped (the property that keeps a counter alive across ticks), and
# that the gauges exist. `alloy validate` (check-alloy-config.sh) proves the
# config loads; this proves it does what the alerts assume.
#
# Needs: yq, curl, python3, alloy (brew install grafana-alloy). Missing
# `alloy` is a hard failure, not a skip.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALUES="$REPO_ROOT/observability/alloy/values.yaml"
FIXTURES="$REPO_ROOT/scripts/fixtures/reboot-cascade-janitor"

for tool in yq curl python3 alloy; do
  command -v "$tool" >/dev/null 2>&1 || {
    if [ "$tool" = alloy ]; then
      printf 'ERROR: alloy is required (brew install grafana-alloy); this is a hard failure, not a skip\n' >&2
    else
      printf 'ERROR: %s is required\n' "$tool" >&2
    fi
    exit 2
  }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/alloy-janitor-metrics.XXXXXX")"
ALLOY_PID=""
cleanup() {
  if [ -n "$ALLOY_PID" ]; then kill "$ALLOY_PID" 2>/dev/null || true; wait "$ALLOY_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ---------------------------------------------------------------- input
# Every metric line the fixtures pin, in fixture order. Not de-duplicated:
# a line two scenarios both pin must count twice, which is the counter
# semantics the alerts rely on.
find "$FIXTURES" -mindepth 2 -maxdepth 2 -name expect-log | sort \
  | xargs grep -h '^\[metric\] ' > "$WORK/janitor.log" || true
INPUT_LINES=$(wc -l < "$WORK/janitor.log" | tr -d ' ')
[ "$INPUT_LINES" -gt 0 ] || { printf 'ERROR: no [metric] lines pinned under %s\n' "$FIXTURES" >&2; exit 1; }
WANT_REMEDIATION_SERIES=$(grep '^\[metric\] janitor_remediation_total ' "$WORK/janitor.log" | sort -u | wc -l | tr -d ' ')
WANT_STREAK_NODES=$(sed -n 's/^\[metric\] janitor_state_streak node=\([^ ]*\) .*/\1/p' "$WORK/janitor.log" | sort -u | wc -l | tr -d ' ')

# ---------------------------------------------------------------- config
yq -e '.alloy.configMap.content' "$VALUES" > "$WORK/full.alloy"
awk '/^loki\.process "janitor_metrics"/ {p=1} p {print} p && /^}$/ {exit}' "$WORK/full.alloy" > "$WORK/branch.alloy"
[ -s "$WORK/branch.alloy" ] || { printf 'ERROR: could not extract loki.process "janitor_metrics" from %s\n' "$VALUES" >&2; exit 1; }

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

# The stream labels discovery.relabel "pods" attaches to a janitor Job pod,
# as observed in Loki on 2026-09-09 — the ones the branch must drop.
cat > "$WORK/test.alloy" <<CFG
loki.source.file "janitor" {
  targets = [{
    __path__  = "$WORK/janitor.log",
    namespace = "reboot-cascade-janitor",
    pod       = "reboot-cascade-janitor-29816150-fbsbj",
    container = "janitor",
    app       = "reboot-cascade-janitor",
    job       = "loki.source.kubernetes.pods",
    instance  = "reboot-cascade-janitor/reboot-cascade-janitor-29816150-fbsbj:janitor",
  }]
  forward_to = [loki.process.janitor_metrics.receiver]
}
CFG
cat "$WORK/branch.alloy" >> "$WORK/test.alloy"

alloy validate "$WORK/test.alloy" >/dev/null

# ---------------------------------------------------------------- run
alloy run --server.http.listen-addr="127.0.0.1:$PORT" --storage.path="$WORK/storage" \
  "$WORK/test.alloy" > "$WORK/alloy.out" 2>&1 &
ALLOY_PID=$!

# Wait for the exporter, then for the file to have been read through.
got=0
for _ in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:$PORT/metrics" > "$WORK/metrics" 2>/dev/null; then
    n=$(grep -c '^janitor_remediation_total{' "$WORK/metrics" || true)
    if [ "$n" -ge "$WANT_REMEDIATION_SERIES" ]; then got=1; break; fi
  fi
  if ! kill -0 "$ALLOY_PID" 2>/dev/null; then break; fi
  sleep 0.5
done
if [ "$got" -ne 1 ]; then
  printf 'FAIL: alloy did not expose %s janitor_remediation_total series within 30s\n' "$WANT_REMEDIATION_SERIES" >&2
  printf -- '---- alloy output ----\n' >&2; tail -30 "$WORK/alloy.out" >&2
  printf -- '---- janitor_ metrics seen ----\n' >&2; grep '^janitor_' "$WORK/metrics" >&2 || true
  exit 1
fi
grep '^janitor_' "$WORK/metrics" | sort > "$WORK/janitor-metrics"

# ---------------------------------------------------------------- assert
# Alloy attaches its own labels to a component's metrics — `component_id`,
# `component_path`, and (from loki.source.file, which only this test uses)
# `filename`. In the cluster the scrape adds `job`/`instance`/`pod` for the
# ALLOY pod on top. None of them are part of the contract, and every
# expression in janitor-rules.yaml aggregates them away, so they are stripped
# before comparing. What IS asserted is that no label of the JANITOR's own log
# stream survived: a counter re-labelled with a per-tick Job pod name would
# start at 1 every five minutes and never look like an increase.
python3 - "$WORK/janitor.log" "$WORK/janitor-metrics" <<'PYEOF'
import collections, re, sys

log_path, metrics_path = sys.argv[1], sys.argv[2]

ALLOY_OWN = {"component_id", "component_path", "filename"}
# Stream labels discovery.relabel "pods" puts on a janitor Job pod's entries.
STREAM = ["namespace", "pod", "container", "app", "component", "job", "instance"]

SERIES = re.compile(r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{(?P<labels>.*)\})?\s+(?P<value>\S+)$")
LABEL = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:[^"\\]|\\.)*)"')

exported = {}   # (name, frozenset(labels)) -> float
raw = []
for line in open(metrics_path):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    m = SERIES.match(line)
    if not m:
        print("FAIL: could not parse exported line: %s" % line, file=sys.stderr)
        sys.exit(1)
    raw.append(line)
    labels = {k: v for k, v in LABEL.findall(m.group("labels") or "")}
    kept = frozenset((k, v) for k, v in labels.items() if k not in ALLOY_OWN)
    exported[(m.group("name"), kept)] = float(m.group("value"))

# Expected remediation series: every distinct pinned line, valued by how often
# the fixtures pin it (counter semantics: same target twice = 2).
want = collections.Counter()
streak_nodes = set()
saw_ts = saw_dur = False
for line in open(log_path):
    line = line.strip()
    if not line.startswith("[metric] "):
        continue
    _, name, *kvs = line.split()
    fields = dict(kv.split("=", 1) for kv in kvs if "=" in kv)
    if name == "janitor_remediation_total":
        want[(name, frozenset(fields.items()))] += 1
    elif name == "janitor_state_streak":
        streak_nodes.add(fields["node"])
    elif name == "janitor_run_timestamp_seconds":
        saw_ts = True
    elif name == "janitor_run_duration_seconds":
        saw_dur = True

rc = 0
def fail(msg):
    global rc
    print("FAIL: %s" % msg, file=sys.stderr)
    rc = 1

for key, count in sorted(want.items(), key=lambda kv: sorted(kv[0][1])):
    labels = dict(key[1])
    pretty = "%s{%s}" % (key[0], ",".join("%s=%s" % (k, labels[k]) for k in sorted(labels)))
    if key not in exported:
        fail("pinned line produced no matching series: %s (expected value %d)" % (pretty, count))
    elif exported[key] != count:
        fail("%s = %g, expected %d (the fixtures pin that line %d time(s))"
             % (pretty, exported[key], count, count))

got_remediation = sum(1 for (n, _) in exported if n == "janitor_remediation_total")
if got_remediation != len(want):
    fail("expected %d distinct janitor_remediation_total series, got %d"
         % (len(want), got_remediation))

got_streak = {dict(l).get("node") for (n, l) in exported if n == "janitor_state_streak"}
if got_streak != streak_nodes:
    fail("janitor_state_streak nodes %s, expected %s" % (sorted(got_streak), sorted(streak_nodes)))

for name, seen in (("janitor_run_timestamp_seconds", saw_ts), ("janitor_run_duration_seconds", saw_dur)):
    if not seen:
        fail("no fixture pins a %s line, so this test proves nothing about it" % name)
    elif not any(n == name for (n, _) in exported):
        fail("%s not exported" % name)

for label in STREAM:
    leaked = [l for l in raw if re.search(r'[{,]%s="' % label, l)]
    if leaked:
        fail("janitor log-stream label '%s' leaked onto a derived series "
             "(a counter under a per-tick pod label never increases):\n    %s"
             % (label, "\n    ".join(leaked)))

if rc:
    print("---- janitor_ series exported ----", file=sys.stderr)
    for line in raw:
        print("    %s" % line, file=sys.stderr)
    sys.exit(1)

print("ok   %d pinned line(s) -> %d janitor_remediation_total series with exact "
      "labels+counts, janitor_state_streak for %s, both run gauges present, "
      "no stream label leaked"
      % (sum(want.values()) + len(streak_nodes) + saw_ts + saw_dur,
         got_remediation, ",".join(sorted(streak_nodes))))
PYEOF
