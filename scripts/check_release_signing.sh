#!/usr/bin/env sh
# #23: release signing, proven without the owner's key.
#
#   sh scripts/check_release_signing.sh        (APKSIGNER=/path/to/apksigner to override)
#
# Four release builds, each held to what it must show:
#   no key          - with none of the four PRO_COMPANION_* variables and no
#                     android/key.properties, `flutter build apk --release` must
#                     fail, name every missing variable, and leave no APK. A
#                     fallback to the debug keys builds, and turns this red.
#   environment     - a throwaway keystore generated here, named by the four
#                     variables: apksigner must verify the APK and report exactly
#                     that keystore's certificate, and no other signer.
#   debug pin       - the same keystore with linkDebugCerts passed to the build: a
#                     debug pin must not reach a release APK (#33).
#   key.properties  - the same keystore named by android/key.properties instead,
#                     held to the same check.
# #46: each signed APK must also request INTERNET and ACCESS_NETWORK_STATE, read
# by aapt2 from the manifest the APK carries (the merged release manifest).
# Only a release build can show this: the debug and profile manifests add
# INTERNET for the Flutter tool. AAPT2=/path/to/aapt2 overrides.
# #31: and ACCESS_FINE_LOCATION and ACCESS_COARSE_LOCATION, the same way, so
# every event can carry where it happened.
# #32: and FOREGROUND_SERVICE, FOREGROUND_SERVICE_LOCATION and POST_NOTIFICATIONS,
# the core host's (ADR 003), without which it cannot keep logging with the UI gone.
# #33: each must also export .LinkService with no permission, query race-timer, and
# pin exactly the two certificates ADR 004 records, read from the ADR itself.
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

if [ -z "${APKSIGNER:-}" ] || [ -z "${AAPT2:-}" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  if [ -z "$SDK" ] || [ ! -d "$SDK/build-tools" ]; then
    echo "FAIL: no Android SDK build-tools found; set ANDROID_HOME, or APKSIGNER and AAPT2"
    exit 1
  fi
  TOOLS="$SDK/build-tools/$(ls "$SDK/build-tools" | sort -V | tail -n 1)"
fi
if [ -z "${APKSIGNER:-}" ]; then
  APKSIGNER="$TOOLS/apksigner"
  [ -f "$APKSIGNER" ] || APKSIGNER="$TOOLS/apksigner.bat"
fi
if [ -z "${AAPT2:-}" ]; then
  AAPT2="$TOOLS/aapt2"
  [ -f "$AAPT2" ] || AAPT2="$TOOLS/aapt2.exe"
fi
echo "release-signing: apksigner is $APKSIGNER"
echo "release-signing: aapt2 is $AAPT2"

# #33: who the link trusts, read from ADR 004's table rather than copied here, so the doc and the
# APK cannot part. Read before any build, so a renamed row costs no builds to find, and refused when
# it does not yield two digests, so an empty list is never compared with an empty read.
ADR=docs/adr/004-race-timer-link.md
LINK_PACKAGE=$(tr -d '\r' <"$ADR" | sed -n 's/^\*\*The companion trusts race-timer\*\*, package `\([^`]*\)`.*/\1/p')
LINK_CERTS=$(tr -d '\r' <"$ADR" \
  | sed -n -e 's/^| from Play |.*`\([0-9a-f]\{64\}\)`.*/\1/p' -e 's/^| sideloaded release |.*`\([0-9a-f]\{64\}\)`.*/\1/p' \
  | sort -u)
if [ -z "$LINK_PACKAGE" ] || [ "$(printf '%s\n' "$LINK_CERTS" | grep -c .)" != 2 ]; then
  echo "FAIL: could not read race-timer's package and two digests from $ADR (got '$LINK_PACKAGE', '$LINK_CERTS')"
  exit 1
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
  if ! flutter build apk --release ${DEBUG_PIN_ARG:-} >"$WORK/$1.log" 2>&1; then
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
  # The digest line's prefix is apksigner's wording, and it moves between build-tools versions:
  # 36.0.0 prints "Signer #1 certificate SHA-256 digest:", the CI runner's "V2 Signer: certificate
  # SHA-256 digest:" (one line per scheme). So read every SHA-256 digest whatever precedes it, and
  # hold the APK to exactly one distinct certificate.
  digests=$(tr -d '\r' <"$WORK/$1.certs" | sed -n 's/.*certificate SHA-256 digest: *\([0-9a-f]*\).*/\1/p' | sort -u)
  signers=$(printf '%s\n' "$digests" | grep -c .)
  got=$(printf '%s\n' "$digests" | head -n 1)
  if [ "$signers" != 1 ] || [ "$got" != "$EXPECTED" ]; then
    cat "$WORK/$1.certs"
    echo "FAIL: ($1) signed by $signers signer(s), first '$got'; expected only the throwaway key, $EXPECTED"
    exit 1
  fi
  echo "ok ($1): signed by the throwaway key and nothing else, $got"
  check_permissions "$1"
  check_link "$1"
}

