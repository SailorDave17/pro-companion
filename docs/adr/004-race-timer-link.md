# ADR 004 — The race-timer link: a bound service answering every event, with the caller judged by package and certificate

- Status: accepted 2026-10-06, on measurement (#15). The companion's half built by #33, 2026-11-01:
  see "Built (#33)"
- Builds on: pro-companion ADR 001 ("The race-timer link": race-timer signals and the companion
  logs, the mechanism is picked by a spike, manual gun-time entry is the fallback, and the link
  carries a kill condition) and ADR 003 (the core host: a `location` foreground service owning a
  headless engine, which platform code reaches over the service's method channel)
- Evidence: `tool/core_host_spike/`, its race-timer stand-in in `android/harness/`, the runs in
  `results/2026-10-06-link-run.txt` and `results/2026-10-06-link-kill-probe.txt`, and the
  instrumented `LinkTrustTest`. For the real app: `RaceTimerLinkTest`, run by
  `integration_test/race_timer_link.sh`, and `integration_test/link_kill.sh`
- Built by: race-timer#294 (the emitter) and pro-companion #33 (the receiver). Field-checked by #21
  (the harness on the owner's phone) and #34 (the real race-timer on a personal phone). There is no
  dedicated club phone (G50): "the club phone" below is the owner's own, which every measurement
  here was taken on
- **Held on the club phone 2026-10-07 (#21)**: 50 of 50 events delivered unplugged with the screen
  off. See "Kill condition".

## Context

Scope decision 2: race-timer owns the start sequence and the companion logs it. Both run on the
same phone. race-timer exposes no interface to other apps today: its phone manifest exports only the
launcher activity (race-timer#294's filing note). So the link is new work on both sides, and it has
to deliver while the companion is in the background with the screen off: the phone is in a pocket,
and Doze is the normal state.

**The two apps will not share a signing key.** race-timer reaches a personal phone through Google
Play, which re-signs it with Play's app-signing key; its phone app is on Play's internal track
today. The companion is sideloaded, signed with the owner's upload key (groom decision G20, #27).
A `signature`-level permission needs one signer on both sides, so it would refuse race-timer on
a real phone with no error anywhere, while passing every test run on a development machine,
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
  companion attaches each incoming sequence to the fleet the PRO has armed as next start, and a wrong
  attribution is fixed by undo. Armed means the fleet selected on the phone, with no control of its
  own (owner decision on #33). The unit it attaches is the `sequence`: the first event of a sequence
  to arrive takes the selected fleet, normally its `sequence_start`, or a signal resent ahead of it,
  and every later event takes the sequence's fleet. race-timer knows nothing about fleets and never
  will need to.
- **The companion keeps what it does not know** rather than refusing it, so race-timer can add to
  the contract without a coordinated release. A field it does not know is kept under `payload.link`,
  and a `kind` it does not know is logged as a signal with its own `kind` kept there, since signals
  move no anchor and race-timer never resends a `malformed` (owner decision on #33). The spike's
  harness adds `x_`-prefixed measurement fields, which are not part of the contract.
- **How #33 logs each kind**: `start`, `postponement` and `general_recall` map to the existing
  `start`, `start.postponement` and `start.general_recall` (#25), each with `source: race-timer`.
  `individual_recall` maps to `start.individual_recall` (#29), whose `payload.start` names the
  companion's start event, found through `sequence`. `sequence_start` and `signal` have no manual
  equivalent, and are logged as `start.sequence_start` and `start.signal`. Neither is among a fleet's
  starts, so neither moves an anchor. `packages/core/lib/src/link.dart` holds the map.

**The answer.** Every transaction returns one status:

| status | meaning | race-timer does |
|---|---|---|
| `accepted` | the companion's core has committed the event, or held that `id` already | nothing more |
| `no_core` | nothing committed it: the core host is not running, is failing, or did not answer in time | keeps the event and retries it, same `id` |
| `refused` | the caller is not race-timer's package signed by a pinned certificate | logs it. A retry cannot help: the pins are out of date. |
| `malformed` | not a JSON object with a string `id`, a string `kind`, an integer `at_ms` and a string `sequence`, a `v` the companion does not know, or JSON the log could not store | logs it: a race-timer bug |
| no binding (`bindService` returns false) | the companion is not installed, or race-timer cannot see it | behaves exactly as before (race-timer#294 criterion 3) |
| `DeadObjectException` | the companion's process died under the binding | as `no_core`: keeps the event, rebinds |

So delivery is **at least once**: race-timer retries anything not answered, and the companion
stores one event per `id`. Only the binder thread waits, for at most 2 s, and the main thread never
does. A call that outlives the wait is told `no_core` and stays queued, so if it does commit, the
retry is accepted and stores nothing. Text is judged only by the core, and the host-down check comes
before it, so a malformed event with the host down is told `no_core` until the host is back.

**A stated limit: an escaped NUL.** "Could not store" means this phone's log. A string carrying
`\u0000`, which only a race-timer bug would send, is stored, buzzed and told `accepted`, but the
shore refuses it for good (`inconsistent_canonical`, since Postgres text holds no NUL). The gun
then counts on the PRO's phone, which shows the refusal in its log, and no other phone gets it. The
owner chose this over refusing it as `malformed`, which would lose the gun on the phone too with no
buzz, and over replacing the NUL, which breaks "verbatim" (owner decision at #33's review).

## Who trusts whom: the certificate digests

Each side pins the other's package **and** signing certificate (SHA-256), as compiled-in build
inputs per build type. A release build pins only the field keys, and a debug build adds whatever
`-PlinkDebugCerts` names: a developer's own key, or `race_timer_link.sh`'s throwaway stand-in key.
Only the debug build type reads that property, and `scripts/check_release_signing.sh` holds a release
APK to the two field keys with it set. Nothing on the phone can widen either list.

**The companion trusts race-timer**, package `io.github.sailordave17.racetimer`:

| race-timer as installed | signed with | SHA-256 | where it is recorded |
|---|---|---|---|
| from Play | Play's app-signing key for race-timer | `3ec6dcb6a362106d30db30fce8475d14aec714a0ed338e8c00a3553de8c6f17f` | Play Console, App integrity → App signing, the key marked "In use" (read 2026-10-08, #27) |
| sideloaded release | race-timer's upload key | `918a82574c74bc3a96707994604a535d77e31018545a9b83c5c008abfe2dc8f6` | race-timer's `docs/release-signing.md` (read 2026-10-06); Play Console's upload key certificate and the APK on the club phone agree (2026-10-08) |
| debug, from a developer's machine | that machine's debug key | per machine | debug builds only |

**The club phone carries the sideloaded release today, not Play's**, *measured 2026-10-08 (#27)*.
`dumpsys package` names `com.android.shell` as the installer (an `adb install`, 2026-09-29), and
`apksigner` on the `base.apk` pulled off the phone reads race-timer's upload key. So the second row is
the one the club phone needs until race-timer is installed there from Play. That install has to
uninstall the sideload first, since the two are signed by different keys.

Play Console also lists a **previous** app-signing key: first used 3 Aug 2026, marked
"Quantum-ready (beta)", classical certificate
`577e91f860496f5c2411d843020f4774d8ddb9859d7edc71a33bf188e577a2b3`. Both keys showed a 0% install
base on 2026-10-08. A Play install signed before the key change would carry the previous key.
`hasSigningCertificate` searches every certificate a package "has proven to have been signed" with
(its documentation), rotation history included, so whether a Play install also matches the previous
key depends on the lineage Play ships, which was not measured. The previous key is not pinned. #167
settles it on a real Play install. This said #34 until 2026-11-01, when the owner kept the sideload
for #34's run, so the Play row stays unproven on a real phone until #167.

**race-timer trusts the companion**, package `com.procompanion.app`. Before it binds, it checks
that package's signing certificate (`hasSigningCertificate` again) and binds by explicit component,
which is race-timer#294 criterion 4's "explicit package-and-certificate target":

| companion as installed | signed with | SHA-256 | where it is recorded |
|---|---|---|---|
| field build (G20) | the owner's upload key | `8578eb0538b09db7f4df3284049591986aa32e5a338ee513f86e7c754bdc5506` | `docs/field-builds.md`, "The field key" (#27, 2026-10-08). `test/field_key_doc_test.dart` holds this row to it. |
| debug | that machine's debug key | per machine | debug builds only |

The spike pinned a key of its own making. It proves the check, not these values.

### Rejected: a signature-level permission

- **`signature`** needs both apps signed by one key. race-timer from Play and the companion
  sideloaded never are, so race-timer would be refused on a real phone and nowhere else. A
  broadcast to a receiver guarded by it is dropped without a word, and a bind refused by it fails
  only on the phone.
- **`signature|knownSigner`** (Android 12+, `android:knownCerts`) grants by a list of digests,
  which answers the signer problem. But a custom permission is granted when the app *using* it is
  installed, and race-timer will be on the phone before the companion defines the permission.
  Whether the grant follows a later install was not measured. A runtime check depends on neither
  install order nor API level, and it names its reason when it refuses.

## Built (#33)

`packages/core/lib/src/link.dart` holds the rules, shared by the store and `FakeCore`.
`android/.../LinkService.kt`, `LinkInbox.kt` and `LinkTrust.kt` are the transport and the trust
check, in the core's process, and judge the caller before the payload is read. The owner's decisions
at pickup and at the review, 2026-11-01:

- **What an event holds.** `payload.link` is the contract object verbatim, nested so that a field
  race-timer adds later can never read as one of ours. `payload.at_ms` is race-timer's time and
  `payload.received_ms` the phone's, stamped first in the transaction, so an event held while the
  engine started keeps its real receipt. `device_ts` is when it was committed.
- **Dedupe.** `link_event`, one append-only row per `id`, in one commit with the event. A row
  outlives what it stored, so a late retry can never bring back what the PRO took away.
- **A gun's time** is its latest time fix, else `at_ms`, else `device_ts` (`firedAt`, `gunTime`), and
  a fleet's starts and recalls read in that order, so a resent gun still comes before the recall
  that cancelled it. So race-timer need not resend in order. The card reads that order too
  (`onTheWater`): the fleet's last race-timer event is the last to fire, not the last to arrive, so
  a backlog resent out of order cannot put an earlier race back on it (#33's review). A race-timer
  recall that arrives before its own gun names the fleet's anchor only if that fired during its
  sequence. An earlier race's gun is not its start.
- **A wrong fleet.** The card of anything race-timer sent opens a list of fleets and writes
  nothing, and Back is a true cancel. Picking a fleet undoes and re-logs in one commit: the
  sequence, what the PRO tapped on that fleet's card while it ran (a manual gun, postponement or
  general recall), what names a gun that moved (a typed time, an individual recall, OCS boats and
  clearances), and the phone's own fleet. A copy keeps its original's time. So the fix is 2 taps on
  that fleet whatever was tapped since, and 3 from another fleet, its row first. On a race-timer gun
  the list also offers FIX THE GUN TIME, since the card is where a time is fixed, so that fix takes a
  tap more than on a manual gun (owner decision at #33's review: UNDO alone reached the sequence
  only while nothing was tapped after it, and after two OCS boats cost 4 taps and lost them). UNDO
  still offers the fix while nothing was tapped after the sequence, and reaches it right after a
  switch to its fleet, because a wrong fleet is often noticed after the phone has moved on; there it
  replaces UNDO SWITCH. With no fleets defined, nothing can be misattributed: the card fixes the
  time, and UNDO stays one event at a time.
- **Take-back.** NO FLEET · TAKE IT BACK undoes the same set, for a sequence that should never have
  counted, such as a rehearsal, and is recorded on the undos rather than inferred. What arrives of
  it later is logged and undone at once. So **a mistaken take-back cannot be reversed**: the gun must
  then be tapped by hand.
- **The banner** shows unless something from race-timer arrived in the last 10 minutes. race-timer
  binds only while a sequence runs, so it shows on most opens before the first start. It takes its
  32 dp from the card, so no button moves when it comes or goes. A countdown the card shows ends
  when the banner comes up: one race-timer stopped sending partway through would otherwise hold the
  card, and the last race's recall, OCS and time fix with it, and on a day with no fleets nothing
  could undo it (#33's review).
- **Confirmation.** One buzz and one tone from the core host's engine when a call stored the event,
  and none for a retry. *Measured* on the API 34 emulator with the activity gone and the screen off:
  6 events, 6 finished vibrations, and 6 stream-5 tracks in `dumpsys media.audio_flinger`, each
  within 21 ms of its vibration. Measured again after the review, with the raw output kept
  (`tool/core_host_spike/results/2026-11-02-link-tone.txt`: 6 of 6, within 39 ms). The device
  test asserts the buzz only, since API 34 keeps about 16 s of tracks. Whether either is felt over
  race-timer's own cue, which it lands on within tens of milliseconds, is #34's to read on a phone.

Not moved by a fix: finishes already logged under the wrong fleet, and any sequence on the fleet
older than its newest.

## Consequences and limits

- **The emulator cannot show the CPU sleeping**, which is ADR 003's limit again. Forced Doze
  changes the scheduler's state, but the host CPU never suspends, so these runs prove the processes,
  the binder path and the Doze rules, not phone timing. **#21 repeats criterion 1 on the club phone
  with this harness**: 50 events over 30 minutes, screen off and unplugged, over the chosen mechanism
  only (`--es mech bound --ei count 51 --ei interval_ms 36000`, where event 1 goes out on the cable;
  the spike's README has the procedure).
  That run, not this one, is where an OEM battery manager shows. The harness holds a partial wake
  lock for its run, as race-timer's sequence keeps the CPU awake, so a gap there is the link's and
  not the stand-in's.
- **Package visibility.** race-timer must declare the companion's package in `<queries>` to bind
  to it at all. A binding caller is made visible to the companion by the binding. The spike also
  declared race-timer's package in the companion's `<queries>`, so whether the certificate check
  needs that declaration was not measured. The app keeps it.
- **`hasSigningCertificate` is API 28**, and the companion's `minSdk` stays Flutter's default, 24, so
  an old personal phone can still log by hand. Below 28 the link is refused, `api_below_28`, with no
  `GET_SIGNATURES` path (owner decision on #33): raising `minSdk` would cost those phones the whole
  app, and reading the old signatures is a second, weaker way in. No real caller is affected, since
  race-timer's own `minSdk` is 30 (read 2026-11-01).
- **The link could take the core host down, and #32 and #33 closed that.** The link service lives
  in the core host's process. When that process has died and ADR 003's sticky restart is pending,
  the first event to arrive starts the process for the link. The pending restart then runs as a
  background start of a `location` foreground service, and Android refuses it. In the spike
  `CoreService.onCreate` did not catch the refusal, so the host crashed. After quick repeat crashes,
  the system either gave up on the service or scheduled its next restart 30 minutes out, and every
  restart in between was refused the same way. Every mechanism did this in the kill probe. With no
  link traffic the same restart succeeded in 1.4 s. The real host (#32) catches the refusal, stops
  itself and leaves the process alive, so the link answers `no_core`. *Measured on it* by #33,
  `results/2026-11-01-link-kill-real-host.txt`: 16 of 16 told `no_core`, no crash, and 20 of 20
  stored once the app was reopened and race-timer's stand-in retried. The host stays down until the
  PRO opens the app. Provided race-timer keeps every unanswered event, as decision 4 requires,
  nothing is lost in that time, only the log's timeliness. With location refused the host is only
  ever bound, so it goes with the activity and the link answers `no_core` from then on.
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
the link comes from a real phone: #21 (this harness) and #34 (the real race-timer). If either
loses one event with the companion backgrounded and the screen off, ADR 001's kill condition fires.
Manual gun-time entry (#25) becomes the fallback, scope decision 3 (absorbing race-timer's cue path)
moves up from horizon, and the result goes to the owner at once. The first thing to try before
that is the core host's wake lock that ADR 003 already names, not a different mechanism: on the
emulator, all three mechanisms delivered alike.

### On the club phone, 2026-10-07 (#21): did not fire

On the club phone (Samsung Galaxy S23 Ultra, Android 16, One UI 8.5, retail build), the harness
emitted 51 events over the bound service, 36 s apart, with the companion backgrounded
(`tool/core_host_spike/results/2026-10-07-club-phone-link-run3.txt`). Event 1 went out on the
cable. The phone was unplugged 2 s later and its screen went off 3 s after that, and it stayed that
way, on no charger, until the run was over. The battery history and the events buffer both show no
screen-on and no plug in between.

| events | delivered | duplicates | refused | emit → core p50 / p95 / max |
|---|---|---|---|---|
| 2–51, unplugged and screen off | **50 / 50** | 0 | 0 | 11 / 27 / 41 ms (all 51) |

**No event was lost, so ADR 001's link kill condition does not fire.** Two earlier runs that day
delivered every event too (101 of 101), but neither held these conditions for 30 minutes: the club
phone is also the owner's daily phone, and both were used and charged mid-run
(`results/2026-10-07-club-phone-link-runs.txt`).

Two limits on what this shows:

- **Light Doze, not deep.** Light Doze was idle from the second minute on. Deep Doze reached only
  `IDLE_PENDING`, a minute after the last event, so no event went out in deep idle. A phone moving
  in a pocket on a race day resets deep Doze's motion check, so light Doze is the likelier state
  there, but this run does not show that.
- **The harness held the CPU awake**, as race-timer's sequence does. While it did, the core's 10 s
  tick held to 10.2 s at worst; once it let go, the tick gapped by up to 104 s. So this run says the
  link delivers to a backgrounded core, screen off and in light Doze, while the emitter holds a wake
  lock, and nothing about an emitter that does not. #34 repeats it with the real race-timer.
