#!/usr/bin/env sh
# #33: #15's kill probe, on the real host (ADR 003's amendment, ADR 004). This is the one link path
# with no instrumentation holding the process up.
#
#   sh integration_test/link_kill.sh [device-id]         (ADB=/path/to/adb to override)
#
# Emulators only (race_timer_link.sh refuses anything else, and it says why). It needs `adb root`
# for a kill -9 of another UID, so it takes an image that allows it, and unroots on the way out.
#
# The core is started from the activity, the activity is closed, and the process is killed as the
# low-memory killer would. The stand-in then at once emits $COUNT events $INTERVAL ms apart over the
# bound service. In the spike, an event reaching the process first turned the sticky restart into a
# refused foreground start and crash-looped the process, until the system put the next restart 30
# minutes out (tool/core_host_spike/results/2026-10-06-link-kill-probe.txt). The app is reopened
# while the run goes on, and the stand-in retries everything it was not told accepted, as ADR 004
# asks of race-timer, until it is.
#
# Owner's decision on #33: judged on what must always hold, because which branch runs is a race. The
# restart is scheduled 1 s after the death, on a 2-vCPU runner, so this PRINTS the branch and never
# fails for it:
#   no_core answered          - the bind reached the process first, the host stayed down.
#   sticky restart won        - the host came back first, and the events went to it.
# It FAILS only on a crash of the app, a dead process, or an event lost once the app is reopened: an
# event never told accepted, or an accepted id not in the log exactly once (LinkKillReadback).
set -u
DEVICE="${1:-emulator-5554}"
ADB="${ADB:-adb}"
APP=com.procompanion.app
STAND_IN=io.github.sailordave17.racetimer
COUNT=20
INTERVAL=1000
RETRY_MS=90000
RUN="kill-$(date +%s)-$$"
LOG="build/link_kill_$RUN.log"
LOGCAT=
cd "$(dirname "$0")/.." || exit 1

sh integration_test/race_timer_link.sh "$DEVICE" build || exit 1

shell() { "$ADB" -s "$DEVICE" shell "$@" | tr -d '\r'; }

# within <seconds> <command...>: true as soon as the command is, false at the bound.
within() {
  left=$1
  shift
  until "$@"; do
    left=$((left - 1))
    [ "$left" -gt 0 ] || return 1
    sleep 1
  done
}
is_root() { [ "$(shell id -u)" = 0 ]; }
is_not_root() { [ "$(shell id -u)" != 0 ]; }
in_foreground() { shell dumpsys activity services "$APP" | grep -q 'isForeground=true'; }
no_activities() { [ "$(shell dumpsys activity activities | grep -c "$APP/.MainActivity")" = 0 ]; }
run_done() { grep -q "DONE run=$RUN " "$LOG"; }
open_the_app() {
  sh integration_test/grant_location.sh "$ADB" "$DEVICE" || exit 1
  shell input keyevent KEYCODE_WAKEUP
  shell wm dismiss-keyguard
  shell am start -n "$APP/.MainActivity" >/dev/null
}

restore() {
  [ -n "$LOGCAT" ] && kill "$LOGCAT" 2>/dev/null
  "$ADB" -s "$DEVICE" uninstall "$STAND_IN" >/dev/null 2>&1
  "$ADB" -s "$DEVICE" unroot >/dev/null 2>&1
  "$ADB" -s "$DEVICE" wait-for-device
  within 30 is_not_root
}
trap restore EXIT
# dash skips the EXIT trap when a signal ends it; exiting from a signal trap runs it.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The process the case is about: a crash here is the failure the host's refusal handling closed.
no_crash() {
  crashes=$(tr -d '\r' < "$LOG" | grep -E \
    "Process: $APP, PID|$APP has crashed too many|Scheduling restart of .*$APP.* in 1800000ms")
  [ -z "$crashes" ] && return 0
  printf '%s\n' "$crashes"
  echo "FAIL: the app crashed under the link ($LOG)"
  exit 1
}

"$ADB" -s "$DEVICE" root >/dev/null
"$ADB" -s "$DEVICE" wait-for-device
within 30 is_root || { echo "FAIL: this image does not allow adb root, which the kill needs"; exit 1; }

