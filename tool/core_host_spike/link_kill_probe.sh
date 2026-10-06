#!/usr/bin/env sh
# #15, beyond the criteria: what each mechanism does while the companion's core host is
# down. Measured 2026-10-06 (API 36): with no traffic the sticky core host is back in
# about 1.5 s, but an event that reaches the process first makes that restart a background
# start of a location foreground service, which is refused, and the host crash-loops.
# For each case the core is started from the activity, the activity is closed, and
# the companion's process is killed (kill -9 as root, standing in for the low-memory
# killer). Then the harness at once emits COUNT events INTERVAL ms apart over one
# mechanism, or nothing at all for the `none` control. Afterwards the probe reports
# whether the core host came back, what ActivityManager said about it, and what the
# harness was told against what reached the core.
#   ADB=path/to/adb sh tool/core_host_spike/link_kill_probe.sh [count] [interval_ms]
# Needs an image that allows `adb root` (google_apis, not google_apis_playstore).
set -eu
cd "$(dirname "$0")"
COUNT="${1:-10}"
INTERVAL="${2:-500}"
ADB="${ADB:-adb}"
PKG=com.procompanion.core_host_spike
HARNESS=com.procompanion.link_harness
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
LOG="build/link_kill_probe_$STAMP.log"

"$ADB" root >/dev/null
"$ADB" wait-for-device
"$ADB" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS
"$ADB" shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION
"$ADB" logcat -c
"$ADB" logcat -v time -s LINK:V flutter:V ActivityManager:I AndroidRuntime:E > "$LOG" &
LOGCAT=$!
trap 'kill $LOGCAT 2>/dev/null || true' EXIT

wait_count() { # pattern, count, timeout seconds
  t=0
  until [ "$(grep -c "$1" "$LOG" || true)" -ge "$2" ]; do
    t=$((t + 1)); [ "$t" -le "$3" ] || { echo "timed out waiting for: $1" >&2; return 1; }
    sleep 1
  done
}

for m in none broadcast bound provider; do
  # The core from the activity, as a PRO starts it; launching also clears a process the
  # system marked bad after repeated crashes.
  starts=$(grep -c 'CORE .* START' "$LOG" || true)
  "$ADB" shell am force-stop "$PKG"   # a core the last case left running would not START again
  "$ADB" shell input keyevent KEYCODE_WAKEUP
  "$ADB" shell am start -n "$PKG/.MainActivity" --ez autostart true >/dev/null
  wait_count 'CORE .* START' $((starts + 1)) 60
  sleep 2
  "$ADB" shell input keyevent KEYCODE_BACK
  sleep 3
  from=$(wc -l < "$LOG")
  pid=$("$ADB" shell pidof "$PKG" | tr -d '\r')
  run="killed-$m-$STAMP"
  "$ADB" shell kill -9 "$pid"
  if [ "$m" != none ]; then
    "$ADB" shell am start-foreground-service -n "$HARNESS/.EmitService" \
      --es mech "$m" --ei count "$COUNT" --ei interval_ms "$INTERVAL" --es run "$run" >/dev/null
    # A call can block while the companion crash-loops (measured: a provider call never
    # returned). Record that, and stop the harness, rather than wait on it.
    if ! wait_count "DONE run=$run " 1 120 2>/dev/null; then
      echo "== $m: the harness did not finish its run in 120 s; a call into the companion was still blocked"
      "$ADB" shell am force-stop "$HARNESS"
    fi
  fi
  sleep 15   # ADR 003 measured the sticky restart at about 2 s
  echo "== $m: killed pid $pid; 15 s later pid '$("$ADB" shell pidof "$PKG" | tr -d '\r')', \
core service records $("$ADB" shell dumpsys activity services "$PKG" | grep -c 'ServiceRecord.*CoreService' || true)"
  tail -n +"$((from + 1))" "$LOG" |
    grep -E 'Scheduling restart|not allowed|Disallowed|crashed too many|Start proc|has died|FATAL|Exception|START pid' |
    sed 's/^[0-9-]* //; s/^/  /' | cut -c1-230
  grep "EMIT run=$run " "$LOG" | sed 's/.*EMIT /  EMIT /; s/ id=[^ ]*//; s/ kind=[^ ]*//' || true
done
kill $LOGCAT 2>/dev/null || true

echo "== report ($LOG)"
dart link_report.dart "$LOG"
