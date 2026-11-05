import 'dart:math';

import 'package:pro_companion_core/core.dart';
import 'package:test/test.dart';

/// #78: a PRO's custom mark list for its race area, sent by cloud pull, and
/// what a mark-boat phone makes of it.
void main() {
  const alpha = '00000000-0000-4000-8000-00000000c0a1';
  const bravo = '00000000-0000-4000-8000-00000000c0b2';
  const pro = '01J8PH0NE00000000000000001';
  var ts = 0;
  var n = 0;

  EventEnvelope stored(NewEvent e, {String deviceId = pro}) => EventEnvelope(
        ulid: '01J8${(++n).toString().padLeft(22, '0')}',
        deviceTs: ts += 1000,
        deviceId: deviceId,
        seq: n,
        source: e.source,
        kind: e.kind,
        payloadVersion: 1,
        payload: e.payload,
        correctsUlid: e.correctsUlid,
      );

  final random = Random(78);
  CustomMark mark(String name, {String? colour, String? shape}) =>
      CustomMark(id: newCustomMarkId(random), name: name, colour: colour, shape: shape);

  group('criterion 1: custom ids never collide with the standard set', () {
    test('every new id is a custom one, distinct, and no standard id is', () {
      final ids = {for (var i = 0; i < 500; i++) newCustomMarkId(random)};
      expect(ids, hasLength(500));
      expect(ids.every(isCustomMarkId), isTrue);
      expect(StandardMarks.all.where(isCustomMarkId), isEmpty);
      expect(StandardMarks.all.where((m) => m.startsWith(customMarkPrefix)), isEmpty);
    });

    test('a list carries the race area and every mark, and refuses what is not a custom mark', () {
      final pin = mark('Pin', colour: MarkColours.orange, shape: MarkShapes.cone);
      final e = MarkListEvents.send(course: alpha, marks: [pin, mark('Spreader')]);
      expect(e.kind, MarkListKinds.sent);
      expect(e.payload[coursePayloadKey], alpha);
      expect((e.payload['marks'] as List).first, {'id': pin.id, 'name': 'Pin', 'colour': 'orange', 'shape': 'cone'});
      expect(() => MarkListEvents.send(course: alpha, marks: [CustomMark(id: StandardMarks.windward, name: 'W')]),
          throwsArgumentError, reason: 'a standard id is not a custom one');
      expect(() => MarkListEvents.send(course: alpha, marks: [pin, pin]), throwsArgumentError);
      expect(() => MarkListEvents.send(course: alpha, marks: [mark('  ')]), throwsArgumentError);
      expect(() => MarkListEvents.send(course: alpha, marks: [mark('X', colour: 'purple')]), throwsArgumentError);
      expect(() => MarkListEvents.send(course: '', marks: [pin]), throwsArgumentError);
    });

    test('a station may name a custom mark, and still nothing outside the two', () {
      final id = newCustomMarkId(random);
      expect(StationEvents.select(id).payload[markPayloadKey], id);
      expect(() => StationEvents.select('custom_'), throwsArgumentError);
      expect(() => StationEvents.select('pin'), throwsArgumentError);
    });

    test('the kinds are in EventKinds.all', () {
      expect(EventKinds.all, containsAll(MarkListKinds.all));
    });
  });

  group('criterion 2: the list for this race area, and no other', () {
    test("a race area's list in force is its latest, from any phone, and another race area's is not it", () {
      final first = [mark('Pin')];
      final second = [mark('Spreader')];
      final other = [mark('Bravo pin')];
      final events = [
        stored(MarkListEvents.send(course: alpha, marks: first)),
        stored(MarkListEvents.send(course: bravo, marks: other)),
        stored(MarkListEvents.send(course: alpha, marks: second), deviceId: '01J8PH0NE00000000000000002'),
      ];
      expect(currentMarkList(events, alpha), second, reason: 'another PRO phone\'s, pulled, counts');
      expect(currentMarkList(events, bravo), other);
      expect(currentMarkList(events, null), isEmpty, reason: 'a phone with no race area has none');
    });
  });

  group('criterion 3: with no list, the standard set alone', () {
    test('no list is an empty list', () {
      expect(currentMarkList(const [], alpha), isEmpty);
      expect(currentMarkListEvent(const [], alpha), isNull);
    });
  });

  group('criterion 4: a superseding list keeps earlier ids valid and readable', () {
    test('an undo returns to the list before, and every id ever sent keeps a name', () {
      final pin = mark('Pin');
      final spreader = mark('Spreader');
      final first = stored(MarkListEvents.send(course: alpha, marks: [pin]));
      final renamed = CustomMark(id: pin.id, name: 'Pin end');
      final second = stored(MarkListEvents.send(course: alpha, marks: [renamed, spreader]));
      final third = stored(MarkListEvents.send(course: alpha, marks: [spreader]));
      final events = [first, second, third];
      expect(currentMarkList(events, alpha), [spreader]);
      expect(customMarksEver(events)[pin.id]?.name, 'Pin end', reason: 'dropped from the list in force, still named');

      final undo = stored(MarkListEvents.undo(third.ulid));
      expect(currentMarkList([...events, undo], alpha), [renamed, spreader]);
      final undoAgain = stored(MarkListEvents.undo(second.ulid));
      expect(currentMarkList([...events, undo, undoAgain], alpha), [pin]);
      expect(customMarksEver([...events, undo, undoAgain]).keys, containsAll([pin.id, spreader.id]));
    });

    test('a list with a malformed mark keeps the others', () {
      final pin = mark('Pin');
      final e = stored(NewEvent(kind: MarkListKinds.sent, source: 'tap', payload: {
        coursePayloadKey: alpha,
        'marks': [
          pin.toPayload(),
          {'id': 'windward', 'name': 'Not mine'},
          {'id': newCustomMarkId(random), 'name': ''},
          'not a mark',
        ],
      }));
      expect(currentMarkList([e], alpha), [pin]);
    });
  });
}
