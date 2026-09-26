# ADR 006 — Sync runs inside the headless core engine: pure-Dart `supabase`, in a package of its own

- Status: proposed 2026-09-26, on measurement (#47); accepted when its PR merges
- Builds on: pro-companion ADR 001 (the UI never calls the network; sync is the core's), ADR 003
  (the core host: a `location` foreground service owning a headless engine that runs `coreMain`)
  and ADR 005 (the companion's own Supabase project; device handoff signs a phone in anonymously,
  and `admit_device` admits it)
- Evidence: `tool/core_host_spike/`: the client in `sync/`, the run in `sync_run.dart`, and the
  runs in `results/2026-09-26-sync-run-3600s.txt` and `results/2026-09-26-sync-run-60s.txt`

## Context

Every sync story, #6 first, assumes the headless core engine can host the Supabase client. The
UI engine cannot host it (ADR 001), and a client that needs an activity would die with the UI
(ADR 003). `supabase_flutter` is the obvious client and the wrong one here. 2.17.2 depends on
`shared_preferences`, `app_links` and `url_launcher`, all Flutter plugins, and ADR 003 requires
every plugin in the core to be proven without an activity. So #47 asked whether the pure-Dart
`supabase` package, with a session store of our own, can do the whole job with the activity
destroyed:
- sign in and be admitted;
- write through RLS;
- resume after the process is killed;
- refresh an expired token.

## Decision

1. **Sync runs in the core engine**, the one `coreMain` runs in, and never in the UI's.
2. **The client is package `supabase`, pinned, and never `supabase_flutter`.** The spike measured
   2.16.1 (`gotrue` 2.27.2). No package it pulls in is a Flutter plugin: the spike build's
   generated plugin registrant registers nothing.
3. **The sync package owns the session.** It writes the session's JSON to a file in app-private
   storage on every auth change. It writes a temporary file and renames it, so a kill mid-write
   leaves the previous session rather than half of one. When the engine starts, it calls
   `recoverSession` on that file. `autoRefreshToken` stays on, as it is by default. With it off,
   gotrue 2.27.2's `recoverSession` signs out an expired session instead of refreshing it (read
   from its source, not measured).
4. **Package layout**, proposed for the story that builds sync (#6):

   | package | may import | must not import |
   |---|---|---|
   | `packages/core` (`pro_companion_core`) | as today | Flutter, `dart:io`, `package:http`, `package:supabase`, and **`package:pro_companion_sync`**: sync depends on the core, never the reverse |
   | `packages/sync` (`pro_companion_sync`, new) | `package:supabase`, `dart:io`, `pro_companion_core` | `package:flutter/`, `dart:ui`, so it stays runnable headless and testable with `dart test` |
   | `lib/` (UI) | the core's interface | as today, and **`package:pro_companion_sync/`** |
   | `lib/core_host.dart` (new, #32) | core, sync, and the host's method channel | widgets |

   The headless entry point, `coreMain`, is the one composition root that wires core and sync.
   It gets a file of its own, which #32 starts with `DartEntrypoint(bundle, libraryUri,
   "coreMain")`, and it is the one file under `lib/` exempt from the new UI rule. **Today's UI rule
   has a gap this closes.** It forbids `package:supabase` by prefix, so a `package:pro_companion_sync/`
   import in a screen would pass it and reach the network one package removed.
5. **The main manifest needs `INTERNET`.** Only the debug and profile manifests carry it (the
   Flutter tool adds it for development), in the app as in the spike. A release build would have
   no network: this is reasoned, not measured, since the spike ran a profile build. Add it in the
   first story that ships a network call (#6, or #71 if it lands first).

## Measured

On an API 34 `google_apis` x86_64 emulator (Pixel 5 profile, the image CI uses), with a profile
build, against the local stack started from `supabase/migrations/`. The phone reached the stack at
its own 127.0.0.1 over `adb reverse`. Three runs of `sync_run.dart`:

- **run 1:** `jwt_expiry` 3600, criteria 1–3;
- **run 2:** `jwt_expiry` 60, every criterion, whose 4b control failed, below;
- **run 3:** `jwt_expiry` 60, every criterion, all passing.

Runs 1 and 3 are committed.

| # | criterion | verdict | evidence |
|---|---|---|---|
| 1 | signs in anonymously and calls `admit_device` with the activity destroyed; round trip recorded | **pass** | 0 activities after BACK and after the admission. Anonymous sign-in took 470 / 103 / 51 ms (runs 1 / 2 / 3). `admit_device`'s first call took 662 / 165 / 137 ms. Then 20 repeats: p50 13.9 / 11.7 / 11.6 ms, p95 28.2 / 16.7 / 21.0 ms. The server's admission row is the phone's anonymous user, as `overall_pro`. |
| 2 | RLS takes a fleet on its own event and refuses another club's | **pass** | Own event: inserted. Another club's event: `42501`, "new row violates row-level security policy for table fleet". The server then held 1 fleet on the phone's event and 0 on the other club's. |
| 3 | after a kill, `coreMain` restarts with no UI and resumes the same user without signing in | **pass** | `kill -9` as root, standing in for the low-memory killer. The system logged "Scheduling restart of crashed service … in 1000ms for start-requested", and the core was back 1.5–2.2 s after the kill with 0 activities. It `RESUMED` the same user from its file in 7–14 ms, with no network call while the token was unexpired, then wrote as that user. Anonymous users and the user's auth sessions were unchanged. Killed again after three refreshes (run 3), it resumed on the last-rotated token, so each rotation had reached the file. |
| 4 | with `jwt_expiry` shortened, a write after expiry refreshes inside the engine and succeeds | **pass** | (a) The client's own ticker, as shipped, refreshed twice in 60 s, and a write went through. (b) With the ticker stopped, standing in for a CPU asleep through every tick, the expired token was presented directly as a control: 200 at 5 s past `exp`, 401 at 40 s past. The write then started on the expired token, refreshed on the way (new `iat`) and succeeded in 208 ms. |
| 5 | the client in a separate sync package; #24's rule still holds; layout recorded | **pass** | The client is `tool/core_host_spike/sync` (`core_host_spike_sync`), and the spike's `coreMain` imports only that. `test/import_boundary_test.dart` passes 4/4. With the client's file copied into `packages/core/lib/src/`, exactly 1 test went red, naming `dart:io` and `package:supabase` (predicted before the run); reverted, 4/4. Layout: decision 4. |
| 6 | pass or fail per criterion; alternatives on any failure | **pass** | This table. No criterion failed, so no alternative host is proposed. The ones considered are below. |

**Run 2's 4b failed in the control, not in the engine.** Its probe went at 5 s past `exp` and
read 200, because the server was still taking the token. The write had already refreshed,
because gotrue treats a token as expired 30 s before its `exp` (`Constants.expiryMargin`, read
from its source). Run 3 added the 40 s probe. So
the server takes a token for a while after its `exp`: measured, somewhere between 5 and 40 s.
Anything that reasons about token expiry must not assume a 401 at `exp`.

## Also measured (not criteria)

- **Refresh-token reuse**, with the local stack's rotation on and a 10 s reuse interval:
  - The **parent** of the active refresh token, presented 15 s after its rotation, read 200. The
    live session carried on. That is the case of a phone killed between a refresh and its session
    write, or of a refresh response lost on the water.
  - A **grandparent**, two rotations back, read 400 `refresh_token_already_used`, and it cost the
    whole session. The live session's next refresh signed the phone out, and its next write was
    refused. On the device-handoff path, that means a new anonymous user who must be admitted again
    with a code.

  So a phone must never refresh from a copy more than one rotation old. The session file,
  rewritten on every change, keeps the lag at one at most. #6 must keep it that way, for example
  by never caching the session anywhere else. The live project's rotation and interval were not
  read here.
- **`recoverSession` on an unexpired session emits `tokenRefreshed` without a refresh**: the
  event arrives with the token's `iat` unchanged. Counting refreshes by that event over-counts.
- **After the system restarts the service**, `dumpsys` shows it foreground again, with type
  `location` (0x8) and `mAllowWhileInUsePermissionInFgsReason=PROC_STATE_TOP`, as before the kill.
  So the restart did not throw on the background start. Whether GPS fixes flow after a restart
  with no UI is **not** measured, since the spike takes none. #32 and #21 own it.

## Limits

- **An emulator on loopback is not a venue.** The round trips measure the engine, the client and
  the stack, not a phone on cellular at a club. The first call's cost (connection and JIT warm-up)
  is the one to watch in the field.
- **The CPU never sleeps on an emulator** (ADR 003). Arm 4b stands in for a sleeping phone by
  stopping the ticker. The real clock behaviour is #21's.
- **Offline refresh was not tried.** Signal lost with a token expired, and the retry when it
  comes back, belong to #6. So does whether gotrue's retry of a lost refresh stays within the
  parent case.
- **`kill -9` as root stands in for the low-memory killer.** A force-stop (Settings, or `am
  force-stop`) cancels the sticky restart, so the core stays down until the UI starts it again.
  That is Android's rule, not measured here.

## Alternatives considered

None was needed, since nothing failed. For the record:
- **`supabase_flutter` in the core engine.** Rejected: it brings three plugins to prove
  headless (decision 2), and its session store is `shared_preferences`, one more plugin between
  the core and its own state.
- **Sync in the UI engine.** Rejected by ADR 001, and it would die with the activity.
- **Native sync in the service**, with supabase-kt in Kotlin. Rejected: it means two languages for
  one envelope and one hash chain (`docs/event-chain.md`), and a platform-channel hop for every
  event.

## Kill condition

**Reopen this ADR if, on the club phone (#21), an admitted phone's session is lost during a
day**, meaning a new anonymous user appears for a phone admitted that morning. The first suspect is
a refresh from a copy more than one rotation old, not the host.
