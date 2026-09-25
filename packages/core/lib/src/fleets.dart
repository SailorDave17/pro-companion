import 'envelope.dart';
import 'order.dart';

/// Fleets (#18): several classes racing one day, each with its own starts,
/// course and results. A fleet is defined by an event, and its id is that
/// event's ULID, so a phone can create one offline. Every race-time event
/// carries its fleet in `payload.fleet` ([fleetPayloadKey]); an event with no
/// fleet belongs to a day run as a single fleet.
abstract final class FleetKinds {
  /// A fleet named on this phone. `payload.name`, and `payload.class` or null.
  static const defined = 'fleet.defined';

  /// This phone now logs race-time events for `payload.fleet`.
  static const selected = 'fleet.selected';

  /// Takes a fleet switch back. Its `correctsUlid` is the switch it undoes;
  /// the phone returns to the fleet it had before.
  static const undo = 'fleet.undo';

  static const all = {defined, selected, undo};
}

/// The payload key every race-time event carries its fleet in.
const fleetPayloadKey = 'fleet';

/// The fleet [e] was logged for, or null for a single-fleet day.
String? fleetOf(EventEnvelope e) => e.payload[fleetPayloadKey] as String?;

/// Builds the events that define and switch fleets.
abstract final class FleetEvents {
  static NewEvent define(String name, {String? klass}) {
    final trimmedClass = klass?.trim();
    return NewEvent(
      kind: FleetKinds.defined,
      source: 'tap',
      payload: {
        'name': name.trim(),
        'class': trimmedClass == null || trimmedClass.isEmpty ? null : trimmedClass,
      },
    );
  }

  static NewEvent select(String fleet) =>
      NewEvent(kind: FleetKinds.selected, source: 'tap', payload: {fleetPayloadKey: fleet});

  static NewEvent undo(String switchUlid) =>
      NewEvent(kind: FleetKinds.undo, source: 'tap', correctsUlid: switchUlid);
}

/// A fleet, as defined.
class Fleet {
  const Fleet({required this.id, required this.name, this.klass});

  /// The ULID of the event that defined it.
  final String id;
  final String name;

  /// The boat class, when the PRO gave one.
  final String? klass;

  @override
  String toString() => 'Fleet($name${klass == null ? '' : ' / $klass'} $id)';
}

/// Every fleet defined, in the order they were defined.
List<Fleet> fleets(Iterable<EventEnvelope> events) => [
      for (final e in events.where((e) => e.kind == FleetKinds.defined).toList()..sort(happened))
        Fleet(id: e.ulid, name: e.payload['name'] as String, klass: e.payload['class'] as String?),
    ];

/// [deviceId]'s fleet switches that have not been undone, oldest first. A
/// switch names a fleet that is defined; one that does not is ignored.
List<EventEnvelope> _switches(Iterable<EventEnvelope> events, String deviceId) {
  final undone = undoneBy(events, FleetKinds.undo);
  final defined = {for (final f in fleets(events)) f.id};
  return events
      .where((e) =>
          e.kind == FleetKinds.selected &&
          e.deviceId == deviceId &&
          !undone.contains(e.ulid) &&
          defined.contains(fleetOf(e)))
      .toList()
    ..sort(happened);
}

/// The fleet [deviceId] is logging for, or null. Scoped to one phone: another
/// phone's switch, arriving by sync, never moves this one.
String? selectedFleet(Iterable<EventEnvelope> events, String deviceId) {
  final s = _switches(events, deviceId);
  return s.isEmpty ? null : fleetOf(s.last);
}

/// The fleets [deviceId] has switched to, most recent first, each once. What
/// a finish screen with too many fleets for one row puts within reach.
List<String> recentFleets(Iterable<EventEnvelope> events, String deviceId) {
  final seen = <String>{};
  return [
    for (final s in _switches(events, deviceId).reversed)
      if (seen.add(fleetOf(s)!)) fleetOf(s)!,
  ];
}

/// The switch that "Undo" on [deviceId] would take back: its latest one not
/// already undone. Null when there is none.
EventEnvelope? lastFleetSwitch(Iterable<EventEnvelope> events, String deviceId) {
  final s = _switches(events, deviceId);
  return s.isEmpty ? null : s.last;
}
