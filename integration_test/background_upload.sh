#!/usr/bin/env sh
# #52 on a phone: events waiting in the core host go up by themselves when the network comes back,
# with the activity destroyed. BackgroundUploadTest (android/app/src/androidTest) is the test.
#
#   sh integration_test/background_upload.sh [device-id]      (ADB=/path/to/adb to override)
#
# An emulator only, and the local stack running (scripts/start_local_stack.sh). It:
#   - writes the build's defines from the stack's status, with the stack's address changed from
#     127.0.0.1 to 10.0.2.2, the emulator's own route to this machine. So the build reaches the
#     stack through the emulator's network, which airplane mode really cuts, and not through adb's
#     reverse forward, which airplane mode leaves up (sync_flow.sh);
#   - provisions a race day with the owner script, and clears the app, so the phone is fresh;
#   - builds the app and its test APK with Gradle, passing the defines as Flutter's tool would
#     (-Pdart-defines, each NAME=value in base64), and installs both;
#   - runs the test with the race day's overall PRO code, and reads its verdict;
#   - reads the shore as the table owner: the five waiting notes are there, once each.
# The key is passed to Gradle and never printed.
set -u
DEVICE="${1:-emulator-5554}"
ADB="${ADB:-adb}"
APP=com.procompanion.app
PORT=54421
CLASS=BackgroundUploadTest
cd "$(dirname "$0")/.." || exit 1

fail() {
  echo "FAIL: $*"
  exit 1
}

# Whatever happens, the emulator is left with its network for the next test.
trap '"$ADB" -s "$DEVICE" shell cmd connectivity airplane-mode disable >/dev/null 2>&1' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

case "$DEVICE" in
  emulator-*) ;;
  *) fail "$DEVICE is not an emulator: the build reaches the stack at 10.0.2.2, an emulator's route to this machine" ;;
esac

mkdir -p build
defines=build/background_upload.defines.json
dart run scripts/sync_defines.dart --out "$defines" >/dev/null || fail "no defines file: is the local stack running?"
value() { sed -n "s/^ *\"$1\": *\"\([^\"]*\)\".*/\1/p" "$defines"; }
url=$(value PRO_COMPANION_SUPABASE_URL)
key=$(value PRO_COMPANION_SUPABASE_PUBLISHABLE_KEY)
emulator_url=$(printf '%s' "$url" | sed 's#^http://127\.0\.0\.1:#http://10.0.2.2:#')
[ -n "$key" ] || fail "the defines file has no publishable key"
case "$emulator_url" in
  http://10.0.2.2:$PORT) ;;
  *) fail "the stack's URL '$url' is not 127.0.0.1:$PORT, so it cannot be moved to 10.0.2.2" ;;
esac
b64() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
dart_defines="$(b64 "PRO_COMPANION_SUPABASE_URL=$emulator_url"),$(b64 "PRO_COMPANION_SUPABASE_PUBLISHABLE_KEY=$key")"

stamp=$(date +%s)
prov=$(dart run scripts/owner.dart provision --club "Background upload club $stamp" \
  --event "Background upload $stamp" --date "$(date +%F)" --race-area Alpha) || fail "provision failed: $prov"
code=$(printf '%s\n' "$prov" | awk '$1 == "code" && $3 == "overall_pro" { print $2 }')
event_id=$(printf '%s\n' "$prov" | awk '$1 == "event" { print $2 }')
[ -n "$code" ] && [ -n "$event_id" ] || fail "provision printed no overall_pro code or event id"

# The first build generates the Gradle wrapper and local.properties.
[ -f android/gradlew ] || flutter build apk --debug >/dev/null || fail "the first build failed"
# --no-watch-fs: a watched build here can report success having compiled nothing
# (cairn windows-shell-hazards, hazard 4).
(cd android && ./gradlew -q --no-watch-fs app:assembleDebug app:assembleDebugAndroidTest \
  "-Pdart-defines=$dart_defines") || fail "the Gradle build failed"
"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/debug/app-debug.apk >/dev/null || fail "install failed"
"$ADB" -s "$DEVICE" install -r -t build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk >/dev/null ||
  fail "the test APK's install failed"

# A fresh phone: no device id, no session, no admission. pm clear drops the permissions, so they
# are granted again, and any dialog an earlier run left on the app's task is cleared.
"$ADB" -s "$DEVICE" shell am force-stop "$APP"
"$ADB" -s "$DEVICE" shell pm clear "$APP" >/dev/null 2>&1
sh integration_test/grant_location.sh "$ADB" "$DEVICE" || fail "could not grant"

echo "background-upload: race day $event_id"
"$ADB" -s "$DEVICE" logcat -c
# am instrument exits 0 on a failed test, so the verdict is read from its output, matched on a
# whole line (cairn instrumented-tests-in-a-flutter-app, section 4).
out=$("$ADB" -s "$DEVICE" shell am instrument -w -e class "$APP.$CLASS" -e code "$code" \
  -e host 10.0.2.2 -e port "$PORT" "$APP.test/androidx.test.runner.AndroidJUnitRunner" | tr -d '\r')
printf '%s\n' "$out"
"$ADB" -s "$DEVICE" logcat -d -s BackgroundUpload:I | grep 'after the failed try' | sed 's/^.*: /background-upload: /'
printf '%s\n' "$out" | grep -qxF "OK (1 test)" || fail "$CLASS did not pass"

# The shore's side: the five notes logged with the network down are there, once each (the
# server keys an event by its ULID, so a second copy cannot exist; this counts them by their text).
on_shore=$(docker exec supabase_db_pro_companion psql -U postgres -tAc \
  "select count(*) from public.event_log where event_id = '$event_id' and kind = 'note'
     and canonical::jsonb -> 'payload' ->> 'text' like 'background %'" | tr -d '\r ')
echo "background-upload: $on_shore waiting notes on shore for the race day"
[ "${on_shore:-0}" -eq 5 ] || fail "expected the 5 waiting notes on shore, read $on_shore"
echo "background-upload: passed"
