import 'envelope.dart';
import 'fleets.dart';
import 'order.dart';

/// Finish capture (#4): the event kinds a finish screen appends, and the
/// finish order derived from them. Nothing here edits an event - an undo, a
/// missed finish and a sail number are each a new event (ADR 001).
///
/// Finishes are partitioned by fleet (#18): a finish and a missed finish carry
/// their fleet, so each fleet has its own places. A sail number and an undo
/// name the finish they apply to, so they follow it.
abstract final class FinishKinds {
  /// A boat crossed the line. Its time is the envelope's device timestamp.
  static const finish = 'finish';

  /// A boat that was missed, placed between two recorded finishes. Its time
  /// is unknown; `payload.gap` is the marker.
  static const missed = 'finish.missed';

  /// A sail number for a finish or missed finish. The latest one wins.
  static const sail = 'finish.sail';

  /// Takes a finish or missed finish back out of the order. Its
  /// `correctsUlid` is the event it undoes.
  static const undo = 'finish.undo';

  static const all = {finish, missed, sail, undo};
}

/// Builds the events a finish screen appends.
abstract final class FinishEvents {
  /// A finish for [fleet] (null on a single-fleet day).
  static NewEvent finish({required String? fleet}) =>
      NewEvent(kind: FinishKinds.finish, source: 'tap', payload: {fleetPayloadKey: fleet});

  static NewEvent undo(String entryUlid) =>
      NewEvent(kind: FinishKinds.undo, source: 'tap', correctsUlid: entryUlid);

  /// A missed finish for [fleet], placed immediately before [beforeUlid] and
  /// after [afterUlid] (null when it goes first).
  static NewEvent missed({required String? fleet, required String? afterUlid, required String beforeUlid}) =>
      NewEvent(
        kind: FinishKinds.missed,
        source: 'tap',
        payload: {fleetPayloadKey: fleet, 'gap': true, 'after': afterUlid, 'before': beforeUlid},
      );

  static NewEvent assignSail(String entryUlid, String sail) => NewEvent(
        kind: FinishKinds.sail,
        source: 'tap',
        payload: {'finish': entryUlid, 'sail': sail},
      );
}

/// One place in the finish order.
class FinishEntry {
  const FinishEntry({
    required this.ulid,
    required this.place,
    required this.missed,
    this.deviceTs,
    this.sail,
  });

  /// The finish or missed-finish event this place stands for.
  final String ulid;
  final int place;

  /// True for a missed finish, whose time is unknown.
  final bool missed;

  /// When the boat was tapped; null for a missed finish.
  final int? deviceTs;
  final String? sail;

  @override
  String toString() => 'FinishEntry($place ${missed ? 'missed' : deviceTs} ${sail ?? '-'} $ulid)';
}

/// True for a finish or missed finish logged for [fleet].
bool _placeIn(EventEnvelope e, String? fleet) =>
    (e.kind == FinishKinds.finish || e.kind == FinishKinds.missed) && fleetOf(e) == fleet;

/// The finish or missed finish of [fleet] that "Undo last" takes back: the
/// most recently logged one not already undone. Null when there is none.
EventEnvelope? lastUndoableFinish(Iterable<EventEnvelope> events, {required String? fleet}) {
  final undone = undoneBy(events, FinishKinds.undo);
  final candidates = events.where((e) => _placeIn(e, fleet) && !undone.contains(e.ulid)).toList()..sort(happened);
  return candidates.isEmpty ? null : candidates.last;
}

/// The ULID of [lastUndoableFinish], or null.
String? lastUndoable(Iterable<EventEnvelope> events, {required String? fleet}) =>
    lastUndoableFinish(events, fleet: fleet)?.ulid;

/// Derives [fleet]'s finish order from the log: its finishes by time, each
/// missed finish between the two it was placed between, undone places
/// removed, and each place's latest sail number. Another fleet's finishes
/// never take a place here.
List<FinishEntry> finishOrder(Iterable<EventEnvelope> events, {required String? fleet}) {
  final log = events
      .where((e) => _placeIn(e, fleet) || e.kind == FinishKinds.sail || e.kind == FinishKinds.undo)
      .toList()
    ..sort(happened);

  // Finishes in time order first, then each missed finish slotted in, in the
  // order they were logged - so two misses placed in one gap keep their order.
  final order = <EventEnvelope>[
    for (final e in log)
      if (e.kind == FinishKinds.finish) e,
  ];
  for (final m in log.where((e) => e.kind == FinishKinds.missed)) {
    final before = order.indexWhere((e) => e.ulid == m.payload['before']);
    if (before >= 0) {
      order.insert(before, m);
      continue;
    }
    final after = order.indexWhere((e) => e.ulid == m.payload['after']);
    order.insert(after >= 0 ? after + 1 : order.length, m);
  }

  final undone = undoneBy(log, FinishKinds.undo);
  final sails = <String, String>{
    for (final e in log)
      if (e.kind == FinishKinds.sail) e.payload['finish'] as String: e.payload['sail'] as String,
  };

  final kept = order.where((e) => !undone.contains(e.ulid)).toList();
  return [
    for (var i = 0; i < kept.length; i++)
      FinishEntry(
        ulid: kept[i].ulid,
        place: i + 1,
        missed: kept[i].kind == FinishKinds.missed,
        deviceTs: kept[i].kind == FinishKinds.missed ? null : kept[i].deviceTs,
        sail: switch (sails[kept[i].ulid]) {
          null || '' => null,
          final s => s,
        },
      ),
  ];
}
