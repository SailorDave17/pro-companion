import 'envelope.dart';
import 'order.dart';

/// Committee roles (#20): the job a phone does on the day. A phone runs as one
/// role at a time, picked on the phone and kept in the log, so a restart, and
/// every later event, knows it. Restricting the pick to the role a phone was
/// admitted as is #77's.
abstract final class RoleKinds {
  /// This phone now runs as `payload.role`.
  static const assigned = 'role.assigned';

  /// Takes a role pick back. Its `correctsUlid` is the pick it undoes, and
  /// the phone has no role until another is picked.
  static const undo = 'role.undo';

  static const all = {assigned, undo};
}

/// Groom decision G28's six roles, as the server stores them
/// (`committee_device_role_g28_check`, docs/roles.md).
abstract final class Roles {
  static const overallPro = 'overall_pro';
  static const coursePro = 'course_pro';
  static const recorder = 'recorder';
  static const markBoat = 'mark_boat';
  static const safety = 'safety';
  static const scorer = 'scorer';

  static const all = {overallPro, coursePro, recorder, markBoat, safety, scorer};
}

/// Builds the events a role pick appends.
abstract final class RoleEvents {
  /// A pick of [role], which the pick itself already carries in its envelope.
  static NewEvent assign(String role) {
    if (!Roles.all.contains(role)) {
      throw ArgumentError.value(role, 'role', 'is not one of the six committee roles');
    }
    return NewEvent(kind: RoleKinds.assigned, source: 'tap', role: role, payload: {'role': role});
  }

  static NewEvent undo(String pickUlid) => NewEvent(kind: RoleKinds.undo, source: 'tap', correctsUlid: pickUlid);
}

/// [deviceId]'s role pick in force: its latest, unless that pick was undone,
/// when the phone has no role. Null when there is none. Scoped to one phone:
/// another phone's pick, or its undo, arriving by sync never moves this one.
EventEnvelope? currentRolePick(Iterable<EventEnvelope> events, String deviceId) {
  final own = events.where((e) => e.deviceId == deviceId && RoleKinds.all.contains(e.kind)).toList();
  final picks = own.where((e) => e.kind == RoleKinds.assigned).toList()..sort(happened);
  if (picks.isEmpty) return null;
  return undoneBy(own, RoleKinds.undo).contains(picks.last.ulid) ? null : picks.last;
}

/// The role [deviceId] runs as, or null when it has none. A pick that names no
/// role, as #6's every-kind upload test appends, gives none.
String? currentRole(Iterable<EventEnvelope> events, String deviceId) {
  final role = currentRolePick(events, deviceId)?.payload['role'];
  return role is String ? role : null;
}
