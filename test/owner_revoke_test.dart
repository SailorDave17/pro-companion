import 'package:flutter_test/flutter_test.dart';

import '../scripts/owner.dart' as owner;
import 'support/local_stack.dart';

/// #72: the owner script's revoke subcommand, run against #41's local stack the way the owner runs
/// it. What a revoked admission does on the server is held by supabase/tests/append_event_test.sql
/// and re_admission_test.sql; these hold what the subcommand does with a device. They skip unless
/// PRO_COMPANION_LOCAL_STACK=1, which the CI job `local-stack` sets (README, Server side).
///
/// The stack allows 30 anonymous sign-ins an hour, so this file spends one, and three magic-link
/// verifications. Every other phone is seated in a database session, which spends none, and writes
/// nothing.
void main() {
  group('revoke against the local stack (#72)', () {
    late LocalStack stack;
    late Map<String, String> status;

    setUpAll(() async {
      stack = await LocalStack.connect();
      status = await owner.readLocalStatus();
    });

    Future<({int code, String out, String err})> revoke(List<String> args) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await owner.run(['revoke', ...args],
          out: out, err: err, localStatus: () async => status);
      return (code: code, out: '$out', err: '$err');
    }

    String newClub() => 'Revoke test ${DateTime.now().microsecondsSinceEpoch}';

    /// The flags that name [event] of [club], which raceDay provisions on 2026-09-27.
    List<String> named(String club, {String event = 'Test day'}) =>
        ['--club', club, '--event', event, '--date', '2026-09-27'];

    /// A phone admitted to [day] with the code for [slot] (`scorer`, `recorder Alpha`), and its id.
    /// Given [uid], that phone presents the code, as a role change does.
    Future<String> seat(owner.Provisioned day, String slot, {String? uid}) async {
      final phone = uid ?? randomUuid();
      expect(await stack.admitInSession(phone, day.eventId, day.codes[slot]!),
          isNot(startsWith('refused')));
      return phone;
    }

    List<String> admissionLines(String out) =>
        [for (final line in out.split('\n')) if (line.startsWith('admission ')) line];

    Future<(int, Object?)> append(Phone phone, String eventId, int seq) => phone.send(
        'POST', '/rest/v1/rpc/append_event',
        body: {'p_event': eventId, 'p_canonical': sampleEvent(newUlid(), seq: seq)});

    test('criterion 1: with no device it lists every admission of the event, with its role, race '
        'area, person, admitted time and state, and changes nothing', () async {
      final club = newClub();
      final day = await stack.raceDay(raceAreas: ['Alpha', 'Bravo'], club: club);
      final gone = await seat(day, 'scorer');
      final moved = await seat(day, 'recorder Alpha');
      await seat(day, 'recorder Bravo', uid: moved);
      final volunteer = await stack.admittedNamedPhone(day, 'overall_pro', person: 'Jo Volunteer');
      // Revoked last, so the update moves its row behind the others: only the read's order can put
      // it first again.
      await stack.revoke((await stack.admissionChain(day.eventId, gone)).single['id']! as String);
      // Another event of the club, whose admission must not be listed here.
      await seat(await stack.raceDay(club: club, event: 'Another day'), 'scorer');

      final before = await stack.admissions(day.eventId);
      final times = [for (final row in before) row['admitted_at']];
      final run = await revoke(named(club));

      expect(run.code, 0, reason: run.err);
      expect(run.out,
          startsWith('target      the local stack\nevent       ${day.eventId}  Test day on 2026-09-27\n'));
      expect(admissionLines(run.out), [
        'admission   $gone  scorer  whole event  no person  ${times[0]}  revoked',
        'admission   $moved  recorder  Alpha  no person  ${times[1]}  superseded',
        'admission   $moved  recorder  Bravo  no person  ${times[2]}  active',
        'admission   ${volunteer.userId}  overall_pro  whole event  Jo Volunteer  ${times[3]}  active',
      ]);
      expect(await stack.admissions(day.eventId), before, reason: 'a list changes nothing');
    });

    test('criterion 2: a named device has its active admission in the event marked and its next '
        'write refused, and no other phone or event is touched', () async {
      final club = newClub();
      final day = await stack.raceDay(raceAreas: ['Alpha', 'Bravo'], club: club);
      final otherDay = await stack.raceDay(club: club, event: 'Another day');
      final phone = await stack.admittedPhone(day, 'recorder', raceArea: 'Alpha');
      await stack.admit(phone, day, 'recorder', raceArea: 'Bravo');
      await stack.admit(phone, otherDay, 'scorer');
      // A replacement holding the same role's code, so a revoke keyed on the role takes it too (#5).
      final replacement = await seat(day, 'recorder Bravo');

      final (writes, wrote) = await append(phone, day.eventId, 1);
      expect(writes, 200, reason: 'the phone writes until it is revoked: $wrote');

      final run = await revoke([...named(club), '--device', phone.userId]);
      expect(run.code, 0, reason: run.err);

      final rows = await stack.admissions(day.eventId);
      expect([
        for (final row in rows)
          [row['auth_uid'], row['race_area'], row['superseded_by'] != null, row['revoked']],
      ], [
        [phone.userId, 'Alpha', true, false],
        [phone.userId, 'Bravo', false, true],
        [replacement, 'Bravo', false, false],
      ]);
      expect(admissionLines(run.out), hasLength(2), reason: 'it prints the phone\'s own admissions');
      expect(run.out, contains('  superseded\n'));
      expect(run.out, contains('  revoked\n'));

      final logged = await stack.eventLog(day.eventId);
      final (refused, why) = await append(phone, day.eventId, 2);
      expect(refused, 422, reason: '$why');
      expect(why, allOf(containsPair('code', 'append_event_refused'), containsPair('details', 'revoked')));
      expect(await stack.eventLog(day.eventId), logged, reason: 'nothing was stored');

      final (presented, answer) = await stack.tryAdmit(phone, day, 'recorder', raceArea: 'Bravo');
      expect(presented, 403, reason: '$answer');

      final (elsewhere, wroteElsewhere) = await append(phone, otherDay.eventId, 1);
      expect(elsewhere, 200, reason: 'a revoke holds in its own event only: $wroteElsewhere');

      // Revoking a sign-in does not retire the role's code: a new sign-in with it is admitted.
      await seat(day, 'recorder Bravo');
    });

    test('a named volunteer\'s id is their account: a revoke takes the spare phone signed in to it '
        'off the event too', () async {
      final club = newClub();
      final day = await stack.raceDay(club: club);
      final lost = await stack.admittedNamedPhone(day, 'scorer', person: 'Jo Volunteer');
      final spare = await stack.signInAgain(lost);
      expect(spare.userId, lost.userId, reason: 'both phones are one Auth user');
      final (writes, wrote) = await append(spare, day.eventId, 1);
      expect(writes, 200, reason: 'the spare writes until the revoke: $wrote');

      final run = await revoke([...named(club), '--device', lost.userId]);
      expect(run.code, 0, reason: run.err);
      expect(run.out, contains('A named volunteer\'s id is their account'));

      final (refused, why) = await append(spare, day.eventId, 2);
      expect(refused, 422, reason: '$why');
      expect(why, containsPair('details', 'revoked'));
      final (presented, answer) = await stack.tryAdmit(spare, day, 'safety');
      expect(presented, 403, reason: 'any code, whatever the phone: $answer');
    });

    test('criterion 3: a device already revoked reports no change and exits zero', () async {
      final club = newClub();
      final day = await stack.raceDay(club: club);
      final phone = await seat(day, 'scorer');
      expect((await revoke([...named(club), '--device', phone])).code, 0);
      final revoked = await stack.admissions(day.eventId);
      expect(revoked.single['revoked'], true);

      final again = await revoke([...named(club), '--device', phone]);

      expect(again.code, 0, reason: again.err);
      expect(again.out, contains('no change   $phone was already revoked from this event'));
      expect(admissionLines(again.out), isEmpty, reason: 'nothing to report on');
      expect(await stack.admissions(day.eventId), revoked, reason: 'the first revoke\'s time stands');

      // Two runs that both read the row active both call revoke_device, and the script's skip cannot
      // help. In a session of its own, so now() has moved on, which a pgTAP transaction cannot show.
      await stack.revoke(revoked.single['id']! as String);
      expect(await stack.admissions(day.eventId), revoked, reason: 'revoke_device keeps the first time');
    });

    test('criterion 4: an unknown device, or one admitted only to another event, exits non-zero '
        'with a message and changes nothing', () async {
      final club = newClub();
      final day = await stack.raceDay(club: club);
      final otherDay = await stack.raceDay(club: club, event: 'Another day');
      await seat(day, 'scorer');
      final elsewhere = await seat(otherDay, 'scorer');
      final before = [...await stack.admissions(day.eventId), ...await stack.admissions(otherDay.eventId)];

      for (final device in [randomUuid(), elsewhere]) {
        final run = await revoke([...named(club), '--device', device]);
        expect(run.code, 1, reason: run.out);
        expect(run.err,
            contains('no admission to this event belongs to the id $device; nothing was changed'));
      }

      expect([...await stack.admissions(day.eventId), ...await stack.admissions(otherDay.eventId)], before);
    });

    test('a phone changing role while revoke runs fails the run, and running it again finishes it',
        () async {
      final club = newClub();
      final day = await stack.raceDay(club: club);
      final phone = await seat(day, 'scorer');

      // The role change holds the row revoke_device needs. So the revoke waits, lands on the row the
      // change superseded, and leaves the new admission active. The phone is refused either way
      // (any revoked admission refuses it, #70), but criterion 2 asks for every active admission.
      final change = stack.admitInSession(phone, day.eventId, day.codes['safety']!,
          hold: const Duration(seconds: 4));
      await stack.untilHeld(phone);
      final run = await revoke([...named(club), '--device', phone]);
      await change;

      expect(run.code, 1, reason: run.out);
      expect(run.err, contains('Run revoke again'));

      final again = await revoke([...named(club), '--device', phone]);
      expect(again.code, 0, reason: again.err);
      expect([
        for (final row in await stack.admissions(day.eventId))
          [row['role'], row['superseded_by'] != null, row['revoked']],
      ], [
        ['scorer', true, true],
        ['safety', false, true],
      ]);
      expect(admissionLines(again.out).first, endsWith('  superseded, revoked'));
    });

    test('two events sharing a club, name and date are refused with their ids, and --event-id picks '
        'one', () async {
      final club = newClub();
      final first = await stack.raceDay(club: club);
      final second = await stack.raceDay(club: club);
      final phone = await seat(second, 'scorer');

      final refused = await revoke([...named(club), '--device', phone]);
      expect(refused.code, 1, reason: refused.out);
      expect(refused.err, contains('2 events are named "Test day" on 2026-09-27 at "$club"'));
      expect(refused.err, contains('--event-id: ${first.eventId}, ${second.eventId}'));
      expect((await stack.admissions(second.eventId)).single['revoked'], false);

      final listed = await revoke(['--event-id', second.eventId]);
      expect(listed.code, 0, reason: listed.err);
      expect(admissionLines(listed.out).single, startsWith('admission   $phone  scorer'));

      final empty = await revoke(['--event-id', first.eventId]);
      expect(empty.code, 0, reason: empty.err);
      expect(empty.out, contains('No phone has been admitted to this event.'));

      final picked = await revoke(['--event-id', second.eventId, '--device', phone]);
      expect(picked.code, 0, reason: picked.err);
      expect((await stack.admissions(second.eventId)).single['revoked'], true);
    });

    test('a club or an event that is not there exits non-zero with a message', () async {
      final club = newClub();
      await stack.raceDay(club: club);
      final missing = {
        'no club is named': named('$club, gone'),
        'no event is named "Another day"': named(club, event: 'Another day'),
        'no event is named "Test day" on 2026-09-28': ['--club', club, '--event', 'Test day', '--date', '2026-09-28'],
        'no event has the id': ['--event-id', randomUuid()],
      };
      for (final MapEntry(key: message, value: args) in missing.entries) {
        final run = await revoke(args);
        expect(run.code, 1, reason: run.out);
        expect(run.err, contains(message));
      }
    });
  }, skip: localStackRequested ? false : localStackSkip);
}
