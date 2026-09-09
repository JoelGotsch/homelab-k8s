#!/usr/bin/env bash
# Offline decision-logic tests for the reboot-cascade janitor.
#
# WHY THIS EXISTS. On 2026-09-09 the janitor turned one dead FUSE mount
# into a 5.5-hour, 28-Argo-app outage through four defects that were all
# invisible to reading the file: it escalated straight to a node-plugin
# restart, its per-node restart cap was re-initialised every tick, its
# candidate list excluded by construction the Running-but-broken pods
# its own remediation created, and its signature-B pattern was the bare
# substring "already exists". None of that could be seen without
# executing the decision logic, and executing it meant breaking a
# production cluster. So the logic is now exercised against recorded
# fixtures instead.
#
# HOW IT WORKS. The shell body is extracted from the CronJob in
# infrastructure/reboot-cascade-janitor/reboot-cascade-janitor.yaml —
# the deployed artifact, not a copy — and run with kubectl, date and
# sleep faked. Every mutation in that script goes through its act()
# helper, which prints one "[act] <verb> <subject> k=v ..." line, so a
# scenario's expectations are just that plan plus log substrings. A
# mutation added outside act() is invisible here, which is the same
# property that makes DRY_RUN trustworthy.
#
# ADD A SCENARIO: mkdir scripts/fixtures/reboot-cascade-janitor/NN-name
# and drop in any of
#   pending.json            get pods -A --field-selector status.phase=Pending
#   consumers-<node>.json   get pods -A --field-selector spec.nodeName=<node>,status.phase=Running
#   plugins.json            get pods -n csi-rclone -l app=csi-rclone-node
#   plugins-after-<node>.json  the same query during the post-restart readiness poll
#   events-<uid>.json       get events --field-selector involvedObject.uid=<uid>
#   pv.json                 get pv
#   state.json              get configmap <state>   (absent = NotFound)
#   inherit                 name of another scenario to fall back to
#   env                     KEY=value overrides, one per line
#   expect                  the exact [act] plan, in order (empty = no actions)
#   expect-log              substrings that MUST appear in the run log
#   reject-log              substrings that must NOT appear
#   expect-kubectl          substrings that MUST appear in the faked mutations
#   expect-no-mutations     non-empty = the run must not call a mutating verb
# MUTATION TESTS. After the scenarios, each of the four 2026-09-09
# defects is re-introduced into a COPY of the manifest and the scenario
# that guards it must fail. A green suite that stays green when the bug
# comes back is the thing this file exists to prevent. Skip them with
# --no-mutations; run one scenario alone by naming it as an argument.
#
# Anything not present falls back to the scenario named in `inherit`,
# then to _common/. Defaults for the janitor's own tunables come from
# the ConfigMap in the manifest, so a threshold edit is exercised by
# these tests rather than silently ignored by them.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="${JANITOR_MANIFEST:-$REPO_ROOT/infrastructure/reboot-cascade-janitor/reboot-cascade-janitor.yaml}"
FIXTURES="$SCRIPT_DIR/fixtures/reboot-cascade-janitor"
COMMON="$FIXTURES/_common"

# The frozen clock every fixture timestamp is expressed against:
# 2026-09-09T05:30:00Z, the tick at which the incident's escalation
# ladder would have fired.
FAKE_NOW=1788931800

for tool in yq jq sed awk; do
  command -v "$tool" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "$tool" >&2
    exit 2
  }
done
[ -f "$MANIFEST" ] || { printf 'ERROR: manifest not found: %s\n' "$MANIFEST" >&2; exit 2; }

TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/reboot-cascade-janitor-test.XXXXXX")"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

# ---------------------------------------------------------------- extract
JANITOR_SH="$TEMP_ROOT/janitor.sh"
yq e 'select(.kind == "CronJob") | .spec.jobTemplate.spec.template.spec.containers[0].args[0]' \
  "$MANIFEST" > "$JANITOR_SH"
[ -s "$JANITOR_SH" ] || { printf 'ERROR: could not extract the janitor script from %s\n' "$MANIFEST" >&2; exit 2; }
sh -n "$JANITOR_SH" || { printf 'ERROR: extracted janitor script is not valid POSIX sh\n' >&2; exit 1; }

