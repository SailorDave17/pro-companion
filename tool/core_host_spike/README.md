# core_host_spike

The spike behind pro-companion **ADR 003** (the core host), built for issue #14. It is a separate
app on purpose. The real host is built in the local-core stories (#24, #32), using the model this
spike proved.

| what | where |
|---|---|
| Foreground service (`location`) owning a headless FlutterEngine | `android/app/src/main/kotlin/.../CoreService.kt` |
| Activity: runtime permissions, then starts the service while visible | `android/app/src/main/kotlin/.../MainActivity.kt` |
| Headless Dart entry point `coreMain` (no widget tree) and the UI | `lib/main.dart` |
| Criterion 2 and 3 instrumented tests | `android/app/src/androidTest/kotlin/...` |
| Runs both tests, revoking permissions first | `run_tests.sh` |
| Criterion 1: 30 min in forced Doze, activity destroyed, plus port round trips | `doze_run.sh` |

`ADB=path/to/adb sh run_tests.sh` and `ADB=path/to/adb sh doze_run.sh 30`, with one device or
emulator attached.
