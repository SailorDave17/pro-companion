import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import '../scripts/owner.dart' as owner;

/// #63: scripts/owner.dart provision, and since #65 the admission codes it issues. The unit tests
/// run everywhere. The local-stack tests run only with PRO_COMPANION_LOCAL_STACK=1 and the stack
/// started (README, Server side): in CI, that is the local-stack job (#41). Once asked for, a stack
/// that is down fails them rather than skipping them.
void main() {
  group('arguments', () {
    test('provision takes a club, an event, a date and one or more race areas', () {
      final args = owner.parseProvision([
        '--club', 'Hoover Sailing Club', '--event', 'Club night', '--date', '2026-09-27',
        '--race-area', 'Alpha', '--race-area', 'Bravo',
      ]);
      expect(args.club, 'Hoover Sailing Club');
      expect(args.event, 'Club night');
      expect(args.date, '2026-09-27');
      expect(args.raceAreas, ['Alpha', 'Bravo']);
      expect(args.project, isNull);
    });

    test('refuses before any write what the server would refuse after the event exists', () {
      final base = ['--club', 'C', '--event', 'E', '--date', '2026-09-27'];
      final refused = {
        'no race area': base,
        'a date that is not on the calendar': ['--club', 'C', '--event', 'E', '--date', '2026-02-30', '--race-area', 'A'],
        'a race area named twice': [...base, '--race-area', 'A', '--race-area', 'A'],
        'an unknown flag': [...base, '--race-area', 'A', '--fleet', 'Lasers'],
        'a flag with no value': [...base, '--race-area'],
        'a project that is not a ref': [...base, '--race-area', 'A', '--project', 'Hoover'],
      };
      refused.forEach((reason, args) {
        expect(() => owner.parseProvision(args), throwsA(isA<owner.UsageError>()), reason: reason);
      });
    });

    test('#5: sign-in-mode takes a club and one of the three modes G39 names', () {
      final args = owner.parseSignInMode(['--club', 'Hoover Sailing Club', '--mode', 'named_volunteers']);
      expect(args.club, 'Hoover Sailing Club');
      expect(args.mode, 'named_volunteers');
      expect(args.project, isNull);
      for (final mode in ['device_handoff', 'named_volunteers', 'both']) {
        expect(owner.parseSignInMode(['--club', 'C', '--mode', mode]).mode, mode);
      }
    });

    test('#5: sign-in-mode refuses before any call what the server would refuse', () {
      final refused = {
        'no mode': ['--club', 'C'],
        'no club': ['--mode', 'both'],
        'a mode that is not one of the three': ['--club', 'C', '--mode', 'anyone'],
        'a mode spelled with hyphens': ['--club', 'C', '--mode', 'named-volunteers'],
        'an unknown flag': ['--club', 'C', '--mode', 'both', '--event', 'E'],
        'a flag with no value': ['--club', 'C', '--mode'],
        'a project that is not a ref': ['--club', 'C', '--mode', 'both', '--project', 'Hoover'],
      };
      refused.forEach((reason, args) {
        expect(() => owner.parseSignInMode(args), throwsA(isA<owner.UsageError>()), reason: reason);
      });
    });

    test('a missing or unknown subcommand is a usage error, exit 64, and nothing is called', () async {
      var asked = 0;
      Future<Map<String, String>> status() async {
        asked++;
        return const {};
      }

      expect(await owner.run([], localStatus: status), 64);
      expect(await owner.run(['nonsense', '--club', 'C'], localStatus: status), 64);
      expect(await owner.run(['sign-in-mode', '--club', 'C', '--mode', 'anyone'], localStatus: status), 64);
      expect(asked, 0, reason: 'a usage error never reaches a target');
    });
  });

  group('target (criterion 2)', () {
    const localStatus = {'API_URL': 'http://127.0.0.1:54421', 'SECRET_KEY': 'the-local-key'};

    test('with no --project it is the local stack, even with a live key in the shell and the file',
        () async {
      var asked = 0;
      final target = await owner.resolveTarget(null,
          environment: {'SUPABASE_SECRET_KEY': 'a-live-key', 'SUPABASE_URL': 'https://pxywvqhdywgrysmwvbxy.supabase.co'},
          envFile: {'SUPABASE_SECRET_KEY': 'another-live-key'},
          localStatus: () async {
            asked++;
            return localStatus;
          });
      expect(asked, 1);
      expect(target.apiUrl, Uri.parse('http://127.0.0.1:54421'));
      expect(target.secretKey, 'the-local-key');
    });

    test('--project reaches that project, with its key, and never asks the local stack', () async {
      var asked = 0;
      Future<Map<String, String>> status() async {
        asked++;
        return localStatus;
      }

      final fromShell = await owner.resolveTarget('pxywvqhdywgrysmwvbxy',
          environment: {'SUPABASE_SECRET_KEY': 'the-shell-key'},
          envFile: {'SUPABASE_SECRET_KEY': 'the-file-key'},
          localStatus: status);
      expect(fromShell.apiUrl, Uri.https('pxywvqhdywgrysmwvbxy.supabase.co'));
      expect(fromShell.secretKey, 'the-shell-key');

      final fromFile = await owner.resolveTarget('pxywvqhdywgrysmwvbxy',
          environment: const {}, envFile: {'SUPABASE_SECRET_KEY': 'the-file-key'}, localStatus: status);
      expect(fromFile.secretKey, 'the-file-key');
      expect(asked, 0);
    });

    test('a live run with no key names what it looked for and never a value', () async {
      await expectLater(
          owner.resolveTarget('pxywvqhdywgrysmwvbxy',
              environment: const {},
              envFile: {'SUPPABASE_TOKEN': 'a-value-that-must-not-be-printed'},
              localStatus: () async => localStatus),
          throwsA(isA<StateError>()
              .having((e) => e.message, 'message', contains('SUPABASE_SECRET_KEY'))
              .having((e) => e.message, 'message', contains('SUPPABASE_TOKEN'))
              .having((e) => e.message, 'message', isNot(contains('a-value-that-must-not-be-printed')))));
    });
  });

  group('admission code', () {
    test('two groups of four from Crockford base32, which has no I, L, O or U', () {
      final codes = [for (var i = 0; i < 500; i++) owner.newAdmissionCode()];
      for (final code in codes) {
        expect(code, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$')));
      }
      expect(codes.toSet().length, codes.length, reason: 'a fresh code each time');
      expect(owner.newAdmissionCode(Random(7)), owner.newAdmissionCode(Random(7)),
          reason: 'the code comes from the random source it is given');
    });

    test('#65: one code per event-wide role, then one per race area for each bound role', () {
      expect(owner.codeSlots(['Alpha', 'Bravo']), [
        (role: 'overall_pro', raceArea: null),
        (role: 'scorer', raceArea: null),
        (role: 'safety', raceArea: null),
        (role: 'course_pro', raceArea: 'Alpha'),
        (role: 'recorder', raceArea: 'Alpha'),
        (role: 'mark_boat', raceArea: 'Alpha'),
        (role: 'course_pro', raceArea: 'Bravo'),
        (role: 'recorder', raceArea: 'Bravo'),
        (role: 'mark_boat', raceArea: 'Bravo'),
      ]);
      expect(owner.codeSlots(['Alpha']), hasLength(6));
    });
  });

  final localStack = Platform.environment['PRO_COMPANION_LOCAL_STACK'] == '1';

  group('against the local stack (criteria 1, 3 and 4)', () {
    late Map<String, String> status;
    late Uri api;
    late String firstRun;
    late String secondRun;
    late String treeBefore;
    late String treeAfter;
    final club = 'Owner script test ${DateTime.now().microsecondsSinceEpoch}';

    Future<String> gitStatus() async =>
        (await Process.run('git', ['status', '--porcelain'])).stdout as String;

    Future<String> provision(String event) async {
      final out = StringBuffer();
      final code = await owner.run(
        ['provision', '--club', club, '--event', event, '--date', '2026-09-27',
          '--race-area', 'Alpha', '--race-area', 'Bravo'],
        out: out,
        localStatus: () async => status,
      );
      expect(code, 0, reason: out.toString());
      return out.toString();
    }

    String field(String output, String label) {
      final match = RegExp('^${RegExp.escape(label)} +(\\S+)', multiLine: true).firstMatch(output);
      expect(match, isNotNull, reason: 'no "$label" line in:\n$output');
      return match!.group(1)!;
    }

    /// Every printed code line, keyed by its role and race area: `overall_pro`, `recorder Alpha`.
    Map<String, String> codes(String output) => {
          for (final m in RegExp(r'^code +(\S+)  (\S+)(?:  (.+))?$', multiLine: true).allMatches(output))
            [m.group(2), m.group(3)].whereType<String>().join(' '): m.group(1)!,
        };

    /// The race area id printed for [name].
    String raceAreaId(String output, String name) =>
        RegExp('^race area +(\\S+)  ${RegExp.escape(name)}\$', multiLine: true).firstMatch(output)!.group(1)!;

    Future<(int, Object?)> call(String method, Uri uri, Map<String, String> headers,
        [Object? body]) async {
      final client = HttpClient();
      try {
        final request = await client.openUrl(method, uri);
        headers.forEach(request.headers.set);
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.add(utf8.encode(jsonEncode(body)));
        }
        final response = await request.close();
        final text = await response.transform(utf8.decoder).join();
        return (response.statusCode, text.isEmpty ? null : jsonDecode(text));
      } finally {
        client.close();
      }
    }

    /// A phone signing in the way the device-handoff path does: anonymously.
    Future<String> anonymousPhone() async {
      final (statusCode, body) = await call('POST', api.replace(path: '/auth/v1/signup'),
          {'apikey': status['PUBLISHABLE_KEY']!}, <String, Object?>{});
      expect(statusCode, 200, reason: '$body');
      return (body as Map)['access_token'] as String;
    }

    Map<String, String> asPhone(String token) =>
        {'apikey': status['PUBLISHABLE_KEY']!, 'Authorization': 'Bearer $token'};

    setUpAll(() async {
      status = await owner.readLocalStatus();
      api = Uri.parse(status['API_URL']!);
      treeBefore = await gitStatus();
      firstRun = await provision('Club night');
      secondRun = await provision('Second day');
      treeAfter = await gitStatus();
    });

    test('provision prints the club it made, the event and each race area', () {
      expect(firstRun, contains('target      the local stack'));
      expect(firstRun, matches(RegExp(r'^club +\S+  .+ \(provisioned\)$', multiLine: true)));
      expect(RegExp(r'^race area +\S+  (\S+)$', multiLine: true)
          .allMatches(firstRun)
          .map((m) => m.group(1))
          .toList(), ['Alpha', 'Bravo']);
    });

    test('#65: it prints one code per event-wide role and one per race area for each bound role', () {
      final printed = codes(firstRun);
      expect(printed.keys, [
        'overall_pro', 'scorer', 'safety',
        'course_pro Alpha', 'recorder Alpha', 'mark_boat Alpha',
        'course_pro Bravo', 'recorder Bravo', 'mark_boat Bravo',
      ]);
      for (final code in printed.values) {
        expect(code, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$')));
      }
      expect(printed.values.toSet(), hasLength(9), reason: 'no code is printed for two roles');
    });

    test('a second run for the same club reuses it instead of provisioning another', () {
      expect(secondRun, matches(RegExp(r'^club +\S+  .+ \(reused\)$', multiLine: true)));
      expect(field(secondRun, 'club'), field(firstRun, 'club'));
      expect(field(secondRun, 'event'), isNot(field(firstRun, 'event')));
    });

    /// Admits a new anonymous phone with [code] and returns its token and its own admission row.
    Future<(String, Map)> admit(String code) async {
      final phone = await anonymousPhone();
      final (statusCode, body) = await call('POST', api.replace(path: '/rest/v1/rpc/admit_device'),
          asPhone(phone), {'p_event': field(firstRun, 'event'), 'p_admission_code': code});
      expect(statusCode, 200, reason: '$body');
      expect(body, matches(RegExp(r'^[0-9a-f-]{36}$')), reason: 'the new admission id');
      final (readStatus, rows) = await call(
          'GET',
          api.replace(path: '/rest/v1/committee_device', queryParameters: {'select': 'role,course_id'}),
          asPhone(phone));
      expect(readStatus, 200, reason: '$rows');
      return (phone, (rows as List).single as Map);
    }

    test('#65: a phone presenting a printed code is admitted as its role, on its race area', () async {
      // Three phones, not nine: the stack allows 30 anonymous sign-ins an hour, and
      // admission_code_test.sql admits one phone per code. Two recorders on two race areas, so a
      // race area read off the role alone fails.
      final printed = codes(firstRun);
      final (_, pro) = await admit(printed['overall_pro']!);
      expect(pro, {'role': 'overall_pro', 'course_id': null});
      final (phone, alpha) = await admit(printed['recorder Alpha']!);
      expect(alpha, {'role': 'recorder', 'course_id': raceAreaId(firstRun, 'Alpha')});
      final (_, bravo) = await admit(printed['recorder Bravo']!);
      expect(bravo, {'role': 'recorder', 'course_id': raceAreaId(firstRun, 'Bravo')});

      final (readStatus, courses) = await call(
          'GET',
          api.replace(path: '/rest/v1/course', queryParameters: {
            'select': 'name',
            'event_id': 'eq.${field(firstRun, 'event')}',
            'order': 'name',
          }),
          asPhone(phone));
      expect(readStatus, 200, reason: '$courses');
      expect([for (final row in courses as List) (row as Map)['name']], ['Alpha', 'Bravo'],
          reason: 'the admitted phone reads the race areas the script made on its event');
    });

    test('a code the script printed for another event does not admit', () async {
      final phone = await anonymousPhone();
      final (statusCode, body) = await call('POST', api.replace(path: '/rest/v1/rpc/admit_device'),
          asPhone(phone), {
        'p_event': field(firstRun, 'event'),
        'p_admission_code': codes(secondRun)['overall_pro'],
      });
      expect(statusCode, isNot(200));
      expect((body as Map)['code'], '28000', reason: '$body');
    });

    test('the runs wrote nothing into the tree, the code included', () {
      expect(treeAfter, treeBefore);
      expect(Process.runSync('git', ['check-ignore', '-q', '.env.local']).exitCode, 0,
          reason: '.env.local stays git-ignored');
    });
  }, skip: localStack ? false : 'set PRO_COMPANION_LOCAL_STACK=1 with the local stack running');
}