# ---------------------------------------------------------------- fakes
BIN="$TEMP_ROOT/bin"
mkdir -p "$BIN"

cat >"$BIN/date" <<'FAKE'
#!/usr/bin/env bash
# The janitor asks for one thing only. Anything else is a new time
# dependency the fixtures cannot pin, so fail loudly rather than drift.
if [ "$*" = "-u +%s" ]; then printf '%s\n' "$FAKE_NOW"; exit 0; fi
printf 'unexpected date invocation: %s\n' "$*" >&2
exit 90
FAKE

cat >"$BIN/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE

cat >"$BIN/kubectl" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail

args="$*"

find_fixture() {
  local name="$1" dir
  for dir in $FIXTURE_DIRS; do
    if [ -f "$dir/$name" ]; then printf '%s\n' "$dir/$name"; return 0; fi
  done
  return 1
}

serve() {           # serve PRIMARY [FALLBACK]
  local f
  if f=$(find_fixture "$1"); then cat "$f"; exit 0; fi
  if [ -n "${2:-}" ] && f=$(find_fixture "$2"); then cat "$f"; exit 0; fi
  printf 'MISSING FIXTURE: %s (for: kubectl %s)\n' "$1" "$args" >&2
  exit 91
}

field_value() {     # field_value spec.nodeName -> X, from --field-selector
  printf '%s\n' "$args" | tr ' ,' '\n\n' | sed -n "s/^$1=//p" | head -1
}

verb="${1:-}"
case "$verb" in
  delete|patch|create|apply|annotate|label|scale)
    printf '%s\n' "$args" >>"$FAKE_KUBECTL_LOG"
    exit 0
    ;;
  get) ;;
  *) printf 'unexpected kubectl invocation: %s\n' "$args" >&2; exit 90 ;;
esac

case "${2:-}" in
  pv|persistentvolumes|persistentvolume)
    serve pv.json
    ;;
  configmap|configmaps|cm)
    f=$(find_fixture state.json) || {
      printf 'Error from server (NotFound): configmaps not found\n' >&2
      exit 1
    }
    cat "$f"
    exit 0
    ;;
  events|event)
    uid=$(field_value involvedObject.uid)
    serve "events-${uid}.json" events-default.json
    ;;
  pods|pod)
    node=$(field_value spec.nodeName)
    if [[ "$args" == *" -l "* ]]; then
      # node-plugin DaemonSet query; with a node selector it is the
      # post-restart readiness poll, which may see a replacement.
      if [ -n "$node" ]; then serve "plugins-after-${node}.json" plugins.json; fi
      serve plugins.json
    elif [[ "$args" == *"status.phase=Pending"* ]]; then
      serve pending.json
    elif [[ "$args" == *"status.phase=Running"* ]]; then
      serve "consumers-${node}.json"
    fi
    printf 'unexpected pod query: %s\n' "$args" >&2
    exit 90
    ;;
esac
printf 'unexpected kubectl get: %s\n' "$args" >&2
exit 90
FAKE
chmod +x "$BIN/date" "$BIN/sleep" "$BIN/kubectl"

# --------------------------------------------------- defaults from the manifest
# Read the janitor's tunables from the ConfigMap it actually ships with,
# so a threshold edit is covered by these tests instead of bypassing
# them — and so a variable the script reads but the ConfigMap does not
# define fails here (set -u) rather than in the cluster.
CONFIG_ENV="$TEMP_ROOT/config.env"
yq e 'select(.kind == "ConfigMap" and .metadata.name == "reboot-cascade-janitor-config")
      | .data | to_entries | .[] | .key + "=" + .value' "$MANIFEST" >"$CONFIG_ENV"
[ -s "$CONFIG_ENV" ] || { printf 'ERROR: no reboot-cascade-janitor-config ConfigMap in the manifest\n' >&2; exit 2; }

shipped_dry_run="$(yq e 'select(.kind == "ConfigMap" and .metadata.name == "reboot-cascade-janitor-config") | .data.DRY_RUN' "$MANIFEST")"
case "$shipped_dry_run" in
  true | false) ;;
  *)
    printf 'ERROR: shipped DRY_RUN is %s; the script compares it to the string "true", so anything else means acting mode by accident\n' \
      "$shipped_dry_run" >&2
    exit 1
    ;;
