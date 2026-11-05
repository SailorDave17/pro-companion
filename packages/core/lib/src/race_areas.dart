import 'envelope.dart';
import 'order.dart';
import 'roles.dart';

/// Race areas on a phone (#74). A race area is a `course` row on the server
/// (#58), created by the owner script (G27), so a phone only reads them. A
/// phone admitted with a bound role (course PRO, recorder, mark boat) works on
/// the race area its admission names, fixed. One admitted with an event-wide
/// role (overall PRO, scorer, safety) picks one, and the pick is kept in the
/// log like a station (#26). A phone that was never admitted (single-phone
/// use, milestone 1) has one implicit race area and no picker.
abstract final class RaceAreaKinds {
  /// This phone now works on race area `payload.course`, a course id.
  static const selected = 'race_area.selected';

  /// Takes a race-area pick back. Its `correctsUlid` is the pick it undoes;
  /// the phone returns to the race area it had before, or to none.
  static const undo = 'race_area.undo';

  static const all = {selected, undo};
}

/// The payload key a `fleet.defined` carries its race area's course id in
/// (#74 criterion 3), and a race-area pick its pick. The server reads a
/// fleet's race area from it (#75, `docs/roles.md`).
const coursePayloadKey = 'course';

/// Builds the events a race-area pick appends.
abstract final class RaceAreaEvents {
  /// A pick of the race area whose course id is [courseId].
  static NewEvent select(String courseId) {
    if (courseId.trim().isEmpty) throw ArgumentError.value(courseId, 'courseId', 'is empty');
    return NewEvent(kind: RaceAreaKinds.selected, source: 'tap', payload: {coursePayloadKey: courseId});
  }

  static NewEvent undo(String pickUlid) => NewEvent(kind: RaceAreaKinds.undo, source: 'tap', correctsUlid: pickUlid);
}

/// One race area of a race day, as the server's `course` table holds it.
class RaceArea {
  const RaceArea({required this.id, required this.name});

  /// The course id (a UUID), which a fleet names in `payload.course`.
  final String id;
  final String name;

  Map<String, Object?> toWire() => {'id': id, 'name': name};

  factory RaceArea.fromWire(Map wire) => RaceArea(id: wire['id'] as String, name: wire['name'] as String);

  @override
  bool operator ==(Object other) => other is RaceArea && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'RaceArea($name $id)';
}

/// What a phone knows about race areas (#74): the admission it holds, what
/// that admission granted, and the race day's race areas, fetched once with
/// signal and kept offline. Plain data, so it crosses the core boundary.
class RaceAreas {
  const RaceAreas({this.admissionId, this.grantedRole, this.boundCourse, this.areas = const []});

  /// A phone that was never admitted.
  static const none = RaceAreas();

  /// The admission the phone holds, or null when it was never admitted.
  final String? admissionId;

  /// The role that admission granted, or null while sync has not learned it.
  final String? grantedRole;

  /// The course id of the race area a bound role's admission names, or null.
  final String? boundCourse;

  /// The race day's race areas, by name. Empty until they are fetched.
  final List<RaceArea> areas;

  bool get admitted => admissionId != null;

  /// The admission's grant is known. Until it is, the phone shows no race
  /// area and offers no picker: a bound phone must never be offered one.
  bool get granted => admitted && grantedRole != null;

  /// Admitted to a bound role: its race area is fixed.
  bool get bound => granted && boundCourse != null;

  /// Admitted to an event-wide role: this phone picks its race area.
  bool get picks => granted && boundCourse == null;

  /// The race area whose course id is [id], or null when it is not cached.
  RaceArea? byId(String? id) => id == null ? null : areas.where((a) => a.id == id).firstOrNull;

  Map<String, Object?> toWire() => {
        'admission_id': admissionId,
        'granted_role': grantedRole,
        'bound_course': boundCourse,
        'areas': [for (final a in areas) a.toWire()],
      };

  factory RaceAreas.fromWire(Map wire) => RaceAreas(
        admissionId: wire['admission_id'] as String?,
        grantedRole: wire['granted_role'] as String?,
        boundCourse: wire['bound_course'] as String?,
        areas: [for (final a in wire['areas'] as List) RaceArea.fromWire(a as Map)],
      );

  @override
  String toString() =>
      'RaceAreas(${admissionId ?? 'not admitted'}${grantedRole == null ? '' : ' as $grantedRole'}'
      '${boundCourse == null ? '' : ' on $boundCourse'}, ${areas.length} areas)';
}

/// [deviceId]'s race-area pick in force: its latest not undone, made under
/// [admissionId] and since the phone's role pick in force. A new admission or
/// a new role pick starts with no race area. Scoped to one phone: another
/// phone's pick, arriving by sync, never moves this one.
EventEnvelope? currentRaceAreaPick(Iterable<EventEnvelope> events, String deviceId, String? admissionId) {
  if (admissionId == null) return null;
  final role = currentRolePick(events, deviceId);
  if (role == null) return null;
  final own = events.where((e) => e.deviceId == deviceId && RaceAreaKinds.all.contains(e.kind)).toList();
  final undone = undoneBy(own, RaceAreaKinds.undo);
  final picks = own
      .where((e) =>
          e.kind == RaceAreaKinds.selected &&
          e.admissionId == admissionId &&
          !undone.contains(e.ulid) &&
          happened(e, role) > 0)
      .toList()
    ..sort(happened);
  return picks.isEmpty ? null : picks.last;
}

/// The course id of the race area [deviceId] works on (#74), or null for a
/// phone with one implicit race area (never admitted), one whose grant is not
/// known yet, and an event-wide phone that has picked none.
String? currentCourse(RaceAreas info, Iterable<EventEnvelope> events, String deviceId) {
  if (!info.granted) return null;
  if (info.bound) return info.boundCourse;
  final pick = currentRaceAreaPick(events, deviceId, info.admissionId);
  final course = pick?.payload[coursePayloadKey];
  return course is String ? course : null;
}

/// [payload] as a `fleet.defined` is stored on a phone working on [course]:
/// with the course id in [coursePayloadKey], unless it names one of its own.
Map<String, Object?> withCourse(Map<String, Object?> payload, String? course) =>
    course == null || payload.containsKey(coursePayloadKey) ? payload : {...payload, coursePayloadKey: course};

/// The fleets a phone on [course] lists (#74): those defined on it, and those
/// that name no race area (a single-race-area day's, or one defined before
/// #74). With no course every fleet is listed, as before #74.
bool onCourse(EventEnvelope fleetDefined, String? course) {
  if (course == null) return true;
  final c = fleetDefined.payload[coursePayloadKey];
  return c == null || c == course;
}
