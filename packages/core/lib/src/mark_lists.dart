import 'dart:math';

import 'envelope.dart';
import 'order.dart';
import 'race_areas.dart';
import 'stations.dart';

/// The custom mark list (#78, groom decision G11's second half): a PRO on a
/// race area defines marks the standard set does not have and sends them, by
/// cloud pull (scope decision 9), to the mark-boat phones on that race area.
/// Not a critical kind (owner decision at #78's pickup, after G24 and G29):
/// the phone offers the editor on a PRO's home only, and the server accepts a
/// list as it accepts any set-up event.
abstract final class MarkListKinds {
  /// A race area's custom marks, whole: `payload.course` (a course id) and
  /// `payload.marks`, each `{id, name, colour, shape}`. It supersedes the
  /// race area's list before it.
  static const sent = 'mark_list.sent';

  /// Takes a list back. Its `correctsUlid` is the list it undoes; the race
  /// area returns to the list before it, or to none.
  static const undo = 'mark_list.undo';

  static const all = {sent, undo};
}

/// The colours a custom mark may be given, in the order the editor shows them.
abstract final class MarkColours {
  static const yellow = 'yellow';
  static const orange = 'orange';
  static const red = 'red';
  static const green = 'green';
  static const white = 'white';

  static const all = [yellow, orange, red, green, white];
}

/// The shapes a custom mark may be given, in the order the editor shows them.
abstract final class MarkShapes {
  static const cylinder = 'cylinder';
  static const ball = 'ball';
  static const cone = 'cone';
  static const flag = 'flag';

  static const all = [cylinder, ball, cone, flag];
}

/// What every custom mark id starts with. No standard id does, so a custom id
/// never collides with the standard set (#78 criterion 1).
const customMarkPrefix = 'custom_';

final _customId = RegExp(r'^custom_[0-9a-hjkmnp-tv-z]{10}$');

/// Whether [id] is a custom mark id as [newCustomMarkId] makes them.
bool isCustomMarkId(String id) => _customId.hasMatch(id);

/// Whether a station may name [id]: a standard mark, or a custom one.
bool isStationMark(String id) => StandardMarks.all.contains(id) || isCustomMarkId(id);

const _crockford = '0123456789abcdefghjkmnpqrstvwxyz';

/// A new custom mark id: the prefix and ten random Crockford characters, so
/// two PROs editing one race area's list at once do not mint the same id.
String newCustomMarkId([Random? random]) {
  final r = random ?? Random.secure();
  return customMarkPrefix + String.fromCharCodes([for (var i = 0; i < 10; i++) _crockford.codeUnitAt(r.nextInt(32))]);
}

/// One custom mark, as a list carries it.
class CustomMark {
  const CustomMark({required this.id, required this.name, this.colour, this.shape});

  final String id;
  final String name;

  /// One of [MarkColours.all], or null.
  final String? colour;

  /// One of [MarkShapes.all], or null.
  final String? shape;

  Map<String, Object?> toPayload() => {'id': id, 'name': name, 'colour': colour, 'shape': shape};

  static CustomMark? fromPayload(Object? m) {
    if (m case {'id': final String id, 'name': final String name} when isCustomMarkId(id) && name.trim().isNotEmpty) {
      final colour = m['colour'], shape = m['shape'];
      return CustomMark(
        id: id,
        name: name,
        colour: colour is String && MarkColours.all.contains(colour) ? colour : null,
        shape: shape is String && MarkShapes.all.contains(shape) ? shape : null,
      );
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is CustomMark && other.id == id && other.name == name && other.colour == colour && other.shape == shape;

  @override
  int get hashCode => Object.hash(id, name, colour, shape);

  @override
  String toString() => 'CustomMark($name $id${colour == null ? '' : ' $colour'}${shape == null ? '' : ' $shape'})';
}

/// Builds the events a mark list appends.
abstract final class MarkListEvents {
  /// Race area [course]'s list, [marks] in the order the picker shows them.
  /// Refuses an id that is not a custom one, an id twice, an empty name, and
  /// a colour or shape outside its set.
  static NewEvent send({required String course, required List<CustomMark> marks}) {
    if (course.trim().isEmpty) throw ArgumentError.value(course, 'course', 'is empty');
    final ids = <String>{};
    for (final m in marks) {
      if (!isCustomMarkId(m.id)) throw ArgumentError.value(m.id, 'marks', 'holds an id that is not a custom mark id');
      if (!ids.add(m.id)) throw ArgumentError.value(m.id, 'marks', 'holds an id twice');
      if (m.name.trim().isEmpty) throw ArgumentError.value(m.name, 'marks', 'holds a mark with no name');
      if (m.colour != null && !MarkColours.all.contains(m.colour)) {
        throw ArgumentError.value(m.colour, 'marks', 'holds a colour outside the set');
      }
      if (m.shape != null && !MarkShapes.all.contains(m.shape)) {
        throw ArgumentError.value(m.shape, 'marks', 'holds a shape outside the set');
      }
    }
    return NewEvent(kind: MarkListKinds.sent, source: 'tap', payload: {
      coursePayloadKey: course,
      'marks': [for (final m in marks) CustomMark(id: m.id, name: m.name.trim(), colour: m.colour, shape: m.shape).toPayload()],
    });
  }

  static NewEvent undo(String listUlid) => NewEvent(kind: MarkListKinds.undo, source: 'tap', correctsUlid: listUlid);
}

List<CustomMark> _marksOf(EventEnvelope list) => [
      for (final m in (list.payload['marks'] is List ? list.payload['marks'] as List : const []))
        ?CustomMark.fromPayload(m),
    ];

/// Race area [course]'s list in force: its latest `mark_list.sent` not undone,
/// from any phone, pulled ones included. Null when there is none, and for a
/// phone with no race area.
EventEnvelope? currentMarkListEvent(Iterable<EventEnvelope> events, String? course) {
  if (course == null) return null;
  final lists = events.where((e) => MarkListKinds.all.contains(e.kind)).toList();
  final undone = undoneBy(lists, MarkListKinds.undo);
  final inForce = lists
      .where((e) => e.kind == MarkListKinds.sent && e.payload[coursePayloadKey] == course && !undone.contains(e.ulid))
      .toList()
    ..sort(happened);
  return inForce.isEmpty ? null : inForce.last;
}

/// Race area [course]'s custom marks in force (#78 criterion 2), in the
/// order sent. Empty with no list, so the standard set still works alone
/// (criterion 3).
List<CustomMark> currentMarkList(Iterable<EventEnvelope> events, String? course) {
  final list = currentMarkListEvent(events, course);
  return list == null ? const [] : _marksOf(list);
}

/// Every custom mark any list in [events] ever named, by id, with the name of
/// the latest list naming it, undone or superseded ones included: an earlier
/// event keeps its mark id readable whatever came after (#78 criterion 4).
Map<String, CustomMark> customMarksEver(Iterable<EventEnvelope> events) {
  final lists = events.where((e) => e.kind == MarkListKinds.sent).toList()..sort(happened);
  return {
    for (final l in lists)
      for (final m in _marksOf(l)) m.id: m,
  };
}
