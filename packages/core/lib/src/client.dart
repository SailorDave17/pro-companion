import 'dart:async';
import 'dart:isolate';

import 'admissions.dart';
import 'chain_status.dart';
import 'envelope.dart';
import 'location.dart';
import 'pulls.dart';
import 'race_times.dart';
import 'uploads.dart';
import 'wire.dart';

/// The only way the UI reaches the core (ADR 001, ADR 003). Every call is
/// async, and every argument and result crosses as plain data.
abstract interface class CoreClient {
  /// Appends [event] as this device's next event. Completes once it is
  /// committed on the phone, with the event as stored.
  Future<EventEnvelope> append(NewEvent event);

  /// Every event in the log, in ADR 001 order: this phone's own and, once sync
  /// pulls them (#64), the other committee phones' events too.
  Future<List<EventEnvelope>> readAll();

  /// This phone's own events, in ADR 001 order. What every screen reads, so
  /// another phone's pulled events change none of them (owner decision on
  /// #64): a story that shows the committee's view reads [readAll] on purpose.
  Future<List<EventEnvelope>> readOwn();

  /// How many events the log holds.
  Future<int> count();

  /// This install's device id.
  Future<String> deviceId();

  /// The admission this phone holds (#49), or null when it has never been
  /// admitted.
  Future<String?> admissionId();

  /// Caches [admissionId], `admit_device`'s answer, so that every event
  /// appended from now on carries it (#49). A re-admission calls this again;
  /// events already stored keep the admission they were written under, and
  /// the core first appends the role-change marker under the old admission
  /// (#71, groom decision G46), as its last event from this phone.
  Future<void> setAdmissionId(String admissionId);

  /// Admits this phone with a role's admission [code] (#71, ADR 005): signs
  /// it in by device handoff when it holds no session, finds the race day the
  /// code is for, calls `admit_device`, and caches the admission as
  /// [setAdmissionId] does, marker included. Answers with what the code
  /// granted. A refusal, no signal and a core with no server wired to it each
  /// come back as a [CoreException] coded from `JoinCodes`.
  Future<Admission> join(String code);

  /// Tells the core the phone's latest fix, [fix]'s `ageMs` old as of now
  /// (#31). Every event appended from now on carries it, with its age grown
  /// by the time since.
  Future<void> reportFix(GpsFix fix);

  /// Tells the core the phone has no position, for [reason], one of
  /// `GpsReasons.all` (#31). Every event appended from now on carries a null
  /// position and that reason, until the next fix.
  Future<void> reportNoFix(String reason);

  /// Tells the core the satellites' time from the phone's latest fix that
  /// carried it, against the phone's own clock at that fix (#55). Every
  /// clock-offset event from now on is read from it, with its age, until the
  /// next one or until [reportClockChanged].
  Future<void> reportGpsTime(GpsTimeSample sample);

  /// Tells the core the phone's clock was set (#55), so the offset it holds no
  /// longer holds. The core appends a `clock.changed` event, so every race
  /// this phone had joined is joined again by its next finish, and clock-offset
  /// events say `clock_changed` until the next [reportGpsTime].
  Future<void> reportClockChanged();

  /// Where this phone's own events stand on their way to shore (#6): how many
  /// wait, how many the server holds, which it refused and why, and how sync's
  /// latest run ended.
  Future<UploadStatus> uploadStatus();

  /// The revocation of the admission this phone's taps go under (#53), or
  /// null while it stands. Cheap enough to poll: the UI's revoked banner reads
  /// it every few seconds, on every screen.
  Future<Revocation?> revocation();

  /// How up to date this phone is with the other committee phones (#64): when
  /// a pull last read every race day it may read, and how sync's latest pull
  /// ended.
  Future<PullStatus> pullStatus();

  /// Whether this phone's own chain stands, and how each other committee
  /// phone's log reads on each race day it was pulled from (#67): verified,
  /// catching up, refused at N, or altered. Worked out in the core, from the
  /// stored text and the pulled refusal stubs, each time it is asked.
  Future<ChainStatus> chainStatus();

