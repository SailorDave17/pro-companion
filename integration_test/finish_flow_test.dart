import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_companion/confirmation.dart';
import 'package:pro_companion/main.dart' as app;

/// #4 on a device: the finish screen against the real core, and the real
/// buzz-and-beep channel. The widget tests drive a fake of both. The
/// confirmation service swallows platform errors on purpose, so only a direct
/// call proves MainActivity's handler exists and runs.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the platform confirmation channel answers vibrate and every tone stream', (tester) async {
    const device = PlatformConfirmationDevice();
    await device.vibrate();
    for (final stream in BeepStream.values) {
      await device.tone(stream);
    }
  });

  testWidgets('finish, finish, undo last - on the real core', (tester) async {
    await app.main();
    await tester.pumpAndSettle();
    await tester.tap(find.text('FINISHES'));
    await tester.pumpAndSettle();

    final heading = find.textContaining(RegExp(r'^Finishes · \d+$'));
    int shown() => int.parse((tester.widget<Text>(heading).data!).split('· ').last);
    final before = shown();

    final finish = find.widgetWithText(FilledButton, 'FINISH');
    await tester.tap(finish);
    await tester.pumpAndSettle();
    await tester.tap(finish);
    await tester.pumpAndSettle();
    expect(shown(), before + 2);

    await tester.tap(find.textContaining('UNDO LAST'));
    await tester.pumpAndSettle();
    expect(shown(), before + 1);
    expect(find.text('Not logged. Tap again.'), findsNothing);
  });
}
