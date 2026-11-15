#!/usr/bin/env sh
# Boots a second emulator for integration_test/two_phones.sh (#113 criterion 9) beside the one CI's
# emulator runner started, from the same system image, and waits for it to finish booting.
#
#   sh integration_test/second_emulator.sh [port] [system-image]      (ADB=/path/to/adb)
#
# One AVD cannot run twice unless every instance is read-only, and the runner's own is not, so this
# makes an AVD of its own. Locally, boot a second AVD yourself and pass both ids to two_phones.sh.
set -u
PORT="${1:-5556}"
IMAGE="${2:-system-images;android-34;google_apis;x86_64}"
ADB="${ADB:-adb}"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?set ANDROID_HOME}}"
DEVICE="emulator-$PORT"

avdmanager=$(ls "$SDK"/cmdline-tools/*/bin/avdmanager 2>/dev/null | head -n 1)
[ -n "$avdmanager" ] || { echo "FAIL: no avdmanager under $SDK/cmdline-tools"; exit 1; }
echo no | "$avdmanager" create avd --force -n second -k "$IMAGE" -d pixel_5 >/dev/null ||
  { echo "FAIL: could not create the second AVD from $IMAGE"; exit 1; }
"$SDK/emulator/emulator" -avd second -port "$PORT" -no-window -no-audio -no-boot-anim -no-snapshot \
  -gpu swiftshader_indirect >/tmp/second_emulator.log 2>&1 &

waited=0
until [ "$("$ADB" -s "$DEVICE" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
  [ "$waited" -ge 600 ] && { echo "FAIL: $DEVICE did not boot within 600 s"; tail -n 40 /tmp/second_emulator.log; exit 1; }
  sleep 5
  waited=$((waited + 5))
done
"$ADB" -s "$DEVICE" shell settings put global window_animation_scale 0
"$ADB" -s "$DEVICE" shell settings put global transition_animation_scale 0
"$ADB" -s "$DEVICE" shell settings put global animator_duration_scale 0
echo "second emulator: $DEVICE booted in about $waited s"
