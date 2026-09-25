import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

import 'support/fake_confirmation.dart';

/// #24 criterion 7, the UI's half: the home screen is driven against the fake
/// core, and reaches the log only through the async interface.
void main() {
  final quiet = ConfirmationService(FakeConfirmationDevice());

  Future<FakeCore> coreHolding(int events) async {
    final core = FakeCore();
    for (var i = 0; i < events; i++) {
      await core.append(const NewEvent(kind: 'note', source: 'tap'));
    }
    core.calls.clear();
    return core;
  }

  testWidgets('shows how many events are on this phone, read through the core', (tester) async {
    final core = await tester.runAsync(() => coreHolding(3));
    await tester.pumpWidget(ProCompanionApp(confirmation: quiet, core:core!));
    expect(find.text('Reading the log…'), findsOneWidget, reason: 'the call is async');
    await tester.pumpAndSettle();
    expect(find.text('3 events on this phone'), findsOneWidget);
    expect(core.calls, {'count': 1}, reason: 'one async call, and nothing but the interface');
  });

  testWidgets('says "1 event", not "1 events"', (tester) async {
    final core = await tester.runAsync(() => coreHolding(1));
    await tester.pumpWidget(ProCompanionApp(confirmation: quiet, core:core!));
    await tester.pumpAndSettle();
    expect(find.text('1 event on this phone'), findsOneWidget);
  });

  testWidgets('an empty log reads as zero, not as an error', (tester) async {
    await tester.pumpWidget(ProCompanionApp(confirmation: quiet, core:FakeCore()));
    await tester.pumpAndSettle();
    expect(find.text('0 events on this phone'), findsOneWidget);
  });

  // The CI emulator is a 320 x 640 dp phone. Back from FLEETS, the keyboard
  // is still up while home lays out, and with SEQUENCE added the column no
  // longer fit in what the keyboard left (#25, PR #94's integration job).
  testWidgets('home still fits on a 320 x 640 phone with the keyboard still up', (tester) async {
    tester.view.physicalSize = const Size(640, 1280);
    tester.view.devicePixelRatio = 2.0;
    // The status bar the emulator's SafeArea gave up; without it the column
    // had 24 dp more than on the device, and this passed before the fix.
    tester.view.padding = const FakeViewPadding(top: 24 * 2.0);
    tester.view.viewPadding = const FakeViewPadding(top: 24 * 2.0);
    tester.view.viewInsets = const FakeViewPadding(bottom: 243 * 2.0);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProCompanionApp(confirmation: quiet, core: FakeCore()));
    await tester.pumpAndSettle();
    for (final label in ['FLEETS', 'SEQUENCE', 'FINISHES']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
  });

  testWidgets('a core that fails is said so, not shown as a count', (tester) async {
    final core = FakeCore()..failWith = const CoreException('failed', 'disk gone');
    await tester.pumpWidget(ProCompanionApp(confirmation: quiet, core:core));
    await tester.pumpAndSettle();
    expect(find.text('The log on this phone could not be read'), findsOneWidget);
    expect(find.textContaining('events on this phone'), findsNothing);
  });
}