"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/debug/app-debug.apk >/dev/null || exit 1
"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk >/dev/null || exit 1
"$ADB" -s "$DEVICE" uninstall "$STAND_IN" >/dev/null 2>&1
"$ADB" -s "$DEVICE" install -t build/link_standin_trusted.apk >/dev/null ||
  { echo "FAIL: could not install the stand-in"; exit 1; }

shell am force-stop "$APP"
"$ADB" -s "$DEVICE" logcat -c
"$ADB" -s "$DEVICE" logcat -v time -s LINK:V CoreService:W ActivityManager:I AndroidRuntime:E > "$LOG" &
LOGCAT=$!

open_the_app
within 60 in_foreground || { echo "FAIL: the core host never went into the foreground, so the case did not run"; exit 1; }
sleep 2
shell input keyevent KEYCODE_BACK
within 15 no_activities || { echo "FAIL: BACK left an activity up, so the case did not run"; exit 1; }

pid=$(shell pidof "$APP")
[ -n "$pid" ] || { echo "FAIL: no process to kill, so the case did not run"; exit 1; }
shell kill -9 "$pid"
shell am start-foreground-service -n "$STAND_IN/com.procompanion.link_harness.EmitService" \
  --es companion "$APP" --es mech bound --ei count "$COUNT" --ei interval_ms "$INTERVAL" \
  --ei retry_ms "$RETRY_MS" --es run "$RUN" >/dev/null

sleep 15   # the spike's bound: ADR 003 measured the sticky restart at about 2 s
no_crash
alive=$(shell pidof "$APP")
[ -n "$alive" ] || { echo "FAIL: the process is dead 15 s after the kill, with race-timer bound to it"; exit 1; }

early=$(tr -d '\r' < "$LOG" | grep "EMIT run=$RUN ")
first=$(printf '%s\n' "$early" | grep ' n=1 ' | sed -n 's/.* status=\([^ ]*\).*/\1/p')
case "$first" in
  no_core) branch="no_core answered" ;;
  accepted) branch="the sticky restart won the race" ;;
  *) branch="neither: event 1 was told '$first'" ;;
esac
echo "link-kill: killed pid $pid, 15 s later pid $alive"
echo "link-kill: branch: $branch ($(printf '%s\n' "$early" | grep -c 'status=no_core') no_core, \
$(printf '%s\n' "$early" | grep -c 'status=accepted') accepted of $(printf '%s\n' "$early" | grep -c .) so far)"

open_the_app
within 40 in_foreground || { echo "FAIL: reopening the app brought no core host back, so race-timer's retry has nowhere to land"; exit 1; }
within 120 run_done || { "$ADB" -s "$DEVICE" shell am force-stop "$STAND_IN"; echo "a call into the app was still blocked at the bound"; }
sleep 2
no_crash
[ -n "$(shell pidof "$APP")" ] || { echo "FAIL: the process died after the app was reopened"; exit 1; }

emits=$(tr -d '\r' < "$LOG" | grep "EMIT run=$RUN ")
told=$(printf '%s\n' "$emits" | sed -n 's/.* n=\([0-9]*\) .*status=accepted.*/\1/p' | sort -un | grep -c .)
echo "link-kill: $told of $COUNT events told accepted, $(printf '%s\n' "$emits" | grep -c ' resend=true') retries"
if [ "$told" != "$COUNT" ]; then
  printf '%s\n' "$emits" | grep -v 'status=accepted' | tail -n 5
  echo "FAIL: an event was never told accepted with the app reopened, so it is lost ($LOG)"
  exit 1
fi
ids=$(printf '%s\n' "$emits" | sed -n 's/.* id=\([^ ]*\) .*status=accepted.*/\1/p' | sort -u | tr '\n' ',' | sed 's/,$//')
out=$("$ADB" -s "$DEVICE" shell am instrument -w -e class "$APP.LinkKillReadback" -e ids "$ids" \
  "$APP.test/androidx.test.runner.AndroidJUnitRunner" | tr -d '\r')
if printf '%s\n' "$out" | grep -qxF "OK (1 test)"; then
  echo "link-kill: passed"
else
  printf '%s\n' "$out"
  echo "FAIL: an id told accepted is not in the log exactly once"
  exit 1
fi