# #46, #31 and #32. aapt2 prints one "uses-permission: name='...'" line per permission, with any
# maxSdkVersion after it on the same line, so a whole-line match also refuses a permission capped
# below current phones.
REQUIRED_PERMISSIONS="android.permission.INTERNET android.permission.ACCESS_NETWORK_STATE android.permission.ACCESS_FINE_LOCATION android.permission.ACCESS_COARSE_LOCATION android.permission.FOREGROUND_SERVICE android.permission.FOREGROUND_SERVICE_LOCATION android.permission.POST_NOTIFICATIONS"
check_permissions() {
  if ! "$AAPT2" dump permissions "$APK" >"$WORK/$1.permissions" 2>&1; then
    cat "$WORK/$1.permissions"
    echo "FAIL: aapt2 could not read the APK's permissions ($1)"
    exit 1
  fi
  missing=""
  for p in $REQUIRED_PERMISSIONS; do
    tr -d '\r' <"$WORK/$1.permissions" | grep -qxF "uses-permission: name='$p'" || missing="$missing $p"
  done
  if [ -n "$missing" ]; then
    cat "$WORK/$1.permissions"
    echo "FAIL: ($1) the release APK does not request:$missing"
    exit 1
  fi
  echo "ok ($1): the release APK requests $REQUIRED_PERMISSIONS"
}

# #33. Prints the attribute lines of each manifest element of kind $2 whose name ends in $3, from the
# aapt2 dump in $1. A dump is "E: <element>" and then that element's "A: ..." lines, before any child.
# The match is on the closing quote and not the whole value, because the merged manifest carries the
# full class name where the source says .LinkService.
manifest_element() {
  tr -d '\r' <"$1" | awk -v kind="$2" -v name="$3\"" '
    function finish() { if (element == kind && index(attributes, name)) printf "%s", attributes; attributes = "" }
    $1 == "E:" { finish(); element = $2; next }
    $1 == "A:" { attributes = attributes $0 "\n" }
    END { finish() }
  '
}

# Every test here refuses when it reads nothing, so a dump in a shape this does not expect is a red
# build naming the dump, never a pass.
check_link() {
  if ! "$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" >"$WORK/$1.manifest" 2>&1; then
    cat "$WORK/$1.manifest"
    echo "FAIL: aapt2 could not read the APK's manifest ($1)"
    exit 1
  fi
  if ! "$AAPT2" dump resources "$APK" >"$WORK/$1.resources" 2>&1; then
    cat "$WORK/$1.resources"
    echo "FAIL: aapt2 could not read the APK's resources ($1)"
    exit 1
  fi
  service=$(manifest_element "$WORK/$1.manifest" service .LinkService)
  if ! printf '%s\n' "$service" | grep -Eq 'exported[^=]*=("?true|.*0xffffffff|-1)'; then
    cat "$WORK/$1.manifest"
    echo "FAIL: ($1) the release APK does not export .LinkService"
    exit 1
  fi
  # The merged manifest, so this also sees what a library's manifest could add to the element.
  if printf '%s\n' "$service" | grep -Eq '[: ](permission|process)[(=]'; then
    cat "$WORK/$1.manifest"
    echo "FAIL: ($1) .LinkService carries a permission or a process, which ADR 004 rules out"
    exit 1
  fi
  if [ -z "$(manifest_element "$WORK/$1.manifest" package "\"$LINK_PACKAGE")" ]; then
    cat "$WORK/$1.manifest"
    echo "FAIL: ($1) the release APK does not query $LINK_PACKAGE"
    exit 1
  fi
  # Every run of hex long enough to be a digest counts, not only a run of 64, so a digest with a
  # character added or lost differs rather than dropping out of the comparison.
  pins=$(tr -d '\r' <"$WORK/$1.resources" \
    | awk '/string\/link_trusted_certs/ { found = 1; print; next } found && /resource 0x/ { found = 0 } found { print }' \
    | grep -Eo '[0-9a-fA-F]{16,}' | sort -u)
  if [ "$pins" != "$LINK_CERTS" ]; then
    grep -A 2 'link_trusted_certs' "$WORK/$1.resources"
    echo "FAIL: ($1) the release APK pins '$pins'; ADR 004 pins '$LINK_CERTS'"
    exit 1
  fi
  echo "ok ($1): the release APK exports .LinkService, queries $LINK_PACKAGE and pins ADR 004's two certificates"
}

echo "release-signing: the key named by environment variables"
export PRO_COMPANION_KEYSTORE="$KEYSTORE"
export PRO_COMPANION_KEYSTORE_PASSWORD="$PASSWORD"
export PRO_COMPANION_KEY_ALIAS="$ALIAS"
export PRO_COMPANION_KEY_PASSWORD="$PASSWORD"
build_and_verify environment

# #33: -PlinkDebugCerts is how a developer's machine pins its own race-timer. Only a debug build may
# hear it, so check_link must still read ADR 004's two here. The throwaway digest stands in because
# it is a well-formed digest that no ADR row can name. It goes in as a flag: measured on #33, set as
# ORG_GRADLE_PROJECT_linkDebugCerts it did not reach this build, and this stage passed with the read
# moved into the release block.
echo "release-signing: a debug pin passed to the build"
DEBUG_PIN_ARG="-PlinkDebugCerts=$EXPECTED"
build_and_verify debug-pin
DEBUG_PIN_ARG=
for v in $VARIABLES; do unset "$v"; done

echo "release-signing: the key named by $KEY_PROPERTIES"
WROTE_KEY_PROPERTIES=1
printf 'storeFile=%s\nstorePassword=%s\nkeyAlias=%s\nkeyPassword=%s\n' \
  "$KEYSTORE" "$PASSWORD" "$ALIAS" "$PASSWORD" >"$KEY_PROPERTIES"
build_and_verify key.properties
