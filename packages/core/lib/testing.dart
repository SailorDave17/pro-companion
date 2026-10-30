/// An in-memory core for widget tests: the UI is driven against it instead of
/// a real store (#24 criterion 7, and #32's "UI widget tests still pass
/// against the fake core").
library;

import 'dart:math';

import 'src/chain_status.dart';
import 'src/client.dart';
import 'src/clock_offsets.dart';
import 'src/envelope.dart';
import 'src/location.dart';
import 'src/order.dart';
import 'src/pulls.dart';
import 'src/race_times.dart';
import 'src/roles.dart';
import 'src/roundings.dart';
import 'src/stations.dart';
import 'src/uploads.dart';
import 'src/wire.dart';

export 'src/location.dart' show LatestFix;

/// Behaves like the real core - sequence numbers, ULIDs, ADR 001 order - and
/// holds the UI to the same boundary rule: an argument that could not cross
/// an isolate-group boundary is refused here too, so a UI test fails where
/// the real core would.
class FakeCore implements CoreClient {
  FakeCore({this.deviceIdValue = '01J0000000FAKEDEVICE00000A', int Function()? clock, LatestFix? location})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        location = location ?? LatestFix();

  final String deviceIdValue;
  final int Function() _clock;

  /// Where the fake's phone is (#31), as the real core holds it: what
  /// [reportFix] and [reportNoFix] report to, and what every append is
  /// stamped from.
  final LatestFix location;
  final _events = <EventEnvelope>[];
  final _random = Random(24);
  String? _admissionId;

  /// When set, every call fails with it, for testing how the UI copes.
  CoreException? failWith;

  /// How many calls the UI has made, by command name.
  final calls = <String, int>{};

  Future<T> _call<T>(String command, T Function() body) async {
    calls[command] = (calls[command] ?? 0) + 1;
    // Async like the real port, but a microtask rather than a timer, so a
    // widget test never ends with a timer still pending.
    await Future<void>.value();
    final failure = failWith;
    if (failure != null) throw failure;
    return body();
  }

  /// Adds events as though they were already in the log: this phone's own,
  /// or, with another device id, another committee phone's pulled down by
  /// sync (#64), which [readAll] returns and [readOwn] does not.
  void seed(Iterable<EventEnvelope> events) => _events.addAll(events);

  /// What [uploadStatus] answers. The fake runs no sync, so a test sets it.
  UploadStatus uploadStatusValue = UploadStatus.empty;

  /// What [revocation] answers (#53), set by a test for the same reason. A
  /// test may change it while the app runs, as sync would.
  Revocation? revocationValue;

  /// What [pullStatus] answers, set by a test for the same reason.
  PullStatus pullStatusValue = PullStatus.empty;

  /// What [chainStatus] answers (#67). The fake holds no canonical text and
  /// no refusal stubs, so it verifies nothing, and a test sets it. A test may
  /// change it while the app runs, as a pull would.
  ChainStatus chainStatusValue = ChainStatus.empty;

  // The store's read order: device time, device, then the device's sequence
  // number (#145).
  List<EventEnvelope> _ordered(Iterable<EventEnvelope> events) => [...events]..sort(happened);

  @override
  Future<EventEnvelope> append(NewEvent event) => _call(Wire.append, () {
        requireWireSafe(event.toWire(), 'event');
        validateNewEvent(event);
        final now = _clock();
        // And a rounding's race and lap (#54), as the real core stamps them.
        event = stampRounding(_events, event,
            deviceId: deviceIdValue, station: currentStation(_events, deviceIdValue), now: now);
        final where = location.current();
        // As the real core does (#55): an event that joins a race the phone
        // has no clock offset for yet has one appended just before it, at
        // the same time.
        final stamp = location.clockOffset(now);
        final join =
            raceToJoin(_events, event, deviceId: deviceIdValue, now: now, measuredNow: stamp.offsetMs != null);
        if (join == null) return _add(event, newUlid(now, _random), now, where);
        var offsetUlid = newUlid(now, _random);
        var eventUlid = newUlid(now, _random);
        if (offsetUlid.compareTo(eventUlid) > 0) (offsetUlid, eventUlid) = (eventUlid, offsetUlid);
        _add(
          ClockEvents.offset(fleet: join.fleet, race: join.atOwnGun ? eventUlid : join.race, stamp: stamp),
          offsetUlid,
          now,
          where,
        );
        return _add(event, eventUlid, now, where);
      });

