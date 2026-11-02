import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pro_companion/fleets/fleet_picker_screen.dart';
import 'package:pro_companion/ui/race_time.dart';
import 'package:pro_companion/ui/sunlight.dart';
import 'package:pro_companion_core/core.dart';

import 'support/bar_check.dart';

/// #33 criterion 4, the second tap: the sequence screen opens the fleet picker
/// to move a race-timer sequence. Reached through the app in
/// test/sequence_link_test.dart; here, what the picker itself does.
void main() {
  const lasers = Fleet(id: '01J80000000000000000000001', name: 'Lasers');
  const fourTwenties = Fleet(id: '01J80000000000000000000002', name: '420s');
  const all = [lasers, fourTwenties];

  /// Opens the picker over a home screen, and the value it pops lands in the
  /// returned list. The extra slot tells a pop from a route never popped.
  Future<List<String?>> open(WidgetTester tester, {bool offerTakeBack = true, String? current}) async {
    setPhoneSize(tester);
    final popped = <String?>[];
    await tester.pumpWidget(MaterialApp(
      theme: sunlightTheme(),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            popped.add(await Navigator.of(context).push<String>(MaterialPageRoute(
              builder: (_) => FleetPickerScreen(
                fleets: all,
                current: current,
                title: 'Right fleet',
                actionId: 'sequence-fleet',
                itemScoped: true,
                offerTakeBack: offerTakeBack,
              ),
            )));
          },
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return popped;
  }

  final takeBackRow = find.byKey(const ValueKey('pick-take-back'));
  Finder row(Fleet f) => find.byKey(ValueKey('pick-${f.id}'));

  testWidgets("title 'Right fleet', action id 'sequence-fleet', and a tap on a fleet pops its id", (tester) async {
    final popped = await open(tester);
    expect(find.text('Right fleet'), findsOneWidget);
    final actions = tester.widgetList<RaceTimeAction>(find.byType(RaceTimeAction));
    expect(actions.map((a) => a.id), everyElement('sequence-fleet'));
    expect(actions.map((a) => a.itemScoped), everyElement(isTrue));
    expect(actions.map((a) => a.primary), everyElement(isTrue));

    await tester.tap(row(fourTwenties));
    await tester.pumpAndSettle();
    expect(popped, [fourTwenties.id]);
  });

  testWidgets('Back pops null', (tester) async {
    final popped = await open(tester);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(popped, [null]);
  });

  testWidgets("the fleet it is on reads '· now', and the others do not", (tester) async {
    await open(tester, current: lasers.id);
    expect(find.text('Lasers · now'), findsOneWidget);
    expect(find.text('420s'), findsOneWidget);
    expect(find.text('420s · now'), findsNothing);
  });

  testWidgets('a sequence on no fleet reads no fleet as now', (tester) async {
    await open(tester);
    expect(find.textContaining('· now'), findsNothing);
  });

  testWidgets('the take-back row pops FleetPickerScreen.takeBack', (tester) async {
    final popped = await open(tester);
    expect(find.text('NO FLEET · TAKE IT BACK'), findsOneWidget);
    await tester.tap(takeBackRow);
    await tester.pumpAndSettle();
    expect(popped, [FleetPickerScreen.takeBack]);
  });

  testWidgets('the take-back row shows only when it is offered', (tester) async {
    await open(tester, offerTakeBack: false);
    expect(takeBackRow, findsNothing);
    expect(row(lasers), findsOneWidget);
  });

  test('what the take-back row pops can never be a fleet: a fleet id is a ULID', () {
    expect(isUlid(FleetPickerScreen.takeBack), isFalse);
  });

  testWidgets('as the fleet switch opens it, nothing of the fix shows', (tester) async {
    setPhoneSize(tester);
    await tester.pumpWidget(MaterialApp(theme: sunlightTheme(), home: const FleetPickerScreen(fleets: all, current: null)));
    expect(find.text('Switch fleet'), findsOneWidget);
    expect(takeBackRow, findsNothing);
    final actions = tester.widgetList<RaceTimeAction>(find.byType(RaceTimeAction));
    expect(actions.map((a) => (a.id, a.itemScoped)), everyElement(('fleet-switch', false)));
  });
}
