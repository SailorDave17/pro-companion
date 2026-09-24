#!/usr/bin/env sh
# #14 instrumented tests on one running Android device or emulator (API 33+ for criterion 3).
#   sh tool/core_host_spike/run_tests.sh
# The permission test needs POST_NOTIFICATIONS and location ungranted, which cannot be
# done from inside the test (revoking kills the process under test), so it is done here.
set -eu
cd "$(dirname "$0")"
PKG=com.procompanion.core_host_spike
ADB="${ADB:-adb}"
RUNNER="$PKG.test/androidx.test.runner.AndroidJUnitRunner"

flutter build apk --debug >/dev/null            # generates the Gradle wrapper and the Dart bundle
(cd android && ./gradlew -q app:installDebug app:installDebugAndroidTest)

for p in android.permission.POST_NOTIFICATIONS android.permission.ACCESS_FINE_LOCATION android.permission.ACCESS_COARSE_LOCATION; do
  "$ADB" shell pm revoke "$PKG" "$p" 2>/dev/null || true
done
"$ADB" shell pm clear-permission-flags "$PKG" android.permission.POST_NOTIFICATIONS user-set user-fixed 2>/dev/null || true
"$ADB" shell am instrument -w -e class "$PKG.NotificationPermissionTest" "$RUNNER"
"$ADB" shell am instrument -w -e class "$PKG.IntentReachesHeadlessDartTest" "$RUNNER"
