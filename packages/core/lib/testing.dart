/// An in-memory core for widget tests: the UI is driven against it instead of
/// a real store (#24 criterion 7, and #32's "UI widget tests still pass
/// against the fake core").
library;

import 'dart:async';
import 'dart:math';

import 'src/admissions.dart';
import 'src/chain_status.dart';
import 'src/client.dart';
import 'src/clock_offsets.dart';
import 'src/envelope.dart';
import 'src/fleets.dart';
import 'src/link.dart';
import 'src/location.dart';
import 'src/order.dart';
import 'src/pulls.dart';
import 'src/race_areas.dart';
import 'src/race_times.dart';
import 'src/roles.dart';
import 'src/roundings.dart';
import 'src/starts.dart';
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

  /// Every race-timer id stored, as the real core's `link_event` holds them.
  final _linkIds = <String>{};

  /// When set, every call fails with it, for testing how the UI copes.
  CoreException? failWith;

  /// How many calls the UI has made, by command name.
  final calls = <String, int>{};

  Future<T> _call<T>(String command, FutureOr<T> Function() body) async {
    calls[command] = (calls[command] ?? 0) + 1;
    // Async like the real port, but a microtask rather than a timer, so a
    // widget test never ends with a timer still pending.
    await Future<void>.value();
    final failure = failWith;
    if (failure != null) throw failure;
    return await body();
  }

  /// Adds events as though they were already in the log: this phone's own,
  /// or, with another device id, another committee phone's pulled down by
  /// sync (#64), which [readAll] returns and [readOwn] does not.
  void seed(Iterable<EventEnvelope> events) => _events.addAll(events);

  /// Sets the admission the phone holds as though it was admitted before the
  /// test began (#74): no marker, and no call counted, as [seed] adds events.
  void seedAdmission(String admissionId) {
    validateAdmissionId(admissionId);
    _admissionId = admissionId;
  }

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

  /// What [join] runs (#71), standing in for the server sync reaches: given
  /// the code, it answers what the code granted, or throws the
  /// [CoreException] the real core would (`JoinCodes`). The fake then caches
  /// the admission as the real core does, marker included. With none set, a
  /// join is refused as `no_server`, as a core nothing is wired to is.
  Future<Admission> Function(String code)? onJoin;

  /// Every code [join] was given, in order.
  final joins = <String>[];

  /// What each admission granted (#74), as the real core keeps what sync
  /// read: a [join] records its answer here, and a test may add one, as a
  /// pull would for an admission made before #74.
  final grants = <String, ({String role, String? course})>{};

  /// The race day's race areas as sync would have kept them (#74). The fake
  /// runs no sync, so a test sets them; a [join] adds the one it granted.
  final raceAreaList = <RaceArea>[];

  RaceAreas _raceAreas() {
    final admission = _admissionId;
    if (admission == null) return RaceAreas.none;
    final grant = grants[admission];
    return RaceAreas(
      admissionId: admission,
      grantedRole: grant?.role,
      boundCourse: grant?.course,
      areas: [...raceAreaList]..sort((a, b) => a.name == b.name ? a.id.compareTo(b.id) : a.name.compareTo(b.name)),
    );
  }

  @override
  Future<RaceAreas> raceAreas() => _call(Wire.raceAreas, _raceAreas);

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
        return _addJoining(event, now);
      });

  /// As the real core does (#55): an event that joins a race the phone has no
  /// clock offset for yet has one appended just before it, at the same time.
  EventEnvelope _addJoining(NewEvent event, int now) {
    final where = location.current();
    final stamp = location.clockOffset(now);
    final join = raceToJoin(_events, event, deviceId: deviceIdValue, now: now, measuredNow: stamp.offsetMs != null);
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
  }

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
      // And the phone's station (#26), unless the event names a mark, and a
      // fleet's race area (#74), unless it names one.
      payload: event.kind == FleetKinds.defined
          ? withCourse(withStation(event.payload, currentStation(_events, deviceIdValue)),
              currentCourse(_raceAreas(), _events, deviceIdValue))
          : withStation(event.payload, currentStation(_events, deviceIdValue)),
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
        _stampAdmission(admissionId);
      });

  /// As the real core does (#71): a change of admission appends the
  /// role-change marker under the admission being left, then stamps the new
  /// one; the first admission, or the same one again, appends nothing.
  void _stampAdmission(String admissionId) {
    final old = _admissionId;
    if (old != null && old != admissionId) {
      final now = _clock();
      _add(AdmissionEvents.superseded(by: admissionId), newUlid(now, _random), now, location.current());
    }
    _admissionId = admissionId;
  }

  @override
  Future<Admission> join(String code) => _call(Wire.join, () async {
        if (code.isEmpty) throw ArgumentError.value(code, 'code', 'must be a non-empty string');
        joins.add(code);
        final handler = onJoin;
        if (handler == null) {
          throw joinException(JoinCodes.noServer, 'this core has no server to join through: nothing is wired to it');
        }
        // Through the wire form, so an answer the real core could not send
        // fails here too.
        final wire = (await handler(code)).toWire();
        requireWireSafe(wire, 'join');
        final admission = Admission.fromWire(wire);
        validateAdmissionId(admission.admissionId);
        _stampAdmission(admission.admissionId);
        // As the real core keeps what the join read (#74).
        grants[admission.admissionId] = (role: admission.role, course: admission.courseId);
        final (course, name) = (admission.courseId, admission.raceArea);
        if (course != null && name != null && !raceAreaList.any((a) => a.id == course)) {
          raceAreaList.add(RaceArea(id: course, name: name));
        }
        return admission;
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
  Future<LinkAnswer> receiveLink(String event, {required int receivedMs}) => _call(Wire.receiveLink, () {
        final LinkEvent link;
        try {
          link = LinkEvent.parse(event);
        } on FormatException catch (e) {
          return LinkAnswer(status: LinkContract.malformed, reason: e.message);
        }
        if (!_linkIds.add(link.id)) return const LinkAnswer(status: LinkContract.accepted);
        final plan = planLink(link, _events,
            deviceId: deviceIdValue, receivedMs: receivedMs, armed: () => selectedFleet(_events, deviceIdValue));
        final now = _clock();
        final stored = _addJoining(plan.event, now);
        if (plan.takenBack) _addJoining(takeBackUndo(stored.ulid, link.sequence), now);
        return const LinkAnswer(status: LinkContract.accepted, stored: true);
      });

  @override
  Future<List<EventEnvelope>> relogSequence(String sequence, String fleet) => _call(Wire.relogSequence, () {
        if (!fleets(_events).any((f) => f.id == fleet)) {
          throw ArgumentError.value(fleet, 'fleet', 'is not a fleet defined on this phone');
        }
        final moving = sequenceEvents(_events, deviceIdValue, sequence);
        if (moving.isEmpty || sequenceStanding(_events, deviceIdValue, sequence)?.fleet == fleet) {
          return const <EventEnvelope>[];
        }
        final now = _clock();
        final logged = <EventEnvelope>[
          if (selectedFleet(_events, deviceIdValue) != fleet) _addJoining(FleetEvents.select(fleet), now),
        ];
        for (final e in moving) {
          logged.add(_addJoining(StartEvents.undo(e.ulid), now));
        }
        final moved = <String, String>{};
        for (final e in moving) {
          final copy = _addJoining(relogCopy(e, fleet, moved), now);
          moved[e.ulid] = copy.ulid;
          logged.add(copy);
        }
        return logged;
      });

  @override
  Future<List<EventEnvelope>> takeBackSequence(String sequence) => _call(Wire.takeBackSequence, () {
        final now = _clock();
        return [
          for (final e in sequenceEvents(_events, deviceIdValue, sequence))
            _addJoining(takeBackUndo(e.ulid, sequence), now),
        ];
      });

  @override
  Future<void> close() => _call(Wire.close, () {});
}
