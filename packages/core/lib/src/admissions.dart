import 'envelope.dart';
import 'wire.dart';

/// The admission events (#71). A phone is admitted with a role's code (ADR
/// 005, groom decision G26); changing role is another admission, which
/// supersedes the first (#70, G44). The core writes the one kind here itself.
abstract final class AdmissionKinds {
  /// The role-change marker (groom decision G46). The core appends it under
  /// the old admission, as that admission's last event from this phone, just
  /// before it stamps the new one. The server accepts this device's events
  /// under the old admission up to the marker's own sequence number and
  /// refuses any past it (#73, `admission_superseded`); it reads only the
  /// marker's kind and `seq`. The payload names the admission that followed,
  /// so the phone's own log says where it went.
  static const superseded = 'admission.superseded';

  static const all = {superseded};
}

/// Builds the admission events. Only the core appends one.
abstract final class AdmissionEvents {
  /// Who writes a marker: the core, on its own account.
  static const source = 'core';

  /// The marker for a change to admission [by].
  static NewEvent superseded({required String by}) =>
      NewEvent(kind: AdmissionKinds.superseded, source: source, payload: {'superseded_by': by});
}

/// What a join answered (#71): the admission the server made or returned, the
/// race day it is for, and the role and race area the code granted. Plain
/// data, so it crosses the core boundary.
class Admission {
  const Admission({
    required this.admissionId,
    required this.eventId,
    required this.role,
    required this.courseId,
    required this.raceArea,
  });

  /// The committee_device row the phone's events are stamped with from now on.
  final String admissionId;

  /// The race day (event) the admission is for.
  final String eventId;

  /// One of `Roles.all`, as the code was issued.
  final String role;

  /// The race area a bound role works on, or null for an event-wide role.
  final String? courseId;

  /// That race area's name, or null for an event-wide role.
  final String? raceArea;

  Map<String, Object?> toWire() => {
        'admission_id': admissionId,
        'event_id': eventId,
        'role': role,
        'course_id': courseId,
        'race_area': raceArea,
      };

  factory Admission.fromWire(Map wire) => Admission(
        admissionId: wire['admission_id'] as String,
        eventId: wire['event_id'] as String,
        role: wire['role'] as String,
        courseId: wire['course_id'] as String?,
        raceArea: wire['race_area'] as String?,
      );

  @override
  bool operator ==(Object other) =>
      other is Admission &&
      other.admissionId == admissionId &&
      other.eventId == eventId &&
      other.role == role &&
      other.courseId == courseId &&
      other.raceArea == raceArea;

  @override
  int get hashCode => Object.hash(admissionId, eventId, role, courseId, raceArea);

  @override
  String toString() => 'Admission($role${raceArea == null ? '' : ' on $raceArea'}, $admissionId for $eventId)';
}

/// The codes a [CoreException] from `join` carries (#71), beside the core's
/// own `refused`, `invalid` and `failed`. The screen reads the code, never the
/// message, to decide what to do next.
abstract final class JoinCodes {
  /// The server judged the code and said no: unknown, another event's, a
  /// revoked phone, or a sign-in path the club does not admit. The message is
  /// one plain sentence for the volunteer, naming no role, race area or event.
  static const refused = 'join_refused';

  /// The server could not be reached. The code is kept and sent again.
  static const noSignal = 'no_signal';

  /// This core has nothing to join through: no sync engine is wired to it.
  /// On a phone that is a build without a server (#113 wires it).
  static const noServer = 'no_server';

  /// A join that could not be made and the server did not judge: a rate limit,
  /// a sign-in the server refused, the store refusing the answer.
  static const failed = 'join_failed';

  static const all = {refused, noSignal, noServer, failed};
}

/// A join the core could not make, as [CoreException]s come back over the
/// port: one of [JoinCodes.all] and a sentence.
CoreException joinException(String code, String message) {
  if (!JoinCodes.all.contains(code)) throw ArgumentError.value(code, 'code', 'is not a join code');
  return CoreException(code, message);
}
