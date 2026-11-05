import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #74: a phone works on the race area its role binds or its PRO picks. The
/// store keeps what the admission granted and the race day's race areas, so
/// the phone knows them offline, and stamps the race area's course id into
/// every `fleet.defined` it appends (criterion 3).
void main() {
  const day = '00000000-0000-4000-8000-0000000000d1';
  const admission = '00000000-0000-4000-8000-0000000000a1';
  const otherAdmission = '00000000-0000-4000-8000-0000000000a2';
  const alpha = RaceArea(id: '00000000-0000-4000-8000-00000000c0a1', name: 'Alpha');
  const bravo = RaceArea(id: '00000000-0000-4000-8000-00000000c0b2', name: 'Bravo');

  late EventStore store;
  setUp(() => store = openStore(tempDbPath()));
  tearDown(() => store.close());

  /// Admits the store's phone as [role], on race area [course] for a bound role.
  void admit(String role, {String? course, String id = admission}) {
    store.recordAdmissionEvent(id, day);
    store.recordAdmissionGrant(id, role, course);
    store.setAdmissionId(id);
  }

  EventEnvelope defineFleet([String name = 'Lasers']) => store.append(FleetEvents.define(name));

  group('what the store keeps', () {
    test('a phone never admitted knows no race area', () {
      expect(store.raceAreas().admitted, isFalse);
      expect(store.raceAreas().granted, isFalse);
      expect(store.course, isNull);
    });

    test("an admission whose grant sync has not learned is neither bound nor picking", () {
      store.recordAdmissionEvent(admission, day);
      store.setAdmissionId(admission);
      final info = store.raceAreas();
      expect((info.admitted, info.granted, info.bound, info.picks), (true, false, false, false));
    });

    test('a bound grant fixes the race area, and an event-wide one picks', () {
      admit(Roles.markBoat, course: alpha.id);
      expect((store.raceAreas().bound, store.raceAreas().picks), (true, false));
      expect(store.course, alpha.id);
      admit(Roles.overallPro, id: otherAdmission);
      expect((store.raceAreas().bound, store.raceAreas().picks), (false, true));
      expect(store.course, isNull, reason: 'nothing is picked yet');
    });

    test('a grant never changes: the same again is a no-op, another is refused', () {
      admit(Roles.recorder, course: alpha.id);
      store.recordAdmissionGrant(admission, Roles.recorder, alpha.id);
      expect(() => store.recordAdmissionGrant(admission, Roles.recorder, bravo.id), throwsStateError);
      expect(() => store.recordAdmissionGrant(admission, Roles.overallPro, null), throwsStateError);
      expect(() => store.recordAdmissionGrant(otherAdmission, 'pro', null), throwsArgumentError);
    });

    test("the race day's race areas are kept by name, each once, and survive a restart", () {
      final path = tempDbPath();
      final s = openStore(path);
      s.recordAdmissionEvent(admission, day);
      s.recordAdmissionGrant(admission, Roles.overallPro, null);
      s.setAdmissionId(admission);
      expect(s.recordRaceAreas(day, [bravo, alpha]), 2);
      expect(s.recordRaceAreas(day, [alpha, const RaceArea(id: 'x', name: '  ')]), 0);
      s.close();
      final reopened = openStore(path);
      addTearDown(reopened.close);
      expect(reopened.raceAreas().areas, [alpha, bravo]);
      expect(reopened.raceAreas().grantedRole, Roles.overallPro);
    });
  });

  group('criterion 3: a fleet defined carries its race area', () {
    test("a bound phone's fleet names its race area", () {
      admit(Roles.recorder, course: alpha.id);
      expect(defineFleet().payload[coursePayloadKey], alpha.id);
    });

    test("an event-wide phone's fleet names its pick, and the next pick moves it", () {
      admit(Roles.overallPro);
      store.recordRaceAreas(day, [alpha, bravo]);
      store.append(RoleEvents.assign(Roles.overallPro));
      expect(defineFleet('A').payload.containsKey(coursePayloadKey), isFalse, reason: 'no race area picked yet');
      store.append(RaceAreaEvents.select(bravo.id));
      expect(defineFleet('B').payload[coursePayloadKey], bravo.id);
      final pick = store.append(RaceAreaEvents.select(alpha.id));
      expect(defineFleet('C').payload[coursePayloadKey], alpha.id);
      store.append(RaceAreaEvents.undo(pick.ulid));
      expect(defineFleet('D').payload[coursePayloadKey], bravo.id, reason: 'the undo returns to the pick before');
    });

    test('criterion 4: a phone never admitted defines fleets as #18 did, with no race area', () {
      final fleet = defineFleet();
      expect(fleet.payload, {'name': 'Lasers', 'class': null});
    });

    test('only a fleet.defined is stamped, and one naming its own race area keeps it', () {
      admit(Roles.recorder, course: alpha.id);
      expect(store.append(NewEvent(kind: 'note', source: 'tap', payload: const {})).payload, isEmpty);
      final own = store.append(NewEvent(
          kind: FleetKinds.defined, source: 'tap', payload: {'name': 'X', 'class': null, coursePayloadKey: bravo.id}));
      expect(own.payload[coursePayloadKey], bravo.id);
    });

    test('a pick made under another admission, or before the role pick in force, does not count', () {
      admit(Roles.overallPro);
      store.recordRaceAreas(day, [alpha, bravo]);
      store.append(RoleEvents.assign(Roles.overallPro));
      store.append(RaceAreaEvents.select(alpha.id));
      expect(store.course, alpha.id);
      // A new role pick starts with no race area, as it starts with no station.
      store.append(RoleEvents.assign(Roles.safety));
      expect(store.course, isNull);
      store.append(RaceAreaEvents.select(bravo.id));
      expect(store.course, bravo.id);
      // Re-admitted as another event-wide role: the pick was the old admission's.
      admit(Roles.scorer, id: otherAdmission);
      expect(store.course, isNull);
    });

    test("another phone's pick, pulled down, never moves this one", () {
      admit(Roles.overallPro);
      store.append(RoleEvents.assign(Roles.overallPro));
      store.append(RaceAreaEvents.select(alpha.id));
      final picks = [for (final e in store.readAll()) if (e.kind == RaceAreaKinds.selected) e];
      final other = EventEnvelope(
        ulid: '01J9${'1'.padLeft(22, '0')}',
        deviceTs: picks.single.deviceTs + 1000,
        deviceId: '01J8PH0NE00000000000000002',
        seq: 1,
        source: 'tap',
        kind: RaceAreaKinds.selected,
        payloadVersion: 1,
        admissionId: admission,
        payload: {coursePayloadKey: bravo.id},
      );
      expect(currentCourse(store.raceAreas(), [...store.readAll(), other], store.deviceId), alpha.id);
    });
  });

  group('across the core boundary', () {
    test('raceAreas answers the same through a client as from the store', () async {
      final path = tempDbPath();
      final s = openStore(path);
      s.recordAdmissionEvent(admission, day);
      s.recordAdmissionGrant(admission, Roles.markBoat, bravo.id);
      s.recordRaceAreas(day, [alpha, bravo]);
      s.setAdmissionId(admission);
      s.close();
      final client = await spawnCore(path);
      addTearDown(client.close);
      final info = await client.raceAreas();
      expect((info.admissionId, info.grantedRole, info.boundCourse), (admission, Roles.markBoat, bravo.id));
      expect(info.areas, [alpha, bravo]);
    });

    test('the fake core keeps a join\'s grant and stamps as the real one does', () async {
      final fake = FakeCore()
        ..onJoin = (_) async =>
            Admission(admissionId: admission, eventId: day, role: Roles.coursePro, courseId: alpha.id, raceArea: alpha.name);
      await fake.join('ABCD1234');
      final info = await fake.raceAreas();
      expect((info.bound, info.boundCourse), (true, alpha.id));
      expect(info.areas, [alpha]);
      expect((await fake.append(FleetEvents.define('Lasers'))).payload[coursePayloadKey], alpha.id);
    });
  });
}
