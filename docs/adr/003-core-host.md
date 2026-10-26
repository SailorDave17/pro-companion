# ADR 003 — The core host: a `location` foreground service owning a headless Flutter engine, reached over an isolate port

- Status: accepted 2026-09-23, on measurement (#14)
- Builds on: pro-companion ADR 001 (the local core, UI never calls the network) and ADR 002 (the
  store is package:sqlite3, which is synchronous and wants to live off the UI isolate)
- Evidence: `tool/core_host_spike/` (service, headless entry point, instrumented tests, Doze run)
- Amended 2026-10-06 by pro-companion #15 (ADR 004): a sticky restart of the host is refused when
  another component starts the process first, and the host as written then crash-loops. See
  "Consequences and limits".
- **Kill condition fired 2026-10-07 on the club phone (#21)**: with the screen off and nothing
  holding a wake lock, the core's 10-second tick ran minutes late. See "Kill condition".
- **Built 2026-10-23 by #32**, with three owner decisions at pickup that amend decisions 1, 5 and
  the kill condition's answer. See "Built (#32)".

## Context

ADR 001 puts every race-time action into a local core. The core has to keep running with the
screen off and the app closed: a mark-boat volunteer's phone is in a pocket, and GPS, race-timer
events and sync must carry on. If the core lived in the widget tree, it would die with the
activity, and moving it out after feature stories exist would move all of them. So where the core
lives, and how the UI reaches it, is fixed first.

## Decision

1. **Host.** An Android **foreground service** (`CoreService`) owns its own `FlutterEngine`. The
   engine runs a separate Dart entry point, **`coreMain`**, annotated
   `@pragma('vm:entry-point')`, with **no widget tree**. The service starts it with
   `DartExecutor.executeDartEntrypoint`. The activity has its own engine for the UI. Destroying the
   activity destroys only the UI engine.
2. **Service type: `location`**, started with `FOREGROUND_SERVICE_TYPE_LOCATION`.
3. **UI ↔ core: an isolate port.** The core registers a `SendPort` with `IsolateNameServer` under
   a fixed name. The UI looks it up and sends `(replyPort, message)` records. Both engines are in
   one process, so they share one Dart VM, and the port needs no platform-channel hop. The core is
   a separate isolate, so SQLite's synchronous calls (ADR 002) never block a frame. The local core
   (#24) exposes only this async message interface to the UI.

   **Messages must be plain data.** The two engines are separate *isolate groups*, and a message
   between groups may carry only primitive values: null, num, bool, String, List, Map, `SendPort`
   and typed data. *Measured*: sending a Dart record `(SendPort, 0)` threw `Invalid argument: is
   a Record` at send time, and the first draft of this spike failed that way. So the core's
   interface is a small wire protocol (`[replyPort, command, args…]` of primitives), with typed
   Dart wrappers on each side. Event envelopes cross as their JSON-ready maps (ADR 001's envelope
   already is one).
4. **Platform → core: a method channel on the service's engine** (`core_host/intents`). Intents
   delivered to the service are forwarded to Dart. They are **queued in the service until Dart
   reports ready**, because a message sent before the Dart handler exists is dropped. The
   race-timer link (#15) arrives this way.
5. **Start sequence.** While the app is visible, the activity asks for **POST_NOTIFICATIONS**
   (Android 13+) and **ACCESS_FINE_LOCATION** ("While using the app"), then calls
   `startForegroundService`. The service posts an ongoing notification ("PRO Companion is
   running").

### The main manifest must declare

```xml
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<service android:name=".CoreService" android:exported="false"
         android:foregroundServiceType="location"/>
```

`ACCESS_BACKGROUND_LOCATION` is **not** needed, because the service is always started while the
app is visible.

## Why `location` and not the alternatives

Checked against Android's documentation on 2026-09-23:

- **`dataSync`, rejected.** From Android 15, *"The system permits an app's `dataSync` services to
  run for a total of 6 hours in a 24-hour period"*. After that the system calls `onTimeout`, and a
  service that doesn't stop crashes the app. A regatta day can exceed that, and so can a three-day
  event summed per 24 hours.
- **`specialUse`, rejected.** Its use case is *"reviewed when you submit your app in the Google
  Play Console"*, which is an approval risk with no benefit here.
- **`location`, chosen.** It has no documented timeout. The core needs GPS anyway, since every
  event is GPS-stamped (ADR 001). Its constraint: it *"cannot [be created] while your app is in the
  background"* without background location. Hence decision 5: start it from the visible activity.

### Rejected: one engine shared by UI and core

The activity attaching to the service's engine (via `FlutterEngineCache`) would put the core in
the UI isolate. SQLite work would then compete with frames, and the core's entry point would need
a widget tree. Two engines in one process cost memory, but the isolate port makes them cheap to
connect.

## Measured (emulator, Pixel 9 API 36 x86_64, 2026-09-23)

- **Criterion 1: headless core in forced Doze, activity destroyed.** Profile build, `doze_run.sh 30`:
  **180 of 180 ticks** in 30 minutes, every gap **10.00 s** (none over 11 s). Deep idle was `IDLE` at
  the start and the end, 0 activities remained, and the service kept running
  (`tool/core_host_spike/results/2026-09-23-doze-run.txt`). An earlier run on the pre-fix build
  also gave 180/180; the rerun is on the committed code.
- **Criterion 2: an intent reaches the headless core after the activity is destroyed.**
  `IntentReachesHeadlessDartTest` (instrumented) passes.
- **Criterion 3: first start requests POST_NOTIFICATIONS and shows the ongoing notification.**
  `NotificationPermissionTest` passes from a revoked state. It clicks through the real system
  dialogs and finds the notification with `FLAG_ONGOING_EVENT`.
- **UI → core port round trip**, 1,000 sequential pings in a profile build, four rounds:
  **p50 0.98–1.05 ms, p95 2.99–3.10 ms, max 5.9–12.4 ms.** Added to ADR 002's store p95 (2.4 ms),
  a UI action reaches a confirmed append in about 5 ms at p95, far inside the 100 ms bar.
- **The tests were proven able to fail**, with the red count predicted before each run:

  | mutation | red |
  |---|---|
  | stop requesting POST_NOTIFICATIONS | the notification test only |
  | the activity stops the service in `onDestroy` | the intent test only |
  | the service stops forwarding intents | the intent test only |

## Consequences and limits

- **The emulator cannot show CPU suspension.** Forced Doze on an emulator changes the scheduler's
  state, but the host CPU never sleeps. A foreground service is exempt from Doze's app restrictions
  but does **not** hold the CPU awake. On a real phone a Dart `Timer` may drift or bunch while the
  CPU sleeps, until location updates (the real workload) or a partial wake lock wake it. The
  10-second cadence here proves the host model, not phone timing. **#21 measures it on the club
  phone**, and if ticks drift there, the fix is a `PARTIAL_WAKE_LOCK` held by the service while a
  race is running, recorded as an amendment here.
- **Permission dialogs are ordered by Android.** On API 36, location was asked before notifications
  whatever order the app requested them in, and the controller is
  `com.google.android.permissioncontroller` on Play images. UI tests match by id suffix and accept
  any order.
- **Plugins in the headless engine.** Any plugin the core uses must work without an activity. #24
  checks that for each one it adds.
- **A sticky restart is refused when something else starts the process first** (amended
  2026-10-06, #15, measured on the Pixel 9 API 36 emulator by
  `tool/core_host_spike/link_kill_probe.sh`). After a `kill -9` with nothing else running, the
  system restarted `CoreService` and the core wrote `START` 1.5 s later, as #47 measured on API 34.
  The probe then sent a race-timer link event right after the kill. The event started the process,
  for the link's receiver, service or provider, before the pending restart, which then ran in that
  process as a background start. `startForeground(…, LOCATION)` was refused, as
  `ForegroundServiceStartNotAllowedException` or as a `SecurityException` on the `location` type.
  `onCreate` does not catch it, so the process crashed. After quick repeat crashes, the system either
  gave up on the service or scheduled its next restart 30 minutes out, and every restart in between
  was refused the same way (`results/2026-10-06-link-kill-probe.txt`). **The real host (#32) must catch a refused `startForeground`,
  stop itself and leave the process running**, so anything else in it can answer for itself. Any
  exported component in the core host's process is a way in, not only the link.

## Kill condition

**Reopen this ADR if, on the club phone (#21), the headless core misses more than one 10-second
tick in 30 minutes with the screen off**, or if an intent sent with the activity destroyed fails to
reach it. The first answer is a wake lock, not a new host.

### Fired, 2026-10-07 (#21)

On the club phone (Samsung Galaxy S23 Ultra, Android 16, One UI 8.5, retail build), the spike's
profile build was started with its activity destroyed, then unplugged with the screen off, in a
pocket. Nothing else on the phone held a wake lock for it. The owner took one phone call during
the run, so the two untouched windows are scored separately
(`tool/core_host_spike/results/2026-10-07-club-phone-tick-run.txt`):

| window | ticks / expected | longest gap | gaps over 30 s |
|---|---|---|---|
| screen off, 21.5 min | 17 / ~128 | 279 s | 14 |
| screen off, 10.7 min | 9 / ~63 | 232 s | 6 |
| the call, screen on, 1.4 min | 8 / ~8 | 10 s | 0 |

**The host lived; its timer did not run.** The process kept one pid from start to readback, its
service stayed in the foreground, and nothing killed or froze it. With no wake lock the CPU
suspended, and a Dart `Timer` fires only when something else wakes the phone. A foreground service
keeps a process alive, not a CPU awake. The emulator could not show this (see "Consequences and
limits"): there, 180 of 180 ticks arrived in 30 minutes of forced Doze. The call cannot have caused
the failure. A woken CPU only adds ticks, and the first window, before the call, already fails.

The intent half of the condition did not fire. Every race-timer link event in #21's three runs
reached the core (152 of 152; ADR 004 has the clean one), but the harness holds a wake lock for its
run, as race-timer's sequence does.

That wake lock also shows what the first answer would do. In the clean link run, with the screen
off and the phone unplugged, the core's tick ran 180 times in 29.9 minutes, against about 179
expected, and never gapped more than 10.2 s. In the 5 minutes after the harness released its lock,
it ran 3 times against about 31, with gaps up to 104 s
(`tool/core_host_spike/results/2026-10-07-club-phone-link-run3.txt`). A binder event every 36 s
alone would have left gaps near 36 s, so it was the lock that kept the CPU awake. That lock belonged
to another process, so it shows the mechanism works, not what the core host's own lock will cost.

This is what "Consequences and limits" predicted a real phone might do. The spike requests no
location updates, so the other waker named there, the real host's GPS workload, is not measured
here.

So the decision is reopened at its first answer: a partial wake lock held by the core host. That has
not been tried yet. Its cost on a race day's battery is the measurement it needs.

## Built (#32), 2026-10-23

The host is in the app: `android/app/src/main/kotlin/com/procompanion/app/CoreService.kt`, and
`lib/core_host.dart` for its engine. The UI engine connects through `lib/core_bootstrap.dart`.

**What changed from the decisions above.** The first three bullets are owner decisions taken at
#32's pickup.

- **Without location the core still runs, but only while the activity lives** (amends decisions 1
  and 5). Android 14 refuses a `location` foreground service to an app holding no location
  permission. *Measured* on the API 34 emulator: `SecurityException: Starting FGS with type
  location … requires permissions … any of … ACCESS_COARSE_LOCATION, ACCESS_FINE_LOCATION`. So
  `MainActivity` binds `CoreService` for as long as it lives, and the core runs in the service
  whatever the user granted. The activity also starts the service, but only once location is
  held, and only then does the service go into the foreground and outlive the UI. Refused,
  every event says `no_permission` and still appends, as #31 had it, until the activity goes.
- **The wake lock is not in this host** (amends "Kill condition"). #127 measures it on this host,
  not the spike, and adds it. The spike requested no location updates. This host's feed asks for a
  high-accuracy fix every 5 s, and whether that wakes the CPU is part of what #127 now reads. Since
  #55 it asks twice: the fused request for the position, and a second, on the GPS provider every
  5 s, for the satellites' time, each fix a channel message to the host's engine. That the second
  costs no extra power because GNSS is already on is reasoned, not measured, so #127's readings
  cover both. Until #127 lands, a timer in this host stalls with the screen off, as #21 measured on
  the spike.
- **The location feed (#31) runs in the service**, on the host's engine, so an event appended with
  the UI gone carries a current fix. The activity's start of the service after a permission answer
  restarts the feed.
- **The activity calls `startService`, not `startForegroundService`.** `startForegroundService`
  obliges the service to call `startForeground` within seconds or Android stops the app. A refused
  start that the service survived by stopping itself would then still end the app (*reasoned*,
  from Android's documented contract, not tried). A plain start from a visible activity is allowed
  and carries no deadline. The service calls `startForeground` in `onStartCommand`, never in
  `onCreate`, because a bind alone must not try to go into the foreground.
- **A refused `startForeground` is caught.** The service stops itself and returns
  `START_NOT_STICKY`, and the process stays up. Unbound, the engine never starts, so an append that
  reached the process is answered `no_core`. *Measured* by `CoreHostRefusedTest` on the API 34
  emulator, with location revoked: three refusals, all caught, one pid throughout, and a second
  refused start was answered the same way. #15's own case, the sticky restart refused because a
  link event started the process first, cannot happen in the app yet: it has no exported component
  other than the launcher activity, and an activity start puts the app in the foreground. **#33
  adds one, so #33 re-runs `link_kill_probe.sh`'s case against this host**: the catch is the same
  code, but that it stops the crash loop there is still *reasoned*.
- **The entry point is found by library as well as name**:
  `DartEntrypoint(bundle, "package:pro_companion/core_host.dart", "coreMain")`, as ADR 006
  decision 4 proposed. In an integration test the root library is the test's own file, so a lookup
  by name alone finds no `coreMain` there. A library is compiled into a build only when something
  imports it, so `lib/core_bootstrap.dart`, which every route to the core goes through, re-exports
  it.
- **The UI waits for a port that answers.** The host publishes its port with `IsolateNameServer`
  under `pro_companion.core`. The name outlives the engine: when the activity goes with no location
  held, the service and its engine go, and the next activity in the same process finds the old
  port still published. `connectCore` pings a port with a device-id request and uses it only once
  it answers, so it waits until the next host publishes over it. Neither the UI nor any other
  client can close the host's core: the server refuses a close, and the UI's client sends none.
- **Appends by intent.** `ACTION_APPEND`, with the event's wire form as JSON and an optional
  `ResultReceiver` that hears `accepted` with the stored event, `refused` with the core's code, or
  `no_core`. The service is not exported, so only the app's own process can send one. An append
  that arrives before the engine says `ready` is queued, as decision 4 had it.
- **The notification** says "PRO Companion is logging", "Logging continues with the screen off.
  Tap to open.", and opens the app the way its launcher icon does. It is shown at once
  (`FOREGROUND_SERVICE_IMMEDIATE`), not after Android 12's ten-second grace.

**Measured on the API 34 emulator** (`pc47_api34`, `google_apis`, the image CI uses), each test
proven able to fail by a mutation with its red count predicted first:

- `CoreHostTest`: with location and notifications granted, an append sent by intent after the
  activity is destroyed is accepted, and read back from the log's own file. The notification is the
  foreground service's, and tapping it in the shade opens the app.
- `CoreHostRefusedTest`: as above, with location revoked.
- `integration_test/core_host.sh` runs both, and is a line in CI's `integration` job.
