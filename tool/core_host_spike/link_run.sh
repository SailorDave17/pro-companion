#!/usr/bin/env sh
# #15 criteria 1 and 2: the harness emits COUNT link events over each mechanism, first
# with the companion backgrounded (HOME, screen on), then with its activity destroyed,
# the screen off and the device forced into Doze. On one running device or emulator,
# API 34+ (a broadcast's sender is unknown below that).
#   ADB=path/to/adb sh tool/core_host_spike/link_run.sh [count] [interval_ms]
# Defaults: 50 events, 5000 ms apart. The log is kept as build/link_run_<stamp>.log
# and the report printed by link_report.dart. SKIP_BUILD=1 reuses the last build.
set -eu
cd "$(dirname "$0")"
COUNT="${1:-50}"
INTERVAL="${2:-5000}"
ADB="${ADB:-adb}"
PKG=com.procompanion.core_host_spike
HARNESS=com.procompanion.link_harness
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG="build/link_run_$STAMP.log"
MECHS="broadcast bound provider"

sh link_build.sh profile trusted

state() {
  echo "  $1: screen $("$ADB" shell dumpsys power | sed -n 's/.*mWakefulness=//p' | tr -d '\r'), \
deep idle $("$ADB" shell dumpsys deviceidle get deep | tr -d '\r'), \
companion activities $("$ADB" shell dumpsys activity activities | grep -c "$PKG/.MainActivity" || true), \
core service $("$ADB" shell dumpsys activity services "$PKG" | grep -c 'CoreService' || true), \
resumed: $("$ADB" shell dumpsys activity activities | sed -n 's/.*topResumedActivity=//p' | head -1 | tr -d '\r')"
}

wait_for() { # pattern, timeout seconds
  t=0
  until grep -q "$1" "$LOG"; do
    t=$((t + 2)); [ "$t" -le "$2" ] || { echo "timed out waiting for: $1" >&2; return 1; }
    sleep 2
  done
}

"$ADB" shell am force-stop "$PKG"
"$ADB" shell am force-stop "$HARNESS"
"$ADB" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS
"$ADB" shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION
"$ADB" logcat -c
# Stream only the two tags, so a long run cannot rotate them out of the ring buffer.
"$ADB" logcat -v time -s LINK:V flutter:V > "$LOG" &
LOGCAT=$!
trap 'kill $LOGCAT 2>/dev/null || true' EXIT

"$ADB" shell am start -n "$PKG/.MainActivity" --ez autostart true >/dev/null
wait_for 'CORE .* START' 60

emit() { # phase, mechanism
  run="$1-$2-$STAMP"
  echo "$(date -u +%H:%M:%S) $run"
  "$ADB" shell am start-foreground-service -n "$HARNESS/.EmitService" \
    --es mech "$2" --ei count "$COUNT" --ei interval_ms "$INTERVAL" --es run "$run" >/dev/null
  wait_for "DONE run=$run " $((COUNT * INTERVAL / 1000 + 120))
  sleep 5   # the last event's core line
  state "after $run"
}

echo "== criterion 1: companion backgrounded"
"$ADB" shell input keyevent KEYCODE_HOME
sleep 3
state "before"
for m in $MECHS; do emit background "$m"; done

echo "== criterion 2: activity destroyed, screen off, forced Doze"
"$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null
sleep 3
"$ADB" shell input keyevent KEYCODE_BACK   # finishes the only activity: destroyed
sleep 3
"$ADB" shell dumpsys battery unplug
"$ADB" shell input keyevent KEYCODE_SLEEP
"$ADB" shell dumpsys deviceidle force-idle >/dev/null
state "before"
for m in $MECHS; do emit doze "$m"; done

"$ADB" shell dumpsys deviceidle unforce >/dev/null
"$ADB" shell dumpsys battery reset
"$ADB" shell input keyevent KEYCODE_WAKEUP
kill $LOGCAT 2>/dev/null || true

echo "== report ($LOG)"
dart link_report.dart "$LOG"