esac
printf 'note: shipped DRY_RUN=%s (scenarios run in acting mode regardless; see run_scenario)\n\n' "$shipped_dry_run"

FAILURES=0
RAN=0

read_lines() {      # read_lines FILE -> prints file or nothing
  [ -f "$1" ] && cat "$1" || true
}

run_scenario() {
  local scen="$1"
  local dir="$FIXTURES/$scen"
  RAN=$((RAN + 1))

  local dirs="$dir"
  if [ -f "$dir/inherit" ]; then
    local parent
    parent="$(tr -d '[:space:]' <"$dir/inherit")"
    [ -d "$FIXTURES/$parent" ] || { printf 'FAIL %s: inherit names a missing scenario: %s\n' "$scen" "$parent" >&2; FAILURES=$((FAILURES + 1)); return; }
    dirs="$dirs $FIXTURES/$parent"
  fi
  dirs="$dirs $COMMON"

  local work="$TEMP_ROOT/work/$scen"
  mkdir -p "$work"
  local out="$work/run.log"
  local kubelog="$work/kubectl.log"
  : >"$kubelog"

  (
    set -a
    # shellcheck disable=SC1090
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      export "${line%%=*}=${line#*=}"
    done <"$CONFIG_ENV"
    # The scenarios exercise the ACTING path by default, whatever the
    # shipped DRY_RUN happens to be: an operator flipping that key must
    # not silently turn every assertion in this suite into a no-op. The
    # dry-run path is covered by the scenario that asks for it (12).
    DRY_RUN=false
    if [ -f "$dir/env" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        export "${line%%=*}=${line#*=}"
      done <"$dir/env"
    fi
    POD_NAMESPACE=reboot-cascade-janitor
    JANITOR_WORKDIR="$work/scratch"
    FIXTURE_DIRS="$dirs"
    FAKE_KUBECTL_LOG="$kubelog"
    FAKE_NOW="$FAKE_NOW"
    PATH="$BIN:$PATH"
    set +a
    sh "$JANITOR_SH"
  ) >"$out" 2>&1
  local rc=$?

  local ok=1
  if [ "$rc" -ne 0 ]; then
    printf 'FAIL %s: janitor exited %d\n' "$scen" "$rc" >&2
    ok=0
  fi

  # 1. the [act] plan, exactly and in order
  local want_acts="$work/want-acts" got_acts="$work/got-acts"
  read_lines "$dir/expect" | grep -v '^[[:space:]]*$' >"$want_acts" || true
  sed -n 's/^\[act\] //p' "$out" | sed 's/^/[act] /' >"$got_acts"
  if ! diff -u "$want_acts" "$got_acts" >"$work/acts.diff"; then
    printf 'FAIL %s: action plan differs (want < / got >):\n' "$scen" >&2
    sed 's/^/    /' "$work/acts.diff" >&2
    ok=0
  fi

  # 2. required log substrings
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    if ! grep -qF -- "$needle" "$out"; then
      printf 'FAIL %s: log is missing: %s\n' "$scen" "$needle" >&2
      ok=0
    fi
  done < <(read_lines "$dir/expect-log")

  # 3. forbidden log substrings
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    if grep -qF -- "$needle" "$out"; then
      printf 'FAIL %s: log must not contain: %s\n' "$scen" "$needle" >&2
      ok=0
    fi
  done < <(read_lines "$dir/reject-log")

  # 4. required faked mutations
  while IFS= read -r needle; do
    [ -n "$needle" ] || continue
    if ! grep -qF -- "$needle" "$kubelog"; then
      printf 'FAIL %s: expected kubectl call missing: %s\n' "$scen" "$needle" >&2
      ok=0
    fi
  done < <(read_lines "$dir/expect-kubectl")

  # 5. dry runs must not touch anything
  if [ -s "$dir/expect-no-mutations" ] && [ -s "$kubelog" ]; then
    printf 'FAIL %s: dry run issued mutating kubectl calls:\n' "$scen" >&2
    sed 's/^/    /' "$kubelog" >&2
    ok=0
  fi

  # 6. no fixture may be silently missing
  if grep -q 'MISSING FIXTURE' "$out"; then
    printf 'FAIL %s: a kubectl query had no fixture:\n' "$scen" >&2
    grep 'MISSING FIXTURE' "$out" | sed 's/^/    /' >&2
    ok=0
  fi

  if [ "$ok" -eq 1 ]; then
    printf 'ok   %s\n' "$scen"
  else
    FAILURES=$((FAILURES + 1))
    printf '%s\n' "---- $scen run log ----" >&2
    sed 's/^/    /' "$out" >&2
    printf '%s\n' '--------------------' >&2
  fi
}

RUN_MUTATIONS=1
wanted=()
for arg in "$@"; do
  case "$arg" in
    --no-mutations) RUN_MUTATIONS=0 ;;
    -*) printf 'ERROR: unknown flag: %s\n' "$arg" >&2; exit 2 ;;
    *) wanted+=("$arg"); RUN_MUTATIONS=0 ;;
  esac
