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

## The race-timer link (#15, ADR 004)

#15 extended the spike again, to pick how race-timer's sequence events reach the companion on the
same phone with the companion backgrounded and the screen off. The spike app is the companion:
three candidate endpoints hand each event to the headless core, which writes it as a `LINK` line.
A second, plain Kotlin app stands in for race-timer. **Verdict: a bound service**, which answered
every event, including `no_core` while the core host was down. The broadcast lost events silently
there, and a provider call blocked its caller. The numbers are in `docs/adr/004-race-timer-link.md`.

| what | where |
|---|---|
| The three endpoints: an explicit broadcast, a bound service, a content provider's `call()` | `android/app/src/main/kotlin/.../LinkEndpoints.kt` |
| Who may send: the pinned package, signed by a pinned certificate, judged at runtime | `.../LinkTrust.kt`, called first by `.../LinkInbox.kt` |
| The core's side: one `LINK` line per event, counted per run and de-duplicated by id | `lib/main.dart` (`LinkLog`) |
| The race-timer stand-in: a foreground service emitting a scripted day over one mechanism | `android/harness/` (package `com.procompanion.link_harness`) |
| Build, sign the harness with a trusted and an imposter key, install | `link_build.sh` |
| Criteria 1 and 2: 50 events per mechanism, backgrounded, then destroyed + forced Doze | `link_run.sh`, read by `link_report.dart` |
| Criterion 3: an imposter-signed harness is refused, a trusted one accepted | `LinkTrustTest` (instrumented), run by `link_tests.sh` |
| Beyond the criteria: each mechanism while the core host is down (killed), with a no-traffic control | `link_kill_probe.sh` (needs `adb root`) |
| The runs committed | `results/2026-10-06-link-run.txt`, `results/2026-10-06-link-kill-probe.txt` |

With one device or emulator attached, API 34 or later:

```sh
ADB=path/to/adb sh tool/core_host_spike/link_run.sh [count] [interval_ms]   # default 50, 5000
ADB=path/to/adb sh tool/core_host_spike/link_tests.sh
ADB=path/to/adb sh tool/core_host_spike/link_kill_probe.sh [count] [interval_ms]   # default 10, 500
```

**#21 on the club phone** runs the chosen mechanism only, at 50 events over 30 minutes, with the
phone screen-off in a pocket: `sh link_build.sh profile trusted`, start the core from the app, close
it, then `adb shell am start-foreground-service -n com.procompanion.link_harness/.EmitService --es
mech bound --ei count 50 --ei interval_ms 36000 --es run club-phone`, with
`adb logcat -v time -s LINK:V flutter:V > club-phone.log` running throughout. Then
`dart link_report.dart club-phone.log` reports it.

`link_build.sh` makes two throwaway keys under `build/link_keys/` on first use and builds the
companion with the trusted one's SHA-256 pinned. The harness is never signed with the companion's
key, because race-timer never will be. A run is started by hand with
`adb shell am start-foreground-service -n com.procompanion.link_harness/.EmitService --es mech
<broadcast|bound|provider> --ei count 50 --ei interval_ms 5000 --es run <id>`, and its `EMIT`,
`RECV`, `LINK` and `DONE` lines are read from logcat (tags `LINK` and `flutter`). The harness holds
a partial wake lock for the run, as race-timer's own sequence does, so on a real phone (#21) a gap
is the link's and not the stand-in's.
