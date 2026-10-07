import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion/roles/role_home.dart';
import 'package:pro_companion/ui/sunlight.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/fake_confirmation.dart';
import 'support/roles.dart';

/// #24 criterion 7, the UI's half: the home screen is driven against the fake
/// core, and reaches the log only through the async interface. Since #20 the
/// home is a role's, opened by the role picker; these hold the PRO's.
void main() {
  final quiet = ConfirmationService(FakeConfirmationDevice());

  testWidgets('shows how many events are on this phone, read through the core', (tester) async {
    final core = withRole(FakeCore());
    await tester.runAsync(() async {
      await core.append(const NewEvent(kind: 'note', source: 'tap'));
      await core.append(const NewEvent(kind: 'note', source: 'tap'));
    });
    core.calls.clear();
    await tester.pumpWidget(ProCompanionApp(confirmation: quiet, core: core));
    expect(find.text('Reading the log…'), findsOneWidget, reason: 'the call is async');
    await tester.pumpAndSettle();
    expect(find.text('3 events on this phone'), findsOneWidget, reason: 'the pick and two notes');
    expect(core.calls, {'readAll': 1, 'deviceId': 1, 'count': 1},
        reason: 'the role from the log, then the count: async calls, and nothing but the interface');
  });

  testWidgets('says "1 event", not "1 events"', (tester) async {
    await tester.pumpWidget(ProCompanionApp(confirmation: quiet, core: withRole(FakeCore())));
    await tester.pumpAndSettle();
    expect(find.text('1 event on this phone'), findsOneWidget);
  });

  testWidgets('an empty log reads as zero, not as an error', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: sunlightTheme(),
      home: RoleHome(role: Roles.overallPro, core: FakeCore(), confirmation: quiet, onUndo: () {}),
    ));
    await tester.pumpAndSettle();
    expect(find.text('0 events on this phone'), findsOneWidget);
  });

  // The CI emulator is a 320 x 640 dp phone. Back from FLEETS, the keyboard
  // is still up while home lays out, and with SEQUENCE added the column no
  // longer fit in what the keyboard left (#25, PR #94's integration job).
  // RESULTS (#7) is the fourth button, and UNDO ROLE (#20) a fifth; the
  // picker, which UNDO ROLE can open with the keyboard still up, must fit too.
  void shortPhoneWithKeyboard(WidgetTester tester) {
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2.0;
    // The status bar the emulator's SafeArea gave up; without it the column
    // had 24 dp more than on the device, and this passed before the fix.
    tester.view.padding = const FakeViewPadding(top: 24 * 2.0);
    tester.view.viewPadding = const FakeViewPadding(top: 24 * 2.0);
    tester.view.viewInsets = const FakeViewPadding(bottom: 243 * 2.0);
    addTearDown(tester.view.reset);
  }

  for (final scale in [1.0, 2.0]) {
    final pct = '${(scale * 100).round()}%';
    Widget app(FakeCore core) => MediaQuery.withClampedTextScaling(
          minScaleFactor: scale,
          maxScaleFactor: scale,
          child: ProCompanionApp(confirmation: quiet, core: core),
        );

    testWidgets('home still fits on a 320 x 640 phone with the keyboard still up, at $pct text', (tester) async {
      shortPhoneWithKeyboard(tester);
      await tester.pumpWidget(app(withRole(FakeCore())));
      await tester.pumpAndSettle();
      for (final label in ['UNDO ROLE', 'FLEETS', 'SEQUENCE', 'FINISHES', 'RESULTS']) {
        expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
      }
    });

    testWidgets('the picker fits there too, at $pct text', (tester) async {
      shortPhoneWithKeyboard(tester);
      await tester.pumpWidget(app(FakeCore()));
      await tester.pumpAndSettle();
      for (final label in ['PRO', 'RECORDER', 'MARK BOAT', 'SAFETY']) {
        expect(find.text(label).hitTestable(), findsOneWidget, reason: label);
      }
    });

    // A layout overflow fails a widget test by itself, so each of these fails
    // if the screen overflows rather than scrolls.
    testWidgets('with "Not logged" up there, the picker and the PRO home scroll rather than overflow, '
        'at $pct text', (tester) async {
      shortPhoneWithKeyboard(tester);
      final fresh = FakeCore();
      await tester.pumpWidget(app(fresh));
      await tester.pumpAndSettle();
      fresh.failWith = const CoreException('failed', 'disk gone');
      await tester.tap(find.text('PRO'));
      await tester.pumpAndSettle();
      expect(find.text('Not logged. Tap again.'), findsOneWidget);

      final picked = withRole(FakeCore());
      await tester.pumpWidget(const SizedBox.shrink()); // a fresh app, not the picker's state
      await tester.pumpWidget(app(picked));
      await tester.pumpAndSettle();
      picked.failWith = const CoreException('failed', 'disk gone');
      await tester.tap(find.text('UNDO ROLE'));
      await tester.pumpAndSettle();
      expect(find.text('Not logged. Tap again.'), findsOneWidget);
      await tester.dragUntilVisible(find.text('RESULTS'), find.byType(Scrollable), const Offset(0, -100));
      expect(find.text('RESULTS').hitTestable(), findsOneWidget, reason: 'the last button, scrolled to');
    });
  }

  testWidgets('a core that fails is said so, not shown as a count, and the picker is still offered', (tester) async {
    final core = FakeCore()..failWith = const CoreException('failed', 'disk gone');
    await tester.pumpWidget(ProCompanionApp(confirmation: quiet, core: core));
    await tester.pumpAndSettle();
    expect(find.text('The log on this phone could not be read'), findsOneWidget);
    expect(find.textContaining('events on this phone'), findsNothing);
    expect(find.text('Pick your role'), findsOneWidget);
  });
}
