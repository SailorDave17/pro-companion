#!/usr/bin/env sh
# #14 criterion 1, plus the ADR 003 port measurement, on one running Android device or emulator.
#   sh tool/core_host_spike/doze_run.sh [minutes]
# Profile build. Starts the core with permissions pre-granted, times 1,000 UI -> core port
# round trips, destroys the activity (BACK), forces Doze, then records the core's TICK lines
# from logcat for the given minutes (default 30) and reports count and largest gap.
set -eu
cd "$(dirname "$0")"
MIN="${1:-30}"
PKG=com.procompanion.core_host_spike
ADB="${ADB:-adb}"
OUT="${OUT:-build/doze_run.log}"
mkdir -p build

flutter build apk --profile >/dev/null
"$ADB" install -r build/app/outputs/flutter-apk/app-profile.apk >/dev/null
"$ADB" shell am force-stop "$PKG"
"$ADB" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS
"$ADB" shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION
"$ADB" logcat -c

"$ADB" shell am start -n "$PKG/.MainActivity" --ez autostart true >/dev/null
sleep 8
# "Ping core" button: centre of the second button on a 1080-wide screen.
"$ADB" shell input tap 540 467
sleep 8
"$ADB" logcat -d -s flutter | grep -o 'PING .*' | tail -1 || echo "PING not captured"

"$ADB" shell input keyevent KEYCODE_BACK       # finishes the only activity: destroyed
sleep 3
echo "activities left for $PKG: $("$ADB" shell dumpsys activity activities | grep -c "$PKG/.MainActivity" || true)"
echo "service running: $("$ADB" shell dumpsys activity services "$PKG" | grep -c 'CoreService' || true)"

"$ADB" shell dumpsys battery unplug
"$ADB" shell input keyevent KEYCODE_SLEEP
"$ADB" shell dumpsys deviceidle force-idle >/dev/null
echo "deep idle state: $("$ADB" shell dumpsys deviceidle get deep | tr -d '\r')"
doze_start=$(date -u +%s)

"$ADB" logcat -c
sleep $((MIN * 60))
echo "deep idle state at end: $("$ADB" shell dumpsys deviceidle get deep | tr -d '\r')"
"$ADB" logcat -d -s flutter | grep 'CORE .* TICK' > "$OUT" || true

"$ADB" shell dumpsys deviceidle unforce >/dev/null
"$ADB" shell dumpsys battery reset
"$ADB" shell input keyevent KEYCODE_WAKEUP

python - "$OUT" "$MIN" <<'EOF'
import re, sys
from datetime import datetime
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
ts = [datetime.fromisoformat(m.group(1).replace("Z", "+00:00"))
      for l in lines if (m := re.search(r"CORE (\S+) TICK", l))]
gaps = [(b - a).total_seconds() for a, b in zip(ts, ts[1:])]
print(f"ticks in {sys.argv[2]} min of forced Doze: {len(ts)} (expected ~{int(sys.argv[2]) * 6})")
if gaps:
    print(f"gap between ticks: min {min(gaps):.2f}s, max {max(gaps):.2f}s, over 11s: {sum(g > 11 for g in gaps)}")
EOF
