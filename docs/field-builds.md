# Field builds — a release APK signed with the owner's upload key

- **Status: the signing path is built and proven with a throwaway key (#23). The owner's own key
  exists, and its builds installed on the club phone and updated there with the log intact (#27,
  2026-10-08).**
- Enforced by: `android/app/build.gradle.kts` (the signing config and `checkReleaseSigning`),
  `scripts/check_release_signing.sh` (run by the CI job `release-signing`), and
  `test/no_secrets_in_tree_test.dart`, which fails if a keystore or `key.properties` is ever tracked.

## Why a release build, and why one key

Every field session runs the build the pilot will ship (groom decision G20), so a phone on the water
never carries a debug build. And Android installs an update only when it is signed by the same key
as the build already on the phone. With one key, each new build installs over the last one and the
phone keeps its local event log.

## Where the key lives: outside the repo, always

The upload keystore and its passwords never enter git. Keep the keystore in a folder of your own,
such as `C:\Users\<you>\keys\`, and keep a backup copy offline. **Keep the password somewhere of its
own too**, such as a named entry in a password manager, and not beside the keystore: a backed-up
keystore whose password lived only in `android/key.properties` on one machine is as lost as no
keystore. Git ignores keystores and `key.properties` at any depth, copies such as
`key.properties.bak` included, and a test fails the CI gate if one is tracked anyway (`git add -f`
gets past an ignore rule).

**If the key is lost**, no phone will take a new build as an update. Each one has to uninstall
first, and uninstalling deletes that phone's local log.

## The field key

Made on 2026-10-08 (#27) as `pro-companion-upload.jks` in the owner's `~\keys\` folder, alias
`upload`, with the command in "Make the key", naming the certificate with `-dname`. Its
certificate:

- Certificate: `CN=Pro Companion Upload, O=SailorDave17`
- SHA-256: `8578eb0538b09db7f4df3284049591986aa32e5a338ee513f86e7c754bdc5506`

`apksigner` read that digest off a release APK, and `keytool -list -v` read the same one off the
keystore (as `85:78:EB:…`). race-timer pins it to trust the companion: pro-companion ADR 004's
table "race-timer trusts the companion" carries the same value, and
`test/field_key_doc_test.dart` fails if the two ever disagree. A new key changes both, and every
phone then has to uninstall first.

## Make the key (once)

```
keytool -genkeypair -v -keystore C:\Users\<you>\keys\pro-companion-upload.jks -storetype PKCS12 -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

`keytool` comes with the JDK. It asks for a password and a name for the certificate. A PKCS12
keystore has one password, which serves as the store password and the key password.

## Point the build at it

Either way works. For each value, the build reads the environment variable first and then
`android/key.properties`.

**`android/key.properties`** (untracked, beside `android/build.gradle.kts`):

```
storeFile=C:/Users/<you>/keys/pro-companion-upload.jks
storePassword=<the password>
keyAlias=upload
keyPassword=<the password>
```

Write the path with forward slashes, because a backslash is an escape character in a `.properties`
file: most backslashes just vanish, and `\upload.jks` stops every build, debug ones included, on
the `\u`. A relative `storeFile` is read from `android/`.

**Or four environment variables:** `PRO_COMPANION_KEYSTORE`, `PRO_COMPANION_KEYSTORE_PASSWORD`,
`PRO_COMPANION_KEY_ALIAS` and `PRO_COMPANION_KEY_PASSWORD`.

## Build, check, install

```
flutter build apk --release
```

The APK is `build/app/outputs/flutter-apk/app-release.apk`. If any value is missing, or the keystore
is not where it says, the build stops at `checkReleaseSigning` and names what is missing. It never
falls back to the debug keys. `flutter run --release` needs the key too.

**Check what signed it** with `apksigner`, from the SDK's build tools:

```
%ANDROID_HOME%\build-tools\36.1.0\apksigner.bat verify --print-certs build\app\outputs\flutter-apk\app-release.apk
```

Read `Signer #1 certificate SHA-256 digest`. Don't use `keytool -printcert -jarfile` on an APK. It
reads only the old v1 signature, so on a correctly signed APK it prints `Not a signed jar file`, and
still exits 0.

**Install it** on a phone connected by USB:

```
%ANDROID_HOME%\platform-tools\adb.exe install -r build\app\outputs\flutter-apk\app-release.apk
```

(The SDK sits under `%LOCALAPPDATA%\Android\Sdk` on this machine, and `ANDROID_HOME` names it. Use
whichever `build-tools` version is there.)

`-r` installs over the build already there and keeps its data, but only when both builds are signed
by the same key. A phone that holds a debug build (anything from `flutter run`, or the CI's debug
APK) refuses a release build as an update, and has to uninstall first, which deletes its local log.
*Measured on the club phone (#27)*: the debug APK over the release build failed with
`INSTALL_FAILED_UPDATE_INCOMPATIBLE`, and the release build stayed. So move a phone to release
builds before a race day, never after one whose events have not all reached shore.

**Keep the build number where it is.** Every field build so far is `0.1.0+1`, and `-r` takes a later
build at the same build number (#27 did exactly that). Android refuses a *lower* build number than
the one installed, and a retail phone will not let `-d` override that for a release build, so a phone
that once took a `--build-number=2` build would refuse every `+1` build after it until uninstalled
(*reasoned*, not tried on the club phone). Raise it only when every later build will be higher too.

## What CI proves, and what it cannot

The `release-signing` job runs `sh scripts/check_release_signing.sh`. With no key, the release
build must fail and name all four variables. With a throwaway keystore made inside the job, named
first by the variables and then by `android/key.properties`, `apksigner` must report that
keystore's certificate and no other. CI never sees the owner's key. That the real key signs, and
that a second build installs over the first on the club phone, was #27, shown by hand on
2026-10-08. The PR for #27 carries the readings.
