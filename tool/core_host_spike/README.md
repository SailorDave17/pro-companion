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

## The sync client (#47, ADR 006)

#47 extended the spike with a Supabase client in the headless core, to settle where sync runs
before any sync story builds on it. The verdict and the measurements are in
`docs/adr/006-sync-in-the-core-engine.md`.

| what | where |
|---|---|
| The client: pure-Dart `supabase`, its session kept in a file, and the commands the core runs | `sync/lib/sync.dart` (package `core_host_spike_sync`) |
| `coreMain` hands every `sync:` intent to it, and opens it again on each start | `lib/main.dart` |
| The run: two clubs provisioned, then every criterion, read back from logcat and the database | `sync_run.dart` |
| The runs committed: `jwt_expiry` 3600 (criteria 1–3), and 60 (all, plus the reuse probe) | `results/2026-09-26-sync-run-*.txt` |

From the repo root, with the local stack running and one `google_apis` emulator attached (not
`google_apis_playstore`, which refuses `adb root`):

```sh
ADB=path/to/adb dart run tool/core_host_spike/sync_run.dart [--skip-build] [--reuse-probe] [--out file]
```

Criterion 4 needs short tokens. Set `jwt_expiry = 60` in `supabase/config.toml`, restart the
stack (`npx --no-install supabase@2.117.0 stop`, then `sh scripts/start_local_stack.sh`), run, and
put it back. The run reads the token lifetime from its first sign-in and skips criterion 4 when
the lifetime is over 120 s. Afterwards, reset the stack's database (`db reset --local`): the run's
clubs, users and fleets otherwise stay in the shared stack.

Commands reach the running service as `am startservice … --es payload sync:<base64url JSON>`
from a root shell, because the service is not exported. The phone reaches the stack at its own
127.0.0.1 over `adb reverse`. No line the run writes carries a key, a token or an admission code.
