# ADR 004 — The race-timer link: a bound service answering every event, with the caller judged by package and certificate

- Status: proposed 2026-10-06, on measurement (#15); accepted when its PR merges
- Builds on: pro-companion ADR 001 ("The race-timer link": race-timer signals and the companion
  logs, the mechanism is picked by a spike, manual gun-time entry is the fallback, and the link
  carries a kill condition) and ADR 003 (the core host: a `location` foreground service owning a
  headless engine, which platform code reaches over the service's method channel)
- Evidence: `tool/core_host_spike/`, its race-timer stand-in in `android/harness/`, the runs in
  `results/2026-10-06-link-run.txt` and `results/2026-10-06-link-kill-probe.txt`, and the
  instrumented `LinkTrustTest`
- Built by: race-timer#294 (the emitter) and pro-companion #33 (the receiver). Field-checked by #21
  (the harness on the club phone) and #34 (the real race-timer on the club phone)

## Context

Scope decision 2: race-timer owns the start sequence and the companion logs it. Both run on the
same phone. race-timer exposes no interface to other apps today: its phone manifest exports only the
launcher activity (race-timer#294's filing note). So the link is new work on both sides, and it has
to deliver while the companion is in the background with the screen off: the phone is in a pocket,
and Doze is the normal state.

**The two apps will not share a signing key.** race-timer reaches the club phone through Google
Play, which re-signs it with Play's app-signing key; its phone app is on Play's internal track
today. The companion is sideloaded, signed with the owner's upload key (groom decision G20, #27).
A `signature`-level permission needs one signer on both sides, so it would refuse race-timer on
the club phone with no error anywhere, while passing every test run on a development machine,
where both apps carry the same debug key.

## Options measured

Three mechanisms, each driven by a stand-in for race-timer (the harness: a plain Kotlin app emitting
from a foreground service, as race-timer runs its sequence) into the core host spike, which plays
the companion. Each event goes through the same entry point (`LinkInbox`), which judges the caller
and then hands the event to the headless core. The core writes one line per event and counts
distinct event ids per run, so a lost log line cannot hide a delivery and a duplicate cannot pass
as one.

- **Broadcast**: an explicit-package broadcast (`setPackage`, since Android 8 stopped implicit
  broadcasts reaching manifest receivers) to a manifest receiver, flagged
  `FLAG_RECEIVER_FOREGROUND`. No answer reaches the sender.
- **Bound service**: race-timer binds once per run and sends one binder transaction per event. Each
  transaction returns a status.
- **Content provider**: `ContentResolver.call(content://…link, "event", json)`, one call per event,
  returning a Bundle with the status. There is no connection to manage.

### Criteria 1 and 2: 50 events per mechanism

Measured on the Pixel 9 API 36 emulator (`google_apis`, x86_64), on a profile build of the committed
tree (`results/2026-10-06-link-run.txt`). Each run was 50 events, 5 s apart, from the harness's
foreground service.

- **Criterion 1:** the companion backgrounded (HOME, screen on).
- **Criterion 2:** its activity destroyed (none left, the core service running), the screen off
  and the device forced into Doze. Deep idle read `IDLE` before and after every run, and the
  harness read `isDeviceIdleMode()` as true at all 150 of its emissions.

| mechanism | stored, crit. 1 / crit. 2 | emit → endpoint, µs: p50 / p95 / max, crit. 1; crit. 2 | emit → core, ms: p50 / p95 / max, crit. 1; crit. 2 |
|---|---|---|---|
| broadcast | 50 of 50 / 50 of 50 | 2,270 / 3,048 / 25,322; 2,386 / 3,609 / 6,832 | 5 / 6 / 90; 5 / 6 / 6 |
| bound service | 50 of 50 / 50 of 50 | 457 / 725 / 5,352; 418 / 750 / 4,168 | 2 / 6 / 8; 2 / 3 / 4 |
| content provider | 50 of 50 / 50 of 50 | 1,428 / 1,823 / 3,697; 1,555 / 2,057 / 2,994 | 3 / 4 / 7; 3 / 4 / 4 |

"Stored" counts distinct event ids the core wrote, and no run had a duplicate. An earlier run the
same day, on the tree before its last edits, also stored 300 of 300. Every mechanism is far inside
the 100 ms bar, and the bound service reaches its endpoint fastest. **Delivery does not choose
between them on an emulator. The kill probe does.**

### Beyond the criteria: the core host down

`link_kill_probe.sh` (`results/2026-10-06-link-kill-probe.txt`) kills the companion's process with
`kill -9`, as the low-memory killer would, while its activity is gone. It then emits 10 events,
500 ms apart, at once:

| case | what race-timer was told | stored | the core host afterwards |
|---|---|---|---|
| no traffic (the control) | nothing sent | nothing sent | back 1.4 s after the kill (ADR 003's sticky restart) |
| broadcast | `sent`, 10 times | 0 | crashed twice, then "crashed too many times" and not restarted |
| bound service | `no_core`, 10 times | 0 | crashed, and the process lived on behind a crash dialog |
| content provider | nothing: the first call had not returned 120 s later | 0 | crashed repeatedly, with its next restart scheduled 30 minutes out |

The "told" column is the one that decides. Why the core host crashed at all is under
"Consequences and limits". A repeat of the probe earlier the same day differed only for the
provider: two calls returned `null`, then the third blocked for 3½ minutes until the run was
stopped.

### Criterion 3: an emitter not signed with the pinned certificate is refused

`LinkTrustTest` (instrumented, run by `link_tests.sh`) runs twice. In the first run the harness is
re-signed with an imposter key; it carries race-timer's stand-in package, so only the certificate
tells it apart. In the second run it carries the pinned key, which is the control. Each run
exercises all three mechanisms, plus a fourth test calling every endpoint from another package
(the companion's own UID). That test exists because the certificate check reads the *pinned*
package's signer, so without the package check any app could send while race-timer is installed.
The imposter is refused with `reason=certificate_not_pinned`, it is told `refused` over the bound
service and the provider, and none of its events reaches the core. The trusted harness's events
all do.

Proven able to fail with the owner's yes, each red count predicted before the run. Every mutation
was confirmed in the build (the dex hash, or the pinned value in the APK's resources), and the
restore was confirmed byte for byte:

| mutation | predicted red, imposter / trusted | actual |
|---|---|---|
| certificate check removed | 3 / 0 | 3 / 0 |
| package check removed | 1 / 1 (another package) | 1 / 1 |
| refusal demoted to advisory: logged, then forwarded | 4 / 1 | 4 / 1 |
| provider reads its own UID, not its caller's | 1 / 1 (provider) | 1 / 1 |
| broadcast loses its sender's identity | 2 / 2 (broadcast, another package) | 2 / 2 |
| configuration: the imposter's digest pinned | 3 / 3 | 3 / 3 |
| configuration: no certificate pinned | 4 / 4 | 4 / 4 |

## Decision

1. **Mechanism: a bound service.** race-timer binds to the companion's link service
   (`BIND_AUTO_CREATE`) when a sequence starts and unbinds when it ends. It sends each event as one
   binder transaction, and every transaction returns a status. It calls off its cue path, and it
   treats a dead binder (`DeadObjectException`) like `no_core`: keep the event and rebind.
2. **Trust: judged at runtime, per transaction, before the payload is read.** The companion accepts
   an event only when the calling UID the platform vouches for (`Binder.getCallingUid()`) holds
   race-timer's package, and that package is signed by a pinned certificate
   (`PackageManager.hasSigningCertificate`, SHA-256). There is no signature-level permission
   (see "Who trusts whom"). A refusal names its reason in the companion's log.
3. **race-timer checks the companion the same way** before it binds: the service's package and its
   signing certificate, against its own pins. This is race-timer#294 criterion 4.
4. **Delivery is at least once, and the companion de-duplicates.** race-timer keeps every event
   the companion could not take (`no_core`, a dead binder, no binding yet) and resends it under
   the same `id`. The companion stores one event per `id` (#33 criterion 2). `refused` and
   `malformed` are logged and not resent, because resending cannot change them.

**Why not the broadcast.** It delivered as well as the others while the companion was healthy. But
the sender never hears an answer, so an event the companion cannot take is lost without anyone
being told. The kill probe measured exactly that: 10 events sent, 0 stored, and race-timer told
`sent` for every one. Its sender is also unknown unless race-timer opts in to sharing its identity,
which exists only from Android 14.

**Why not the content provider.** It is the simplest client, one call per event with no connection
to manage, and with the companion healthy it is as good as the bound service. But a `call()` blocks
until the provider's process answers, and the public API gives the caller no timeout. While the
companion crash-looped in the kill probe, a call never returned. In the committed run the first
call was still blocked 120 s later, and in an earlier run one was still blocked after 3½ minutes
when it was stopped. race-timer is the app that fires the cues, so the link must never be able
to hold one of its threads. Under the same failure, the bound service answered every transaction
`no_core`. The first answer took 405 ms because it started the process, and each later one took
1.7 to 5.9 ms. A transaction on a binder whose process has died throws
`DeadObjectException` at once, which is Android's documented behaviour. The probe did not exercise
it, because the bound process stayed alive behind a crash dialog.

## The contract, version 1

**Transport.** race-timer binds to the companion's exported link service, `com.procompanion.app` /
`.LinkService` in production (`com.procompanion.core_host_spike/.LinkService` in the spike). Each
event is one transaction: code `IBinder.FIRST_CALL_TRANSACTION`, interface token
`com.procompanion.link.ILink`, then the event as one string (`Parcel.writeString`). The reply
carries no exception, then the status as one string. A raw transaction rather than AIDL keeps the
contract to these few lines, so race-timer needs no generated stub to stay in step with.

One event is one JSON object, carried as that string. race-timer sends one per signal it fires, at
the moment it fires it.

| field | type | when | meaning |
|---|---|---|---|
| `v` | int | always | the contract version, `1`. It changes only on an incompatible change. |
| `id` | string | always | race-timer's id for the event, unique per event and **the same on every retry of it**. The companion's dedupe key (#33 criterion 2). A UUID or a ULID. |
| `kind` | string | always | `sequence_start`, `signal`, `postponement`, `individual_recall`, `general_recall` or `start` (scope decision 2's list) |
| `at_ms` | int | always | race-timer's own clock when the signal fired, in milliseconds since the epoch (the form of the companion's `device_ts`). It is when race-timer fired the signal, not when it sent the event, and the companion keeps it verbatim beside its own receipt time (#33 criterion 1). |
| `sequence` | string | always | the `id` of the `sequence_start` this event belongs to. A `sequence_start` names itself. |
| `sequence_name` | string | `sequence_start` | race-timer's name for the sequence, such as `5-4-1-0`. Informational. |
| `signal` | string | `signal` | which signal: `warning`, `preparatory`, `one_minute`, or race-timer's own name for another |
| `seconds_to_start` | int | `signal` | seconds from this signal to the start it counts down to |

- **No fleet, class or race id** (criterion 5). Fleet attribution follows groom decision G25: the
  companion attaches each incoming sequence to the fleet the PRO has armed as next start, one tap per
  start, and a wrong attribution is fixed by undo. The unit it attaches is the `sequence`: every event
  naming that `sequence` takes the fleet that was armed when its `sequence_start` arrived. race-timer
  knows nothing about fleets and never will need to.
- **The companion keeps fields it does not know** rather than refusing them, so race-timer can add a
  field without a coordinated release. The spike's harness adds `x_`-prefixed measurement fields,
  which are not part of the contract.
- **How #33 logs each kind**: `start`, `postponement` and `general_recall` map to the existing
  `start`, `start.postponement` and `start.general_recall` (#25), each with `source: race-timer`.
  `individual_recall` maps to `start.individual_recall` (#29), whose `payload.start` names the
  companion's start event, so #33 finds it through `sequence`. `sequence_start` and `signal` have no
  manual equivalent, and #33 adds kinds for them. How `at_ms` feeds `gunTime` is #33's (its
  criterion 5: a race-timer gun anchors exactly as a manual one does).

**The answer.** Every transaction returns one status:

| status | meaning | race-timer does |
|---|---|---|
| `accepted` | the companion's core has the event | nothing more |
| `no_core` | the companion is installed, but its core host is not running | keeps the event and retries it, same `id` |
| `refused` | the caller is not race-timer's package signed by a pinned certificate | logs it. A retry cannot help: the pins are out of date. |
| `malformed` | not a JSON object with a string `id`, or a `v` the companion does not know | logs it: a race-timer bug |
| no binding (`bindService` returns false) | the companion is not installed, or race-timer cannot see it | behaves exactly as before (race-timer#294 criterion 3) |
| `DeadObjectException` | the companion's process died under the binding | as `no_core`: keeps the event, rebinds |

So delivery is **at least once**: race-timer retries anything not answered, and the companion
stores one event per `id`. **In the spike, `accepted` means handed to the core host, not yet
written.** #33 must answer `accepted` only once the core's append has returned, within a bounded
wait, so that `accepted` means stored.

## Who trusts whom: the certificate digests

Each side pins the other's package **and** signing certificate (SHA-256), as compiled-in build
inputs per build type. A release build pins only the field keys, and a debug build adds the
developer's own debug key. Nothing on the phone can widen either list.

**The companion trusts race-timer**, package `io.github.sailordave17.racetimer`:

| race-timer as installed | signed with | SHA-256 | where it is recorded |
|---|---|---|---|
| from Play, as on the club phone | Play's app-signing key for race-timer | **not recorded yet** | Play Console (App integrity, App signing), which only the owner can open, or read off the installed app (`adb shell pm path io.github.sailordave17.racetimer`, pull `base.apk`, `apksigner verify --print-certs`). It must be pinned before the first field build meant to accept race-timer (#27, then #34). |
| sideloaded release | race-timer's upload key | `918a82574c74bc3a96707994604a535d77e31018545a9b83c5c008abfe2dc8f6` | race-timer's `docs/release-signing.md` (read 2026-10-06) |
| debug, from a developer's machine | that machine's debug key | per machine | debug builds only |

**race-timer trusts the companion**, package `com.procompanion.app`. Before it binds, it checks
that package's signing certificate (`hasSigningCertificate` again) and binds by explicit component,
which is race-timer#294 criterion 4's "explicit package-and-certificate target":

| companion as installed | signed with | SHA-256 | where it is recorded |
|---|---|---|---|
| field build (G20) | the owner's upload key | **not created yet** | #27 creates the key and records it |
| debug | that machine's debug key | per machine | debug builds only |

The spike pinned a key of its own making. It proves the check, not these values.

### Rejected: a signature-level permission

- **`signature`** needs both apps signed by one key. race-timer from Play and the companion
  sideloaded never are, so race-timer would be refused on the club phone and nowhere else. A
  broadcast to a receiver guarded by it is dropped without a word, and a bind refused by it fails
  only on the phone.
- **`signature|knownSigner`** (Android 12+, `android:knownCerts`) grants by a list of digests,
  which answers the signer problem. But a custom permission is granted when the app *using* it is
  installed, and race-timer will be on the phone before the companion defines the permission.
  Whether the grant follows a later install was not measured. A runtime check depends on neither
  install order nor API level, and it names its reason when it refuses.

## Consequences and limits

- **The emulator cannot show the CPU sleeping**, which is ADR 003's limit again. Forced Doze
  changes the scheduler's state, but the host CPU never suspends, so these runs prove the processes,
  the binder path and the Doze rules, not phone timing. **#21 repeats criterion 1 on the club phone
  with this harness**: 50 events over 30 minutes, screen off, in a pocket, over the chosen mechanism
  only (`--es mech bound --ei count 50 --ei interval_ms 36000`; the spike's README has the command).
  That run, not this one, is where an OEM battery manager shows. The harness holds a partial wake
  lock for its run, as race-timer's sequence keeps the CPU awake, so a gap there is the link's and
  not the stand-in's.
- **Package visibility.** race-timer must declare the companion's package in `<queries>` to bind
  to it at all. A binding caller is made visible to the companion by the binding. The spike also
  declared race-timer's package in the companion's `<queries>`, so whether the certificate check
  needs that declaration was not measured. Keep it.
- **`hasSigningCertificate` is API 28**, and the companion's `minSdk` is Flutter's default, 24.
  The spike refuses below 28 rather than crash. #33 either raises `minSdk` to 28 or reads
  `GET_SIGNATURES` there.
- **The link can take the core host down, and #32 must fix that before #33 ships.** The link
  service lives in the core host's process. When that process has died and ADR 003's sticky restart
  is pending, the first event to arrive starts the process for the link. The pending restart then
  runs as a background start of a `location` foreground service, and Android refuses it.
  `CoreService.onCreate` does not catch the refusal, so the host crashes. After quick repeat
  crashes, the system either gave up on the service or scheduled its next restart 30 minutes out,
  and every restart in between was refused the same way. Every mechanism did this in the kill
  probe. With no link traffic the same restart succeeded in 1.4 s. So **the real host (#32) must
  survive a refused
  `startForeground`**: catch it, stop itself, and leave the process alive so the link can answer
  `no_core`. ADR 003 is amended with the measurement. The host then stays down until the PRO opens
  the app. Provided race-timer keeps every unanswered event, as decision 4 requires, nothing is lost
  in that time, only the log's timeliness.
- **Nothing leaves the phone.** race-timer hands events to another app on the same device, so its
  no-INTERNET stance holds, though its privacy policy may still want a sentence saying so
  (race-timer#294's note).
- **The production names**: the companion's link service is `com.procompanion.app/.LinkService`,
  with interface token `com.procompanion.link.ILink`. The spike's is
  `com.procompanion.core_host_spike/.LinkService`, with the same token.
- **What the spike keeps that production will not**: the broadcast receiver and the content
  provider stay in the spike, as the measured alternatives. #33 builds only the bound service.

## Kill condition

**Criterion 6 did not fire.** Its condition was that no mechanism delivers all 50 events under
forced Doze. All three did, the bound service among them (see "Options measured"), so ADR 001's
link kill condition is not invoked and scope decision 3 stays on the horizon.

**It moves to the field.** The emulator cannot sleep its CPU, so the evidence that can still kill
the link comes from the club phone: #21 (this harness) and #34 (the real race-timer). If either
loses one event with the companion backgrounded and the screen off, ADR 001's kill condition fires.
Manual gun-time entry (#25) becomes the fallback, scope decision 3 (absorbing race-timer's cue path)
moves up from horizon, and the result goes to the owner at once. The first thing to try before
that is the core host's wake lock that ADR 003 already names, not a different mechanism: on the
emulator, all three mechanisms delivered alike.
