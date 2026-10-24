#!/usr/bin/env sh
# #32: the core host, a foreground service that outlives the UI (ADR 003).
#
#   sh integration_test/core_host.sh [device-id]      (ADB=/path/to/adb to override)
#
# Instrumented tests, not integration_test/ files: they destroy the activity, send the service an
# intent, read the log's own file and tap the notification shade, none of which a test inside
# Flutter can do. It builds the debug app and its test APK (android/app/src/androidTest), installs
# both, and runs two classes, each in an `am instrument` of its own, because a runtime permission
# can be revoked only from outside the app: revoking one kills the app's process.
#   CoreHostRefusedTest - location revoked: the core runs bound to a visible activity, out of the
#                         foreground, and goes with it; with no activity, a start Android refuses
#                         stops the host, answers no_core and leaves the process up.
#   CoreHostTest        - location and notifications granted: criteria 1 and 4, and an append
#                         that starts the host cold, which waits for the engine to be ready.
#
# am instrument exits 0 on a failed test, so each verdict is read from its output, matched on a
# whole line. The failure line below never quotes the success line (cairn
# instrumented-tests-in-a-flutter-app, section 4).
set -u
DEVICE="${1:-emulator-5554}"
ADB="${ADB:-adb}"
APP=com.procompanion.app
cd "$(dirname "$0")/.." || exit 1

# The first build generates the Gradle wrapper and local.properties.
[ -f android/gradlew ] || flutter build apk --debug >/dev/null || exit 1
# --no-watch-fs: a watched build here can report success having compiled nothing
# (cairn windows-shell-hazards, hazard 4).
(cd android && ./gradlew -q --no-watch-fs app:assembleDebug app:assembleDebugAndroidTest) || exit 1
"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/debug/app-debug.apk >/dev/null || exit 1
"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk >/dev/null || exit 1

# run <class> <expected verdict line>
run() {
  "$ADB" -s "$DEVICE" shell am force-stop "$APP"
  out=$("$ADB" -s "$DEVICE" shell am instrument -w -e class "$APP.$1" \
    "$APP.test/androidx.test.runner.AndroidJUnitRunner" | tr -d '\r')
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -qxF "$2"; then
    echo "core-host: $1 passed"
  else
    echo "FAIL: $1 did not pass every one of its tests"
    exit 1
  fi
}

# Location refused, and the dialog an earlier run left cleared (grant_location.sh's second half).
for p in android.permission.ACCESS_FINE_LOCATION android.permission.ACCESS_COARSE_LOCATION; do
  "$ADB" -s "$DEVICE" shell pm revoke "$APP" "$p" || { echo "FAIL: could not revoke $p"; exit 1; }
done
"$ADB" -s "$DEVICE" shell am force-stop com.google.android.permissioncontroller
"$ADB" -s "$DEVICE" shell am force-stop com.android.permissioncontroller
echo "core-host: location revoked"
run CoreHostRefusedTest "OK (2 tests)"

# Granted again. This also clears the location dialog the refused run left on the app's task.
sh integration_test/grant_location.sh "$ADB" "$DEVICE" || exit 1
run CoreHostTest "OK (3 tests)"
