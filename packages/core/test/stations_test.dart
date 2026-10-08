import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #26: a mark-boat phone picks its station from the standard mark set, and
/// every event it appends from then on carries that station's mark id
/// (criterion 4, owner decision 2026-10-08: the core stamps it, as it stamps
/// the role).
void main() {
  const phone = '01J8PH0NE00000000000000001';
  const otherPhone = '01J8PH0NE00000000000000002';
  var ts = 0;
  var n = 0;

  EventEnvelope event(String kind, {String deviceId = phone, Map<String, Object?> payload = const {}, String? corrects}) =>
      EventEnvelope(
        ulid: '01J8${(++n).toString().padLeft(22, '0')}',
        deviceTs: ts += 1000,
        deviceId: deviceId,
        seq: n,
        source: 'tap',
        kind: kind,
        payloadVersion: 1,
        payload: payload,
        correctsUlid: corrects,
      );

  EventEnvelope markBoat({String deviceId = phone}) =>
      event(RoleKinds.assigned, deviceId: deviceId, payload: {'role': Roles.markBoat});
  EventEnvelope station(String mark, {String deviceId = phone}) =>
      event(StationKinds.selected, deviceId: deviceId, payload: {'mark': mark});
  EventEnvelope undo(EventEnvelope of, {String deviceId = phone}) => event(
      of.kind == RoleKinds.assigned ? RoleKinds.undo : StationKinds.undo,
      deviceId: deviceId,
      corrects: of.ulid);

  group('criterion 2: the standard set', () {
    // Each id by hand, not read from the constants: stored events keep these
    // strings forever, and burgee and the course module read them.
    test('pins each id', () {
      expect(StandardMarks.mark1, 'mark_1');
      expect(StandardMarks.mark2, 'mark_2');
      expect(StandardMarks.mark3, 'mark_3');
      expect(StandardMarks.mark4, 'mark_4');
      expect(StandardMarks.windward, 'windward');
      expect(StandardMarks.leeward, 'leeward');
      expect(StandardMarks.gateLeft, 'gate_left');
      expect(StandardMarks.gateRight, 'gate_right');
      expect(StandardMarks.offset, 'offset');
    });

    test('is exactly those nine, in the order the picker shows them', () {
      expect(StandardMarks.all,
          ['mark_1', 'mark_2', 'mark_3', 'mark_4', 'windward', 'leeward', 'gate_left', 'gate_right', 'offset']);
    });

    test('the kinds are in the set every kind is read from', () {
      expect(StationKinds.all, {'station.selected', 'station.undo'});
      expect(EventKinds.all, containsAll(StationKinds.all));
    });
  });

  group('a station pick', () {
    test('carries its mark in the payload, for a standard mark only', () {
      for (final mark in StandardMarks.all) {
        final e = StationEvents.select(mark);
        expect([e.kind, e.payload, e.correctsUlid], [StationKinds.selected, {'mark': mark}, null]);
      }
      for (final bad in ['', '1', 'mark_5', 'Windward', 'gate left']) {
        expect(() => StationEvents.select(bad), throwsA(isA<ArgumentError>()), reason: '"$bad"');
      }
    });

    test('an undo names the pick it takes back', () {
      final e = StationEvents.undo('01J80000000000000000000001');
      expect([e.kind, e.correctsUlid, e.payload], [StationKinds.undo, '01J80000000000000000000001', isEmpty]);
    });
  });

  group('the station a phone is at', () {
    test('is none until one is picked', () {
      expect(currentStation([], phone), isNull);
      expect(currentStation([markBoat(), event('finish')], phone), isNull);
    });

    test('is the latest pick under the role pick in force', () {
      final role = markBoat();
      final a = station(StandardMarks.windward);
      expect(currentStation([role, a], phone), StandardMarks.windward);
      expect(currentStationPick([role, a], phone)?.ulid, a.ulid);
      final b = station(StandardMarks.gateLeft);
      expect(currentStation([role, a, b], phone), StandardMarks.gateLeft);
    });

    test('an undo returns to the station before it, and then to none', () {
      final role = markBoat();
      final a = station(StandardMarks.mark1);
      final b = station(StandardMarks.mark2);
      final undoB = undo(b);
      expect(currentStation([role, a, b, undoB], phone), StandardMarks.mark1);
      expect(currentStation([role, a, b, undoB, undo(a)], phone), isNull);
    });

    test('is none with no role in force, and a new role pick starts with none', () {
      final role = markBoat();
      final a = station(StandardMarks.offset);
      expect(currentStation([a], phone), isNull, reason: 'a pick with no role pick before it');
      expect(currentStation([role, a, undo(role)], phone), isNull, reason: 'the role taken back');
      expect(currentStation([role, a, markBoat()], phone), isNull, reason: 'a later role pick, the same role');
    });

    test("never moves for another phone's pick, nor for another phone's undo of this one's", () {
      final role = markBoat();
      final mine = station(StandardMarks.leeward);
      final theirRole = markBoat(deviceId: otherPhone);
      final theirs = station(StandardMarks.windward, deviceId: otherPhone);
      expect(currentStation([role, mine, theirRole, theirs], phone), StandardMarks.leeward);
      expect(currentStation([role, mine, theirRole, theirs], otherPhone), StandardMarks.windward);
      expect(currentStation([role, mine, undo(mine, deviceId: otherPhone)], phone), StandardMarks.leeward);
    });

    test("is none for a pick that names no mark, as #6's every-kind upload appends", () {
      final role = markBoat();
      expect(currentStation([role, event(StationKinds.selected, payload: {'probe': StationKinds.selected})], phone),
          isNull);
      expect(currentStation([role, event(StationKinds.selected, payload: {'mark': 1})], phone), isNull);
    });

    test('reads picks in the order they happened, not the order given', () {
      final role = markBoat();
      final a = station(StandardMarks.mark3);
      final b = station(StandardMarks.mark4);
      expect(currentStation([b, a, role], phone), StandardMarks.mark4);
    });
  });

  group('criterion 4: once a station is set, every later event carries its mark id', () {
    Object? markIn(String canonical) => (jsonDecode(canonical) as Map)['payload']['mark'];

    test('in the payload and in the canonical text as stored, whatever its kind', () {
      final store = openStore(tempDbPath());
      store.append(RoleEvents.assign(Roles.markBoat));
      final before = store.append(const NewEvent(kind: 'rounding', source: 'tap', payload: {'sail': '11'}));
      final picked = store.append(StationEvents.select(StandardMarks.windward));
      final later = [
        // A rounding (#54) and a finish-here (#30) do not exist yet; any kind
        // carries the station, theirs included.
        store.append(const NewEvent(kind: 'rounding', source: 'tap', payload: {'sail': '22'})),
        store.append(const NewEvent(kind: 'course.shortened', source: 'tap')),
        store.append(FinishEvents.finish(fleet: null)),
        store.append(const NewEvent(kind: 'note', source: 'manual')),
      ];

      expect(before.payload, {'sail': '11'}, reason: 'before the pick there is no station to carry');
      expect(markOf(picked), StandardMarks.windward, reason: 'the pick carries the mark it picks');
      expect([for (final e in later) markOf(e)], everyElement(StandardMarks.windward));
      expect(later.first.payload, {'sail': '22', 'mark': StandardMarks.windward}, reason: 'its own payload kept');
      expect(store.station, StandardMarks.windward);
      expect([for (final t in store.readCanonical()) markIn(t)],
          [null, null, StandardMarks.windward, ...List.filled(4, StandardMarks.windward)]);
    });

    test('an event that names a mark of its own keeps it, a null one included', () {
      final store = openStore(tempDbPath());
      store.append(RoleEvents.assign(Roles.markBoat));
      store.append(StationEvents.select(StandardMarks.mark1));
      expect(markOf(store.append(const NewEvent(kind: 'rounding', source: 'tap', payload: {'mark': 'offset'}))),
          'offset');
      final atNone = store.append(const NewEvent(kind: 'note', source: 'tap', payload: {'mark': null}));
      expect(atNone.payload, {'mark': null});
      expect(markOf(store.append(const NewEvent(kind: 'rounding', source: 'tap'))), StandardMarks.mark1);
    });

    test('a new pick moves it, and an undo carries the station it undoes and returns to the one before', () {
      final store = openStore(tempDbPath());
      store.append(RoleEvents.assign(Roles.markBoat));
      store.append(StationEvents.select(StandardMarks.mark1));
      final second = store.append(StationEvents.select(StandardMarks.mark2));
      expect(markOf(store.append(const NewEvent(kind: 'rounding', source: 'tap'))), StandardMarks.mark2);

      final undone = store.append(StationEvents.undo(second.ulid));
      expect(markOf(undone), StandardMarks.mark2, reason: 'the undo was logged at the station it undoes');
      expect(store.station, StandardMarks.mark1);
      expect(markOf(store.append(const NewEvent(kind: 'rounding', source: 'tap'))), StandardMarks.mark1);
    });

    test('a role pick ends it: the events after a new pick carry no mark', () {
      final store = openStore(tempDbPath());
      final role = store.append(RoleEvents.assign(Roles.markBoat));
      store.append(StationEvents.select(StandardMarks.leeward));
      store.append(RoleEvents.undo(role.ulid));
      expect(store.station, isNull);
      expect(store.append(const NewEvent(kind: 'note', source: 'tap')).payload, isEmpty);
      store.append(RoleEvents.assign(Roles.markBoat));
      expect(store.append(const NewEvent(kind: 'rounding', source: 'tap')).payload, isEmpty);
    });

    test('a restart keeps the station, read back from the log, and keeps an undo too', () {
      final path = tempDbPath();
      final first = EventStore.open(path);
      first.append(RoleEvents.assign(Roles.markBoat));
      first.append(StationEvents.select(StandardMarks.gateLeft));
      final moved = first.append(StationEvents.select(StandardMarks.gateRight));
      first.close();

      final again = EventStore.open(path);
      expect(again.station, StandardMarks.gateRight);
      expect(markOf(again.append(const NewEvent(kind: 'rounding', source: 'tap'))), StandardMarks.gateRight);
      again.append(StationEvents.undo(moved.ulid));
      again.close();

      final third = openStore(path);
      expect(third.station, StandardMarks.gateLeft);
      expect(markOf(third.append(const NewEvent(kind: 'rounding', source: 'tap'))), StandardMarks.gateLeft);
    });

    test('a payload that only mentions a station kind is not read as a pick on restart', () {
      final path = tempDbPath();
      final first = EventStore.open(path);
      first.append(RoleEvents.assign(Roles.markBoat));
      first.append(const NewEvent(
          kind: 'note', source: 'tap', payload: {'kind': 'station.selected', 'mark': StandardMarks.offset}));
      expect(first.readCanonical().last, contains('"kind":"station.selected"'),
          reason: 'the text the restart narrows its read with is there');
      first.close();
      expect(openStore(path).station, isNull);
    });

    test("another phone's pick, stored here by sync, never moves this phone's station", () {
      final other = openStore(tempDbPath(), seed: 2);
      other.append(RoleEvents.assign(Roles.markBoat));
      final theirs = other.append(StationEvents.select(StandardMarks.windward));
      final path = tempDbPath();
      final store = EventStore.open(path);
      store.append(RoleEvents.assign(Roles.markBoat));
      store.append(StationEvents.select(StandardMarks.leeward));
      store.insert(theirs);
      expect(markOf(store.append(const NewEvent(kind: 'rounding', source: 'tap'))), StandardMarks.leeward);
      store.close();
      expect(openStore(path).station, StandardMarks.leeward, reason: 'nor on restart');
    });

    test('the chain still verifies across a pick, a stamped event and an undo', () {
      final store = openStore(tempDbPath());
      store.append(RoleEvents.assign(Roles.markBoat));
      final picked = store.append(StationEvents.select(StandardMarks.mark3));
      store.append(const NewEvent(kind: 'rounding', source: 'tap'));
      store.append(StationEvents.undo(picked.ulid));
      expect(verifyChain(store.readCanonical()), const ChainVerdict.intact());
    });

    test('over the core interface, as the UI reaches it', () async {
      final core = await spawnCore(tempDbPath());
      addTearDown(core.close);
      await core.append(RoleEvents.assign(Roles.markBoat));
      await core.append(StationEvents.select(StandardMarks.offset));
      final e = await core.append(const NewEvent(kind: 'rounding', source: 'tap'));
      expect(markOf(e), StandardMarks.offset);
      expect((await core.readAll()).last.toWire()['payload'], {'mark': StandardMarks.offset});
    });

    test('and the fake core stamps the same way, counting seeded picks, so widget tests see what the real '
        'core writes', () async {
      final fake = FakeCore();
      await fake.append(RoleEvents.assign(Roles.markBoat));
      expect((await fake.append(const NewEvent(kind: 'rounding', source: 'tap'))).payload, isEmpty);
      final picked = await fake.append(StationEvents.select(StandardMarks.mark4));
      expect(markOf(await fake.append(const NewEvent(kind: 'rounding', source: 'tap'))), StandardMarks.mark4);
      expect(markOf(await fake.append(const NewEvent(kind: 'rounding', source: 'tap', payload: {'mark': 'offset'}))),
          'offset');
      await fake.append(StationEvents.undo(picked.ulid));
      expect((await fake.append(const NewEvent(kind: 'rounding', source: 'tap'))).payload, isEmpty);

      const fakeDevice = '01J0000000FAKEDEVICE00000A';
      final seeded = FakeCore()
        ..seed([markBoat(deviceId: fakeDevice), station(StandardMarks.leeward, deviceId: fakeDevice)]);
      expect(markOf(await seeded.append(const NewEvent(kind: 'rounding', source: 'tap'))), StandardMarks.leeward);
    });
  });
}
