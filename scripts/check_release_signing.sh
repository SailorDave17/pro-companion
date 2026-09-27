#!/usr/bin/env sh
# #23: release signing, proven without the owner's key.
#
#   sh scripts/check_release_signing.sh        (APKSIGNER=/path/to/apksigner to override)
#
# Three release builds, each held to what it must show:
#   no key          - with none of the four PRO_COMPANION_* variables and no
#                     android/key.properties, `flutter build apk --release` must
#                     fail, name every missing variable, and leave no APK. A
#                     fallback to the debug keys builds, and turns this red.
#   environment     - a throwaway keystore generated here, named by the four
#                     variables: apksigner must verify the APK and report exactly
#                     that keystore's certificate, and no other signer.
#   key.properties  - the same keystore named by android/key.properties instead,
#                     held to the same check.
# The CI job release-signing runs this. It stops before building anything if
# android/key.properties already exists: that file names the owner's real key,
# and this script writes and deletes its own copy. It also deletes any release
# APK already at build/app/outputs/flutter-apk/app-release.apk before it
# builds, and every release APK it built when it finishes, since each one is
# signed by a key that no longer exists.
set -u
cd "$(dirname "$0")/.." || exit 1

APK=build/app/outputs/flutter-apk/app-release.apk
KEY_PROPERTIES=android/key.properties
VARIABLES="PRO_COMPANION_KEYSTORE PRO_COMPANION_KEYSTORE_PASSWORD PRO_COMPANION_KEY_ALIAS PRO_COMPANION_KEY_PASSWORD"

if [ -e "$KEY_PROPERTIES" ]; then
  echo "STOP: $KEY_PROPERTIES exists and names the owner's key, so this check will not run here (CI runs it)"
  exit 2
fi
for v in $VARIABLES; do unset "$v"; done

# Java reads these paths, so on Git Bash they are handed over in Windows form (C:/...).
native() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}

if [ -z "${APKSIGNER:-}" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -z "$SDK" ] || [ ! -d "$SDK/build-tools" ]; then
    echo "FAIL: no Android SDK build-tools found; set ANDROID_HOME or APKSIGNER"
    exit 1
  fi
  TOOLS="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -n 1)"
  APKSIGNER="$TOOLS/apksigner"
  [ -f "$APKSIGNER" ] || APKSIGNER="$TOOLS/apksigner.bat"
fi

WORK=$(mktemp -d)
WROTE_KEY_PROPERTIES=0
# Every release APK this script builds is signed by a keystore that is deleted below, so none of
# them may be left where docs/field-builds.md installs from.
cleanup() {
  [ "$WROTE_KEY_PROPERTIES" = 1 ] && rm -f "$KEY_PROPERTIES"
  rm -rf "$WORK"
  rm -f "$APK" "$APK.sha1" build/app/outputs/apk/release/app-release.apk
}
trap cleanup EXIT
# dash (sh on Debian and Ubuntu) skips the EXIT trap when a signal ends it; exiting from a signal
# trap runs it. Without these, a Ctrl-C in the key.properties stage leaves the throwaway key wired up.
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "release-signing: no key"
rm -f "$APK"
if flutter build apk --release >"$WORK/no-key.log" 2>&1; then
  tail -n 40 "$WORK/no-key.log"
  echo "FAIL: a release build with no upload key succeeded"
  exit 1
fi
unnamed=""
for v in $VARIABLES; do
  # "$v (or", not "$v": PRO_COMPANION_KEYSTORE is a prefix of PRO_COMPANION_KEYSTORE_PASSWORD, so a
  # bare match counts the keystore as named whenever the password line is printed.
  grep -qF "$v (or" "$WORK/no-key.log" || unnamed="$unnamed $v"
done
if [ -n "$unnamed" ]; then
  tail -n 40 "$WORK/no-key.log"
  echo "FAIL: the build failed without naming:$unnamed"
  exit 1
fi
if [ -e "$APK" ]; then
  echo "FAIL: the refused build left $APK behind"
  exit 1
fi
echo "ok (no key): refused, naming all four variables"

KEYSTORE=$(native "$WORK/throwaway.jks")
PASSWORD=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
ALIAS=throwaway
keytool -genkeypair -keystore "$KEYSTORE" -storetype PKCS12 -alias "$ALIAS" \
  -keyalg RSA -keysize 2048 -validity 1 -dname "CN=pro-companion CI throwaway" \
  -storepass "$PASSWORD" -keypass "$PASSWORD" -noprompt >/dev/null 2>&1
EXPECTED=$(keytool -list -v -keystore "$KEYSTORE" -storepass "$PASSWORD" -alias "$ALIAS" \
  | tr -d '\r' | sed -n 's/^[[:space:]]*SHA256:[[:space:]]*//p' | tr -d ':' | tr 'A-F' 'a-f')
if ! printf '%s' "$EXPECTED" | grep -Eq '^[0-9a-f]{64}$'; then
  echo "FAIL: could not read the throwaway keystore's SHA-256 digest (got '$EXPECTED')"
  exit 1
fi

# apksigner, not keytool: keytool -printcert reads v1 signatures only, and prints
# "Not a signed jar file" with exit 0 on a correctly v2-signed APK.
build_and_verify() {
  rm -f "$APK"
  if ! flutter build apk --release >"$WORK/$1.log" 2>&1; then
    tail -n 60 "$WORK/$1.log"
    echo "FAIL: the release build with the throwaway key ($1) failed"
    exit 1
  fi
  if [ ! -f "$APK" ]; then
    echo "FAIL: the release build ($1) produced no $APK"
    exit 1
  fi
  if ! "$APKSIGNER" verify --print-certs "$APK" >"$WORK/$1.certs" 2>&1; then
    cat "$WORK/$1.certs"
    echo "FAIL: apksigner could not verify the APK ($1)"
    exit 1
  fi
  signers=$(tr -d '\r' <"$WORK/$1.certs" | grep -c 'certificate SHA-256 digest:')
  got=$(tr -d '\r' <"$WORK/$1.certs" | sed -n 's/^Signer #1 certificate SHA-256 digest: *//p')
  if [ "$signers" != 1 ] || [ "$got" != "$EXPECTED" ]; then
    cat "$WORK/$1.certs"
    echo "FAIL: ($1) signed by $signers signer(s), first '$got'; expected only the throwaway key, $EXPECTED"
    exit 1
  fi
  echo "ok ($1): signed by the throwaway key and nothing else, $got"
}

echo "release-signing: the key named by environment variables"
export PRO_COMPANION_KEYSTORE="$KEYSTORE"
export PRO_COMPANION_KEYSTORE_PASSWORD="$PASSWORD"
export PRO_COMPANION_KEY_ALIAS="$ALIAS"
export PRO_COMPANION_KEY_PASSWORD="$PASSWORD"
build_and_verify environment
for v in $VARIABLES; do unset "$v"; done

echo "release-signing: the key named by $KEY_PROPERTIES"
WROTE_KEY_PROPERTIES=1
printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' \
  "$KEYSTORE" "$PASSWORD" "$ALIAS" "$PASSWORD" >"$KEY_PROPERTIES"
build_and_verify key.properties
