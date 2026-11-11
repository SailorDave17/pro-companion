#!/usr/bin/env sh
# #113 on a phone: sync started by the app's own core host, against the local stack.
#
#   sh integration_test/sync_flow.sh [device-id]      (ADB=/path/to/adb to override)
#
# Needs the local stack running (scripts/start_local_stack.sh), with its mail server. It:
#   - writes the build's defines file from the stack's status (scripts/sync_defines.dart), so the
#     build syncs with the stack and holds nothing but its URL and publishable key;
#   - provisions a race day with the owner script, and clears the app, so the phone is fresh;
#   - points the phone's 127.0.0.1:54421 at the stack with adb reverse;
#   - runs integration_test/sync_flow.dart, and acts when it prints each SYNC_FLOW line:
#       LINK_SENT    reads the link the stack mailed and opens it on the phone, as a tap would;
#       CUT_NOW      removes the reverse forward and pauses the stack's gateway: the cut, with the
#                    host's control that the gateway answers nothing. Airplane mode cuts neither;
#       RESTORE_NOW  puts both back, and checks the gateway answers again;
#       REVOKE_NOW   revokes the phone's sign-in from the race day with the owner script.
# Then it reads the shore as the table owner: every event the phone uploaded is there.
set -u
DEVICE="${1:-emulator-5554}"
ADB="${ADB:-adb}"
APP=com.procompanion.app
PORT=54421
cd "$(dirname "$0")/.." || exit 1

fail() {
  echo "FAIL: $*"
  [ -n "${log:-}" ] && [ -f "$log" ] && cat "$log"
  exit 1
}

GATEWAY=supabase_kong_pro_companion
restore() { "$ADB" -s "$DEVICE" reverse "tcp:$PORT" "tcp:$PORT" >/dev/null 2>&1; }
# Whatever happens, the stack's gateway is left running for the next test.
trap 'docker unpause "$GATEWAY" >/dev/null 2>&1; restore' EXIT
# dash skips the EXIT trap when a signal ends it; exiting from a signal trap runs it (link_kill.sh).
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mkdir -p build
defines=build/sync_flow.defines.json
dart run scripts/sync_defines.dart --out "$defines" || fail "no defines file: is the local stack running?"

stamp=$(date +%s)
event="Sync flow $stamp"
prov=$(dart run scripts/owner.dart provision --club "Sync flow club $stamp" --event "$event" \
  --date "$(date +%F)" --race-area Alpha) || fail "provision failed: $prov"
code=$(printf '%s\n' "$prov" | awk '$1 == "code" && $3 == "overall_pro" { print $2 }')
event_id=$(printf '%s\n' "$prov" | awk '$1 == "event" { print $2 }')
[ -n "$code" ] && [ -n "$event_id" ] || fail "provision printed no overall_pro code or event id"
email="sync.flow.$stamp@pro-companion.test"

# A fresh phone: no device id, no session, no admission. pm clear drops the permissions too, so
# they are granted again before the launch: a permission dialog on top of the app takes the link's
# intent into a second MainActivity, whose engine the flow never sees (measured on the first run).
# An older build's manifest may refuse a grant; then it is uninstalled, and flutter test installs
# this build, whose first launch asks.
"$ADB" -s "$DEVICE" shell pm clear "$APP" >/dev/null 2>&1
if ! sh integration_test/grant_location.sh "$ADB" "$DEVICE"; then
  echo "sync-flow: the installed build refused a grant, so it is uninstalled"
  "$ADB" -s "$DEVICE" uninstall "$APP" >/dev/null 2>&1
  "$ADB" -s "$DEVICE" uninstall "$APP.test" >/dev/null 2>&1
fi
restore
"$ADB" -s "$DEVICE" reverse --list | grep -q "tcp:$PORT" || fail "adb reverse did not take"

log=$(mktemp)
echo "sync-flow: race day $event_id, as $email"
# The expanded reporter, by name: on GitHub Actions the default is the github reporter, which holds
# every line a test prints until the test ends. This script acts on those lines while it runs, so
# LINK_SENT arrived with the failure, 90 s late (measured on #188's first CI run).
flutter test integration_test/sync_flow.dart -d "$DEVICE" --reporter expanded --dart-define-from-file="$defines" \
  --dart-define=SYNC_FLOW_EMAIL="$email" --dart-define=SYNC_FLOW_CODE="$code" \
  --dart-define=SYNC_FLOW_EVENT="$event" --dart-define=SYNC_FLOW_PORT="$PORT" >"$log" 2>&1 &
