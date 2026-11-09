import 'dart:async';
import 'dart:isolate';

import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/host.dart';
import 'package:pro_companion_core/store.dart';
import 'package:pro_companion_core/testing.dart';
import 'package:test/test.dart';

import 'support.dart';

/// #104: the core's magic-link sign-in, as the UI reaches it. As with `join`
/// (#71), the core makes no network call: a host wires the two requests to
/// whatever signs the phone in (sync, #113) and the server relays the answer,
/// or the coded refusal, over the port. A core nothing is wired to refuses
/// both as `no_server`.
void main() {
  const email = 'volunteer@example.com';

  /// [store] served in this isolate over [handlers], reached through the same client the UI uses.
  CoreClient served(EventStore store, SignInHandlers? handlers) {
    final server = CoreServer(store, signIn: handlers);
    final requests = ReceivePort();
    addTearDown(requests.close);
    requests.listen(server.handle);
    return PortCoreClient(requests.sendPort, closesCore: false);
  }

  SignInHandlers handlers({
    Future<void> Function(String email)? requestLink,
    Future<String> Function(String code)? completeLink,
  }) =>
      SignInHandlers(
          requestLink: requestLink ?? (_) async {},
          completeLink: completeLink ?? (_) async => email);

  test('both requests reach the handlers, and the account comes back as plain data', () async {
    final asked = <String>[];
    final core = served(
        openStore(tempDbPath()),
        handlers(requestLink: (e) async => asked.add('request $e'), completeLink: (c) async {
          asked.add('complete $c');
          return email;
        }));
    await core.requestSignInLink(email);
    expect(await core.completeSignInLink('one-time-code'), email);
    expect(asked, ['request $email', 'complete one-time-code']);
  });

  test('a sign-in still waiting on its handler does not block the core: a read answers first', () async {
    final gate = Completer<void>();
    final core = served(openStore(tempDbPath()), handlers(completeLink: (code) async {
      await gate.future;
      return email;
    }));
    final signingIn = core.completeSignInLink('one-time-code');
    expect(await core.count(), 0, reason: 'answered while the sign-in waits on the server');
    gate.complete();
    expect(await signingIn, email);
  });

  group('what comes back when the handler cannot sign in', () {
    test('a coded refusal keeps its code and message, from either request', () async {
      final core = served(
          openStore(tempDbPath()),
          handlers(
              requestLink: (_) async => throw signInException(SignInCodes.signedIn, 'This phone is already signed in.'),
              completeLink: (_) async => throw signInException(SignInCodes.refused, 'That link has expired.')));
      await expectLater(
          core.requestSignInLink(email),
          throwsA(isA<CoreException>()
              .having((e) => e.code, 'code', SignInCodes.signedIn)
              .having((e) => e.message, 'message', 'This phone is already signed in.')));
      await expectLater(
          core.completeSignInLink('one-time-code'),
          throwsA(isA<CoreException>()
              .having((e) => e.code, 'code', SignInCodes.refused)
              .having((e) => e.message, 'message', 'That link has expired.')));
    });

    test('anything else the handler throws is a failure, never a crash of the core', () async {
      final core = served(openStore(tempDbPath()), handlers(requestLink: (_) async => throw StateError('the engine is closed')));
      await expectLater(core.requestSignInLink(email),
          throwsA(isA<CoreException>().having((e) => e.code, 'code', 'failed').having((e) => e.message, 'message', contains('closed'))));
      expect(await core.count(), 0, reason: 'the core is still serving');
    });

    test('a core nothing is wired to refuses both as no_server', () async {
      final core = served(openStore(tempDbPath()), null);
      await expectLater(core.requestSignInLink(email), throwsA(isA<CoreException>().having((e) => e.code, 'code', SignInCodes.noServer)));
      await expectLater(
          core.completeSignInLink('one-time-code'), throwsA(isA<CoreException>().having((e) => e.code, 'code', SignInCodes.noServer)));
      final spawned = await spawnCore(tempDbPath());
      addTearDown(spawned.close);
      await expectLater(spawned.requestSignInLink(email), throwsA(isA<CoreException>().having((e) => e.code, 'code', SignInCodes.noServer)));
    });

    test('an empty address or code is invalid, and the handler is never asked', () async {
      var asked = 0;
      final core = served(
          openStore(tempDbPath()),
          handlers(requestLink: (_) async => asked++, completeLink: (_) async {
            asked++;
            return email;
          }));
      await expectLater(core.requestSignInLink(''), throwsA(isA<CoreException>().having((e) => e.code, 'code', 'invalid')));
      await expectLater(core.completeSignInLink(''), throwsA(isA<CoreException>().having((e) => e.code, 'code', 'invalid')));
      expect(asked, 0);
    });

    test('only a sign-in code may be minted as one', () {
      expect(() => signInException(JoinCodes.refused, 'x'), throwsArgumentError);
      for (final code in SignInCodes.all) {
        expect(signInException(code, 'x').code, code);
      }
    });
  });

  test('the fake core: unwired as the real core, then each request and code is recorded', () async {
    final fake = FakeCore();
    await expectLater(fake.requestSignInLink(email), throwsA(isA<CoreException>().having((e) => e.code, 'code', SignInCodes.noServer)),
        reason: 'nothing wired, as the real core');
    await expectLater(
        fake.completeSignInLink('one-time-code'), throwsA(isA<CoreException>().having((e) => e.code, 'code', SignInCodes.noServer)));
    fake.onRequestSignInLink = (_) async {};
    fake.onCompleteSignInLink = (code) async =>
        code == 'good' ? email : throw signInException(SignInCodes.refused, 'That link has expired.');
    await fake.requestSignInLink(email);
    expect(await fake.completeSignInLink('good'), email);
    await expectLater(fake.completeSignInLink('stale'), throwsA(isA<CoreException>().having((e) => e.code, 'code', SignInCodes.refused)));
    expect(fake.signInLinkRequests, [email, email]);
    expect(fake.signInLinkCodes, ['one-time-code', 'good', 'stale']);
    expect(fake.calls['requestSignInLink'], 2);
    expect(fake.calls['completeSignInLink'], 3);
  });

  group('SignInLink.parse: what a magic link hands the app at its sign-in address', () {
    test('the redirect is the app scheme and the sign-in host, with nothing after it', () {
      final redirect = Uri.parse(signInRedirect);
      expect((redirect.scheme, redirect.host, redirect.path, redirect.query), ('procompanion', 'sign-in', '', ''));
    });

    test('a one-time code in the query is the code to exchange', () {
      final link = SignInLink.parse('$signInRedirect?code=4d3e9f0a-1b2c-4d5e-8f60-718293a4b5c6')!;
      expect(link.isError, isFalse);
      expect(link.code, '4d3e9f0a-1b2c-4d5e-8f60-718293a4b5c6');
      expect(link.errorCode, isNull);
    });

    test("an error in the query names the server's error_code, before any code", () {
      final link = SignInLink.parse(
          '$signInRedirect?error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired')!;
      expect(link.isError, isTrue);
      expect(link.errorCode, 'otp_expired');
      expect(link.errorDescription, 'Email link is invalid or has expired');
      expect(link.code, isNull);
    });

    test("the server's own answer to a reused link, verbatim: the error in the query and the fragment both", () {
      // Measured 2026-11-08 on the local stack (Supabase CLI 2.117.0's auth): a magic link opened a
      // second time redirects here.
      const reused = 'procompanion://sign-in?error=access_denied&error_code=otp_expired'
          '&error_description=Email+link+is+invalid+or+has+expired'
          '#error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid+or+has+expired';
      final link = SignInLink.parse(reused)!;
      expect((link.isError, link.errorCode, link.code), (true, 'otp_expired', null));
    });

    test('an error in the fragment counts as well, and a bare error falls back to its error', () {
      expect(SignInLink.parse('$signInRedirect#error=access_denied&error_code=otp_expired')!.errorCode, 'otp_expired');
      expect(SignInLink.parse('$signInRedirect#error=server_error')!.errorCode, 'server_error');
      expect(SignInLink.parse('$signInRedirect?code=abc#error=access_denied')!.isError, isTrue,
          reason: 'an error anywhere wins over a code');
    });

    test('the sign-in address with neither a code nor an error is an error of its own', () {
      expect(SignInLink.parse(signInRedirect)!.errorCode, 'no_code');
      expect(SignInLink.parse('$signInRedirect?code=')!.errorCode, 'no_code');
      expect(SignInLink.parse('$signInRedirect/')!.errorCode, 'no_code');
    });

    test('any other address is not a sign-in at all', () {
      for (final uri in [
        'https://sign-in?code=abc',
        'procompanion://join?code=abc',
        'procompanion://sign-in/elsewhere?code=abc',
        'otherapp://sign-in?code=abc',
        'not a uri at all %',
        '',
      ]) {
        expect(SignInLink.parse(uri), isNull, reason: uri);
      }
    });
  });
}
