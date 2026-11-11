#!/usr/bin/env sh
# #113 criterion 9: two committee phones, two emulators, sync in each phone's own core host, the
# local stack between them and nothing fake.
#
#   sh integration_test/two_phones.sh <pro-device> <mark-boat-device>      (ADB=/path/to/adb)
#
# Needs the local stack running and both emulators booted. It provisions one race day, makes both
# phones fresh, points each one's 127.0.0.1:54421 at the stack, and runs
# integration_test/two_phones_flow.dart on both at once: the PRO with the race day's overall_pro
# code, the mark boat with its mark_boat Alpha code. Both runs must pass.
set -u
# No apostrophe inside these messages: under bash one pairs with the next line's (review of #113).
PRO="${1:?usage: two_phones.sh <pro-device> <mark-boat-device>}"
MARK="${2:?usage: two_phones.sh <pro-device> <mark-boat-device>}"
ADB="${ADB:-adb}"
APP=com.procompanion.app
PORT=54421
cd "$(dirname "$0")/.." || exit 1

fail() {
  echo "FAIL: $*"
  for f in "${pro_log:-}" "${mark_log:-}"; do [ -n "$f" ] && [ -f "$f" ] && { echo "--- $f"; cat "$f"; }; done
  exit 1
}

mkdir -p build
defines=build/two_phones.defines.json
dart run scripts/sync_defines.dart --out "$defines" || fail "no defines file: is the local stack running?"

stamp=$(date +%s)
prov=$(dart run scripts/owner.dart provision --club "Two phones club $stamp" --event "Two phones $stamp" \
  --date "$(date +%F)" --race-area Alpha) || fail "provision failed: $prov"
pro_code=$(printf '%s\n' "$prov" | awk '$1 == "code" && $3 == "overall_pro" { print $2 }')
mark_code=$(printf '%s\n' "$prov" | awk '$1 == "code" && $3 == "mark_boat" && $4 == "Alpha" { print $2 }')
[ -n "$pro_code" ] && [ -n "$mark_code" ] || fail "provision printed no overall_pro or mark_boat Alpha code"

for device in "$PRO" "$MARK"; do
  # Fresh, with the permissions granted before launch (see sync_flow.sh).
  "$ADB" -s "$device" shell pm clear "$APP" >/dev/null 2>&1
  if ! sh integration_test/grant_location.sh "$ADB" "$device"; then
    "$ADB" -s "$device" uninstall "$APP" >/dev/null 2>&1
    "$ADB" -s "$device" uninstall "$APP.test" >/dev/null 2>&1
  fi
  "$ADB" -s "$device" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null || fail "adb reverse on $device"
done

pro_log=$(mktemp)
mark_log=$(mktemp)
echo "two-phones: PRO on $PRO, mark boat on $MARK"
# The expanded reporter, by name, on both runs: the github reporter, the default on GitHub Actions,
# holds a test's printed lines until the test ends, and PRO_READY is waited for while it runs
# (sync_flow.sh).
flutter test integration_test/two_phones_flow.dart -d "$PRO" --reporter expanded --dart-define-from-file="$defines" \
  --dart-define=TWO_PHONES_ROLE=pro --dart-define=TWO_PHONES_CODE="$pro_code" >"$pro_log" 2>&1 &
pro_run=$!
# One build at a time: two flutter test builds in one project collide over build/. The mark boat
# starts once the PRO is up, and the PRO waits long enough for its build.
waited=0
until grep -q "SYNC_FLOW PRO_READY" "$pro_log"; do
  kill -0 "$pro_run" 2>/dev/null || fail "the PRO's run ended before PRO_READY"
  [ "$waited" -ge 900 ] && fail "no PRO_READY within 900 s"
  sleep 2
  waited=$((waited + 2))
done
flutter test integration_test/two_phones_flow.dart -d "$MARK" --reporter expanded --dart-define-from-file="$defines" \
  --dart-define=TWO_PHONES_ROLE=mark --dart-define=TWO_PHONES_CODE="$mark_code" >"$mark_log" 2>&1 &
mark_run=$!

wait "$pro_run"
pro_status=$?
wait "$mark_run"
mark_status=$?
grep -h "SYNC_FLOW" "$pro_log" "$mark_log"
[ "$pro_status" -eq 0 ] && [ "$mark_status" -eq 0 ] || fail "PRO exit $pro_status, mark boat exit $mark_status"
echo "two-phones: passed"
