import 'envelope.dart';
import 'fleets.dart';
import 'order.dart';

/// Starts, keyed by fleet (#18). The events a start is made of, and each
/// fleet's race state derived from them. #25 logs them by hand
/// (`source: manual`) and #33 from race-timer (`source: race-timer`); both
/// build them here, so neither can log a start without a fleet.
///
/// Nothing here edits an event (ADR 001): a gun's corrected time, and an
/// undo, are each a new event naming the one they apply to.
abstract final class StartKinds {
  /// A fleet's start gun. Its time is the envelope's device timestamp.
  static const start = 'start';

  /// A general recall of a fleet's start: that start no longer anchors
  /// elapsed time, and nothing does until the fleet's next gun.
  static const generalRecall = 'start.general_recall';

  /// A postponement of a fleet's start (#25), logged as its own row. It moves
  /// no anchor: a start not yet made has none to move, and one already made
  /// is recalled, not postponed.
  static const postponement = 'start.postponement';

  /// The real time of a gun tapped late or wrong (#25). `payload.time` is the
  /// time, and `correctsUlid` names the start, which is kept as tapped.
  static const timeCorrected = 'start.time_corrected';

  /// Takes a start, postponement, recall or time correction back. Its
  /// `correctsUlid` is the event it undoes.
  static const undo = 'start.undo';

  /// The events that make up a fleet's sequence. Each carries its fleet; a
  /// time correction and an undo name the event they apply to, so they
  /// follow it.
  static const sequence = {start, postponement, generalRecall};

  static const all = {start, generalRecall, postponement, timeCorrected, undo};
}

/// Builds start events. [fleet] is required, and null only on a day run as a
/// single fleet.
abstract final class StartEvents {
  static NewEvent start({required String? fleet, required String source}) =>
      NewEvent(kind: StartKinds.start, source: source, payload: {fleetPayloadKey: fleet});

  static NewEvent generalRecall({required String? fleet, required String source}) =>
      NewEvent(kind: StartKinds.generalRecall, source: source, payload: {fleetPayloadKey: fleet});

  static NewEvent postponement({required String? fleet, required String source}) =>
      NewEvent(kind: StartKinds.postponement, source: source, payload: {fleetPayloadKey: fleet});

  /// The time [startUlid]'s gun really went, typed by hand, in milliseconds
  /// since the epoch.
  static NewEvent correctTime(String startUlid, {required int time}) => NewEvent(
        kind: StartKinds.timeCorrected,
        source: 'manual',
        correctsUlid: startUlid,
        payload: {'time': time},
      );

  static NewEvent undo(String eventUlid) => NewEvent(kind: StartKinds.undo, source: 'tap', correctsUlid: eventUlid);
}

/// One fleet's race state: what its starts and recalls add up to.
class FleetRaceState {
  const FleetRaceState({required this.starts, required this.recalls, this.anchorUlid});

  /// Guns logged for the fleet, and not undone.
  final int starts;

  /// General recalls logged for the fleet, and not undone.
  final int recalls;

  /// The start elapsed time is measured from: the fleet's most recent start
  /// not recalled since. Null before the first gun and after a recall.
  final String? anchorUlid;

  @override
  bool operator ==(Object other) =>
      other is FleetRaceState && other.starts == starts && other.recalls == recalls && other.anchorUlid == anchorUlid;

  @override
  int get hashCode => Object.hash(starts, recalls, anchorUlid);

  @override
  String toString() => 'FleetRaceState(starts: $starts, recalls: $recalls, anchor: $anchorUlid)';
}

/// [fleet]'s starts, postponements and recalls that have not been undone, in
/// the order they happened. Another fleet's never enter it.
List<EventEnvelope> sequenceOf(Iterable<EventEnvelope> events, String? fleet) {
  final undone = undoneBy(events, StartKinds.undo);
  return events
      .where((e) => StartKinds.sequence.contains(e.kind) && fleetOf(e) == fleet && !undone.contains(e.ulid))
      .toList()
    ..sort(happened);
}

/// [fleet]'s race state. Another fleet's starts and recalls never enter it,
/// and neither does anything undone.
FleetRaceState raceState(Iterable<EventEnvelope> events, String? fleet) {
  var starts = 0;
  var recalls = 0;
  String? anchor;
  for (final e in sequenceOf(events, fleet)) {
    if (e.kind == StartKinds.start) {
      starts++;
      anchor = e.ulid;
    } else if (e.kind == StartKinds.generalRecall) {
      recalls++;
      anchor = null;
    }
  }
  return FleetRaceState(starts: starts, recalls: recalls, anchorUlid: anchor);
}

/// The start [fleet]'s elapsed time is measured from: its most recent start
/// not recalled since, or null.
EventEnvelope? elapsedAnchor(Iterable<EventEnvelope> events, String? fleet) {
  final anchor = raceState(events, fleet).anchorUlid;
  if (anchor == null) return null;
  return events.firstWhere((e) => e.ulid == anchor);
}

/// [start]'s time corrections that have not been undone, in the order they
/// were made.
List<EventEnvelope> _timeFixesOf(Iterable<EventEnvelope> events, EventEnvelope start) {
  final undone = undoneBy(events, StartKinds.undo);
  return events
      .where((e) => e.kind == StartKinds.timeCorrected && e.correctsUlid == start.ulid && !undone.contains(e.ulid))
      .toList()
    ..sort(happened);
}

/// When [start]'s gun went, in milliseconds since the epoch: its latest time
/// correction not undone, or else the device time it was tapped at.
int gunTime(Iterable<EventEnvelope> events, EventEnvelope start) {
  final fixes = _timeFixesOf(events, start);
  return fixes.isEmpty ? start.deviceTs : fixes.last.payload['time'] as int;
}

/// The time [fleet]'s elapsed time is measured from - its anchor's
/// [gunTime] - or null when it has no anchor.
int? anchorTime(Iterable<EventEnvelope> events, String? fleet) {
  final anchor = elapsedAnchor(events, fleet);
  return anchor == null ? null : gunTime(events, anchor);
}

/// The sequence event of [fleet] that "Undo last" takes back: the most
/// recently logged of its starts, postponements, recalls and time
/// corrections not already undone. Null when there is none.
EventEnvelope? lastUndoableStart(Iterable<EventEnvelope> events, {required String? fleet}) {
  final own = sequenceOf(events, fleet);
  final candidates = [
    ...own,
    for (final s in own)
      if (s.kind == StartKinds.start) ..._timeFixesOf(events, s),
  ]..sort(happened);
  return candidates.isEmpty ? null : candidates.last;
}
