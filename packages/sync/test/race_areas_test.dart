import 'package:http/http.dart' as http;
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_sync/sync.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #74 criterion 2's "fetched once with signal and cached offline": the engine keeps what each
/// admission granted and the race day's race areas on the phone, so an event-wide phone can pick
/// one, and a bound phone show its own, with no signal.
void main() {
  const alpha = '00000000-0000-4000-8000-0000000000ca';
  const bravo = '00000000-0000-4000-8000-0000000000cb';
  const charlie = '00000000-0000-4000-8000-0000000000cc';
  const user = '00000000-0000-4000-8000-0000000000b0';

  FakeServer server() => FakeServer()
    ..issueCode('MARK-BRAV', event: dayOne, role: 'mark_boat', course: bravo)
    ..issueCode('OPRO-D1', event: dayOne, role: 'overall_pro')
    ..addCourse(bravo, 'Bravo', event: dayOne)
    ..addCourse(alpha, 'Alpha', event: dayOne)
    ..addCourse(charlie, 'Charlie', event: dayTwo)
    ..eventNames[dayOne] = 'Club night';

  (TestPhone, SyncEngine) fresh(FakeServer s) {
    final phone = TestPhone();
    final engine = phone.engine(s);
    addTearDown(engine.close);
    return (phone, engine);
  }

  int courseReads(FakeServer s) => s.requests.where((r) => r.path == '/rest/v1/course').length;

  group('at the join', () {
    test("an event-wide phone keeps its grant and its race day's race areas, and no other day's", () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.join('OPRO-D1');
      final info = phone.store.raceAreas();
      expect((info.grantedRole, info.picks, info.bound), ('overall_pro', true, false));
      expect([for (final a in info.areas) a.name], ['Alpha', 'Bravo'], reason: 'by name, Charlie being day two\'s');
      final read = s.requests.lastWhere((r) => r.path == '/rest/v1/course');
      expect(read.query['event_id'], 'eq.$dayOne', reason: 'the race day, never the whole table');
    });

    test('a bound phone keeps its race area as fixed', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.join('MARK-BRAV');
      final info = phone.store.raceAreas();
      expect((info.grantedRole, info.bound, info.boundCourse), ('mark_boat', true, bravo));
      expect(info.byId(bravo)?.name, 'Bravo');
    });

    test('a failed race-area read leaves the admission standing, and the next pull reads them', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      var refuse = true;
      s.hooks.add((r) async => refuse && r.path == '/rest/v1/course' && r.query.containsKey('event_id')
          ? throw http.ClientException('no signal')
          : null);
      final granted = await engine.join('OPRO-D1');
      expect(phone.store.admissionId, granted.admissionId);
      expect(phone.store.raceAreas().areas, isEmpty);
      refuse = false;
      final run = await engine.syncOnce();
      expect(run.pull?.state, PullRunState.done, reason: '$run');
      expect(phone.store.raceAreas().areas.map((a) => a.name), ['Alpha', 'Bravo']);
    });
  });

  group('at a pull', () {
    test('an admission made before #74 gets its grant and race areas from the first pull', () async {
      final s = server();
      final phone = TestPhone();
      s.anonymous[user] = true;
      final admission = s.admitDirectly(user, dayOne, role: 'recorder', course: alpha);
      phone.store.setAdmissionId(admission);
      phone.keepSession(s.session(user));
      final engine = phone.engine(s);
      addTearDown(engine.close);
      expect(phone.store.raceAreas().granted, isFalse, reason: 'control: nothing known before the pull');

      final run = await engine.syncOnce();
      expect(run.pull?.state, PullRunState.done, reason: '$run');
      final info = phone.store.raceAreas();
      expect((info.grantedRole, info.boundCourse), ('recorder', alpha));
      expect(info.areas.map((a) => a.name), ['Alpha', 'Bravo']);
    });

    test('race areas are read once: a second pull reads none, and an offline phone still knows them', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.join('OPRO-D1');
      await engine.syncOnce();
      final reads = courseReads(s);
      await engine.syncOnce();
      expect(courseReads(s), reads, reason: 'kept, not fetched again');
      s.offline = true;
      await engine.syncOnce();
      expect(phone.store.raceAreas().areas.map((a) => a.name), ['Alpha', 'Bravo']);
    });
  });
}
