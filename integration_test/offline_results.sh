#!/usr/bin/env sh
# #7 criterion 2: provisional results with no network for the whole race day.
#
#   sh integration_test/offline_results.sh [device-id]      (ADB=/path/to/adb to override)
#
# Two runs of integration_test/offline_results_flow.dart:
#   control - airplane mode off: the flow's probe must connect. If this phone
#             has no network at all, the second run would pass for the wrong
#             reason, so the script stops here instead.
#   offline - airplane mode on, checked: the probe must fail to connect, then a
#             two-race day runs from the app's home to provisional results on
#             the real core, with the network tripwire armed on HTTP clients
#             and sockets. It prints what its probe got and what the tripwire
#             saw.
set -u
DEVICE="${1:-emulator-5554}"
ADB="${ADB:-adb}"
cd "$(dirname "$0")/.." || exit 1

restore() { "$ADB" -s "$DEVICE" shell cmd connectivity airplane-mode disable >/dev/null 2>&1; }
trap restore EXIT

restore
echo "offline-results: control, airplane mode off"
if ! flutter test integration_test/offline_results_flow.dart -d "$DEVICE" --dart-define=EXPECT_NETWORK=true; then
  echo "FAIL: the probe could not connect with airplane mode off, so the offline run would prove nothing"
  exit 1
fi

"$ADB" -s "$DEVICE" shell cmd connectivity airplane-mode enable
if [ "$("$ADB" -s "$DEVICE" shell settings get global airplane_mode_on | tr -d '\r')" != 1 ]; then
  echo "FAIL: airplane mode did not turn on"
  exit 1
fi

echo "offline-results: airplane mode on"
flutter test integration_test/offline_results_flow.dart -d "$DEVICE"
