import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/store.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #30 in the core, through the real store: a shortened course and a finish
/// at a mark carry the phone's station, fleet and device, and a finish at a
/// mark is kept apart from the line's.
void main() {
  late EventStore store;

  /// A mark boat's phone at [mark]: the role pick, then the station pick.
  EventStore stationed(String mark, {int seed = 1}) {
    var t = 1727190000000 + seed;
    final s = openStore(tempDbPath(), clock: () => t += 1000, seed: seed);
    s.append(RoleEvents.assign(Roles.markBoat));
    s.append(StationEvents.select(mark));
    return s;
  }

  Map<String, Object?> canonical(EventEnvelope e) =>
      jsonDecode(store.readCanonical().singleWhere((t) => (jsonDecode(t) as Map)['ulid'] == e.ulid))
          as Map<String, Object?>;

  setUp(() => store = stationed(StandardMarks.windward));

  group('criterion 1: a shortened course names the station and the fleet', () {
    test('as stored, with the mark stamped from the station', () {
      final e = store.append(CourseEvents.shortened(fleet: 'f1'));
      expect([e.kind, e.payload, e.role], [CourseKinds.shortened, {'fleet': 'f1', 'mark': 'windward'}, Roles.markBoat]);
      expect(canonical(e)['payload'], {'fleet': 'f1', 'mark': 'windward'}, reason: 'in the canonical text too');
    });

    test('a single-fleet day names no fleet', () {
      expect(store.append(CourseEvents.shortened(fleet: null)).payload, {'fleet': null, 'mark': 'windward'});
    });

    test('in force: the latest per fleet at this mark, not undone, on this phone', () {
      final a1 = store.append(CourseEvents.shortened(fleet: 'a'));
      final b = store.append(CourseEvents.shortened(fleet: 'b'));
      final a2 = store.append(CourseEvents.shortened(fleet: 'a'));
      store.append(CourseEvents.undo(b.ulid));
      final here = shortenedAt(store.readAll(), deviceId: store.deviceId, mark: 'windward');
      expect(here.map((k, v) => MapEntry(k, v.ulid)), {'a': a2.ulid}, reason: 'b undone, a its latest');
      expect(a1.ulid, isNot(a2.ulid));
      expect(shortenedAt(store.readAll(), deviceId: store.deviceId, mark: 'leeward'), isEmpty);
      expect(shortenedAt(store.readAll(), deviceId: 'another-phone', mark: 'windward'), isEmpty);
    });

    test("another phone's shortened course at the same mark does not switch this one", () {
      final other = stationed(StandardMarks.windward, seed: 2);
      final theirs = other.append(CourseEvents.shortened(fleet: 'a'));
      final mine = store.append(CourseEvents.shortened(fleet: 'b'));
      final day = [...store.readAll(), theirs];
      expect(shortenedAt(day, deviceId: store.deviceId, mark: 'windward').keys, ['b']);
      expect(shortenedAt(day, deviceId: other.deviceId, mark: 'windward').keys, ['a']);
      expect(mine.deviceId, isNot(theirs.deviceId));
    });

    test('a pick of another station leaves the course shortened at the first', () {
      store.append(CourseEvents.shortened(fleet: 'a'));
      store.append(StationEvents.select(StandardMarks.leeward));
      expect(shortenedAt(store.readAll(), deviceId: store.deviceId, mark: 'leeward'), isEmpty);
      expect(shortenedAt(store.readAll(), deviceId: store.deviceId, mark: 'windward').keys, ['a']);
    });
  });

  group('criterion 2: a finish at the mark carries the mark id, fleet and device id', () {
    test('as stored and in the canonical text', () {
      final e = store.append(FinishEvents.atMark(fleet: 'f1'));
      expect([e.kind, e.payload, e.deviceId], [FinishKinds.atMark, {'fleet': 'f1', 'mark': 'windward'}, store.deviceId]);
      final text = canonical(e);
      expect([text['kind'], text['payload'], text['device_id']],
          ['finish.at_mark', {'fleet': 'f1', 'mark': 'windward'}, store.deviceId]);
    });

    test("the mark's order: its fleet's finishes there by time, undone ones out, sail numbers in", () {
      final a = store.append(FinishEvents.atMark(fleet: 'f1'));
      store.append(FinishEvents.atMark(fleet: 'f2'));
      final b = store.append(FinishEvents.atMark(fleet: 'f1'));
      final c = store.append(FinishEvents.atMark(fleet: 'f1'));
      store.append(FinishEvents.undo(b.ulid));
      store.append(FinishEvents.assignSail(c.ulid, '2207'));
      store.append(FinishEvents.assignSail(c.ulid, '2208'));
      store.append(StationEvents.select(StandardMarks.leeward));
      store.append(FinishEvents.atMark(fleet: 'f1'));

      final order = markFinishOrder(store.readAll(), fleet: 'f1', mark: 'windward');
      expect([for (final e in order) (e.place, e.ulid, e.sail, e.missed)], [
        (1, a.ulid, null, false),
        (2, c.ulid, '2208', false),
      ]);
      expect(order.first.deviceTs, a.deviceTs);
      expect(lastUndoableMarkFinish(store.readAll(), fleet: 'f1', mark: 'windward')?.ulid, c.ulid);
      expect(markFinishOrder(store.readAll(), fleet: 'f1', mark: 'leeward'), hasLength(1));
    });

    test('a finish at a mark is never a line finish, and a line finish never a mark one', () {
      final line = openStore(tempDbPath(), seed: 3)..append(RoleEvents.assign(Roles.recorder));
      final lineFinish = line.append(FinishEvents.finish(fleet: 'f1'));
      final atMark = store.append(FinishEvents.atMark(fleet: 'f1'));
      store.append(FinishEvents.assignSail(atMark.ulid, '11'));
      final day = [...line.readAll(), ...store.readAll()];

      expect([for (final e in finishOrder(day, fleet: 'f1')) e.ulid], [lineFinish.ulid]);
      expect(lastUndoable(day, fleet: 'f1'), lineFinish.ulid);
      expect([for (final r in racesOf(day, fleet: 'f1')) for (final e in r) e.ulid], [lineFinish.ulid],
          reason: 'provisional results score the line only');
      expect(knownSails(day, fleet: 'f1', day: atMark.deviceTs), isEmpty,
          reason: "a boat named at a mark is not one of the line's known boats");
      expect([for (final e in markFinishOrder(day, fleet: 'f1', mark: 'windward')) e.ulid], [atMark.ulid]);
    });
  });

  group('which fleet a finish-at-mark screen opens on', () {
    test('none until a fleet finishes here; then the one last shortened or finished for', () {
      expect(lastMarkFleet(store.readAll(), deviceId: store.deviceId, mark: 'windward'), isNull);
      store.append(CourseEvents.shortened(fleet: 'a'));
      store.append(CourseEvents.shortened(fleet: 'b'));
      expect(lastMarkFleet(store.readAll(), deviceId: store.deviceId, mark: 'windward'), (fleet: 'b'));
      store.append(FinishEvents.atMark(fleet: 'a'));
      expect(lastMarkFleet(store.readAll(), deviceId: store.deviceId, mark: 'windward'), (fleet: 'a'));
    });

    test('a fleet whose shortened course was undone is not opened on', () {
      final a = store.append(CourseEvents.shortened(fleet: 'a'));
      store.append(FinishEvents.atMark(fleet: 'a'));
      store.append(CourseEvents.shortened(fleet: null));
      store.append(CourseEvents.undo(a.ulid));
      expect(lastMarkFleet(store.readAll(), deviceId: store.deviceId, mark: 'windward'), (fleet: null),
          reason: "the single-fleet day's, a record holding null");
    });
  });

  test('both new kinds and the finish at a mark are in EventKinds.all', () {
    expect(EventKinds.all, containsAll(['course.shortened', 'course.undo', 'finish.at_mark']));
  });
}
