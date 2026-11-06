import 'envelope.dart';
import 'fleets.dart';
import 'order.dart';
import 'race_areas.dart';

/// Same-named fleets from several phones (#76). A fleet is its `fleet.defined`
/// event and its id is that event's ULID (#18), so two phones that each named
/// "Lasers" before they had signal hold two fleets. Sync uploads both, and the
/// server keeps both: no phone writes `public.fleet`, so nothing collides on
/// its unique name (#75). What splits is every view that reads more than one
/// phone: the PRO's gun under one id and the recorder's finishes under the
/// other would be two fleet races, the finishes with no gun.
///
/// So the core reads them as one fleet (owner decision at #76's pickup,
/// 2026-11-05). Fleets with the same name, trimmed and ignoring case as FLEETS
/// already compares names, on the same race area are one fleet, and its id is
/// the first of them defined, in [happened] order. Nothing is rewritten: every
/// event keeps the fleet id its phone gave it, and each read resolves that id
/// here ([resolve], [apply]). Every phone holding the same definitions reaches
/// the same answer, so no event records the merge.
///
/// A fleet's race area is the course its `fleet.defined` names in
/// `payload.course` (#74). One that names none is listed on every race area
/// ([onCourse]), so it joins the one race area its name is defined on. When
/// one name is defined on two race areas or more, the fleets are not merged
/// across them, and a fleet naming none joins none of them, since it could be
/// either. Every fleet of that name is then [conflicted], for a PRO to see.
class FleetMerge {
  FleetMerge._(this._aliases, this._conflicts);

  /// No fleet merged and none conflicted.
  static final none = FleetMerge._(const {}, const {});

  /// The merge [events] call for, read from every `fleet.defined` among them.
  factory FleetMerge.of(Iterable<EventEnvelope> events) {
    final byName = <String, List<EventEnvelope>>{};
    for (final e in events) {
      if (e.kind != FleetKinds.defined) continue;
      final name = e.payload['name'];
      if (name is! String) continue;
      (byName[_key(name)] ??= []).add(e);
    }
    final aliases = <String, String>{};
    final conflicts = <String, Set<String>>{};
    for (final defined in byName.values) {
      if (defined.length < 2) continue;
      defined.sort(happened);
      final courses = {for (final e in defined) ?_courseOf(e)};
      if (courses.length <= 1) {
        for (final e in defined.skip(1)) {
          aliases[e.ulid] = defined.first.ulid;
        }
        continue;
      }
      for (final course in courses) {
        final on = [for (final e in defined) if (_courseOf(e) == course) e];
        for (final e in on.skip(1)) {
          aliases[e.ulid] = on.first.ulid;
        }
      }
      for (final e in defined) {
        conflicts[e.ulid] = {
          for (final other in defined)
            if (other.ulid != e.ulid && _courseOf(other) != _courseOf(e)) ?_courseOf(other),
        };
      }
    }
    return aliases.isEmpty && conflicts.isEmpty ? none : FleetMerge._(aliases, conflicts);
  }

  /// Merged-away fleet id → the id of the fleet it is read as.
  final Map<String, String> _aliases;

  /// Fleet id → the course ids of the race areas another fleet of its name
  /// is defined on. A fleet naming no race area is listed with an empty set.
  final Map<String, Set<String>> _conflicts;

  /// True when some fleet is read as another.
  bool get merges => _aliases.isNotEmpty;

  /// The id [fleet] is read as: the first same-named fleet on its race area,
  /// or [fleet] itself. Null stays null, a single-fleet day's.
  String? resolve(String? fleet) => fleet == null ? null : _aliases[fleet] ?? fleet;

  /// True when [fleet] is read as another fleet.
  bool mergedAway(String fleet) => _aliases.containsKey(fleet);

  /// True when [fleet]'s name is defined on more than one race area (#76
  /// criterion 4).
  bool conflicted(String fleet) => _conflicts.containsKey(fleet);

  /// The course ids of the other race areas [fleet]'s name is defined on,
  /// none when it is not [conflicted] or the others name no race area.
  Set<String> conflictingCourses(String fleet) => _conflicts[fleet] ?? const {};

  /// [events] as a view reading more than one phone reads them: each event's
  /// `payload.fleet` [resolve]d, and the definitions of merged-away fleets
  /// left out, so [fleets] lists each fleet once. The events themselves are
  /// not changed, and the copies are never stored: they are for reading.
  /// With nothing merged, [events] come back as they are.
  List<EventEnvelope> apply(Iterable<EventEnvelope> events) {
    if (_aliases.isEmpty) return events is List<EventEnvelope> ? events : events.toList();
    return [
      for (final e in events)
        if (!(e.kind == FleetKinds.defined && _aliases.containsKey(e.ulid)))
          switch (e.payload[fleetPayloadKey]) {
            final String f when _aliases.containsKey(f) => _withFleet(e, _aliases[f]!),
            _ => e,
          },
    ];
  }

  static String _key(String name) => name.trim().toLowerCase();

  static String? _courseOf(EventEnvelope defined) => switch (defined.payload[coursePayloadKey]) {
        final String c => c,
        _ => null,
      };

  static EventEnvelope _withFleet(EventEnvelope e, String fleet) => EventEnvelope(
        ulid: e.ulid,
        deviceTs: e.deviceTs,
        deviceId: e.deviceId,
        seq: e.seq,
        source: e.source,
        kind: e.kind,
        payloadVersion: e.payloadVersion,
        payload: {...e.payload, fleetPayloadKey: fleet},
        person: e.person,
        role: e.role,
        admissionId: e.admissionId,
        gps: e.gps,
        gpsReason: e.gpsReason,
        correctsUlid: e.correctsUlid,
        prevHash: e.prevHash,
        extra: e.extra,
      );

  @override
  String toString() => 'FleetMerge(${_aliases.length} merged, ${_conflicts.length} conflicted)';
}
