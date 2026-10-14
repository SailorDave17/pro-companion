#!/usr/bin/env sh
# #31: the app asks for location at launch. The device scripts call this before each launch, so that
# no permission dialog is in the way of what they test.
#
#   sh integration_test/grant_location.sh <adb> <device-id>
#
# Grants location when the app is installed, and fails if a grant to an installed app is refused.
# Before the first install there is nothing to grant: that launch shows the dialog, which the
# flutter_test flows do not mind.
#
# Then it clears any dialog an earlier run left behind. A dialog whose app was killed under it (a
# force-kill phase, an instrumentation ending, a reinstall) stays as the only activity on the app's
# task, and every later launch is delivered to that task: MainActivity never starts, and `flutter
# test` waits for it until the job times out. Measured on #31: force_kill.sh's write phase killed
# the app under the dialog, and its read phase hung for the whole 480 s bound.
set -u
ADB="$1"
DEVICE="$2"
APP=com.procompanion.app

if "$ADB" -s "$DEVICE" shell pm path "$APP" 2>/dev/null | grep -q '^package:'; then
  for p in android.permission.ACCESS_FINE_LOCATION android.permission.ACCESS_COARSE_LOCATION; do
    "$ADB" -s "$DEVICE" shell pm grant "$APP" "$p" || { echo "FAIL: could not grant $p"; exit 1; }
  done
  echo "location: granted"
else
  echo "location: app not installed yet, nothing to grant"
fi
# Both permission controllers: Play images ship the Google one (cairn
# flutter-headless-engine-in-a-foreground-service, section 3). Force-stopping one that is
# not installed is a no-op.
"$ADB" -s "$DEVICE" shell am force-stop com.google.android.permissioncontroller
"$ADB" -s "$DEVICE" shell am force-stop com.android.permissioncontroller
