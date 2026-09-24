#!/usr/bin/env sh
# #24 criterion 4: an append that has returned survives a force-kill, and reads
# back after a relaunch in airplane mode.
#
#   sh integration_test/force_kill.sh [device-id]      (ADB=/path/to/adb to override)
#
# Two runs of integration_test/force_kill_phase.dart against the app's real log:
#   write - appends 5 probe events, waits for each to return, then SIGKILLs its
#           own process: no close, no flush. That run reports "did not complete";
#           it is judged by the acknowledgement line it prints before dying.
#   read  - a fresh process, with the device in airplane mode, must find all 5.
# `flutter test` reinstalls with the app's data kept (measured on API 36), which
# is what lets the second run see what the first one wrote.
#
# What this cannot see: a process kill leaves the OS page cache intact, so it
# proves nothing acknowledged is held in the process - not power-loss
# durability (cairn: flutter-3-44-caps-sqlite3-and-runs-profile-on-emulators).
set -u
DEVICE="${1:-emulator-5554}"
ADB="${ADB:-adb}"
APP=com.procompanion.app
RUN_ID="fk-$(date +%s)-$$"
cd "$(dirname "$0")/.." || exit 1

restore() { "$ADB" -s "$DEVICE" shell cmd connectivity airplane-mode disable >/dev/null 2>&1; }
trap restore EXIT

echo "force-kill: write phase, run $RUN_ID"
out=$(flutter test integration_test/force_kill_phase.dart -d "$DEVICE" \
  --dart-define=PHASE=write --dart-define=RUN_ID="$RUN_ID" 2>&1)
if ! printf '%s\n' "$out" | grep -q "FORCE_KILL_ACKED run=$RUN_ID n=5"; then
  printf '%s\n' "$out"
  echo "FAIL: the write phase never acknowledged its appends"
  exit 1
fi

"$ADB" -s "$DEVICE" shell am force-stop "$APP"
if "$ADB" -s "$DEVICE" shell pidof "$APP" >/dev/null 2>&1; then
  echo "FAIL: the app is still running after the kill"
  exit 1
fi

"$ADB" -s "$DEVICE" shell cmd connectivity airplane-mode enable
if [ "$("$ADB" -s "$DEVICE" shell settings get global airplane_mode_on | tr -d '\r')" != 1 ]; then
  echo "FAIL: airplane mode did not turn on"
  exit 1
fi

echo "force-kill: read phase, airplane mode on"
flutter test integration_test/force_kill_phase.dart -d "$DEVICE" \
  --dart-define=PHASE=read --dart-define=RUN_ID="$RUN_ID"
