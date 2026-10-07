import 'dart:convert';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #20: a phone picks the committee role it runs as, and every event it
/// appends from then on carries that role in its envelope (criterion 2).
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

  EventEnvelope pick(String role, {String deviceId = phone}) =>
      event(RoleKinds.assigned, deviceId: deviceId, payload: {'role': role});
  EventEnvelope undo(EventEnvelope of, {String deviceId = phone}) =>
      event(RoleKinds.undo, deviceId: deviceId, corrects: of.ulid);

  group('the role a phone runs as', () {
    test('is none until a role is picked', () {
      expect(currentRole([], phone), isNull);
      expect(currentRole([event('finish'), event('fleet.defined')], phone), isNull);
    });

    test('is the latest pick', () {
      final a = pick(Roles.overallPro);
      expect(currentRole([a], phone), Roles.overallPro);
      expect(currentRolePick([a], phone)?.ulid, a.ulid);
      final b = undo(a);
      final c = pick(Roles.recorder);
      expect(currentRole([a, b, c], phone), Roles.recorder);
    });

    test('is none once that pick is undone: the picker returns, not the role before it', () {
      final a = pick(Roles.overallPro);
      final b = pick(Roles.recorder);
      expect(currentRole([a, b, undo(b)], phone), isNull);
      expect(currentRole([a, undo(a)], phone), isNull);
    });

    test("never moves for another phone's pick, nor for another phone's undo of this one's", () {
      final mine = pick(Roles.markBoat);
      final theirs = pick(Roles.safety, deviceId: otherPhone);
      expect(currentRole([mine, theirs], phone), Roles.markBoat);
      expect(currentRole([mine, theirs], otherPhone), Roles.safety);
      expect(currentRole([mine, undo(mine, deviceId: otherPhone)], phone), Roles.markBoat);
    });

    test('is none for a pick that names no role, as #6\'s every-kind upload appends', () {
      expect(currentRole([event(RoleKinds.assigned, payload: {'probe': RoleKinds.assigned})], phone), isNull);
      expect(currentRole([event(RoleKinds.assigned, payload: {'role': 7})], phone), isNull);
    });

    test('reads picks in the order they happened, not the order given', () {
      final a = pick(Roles.overallPro);
      final b = pick(Roles.recorder);
      expect(currentRole([b, a], phone), Roles.recorder);
    });
  });

  group('a role pick', () {
    test('carries its role in the envelope and the payload, for one of the six roles only', () {
      for (final role in Roles.all) {
        final e = RoleEvents.assign(role);
        expect([e.kind, e.role, e.payload], [RoleKinds.assigned, role, {'role': role}]);
      }
      for (final bad in ['', 'pro', 'signal_boat', 'Recorder']) {
        expect(() => RoleEvents.assign(bad), throwsA(isA<ArgumentError>()), reason: '"$bad"');
      }
    });

    test('the six are the server check\'s, and the kinds are in the set every kind is read from', () {
      expect(Roles.all, {'overall_pro', 'course_pro', 'recorder', 'mark_boat', 'safety', 'scorer'});
      expect(EventKinds.all, containsAll(RoleKinds.all));
    });
  });

  group('criterion 2: once a role is picked, every later event carries it', () {
    List<String?> rolesOf(EventStore store) => [for (final e in store.readAll()) e.role];

    test('in the envelope and in the canonical text as stored, whatever its kind', () {
      final store = openStore(tempDbPath());
      final before = store.append(const NewEvent(kind: 'note', source: 'tap'));
      final picked = store.append(RoleEvents.assign(Roles.recorder));
      final fleet = store.append(FleetEvents.define('Lasers'));
      final later = [
        fleet,
        store.append(FleetEvents.select(fleet.ulid)),
        store.append(FinishEvents.finish(fleet: fleet.ulid)),
        store.append(FinishEvents.finish(fleet: fleet.ulid, source: FinishSources.volumeKey)),
        store.append(StartEvents.start(fleet: fleet.ulid, source: 'race-timer')),
        store.append(const NewEvent(kind: 'note', source: 'manual')),
      ];

      expect(before.role, isNull, reason: 'before the pick there is no role to carry');
      expect(picked.role, Roles.recorder, reason: 'the pick carries the role it picks');
      expect([for (final e in later) e.role], everyElement(Roles.recorder));
      expect(store.role, Roles.recorder);
      expect(rolesOf(store), [null, ...List.filled(7, Roles.recorder)]);
      expect([for (final t in store.readCanonical()) (jsonDecode(t) as Map)['role']],
          [null, ...List.filled(7, Roles.recorder)]);
    });

    test('an event that names a role of its own keeps it', () {
      final store = openStore(tempDbPath());
      store.append(RoleEvents.assign(Roles.recorder));
      expect(store.append(const NewEvent(kind: 'note', source: 'tap', role: Roles.overallPro)).role, Roles.overallPro);
      expect(store.append(const NewEvent(kind: 'note', source: 'tap')).role, Roles.recorder);
    });

    test('the undo carries the role it undoes, and the events after it carry none', () {
      final store = openStore(tempDbPath());
      final picked = store.append(RoleEvents.assign(Roles.markBoat));
      final undone = store.append(RoleEvents.undo(picked.ulid));
      final after = store.append(const NewEvent(kind: 'note', source: 'tap'));
      expect([undone.role, after.role, store.role], [Roles.markBoat, null, null]);

      final repicked = store.append(RoleEvents.assign(Roles.safety));
      expect([repicked.role, store.append(const NewEvent(kind: 'note', source: 'tap')).role],
          [Roles.safety, Roles.safety]);
    });

    test('a restart keeps the role, read back from the log, and keeps an undo too', () {
      final path = tempDbPath();
      final first = EventStore.open(path);
      first.append(const NewEvent(kind: 'note', source: 'tap'));
      final picked = first.append(RoleEvents.assign(Roles.overallPro));
      first.append(const NewEvent(kind: 'finish', source: 'tap'));
      first.close();

      final again = EventStore.open(path);
      expect(again.role, Roles.overallPro);
      expect(again.append(const NewEvent(kind: 'finish', source: 'tap')).role, Roles.overallPro);
      again.append(RoleEvents.undo(picked.ulid));
      again.close();

      final third = openStore(path);
      expect(third.role, isNull);
      expect(third.append(const NewEvent(kind: 'note', source: 'tap')).role, isNull);
    });

    test("a payload that only mentions a role kind is not read as a pick on restart", () {
      final path = tempDbPath();
      final first = EventStore.open(path);
      first.append(const NewEvent(kind: 'note', source: 'tap', payload: {'kind': 'role.assigned', 'role': 'safety'}));
      expect(first.readCanonical().single, contains('"kind":"role.assigned"'),
          reason: 'the text the restart narrows its read with is there');
      first.close();
      expect(openStore(path).role, isNull);
    });

    test("another phone's pick, stored here by sync, never moves this phone's role", () {
      final other = openStore(tempDbPath(), seed: 2);
      final theirs = other.append(RoleEvents.assign(Roles.safety));
      final path = tempDbPath();
      final store = EventStore.open(path);
      store.append(RoleEvents.assign(Roles.recorder));
      store.insert(theirs);
      expect(store.append(const NewEvent(kind: 'note', source: 'tap')).role, Roles.recorder);
      store.close();
      expect(openStore(path).role, Roles.recorder, reason: 'nor on restart');
    });

    test('the chain still verifies across a pick and its undo', () {
      final store = openStore(tempDbPath());
      final picked = store.append(RoleEvents.assign(Roles.recorder));
      store.append(const NewEvent(kind: 'finish', source: 'tap'));
      store.append(RoleEvents.undo(picked.ulid));
      expect(verifyChain(store.readCanonical()), const ChainVerdict.intact());
    });

    test('over the core interface, as the UI reaches it', () async {
      final core = await spawnCore(tempDbPath());
      addTearDown(core.close);
      final picked = await core.append(RoleEvents.assign(Roles.recorder));
      final e = await core.append(FinishEvents.finish(fleet: null));
      expect([picked.role, e.role], [Roles.recorder, Roles.recorder]);
      expect((await core.readAll()).last.toWire()['role'], Roles.recorder);
    });

    test('and the fake core stamps the same way, counting a seeded pick, so widget tests see what the real '
        'core writes', () async {
      final fake = FakeCore();
      expect((await fake.append(const NewEvent(kind: 'note', source: 'tap'))).role, isNull);
      final picked = await fake.append(RoleEvents.assign(Roles.markBoat));
      expect((await fake.append(const NewEvent(kind: 'note', source: 'tap'))).role, Roles.markBoat);
      expect((await fake.append(const NewEvent(kind: 'note', source: 'tap', role: Roles.safety))).role, Roles.safety);
      await fake.append(RoleEvents.undo(picked.ulid));
      expect((await fake.append(const NewEvent(kind: 'note', source: 'tap'))).role, isNull);

      final seeded = FakeCore()..seed([pick(Roles.recorder, deviceId: '01J0000000FAKEDEVICE00000A')]);
      expect((await seeded.append(const NewEvent(kind: 'note', source: 'tap'))).role, Roles.recorder);
    });
  });
}
