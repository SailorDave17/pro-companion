import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/signin/sign_in_link.dart';
import 'package:pro_companion/signin/sign_in_screen.dart';
import 'package:pro_companion/ui/bars.dart';
import 'package:pro_companion/ui/fit_label.dart';
import 'package:pro_companion/ui/sunlight.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #104 on the app, driven against the fake core: a named volunteer signs the
/// phone in by magic link from the picker's SIGN IN BY EMAIL, the link that
/// opens the app signs the phone in as the volunteer's account, and ENTER ROLE
/// CODE joins under that account and opens the granted role's home. The
/// core's half (the PKCE request, the exchange, the session's is_anonymous,
/// the admission under the account) is packages/sync/test/sign_in_test.dart
/// over a scripted server and test/sync_test.dart's #104 case on the local
/// stack; the wire is packages/core/test/sign_in_test.dart.
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;
  late _Links links;

  const email = 'volunteer@example.com';
  const linkCode = '4d3e9f0a-1b2c-4d5e-8f60-718293a4b5c6';
  const recorderAlpha = Admission(
      admissionId: '3f6c1a52-8d0e-4b7a-9c21-5e4f0a9b7d13',
      eventId: 'b3c7e9a1-2d4f-4b6a-8c0e-1f2a3b4c5d6e',
      role: Roles.recorder,
      courseId: '00000000-0000-4000-8000-0000000000ca',
      raceArea: 'Alpha');

  final signInByEmail = find.byKey(const ValueKey('sign-in-by-email'));
  final emailField = find.byKey(const ValueKey('sign-in-email'));
  final sendLink = find.byKey(const ValueKey('send-link'));
  final linkSent = find.byKey(const ValueKey('link-sent'));
  final problem = find.byKey(const ValueKey('sign-in-problem'));
  final signedInAs = find.byKey(const ValueKey('signed-in-as'));
  final alreadySignedIn = find.byKey(const ValueKey('already-signed-in'));
  final enterRoleCode = find.byKey(const ValueKey('enter-role-code'));
  final tryAgain = find.byKey(const ValueKey('try-link-again'));
  final title = find.text('Sign in by email');
  final picker = find.text('Pick your role');

  setUp(() {
    now = DateTime(2026, 11, 8, 14, 30).millisecondsSinceEpoch;
    core = FakeCore(clock: () => now += 1000);
    device = FakeConfirmationDevice();
    links = _Links();
    addTearDown(links.close);
  });

  Widget app({double textScale = 1, CoreClient? on, NavigatorObserver? observer}) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ProCompanionApp(
          core: on ?? core,
          confirmation: ConfirmationService(device),
          navigatorObservers: [?observer],
          signInLinks: links,
        ),
      );

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 80, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  /// The app opened on the picker, then SIGN IN BY EMAIL.
  Future<void> openSignIn(WidgetTester tester, {double textScale = 1}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app(textScale: textScale));
    await tester.pumpAndSettle();
    expect(picker, findsOneWidget);
    await tap(tester, signInByEmail);
    expect(title, findsOneWidget);
  }

  Future<void> send(WidgetTester tester, [String address = email]) async {
    await tester.enterText(emailField, address);
    await tester.pumpAndSettle();
    await tap(tester, sendLink);
  }

  /// The link opening the app, as Android hands it over while the app runs.
  Future<void> open(WidgetTester tester, String uri) async {
    links.arrive(uri);
    await tester.pumpAndSettle();
  }

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readOwn))!;

  group('criterion 1: an address asks for a magic link, and the screen says to open it on this phone', () {
    testWidgets('SEND LINK hands the address to the core, once, and says where the link went', (tester) async {
      core.onRequestSignInLink = (_) async {};
      await openSignIn(tester);
      expect(tester.widget<FilledButton>(sendLink).onPressed, isNull, reason: 'nothing to send yet');
      await send(tester, '  $email ');
      expect(core.signInLinkRequests, [email], reason: 'trimmed, and sent once');
      expect(linkSent, findsOneWidget);
      expect(find.text(SignInScreen.sentTo(email)), findsOneWidget);
      expect(find.text('SEND A NEW LINK'), findsOneWidget, reason: 'a second request replaces the first');
      expect(await events(tester), isEmpty, reason: 'asking for a link logs nothing');
    });

    testWidgets("an address the server refuses says the server's sentence, and nothing is said to be sent", (tester) async {
      core.onRequestSignInLink = (_) async => throw const CoreException(SignInCodes.refused, 'That email address cannot be used.');
      await openSignIn(tester);
      await send(tester, 'not an address');
      expect(find.text('That email address cannot be used.'), findsOneWidget);
      expect(problem, findsOneWidget);
      expect(linkSent, findsNothing);
    });

    testWidgets('no signal and a build with no server each say so in plain words', (tester) async {
      core.onRequestSignInLink = (_) async => throw const CoreException(SignInCodes.noSignal, 'no answer');
      await openSignIn(tester);
      await send(tester);
      expect(find.text(SignInScreen.needsSignal), findsOneWidget);
      core.onRequestSignInLink = null; // unwired, as the app's core is until #113
      await tap(tester, sendLink);
      expect(find.text(SignInScreen.noServer), findsOneWidget);
    });

    testWidgets('a phone that already holds a session goes straight on to the role code', (tester) async {
      core.onRequestSignInLink = (_) async => throw const CoreException(SignInCodes.signedIn, 'This phone is already signed in.');
      await openSignIn(tester);
      await send(tester);
      expect(alreadySignedIn, findsOneWidget);
      expect(enterRoleCode, findsOneWidget);
    });
  });

  group('criterion 2: the magic link opening the app signs the phone in as the volunteer', () {
    testWidgets('while the screen waits: the code goes to the core, and the account is shown', (tester) async {
      core.onRequestSignInLink = (_) async {};
      core.onCompleteSignInLink = (_) async => email;
      await openSignIn(tester);
      await send(tester);
      await open(tester, '$signInRedirect?code=$linkCode');
      expect(core.signInLinkCodes, [linkCode]);
      expect(signedInAs, findsOneWidget);
      expect(find.text(email), findsOneWidget);
      expect(enterRoleCode, findsOneWidget);
    });

    testWidgets('on a cold start (the app gone on the way to the mail app): the screen opens on the link', (tester) async {
      core.onCompleteSignInLink = (_) async => email;
      links.initial = '$signInRedirect?code=$linkCode';
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(title, findsOneWidget);
      expect(core.signInLinkCodes, [linkCode]);
      expect(signedInAs, findsOneWidget);
    });

    testWidgets('a link arriving on the picker opens the screen on it, once', (tester) async {
      core.onCompleteSignInLink = (_) async => email;
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await open(tester, '$signInRedirect?code=$linkCode');
      expect(title, findsOneWidget);
      expect(signedInAs, findsOneWidget);
      await open(tester, '$signInRedirect?code=$linkCode');
      expect(title, findsOneWidget, reason: 'the second goes to the screen showing, never a second screen');
      expect(core.signInLinkCodes, [linkCode], reason: 'a signed-in screen opens no further link');
    });

    testWidgets('an expired link says so, and the core is never asked', (tester) async {
      core.onRequestSignInLink = (_) async {};
      await openSignIn(tester);
      await send(tester);
      await open(tester, '$signInRedirect?error=access_denied&error_code=otp_expired&error_description=Email+link+is+invalid');
      expect(find.text(SignInScreen.expiredLink), findsOneWidget);
      expect(core.signInLinkCodes, isEmpty);
      await open(tester, '$signInRedirect#error=server_error');
      expect(find.text(SignInScreen.badLink), findsOneWidget);
      expect(core.signInLinkCodes, isEmpty);
    });

    testWidgets("a link the core refuses says the core's sentence, and the phone stays signed out", (tester) async {
      core.onRequestSignInLink = (_) async {};
      core.onCompleteSignInLink =
          (_) async => throw const CoreException(SignInCodes.refused, 'Open the newest link on the phone that asked for it.');
      await openSignIn(tester);
      await send(tester);
      await open(tester, '$signInRedirect?code=$linkCode');
      expect(find.text('Open the newest link on the phone that asked for it.'), findsOneWidget);
      expect(signedInAs, findsNothing);
      expect(enterRoleCode, findsNothing);
    });

    testWidgets('no signal keeps the link, and TRY AGAIN opens it again', (tester) async {
      var answer = 0;
      core.onCompleteSignInLink = (_) async =>
          answer++ == 0 ? throw const CoreException(SignInCodes.noSignal, 'no answer') : email;
      links.initial = '$signInRedirect?code=$linkCode';
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.text(SignInScreen.needsSignal), findsOneWidget);
      await tap(tester, tryAgain);
      expect(core.signInLinkCodes, [linkCode, linkCode]);
      expect(signedInAs, findsOneWidget);
    });

    // #104's review: a link never covers a role's home or a screen opened over the picker.
    testWidgets("a link while a role's home shows is let go: it never covers a race-time screen", (tester) async {
      core.onCompleteSignInLink = (_) async => email;
      withRole(core);
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('undo-role')), findsOneWidget, reason: "the PRO's home");
      await open(tester, '$signInRedirect?code=$linkCode');
      expect(title, findsNothing);
      expect(core.signInLinkCodes, isEmpty);
      expect(find.byKey(const ValueKey('undo-role')), findsOneWidget);
    });

    testWidgets('a link while the join screen shows is let go', (tester) async {
      core.onCompleteSignInLink = (_) async => email;
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('join-with-code')));
      await open(tester, '$signInRedirect?code=$linkCode');
      expect(find.text('Join with a code'), findsOneWidget);
      expect(title, findsNothing);
      expect(core.signInLinkCodes, isEmpty);
    });

    testWidgets('an address that is not a sign-in opens nothing', (tester) async {
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await open(tester, 'procompanion://elsewhere?code=$linkCode');
      await open(tester, 'https://example.com/?code=$linkCode');
      expect(picker, findsOneWidget);
      expect(title, findsNothing);
      expect(core.signInLinkCodes, isEmpty);
    });
  });

  group("criterion 3: signed in, the role's code admits the phone under the account", () {
    testWidgets("ENTER ROLE CODE joins, the grant opens its home, and the pick is the phone's", (tester) async {
      core.onCompleteSignInLink = (_) async => email;
      core.onJoin = (_) async => recorderAlpha;
      links.initial = '$signInRedirect?code=$linkCode';
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tap(tester, enterRoleCode);
      expect(find.text('Join with a code'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('join-code')), 'RECOALFA');
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('join')));
      await tap(tester, find.byKey(const ValueKey('open-home')));
      expect(core.joins, ['RECO-ALFA']);
      expect(title, findsNothing, reason: 'the sign-in screen handed the pick back and closed');
      expect(find.byKey(const ValueKey('undo-role')), findsOneWidget, reason: "the recorder's home");
      final logged = await events(tester);
      expect([for (final e in logged) e.kind], [RoleKinds.assigned]);
      expect(logged.single.payload['role'], Roles.recorder);
    });

    testWidgets("a club that signs phones in by device handoff: the join screen says so, in the server's words", (tester) async {
      const handoff = "This club signs phones in by device handoff, not by a volunteer's email.";
      core.onCompleteSignInLink = (_) async => email;
      core.onJoin = (_) async => throw const CoreException(JoinCodes.refused, handoff);
      links.initial = '$signInRedirect?code=$linkCode';
      setPhoneSize(tester);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tap(tester, enterRoleCode);
      await tester.enterText(find.byKey(const ValueKey('join-code')), 'RECOALFA');
      await tester.pumpAndSettle();
      await tap(tester, find.byKey(const ValueKey('join')));
      expect(find.text(handoff), findsOneWidget);
      expect(await events(tester), isEmpty, reason: 'no role pick for a refused phone');
    });
  });

  group("the platform's links, over MainActivity's channel", () {
    const channel = MethodChannel('pro_companion/sign_in_link');

    Future<void> fromAndroid(WidgetTester tester, String method, Object? arguments) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            channel.name, channel.codec.encodeMethodCall(MethodCall(method, arguments)), (_) {});

    testWidgets("a link sent before anyone listens is kept for the gate's first listen (#104's review)", (tester) async {
      final links = PlatformSignInLinks();
      await fromAndroid(tester, 'link', '$signInRedirect?code=$linkCode');
      final heard = <String>[];
      final sub = links.incoming.listen(heard.add);
      addTearDown(sub.cancel);
      await tester.pump();
      expect(heard, ['$signInRedirect?code=$linkCode']);
      await fromAndroid(tester, 'link', '$signInRedirect?code=second');
      await tester.pump();
      expect(heard, hasLength(2));
    });

    testWidgets('initialLink is asked of Android, and a build with no channel answers none', (tester) async {
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'initialLink' ? 'procompanion://sign-in?code=x' : null);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(await PlatformSignInLinks().takeInitial(), 'procompanion://sign-in?code=x');
      // A build whose activity carries no channel. (Unmocked, the test binding hands the call to a
      // platform that never answers, so the build's own answer is mocked.)
      messenger.setMockMethodCallHandler(channel, (call) async => throw MissingPluginException());
      expect(await PlatformSignInLinks().takeInitial(), isNull, reason: 'MissingPluginException is no link');
    });
  });

  group('criterion 5: the sign-in screen passes the bar-check helper', () {
    Future<List<String>> checkState(WidgetTester tester, String where) async {
      final violations = <String>[];
      final targets = await const MinimumTapTargetGuideline(size: Size.square(Bars.minTargetDp), link: 'docs/usability-bars.md')
          .evaluate(tester);
      if (!targets.passed) violations.add('$where: ${targets.reason}');
      violations.addAll(clippedLabels(tester).map((c) => '$where: $c'));
      return violations;
    }

    for (final scale in [1.0, 2.0]) {
      final pct = '${(scale * 100).round()}%';

      // The picker with its new button, one tap deep, as join_test's picker check walks it.
      testWidgets('from the picker, at $pct text', (tester) async {
        final violations = await barCheck(
          tester,
          (observer) => app(textScale: scale, on: FakeCore(), observer: observer),
          actionIds: const {},
          maxTaps: 1,
        );
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      // Two taps deep over a stand-in for the picker: SIGN IN BY EMAIL, then the field and Back.
      // SEND LINK with an address typed is beyond what the exploration can reach; the states test
      // below covers it.
      testWidgets('the screen and everything on it, two taps deep, at $pct text', (tester) async {
        final violations = await barCheck(
          tester,
          (observer) => MediaQuery.withClampedTextScaling(
            minScaleFactor: scale,
            maxScaleFactor: scale,
            child: MaterialApp(
              theme: sunlightTheme(),
              navigatorObservers: [observer],
              home: _UnderSignIn(core: FakeCore(), confirmation: ConfirmationService(device)),
            ),
          ),
          actionIds: const {},
        );
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      testWidgets('the sent, refused, no-signal and signed-in states, at $pct text', (tester) async {
        final semantics = tester.ensureSemantics();
        final violations = <String>[];
        var request = 0;
        core.onRequestSignInLink = (_) async => switch (request++) {
              0 => null,
              _ => throw const CoreException(SignInCodes.refused, 'That email address cannot be used.'),
            };
        var answer = 0;
        core.onCompleteSignInLink = (_) async =>
            answer++ == 0 ? throw const CoreException(SignInCodes.noSignal, 'no answer') : email;
        await openSignIn(tester, textScale: scale);
        await send(tester);
        expect(linkSent, findsOneWidget);
        violations.addAll(await checkState(tester, 'sent'));
        await tap(tester, sendLink);
        expect(problem, findsOneWidget);
        violations.addAll(await checkState(tester, 'refused'));
        await open(tester, '$signInRedirect?code=$linkCode');
        // At 200% the banners push TRY AGAIN below the fold, where the list has not built it.
        await tester.scrollUntilVisible(tryAgain, 80, scrollable: find.byType(Scrollable).first);
        await tester.pumpAndSettle();
        expect(tryAgain, findsOneWidget);
        violations.addAll(await checkState(tester, 'no signal'));
        await tap(tester, tryAgain);
        expect(signedInAs, findsOneWidget);
        violations.addAll(await checkState(tester, 'signed in'));
        semantics.dispose();
        expect(violations, isEmpty, reason: violations.join('\n'));
      });
    }
  });
}

/// The links that open the app, as a test hands them in.
class _Links implements SignInLinks {
  String? initial;
  final _incoming = StreamController<String>.broadcast();

  void arrive(String uri) => _incoming.add(uri);
  Future<void> close() => _incoming.close();

  @override
  Future<String?> takeInitial() async {
    final uri = initial;
    initial = null;
    return uri;
  }

  @override
  Stream<String> get incoming => _incoming.stream;
}

/// A screen the sign-in screen is pushed over, standing in for the picker in
/// the bar check, as join_test's does for the join screen.
class _UnderSignIn extends StatelessWidget {
  const _UnderSignIn({required this.core, required this.confirmation});

  final CoreClient core;
  final ConfirmationService confirmation;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(Bars.screenGutterDp),
            child: Center(
              child: SizedBox(
                width: double.infinity,
                height: Bars.minTargetDp + 8,
                child: OutlinedButton(
                  key: const ValueKey('sign-in-by-email'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<Object?>(
                    builder: (_) => SignInScreen(core: core, confirmation: confirmation),
                  )),
                  child: const FitLabel('SIGN IN BY EMAIL'),
                ),
              ),
            ),
          ),
        ),
      );
}
