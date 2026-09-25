import 'envelope.dart';
import 'fleets.dart';
import 'order.dart';

/// Starts, keyed by fleet (#18). The events a start is made of, and each
/// fleet's race state derived from them. #25 logs them by hand
/// (`source: manual`) and #33 from race-timer (`source: race-timer`); both
/// build them here, so neither can log a start without a fleet.
abstract final class StartKinds {
  /// A fleet's start gun. Its time is the envelope's device timestamp.
  static const start = 'start';

  /// A general recall of a fleet's start: that start no longer anchors
  /// elapsed time, and nothing does until the fleet's next gun.
  static const generalRecall = 'start.general_recall';

  static const all = {start, generalRecall};
}

/// Builds start events. [fleet] is required, and null only on a day run as a
/// single fleet.
abstract final class StartEvents {
  static NewEvent start({required String? fleet, required String source}) =>
      NewEvent(kind: StartKinds.start, source: source, payload: {fleetPayloadKey: fleet});

  static NewEvent generalRecall({required String? fleet, required String source}) =>
      NewEvent(kind: StartKinds.generalRecall, source: source, payload: {fleetPayloadKey: fleet});
}

/// One fleet's race state: what its starts and recalls add up to.
class FleetRaceState {
  const FleetRaceState({required this.starts, required this.recalls, this.anchorUlid});

  /// Guns logged for the fleet.
  final int starts;

  /// General recalls logged for the fleet.
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

List<EventEnvelope> _startsOf(Iterable<EventEnvelope> events, String? fleet) =>
    events.where((e) => StartKinds.all.contains(e.kind) && fleetOf(e) == fleet).toList()..sort(happened);

/// [fleet]'s race state. Another fleet's starts and recalls never enter it.
FleetRaceState raceState(Iterable<EventEnvelope> events, String? fleet) {
  var starts = 0;
  var recalls = 0;
  String? anchor;
  for (final e in _startsOf(events, fleet)) {
    if (e.kind == StartKinds.start) {
      starts++;
      anchor = e.ulid;
    } else {
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
