#!/usr/bin/env sh
# #15 criterion 3 on one running device or emulator, API 34+ (a broadcast's sender is
# unknown below that). Runs LinkTrustTest twice: first with the harness signed by the
# imposter key, which every mechanism must refuse, then by the pinned key, the control
# that the same path accepts a trusted emitter. In both runs a caller with another
# package is refused too. SKIP_BUILD=1 reuses the last build.
#   ADB=path/to/adb sh tool/core_host_spike/link_tests.sh
set -eu
cd "$(dirname "$0")"
ADB="${ADB:-adb}"
PKG=com.procompanion.core_host_spike
RUNNER="$PKG.test/androidx.test.runner.AndroidJUnitRunner"

status=0
instrument() { # expect
  out=$("$ADB" shell am instrument -w -e class "$PKG.LinkTrustTest" -e expect "$1" "$RUNNER" | tr -d '\r')
  echo "$out"
  # am instrument exits 0 on a failed test, so the verdict is read from its output.
  case "$out" in
    *"OK (4 tests)"*) echo "== expect $1: passed" ;;
    *) echo "== expect $1: FAILED"; status=1 ;;
  esac
}

sh link_build.sh debug imposter
instrument untrusted
SKIP_BUILD=1 sh link_build.sh debug trusted
instrument trusted
exit $status
