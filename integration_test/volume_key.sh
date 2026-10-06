#!/usr/bin/env sh
# #19: the volume-down key logs a finish on the finish screen and nowhere else.
#
#   sh integration_test/volume_key.sh [device-id]      (ADB=/path/to/adb to override)
#
# An instrumented test, not an integration_test/ file: its keys are injected
# through the input system, which reaches MainActivity's handler the way a
# hardware press does, and only an instrumentation may inject them. It builds
# the debug app and its test APK, installs both, clears the app's log so the
# run starts from an empty day, and runs VolumeKeyFinishTest
# (android/app/src/androidTest). Criterion 4's other app is a media session in
# the test APK's own process; the test starts and stops it.
#
# am instrument exits 0 on a failed test, so the verdict is read from its output.
# The failure line below never quotes the success line: a reader matching that
# text as a substring would read the failure as a pass (it did, on #19's first
# mutation driver).
set -u
DEVICE="${1:-emulator-5554}"
ADB="${ADB:-adb}"
APP=com.procompanion.app
TESTS=5
cd "$(dirname "$0")/.." || exit 1

# The first build generates the Gradle wrapper and local.properties.
[ -f android/gradlew ] || flutter build apk --debug >/dev/null || exit 1
# --no-watch-fs: a watched build here can report success having compiled nothing
# (cairn windows-shell-hazards, hazard 4).
(cd android && ./gradlew -q --no-watch-fs app:assembleDebug app:assembleDebugAndroidTest) || exit 1

"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/debug/app-debug.apk >/dev/null || exit 1
"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk >/dev/null || exit 1
"$ADB" -s "$DEVICE" shell pm clear "$APP" >/dev/null

out=$("$ADB" -s "$DEVICE" shell am instrument -w -e class "$APP.VolumeKeyFinishTest" \
  "$APP.test/androidx.test.runner.AndroidJUnitRunner" | tr -d '\r')
printf '%s\n' "$out"
case "$out" in
  *"OK ($TESTS tests)"*) echo "volume-key: passed" ;;
  *) echo "FAIL: VolumeKeyFinishTest did not pass all $TESTS of its tests"; exit 1 ;;
esac
