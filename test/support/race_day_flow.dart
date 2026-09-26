import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion_core/core.dart';

/// A two-race day run through the app from its home, the way the PRO runs
/// it, ending on provisional results (#7 criterion 2). Shared by the host
/// test (test/results_offline_test.dart) and the on-device one
/// (integration_test/offline_results_flow.dart), so both prove one flow.
///
/// Each race is a GUN on the sequence screen and FINISH taps on the finish
/// screen. The sail numbers go straight to [core]: the keypad shows only its
/// first row on the CI emulator's 320 x 640 phone (#95), and naming boats is
/// #4's, proven there.
///
/// Expects [core] to hold nothing yet, and leaves the results screen open
/// with one discard set.
Future<void> raceDayToResults(WidgetTester tester, CoreClient core) async {
  Future<void> open(String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  Future<void> back() async {
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
  }

  Future<void> race(List<String> sails) async {
    await open('SEQUENCE');
    await tester.tap(find.widgetWithText(FilledButton, 'GUN'));
    await tester.pumpAndSettle();
    await back();

    await open('FINISHES');
    final named = {
      for (final e in (await tester.runAsync(core.readAll))!)
        if (e.kind == FinishKinds.finish) e.ulid,
    };
    for (var i = 0; i < sails.length; i++) {
      await tester.tap(find.widgetWithText(FilledButton, 'FINISH'));
      await tester.pumpAndSettle();
    }
    await back();

    final tapped = [
      for (final e in (await tester.runAsync(core.readAll))!)
        if (e.kind == FinishKinds.finish && !named.contains(e.ulid)) e,
    ]..sort(happened);
    expect(tapped, hasLength(sails.length), reason: 'one finish per tap');
    for (var i = 0; i < sails.length; i++) {
      await tester.runAsync(() => core.append(FinishEvents.assignSail(tapped[i].ulid, sails[i])));
    }
  }

  await race(['11', '22', '33']);
  await race(['33', '11']);

  await open('RESULTS');
  expect(find.text('2 races · provisional'), findsOneWidget);
  expect(raceDayLine(tester, '11'), ['1', '11', '3', 'R1 1', 'R2 2']);
  expect(raceDayLine(tester, '33'), ['2', '33', '4', 'R1 3', 'R2 1']);
  expect(raceDayLine(tester, '22'), ['3', '22', '6', 'R1 2', 'R2 DNC 4']);

  await tester.tap(find.byKey(const ValueKey('discards-more-null')));
  await tester.pumpAndSettle();
  expect(find.text('Discards: 1'), findsOneWidget);
  expect(raceDayLine(tester, '22'), ['3', '22', '2', 'R1 2', 'R2 (DNC 4)']);
}

/// Every text in [boat]'s line on the results screen, in order: rank, boat,
/// series points, then each race's points.
List<String> raceDayLine(WidgetTester tester, String boat) => [
      for (final t in tester.widgetList<Text>(
          find.descendant(of: find.byKey(ValueKey('standing-$boat')), matching: find.byType(Text))))
        t.data!,
    ];
