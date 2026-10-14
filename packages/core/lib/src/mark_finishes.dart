import 'envelope.dart';
import 'finishes.dart';
import 'fleets.dart';
import 'order.dart';
import 'stations.dart';

/// A shortened course (#30): a mark-boat phone switches its station to a
/// fleet's finish. The race then finishes there, so the mark boat captures
/// the finishes itself.
///
/// Neither event names its mark: the core stamps the phone's station into
/// both (#26, owner decision 2026-10-08), so the mark is the station's.
abstract final class CourseKinds {
  /// [fleetPayloadKey]'s fleet (null on a single-fleet day) now finishes at
  /// `payload.mark`. A critical kind (groom decisions G24, G29).
  static const shortened = 'course.shortened';

  /// Takes a shortened course back. Its `correctsUlid` is the
  /// `course.shortened` it undoes.
  static const undo = 'course.undo';

  static const all = {shortened, undo};
}

/// Builds the events a shortened course appends.
abstract final class CourseEvents {
  /// [fleet] (null on a single-fleet day) now finishes at this phone's
  /// station.
  static NewEvent shortened({required String? fleet}) =>
      NewEvent(kind: CourseKinds.shortened, source: 'tap', payload: {fleetPayloadKey: fleet});

  static NewEvent undo(String shortenedUlid) =>
      NewEvent(kind: CourseKinds.undo, source: 'tap', correctsUlid: shortenedUlid);
}

/// [deviceId]'s shortened courses in force at [mark]: for each fleet, its
/// latest `course.shortened` there not undone. Scoped to one phone, as a
/// station is: another phone's, arriving by sync, never switches this one.
/// A fleet that is not shortened there is absent, and the single-fleet day
/// is the key null.
Map<String?, EventEnvelope> shortenedAt(Iterable<EventEnvelope> events,
    {required String deviceId, required String mark}) {
  final own = events.where((e) => e.deviceId == deviceId && CourseKinds.all.contains(e.kind));
  final undone = undoneBy(own, CourseKinds.undo);
  final inForce = <String?, EventEnvelope>{};
  for (final e in own.where((e) => e.kind == CourseKinds.shortened && !undone.contains(e.ulid)).toList()
    ..sort(happened)) {
    if (markOf(e) == mark) inForce[fleetOf(e)] = e;
  }
  return inForce;
}

/// True for a finish at [mark] logged for [fleet].
bool _placeAt(EventEnvelope e, String? fleet, String mark) =>
    e.kind == FinishKinds.atMark && fleetOf(e) == fleet && markOf(e) == mark;

/// [fleet]'s finishes at [mark] by time, undone ones removed, each with its
/// latest sail number. Kept apart from the line's [finishOrder]: a finish at
/// a mark never takes a place at the line, nor in provisional results.
List<FinishEntry> markFinishOrder(Iterable<EventEnvelope> events, {required String? fleet, required String mark}) {
  final undone = undoneBy(events, FinishKinds.undo);
  final kept = events.where((e) => _placeAt(e, fleet, mark) && !undone.contains(e.ulid)).toList()..sort(happened);
  final sails = <String, String>{
    for (final e in events.where((e) => e.kind == FinishKinds.sail).toList()..sort(happened))
      e.payload['finish'] as String: e.payload['sail'] as String,
  };
  return [
    for (var i = 0; i < kept.length; i++)
      FinishEntry(
        ulid: kept[i].ulid,
        place: i + 1,
        missed: false,
        deviceTs: kept[i].deviceTs,
        sail: switch (sails[kept[i].ulid]) {
          null || '' => null,
          final s => s,
        },
      ),
  ];
}

/// The finish at [mark] for [fleet] that UNDO LAST takes back: the latest one
/// not already undone. Null when there is none.
EventEnvelope? lastUndoableMarkFinish(Iterable<EventEnvelope> events,
    {required String? fleet, required String mark}) {
  final undone = undoneBy(events, FinishKinds.undo);
  final candidates = events.where((e) => _placeAt(e, fleet, mark) && !undone.contains(e.ulid)).toList()
    ..sort(happened);
  return candidates.isEmpty ? null : candidates.last;
}

/// The fleet a finish-at-mark screen opens on: of the fleets [deviceId] has
/// shortened at [mark], the one it last shortened or last finished a boat
/// for. Null when no fleet finishes there. A record, because the
/// single-fleet day's fleet is null.
({String? fleet})? lastMarkFleet(Iterable<EventEnvelope> events, {required String deviceId, required String mark}) {
  final inForce = shortenedAt(events, deviceId: deviceId, mark: mark);
  final touched = [
    ...inForce.values,
    for (final e in events)
      if (e.kind == FinishKinds.atMark &&
          e.deviceId == deviceId &&
          markOf(e) == mark &&
          inForce.containsKey(fleetOf(e)))
        e,
  ]..sort(happened);
  return touched.isEmpty ? null : (fleet: fleetOf(touched.last));
}
