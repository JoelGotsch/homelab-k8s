#!/usr/bin/env bash
# check-renovate-window.sh — the Renovate CronJob fires INSIDE the schedule
# window it is meant to open, and every window override says the same thing.
#
# WHY THIS EXISTS (TODO hl-0237, 2026-09-09). The runner was `0 5 * * 6` with
# no `spec.timeZone` (05:00 UTC = 07:00 Berlin in summer) while the central
# preset said `timezone: Europe/Berlin` + `schedule: ["before 06:00 on
# saturday"]`. Every weekly run since activation (2026-07-16) started after
# the window had closed, found every update, and opened nothing — "outside
# schedule" is logged at info, the run exits 0, and the dependency dashboard
# still updates, so it looked like a working bot with a quiet backlog. ~70
# updates were parked when it was noticed. The two values live in two repos
# and nothing compared them.
#
# WHAT IT CHECKS
#
#   1. cronjob.yaml has `spec.timeZone`, equal to the preset's `timezone`.
#   2. The cron day-of-week is the preset window's day.
#   3. The cron fire time is strictly before the window's `before HH:MM`.
#      A run takes ~13 min across 32 repos and the schedule is re-checked
#      per repo, so the margin is reported too; < 60 min is a warning.
#   4. Every `before …` schedule string in the preset and in this repo's
#      renovate.json5 is identical to the preset's top-level window — an
#      override that restates the window with a different time re-creates
#      the original fault for the rules it covers.
#
# Cross-repo: the preset lives in ../homelab-infra (side-by-side clone
# convention, CLAUDE.md). Absent sibling → SKIP with a message, like the
# other cross-repo hooks here; it cannot be a FAIL on a machine that has
# only this repo, and it cannot be silent either.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
INFRA="${HOMELAB_INFRA_DIR:-$HERE/../homelab-infra}"
CRON="$HERE/platform/renovate/cronjob.yaml"
PRESET="$INFRA/renovate-presets/default.json5"
REPO_CFG="$HERE/renovate.json5"

for tool in yq awk grep sed; do
  command -v "$tool" >/dev/null 2>&1 || { echo "FATAL: required tool is missing: $tool" >&2; exit 1; }
done
[ -f "$CRON" ] || { echo "FATAL: $CRON not found" >&2; exit 1; }
[ -f "$PRESET" ] || { echo "SKIP: $PRESET not found — the homelab-infra sibling checkout is required for this check"; exit 0; }

fail=0
ok()   { printf 'OK:   %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; fail=1; }

# --- preset: top-level timezone + window (2-space indent = top level; the
# vulnerabilityAlerts block's "at any time" sits deeper and is not a window)
preset_tz=$(awk -F'"' '/^  timezone: "/{print $2; exit}' "$PRESET")
preset_window=$(awk -F'"' '/^  schedule: \["before /{print $2; exit}' "$PRESET")
[ -n "$preset_tz" ] || bad "preset has no top-level timezone: $PRESET"
[ -n "$preset_window" ] || bad "preset has no top-level 'before … on <day>' schedule: $PRESET"
[ "$fail" = 0 ] || exit 1

# "before HH:MM on <day>"
win_hhmm=$(sed -nE 's/^before ([0-9]{1,2}:[0-9]{2}) on ([a-z]+)$/\1/p' <<<"$preset_window")
win_day=$(sed -nE 's/^before ([0-9]{1,2}:[0-9]{2}) on ([a-z]+)$/\2/p' <<<"$preset_window")
[ -n "$win_hhmm" ] && [ -n "$win_day" ] || { bad "cannot parse preset window '$preset_window' (expected 'before HH:MM on <day>')"; exit 1; }
win_min=$(( 10#${win_hhmm%%:*} * 60 + 10#${win_hhmm##*:} ))
case "$win_day" in
  sunday) win_dow=0 ;; monday) win_dow=1 ;; tuesday) win_dow=2 ;; wednesday) win_dow=3 ;;
  thursday) win_dow=4 ;; friday) win_dow=5 ;; saturday) win_dow=6 ;;
  *) bad "unknown day in preset window: $win_day"; exit 1 ;;
esac

# --- cronjob
cron_sched=$(yq -r '.spec.schedule // ""' "$CRON")
cron_tz=$(yq -r '.spec.timeZone // ""' "$CRON")
read -r c_min c_hour _ _ c_dow <<<"$cron_sched"   # day-of-month and month are not window-relevant
[[ "$c_min" =~ ^[0-9]+$ && "$c_hour" =~ ^[0-9]+$ ]] || { bad "cron schedule '$cron_sched' must have a numeric minute and hour (a step or '*' cannot be checked against a window)"; exit 1; }

# 1. time zone
if [ -z "$cron_tz" ]; then
  bad "cronjob.yaml has no spec.timeZone — the schedule is evaluated in UTC, the preset window in $preset_tz"
elif [ "$cron_tz" != "$preset_tz" ]; then
  bad "cronjob.yaml spec.timeZone=$cron_tz but the preset's timezone is $preset_tz"
else
  ok "spec.timeZone $cron_tz matches the preset"
fi

# 2. day
case "$c_dow" in
  "$win_dow"|"$win_day"|"${win_day:0:3}") ok "cron day-of-week '$c_dow' is the window's $win_day" ;;
  *) bad "cron day-of-week '$c_dow' is not the window's $win_day (=$win_dow)" ;;
esac

# 3. fire time vs window close
fire_min=$(( 10#$c_hour * 60 + 10#$c_min ))
margin=$(( win_min - fire_min ))
if [ "$margin" -le 0 ]; then
  bad "cron fires at $(printf '%02d:%02d' "$c_hour" "$c_min") $cron_tz, at or after the window closes ($preset_window) — no run can open a branch"
elif [ "$margin" -lt 60 ]; then
  warn "cron fires $margin min before the window closes ($preset_window); a run takes ~13 min across the org and re-checks per repo, so late repos may be dropped"
else
  ok "cron fires at $(printf '%02d:%02d' "$c_hour" "$c_min") $cron_tz, $margin min before the window closes ($preset_window)"
fi

# 4. every restated window equals the preset's
while IFS=: read -r file line text; do
  if [ "$text" != "$preset_window" ]; then
    bad "$file:$line restates the window as '$text' but the preset says '$preset_window'"
  fi
done < <(grep -nHoE '"before [^"]+"' "$PRESET" "$REPO_CFG" 2>/dev/null | sed -E 's/"([^"]+)"$/\1/')
n=$(grep -hoE '"before [^"]+"' "$PRESET" "$REPO_CFG" 2>/dev/null | wc -l | tr -d ' ')
[ "$fail" = 0 ] && ok "all $n 'before …' schedule strings in the preset and $(basename "$REPO_CFG") equal '$preset_window'"

exit "$fail"