  /// Every fleet race's finishes, at the line and at marks, from every phone
  /// this one holds, each timed from its race's gun through both phones'
  /// clock offsets, and each race flagged where a time could not be worked
  /// out or where two phones took finishes (#69). Worked out in the core each
  /// time it is asked, so scoring and export read the flags rather than work
  /// them out again.
  Future<List<FleetRaceTimes>> raceTimes();

  /// Closes the store and stops the core.
  Future<void> close();
}

/// A [CoreClient] speaking the wire protocol to a core behind [SendPort].
///
/// With [closesCore] false it is a client of a core it does not own: one a
/// host serves for every client, as the foreground service does (#32). Its
/// [close] then sends nothing, and the core goes on serving the others.
class PortCoreClient implements CoreClient {
  PortCoreClient(this._core, {this.closesCore = true});

  final SendPort _core;
  final bool closesCore;

  Future<Object?> _call(String command, Map<String, Object?> args) {
    requireWireSafe(args, 'args');
    final completer = Completer<Object?>();
    final port = RawReceivePort();
    port.handler = (Object? reply) {
      port.close();
      final r = reply as List;
      if (r[0] == Wire.ok) {
        completer.complete(r[1]);
      } else {
        completer.completeError(CoreException(r[1] as String, r[2] as String));
      }
    };
    _core.send([port.sendPort, command, args]);
    return completer.future;
  }

  @override
  Future<EventEnvelope> append(NewEvent event) async =>
      EventEnvelope.fromWire(await _call(Wire.append, {'event': event.toWire()}) as Map);

  @override
  Future<List<EventEnvelope>> readAll() async => [
        for (final w in await _call(Wire.readAll, const {}) as List) EventEnvelope.fromWire(w as Map),
      ];

  @override
  Future<List<EventEnvelope>> readOwn() async => [
        for (final w in await _call(Wire.readOwn, const {}) as List) EventEnvelope.fromWire(w as Map),
      ];

  @override
  Future<int> count() async => await _call(Wire.count, const {}) as int;

  @override
  Future<String> deviceId() async => await _call(Wire.deviceId, const {}) as String;

  @override
  Future<String?> admissionId() async => await _call(Wire.admissionId, const {}) as String?;

  @override
  Future<void> setAdmissionId(String admissionId) async {
    await _call(Wire.setAdmissionId, {'admission_id': admissionId});
  }

  @override
  Future<Admission> join(String code) async => Admission.fromWire(await _call(Wire.join, {'code': code}) as Map);

  @override
  Future<void> reportFix(GpsFix fix) async {
    await _call(Wire.reportLocation, {'fix': fix.toWire()});
  }

  @override
  Future<void> reportNoFix(String reason) async {
    await _call(Wire.reportLocation, {'reason': reason});
  }

  @override
  Future<void> reportGpsTime(GpsTimeSample sample) async {
    await _call(Wire.reportLocation, {'gps_time': sample.toWire()});
  }

  @override
  Future<void> reportClockChanged() async {
    await _call(Wire.reportLocation, {'clock_changed': true});
  }

  @override
  Future<UploadStatus> uploadStatus() async =>
      UploadStatus.fromWire(await _call(Wire.uploadStatus, const {}) as Map);

  @override
  Future<Revocation?> revocation() async {
    final wire = await _call(Wire.revocation, const {});
    return wire == null ? null : Revocation.fromWire(wire as Map);
  }

  @override
  Future<PullStatus> pullStatus() async => PullStatus.fromWire(await _call(Wire.pullStatus, const {}) as Map);

  @override
  Future<ChainStatus> chainStatus() async =>
      ChainStatus.fromWire(await _call(Wire.chainStatus, const {}) as Map);

  @override
  Future<List<FleetRaceTimes>> raceTimes() async => [
        for (final w in await _call(Wire.raceTimes, const {}) as List) FleetRaceTimes.fromWire(w as Map),
      ];

  @override
  Future<void> close() async {
    if (!closesCore) return;
    await _call(Wire.close, const {});
  }
}
