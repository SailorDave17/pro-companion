import 'envelope.dart';
import 'order.dart';
import 'roles.dart';

/// A mark boat's station (#26): the mark its phone is at, picked from the
/// standard set and kept in the log, so a restart, and every later event,
/// knows it. Self-declared and never enforced (groom decision G49).
abstract final class StationKinds {
  /// This phone is now at `payload.mark`.
  static const selected = 'station.selected';

  /// Takes a station pick back. Its `correctsUlid` is the pick it undoes; the
  /// phone returns to the station it had before, or to none.
  static const undo = 'station.undo';

  static const all = {selected, undo};
}

/// Groom decision G11's first half: the fixed standard mark set, which works
/// offline on one phone. Rounding (#54), finish-here (#30) and the course
/// module key on these ids, so they are fixed once, here, and documented in
/// docs/marks.md. The PRO-sent custom list is its own story.
abstract final class StandardMarks {
  static const mark1 = 'mark_1';
  static const mark2 = 'mark_2';
  static const mark3 = 'mark_3';
  static const mark4 = 'mark_4';
  static const windward = 'windward';
  static const leeward = 'leeward';
  static const gateLeft = 'gate_left';
  static const gateRight = 'gate_right';
  static const offset = 'offset';

  /// The set, in the order the station picker shows it.
  static const all = [mark1, mark2, mark3, mark4, windward, leeward, gateLeft, gateRight, offset];
}

/// The payload key an event carries its mark in. The core stamps it into
/// every event a stationed phone appends (#26 criterion 4, owner decision
/// 2026-10-08).
const markPayloadKey = 'mark';

/// The mark [e] names, or null when it names none.
String? markOf(EventEnvelope e) {
  final mark = e.payload[markPayloadKey];
  return mark is String ? mark : null;
}

/// Builds the events a station pick appends.
abstract final class StationEvents {
  /// A pick of [mark], one of the standard set.
  static NewEvent select(String mark) {
    if (!StandardMarks.all.contains(mark)) {
      throw ArgumentError.value(mark, 'mark', 'is not one of the standard marks');
    }
    return NewEvent(kind: StationKinds.selected, source: 'tap', payload: {markPayloadKey: mark});
  }

  static NewEvent undo(String pickUlid) => NewEvent(kind: StationKinds.undo, source: 'tap', correctsUlid: pickUlid);
}

/// [deviceId]'s station pick in force: its latest not undone, made since the
/// phone's role pick in force. A new role pick starts with no station, and a
/// phone with no role has none. Null when there is none. Scoped to one phone:
/// another phone's pick, or its undo, arriving by sync never moves this one.
EventEnvelope? currentStationPick(Iterable<EventEnvelope> events, String deviceId) {
  final role = currentRolePick(events, deviceId);
  if (role == null) return null;
  final own = events.where((e) => e.deviceId == deviceId && StationKinds.all.contains(e.kind)).toList();
  final undone = undoneBy(own, StationKinds.undo);
  final picks = own
      .where((e) => e.kind == StationKinds.selected && !undone.contains(e.ulid) && happened(e, role) > 0)
      .toList()
    ..sort(happened);
  return picks.isEmpty ? null : picks.last;
}

/// The mark [deviceId] is stationed at, or null when it has none. A pick that
/// names no mark, as #6's every-kind upload test appends, gives none.
String? currentStation(Iterable<EventEnvelope> events, String deviceId) {
  final pick = currentStationPick(events, deviceId);
  return pick == null ? null : markOf(pick);
}

/// [payload] as a stationed phone stores it: with [station] in
/// [markPayloadKey], unless it names a mark of its own. A null there is a mark
/// of its own too: an event that says it is at no mark.
Map<String, Object?> withStation(Map<String, Object?> payload, String? station) =>
    station == null || payload.containsKey(markPayloadKey) ? payload : {...payload, markPayloadKey: station};
