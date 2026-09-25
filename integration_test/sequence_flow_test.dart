import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_companion/main.dart' as app;

/// #25 on a device, against the real core and the real buzz-and-beep
/// channel: a manual gun, its time fixed by hand, a general recall and its
/// undo. The widget tests drive a fake of both.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('gun, fix its time, general recall, undo the recall - on the real core', (tester) async {
    await app.main();
    await tester.pumpAndSettle();

    // The log on a device outlives a run, so the fleet is new each time and
    // starts with no sequence of its own.
    final fleet = 'Start${DateTime.now().millisecondsSinceEpoch % 100000}';
    await tester.tap(find.text('FLEETS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('fleet-name')), fleet);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('fleet-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('SEQUENCE'));
    await tester.pumpAndSettle();
    if (find.text(fleet).evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('fleet-more')));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text(fleet));
    await tester.pumpAndSettle();
    expect(find.text('Sequence · $fleet'), findsOneWidget);
    expect(find.text('NO GUN'), findsOneWidget);

    final card = find.byKey(const ValueKey('start-card'));
    String headline() =>
        tester.widget<Text>(find.descendant(of: card, matching: find.textContaining(RegExp(r'^(GUN|NO GUN|GENERAL)')))).data!;

    await tester.tap(find.widgetWithText(FilledButton, 'GUN'));
    await tester.pumpAndSettle();
    final tapped = headline().substring('GUN '.length);

    // The gun "really went" one second before the tap.
    final parts = tapped.split(':').map(int.parse).toList();
    final now = DateTime.now();
    final real = DateTime(now.year, now.month, now.day, parts[0], parts[1], parts[2])
        .subtract(const Duration(seconds: 1));
    String two(int n) => n.toString().padLeft(2, '0');
    final typed = '${two(real.hour)}${two(real.minute)}${two(real.second)}';
    final fixed = '${two(real.hour)}:${two(real.minute)}:${two(real.second)}';

    await tester.tap(card);
    await tester.pumpAndSettle();
    // The CI emulator is a 320 x 640 dp phone, where only the keypad's first
    // row is on screen: a tap on a key below it lands on UNDO instead (PR #94,
    // measured). Each key is scrolled into view first; fitting both keypads on
    // a phone that small is #95.
    Future<void> press(Finder key) async {
      await tester.ensureVisible(key);
      await tester.pumpAndSettle();
      await tester.tap(key);
      await tester.pump();
    }

    for (final d in typed.split('')) {
      await press(find.byKey(ValueKey('key-$d')));
    }
    await press(find.byKey(const ValueKey('keypad-save')));
    await tester.pumpAndSettle();
    expect(headline(), 'GUN $fixed');
    expect(find.textContaining('tapped $tapped'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'GENERAL RECALL'));
    await tester.pumpAndSettle();
    expect(headline(), 'GENERAL RECALL');

    await tester.tap(find.text('UNDO RECALL'));
    await tester.pumpAndSettle();
    expect(headline(), 'GUN $fixed', reason: 'the recalled gun anchors again, at its fixed time');
    expect(find.text('Not logged. Tap again.'), findsNothing);
  });
}
