import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'roles.dart';

/// A real Crockford ULID, so an undo a test or the bar check taps on it is
/// accepted by the core, as on a phone.
String fixtureUlid(int n) => '01J8${n.toString().padLeft(22, '0')}';

/// One event as race-timer sends it (ADR 004), for [FakeCore.receiveLink].
String linkEvent(
  String kind, {
  required String id,
  required int atMs,
  String sequence = 'seq-1',
  Map<String, Object?> fields = const {},
}) =>
    jsonEncode({'v': 1, 'id': id, 'kind': kind, 'at_ms': atMs, 'sequence': sequence, ...fields});

const _kinds = {
  LinkContract.sequenceStart: StartKinds.sequenceStart,
  LinkContract.signal: StartKinds.signal,
  LinkContract.postponement: StartKinds.postponement,
  LinkContract.individualRecall: StartKinds.individualRecall,
  LinkContract.generalRecall: StartKinds.generalRecall,
  LinkContract.start: StartKinds.start,
};

/// The event [FakeCore.receiveLink] would have stored for a [kind] from the
/// contract, for a fixture that has to exist before the app does: a bar check
/// builds its app synchronously, and a receipt is a Future.
EventEnvelope raceTimerEvent(
  String kind, {
  required String ulid,
  required String deviceId,
  required int seq,
  required String? fleet,
  required int atMs,
  int? receivedMs,
  int? deviceTs,
  String sequence = 'seq-1',
  Map<String, Object?> fields = const {},
}) =>
    EventEnvelope(
      ulid: ulid,
      deviceTs: deviceTs ?? receivedMs ?? atMs,
      deviceId: deviceId,
      seq: seq,
      source: raceTimerSource,
      kind: _kinds[kind]!,
      payloadVersion: 1,
      payload: {
        fleetPayloadKey: fleet,
        linkAtKey: atMs,
        linkReceivedKey: receivedMs ?? atMs,
        linkSequenceKey: sequence,
        linkFieldsKey: jsonDecode(linkEvent(kind, id: ulid, atMs: atMs, sequence: sequence, fields: fields)),
      },
    );

/// A race day race-timer ran, for a bar check: three fleets named and Lasers
/// selected, a sequence up to its gun, and a full list of finishes, so every
/// race-time action in the app can exist and UNDO opens the right-fleet
/// picker. With [linkUp] its last arrival is a few minutes before [now], the
/// phone's clock in the app under test, and the banner is down; without, it
/// is twenty minutes before, and the banner is up.
FakeCore raceTimerDay({required int now, bool linkUp = true}) {
  var t = now - (linkUp ? 2 : 20) * 60000;
  var seq = 0;
  final day = withRole(FakeCore(clock: () => t += 1000));
  EventEnvelope event(String kind, Map<String, Object?> payload) => EventEnvelope(
        ulid: fixtureUlid(++seq),
        deviceTs: t += 1000,
        deviceId: day.deviceIdValue,
        seq: seq,
        source: 'tap',
        kind: kind,
        payloadVersion: 1,
        payload: payload,
      );
  EventEnvelope signal(String kind, {Map<String, Object?> fields = const {}, required String fleet}) {
    final at = t += 1000;
    return raceTimerEvent(kind,
        ulid: fixtureUlid(++seq),
        deviceId: day.deviceIdValue,
        seq: seq,
        fleet: fleet,
        atMs: at,
        fields: fields);
  }

  final fleets = [
    for (final name in ['Lasers', '420s', 'Optis']) event(FleetKinds.defined, {'name': name, 'class': null}),
  ];
  day.seed(fleets);
  final fleet = fleets.first.ulid;
  day.seed([
    event(FleetKinds.selected, {fleetPayloadKey: fleet}),
    signal(LinkContract.sequenceStart, fleet: fleet, fields: {'sequence_name': '5-4-1-0'}),
    signal(LinkContract.signal, fleet: fleet, fields: {'signal': 'warning', 'seconds_to_start': 300}),
    signal(LinkContract.start, fleet: fleet),
    for (var i = 0; i < 12; i++) event(FinishKinds.finish, {fleetPayloadKey: fleet}),
  ]);
  return day;
}
