# ADR 002 — The local store: SQLite (package:sqlite3), append-only enforced by the engine

- Status: accepted 2026-09-23, on measurement (#13)
- Builds on: pro-companion ADR 001 (the local core owns an append-only event log; its first kill
  condition reopens "its storage choice", and until now no choice existed)
- Evidence: `tool/store_bench/` (harness, fixture, results), rerunnable with the commands below

## Context

ADR 001 puts every committee action into an append-only event log on the phone, answered within
the 100 ms bar. A store had to be chosen on measured latency at end-of-day volume, not on
preference. The UI must feel instant and a race day must never lose an acknowledged event.

## Method

- **Volume.** `tool/store_bench/fixtures/pilot_day.json` sizes one phone's store for the whole
  committee, with every parameter justified from the pilot scope:
  - 5 devices, 3 fleets × 20 boats × 4 races;
  - roundings, finishes and sail assignments, sequence events, 5% undo corrections;
  - notes, a wind log, GPS tracks, safety events;
  - **3,028 events per day**, and **9,084 retained** over a three-day regatta with no purge.
  
  The generator is deterministic and its counts are checked against hand arithmetic in
  `test/bench_test.dart`.
- **Envelope.** The ADR 001 envelope: ULID, per-device sequence number, device, person, kind,
  device time, GPS, and a SHA-256 hash chained to the device's previous event, plus a payload.
- **Latency.** Each store is filled to 9,084 events. Then 1,000 further appends are timed, each
  **followed by a read-back by ULID** and a hash comparison, so a write that did not happen fails
  the run rather than timing fast. p50, p95 and max come from nearest-rank percentiles.
- **Build and device.** Profile build (AOT) on an Android emulator, Pixel 9, **API 36, x86_64**.
  Flutter 3.44.9, the version CI pins. Profile mode was measured to run on this emulator.
- **Mutation.** An UPDATE and a DELETE of a stored event are attempted against each store, to see
  whether the store can refuse them itself.
- **Durability.** For the chosen engine only: `tool/store_bench/crash_test.sh` force-stops the app
  mid-append six times, and each relaunch checks that every event acknowledged before the kill is
  present, with each device's sequence contiguous and its hash chain unbroken.

## Results

Two runs, `tool/store_bench/results/2026-09-23-emulator-run{1,2}.json`. Latency is
append-and-read-back per event, in ms.

| store (version) | p50 run1 / run2 | p95 run1 / run2 | max run1 / run2 | fill 9,084 events | on disk | refuses UPDATE / DELETE itself |
|---|---|---|---|---|---|---|
| **sqlite3 3.0.0** (WAL, synchronous=FULL) | 0.86 / 0.90 | **2.33 / 2.45** | 6.05 / 6.51 | 11.3 s / 11.5 s | 5.2 MB | **yes / yes** (triggers: `RAISE(ABORT)`) |
| hive_ce 2.20.0 | 0.94 / 0.95 | 2.54 / 2.70 | 5.53 / 6.03 | 10.9 s / 10.6 s | 4.2 MB | no / no |
| sembast 3.8.11 | 3.80 / 3.53 | 6.35 / 6.25 | 10.04 / 9.80 | 36.0 s / 34.6 s | 4.5 MB | no / no |

**Every candidate passes the bar by more than an order of magnitude on the emulator.** The two
runs agree within about 5% on every figure.

**Durability (sqlite3):** 6 of 6 force-kills lost nothing acknowledged. Several relaunches found
one event *more* than the last acknowledgement, a commit that landed just before the kill cut off
its print, which is the safe direction. The harness was proven able to fail: with appends
acknowledged inside a transaction that is never committed, it reported **LOST on 6 of 6 cycles**
and FAIL, as predicted before the run.

## Decision

**SQLite through package:sqlite3**, with:
- `journal_mode=WAL` and `synchronous=FULL`;
- a `STRICT` events table keyed by ULID, with `UNIQUE (device_id, seq)`;
- `BEFORE UPDATE` and `BEFORE DELETE` triggers that raise, so **the append-only rule is enforced by
  the engine** and not only by core code.

Latency does not decide it, since all three pass. Two things do:

1. **Only SQLite can refuse an edit or a delete itself.** hive_ce and sembast accept both, so the
   core would have to be the only guard. For a log whose value is being protest-grade, a guard the
   engine enforces is worth more than a guard every future code path must remember. It is also
   the same shape as the server's append-only rule (burgee#7), which keeps the two halves of ADR
   001 speaking one language.
2. **SQL answers the reads the pilot needs** without a second index layer: per-device chain order,
   per-fleet standings, and "what has not reached shore". Both key-value stores would need hand-kept
   secondary keys for these.

### Rejected

- **hive_ce 2.20.0.** Latency is statistically tied with SQLite (p95 2.54–2.70 ms). Rejected
  because it cannot refuse a mutation (a `put` over an existing key and a `delete` both succeed),
  and it has no query layer for the reads above.
- **sembast 3.8.11.** It passes (p95 6.25–6.35 ms), but it is about 2.6× slower per append and about
  3.2× slower to fill, and it cannot refuse a mutation either.
- **Not measured:** ObjectBox and isar_community (no release since May and March 2026
  respectively), drift (an ORM over the same SQLite engine, so its engine latency is this one; any
  typed-query layer is the local core's choice in #24), and sqflite (the same engine behind a
  method channel).

## Consequences

- **The version is capped by Flutter.** `sqlite3` 3.6.0 is current, but Flutter 3.44.9 pins `meta`
  1.18.0, which `hooks` ≥ 2.2 (needed by sqlite3 ≥ 3.6) cannot use. So **3.0.0 is the newest version
  this toolchain resolves**. Upgrading Flutter lifts the cap, and the harness reruns the numbers.
  `sqlite3_flutter_libs` is **end-of-life** (`0.6.0+eol`); sqlite3 3.x bundles SQLite through Dart
  build hooks, and nothing else is needed. It built on Android and on the Windows host with no
  extra setup.
- **package:sqlite3 is synchronous.** Its own README recommends running it off the UI isolate. The
  benchmark ran it in one isolate. Where the core lives is ADR 003's decision (#14), and the local
  core (#24) calls the store only through the async core interface.
- **synchronous=FULL was tested against process death, not power loss.** A force-kill leaves the OS
  page cache intact, so this harness cannot tell FULL from NORMAL or OFF. Power-loss durability
  rests on SQLite's documented WAL guarantee and is **not measured here**.
- **The emulator is not the club phone.** An x86_64 emulator on a desktop disk says nothing about
  a mid-range phone's flash. The club-phone numbers are #21's, run with this same harness.

## Kill condition

**Club-phone p95 above 100 ms reopens this ADR.** Measured by #21 with
`tool/store_bench/integration_test/benchmark_test.dart` at the fixture's volume. Also reopen it if
the local core (#24) finds a read the pilot needs that SQLite cannot answer within the bar at that
volume.

## Rerun

```
cd tool/store_bench
flutter test                                    # generator, chain, stores: 12 tests
flutter drive --profile --driver=test_driver/integration_test.dart \
  --target=integration_test/benchmark_test.dart -d DEVICE_ID   # -> build/integration_response_data.json
ADB=path/to/adb sh crash_test.sh 6              # force-kill durability, sqlite3
```
