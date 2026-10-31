import 'package:flutter_test/flutter_test.dart';

import 'support/local_stack.dart';

/// #41: tests against a local Supabase built from the companion's own migrations. These are the
/// samples for the helper in support/local_stack.dart. A phone is seeded through the stack's auth
/// and admission function (criterion 2), and the event log's refusals are the database's, met the
/// way a phone meets them (criteria 3 and 4). They skip unless PRO_COMPANION_LOCAL_STACK=1, which
/// the CI job `local-stack` sets (README, Server side).
void main() {
  /// PostgREST's answer when the role holds no privilege on the event log.
  final refusedByGrant = allOf(
    containsPair('code', '42501'),
    containsPair('message', 'permission denied for table event_log'),
  );

  group('against the local stack (#41)', () {
    late LocalStack stack;

    setUpAll(() async {
      stack = await LocalStack.connect();
    });

    test('criterion 2: a phone is signed in by the stack\'s auth and admitted by admit_device, '
        'never through service_role', () async {
      final day = await stack.raceDay(raceAreas: ['Alpha', 'Bravo']);
      stack.phoneRequests.clear();

      final pro = await stack.admittedPhone(day, 'overall_pro');
      final recorder = await stack.admittedPhone(day, 'recorder', raceArea: 'Bravo');

      expect(stack.phoneRequests, [
        'POST /auth/v1/signup publishable',
        'POST /rest/v1/rpc/admit_device publishable+token',
        'POST /auth/v1/signup publishable',
        'POST /rest/v1/rpc/admit_device publishable+token',
      ], reason: 'each phone signs in, then admits itself with its own token; no secret key');
      for (final phone in [pro, recorder]) {
        expect(phone.claims['role'], 'authenticated');
        expect(phone.claims['is_anonymous'], true);
        expect(phone.claims['sub'], phone.userId);
      }

      // Each phone reads its own admission back through RLS: the role and race area its code grants.
      const select = {'select': 'id,role,course_id,person'};
      final (proStatus, proRows) = await pro.send('GET', '/rest/v1/committee_device', query: select);
      expect(proStatus, 200, reason: '$proRows');
      expect(proRows, [
        {'id': pro.admissionId, 'role': 'overall_pro', 'course_id': null, 'person': null},
      ]);
      final (recorderStatus, recorderRows) =
          await recorder.send('GET', '/rest/v1/committee_device', query: select);
      expect(recorderStatus, 200, reason: '$recorderRows');
      // A device-handoff admission names no person (#5): the phone passes from hand to hand.
      expect(recorderRows, [
        {
          'id': recorder.admissionId,
          'role': 'recorder',
          'course_id': day.raceAreaIds['Bravo'],
          'person': null,
        },
      ]);
    });

    test('criterion 3: a phone never admitted cannot insert into the event log', () async {
      final day = await stack.raceDay();
      final stranger = await stack.phone();

      final (status, body) = await stranger.send('POST', '/rest/v1/event_log',
          body: {'event_id': day.eventId, 'canonical': sampleEvent(newUlid())});
      expect(status, 403, reason: '$body');
      expect(body, refusedByGrant);

      // The refusal is the database's, as a phone meets it: the same stack's RLS hides the club
      // from this phone and shows it to a phone admitted to the event.
      final member = await stack.admittedPhone(day, 'scorer');
      final club = {'select': 'id', 'id': 'eq.${day.clubId}'};
      expect((await stranger.send('GET', '/rest/v1/club', query: club)).$2, isEmpty);
      expect((await member.send('GET', '/rest/v1/club', query: club)).$2, [
        {'id': day.clubId},
      ]);
    });

    test('criterion 4: an admitted phone cannot update or delete a row of the event log', () async {
      final day = await stack.raceDay();
      final phone = await stack.admittedPhone(day, 'overall_pro');
      final row = await stack.seedEventLogRow(day.eventId);
      final filter = {'ulid': 'eq.${row.ulid}'};

      // The grant layer holds (owner decision on #41): the phone holds no privilege on the log.
      // Behind it, #40's append-only triggers refuse every role; supabase/tests/event_log_test.sql
      // holds those.
      final (updateStatus, updateBody) = await phone.send('PATCH', '/rest/v1/event_log',
          query: filter, body: {'received_at': '2026-09-27T12:00:00Z'});
      expect(updateStatus, 403, reason: '$updateBody');
      expect(updateBody, refusedByGrant);

      final (deleteStatus, deleteBody) =
          await phone.send('DELETE', '/rest/v1/event_log', query: filter);
      expect(deleteStatus, 403, reason: '$deleteBody');
      expect(deleteBody, refusedByGrant);

      expect(await stack.eventLogCanonical(row.ulid), row.canonical, reason: 'the row is untouched');
    });

    // #70's review found that an admission overlapping a role change of the same phone met the
    // one-active index and answered a bare 23505. A call waiting on the lock cannot see the
    // successor the other committed; admit_device now looks again once. pgTAP runs in one session,
    // so the overlap is made here, from two database sessions.
    test('#70: an admission overlapping a role change of the same phone answers as if it came after',
        () async {
      final day = await stack.raceDay();
      final scorer = day.codes['scorer']!;
      final pro = day.codes['overall_pro']!;
      final safety = day.codes['safety']!;

      /// The phone admitted as scorer, then a role change to overall PRO held open, and [code]
      /// presented while it is held. Returns the held call's answer, the overlapping call's, and
      /// how long the overlapping call took.
      Future<(String, String, Duration)> overlap(String uid, String code) async {
        expect(await stack.admitInSession(uid, day.eventId, scorer), matches(uuid));
        final held = stack.admitInSession(uid, day.eventId, pro, hold: const Duration(seconds: 4));
        await stack.untilHeld(uid);
        final clock = Stopwatch()..start();
        final second = await stack.admitInSession(uid, day.eventId, code);
        clock.stop();
        return (await held, second, clock.elapsed);
      }

      // The same slot: the overlapping call gets the held call's admission.
      final samePhone = randomUuid();
      final (heldSame, secondSame, waitedSame) = await overlap(samePhone, pro);
      expect(heldSame, matches(uuid), reason: heldSame);
      expect(waitedSame, greaterThan(const Duration(seconds: 2)),
          reason: 'the second call waited for the held one, so the two overlapped');
      expect(secondSame, heldSame, reason: 'the overlapping same-slot call answers with the successor');
      expect((await stack.admissionChain(day.eventId, samePhone)).map((a) => a['role']),
          ['scorer', 'overall_pro'], reason: 'and adds no row');

      // Another slot: the overlapping call supersedes the held call's admission.
      final otherPhone = randomUuid();
      final (heldOther, secondOther, waitedOther) = await overlap(otherPhone, safety);
      expect(waitedOther, greaterThan(const Duration(seconds: 2)));
      expect(secondOther, matches(uuid), reason: secondOther);
      final chain = await stack.admissionChain(day.eventId, otherPhone);
      expect(chain, [
        {'id': chain.first['id'], 'role': 'scorer', 'superseded_by': heldOther},
        {'id': heldOther, 'role': 'overall_pro', 'superseded_by': secondOther},
        {'id': secondOther, 'role': 'safety', 'superseded_by': null},
      ], reason: 'the overlapping call for another slot supersedes the successor');
    });
  }, skip: localStackRequested ? false : localStackSkip);
}

/// A lowercase hyphenated UUID, as admit_device answers.
final uuid = RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');
