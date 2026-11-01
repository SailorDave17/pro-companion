import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/join/join_screen.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/roles/roles.dart';
import 'package:pro_companion/ui/bars.dart';
import 'package:pro_companion/ui/fit_label.dart';
import 'package:pro_companion/ui/sunlight.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/bar_check.dart';
import 'support/fake_confirmation.dart';

/// #71 on the app, driven against the fake core: a phone handed a role's
/// admission code joins from the picker's JOIN WITH CODE, sees the role and
/// race area granted, and one tap opens that role's home. The core's half
/// (the sign-in, the lookup, admit_device, the admission cached with its
/// role-change marker) is packages/sync/test/join_test.dart over a scripted
/// server, test/sync_test.dart's join case on the local stack, and
/// packages/core/test/admission_test.dart's criterion 6 for the marker.
///
/// Criterion 5's mutation, run on 2026-10-31 and recorded on the PR: with the
/// refusal branch of JoinScreen._join changed to treat the refusal as a grant
/// of the first pickable role (the phone picks a role when the code is
/// refused), the three tests under criterion 2 go red, and nothing else does.
void main() {
  late int now;
  late FakeCore core;
  late FakeConfirmationDevice device;

  const alpha = '00000000-0000-4000-8000-0000000000ca';
  const day = 'b3c7e9a1-2d4f-4b6a-8c0e-1f2a3b4c5d6e';
  const recorderAlpha = Admission(
      admissionId: '3f6c1a52-8d0e-4b7a-9c21-5e4f0a9b7d13', eventId: day, role: Roles.recorder, courseId: alpha, raceArea: 'Alpha');
  const scorerDay = Admission(
      admissionId: '9b0d7e21-44c6-4e1f-8a35-c7f2d6190e48', eventId: day, role: Roles.scorer, courseId: null, raceArea: null);
  const refusal = 'That code was not recognised.';

  final joinWithCode = find.byKey(const ValueKey('join-with-code'));
  final codeField = find.byKey(const ValueKey('join-code'));
  final joinButton = find.byKey(const ValueKey('join'));
  final openHome = find.byKey(const ValueKey('open-home'));
  final problem = find.byKey(const ValueKey('join-problem'));
  final needsSignal = find.byKey(const ValueKey('needs-signal'));
  final picker = find.text('Pick your role');
  final undoRole = find.byKey(const ValueKey('undo-role'));

  setUp(() {
    now = DateTime(2026, 10, 31, 14, 30).millisecondsSinceEpoch;
    core = FakeCore(clock: () => now += 1000);
    device = FakeConfirmationDevice();
  });

  Widget app({double textScale = 1, CoreClient? on, NavigatorObserver? observer}) => MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: ProCompanionApp(
          core: on ?? core,
          confirmation: ConfirmationService(device),
          navigatorObservers: [?observer],
        ),
      );

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    await tester.pumpAndSettle();
  }

  /// Taps [f] on the join screen's list, scrolled into view first: at 200%
  /// text a banner pushes JOIN and OPEN HOME below the fold, where the list
  /// has not built them, as a thumb would scroll to them.
  Future<void> tapOnList(WidgetTester tester, Finder f) async {
    await tester.scrollUntilVisible(f, 80, scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tap(tester, f);
  }

  Future<void> tapJoin(WidgetTester tester) => tapOnList(tester, joinButton);
  Future<void> tapOpen(WidgetTester tester) => tapOnList(tester, openHome);

  /// The app opened on the picker, then JOIN WITH CODE.
  Future<void> openJoin(WidgetTester tester, {double textScale = 1}) async {
    setPhoneSize(tester);
    await tester.pumpWidget(app(textScale: textScale));
    await tester.pumpAndSettle();
    expect(picker, findsOneWidget);
    await tap(tester, joinWithCode);
    expect(find.text('Join with a code'), findsOneWidget);
  }

  Future<void> enter(WidgetTester tester, String code) async {
    await tester.enterText(codeField, code);
    await tester.pumpAndSettle();
  }

  String fieldText(WidgetTester tester) => tester.widget<TextField>(codeField).controller!.text;

  Future<List<EventEnvelope>> events(WidgetTester tester) async => (await tester.runAsync(core.readOwn))!;

  /// The screen's words must name no role, race area or event (criterion 2).
  const revealing = ['PRO', 'Recorder', 'Mark boat', 'Safety', 'Scorer', 'Course PRO', 'Alpha', 'Club night', day];

  group('criterion 1: a valid code admits the phone, shows the grant, and one tap opens the home', () {
    testWidgets('the code goes to the core as the field shaped it, and the grant is shown before any home', (tester) async {
      core.onJoin = (code) async => recorderAlpha;
      await openJoin(tester);
      expect(tester.widget<FilledButton>(joinButton).onPressed, isNull, reason: 'nothing to send yet');

      await enter(tester, 'reco alfa');
      expect(fieldText(tester), 'RECO-ALFA', reason: 'upper-cased, with the dash the script prints');
      await tapJoin(tester);

      expect(core.joins, ['RECO-ALFA'], reason: 'the core was asked once, with the code as shown');
      expect(await core.admissionId(), recorderAlpha.admissionId, reason: 'cached in the core by the join');
      expect(find.text('Admitted as'), findsOneWidget);
      expect(find.byKey(const ValueKey('granted-role')), findsOneWidget);
      expect(find.text('Recorder'), findsOneWidget);
      expect(find.text('Race area: Alpha'), findsOneWidget);
      expect(await events(tester), isEmpty, reason: 'no role pick yet: the grant is shown first');
      expect(undoRole, findsNothing, reason: 'and no home is open');
      expect(codeField, findsNothing, reason: 'the entry is done');

      await tapOpen(tester);
      final all = await events(tester);
      expect(all, hasLength(1), reason: 'one tap, one event');
      expect([all.single.kind, all.single.role, all.single.payload], [RoleKinds.assigned, Roles.recorder, {'role': Roles.recorder}]);
      expect(all.single.admissionId, recorderAlpha.admissionId, reason: 'stamped with the admission just granted');
      expect([device.vibrations, device.tones.length], [1, 1], reason: 'the pick is confirmed as a pick is (#20)');
      expect(find.text('Join with a code'), findsNothing);
      expect(find.text('Recorder'), findsOneWidget, reason: "the recorder's home");
      expect(undoRole, findsOneWidget);
      expect(find.text('FINISHES'), findsOneWidget);
    });

    testWidgets('an event-wide role is granted the whole event, and its home opens', (tester) async {
      core.onJoin = (code) async => scorerDay;
      await openJoin(tester);
      await enter(tester, 'SCOR0001');
      await tapJoin(tester);
      expect(find.text('Scorer'), findsOneWidget);
      expect(find.text('Whole event'), findsOneWidget);
      await tapOpen(tester);
      expect(find.text('Scorer'), findsOneWidget);
      expect(find.text('No actions for this role yet.'), findsOneWidget, reason: "the scorer's home is held");
      expect((await events(tester)).single.role, Roles.scorer);
    });

    testWidgets('a restart opens the granted role\'s home, read back from the log', (tester) async {
      core.onJoin = (code) async => recorderAlpha;
      await openJoin(tester);
      await enter(tester, 'RECOALFA');
      await tapJoin(tester);
      await tapOpen(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      expect(picker, findsNothing);
      expect(find.text('Recorder'), findsOneWidget);
    });

    testWidgets('a pick that does not log says so on the grant, and the home stays shut', (tester) async {
      core.onJoin = (code) async => recorderAlpha;
      await openJoin(tester);
      await enter(tester, 'RECOALFA');
      await tapJoin(tester);
      core.failWith = const CoreException('refused', 'disk full');
      await tapOpen(tester);
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
      expect(undoRole, findsNothing);
      expect([device.vibrations, device.tones.length], [0, 0]);
      core.failWith = null;
      await tapOpen(tester);
      expect(undoRole, findsOneWidget);
    });

    testWidgets('a second tap on JOIN while the first is on its way is the same tap', (tester) async {
      var answers = 0;
      core.onJoin = (code) async {
        answers++;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return recorderAlpha;
      };
      await openJoin(tester);
      await enter(tester, 'RECOALFA');
      await tester.tap(joinButton);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('JOINING…'), findsOneWidget);
      expect(tester.widget<FilledButton>(joinButton).onPressed, isNull);
      await tester.pumpAndSettle();
      expect(answers, 1);
      expect(find.text('Admitted as'), findsOneWidget);
    });
  });

  group('criterion 2: a refused code', () {
    testWidgets('one plain sentence that names no role, race area or event; the code stays; no role, no home', (tester) async {
      core.onJoin = (code) async => throw const CoreException(JoinCodes.refused, refusal);
      await openJoin(tester);
      await enter(tester, 'XXXX0000');
      await tapJoin(tester);

      expect(problem, findsOneWidget);
      final shown = tester.widget<Text>(find.descendant(of: problem, matching: find.byType(Text))).data!;
      expect(shown, refusal);
      for (final word in revealing) {
        expect(shown.toLowerCase(), isNot(contains(word.toLowerCase())), reason: word);
      }
      expect(fieldText(tester), 'XXXX-0000', reason: 'kept, to be corrected');
      expect(await events(tester), isEmpty, reason: 'no role pick: the phone picked nothing');
      expect(await core.admissionId(), isNull);
      expect(find.text('Admitted as'), findsNothing);
      expect(openHome, findsNothing);
      expect(undoRole, findsNothing, reason: 'no home opened');
      expect(picker, findsNothing, reason: 'still on the join screen, not sent back to pick');
      expect(find.text('Join with a code'), findsOneWidget);
    });

    testWidgets('a refusal never opens a home: no role home is reachable without another code', (tester) async {
      core.onJoin = (code) async => throw const CoreException(JoinCodes.refused, refusal);
      await openJoin(tester);
      await enter(tester, 'XXXX0000');
      await tapJoin(tester);
      await tapJoin(tester);
      expect(core.joins, ['XXXX-0000', 'XXXX-0000'], reason: 'JOIN sends again; nothing else moves');
      for (final role in pickableRoles) {
        expect(find.text(roleName(role)), findsNothing, reason: 'no home for $role');
      }
      expect(await events(tester), isEmpty);
    });

    testWidgets('editing the code clears the sentence, and JOIN sends the new code', (tester) async {
      core.onJoin = (code) async => code == 'RECO-ALFA' ? recorderAlpha : throw const CoreException(JoinCodes.refused, refusal);
      await openJoin(tester);
      await enter(tester, 'XXXX0000');
      await tapJoin(tester);
      expect(problem, findsOneWidget);
      await enter(tester, 'RECOALFA');
      expect(problem, findsNothing);
      await tapJoin(tester);
      expect(find.text('Admitted as'), findsOneWidget);
      expect(core.joins, ['XXXX-0000', 'RECO-ALFA']);
    });
  });

  group('criterion 3: no signal', () {
    testWidgets('says admission needs signal, keeps the code, and sends it again without a second entry', (tester) async {
      var attempts = 0;
      core.onJoin = (code) async => ++attempts < 3 ? throw const CoreException(JoinCodes.noSignal, 'no answer') : recorderAlpha;
      await openJoin(tester);
      await enter(tester, 'RECOALFA');
      await tapJoin(tester);

      expect(needsSignal, findsOneWidget);
      expect(find.text(JoinScreen.needsSignal), findsOneWidget);
      expect(problem, findsNothing, reason: 'no signal is not a refusal');
      expect(fieldText(tester), 'RECO-ALFA');
      expect(attempts, 1);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(attempts, 2, reason: 'sent again on its own');
      expect(needsSignal, findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(attempts, 3);
      expect(core.joins, everyElement('RECO-ALFA'), reason: 'the same code each time, never re-entered');
      expect(needsSignal, findsNothing);
      expect(find.text('Admitted as'), findsOneWidget);
      expect(find.text('Recorder'), findsOneWidget);
    });

    testWidgets('leaving the screen stops the retry', (tester) async {
      var attempts = 0;
      core.onJoin = (code) async {
        attempts++;
        throw const CoreException(JoinCodes.noSignal, 'no answer');
      };
      await openJoin(tester);
      await enter(tester, 'RECOALFA');
      await tapJoin(tester);
      await tap(tester, find.byTooltip('Back'));
      expect(picker, findsOneWidget);
      await tester.pump(const Duration(seconds: 20));
      expect(attempts, 1);
    });

    testWidgets('a core with no server says so once, and does not retry', (tester) async {
      await openJoin(tester);
      await enter(tester, 'RECOALFA');
      await tapJoin(tester);
      expect(find.text(JoinScreen.noServer), findsOneWidget);
      expect(needsSignal, findsNothing);
      await tester.pump(const Duration(seconds: 20));
      expect(core.calls['join'], 1);
    });

    testWidgets('a failure the server did not judge says so, and JOIN tries again on a tap', (tester) async {
      var attempts = 0;
      core.onJoin = (code) async =>
          ++attempts == 1 ? throw const CoreException(JoinCodes.failed, 'The server is rate limiting sign-ins.') : recorderAlpha;
      await openJoin(tester);
      await enter(tester, 'RECOALFA');
      await tapJoin(tester);
      expect(find.textContaining('rate limiting'), findsOneWidget);
      await tester.pump(const Duration(seconds: 20));
      expect(attempts, 1, reason: 'no retry on its own');
      await tapJoin(tester);
      expect(find.text('Admitted as'), findsOneWidget);
    });
  });

  group('criterion 4: the join screen passes the bar-check helper', () {
    /// The checks the exploration makes on one screen, for a state it cannot type its way into.
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

      // One tap from the picker, as role_test's picker check already walks it,
      // and here two taps deep from a screen that stands in for the picker:
      // JOIN WITH CODE, then everything on the join screen (the field, and
      // Back to the screen beneath; JOIN with a code typed is beyond what the
      // exploration can reach, and the states test below covers it). The real
      // picker's other taps open the role homes, whose own checks hold them.
      testWidgets('from the picker, at $pct text', (tester) async {
        final violations = await barCheck(
          tester,
          (observer) => app(textScale: scale, on: FakeCore(), observer: observer),
          actionIds: const {},
          maxTaps: 1,
        );
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      testWidgets('the screen and everything on it, two taps deep, at $pct text', (tester) async {
        final violations = await barCheck(
          tester,
          (observer) => MediaQuery.withClampedTextScaling(
            minScaleFactor: scale,
            maxScaleFactor: scale,
            child: MaterialApp(
              theme: sunlightTheme(),
              navigatorObservers: [observer],
              home: _UnderJoin(core: FakeCore(), confirmation: ConfirmationService(device)),
            ),
          ),
          actionIds: const {},
        );
        expect(violations, isEmpty, reason: violations.join('\n'));
      });

      testWidgets('the refused, no-signal and admitted states, at $pct text', (tester) async {
        final semantics = tester.ensureSemantics();
        setPhoneSize(tester);
        final violations = <String>[];
        var answer = 0;
        core.onJoin = (code) async => switch (answer++) {
              0 => throw const CoreException(JoinCodes.refused, refusal),
              1 => throw const CoreException(JoinCodes.noSignal, 'no answer'),
              _ => recorderAlpha,
            };
        await tester.pumpWidget(app(textScale: scale));
        await tester.pumpAndSettle();
        await tap(tester, joinWithCode);
        await enter(tester, 'RECOALFA');
        await tapJoin(tester);
        expect(problem, findsOneWidget);
        violations.addAll(await checkState(tester, 'refused'));
        await tapJoin(tester);
        expect(needsSignal, findsOneWidget);
        violations.addAll(await checkState(tester, 'no signal'));
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expect(openHome, findsOneWidget);
        violations.addAll(await checkState(tester, 'admitted'));
        semantics.dispose();
        expect(violations, isEmpty, reason: violations.join('\n'));
      });
    }
  });

  test('the code formatter: letters and digits, upper-cased, a dash after four, nine at most', () {
    expect(CodeFormatter.format('reco alfa'), 'RECO-ALFA');
    expect(CodeFormatter.format('RECO-ALFA'), 'RECO-ALFA');
    expect(CodeFormatter.format('rec'), 'REC');
    expect(CodeFormatter.format('reco'), 'RECO');
    expect(CodeFormatter.format('reco1'), 'RECO-1');
    expect(CodeFormatter.format('reco-alfa-extra'), 'RECO-ALFA');
    expect(CodeFormatter.format(' 7k3m\n9xq2 '), '7K3M-9XQ2');
    expect(CodeFormatter.format(''), '');
  });
}

/// A screen the join screen is pushed over, standing in for the picker in the
/// bar check: one JOIN WITH CODE, so Back from the join screen lands on a
/// Scaffold the check can judge, as it does on the real picker.
class _UnderJoin extends StatelessWidget {
  const _UnderJoin({required this.core, required this.confirmation});

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
                  key: const ValueKey('join-with-code'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<Object?>(
                    builder: (_) => JoinScreen(core: core, confirmation: confirmation),
                  )),
                  child: const FitLabel('JOIN WITH CODE'),
                ),
              ),
            ),
          ),
        ),
      );
}

