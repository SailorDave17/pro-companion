import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pro_companion/main.dart' as app;

/// #18 on a device, against the real core: fleets are named on the FLEETS
/// screen, switched from the finish screen's row, each keeps its own
/// finishes, and a wrong switch is undone. The widget tests drive a fake core.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('name two fleets, switch between them, finish, undo a wrong switch - on the real core',
      (tester) async {
    await app.main();
    await tester.pumpAndSettle();

    // The log on a device outlives a run, so the names are new each time.
    final tag = (DateTime.now().millisecondsSinceEpoch % 100000).toString();
    final a = 'Red$tag';
    final b = 'Blue$tag';

    await tester.tap(find.text('FLEETS'));
    await tester.pumpAndSettle();
    for (final name in [a, b]) {
      await tester.enterText(find.byKey(const ValueKey('fleet-name')), name);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('fleet-add')));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining(a), findsOneWidget);
    expect(find.textContaining(b), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FINISHES'));
    await tester.pumpAndSettle();

    /// Switches by the row, or by MORE when earlier runs left more fleets
    /// than the row shows.
    Future<void> switchTo(String name) async {
      if (find.text(name).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('fleet-more')));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(name));
      await tester.pumpAndSettle();
    }

    Finder heading(String fleet, int n) => find.text('Finishes · $fleet · $n');
    final finish = find.widgetWithText(FilledButton, 'FINISH');

    await switchTo(a);
    expect(heading(a, 0), findsOneWidget);
    await tester.tap(finish);
    await tester.pumpAndSettle();
    await tester.tap(finish);
    await tester.pumpAndSettle();
    expect(heading(a, 2), findsOneWidget);

    await switchTo(b);
    expect(heading(b, 0), findsOneWidget, reason: "the other fleet's finishes are not this fleet's");
    await tester.tap(finish);
    await tester.pumpAndSettle();
    expect(heading(b, 1), findsOneWidget);

    await switchTo(a);
    expect(heading(a, 2), findsOneWidget);
    expect(find.text('UNDO SWITCH ($a)'), findsOneWidget);
    await tester.tap(find.text('UNDO SWITCH ($a)'));
    await tester.pumpAndSettle();
    expect(heading(b, 1), findsOneWidget, reason: 'the undone switch returns the phone to its fleet');
    expect(find.text('Not logged. Tap again.'), findsNothing);
  });
}
