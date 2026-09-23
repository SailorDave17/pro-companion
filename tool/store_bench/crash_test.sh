#!/usr/bin/env sh
# #13 criterion 4: force-kill the sqlite3 writer mid-append, relaunch, and check that
# every acknowledged event survived. Needs one running Android device or emulator.
#
#   sh tool/store_bench/crash_test.sh [cycles]
#
# Each launch prints "STORED count=N maxseq=M contiguous=.. chain=.." for what the
# previous run left, then appends until killed, printing "ACK <seq>" as each append
# returns. PASS means: for every cycle, the next launch's maxseq >= the last ACK
# printed before the kill, and the stored chain is contiguous and unbroken.
set -eu
cd "$(dirname "$0")"
CYCLES="${1:-6}"
PKG=com.procompanion.store_bench
ADB="${ADB:-adb}"

flutter build apk --profile >/dev/null
"$ADB" install -r build/app/outputs/flutter-apk/app-profile.apk >/dev/null
"$ADB" shell pm clear "$PKG" >/dev/null

prev_ack=0
fail=0
i=0
while [ "$i" -le "$CYCLES" ]; do
  "$ADB" logcat -c
  "$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null
  sleep $((3 + i % 4))
  "$ADB" shell am force-stop "$PKG"
  sleep 1
  log=$("$ADB" logcat -d -s flutter)
  stored=$(printf '%s\n' "$log" | grep -o 'STORED .*' | tail -1)
  ack=$(printf '%s\n' "$log" | grep -o 'ACK [0-9]*' | tail -1 | cut -d' ' -f2)
  maxseq=$(printf '%s\n' "$stored" | sed -n 's/.*maxseq=\([0-9]*\).*/\1/p')
  verdict=ok
  [ "${maxseq:-0}" -ge "$prev_ack" ] || verdict=LOST
  case "$stored" in *"contiguous=true chain=true"*) ;; *) verdict="$verdict BROKEN" ;; esac
  [ "$verdict" = ok ] || fail=1
  echo "cycle $i: launch found [$stored] vs last ACK before previous kill=$prev_ack -> $verdict; this run ACKed up to ${ack:-none}"
  prev_ack="${ack:-$prev_ack}"
  i=$((i + 1))
done
[ "$fail" = 0 ] && echo "PASS: every acknowledged event survived $CYCLES force-kills" || { echo "FAIL"; exit 1; }