done
if [ -n "${JANITOR_MANIFEST:-}" ]; then RUN_MUTATIONS=0; fi
if [ "${#wanted[@]}" -eq 0 ]; then
  while IFS= read -r d; do
    wanted+=("$(basename "$d")")
  done < <(find "$FIXTURES" -mindepth 1 -maxdepth 1 -type d ! -name '_*' | sort)
fi

for scen in "${wanted[@]}"; do
  [ -d "$FIXTURES/$scen" ] || { printf 'ERROR: no such scenario: %s\n' "$scen" >&2; exit 2; }
  run_scenario "$scen"
done

if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d of %d scenario(s) FAILED\n' "$FAILURES" "$RAN" >&2
  exit 1
fi
printf '\nall %d scenario(s) passed\n' "$RAN"

# ------------------------------------------------------------- mutations
# Each row: description | scenario that must fail | yq expression that
# re-introduces one of the 2026-09-09 defects into the config ConfigMap.
run_mutation() {
  local desc="$1" scen="$2" expr="$3"
  local mutated="$TEMP_ROOT/mutated.yaml"
  yq e "(select(.kind == \"ConfigMap\" and .metadata.name == \"reboot-cascade-janitor-config\") | $expr)" \
    "$MANIFEST" >"$mutated"
  if JANITOR_MANIFEST="$mutated" "$0" "$scen" >"$TEMP_ROOT/mutation.log" 2>&1; then
    printf 'FAIL mutation not caught: %s (scenario %s still passed)\n' "$desc" "$scen" >&2
    MUT_FAILURES=$((MUT_FAILURES + 1))
  else
    printf 'ok   mutation caught by %-24s %s\n' "$scen" "$desc"
  fi
}

if [ "$RUN_MUTATIONS" -eq 1 ]; then
  printf '\n'
  MUT_FAILURES=0
  run_mutation 'defect (d): bare "already exists" pattern' \
    10-loose-already-exists '.data.OP_EXISTS_PATTERN = "already exists"'
  run_mutation 'defect (a): signature B goes straight to a plugin restart' \
    05-sig-b-first-tick '.data.CHEAP_FIX_TICKS_BEFORE_ESCALATION = "1"'
  run_mutation 'defect (b): no cross-tick plugin-restart cooldown' \
    07-sig-b-cooldown '.data.PLUGIN_RESTART_COOLDOWN_SECONDS = "0"'
  run_mutation 'defect (c): severed Running consumers left alone' \
    11-sweep-external-restart '.data.SEVER_SWEEP = "false"'
  run_mutation 'the Terminating re-delete loop returns' \
    02-terminating-quiet '.data.TERMINATING_QUIET_SECONDS = "0"'
  run_mutation 'collateral recycles no longer bounded' \
    13-collateral-cap '.data.COLLATERAL_MAX_PODS = "50"'
  if [ "$MUT_FAILURES" -ne 0 ]; then
    printf '\n%d mutation(s) went UNDETECTED\n' "$MUT_FAILURES" >&2
    exit 1
  fi
  printf '\nall mutations detected\n'
fi
