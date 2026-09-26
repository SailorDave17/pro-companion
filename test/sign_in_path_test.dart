import 'package:flutter_test/flutter_test.dart';

import '../scripts/owner.dart' as owner;
import 'support/local_stack.dart';

/// #5: the club's sign-in paths, met the way a phone meets them on #41's local stack. A
/// device-handoff phone signs in anonymously. A named volunteer's phone signs in by magic link,
/// seeded through the stack's admin API because a test cannot click an email link. Both present a
/// role's admission code. supabase/tests/sign_in_path_test.sql holds every rule against the token's
/// claims; these hold what only real sign-ins show: the token each path carries, four phones
/// appending at once, a replacement phone, and the owner script switching a club's mode. They skip
/// unless PRO_COMPANION_LOCAL_STACK=1, which the CI job `local-stack` sets (README, Server side).
///
/// The stack allows 30 anonymous sign-ins an hour, so this file spends five of them, and four
/// magic-link sign-ins.
void main() {
  group('sign-in paths against the local stack (#5)', () {
    late LocalStack stack;
    late Map<String, String> status;

    setUpAll(() async {
      stack = await LocalStack.connect();
      status = await owner.readLocalStatus();
    });

    Future<(int, Object?)> append(Phone phone, String eventId, String canonical) => phone.send(
        'POST', '/rest/v1/rpc/append_event', body: {'p_event': eventId, 'p_canonical': canonical});

    /// [phone]'s admissions as it reads them itself, through RLS.
    Future<Object?> ownAdmissions(Phone phone) async {
      final (code, rows) = await phone.send('GET', '/rest/v1/committee_device', query: {'select': 'id'});
      expect(code, 200, reason: '$rows');
      return rows;
    }

    test('criteria 1, 2, 6, 7 and 8: four phones on two race areas, two by each path, each hold '
        'their own admission and append at once; a replacement joins without revoking the original',
        () async {
      final day = await stack.raceDay(raceAreas: ['Alpha', 'Bravo']);
      stack.phoneRequests.clear();
      final handoffAlpha = await stack.admittedPhone(day, 'recorder', raceArea: 'Alpha');
      final handoffBravo = await stack.admittedPhone(day, 'recorder', raceArea: 'Bravo');
      final namedAlpha = await stack.admittedNamedPhone(day, 'course_pro', raceArea: 'Alpha');
      final namedBravo =
          await stack.admittedNamedPhone(day, 'course_pro', raceArea: 'Bravo', person: 'Jo Volunteer');
      final phones = [handoffAlpha, handoffBravo, namedAlpha, namedBravo];

      // Each path signs in as the pilot does, and no phone's request carries the secret key.
      expect(stack.phoneRequests, [
        for (final signIn in ['signup', 'signup', 'verify', 'verify']) ...[
          'POST /auth/v1/$signIn publishable',
          'POST /rest/v1/rpc/admit_device publishable+token',
        ],
      ]);
      for (final phone in [handoffAlpha, handoffBravo]) {
        expect(phone.claims['is_anonymous'], true, reason: 'the device-handoff path');
        expect(phone.claims['email'], anyOf(isNull, isEmpty), reason: 'an anonymous sign-in has no address');
      }
      for (final phone in [namedAlpha, namedBravo]) {
        expect(phone.claims['is_anonymous'], false, reason: 'the named-volunteers path');
        expect(phone.claims['email'], phone.email);
        expect(phone.claims['amr'], [containsPair('method', 'otp')], reason: 'signed in by its magic link');
      }

      // Criterion 6: each holds its own admission, with its code's role and race area. Criteria 1
      // and 8: a device-handoff admission is tied to its role and race area and names no person.
      // Criterion 2's server half: a magic-link admission is held by the named account itself.
      expect([
        for (final row in await stack.admissions(day.eventId))
          [row['auth_uid'], row['role'], row['race_area'], row['person'], row['is_anonymous'], row['email']],
      ], [
        [handoffAlpha.userId, 'recorder', 'Alpha', null, true, null],
        [handoffBravo.userId, 'recorder', 'Bravo', null, true, null],
        [namedAlpha.userId, 'course_pro', 'Alpha', null, false, namedAlpha.email],
        [namedBravo.userId, 'course_pro', 'Bravo', 'Jo Volunteer', false, namedBravo.email],
      ]);
      for (final phone in phones) {
        expect(await ownAdmissions(phone), [
          {'id': phone.admissionId},
        ], reason: 'each phone reads its own admission and no other');
      }

      // Criterion 6: all four append at once through append_event, five events each, every one from
      // its own device.
      final devices = {for (final phone in phones) phone: newUlid()};
      final sent = {
        for (final phone in phones)
          phone: [
            for (var seq = 1; seq <= 5; seq++) sampleEvent(newUlid(), deviceId: devices[phone]!, seq: seq),
          ],
      };
      final answers = await Future.wait([
        for (final phone in phones)
          for (final canonical in sent[phone]!) append(phone, day.eventId, canonical),
      ]);
      expect([for (final (code, body) in answers) (code, (body as Map)['outcome'], body['duplicate'])],
          everyElement((200, 'accepted', false)), reason: '$answers');
      expect(await stack.eventLog(day.eventId), unorderedEquals([for (final events in sent.values) ...events]),
          reason: 'every event from every phone, stored exactly as sent');

      // Criterion 7: a replacement presents the recorder on Alpha's code mid-race. It gets an
      // admission of its own, and the original is not revoked: both go on appending.
      final replacement = await stack.admittedPhone(day, 'recorder', raceArea: 'Alpha');
      expect(replacement.admissionId, isNot(handoffAlpha.admissionId));
      final recorders = [
        for (final row in await stack.admissions(day.eventId))
          if (row['role'] == 'recorder' && row['race_area'] == 'Alpha') [row['auth_uid'], row['revoked']],
      ];
      expect(recorders, [
        [handoffAlpha.userId, false],
        [replacement.userId, false],
      ]);
      final replacementEvent = sampleEvent(newUlid(), deviceId: newUlid());
      final originalEvent = sampleEvent(newUlid(), deviceId: devices[handoffAlpha]!, seq: 6);
      for (final (phone, canonical) in [(replacement, replacementEvent), (handoffAlpha, originalEvent)]) {
        final (code, body) = await append(phone, day.eventId, canonical);
        expect(code, 200, reason: '$body');
        expect((body! as Map)['outcome'], 'accepted');
      }
      expect(await stack.eventLog(day.eventId), containsAll([replacementEvent, originalEvent]));
      expect(await stack.refusals(day.eventId), isEmpty);
    });

    test('criterion 3: the owner script switches a club\'s mode; a path it names admits new phones, '
        'a path it excludes is refused, and admitted phones are unaffected', () async {
      final club = 'Sign-in mode test ${DateTime.now().microsecondsSinceEpoch}';
      final day = await stack.raceDay(club: club);

      Future<String> signInMode(String mode) async {
        final out = StringBuffer();
        final code = await owner.run(['sign-in-mode', '--club', club, '--mode', mode],
            out: out, localStatus: () async => status);
        expect(code, 0, reason: '$out');
        return '$out';
      }

      /// admit_device's refusal of an excluded path: 403, carrying the mode and the path.
      Matcher excluded(String mode, String path) => isA<(int, Object?)>()
          .having((a) => a.$1, 'status', 403)
          .having((a) => a.$2, 'body', allOf(
            containsPair('code', '42501'),
            containsPair('message', 'admit_device: the club\'s sign-in mode does not admit this sign-in'),
            containsPair('details', 'sign_in_mode=$mode path=$path'),
          ));

      // A club starts at both: this phone is admitted before any switch.
      final early = await stack.admittedPhone(day, 'scorer');

      expect(await signInMode('named_volunteers'),
          allOf(contains('target      the local stack'), contains('sign-in     named_volunteers (was both)')));
      final anonymous = await stack.phone();
      expect(await stack.tryAdmit(anonymous, day, 'overall_pro'), excluded('named_volunteers', 'device_handoff'));
      final named = await stack.admit(await stack.namedPhone(), day, 'recorder', raceArea: 'Alpha');
      expect(await stack.tryAdmit(early, day, 'scorer'), (200, early.admissionId),
          reason: 'the phone admitted at both gets its own admission back');
      final (earlyCode, earlyBody) = await append(early, day.eventId, sampleEvent(newUlid(), deviceId: newUlid()));
      expect((earlyCode, (earlyBody! as Map)['outcome']), (200, 'accepted'));

      expect(await signInMode('device_handoff'), contains('sign-in     device_handoff (was named_volunteers)'));
      expect((await stack.tryAdmit(anonymous, day, 'overall_pro')).$1, 200,
          reason: 'the phone refused a moment ago is admitted now, with nothing changed on it');
      final volunteer = await stack.namedPhone();
      expect(await stack.tryAdmit(volunteer, day, 'safety'), excluded('device_handoff', 'named_volunteers'));
      final (namedCode, namedBody) = await append(named, day.eventId, sampleEvent(newUlid(), deviceId: newUlid()));
      expect((namedCode, (namedBody! as Map)['outcome']), (200, 'accepted'),
          reason: 'the named volunteer admitted at named_volunteers still appends');

      expect(await signInMode('both'), contains('sign-in     both (was device_handoff)'));
      expect((await stack.tryAdmit(volunteer, day, 'safety')).$1, 200,
          reason: 'at both, the named volunteer refused a moment ago is admitted');
      expect(await signInMode('both'), contains('sign-in     both (unchanged)'));

      final missing = StringBuffer();
      expect(
          await owner.run(['sign-in-mode', '--club', '$club (no such club)', '--mode', 'both'],
              out: missing, localStatus: () async => status),
          1,
          reason: 'a club no one has provisioned is not switched');
    });
  }, skip: localStackRequested ? false : localStackSkip);
}
