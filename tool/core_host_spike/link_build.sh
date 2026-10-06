#!/usr/bin/env sh
# #15: builds the link spike and installs it on one running device or emulator.
#   ADB=path/to/adb sh tool/core_host_spike/link_build.sh [debug|profile] [trusted|imposter]
#
# The companion (this spike's app) is signed with the machine's debug key. The harness
# APK is built once and signed twice, with two throwaway keys made here under
# build/link_keys: "trusted", whose SHA-256 the companion is built to pin, and
# "imposter", which it is not. Both copies carry the same package, so they differ
# only in signer, and the one named is installed. The race-timer stand-in is never
# signed with the companion's key, because race-timer never will be either.
#
# SKIP_BUILD=1 reuses the last build and only re-signs and installs.
set -eu
cd "$(dirname "$0")"
MODE="${1:-profile}"
SIGNER="${2:-trusted}"
ADB="${ADB:-adb}"
PKG=com.procompanion.core_host_spike
HARNESS=com.procompanion.link_harness
KEYS=build/link_keys
PASS=linkspike   # throwaway keys for a debug-only harness; they sign nothing else

SDK=$(printf '%s' "${ANDROID_HOME:-${ANDROID_SDK_ROOT:?set ANDROID_HOME}}" | tr '\\' '/')
BT=$(ls -d "$SDK"/build-tools/* | sort -V | tail -1)
apksigner() { java -jar "$BT/lib/apksigner.jar" "$@"; }

mkdir -p "$KEYS"
for k in trusted imposter; do
  [ -f "$KEYS/$k.jks" ] || keytool -genkeypair -noprompt -keystore "$KEYS/$k.jks" -storepass "$PASS" \
    -keypass "$PASS" -alias "$k" -dname "CN=link harness $k" -keyalg RSA -keysize 2048 -validity 365 >/dev/null 2>&1
done
digest() {
  keytool -list -v -keystore "$KEYS/$1.jks" -storepass "$PASS" -alias "$1" |
    sed -n 's/^.*SHA256: *//p' | tr -d ':\r' | tr 'A-F' 'a-f'
}
TRUSTED=$(digest trusted)
[ -n "$TRUSTED" ] || { echo "could not read the trusted key's SHA-256" >&2; exit 1; }
echo "pinned certificate (trusted harness key): $TRUSTED"

case "$MODE" in
  debug) TASK=Debug ;;
  profile) TASK=Profile ;;
  *) echo "mode must be debug or profile" >&2; exit 64 ;;
esac

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  flutter pub get >/dev/null
  # The first build generates the Gradle wrapper and local.properties.
  [ -f android/gradlew ] || flutter build apk --debug >/dev/null
  TASKS="app:assemble$TASK harness:assembleDebug"
  [ "$MODE" = debug ] && TASKS="$TASKS app:assembleDebugAndroidTest"
  # --no-watch-fs: a watched build here can report success having compiled nothing
  # (cairn windows-shell-hazards, hazard 4).
  (cd android && ./gradlew -q --no-watch-fs $TASKS \
    -PlinkTrustedPackage="$HARNESS" -PlinkTrustedCerts="$TRUSTED")
fi

APP=build/app/outputs/apk/$MODE/app-$MODE.apk
HARNESS_APK=build/link_harness_$SIGNER.apk
apksigner sign --ks "$KEYS/$SIGNER.jks" --ks-pass "pass:$PASS" --ks-key-alias "$SIGNER" \
  --out "$HARNESS_APK" build/harness/outputs/apk/debug/harness-debug.apk
echo "harness signed with the $SIGNER key: $(apksigner verify --print-certs "$HARNESS_APK" |
  sed -n 's/^.*certificate SHA-256 digest: *//p' | sort -u | tr '\n' ' ')"

"$ADB" install -r "$APP" >/dev/null
[ "$MODE" = debug ] && "$ADB" install -r build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk >/dev/null
# A copy signed by the other key cannot replace this one in place.
"$ADB" uninstall "$HARNESS" >/dev/null 2>&1 || true
"$ADB" install "$HARNESS_APK" >/dev/null
echo "installed: $PKG ($MODE), $HARNESS ($SIGNER)"
