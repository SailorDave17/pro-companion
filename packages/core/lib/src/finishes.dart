import 'envelope.dart';

/// Finish capture (#4): the event kinds a finish screen appends, and the
/// finish order derived from them. Nothing here edits an event - an undo, a
/// missed finish and a sail number are each a new event (ADR 001).
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
  static NewEvent finish() => const NewEvent(kind: FinishKinds.finish, source: 'tap');

  static NewEvent undo(String entryUlid) =>
      NewEvent(kind: FinishKinds.undo, source: 'tap', correctsUlid: entryUlid);

  /// A missed finish placed immediately before [beforeUlid] and after
  /// [afterUlid] (null when it goes first).
  static NewEvent missed({required String? afterUlid, required String beforeUlid}) => NewEvent(
        kind: FinishKinds.missed,
        source: 'tap',
        payload: {'gap': true, 'after': afterUlid, 'before': beforeUlid},
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

/// The order finish events happened in: device time, then device, then - for
/// two events one phone logged in the same millisecond - that phone's
/// sequence number, which is the order they were tapped. ADR 001's log order
/// breaks that tie by ULID, whose random tail can invert two taps; the finish
/// order must not.
int _happened(EventEnvelope a, EventEnvelope b) {
  final byTs = a.deviceTs.compareTo(b.deviceTs);
  if (byTs != 0) return byTs;
  final byDevice = a.deviceId.compareTo(b.deviceId);
  if (byDevice != 0) return byDevice;
  final bySeq = a.seq.compareTo(b.seq);
  return bySeq != 0 ? bySeq : a.ulid.compareTo(b.ulid);
}

/// The finish or missed finish that "Undo last" takes back: the most recently
/// logged one not already undone. Null when there is none.
String? lastUndoable(Iterable<EventEnvelope> events) {
  final undone = {
    for (final e in events)
      if (e.kind == FinishKinds.undo) e.correctsUlid,
  };
  final candidates = events
      .where((e) => (e.kind == FinishKinds.finish || e.kind == FinishKinds.missed) && !undone.contains(e.ulid))
      .toList()
    ..sort(_happened);
  return candidates.isEmpty ? null : candidates.last.ulid;
}

/// Derives the finish order from the log: finishes by time, each missed
/// finish between the two it was placed between, undone places removed, and
/// each place's latest sail number.
List<FinishEntry> finishOrder(Iterable<EventEnvelope> events) {
  final log = events.where((e) => FinishKinds.all.contains(e.kind)).toList()..sort(_happened);

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

  final undone = {
    for (final e in log)
      if (e.kind == FinishKinds.undo && e.correctsUlid != null) e.correctsUlid!,
  };
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
