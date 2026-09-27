import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_sync/sync.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #6 criterion 14 and ADR 006 decision 3: the session is kept in one file, rewritten on every
/// change; it is never lost to an answer GoTrue did not give; and sync never signs anyone in on
/// its own. The local-stack tests hold the same against the real GoTrue.
void main() {
  const alice = '00000000-0000-4000-8000-00000000a11c';

  Map<String, Object?> fileOf(TestPhone phone) => jsonDecode(phone.sessionFile.readAsStringSync()) as Map<String, Object?>;

  test('a sign-in is kept in the file, and every rotation of the refresh token reaches it', () async {
    final server = FakeServer();
    final phone = TestPhone();
    final engine = phone.engine(server);
    addTearDown(engine.close);

    final user = await engine.signInAnonymously();
    final first = fileOf(phone)['refresh_token'];
    expect((fileOf(phone)['user'] as Map)['id'], user);

    await engine.clientForTests.auth.refreshSession();
    // gotrue announces a refresh a turn after it returns, as it does for the ticker's own.
    await Future<void>.delayed(Duration.zero);
    final second = fileOf(phone)['refresh_token'];
    expect(second, isNot(first));
    expect(second, engine.clientForTests.auth.currentSession?.refreshToken,
        reason: 'the file holds the token in use, never one a rotation behind');
  });

  test("GoTrue's own rejection of the kept session signs the phone out and removes the file", () async {
    final server = FakeServer();
    final phone = TestPhone(admission: server.admitDirectly(alice, dayOne));
    phone.keepSession(server.session(alice, validFor: const Duration(minutes: -2)));
    server.revokeRefreshTokens(alice);
    phone.log(1);
    final engine = phone.engine(server);
    addTearDown(engine.close);

    final run = await engine.syncOnce();
    expect(run.state, UploadRunState.noSession);
    expect(phone.sessionFile.existsSync(), isFalse);
    expect(server.requests.where((r) => r.path == '/auth/v1/signup'), isEmpty, reason: 'nobody signed in on its own');
    expect(phone.store.uploadStatus().refused, isEmpty, reason: 'the events wait');
  });

  // Answers on the token endpoint that GoTrue never gives. Without the guard, gotrue signs the
  // phone out over each: on the device-handoff path, a new user who must be admitted again.
  final notGoTrue = <String, http.Response Function()>{
    "a captive portal's redirect": () => http.Response('<html>login</html>', 302, headers: {'location': '/login'}),
    "a firewall's 403 page": () => http.Response('<html>Forbidden</html>', 403),
    'a 401 with no body': () => http.Response('', 401),
    'a rate limit': () => http.Response(jsonEncode({'code': 429, 'error_code': 'over_request_rate_limit'}), 429,
        headers: {'content-type': 'application/json'}),
    "a gateway's own 401": () => http.Response(jsonEncode({'message': 'Invalid API key'}), 401,
        headers: {'content-type': 'application/json'}),
    'a 200 with no session in it': () => http.Response('{}', 200, headers: {'content-type': 'application/json'}),
    // A control: gotrue already retries a 2xx it cannot parse, so this passes without the guard.
    "(control) a captive portal's 200 page": () => http.Response('<html>Sign in to Club Wi-Fi</html>', 200),
  };
  for (final MapEntry(key: what, value: bad) in notGoTrue.entries) {
    test('$what on the token endpoint keeps the session', () async {
      final server = FakeServer();
      final phone = TestPhone(admission: server.admitDirectly(alice, dayOne));
      phone.keepSession(server.session(alice, validFor: const Duration(minutes: -2)));
      phone.log(1);
      var first = true;
      server.hooks.add((r) {
        if (r.path != '/auth/v1/token' || !first) return null;
        first = false;
        return bad();
      });
      final engine = phone.engine(server);
      addTearDown(engine.close);

      final run = await engine.syncOnce();
      expect(run.state, UploadRunState.done, reason: '$run');
      expect(engine.userId, alice, reason: 'the same user, recovered on the retry');
      expect(phone.sessionFile.existsSync(), isTrue);
      expect(server.requests.where((r) => r.path == '/auth/v1/token').length, 2);
      expect(server.requests.where((r) => r.path == '/auth/v1/signup'), isEmpty);
    });
  }

  for (final (what, bytes) in [
    ('cut off mid-write', utf8.encode('{"access_token": "trunc')),
    ('not text at all', [0xff, 0xfe, 0x7b, 0x22]),
  ]) {
    test('a kept session $what is set aside, so the phone can sign in again', () async {
      final server = FakeServer();
      final phone = TestPhone(admission: server.admitDirectly(alice, dayOne));
      phone.sessionFile.writeAsBytesSync(bytes);
      phone.log(1);
      final engine = phone.engine(server);
      addTearDown(engine.close);

      final run = await engine.syncOnce();
      expect(run.state, UploadRunState.sessionUnreadable);
      expect(phone.store.uploadStatus().lastRun?.state, UploadRunState.sessionUnreadable);
      expect(phone.sessionFile.existsSync(), isFalse);
      expect(File('${phone.dir}${Platform.pathSeparator}sync_session.unreadable.json').existsSync(), isTrue);
      expect(await engine.signInAnonymously(), isNotEmpty);
    });
  }

  group('sync never mints a user over a session it holds', () {
    test('an anonymous sign-in is refused while a session is held', () async {
      final server = FakeServer();
      final phone = TestPhone();
      phone.keepSession(server.session(alice));
      final engine = phone.engine(server);
      addTearDown(engine.close);
      await expectLater(engine.signInAnonymously(), throwsStateError);
      expect(server.requests.where((r) => r.path == '/auth/v1/signup'), isEmpty);
    });

    test('and while a kept session cannot be checked for want of signal', () async {
      final server = FakeServer()..offline = true;
      final phone = TestPhone();
      phone.keepSession(server.session(alice, validFor: const Duration(minutes: -2)));
      final engine = phone.engine(server);
      addTearDown(engine.close);
      await expectLater(engine.signInAnonymously(), throwsStateError);
      expect(server.requests.where((r) => r.path == '/auth/v1/signup'), isEmpty);
      expect(phone.sessionFile.existsSync(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  test('a sign-in the server refuses for its rate limit says so', () async {
    final server = FakeServer();
    server.hooks.add((r) => r.path == '/auth/v1/signup'
        ? http.Response(jsonEncode({'code': 'over_request_rate_limit', 'message': 'Request rate limit reached'}), 429,
            headers: {'content-type': 'application/json', 'x-supabase-api-version': '2024-01-01'})
        : null);
    final phone = TestPhone();
    final engine = phone.engine(server);
    addTearDown(engine.close);
    await expectLater(engine.signInAnonymously(),
        throwsA(isA<SignInRateLimited>().having((e) => e.message, 'message', contains('RATE LIMITED'))));
  });

  group('the key: the publishable one, and nothing else (criteria 5 and 13)', () {
    final serviceRole = jwt({'role': 'service_role', 'iss': 'supabase', 'ref': 'x'});
    final anon = jwt({'role': 'anon', 'iss': 'supabase', 'ref': 'x'});
    final refused = {
      'a secret key': 'sb_secret_${'k' * 20}',
      'a secret key behind a space': ' sb_secret_${'k' * 20}',
      'a publishable key behind a space': ' $publishableKey',
      'a publishable key with a space after it': '$publishableKey ',
      'a service_role JWT': serviceRole,
      'an unknown sb_ key': 'sb_other_${'k' * 20}',
      'a malformed JWT': 'a.b.c',
      'nothing': '',
    };
    for (final MapEntry(key: what, value: key) in refused.entries) {
      test('refuses $what before any request, without echoing it', () {
        final server = FakeServer();
        final phone = TestPhone();
        expect(
          () => SyncEngine.open(
              url: projectUrl, publishableKey: key, store: phone.store, sessionDir: phone.dir, transport: server),
          throwsA(isA<ArgumentError>().having((e) => '$e', 'message', allOf(contains('publishable'), isNot(contains(key.isEmpty ? '\u0000' : key.trim()))))),
        );
        expect(server.requests, isEmpty);
      });
    }

    test('takes a publishable key and a legacy anon JWT', () {
      expect(() => requirePublishableKey(publishableKey), returnsNormally);
      expect(() => requirePublishableKey(anon), returnsNormally);
    });

    test('every request carries the publishable key, and a bearer that is the user\'s own', () async {
      final server = FakeServer();
      final (phone, engine, _) = await admittedPhone(server, alice, dayOne);
      phone.log(2);
      await engine.syncOnce();
      expect(server.requests, isNotEmpty);
      for (final r in server.requests) {
        expect(r.apikey, publishableKey, reason: '$r');
        expect(r.bearer == publishableKey || claimsOf(r.bearer!)['role'] == 'authenticated', isTrue, reason: '$r');
      }
    });
  });

  test('the store is untouched by a sign-in: admit records the race day and leaves the stamp alone', () async {
    final server = FakeServer();
    final phone = TestPhone();
    final engine = phone.engine(server);
    addTearDown(engine.close);
    await engine.signInWithMagicLink(server.magicLinkFor(alice));
    final admission = await engine.admit(dayOne, 'CODE-1');
    expect(phone.store.admissionEvent(admission), dayOne);
    expect(phone.store.admissionId, isNull, reason: 'the caller stamps it (#71 logs its marker first)');
    phone.store.setAdmissionId(admission);
    phone.store.append(const NewEvent(kind: 'note', source: 'tap'));
    expect((await engine.syncOnce()).accepted, 1);
  });

  test('a kept file gone bad under a live session is written again, and the run goes on', () async {
    final server = FakeServer();
    final phone = TestPhone();
    final engine = phone.engine(server);
    addTearDown(engine.close);
    await engine.signInWithMagicLink(server.magicLinkFor(alice));
    phone.store.setAdmissionId(await engine.admit(dayOne, 'CODE-1'));
    phone.log(1);
    phone.sessionFile.writeAsBytesSync([0xff, 0xfe, 0x7b, 0x22]);

    final run = await engine.syncOnce();
    expect(run.accepted, 1);
    final kept = jsonDecode(phone.sessionFile.readAsStringSync()) as Map;
    expect(kept['refresh_token'], isA<String>(), reason: 'the session in memory is on disk again');
  });

  test('a race day the store could not keep is refused before the server admits anyone', () async {
    final server = FakeServer();
    final phone = TestPhone();
    final engine = phone.engine(server);
    addTearDown(engine.close);
    await engine.signInWithMagicLink(server.magicLinkFor(alice));
    await expectLater(engine.admit(dayOne.toUpperCase(), 'CODE-1'), throwsArgumentError);
    expect(server.requests.where((r) => r.path.endsWith('/rpc/admit_device')), isEmpty,
        reason: 'an admission made first would be lost when the store refused its race day');
    expect(server.admissions[alice], isNull);
  });
}