run=$!

# Waits for the flow to print SYNC_FLOW $1, for up to $2 seconds.
await() {
  waited=0
  until grep -q "SYNC_FLOW $1" "$log"; do
    kill -0 "$run" 2>/dev/null || fail "the flow ended before $1"
    [ "$waited" -ge "$2" ] && fail "no $1 within $2 s"
    sleep 1
    waited=$((waited + 1))
  done
  echo "sync-flow: $1"
}

# The first wait covers the build and install.
await LINK_SENT 900
# By its shape: dart run can print its own progress on the same line.
redirect=$(dart run integration_test/stack_link.dart "$email" 2>&1 |
  sed -n 's#.*\(procompanion://sign-in?[^[:space:]]*\).*#\1#p' | tail -n 1)
case "$redirect" in
  procompanion://sign-in\?code=*) ;;
  *) fail "the mailed link redirected to '$redirect', not the app with a code" ;;
esac
# This build is installed and running now. A permission dialog it raised at launch would take the
# link's intent into a second MainActivity, so grant, and clear any dialog, before the tap.
sh integration_test/grant_location.sh "$ADB" "$DEVICE" || fail "could not grant before the link"
sleep 2
# Single quotes for the phone's shell, which would split the address at an &.
"$ADB" -s "$DEVICE" shell am start -W -a android.intent.action.VIEW -d "'$redirect'" "$APP" >/dev/null ||
  fail "the link's intent was not delivered"

await CUT_NOW 120
# Two halves, because either alone leaves a path open. Removing the reverse forward refuses a new
# connection on the phone, but sync's pooled keep-alive connection, opened before the cut, still
# reaches the stack through adb: measured on the first runs, the "cut" phone uploaded every event.
# Pausing the gateway answers nothing on any connection, old or new, until it is unpaused.
# The gateway goes first: the phone's control sees the forward's removal at once, and taps as soon
# as it does, so with the forward first one tap went up on the pooled connection (measured).
docker pause "$GATEWAY" >/dev/null || fail "could not pause the stack's gateway"
# The host's control: the gateway itself gives no answer now.
curl -s -m 3 -o /dev/null "http://127.0.0.1:$PORT/rest/v1/" && fail "the gateway still answers: the cut cut nothing"
"$ADB" -s "$DEVICE" reverse --remove "tcp:$PORT" || fail "the cut failed"
"$ADB" -s "$DEVICE" reverse --list | grep -q "tcp:$PORT" && fail "the reverse forward is still up"
await CUT_SEEN 90

await RESTORE_NOW 120
docker unpause "$GATEWAY" >/dev/null || fail "could not unpause the stack's gateway"
restore
curl -s -m 5 -o /dev/null "http://127.0.0.1:$PORT/rest/v1/" || fail "the gateway does not answer after the restore"
await RESTORED 90

# Criterion 3: the signed-in phone keeps its session in the no-backup directory, and nowhere a
# backup or a device transfer reaches. run-as reads a debug build's private files.
"$ADB" -s "$DEVICE" shell run-as "$APP" ls no_backup | grep -q '^sync_session.json' ||
  fail "no sync_session.json in the app's no_backup directory"
"$ADB" -s "$DEVICE" shell run-as "$APP" find . -name 'sync_session.json' | grep -v '^./no_backup/' | grep -q . &&
  fail "a session file outside no_backup"
echo "sync-flow: the session is in no_backup, and only there"

await REVOKE_NOW 120
listed=$(dart run scripts/owner.dart revoke --event-id "$event_id") || fail "listing admissions failed: $listed"
device=$(printf '%s\n' "$listed" | awk '$1 == "admission" { print $2 }' | sort -u)
[ "$(printf '%s\n' "$device" | grep -c .)" -eq 1 ] || fail "expected one sign-in on the race day: $listed"
dart run scripts/owner.dart revoke --event-id "$event_id" --device "$device" >/dev/null || fail "the revoke failed"

wait "$run"
status=$?
cat "$log"
[ "$status" -eq 0 ] || fail "the flow failed"

# The shore's side: the role pick, the three cut notes and every note before the revocation.
on_shore=$(docker exec "supabase_db_pro_companion" psql -U postgres -tAc \
  "select count(*) from public.event_log where event_id = '$event_id'" | tr -d '\r ')
echo "sync-flow: $on_shore events on shore for the race day"
[ "${on_shore:-0}" -ge 4 ] || fail "expected at least 4 events on shore, read $on_shore"
echo "sync-flow: passed"