  EventEnvelope _add(NewEvent event, String ulid, int now, GpsStamp where) {
    final seq = 1 + _events.where((e) => e.deviceId == deviceIdValue).length;
    final e = EventEnvelope(
      ulid: ulid,
      deviceTs: now,
      deviceId: deviceIdValue,
      seq: seq,
      person: event.person,
      // As the real core does (#20): the phone's role, unless the event
      // names one. Seeded role picks count, as stored ones do there.
      role: event.role ?? currentRole(_events, deviceIdValue),
      admissionId: _admissionId,
      // And where the phone is (#31), as the real core stamps it.
      gps: where.fix,
      gpsReason: where.reason,
      source: event.source,
      kind: event.kind,
      payloadVersion: event.payloadVersion,
      correctsUlid: event.correctsUlid,
      // And the phone's station (#26), unless the event names a mark.
      payload: withStation(event.payload, currentStation(_events, deviceIdValue)),
    );
    _events.add(e);
    return e;
  }

  @override
  Future<List<EventEnvelope>> readAll() => _call(Wire.readAll, () => _ordered(_events));

  @override
  Future<List<EventEnvelope>> readOwn() =>
      _call(Wire.readOwn, () => _ordered(_events.where((e) => e.deviceId == deviceIdValue)));

  @override
  Future<int> count() => _call(Wire.count, () => _events.length);

  @override
  Future<String> deviceId() => _call(Wire.deviceId, () => deviceIdValue);

  @override
  Future<String?> admissionId() => _call(Wire.admissionId, () => _admissionId);

  @override
  Future<void> setAdmissionId(String admissionId) => _call(Wire.setAdmissionId, () {
        validateAdmissionId(admissionId);
        _admissionId = admissionId;
      });

  @override
  Future<void> reportFix(GpsFix fix) => _call(Wire.reportLocation, () {
        // Through the wire form, as the real core receives it.
        final wire = fix.toWire();
        requireWireSafe(wire, 'fix');
        location.reportFix(GpsFix.fromWire(wire)!);
      });

  @override
  Future<void> reportNoFix(String reason) => _call(Wire.reportLocation, () => location.reportNone(reason));

  @override
  Future<void> reportGpsTime(GpsTimeSample sample) => _call(Wire.reportLocation, () {
        final wire = sample.toWire();
        requireWireSafe(wire, 'gps_time');
        location.reportGpsTime(GpsTimeSample.fromWire(wire));
      });

  /// As the real core does: the offset held is dropped, and the set is logged.
  @override
  Future<void> reportClockChanged() => _call(Wire.reportLocation, () {
        location.reportClockChanged();
        final now = _clock();
        _add(ClockEvents.changed(), newUlid(now, _random), now, location.current());
      });

  @override
  Future<UploadStatus> uploadStatus() => _call(Wire.uploadStatus, () {
        // Through the wire form, so a status the real core could not send
        // fails here too.
        final wire = uploadStatusValue.toWire();
        requireWireSafe(wire, 'uploadStatus');
        return UploadStatus.fromWire(wire);
      });

  @override
  Future<Revocation?> revocation() => _call(Wire.revocation, () {
        final wire = revocationValue?.toWire();
        requireWireSafe(wire, 'revocation');
        return wire == null ? null : Revocation.fromWire(wire);
      });

  @override
  Future<PullStatus> pullStatus() => _call(Wire.pullStatus, () {
        final wire = pullStatusValue.toWire();
        requireWireSafe(wire, 'pullStatus');
        return PullStatus.fromWire(wire);
      });

  @override
  Future<ChainStatus> chainStatus() => _call(Wire.chainStatus, () {
        final wire = chainStatusValue.toWire();
        requireWireSafe(wire, 'chainStatus');
        return ChainStatus.fromWire(wire);
      });

  @override
  Future<List<FleetRaceTimes>> raceTimes() => _call(Wire.raceTimes, () {
        // Worked out from the fake's events, as the real core works it out
        // from the log (#69), and through the wire form, so an answer the
        // real core could not send fails here too.
        final wire = [for (final r in raceTimesOf(_ordered(_events))) r.toWire()];
        requireWireSafe(wire, 'raceTimes');
        return [for (final w in wire) FleetRaceTimes.fromWire(w)];
      });

  @override
  Future<void> close() => _call(Wire.close, () {});
}
