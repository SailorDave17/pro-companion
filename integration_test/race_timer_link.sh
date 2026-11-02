#!/usr/bin/env sh
# #33: race-timer's link against the real app (ADR 004), criteria 1, 2, 6, 7 and 8's buzz on a
# device. Criterion 8's tone is read once, in tool/core_host_spike/results/2026-11-02-link-tone.txt.
#
#   sh integration_test/race_timer_link.sh [device-id]         (ADB=/path/to/adb to override)
#   sh integration_test/race_timer_link.sh <device-id> build   keys, build and signing only, for
#                                                              integration_test/link_kill.sh
#
# Emulators only. The stand-in (tool/core_host_spike/android/harness) carries race-timer's real
# package, which is the only one the app pins, and each phase uninstalls it: on a personal phone
# that would delete race-timer and its data.
#
# Two throwaway keys are made under build/link_keys (build/ is ignored, and
# test/no_secrets_in_tree_test.dart refuses a tracked keystore, so nothing can be committed). The
# debug app is built pinning "trusted", the stand-in is built once and signed twice, so its two
# copies differ only in signer. Then RaceTimerLinkTest runs once per copy:
#   trusted  - a day in forced Doze with the activity destroyed: every event stored once, verbatim.
#   imposter - the same path: told refused, nothing stored, certificate_not_pinned on record.
#
# am instrument exits 0 on a failed test, so each verdict is read from its output, matched on a
# whole line. The failure line below never quotes the success line (cairn
# instrumented-tests-in-a-flutter-app, section 4).
set -u
DEVICE="${1:-emulator-5554}"
MODE="${2:-run}"
ADB="${ADB:-adb}"
APP=com.procompanion.app
STAND_IN=io.github.sailordave17.racetimer
KEYS=build/link_keys
PASS=linkharness   # throwaway keys for a debug-only stand-in; they sign nothing else
TESTS=6
cd "$(dirname "$0")/.." || exit 1

case "$DEVICE" in
  emulator-*) ;;
  *)
    echo "STOP: $DEVICE is not an emulator, and this script uninstalls $STAND_IN, which on a phone is the real race-timer"
    exit 2
    ;;
esac

SDK=$(printf '%s' "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}" | tr '\\' '/')
if [ -z "$SDK" ] || [ ! -d "$SDK/build-tools" ]; then
  echo "FAIL: no Android SDK build-tools found; set ANDROID_HOME"
  exit 1
fi
BUILD_TOOLS="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -n 1)"
apksigner() { java -jar "$BUILD_TOOLS/lib/apksigner.jar" "$@"; }

mkdir -p "$KEYS" || exit 1
for k in trusted imposter; do
  [ -f "$KEYS/$k.jks" ] || keytool -genkeypair -noprompt -keystore "$KEYS/$k.jks" -storepass "$PASS" \
    -keypass "$PASS" -alias "$k" -dname "CN=race-timer stand-in $k" -keyalg RSA -keysize 2048 \
    -validity 365 >/dev/null 2>&1
done
TRUSTED=$(keytool -list -v -keystore "$KEYS/trusted.jks" -storepass "$PASS" -alias trusted \
  | tr -d '\r' | sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | tr -d ':' | tr 'A-F' 'a-f')
if ! printf '%s' "$TRUSTED" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "FAIL: could not read the trusted key's SHA-256 digest (got '$TRUSTED')"
  exit 1
fi

# The first build generates the Gradle wrapper and local.properties.
[ -f android/gradlew ] || flutter build apk --debug >/dev/null || exit 1
# --no-watch-fs: a watched build here can report success having compiled nothing
# (cairn windows-shell-hazards, hazard 4).
(cd android && ./gradlew -q --no-watch-fs \
  app:assembleDebug app:assembleDebugAndroidTest harness:assembleDebug \
  -PlinkDebugCerts="$TRUSTED" -PlinkHarness=1 \
  -PlinkHarnessPackage="$STAND_IN" -PlinkHarnessCompanion="$APP") || exit 1
for k in trusted imposter; do
  apksigner sign --ks "$KEYS/$k.jks" --ks-pass "pass:$PASS" --ks-key-alias "$k" \
    --out "build/link_standin_$k.apk" build/harness/outputs/apk/debug/harness-debug.apk ||
    { echo "FAIL: could not sign the stand-in with the $k key"; exit 1; }
done
[ "$MODE" = build ] && exit 0

# Whatever happened: an instrumentation crash skips the test's own undo, and volume_key.sh runs
# next on this emulator, which must not be asleep, unplugged and idle, or holding the stand-in.
restore() {
  "$ADB" -s "$DEVICE" shell dumpsys deviceidle unforce >/dev/null 2>&1
  "$ADB" -s "$DEVICE" shell dumpsys battery reset >/dev/null 2>&1
  "$ADB" -s "$DEVICE" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
  "$ADB" -s "$DEVICE" shell wm dismiss-keyguard >/dev/null 2>&1
  "$ADB" -s "$DEVICE" uninstall "$STAND_IN" >/dev/null 2>&1
}
trap restore EXIT
# dash skips the EXIT trap when a signal ends it; exiting from a signal trap runs it.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/debug/app-debug.apk >/dev/null || exit 1
"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk >/dev/null || exit 1

# phase <trusted|imposter>
phase() {
  # A copy signed by the other key cannot replace this one in place.
  "$ADB" -s "$DEVICE" uninstall "$STAND_IN" >/dev/null 2>&1
  "$ADB" -s "$DEVICE" install -t "build/link_standin_$1.apk" >/dev/null ||
    { echo "FAIL: could not install the $1 stand-in"; exit 1; }
  sh integration_test/grant_location.sh "$ADB" "$DEVICE" || exit 1
  "$ADB" -s "$DEVICE" shell am force-stop "$APP"
  "$ADB" -s "$DEVICE" logcat -c
  out=$("$ADB" -s "$DEVICE" shell am instrument -w -e class "$APP.RaceTimerLinkTest" -e expect "$1" \
    "$APP.test/androidx.test.runner.AndroidJUnitRunner" | tr -d '\r')
  printf '%s\n' "$out"
  if printf '%s\n' "$out" | grep -qxF "OK ($TESTS tests)"; then
    echo "race-timer-link: $1 stand-in passed"
  else
    echo "FAIL: RaceTimerLinkTest with the $1 stand-in did not pass every one of its tests"
    exit 1
  fi
}

phase trusted
phase imposter
