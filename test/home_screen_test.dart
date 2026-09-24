import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/main.dart';
import 'package:pro_companion_core/core.dart';
import 'package:pro_companion_core/testing.dart';

/// #24 criterion 7, the UI's half: the home screen is driven against the fake
/// core, and reaches the log only through the async interface.
void main() {
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
    await tester.pumpWidget(ProCompanionApp(core: core!));
    expect(find.text('Reading the log…'), findsOneWidget, reason: 'the call is async');
    await tester.pumpAndSettle();
    expect(find.text('3 events on this phone'), findsOneWidget);
    expect(core.calls, {'count': 1}, reason: 'one async call, and nothing but the interface');
  });

  testWidgets('says "1 event", not "1 events"', (tester) async {
    final core = await tester.runAsync(() => coreHolding(1));
    await tester.pumpWidget(ProCompanionApp(core: core!));
    await tester.pumpAndSettle();
    expect(find.text('1 event on this phone'), findsOneWidget);
  });

  testWidgets('an empty log reads as zero, not as an error', (tester) async {
    await tester.pumpWidget(ProCompanionApp(core: FakeCore()));
    await tester.pumpAndSettle();
    expect(find.text('0 events on this phone'), findsOneWidget);
  });

  testWidgets('a core that fails is said so, not shown as a count', (tester) async {
    final core = FakeCore()..failWith = const CoreException('failed', 'disk gone');
    await tester.pumpWidget(ProCompanionApp(core: core));
    await tester.pumpAndSettle();
    expect(find.text('The log on this phone could not be read'), findsOneWidget);
    expect(find.textContaining('events on this phone'), findsNothing);
  });
}
