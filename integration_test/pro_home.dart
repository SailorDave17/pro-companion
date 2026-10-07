import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion_core/core.dart';

/// Brings the app to the PRO's home (#20). The app's log on a device outlives
/// each test file, so a run may open on the role picker (a fresh install, or
/// after `pm clear`), on the PRO's home, or on another role's home.
///
/// Not named *_test.dart: a helper, not a test of its own.
Future<void> openProHome(WidgetTester tester) async {
  final undo = find.byKey(const ValueKey('undo-role'));
  if (undo.evaluate().isNotEmpty && find.text('PRO').evaluate().isEmpty) {
    await tester.tap(undo);
    await tester.pumpAndSettle();
  }
  final pick = find.byKey(const ValueKey('pick-${Roles.overallPro}'));
  if (pick.evaluate().isNotEmpty) {
    await tester.tap(pick);
    await tester.pumpAndSettle();
  }
  expect(find.text('SEQUENCE'), findsOneWidget, reason: "the PRO's home");
}
