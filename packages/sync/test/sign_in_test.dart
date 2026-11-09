import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:http/http.dart' as http;
import 'package:pro_companion_core/host.dart' show CoreServer, PortCoreClient, SignInHandlers;
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_sync/sync.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #104: a named volunteer's magic-link sign-in, the sign-in screen's two calls, against the real
/// client over the scripted server. The phone asks for a link to the volunteer's address with the
/// app's own redirect, the client's PKCE flow keeps the code verifier in a file beside the
/// session, and the link's one-time code is exchanged for the volunteer's own session, whose token
/// is not anonymous. Every failure comes back as a CoreException coded from SignInCodes.
void main() {
  const email = 'volunteer@example.com';
  const alpha = '00000000-0000-4000-8000-0000000000ca';

  FakeServer server() => FakeServer()
    ..issueCode('RECO-ALFA', event: dayOne, role: 'recorder', course: alpha)
    ..courses[alpha] = 'Alpha';

  (TestPhone, SyncEngine) fresh(FakeServer s, [TestPhone? on]) {
    final phone = on ?? TestPhone();
    final engine = phone.engine(s);
    addTearDown(engine.close);
    return (phone, engine);
  }

  File pkceFile(TestPhone phone) => File('${phone.dir}${Platform.pathSeparator}sync_pkce.json');
  Map<String, Object?> claims(String token) =>
      jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1])))) as Map<String, Object?>;
  Map<String, Object?> keptSession(TestPhone phone) =>
      jsonDecode(phone.sessionFile.readAsStringSync()) as Map<String, Object?>;
  Matcher coded(String code, [Object? message]) => throwsA(isA<CoreException>()
      .having((e) => e.code, 'code', code)
      .having((e) => e.message, 'message', message ?? anything));
  Iterable<Seen> exchanges(FakeServer s) =>
      s.requests.where((r) => r.path == '/auth/v1/token' && r.query['grant_type'] == 'pkce');
  http.Response goTrue(int status, String code) => http.Response(jsonEncode({'code': code, 'message': code}), status,
      headers: {'content-type': 'application/json', 'x-supabase-api-version': '2024-01-01'});

  group('criteria 1 and 2: a link is asked for, and opening it signs the phone in as the volunteer', () {
    test('the request names the address, the app redirect and a PKCE challenge, and signs nobody in', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.requestMagicLink(email);
      final otp = s.requests.singleWhere((r) => r.path == '/auth/v1/otp');
      expect(otp.json['email'], email);
      expect(otp.query['redirect_to'], signInRedirect, reason: 'back to this app, not the Site URL');
      expect(otp.json['code_challenge'], isA<String>().having((c) => c.length, 'length', greaterThanOrEqualTo(43)));
      expect(otp.json['code_challenge_method'], 's256');
      expect(s.requests.where((r) => r.path == '/auth/v1/signup'), isEmpty, reason: 'no anonymous user is made');
      expect(phone.sessionFile.existsSync(), isFalse, reason: 'nothing is signed in until the link opens');
      expect(pkceFile(phone).existsSync(), isTrue, reason: 'the verifier is on disk, not only in memory');
    });

    test("opening the link exchanges its code for the volunteer's session, kept before it answers", () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.requestMagicLink(email);
      final code = s.newestLinkCode[email]!;
      expect(await engine.completeMagicLink(code), email);
      final exchange = exchanges(s).single;
      expect(exchange.json['auth_code'], code);
      expect(engine.userId, s.namedUsers[email]);
      final kept = keptSession(phone);
      expect(claims(kept['access_token'] as String)['is_anonymous'], isFalse, reason: 'the named path, not device handoff');
      expect(claims(kept['access_token'] as String)['sub'], s.namedUsers[email]);
      expect(pkceFile(phone).existsSync(), isFalse, reason: 'the verifier is spent by the exchange');
    });

    test('the verifier outlives the engine: a host restarted between the request and the link still signs in', () async {
      final s = server();
      final phone = TestPhone();
      final before = phone.engine(s);
      await before.requestMagicLink(email);
      await before.close();
      final (_, after) = fresh(s, phone);
      expect(await after.completeMagicLink(s.newestLinkCode[email]!), email);
      expect(after.userId, s.namedUsers[email]);
    });

    test('a link opened on another phone is refused there, and nothing is sent', () async {
      final s = server();
      final (_, asking) = fresh(s);
      await asking.requestMagicLink(email);
      final (other, opening) = fresh(s);
      await expectLater(opening.completeMagicLink(s.newestLinkCode[email]!),
          coded(SignInCodes.refused, 'Open the newest link on the phone that asked for it.'));
      expect(exchanges(s), isEmpty, reason: 'refused by the client before any request');
      expect(other.sessionFile.existsSync(), isFalse);
    });

    test('a second request replaces the first: only the newest link signs in', () async {
      final s = server();
      final (_, engine) = fresh(s);
      await engine.requestMagicLink(email);
      final first = s.newestLinkCode[email]!;
      await engine.requestMagicLink(email);
      final newest = s.newestLinkCode[email]!;
      expect(newest, isNot(first));
      await expectLater(engine.completeMagicLink(first),
          coded(SignInCodes.refused, 'That link has expired or was used already. Ask for a new one.'));
      expect(await engine.completeMagicLink(newest), email);
    });

    test('a link the server no longer holds (expired or used) is refused in plain words', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.requestMagicLink(email);
      s.pkceFlows.clear();
      await expectLater(engine.completeMagicLink(s.newestLinkCode[email]!),
          coded(SignInCodes.refused, 'That link has expired or was used already. Ask for a new one.'));
      expect(phone.sessionFile.existsSync(), isFalse);
    });
  });

  group('refused over a session the phone holds', () {
    test('a phone already signed in by device handoff neither asks for a link nor opens one', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.join('RECO-ALFA');
      await expectLater(engine.requestMagicLink(email), coded(SignInCodes.signedIn, 'This phone is already signed in.'));
      await expectLater(engine.completeMagicLink('4d3e9f0a-1b2c-4d5e-8f60-000000000001'), coded(SignInCodes.signedIn));
      expect(s.requests.where((r) => r.path == '/auth/v1/otp'), isEmpty);
      expect(exchanges(s), isEmpty);
      expect(phone.store.admissionId, isNotNull, reason: 'the admission it holds is untouched');
    });

    test('and an admitted session it cannot check without signal counts as held', () async {
      final s = server()..offline = true;
      final user = uuid(0x5001);
      final phone = TestPhone(admission: s.admitDirectly(user, dayOne));
      phone.keepSession(s.session(user, validFor: const Duration(minutes: -2)));
      final (_, engine) = fresh(s, phone);
      await expectLater(engine.requestMagicLink(email), coded(SignInCodes.signedIn));
      expect(phone.sessionFile.existsSync(), isTrue);
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  // #104's review (owner decision 2026-11-09): a kept session that holds no admission strands
  // nothing, so a sign-in replaces it, in both directions, and an admitted session keeps the rule.
  group('a kept session with no admission never blocks the path the club admits', () {
    http.Response modeRefusal(String mode, String path) => http.Response(
        jsonEncode({'code': '42501', 'details': 'sign_in_mode=$mode path=$path', 'hint': null, 'message': 'x'}), 403,
        headers: {'content-type': 'application/json'});

    test('in a named_volunteers club: a refused JOIN WITH CODE is followed by email sign-in, and then the join admits the account',
        () async {
      final s = server();
      final (phone, engine) = fresh(s);
      s.hooks.add((r) => r.path.endsWith('/rpc/admit_device') ? modeRefusal('named_volunteers', 'device_handoff') : null);
      await expectLater(engine.join('RECO-ALFA'),
          coded(JoinCodes.refused, "This club signs phones in by each volunteer's own email. Sign in by email first."));
      expect(phone.sessionFile.existsSync(), isFalse, reason: 'the anonymous session the refusal left is dropped');
      s.hooks.clear();
      await engine.requestMagicLink(email);
      expect(await engine.completeMagicLink(s.newestLinkCode[email]!), email);
      final granted = await engine.join('RECO-ALFA');
      final admit = s.requests.lastWhere((r) => r.path == '/rest/v1/rpc/admit_device');
      expect(admit.caller, s.namedUsers[email]);
      expect(phone.store.admissionId, granted.admissionId);
    });

    test('a kept session with no admission, whatever left it, is replaced by the link, never refused', () async {
      // Here the app was killed between the anonymous sign-in and admit_device, so no join ran to
      // drop the session: the link request does it.
      final s = server();
      final phone = TestPhone();
      final stray = uuid(0x5002);
      s.anonymous[stray] = true;
      phone.keepSession(s.session(stray));
      final (_, engine) = fresh(s, phone);
      await engine.requestMagicLink(email);
      expect(await engine.completeMagicLink(s.newestLinkCode[email]!), email);
      expect(engine.userId, s.namedUsers[email], reason: 'the stray anonymous user is gone from the phone');
    });

    test("the link's verifier survives the drop: asked for first, then a refused join, then opened", () async {
      final s = server();
      final (_, engine) = fresh(s);
      await engine.requestMagicLink(email);
      s.hooks.add((r) => r.path.endsWith('/rpc/admit_device') ? modeRefusal('named_volunteers', 'device_handoff') : null);
      await expectLater(engine.join('RECO-ALFA'), coded(JoinCodes.refused));
      expect(await engine.completeMagicLink(s.newestLinkCode[email]!), email, reason: 'the verifier was put back after the sign-out');
    });

    test('in a device_handoff club: a refused named phone is told to enter the code again, and then joins by device handoff',
        () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.requestMagicLink(email);
      await engine.completeMagicLink(s.newestLinkCode[email]!);
      s.hooks.add((r) => r.path.endsWith('/rpc/admit_device') ? modeRefusal('device_handoff', 'named_volunteers') : null);
      await expectLater(
          engine.join('RECO-ALFA'),
          coded(JoinCodes.refused,
              "This club signs phones in by device handoff, not by a volunteer's email. Enter the code again to join by device handoff."));
      expect(phone.sessionFile.existsSync(), isFalse);
      s.hooks.clear();
      await engine.join('RECO-ALFA');
      final admit = s.requests.lastWhere((r) => r.path == '/rest/v1/rpc/admit_device');
      expect(s.anonymous[admit.caller], isTrue, reason: 'the second try signed in by device handoff');
    });

    test("an admitted phone's mode refusal keeps its session, names no next step, and a link is still refused", () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.join('RECO-ALFA');
      final kept = phone.sessionFile.readAsStringSync();
      s.hooks.add((r) => r.path.endsWith('/rpc/admit_device') ? modeRefusal('named_volunteers', 'device_handoff') : null);
      // The same slot's code again: the lookup answers, and admit_device refuses on the mode.
      await expectLater(engine.join('RECO-ALFA'), coded(JoinCodes.refused, "This club signs phones in by each volunteer's own email."));
      expect(phone.sessionFile.readAsStringSync(), kept);
      await expectLater(engine.requestMagicLink(email), coded(SignInCodes.signedIn));
    });
  });

  group('what the screen is told when no sign-in can be made', () {
    test('no signal, on either call, is no_signal', () async {
      final s = server();
      final (_, engine) = fresh(s);
      s.offline = true;
      await expectLater(engine.requestMagicLink(email), coded(SignInCodes.noSignal));
      s.offline = false;
      await engine.requestMagicLink(email);
      s.offline = true;
      await expectLater(engine.completeMagicLink(s.newestLinkCode[email]!), coded(SignInCodes.noSignal));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test("the server's mail rate limit says to wait, and an address it will not mail is refused", () async {
      final s = server();
      final (_, engine) = fresh(s);
      s.hooks.add((r) => r.path == '/auth/v1/otp' ? goTrue(429, 'over_email_send_rate_limit') : null);
      await expectLater(engine.requestMagicLink(email),
          coded(SignInCodes.failed, 'The server is limiting sign-in emails. Try again in a few minutes.'));
      s.hooks
        ..clear()
        ..add((r) => r.path == '/auth/v1/otp' ? goTrue(400, 'validation_failed') : null);
      await expectLater(engine.requestMagicLink('not an address'), coded(SignInCodes.refused, 'That email address cannot be used.'));
      s.hooks
        ..clear()
        ..add((r) => r.path == '/auth/v1/otp' ? goTrue(422, 'otp_disabled') : null);
      await expectLater(
          engine.requestMagicLink(email), coded(SignInCodes.refused, 'The server would not send a link to that address.'));
    });

    test('an empty address or code is refused before anything is sent', () async {
      final s = server();
      final (_, engine) = fresh(s);
      // The sentences, not only the code: without its own guard, an empty code reaches gotrue,
      // whose missing verifier maps to the same code and also sends nothing (#104's review).
      await expectLater(engine.requestMagicLink(''), coded(SignInCodes.refused, 'Enter an email address.'));
      await expectLater(engine.completeMagicLink(''), coded(SignInCodes.refused, 'The link carried no sign-in code.'));
      expect(s.requests, isEmpty);
    });

    test('a server that answered 5xx is a failure with its own sentence, never no signal', () async {
      // Measured on the local stack: with no mail server, a magic-link request answers 500.
      final s = server();
      final (_, engine) = fresh(s);
      s.hooks.add((r) => r.path == '/auth/v1/otp' ? goTrue(500, 'unexpected_failure') : null);
      await expectLater(
          engine.requestMagicLink(email), coded(SignInCodes.failed, 'The server could not send the link. Try again later.'));
    });

    test('no message carries a token, a code or a verifier', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.requestMagicLink(email);
      final code = s.newestLinkCode[email]!;
      final verifier = pkceFile(phone).readAsStringSync();
      // The transport's guard reads a token-endpoint 500 GoTrue would not send as no answer, as
      // it does a captive portal's page, so this comes back as no signal. Whatever its code, its
      // message must carry no secret.
      s.hooks.add((r) => exchanges(s).isNotEmpty ? goTrue(500, 'unexpected_failure') : null);
      final e = await engine.completeMagicLink(code).then<Object?>((_) => null, onError: (Object e) => e);
      expect(e, isA<CoreException>());
      final error = e as CoreException;
      expect(SignInCodes.all, contains(error.code));
      final message = error.message;
      expect(message, isNot(contains(code)));
      for (final value in (jsonDecode(verifier) as Map).values) {
        expect(message, isNot(contains(value as String)));
      }
    });
  });

  group('criterion 3: a signed-in volunteer presenting a code is admitted under the account', () {
    test('join after the magic link admits the named user, with no anonymous sign-in', () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.requestMagicLink(email);
      await engine.completeMagicLink(s.newestLinkCode[email]!);
      final granted = await engine.join('RECO-ALFA');
      final admit = s.requests.singleWhere((r) => r.path == '/rest/v1/rpc/admit_device');
      expect(admit.caller, s.namedUsers[email], reason: "the volunteer's own account");
      expect(s.anonymous[admit.caller], isFalse);
      expect(s.requests.where((r) => r.path == '/auth/v1/signup'), isEmpty);
      expect(s.admissions[s.namedUsers[email]]?.keys, [granted.admissionId]);
      expect(phone.store.admissionId, granted.admissionId);
    });
  });

  group('criterion 4: an expired session with no signal never holds up the log', () {
    test("a race-time append through the core answers while the engine's refresh of the expired session hangs",
        () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.requestMagicLink(email);
      await engine.completeMagicLink(s.newestLinkCode[email]!);
      final user = s.namedUsers[email]!;
      await engine.join('RECO-ALFA');
      await engine.close();
      // Later in the race: the access token has expired, and the refresh never answers (a dead
      // link), so the engine's run waits on it, up to its own timeout.
      phone.keepSession(s.session(user, validFor: const Duration(minutes: -2)));
      final hang = Completer<http.Response?>();
      s.firstHooks.add((r) => r.path == '/auth/v1/token' && !hang.isCompleted ? hang.future : null);
      final (_, later) = fresh(s, phone);
      // The core as #113's host serves it: one store, the engine wired in behind it.
      final core = CoreServer(phone.store,
          join: later.join, signIn: SignInHandlers(requestLink: later.requestMagicLink, completeLink: later.completeMagicLink));
      final requests = ReceivePort();
      addTearDown(requests.close);
      requests.listen(core.handle);
      final client = PortCoreClient(requests.sendPort, closesCore: false);

      var runDone = false;
      final running = later.syncOnce().whenComplete(() => runDone = true);
      while (!s.requests.any((r) => r.path == '/auth/v1/token')) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final stored = await client
          .append(NewEvent(kind: 'note', source: 'tap', payload: {'text': 'Finish 7 seen'}))
          .timeout(const Duration(seconds: 2));
      expect(runDone, isFalse, reason: 'the append answered while the refresh still hung');
      hang.complete(null);
      await running;
      expect(phone.store.readOwn().map((e) => e.ulid), contains(stored.ulid));
    }, timeout: const Timeout(Duration(seconds: 60)));

    test("events wait on the phone while the volunteer's session cannot be refreshed, and go up under the account once it can",
        () async {
      final s = server();
      final (phone, engine) = fresh(s);
      await engine.requestMagicLink(email);
      await engine.completeMagicLink(s.newestLinkCode[email]!);
      final user = s.namedUsers[email]!;
      final admission = (await engine.join('RECO-ALFA')).admissionId;
      await engine.close();

      // Later in the race: the access token has expired, and the phone is out of signal.
      phone.keepSession(s.session(user, validFor: const Duration(minutes: -2)));
      s.offline = true;
      final (_, later) = fresh(s, phone);
      final logged = phone.log(3);
      final offline = await later.syncOnce();
      expect(offline.state, isNot(UploadRunState.done));
      expect(phone.store.uploadStatus().refused, isEmpty, reason: 'the events wait on the phone');

      s.offline = false;
      final back = await later.syncOnce();
      expect(back.state, UploadRunState.done, reason: '$back');
      expect(later.userId, user, reason: 'the same account, refreshed, never a new sign-in');
      expect(s.requests.where((r) => r.path == '/auth/v1/signup'), isEmpty);
      for (final ulid in logged) {
        expect(s.log[ulid]?.canonical, contains('"admission_id":"$admission"'), reason: 'uploaded under the admission');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
