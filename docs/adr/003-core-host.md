# ADR 003 — The core host: a `location` foreground service owning a headless Flutter engine, reached over an isolate port

- Status: accepted 2026-09-23, on measurement (#14)
- Builds on: pro-companion ADR 001 (the local core, UI never calls the network) and ADR 002 (the
  store is package:sqlite3, which is synchronous and wants to live off the UI isolate)
- Evidence: `tool/core_host_spike/` (service, headless entry point, instrumented tests, Doze run)

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

## Kill condition

**Reopen this ADR if, on the club phone (#21), the headless core misses more than one 10-second
tick in 30 minutes with the screen off**, or if an intent sent with the activity destroyed fails to
reach it. The first answer is a wake lock, not a new host.
