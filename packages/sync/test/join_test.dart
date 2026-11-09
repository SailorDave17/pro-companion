import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pro_companion_core/core.dart' show RoleEvents;
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_sync/sync.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #71: the engine's join, the one call the join screen makes, against the real client over the
/// scripted server. Signs the phone in by device handoff when it holds no session, looks the race
/// day up from the code, admits the phone, reads what the code granted, and stamps the admission on
/// the store with the role-change marker on a change (G46). Every failure comes back as a
/// CoreException coded from JoinCodes, so the screen can tell a refusal from no signal.
void main() {
  const alpha = '00000000-0000-4000-8000-0000000000ca';
  const bravo = '00000000-0000-4000-8000-0000000000cb';

  FakeServer server() => FakeServer()
    ..issueCode('RECO-ALFA', event: dayOne, role: 'recorder', course: alpha)
    ..issueCode('MARK-BRAV', event: dayOne, role: 'mark_boat', course: bravo)
    ..issueCode('SCOR-D1', event: dayOne, role: 'scorer')
    ..issueCode('OPRO-D2', event: dayTwo, role: 'overall_pro')
    ..courses[alpha] = 'Alpha'
    ..courses[bravo] = 'Bravo'
    ..eventNames[dayOne] = 'Club night'
    ..eventNames[dayTwo] = 'Their regatta';

  (TestPhone, SyncEngine) fresh(FakeServer s) {
    final phone = TestPhone();
    final engine = phone.engine(s);
    addTearDown(engine.close);
    return (phone, engine);
  }

  Iterable<String> paths(FakeServer s) => s.requests.map((r) => r.path);

  group('criterion 1: a valid code admits the phone and the core caches the admission', () {
    test('a phone with no session signs in by device handoff, admit_device is called, and the grant comes back', () async {
      final s = server();
      final (phone, engine) = fresh(s);

      final granted = await engine.join('RECO-ALFA');

      expect(paths(s), containsAllInOrder(['/auth/v1/signup', '/rest/v1/rpc/race_day_for_code', '/rest/v1/rpc/admit_device']));
      final admit = s.requests.singleWhere((r) => r.path == '/rest/v1/rpc/admit_device');
      expect(admit.json, {'p_event': dayOne, 'p_admission_code': 'RECO-ALFA'}, reason: 'the race day the lookup answered, and no person');
      expect(s.anonymous[admit.caller], isTrue, reason: 'the device-handoff path');
      expect(granted.role, 'recorder');
      expect(granted.raceArea, 'Alpha');
      expect(granted.courseId, alpha);
      expect(granted.eventId, dayOne);
      expect(s.admissions[admit.caller]?.keys, [granted.admissionId]);
      expect(phone.store.admissionId, granted.admissionId, reason: 'cached in the core');
      expect(phone.store.admissionEvent(granted.admissionId), dayOne, reason: 'and its race day, for the upload');
      expect(phone.sessionFile.existsSync(), isTrue, reason: 'the session is kept before the join returns');
      expect(phone.store.readOwn(), isEmpty, reason: 'a first admission appends no marker');
    });

    test('an event-wide role grants no race area', () async {
      final s = server();
      final (_, engine) = fresh(s);
      final granted = await engine.join('SCOR-D1');
      expect([granted.role, granted.courseId, granted.raceArea], ['scorer', null, null]);
      // Since #74 the join reads the race day's race areas, which an event-wide phone picks from,
      // and never one race area by id, since none was granted.
      final courseReads = s.requests.where((r) => r.path == '/rest/v1/course').toList();
      expect([for (final r in courseReads) r.query.keys.toSet()], [
        {'select', 'event_id'}
      ]);
    });

    test('a phone already signed in keeps its user: no second sign-in', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      final first = await engine.join('RECO-ALFA');
      final signUps = paths(s).where((p) => p == '/auth/v1/signup').length;
      final again = await engine.join('RECO-ALFA');
      expect(again, first, reason: 'the active slot\'s own code answers the same admission (#70)');
      expect(paths(s).where((p) => p == '/auth/v1/signup').length, signUps);
      expect(phone.store.readOwn(), isEmpty, reason: 'the same admission again appends no marker');
    });

    test('what it logged then uploads under the admission, and the phone\'s role pick stamps the rest', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.join('RECO-ALFA');
      phone.store.append(RoleEvents.assign('recorder'));
      phone.log(2);
      final run = await engine.syncOnce();
      expect(run.accepted, 3, reason: '$run');
    });
  });

  group('criterion 2: a code the server refuses', () {
    test('an unknown code is refused with one plain sentence, naming no role, race area or event', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      final e = await engine.join('XXXX-0000').then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<CoreException>().having((e) => e.code, 'code', JoinCodes.refused));
      final message = (e as CoreException).message;
      expect(message, 'That code was not recognised.');
      for (final word in ['recorder', 'scorer', 'mark', 'Alpha', 'Bravo', 'Club night', 'regatta', dayOne]) {
        expect(message.toLowerCase(), isNot(contains(word.toLowerCase())), reason: word);
      }
      expect(phone.store.admissionId, isNull);
      expect(paths(s), isNot(contains('/rest/v1/rpc/admit_device')), reason: 'refused at the lookup');
    });

    test('a code admit_device itself refuses reads the same way, and a revoked phone or a mode is its own sentence', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      s.hooks.add((r) => r.path.endsWith('/rpc/admit_device') ? FakeServer.notRecognised() : null);
      await expectLater(engine.join('RECO-ALFA'),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.refused).having((e) => e.message, 'message', 'That code was not recognised.')));
      s.hooks.clear();

      s.hooks.add((r) => r.path.endsWith('/rpc/admit_device')
          ? postgrestError(403, '42501', 'admit_device: this device was revoked from the event')
          : null);
      await expectLater(engine.join('RECO-ALFA'),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.refused).having((e) => e.message, 'message', 'This phone was revoked from the race day.')));
      s.hooks.clear();

      // #104 criterion 3: the sentence names how the club does sign phones
      // in, read from the refusal's details. This phone holds no admission, so
      // the refused session is dropped and the sentence names the next step
      // (#104's review); sign_in_test.dart holds an admitted phone's form.
      const handoff =
          "This club signs phones in by device handoff, not by a volunteer's email. Enter the code again to join by device handoff.";
      for (final (details, sentence) in [
        (
          'sign_in_mode=named_volunteers path=device_handoff',
          "This club signs phones in by each volunteer's own email. Sign in by email first."
        ),
        ('sign_in_mode=device_handoff path=named_volunteers', handoff),
        ('sign_in_mode=device_handoff path=unknown', handoff),
        ('sign_in_mode=some_later_mode path=named_volunteers', 'The club does not admit phones signed in this way.'),
      ]) {
        s.hooks.clear();
        s.hooks.add((r) => r.path.endsWith('/rpc/admit_device')
            ? http.Response(jsonEncode({'code': '42501', 'details': details, 'hint': null, 'message': 'x'}), 403,
                headers: {'content-type': 'application/json'})
            : null);
        await expectLater(engine.join('RECO-ALFA'),
            throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.refused).having((e) => e.message, 'message', sentence)),
            reason: details);
      }
      expect(phone.store.admissionId, isNull, reason: 'nothing stamped by a refusal');
    });

    test('a refusal leaves the session: the next code is tried as the same user', () async {
      final s = server();
      final (_, engine) = fresh(s);
      await expectLater(engine.join('XXXX-0000'), throwsA(isA<CoreException>()));
      final granted = await engine.join('RECO-ALFA');
      expect(paths(s).where((p) => p == '/auth/v1/signup').length, 1);
      expect(granted.role, 'recorder');
    });
  });

  group('criterion 3: no signal', () {
    test('offline, nothing is signed in or admitted, and the failure says no signal', () async {
      final s = server()..offline = true;
      final (phone, engine) = fresh(s);
      await expectLater(engine.join('RECO-ALFA'), throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.noSignal)));
      expect(s.admissions, isEmpty);
      expect(phone.sessionFile.existsSync(), isFalse, reason: 'no user was minted offline');
      expect(phone.store.admissionId, isNull);

      s.offline = false;
      final granted = await engine.join('RECO-ALFA');
      expect(granted.role, 'recorder', reason: 'the same code, sent again once signal is back');
    });

    test('a gateway\'s page or a dead link mid-way is no signal, not a refusal', () async {
      final s = server();
      final (_, engine) = fresh(s);
      s.hooks.add((r) => r.path.endsWith('/rpc/admit_device') ? http.Response('<html>Bad Gateway</html>', 502) : null);
      await expectLater(engine.join('RECO-ALFA'), throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.noSignal)));
      s.hooks.clear();
      s.hooks.add((r) => r.path.endsWith('/rpc/race_day_for_code') ? throw http.ClientException('dropped') : null);
      await expectLater(engine.join('RECO-ALFA'), throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.noSignal)));
    });

    test('a kept session the phone cannot check is no signal, never a fresh sign-in', () async {
      final s = server();
      final phone = TestPhone();
      phone.keepSession(s.session(uuid(0xa11c), validFor: const Duration(seconds: -600)));
      s.offline = true;
      final engine = phone.engine(s);
      addTearDown(engine.close);
      await expectLater(engine.join('RECO-ALFA'), throwsA(isA<CoreException>().having((e) => e.code, 'code', JoinCodes.noSignal)));
      expect(s.requests.where((r) => r.path == '/auth/v1/signup'), isEmpty, reason: 'a new user would strand the kept one\'s events');
      expect(phone.sessionFile.existsSync(), isTrue, reason: 'the kept session stays for the next try');
    });

    test('a rate-limited sign-in is a failure with its own sentence, not no signal', () async {
      final s = server();
      final (_, engine) = fresh(s);
      s.hooks.add((r) => r.path == '/auth/v1/signup'
          ? http.Response(jsonEncode({'code': 'over_request_rate_limit', 'message': 'rate limited'}), 429,
              headers: {'content-type': 'application/json', 'x-supabase-api-version': '2024-01-01'})
          : null);
      await expectLater(
          engine.join('RECO-ALFA'),
          throwsA(isA<CoreException>()
              .having((e) => e.code, 'code', JoinCodes.failed)
              .having((e) => e.message, 'message', contains('rate limiting'))));
    });
  });

  group('criterion 6: a role change appends the marker under the old admission before the new one is stamped', () {
    test('the marker is the old admission\'s last event from this phone, and it uploads accepted', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      final first = await engine.join('RECO-ALFA');
      phone.store.append(RoleEvents.assign('recorder'));
      final before = phone.log(2);

      final second = await engine.join('MARK-BRAV');
      expect(second.admissionId, isNot(first.admissionId));
      expect([second.role, second.raceArea], ['mark_boat', 'Bravo']);
      phone.store.append(RoleEvents.assign('mark_boat'));
      final after = phone.log(1);

      final own = phone.store.readOwn();
      final marker = own.singleWhere((e) => e.kind == AdmissionKinds.superseded);
      expect(marker.admissionId, first.admissionId, reason: 'under the admission being left');
      expect(marker.payload, {'superseded_by': second.admissionId});
      expect(marker.role, 'recorder', reason: 'the role the phone ran as under it');
      for (final e in own) {
        expect(e.seq <= marker.seq, e.admissionId == first.admissionId, reason: '${e.kind} seq ${e.seq}');
      }
      expect(phone.store.admissionId, second.admissionId);

      final run = await engine.syncOnce();
      expect(run.accepted, 6, reason: 'pick, 2 notes, the marker, the new pick, 1 note: $run');
      final sent = [for (final u in [...before, marker.ulid, ...after]) s.appendsOf(u)];
      expect(sent, everyElement(1));
      expect(s.appends.map((r) => (jsonDecode(r.json['p_canonical'] as String) as Map)['seq']).toList(), [1, 2, 3, 4, 5, 6],
          reason: 'in sequence order, so the marker lands before anything written after it');
    });

    test('a join the server refuses after a change appends no marker and leaves the admission', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      final first = await engine.join('RECO-ALFA');
      await expectLater(engine.join('XXXX-0000'), throwsA(isA<CoreException>()));
      expect(phone.store.admissionId, first.admissionId);
      expect(phone.store.readOwn().where((e) => e.kind == AdmissionKinds.superseded), isEmpty);
    });
  });
}
